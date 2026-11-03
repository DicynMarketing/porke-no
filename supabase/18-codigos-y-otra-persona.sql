-- =====================================================================
-- Porké No? · Paso 18: códigos de descuento y "pedir para otra persona"
-- Correr una sola vez en SQL Editor › New query › Run (después del 17).
-- =====================================================================

begin;

-- Quién recibe el pedido (si es para otra persona) y descuento por código.
alter table public.pedidos add column if not exists recibe_nombre text
  check (recibe_nombre is null or length(recibe_nombre) <= 60);
alter table public.pedidos add column if not exists recibe_telefono text
  check (recibe_telefono is null or length(recibe_telefono) <= 20);
alter table public.pedidos add column if not exists descuento numeric(6,2) not null default 0 check (descuento >= 0);
alter table public.pedidos add column if not exists codigo text check (codigo is null or length(codigo) <= 20);

-- Códigos que crea el admin (ej. PORKE10).
create table if not exists public.codigos_descuento (
  id          bigint generated always as identity primary key,
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  codigo      text not null check (codigo ~ '^[A-Z0-9]{3,20}$'),
  tipo        text not null check (tipo in ('porcentaje', 'monto')),
  valor       numeric(6,2) not null check (valor > 0),
  minimo      numeric(6,2) not null default 0 check (minimo >= 0),
  usos_max    integer check (usos_max is null or usos_max > 0),
  usos        integer not null default 0,
  por_cliente smallint not null default 1 check (por_cliente between 1 and 50),
  vence_en    timestamptz,
  activo      boolean not null default true,
  creado_en   timestamptz not null default now(),
  unique (sucursal_id, codigo),
  check (tipo = 'monto' or valor <= 100)
);
alter table public.codigos_descuento enable row level security;
drop policy if exists "codigos: admin" on public.codigos_descuento;
create policy "codigos: admin" on public.codigos_descuento for all to authenticated
  using (public.es_admin(sucursal_id)) with check (public.es_admin(sucursal_id));
grant select, insert, update, delete on public.codigos_descuento to authenticated;
grant all on public.codigos_descuento to service_role;

create table if not exists public.codigo_usos (
  id         bigint generated always as identity primary key,
  codigo_id  bigint not null references public.codigos_descuento (id) on delete cascade,
  cliente_id uuid references auth.users (id) on delete set null,
  pedido_id  uuid references public.pedidos (id) on delete cascade,
  creado_en  timestamptz not null default now()
);
create index if not exists codigo_usos_cli on public.codigo_usos (codigo_id, cliente_id);
alter table public.codigo_usos enable row level security;   -- solo el servidor
grant all on public.codigo_usos to service_role;

-- Calcula el descuento de un código para este cliente (lo usan la app y crear-pedido).
create or replace function public.revisar_codigo(p_sucursal uuid, p_codigo text, p_subtotal numeric, p_cliente uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  c public.codigos_descuento;
  quien uuid := coalesce(auth.uid(), p_cliente);   -- desde la app siempre es la persona con sesión
  usados integer;
  d numeric;
begin
  select * into c from public.codigos_descuento
   where sucursal_id = p_sucursal and codigo = upper(trim(coalesce(p_codigo, '')));
  if not found or not c.activo then return jsonb_build_object('ok', false, 'mensaje', 'Ese código no existe o ya no está activo'); end if;
  if c.vence_en is not null and c.vence_en < now() then return jsonb_build_object('ok', false, 'mensaje', 'Ese código ya venció'); end if;
  if c.usos_max is not null and c.usos >= c.usos_max then return jsonb_build_object('ok', false, 'mensaje', 'Ese código ya se agotó'); end if;
  if quien is null then return jsonb_build_object('ok', false, 'mensaje', 'Inicia sesión para usar códigos'); end if;
  select count(*) into usados from public.codigo_usos where codigo_id = c.id and cliente_id = quien;
  if usados >= c.por_cliente then return jsonb_build_object('ok', false, 'mensaje', 'Ya usaste este código'); end if;
  if coalesce(p_subtotal, 0) < c.minimo then
    return jsonb_build_object('ok', false, 'mensaje', 'Este código es para compras desde $' || to_char(c.minimo, 'FM999990.00'));
  end if;
  d := case when c.tipo = 'porcentaje' then round(coalesce(p_subtotal, 0) * c.valor / 100, 2) else c.valor end;
  d := least(d, coalesce(p_subtotal, 0));
  return jsonb_build_object('ok', true, 'id', c.id, 'codigo', c.codigo, 'descuento', d,
    'texto', case when c.tipo = 'porcentaje' then to_char(c.valor, 'FM990') || '% de descuento' else '$' || to_char(c.valor, 'FM999990.00') || ' de descuento' end);
end $$;
revoke execute on function public.revisar_codigo(uuid, text, numeric, uuid) from public, anon;
grant execute on function public.revisar_codigo(uuid, text, numeric, uuid) to authenticated, service_role;

-- Aparta un uso del código (solo el servidor, al guardar el pedido). Evita pasarse del límite.
create or replace function public.apartar_codigo(p_codigo bigint, p_cliente uuid)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  c public.codigos_descuento;
  u bigint;
begin
  select * into c from public.codigos_descuento where id = p_codigo for update;
  if not found or not c.activo or (c.usos_max is not null and c.usos >= c.usos_max)
     or (select count(*) from public.codigo_usos where codigo_id = c.id and cliente_id = p_cliente) >= c.por_cliente then
    return null;
  end if;
  update public.codigos_descuento set usos = usos + 1 where id = c.id;
  insert into public.codigo_usos (codigo_id, cliente_id) values (c.id, p_cliente) returning id into u;
  return u;
end $$;
revoke execute on function public.apartar_codigo(bigint, uuid) from public, anon, authenticated;
grant execute on function public.apartar_codigo(bigint, uuid) to service_role;

create or replace function public.soltar_codigo(p_uso bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare c bigint;
begin
  delete from public.codigo_usos where id = p_uso returning codigo_id into c;
  if c is not null then update public.codigos_descuento set usos = greatest(0, usos - 1) where id = c; end if;
end $$;
revoke execute on function public.soltar_codigo(bigint) from public, anon, authenticated;
grant execute on function public.soltar_codigo(bigint) to service_role;

-- Si el pedido se cancela, el código vuelve a quedar disponible para esa persona.
create or replace function public.pedidos_soltar_codigo()
returns trigger language plpgsql security definer set search_path = '' as $$
declare u record;
begin
  if new.estado = 'cancelado' and old.estado <> 'cancelado' then
    for u in select id from public.codigo_usos where pedido_id = new.id loop
      perform public.soltar_codigo(u.id);
    end loop;
  end if;
  return new;
end $$;
drop trigger if exists pedidos_soltar_codigo on public.pedidos;
create trigger pedidos_soltar_codigo after update of estado on public.pedidos
  for each row execute function public.pedidos_soltar_codigo();
revoke execute on function public.pedidos_soltar_codigo() from public, anon, authenticated;

commit;
