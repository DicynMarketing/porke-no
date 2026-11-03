-- =====================================================================
-- Porké No? · Paso 20: invita a un amigo y gana un sello
-- Reglas contra cuentas repetidas:
--  * Un teléfono (número) solo puede estar en una cuenta.
--  * Un dispositivo (teléfono físico) que ya tiene otra cuenta no puede usar códigos de amigo.
--  * El sello se da solo cuando el amigo recibe su PRIMER pedido (desde el mínimo de sellos).
--  * Máximo 5 sellos por invitar, por persona y por mes.
-- =====================================================================
begin;

alter table public.sellos alter column pedido_id drop not null;
alter table public.clientes add column if not exists codigo_amigo text unique check (codigo_amigo is null or codigo_amigo ~ '^[A-Z0-9]{4,12}$');

create table if not exists public.dispositivos_cliente (
  dispositivo text not null check (length(dispositivo) between 8 and 80),
  cliente_id  uuid not null references auth.users (id) on delete cascade,
  creado_en   timestamptz not null default now(),
  primary key (dispositivo, cliente_id)
);
alter table public.dispositivos_cliente enable row level security;   -- solo el servidor
grant all on public.dispositivos_cliente to service_role;

create table if not exists public.referidos (
  invitado_id  uuid primary key references auth.users (id) on delete cascade,
  invitador_id uuid not null references auth.users (id) on delete cascade,
  sucursal_id  uuid not null references public.sucursales (id) on delete cascade,
  estado       text not null default 'pendiente' check (estado in ('pendiente', 'premiado', 'sin_premio')),
  creado_en    timestamptz not null default now(),
  premiado_en  timestamptz
);
alter table public.referidos enable row level security;
drop policy if exists "referidos: propios" on public.referidos;
create policy "referidos: propios" on public.referidos for select to authenticated
  using (invitado_id = auth.uid() or invitador_id = auth.uid());
grant select on public.referidos to authenticated;
grant all on public.referidos to service_role;

-- La app anota en qué teléfono físico inició sesión el cliente.
create or replace function public.registrar_dispositivo(p_disp text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then return; end if;
  if p_disp is null or length(p_disp) not between 8 and 80 then return; end if;
  insert into public.dispositivos_cliente (dispositivo, cliente_id) values (p_disp, auth.uid()) on conflict do nothing;
end $$;
revoke execute on function public.registrar_dispositivo(text) from public, anon;
grant execute on function public.registrar_dispositivo(text) to authenticated;

-- ¿Este número ya está en otra cuenta? (la app lo avisa; el servidor lo bloquea)
create or replace function public.telefono_en_otra_cuenta(p_telefono text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.clientes c
                  where c.id <> auth.uid() and c.celular is not null
                    and regexp_replace(c.celular, '\D', '', 'g') = regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'));
$$;
revoke execute on function public.telefono_en_otra_cuenta(text) from public, anon;
grant execute on function public.telefono_en_otra_cuenta(text) to authenticated;

-- crear-pedido ya consulta esta función: ahora también frena un número que pertenece a otra cuenta.
create or replace function public.esta_bloqueado(p_sucursal uuid, p_cliente uuid, p_telefono text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.bloqueos b
                  where b.sucursal_id = p_sucursal
                    and (b.cliente_id = p_cliente
                         or (p_telefono is not null and b.telefono = regexp_replace(p_telefono, '\D', '', 'g'))))
      or exists (select 1 from public.clientes c
                  where c.id <> p_cliente and c.celular is not null
                    and regexp_replace(c.celular, '\D', '', 'g') = regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'));
$$;

-- Mi código para invitar (se crea la primera vez).
create or replace function public.mi_codigo_amigo()
returns text language plpgsql security definer set search_path = '' as $$
declare c text; n text;
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then raise exception 'Inicia sesión con Google'; end if;
  select codigo_amigo, nombre into c, n from public.clientes where id = auth.uid();
  if c is not null then return c; end if;
  insert into public.clientes (id) values (auth.uid()) on conflict (id) do nothing;
  loop
    c := left(upper(regexp_replace(translate(coalesce(n, 'AMIGO'), 'áéíóúÁÉÍÓÚñÑ', 'aeiouAEIOUnN'), '[^A-Za-z]', '', 'g')) || 'PORK', 5)
         || lpad((floor(random() * 10000))::int::text, 4, '0');
    begin
      update public.clientes set codigo_amigo = c where id = auth.uid();
      return c;
    exception when unique_violation then null;
    end;
  end loop;
end $$;
revoke execute on function public.mi_codigo_amigo() from public, anon;
grant execute on function public.mi_codigo_amigo() to authenticated;

-- El amigo escribe el código de quien lo invitó.
create or replace function public.usar_codigo_amigo(p_sucursal uuid, p_codigo text, p_disp text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  yo uuid := auth.uid();
  inv uuid;
  tel_yo text; tel_inv text;
begin
  if yo is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then raise exception 'Inicia sesión con Google'; end if;
  select id into inv from public.clientes where codigo_amigo = upper(trim(coalesce(p_codigo, '')));
  if inv is null then raise exception 'Ese código de amigo no existe'; end if;
  if inv = yo then raise exception 'No puedes usar tu propio código'; end if;
  if exists (select 1 from public.referidos where invitado_id = yo) then raise exception 'Ya usaste un código de amigo'; end if;
  if exists (select 1 from public.pedidos where cliente_id = yo and estado = 'entregado') then
    raise exception 'El código de amigo es solo para tu primer pedido';
  end if;
  -- Mismo teléfono físico con otra cuenta = cuenta repetida.
  if p_disp is not null and exists (select 1 from public.dispositivos_cliente where dispositivo = p_disp and cliente_id <> yo) then
    raise exception 'Este teléfono ya tiene otra cuenta. El código de amigo es para personas nuevas';
  end if;
  select regexp_replace(coalesce(celular, ''), '\D', '', 'g') into tel_yo from public.clientes where id = yo;
  select regexp_replace(coalesce(celular, ''), '\D', '', 'g') into tel_inv from public.clientes where id = inv;
  if tel_yo <> '' and tel_yo = tel_inv then raise exception 'Este código es para personas nuevas'; end if;
  insert into public.referidos (invitado_id, invitador_id, sucursal_id) values (yo, inv, p_sucursal);
  return 'Listo: cuando recibas tu primer pedido, tu amigo gana un sello';
end $$;
revoke execute on function public.usar_codigo_amigo(uuid, text, text) from public, anon;
grant execute on function public.usar_codigo_amigo(uuid, text, text) to authenticated;

-- Da un sello y, si completa la tarjeta, el cupón.
create or replace function public.dar_sello(p_cliente uuid, p_sucursal uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s public.sucursales; n integer; c uuid;
begin
  select * into s from public.sucursales where id = p_sucursal;
  perform pg_advisory_xact_lock(hashtext(p_cliente::text));
  insert into public.sellos (cliente_id, sucursal_id, pedido_id) values (p_cliente, p_sucursal, null);
  select count(*) into n from public.sellos where cliente_id = p_cliente and sucursal_id = p_sucursal and cupon_id is null;
  if n >= s.sellos_meta then
    insert into public.cupones (cliente_id, sucursal_id) values (p_cliente, p_sucursal) returning id into c;
    update public.sellos set cupon_id = c
     where id in (select id from public.sellos where cliente_id = p_cliente and sucursal_id = p_sucursal and cupon_id is null order by id limit s.sellos_meta);
  end if;
end $$;
revoke execute on function public.dar_sello(uuid, uuid) from public, anon, authenticated;

-- Primer pedido entregado del amigo → sello para quien lo invitó (máx. 5 al mes).
create or replace function public.pedidos_premiar_referido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r public.referidos; s public.sucursales;
begin
  if new.estado <> 'entregado' or old.estado = 'entregado' or new.cliente_id is null then return new; end if;
  select * into r from public.referidos where invitado_id = new.cliente_id and estado = 'pendiente';
  if not found then return new; end if;
  select * into s from public.sucursales where id = new.sucursal_id;
  if new.subtotal < s.sellos_minimo then return new; end if;
  if (select count(*) from public.referidos where invitador_id = r.invitador_id and estado = 'premiado'
       and premiado_en > date_trunc('month', now())) >= 5 then
    update public.referidos set estado = 'sin_premio', premiado_en = now() where invitado_id = r.invitado_id;
    return new;
  end if;
  update public.referidos set estado = 'premiado', premiado_en = now() where invitado_id = r.invitado_id;
  perform public.dar_sello(r.invitador_id, new.sucursal_id);
  return new;
end $$;
drop trigger if exists pedidos_premiar_referido on public.pedidos;
create trigger pedidos_premiar_referido after update of estado on public.pedidos
  for each row execute function public.pedidos_premiar_referido();
revoke execute on function public.pedidos_premiar_referido() from public, anon, authenticated;

commit;
