# Oro de Hermandad

Addon para WoW Forever que te dice qué hacer para ganar oro. Escanea la subasta él mismo (con la hora de cada escaneo), lee tus bolsas y tu banco, tus profesiones y las de tu hermandad, y te da una lista corta de acciones. Te dice a qué hora se vende mejor cada material («Cuándo vender»), te avisa cuando los precios están viejos y, con el modo **Especular**, te señala chollos para comprar y revender. **Auctionator es opcional** desde la 0.6.0: si lo tienes, el addon también lee sus precios y su historial.

Versión 0.6.0, para el cliente 1.60 de Forever (Interface 16001). Probado con las pruebas automáticas y en el juego (cliente 1.60.1.71037, 22 de noviembre de 2026; ver «Pruebas»). La instalación está explicada paso a paso en la guía `INSTALAR_ORO_DE_HERMANDAD.md`; pídela a quien te pasó el addon. Los cambios de cada versión están en `CAMBIOS.md`.

## Cómo se usa

- Para abrir la ventana: **botón de la moneda** junto al minimapa, `/oro`, o el menú de addons (o accesorios) del minimapa.
- Se abre sola, pegada a la subasta, cuando hablas con un subastador. Se cierra con ella.
- **Abre cada profesión una vez** (y cuando aprendas recetas nuevas) para que el addon las conozca.
- **Escanea la subasta con el addon**: con la subasta abierta, la ventana tiene una fila con el botón **Escanear** (unos segundos, no se nota en el juego). Si eliges «Escanear cada vez que abro la subasta» en las opciones (o `/oro escanear auto`), lo hace solo en cada visita. Así cada visita apunta precios para ti y para tu hermandad (ver «Escanear la subasta» y «Precios compartidos con la hermandad»).

## Modos

Se cambian con los tres botones de arriba de la ventana, con `/oro tranquilo`, `/oro atope` o `/oro especular`, o en el panel de opciones.

| | Tranquilo | A tope | Especular |
| --- | --- | --- | --- |
| Para qué | Subes de nivel o juegas con amigos | Sesión solo para hacer oro | Comprar barato para revender y vender cuando algo está caro |
| Ventas | Una línea con todo | Una línea por objeto | Solo **Vende ahora**: lo que llevas o tienes en el banco cuando está caro |
| Recetas | Solo las que puedes hacer con lo que llevas | También las rentables comprando materiales: qué falta, quién de la hermandad lo consigue y botón **Comprar lo que falta**. Lo que vende un mercader se compra allí, y lo que tienes en el banco se saca, no se compra | No |
| Recolección | Lo que más vale en zonas de tu nivel | Las 2 mejores rutas por profesión y la mejor tela para tu nivel | No |
| Banco | Solo si lo que sacas vale al menos 1 oro (para vender o para tus recetas) | Todo lo que vale la pena sacar: para vender o para tus recetas | Lo que está caro, en **Vende ahora** |
| Hermandad | 1 sugerencia | Hasta 4, y qué profesiones os faltan | No |
| Chollos | Como mucho 1, y solo si es muy fiable | Hasta 2 | Hasta 8, con el estado del mercado |
| Balance de la semana | No | No | Lo que más sube y más baja, y el botón **Tabla** |
| Precios viejos a partir de | 24 h | 6 h | 6 h |

## Qué te sugiere

- **Avisos**: cuándo subir de rango una profesión que está a punto de topar, y desde qué nivel de personaje se puede. Las principales se suben con el instructor. Cocina, Pesca y Primeros auxilios, también con el instructor hasta Oficial; Experto, con un libro que vende un mercader; Artesano, con una misión.
- **Ahora**:
  - fundir cuando el lingote vale más que el mineral, o fabricar recetas con beneficio;
  - qué vender en la subasta y qué vale más en el vendedor;
  - qué sacar del banco: para vender (también lo que fabricas tú, como los lingotes) o para tus recetas (lo que usan tus recetas rentables no te lo sugiere vender);
  - si eres el mejor encantador de la hermandad (o el único), las piezas verdes y azules sin precio en la subasta, para que las desencantes;
  - la chatarra gris.
  - Nunca te sugiere vender tus herramientas de profesión ni pociones o comida, salvo las que fabricas tú.
- **Recoger**: el mineral, la hierba o la piel que más vale de lo que tu nivel de profesión permite, con valor aproximado por veta, planta o bicho y las zonas donde abunda.
- **Hermandad**:
  - qué llevas que usa un amigo, según su profesión y su nivel;
  - recetas rentables de tus amigos con tus materiales;
  - piezas sin precio en la subasta para el mejor encantador, si no eres tú;
  - qué profesiones le faltan al grupo.
- **Especular**: los chollos (ver «Modo Especular»). En Tranquilo y A tope la sección solo aparece cuando hay alguno, y las filas de venta dicen si hoy el precio está bajo («si no tienes prisa, espera») o alto («buen momento para vender»).

Los importes ya descuentan la comisión de la subasta (5 % por defecto; puedes cambiarla con `/oro comision`).

## Precios de la subasta

- Los precios salen del escáner del propio addon (ver «Escanear la subasta») y, si tienes Auctionator, también de él: de cada objeto se usa el más reciente de los dos (a igualdad, el del addon).
- Solo un escaneo terminado cuenta como «precios al día»: el del addon, o el completo o el de **escanear al abrir la subasta** de Auctionator. Una búsqueda suelta, la pestaña Comprar o tus favoritos no.
- No busques nada mientras Auctionator hace su escaneo de resumen: una búsqueda (la barra de búsqueda o una lista de la compra) lo corta y Auctionator lo da por terminado solo con lo que encontró esa búsqueda. El addon lo nota y no lo cuenta como escaneo. Por eso **Comprar lo que falta**, mientras dura ese escaneo, solo crea la lista en Auctionator sin buscarla. Sin Auctionator, **Comprar lo que falta** escribe el nombre del siguiente material en la búsqueda de la subasta.
- Si los precios están viejos, te avisa al abrir la subasta, con un sonido (en modo automático no: el escaneo ya viene). El mismo aviso no se repite en cada visita: vuelve solo si cambia o después de otro escaneo.
- Si acabas de hacer un escaneo completo y la subasta tiene poca oferta (un servidor nuevo, por ejemplo), te lo dice sin pedirte otro escaneo.

## Escanear la subasta

Desde la 0.6.0 el addon escanea la subasta entera él mismo (el «escaneo completo» del juego): tarda unos segundos, lee por tandas cortas para que el juego no se trabe y apunta la **hora exacta** de cada escaneo (Auctionator solo guarda un precio por día).

- **Modos** (opciones, apartado «Escáner de la subasta», o `/oro escanear auto | proponer | off`):
  - **Proponerlo al abrir la subasta** (por defecto): la fila del escáner de la ventana tiene el botón **Escanear** y, cuando conviene, dice por qué: «Escaneaste hace 40 min: si escaneas ahora, el addon mide lo que se ha vendido entre los dos escaneos.» (la **pareja**), «Hace 2 h que nadie de la hermandad escanea esta subasta.» o «La franja 20-24 h tiene pocos datos para «Cuándo vender».». La casilla «Escanear siempre al abrir la subasta» pasa a automático. Con la ventana cerrada, una línea en el chat por visita (y como mucho cada 30 min).
  - **Escanear cada vez que abro la subasta**: lo pide solo al abrirla y, mientras sigue abierta, cuando toca otra vez (para guardarlo o para medir ventas). Nunca mientras publicas o compras, ni en los 15 s siguientes. No escribe nada en el chat.
  - **Solo con el botón**: nada solo; el botón y `/oro escanear` siguen funcionando.
- **La pareja:** para medir lo que se vende hace falta que **la misma persona escanee dos veces con entre 30 min y 2 h de diferencia** (por ejemplo al llegar a la ciudad y antes de irse). El addon te lo propone.
- **Uno cada 15 minutos por cuenta:** la subasta solo deja un escaneo completo cada 15 min por cuenta. Si no se puede, la fila dice a qué hora: «Siguiente escaneo completo posible a las 21:15 (la subasta deja uno cada 15 min por cuenta).».
- **Qué se guarda:** un escaneo cada 30 min y 8 al día por reino y facción van al historial (y a la hermandad); los demás solo ponen los precios al día y sirven de primera mitad de una pareja.
- **Auctionator:** si tienes activadas en Auctionator sus opciones de escanear al abrir la subasta **y** que ese escaneo sea el completo, el addon no pide el suyo: usa el de Auctionator. Si pulsas el escaneo completo de Auctionator justo después de uno del addon, puede quedarse esperando hasta que cierres la subasta (la subasta deja uno cada 15 min).
- **«Escanear la lista»:** si la subasta no responde al escaneo completo o falta mucho para el siguiente, la fila ofrece buscar uno a uno los objetos vigilados (2-3 min). Solo cuando lo pides; mientras dura, no vendas ni compres (se pausa si vas a las pestañas Vender o Subastas). «Parar» o `/oro escanear parar` lo detiene.
- **Subasta neutral:** Bahía del Botín, Gadgetzan y Vista Eterna son otro mercado (se queda un 15 %): allí el addon no escanea ni guarda precios. Si no está seguro de qué subasta es, tampoco (`/oro sondeo` dice por qué).
- **Nunca** publica, compra, puja ni cancela por ti.

## Cuándo vender

`/oro cuando` (o el botón **Cuándo vender** de la ventana) enseña, por franja de 4 horas (hora de España), si el precio más bajo suele estar por encima o por debajo de lo normal y si se vende más o menos que de media, con tus escaneos y los de la hermandad de las últimas semanas (lo de hace dos semanas pesa la mitad):

```text
Franja        00-04   04-08   08-12   12-16   16-20   20-24
Precio         +4 %    +6 %    +1 %     0 %    −2 %    −3 %
Ventas            —       —    ×0,8    ×1,0    ×1,3    ×1,9
Medido          0 h   0,5 h     3 h     5 h     9 h    14 h
Escaneos          2       1       5       9      14      22
Mejor franja para vender: 20-24 h (más ventas; precio −3 %). Pon o iguala el precio hacia las 19-20 h, con 2 h (u 8 h si no vas a volver).
```

- **Ventas es una estimación:** lo que desaparece entre dos escaneos de la misma persona (la pareja). Si alguien retira su subasta más barata sin volver a ponerla, cuenta como vendida; si alguien repone al mismo precio o más barato, esa venta no se ve. Lo que tú compras entre los dos escaneos se descuenta. Dos personas que miden las mismas compras cuentan una vez, y también dos personajes de tu cuenta: cada medición empieza donde acabó la última de la cuenta.
- **Pocos datos («—»):** una franja cuenta para las ventas con al menos 3 mediciones en 2 días distintos y una hora medida; la mayor venta de cada franja se deja fuera (una compra enorme suelta no decide nada). Recomienda una franja por ventas con 3 franjas así; si no, por el precio (3 franjas con precio y 3 puntos de diferencia); si no, «aún pocos datos».
- **Medido** son las horas medidas entre parejas de escaneos y **Escaneos**, los escaneos con precio de referencia: así se ve dónde faltan datos.
- **Cuándo poner:** «Pon o iguala el precio hacia las 19-20 h» es la hora antes de la mejor franja: la subasta vende primero lo más barato y, a igual precio, lo último que se puso, así que basta con igualar el más barato justo antes de que lleguen los compradores. Con 2 h (u 8 h si no vas a volver): el depósito de 8 h es 4 veces el de 2 h y el de 24 h, 12 veces.
- Con un objeto (`/oro cuando hierro`, su número o su enlace), su tabla. En la descripción de los objetos vigilados: «Cuándo vender: 20-24 h (más ventas)».
- En la ventana, la tabla sale arriba en columnas; debajo va todo el texto (también la tabla) ya seleccionado para copiarlo con Ctrl+C.

## Tus ventas

El addon apunta, **solo en tu PC**, cuándo se venden tus subastas («Ha aparecido un comprador…») para la línea «Tus ventas (28 días): 20-24 h 9 · 16-20 h 4 · resto 2» de «Cuándo vender». Cuenta **veces**, no unidades: el aviso del juego no dice cuántas compraron de una subasta de materiales. No se comparte ni se sube. Se apaga en las opciones («Apuntar mis ventas para «Cuándo vender»»). Lo que compras se apunta unas horas (solo para descontarlo de las ventas estimadas).

## Historial de precios

Desde la versión 0.3.0 el addon apunta los precios de una lista de materiales y consumibles comunes (114 desde la 0.3.1, con todo lo que da la recolección y lo que hace falta para valorar la fundición; 161 desde la 0.5.0, con la pesca): minerales y lingotes, piedras, gemas, hierbas, cuero, tela, pociones, elixires, frascos, comida, vendas, materiales de encantamiento y esencias. Puedes añadir hasta 40 objetos más con `/oro vigilar`. Con estos datos funciona el modo Especular.

- **Pesca (0.5.0):** apunta también el pescado crudo, lo que se cocina con él, los aceites que se destilan (de bocanegra, de fuego y de Escama Tormentosa) y los elixires que los usan. Son 47 objetos más para la pestaña «Pesca» del panel de la hermandad: qué pescar, dónde, si compensa venderlo crudo, cocinarlo o destilarlo, y a qué hora y qué día se vende mejor. Desde la 0.5.1 también se comparten con la hermandad como el resto (ver «Precios compartidos con la hermandad»): así el pescado que escanea cualquiera llega al panel, no solo el de quien tiene el subidor. Al instalar la 0.5.0, el mismo día se rellena con el historial de Auctionator lo que ya tengas escaneado de ellos.

- **Cuándo apunta:** con cada escaneo guardado (los del addon, como mucho uno cada 30 min y 8 al día por reino y facción, y los de Auctionator). Por cada día guarda el precio mínimo más bajo y el más alto, el último, cuántas unidades había a la venta y cuántos escaneos hubo. De los últimos 14 días guarda además cada escaneo con su hora. Una búsqueda que corta el escaneo de Auctionator no se apunta: solo refresca los precios. Tus propias subastas no cuentan como precio del mercado (en el escaneo completo).
- **Mercado (reino y facción):** los precios se guardan por mercado, `Reino-Facción` (por ejemplo `CAMWOWEU4Realm4PvP-Alliance`), y con esa misma clave se comparten con la hermandad y llegan al panel. WoW Forever no tiene reinos y, tras un cambio del juego en noviembre de 2026, el addon ya no puede leer su nombre. Desde la 0.6.0 usa el último que dio el juego a ese personaje (o a otro de tu cuenta de la misma facción); si no hay, el de tus precios guardados (los que ya tenías al llegar la 0.6.0: un reino puesto con `/oro reino` no cuenta) o, si tampoco hay precios, el que tenía tu hermandad con la 0.5.x; y si nada de eso, «Forever». Así siguen tus precios de siempre. Para compartir precios, todos en la hermandad tienen que usar el mismo: `/oro reino` dice cuál usas y de dónde sale. Si alguien nuevo sale con «Forever» y los demás con otro, que escriba `/oro reino` y el nombre que usan los demás (en cada personaje que salga con «Forever»: lo de `/oro reino` es solo para ese personaje), exactamente igual que les sale a ellos: las mayúsculas cuentan (`camwoweu4realm4pvp` sería otro mercado). Si el addon ya conoce ese reino, corrige las mayúsculas él solo, y si pegas el mercado entero (`CAMWOWEU4Realm4PvP-Alliance`) se queda con el reino. Lo de la hermandad (amigos a mano, profesiones) pasa al reino nuevo; si alguien ya estaba allí, se junta lo de los dos (de una profesión puesta a mano en los dos, la de más nivel). Si un personaje usa «Forever» porque lo elegiste con `/oro reino`, lo de su hermandad se queda con él aunque tus otros personajes usen otro reino. Lo que apunta un personaje que sale con «Forever» sin elegirlo también es suyo: pasa con él al reino de verdad cuando lo tenga, no con tus otros personajes. `/oro reino borrar` vuelve a lo automático. Si el juego vuelve a dar el reino, se usa ese.
- **Días que faltan:** al entrar, una vez al día, los rellena con el historial de Auctionator (sus últimos 21 días). Nunca sustituye lo que el addon vio por sí mismo.
- **Depósitos:** con la subasta abierta apunta cuánto cuesta publicar una unidad de cada objeto, según la duración.
- **Tamaño:** lo tuyo, como mucho 2 MB (1,25 MB hasta la 0.5.1). Guarda 120 días por objeto; si hiciera falta, recorta primero los días más viejos (de más de 90 y de más de 60 días) y después los escaneos sueltos más viejos, que son lo único con hora. Lo que comparten tus compañeros va aparte, con su propio tope de 4 MB (3 MB hasta la 0.5.1; ver «Precios compartidos con la hermandad»). Desde la 0.6.0 un escaneo puede llevar también la venta estimada desde el anterior de la misma persona.
- **`/oro tabla`:** abre una ventana con una tabla lista para pegar en Excel (columnas separadas por `;` y coma decimal). Tiene, por objeto, el precio de hoy, el normal de los últimos 14 días, el cambio en 1 y en 7 días (en %), el mínimo y el máximo de esos 14 días, la oferta de hoy, los días con precio y la confianza. Los precios van en oro: `0,0082` son 82 cobres. Ya sale seleccionada: pulsa Ctrl+C y pégala en Excel.
- **Privacidad:** se guarda en tu PC, en el archivo `WTF\Account\<cuenta>\SavedVariables\OroHermandad.lua`, en el bloque `OroHermandadHist`. Ahí solo hay precios de objetos (con su nombre, su precio de mercader, su categoría y los depósitos) por reino y facción, y los precios que han compartido tus compañeros, cada uno con un código de 8 cifras en vez de su nombre. No hay nombres de personajes, ni oro, ni profesiones. Los nombres de los vendedores que ve la subasta nunca se guardan ni se envían. Desde la 0.4.0 el addon comparte con tu hermandad los precios de tus escaneos completos (lo explica «Precios compartidos con la hermandad»). El subidor de la hermandad, si lo usas en tu PC, envía al panel ese bloque y nada más de ese archivo.
- **`/oro sondeo`:** comprueba lo que el addon necesita saber del juego: qué subasta es (la de tu facción o la neutral), qué mercado usa y de dónde sale su reino (la línea «Mercado:», por ejemplo «Mercado: CAMWOWEU4Realm4PvP-Alliance (el juego no da el reino: el de tus datos guardados)»), cómo responde al escaneo completo, las franjas de tiempo de las subastas, si reconoce tus propias subastas, la versión de Auctionator y la forma de sus escaneos, los depósitos y las duraciones de la subasta, «Cuándo vender», si tus escaneos y los de tus compañeros dan el mismo precio («Capas») y si el historial se guardó bien tras el último `/reload`. Cópialo de la ventana y pégalo en una incidencia: no lleva nombres de personajes ni tu oro. Hazlo una vez el primer día, con la subasta abierta, y repítelo tras un `/reload`.

## Modo Especular

Compra barato lo que alguien ha tirado de precio y revéndelo a su precio normal; vende lo tuyo cuando está caro. Todo sale del historial de precios que apunta el addon en tu PC (ver «Historial de precios»).

- **Precio normal:** la mediana de los últimos 14 días (sin contar hoy). Hacen falta al menos 7 días con precio: hasta entonces la sección dice «Aprendiendo precios: día 3 de 7». Haz un escaneo completo cada día.
- **Días para los chollos:** un chollo pide más: 10 días con precio (12 en Tranquilo, que solo enseña los fiables). Mientras tanto la sección dice, por ejemplo, «Los chollos necesitan 10 días con precio (ahora hay 8)».
- **Chollo:** el precio de ahora está al menos un 20 % por debajo de lo normal y fuera de su variación de siempre, el precio normal es orientativo o fiable y el mercado no está bajando. Ejemplo:

  > **Chollo: Paño rúnico a 60p (40 % por debajo de lo normal)**
  > Compra 40× a 82p 16c como máximo; no revendas por debajo de 63p 70c; objetivo 1o; ganancia ≈ 13o 79p tras la comisión y un depósito perdido · estimado: confirma en la subasta. Precio de hace 10 min. Fiable · 14 días · variación ±3 %.

  - **Compra 40× a 82p 16c como máximo:** cuántas comprar y lo más que puedes pagar por unidad (a ese precio aún ganas un 15 %). Las unidades salen de lo que hay a la venta, de la oferta normal del objeto (una cuarta parte, para poder revenderlas) y de tu presupuesto.
  - **No revendas por debajo de 63p 70c:** por debajo pierdes dinero, contando la comisión y los depósitos.
  - **Objetivo 1o:** el precio de reventa. Es prudente: uno que se alcanzó al menos 6 de cada 10 días de las dos últimas semanas, y nunca más que el de los últimos 3 días.
  - **Ganancia ≈:** lo que ganarías vendiéndolas todas al objetivo, tras la comisión de la subasta (5 %, o la que hayas puesto con `/oro comision`) y perdiendo un depósito (una subasta que caduca).
  - **Estimado: confirma en la subasta:** se calculó con tu último escaneo. Si abres el objeto en la pestaña Comprar, el addon lo recalcula con lo que de verdad hay a la venta (sin tus propias subastas) y dice «Precio confirmado en la subasta».
- **Posible chollo:** el escaneo del addon trae cuántas unidades hay a cada precio, pero el que Auctionator hace por defecto (su botón «Full Scan» y el de escanear al abrir la subasta) trae solo el precio mínimo de cada objeto. Si el precio es de chollo y el addon no sabe cuántas hay, no puede calcular la compra: la sección dice «Posible chollo: Paño rúnico a 60p (40 % por debajo de lo normal)». Ábrelo en la subasta, en la pestaña Comprar o desde la lista de **Comprar lo que falta**, y el addon hace la cuenta con lo que hay a la venta. Para que el escaneo traiga las cantidades, escanea con el addon (botón **Escanear**) o, en las opciones de Auctionator, apartado **Advanced**, marca **Use alternate slower scan mode by default** (el escaneo completo por réplica).
- **Comprar:** el botón **Comprar lo que falta** (o `/oro comprar`) pone los chollos, con su cantidad, en la lista «Oro de Hermandad» de Auctionator (sin Auctionator, escribe el nombre del siguiente en la búsqueda de la subasta). Comprar es siempre cosa tuya: el addon nunca compra solo.
- **Presupuesto:** por defecto, el 25 % del oro que llevas. Cada chollo usa como mucho la cuarta parte y entre todos no pasan del presupuesto. Cámbialo con `/oro especular presupuesto 200` (oros) o en el panel de opciones; `/oro especular presupuesto auto` (o 0) vuelve al 25 %.
- **Vende ahora:** algo que llevas (o tienes en el banco) está al menos un 25 % por encima de lo normal. No te sugiere vender herramientas ni pociones, frascos o comida que no fabricas.
- **Balance de la semana:** los 3 objetos que más suben y los 3 que más bajan en 7 días, solo con un precio normal orientativo o fiable, y el cambio por categoría. Para verlo todo, el botón **Tabla** (lo mismo que `/oro tabla`).
- **Descripción de los objetos:** en los vigilados verás «Normal (14 d) 1o · hoy -40 %» y, si hay chollo, cuántas comprar y a cuánto como máximo; si el precio está alto o bajo, también lo dice. Solo lo llama «Chollo» si el modo lo admite: un precio de chollo con un precio normal aún orientativo en Tranquilo, o que no viene de un escaneo de las últimas 2 horas, sale como «Precio bajo»; si no se sabe cuántas hay, «Posible chollo».
- **En Tranquilo y A tope:** Tranquilo enseña como mucho 1 chollo, y solo si es fiable; A tope, hasta 2. `/oro especular off` los quita de esos modos y de la descripción de los objetos; el modo Especular sigue funcionando.

**Riesgos:**
- **El precio mínimo publicado no es una venta confirmada.** Es lo que alguien pide, no lo que alguien paga: un objeto puede pasar días sin venderse a su precio normal. Compra solo lo que estés dispuesto a guardar un tiempo.
- **Protección de lanzamiento:** hasta el 18-nov (14 días después del lanzamiento del 4-nov) no sugiere ninguna compra para revender, porque los precios del lanzamiento no paran de bajar. Sí avisa de precios altos para vender.
- **Datos necesarios:** sin 7 días de precios no hay precio normal; los chollos piden 10 días, y los de Tranquilo, 12 y poca variación. Si un objeto baja más de un 10 % en unos días (o sube mucho), no da chollos. Si eso pasa a la mitad o más de los objetos que ya tienen tendencia (hacen falta al menos 3), la sección dice «Mercado bajando: 4 de 6 objetos han caído más de un 10 % en unos días. Vende pronto lo que farmees y no compres para revender.» (en Tranquilo y A tope, solo si la sección tiene alguna fila). Si el precio lleva dos días por debajo de lo normal, es un precio nuevo y no un chollo.
- **La reventa cuesta:** con un 5 % de comisión el precio tiene que subir un 5,3 % solo para no perder, y cada subasta que caduca se queda con su depósito.
- **Todo son reglas probadas con datos simulados:** se ajustarán con los precios reales de las primeras semanas.
- **Lo que sale de tu PC:** los precios de tus escaneos completos, a tu hermandad (ver «Precios compartidos con la hermandad»; se apaga con `/oro compartir off`), y, si usas el subidor de la hermandad, el bloque `OroHermandadHist` (precios de los objetos vigilados) al panel.

Los patrones por día de la semana no salen en el juego: un solo jugador no junta datos suficientes. Los da el panel de la hermandad, fuera del juego; la hora del día, también en el juego con «Cuándo vender».

## Precios compartidos con la hermandad

Desde la 0.4.0, cada addon de la hermandad comparte lo que ve en la subasta, sin que nadie tenga que hacer nada (desde la 0.5.1, también el pescado). Las versiones se entienden entre sí: quien tenga la 0.4.0 o la 0.5.0 recibe lo de la 0.5.1 sin el pescado, y lo suyo llega igual que siempre. Así el panel de la hermandad se alimenta con los escaneos de todos aunque solo una o dos personas tengan el subidor en su PC, y en el juego cada uno tiene antes precio normal y precios más recientes.

**Qué se comparte.** Al terminar un escaneo completo de la subasta (de los que se guardan: como mucho 8 al día), Oro de Hermandad comparte con tu hermandad, por el canal oculto de los addons (no se ve en el chat), el precio más bajo y las unidades de los objetos de la lista fija (161 desde la 0.5.1, con la pesca; en la 0.4.0 y la 0.5.0 eran 114, sin la pesca), la hora del escaneo y el reino y la facción. Desde la 0.6.0 los escaneos llevan también una estimación de cuántas unidades se vendieron entre dos escaneos (sin nombres); las versiones anteriores la ignoran y se quedan con los precios. Nada más: ni tu oro, ni tus bolsas, ni tus subastas, ni tus objetos extra de `/oro vigilar`. Los PC con el subidor envían esos precios al panel identificados solo con un código de 8 cifras por personaje (un hash del nombre del personaje y de la hermandad): los nombres de los personajes nunca salen del juego. Ese código es seudónimo, no anónimo: quien conozca la lista de la hermandad podría calcularlo. Si no quieres compartir tus escaneos, escribe `/oro compartir off`: desde ese momento no sale ninguno más, tampoco los que aún esperaban en la cola (por ejemplo, porque estabas en una mazmorra).

**Invisible.** No sale nada en el chat, no suena nada, no se abre ninguna ventana y no hay que pulsar nada. No toca Auctionator ni la subasta: usa lo que el addon ya apuntó de tu escaneo. Nunca envía nada en combate, en mazmorras, bandas, campos de batalla o arenas, ni cuando el juego restringe los mensajes de addon: lo deja en cola y sale después. Va detrás de los mensajes de profesiones de la hermandad, respeta el ritmo que admite el servidor y lo pesado lo hace por tandas cortas, para que el juego no se trabe. Cada personaje comparte como mucho un escaneo cada 15 minutos; los que tengan la 0.3 o la 0.2 simplemente ignoran estos mensajes.

**Quién lo recibe y para qué.**
- Todos los que tienen la 0.4.0 o posterior guardan lo que comparten sus compañeros conectados (15 días de precios, 72 h de escaneos, 40 compañeros por reino y facción como mucho, con su propio tope de 4 MB desde la 0.6.0: si no cupiera, se recortan antes los escaneos de más de 48 h y los días más viejos de cada uno que a ningún compañero) y lo usan en Especular: el precio normal sale antes porque junta tus días y los suyos, y si un compañero escaneó hace poco se ve su precio: «Un compañero lo vio hace 10 min.». Nunca se dice quién.
- Lo de los compañeros se compara con lo tuyo: si alguien da precios de menos de la mitad o más del doble que tú, no se usa. Con datos de compañeros, «Fiable» pide precios de al menos 2 personas, como en el panel.
- Un chollo con el precio de un compañero sale siempre como **Posible chollo**: ábrelo en la pestaña Comprar de la subasta y el addon hace la cuenta con lo que de verdad hay a la venta.
- **El subidor (1 o 2 PC bastan):** quien tenga el subidor de precios en su PC envía al panel lo suyo y lo que han compartido los demás, cada uno como una persona distinta. Además pide a la hermandad los escaneos que se perdió mientras no estaba (de las últimas 72 h): al entrar en el juego (si entras en una mazmorra o en combate, en cuanto sales), y por susurro a cada compañero que entra después. Esas respuestas también van por el canal oculto; si un compañero tiene muchos escaneos guardados, llegan del más viejo al más nuevo, unos pocos cada 11 minutos, sin que nadie haga nada.
- El subidor crea en tu PC la carpeta `Interface\AddOns\OroHermandad_Subidor` (un aviso de dos archivos que no hace nada más) para que el addon sepa que ese PC sube los precios (ver «Subidor del PC»). **La primera vez, sal del juego del todo y vuelve a entrar**: un `/reload` no ve carpetas nuevas. Hasta entonces, o si el subidor no puede crearla, escribe una vez `/oro subidor on`. `/oro subidor off` lo apaga y `/oro subidor auto` vuelve a lo normal (activado si está el aviso).
- `/oro estado` dice cuántos compañeros te han compartido precios en este reino y facción, y `/oro sondeo` añade cómo va (sin nombres ni códigos).

**Límites.**
- Lo que un compañero escaneó cuando no había nadie con el subidor conectado solo llega al panel si alguien con el subidor está en el juego a la vez que él en las 72 h siguientes.
- Cada personaje cuenta como una persona: los alts de quien no usa el subidor cuentan como personas distintas (los de quien lo usa, no).
- Si un compañero sale del juego justo cuando el addon le responde por susurro, el juego puede escribir una vez «No hay ningún jugador llamado…».
- Si cambias de hermandad, tu código cambia; lo viejo se olvida en 15 días.
- Solo comparten los que usan el mismo reino (`/oro reino`; ver «Mercado» en «Historial de precios»). Mientras el juego no dé el reino, los compañeros que sigan con la 0.5.x no comparten ni reciben: que actualicen a la 0.6.0.
- Si actualizas el addon y solo haces `/reload`, lo que va en archivos nuevos (los precios compartidos al pasar a la 0.4.0; el escáner y «Cuándo vender» al pasar a la 0.6.0) no funciona hasta que sales del juego del todo y vuelves a entrar. Todo lo demás sí, y `/oro sondeo`, `/oro escanear` y `/oro cuando` lo dicen.
- **Si vuelves a la 0.3.1:** verá el historial de la 0.4.0 como de una versión más nueva y no lo tocará (ni apuntará precios mientras tanto); al volver a la 0.4.0 está todo. El subidor también tiene que ser el nuevo: el antiguo avisa de que no entiende el formato 2 del historial.

## Subidor del PC

El subidor de la hermandad es una ventana para Windows, **«Oro de Hermandad · Subidor»**: se descarga del panel de la hermandad («Subidor para Windows»), no necesita instalar Python y sube sola mientras está abierta.

1. Clic derecho en el zip → Propiedades → marca «Desbloquear» → Aceptar (si no, Windows puede bloquear el lanzador porque viene de internet).
2. Extrae la carpeta.
3. Abre «Abrir subidor.cmd» (la primera vez te ofrece un acceso directo en el escritorio).

- **Quien tiene el subidor actualiza primero** el addon y el subidor a la 0.6.0: si no, el panel no recibe las ventas.
- WoW solo guarda los precios en el disco al recargar la interfaz o al salir del juego. En el PC del subidor, cuando hay algo nuevo, la ventana del addon tiene el botón **Guardar y subir** (o `/oro guardar`): pide confirmación dentro de la ventana y recarga la interfaz, para que el subidor, si está abierto, envíe los precios en unos segundos en vez de al salir. Nunca recarga solo ni en combate, y está desactivado mientras aún se guardan precios o si hoy a tu clave le quedan 2 envíos o menos en el panel.
- El pie de la ventana y `/oro subidor` cuentan lo que dice el subidor: el último envío aceptado y cuántas personas aportan precios, si el panel rechazó la clave o pide esperar, o si el subidor no parece abierto (su último aviso ya tenía más de 2 h al entrar en el juego o recargar: el juego solo lo lee entonces).
- El subidor solo lee el archivo que WoW ya ha guardado y escribe su carpeta de aviso: no toca el juego, ni su memoria, ni pulsa teclas.

## Descripción de los objetos

Al pasar el ratón por un objeto verás:
- su precio en la subasta y de cuándo es;
- en los objetos vigilados, su precio normal y el aviso de Especular que toque (chollo, precio alto o bajo), y la mejor franja para venderlo («Cuándo vender»);
- quién de tu hermandad lo usa;
- cuántos tienes en el banco.

Se desactiva con `/oro info off` (las líneas de Especular, también con `/oro especular off`).

## Hermandad

- Lo que se comparte entre quienes tienen el addon:
  - tu nivel;
  - tus profesiones con su nivel;
  - tus 8 recetas más rentables (producto, beneficio y materiales);
  - desde la 0.4.0, los precios de tus escaneos completos de la lista fija (ver «Precios compartidos con la hermandad»).
- No se comparten ni bolsas, ni oro, ni tus ventas.
- Tus datos se envían al entrar y cuando cambian tus profesiones o tus recetas. Si no han cambiado, no se repiten antes de media hora; `/oro sync` los envía igualmente y pide los de los demás.
- Si alguien no tiene el addon, el addon lee su profesión del roster de la hermandad cuando el juego la ofrece. También lo puedes añadir a mano con `/oro amigo Nombre profesión nivel`.
- Solo se aceptan datos por susurro de miembros de tu hermandad.
- En mazmorras, bandas y encuentros el juego bloquea los mensajes de addon: el intercambio con la hermandad se pausa y sigue al salir. Ahí tampoco se lee el roster, y lo guardado no se borra.
- Los datos se guardan por hermandad. Si venías de la versión 0.1, los amigos que añadiste a mano pasan a tu hermandad actual al entrar. Si en la 0.2.0 añadiste a alguien con tu reino (`/oro amigo Ana-Forever …`), pasa a ser `Ana` y ya no sale dos veces.
- Los datos de alguien que deja de usar el addon desaparecen a los 30 días.

## Oro de la sesión

La sesión empieza al entrar con el personaje (un `/reload` no la reinicia). Pasados 5 minutos de sesión, el pie de la ventana (y `/oro estado`) muestra lo que has ganado desde que entraste y tu oro por hora; antes, el cálculo por hora no es fiable. Para ver el detalle en cualquier momento, también en esos primeros minutos, usa `/oro sesion`; para empezar de cero, `/oro sesion reset`.

## Comandos

```text
/oro                       abre o cierra la ventana
/oro tranquilo | atope | especular   cambia de modo
/oro especular on | off    chollos y precio normal también en Tranquilo, A tope y la descripción de los objetos
/oro especular presupuesto 200 | auto   oro para chollos (auto: el 25 % del que llevas)
/oro estado                precios, profesiones y hermandad
/oro escanear              escanea la subasta entera ahora (unos segundos) o dice por qué no
/oro escanear lista | parar   busca uno a uno los objetos vigilados (2-3 min) | para lo que esté en marcha
/oro escanear auto | proponer | off   escanear cada vez que abres la subasta | que te lo proponga | solo con el botón
/oro cuando [objeto]       a qué hora se vende mejor (hora de España); el objeto por nombre, número o enlace
/oro comprar               lo que falta para tus recetas (A tope) y los chollos: lista en Auctionator o, sin él, búsqueda en la subasta
/oro sesion [reset]        oro de la sesión
/oro amigo Ana ingenieria 150   añade a alguien a mano
/oro amigo borrar Ana      lo quita
/oro sync                  envía tus datos a la hermandad y le pide los suyos (con el subidor, también los precios que te perdiste)
/oro compartir on | off    comparte con la hermandad los precios de tus escaneos completos (por defecto, sí)
/oro subidor on | off | auto   este PC pide a la hermandad los precios que se perdió (auto: si está el aviso del subidor)
/oro guardar               en el PC del subidor: recarga la interfaz para que WoW guarde y el subidor envíe
/oro comision 5            porcentaje que se queda la subasta
/oro tabla                 precios guardados de la lista vigilada, para copiarlos a Excel
/oro vigilar [enlace]      guarda también los precios de ese objeto (Mayús+clic en él); sin enlace, lista tus extras
/oro olvidar [enlace]      deja de vigilarlo y borra sus precios guardados
/oro reino                 el reino de tus precios y de dónde sale (WoW Forever ya no lo da)
/oro reino <nombre> | borrar   usa el reino de tu hermandad (con sus mayúsculas) | vuelve a lo automático
/oro sondeo                diagnóstico para pegarlo en una incidencia
/oro opciones              panel de opciones (Esc > Opciones > Addons o Accesorios)
/oro auto | minimapa | sonido | info  on/off
```

## Límites conocidos

- **Datos de recolección:** las zonas y el rendimiento por veta son los de WoW Classic y aproximados. Las vetas y hierbas nuevas de Forever no están en la tabla. Las recetas, en cambio, se leen del juego, así que las nuevas de Forever sí se tienen en cuenta.
- **Material exclusivo de Forever:** el addon tiene en cuenta el Azerotio y el Torio pesado solo si el juego confirma que esos objetos existen.
- **Precios de mercader:** son aproximados hasta que el personaje visita un mercader; a partir de entonces el addon usa lo que le cobran a él (con sus descuentos de reputación). Cada personaje guarda los suyos, y lo que no puede comprar (en rojo) no se apunta.
- **Pruebas:** probado con las pruebas automáticas y en el juego (cliente 1.60.1.71037, 22 de noviembre de 2026). En el juego se ha comprobado: el escaneo de la subasta entera (300 550 subastas en unos 2 s, sin trabar el juego) se guarda en su mercado; reconoce la subasta de tu facción y tus propias subastas en el escaneo; el reino sale bien aunque el juego lo dé vacío; los precios se comparten entre dos compañeros de la hermandad; «Cuándo vender» suma tus escaneos y los de los compañeros; el subidor nuevo recibe los datos y los sube al panel; y «Guardar y subir» recarga la interfaz y los datos llegan al panel. Falta por comprobar en el juego: que en la subasta neutral no se guarde nada y el subidor en un Windows recién instalado. El addon se ha comprobado contra el código de la interfaz de Blizzard para Forever (1.60.1) y con un cliente simulado (Lua 5.1). La primera vez que lo uses, activa `/console scriptErrors 1` y avisa de cualquier error (ver «Si algo falla»).
- **Ventas estimadas:** son una estimación en los dos sentidos (ver «Cuándo vender»). De noche, si nadie de la hermandad escanea, no hay datos: el addon lo dice («pocos datos») en vez de inventarlo.

## Si algo falla

1. Escribe `/console scriptErrors 1` y repite lo que hacías.
2. Copia el texto del error y pásaselo a quien mantenga el addon.
3. Mientras tanto puedes desactivarlo desde la lista de addons (en la pantalla de personajes, **Menú** → **Addons** o **Accesorios**, según el idioma del juego; dentro del juego, Esc → **Addons** o **Accesorios**). No toca tus subastas ni tus objetos: solo lee y sugiere.

## Para desarrolladores

- Desde la raíz del repositorio, con Lua 5.1 (la versión de WoW):

  ```text
  sh test-lua/run.sh
  node scripts/build-oro-hermandad.mjs
  ```

  El primer comando ejecuta las pruebas. El segundo crea `dist-addon/OroHermandad.zip`, con los saltos de línea normalizados para que salga igual en Windows y en Linux. Git ignora esa carpeta: los ZIP generados no se suben al repositorio. No va en `public/`, que es la carpeta de la web: lo que hay ahí se publica al desplegar.
- `Engine.lua` y `Spec.lua` son lógica pura, sin API del juego. Cada modo de `Engine.MODES` define todas sus banderas (`Engine.MODE_KEYS`) y un límite para cada sección (también `spec`): el motor nunca pregunta por el nombre del modo, así que un modo nuevo no puede comportarse sin querer como otro. `Spec.lua` (Especular v1) debe dar los mismos enteros que `src/especular.mjs` del panel de la hermandad: el contrato es `test-vectors/especular-v1.json`.
- `Scanner.lua` (0.6.0) es el escáner de la subasta: un gancho en `C_AuctionHouse.ReplicateItems` ve las peticiones de cualquier addon, `REPLICATE_ITEM_LIST_UPDATE` solo se escucha 60 s tras una petición, la lectura va por tandas de 1,5 ms, la huella de 32 filas descarta una respuesta repetida, y apunta precios, ventas estimadas (`Spec.InferSold`), tus ventas y tus compras. `Timing.lua` (0.6.0) es «Cuándo vender»: sumas que se olvidan con media vida de 14 días por objeto y franja, la regla de consejo C11 (`test-lua/fixtures/v06/timing-advice.json`, la misma que el panel) y una primera pasada al entrar que no cuenta dos veces lo ya sumado. Core los llama con llamadas protegidas: sin esos archivos (un `/reload` tras actualizar) todo sigue como la 0.5.1.
- `History.lua` es el lado del juego del historial: recibe los escaneos del escáner (`RecordAggregate`) y los de Auctionator por tandas, importa su historial, aprende los depósitos y escribe `OroHermandadHist` con el formato del contrato 2 (cadenas `d,lo,hi,last,qty,scans,src` por día y `t,lo,qty,qty5[,dt,sold]` por escaneo). Desde la 0.4.0 es el esquema 2: cada mercado lleva además `self` (los códigos de tus personajes) y `obs` (lo de los compañeros, con su tope de 4 MB aparte); el esquema 1 se lee sin perder nada.
- `Relay.lua` son los precios compartidos (relay-v1): mensajes `P3` (resumen de un escaneo entero, en partes de 250 bytes como mucho) y `Q3` (petición de la puesta al día), con el mismo prefijo `OroHerm` y la cola de `Guild.lua` (una subcola de menos prioridad que nunca envía en combate, instancias ni con restricciones). El código de cada personaje es FNV-1a de 32 bits de `reino de la hermandad/hermandad|nombre-reino` en minúsculas, calculado por quien recibe con el remitente que da el servidor. Las pruebas `test-lua/test_relay.lua` hacen hablar entre sí a varios clientes simulados (y a la 0.3.1 y la 0.2.0, que ignoran los mensajes nuevos) y usan los datos compartidos con el subidor y el panel de `test-lua/fixtures/relay/`.
- `test-lua/wow_stub.lua` simula el cliente moderno de Forever: sin `GetItemInfo` global, con `C_TradeSkillUI`, bolsa de componentes, banco por pestañas, roster, escaneos de Auctionator con filas como las reales, su historial interno, los depósitos de `C_AuctionHouse` y, desde la 0.6.0, la subasta entera (réplica con su espera de 15 min, avisos repetidos de la caché de objetos), búsquedas, publicar y comprar (protegidos), mapas y `/reload`. `test_scanner.lua` y `test_timing.lua` prueban el escáner y «Cuándo vender»; los datos compartidos con el subidor y el panel están en `test-lua/fixtures/v06/`, fijados por SHA-256.
- El flujo `.github/workflows/oro-hermandad.yml` ejecuta las pruebas, construye el zip y lo deja en la ejecución como artefacto `OroHermandad.zip` (pestaña **Actions**, «Comprobar addon Oro de Hermandad»).
- **Publicar una versión:** la publica una persona con **Actions → Publicar Oro de Hermandad** (comprueba que la versión es la misma en la etiqueta, el TOC, `Core.lua`, `History.lua` y `CAMBIOS.md`, sube a GitHub el addon y el subidor y, después, el addon a CurseForge). Antes, sube la versión en esas cuatro líneas y escribe su sección en `CAMBIOS.md` (`## X.Y.Z (AAAA-MM-DD)`). Los pasos de las personas están en `CONTRIBUTING.md`.
