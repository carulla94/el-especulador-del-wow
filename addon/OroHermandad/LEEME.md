# Oro de Hermandad

Addon para WoW Forever que te dice qué hacer para ganar oro. Lee los precios de Auctionator, tus bolsas y tu banco, tus profesiones y las de tu hermandad, y te da una lista corta de acciones. También te avisa cuando los precios de la subasta están viejos y, con el modo **Especular**, te señala chollos para comprar y revender.

Versión 0.4.0, para el cliente 1.60 de Forever (Interface 16001). **Todavía no se ha probado dentro del juego** (ver «Límites conocidos»). La instalación está explicada paso a paso en la guía `INSTALAR_ORO_DE_HERMANDAD.md`; pídela a quien te pasó el addon.

## Cómo se usa

- Para abrir la ventana: **botón de la moneda** junto al minimapa, `/oro`, o el menú de addons (o accesorios) del minimapa.
- Se abre sola, pegada a la subasta, cuando hablas con un subastador. Se cierra con ella.
- **Abre cada profesión una vez** (y cuando aprendas recetas nuevas) para que el addon las conozca.
- **Haz un escaneo completo en Auctionator** de vez en cuando o, mejor, activa en sus opciones **escanear al abrir la subasta**: así cada visita a la subasta apunta precios para ti y para tu hermandad (ver «Precios compartidos con la hermandad»).

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

- Solo un escaneo de Auctionator terminado cuenta como «precios al día»: su escaneo completo o el de **escanear al abrir la subasta**. Una búsqueda suelta, la pestaña Comprar o tus favoritos no.
- No busques nada mientras Auctionator escanea la subasta: una búsqueda (la barra de búsqueda o una lista de la compra) corta su escaneo y Auctionator lo da por terminado solo con lo que encontró esa búsqueda. El addon lo nota y no lo cuenta como escaneo. Por eso **Comprar lo que falta**, mientras dura el escaneo, solo crea la lista en Auctionator sin buscarla.
- Si los precios están viejos, te avisa al abrir la subasta, con un sonido. El mismo aviso no se repite en cada visita: vuelve solo si cambia o después de otro escaneo.
- Si acabas de hacer un escaneo completo y la subasta tiene poca oferta (un servidor nuevo, por ejemplo), te lo dice sin pedirte otro escaneo.

## Historial de precios

Desde la versión 0.3.0 el addon apunta los precios de una lista de materiales y consumibles comunes (114 desde la 0.3.1, con todo lo que da la recolección y lo que hace falta para valorar la fundición): minerales y lingotes, piedras, gemas, hierbas, cuero, tela, pociones, elixires, frascos, comida, vendas, materiales de encantamiento y esencias. Puedes añadir hasta 40 objetos más con `/oro vigilar`. Con estos datos funciona el modo Especular.

- **Cuándo apunta:** con cada escaneo terminado de Auctionator. Por cada día guarda el precio mínimo más bajo y el más alto, el último, cuántas unidades había a la venta y cuántos escaneos hubo. De los últimos 14 días guarda además cada escaneo con su hora. Una búsqueda que corta el escaneo de Auctionator solo apunta ese momento: no cuenta para el día. Tus propias subastas no cuentan como precio del mercado (en el escaneo completo).
- **Días que faltan:** al entrar, una vez al día, los rellena con el historial de Auctionator (sus últimos 21 días). Nunca sustituye lo que el addon vio por sí mismo.
- **Depósitos:** con la subasta abierta apunta cuánto cuesta publicar una unidad de cada objeto, según la duración.
- **Tamaño:** lo tuyo, como mucho 768 KB. Guarda 120 días por objeto; si hiciera falta, recorta primero los escaneos sueltos más viejos. Lo que comparten tus compañeros va aparte, con su propio tope de 2 MB (ver «Precios compartidos con la hermandad»).
- **`/oro tabla`:** abre una ventana con una tabla lista para pegar en Excel (columnas separadas por `;` y coma decimal). Tiene, por objeto, el precio de hoy, el normal de los últimos 14 días, el cambio en 1 y en 7 días (en %), el mínimo y el máximo de esos 14 días, la oferta de hoy, los días con precio y la confianza. Los precios van en oro: `0,0082` son 82 cobres. Ya sale seleccionada: pulsa Ctrl+C y pégala en Excel.
- **Privacidad:** se guarda en tu PC, en el archivo `WTF\Account\<cuenta>\SavedVariables\OroHermandad.lua`, en el bloque `OroHermandadHist`. Ahí solo hay precios de objetos (con su nombre, su precio de mercader, su categoría y los depósitos) por reino y facción, y los precios que han compartido tus compañeros, cada uno con un código de 8 cifras en vez de su nombre. No hay nombres de personajes, ni oro, ni profesiones. Desde la 0.4.0 el addon comparte con tu hermandad los precios de tus escaneos completos (lo explica «Precios compartidos con la hermandad»). El subidor de la hermandad, si lo usas en tu PC, envía al panel ese bloque y nada más de ese archivo.
- **`/oro sondeo`:** comprueba lo que el addon necesita saber del juego: la versión de Auctionator y la forma de sus escaneos, su historial, los depósitos y las duraciones de la subasta, y si el historial se guardó bien tras el último `/reload`. Cópialo de la ventana y pégalo en una incidencia: no lleva nombres de personajes ni tu oro. Hazlo una vez el primer día, con la subasta abierta, y repítelo tras un `/reload`.

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
- **Posible chollo:** el escaneo que Auctionator hace por defecto (su botón «Full Scan» y el de escanear al abrir la subasta) trae el precio mínimo de cada objeto, pero no cuántas unidades hay a ese precio. Si el precio es de chollo y el addon no sabe cuántas hay, no puede calcular la compra: la sección dice «Posible chollo: Paño rúnico a 60p (40 % por debajo de lo normal)». Ábrelo en la subasta, en la pestaña Comprar o desde la lista de **Comprar lo que falta**, y el addon hace la cuenta con lo que hay a la venta. Para que el escaneo traiga las cantidades, en las opciones de Auctionator, apartado **Advanced**, marca **Use alternate slower scan mode by default** (el escaneo completo por réplica, más lento).
- **Comprar:** el botón **Comprar lo que falta** (o `/oro comprar`) pone los chollos, con su cantidad, en la lista «Oro de Hermandad» de Auctionator. Comprar es siempre cosa tuya: el addon nunca compra solo.
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

Los patrones por día de la semana no salen en el juego: un solo jugador no junta datos suficientes. Los dará el panel de la hermandad, fuera del juego.

## Precios compartidos con la hermandad

Desde la 0.4.0, cada addon de la hermandad comparte lo que ve en la subasta, sin que nadie tenga que hacer nada. Así el panel de la hermandad se alimenta con los escaneos de todos aunque solo una o dos personas tengan el subidor en su PC, y en el juego cada uno tiene antes precio normal y precios más recientes.

**Qué se comparte.** Al terminar un escaneo completo de la subasta, Oro de Hermandad comparte con tu hermandad, por el canal oculto de los addons (no se ve en el chat), el precio más bajo y las unidades de los objetos de la lista fija, la hora del escaneo y el reino y la facción. Nada más: ni tu oro, ni tus bolsas, ni tus subastas, ni tus objetos extra de `/oro vigilar`. Los PC con el subidor envían esos precios al panel identificados solo con un código de 8 cifras por personaje (un hash del nombre del personaje y de la hermandad): los nombres de los personajes nunca salen del juego. Ese código es seudónimo, no anónimo: quien conozca la lista de la hermandad podría calcularlo. Si no quieres compartir tus escaneos, escribe `/oro compartir off`: desde ese momento no sale ninguno más, tampoco los que aún esperaban en la cola (por ejemplo, porque estabas en una mazmorra).

**Invisible.** No sale nada en el chat, no suena nada, no se abre ninguna ventana y no hay que pulsar nada. No toca Auctionator ni la subasta: usa lo que el addon ya apuntó de tu escaneo. Nunca envía nada en combate, en mazmorras, bandas, campos de batalla o arenas, ni cuando el juego restringe los mensajes de addon: lo deja en cola y sale después. Va detrás de los mensajes de profesiones de la hermandad, respeta el ritmo que admite el servidor y lo pesado lo hace por tandas cortas, para que el juego no se trabe. Cada personaje comparte como mucho un escaneo cada 15 minutos; los que tengan la 0.3 o la 0.2 simplemente ignoran estos mensajes.

**Quién lo recibe y para qué.**
- Todos los que tienen la 0.4.0 guardan lo que comparten sus compañeros conectados (15 días de precios, 72 h de escaneos, 40 compañeros por reino y facción como mucho, con su propio tope de 2 MB: si no cupiera, se recortan antes los días más viejos de cada uno que a ningún compañero) y lo usan en Especular: el precio normal sale antes porque junta tus días y los suyos, y si un compañero escaneó hace poco se ve su precio: «Un compañero lo vio hace 10 min.». Nunca se dice quién.
- Lo de los compañeros se compara con lo tuyo: si alguien da precios de menos de la mitad o más del doble que tú, no se usa. Con datos de compañeros, «Fiable» pide precios de al menos 2 personas, como en el panel.
- Un chollo con el precio de un compañero sale siempre como **Posible chollo**: ábrelo en la pestaña Comprar de la subasta y el addon hace la cuenta con lo que de verdad hay a la venta.
- **El subidor (1 o 2 PC bastan):** quien tenga el subidor de precios en su PC envía al panel lo suyo y lo que han compartido los demás, cada uno como una persona distinta. Además pide a la hermandad los escaneos que se perdió mientras no estaba (de las últimas 72 h): al entrar en el juego (si entras en una mazmorra o en combate, en cuanto sales), y por susurro a cada compañero que entra después. Esas respuestas también van por el canal oculto; si un compañero tiene muchos escaneos guardados, llegan del más viejo al más nuevo, unos pocos cada 11 minutos, sin que nadie haga nada.
- El subidor crea en tu PC la carpeta `Interface\AddOns\OroHermandad_Subidor` (un aviso de dos archivos que no hace nada más) para que el addon sepa que ese PC sube los precios. **La primera vez, sal del juego del todo y vuelve a entrar**: un `/reload` no ve carpetas nuevas. Hasta entonces, o si el subidor no puede crearla, escribe una vez `/oro subidor on`. `/oro subidor off` lo apaga y `/oro subidor auto` vuelve a lo normal (activado si está el aviso).
- `/oro estado` dice cuántos compañeros te han compartido precios en este reino y facción, y `/oro sondeo` añade cómo va (sin nombres ni códigos).

**Límites.**
- Lo que un compañero escaneó cuando no había nadie con el subidor conectado solo llega al panel si alguien con el subidor está en el juego a la vez que él en las 72 h siguientes.
- Cada personaje cuenta como una persona: los alts de quien no usa el subidor cuentan como personas distintas (los de quien lo usa, no).
- Si un compañero sale del juego justo cuando el addon le responde por susurro, el juego puede escribir una vez «No hay ningún jugador llamado…».
- Si cambias de hermandad, tu código cambia; lo viejo se olvida en 15 días.
- Si actualizas el addon y solo haces `/reload`, los precios compartidos no funcionan hasta que sales del juego del todo y vuelves a entrar (todo lo demás sí; `/oro sondeo` lo dice).
- **Si vuelves a la 0.3.1:** verá el historial de la 0.4.0 como de una versión más nueva y no lo tocará (ni apuntará precios mientras tanto); al volver a la 0.4.0 está todo. El subidor también tiene que ser el nuevo: el antiguo avisa de que no entiende el formato 2 del historial.

## Descripción de los objetos

Al pasar el ratón por un objeto verás:
- su precio en la subasta y de cuándo es;
- en los objetos vigilados, su precio normal y el aviso de Especular que toque (chollo, precio alto o bajo);
- quién de tu hermandad lo usa;
- cuántos tienes en el banco.

Se desactiva con `/oro info off` (las líneas de Especular, también con `/oro especular off`).

## Hermandad

- Lo que se comparte entre quienes tienen el addon:
  - tu nivel;
  - tus profesiones con su nivel;
  - tus 8 recetas más rentables (producto, beneficio y materiales);
  - desde la 0.4.0, los precios de tus escaneos completos de la lista fija (ver «Precios compartidos con la hermandad»).
- No se comparten ni bolsas ni oro.
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
/oro comprar               lista de la compra en Auctionator: lo que falta para tus recetas (A tope) y los chollos
/oro sesion [reset]        oro de la sesión
/oro amigo Ana ingenieria 150   añade a alguien a mano
/oro amigo borrar Ana      lo quita
/oro sync                  envía tus datos a la hermandad y le pide los suyos (con el subidor, también los precios que te perdiste)
/oro compartir on | off    comparte con la hermandad los precios de tus escaneos completos (por defecto, sí)
/oro subidor on | off | auto   este PC pide a la hermandad los precios que se perdió (auto: si está el aviso del subidor)
/oro comision 5            porcentaje que se queda la subasta
/oro tabla                 precios guardados de la lista vigilada, para copiarlos a Excel
/oro vigilar [enlace]      guarda también los precios de ese objeto (Mayús+clic en él); sin enlace, lista tus extras
/oro olvidar [enlace]      deja de vigilarlo y borra sus precios guardados
/oro sondeo                diagnóstico para pegarlo en una incidencia
/oro opciones              panel de opciones (Esc > Opciones > Addons o Accesorios)
/oro auto | minimapa | sonido | info  on/off
```

## Límites conocidos

- **Datos de recolección:** las zonas y el rendimiento por veta son los de WoW Classic y aproximados. Las vetas y hierbas nuevas de Forever no están en la tabla. Las recetas, en cambio, se leen del juego, así que las nuevas de Forever sí se tienen en cuenta.
- **Material exclusivo de Forever:** el addon tiene en cuenta el Azerotio y el Torio pesado solo si el juego confirma que esos objetos existen.
- **Precios de mercader:** son aproximados hasta que el personaje visita un mercader; a partir de entonces el addon usa lo que le cobran a él (con sus descuentos de reputación). Cada personaje guarda los suyos, y lo que no puede comprar (en rojo) no se apunta.
- **Sin probar todavía dentro del juego:** el addon se ha comprobado contra el código de la interfaz de Blizzard para Forever (1.60.1) y con un cliente simulado (Lua 5.1), pero aún no en el juego real. La primera vez que lo uses, activa `/console scriptErrors 1` y avisa de cualquier error (ver «Si algo falla»).

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
- `History.lua` es el lado del juego del historial: lee los escaneos de Auctionator por tandas, importa su historial, aprende los depósitos y escribe `OroHermandadHist` con el formato del contrato 2 (cadenas `d,lo,hi,last,qty,scans,src` por día y `t,lo,qty,qty5` por escaneo). Desde la 0.4.0 es el esquema 2: cada mercado lleva además `self` (los códigos de tus personajes) y `obs` (lo de los compañeros, con su tope de 2 MB aparte); el esquema 1 se lee sin perder nada.
- `Relay.lua` son los precios compartidos (relay-v1): mensajes `P3` (resumen de un escaneo entero, en partes de 250 bytes como mucho) y `Q3` (petición de la puesta al día), con el mismo prefijo `OroHerm` y la cola de `Guild.lua` (una subcola de menos prioridad que nunca envía en combate, instancias ni con restricciones). El código de cada personaje es FNV-1a de 32 bits de `reino de la hermandad/hermandad|nombre-reino` en minúsculas, calculado por quien recibe con el remitente que da el servidor. Las pruebas `test-lua/test_relay.lua` hacen hablar entre sí a varios clientes simulados (y a la 0.3.1 y la 0.2.0, que ignoran los mensajes nuevos) y usan los datos compartidos con el subidor y el panel de `test-lua/fixtures/relay/`.
- `test-lua/wow_stub.lua` simula el cliente moderno de Forever: sin `GetItemInfo` global, con `C_TradeSkillUI`, bolsa de componentes, banco por pestañas, roster, escaneos de Auctionator con filas como las reales, su historial interno y los depósitos de `C_AuctionHouse`.
- El flujo `.github/workflows/oro-hermandad.yml` ejecuta las pruebas, construye el zip y lo deja en la ejecución como artefacto `OroHermandad.zip` (pestaña **Actions**, «Comprobar addon Oro de Hermandad»). Cada versión se publica además en Releases con la etiqueta `oro-hermandad-vX.Y.Z` y el zip adjunto: al publicar una nueva, actualiza el enlace del paso 2 de `INSTALAR_ORO_DE_HERMANDAD.md`.
