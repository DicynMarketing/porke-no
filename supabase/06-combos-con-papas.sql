-- =====================================================================
-- Porké No? · Paso 6: los combos "con papas" llevan las papas fritas
-- incluidas como parte del combo (para que la cocina las vea en el pedido).
-- Correr una sola vez en SQL Editor › New query › Run. Se puede repetir.
-- =====================================================================
update public.promociones
   set items = items || '[{"codigo":"papas","cantidad":1}]'::jsonb
 where tipo = 'combo'
   and nombre ilike '%con papas%'
   and not items @> '[{"codigo":"papas"}]'::jsonb;
