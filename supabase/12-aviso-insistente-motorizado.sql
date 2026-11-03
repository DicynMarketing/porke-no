-- =====================================================================
-- Porké No? · Paso 12: aviso insistente al motorizado
-- Correr una sola vez en SQL Editor › New query › Run (después del 11).
--
-- Cuando el local envía un pedido con un motorizado, su teléfono suena de
-- nuevo cada 30 segundos (hasta 10 minutos) hasta que él toque "Ya lo vi"
-- en la app. Usa pg_cron (incluido gratis en Supabase).
-- =====================================================================

create extension if not exists pg_cron;

begin;

alter table public.pedidos add column if not exists en_camino_desde timestamptz;
alter table public.pedidos add column if not exists entrega_vista_en timestamptz;

-- Marca la hora en que el pedido sale a entregar (y reinicia el "visto" si cambia el motorizado).
create or replace function public.pedidos_marcar_en_camino()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.estado = 'en_camino' and (tg_op = 'INSERT' or old.estado is distinct from 'en_camino'
                                   or old.motorizado_id is distinct from new.motorizado_id) then
    new.en_camino_desde := now();
    new.entrega_vista_en := null;
  end if;
  return new;
end $$;
drop trigger if exists pedidos_marcar_en_camino on public.pedidos;
create trigger pedidos_marcar_en_camino before insert or update on public.pedidos
  for each row execute function public.pedidos_marcar_en_camino();

-- El motorizado confirma que vio la entrega: deja de sonar.
create or replace function public.motorizado_vi_entrega(p_pedido uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.pedidos set entrega_vista_en = now()
   where id = p_pedido and motorizado_id = auth.uid() and entrega_vista_en is null;
end $$;
revoke execute on function public.motorizado_vi_entrega(uuid) from public, anon;
grant execute on function public.motorizado_vi_entrega(uuid) to authenticated;

-- Cada 30 s: vuelve a avisar las entregas que el motorizado todavía no ha visto.
create or replace function public.repetir_aviso_entrega()
returns void language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  insert into public.push_pendientes (tipo, pedido_id, datos)
  select 'entrega', p.id, jsonb_build_object('repite', true)
    from public.pedidos p
   where p.estado = 'en_camino' and p.motorizado_id is not null and p.entrega_vista_en is null
     and p.en_camino_desde between now() - interval '10 minutes' and now() - interval '25 seconds';
  get diagnostics n = row_count;
  if n > 0 then
    perform public.disparar_envio_push();
  end if;
end $$;
revoke execute on function public.repetir_aviso_entrega() from public, anon, authenticated;

commit;

select cron.unschedule('repetir-aviso-entrega') where exists (select 1 from cron.job where jobname = 'repetir-aviso-entrega');
select cron.schedule('repetir-aviso-entrega', '30 seconds', 'select public.repetir_aviso_entrega()');
