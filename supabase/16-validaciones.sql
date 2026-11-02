-- =====================================================================
-- Porké No? · Paso 16: validaciones en el servidor
-- Correr una sola vez en SQL Editor › New query › Run (después del 15).
--
-- Lo que el cliente guarda directamente (perfil, direcciones, avisos) se
-- revisa en la base de datos: largos máximos, coordenadas válidas, avisos
-- solo hacia los servicios oficiales (Google, Mozilla, Apple, Microsoft) y
-- un tope de registros por persona para que nadie llene la base de datos.
-- =====================================================================

begin;

-- Perfil del cliente.
alter table public.clientes drop constraint if exists clientes_largos;
alter table public.clientes add constraint clientes_largos check (
  length(coalesce(nombre, '')) <= 80 and length(coalesce(celular, '')) <= 20
  and length(coalesce(telefono, '')) <= 20 and length(coalesce(correo, '')) <= 254);

-- Direcciones guardadas: largos, coordenadas y máximo 10 por cliente.
alter table public.direcciones drop constraint if exists direcciones_validas;
alter table public.direcciones add constraint direcciones_validas check (
  length(coalesce(nombre, '')) <= 40 and length(coalesce(referencia, '')) <= 200
  and (lat is null or lat between -90 and 90) and (lng is null or lng between -180 and 180));

create or replace function public.direcciones_tope()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (select count(*) from public.direcciones where cliente_id = new.cliente_id) >= 10 then
    raise exception 'Puedes guardar hasta 10 direcciones';
  end if;
  return new;
end $$;
drop trigger if exists direcciones_tope on public.direcciones;
create trigger direcciones_tope before insert on public.direcciones
  for each row execute function public.direcciones_tope();

-- Avisos al teléfono: solo direcciones de los servicios oficiales de notificaciones.
alter table public.suscripciones_push drop constraint if exists suscripciones_validas;
alter table public.suscripciones_push add constraint suscripciones_validas check (
  endpoint ~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/'
  and length(endpoint) <= 600 and length(p256dh) <= 200 and length(auth) <= 100
  and app in ('cliente', 'equipo') and length(coalesce(dispositivo, '')) <= 80);

-- Máximo 8 teléfonos por persona y app: al pasar el tope se borra el más viejo.
create or replace function public.suscripciones_tope()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.suscripciones_push
   where id in (select id from public.suscripciones_push
                 where usuario_id = new.usuario_id and app = new.app
                 order by coalesce(ultimo_uso, creado_en) desc offset 8);
  return null;
end $$;
drop trigger if exists suscripciones_tope on public.suscripciones_push;
create trigger suscripciones_tope after insert on public.suscripciones_push
  for each row execute function public.suscripciones_tope();

revoke execute on function public.direcciones_tope() from public, anon, authenticated;
revoke execute on function public.suscripciones_tope() from public, anon, authenticated;

commit;
