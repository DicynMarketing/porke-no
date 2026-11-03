-- =====================================================================
-- Porké No? · Paso 17: "Llegué", bloqueo de clientes, favoritos y
-- tiempo meta de la cocina.
-- Correr una sola vez en SQL Editor › New query › Run (después del 16).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. El motorizado avisa "Llegué" y al cliente le llega la notificación.
-- ---------------------------------------------------------------------
alter table public.pedidos add column if not exists llego_en timestamptz;

alter table public.push_pendientes drop constraint if exists push_pendientes_tipo_check;
alter table public.push_pendientes add constraint push_pendientes_tipo_check
  check (tipo in ('nuevo', 'estado', 'pago', 'entrega', 'version', 'solicitud', 'promo', 'llegada'));

create or replace function public.pedidos_marcar_en_camino()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.estado = 'en_camino' and (tg_op = 'INSERT' or old.estado is distinct from 'en_camino'
                                   or old.motorizado_id is distinct from new.motorizado_id) then
    new.en_camino_desde := now();
    new.entrega_vista_en := null;
    new.llego_en := null;
  end if;
  return new;
end $$;

create or replace function public.motorizado_llegue(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  update public.pedidos set llego_en = now(), entrega_vista_en = coalesce(entrega_vista_en, now())
   where id = p_pedido and motorizado_id = auth.uid() and estado = 'en_camino'
     and tipo = 'delivery' and llego_en is null and public.es_equipo(sucursal_id, 'motorizado')
  returning * into r;
  if found then
    insert into public.push_pendientes (tipo, pedido_id) values ('llegada', r.id);
    perform public.disparar_envio_push();
    return r;
  end if;
  select * into r from public.pedidos where id = p_pedido and motorizado_id = auth.uid();
  if not found then raise exception 'Este pedido no está en camino contigo'; end if;
  return r;
end $$;
revoke execute on function public.motorizado_llegue(uuid) from public, anon;
grant execute on function public.motorizado_llegue(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Clientes bloqueados (por cuenta y por teléfono).
-- ---------------------------------------------------------------------
create table if not exists public.bloqueos (
  id          bigint generated always as identity primary key,
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  cliente_id  uuid references auth.users (id) on delete set null,
  telefono    text,
  nombre      text,
  motivo      text check (motivo is null or length(motivo) <= 120),
  creado_por  uuid references auth.users (id) on delete set null,
  creado_en   timestamptz not null default now()
);
create index if not exists bloqueos_tel on public.bloqueos (sucursal_id, telefono);
create index if not exists bloqueos_cli on public.bloqueos (sucursal_id, cliente_id);
alter table public.bloqueos enable row level security;
drop policy if exists "bloqueos: admin ve" on public.bloqueos;
create policy "bloqueos: admin ve" on public.bloqueos for select to authenticated using (public.es_admin(sucursal_id));
grant select on public.bloqueos to authenticated;
grant all on public.bloqueos to service_role;

-- ¿Está bloqueado este cliente o este teléfono? (lo usa crear-pedido)
create or replace function public.esta_bloqueado(p_sucursal uuid, p_cliente uuid, p_telefono text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bloqueos b
                  where b.sucursal_id = p_sucursal
                    and (b.cliente_id = p_cliente
                         or (p_telefono is not null and b.telefono = regexp_replace(p_telefono, '\D', '', 'g'))));
$$;
revoke execute on function public.esta_bloqueado(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.esta_bloqueado(uuid, uuid, text) to service_role;

-- El admin bloquea al cliente de un pedido (su cuenta y su teléfono).
create or replace function public.admin_bloquear(p_pedido uuid, p_motivo text)
returns public.bloqueos language plpgsql security definer set search_path = '' as $$
declare
  p public.pedidos;
  r public.bloqueos;
begin
  select * into p from public.pedidos where id = p_pedido;
  if not found or not public.es_admin(p.sucursal_id) then raise exception 'Sin permiso'; end if;
  insert into public.bloqueos (sucursal_id, cliente_id, telefono, nombre, motivo, creado_por)
  values (p.sucursal_id, p.cliente_id, regexp_replace(coalesce(p.telefono, ''), '\D', '', 'g'), p.nombre,
          nullif(left(trim(coalesce(p_motivo, '')), 120), ''), auth.uid())
  returning * into r;
  return r;
end $$;
revoke execute on function public.admin_bloquear(uuid, text) from public, anon;
grant execute on function public.admin_bloquear(uuid, text) to authenticated;

create or replace function public.admin_desbloquear(p_bloqueo bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  delete from public.bloqueos where id = p_bloqueo and public.es_admin(sucursal_id);
  if not found then raise exception 'Sin permiso'; end if;
end $$;
revoke execute on function public.admin_desbloquear(bigint) from public, anon;
grant execute on function public.admin_desbloquear(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 3. Favoritos del cliente.
-- ---------------------------------------------------------------------
create table if not exists public.favoritos (
  cliente_id  uuid not null references auth.users (id) on delete cascade,
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  codigo      text not null check (length(codigo) between 1 and 60),
  creado_en   timestamptz not null default now(),
  primary key (cliente_id, sucursal_id, codigo)
);
alter table public.favoritos enable row level security;
drop policy if exists "favoritos: propios" on public.favoritos;
create policy "favoritos: propios" on public.favoritos for all to authenticated
  using (cliente_id = auth.uid()) with check (cliente_id = auth.uid());
grant select, insert, delete on public.favoritos to authenticated;
grant all on public.favoritos to service_role;

create or replace function public.favoritos_tope()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.favoritos where cliente_id = new.cliente_id) >= 50 then
    raise exception 'Llegaste al máximo de favoritos';
  end if;
  return new;
end $$;
drop trigger if exists favoritos_tope on public.favoritos;
create trigger favoritos_tope before insert on public.favoritos for each row execute function public.favoritos_tope();
revoke execute on function public.favoritos_tope() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Tiempo meta de la cocina (minutos) para el temporizador.
-- ---------------------------------------------------------------------
alter table public.sucursales add column if not exists cocina_meta_min smallint not null default 20
  check (cocina_meta_min between 5 and 90);

commit;
