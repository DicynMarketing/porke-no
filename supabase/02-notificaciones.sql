-- =====================================================================
-- Porké No? · Paso 2: notificaciones push (Web Push con VAPID)
-- ---------------------------------------------------------------------
-- Correr DESPUÉS de schema.sql, una sola vez, en SQL Editor › New query › Run.
--
-- Cómo funciona:
--   1. Cada teléfono que activa los avisos guarda su "suscripción" en
--      suscripciones_push (solo la ve y la borra su dueño).
--   2. Cuando entra un pedido o cambia de estado, un trigger anota el aviso
--      en push_pendientes (tabla interna, nadie de la app la puede tocar)
--      y despierta la Edge Function "enviar-push".
--   3. enviar-push lee los avisos pendientes, decide a quién van y los
--      envía. Las suscripciones muertas (teléfono desinstalado) se borran.
-- =====================================================================

begin;

-- pg_net permite que la base de datos llame a la Edge Function.
create extension if not exists pg_net;

-- La tabla "dispositivos" del primer esquema nunca se usó: la reemplaza esta.
drop table if exists public.dispositivos;

-- ---------------------------------------------------------------------
-- Suscripciones de cada teléfono
-- ---------------------------------------------------------------------
create table public.suscripciones_push (
  id          uuid primary key default gen_random_uuid(),
  usuario_id  uuid not null references auth.users (id) on delete cascade,
  endpoint    text not null check (endpoint ~ '^https://'),
  p256dh      text not null,
  auth        text not null,
  app         text not null default 'cliente' check (app in ('cliente', 'equipo')),
  dispositivo text,
  creado_en   timestamptz not null default now(),
  ultimo_uso  timestamptz not null default now(),
  unique (usuario_id, endpoint)
);
create index suscripciones_push_usuario on public.suscripciones_push (usuario_id);

alter table public.suscripciones_push enable row level security;
create policy "suscripciones: ver propias" on public.suscripciones_push
  for select to authenticated using (usuario_id = auth.uid());
create policy "suscripciones: crear propias" on public.suscripciones_push
  for insert to authenticated with check (usuario_id = auth.uid());
create policy "suscripciones: editar propias" on public.suscripciones_push
  for update to authenticated using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());
create policy "suscripciones: borrar propias" on public.suscripciones_push
  for delete to authenticated using (usuario_id = auth.uid());
grant select, insert, update, delete on public.suscripciones_push to authenticated;
grant all on public.suscripciones_push to service_role;

-- ---------------------------------------------------------------------
-- Cola interna de avisos por enviar
-- ---------------------------------------------------------------------
create table public.push_pendientes (
  id        bigint generated always as identity primary key,
  tipo      text not null check (tipo in ('nuevo', 'estado', 'pago', 'entrega', 'version')),
  pedido_id uuid references public.pedidos (id) on delete cascade,
  datos     jsonb not null default '{}'::jsonb,
  creado_en timestamptz not null default now()
);
alter table public.push_pendientes enable row level security;   -- sin políticas: la app no la ve
revoke all on public.push_pendientes from anon, authenticated;
grant all on public.push_pendientes to service_role;
grant usage, select on all sequences in schema public to service_role;

-- Despierta a la Edge Function. Si falla, el pedido se guarda igual.
create function public.disparar_envio_push()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url     := 'https://dgfdkcphklmeqlvyzmpu.supabase.co/functions/v1/enviar-push',
    body    := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000
  );
exception when others then
  null;
end $$;

-- Qué avisos genera cada cambio de un pedido.
create function public.pedidos_encolar_push()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  hay boolean := false;
begin
  if tg_op = 'INSERT' then
    -- Pedido nuevo: administradores y motorizados del local.
    insert into public.push_pendientes (tipo, pedido_id) values ('nuevo', new.id);
    hay := true;
  else
    -- Cambio de estado: el cliente del pedido.
    if new.estado is distinct from old.estado
       and new.estado in ('preparando', 'en_camino', 'entregado', 'cancelado') then
      insert into public.push_pendientes (tipo, pedido_id, datos)
      values ('estado', new.id, jsonb_build_object('estado', new.estado));
      hay := true;
    end if;
    -- El local revisó el pago: el cliente del pedido.
    if new.estado_pago is distinct from old.estado_pago
       and new.estado = 'recibido'
       and new.estado_pago in ('verificado', 'rechazado') then
      insert into public.push_pendientes (tipo, pedido_id, datos)
      values ('pago', new.id, jsonb_build_object('estado_pago', new.estado_pago));
      hay := true;
    end if;
    -- Sale a entregar: el motorizado asignado.
    if new.estado = 'en_camino' and old.estado <> 'en_camino' and new.motorizado_id is not null then
      insert into public.push_pendientes (tipo, pedido_id) values ('entrega', new.id);
      hay := true;
    end if;
  end if;
  if hay then
    perform public.disparar_envio_push();
  end if;
  return null;
end $$;

create trigger pedidos_push after insert or update on public.pedidos
for each row execute function public.pedidos_encolar_push();

-- La Edge Function toma los avisos de la cola (y los borra) de forma segura
-- aunque corran dos copias a la vez.
create function public.tomar_push_pendientes(p_max integer default 50)
returns setof public.push_pendientes language sql security definer set search_path = '' as $$
  delete from public.push_pendientes
  where id in (
    select id from public.push_pendientes
    order by id
    for update skip locked
    limit greatest(1, least(coalesce(p_max, 50), 200))
  )
  returning *;
$$;

-- Solo desde el SQL Editor: avisa a todos los teléfonos que hay versión nueva.
--   select public.avisar_nueva_version('0.9.1', 'Pantalla de rol y notificaciones');
create function public.avisar_nueva_version(p_version text, p_notas text default '')
returns text language plpgsql security definer set search_path = '' as $$
begin
  insert into public.push_pendientes (tipo, datos)
  values ('version', jsonb_build_object('v', p_version, 'notas', coalesce(p_notas, '')));
  perform public.disparar_envio_push();
  return 'Aviso de la versión ' || p_version || ' enviado a la cola';
end $$;

revoke execute on function public.disparar_envio_push()                 from public, anon, authenticated;
revoke execute on function public.pedidos_encolar_push()                from public, anon, authenticated;
revoke execute on function public.tomar_push_pendientes(integer)        from public, anon, authenticated;
revoke execute on function public.avisar_nueva_version(text, text)      from public, anon, authenticated;
grant  execute on function public.tomar_push_pendientes(integer)        to service_role;

commit;
