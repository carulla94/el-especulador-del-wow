# Trabajar en El Especulador del WoW

## Acceso y ramas

Repositorio: `https://github.com/carulla94/el-especulador-del-wow`.

El repositorio es público: cualquiera puede leer el código, pero para subir ramas el propietario debe invitar al usuario de GitHub del compañero en **Settings > Collaborators**. No hace falta compartir contraseñas de GitHub, Cloudflare o de la app. Una invitación de código permite trabajar en el proyecto; no concede por sí sola la contraseña de acceso a la cartera.

Clona el repositorio una vez aceptada la invitación:

```text
git clone https://github.com/carulla94/el-especulador-del-wow.git
cd el-especulador-del-wow
git switch -c mejora/nombre-del-cambio
npm install
```

`carulla94` y `yjaviy` pueden subir directamente a `main` y publicar sin pedir autorización, con o sin pull request. El resto usa una rama por cambio y abre una pull request con el problema, la solución y las comprobaciones realizadas, y revisa el diff antes de fusionar. **Un cambio en `main` ejecuta el flujo de Cloudflare y puede actualizar la app real**, incluidos sus cambios de almacenamiento. No renombres `Portfolio`, el Worker o sus migraciones para pruebas. El flujo de GitHub Pages se ejecuta manualmente desde Actions.

## Entorno

- Node.js 24.16.0 es la versión de los flujos; mínimo 22.13 para las pruebas que usan SQLite de Node.
- Python 3.10 o superior para el sincronizador y sus pruebas; los flujos usan Python 3.13.
- `npm install` añade Wrangler para el desarrollo y despliegue de Cloudflare. La aplicación no tiene dependencias de ejecución npm.

```text
npm test
python -m unittest discover -s pc_sync -p "test_*.py" -q
```

## Revisar la edición de GitHub Pages

```text
npm run build:pages
python -m http.server 8000 --bind 127.0.0.1 --directory dist-pages
```

Abre `http://127.0.0.1:8000/`. Para comprobar también una ruta de proyecto, inicia el servidor en la raíz del repositorio sin `--directory` y abre `http://127.0.0.1:8000/dist-pages/`. Las importaciones, assets y descargas deben funcionar en ambas rutas.

Pages guarda los datos en IndexedDB y no llama al backend de Cloudflare. Usa datos de prueba y conserva copias JSON. La misma cartera no se comparte automáticamente entre localhost, GitHub Pages, Cloudflare ni otros dispositivos. No interpretes el modo local como una cuenta con autenticación.

## Revisar la edición de Cloudflare

```text
npm run dev
npm run check:deploy
```

Para entrar en desarrollo, configura una contraseña de prueba de al menos 16 caracteres mediante `.dev.vars`, usando la clave `OWNER_PASSWORD`. Ese archivo está excluido de Git. Usa exclusivamente credenciales de prueba locales. Wrangler indica la URL del servidor de desarrollo. La base de desarrollo local es independiente de producción; no ejecutes operaciones remotas sobre la cartera real para probar una interfaz.

No publiques con `npm run deploy` sin revisar destino, bindings y migraciones; salvo `carulla94` y `yjaviy`, hace falta además la autorización del propietario. No escribas la contraseña de producción en el repositorio, una captura, un issue o un log. No entregues la clave `CLOUDFLARE_API_TOKEN` a pasos de instalación, pruebas o código procedente de una pull request no revisada.

## Directorios

| Ruta | Responsabilidad |
| --- | --- |
| `public/` | Interfaz y estilos compartidos. En Cloudflare la app pide la contraseña del propietario y el panel de la hermandad, una clave personal. |
| `src/engine.mjs` | Cálculos de mercado, inventario FIFO y formato de copias. |
| `src/auctioneer.mjs` | Lectura restringida de SavedVariables de Auctioneer y del puente. |
| `src/worker.mjs` | Autenticación, API y coordinación de la cuenta en Cloudflare. |
| `src/storage.mjs` | Persistencia SQLite del Durable Object. |
| `src/guild.mjs` | Mercado de la hermandad: Durable Object `GuildMarket`, claves de miembros, envíos del sincronizador (formatos 1 y 2), huecos por observador, resúmenes y CSV. |
| `src/especular.mjs` | Reglas «Especular v1» (chollos, flips, balances, días de la semana), gemelas del `Spec.lua` del addon. La construcción la copia a `public/especular.js`. |
| `test-vectors/` | Contrato compartido con el addon (`especular-v1.json`); no se edita: un cambio de reglas va en un archivo `-v2` nuevo. |
| `public/hermandad.*` | Panel de la hermandad (`/hermandad`): página, estilos y JavaScript con gráficos SVG propios. |
| `pages/` | Persistencia y adaptación de la edición local para Pages. |
| `scripts/build-pages.mjs` | Artefacto estático `dist-pages/`, sin secretos ni datos de usuario. |
| `addon/EspeculadorBridge/` | Puente experimental para el cliente real del juego. |
| `pc_sync/` | Envío opcional de archivos desde el PC a la cuenta en Cloudflare. |
| `test/` | Pruebas del motor, importadores, almacenamiento, transporte, mercado de la hermandad y su panel. |
| `test/fixtures/v06/` | Copias exactas de los datos de prueba compartidos de la 0.6.0 (ver «Contratos de la 0.6.0»), fijadas por su SHA-256 en cada prueba. No se editan a mano. |
| `src/timing.mjs` | «Cuándo vender»: precios y ventas estimadas por día de la semana y franja de 4 horas (hora de España). |
| `addon/OroHermandad/` | El addon Oro de Hermandad. `CAMBIOS.md` tiene las notas de cada versión (`## X.Y.Z (AAAA-MM-DD)`). |
| `scripts/build-oro-hermandad.mjs` | El zip del addon: el TOC, los `.lua` que lista, `LEEME.md` y `CAMBIOS.md`. Tiene que salir igual que el de CurseForge. |
| `.pkgmeta` | Cómo empaqueta el addon BigWigsMods/packager para CurseForge. Una carpeta o un archivo nuevo en la raíz va también en su `ignore` (lo comprueba la pull request). |
| `test/fixtures/relay/` | Copias exactas de los datos de prueba de la retransmisión que comparten el addon (`test-lua/fixtures/relay/`) y el subidor (`pc_sync/fixtures/relay/`), y `guild-v1.mjs`, el `src/guild.mjs` anterior a la 0.4 (solo cambia su `import`) para probar que una base escrita por él sobrevive. No se editan a mano. |
| `.github/workflows/` | Validación y publicación de cada edición: `oro-hermandad.yml` (pruebas del addon y de la publicación y empaquetado de prueba en cada cambio del addon y en cada pull request que no toque solo la web o el subidor), `subidor-windows.yml` (el subidor para Windows), `publicar-oro-hermandad.yml` (las versiones, solo a mano). |

## Retransmisión de la hermandad (relay-v1)

Desde la 0.4 cada addon comparte sus escaneos completos con la hermandad por el canal oculto de los addons (mensajes `P3` y `Q3` del prefijo `OroHerm`) y los PC con el subidor los envían al panel como observadores aparte (envío formato 2). Reglas para no romperlo:

- Los formatos de los mensajes, el código de observador y el envío formato 2 son un contrato entre `addon/OroHermandad`, `pc_sync/hermandad.py` y `src/guild.mjs`, con los mismos datos de prueba en los tres. Un cambio incompatible lleva un nombre nuevo (`P4`, `Q4`, formato 3), nunca un cambio de los actuales; el panel sigue aceptando el formato 1 de los subidores 0.3.
- Privacidad: los nombres de los personajes nunca salen del juego. Cada personaje se identifica con un código de 8 cifras hexadecimales (FNV-1a de 32 bits del reino y nombre de la hermandad y del personaje), calculado por quien recibe el mensaje a partir del remitente que da el juego. Ese código es seudónimo, no anónimo: quien conozca la lista de la hermandad podría calcularlo. No lo muestres en el panel ni lo escribas en registros, y no añadas al envío nada que no esté en el contrato. Quien no quiera compartir escribe `/oro compartir off`.
- En el servidor, la columna `member_id` de `guild_obs_day` y `guild_obs_point` es el hueco del observador: el id del miembro para sus propios personajes (también las filas anteriores a la 0.4) o `1000000000 + n` para un compañero retransmitido. Los agregados se calculan por persona (un hueco retransmitido vinculado a un miembro es ese miembro).
- Los motivos de `skippedObservers` también son contrato: `LIMITE_DE_OBSERVADORES` (el panel está lleno), `ENVIO` (no cabía en ese envío: el subidor vuelve a enviar enseguida) y `CUOTA` (se acabó la parte del día para compañeros: el subidor vuelve a enviar pasada la medianoche UTC). Los compañeros entran por turnos, primero el que lleva más tiempo sin guardarse.
- Desde la 0.6.0 un `P3` lleva también la venta estimada: el campo 8 de la cabecera es `dt` (segundos entre los dos escaneos, en base 36) y cada objeto lleva un quinto subcampo con las unidades vendidas (vacío: sin venta). Es el mismo `P3`: los addons 0.4 y 0.5 ignoran los campos que sobran. Una respuesta de recuperación lleva como mucho 28 mensajes (dos escaneos de 14 partes, el peor caso con ventas); lo que no cabe va en la siguiente.
- `Core.lua` llama a `Relay.lua` solo a través de `relayCall` (tras actualizar con solo un `/reload`, el juego aún no carga `Relay.lua` y todo lo demás debe seguir funcionando).
- Los cambios de la base de la hermandad son aditivos y los aplica el propio Durable Object (`GuildStore.migrate`, marcado en `guild_meta.schema`), sin migraciones de wrangler. Si añades otro, sigue el mismo patrón y amplía la prueba de `test/guild-relay.test.mjs` que abre una base escrita por la versión anterior.

## Contratos de la 0.6.0

El addon, el subidor y el panel comparten estos contratos, con los mismos datos de prueba en las tres partes (originales en el diseño de la 0.6.0, copias exactas en `test-lua/fixtures/v06/`, `pc_sync/fixtures/v06/` y `test/fixtures/v06/`, cada una fijada por su SHA-256). Un cambio de contrato lleva datos de prueba con otro nombre o versión, nunca la edición de una copia.

| Id | Contrato | Quién lo produce → quién lo lee | Datos de prueba |
| --- | --- | --- | --- |
| C1 | Punto `t,lo,qty,qty5[,dt,sold]` con la venta estimada opcional; unión de puntos del mismo momento | addon → subidor → panel (`mergePoint`) | `points-v2.json` |
| C2 | Ventas en los `P3` (campo 8 = `dt`, quinto subcampo = unidades) | addon ↔ addon | `p3-samples.json` |
| C3 | Envío: `sold: [[t, dt, unidades]]` por serie, solo de puntos enviados | subidor → panel (`validateUpload`) | `hist-v060.lua` → `upload-v060.json` |
| C4 | Respuesta de `/api/guild/sync`: `estado.mercados[]`, `subidor.ultima`, `markets[].sold` | panel → subidor | `sync-response-v060.json` |
| C5 | Franja de hora de España (CET/CEST) de una hora unix | addon (`Spec.MadridSlot`) = panel (`localSlot`) | `madrid-slots.json` |
| C6 | `Spec.InferSold` (ventas entre dos escaneos de la misma persona) | solo el addon | `sold-inference.json` |
| C7 | Aviso del subidor para el addon (formato 2) | subidor → addon | `marker-v2.json`, `marker-v2/*.lua` |
| C8 | `buildTiming` `cuando-vender-2` (celdas de 12 columnas, mediciones repetidas unidas, días con venta por fecha de España: en verano, de 00:00 a 01:00 ya es el día siguiente, como en el addon) | panel | `timing-v2.json` |
| C9 | Líneas de versión: `## Version:` del TOC, `Core.VERSION = "X.Y.Z"`, `local version = "X.Y.Z"` (History.lua) y `## X.Y.Z (AAAA-MM-DD)` en `CAMBIOS.md` | addon → flujo de publicación | `test/release-workflow.test.mjs` |
| C10 | Flujo reutilizable `subidor-windows.yml`: salida `version`, artefacto `Subidor_Windows` con `Subidor_Windows.zip`, enlace `releases/latest/download/Subidor_Windows.zip` y la línea del subidor en las notas | subidor → publicación → panel | `test/release-workflow.test.mjs`, `test/hermandad-view.test.mjs` |
| C11 | Consejo de «Cuándo vender» (`advice(blocks)`: 3 mediciones en 2 días por franja, sin la más grande) | addon (`Timing.Advice`) = panel (`timingAdvice`) | `timing-advice.json` |

## Publicar una versión de Oro de Hermandad

Lo hacen siempre personas, nunca un asistente ni un flujo por su cuenta: crear el proyecto y la clave de CurseForge, elegir la licencia, fusionar y lanzar «Publicar Oro de Hermandad». Cada cambio en `main` publica el panel enseguida (`deploy-cloudflare.yml`), así que el orden importa: se prueba desde la pull request, se fusiona y se publica la versión justo después.

1. **Licencia:** «Todos los derechos reservados» (decidido para la 0.6.0). Al crear el proyecto en CurseForge, elige «All Rights Reserved». Para cambiarla más adelante, ver «Licencia».
2. **Cuenta y proyecto de CurseForge** (con la cuenta de `carulla94` o la de `yjaviy`, da igual cuál; quien lo cree puede añadir al otro como miembro del proyecto): https://authors.curseforge.com/#/projects/create/choose-game → World of Warcraft → Addons → **Forever**. Nombre «Oro de Hermandad», resumen (≤ 256 caracteres): «Ideas para ganar oro en WoW Forever con tus profesiones y tu hermandad: escanea la subasta con hora, te dice a qué hora se vende mejor y comparte los precios con tu hermandad.» Descripción: qué hace, cómo se usa, «Qué compartes con tu hermandad» (solo precios y unidades de la lista fija, código de 8 cifras en vez del nombre, `/oro compartir off`), y este párrafo: «El addon funciona solo. El panel web y su subidor para Windows son la herramienta de nuestra hermandad (el código está en GitHub y cualquiera puede montar el suyo); no van en esta descarga.» Requisitos (WoW Forever 1.60.1; Auctionator opcional) y al final el enlace al GitHub. Una línea en inglés al principio: «Gold-making helper for WoW Forever (Spanish UI). Optional guild price sharing over addon messages; no character names are shared.» Logo propio de 400×400 y una captura **sin nombres** de personajes, hermandad ni vendedores.
3. **Número del proyecto** → pull request con `## X-Curse-Project-ID: <número>` en `addon/OroHermandad/OroHermandad.toc`. Sin esa línea el flujo publica en GitHub y se salta CurseForge. Hecho: el proyecto es el **1823630** (https://authors.curseforge.com/#/projects/1823630) y su línea ya está en el TOC.
4. **Clave:** https://authors.curseforge.com/#/settings/api-tokens, con una cuenta que pueda subir archivos al proyecto. Nunca en el chat ni en el código.
5. **GitHub** (solo `carulla94`: el repositorio es de una cuenta personal y ahí solo el dueño puede crear entornos y secretos; los colaboradores no tienen rol de administrador). Lo más sencillo es que el proyecto de CurseForge tenga a `carulla94` como miembro con permiso para subir archivos y que él cree su propia clave (paso 4), así ninguna clave pasa de una persona a otra: Settings → Environments → `publicar-addon` → secreto `CF_API_TOKEN`; reglas: rama `main` y etiquetas `oro-hermandad-v*` (opcional: revisor obligatorio). Settings → Actions → General → Workflow permissions → «Read and write» si `gh release` falla con «Resource not accessible by integration».
6. **Probar antes de fusionar**, con los artefactos de la propia pull request (pestaña Actions): `OroHermandad` (de `oro-hermandad.yml`) en el juego, con las comprobaciones de la 0.6.0, y `Subidor_Windows` (de `subidor-windows.yml`) en un PC con Windows 11 limpio. Empieza quien tiene el subidor: addon y subidor a la vez.
7. **Cambiar en `addon/OroHermandad/LEEME.md` las líneas «sin probar»** por lo que se ha comprobado de verdad (pull request pequeña o en la misma).
8. **Fusionar la pull request:** al fusionar, el panel se publica solo (no hay que hacer nada con Cloudflare). Desde ese momento el panel enlaza el subidor nuevo, que aún no existe: haz el paso 9 enseguida.
9. **Publicar en la misma sesión, justo después de fusionar:** Actions → «Publicar Oro de Hermandad» → Run workflow → `main` → `0.6.0`. La versión de GitHub sale con `OroHermandad.zip` y `Subidor_Windows.zip`; luego se sube a CurseForge. Si solo falla CurseForge: «Re-run failed jobs». Si falla solo la compilación de Windows, la versión sale con el subidor anterior sin cambios (el addon no espera); «Re-run failed jobs» la vuelve a compilar y, si sale, cambia el subidor de la versión, sin subir otra vez a CurseForge ni a Wago (cada uno mira si ya se subió en otra ejecución o intento de este flujo en el mismo commit; tampoco un «Run workflow» nuevo de una versión ya publicada la sube otra vez). Con `reusar_subidor` se salta esa compilación a propósito. La primera versión 0.6.0 necesita compilarlo (las anteriores no tienen subidor que reutilizar). Cancelar la ejecución detiene la publicación (lo ya publicado se queda); si la compilación de Windows se queda sin tiempo y no sale la versión, lánzalo otra vez con `reusar_subidor` o espera a arreglarla.
10. **Avisar a la hermandad en este orden:** quien tiene el subidor actualiza primero el addon y el subidor (si no, el panel no recibe las ventas); después, el resto actualiza el addon.
11. **Esperar la revisión** de CurseForge (horas o pocos días). Luego, en la hermandad: app de CurseForge → WoW → instalación Forever → «Oro de Hermandad» → Instalar.
12. **Solo el subidor (versiones 0.6.x):** fusionar el código → Actions → «Publicar Oro de Hermandad» con `solo_subidor` (sube el zip nuevo a la última versión y cambia la línea del subidor en sus notas; falla si la versión no es más nueva) → **después**, una pull request de una línea que sube `LATEST_UPLOADER` en `src/guild.mjs`, para que las ventanas avisen solo cuando el zip ya está.
13. (Opcional) **Wago:** proyecto Forever 1.60.1, `## X-Wago-ID:` en el TOC y secreto `WAGO_API_TOKEN` en el mismo entorno.
14. (Opcional, para no adelantar textos) los campos nuevos del servidor (`sold` en el envío, columnas `dt` y `sold`, `estado` y `subidor` en la respuesta) son compatibles hacia atrás y pueden ir en una pull request anterior sin cambios de textos del panel.

Campos del TOC (`addon/OroHermandad/OroHermandad.toc`) para las tiendas: `## X-Website:` (ya está); `## X-Curse-Project-ID: 1823630` (paso 3); opcionales, `## X-Wago-ID:` (paso 13) y `## X-License:` (ver «Licencia»). Las versiones van escritas, sin `@project-version@`: el flujo comprueba que el TOC, `Core.VERSION`, `History.lua` y `CAMBIOS.md` dicen lo mismo que la etiqueta (C9). Una versión es `X.Y.Z` o, de prueba, `X.Y.Z-alphaN` o `X.Y.Z-betaN` (por ejemplo `0.6.1-beta1`): sale como «prerelease» en GitHub (nunca es la «última versión» que enlaza el panel) y como alpha o beta en CurseForge y Wago. El flujo no acepta otra forma (`0.6.1-rc1`, `0.6.1beta1`), porque GitHub y las tiendas no estarían de acuerdo en si es de prueba.

La línea del subidor en las notas de cada versión es un contrato del flujo: `Subidor para Windows X.Y.Z: Subidor_Windows.zip (SHA-256 …)`, o `Subidor para Windows X.Y.Z (sin cambios): …` cuando se reutilizó el anterior. No la cambies a mano: la siguiente publicación la usa para comprobar el zip que reutiliza.

**Probar el empaquetador en local, solo en una copia desechable.** El empaquetador copia solo lo que Git conoce, así que en tu carpeta de trabajo, con cambios sin confirmar, dejaría fuera archivos nuevos (por ejemplo `CAMBIOS.md` o un `.lua` nuevo). Copia los archivos a una carpeta temporal fuera del repositorio y allí haz `git init && git add -A && git commit -m prueba`, luego `printf -- '- prueba\n' > .notas-version.md` y `bash ruta/a/packager/release.sh -d -u -n "{package-name}-{project-version}:{project-version}"`, y compara el zip de `.release/` con el de `node scripts/build-oro-hermandad.mjs` (descomprimidos, `diff -r`). Nunca lo lances con una clave de CurseForge o Wago ni sin `-d`.

## Licencia

El repositorio no tiene archivo de licencia: es «Todos los derechos reservados» (el código se puede leer, pero no copiar ni reutilizar sin permiso), decidido para la 0.6.0; en CurseForge, «All Rights Reserved». Si un día los dueños, con quien ha aportado código, prefieren una libre:

- **MIT** (u otra libre): se añade `LICENSE` en la raíz con el texto de la licencia, `## X-License: MIT` en el TOC del addon si se quiere, y se cambia la licencia del proyecto en CurseForge.

Un `LICENSE`, `LICENSE.md` o `LICENSE.txt` en la raíz no entra en el zip del addon: está en el `ignore` de `.pkgmeta`. Ningún cambio automático añade una licencia.

## Antes de proponer un cambio

1. Ejecuta las pruebas que correspondan al comportamiento modificado.
2. Si toca la interfaz o Pages, construye `dist-pages` y comprueba navegación, importación, movimientos, recarga y copia JSON.
3. Si cambia la estructura de datos, verifica que las copias existentes siguen restaurándose y que un fallo de escritura no borra el estado anterior.
4. No subas bases de datos, SavedVariables personales, copias de cartera, archivos `.env`/`.dev.vars`, ZIP generados ni claves. Los cambios de permisos, publicación del repositorio y migraciones de producción requieren revisión explícita de `carulla94` o `yjaviy`.
5. Documenta las limitaciones reales: los precios ofertados no son ventas confirmadas, y el puente necesita validación dentro del juego.
