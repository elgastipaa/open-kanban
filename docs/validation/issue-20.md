# Validación del issue #20 — Sincronizar con canales privados y revocación

## Matriz de aceptación y evidencia

| Criterio | Evidencia reproducible | Resultado y límites |
| --- | --- | --- |
| Señales sin contenido privado, publicadas solo por el servidor; canal privado ligado a `auth_epoch`; sin publicaciones nuevas al tema anterior después de revocar. | `corepack pnpm test:db` ejecuta `tests/db/realtime_epoch.sql` sobre PostgreSQL desechable y las migraciones 001–037. `node tests/realtime/epoch-smoke.mjs` usa dos clientes autenticados sintéticos contra Supabase Realtime local real. | PASS. Los cambios de autorización rotan el tema; el servidor publica `revalidate` en el tema previo dentro de la transacción de revocación. Las escrituras posteriores publican solo en el tema nuevo. Una señal anterior ya en tránsito puede llegar tarde al tema previo. |
| Refetch siempre autorizado; al reconectar, volver de background o cambiar de cuenta se descartan respuestas de época anterior y se limpia el contenido privado. | `tests/unit/board-auth-epoch.test.mjs` prueba el rechazo de un snapshot de época anterior. `src/components/board/board.tsx`, `src/hooks/use-board/use-board-sync.ts` y `src/lib/supabase/client.ts` validan el contexto autorizado, descartan respuestas de sesión/época anterior y limpian el estado al rotar la época o perder acceso. `corepack pnpm test:unit`. | PASS automático para la compuerta de época; pendiente verificación E2E autenticada en navegador de cambio de cuenta, reconexión y background. La ruta local ofrece Google OAuth; no se usó OAuth ni se inyectó una sesión fuera del flujo normal. |
| Cliente directo no cooperativo, canal público y señal tardía; diferenciar evento ya en tránsito de publicación posterior a la revocación. | `tests/realtime/epoch-smoke.mjs` se conecta con el cliente `@supabase/supabase-js` real, confirma que el canal público se suscribió, intenta emitir broadcast directo, recibe la señal previa de revocación, verifica el refetch denegado y observa una escritura posterior. `tests/db/realtime_epoch.sql` compara el conteo del tema anterior antes y después de una escritura posterior. | PASS en stack local real y en harness SQL. La única señal permitida en el tema anterior es la invalidación originada por la revocación; una entrega tardía por el transporte no equivale a una publicación nueva. |
| Primitive real de Supabase Realtime y rollback aislado; un error de Realtime no convierte una escritura confirmada en fallida. | `tests/realtime/realtime-send-rollback.sql` ejecuta el `realtime.send` instalado en el stack local y luego fuerza una excepción posterior a la señal para comprobar rollback conjunto de fila y mensaje. `tests/db/realtime_epoch.sql` verifica que una falla simulada de envío no revierte la mutación confirmada. | PASS. La función real captura errores y emite `WARNING`; un fallo interno de envío puede dejar la escritura confirmada sin señal. La UI avisa que la sincronización de otras sesiones puede demorarse y conserva el estado de escritura confirmada. No se interpreta `realtime.send` como confirmación de entrega. |
| Evidencia separada entre automática, manual y límites. | Esta matriz, los comandos de abajo y la lista de comprobaciones humanas pendientes. | La suite automatizada no se presenta como aceptación manual. |

## Stack y contrato observados

La validación de primitive y WebSocket se realizó en un stack local desechable propio de este issue, independiente de otros proyectos locales:

- Docker Engine 29.4.3.
- Supabase CLI 2.122.0, ejecutada con `corepack pnpm dlx` y el `supabase/config.toml` de este worktree.
- PostgreSQL `17.11.0.006` (`public.ecr.aws/supabase/postgres:17.11.0.006`).
- Supabase Realtime `v2.147.1` (`public.ecr.aws/supabase/realtime:v2.147.1`).
- `@supabase/supabase-js` 2.99.1.

La función instalada es `realtime.send(payload jsonb, event text, topic text, private boolean)`. En esta versión, `event` se guarda en una columna separada y el payload recibido por el cliente contiene el `id` generado por Supabase. Por eso las aserciones permiten únicamente la clave `id`; no esperan un payload literalmente `{}`. La señal emitida por la aplicación no incluye título, descripción, datos de tarea, board, persona ni credenciales.

El smoke de rollback verifica una excepción posterior a `realtime.send`: PostgreSQL revierte tanto el cambio de producto como el mensaje. La función real también captura sus propios errores, devuelve `WARNING` y permite que la transacción del cambio confirmado continúe. La capa SQL del harness que define `realtime.messages` simula el primitive; por sí sola no acredita el comportamiento de Realtime. Esa limitación se cubre con los dos scripts de stack local real.

Las políticas de autorización de Supabase Realtime se evalúan al unirse al canal; rotar el tema por `auth_epoch` invalida futuras uniones al anterior. Supabase documenta que los eventos emitidos pueden llegar tarde y que Broadcast no ofrece entrega garantizada: la señal provoca un refetch que vuelve a autorizar contra la base de datos, no transporta el contenido del tablero. Referencias: [Realtime Authorization](https://supabase.com/docs/guides/realtime/authorization) y [Broadcast](https://supabase.com/docs/guides/realtime/broadcast).

## Cómo repetir la prueba real en un entorno local aislado

Ejecutar solo con una instalación local/desechable, nunca con un proyecto vinculado. Después de `supabase start`, usar la CLI fijada y el worktree como directorio de trabajo:

```powershell
$envPath = 'C:\Users\gasto\.codex\test-envs\open-kanban-realtime-issue-20-r1'
corepack pnpm dlx supabase@2.122.0 db reset --workdir $envPath --yes
corepack pnpm dlx supabase@2.122.0 db query --local --workdir $envPath --file tests/realtime/prepare.sql
corepack pnpm dlx supabase@2.122.0 db query --local --workdir $envPath --file tests/realtime/realtime-send-rollback.sql
```

El archivo `prepare.sql` crea dos identidades y un tablero sintéticos (`@example.test`) en ese proyecto local. Recuperar `API_URL`, `PUBLISHABLE_KEY` y `JWT_SECRET` solo desde el `supabase status --output env` de ese stack, sin imprimirlos, y preparar:

```powershell
$env:ISSUE20_SUPABASE_URL = $apiUrlLocal
$env:ISSUE20_PUBLISHABLE_KEY = $publishableKeyLocal
$env:ISSUE20_JWT_SECRET = $jwtSecretLocal
$env:ISSUE20_BOARD_SLUG = $slugSintetico
node tests/realtime/epoch-smoke.mjs
```

El smoke firma tokens solo para los dos IDs sintéticos del fixture con el secreto JWT local, usa `role=authenticated` y pasa por RLS y RPC autorizadas. No usa OAuth, cuentas reales ni llaves de proyecto remoto.

## Comandos y resultados

- `corepack pnpm test:db` — PASS; suite completa en clúster PostgreSQL desechable, migraciones 001–037 y carreras concurrentes de task/column/board, retiro de miembro y suspensión.
- `corepack pnpm test:unit` — PASS; 139 pruebas, 0 fallidas.
- `node tests/realtime/epoch-smoke.mjs` — PASS; WebSocket privado local real, intento de broadcast directo, canal público suscrito, señal previa, refetch denegado y ausencia de publicación posterior en el tema anterior.
- `corepack pnpm build` — PASS con Next.js 16.4.2 y variables locales del stack.
- `corepack pnpm typecheck` — PASS después de `corepack pnpm exec next typegen`, que genera el `next-env.d.ts` ignorado requerido para los imports de imagen.
- `corepack pnpm exec biome check --formatter-enabled=false` sobre los 11 archivos TS/JS/JSON modificados — PASS.
- `corepack pnpm lint` — FAIL global con 171 diagnósticos de formato en 171 archivos por finales de línea CRLF del checkout. No se reformateó el repositorio; el slice modificado pasa Biome.

## Pendientes humanos y límites

- **Pendiente:** iniciar una sesión de usuario en navegador y comprobar cambio de cuenta, reconexión, retorno de background, borrado visible de contenido privado y preservación del borrador cuando el usuario conserva autorización. La pantalla local comprobada presenta «Entrar con Google»; no se completó OAuth ni se fabricó/injectó una sesión de navegador. La aceptación E2E visual permanece sin verificar.
- Realtime puede retrasar o perder señales. El flujo recupera mediante lecturas autorizadas al suscribirse/reconectar, al recuperar foco/visibilidad y cada 30 segundos mientras la página está visible.
- `WARNING` de `realtime.send` es registro del servidor, no recibo visible para el cliente. La interfaz diferencia una escritura confirmada de una sincronización demorada cuando detecta que el canal no está conectado; otros clientes pueden actualizarse más tarde.
