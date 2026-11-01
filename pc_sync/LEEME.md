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
