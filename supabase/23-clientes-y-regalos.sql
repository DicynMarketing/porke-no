-- =====================================================================
-- Porké No? · Paso 23: registro de clientes y regalos personales
-- (el admin elige a un cliente y le regala un % o $ de descuento, o un
-- producto/combo gratis; le llega un aviso y lo usa al pagar).
-- Ya aplicado por Claude.
-- =====================================================================

create table if not exists public.regalos (
  id           uuid primary key default gen_random_uuid(),
  sucursal_id  uuid not null references public.sucursales (id) on delete cascade,
  cliente_id   uuid not null references auth.users (id) on delete cascade,
  tipo         text not null check (tipo in ('porcentaje', 'monto', 'producto')),
  valor        numeric(6,2) check (valor is null or valor > 0),
  producto     text check (producto is null or length(producto) <= 40),
  titulo       text not null check (length(titulo) between 1 and 80),
  mensaje      text check (mensaje is null or length(mensaje) <= 140),
  estado       text not null default 'disponible' check (estado in ('disponible', 'usado', 'anulado')),
  vence_en     timestamptz not null,
  visto_en     timestamptz,
  usado_en     timestamptz,
  pedido_id    uuid references public.pedidos (id) on delete set null,
  creado_por   uuid references auth.users (id) on delete set null,
  creado_en    timestamptz not null default now(),
  check ((tipo = 'producto' and producto is not null) or (tipo <> 'producto' and valor is not null)),
  check (tipo <> 'porcentaje' or valor <= 100)
);
create index if not exists regalos_cliente on public.regalos (cliente_id, estado);
create index if not exists regalos_sucursal on public.regalos (sucursal_id, creado_en);
alter table public.regalos enable row level security;
drop policy if exists "regalos: propios o admin" on public.regalos;
create policy "regalos: propios o admin" on public.regalos for select to authenticated
  using (cliente_id = auth.uid() or public.es_admin(sucursal_id));
grant select on public.regalos to authenticated;
grant all on public.regalos to service_role;

alter table public.pedidos add column if not exists regalo_id uuid references public.regalos (id) on delete set null;

alter table public.push_pendientes drop constraint if exists push_pendientes_tipo_check;
alter table public.push_pendientes add constraint push_pendientes_tipo_check
  check (tipo in ('nuevo', 'estado', 'pago', 'entrega', 'version', 'solicitud', 'promo', 'llegada', 'regalo'));

-- Registro de clientes para el admin: pedidos, gasto y fechas (sin contar cancelados).
create or replace function public.admin_clientes(p_sucursal uuid)
returns table (cliente_id uuid, nombre text, telefono text, pedidos integer, gastado numeric,
               primero timestamptz, ultimo timestamptz, pedidos_60d integer, regalos_activos integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.es_admin(p_sucursal) then raise exception 'Sin permiso'; end if;
  return query
  select p.cliente_id,
         (array_agg(p.nombre order by p.creado_en desc))[1]::text,
         (array_agg(p.telefono order by p.creado_en desc))[1]::text,
         count(*)::integer, coalesce(sum(p.subtotal), 0)::numeric,
         min(p.creado_en), max(p.creado_en),
         (count(*) filter (where p.creado_en > now() - interval '60 days'))::integer,
         (select count(*)::integer from public.regalos g
           where g.cliente_id = p.cliente_id and g.sucursal_id = p_sucursal and g.estado = 'disponible' and g.vence_en > now())
    from public.pedidos p
   where p.sucursal_id = p_sucursal and p.cliente_id is not null
     and p.estado::text <> 'cancelado' and p.estado_pago::text is distinct from 'rechazado'
   group by p.cliente_id
   order by count(*) desc, max(p.creado_en) desc
   limit 2000;
end $$;
revoke execute on function public.admin_clientes(uuid) from public, anon;
grant execute on function public.admin_clientes(uuid) to authenticated;

-- El admin le regala algo a un cliente que ya pidió en su local.
create or replace function public.admin_regalar(p_sucursal uuid, p_cliente uuid, p_tipo text, p_valor numeric,
                                                p_producto text, p_mensaje text, p_dias integer)
returns public.regalos language plpgsql security definer set search_path = '' as $$
declare
  r public.regalos;
  t text;
  nom text;
begin
  if not public.es_admin(p_sucursal) then raise exception 'Solo el administrador puede regalar'; end if;
  if not exists (select 1 from public.pedidos where sucursal_id = p_sucursal and cliente_id = p_cliente) then
    raise exception 'Ese cliente no ha pedido en este local';
  end if;
  if (select count(*) from public.regalos where sucursal_id = p_sucursal and creado_en > now() - interval '24 hours') >= 100 then
    raise exception 'Llegaste al máximo de regalos por hoy';
  end if;
  if p_dias is null or p_dias not between 1 and 90 then raise exception 'Elige cuántos días dura el regalo (1 a 90)'; end if;
  if p_tipo = 'porcentaje' then
    if p_valor is null or p_valor < 1 or p_valor > 100 then raise exception 'El descuento debe ser de 1%% a 100%%'; end if;
    t := to_char(p_valor, 'FM990') || '% de descuento en tu pedido';
  elsif p_tipo = 'monto' then
    if p_valor is null or p_valor < 0.25 or p_valor > 100 then raise exception 'El descuento debe ser de $0.25 a $100'; end if;
    t := '$' || to_char(p_valor, 'FM990.00') || ' de descuento en tu pedido';
  elsif p_tipo = 'producto' then
    if p_producto like 'c:%' then
      select nombre into nom from public.promociones where sucursal_id = p_sucursal and tipo = 'combo' and id::text = substr(p_producto, 3);
    else
      select nombre into nom from public.productos where sucursal_id = p_sucursal and codigo = p_producto;
    end if;
    if nom is null then raise exception 'Ese producto no existe'; end if;
    t := nom || ' GRATIS';
  else
    raise exception 'Tipo de regalo no válido';
  end if;
  insert into public.regalos (sucursal_id, cliente_id, tipo, valor, producto, titulo, mensaje, vence_en, creado_por)
  values (p_sucursal, p_cliente, p_tipo, case when p_tipo = 'producto' then null else round(p_valor, 2) end,
          case when p_tipo = 'producto' then p_producto else null end, left(t, 80),
          nullif(left(trim(coalesce(p_mensaje, '')), 140), ''), now() + make_interval(days => p_dias), auth.uid())
  returning * into r;
  insert into public.push_pendientes (tipo, datos)
  values ('regalo', jsonb_build_object('cliente', p_cliente, 'titulo', '🎁 ¡Tienes un regalo de Porké No?!',
                                       'texto', r.titulo || coalesce(' · ' || r.mensaje, '')));
  perform public.disparar_envio_push();
  return r;
end $$;
revoke execute on function public.admin_regalar(uuid, uuid, text, numeric, text, text, integer) from public, anon;
grant execute on function public.admin_regalar(uuid, uuid, text, numeric, text, text, integer) to authenticated;

-- El admin anula un regalo que todavía no se usó.
create or replace function public.admin_anular_regalo(p_regalo uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.regalos set estado = 'anulado'
   where id = p_regalo and estado = 'disponible' and public.es_admin(sucursal_id);
  if not found then raise exception 'No se pudo anular (ya se usó o no tienes permiso)'; end if;
end $$;
revoke execute on function public.admin_anular_regalo(uuid) from public, anon;
grant execute on function public.admin_anular_regalo(uuid) to authenticated;

-- El cliente ya vio la animación del regalo.
create or replace function public.regalo_visto(p_regalo uuid)
returns void language sql security definer set search_path = '' as $$
  update public.regalos set visto_en = coalesce(visto_en, now()) where id = p_regalo and cliente_id = auth.uid();
$$;
revoke execute on function public.regalo_visto(uuid) from public, anon;
grant execute on function public.regalo_visto(uuid) to authenticated;

-- Si el pedido se cancela, el regalo vuelve a estar disponible.
create or replace function public.pedidos_soltar_regalo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.estado = 'cancelado' and old.estado <> 'cancelado' and new.regalo_id is not null then
    update public.regalos set estado = 'disponible', usado_en = null, pedido_id = null
     where id = new.regalo_id and estado = 'usado';
  end if;
  return new;
end $$;
drop trigger if exists pedidos_soltar_regalo on public.pedidos;
create trigger pedidos_soltar_regalo after update of estado on public.pedidos
  for each row execute function public.pedidos_soltar_regalo();
revoke execute on function public.pedidos_soltar_regalo() from public, anon, authenticated;
