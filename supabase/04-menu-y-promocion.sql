-- =====================================================================
-- Porké No? · Paso 4: bebidas nuevas y combos de los miércoles
-- Correr una sola vez en SQL Editor › New query › Run.
--
-- Los precios y los días de cada producto quedan aquí, en la tabla
-- productos (Table Editor). Para cambiar el precio del combo o el día de
-- la promoción basta con editar las columnas "precio" y "dias".
--   dias: 0 = domingo, 1 = lunes, 2 = martes, 3 = miércoles, 4 = jueves,
--         5 = viernes, 6 = sábado. Vacío (null) = todos los días.
-- =====================================================================

begin;

-- Días en que se vende un producto (promociones). null = todos los días.
alter table public.productos add column if not exists dias smallint[]
  check (dias is null or dias <@ array[0,1,2,3,4,5,6]::smallint[]);

-- El administrador puede activar 30 minutos de prueba de la promoción otro día.
alter table public.sucursales add column if not exists promo_prueba_hasta timestamptz;

-- Los clientes reciben al instante cuando el admin activa o termina la prueba.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sucursales') then
    alter publication supabase_realtime add table public.sucursales;
  end if;
end $$;

-- Sodas: solo estos sabores.
update public.productos
   set sabores = '{"Coca-Cola": true, "Coca-Cola Cero": true, "Fresa": true, "Ginger Ale": true}'::jsonb
 where codigo = '2-0';

-- Agua, jugos y té (los códigos coinciden con el menú de la app).
-- PRECIOS POR CONFIRMAR con la dueña: jugos y té quedan en $1.25.
insert into public.productos (sucursal_id, codigo, seccion, categoria, nombre, descripcion, precio, orden)
select s.id, p.codigo, 'comida_rapida', 'Bebidas', p.nombre, '', p.precio, p.orden
from public.sucursales s
cross join (values
  ('2-1', 'Agua',            1.00, 10),
  ('2-2', 'Jugo de naranja', 1.25, 11),
  ('2-3', 'Jugo del Valle',  1.25, 12),
  ('2-4', 'Té frío',         1.25, 13)
) p(codigo, nombre, precio, orden)
where s.slug = 'aguadulce'
on conflict (sucursal_id, codigo) do update
  set nombre = excluded.nombre, categoria = excluded.categoria, disponible = true;

-- Combos de los miércoles: hamburguesa con papas a $5.00 (solo los días en "dias").
insert into public.productos (sucursal_id, codigo, seccion, categoria, nombre, descripcion, precio, dias, orden)
select s.id, p.codigo, 'comida_rapida', 'Promo miércoles', p.nombre, p.descripcion, 5.00, array[3]::smallint[], p.orden
from public.sucursales s
cross join (values
  ('4-0', 'Clásica con papas',            'Hamburguesa Clásica con papas fritas.',  0),
  ('4-1', 'Cheese Burger con papas',      'Cheese Burger con papas fritas.',        1),
  ('4-2', 'Burger con Cebolla con papas', 'Burger con Cebolla con papas fritas.',   2)
) p(codigo, nombre, descripcion, orden)
where s.slug = 'aguadulce'
on conflict (sucursal_id, codigo) do update
  set nombre = excluded.nombre, descripcion = excluded.descripcion, categoria = excluded.categoria,
      precio = excluded.precio, dias = excluded.dias;

commit;
