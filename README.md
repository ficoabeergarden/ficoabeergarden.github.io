# Ficoa Beer Garden — Sitio

Tres archivos únicos y autocontenidos (HTML, CSS, JS e imágenes embebidas). No necesitan build ni servidor. Los tres van en la **misma carpeta** del repo, porque se enlazan entre sí.

- `index.html` — landing (agenda, reservas, juego, cómo llegar)
- `carta.html` — la carta completa
- `domicilio.html` — pedidos a domicilio: el cliente arma el pedido y se abre WhatsApp con todo escrito

## Publicarlo en GitHub Pages

1. GitHub → botón **+** arriba a la derecha → **New repository**.
2. Nombre: `beergarden`. Público. Sin README.
3. En el repo vacío: **uploading an existing file** → arrastra `index.html`, `carta.html`, `domicilio.html` y `README.md` → **Commit changes**.
4. **Settings → Pages** → Source: `Deploy from a branch`, branch `main`, folder `/ (root)` → **Save**.
5. En 1–2 minutos queda en `https://<tu-usuario>.github.io/beergarden/`.
6. Genera el QR con esa URL y pégalo en las mesas.

## Actualizarlo después

**Add file → Upload files** en la raíz del repo → arrastra los archivos nuevos (mismo nombre = los reemplaza) → **Commit changes**. Recarga con Cmd+Shift+R.

## Pedidos a domicilio

El botón "Pedir a domicilio" de la landing abre `domicilio.html`. El cliente elige platos con los botones + / –, escribe nombre, dirección, referencia y forma de pago, y el botón inferior abre WhatsApp al **098 455 1000** con el pedido, el total y los datos ya redactados. No cobra en línea: el envío y el tiempo se confirman por el chat.

Menú de domicilio incluido (precios de la carta): alitas y costillitas, hamburguesas, pizzas, sánduches, entradas, litro de cerveza y gaseosa. Si cambia un precio o quieres agregar platos, avísame y lo actualizo.

## Qué falta definir

- **Costo de envío y zonas de cobertura**: hoy la página dice que se confirma por WhatsApp.
- **Agenda**: los flyers son los actuales; hay que cambiarlos cada semana.
- **Juega y gana**: "Atrapa la espuma", 30 segundos. Mueve el jarro para atrapar gotas de cerveza y esquivar las patrullas. Meta: 50 de 56 gotas sin chocar 3 patrullas. Definir qué premio se canjea en caja.


## Eventos y entradas

1. En Supabase → SQL Editor ejecuta `supabase/eventos.sql` (después de beerclub.sql).
2. `agenda.html`: el cliente elige entradas, ve los datos para transferir y recibe sus QR cuando el staff confirma.
3. `staff.html` → pestaña **Eventos**: crear evento (admin), confirmar pagos, reemitir QR, y **Puerta** para escanear.
4. Antes de abrir puertas toca **Descargar lista del evento** con wifi: así la puerta valida sin internet y sincroniza al volver la señal.
5. `sw.js` guarda las páginas en el teléfono para que abran sin conexión.
