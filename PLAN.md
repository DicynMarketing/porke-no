# Porké No? · Plan de trabajo (en este orden)

Pasos 1 al 11: hechos en la versión 0.10.0 (falta lo de Supabase, ver supabase/README.md). Cada paso se termina, se prueba y se entrega con su versión y con lo que haya que hacer en Supabase antes de pasar al siguiente.

| # | Qué | Para quién | Detalle |
|---|-----|-----------|---------|
| 1 | **Ley 81: botón "Eliminar mi cuenta"** | Cliente | Borra de verdad los datos del cliente (cuenta, direcciones, sellos, cupones) y deja los pedidos sin datos personales. Textos reales de Privacidad y Términos a nombre del restaurante. |
| 2 | **Respaldo automático gratis** | Dueño | Copia diaria de la base de datos, cifrada con contraseña, guardada en GitHub. |
| 3 | **Reporte de ventas** | Solo admin | Ventas de hoy, la semana y el mes; productos más vendidos; por método de pago; por motorizado. |
| 4 | **Pausar pedidos con un botón** | Admin → cliente | El admin pone "en espera" y el cliente ve un aviso del tipo "Tu pedido se tomará en breve". |
| 5 | **Aceptar e imprimir el pedido con un clic** | Admin → cliente | Botón "Aceptar pedido": al cliente le aparece "Pedido tomado" y en el restaurante se imprime la comanda automáticamente. |
| 6 | **Repetir mi último pedido** | Cliente | Un solo toque vuelve a llenar el carrito. |
| 7 | **Ver al motorizado en el mapa** | Cliente | Ubicación en vivo mientras llega el pedido. |
| 8 | **Programar pedido** | Cliente | Elegir una hora (ej. desayuno a las 7:30 a.m.). |
| 9 | **Notificaciones de promociones** | Admin → clientes | Aviso a los clientes que aceptaron recibirlas cuando hay descuento o combo. |
| 10 | **Recibos por correo** | Cliente | Con Resend (plan gratis; se confirma el precio antes de activarlo). |
| 11 | **Aviso de errores** | DiCyn | Sentry: avisa si algo falla en el teléfono de un cliente. |
| 12 | **Fotos que faltan** | — | Papas Locas de Pollo, Empanadas y Emparedado de jamón (las manda el dueño). |
| 13 | **Tarifas de delivery por zonas** | Cliente | Precio según el punto del mapa. Hoy: $2.00 (centro de Aguadulce y Pocrí). Falta la lista por barrio. |
| 14 | **Quitar el código viejo del prototipo** | — | Canal ntfy.sh y PIN de prueba. |
| 15 | **Pasar todo a la dirección principal** | — | Solo cuando el dueño lo autorice. |

Descartado: regalo de cumpleaños (se presta a fechas falsas y cuentas repetidas).
