# Fase 1 · Conectar Porké No? a Supabase

Mientras `SB_URL` y `SB_KEY` estén vacías en `index.html`, la app funciona igual que el prototipo.

## 1. Crear el proyecto (lo haces tú)
1. Entra a https://supabase.com y toca **Start your project**. Entra con tu cuenta de GitHub.
2. Toca **New project**. Nombre: `porke-no`. Pon una contraseña de base de datos y guárdala solo para ti; no la compartas con nadie, ni conmigo. Región: la más cercana a Panamá es **East US (North Virginia)**; Porké No? quedó en **West US (Oregon)**, que también funciona bien (la meta de menos de 2 segundos se cumple igual). Plan: **Free**.
3. Espera unos 2 minutos a que termine.

## 2. Crear las tablas
1. En el menú izquierdo toca **SQL Editor** › **New query**.
2. Copia todo el archivo `supabase/schema.sql`, pégalo y toca **Run**. Debe decir *Success*.

## 3. Permitir pedidos sin cuenta (fase 1)
**Authentication** › **Sign In / Providers** › activa **Allow anonymous sign-ins** › **Save**.
(En la fase 2 esto se cambia por el código de verificación al teléfono).

## 4. Subir la función que valida pedidos
1. **Edge Functions** › **Deploy a new function** › **Via Editor**.
2. Nombre: `crear-pedido`. Borra el ejemplo, pega todo `supabase/functions/crear-pedido/index.ts` y toca **Deploy function**.
3. Entra a la función, pestaña **Details** (o **Settings**). Si ves la opción **Verify JWT with legacy secret** encendida, apágala y guarda. La función ya revisa la sesión del cliente por su cuenta, y con las claves nuevas esa opción bloquea los pedidos.

## 5. Crear las cuentas del equipo
1. **Authentication** › **Users** › **Add user** › **Create new user**. Pon el correo y la contraseña de la dueña y marca **Auto Confirm User**. Haz lo mismo con cada motorizado.
2. **SQL Editor** › **New query**. Escribe una línea por persona y toca **Run**:
   ```sql
   select public.agregar_equipo('correo-de-la-duena@gmail.com', 'aguadulce', 'admin', 'Dueña');
   select public.agregar_equipo('correo-del-motorizado@gmail.com', 'aguadulce', 'motorizado', 'Carlos');
   ```

## Revisar que el SQL quedó bien
En **SQL Editor** › **New query**, pega esto y toca **Run**. Las tres columnas deben decir `true`:
```sql
select has_table_privilege('anon', 'public.productos', 'select')            as menu_visible,
       has_table_privilege('authenticated', 'public.pedidos', 'select')     as pedidos_con_reglas,
       has_function_privilege('anon', 'public.es_admin(uuid)', 'execute')   as reglas_ok;
```

## 6. Las dos claves públicas (ya están puestas en la app)
**Project Settings** › **API Keys**: la **Project URL** y la clave **publishable** (`sb_publishable_…`).
Esas dos son públicas y pueden ir en la app. La clave **secret** (`sb_secret_…`) o **service_role** NO se comparte nunca.

## Datos de ejemplo que hay que confirmar
En la tabla `sucursales` (menú **Table Editor**): la ubicación exacta del local (lat/lng), el radio de entrega (hoy 5 km) y la cuenta bancaria real. El horario está en `horarios`.
