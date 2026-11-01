# El Especulador del WoW · puente Auctioneer

**Versión experimental 0.2.0.** Adaptador escrito a partir del código del fork **NoobyGains/Auctioneer-Forever 12.x**. No está validado dentro del juego. No implica compatibilidad con otras generaciones de Auctioneer, Auctionator ni el proyecto distinto “Auctioneer Suite 4.0.0”.

## Instalar y usar

1. Conserva una copia de tu carpeta WTF. Cierra WoW.
2. Copia la carpeta **EspeculadorBridge** completa dentro de `Interface/AddOns` del cliente Forever, junto a `Auctioneer`. El archivo `.toc` debe estar directamente en esa carpeta, sin un nivel adicional.
3. Abre el juego y activa ambos addons. El puente comprueba el cliente Forever 1.60.x/interfaz 16001, la región Europa y la facción Alianza.
4. En tu personaje del conjunto de reglas **PvP**, escribe `/especulador confirmar EU PVP ALIANZA`. La modalidad PvP es una declaración tuya: el nombre del reino no la demuestra. La confirmación queda ligada a ese reino e interfaz.
5. Ejecuta una búsqueda o escaneo de Auctioneer. El puente observa los resultados que Auctioneer termina de procesar, sin lanzar búsquedas propias.
6. Cuando haya terminado, escribe `/reload` o sal del juego para que el cliente guarde las variables en disco.
7. Importa en el panel local `WTF/Account/TU_CUENTA/SavedVariables/EspeculadorBridge.lua`, o configura ese archivo como fuente local. El panel no necesita tu contraseña.

`/especulador estado` muestra el registro del módulo y el número de observaciones en memoria. `/especulador pausar` detiene la captura y conserva los datos; confirma de nuevo el mercado para reanudar.

## Qué exporta

La variable **EspeculadorBridgeDB** contiene:

- Esquema 1, origen `Auctioneer12.x` y mercado `forever.pvp.alliance.eu` únicamente tras confirmar el contexto compatible.
- Metadatos: región, facción, declaración de PvP, reino, interfaz y número de compilación. No incluye nombre del personaje ni identificadores de cuenta.
- Un mapa de hasta 20.000 observaciones por clave completa de objeto. Conserva por separado nivel, sufijo y especie de mascota.
- Cada fila guarda precio mínimo de compra, cantidad total observada y su propia fecha de captura en segundos Unix. No contiene una referencia histórica inventada.
- `capturedAt` es la fecha del último lote capturado. `savedAt` es la fecha de salida o recarga de interfaz; **no se puede usar para rejuvenecer los precios**.
- `lastBatchScope = "partial"` y `complete = false` siempre. El mapa puede reunir filas procedentes de búsquedas diferentes; no representa un único escaneo completo simultáneo.

La cantidad total observada **no indica cuántas unidades existen al precio mínimo**. Tampoco contiene profundidad de mercado ni ventas confirmadas. El panel debe mantener la fecha de cada fila y evitar recomendaciones con datos antiguos.

## Alcance y límites

El puente se limita a leer objetos ya procesados por Auctioneer y a preparar sus propias SavedVariables. No modifica las tablas del addon, sus archivos, las subastas ni el inventario. No compra, publica, cancela, envía correo, transmite datos a otros jugadores ni simula entradas. La actualización de archivos depende del guardado normal del cliente; no hay sincronización de precios con cada segundo de juego.

Si cambian cliente, región, facción o reino, se desactiva el enlace de mercado. Las observaciones se conservan desactivadas y se reinician antes de ligarlas a otro contexto. Si una versión futura cambia la interfaz o la API, habrá que revisar el adaptador. El README del fork documenta además un fallo de SavedVariables en ciertas builds de beta: hay que comprobar que no afecta a la versión de cliente que uses. Este puente no instala parches para ese fallo.

## Fuentes verificadas

- [Registro de módulos y contexto Auctioneer](https://github.com/NoobyGains/Auctioneer-Forever/blob/main/Auctioneer/Main.lua).
- [Callbacks y entrega de objetos procesados del escáner](https://github.com/NoobyGains/Auctioneer-Forever/blob/main/Auctioneer/Modules/Scanner/Main.lua).
- [Claves completas de objetos y arranque de módulos](https://github.com/NoobyGains/Auctioneer-Forever/blob/main/Auctioneer/Internal.lua).
- [Constantes](https://github.com/NoobyGains/Auctioneer-Forever/blob/main/Auctioneer/Const.lua).
- [README y límites de beta](https://github.com/NoobyGains/Auctioneer-Forever).

En el escáner, `Push()` puede ejecutarse al finalizar una búsqueda, cerrar la casa de subastas o cambiar de vista. Por eso `ScannerItemsCompleted` no demuestra que se haya recorrido todo el mercado y el puente nunca lo etiqueta como tal.

No se ha podido ejecutar un intérprete Lua en el entorno de desarrollo. Además de la revisión del código, queda pendiente comprobar instalación, carga y captura con un archivo real producido por el cliente.
