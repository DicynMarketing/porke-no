-- =====================================================================
-- Porké No? · Paso 11: la pantalla de cocina entra como el motorizado
-- Correr una sola vez en SQL Editor › New query › Run (después del 10).
--
-- La tablet de la cocina pide acceso (sin correo ni contraseña) y el
-- administrador la aprueba desde su tablet. La cocina puede aceptar y
-- avanzar pedidos; no ve ventas ni cambia el menú.
-- =====================================================================

alter type public.rol_equipo add value if not exists 'cocina';

begin;

alter table public.solicitudes_acceso add column if not exists rol text not null default 'motorizado';
alter table public.solicitudes_acceso drop constraint if exists solicitudes_acceso_rol_check;
alter table public.solicitudes_acceso add constraint solicitudes_acceso_rol_check check (rol in ('motorizado', 'cocina'));

-- Pedir acceso indicando si es motorizado o pantalla de cocina.
create or replace function public.solicitar_acceso(p_sucursal text, p_nombre text, p_dispositivo text, p_rol text)
returns public.solicitudes_acceso language plpgsql security definer set search_path = '' as $$
declare
  s uuid;
  r public.solicitudes_acceso;
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  if p_rol not in ('motorizado', 'cocina') then raise exception 'Rol inválido'; end if;
  select id into s from public.sucursales where slug = p_sucursal and activa;
  if s is null then raise exception 'Local no encontrado'; end if;
  if exists (select 1 from public.equipo where usuario_id = auth.uid() and sucursal_id = s and activo) then
    raise exception 'Este teléfono ya tiene acceso';
  end if;
  update public.solicitudes_acceso set estado = 'cancelada', resuelto_en = now()
   where usuario_id = auth.uid() and sucursal_id = s and estado = 'pendiente';
  insert into public.solicitudes_acceso (sucursal_id, usuario_id, nombre, dispositivo, rol)
  values (s, auth.uid(), trim(p_nombre), left(p_dispositivo, 80), p_rol)
  returning * into r;
  return r;
end $$;
revoke execute on function public.solicitar_acceso(text, text, text, text) from public, anon;
grant execute on function public.solicitar_acceso(text, text, text, text) to authenticated;

-- Aprobar: le da al dispositivo el rol que pidió (nunca cambia a un admin o cajero).
create or replace function public.resolver_solicitud(p_solicitud uuid, p_accion text)
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
    values (r.usuario_id, r.sucursal_id, r.rol::public.rol_equipo, r.nombre)
    on conflict (usuario_id, sucursal_id) do update set nombre = excluded.nombre, rol = excluded.rol, activo = true
      where public.equipo.rol::text in ('motorizado', 'cocina');
  end if;
  update public.solicitudes_acceso
     set estado = case p_accion when 'aprobar' then 'aprobada' when 'rechazar' then 'rechazada' else 'cancelada' end,
         resuelto_en = now(), resuelto_por = auth.uid()
   where id = p_solicitud returning * into r;
  return r;
end $$;

-- Quitar el acceso a un motorizado o a una pantalla de cocina.
create or replace function public.quitar_acceso(p_usuario uuid, p_sucursal uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.es_admin(p_sucursal) then raise exception 'Sin permiso'; end if;
  update public.equipo set activo = false
   where usuario_id = p_usuario and sucursal_id = p_sucursal and rol::text in ('motorizado', 'cocina');
  if not found then raise exception 'Ese dispositivo no está activo'; end if;
  update public.solicitudes_acceso set estado = 'revocada', resuelto_en = now(), resuelto_por = auth.uid()
   where usuario_id = p_usuario and sucursal_id = p_sucursal and estado = 'aprobada';
  delete from public.suscripciones_push where usuario_id = p_usuario and app = 'equipo';
end $$;

-- La cocina maneja pedidos igual que el cajero.
create or replace function public.es_caja(p_sucursal uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.es_admin(p_sucursal)
      or exists (select 1 from public.equipo e
                  where e.usuario_id = auth.uid() and e.sucursal_id = p_sucursal and e.activo
                    and e.rol::text in ('cajero', 'cocina'));
$$;

commit;
