-- =====================================================================
-- Porké No? · Paso 7: un solo jugo de naranja (marca Del Valle)
-- Correr una sola vez en SQL Editor › New query › Run.
-- "Jugo de naranja" y "Jugo del Valle" eran el mismo producto.
-- =====================================================================

begin;

update public.productos set nombre = 'Jugo de naranja Del Valle' where codigo = '2-2';

-- El duplicado deja de existir (los pedidos viejos guardan su propia copia del nombre).
delete from public.promociones where tipo = 'precio' and producto_codigo = '2-3';
delete from public.productos where codigo = '2-3';

commit;
