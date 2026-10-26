// Porké No? · Edge Function "crear-pedido"
//
// Recibe el pedido desde la app, lo valida y lo guarda. El cliente nunca
// decide el total: aquí se leen precios, horarios, zona de entrega y
// métodos de pago de la base de datos.
//
// Despliegue:  supabase functions deploy crear-pedido
// (usa las variables que Supabase pone solas en cada función: SUPABASE_URL y
// la clave secreta, SUPABASE_SECRET_KEYS en proyectos nuevos o
// SUPABASE_SERVICE_ROLE_KEY en los antiguos).

import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const MAX_LINEAS = 30;
const MAX_CANTIDAD = 50;
const MAX_PEDIDOS_10_MIN = 5;
const DIAS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const SECCION: Record<string, string> = { desayunos: "Desayunos", comida_rapida: "Comida rápida" };
const NOMBRE_DIA = ["domingos", "lunes", "martes", "miércoles", "jueves", "viernes", "sábados"];

type Linea = { codigo: string; cantidad: number; doble?: boolean; sabor?: string | null };

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
const fallo = (status: number, error: string) => json(status, { error });

function claveSecreta() {
  try {
    const k = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (k.default) return k.default as string;
  } catch { /* proyecto con claves antiguas */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}

const centavos = (n: number | string) => Math.round(Number(n) * 100);
const texto = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

// Día de la semana y minuto del día en la zona horaria del local.
function ahora(zona: string) {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: zona, weekday: "short", hour: "2-digit", minute: "2-digit", hourCycle: "h23",
    }).formatToParts(new Date()).map((x) => [x.type, x.value]),
  );
  return { dia: DIAS.indexOf(p.weekday), minuto: Number(p.hour) * 60 + Number(p.minute) };
}

const aMinutos = (t: string) => {
  const [h, m] = t.split(":");
  return Number(h) * 60 + Number(m);
};

// Igual que isOpenC() en la app: si cierre < apertura, cruza la medianoche.
function abierto(h: { activo: boolean; apertura: string; cierre: string }, minuto: number) {
  const a = aMinutos(h.apertura), c = aMinutos(h.cierre);
  return h.activo && (a <= c ? minuto >= a && minuto < c : minuto >= a || minuto < c);
}

function distanciaKm(lat1: number, lng1: number, lat2: number, lng2: number) {
  const r = (g: number) => (g * Math.PI) / 180;
  const a = Math.sin(r(lat2 - lat1) / 2) ** 2 +
    Math.cos(r(lat1)) * Math.cos(r(lat2)) * Math.sin(r(lng2 - lng1) / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(a)));
}

const hora12 = (t: string) => {
  const m = aMinutos(t), h = Math.floor(m / 60);
  return `${h % 12 || 12}:${String(m % 60).padStart(2, "0")} ${h < 12 ? "a.m." : "p.m."}`;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fallo(405, "Método no permitido.");

  const db = createClient(Deno.env.get("SUPABASE_URL")!, claveSecreta(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Quién pide: la sesión de Google del cliente.
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await db.auth.getUser(jwt);
  const user = auth?.user;
  if (!user) return fallo(401, "Tu sesión expiró. Cierra y vuelve a abrir la app.");
  // Solo clientes con cuenta de Google; las sesiones anónimas (motorizados por dispositivo) no piden.
  if (user.is_anonymous || !user.email) return fallo(401, "Inicia sesión con Google para hacer tu pedido.");

  let b: Record<string, unknown>;
  try {
    b = await req.json();
  } catch {
    return fallo(400, "Pedido inválido.");
  }

  // --- Datos del cliente ---
  const tipo = b.tipo === "delivery" || b.tipo === "recoger" ? b.tipo : null;
  if (!tipo) return fallo(400, "Elige delivery o recoger en el local.");
  const nombre = texto(b.nombre, 80);
  let tel = String(b.telefono ?? "").replace(/\D/g, "");
  if (tel.length === 11 && tel.startsWith("507")) tel = tel.slice(3);
  if (!nombre) return fallo(400, "Falta tu nombre y teléfono.");
  if (tel.length !== 8) return fallo(400, "El teléfono debe tener 8 dígitos (ej. 6000-0000).");
  const telefono = `${tel.slice(0, 4)}-${tel.slice(4)}`;
  const correo = user.email; // el comprobante va al correo de la cuenta de Google
  const nota = texto(b.nota, 300) || null;
  const referencia = texto(b.referencia, 200) || null;

  // --- Sucursal ---
  const { data: suc } = await db.from("sucursales").select("*").eq("id", b.sucursal).eq("activa", true).maybeSingle();
  if (!suc) return fallo(404, "Este local no está recibiendo pedidos.");

  // --- Método de pago ---
  const metodo = String(b.metodo_pago ?? "");
  if (!(suc.metodos_pago as string[]).includes(metodo)) return fallo(400, "Ese método de pago no está disponible.");
  const conComprobante = metodo === "yappy" || metodo === "transferencia";
  const porWhatsapp = conComprobante && b.comprobante_whatsapp === true;
  let comprobante: string | null = null;
  if (conComprobante && !porWhatsapp) {
    comprobante = typeof b.comprobante_path === "string" ? b.comprobante_path : null;
    const archivo = comprobante?.startsWith(`${user.id}/`) ? comprobante.slice(user.id.length + 1) : "";
    if (!/^[A-Za-z0-9._-]+$/.test(archivo)) return fallo(400, "Sube la captura del comprobante para continuar.");
    const { data: hay } = await db.storage.from("comprobantes").list(user.id, { search: archivo });
    if (!hay?.some((f) => f.name === archivo)) return fallo(400, "No encontramos tu comprobante. Súbelo de nuevo.");
  }

  // --- Ubicación y zona de entrega ---
  let lat: number | null = null, lng: number | null = null;
  if (tipo === "delivery") {
    lat = Number(b.lat);
    lng = Number(b.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      return fallo(400, "Elige tu ubicación de entrega.");
    }
    if (!referencia) return fallo(400, "Escribe una referencia: calle, número de casa…");
    const km = distanciaKm(suc.lat, suc.lng, lat, lng);
    if (km > Number(suc.radio_km)) {
      return fallo(422,
        `Tu ubicación está a ${km.toFixed(1)} km del local y entregamos hasta ${Number(suc.radio_km)} km. ` +
        "Puedes elegir recoger en el local.");
    }
  }

  // --- Productos ---
  const lineas = Array.isArray(b.items) ? (b.items as Linea[]) : [];
  if (!lineas.length) return fallo(400, "Tu pedido está vacío.");
  if (lineas.length > MAX_LINEAS) return fallo(400, "El pedido tiene demasiados productos.");
  // Todos los productos y promociones activas de la sucursal (son pocos; los combos usan varios productos).
  const { data: prods } = await db.from("productos").select("*").eq("sucursal_id", suc.id);
  const porCodigo = new Map((prods ?? []).map((p) => [p.codigo, p]));
  const { data: promos } = await db.from("promociones").select("*").eq("sucursal_id", suc.id).eq("activa", true);

  // --- Horario de cada sección pedida ---
  const t = ahora(suc.zona_horaria);
  const { data: hrs } = await db.from("horarios").select("seccion, activo, apertura, cierre")
    .eq("sucursal_id", suc.id).eq("dia_semana", t.dia);
  const horario = new Map((hrs ?? []).map((h) => [h.seccion, h]));

  // Promociones: solo valen los días elegidos (o durante la prueba de 30 min del admin).
  const prueba = !!suc.promo_prueba_hasta && new Date(suc.promo_prueba_hasta).getTime() > Date.now();
  const hoy = (dias: number[] | null) => !dias?.length || dias.includes(t.dia) || prueba;
  const precioPromo = new Map((promos ?? []).filter((x) => x.tipo === "precio" && hoy(x.dias)).map((x) => [x.producto_codigo, x]));
  const combos = new Map((promos ?? []).filter((x) => x.tipo === "combo").map((x) => [`c:${x.id}`, x]));

  // Revisa que un producto se pueda vender ahora; devuelve el mensaje de error o null.
  // deno-lint-ignore no-explicit-any
  const revisar = (p: any): string | null => {
    if (!p.disponible) return `${p.nombre} ya no está disponible. Quítalo de tu pedido.`;
    const dias = Array.isArray(p.dias) ? (p.dias as number[]) : [];
    if (dias.length && !hoy(dias)) return `${p.nombre} es una promoción de los ${dias.map((d) => NOMBRE_DIA[d]).join(" y ")}. Quítala de tu pedido.`;
    const h = horario.get(p.seccion);
    // Las bebidas se venden también en el horario de desayunos.
    const hd = p.categoria === "Bebidas" ? horario.get("desayunos") : null;
    if ((!h || !abierto(h, t.minuto)) && !(hd && abierto(hd, t.minuto))) {
      const sec = SECCION[p.seccion] ?? p.seccion;
      return h?.activo ? `${sec} está cerrado ahora. Abrimos a las ${hora12(h.apertura)}.` : `${sec} está cerrado ahora.`;
    }
    return null;
  };
  // deno-lint-ignore no-explicit-any
  const revisarSabor = (p: any, pedido: unknown): { sabor: string | null; error: string | null } => {
    const sabores = (p.sabores ?? {}) as Record<string, boolean>;
    if (!Object.keys(sabores).length) return { sabor: null, error: null };
    const sabor = typeof pedido === "string" ? pedido : null;
    if (!sabor || !(sabor in sabores)) return { sabor: null, error: `Elige el sabor de ${p.nombre}.` };
    if (!sabores[sabor]) return { sabor: null, error: `${p.nombre} ${sabor} está agotada. Elige otro sabor.` };
    return { sabor, error: null };
  };

  const items = [];
  let subtotal = 0;
  for (const l of lineas) {
    const cod = String(l?.codigo ?? "");
    const cantidad = Number(l?.cantidad);
    if (!Number.isInteger(cantidad) || cantidad < 1 || cantidad > MAX_CANTIDAD) return fallo(400, "Revisa las cantidades de tu pedido.");

    // Combo armado por el administrador
    if (cod.startsWith("c:")) {
      const c = combos.get(cod);
      if (!c || !hoy(c.dias)) return fallo(409, `${c?.nombre ?? "Esa promoción"} ya no está disponible hoy. Quítala de tu pedido.`);
      const componentes = [];
      let sabor: string | null = null;
      for (const it of (c.items ?? []) as { codigo: string; cantidad?: number }[]) {
        if (it.codigo === "papas") { // papas fritas incluidas en el combo (no es un producto aparte)
          componentes.push({ codigo: "papas", nombre: "Papas fritas", cantidad: it.cantidad ?? 1 });
          continue;
        }
        const p = porCodigo.get(it.codigo);
        if (!p) return fallo(409, `${c.nombre} ya no está disponible. Quítalo de tu pedido.`);
        const err = revisar(p);
        if (err) return fallo(409, `${c.nombre}: ${err}`);
        const s = revisarSabor(p, l.sabor);
        if (s.error) return fallo(400, s.error);
        if (s.sabor) sabor = s.sabor;
        componentes.push({ codigo: p.codigo, nombre: p.nombre, cantidad: it.cantidad ?? 1 });
      }
      // Doble carne en el combo: se cobra el extra de la hamburguesa que trae (p. ej. $1.50).
      const doble = l.doble === true;
      const conDoble = componentes.map((x) => porCodigo.get(x.codigo)).find((p) => p && p.extra_doble != null);
      if (doble && !conDoble) return fallo(400, `${c.nombre} no se puede pedir doble.`);
      const unitario = centavos(c.precio) + (doble ? centavos(conDoble.extra_doble) : 0);
      subtotal += unitario * cantidad;
      items.push({
        codigo: cod, nombre: c.nombre, seccion: porCodigo.get(componentes.find((x) => x.codigo !== "papas")?.codigo ?? "")?.seccion ?? "comida_rapida",
        cantidad, doble, sabor, promo: true, combo: true, categoria: "Promoción", componentes,
        precio_unitario: unitario / 100, importe: (unitario * cantidad) / 100,
      });
      continue;
    }

    const p = porCodigo.get(cod);
    if (!p) return fallo(400, "Uno de los productos ya no existe. Revisa tu pedido.");
    const err = revisar(p);
    if (err) return fallo(409, err);
    const doble = l.doble === true;
    if (doble && p.extra_doble == null) return fallo(400, `${p.nombre} no se puede pedir doble.`);
    const s = revisarSabor(p, l.sabor);
    if (s.error) return fallo(400, s.error);
    const pp = precioPromo.get(p.codigo);
    const promo = !!pp || (Array.isArray(p.dias) && p.dias.length > 0);
    const unitario = centavos(pp ? pp.precio : p.precio) + (doble ? centavos(p.extra_doble) : 0);
    subtotal += unitario * cantidad;
    items.push({
      codigo: p.codigo, nombre: p.nombre, seccion: p.seccion, cantidad, doble, sabor: s.sabor, promo,
      categoria: pp ? "Promoción" : p.categoria,
      precio_unitario: unitario / 100, importe: (unitario * cantidad) / 100,
    });
  }

  // --- Cupón de la tarjeta de sellos: una hamburguesa gratis ---
  // Se regala la hamburguesa (sin promoción) más cara del pedido; si la pide doble, el extra se cobra.
  let cupon: string | null = null;
  if (typeof b.cupon === "string" && b.cupon) {
    const { data: cp } = await db.from("cupones").select("id").eq("id", b.cupon).eq("cliente_id", user.id)
      .eq("sucursal_id", suc.id).eq("estado", "disponible").maybeSingle();
    if (!cp) return fallo(409, "Tu cupón ya no está disponible. Revisa tu pedido.");
    let mejor = -1;
    items.forEach((it, i) => {
      const p = porCodigo.get(it.codigo);
      if (it.promo || !p || p.categoria !== "Hamburguesas") return;
      if (mejor < 0 || centavos(p.precio) > centavos(porCodigo.get(items[mejor].codigo).precio)) mejor = i;
    });
    if (mejor < 0) return fallo(400, "Agrega una hamburguesa a tu pedido para usar tu cupón.");
    const it = items[mejor], base = centavos(porCodigo.get(it.codigo).precio), extra = Math.round(it.precio_unitario * 100) - base;
    if (it.cantidad > 1) {
      it.cantidad -= 1;
      it.importe = Math.round(it.precio_unitario * 100 * it.cantidad) / 100;
    } else items.splice(mejor, 1);
    items.push({ ...it, cantidad: 1, cupon: true, categoria: "Cupón", precio_unitario: extra / 100, importe: extra / 100 });
    subtotal -= base;
    cupon = cp.id;
  }

  // --- Freno a pedidos repetidos o de broma ---
  const hace10 = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const { count } = await db.from("pedidos").select("id", { count: "exact", head: true })
    .eq("cliente_id", user.id).gte("creado_en", hace10);
  if ((count ?? 0) >= MAX_PEDIDOS_10_MIN) {
    return fallo(429, "Hiciste varios pedidos seguidos. Espera unos minutos o escríbenos por WhatsApp.");
  }

  // --- Totales (en centavos para no perder decimales) ---
  const envio = tipo === "delivery" ? centavos(suc.tarifa_entrega) : 0;
  const servicio = centavos(suc.cargo_servicio);

  // El cupón se aparta antes de guardar el pedido (si dos pedidos lo usan a la vez, solo uno lo logra).
  if (cupon) {
    const { data: ok } = await db.from("cupones").update({ estado: "usado", usado_en: new Date().toISOString() })
      .eq("id", cupon).eq("estado", "disponible").select("id");
    if (!ok?.length) return fallo(409, "Tu cupón ya no está disponible. Revisa tu pedido.");
  }

  await db.from("clientes").upsert({ id: user.id, nombre, celular: telefono, correo }, { onConflict: "id" });

  const { data: pedido, error } = await db.from("pedidos").insert({
    sucursal_id: suc.id,
    cliente_id: user.id,
    dia: new Date().toISOString().slice(0, 10), // lo reemplaza el trigger
    numero: 0,                                   // lo reemplaza el trigger
    tipo, nombre, telefono, correo, referencia, lat, lng, nota,
    productos: items,
    cafe_gratis: items.some((i) => i.seccion === "desayunos"),
    subtotal: subtotal / 100,
    envio: envio / 100,
    servicio: servicio / 100,
    total: (subtotal + envio + servicio) / 100,
    metodo_pago: metodo,
    estado_pago: conComprobante ? "en_revision" : "por_cobrar",
    comprobante_path: comprobante,
    comprobante_whatsapp: porWhatsapp,
  }).select("*").single();

  if (error) {
    if (cupon) await db.from("cupones").update({ estado: "disponible", usado_en: null }).eq("id", cupon);
    console.error("crear-pedido", error);
    return fallo(500, "No se pudo guardar el pedido. Intenta de nuevo.");
  }
  if (cupon) await db.from("cupones").update({ pedido_id: pedido.id }).eq("id", cupon);
  return json(200, { pedido });
});
