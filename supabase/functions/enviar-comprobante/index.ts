// Porké No? · Edge Function "enviar-comprobante"
//
// Manda por correo el comprobante (recibo) de cada pedido nuevo al correo de
// la cuenta de Google del cliente. La llama la base de datos al crear un
// pedido; solo vacía la cola interna correos_pendientes, así que se puede
// llamar sin sesión sin que nadie pueda mandar correos inventados.
//
// Secrets (Edge Functions › Secrets):
//   EMAIL_PROVIDER  = resend  (o "none" para solo registrar, sin enviar)
//   RESEND_API_KEY  = clave de Resend
//   EMAIL_FROM      = "Porké No? <recibos@tu-dominio.com>"
// Verify JWT: APAGADO (la llama la base de datos, que no tiene sesión).

import { createClient } from "npm:@supabase/supabase-js@2.117.3";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

function claveSecreta() {
  try {
    const k = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    if (k.default) return k.default as string;
  } catch { /* proyecto con claves antiguas */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}

const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const dinero = (n: number | string) => `$${Number(n).toFixed(2)}`;
const PAGO: Record<string, string> = { yappy: "Yappy", transferencia: "Transferencia", efectivo: "Efectivo" };

type Correo = { para: string; asunto: string; html: string; texto: string };

// Proveedores de correo. Para cambiar de proveedor, agrega otro aquí y
// cambia el secret EMAIL_PROVIDER.
const PROVEEDORES: Record<string, (c: Correo) => Promise<void>> = {
  resend: async (c) => {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: Deno.env.get("EMAIL_FROM"), to: [c.para], subject: c.asunto, html: c.html, text: c.texto }),
    });
    if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
  },
  none: async (c) => {
    console.log("correo (sin enviar)", c.para, c.asunto);
  },
};

// deno-lint-ignore no-explicit-any
function armar(p: any, local: string, suc: any): Correo {
  const fecha = new Date(p.creado_en).toLocaleString("es-PA", { timeZone: suc?.zona_horaria ?? "America/Panama", dateStyle: "medium", timeStyle: "short" });
  // deno-lint-ignore no-explicit-any
  const lineas = (p.productos ?? []).map((l: any) =>
    [`${l.cantidad}× ${l.nombre}${l.doble ? " (doble)" : ""}${l.sabor ? ` · ${l.sabor}` : ""}${l.componentes?.length ? ` (${l.componentes.map((c: { cantidad: number; nombre: string }) => `${c.cantidad} ${c.nombre}`).join(", ")})` : ""}${l.cupon ? " · Cupón: hamburguesa gratis" : l.promo ? ` · ${l.categoria ?? "Promoción"}` : ""}`, dinero(l.importe)]);
  const filas = [...lineas, ["Productos", dinero(p.subtotal)], ...(Number(p.envio) ? [["Envío", dinero(p.envio)]] : []), ["Servicio de la app", dinero(p.servicio)]];
  const aviso = "Este correo es un comprobante de tu pedido (recibo). No es una factura fiscal.";
  const html = `<!doctype html><html><body style="margin:0;background:#f4f4f4;font-family:Arial,sans-serif;color:#222">
<div style="max-width:480px;margin:0 auto;background:#fff;padding:24px">
<h2 style="margin:0 0 4px">${esc(local)}</h2>
<p style="margin:0 0 16px;color:#666">Comprobante del pedido #${esc(p.numero)} · ${esc(fecha)}</p>
<p>Hola ${esc(p.nombre)}, recibimos tu pedido.</p>
<table style="width:100%;border-collapse:collapse">
${filas.map(([a, b]) => `<tr><td style="padding:6px 0;border-bottom:1px solid #eee">${esc(a)}</td><td style="padding:6px 0;border-bottom:1px solid #eee;text-align:right">${esc(b)}</td></tr>`).join("")}
<tr><td style="padding:10px 0;font-weight:bold">Total</td><td style="padding:10px 0;text-align:right;font-weight:bold">${esc(dinero(p.total))}</td></tr>
</table>
<p>Pago: ${esc(PAGO[p.metodo_pago] ?? p.metodo_pago)} · ${p.tipo === "delivery" ? `Delivery a: ${esc(p.referencia)}` : "Recoger en el local"}</p>
<p style="margin-top:20px;font-size:12px;color:#888">${aviso} ${esc(local)} emitirá la factura cuando corresponda según las normas de Panamá.<br>Tecnología de DiCyn Marketing.</p>
</div></body></html>`;
  const texto = [`${local} · Comprobante del pedido #${p.numero} · ${fecha}`, "", ...filas.map(([a, b]) => `${a}: ${b}`), `Total: ${dinero(p.total)}`, "", aviso].join("\n");
  return { para: p.correo, asunto: `${local} · Comprobante de tu pedido #${p.numero}`, html, texto };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "Método no permitido." });

  const nombreProv = (Deno.env.get("EMAIL_PROVIDER") || "resend").toLowerCase();
  const enviar = PROVEEDORES[nombreProv];
  if (!enviar) return json(500, { error: `Proveedor de correo desconocido: ${nombreProv}` });
  if (nombreProv === "resend" && (!Deno.env.get("RESEND_API_KEY") || !Deno.env.get("EMAIL_FROM"))) {
    return json(500, { error: "Faltan los secrets RESEND_API_KEY y EMAIL_FROM." });
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, claveSecreta(), { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: filas, error } = await db.rpc("tomar_correos_pendientes", { p_max: 20 });
  if (error) return json(500, { error: "No se pudo leer la cola de correos." });

  let enviados = 0, fallidos = 0;
  for (const f of filas ?? []) {
    const { data: p } = await db.from("pedidos").select("*").eq("id", f.pedido_id).maybeSingle();
    if (!p?.correo) continue;
    const { data: suc } = await db.from("sucursales").select("restaurante_id, zona_horaria").eq("id", p.sucursal_id).maybeSingle();
    const { data: r } = suc ? await db.from("restaurantes").select("nombre").eq("id", suc.restaurante_id).maybeSingle() : { data: null };
    try {
      await enviar(armar(p, r?.nombre ?? "Tu pedido", suc));
      enviados++;
    } catch (e) {
      fallidos++;
      console.error("enviar-comprobante", e);
    }
  }
  return json(200, { enviados, fallidos });
});
