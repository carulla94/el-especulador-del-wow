# Instalar Oro de Hermandad

Addon de WoW Forever que te dice cómo ganar oro: qué vender, fundir, fabricar o recoger y qué le sirve a tu hermandad. Es nuevo y aún no se ha probado dentro del juego.

## 1. Instala Auctionator

Pone los precios. Con la app de CurseForge: busca **Auctionator** en WoW Forever y pulsa **Instalar**.

## 2. Consigue OroHermandad.zip

Pídeselo a quien te pasó esta guía (por Discord, por ejemplo).

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

Con acceso al repositorio (es privado): pestaña **Actions** → «Comprobar addon Oro de Hermandad» → última ejecución en verde de la rama `main` (o de `oro-hermandad`, mientras no se haya fusionado) → **OroHermandad.zip**. Si no aparece (caduca con el tiempo), pulsa **Run workflow** (solo sale cuando el flujo ya está en `main`). O créalo con `node scripts/build-oro-hermandad.mjs` (sale en `dist-addon/`).
