-- =====================================================================
-- Porké No? · Paso 10: antes de abrir al público
-- Correr una sola vez en SQL Editor › New query › Run (después del 09).
--
--  · Motivo de cancelación (el cliente lo recibe)
--  · Cerrar el local un día completo (feriado)
--  · Usuario de cajero (acepta, cobra y cancela pedidos; no ve ventas ni cambia el menú)
--  · Propina para el motorizado
-- Para crear un cajero más adelante:
--   1. Authentication › Users › Add user (correo y contraseña del cajero)
--   2. SQL Editor: select public.agregar_equipo('correo@del.cajero', 'aguadulce', 'cajero', 'Nombre');
-- =====================================================================

alter type public.rol_equipo add value if not exists 'cajero';

begin;

-- ---------------------------------------------------------------------
-- Cajero: puede hacer todo lo de los pedidos. Lo demás sigue siendo solo del admin.
-- ---------------------------------------------------------------------
create or replace function public.es_caja(p_sucursal uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.es_admin(p_sucursal)
      or exists (select 1 from public.equipo e
                  where e.usuario_id = auth.uid() and e.sucursal_id = p_sucursal and e.activo
                    and e.rol::text = 'cajero');
$$;
grant execute on function public.es_caja(uuid) to authenticated;

drop policy if exists "pedidos: ver" on public.pedidos;
create policy "pedidos: ver" on public.pedidos
  for select to authenticated using (
    cliente_id = auth.uid()
    or public.es_caja(sucursal_id)
    or (motorizado_id = auth.uid() and public.es_equipo(sucursal_id, 'motorizado'))
  );

drop policy if exists "equipo: ver" on public.equipo;
create policy "equipo: ver" on public.equipo
  for select to authenticated using (usuario_id = auth.uid() or public.es_caja(sucursal_id));

drop policy if exists "comprobantes: ver propios o del local" on storage.objects;
create policy "comprobantes: ver propios o del local" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'comprobantes' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1 from public.pedidos p
        where p.comprobante_path = objects.name and public.es_caja(p.sucursal_id)
      )
    )
  );

-- Las acciones de pedidos ahora las puede hacer el admin o el cajero.
create or replace function public.equipo_aceptar_pago(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_caja(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado <> 'recibido' or r.estado_pago not in ('en_revision', 'rechazado') then
    raise exception 'Este pago ya fue revisado';
  end if;
  update public.pedidos set estado_pago = 'verificado' where id = p_pedido returning * into r;
  return r;
end $$;

create or replace function public.equipo_rechazar_pago(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_caja(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado <> 'recibido' or r.estado_pago not in ('en_revision', 'rechazado') then
    raise exception 'Este pago ya fue revisado';
  end if;
  update public.pedidos set estado_pago = 'rechazado' where id = p_pedido returning * into r;
  return r;
end $$;

create or replace function public.equipo_asignar_motorizado(p_pedido uuid, p_motorizado uuid default null)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
  nom text;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_caja(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.tipo <> 'delivery' or r.estado not in ('recibido', 'preparando') then
    raise exception 'Ya no se puede cambiar el repartidor';
  end if;
  if p_motorizado is not null then
    select e.nombre into nom from public.equipo e
     where e.usuario_id = p_motorizado and e.sucursal_id = r.sucursal_id
       and e.rol = 'motorizado' and e.activo;
    if nom is null then
      raise exception 'Ese repartidor no está activo en este local';
    end if;
  end if;
  update public.pedidos set motorizado_id = p_motorizado, motorizado_nombre = nom
   where id = p_pedido returning * into r;
  return r;
end $$;

create or replace function public.equipo_avanzar(p_pedido uuid, p_esperado public.estado_pedido)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r   public.pedidos;
  sig public.estado_pedido;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_caja(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado <> p_esperado then
    raise exception 'El pedido ya cambió de estado. Actualiza la pantalla.';
  end if;
  sig := case r.estado
           when 'recibido'   then 'preparando'
           when 'preparando' then 'en_camino'
           when 'en_camino'  then 'entregado'
         end;
  if sig is null then
    raise exception 'Este pedido ya no puede avanzar';
  end if;
  if r.estado = 'recibido' and r.estado_pago not in ('por_cobrar', 'verificado') then
    raise exception 'Primero verifica el pago';
  end if;
  if sig = 'en_camino' and r.tipo = 'delivery' and r.motorizado_id is null then
    raise exception 'Elige un repartidor';
  end if;
  if sig = 'entregado' and r.tipo = 'delivery' then
    raise exception 'La entrega la marca el repartidor';
  end if;
  update public.pedidos
     set estado = sig,
         estado_pago = case when sig = 'entregado' and estado_pago = 'por_cobrar'
                            then 'verificado'::public.estado_pago else estado_pago end
   where id = p_pedido returning * into r;
  return r;
end $$;

create or replace function public.equipo_cancelar(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_caja(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado not in ('recibido', 'preparando') then
    raise exception 'Este pedido ya no se puede cancelar';
  end if;
  update public.pedidos set estado = 'cancelado' where id = p_pedido returning * into r;
  return r;
end $$;

-- ---------------------------------------------------------------------
-- Motivo de cancelación
-- ---------------------------------------------------------------------
alter table public.pedidos add column if not exists motivo_cancelacion text
  check (motivo_cancelacion is null or length(motivo_cancelacion) <= 120);

create or replace function public.equipo_cancelar(p_pedido uuid, p_motivo text)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_caja(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado not in ('recibido', 'preparando') then
    raise exception 'Este pedido ya no se puede cancelar';
  end if;
  update public.pedidos
     set estado = 'cancelado', motivo_cancelacion = nullif(left(trim(coalesce(p_motivo, '')), 120), '')
   where id = p_pedido returning * into r;
  return r;
end $$;
revoke execute on function public.equipo_cancelar(uuid, text) from public, anon;
grant execute on function public.equipo_cancelar(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Cerrar el local días completos (feriados). Fechas en hora de Panamá.
-- ---------------------------------------------------------------------
alter table public.sucursales add column if not exists cierres date[] not null default '{}';
alter table public.sucursales add column if not exists cierre_msg text
  check (cierre_msg is null or length(cierre_msg) <= 120);

-- ---------------------------------------------------------------------
-- Propina para el motorizado (va completa al motorizado; no es venta del local)
-- ---------------------------------------------------------------------
alter table public.pedidos add column if not exists propina numeric(6,2) not null default 0
  check (propina >= 0 and propina <= 50);
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.pedidos'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%total = ((subtotal + envio) + servicio)%'
  loop
    execute format('alter table public.pedidos drop constraint %I', c);
  end loop;
end $$;
alter table public.pedidos drop constraint if exists pedidos_total_check;
alter table public.pedidos add constraint pedidos_total_check
  check (total = subtotal + envio + servicio + propina);

commit;
