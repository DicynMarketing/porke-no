-- =====================================================================
-- Porké No? · Paso 8: tarjeta de sellos y delivery mínimo de $2.00
-- Correr una sola vez en SQL Editor › New query › Run.
--
-- Cada pedido hecho en la app y ENTREGADO suma un sello (si sus productos
-- suman al menos "sellos_minimo"). Al juntar "sellos_meta" sellos el
-- cliente recibe un cupón: una hamburguesa gratis en su próximo pedido.
-- Todo lo calcula la base de datos; el teléfono solo lo muestra.
-- Para cambiar las reglas: Table Editor › sucursales › columnas
--   sellos_meta   (cuántas compras; hoy 6)
--   sellos_minimo (compra mínima en productos para contar; hoy $3.00)
-- =====================================================================

begin;

-- Delivery mínimo: $2.00 (centro de Aguadulce y Pocrí).
update public.sucursales set tarifa_entrega = 2.00 where slug = 'aguadulce';

alter table public.sucursales add column if not exists sellos_meta smallint not null default 6
  check (sellos_meta between 2 and 20);
alter table public.sucursales add column if not exists sellos_minimo numeric(8,2) not null default 3.00
  check (sellos_minimo >= 0);

create table if not exists public.cupones (
  id          uuid primary key default gen_random_uuid(),
  cliente_id  uuid not null references auth.users (id) on delete cascade,
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  tipo        text not null default 'hamburguesa' check (tipo in ('hamburguesa')),
  estado      text not null default 'disponible' check (estado in ('disponible', 'usado')),
  pedido_id   uuid references public.pedidos (id) on delete set null,
  creado_en   timestamptz not null default now(),
  usado_en    timestamptz
);
create index if not exists cupones_cliente on public.cupones (cliente_id, sucursal_id, estado);

create table if not exists public.sellos (
  id          bigint generated always as identity primary key,
  cliente_id  uuid not null references auth.users (id) on delete cascade,
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  pedido_id   uuid not null unique references public.pedidos (id) on delete cascade,
  cupon_id    uuid references public.cupones (id) on delete set null,
  creado_en   timestamptz not null default now()
);
create index if not exists sellos_cliente on public.sellos (cliente_id, sucursal_id) where cupon_id is null;

-- Solo se pueden ver; nadie los crea ni los cambia desde el teléfono.
alter table public.cupones enable row level security;
alter table public.sellos  enable row level security;
drop policy if exists "cupones: ver propios o del local" on public.cupones;
drop policy if exists "sellos: ver propios o del local"  on public.sellos;
create policy "cupones: ver propios o del local" on public.cupones
  for select to authenticated using (cliente_id = auth.uid() or public.es_admin(sucursal_id));
create policy "sellos: ver propios o del local" on public.sellos
  for select to authenticated using (cliente_id = auth.uid() or public.es_admin(sucursal_id));
grant select on public.cupones, public.sellos to authenticated;
grant all on public.cupones, public.sellos to service_role;

-- Al entregar un pedido: un sello; al completar la tarjeta: un cupón.
-- Al cancelar un pedido que usaba un cupón: el cupón vuelve a estar disponible.
create or replace function public.pedidos_sellos()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  s public.sucursales;
  n integer;
  c uuid;
begin
  if new.estado = 'cancelado' and old.estado <> 'cancelado' then
    update public.cupones set estado = 'disponible', pedido_id = null, usado_en = null
     where pedido_id = new.id and estado = 'usado';
    return new;
  end if;
  if new.estado <> 'entregado' or old.estado = 'entregado' or new.cliente_id is null then
    return new;
  end if;
  select * into s from public.sucursales where id = new.sucursal_id;
  if new.subtotal < s.sellos_minimo then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext(new.cliente_id::text)); -- dos entregas a la vez no dan dos cupones
  insert into public.sellos (cliente_id, sucursal_id, pedido_id)
  values (new.cliente_id, new.sucursal_id, new.id)
  on conflict (pedido_id) do nothing;
  select count(*) into n from public.sellos
   where cliente_id = new.cliente_id and sucursal_id = new.sucursal_id and cupon_id is null;
  if n >= s.sellos_meta then
    insert into public.cupones (cliente_id, sucursal_id) values (new.cliente_id, new.sucursal_id)
    returning id into c;
    update public.sellos set cupon_id = c
     where id in (select id from public.sellos
                   where cliente_id = new.cliente_id and sucursal_id = new.sucursal_id and cupon_id is null
                   order by id limit s.sellos_meta);
  end if;
  return new;
end $$;
revoke execute on function public.pedidos_sellos() from public, anon, authenticated;

drop trigger if exists pedidos_sellos on public.pedidos;
create trigger pedidos_sellos after update of estado on public.pedidos
for each row execute function public.pedidos_sellos();

-- La app se entera al instante de cada sello y cupón nuevo.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sellos') then
    alter publication supabase_realtime add table public.sellos;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'cupones') then
    alter publication supabase_realtime add table public.cupones;
  end if;
end $$;

commit;
