-- =====================================================================
-- Porké No? · Paso 21: el aviso de entrega al motorizado se repite cada
-- 10 segundos (antes 30) hasta que toque "Sí, ya lo vi", durante máx. 20 min.
-- Ya aplicado por Claude. Correr solo si se reconstruye la base de datos.
-- =====================================================================

create or replace function public.repetir_aviso_entrega()
returns void language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  insert into public.push_pendientes (tipo, pedido_id, datos)
  select 'entrega', p.id, jsonb_build_object('repite', true)
    from public.pedidos p
   where p.estado = 'en_camino' and p.motorizado_id is not null and p.entrega_vista_en is null
     and p.en_camino_desde between now() - interval '20 minutes' and now() - interval '8 seconds';
  get diagnostics n = row_count;
  if n > 0 then
    perform public.disparar_envio_push();
  end if;
end $$;
revoke execute on function public.repetir_aviso_entrega() from public, anon, authenticated;

select cron.unschedule('repetir-aviso-entrega') where exists (select 1 from cron.job where jobname = 'repetir-aviso-entrega');
select cron.schedule('repetir-aviso-entrega', '10 seconds', 'select public.repetir_aviso_entrega()');
