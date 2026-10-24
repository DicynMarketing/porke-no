# Fase 1 · Conectar Porké No? a Supabase

En esta rama `index.html` ya apunta al proyecto de Supabase de Porké No?. Si `SB_URL` y `SB_KEY` quedan vacías, la app funciona igual que el prototipo.

Vista previa de esta rama (Cloudflare Pages): `https://fase-1-pedidos-en-vivo.porke-no.pages.dev` (cliente) y la misma dirección con `?app=equipo` al final (Admin y motorizado).

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

---

# Paso 2 · Pantalla de rol y notificaciones push (versión 0.9.1)

Haz estos pasos en orden. Cada uno se hace una sola vez.

## A. Correr el SQL de notificaciones
1. **SQL Editor** › **New query**.
2. Abre https://github.com/DicynMarketing/porke-no/blob/fase-1-pedidos-en-vivo/supabase/02-notificaciones.sql, toca el botón de copiar (dos cuadritos), pégalo y toca **Run**. Debe decir *Success*.

## B. Crear las claves de notificaciones (VAPID)
1. En la computadora o el teléfono abre https://fase-1-pedidos-en-vivo.porke-no.pages.dev/herramientas/claves-push.html
2. Toca **Crear claves**. Salen dos claves. No cierres la página hasta terminar el paso C.

## C. Guardar las claves en Supabase (Secrets)
1. **Edge Functions** › **Secrets** (o **Project Settings** › **Edge Functions** › **Secrets**).
2. Crea estos tres, uno por uno (**Add new secret** › nombre › valor › **Save**):
   - `VAPID_PUBLIC_KEY` → la clave 1 (pública)
   - `VAPID_PRIVATE_KEY` → la clave 2 (privada)
   - `VAPID_SUBJECT` → `mailto:dicynmarketing@gmail.com`
3. No me pases ninguna de las dos claves: la app pide la pública sola al servidor.

## D. Subir la función que envía los avisos
1. **Edge Functions** › **Deploy a new function** › **Via Editor**.
2. Nombre exacto: `enviar-push`. Borra el ejemplo, pega todo `supabase/functions/enviar-push/index.ts` y toca **Deploy function**.
3. En la función, **Verify JWT with legacy secret**: **apagado**. La llama la base de datos, que no tiene sesión. Es seguro: la función solo envía lo que la base de datos dejó en su cola interna, y nadie desde la app puede escribir en esa cola.

## E. Cuenta de motorizado de tu esposa
1. **Authentication** › **Users** › **Add user** › **Create new user**: su correo y una contraseña; marca **Auto Confirm User** › **Create user**.
2. **SQL Editor** › **New query** (cambia el correo y el nombre) › **Run**:
   ```sql
   select public.agregar_equipo('correo-de-tu-esposa@gmail.com', 'aguadulce', 'motorizado', 'Nombre de tu esposa');
   ```

## F. Avisar a todos que hay versión nueva (opcional, cada vez que se publique una)
Cuando la versión ya esté publicada, en **SQL Editor** › **Run**:
```sql
select public.avisar_nueva_version('0.9.1', 'Pantalla de rol y notificaciones en la bandeja del teléfono');
```
Llega como notificación a todos los teléfonos que activaron los avisos.
