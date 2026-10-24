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
  const codigos = [...new Set(lineas.map((l) => String(l?.codigo ?? "")))];
  const { data: prods } = await db.from("productos").select("*").eq("sucursal_id", suc.id).in("codigo", codigos);
  const porCodigo = new Map((prods ?? []).map((p) => [p.codigo, p]));

  // --- Horario de cada sección pedida ---
  const t = ahora(suc.zona_horaria);
  const { data: hrs } = await db.from("horarios").select("seccion, activo, apertura, cierre")
    .eq("sucursal_id", suc.id).eq("dia_semana", t.dia);
  const horario = new Map((hrs ?? []).map((h) => [h.seccion, h]));

  const items = [];
  let subtotal = 0;
  for (const l of lineas) {
    const p = porCodigo.get(String(l?.codigo ?? ""));
    if (!p) return fallo(400, "Uno de los productos ya no existe. Revisa tu pedido.");
    if (!p.disponible) return fallo(409, `${p.nombre} ya no está disponible. Quítalo de tu pedido.`);
    const cantidad = Number(l.cantidad);
    if (!Number.isInteger(cantidad) || cantidad < 1 || cantidad > MAX_CANTIDAD) {
      return fallo(400, `Revisa la cantidad de ${p.nombre}.`);
    }
    const doble = l.doble === true;
    if (doble && p.extra_doble == null) return fallo(400, `${p.nombre} no se puede pedir doble.`);
    const sabores = (p.sabores ?? {}) as Record<string, boolean>;
    let sabor: string | null = null;
    if (Object.keys(sabores).length) {
      sabor = typeof l.sabor === "string" ? l.sabor : null;
      if (!sabor || !(sabor in sabores)) return fallo(400, `Elige el sabor de ${p.nombre}.`);
      if (!sabores[sabor]) return fallo(409, `${p.nombre} ${sabor} está agotada. Elige otro sabor.`);
    }
    const h = horario.get(p.seccion);
    if (!h || !abierto(h, t.minuto)) {
      const sec = SECCION[p.seccion] ?? p.seccion;
      return fallo(409, h?.activo
        ? `${sec} está cerrado ahora. Abrimos a las ${hora12(h.apertura)}.`
        : `${sec} está cerrado ahora.`);
    }
    const unitario = centavos(p.precio) + (doble ? centavos(p.extra_doble) : 0);
    subtotal += unitario * cantidad;
    items.push({
      codigo: p.codigo, nombre: p.nombre, seccion: p.seccion, cantidad, doble, sabor,
      precio_unitario: unitario / 100, importe: (unitario * cantidad) / 100,
    });
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
    console.error("crear-pedido", error);
    return fallo(500, "No se pudo guardar el pedido. Intenta de nuevo.");
  }
  return json(200, { pedido });
});
