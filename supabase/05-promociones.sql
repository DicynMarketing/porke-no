-- =====================================================================
-- Porké No? · Paso 5: promociones editables desde el Admin
-- Correr una sola vez en SQL Editor › New query › Run (después del 04).
--
-- Dos tipos de promoción, ambas con días y botón "Activar":
--   precio: precio especial para un producto del inventario
--   combo : varios productos juntos a un precio (p. ej. Clásica + papas + soda a $6)
-- El servidor (crear-pedido) cobra estos precios solo los días elegidos.
-- =====================================================================

begin;

create table if not exists public.promociones (
  id              uuid primary key default gen_random_uuid(),
  sucursal_id     uuid not null references public.sucursales (id) on delete cascade,
  tipo            text not null check (tipo in ('precio', 'combo')),
  nombre          text not null check (length(trim(nombre)) between 1 and 80),
  descripcion     text not null default '' check (length(descripcion) <= 160),
  producto_codigo text,                                   -- tipo precio
  items           jsonb not null default '[]'::jsonb,     -- tipo combo: [{"codigo":"0-0","cantidad":1}]
  precio          numeric(8,2) not null check (precio >= 0 and precio <= 500),
  dias            smallint[] not null default '{}'        -- vacío = todos los días; 0 = domingo … 6 = sábado
                  check (dias <@ array[0,1,2,3,4,5,6]::smallint[]),
  activa          boolean not null default false,
  orden           integer not null default 0,
  creado_en       timestamptz not null default now(),
  actualizado_en  timestamptz not null default now(),
  check (tipo <> 'precio' or producto_codigo is not null),
  check (tipo <> 'combo' or (jsonb_typeof(items) = 'array' and jsonb_array_length(items) between 1 and 20))
);
create unique index if not exists promociones_precio_unica
  on public.promociones (sucursal_id, producto_codigo) where tipo = 'precio';
create index if not exists promociones_sucursal on public.promociones (sucursal_id, activa);

drop trigger if exists promociones_actualizado on public.promociones;
create trigger promociones_actualizado before update on public.promociones
for each row execute function public.tocar_actualizado();

alter table public.promociones enable row level security;
drop policy if exists "promociones: ver" on public.promociones;
drop policy if exists "promociones: admin crea" on public.promociones;
drop policy if exists "promociones: admin edita" on public.promociones;
drop policy if exists "promociones: admin borra" on public.promociones;
-- Todos pueden leerlas (el menú es público); así la app se entera al instante cuando se desactivan.
create policy "promociones: ver" on public.promociones
  for select to anon, authenticated using (true);
create policy "promociones: admin crea" on public.promociones
  for insert to authenticated with check (public.es_admin(sucursal_id));
create policy "promociones: admin edita" on public.promociones
  for update to authenticated using (public.es_admin(sucursal_id)) with check (public.es_admin(sucursal_id));
create policy "promociones: admin borra" on public.promociones
  for delete to authenticated using (public.es_admin(sucursal_id));
grant select on public.promociones to anon, authenticated;
grant insert, update, delete on public.promociones to authenticated;
grant all on public.promociones to service_role;

-- El administrador también cambia el precio normal de los productos (ya tenía permiso de editar productos).

do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'promociones') then
    alter publication supabase_realtime add table public.promociones;
  end if;
end $$;

-- Los combos de los miércoles pasan a ser promociones editables.
insert into public.promociones (sucursal_id, tipo, nombre, descripcion, items, precio, dias, activa, orden)
select s.id, 'combo', c.nombre, c.descripcion, c.items::jsonb, 5.00, array[3]::smallint[], true, c.orden
from public.sucursales s
cross join (values
  ('Clásica con papas',            'Hamburguesa Clásica con papas fritas.', '[{"codigo":"0-0","cantidad":1}]', 0),
  ('Cheese Burger con papas',      'Cheese Burger con papas fritas.',       '[{"codigo":"0-2","cantidad":1}]', 1),
  ('Burger con Cebolla con papas', 'Burger con Cebolla con papas fritas.',  '[{"codigo":"0-3","cantidad":1}]', 2)
) c(nombre, descripcion, items, orden)
where s.slug = 'aguadulce'
  and not exists (select 1 from public.promociones p where p.sucursal_id = s.id and p.tipo = 'combo' and p.nombre = c.nombre);

-- Los productos antiguos de combos (4-x) dejan de venderse; quedan solo para los pedidos viejos.
update public.productos set disponible = false where codigo like '4-%';

commit;
