-- =====================================================================
-- Porké No? · Paso 14: 30 segundos para que el cliente cancele
-- Correr una sola vez en SQL Editor › New query › Run (después del 13).
--
-- Al enviar un pedido, queda 30 s en espera: el cliente puede cancelarlo
-- y el local todavía no lo ve ni recibe el aviso. Pasado ese tiempo (lo
-- revisa pg_cron cada 5 s) el pedido llega a la cocina y ya no se puede
-- cancelar desde la app del cliente.
-- =====================================================================

begin;

alter table public.pedidos add column if not exists retener_hasta timestamptz;

-- Aviso al local y correo: solo cuando el pedido ya no está en espera.
create or replace function public.pedidos_encolar_push()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  hay boolean := false;
begin
  if tg_op = 'INSERT' then
    -- Pedido nuevo: administradores (si está en espera, lo avisa liberar_pedidos_retenidos).
    if new.retener_hasta is null or new.retener_hasta <= now() then
      insert into public.push_pendientes (tipo, pedido_id) values ('nuevo', new.id);
      hay := true;
    end if;
  else
    -- Cambio de estado: el cliente del pedido (no si él mismo lo canceló).
    if new.estado is distinct from old.estado
       and new.estado in ('preparando', 'en_camino', 'entregado', 'cancelado')
       and not (new.estado = 'cancelado' and new.motivo_cancelacion = 'Cancelado por el cliente') then
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

create or replace function public.pedidos_encolar_correo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.correo is not null and (new.retener_hasta is null or new.retener_hasta <= now()) then
    insert into public.correos_pendientes (pedido_id) values (new.id);
    perform public.disparar_envio_correo();
  end if;
  return null;
end $$;

-- El cliente cancela su pedido mientras está en los 30 s de espera.
create or replace function public.cliente_cancelar(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido and cliente_id = auth.uid() for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  if r.estado <> 'recibido' or r.retener_hasta is null or r.retener_hasta < now() - interval '3 seconds' then
    raise exception 'Tu pedido ya fue confirmado y está en la cocina. Si necesitas algo, escríbenos por WhatsApp';
  end if;
  update public.pedidos
     set estado = 'cancelado', motivo_cancelacion = 'Cancelado por el cliente', retener_hasta = null
   where id = p_pedido returning * into r;   -- el cupón vuelve solo (trigger pedidos_sellos)
  return r;
end $$;
revoke execute on function public.cliente_cancelar(uuid) from public, anon;
grant execute on function public.cliente_cancelar(uuid) to authenticated;

-- Cada 5 s: los pedidos que ya pasaron sus 30 s llegan al local.
create or replace function public.liberar_pedidos_retenidos()
returns void language plpgsql security definer set search_path = '' as $$
declare
  ids uuid[];
begin
  with l as (
    update public.pedidos set retener_hasta = null
     where retener_hasta is not null and retener_hasta <= now() and estado = 'recibido'
    returning id, correo)
  select array_agg(id) into ids from l;
  if ids is null then
    -- Pedidos cancelados o avanzados que quedaron marcados: solo limpiar.
    update public.pedidos set retener_hasta = null where retener_hasta is not null and retener_hasta <= now();
    return;
  end if;
  insert into public.push_pendientes (tipo, pedido_id) select 'nuevo', unnest(ids);
  insert into public.correos_pendientes (pedido_id)
    select id from public.pedidos where id = any(ids) and correo is not null;
  perform public.disparar_envio_push();
  perform public.disparar_envio_correo();
end $$;
revoke execute on function public.liberar_pedidos_retenidos() from public, anon, authenticated;

commit;

select cron.unschedule('liberar-pedidos') where exists (select 1 from cron.job where jobname = 'liberar-pedidos');
select cron.schedule('liberar-pedidos', '5 seconds', 'select public.liberar_pedidos_retenidos()');
