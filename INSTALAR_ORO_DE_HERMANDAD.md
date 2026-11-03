# Instalar Oro de Hermandad

Addon de WoW Forever que te dice cómo ganar oro: qué vender, fundir, fabricar o recoger y qué le sirve a tu hermandad. Es nuevo y aún no se ha probado dentro del juego.

## 1. Instala Auctionator

Pone los precios. Con la app de CurseForge: busca **Auctionator** en WoW Forever y pulsa **Instalar**.

## 2. Descarga OroHermandad.zip

Descárgalo de la [versión 0.2.1](https://github.com/carulla94/el-especulador-del-wow/releases/download/oro-hermandad-v0.2.1/OroHermandad.zip) (todas las versiones, en [Releases](https://github.com/carulla94/el-especulador-del-wow/releases)). Si no puedes abrir el enlace, pídeselo a quien te pasó esta guía.

## 3. Descomprímelo en la carpeta AddOns

1. En Battle.net, elige World of Warcraft y la versión **Forever**.
2. Pulsa la rueda dentada junto a **Jugar** y luego **Mostrar en el explorador**.
3. Entra en `_forever_` → `Interface` → `AddOns`. Si alguna carpeta no existe, créala.
4. Descomprime ahí el zip.

Tiene que quedar `AddOns\OroHermandad\OroHermandad.toc`. Si ves `OroHermandad\OroHermandad\...`, sube la carpeta interior un nivel.

## 4. Actívalo

En la pantalla de personajes, pulsa **Menú** (arriba) y luego **Addons** (o **Accesorios**, según el idioma del juego; *AddOns* en inglés). Deja marcados **Oro de Hermandad** y **Auctionator**. Si alguno pone «No actualizado», marca arriba de la lista **Cargar addons antiguos** (o **Cargar accesorios antiguos**). Si sale un aviso, elige cargar los addons (no «Desactivar») y pulsa **Aceptar**.

## 5. Primer uso

1. En la subasta, haz un **escaneo completo** con Auctionator (o activa en sus opciones **escanear al abrir la subasta**).
2. Abre **una vez cada profesión** para que el addon aprenda tus recetas.
3. Pulsa el **botón de la moneda** junto al minimapa o escribe `/oro`.

En la ventana eliges el modo: **Tranquilo** mientras subes de nivel, **A tope** en sesiones solo para hacer oro. Cuantos más del grupo lo usen, mejores son las sugerencias de hermandad.

## Si algo falla

Escribe `/console scriptErrors 1` en el chat, repite lo que hacías y pasa el texto del error al grupo.

Para actualizar, borra la carpeta `OroHermandad` y repite los pasos 2 y 3. El manual va dentro del zip: `OroHermandad/LEEME.md`.

## Para quien reparte el zip

Cada versión se publica en [Releases](https://github.com/carulla94/el-especulador-del-wow/releases) con la etiqueta `oro-hermandad-vX.Y.Z` y el zip adjunto. Con permiso de escritura también está en la pestaña **Actions** → «Comprobar addon Oro de Hermandad» → última ejecución en verde → **OroHermandad.zip**, o se crea con `node scripts/build-oro-hermandad.mjs` (sale en `dist-addon/`).
