# El Especulador del WoW · Cloudflare

Aplicación privada para WoW Forever, Europa, PvP y Alianza. Versión cloud 0.3.0.

La interfaz, contabilidad, inventario, cálculos y datos persistentes se ejecutan en Cloudflare Workers con SQLite en un Durable Object. Puedes importar los archivos de Auctioneer desde el navegador o emparejar el sincronizador del PC para enviar sus cambios por HTTPS.

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
