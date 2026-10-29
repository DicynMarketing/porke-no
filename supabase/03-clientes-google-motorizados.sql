-- =====================================================================
-- Porké No? · Paso 3: clientes con Google, motorizados por dispositivo
-- aprobado y comprobante por correo.
-- Correr DESPUÉS de schema.sql y 02-notificaciones.sql, una sola vez,
-- en SQL Editor › New query › Run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Clientes: el celular es solo un dato de contacto (se puede repetir
--    entre cuentas). La cuenta es única por correo gracias a Google.
-- ---------------------------------------------------------------------
alter table public.clientes drop constraint if exists clientes_telefono_key;
alter table public.clientes add column if not exists celular text check (celular ~ '^[0-9]{4}-[0-9]{4}$');
grant insert (celular) on public.clientes to authenticated;
grant update (celular) on public.clientes to authenticated;

-- ---------------------------------------------------------------------
-- 2. Solicitudes de acceso de motorizados (por dispositivo)
-- ---------------------------------------------------------------------
create table public.solicitudes_acceso (
  id           uuid primary key default gen_random_uuid(),
  sucursal_id  uuid not null references public.sucursales (id) on delete cascade,
  usuario_id   uuid not null references auth.users (id) on delete cascade,
  nombre       text not null check (length(trim(nombre)) between 2 and 60),
  dispositivo  text check (length(dispositivo) <= 80),
  estado       text not null default 'pendiente'
               check (estado in ('pendiente', 'aprobada', 'rechazada', 'cancelada', 'revocada')),
  creado_en    timestamptz not null default now(),
  resuelto_en  timestamptz,
  resuelto_por uuid
);
create unique index solicitudes_una_pendiente on public.solicitudes_acceso (usuario_id, sucursal_id) where estado = 'pendiente';
create index solicitudes_sucursal on public.solicitudes_acceso (sucursal_id, estado, creado_en desc);

alter table public.solicitudes_acceso enable row level security;
create policy "solicitudes: ver propias o del local" on public.solicitudes_acceso
  for select to authenticated using (usuario_id = auth.uid() or public.es_admin(sucursal_id));
grant select on public.solicitudes_acceso to authenticated;          -- escribir solo por las funciones de abajo
grant all on public.solicitudes_acceso to service_role;

-- El motorizado pide acceso desde su teléfono (sesión anónima del dispositivo).
create function public.solicitar_acceso(p_sucursal text, p_nombre text, p_dispositivo text default null)
returns public.solicitudes_acceso language plpgsql security definer set search_path = '' as $$
declare
  s uuid;
  r public.solicitudes_acceso;
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  select id into s from public.sucursales where slug = p_sucursal and activa;
  if s is null then raise exception 'Local no encontrado'; end if;
  if exists (select 1 from public.equipo where usuario_id = auth.uid() and sucursal_id = s and activo) then
    raise exception 'Este teléfono ya tiene acceso';
  end if;
  update public.solicitudes_acceso set estado = 'cancelada', resuelto_en = now()
   where usuario_id = auth.uid() and sucursal_id = s and estado = 'pendiente';
  insert into public.solicitudes_acceso (sucursal_id, usuario_id, nombre, dispositivo)
  values (s, auth.uid(), trim(p_nombre), left(p_dispositivo, 80))
  returning * into r;
  return r;
end $$;

-- El motorizado cancela su propia solicitud pendiente.
create function public.cancelar_mi_solicitud()
returns void language sql security definer set search_path = '' as $$
  update public.solicitudes_acceso set estado = 'cancelada', resuelto_en = now()
   where usuario_id = auth.uid() and estado = 'pendiente';
$$;

-- El administrador aprueba, rechaza o cancela una solicitud pendiente.
create function public.resolver_solicitud(p_solicitud uuid, p_accion text)
returns public.solicitudes_acceso language plpgsql security definer set search_path = '' as $$
declare
  r public.solicitudes_acceso;
begin
  select * into r from public.solicitudes_acceso where id = p_solicitud for update;
  if not found or not public.es_admin(r.sucursal_id) then raise exception 'Solicitud no encontrada'; end if;
  if r.estado <> 'pendiente' then raise exception 'Esta solicitud ya fue resuelta'; end if;
  if p_accion not in ('aprobar', 'rechazar', 'cancelar') then raise exception 'Acción inválida'; end if;
  if p_accion = 'aprobar' then
    insert into public.equipo (usuario_id, sucursal_id, rol, nombre)
    values (r.usuario_id, r.sucursal_id, 'motorizado', r.nombre)
    on conflict (usuario_id, sucursal_id) do update set nombre = excluded.nombre, activo = true
      where public.equipo.rol = 'motorizado';                      -- nunca degrada a un admin
  end if;
  update public.solicitudes_acceso
     set estado = case p_accion when 'aprobar' then 'aprobada' when 'rechazar' then 'rechazada' else 'cancelada' end,
         resuelto_en = now(), resuelto_por = auth.uid()
   where id = p_solicitud returning * into r;
  return r;
end $$;

-- El administrador le quita el acceso a un motorizado.
create function public.quitar_acceso(p_usuario uuid, p_sucursal uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.es_admin(p_sucursal) then raise exception 'Sin permiso'; end if;
  update public.equipo set activo = false
   where usuario_id = p_usuario and sucursal_id = p_sucursal and rol = 'motorizado';
  if not found then raise exception 'Ese motorizado no está activo'; end if;
  update public.solicitudes_acceso set estado = 'revocada', resuelto_en = now(), resuelto_por = auth.uid()
   where usuario_id = p_usuario and sucursal_id = p_sucursal and estado = 'aprobada';
  delete from public.suscripciones_push where usuario_id = p_usuario and app = 'equipo';
end $$;

revoke execute on function public.solicitar_acceso(text, text, text)   from public, anon;
revoke execute on function public.cancelar_mi_solicitud()              from public, anon;
revoke execute on function public.resolver_solicitud(uuid, text)       from public, anon;
revoke execute on function public.quitar_acceso(uuid, uuid)            from public, anon;
grant  execute on function public.solicitar_acceso(text, text, text)   to authenticated;
grant  execute on function public.cancelar_mi_solicitud()              to authenticated;
grant  execute on function public.resolver_solicitud(uuid, text)       to authenticated;
grant  execute on function public.quitar_acceso(uuid, uuid)            to authenticated;

-- El motorizado necesita saber al instante si lo aprobaron; el admin, si hay solicitudes.
alter publication supabase_realtime add table public.solicitudes_acceso, public.equipo;

-- Aviso push al administrador cuando llega una solicitud.
alter table public.push_pendientes drop constraint if exists push_pendientes_tipo_check;
alter table public.push_pendientes add constraint push_pendientes_tipo_check
  check (tipo in ('nuevo', 'estado', 'pago', 'entrega', 'version', 'solicitud'));
alter table public.push_pendientes add column if not exists solicitud_id uuid references public.solicitudes_acceso (id) on delete cascade;

create function public.solicitudes_encolar_push()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.push_pendientes (tipo, solicitud_id) values ('solicitud', new.id);
  perform public.disparar_envio_push();
  return null;
end $$;
create trigger solicitudes_push after insert on public.solicitudes_acceso
for each row execute function public.solicitudes_encolar_push();
revoke execute on function public.solicitudes_encolar_push() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Comprobante por correo: cola interna + Edge Function "enviar-comprobante"
-- ---------------------------------------------------------------------
create table public.correos_pendientes (
  id        bigint generated always as identity primary key,
  pedido_id uuid not null references public.pedidos (id) on delete cascade,
  creado_en timestamptz not null default now()
);
alter table public.correos_pendientes enable row level security;   -- sin políticas: la app no la ve
revoke all on public.correos_pendientes from anon, authenticated;
grant all on public.correos_pendientes to service_role;
grant usage, select on all sequences in schema public to service_role;

create function public.disparar_envio_correo()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url     := 'https://dgfdkcphklmeqlvyzmpu.supabase.co/functions/v1/enviar-comprobante',
    body    := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000
  );
exception when others then
  null;
end $$;

create function public.pedidos_encolar_correo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.correo is not null then
    insert into public.correos_pendientes (pedido_id) values (new.id);
    perform public.disparar_envio_correo();
  end if;
  return null;
end $$;
create trigger pedidos_correo after insert on public.pedidos
for each row execute function public.pedidos_encolar_correo();

create function public.tomar_correos_pendientes(p_max integer default 20)
returns setof public.correos_pendientes language sql security definer set search_path = '' as $$
  delete from public.correos_pendientes
  where id in (
    select id from public.correos_pendientes order by id
    for update skip locked
    limit greatest(1, least(coalesce(p_max, 20), 100))
  )
  returning *;
$$;

revoke execute on function public.disparar_envio_correo()           from public, anon, authenticated;
revoke execute on function public.pedidos_encolar_correo()          from public, anon, authenticated;
revoke execute on function public.tomar_correos_pendientes(integer) from public, anon, authenticated;
grant  execute on function public.tomar_correos_pendientes(integer) to service_role;

-- ---------------------------------------------------------------------
-- 4. Capacidad: índice para los pedidos activos del panel y del motorizado.
-- ---------------------------------------------------------------------
create index if not exists pedidos_activos on public.pedidos (sucursal_id, creado_en desc)
  where estado in ('recibido', 'preparando', 'en_camino');

commit;
