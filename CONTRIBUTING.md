# Trabajar en El Especulador del WoW

## Acceso y ramas

Repositorio: `https://github.com/carulla94/el-especulador-del-wow`.

El repositorio es público: cualquiera puede leer el código, pero para subir ramas el propietario debe invitar al usuario de GitHub del compañero en **Settings > Collaborators**. No hace falta compartir contraseñas de GitHub, Cloudflare o de la app. Una invitación de código permite trabajar en el proyecto; no concede por sí sola la contraseña de acceso a la cartera.

Clona el repositorio una vez aceptada la invitación:

```text
git clone https://github.com/carulla94/el-especulador-del-wow.git
cd el-especulador-del-wow
git switch -c mejora/nombre-del-cambio
npm install
```

Usa una rama por cambio y abre una pull request con el problema, la solución y las comprobaciones realizadas. Revisa el diff antes de fusionar. **Un cambio en `main` ejecuta el flujo de Cloudflare y puede actualizar la app real**, incluidos sus cambios de almacenamiento. No renombres `Portfolio`, el Worker o sus migraciones para pruebas. El flujo de GitHub Pages se ejecuta manualmente desde Actions.

## Entorno

- Node.js 24.16.0 es la versión de los flujos; mínimo 22.13 para las pruebas que usan SQLite de Node.
- Python 3.10 o superior para el sincronizador y sus pruebas; los flujos usan Python 3.13.
- `npm install` añade Wrangler para el desarrollo y despliegue de Cloudflare. La aplicación no tiene dependencias de ejecución npm.

```text
npm test
python -m unittest discover -s pc_sync -p "test_*.py" -q
```

## Revisar la edición de GitHub Pages

```text
npm run build:pages
python -m http.server 8000 --bind 127.0.0.1 --directory dist-pages
```

Abre `http://127.0.0.1:8000/`. Para comprobar también una ruta de proyecto, inicia el servidor en la raíz del repositorio sin `--directory` y abre `http://127.0.0.1:8000/dist-pages/`. Las importaciones, assets y descargas deben funcionar en ambas rutas.

Pages guarda los datos en IndexedDB y no llama al backend de Cloudflare. Usa datos de prueba y conserva copias JSON. La misma cartera no se comparte automáticamente entre localhost, GitHub Pages, Cloudflare ni otros dispositivos. No interpretes el modo local como una cuenta con autenticación.

## Revisar la edición de Cloudflare

```text
npm run dev
npm run check:deploy
```

Para entrar en desarrollo, configura una contraseña de prueba de al menos 16 caracteres mediante `.dev.vars`, usando la clave `OWNER_PASSWORD`. Ese archivo está excluido de Git. Usa exclusivamente credenciales de prueba locales. Wrangler indica la URL del servidor de desarrollo. La base de desarrollo local es independiente de producción; no ejecutes operaciones remotas sobre la cartera real para probar una interfaz.

No publiques con `npm run deploy` sin revisar destino, bindings, migraciones y autorización del propietario. No escribas la contraseña de producción en el repositorio, una captura, un issue o un log. No entregues la clave `CLOUDFLARE_API_TOKEN` a pasos de instalación, pruebas o código procedente de una pull request no revisada.

## Directorios

| Ruta | Responsabilidad |
| --- | --- |
| `public/` | Interfaz y estilos compartidos. En Cloudflare la app pide la contraseña del propietario y el panel de la hermandad, una clave personal. |
| `src/engine.mjs` | Cálculos de mercado, inventario FIFO y formato de copias. |
| `src/auctioneer.mjs` | Lectura restringida de SavedVariables de Auctioneer y del puente. |
| `src/worker.mjs` | Autenticación, API y coordinación de la cuenta en Cloudflare. |
| `src/storage.mjs` | Persistencia SQLite del Durable Object. |
| `src/guild.mjs` | Mercado de la hermandad: Durable Object `GuildMarket`, claves de miembros, envíos del sincronizador, resúmenes y CSV. |
| `src/especular.mjs` | Reglas «Especular v1» (chollos, flips, balances, días de la semana), gemelas del `Spec.lua` del addon. La construcción la copia a `public/especular.js`. |
| `test-vectors/` | Contrato compartido con el addon (`especular-v1.json`); no se edita: un cambio de reglas va en un archivo `-v2` nuevo. |
| `public/hermandad.*` | Panel de la hermandad (`/hermandad`): página, estilos y JavaScript con gráficos SVG propios. |
| `pages/` | Persistencia y adaptación de la edición local para Pages. |
| `scripts/build-pages.mjs` | Artefacto estático `dist-pages/`, sin secretos ni datos de usuario. |
| `addon/EspeculadorBridge/` | Puente experimental para el cliente real del juego. |
| `pc_sync/` | Envío opcional de archivos desde el PC a la cuenta en Cloudflare. |
| `test/` | Pruebas del motor, importadores, almacenamiento, transporte, mercado de la hermandad y su panel. |
| `.github/workflows/` | Validación y publicación de cada edición. |

## Antes de proponer un cambio

1. Ejecuta las pruebas que correspondan al comportamiento modificado.
2. Si toca la interfaz o Pages, construye `dist-pages` y comprueba navegación, importación, movimientos, recarga y copia JSON.
3. Si cambia la estructura de datos, verifica que las copias existentes siguen restaurándose y que un fallo de escritura no borra el estado anterior.
4. No subas bases de datos, SavedVariables personales, copias de cartera, archivos `.env`/`.dev.vars`, ZIP generados ni claves. Los cambios de permisos, publicación del repositorio y migraciones de producción requieren revisión explícita.
5. Documenta las limitaciones reales: los precios ofertados no son ventas confirmadas, y el puente necesita validación dentro del juego.
