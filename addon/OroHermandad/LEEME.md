# Oro de Hermandad

Addon para WoW Forever que te dice qué hacer para ganar oro. Lee los precios de Auctionator, tus bolsas y tu banco, tus profesiones y las de tu hermandad, y te da una lista corta de acciones. También te avisa cuando los precios de la subasta están viejos.

Versión 0.2.0, para el cliente 1.60 de Forever (Interface 16001). La instalación está explicada paso a paso en `INSTALAR_ORO_DE_HERMANDAD.md`, en la raíz del repositorio.

## Cómo se usa

- Para abrir la ventana: **botón de la moneda** junto al minimapa, `/oro`, o el menú de accesorios del minimapa.
- Se abre sola, pegada a la subasta, cuando hablas con un subastador. Se cierra con ella.
- **Abre cada profesión una vez** (y cuando aprendas recetas nuevas) para que el addon las conozca.
- **Haz un escaneo completo en Auctionator** de vez en cuando, o activa en sus opciones **escanear al abrir la subasta**.

## Modos

| | Tranquilo | A tope |
| --- | --- | --- |
| Para qué | Subes de nivel o juegas con amigos | Sesión solo para hacer oro |
| Ventas | Una línea con todo | Una línea por objeto |
| Recetas | Solo las que puedes hacer con lo que llevas | También las rentables comprando materiales: qué falta, quién de la hermandad lo consigue y botón **Comprar lo que falta** |
| Recolección | Lo que más vale en zonas de tu nivel | Las 2 mejores rutas por profesión y la mejor tela para tu nivel |
| Banco | Solo si hay más de 1 oro para vender | Todo lo que vale la pena sacar y vender |
| Hermandad | 1 sugerencia | Hasta 4, y qué profesiones os faltan |
| Precios viejos a partir de | 24 h | 6 h |

## Qué te sugiere

- **Avisos**: cuándo ir al instructor porque una profesión está a punto de topar.
- **Ahora**:
  - fundir cuando el lingote vale más que el mineral, o fabricar recetas con beneficio;
  - qué vender en la subasta y qué vale más en el vendedor;
  - qué sacar del banco;
  - la chatarra gris.
  - Nunca te sugiere vender tus herramientas de profesión ni pociones o comida, salvo las que fabricas tú.
- **Recoger**: el mineral, la hierba o la piel que más vale de lo que tu nivel de profesión permite, con valor aproximado por veta, planta o bicho y las zonas donde abunda.
- **Hermandad**:
  - qué llevas que usa un amigo, según su profesión y su nivel;
  - recetas rentables de tus amigos con tus materiales;
  - piezas sin precio en la subasta para el mejor encantador;
  - qué profesiones le faltan al grupo.

Los importes ya descuentan la comisión de la subasta (5 % por defecto; puedes cambiarla con `/oro comision`).

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
- Si alguien no tiene el addon, el addon lee su profesión del roster de la hermandad cuando el juego la ofrece. También lo puedes añadir a mano con `/oro amigo Nombre profesión nivel`.
- Los datos se guardan por hermandad.
- Los datos de alguien que deja de usar el addon desaparecen a los 30 días.

## Oro de la sesión

El pie de la ventana muestra lo que has ganado desde que entraste y tu oro por hora. Para el detalle, `/oro sesion`; para empezar de cero, `/oro sesion reset`.

## Comandos

```text
/oro                       abre o cierra la ventana
/oro tranquilo | atope     cambia de modo
/oro estado                precios, profesiones y hermandad
/oro comprar               lista de la compra en Auctionator con lo que falta
/oro sesion [reset]        oro de la sesión
/oro amigo Ana ingenieria 150   añade a alguien a mano
/oro amigo borrar Ana      lo quita
/oro sync                  pide a la hermandad que comparta sus datos
/oro comision 5            porcentaje que se queda la subasta
/oro opciones              panel de opciones (Esc > Opciones > Accesorios)
/oro auto | minimapa | sonido | info  on/off
```

## Límites conocidos

- **Datos de recolección:** las zonas y el rendimiento por veta son los de WoW Classic y aproximados. Las vetas y hierbas nuevas de Forever no están en la tabla. Las recetas, en cambio, se leen del juego, así que las nuevas de Forever sí se tienen en cuenta.
- **Material exclusivo de Forever:** el addon tiene en cuenta el Azerotio y el Torio pesado solo si el juego confirma que esos objetos existen.
- **Precios de mercader:** son aproximados hasta que visitas un mercader; a partir de entonces el addon usa los reales.
- **Probado fuera del juego:** el addon se ha comprobado contra el código de la interfaz de Blizzard para Forever (1.60.1) y con un cliente simulado. Ha habido poco tiempo de pruebas dentro del juego, así que avisa de cualquier error.

## Si algo falla

1. Escribe `/console scriptErrors 1` y repite lo que hacías.
2. Copia el texto del error y pásaselo a quien mantenga el addon.
3. Mientras tanto puedes desactivarlo desde la lista de accesorios. No toca tus subastas ni tus objetos: solo lee y sugiere.

## Para desarrolladores

- Desde la raíz del repositorio, con Lua 5.1 (la versión de WoW):

  ```text
  sh test-lua/run.sh
  node scripts/build-oro-hermandad.mjs
  ```

  El primer comando ejecuta las pruebas. El segundo regenera `descargas/OroHermandad.zip`.
- `Engine.lua` es lógica pura, sin API del juego.
- `test-lua/wow_stub.lua` simula el cliente moderno de Forever: sin `GetItemInfo` global, con `C_TradeSkillUI`, bolsa de componentes, banco por pestañas y roster.
- El flujo `.github/workflows/oro-hermandad.yml` comprueba las pruebas y que el zip esté al día.
