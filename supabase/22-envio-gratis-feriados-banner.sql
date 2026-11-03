-- =====================================================================
-- Porké No? · Paso 22: envío gratis desde un monto, horario especial
-- para feriados y banners con imagen. Ya aplicado por Claude.
-- =====================================================================

-- Envío gratis: el admin lo enciende y elige desde qué monto (en productos).
alter table public.sucursales add column if not exists envio_gratis_activo boolean not null default false;
alter table public.sucursales add column if not exists envio_gratis_desde numeric(6,2) not null default 15
  check (envio_gratis_desde between 1 and 500);

-- Feriados con horario especial: {"2026-12-24": {"a": "10:00", "b": "16:00"}}.
-- (Los días cerrados completos siguen en sucursales.cierres.)
alter table public.sucursales add column if not exists horario_especial jsonb not null default '{}'::jsonb;
alter table public.sucursales drop constraint if exists sucursales_horario_especial_ok;
alter table public.sucursales add constraint sucursales_horario_especial_ok
  check (jsonb_typeof(horario_especial) = 'object' and length(horario_especial::text) <= 6000);

-- Banners con imagen (máx. 4): [{"url": "...", "titulo": "...", "texto": "...", "activo": true}].
alter table public.sucursales add column if not exists banners jsonb not null default '[]'::jsonb;
alter table public.sucursales add column if not exists banners_fijos boolean not null default true;
alter table public.sucursales drop constraint if exists sucursales_banners_ok;
alter table public.sucursales add constraint sucursales_banners_ok
  check (jsonb_typeof(banners) = 'array' and jsonb_array_length(banners) <= 4 and length(banners::text) <= 4000);
