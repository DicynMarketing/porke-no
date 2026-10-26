# Fase 1 · Conectar Porké No? a Supabase

## ✅ Lista de pendientes en Supabase (se actualiza en cada cambio)
Última versión de la app: **0.9.20**. Haz solo lo que todavía no hayas hecho, en este orden:

| # | Qué | Dónde | Estado |
|---|-----|-------|--------|
| 1 | SQL `04-menu-y-promocion.sql` | SQL Editor › Run | ✔ Hecho |
| 2 | SQL `05-promociones.sql` | SQL Editor › Run | ✔ Hecho |
| 3 | SQL `06-combos-con-papas.sql` | SQL Editor › Run | ✔ Hecho |
| 4 | SQL `07-jugo-del-valle.sql` | SQL Editor › Run | ✔ Hecho |
| 5 | Función `crear-pedido` (código de `supabase/functions/crear-pedido/index.ts`) | Edge Functions › crear-pedido › Code › Deploy | ✔ Hecho (versión 0.9.18: bebidas también en horario de desayunos) |
| 6 | Secrets `VAPID_*` y `EMAIL_PROVIDER = none` | Edge Functions › Secrets | ✔ Hecho |
| 7 | Función `enviar-push` | Edge Functions › enviar-push › Code › Deploy | Volver a subir si no lo hiciste desde la versión 0.9.8 |


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

---

# Paso 3 · Clientes con Google, motorizados por teléfono aprobado y comprobante por correo (versión 0.9.2)

Haz los pasos en este orden. Cada uno se hace una sola vez.

## G. Correr el SQL nuevo
**SQL Editor** › **New query** › pega todo `supabase/03-clientes-google-motorizados.sql` › **Run** → *Success*.
(Abre https://github.com/DicynMarketing/porke-no/blob/fase-1-pedidos-en-vivo/supabase/03-clientes-google-motorizados.sql y usa el botón de copiar).

## H. Volver a subir las dos funciones que cambiaron
En **Edge Functions**, entra a cada una › **Code** (o **Edit**) › borra todo › pega la versión nueva › **Deploy**:
- `crear-pedido` ← `supabase/functions/crear-pedido/index.ts` (ahora exige cuenta de Google). Verify JWT: apagado.
- `enviar-push` ← `supabase/functions/enviar-push/index.ts` (el aviso de pedido nuevo va solo al administrador). Verify JWT: apagado.

## I. Crear el acceso con Google (en Google Cloud)
1. Entra a https://console.cloud.google.com con tu cuenta de Google › arriba, selector de proyectos › **New project** › nombre `porke-no` › **Create**.
2. Menú ☰ › **APIs & Services** › **OAuth consent screen** (en la versión nueva se llama **Google Auth Platform**) › **Get started**:
   - App name: `Porké No?` · User support email: tu correo › **Next**
   - Audience: **External** › **Next** · Contact information: tu correo › **Next** › acepta › **Create**.
3. **Branding** › **Authorized domains** › **Add domain** (uno por uno): `porke-no.pages.dev` y `dgfdkcphklmeqlvyzmpu.supabase.co` › **Save**.
4. **Audience** › **Publish app** › **Confirm**. (Solo se piden nombre y correo, por eso Google no exige revisión).
5. **Clients** › **Create client** › Application type: **Web application** › Name: `Porké No? web`:
   - **Authorized JavaScript origins** › **Add URI**:
     `https://porke-no.pages.dev` y `https://fase-1-pedidos-en-vivo.porke-no.pages.dev`
   - **Authorized redirect URIs** › **Add URI**: `https://dgfdkcphklmeqlvyzmpu.supabase.co/auth/v1/callback`
     (Google siempre devuelve al cliente a Supabase; Supabase lo regresa a la app. Por eso las páginas de la app van en "JavaScript origins" y aquí solo va la dirección de Supabase).
   - **Create**. Se muestran **Client ID** y **Client secret**. Déjalos abiertos para el paso J. No los pegues en el chat.

## J. Activar Google en Supabase
1. **Authentication** › **Sign In / Providers** › **Google** › actívalo.
2. Pega **Client ID** en "Client IDs" y **Client secret** en "Client Secret (for OAuth)" › **Save**. El secreto queda solo en Supabase.
3. En la misma sección de proveedores deja **Allow anonymous sign-ins** encendido (lo usan los teléfonos de los motorizados) y activa **Allow manual linking** (pasa los pedidos de prueba anteriores a la cuenta de Google) › **Save**.
4. No actives "Email" para clientes: los clientes solo entran con Google. (El administrador sigue entrando con el correo y la contraseña que creaste en Users).

## K. Direcciones permitidas de regreso
**Authentication** › **URL Configuration**:
- **Site URL**: `https://porke-no.pages.dev` › **Save**
- **Redirect URLs** › **Add URL** (una por una) › **Save**:
  - `https://porke-no.pages.dev/**`
  - `https://*.porke-no.pages.dev/**`  (cubre el link de prueba de cada rama)

## L. Correo del comprobante (Resend)
1. Entra a https://resend.com › **Sign up** (con tu Google). Plan **Free**.
2. **API Keys** › **Create API Key** › nombre `porke-no` › permiso **Sending access** › **Add**. Copia la clave (empieza con `re_`).
3. En Supabase › **Edge Functions** › **Secrets** › crea:
   - `EMAIL_PROVIDER` → `resend`
   - `RESEND_API_KEY` → la clave `re_…`
   - `EMAIL_FROM` → `Porké No? <onboarding@resend.dev>` (para probar)
4. **Importante:** con `onboarding@resend.dev`, Resend solo entrega correos a la dirección con la que creaste tu cuenta de Resend. Para que les llegue a todos los clientes hace falta un dominio propio verificado en Resend (**Domains** › **Add Domain**) y cambiar `EMAIL_FROM` a `Porké No? <recibos@tu-dominio>`. El dominio tiene costo anual: antes de comprarlo te confirmo el precio.
5. **Edge Functions** › **Deploy a new function** › **Via Editor** › nombre `enviar-comprobante` › pega `supabase/functions/enviar-comprobante/index.ts` › **Deploy**. Verify JWT: **apagado** (la llama la base de datos; solo envía comprobantes de pedidos que ya están en su cola interna).

## M. Motorizados
Ya no se crean en Authentication. En el teléfono del motorizado: abre la app del equipo › **Soy motorizado** › escribe su nombre › **Pedir acceso**. En la tablet aparece la solicitud con su nombre y su teléfono: **Aprobar**, **Rechazar** o **Cancelar**. Para quitarle el acceso: pestaña **Repartidores** › **×** junto a su nombre (toca dos veces).
Si antes creaste la cuenta de motorizado de tu esposa con correo y contraseña, ya no la necesita: puede pedir acceso desde su teléfono como se explica arriba.

## Capacidad y plan
- El menú y los horarios se guardan en el teléfono y se actualizan al abrir la app (y cada 10 minutos al volver a ella). No usan tiempo real.
- El cliente solo abre una conexión en tiempo real mientras tiene un pedido activo, y la cierra al salir de la app o al terminar el pedido. La tablet del administrador y el motorizado mantienen la suya.
- Plan gratis de Supabase (datos de octubre 2026, verifícalos en https://supabase.com/pricing): 200 conexiones de tiempo real a la vez, 50,000 usuarios activos al mes, 500,000 llamadas a funciones al mes, base de datos de 500 MB, archivos 1 GB, 5 GB de tráfico al mes. **El proyecto gratis se pausa tras 1 semana sin uso.**
- Con 200 a 300 clientes y picos de decenas a la vez, el plan gratis alcanza en capacidad, pero antes de abrir al público conviene el **plan Pro (desde 25 USD al mes)**: no se pausa, tiene copias de seguridad diarias y más margen (500 conexiones de tiempo real, 8 GB de base de datos).

---

# Paso 4 · Bebidas nuevas y combos de los miércoles (versión 0.9.10)

## N. Correr el SQL
**SQL Editor** › **New query** › pega todo `supabase/04-menu-y-promocion.sql` › **Run** → *Success*.
Se puede correr dos veces sin problema.

## O. Volver a subir dos funciones
**Edge Functions** › entra a cada una › **Code** › pega la versión nueva › **Deploy** (Verify JWT sigue apagado):
- `crear-pedido` ← `supabase/functions/crear-pedido/index.ts` (cobra el combo a $5.00 solo el día de la promoción).
- `enviar-comprobante` ← `supabase/functions/enviar-comprobante/index.ts` (el correo dice "Promo miércoles" en el combo).

## Cambiar precios o el día de la promoción
**Table Editor** › `productos`:
- Precio: columna `precio` (combos `4-0`, `4-1`, `4-2`; jugos y té `2-2`, `2-3`, `2-4`).
- Día: columna `dias` (`{3}` = miércoles; `{3,5}` = miércoles y viernes; 0 = domingo … 6 = sábado). Vacío = todos los días.

---

# Paso 5 · Promociones editables (versión 0.9.12)

## P. Correr el SQL
**SQL Editor** › **New query** › pega todo `supabase/05-promociones.sql` › **Run** → *Success*.
Crea la tabla de promociones y pasa los 3 combos de los miércoles a combos editables.

## Q. Volver a subir dos funciones
**Edge Functions** › entra a cada una › **Code** › pega la versión nueva › **Deploy** (Verify JWT apagado):
- `crear-pedido` ← cobra los precios de promoción y los combos solo los días elegidos.
- `enviar-comprobante` ← el correo muestra qué trae cada combo.

## Cómo se usa (app del equipo › 🎉 Promociones)
- **Precio normal:** cámbialo y toca **Guardar**.
- **Precio de promoción de un producto:** escribe el precio, marca los días (D L M M J V S; sin días = todos) y enciende **Activar promoción**.
- **Combos:** **＋ Armar combo** › nombre › toca **+** en los productos que lleva › precio › días › **Activar promoción** › **Guardar combo**.
- **Probar otro día:** **Probar todas las promociones (30 min)**.
