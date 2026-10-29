-- =====================================================================
-- Porké No? · Paso 13: el motorizado registra el cobro en efectivo
-- Correr una sola vez en SQL Editor › New query › Run (después del 12).
--
-- Si el cliente paga en efectivo, el motorizado primero toca "Cobré $X"
-- y solo después puede marcar el pedido como entregado. Con Yappy o
-- transferencia el pago ya está verificado y entrega directo.
-- =====================================================================

begin;

-- Registrar que cobró el efectivo (queda como pago verificado).
create or replace function public.motorizado_cobrar(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  update public.pedidos set estado_pago = 'verificado'
   where id = p_pedido and motorizado_id = auth.uid() and estado = 'en_camino'
     and estado_pago = 'por_cobrar' and public.es_equipo(sucursal_id, 'motorizado')
  returning * into r;
  if not found then
    select * into r from public.pedidos where id = p_pedido and motorizado_id = auth.uid();
    if not found then raise exception 'Este pedido no está en camino contigo'; end if;
  end if;
  return r;
end $$;
revoke execute on function public.motorizado_cobrar(uuid) from public, anon;
grant execute on function public.motorizado_cobrar(uuid) to authenticated;

-- Entregar: si es en efectivo, primero hay que registrar el cobro.
create or replace function public.motorizado_entregar(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido and motorizado_id = auth.uid() and estado = 'en_camino';
  if not found or not public.es_equipo(r.sucursal_id, 'motorizado') then
    raise exception 'Este pedido no está en camino contigo';
  end if;
  if r.estado_pago = 'por_cobrar' then
    raise exception 'Primero registra el cobro de $% en efectivo', to_char(r.total, 'FM999990.00');
  end if;
  update public.pedidos set estado = 'entregado' where id = p_pedido returning * into r;
  return r;
end $$;

commit;
