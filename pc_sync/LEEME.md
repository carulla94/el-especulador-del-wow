# Sincronizador de PC · El Especulador del WoW

La aplicación y tu cartera viven en Cloudflare. Este pequeño programa solo lee los archivos que WoW guarda en tu PC y envía sus cambios a tu aplicación mediante una clave de dispositivo. No necesitas mantener abierto un servidor local.

## Empezar

1. Abre la aplicación en la nube, entra en **Auctioneer** y crea una clave para este PC. Cópiala: se muestra una sola vez. Su permiso se limita a subir observaciones; no permite leer tu cartera ni registrar compras o ventas.
2. Instala el puente compatible con Auctioneer y confirma dentro del juego `/especulador confirmar EU PVP ALIANZA`. Ejecuta un escaneo y usa `/reload` o sal del juego para que WoW guarde los archivos.
3. Extrae esta carpeta y abre **SINCRONIZAR.cmd**. Requiere Python 3.10 o superior, sin paquetes adicionales.
4. Introduce la dirección principal **HTTPS** de tu aplicación, la carpeta local **SavedVariables**, el nombre exacto del reino y la confirmación **EU PVP ALIANZA**.
5. Pega la clave del dispositivo cuando se solicite. No se muestra en pantalla ni se guarda en un archivo.
6. Mantén abierta la ventana mientras juegas. Para detenerlo, pulsa **Ctrl+C**.

La carpeta suele ser `World of Warcraft/CLIENTE/WTF/Account/TU_CUENTA/SavedVariables/`. Usa la carpeta del cliente Forever que realmente utilizas. El programa no busca cuentas ni instalaciones por sí mismo.

## Qué lee y cuándo actualiza

Exclusivamente estos archivos de la carpeta elegida:

- `Auctioneer_Stats_OverTime.lua`: histórico horario del fork Auctioneer 12.x compatible.
- `EspeculadorBridge.lua`: observaciones recientes del puente.

Comprueba cambios cada 15 segundos. Envía solo los archivos que hayan cambiado y únicamente al dominio HTTPS introducido, en `/api/device/sync`. La nube valida formato, mercado y fechas antes de aceptar los datos. Un archivo sin confirmar o de otro reino se rechaza: completa primero la confirmación del puente y revisa el reino seleccionado.

WoW guarda normalmente al recargar la interfaz o salir. El sincronizador no puede leer precios que todavía solo están en memoria del juego. Tampoco sustituye la fecha de una observación por la fecha de modificación del archivo.

Es una lectura sin modificaciones: no ejecuta Lua, no cambia archivos ni fechas de WoW, no compra ni publica y no necesita tu contraseña de Battle.net. El histórico horario no representa ofertas actuales; el programa en la nube mantiene esa distinción.

## Clave y reintentos

La clave y los hashes se mantienen solo en memoria. Al cerrar y volver a abrir tendrás que pegar de nuevo la clave; los archivos presentes se enviarán otra vez, y la nube deduplicará los registros.

Ante fallos de conexión, la ventana muestra un mensaje y reintenta con pausas entre 60 segundos y cinco minutos. Los cambios solo se consideran enviados después de una confirmación explícita de la nube. Si la clave se ha revocado o no es válida, el proceso se detiene. Crea una nueva clave desde la aplicación y vuelve a iniciarlo.

Límites: 10 MB por archivo y 16 MB para el cuerpo JSON combinado. Los archivos que estén cambiando o incompletos se posponen. Las redirecciones HTTP están bloqueadas para evitar reenviar la clave a otra dirección; usa siempre el dominio HTTPS final de tu aplicación.

## Uso desde terminal

`python sincronizar.py --url https://TU-APP.workers.dev --folder "RUTA_SAVEDVARIABLES" --realm "TU REINO"`

Añade `--once` para realizar una sola comprobación. La confirmación del mercado y la clave se solicitan de forma interactiva. Para automatización avanzada puedes suministrar la clave en la variable de entorno `ESPECULADOR_DEVICE_TOKEN`; no la incluyas en argumentos, capturas o archivos de instrucciones compartidos.

Pruebas del sincronizador: `python -m unittest test_sync.py -v`. Son pruebas locales con respuestas simuladas; queda pendiente validar el recorrido completo con el cliente real de Forever y la aplicación desplegada.

## Panel de la hermandad: HERMANDAD.cmd

Es otro programa de esta misma carpeta, para los miembros de la hermandad que usan el addon **Oro de Hermandad** (0.3.0 o posterior). Envía los precios que ese addon apunta al panel de la hermandad. No tiene nada que ver con tu cartera ni con Auctioneer.

1. Pide a quien administra la hermandad la dirección del panel y tu **clave personal** (empieza por `gld_`). Se muestra una sola vez: no la compartas ni la publiques.
2. Abre **HERMANDAD.cmd**. Requiere Python 3.10 o superior; si no lo tienes, la ventana explica cómo instalarlo.
3. La primera vez pide tres datos: la dirección **HTTPS** del panel, la carpeta de World of Warcraft (busca las instalaciones habituales y te propone la que tiene `_forever_`) y tu clave, que no se ve al pegarla.
4. Mantén la ventana abierta mientras juegas. WoW guarda el archivo al usar `/reload` o al salir; el programa lo envía en cuanto termina de escribirse.

Las siguientes veces no pregunta nada. La dirección, la carpeta y el registro de envíos se guardan en `%LOCALAPPDATA%\OroHermandad\config.json`. La clave se guarda cifrada con la protección de datos de Windows (**DPAPI**): solo tu usuario de Windows en este PC puede descifrarla. Nunca se guarda como texto ni se pasa como argumento. En otros sistemas no se guarda y se pide en cada arranque.

### Qué se envía y qué no

Lee `_forever_/WTF/Account/<CUENTA>/SavedVariables/OroHermandad.lua` de cada cuenta y saca solo el bloque **`OroHermandadHist`**. Por cada reino y facción, envía:

- el ID y el nombre de cada objeto vigilado;
- su categoría y su precio de venta al mercader;
- sus precios por día y por escaneo (mínimo, máximo, último y cantidad);
- los depósitos de subasta aprendidos;
- la comisión de la subasta, si el addon la conoce.

Nunca envía **`OroHermandadDB`** (tu hermandad, sus miembros, profesiones y recetas) ni **`OroHermandadCharDB`** (tus personajes, oro y banco). Tampoco abre **`Auctionator.lua`** ni ningún otro archivo. El programa se salta esos bloques sin guardar nada de ellos. En el panel apareces con el nombre que te puso quien administra la hermandad, nunca con el de tus personajes.

El archivo se interpreta en tu PC sin ejecutar Lua, con límites de tamaño (10 MB), profundidad y número de elementos. Un archivo dañado o de otro formato se avisa y no se envía. Los datos van solo a `https://<panel>/api/guild/sync`, con tu clave en la cabecera `Authorization`. Las redirecciones están bloqueadas y cada envío ocupa como mucho 2 MiB. Solo se envía un archivo cuyo contenido haya cambiado (por su sha256), y solo se da por enviado cuando el panel lo confirma. Tras el primer envío aceptado de cada cuenta solo va lo nuevo: los tres últimos días de cada objeto y sus escaneos recientes; un objeto que el panel aún no tiene va completo. Después de `--reset` o de un envío rechazado, el siguiente vuelve a ir completo. Si falla la conexión, se reintenta tras una pausa de entre 60 segundos y 5 minutos. Si el panel ha agotado su cuota diaria de escritura, espera lo que el panel indique (como mucho una hora entre intentos). Si el panel rechaza la clave, el programa se detiene.

### Opciones

- `HERMANDAD.cmd --once`: una sola comprobación (y un envío si hay cambios), y termina.
- `HERMANDAD.cmd --instalar-inicio`: opcional. Crea una tarea del Programador de tareas que arranca el subidor sin ventana un minuto después de iniciar sesión en Windows. La tarea sigue funcionando con el portátil sin enchufar y no tiene límite de tiempo (las tareas normales de Windows no arrancan con batería y se detienen a las 72 horas). Lo que hace queda en `%LOCALAPPDATA%\OroHermandad\registro.txt`. Si Windows pide permisos de administrador, la ventana explica qué hacer.
- `HERMANDAD.cmd --quitar-inicio`: quita esa tarea.
- `HERMANDAD.cmd --reset`: borra la dirección, la carpeta, la clave cifrada y el registro de envíos. Úsalo si te dan una clave nueva.

Pruebas: `python -m unittest test_hermandad.py -v`. Usan archivos inventados dentro de la prueba y respuestas simuladas, sin red ni Windows.
