# El Especulador del WoW · Cloudflare y GitHub Pages

Aplicación privada para WoW Forever, Europa, PvP y Alianza. Versión cloud 0.3.0.

La interfaz, contabilidad, inventario, cálculos y datos persistentes se ejecutan en Cloudflare Workers con SQLite en un Durable Object. Puedes importar los archivos de Auctioneer desde el navegador o emparejar el sincronizador del PC para enviar sus cambios por HTTPS.

El código está en el repositorio privado [carulla94/el-especulador-del-wow](https://github.com/carulla94/el-especulador-del-wow). La app privada en la nube está en [el-especulador-del-wow.arqcon-cat.workers.dev](https://el-especulador-del-wow.arqcon-cat.workers.dev/). Para trabajar con otra persona, añade su usuario de GitHub como colaborador desde **Settings > Collaborators**; compartir el enlace por sí solo no concede acceso a un repositorio privado. Lee [CONTRIBUTING.md](CONTRIBUTING.md) para el entorno de desarrollo y el flujo de ramas.

## Edición local para GitHub Pages

GitHub Pages sirve archivos estáticos. Esta edición reutiliza los cálculos y los importadores de la app, y guarda la cartera en **IndexedDB de este navegador**. Permite importar manualmente Lua/JSON/AHL1, registrar movimientos, configurar reglas y exportar o restaurar copias JSON. No conecta la cuenta privada de Cloudflare ni envía los archivos importados a un servidor.

Los datos son distintos en cada navegador, perfil, dispositivo y origen. Borrar los datos del sitio, usar navegación privada o perder el perfil puede hacer perder la cartera local. Exporta copias JSON con frecuencia; el sitio no ofrece una contraseña que proteja los datos de otra persona que use ese mismo perfil. La sincronización automática desde el PC y las claves de equipos pertenecen a la edición en Cloudflare. La interfaz de Pages identifica este modo y conserva un enlace a la app en la nube.

```text
npm run build:pages
python -m http.server 8000 --bind 127.0.0.1 --directory dist-pages
```

Abre `http://127.0.0.1:8000/` para revisar el resultado. El directorio `dist-pages` se genera desde una lista limitada de archivos: interfaz, módulos de cálculo e importación, runtime local y ZIP del addon. No incluye el Worker, contraseñas, tokens, cartera ni el sincronizador del PC. No abras el HTML mediante `file://`: los módulos e IndexedDB necesitan un origen HTTP/HTTPS estable.

Para publicar:

1. Comprueba que el plan y la visibilidad del repositorio permiten GitHub Pages. **GitHub Free permite Pages en repositorios públicos; los privados requieren un plan compatible, como GitHub Pro.** Este proyecto permanece privado: no cambies su visibilidad sin autorización del propietario. Que el repositorio sea privado no hace que una página publicada sea privada.
2. En **Settings > Pages > Build and deployment > Source**, selecciona **GitHub Actions**. Este paso debe habilitarse en GitHub; añadir el archivo del flujo no activa Pages por sí solo.
3. Abre **Actions > Publicar edición local en GitHub Pages > Run workflow**, selecciona `main` y ejecuta. El flujo prueba el proyecto, construye `dist-pages` y publica solo ese artefacto con las acciones oficiales de GitHub y su token temporal OIDC. No utiliza la clave de Cloudflare ni necesita secretos propios.
4. Utiliza la URL que confirme el despliegue. Si se publica como sitio de proyecto, la ruta esperada es `https://carulla94.github.io/el-especulador-del-wow/`; la URL solo está disponible cuando Pages está habilitado y el flujo termina correctamente.

La publicación de Pages es manual por diseño. Para publicar cambios, vuelve a ejecutar su flujo después de fusionar la rama revisada en `main`. El flujo de Cloudflare existente sigue publicando la edición en la nube al cambiar `main`.

El flujo independiente **Comprobar Pages con Chromium** prueba el artefacto bajo una ruta de proyecto real. Comprueba la persistencia de ajustes y compras tras recargar usando IndexedDB de Chromium, la descarga de la copia JSON y el fallo claro cuando IndexedDB está bloqueado. También verifica que ese modo no envía peticiones a una API ni a otros servidores. No recibe credenciales de Cloudflare ni publica cambios. Para ejecutarlo en un entorno de desarrollo preparado:

```text
npm install
npm run build:pages
npx playwright install chromium
npm run test:browser
```

Referencias oficiales: [qué es GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages), [crear un sitio y planes compatibles](https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site) y [flujos personalizados para Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages).

## Publicar en tu cuenta

Necesitas Node.js 22.13 o superior para las herramientas de desarrollo. El navegador del usuario no necesita instalar nada. El sincronizador opcional del PC requiere Python 3.10 o superior; no ejecuta el servidor ni hace cálculos de trading.

```text
npm install
npm test
npx wrangler whoami
npx wrangler login
npm run check:deploy
npm run deploy
npx wrangler secret put OWNER_PASSWORD
```

Omite `login` si Wrangler ya tiene sesión. Usa una contraseña exclusiva de al menos 16 caracteres. El secreto se introduce por la entrada interactiva de Wrangler o en Variables y secretos del Worker: **nunca lo escribas en este repositorio**. Hasta configurarlo, la cuenta responde cerrada con 503; solo es visible la página de acceso. No utilices despliegues temporales en una cuenta distinta.

Cloudflare construye los ZIP del sincronizador y del puente mediante `scripts/prepare-downloads.mjs` antes de desplegar. El resto del código de aplicación no necesita paquetes de ejecución externos. Wrangler es una dependencia de desarrollo.

`wrangler.jsonc` conserva el nombre estable del Worker y de su clase `Portfolio`. No cambies esos nombres ni elimines su namespace si quieres mantener los datos. La configuración crea la base SQLite con la migración `v1`.

También puedes conectar este repositorio desde Workers & Pages → Create application → GitHub. Directorio raíz del proyecto; comando de construcción `npm run build`; despliegue `npx wrangler deploy`. Conserva la configuración del repositorio y añade `OWNER_PASSWORD` como secreto del Worker.

## Alternativa: desplegar desde GitHub Actions

El flujo `.github/workflows/deploy-cloudflare.yml` valida y publica esta misma app en tu cuenta de Cloudflare. Usa las acciones oficiales de GitHub para preparar Node.js 24.16.0 y Python 3.13; instala las herramientas del proyecto, ejecuta las pruebas de Node y del sincronizador, construye las descargas y comprueba el paquete de Wrangler antes de publicar.

1. En este repositorio privado, abre **Settings > Secrets and variables > Actions > New repository secret**.
2. Nombre del secreto: `CLOUDFLARE_API_TOKEN`. Guarda ahi la clave de usuario limitada a **Workers Scripts: Edit** para la cuenta de Cloudflare indicada en el flujo. Este paso concede al flujo de GitHub acceso de despliegue a esa cuenta y debe estar autorizado por su titular. Nunca pegues la clave en el codigo, en un issue ni en los logs.
3. Abre **Actions > Validar y publicar en Cloudflare > Run workflow**, selecciona `main` y ejecuta el flujo. Los siguientes cambios en `main` volveran a validar y publicar automaticamente.
4. Comprueba la URL confirmada por Wrangler y configura `OWNER_PASSWORD` como secreto del **Worker en Cloudflare**, con al menos 16 caracteres. No es una variable de construccion ni un secreto que este flujo necesite en GitHub.

Si falta `CLOUDFLARE_API_TOKEN`, las pruebas y la construccion se ejecutan, el despliegue se omite sin error y el resumen indica como habilitarlo. El flujo no recibe eventos de pull requests, solo permite publicar `main`, concede a `GITHUB_TOKEN` permiso de lectura del codigo y serializa los despliegues sin interrumpir una migracion en curso. La clave de Cloudflare solo se entrega a la comprobacion de disponibilidad y al paso de publicacion, despues de las validaciones.

La cuenta de destino esta fijada en `CLOUDFLARE_ACCOUNT_ID`; no se selecciona automaticamente una cuenta distinta. La clave debe permitir las operaciones necesarias en esa cuenta. Si Cloudflare rechaza la creacion inicial por permisos, crea primero el Worker `el-especulador-del-wow` desde el panel con tu sesion habitual y vuelve a ejecutar el flujo. No amplíes permisos ni habilites servicios ajenos a esta app sin revisar el motivo del error.

Referencia oficial: [Cloudflare con GitHub Actions](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/).

## Entrar y traer tus datos

1. Abre la URL que confirme Cloudflare y entra con la contraseña del Worker.
2. En Ajustes puedes restaurar la copia JSON de la versión local. Se recalculan los costes FIFO y los beneficios; no se confía en los resultados declarados por el archivo. Antes de sustituir datos se conserva una copia interna, descargable en `/api/backups/previous` tras iniciar sesión.
3. En Auctioneer puedes importar el histórico `Auctioneer_Stats_OverTime.lua` y las observaciones `EspeculadorBridge.lua`. Selecciona el reino y confirma el mercado. Se conserva cada variante y fecha original.
4. Para envío automático, crea una clave para tu PC. Se muestra una sola vez. Descarga el sincronizador desde esa misma sección, ejecuta `SINCRONIZAR.cmd` e introduce URL, clave, carpeta y reino. La clave no se guarda en el código ni en archivos del programa: permanece en memoria hasta cerrarlo.
5. WoW debe guardar los archivos mediante `/reload` o salida del juego. La nube no puede leer carpetas de tu PC ni forzar escaneos. El sincronizador solo lee y envía los dos archivos compatibles; no compra ni publica.

Las claves del PC solo permiten enviar datos de mercado, no leer movimientos, exportar copias o registrar operaciones. Puedes revocarlas desde la app sin borrar los escaneos ya recibidos.

## Datos y seguridad

- Cuenta única privada con contraseña en un secreto de Cloudflare.
- Sesión firmada de ocho horas, cookie HttpOnly/Secure/SameSite y protección CSRF en escrituras del navegador.
- Límite de intentos de acceso persistente. Cambiar la contraseña o el secreto opcional `SESSION_SECRET` invalida las sesiones anteriores.
- Los tokens del PC se guardan únicamente como hashes; no se incluyen en las exportaciones.
- Estado y copia previa divididos en fragmentos UTF-8 de hasta 512 KiB, con sustitución atómica. No se coloca un JSON grande en una fila que supere el límite SQLite de Cloudflare.
- Esta versión limita el estado de una cuenta a 16 MiB. Es un límite de esta implementación, no la capacidad total de Cloudflare. Si se supera se rechaza la escritura sin borrar los datos existentes; se deberá ampliar el modelo de almacenamiento antes de seguir importando.
- Se conserva la última captura de ofertas y un histórico independiente. Una captura anterior no reemplaza observaciones más recientes. No se borran movimientos ni históricos automáticamente.
- Exporta una copia JSON después de sesiones importantes. No dependas exclusivamente del almacenamiento del navegador: la cuenta está en la base de Cloudflare.

## Alcance de Auctioneer y de las recomendaciones

Compatible con el esquema inspeccionado de NoobyGains/Auctioneer-Forever 12.x. Otros addons llamados Auctioneer o Auctionator no son intercambiables.

El histórico contiene mínimos y máximos por hora; no son ofertas actuales. El puente registra observaciones parciales con su propia fecha por objeto. No hay profundidad al precio mínimo ni ventas confirmadas de terceros. Se propone como máximo una unidad de prueba cuando se cumple el filtro de reventa. El ROI inicial del 20% es editable y no constituye rentabilidad prometida.

La pestaña Estrategia contiene cálculo manual de reventa, fabricación y NPC. No incluye un catálogo de recetas o de precios de vendedores verificado en el juego. El resultado de un desencantado es aleatorio y exige valorar los rendimientos antes de usar una estimación.

El puente sigue siendo experimental y necesita validación dentro del cliente real. Lee su guía en `addon/EspeculadorBridge/LEEME.md`.

## Comprobar el proyecto

```text
npm test
python -m unittest discover -s pc_sync -p "test_*.py"
node scripts/prepare-downloads.mjs
node scripts/bundle-dashboard.mjs
```

Las pruebas del backend usan SQLite real de Node y llamadas HTTP en proceso, con un adaptador de la API de almacenamiento de Cloudflare. No equivalen por sí solas a ejecutar `wrangler dev` o a validar un despliegue real. El bundle opcional de `dashboard-deploy/` incrusta los assets para una publicación alternativa; el proyecto fuente normal usa el binding `ASSETS`.

Fuentes oficiales: [assets](https://developers.cloudflare.com/workers/static-assets/binding/), [SQLite Durable Objects](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/), [límites](https://developers.cloudflare.com/durable-objects/platform/limits/) y [secretos](https://developers.cloudflare.com/workers/configuration/secrets/).
