# Instalar Oro de Hermandad

Addon de WoW Forever que te dice cómo ganar oro: qué vender, fundir, fabricar o recoger, qué le sirve a tu hermandad y, desde la 0.6.0, a qué hora se vende mejor cada material. Escanea la subasta él mismo: **Auctionator ya es opcional**. Probado fuera del juego con las pruebas automáticas; las comprobaciones dentro del juego están en la lista de la versión.

## 1. Instala el addon

**Con la app de CurseForge** (en cuanto esté publicado allí): World of Warcraft → instalación **Forever** → busca **Oro de Hermandad** → **Instalar**. La app lo actualiza sola.

**A mano, con el zip** (si aún no está en CurseForge o no usas la app):

1. Descarga `OroHermandad.zip` de la [última versión](https://github.com/carulla94/el-especulador-del-wow/releases/latest/download/OroHermandad.zip) (la 0.6.0 en concreto: [oro-hermandad-v0.6.0](https://github.com/carulla94/el-especulador-del-wow/releases/download/oro-hermandad-v0.6.0/OroHermandad.zip); todas las versiones, en [Releases](https://github.com/carulla94/el-especulador-del-wow/releases)). Si no puedes abrir el enlace, pídeselo a quien te pasó esta guía.
2. En Battle.net, elige World of Warcraft y la versión **Forever**.
3. Pulsa la rueda dentada junto a **Jugar** y luego **Mostrar en el explorador**.
4. Entra en `_forever_` → `Interface` → `AddOns`. Si alguna carpeta no existe, créala.
5. Descomprime ahí el zip.

Tiene que quedar `AddOns\OroHermandad\OroHermandad.toc`. Si ves `OroHermandad\OroHermandad\...`, sube la carpeta interior un nivel.

## 2. Actívalo

En la pantalla de personajes, pulsa **Menú** (arriba) y luego **Addons** (o **Accesorios**, según el idioma del juego; *AddOns* en inglés). Deja marcado **Oro de Hermandad**. Si pone «No actualizado», marca arriba de la lista **Cargar addons antiguos** (o **Cargar accesorios antiguos**). Si sale un aviso, elige cargar los addons (no «Desactivar») y pulsa **Aceptar**.

**Auctionator (opcional):** no hace falta. Si ya lo usas, déjalo: el addon también lee sus precios y su historial, y si en sus opciones escanea la subasta entera al abrirla, usa ese escaneo en vez de pedir otro.

## 3. Primer uso

1. Abre la subasta: la ventana del addon sale a su lado con la fila «Escaneo de la subasta: listo (unos segundos).» y el botón **Escanear**. Púlsalo: tarda unos segundos y no se nota en el juego.
2. Para que escanee solo cada vez que abres la subasta: en las opciones (Esc → Opciones → Addons → Oro de Hermandad), «Escanear la subasta» → **Escanear cada vez que abro la subasta**, o escribe `/oro escanear auto`.
3. **La pareja:** para saber qué se vende, escanea dos veces con entre 30 min y 2 h de diferencia (por ejemplo al llegar a la ciudad y antes de irte). El addon te lo propone en la ventana. La subasta solo deja un escaneo completo cada 15 min por cuenta.
4. Abre **una vez cada profesión** para que el addon aprenda tus recetas.
5. Pulsa el **botón de la moneda** junto al minimapa o escribe `/oro`. `/oro cuando` (o el botón **Cuándo vender**) te dice a qué hora se vende mejor.

En la ventana eliges el modo: **Tranquilo** mientras subes de nivel, **A tope** en sesiones solo para hacer oro. Cuantos más del grupo lo usen, mejores son las sugerencias de hermandad.
El tercer modo, **Especular**, busca chollos para comprar y revender: necesita 7 días de escaneos para el precio normal y 10 para los chollos (12 en Tranquilo).

**Precios compartidos:** al terminar un escaneo completo, el addon comparte con tu hermandad, sin que se vea en el chat, el precio más bajo y las unidades de la lista fija y una estimación de cuántas se vendieron entre dos escaneos. Los nombres de los personajes nunca salen del juego: el panel solo recibe un código de 8 cifras por personaje (seudónimo, no anónimo). Los nombres de los vendedores que ve la subasta nunca se guardan ni se envían, y tus propias ventas se quedan en tu PC. No hay que hacer nada; con `/oro compartir off` dejas de compartir los tuyos.

## 4. Subidor para Windows (solo 1 o 2 personas de la hermandad)

Con 1 o 2 compañeros que tengan el subidor en su PC, el panel de la hermandad recoge lo de todos. Se descarga del panel de la hermandad, en **Descargas** → «Subidor para Windows»:

1. Clic derecho en el zip → Propiedades → marca «Desbloquear» → Aceptar.
2. Extrae la carpeta.
3. Abre «Abrir subidor.cmd» (la primera vez te ofrece un acceso directo en el escritorio).

Es una ventana, **«Oro de Hermandad · Subidor»**, que sube sola mientras está abierta (no hace falta instalar Python). La primera vez, sal del juego del todo y vuelve a entrar para que el addon vea que ese PC sube precios. WoW solo guarda los precios al recargar o al salir: en ese PC la ventana del addon tiene el botón **Guardar y subir** (o `/oro guardar`) para que los precios lleguen al panel en segundos.

## Actualizar

- **Primero, quien tiene el subidor:** actualiza el addon y el subidor a la vez (si no, el panel no recibe las ventas). Después, el resto actualiza el addon.
- Con la app de CurseForge, se actualiza sola. A mano: borra la carpeta `OroHermandad` y repite el paso 1.
- Después **sal del juego del todo y vuelve a entrar**: un `/reload` no carga los archivos nuevos de una versión (la 0.6.0 trae dos, `Scanner.lua` y `Timing.lua`; hasta entonces `/oro escanear` y `/oro cuando` lo recuerdan). El manual va dentro: `OroHermandad/LEEME.md`, y los cambios, en `OroHermandad/CAMBIOS.md`.

## Si algo falla

Escribe `/console scriptErrors 1` en el chat, repite lo que hacías y pasa el texto del error al grupo. `/oro sondeo` da un diagnóstico para copiar (sin nombres de personajes ni tu oro).

## Para quien reparte el zip

Cada versión se publica en [Releases](https://github.com/carulla94/el-especulador-del-wow/releases) con la etiqueta `oro-hermandad-vX.Y.Z` y dos archivos: `OroHermandad.zip` (el addon) y `Subidor_Windows.zip` (el subidor). La publica una persona con **Actions → Publicar Oro de Hermandad**, que después sube el addon a CurseForge. Con permiso de escritura, el zip de cada cambio también está en la pestaña **Actions** → «Comprobar addon Oro de Hermandad» → última ejecución en verde → **OroHermandad.zip**, o se crea con `node scripts/build-oro-hermandad.mjs` (sale en `dist-addon/`).
