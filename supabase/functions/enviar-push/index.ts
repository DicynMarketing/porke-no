// Porké No? · Edge Function "enviar-push"
//
// GET  → devuelve la clave pública VAPID (la app la necesita para suscribirse).
// POST → envía los avisos que están en la cola push_pendientes. La llama la
//        base de datos (trigger) cada vez que entra o cambia un pedido. Se
//        puede llamar sin sesión: solo vacía la cola, y la cola solo la llena
//        la base de datos, así que nadie puede mandar avisos inventados.
//
// Secrets que necesita (Edge Functions › Secrets):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:…)
// Verify JWT: APAGADO (la llama la base de datos, que no tiene sesión).

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const VIEJO_MS = 30 * 60 * 1000; // un aviso de hace más de 30 min ya no sirve

function claveSecreta() {
  try {
    const k = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (k.default) return k.default as string;
  } catch { /* proyecto con claves antiguas */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}

type Aviso = { usuarios: string[] | null; app: "cliente" | "equipo" | null; title: string; body: string; tag: string; hash?: string };
type Fila = { id: number; tipo: string; pedido_id: string | null; datos: Record<string, string>; creado_en: string };

const dinero = (n: number | string) => `$${Number(n).toFixed(2)}`;

// Decide a quién va cada aviso y qué dice.
// deno-lint-ignore no-explicit-any
async function armar(db: any, f: Fila): Promise<Aviso | null> {
  if (f.tipo === "version") {
    return {
      usuarios: null, app: null, tag: "version",
      title: "Hay una nueva versión de Porké No?",
      body: f.datos.notas || `Abre la app y toca "Actualizar ahora" (versión ${f.datos.v}).`,
    };
  }
  const { data: p } = await db.from("pedidos").select("*").eq("id", f.pedido_id).maybeSingle();
  if (!p) return null;
  const { data: s } = await db.from("sucursales").select("restaurante_id").eq("id", p.sucursal_id).maybeSingle();
  const { data: r } = s ? await db.from("restaurantes").select("nombre").eq("id", s.restaurante_id).maybeSingle() : { data: null };
  const local = r?.nombre ?? "el local";
  const tag = `pedido-${p.id}`;
  const delivery = p.tipo === "delivery";

  if (f.tipo === "nuevo") {
    const { data: eq } = await db.from("equipo").select("usuario_id").eq("sucursal_id", p.sucursal_id).eq("activo", true);
    return {
      usuarios: (eq ?? []).map((e: { usuario_id: string }) => e.usuario_id), app: "equipo", tag,
      title: `🔔 Pedido nuevo #${p.numero}`,
      body: `${p.nombre} · ${delivery ? "Delivery" : "Recoger en el local"} · ${dinero(p.total)}`,
    };
  }
  if (f.tipo === "entrega") {
    if (!p.motorizado_id) return null;
    return {
      usuarios: [p.motorizado_id], app: "equipo", tag,
      title: `🛵 Nueva entrega #${p.numero}`,
      body: `${p.nombre} · ${p.referencia ?? ""}${p.metodo_pago === "efectivo" ? ` · Cobrar ${dinero(p.total)}` : " · Ya pagado"}`,
    };
  }
  if (!p.cliente_id) return null;
  const cliente = { usuarios: [p.cliente_id], app: "cliente" as const, tag, hash: "pedido" };
  if (f.tipo === "pago") {
    return f.datos.estado_pago === "verificado"
      ? { ...cliente, title: "Pago verificado ✅", body: "Ya lo tenemos. En breve empezamos tu pedido 🐷" }
      : { ...cliente, title: "Verifica tu pago", body: "No vimos el pago en la cuenta del local. Toca para ver opciones." };
  }
  const textos: Record<string, [string, string]> = {
    preparando: ["Preparando tu pedido", "Nuestro cocinero ya está en eso 🔥"],
    en_camino: delivery
      ? ["¡Tu pedido va en camino!", "El repartidor va hacia ti 🛵"]
      : ["¡Tu pedido está listo!", "Ya puedes pasar a recogerlo 🛍️"],
    entregado: ["¡Pedido entregado!", `¡Buen provecho! Gracias por pedir en ${local}`],
    cancelado: ["Tu pedido fue cancelado", `Escríbele a ${local} por WhatsApp si tienes dudas.`],
  };
  const t = textos[f.datos.estado];
  return t ? { ...cliente, title: t[0], body: t[1] } : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const publica = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
  if (req.method === "GET") return json(200, { publicKey: publica });
  if (req.method !== "POST") return json(405, { error: "Método no permitido." });

  const privada = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
  if (!publica || !privada) return json(500, { error: "Faltan los secrets VAPID_PUBLIC_KEY y VAPID_PRIVATE_KEY." });
  const vapidDetails = {
    subject: Deno.env.get("VAPID_SUBJECT") || "mailto:dicynmarketing@gmail.com",
    publicKey: publica,
    privateKey: privada,
  };

  const db = createClient(Deno.env.get("SUPABASE_URL")!, claveSecreta(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let enviados = 0, borrados = 0, fallidos = 0;
  for (let vuelta = 0; vuelta < 5; vuelta++) {
    const { data: filas, error } = await db.rpc("tomar_push_pendientes", { p_max: 50 });
    if (error) {
      console.error("tomar_push_pendientes", error);
      return json(500, { error: "No se pudo leer la cola de avisos." });
    }
    if (!filas?.length) break;

    for (const f of filas as Fila[]) {
      if (Date.now() - new Date(f.creado_en).getTime() > VIEJO_MS) continue;
      const aviso = await armar(db, f);
      if (!aviso || (aviso.usuarios && !aviso.usuarios.length)) continue;

      let q = db.from("suscripciones_push").select("id, endpoint, p256dh, auth, app");
      if (aviso.usuarios) q = q.in("usuario_id", aviso.usuarios);
      if (aviso.app) q = q.eq("app", aviso.app);
      const { data: subs } = await q;

      const vistos = new Set<string>();
      for (const s of subs ?? []) {
        if (vistos.has(s.endpoint)) continue; // un mismo teléfono recibe el aviso una sola vez
        vistos.add(s.endpoint);
        const app = aviso.app ?? s.app;
        const url = (app === "equipo" ? "./?app=equipo" : "./") + (aviso.hash ? `#${aviso.hash}` : "");
        const payload = JSON.stringify({ title: aviso.title, body: aviso.body, tag: aviso.tag, app, url });
        try {
          const r = webpush.generateRequestDetails(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            payload,
            { vapidDetails, TTL: 3600, urgency: "high" },
          );
          const headers = { ...r.headers } as Record<string, string>;
          delete headers["Content-Length"]; // fetch la calcula sola
          const res = await fetch(r.endpoint, { method: r.method, headers, body: r.body });
          if (res.status === 404 || res.status === 410) {
            await db.from("suscripciones_push").delete().eq("id", s.id);
            borrados++;
          } else if (res.ok) {
            enviados++;
          } else {
            fallidos++;
            console.error("push", res.status, await res.text());
          }
        } catch (e) {
          fallidos++;
          console.error("push", e);
        }
      }
    }
  }
  return json(200, { enviados, borrados, fallidos });
});
