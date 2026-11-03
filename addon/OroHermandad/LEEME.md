# Oro de Hermandad

Addon para WoW Forever que te dice qué hacer para ganar oro. Lee los precios de Auctionator, tus bolsas y tu banco, tus profesiones y las de tu hermandad, y te da una lista corta de acciones. También te avisa cuando los precios de la subasta están viejos.

Versión 0.2.1, para el cliente 1.60 de Forever (Interface 16001). **Todavía no se ha probado dentro del juego** (ver «Límites conocidos»). La instalación está explicada paso a paso en la guía `INSTALAR_ORO_DE_HERMANDAD.md`; pídela a quien te pasó el addon.

## Cómo se usa

- Para abrir la ventana: **botón de la moneda** junto al minimapa, `/oro`, o el menú de addons (o accesorios) del minimapa.
- Se abre sola, pegada a la subasta, cuando hablas con un subastador. Se cierra con ella.
- **Abre cada profesión una vez** (y cuando aprendas recetas nuevas) para que el addon las conozca.
- **Haz un escaneo completo en Auctionator** de vez en cuando, o activa en sus opciones **escanear al abrir la subasta**.

## Modos

| | Tranquilo | A tope |
| --- | --- | --- |
| Para qué | Subes de nivel o juegas con amigos | Sesión solo para hacer oro |
| Ventas | Una línea con todo | Una línea por objeto |
| Recetas | Solo las que puedes hacer con lo que llevas | También las rentables comprando materiales: qué falta, quién de la hermandad lo consigue y botón **Comprar lo que falta**. Lo que vende un mercader se compra allí, y lo que tienes en el banco se saca, no se compra |
| Recolección | Lo que más vale en zonas de tu nivel | Las 2 mejores rutas por profesión y la mejor tela para tu nivel |
| Banco | Solo si lo que sacas vale al menos 1 oro (para vender o para tus recetas) | Todo lo que vale la pena sacar: para vender o para tus recetas |
| Hermandad | 1 sugerencia | Hasta 4, y qué profesiones os faltan |
| Precios viejos a partir de | 24 h | 6 h |

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

Los importes ya descuentan la comisión de la subasta (5 % por defecto; puedes cambiarla con `/oro comision`).

## Precios de la subasta

- Solo un escaneo de Auctionator terminado cuenta como «precios al día»: su escaneo completo o el de **escanear al abrir la subasta**. Una búsqueda suelta, la pestaña Comprar o tus favoritos no.
- No busques nada mientras Auctionator escanea la subasta: una búsqueda (la barra de búsqueda o una lista de la compra) corta su escaneo y Auctionator lo da por terminado solo con lo que encontró esa búsqueda. El addon lo nota y no lo cuenta como escaneo. Por eso **Comprar lo que falta**, mientras dura el escaneo, solo crea la lista en Auctionator sin buscarla.
- Si los precios están viejos, te avisa al abrir la subasta, con un sonido. El mismo aviso no se repite en cada visita: vuelve solo si cambia o después de otro escaneo.
- Si acabas de hacer un escaneo completo y la subasta tiene poca oferta (un servidor nuevo, por ejemplo), te lo dice sin pedirte otro escaneo.

## Descripción de los objetos

Al pasar el ratón por un objeto verás:
- su precio en la subasta y de cuándo es;
- quién de tu hermandad lo usa;
- cuántos tienes en el banco.

Se desactiva con `/oro info off`.

## Hermandad

- Lo que se comparte entre quienes tienen el addon:
  - tu nivel;
  - tus profesiones con su nivel;
  - tus 8 recetas más rentables (producto, beneficio y materiales).
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
/oro tranquilo | atope     cambia de modo
/oro estado                precios, profesiones y hermandad
/oro comprar               (A tope) lista de la compra en Auctionator con lo que falta
/oro sesion [reset]        oro de la sesión
/oro amigo Ana ingenieria 150   añade a alguien a mano
/oro amigo borrar Ana      lo quita
/oro sync                  envía tus datos a la hermandad y le pide los suyos
/oro comision 5            porcentaje que se queda la subasta
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
- `Engine.lua` es lógica pura, sin API del juego.
- `test-lua/wow_stub.lua` simula el cliente moderno de Forever: sin `GetItemInfo` global, con `C_TradeSkillUI`, bolsa de componentes, banco por pestañas y roster.
- El flujo `.github/workflows/oro-hermandad.yml` ejecuta las pruebas, construye el zip y lo deja en la ejecución como artefacto `OroHermandad.zip` (pestaña **Actions**, «Comprobar addon Oro de Hermandad»), para descargarlo y repartirlo.
