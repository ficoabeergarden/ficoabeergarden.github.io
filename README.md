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
- **Juega y gana**: "Llena el jarro", 3 jarros, meta 240 puntos. Mantener presionado para servir y soltar en la línea. Definir qué premio se canjea en caja.
