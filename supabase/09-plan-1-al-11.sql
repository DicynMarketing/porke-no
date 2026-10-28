-- =====================================================================
-- Porké No? · Paso 9: plan del 1 al 11
-- Correr una sola vez en SQL Editor › New query › Run (después del 08).
--
--  1. Eliminar mi cuenta (Ley 81)
--  4. Pedidos en espera ("tu pedido se tomará en breve")
--  7. Ubicación del motorizado en el mapa del cliente
--  8. Pedidos programados
--  9. Avisos de promociones a los clientes que los aceptaron
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Eliminar mi cuenta. Borra la cuenta, el perfil, direcciones, avisos,
--    sellos y cupones. Los pedidos se conservan (registros de ventas que
--    exige la ley) pero sin nombre, teléfono, correo ni dirección.
-- ---------------------------------------------------------------------
create or replace function public.eliminar_mi_cuenta()
returns void language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid();
begin
  if u is null then
    raise exception 'Inicia sesión para eliminar tu cuenta';
  end if;
  if exists (select 1 from public.equipo where usuario_id = u and activo) then
    raise exception 'Las cuentas del equipo se quitan desde el administrador';
  end if;
  if exists (select 1 from public.pedidos where cliente_id = u and estado in ('recibido', 'preparando', 'en_camino')) then
    raise exception 'Tienes un pedido en curso. Podrás eliminar tu cuenta cuando se entregue';
  end if;
  update public.pedidos p
     set nombre = 'Cliente eliminado', telefono = '0000-0000', correo = null, referencia = null, nota = null,
         lat = case when p.tipo = 'delivery' then s.lat end,
         lng = case when p.tipo = 'delivery' then s.lng end,
         cliente_id = null
    from public.sucursales s
   where s.id = p.sucursal_id and p.cliente_id = u;
  delete from auth.users where id = u;   -- borra en cascada perfil, direcciones, avisos, sellos y cupones
end $$;
revoke execute on function public.eliminar_mi_cuenta() from public, anon;
grant execute on function public.eliminar_mi_cuenta() to authenticated;

-- ---------------------------------------------------------------------
-- 4. Pedidos en espera: el admin lo activa por unos minutos; el cliente ve
--    "Tu pedido se tomará en breve" y la espera estimada sube.
-- ---------------------------------------------------------------------
alter table public.sucursales add column if not exists espera_hasta timestamptz;
alter table public.sucursales add column if not exists espera_min smallint not null default 20
  check (espera_min between 5 and 120);

-- ---------------------------------------------------------------------
-- 8. Pedidos programados (el cliente elige la hora).
-- ---------------------------------------------------------------------
alter table public.pedidos add column if not exists programado_para timestamptz;
create index if not exists pedidos_programados on public.pedidos (sucursal_id, programado_para)
  where programado_para is not null;

-- ---------------------------------------------------------------------
-- 7. Ubicación del motorizado mientras lleva un pedido.
-- ---------------------------------------------------------------------
create table if not exists public.ubicaciones_motorizado (
  motorizado_id  uuid primary key references auth.users (id) on delete cascade,
  sucursal_id    uuid not null references public.sucursales (id) on delete cascade,
  lat            double precision not null check (lat between -90 and 90),
  lng            double precision not null check (lng between -180 and 180),
  actualizado_en timestamptz not null default now()
);
alter table public.ubicaciones_motorizado enable row level security;
drop policy if exists "ubicaciones: motorizado crea" on public.ubicaciones_motorizado;
drop policy if exists "ubicaciones: motorizado actualiza" on public.ubicaciones_motorizado;
drop policy if exists "ubicaciones: ver propia o del local" on public.ubicaciones_motorizado;
create policy "ubicaciones: motorizado crea" on public.ubicaciones_motorizado
  for insert to authenticated
  with check (motorizado_id = auth.uid() and public.es_equipo(sucursal_id, 'motorizado'));
create policy "ubicaciones: motorizado actualiza" on public.ubicaciones_motorizado
  for update to authenticated
  using (motorizado_id = auth.uid())
  with check (motorizado_id = auth.uid() and public.es_equipo(sucursal_id, 'motorizado'));
create policy "ubicaciones: ver propia o del local" on public.ubicaciones_motorizado
  for select to authenticated using (motorizado_id = auth.uid() or public.es_admin(sucursal_id));
grant select, insert, update on public.ubicaciones_motorizado to authenticated;
grant all on public.ubicaciones_motorizado to service_role;

-- El cliente solo ve al motorizado de SU pedido, solo mientras va en camino.
create or replace function public.ubicacion_de_mi_pedido(p_pedido uuid)
returns table (lat double precision, lng double precision, actualizado_en timestamptz)
language sql stable security definer set search_path = '' as $$
  select u.lat, u.lng, u.actualizado_en
    from public.pedidos p
    join public.ubicaciones_motorizado u on u.motorizado_id = p.motorizado_id
   where p.id = p_pedido and p.cliente_id = auth.uid() and p.estado = 'en_camino'
     and u.actualizado_en > now() - interval '10 minutes';
$$;
revoke execute on function public.ubicacion_de_mi_pedido(uuid) from public, anon;
grant execute on function public.ubicacion_de_mi_pedido(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 9. Avisos de promociones. Solo a clientes que activaron "Promociones" en
--    Mi cuenta › Notificaciones. Máximo 3 avisos por día.
-- ---------------------------------------------------------------------
alter table public.push_pendientes drop constraint if exists push_pendientes_tipo_check;
alter table public.push_pendientes add constraint push_pendientes_tipo_check
  check (tipo in ('nuevo', 'estado', 'pago', 'entrega', 'version', 'solicitud', 'promo'));

create table if not exists public.avisos_promo (
  id            bigint generated always as identity primary key,
  sucursal_id   uuid not null references public.sucursales (id) on delete cascade,
  titulo        text not null check (length(trim(titulo)) between 1 and 60),
  texto         text not null check (length(trim(texto)) between 1 and 160),
  destinatarios integer not null default 0,
  enviado_por   uuid references auth.users (id) on delete set null,
  creado_en     timestamptz not null default now()
);
alter table public.avisos_promo enable row level security;
drop policy if exists "avisos: admin ve" on public.avisos_promo;
create policy "avisos: admin ve" on public.avisos_promo
  for select to authenticated using (public.es_admin(sucursal_id));
grant select on public.avisos_promo to authenticated;
grant all on public.avisos_promo to service_role;

create or replace function public.avisar_promocion(p_sucursal uuid, p_titulo text, p_texto text)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  if not public.es_admin(p_sucursal) then
    raise exception 'Solo el administrador puede enviar avisos';
  end if;
  if (select count(*) from public.avisos_promo
       where sucursal_id = p_sucursal and creado_en > now() - interval '24 hours') >= 3 then
    raise exception 'Ya enviaste 3 avisos hoy. Para no molestar a los clientes, espera hasta mañana';
  end if;
  select count(*) into n from public.clientes where notif_promos;
  insert into public.avisos_promo (sucursal_id, titulo, texto, destinatarios, enviado_por)
  values (p_sucursal, trim(p_titulo), trim(p_texto), n, auth.uid());
  insert into public.push_pendientes (tipo, datos)
  values ('promo', jsonb_build_object('titulo', trim(p_titulo), 'texto', trim(p_texto)));
  perform public.disparar_envio_push();
  return n;
end $$;
revoke execute on function public.avisar_promocion(uuid, text, text) from public, anon;
grant execute on function public.avisar_promocion(uuid, text, text) to authenticated;

commit;
