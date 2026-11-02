-- =====================================================================
-- Porké No? · Paso 15: refuerzo de seguridad
-- Correr una sola vez en SQL Editor › New query › Run (después del 14).
--
--  1. El cliente solo puede cambiar su nombre, teléfono y avisos (no campos
--     internos como "teléfono verificado" o el correo).
--  2. Las personas sin sesión no ven el identificador del dueño.
--  3. Pedir acceso como motorizado/cocina tiene límite (evita llenar el panel
--     de solicitudes falsas) y el nombre se limita a 40 letras.
--  4. Funciones viejas o internas ya no se pueden llamar desde la app.
-- =====================================================================

begin;

-- 1. Columnas que el cliente puede escribir en su propio perfil.
revoke insert, update on public.clientes from authenticated;
grant insert (id, nombre, celular, telefono, notif_pedidos, notif_promos, terminos_aceptados_en) on public.clientes to authenticated;
grant update (id, nombre, celular, telefono, notif_pedidos, notif_promos, terminos_aceptados_en) on public.clientes to authenticated;

-- 2. Restaurantes: lo público, sin el identificador del dueño.
revoke select on public.restaurantes from anon;
grant select (id, nombre, slug, logo_url, plan, activo, creado_en, actualizado_en) on public.restaurantes to anon;

-- 3. Solicitudes de acceso con límite.
create or replace function public.solicitar_acceso(p_sucursal text, p_nombre text, p_dispositivo text, p_rol text)
returns public.solicitudes_acceso language plpgsql security definer set search_path = '' as $$
declare
  s uuid;
  r public.solicitudes_acceso;
  n text := left(trim(coalesce(p_nombre, '')), 40);
begin
  if auth.uid() is null then raise exception 'Sin sesión'; end if;
  if p_rol not in ('motorizado', 'cocina') then raise exception 'Rol inválido'; end if;
  if length(n) < 2 then raise exception 'Escribe tu nombre'; end if;
  select id into s from public.sucursales where slug = p_sucursal and activa;
  if s is null then raise exception 'Local no encontrado'; end if;
  if exists (select 1 from public.equipo where usuario_id = auth.uid() and sucursal_id = s and activo) then
    raise exception 'Este teléfono ya tiene acceso';
  end if;
  if (select count(*) from public.solicitudes_acceso
       where sucursal_id = s and estado = 'pendiente' and creado_en > now() - interval '30 minutes') >= 5 then
    raise exception 'Hay muchas solicitudes pendientes. Pídele al administrador que las revise e intenta en unos minutos';
  end if;
  update public.solicitudes_acceso set estado = 'cancelada', resuelto_en = now()
   where usuario_id = auth.uid() and sucursal_id = s and estado = 'pendiente';
  insert into public.solicitudes_acceso (sucursal_id, usuario_id, nombre, dispositivo, rol)
  values (s, auth.uid(), n, left(p_dispositivo, 80), p_rol)
  returning * into r;
  return r;
end $$;

-- 4. Versiones viejas (ya no las usa la app) y funciones internas.
revoke execute on function public.solicitar_acceso(text, text, text) from public, anon, authenticated;
revoke execute on function public.equipo_cancelar(uuid) from public, anon, authenticated;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

commit;
