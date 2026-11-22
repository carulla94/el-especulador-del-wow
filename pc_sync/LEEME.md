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

## Panel de la hermandad: el subidor

Es otro programa, para la hermandad que usa el addon **Oro de Hermandad** (0.4.0 o posterior; también lee los archivos de 0.3.x). Envía al panel de la hermandad los precios que apunta ese addon, desde la 0.6.0 también su estimación de lo que se vende entre dos escaneos y, si usas el addon **Forever Fishing**, tus sesiones de pesca. No tiene nada que ver con tu cartera ni con Auctioneer.

**Basta con que una o dos personas de la hermandad lo tengan abierto.** Al terminar un escaneo completo de la subasta, el addon de cada compañero comparte un resumen de precios con la hermandad por el canal oculto de los addons (no se ve en el chat, no suena y no abre ventanas). El addon de quien tiene el subidor lo recoge mientras juega, pide a los compañeros conectados los escaneos que se perdió en las últimas 72 horas y lo guarda en su `OroHermandad.lua`; este programa lo sube al panel junto con los precios propios. El panel cuenta cuántas personas aportan precios, no solo cuántas suben. Los demás solo juegan con el addon: no necesitan Python, ni este programa, ni hacer nada.

### Subidor para Windows (la ventana: lo normal)

Desde la 0.6.0 el subidor es una ventana, **«Oro de Hermandad · Subidor»**, que sube sola mientras está abierta y no necesita instalar Python: va todo en una carpeta, con el Python oficial de python.org (firmado) dentro. Se descarga desde el panel, en **Descargas → «Subidor para Windows»** (`Subidor_Windows.zip`).

1. Clic derecho en el zip → Propiedades → marca «Desbloquear» → Aceptar. (Si no, Windows puede bloquear el lanzador porque viene de internet.)
2. Extrae la carpeta donde quieras (por ejemplo en Documentos). No la pongas dentro de la carpeta de WoW.
3. Abre «Abrir subidor.cmd»; la primera vez te ofrece un acceso directo en el escritorio.

La primera vez la ventana pide tres datos: la dirección **HTTPS** del panel, la carpeta de World of Warcraft (propone las instalaciones que tienen `_forever_`) y tu **clave personal** (empieza por `gld_`; te la da quien administra la hermandad, se muestra una sola vez: no la compartas ni la publiques). Después enseña si todo está enviado, el último envío aceptado, cuántas personas suben y aportan precios, el estado del aviso para el addon y un registro. Deja la ventana abierta mientras juegas, o marca «Abrir el subidor al iniciar Windows (minimizado)»: se abre minimizada en la barra de tareas y nunca funciona oculta. Cerrarla para la subida hasta que la vuelvas a abrir. Si la ruta de la carpeta del subidor es muy larga (más de unos 100 caracteres), Windows no puede abrirlo al iniciar sesión: la ventana lo dice y no lo marca; mueve la carpeta a una ruta más corta, por ejemplo `C:\OroHermandad`. Si la copias allí en vez de moverla y marcas la casilla en la copia corta, la carpeta larga, si vuelves a abrirla, te lo dice y no le quita el inicio con Windows ni el acceso directo del escritorio.

WoW solo escribe el archivo al usar `/reload` o al salir del juego: el subidor no puede leer precios que todavía solo están en la memoria del juego. Después de escanear, pulsa **«Guardar y subir»** en el addon (solo aparece en el PC del subidor) o usa `/reload`, y la ventana los envía en segundos. «Subir ahora» solo hace que mire el archivo en ese momento (o reintente si no había conexión).

**Actualizar.** Cierra el subidor, desbloquea el zip nuevo y extrae su carpeta encima de la anterior (Reemplazar). Tu clave y tu configuración se conservan. Si la extraes en otra carpeta, la versión nueva se queda con el inicio con Windows y con el acceso directo del escritorio la primera vez que la abres, y la antigua, si vuelves a abrirla, te dice dónde está la nueva y no se los quita. La ventana avisa cuando el panel ofrece una versión nueva; nunca se actualiza sola. **Quien tiene el subidor actualiza primero el addon y el subidor** (si no, el panel no recibe las ventas); después, el resto de la hermandad actualiza el addon. Si una cuenta todavía tiene un addon anterior a 0.6.0, la ventana lo dice en la fila «Cuentas».

Si ya usabas el subidor antiguo que arrancaba oculto con Windows (`--instalar-inicio`), la ventana lo detecta y te ofrece quitarlo y, después, abrirse ella al iniciar Windows; la configuración, la clave y el registro de envíos siguen valiendo. «Más…» tiene «Cambiar clave», «Crear acceso directo en el escritorio», «Quitar el aviso del addon» y «Borrar mis datos de este PC». Mientras otro subidor funciona en este PC (por ejemplo `HERMANDAD.cmd`), la ventana no cambia ni borra nada: espera con «Reintentar». Si cambias la dirección del panel, al panel nuevo se le envía todo otra vez.

Riesgo de baneo: **muy bajo**. El programa solo lee el archivo que WoW ya ha guardado y escribe una carpeta pequeña de aviso; no toca el juego, ni su memoria, ni pulsa teclas. Es el mismo tipo de programa que la app de TSM o WeakAuras Companion. Blizzard no certifica ningún programa, así que nadie puede prometer «está permitido».

### Versión de consola: HERMANDAD.cmd (para quien ya tiene Python)

Es el mismo subidor sin ventana, en este zip (`Sincronizador_PC.zip`). Comparte con la ventana la configuración, la clave cifrada y el registro de envíos, y nunca suben los dos a la vez.

1. Pide a quien administra la hermandad la dirección del panel y tu **clave personal** (empieza por `gld_`).
2. Abre **HERMANDAD.cmd**. Requiere Python 3.10 o superior; si no lo tienes, la ventana explica cómo instalarlo.
3. La primera vez pide tres datos: la dirección **HTTPS** del panel, la carpeta de World of Warcraft (busca las instalaciones habituales y te propone la que tiene `_forever_`) y tu clave, que no se ve al pegarla.
4. Si el juego estaba abierto cuando lo arrancaste por primera vez, sal del juego del todo y vuelve a entrar una vez (un /reload no basta; ver «El aviso para el addon»).
5. Mantén la ventana abierta mientras juegas. WoW guarda el archivo al usar `/reload` o al salir; el programa lo envía en cuanto termina de escribirse.

No tienes que hacer nada en el juego: ni comandos ni clics. Las siguientes veces no pregunta nada. La dirección, la carpeta, el estado del subidor y el registro de envíos se guardan en `%LOCALAPPDATA%\OroHermandad\config.json`. La clave se guarda cifrada con la protección de datos de Windows (**DPAPI**): solo tu usuario de Windows en este PC puede descifrarla. Nunca se guarda como texto ni se pasa como argumento. En otros sistemas no se guarda y se pide en cada arranque. Con Python también puedes abrir la ventana desde el código del repositorio: `pyw -3 subidor.pyw`.

### Qué se comparte y qué se envía

Al terminar un escaneo completo de la subasta, Oro de Hermandad comparte con tu hermandad, por el canal oculto de los addons (no se ve en el chat), el precio más bajo y las unidades de los objetos de la lista fija, la hora del escaneo, el reino y la facción y, desde la 0.6.0, cuántas unidades calcula que se vendieron desde tu escaneo anterior (una estimación, sin nombres). Nada más: ni tu oro, ni tus bolsas, ni tus subastas, ni tus ventas, ni tus objetos extra. Los PC con el subidor envían esos precios al panel identificados solo con un código de 8 cifras por personaje (un hash del nombre del personaje y de la hermandad): los nombres de los personajes nunca salen del juego. Ese código es seudónimo, no anónimo: quien conozca la lista de la hermandad podría calcularlo. Si no quieres compartir tus escaneos, escribe `/oro compartir off` en el juego (seguirás viendo los de la hermandad).

Este programa lee `_forever_/WTF/Account/<CUENTA>/SavedVariables/OroHermandad.lua` de cada cuenta y saca solo el bloque **`OroHermandadHist`**. Por cada reino y facción, envía:

- el ID y el nombre de cada objeto vigilado, su categoría y su precio de venta al mercader (solo de tus objetos; los que solo ha visto un compañero van sin nombre);
- sus precios por día y por escaneo (mínimo, máximo, último y cantidad): los de tus personajes y los de cada compañero cuyo escaneo recogió tu addon (de cada compañero, los últimos 14 días);
- con el addon 0.6.0, la estimación de ventas de cada escaneo que la tenga (`sold`: la hora del escaneo, los segundos desde el escaneo anterior y las unidades), solo de los escaneos que van en ese envío;
- el código de 8 cifras de cada uno de tus personajes y de cada compañero, nunca su nombre;
- los depósitos de subasta aprendidos y la comisión de la subasta, si el addon la conoce.

Nunca envía **`OroHermandadDB`** (tu hermandad, sus miembros, profesiones y recetas, tus ventas y compras, la caché de precios y el estado del escáner) ni **`OroHermandadCharDB`** (tus personajes, oro y banco). Tampoco abre **`Auctionator.lua`** ni ningún otro archivo, salvo `ForeverFishing.lua` (ver «Tus sesiones de pesca»). El programa se salta esos bloques sin guardar nada de ellos. En el panel apareces con el nombre que te puso quien administra la hermandad; tus otros personajes de la misma cuenta se suman a ti. Los compañeros que no suben aparecen como «un compañero», nunca con un nombre. Sus otros personajes cuentan como personas distintas, porque nadie puede comprobar que son del mismo jugador.

El archivo se interpreta en tu PC sin ejecutar Lua, con límites de tamaño (10 MB), profundidad y número de elementos. Un archivo dañado o de otro formato se avisa y no se envía. Los datos van solo a `https://<panel>/api/guild/sync`, con tu clave en la cabecera `Authorization`. Las redirecciones están bloqueadas y cada envío ocupa como mucho 2 MiB. Solo se envía un archivo cuyo contenido haya cambiado (por su sha256), y solo se da por enviado cuando el panel lo confirma. Tras el primer envío aceptado de cada cuenta solo va lo nuevo, también de cada compañero: los tres últimos días de cada objeto y sus escaneos recientes; un objeto que el panel aún no tiene va completo. Después de `--reset` o de un envío rechazado, el siguiente vuelve a ir completo. Si un envío pasa de 2 MiB, primero se quedan fuera los puntos de escaneo (con sus estimaciones de ventas) de un compañero tras otro, empezando por los de escaneos más antiguos, hasta que cabe; si no basta, también los tuyos y por último los compañeros con escaneos más antiguos; lo que no cupo sale en el envío siguiente, enseguida y con el mismo archivo, hasta que llega todo. Si el panel no guarda a un compañero, la ventana lo dice y ese compañero vuelve a ir completo más tarde: si no cabía en ese envío (`ENVIO`), enseguida, en otro envío con el mismo archivo; si se acabó la parte de la cuota diaria para compañeros (`CUOTA`), pasada la medianoche UTC (la 01:05 o las 02:05 en España), aunque el archivo no haya cambiado; si el panel ya tiene el máximo de compañeros, con el siguiente archivo. Si falla la conexión, se reintenta tras una pausa de entre 60 segundos y 5 minutos. Si el panel ha agotado su cuota diaria de escritura, espera lo que el panel indique (como mucho una hora entre intentos). Si el panel rechaza la clave, el programa se detiene.

### Tus sesiones de pesca (Forever Fishing)

Si tienes el addon **Forever Fishing**, el subidor (desde la 0.5.0) lee también `ForeverFishing.lua`, en la misma carpeta `SavedVariables` de cada cuenta, y envía a `https://<panel>/api/guild/fishing` las sesiones de pesca que guarda ese addon. Así la pestaña **Pesca** del panel enseña cuánto has sacado por hora en cada sesión con los precios del día, tu ritmo real de capturas (y lo usa para calcular el oro por hora de cada zona) y lo que de verdad pica en cada zona según lo que ha pescado la hermandad.

De cada sesión solo va: la hora de inicio y de fin, el tiempo con la caña en la mano, los lanzamientos, las capturas y, por cada lugar («Zona: Subzona»), el ID de cada objeto pescado y cuántos. **Nunca** va el nombre del personaje, el reino, el código (GUID) del personaje ni ninguna otra opción del addon. Lo que no tiene lugar se cuenta como «sin lugar». Se envían como mucho las 200 sesiones más recientes, y solo cuando cambian. Un miembro ve en el panel solo sus sesiones; quien administra la hermandad ve las de todos con el nombre que les puso en el panel. «Lo que de verdad pica» suma las sesiones de todos, sin nombres. El panel guarda las sesiones 180 días y las borra si se revoca al miembro con sus datos.

Si no usas Forever Fishing no pasa nada: el subidor no lo busca más allá de esa carpeta y no avisa. Si el panel aún no tiene esta parte, la ventana lo dice una vez y no vuelve a intentarlo hasta que el archivo cambie.

### El aviso para el addon

Lo único que el subidor escribe en la carpeta de WoW es la carpeta `Interface\AddOns\OroHermandad_Subidor`, un aviso de dos archivos (`OroHermandad_Subidor.toc` y `OroHermandad_Subidor.lua`) que le dice a Oro de Hermandad que este PC sube los precios, para que pida a los compañeros los escaneos que se perdió. Desde la 0.6.0 el `.lua` lleva también el estado del subidor, solo con números y palabras fijas: cuándo lo escribió, la versión, la hora del último envío aceptado y cómo fue el último intento (`ok`, `clave`, `red`, `cuota` o `rechazado`), cuántas personas suben y aportan precios y cuántos envíos le quedan hoy a tu clave. El addon lo lee al entrar o con `/reload` y lo enseña en su ventana; con él sabe si el subidor parece abierto y cuándo no tiene sentido «Guardar y subir». Solo se crea si Oro de Hermandad está instalado en ese `_forever_`, lleva la misma versión de interfaz que el addon y solo se reescribe si cambia (o una vez por hora mientras el subidor está abierto, y nunca dos veces en un minuto). No toca nada más de WoW.

WoW solo descubre una carpeta de addon nueva al arrancar: la primera vez sal del juego del todo y vuelve a entrar (un /reload no basta). Si el subidor no puede crearla (por ejemplo, sin permiso en la carpeta de WoW), la ventana lo dice: entonces escribe una vez `/oro subidor on` en el juego. `/oro subidor off` hace que este PC deje de pedir precios sin quitar el subidor, y `/oro subidor auto` vuelve a depender del aviso.

### Formatos y versiones

Oro de Hermandad 0.4.0, 0.5.x y 0.6.0 guardan `OroHermandadHist` en el formato 2 (añade los precios de los compañeros); la 0.6.0 añade a algunos puntos de escaneo dos campos opcionales con la estimación de ventas, que los addons y subidores anteriores ignoran sin problema. Este subidor lee el formato 1 (addon 0.3.x) y el 2 y siempre envía el formato 2 del panel. Un subidor anterior (0.3.0) avisa de que no entiende el formato 2: descarga este desde el panel. Si vuelves al addon 0.3.1, deja el archivo de formato 2 sin tocar y apaga su historial; al volver a 0.4.0 todo sigue ahí.

### Opciones de la versión de consola

- `HERMANDAD.cmd --once`: una sola comprobación (y un envío si hay cambios, más los que hagan falta si algo no cupo), y termina.
- `HERMANDAD.cmd --instalar-inicio`: solo si sabes lo que haces (lo normal es la ventana con «Abrir el subidor al iniciar Windows»). Crea una tarea del Programador de tareas que arranca el subidor oculto, sin ventana, un minuto después de iniciar sesión en Windows. La tarea sigue funcionando con el portátil sin enchufar y no tiene límite de tiempo (las tareas normales de Windows no arrancan con batería y se detienen a las 72 horas). Lo que hace queda en `%LOCALAPPDATA%\OroHermandad\registro.txt`. Si Windows pide permisos de administrador, la ventana explica qué hacer.
- `HERMANDAD.cmd --quitar-inicio`: quita esa tarea.
- `HERMANDAD.cmd --quitar-aviso`: quita la carpeta `Interface\AddOns\OroHermandad_Subidor` (solo sus dos archivos, y la carpeta si queda vacía). Si vuelves a abrir el subidor, la vuelve a crear.
- `HERMANDAD.cmd --reset`: borra la dirección, la carpeta, la clave cifrada y el registro de envíos, y quita el aviso para el addon. Úsalo si te dan una clave nueva.

Pruebas: `python -m unittest discover -s pc_sync -p "test_*.py"` desde la raíz del repositorio (o, dentro de `pc_sync`, `python test_hermandad.py`, `python test_sync.py` y `python test_subidor.py`). Usan archivos inventados dentro de la prueba (y en `fixtures/relay/` y `fixtures/v06/` los ejemplos compartidos con el addon y el panel) y respuestas simuladas, sin red ni Windows; las de la ventana solo corren donde se puede abrir una ventana (Windows, o Linux con pantalla), y las de Windows de verdad (DPAPI, registro, Programador de tareas) en el flujo «Subidor para Windows» de GitHub Actions, que también construye y prueba `Subidor_Windows.zip`.
