-- =====================================================================
-- Porké No? · Esquema de base de datos para Supabase (PostgreSQL)
-- ---------------------------------------------------------------------
-- Cómo usarlo: en un proyecto NUEVO de Supabase abre SQL Editor, pega
-- todo este archivo y pulsa Run. Corre en una sola transacción: si algo
-- falla, no queda nada a medias.
--
-- Contenido:
--   1. Tipos
--   2. Tablas
--   3. Funciones de apoyo (roles, distancia)
--   4. Triggers (número de pedido, distancia, historial, protección)
--   5. Reglas de acceso por fila (RLS) y permisos
--   6. Acciones sobre pedidos (RPC) para cliente, admin y motorizado
--   7. Tiempo real
--   8. Archivos (comprobantes privados y fotos del menú)
--   9. Datos iniciales de Porké No? Aguadulce
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------
create type public.tipo_pedido   as enum ('delivery', 'recoger');
create type public.estado_pedido as enum ('recibido', 'preparando', 'en_camino', 'entregado', 'cancelado');
create type public.metodo_pago   as enum ('yappy', 'transferencia', 'efectivo');
create type public.estado_pago   as enum ('por_cobrar', 'en_revision', 'verificado', 'rechazado');
create type public.rol_equipo    as enum ('admin', 'motorizado');

-- ---------------------------------------------------------------------
-- 2. Tablas
-- ---------------------------------------------------------------------

-- Cada restaurante que usa la app (Porké No? es el primero).
create table public.restaurantes (
  id             uuid primary key default gen_random_uuid(),
  nombre         text not null,
  slug           text not null unique,
  logo_url       text,
  dueno_id       uuid references auth.users (id) on delete set null,
  plan           text not null default 'basico',
  activo         boolean not null default true,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

-- Cada local, con su ubicación, zona de entrega, tarifas y datos de pago.
create table public.sucursales (
  id             uuid primary key default gen_random_uuid(),
  restaurante_id uuid not null references public.restaurantes (id) on delete cascade,
  nombre         text not null,
  slug           text not null unique,
  direccion      text,
  lat            double precision not null check (lat between -90 and 90),
  lng            double precision not null check (lng between -180 and 180),
  radio_km       numeric(5,2) not null default 5 check (radio_km > 0),
  tarifa_entrega numeric(8,2) not null default 1.50 check (tarifa_entrega >= 0),
  cargo_servicio numeric(8,2) not null default 0.15 check (cargo_servicio >= 0),
  metodos_pago   public.metodo_pago[] not null default '{yappy,transferencia,efectivo}',
  yappy          text,
  banco          jsonb not null default '{}'::jsonb,   -- {"banco","tipo","cuenta","titular"}
  whatsapp       text,
  zona_horaria   text not null default 'America/Panama',
  activa         boolean not null default true,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

-- Horario por sección y día de la semana (0 = domingo … 6 = sábado).
-- Si cierre < apertura, el horario cruza la medianoche.
create table public.horarios (
  id          bigint generated always as identity primary key,
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  seccion     text not null,                 -- 'desayunos', 'comida_rapida'
  dia_semana  smallint not null check (dia_semana between 0 and 6),
  activo      boolean not null default true,
  apertura    time not null,
  cierre      time not null,
  unique (sucursal_id, seccion, dia_semana)
);

-- Menú. "codigo" es el identificador que usa la app (p. ej. '0-1').
create table public.productos (
  id             uuid primary key default gen_random_uuid(),
  sucursal_id    uuid not null references public.sucursales (id) on delete cascade,
  codigo         text not null,
  seccion        text not null,              -- 'desayunos', 'comida_rapida'
  categoria      text not null,              -- 'Hamburguesas', 'Bebidas', …
  nombre         text not null,
  descripcion    text not null default '',
  precio         numeric(8,2) not null check (precio >= 0),
  extra_doble    numeric(8,2) check (extra_doble >= 0),   -- null = no se puede hacer doble
  sabores        jsonb not null default '{}'::jsonb,       -- {"Coca-Cola": true, "Naranja": false}
  disponible     boolean not null default true,
  foto_url       text,
  orden          integer not null default 0,
  creado_en      timestamptz not null default now(),
  actualizado_en timestamptz not null default now(),
  unique (sucursal_id, codigo)
);

-- Perfil del cliente. El id es el mismo del usuario de Supabase Auth.
-- "telefono" solo se llena cuando está verificado por código (fase 2).
create table public.clientes (
  id                    uuid primary key references auth.users (id) on delete cascade,
  nombre                text,
  telefono              text unique,
  telefono_verificado   boolean not null default false,
  correo                text,
  cumple_dia            smallint check (cumple_dia between 1 and 31),
  cumple_mes            smallint check (cumple_mes between 1 and 12),
  cumple_anio           smallint check (cumple_anio between 1900 and 2100),
  notif_pedidos         boolean not null default true,
  notif_promos          boolean not null default false,
  terminos_aceptados_en timestamptz,
  creado_en             timestamptz not null default now(),
  actualizado_en        timestamptz not null default now()
);

-- Ubicaciones guardadas del cliente (Casa, Trabajo…).
create table public.direcciones (
  id             uuid primary key default gen_random_uuid(),
  cliente_id     uuid not null references public.clientes (id) on delete cascade,
  nombre         text not null,
  referencia     text not null default '',
  lat            double precision not null check (lat between -90 and 90),
  lng            double precision not null check (lng between -180 and 180),
  predeterminada boolean not null default false,
  creado_en      timestamptz not null default now()
);

-- Personal de cada sucursal.
create table public.equipo (
  id          uuid primary key default gen_random_uuid(),
  usuario_id  uuid not null references auth.users (id) on delete cascade,
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  rol         public.rol_equipo not null,
  nombre      text not null,
  activo      boolean not null default true,
  creado_en   timestamptz not null default now(),
  unique (usuario_id, sucursal_id)
);

-- Pedidos. Solo los crea la Edge Function "crear-pedido" (que calcula los
-- totales) y solo cambian a través de las funciones de la sección 6.
create table public.pedidos (
  id                   uuid primary key default gen_random_uuid(),
  sucursal_id          uuid not null references public.sucursales (id) on delete restrict,
  cliente_id           uuid references auth.users (id) on delete set null,
  dia                  date not null,          -- lo pone el trigger (zona horaria del local)
  numero               integer not null,       -- lo pone el trigger (1, 2, 3… cada día)
  tipo                 public.tipo_pedido not null,
  nombre               text not null,
  telefono             text not null,
  correo               text,
  referencia           text,
  lat                  double precision check (lat between -90 and 90),
  lng                  double precision check (lng between -180 and 180),
  distancia_km         numeric(6,2),
  productos            jsonb not null,         -- líneas validadas por el servidor
  cafe_gratis          boolean not null default false,
  nota                 text,
  subtotal             numeric(10,2) not null check (subtotal >= 0),
  envio                numeric(10,2) not null default 0 check (envio >= 0),
  servicio             numeric(10,2) not null default 0 check (servicio >= 0),
  total                numeric(10,2) not null check (total >= 0),
  metodo_pago          public.metodo_pago not null,
  estado_pago          public.estado_pago not null,
  comprobante_path     text,
  comprobante_whatsapp boolean not null default false,
  estado               public.estado_pedido not null default 'recibido',
  motorizado_id        uuid references auth.users (id) on delete set null,
  motorizado_nombre    text,
  calificacion         smallint check (calificacion between 1 and 5),
  etiquetas            smallint[] not null default '{}',
  creado_en            timestamptz not null default now(),
  actualizado_en       timestamptz not null default now(),
  entregado_en         timestamptz,
  unique (sucursal_id, dia, numero),
  check (tipo = 'recoger' or (lat is not null and lng is not null)),
  check (total = subtotal + envio + servicio)
);

create unique index pedidos_comprobante_unico on public.pedidos (comprobante_path) where comprobante_path is not null;
create index pedidos_sucursal_dia   on public.pedidos (sucursal_id, dia desc, creado_en desc);
create index pedidos_cliente        on public.pedidos (cliente_id, creado_en desc);
create index pedidos_motorizado     on public.pedidos (motorizado_id, dia desc) where motorizado_id is not null;

-- Historial de cada cambio de estado (para reportes y reclamos).
create table public.pedido_eventos (
  id            bigint generated always as identity primary key,
  pedido_id     uuid not null references public.pedidos (id) on delete cascade,
  estado        public.estado_pedido not null,
  estado_pago   public.estado_pago not null,
  motorizado_id uuid,
  actor         uuid,
  creado_en     timestamptz not null default now()
);
create index pedido_eventos_pedido on public.pedido_eventos (pedido_id, creado_en);

-- Contador del número de pedido del día (evita números repetidos con
-- muchos pedidos a la vez).
create table public.contador_pedidos (
  sucursal_id uuid not null references public.sucursales (id) on delete cascade,
  dia         date not null,
  ultimo      integer not null,
  primary key (sucursal_id, dia)
);

-- Teléfonos que reciben notificaciones push (fase 3).
create table public.dispositivos (
  id         uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references auth.users (id) on delete cascade,
  tipo       text not null check (tipo in ('webpush', 'fcm')),
  token      text not null unique,             -- token FCM o suscripción Web Push (JSON)
  plataforma text,
  creado_en  timestamptz not null default now(),
  ultimo_uso timestamptz not null default now()
);
create index dispositivos_usuario on public.dispositivos (usuario_id);

create index productos_sucursal on public.productos (sucursal_id, orden);
create index equipo_usuario     on public.equipo (usuario_id) where activo;
create index direcciones_cliente on public.direcciones (cliente_id);

-- ---------------------------------------------------------------------
-- 3. Funciones de apoyo
-- ---------------------------------------------------------------------

-- ¿El usuario actual es del equipo de esta sucursal (opcionalmente con un rol)?
create function public.es_equipo(p_sucursal uuid, p_rol public.rol_equipo default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.equipo e
    where e.usuario_id = auth.uid() and e.sucursal_id = p_sucursal and e.activo
      and (p_rol is null or e.rol = p_rol)
  );
$$;

-- ¿El usuario actual administra esta sucursal? (admin del local o dueño del restaurante)
create function public.es_admin(p_sucursal uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.es_equipo(p_sucursal, 'admin')
      or exists (
        select 1 from public.sucursales s
        join public.restaurantes r on r.id = s.restaurante_id
        where s.id = p_sucursal and r.dueno_id = auth.uid()
      );
$$;

-- Distancia en km entre dos puntos (fórmula de haversine).
create function public.distancia_km(lat1 double precision, lng1 double precision,
                                    lat2 double precision, lng2 double precision)
returns double precision language sql immutable set search_path = '' as $$
  select 2 * 6371 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2)
    + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  )));
$$;

-- ---------------------------------------------------------------------
-- 4. Triggers
-- ---------------------------------------------------------------------

create function public.tocar_actualizado()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.actualizado_en := now();
  return new;
end $$;

create trigger restaurantes_actualizado before update on public.restaurantes for each row execute function public.tocar_actualizado();
create trigger sucursales_actualizado   before update on public.sucursales   for each row execute function public.tocar_actualizado();
create trigger productos_actualizado    before update on public.productos    for each row execute function public.tocar_actualizado();
create trigger clientes_actualizado     before update on public.clientes     for each row execute function public.tocar_actualizado();

-- Al crear un pedido: día según la hora del local, número del día,
-- distancia al local y estado inicial.
create function public.pedidos_antes_insertar()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  s public.sucursales;
begin
  select * into s from public.sucursales where id = new.sucursal_id;
  if not found then
    raise exception 'Sucursal no encontrada';
  end if;
  new.dia := (now() at time zone s.zona_horaria)::date;
  insert into public.contador_pedidos as c (sucursal_id, dia, ultimo)
  values (new.sucursal_id, new.dia, 1)
  on conflict (sucursal_id, dia) do update set ultimo = c.ultimo + 1
  returning c.ultimo into new.numero;
  if new.lat is not null and new.lng is not null then
    new.distancia_km := round(public.distancia_km(s.lat, s.lng, new.lat, new.lng)::numeric, 2);
  end if;
  new.estado := 'recibido';
  new.creado_en := now();
  new.actualizado_en := now();
  return new;
end $$;

create trigger pedidos_insertar before insert on public.pedidos
for each row execute function public.pedidos_antes_insertar();

-- Al actualizar un pedido: no se pueden tocar los datos de la compra.
create function public.pedidos_antes_actualizar()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.sucursal_id is distinct from old.sucursal_id
     or new.dia is distinct from old.dia
     or new.numero is distinct from old.numero
     or new.tipo is distinct from old.tipo
     or new.productos is distinct from old.productos
     or new.subtotal is distinct from old.subtotal
     or new.envio is distinct from old.envio
     or new.servicio is distinct from old.servicio
     or new.total is distinct from old.total
     or new.creado_en is distinct from old.creado_en
     or (new.cliente_id is distinct from old.cliente_id and new.cliente_id is not null) then
    raise exception 'Los datos de la compra no se pueden modificar';
  end if;
  new.actualizado_en := now();
  if new.estado = 'entregado' and old.estado <> 'entregado' then
    new.entregado_en := now();
  end if;
  return new;
end $$;

create trigger pedidos_actualizar before update on public.pedidos
for each row execute function public.pedidos_antes_actualizar();

-- Guarda en el historial cada cambio de estado, de pago o de motorizado.
create function public.pedidos_registrar_evento()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT'
     or new.estado is distinct from old.estado
     or new.estado_pago is distinct from old.estado_pago
     or new.motorizado_id is distinct from old.motorizado_id then
    insert into public.pedido_eventos (pedido_id, estado, estado_pago, motorizado_id, actor)
    values (new.id, new.estado, new.estado_pago, new.motorizado_id, auth.uid());
  end if;
  return null;
end $$;

create trigger pedidos_evento after insert or update on public.pedidos
for each row execute function public.pedidos_registrar_evento();

-- ---------------------------------------------------------------------
-- 5. Reglas de acceso por fila (RLS) y permisos
-- ---------------------------------------------------------------------
alter table public.restaurantes     enable row level security;
alter table public.sucursales       enable row level security;
alter table public.horarios         enable row level security;
alter table public.productos        enable row level security;
alter table public.clientes         enable row level security;
alter table public.direcciones      enable row level security;
alter table public.equipo           enable row level security;
alter table public.pedidos          enable row level security;
alter table public.pedido_eventos   enable row level security;
alter table public.contador_pedidos enable row level security;
alter table public.dispositivos     enable row level security;

-- Restaurantes: cualquiera ve los activos (nombre, logo); el dueño edita.
create policy "restaurantes: ver activos" on public.restaurantes
  for select to anon, authenticated using (activo or dueno_id = auth.uid());
create policy "restaurantes: dueño edita" on public.restaurantes
  for update to authenticated using (dueno_id = auth.uid()) with check (dueno_id = auth.uid());

-- Sucursales: cualquiera ve las activas (la app muestra tarifas y datos de pago); el admin edita.
create policy "sucursales: ver activas" on public.sucursales
  for select to anon, authenticated using (activa or public.es_admin(id));
create policy "sucursales: admin edita" on public.sucursales
  for update to authenticated using (public.es_admin(id)) with check (public.es_admin(id));
create policy "sucursales: dueño crea" on public.sucursales
  for insert to authenticated with check (
    exists (select 1 from public.restaurantes r where r.id = restaurante_id and r.dueno_id = auth.uid())
  );

-- Horarios y productos: lectura pública; el admin de la sucursal administra.
create policy "horarios: ver" on public.horarios
  for select to anon, authenticated using (true);
create policy "horarios: admin crea" on public.horarios
  for insert to authenticated with check (public.es_admin(sucursal_id));
create policy "horarios: admin edita" on public.horarios
  for update to authenticated using (public.es_admin(sucursal_id)) with check (public.es_admin(sucursal_id));
create policy "horarios: admin borra" on public.horarios
  for delete to authenticated using (public.es_admin(sucursal_id));

create policy "productos: ver" on public.productos
  for select to anon, authenticated using (true);
create policy "productos: admin crea" on public.productos
  for insert to authenticated with check (public.es_admin(sucursal_id));
create policy "productos: admin edita" on public.productos
  for update to authenticated using (public.es_admin(sucursal_id)) with check (public.es_admin(sucursal_id));
create policy "productos: admin borra" on public.productos
  for delete to authenticated using (public.es_admin(sucursal_id));

-- Clientes: cada uno ve y edita solo su perfil. El teléfono verificado
-- no lo puede escribir el cliente (lo pondrá el servidor tras el código OTP).
create policy "clientes: ver propio" on public.clientes
  for select to authenticated using (id = auth.uid());
create policy "clientes: crear propio" on public.clientes
  for insert to authenticated with check (id = auth.uid());
create policy "clientes: editar propio" on public.clientes
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "clientes: borrar propio" on public.clientes
  for delete to authenticated using (id = auth.uid());
revoke insert, update on public.clientes from anon, authenticated;
grant insert (id, nombre, correo, cumple_dia, cumple_mes, cumple_anio, notif_pedidos, notif_promos, terminos_aceptados_en)
  on public.clientes to authenticated;
grant update (nombre, correo, cumple_dia, cumple_mes, cumple_anio, notif_pedidos, notif_promos, terminos_aceptados_en)
  on public.clientes to authenticated;

-- Direcciones: solo las propias.
create policy "direcciones: propias" on public.direcciones
  for all to authenticated using (cliente_id = auth.uid()) with check (cliente_id = auth.uid());

-- Equipo: cada uno ve su fila; el admin ve y administra el equipo de su sucursal.
create policy "equipo: ver" on public.equipo
  for select to authenticated using (usuario_id = auth.uid() or public.es_admin(sucursal_id));
create policy "equipo: admin crea" on public.equipo
  for insert to authenticated with check (public.es_admin(sucursal_id));
create policy "equipo: admin edita" on public.equipo
  for update to authenticated using (public.es_admin(sucursal_id)) with check (public.es_admin(sucursal_id));
create policy "equipo: admin borra" on public.equipo
  for delete to authenticated using (public.es_admin(sucursal_id));

-- Pedidos: el cliente ve los suyos, el admin los de su sucursal y el
-- motorizado solo los que tiene asignados. Nadie inserta ni edita
-- directamente: se usa la Edge Function y las funciones de la sección 6.
create policy "pedidos: ver" on public.pedidos
  for select to authenticated using (
    cliente_id = auth.uid()
    or public.es_admin(sucursal_id)
    or (motorizado_id = auth.uid() and public.es_equipo(sucursal_id, 'motorizado'))
  );
revoke insert, update, delete on public.pedidos from anon, authenticated;

create policy "pedido_eventos: ver" on public.pedido_eventos
  for select to authenticated using (
    exists (select 1 from public.pedidos p where p.id = pedido_id)   -- aplica la regla de pedidos
  );
revoke insert, update, delete on public.pedido_eventos from anon, authenticated;

-- Contador: interno, sin acceso desde la app.
revoke all on public.contador_pedidos from anon, authenticated;

-- Dispositivos: solo los propios.
create policy "dispositivos: propios" on public.dispositivos
  for all to authenticated using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());

-- ---------------------------------------------------------------------
-- 6. Acciones sobre pedidos (se llaman con supabase.rpc)
--    Cada función revisa quién la llama y que el cambio tenga sentido.
-- ---------------------------------------------------------------------

-- Cliente: sube otro comprobante cuando el local no vio el pago.
create function public.cliente_reenviar_comprobante(p_pedido uuid, p_path text default null, p_whatsapp boolean default false)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  if not coalesce(p_whatsapp, false)
     and (p_path is null or p_path !~ ('^' || auth.uid()::text || '/[A-Za-z0-9._-]+$')) then
    raise exception 'Comprobante inválido';
  end if;
  update public.pedidos
     set comprobante_path     = case when p_whatsapp then null else p_path end,
         comprobante_whatsapp = coalesce(p_whatsapp, false),
         estado_pago          = 'en_revision'
   where id = p_pedido and cliente_id = auth.uid()
     and estado = 'recibido'
     and metodo_pago in ('yappy', 'transferencia')
     and estado_pago in ('en_revision', 'rechazado')
  returning * into r;
  if not found then
    raise exception 'Este pedido ya no acepta comprobantes';
  end if;
  return r;
end $$;

-- Cliente: cambia a pago en efectivo (si el local lo acepta).
create function public.cliente_pagar_efectivo(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  update public.pedidos p
     set metodo_pago = 'efectivo', estado_pago = 'por_cobrar',
         comprobante_path = null, comprobante_whatsapp = false
   where p.id = p_pedido and p.cliente_id = auth.uid()
     and p.estado = 'recibido'
     and p.estado_pago in ('en_revision', 'rechazado')
     and exists (select 1 from public.sucursales s where s.id = p.sucursal_id and 'efectivo' = any (s.metodos_pago))
  returning * into r;
  if not found then
    raise exception 'No se puede cambiar el pago de este pedido';
  end if;
  return r;
end $$;

-- Cliente: califica un pedido entregado (una sola vez).
create function public.cliente_calificar(p_pedido uuid, p_estrellas integer, p_etiquetas integer[] default '{}')
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  if p_estrellas is null or p_estrellas not between 1 and 5 then
    raise exception 'Calificación inválida';
  end if;
  update public.pedidos
     set calificacion = p_estrellas::smallint,
         etiquetas = coalesce((select array_agg(distinct t::smallint) from unnest(p_etiquetas) t where t between 0 and 9), '{}')
   where id = p_pedido and cliente_id = auth.uid()
     and estado = 'entregado' and calificacion is null
  returning * into r;
  if not found then
    raise exception 'Este pedido no se puede calificar';
  end if;
  return r;
end $$;

-- Admin: confirma que el pago llegó.
create function public.equipo_aceptar_pago(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_admin(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado <> 'recibido' or r.estado_pago not in ('en_revision', 'rechazado') then
    raise exception 'Este pago ya fue revisado';
  end if;
  update public.pedidos set estado_pago = 'verificado' where id = p_pedido returning * into r;
  return r;
end $$;

-- Admin: no vio el pago; el cliente puede reintentar o pagar en efectivo.
create function public.equipo_rechazar_pago(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_admin(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado <> 'recibido' or r.estado_pago not in ('en_revision', 'rechazado') then
    raise exception 'Este pago ya fue revisado';
  end if;
  update public.pedidos set estado_pago = 'rechazado' where id = p_pedido returning * into r;
  return r;
end $$;

-- Admin: elige (o quita) el motorizado de un pedido de delivery.
create function public.equipo_asignar_motorizado(p_pedido uuid, p_motorizado uuid default null)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
  nom text;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_admin(r.sucursal_id) then
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

-- Admin: pasa el pedido al siguiente estado. p_esperado es el estado que
-- ve en pantalla; si otro admin ya lo cambió, no se repite el paso.
create function public.equipo_avanzar(p_pedido uuid, p_esperado public.estado_pedido)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r   public.pedidos;
  sig public.estado_pedido;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_admin(r.sucursal_id) then
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

-- Admin: cancela un pedido que aún no sale del local.
create function public.equipo_cancelar(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  select * into r from public.pedidos where id = p_pedido for update;
  if not found or not public.es_admin(r.sucursal_id) then
    raise exception 'Pedido no encontrado';
  end if;
  if r.estado not in ('recibido', 'preparando') then
    raise exception 'Este pedido ya no se puede cancelar';
  end if;
  update public.pedidos set estado = 'cancelado' where id = p_pedido returning * into r;
  return r;
end $$;

-- Motorizado: marca entregado un pedido suyo. Si era en efectivo, queda cobrado.
create function public.motorizado_entregar(p_pedido uuid)
returns public.pedidos language plpgsql security definer set search_path = '' as $$
declare
  r public.pedidos;
begin
  update public.pedidos
     set estado = 'entregado',
         estado_pago = case when estado_pago = 'por_cobrar' then 'verificado'::public.estado_pago else estado_pago end
   where id = p_pedido and motorizado_id = auth.uid()
     and estado = 'en_camino'
     and public.es_equipo(sucursal_id, 'motorizado')
  returning * into r;
  if not found then
    raise exception 'Este pedido no está en camino contigo';
  end if;
  return r;
end $$;

-- Solo desde el SQL Editor: agrega a una persona al equipo de una sucursal.
-- Primero crea su usuario en Authentication › Users (correo y contraseña).
--   select public.agregar_equipo('duena@correo.com', 'aguadulce', 'admin', 'Dueña');
--   select public.agregar_equipo('carlos@correo.com', 'aguadulce', 'motorizado', 'Carlos');
create function public.agregar_equipo(p_correo text, p_sucursal text, p_rol public.rol_equipo, p_nombre text)
returns public.equipo language plpgsql security definer set search_path = '' as $$
declare
  u uuid;
  s uuid;
  r public.equipo;
begin
  select id into u from auth.users where lower(email) = lower(p_correo);
  if u is null then
    raise exception 'No existe un usuario con el correo %. Créalo primero en Authentication › Users.', p_correo;
  end if;
  select id into s from public.sucursales where slug = p_sucursal;
  if s is null then
    raise exception 'No existe la sucursal %', p_sucursal;
  end if;
  insert into public.equipo (usuario_id, sucursal_id, rol, nombre)
  values (u, s, p_rol, p_nombre)
  on conflict (usuario_id, sucursal_id) do update
     set rol = excluded.rol, nombre = excluded.nombre, activo = true
  returning * into r;
  return r;
end $$;

-- Permisos de ejecución: las acciones solo para usuarios con sesión;
-- agregar_equipo solo desde el SQL Editor.
revoke execute on function public.cliente_reenviar_comprobante(uuid, text, boolean) from public, anon;
revoke execute on function public.cliente_pagar_efectivo(uuid)                      from public, anon;
revoke execute on function public.cliente_calificar(uuid, integer, integer[])       from public, anon;
revoke execute on function public.equipo_aceptar_pago(uuid)                         from public, anon;
revoke execute on function public.equipo_rechazar_pago(uuid)                        from public, anon;
revoke execute on function public.equipo_asignar_motorizado(uuid, uuid)             from public, anon;
revoke execute on function public.equipo_avanzar(uuid, public.estado_pedido)        from public, anon;
revoke execute on function public.equipo_cancelar(uuid)                             from public, anon;
revoke execute on function public.motorizado_entregar(uuid)                         from public, anon;
grant  execute on function public.cliente_reenviar_comprobante(uuid, text, boolean) to authenticated;
grant  execute on function public.cliente_pagar_efectivo(uuid)                      to authenticated;
grant  execute on function public.cliente_calificar(uuid, integer, integer[])       to authenticated;
grant  execute on function public.equipo_aceptar_pago(uuid)                         to authenticated;
grant  execute on function public.equipo_rechazar_pago(uuid)                        to authenticated;
grant  execute on function public.equipo_asignar_motorizado(uuid, uuid)             to authenticated;
grant  execute on function public.equipo_avanzar(uuid, public.estado_pedido)        to authenticated;
grant  execute on function public.equipo_cancelar(uuid)                             to authenticated;
grant  execute on function public.motorizado_entregar(uuid)                         to authenticated;
revoke execute on function public.agregar_equipo(text, text, public.rol_equipo, text) from public, anon, authenticated;
revoke execute on function public.pedidos_antes_insertar()   from public, anon, authenticated;
revoke execute on function public.pedidos_registrar_evento() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Tiempo real: la app escucha cambios de pedidos, menú y horarios.
--    Supabase Realtime respeta las reglas RLS de arriba.
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.pedidos, public.productos, public.horarios;

-- ---------------------------------------------------------------------
-- 8. Archivos
-- ---------------------------------------------------------------------

-- Comprobantes de pago: privados. Ruta: <id del cliente>/<archivo>.jpg
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprobantes', 'comprobantes', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy "comprobantes: cliente sube a su carpeta" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'comprobantes' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "comprobantes: ver propios o del local" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'comprobantes' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1 from public.pedidos p
        where p.comprobante_path = objects.name and public.es_admin(p.sucursal_id)
      )
    )
  );

-- Fotos del menú: públicas. Ruta: <id de la sucursal>/<archivo>
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('menu', 'menu', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy "menu: admin sube" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'menu' and exists (
      select 1 from public.equipo e
      where e.usuario_id = auth.uid() and e.rol = 'admin' and e.activo
        and e.sucursal_id::text = (storage.foldername(name))[1]
    )
  );
create policy "menu: admin cambia" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'menu' and exists (
      select 1 from public.equipo e
      where e.usuario_id = auth.uid() and e.rol = 'admin' and e.activo
        and e.sucursal_id::text = (storage.foldername(name))[1]
    )
  );
create policy "menu: admin borra" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'menu' and exists (
      select 1 from public.equipo e
      where e.usuario_id = auth.uid() and e.rol = 'admin' and e.activo
        and e.sucursal_id::text = (storage.foldername(name))[1]
    )
  );

-- ---------------------------------------------------------------------
-- 9. Datos iniciales: Porké No?, Aguadulce
--    PENDIENTE de confirmar con la dueña: ubicación exacta del local,
--    radio de entrega, cuenta bancaria real y horario por día.
-- ---------------------------------------------------------------------
with r as (
  insert into public.restaurantes (nombre, slug)
  values ('Porké No?', 'porke-no')
  returning id
)
insert into public.sucursales (restaurante_id, nombre, slug, direccion, lat, lng, radio_km,
                               tarifa_entrega, cargo_servicio, yappy, banco, whatsapp)
select r.id, 'Aguadulce', 'aguadulce', 'Aguadulce, Coclé', 8.2436, -80.5472, 5,
       1.50, 0.15, '6349-8263',
       '{"banco": "Banco General (demo)", "tipo": "Cuenta de ahorros", "cuenta": "XXXX-XXXX-XXXX", "titular": "Porké No?"}'::jsonb,
       '50763498263'
from r;

insert into public.horarios (sucursal_id, seccion, dia_semana, activo, apertura, cierre)
select s.id, h.seccion, d, true, h.apertura, h.cierre
from public.sucursales s
cross join generate_series(0, 6) d
cross join (values ('comida_rapida', time '14:00', time '23:00'),
                   ('desayunos',     time '07:00', time '11:00')) h(seccion, apertura, cierre)
where s.slug = 'aguadulce';

-- Los códigos coinciden con el menú de index.html (grupo-posición).
insert into public.productos (sucursal_id, codigo, seccion, categoria, nombre, descripcion, precio, extra_doble, sabores, orden)
select s.id, p.codigo, p.seccion, p.categoria, p.nombre, p.descripcion, p.precio, p.extra_doble, p.sabores::jsonb, p.orden
from public.sucursales s
cross join (values
  ('0-0', 'comida_rapida', 'Hamburguesas',   'Clásica',              'Carne smash, doble queso, salsa de la casa, lechuga y tomate.',                          5.50, 1.50, '{}',  1),
  ('0-1', 'comida_rapida', 'Hamburguesas',   'Bacon',                'Carne smash, doble queso, salsa de la casa, bacon, pepinillos, cebolla caramelizada.',   7.00, 1.50, '{}',  2),
  ('0-2', 'comida_rapida', 'Hamburguesas',   'Cheese Burger',        'Carne smash, queso, pepinillos y salsa de la casa.',                                     6.00, 1.50, '{}',  3),
  ('0-3', 'comida_rapida', 'Hamburguesas',   'Burger con Cebolla',   'Queso, pepinillo, salsa de la casa, cebolla cruda.',                                     6.00, 1.50, '{}',  4),
  ('1-0', 'comida_rapida', 'Para compartir', 'Chicharrones',         'Con yuca.',                                                                              7.50, null, '{}',  5),
  ('1-1', 'comida_rapida', 'Para compartir', 'Papas Locas de Pollo', 'Papas, pollo hilachado, queso y salsas de la casa.',                                      6.00, null, '{}',  6),
  ('1-2', 'comida_rapida', 'Para compartir', 'Choripapas',           'Papas, chorizo, queso y salsas de la casa.',                                             6.00, null, '{}',  7),
  ('1-3', 'comida_rapida', 'Para compartir', 'Hot Dog Jumbo',        'Pan, salchicha jumbo, rizadas, queso y salsa de la casa.',                               4.00, null, '{}',  8),
  ('2-0', 'comida_rapida', 'Bebidas',        'Soda',                 '', 1.25, null, '{"Coca-Cola": true, "Naranja": true, "Ginger ale": true, "Fresca": true}', 9),
  ('2-1', 'comida_rapida', 'Bebidas',        'Agua',                 '', 1.00, null, '{}', 10),
  ('3-0', 'desayunos',     'Desayunos',      'Omelette',             '', 1.00, null, '{}', 11),
  ('3-1', 'desayunos',     'Desayunos',      'Hot cakes',            '', 0.50, null, '{}', 12),
  ('3-2', 'desayunos',     'Desayunos',      'Huevos revueltos',     '', 0.75, null, '{}', 13),
  ('3-3', 'desayunos',     'Desayunos',      'Tortillas',            '', 0.35, null, '{}', 14),
  ('3-4', 'desayunos',     'Desayunos',      'Derretidos',           '', 1.25, null, '{}', 15),
  ('3-5', 'desayunos',     'Desayunos',      'Empanadas',            '', 0.65, null, '{}', 16),
  ('3-6', 'desayunos',     'Desayunos',      'Chorizos',             '', 0.75, null, '{}', 17),
  ('3-7', 'desayunos',     'Desayunos',      'Emparedado de pollo',  '', 3.00, null, '{}', 18),
  ('3-8', 'desayunos',     'Desayunos',      'Emparedado de jamón',  '', 2.15, null, '{}', 19)
) p(codigo, seccion, categoria, nombre, descripcion, precio, extra_doble, sabores, orden)
where s.slug = 'aguadulce';

commit;
