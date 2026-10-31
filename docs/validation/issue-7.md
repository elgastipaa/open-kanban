# Issue #7 — evidencia de implementación

Fecha: 31/10/2026. Issue: «Capturar tareas consecutivas sin duplicados». Rama: `codex/issue-7`. Base fija: `1312906108fa2a4815dd1a42cd5d889d04a16951`. HEAD de código final antes de este informe: `2f88596beaf7d4ccc34c40d6dccb5b2c02b89bb5`.

Se conservó `Blocked by #6`. La autorización de secuencia permitió la implementación y pruebas locales con actores sintéticos; no satisface Auth/OAuth real ni permite cerrar #7.

## Entorno de verificación

- `pnpm test:db` aplica las migraciones 001–018 en un clúster PostgreSQL desechable creado por `scripts/test-db.sh`. La versión local disponible fue PostgreSQL 16.15. El script crea roles `anon` y `authenticated`, ejecuta migraciones, limpia el directorio temporal que él mismo creó y no consume `DATABASE_URL`, `PGHOST` ni credenciales externas.
- Los datos de prueba son sintéticos. El actor `40000000-0000-4000-8000-000000000002` crea y repite capturas; `40000000-0000-4000-8000-000000000001` prueba otra identidad, membresía revocada y consultas aisladas. Los actores y filas Auth solo existen en el clúster temporal.
- No se instaló Supabase CLI ni se probó PostgREST/Auth de extremo a extremo. No se leyó `.env` ni `.env.local`, no se usaron OAuth, sesiones reales, claves reales, personas reales ni producción.
- No hay runner de navegador headless preexistente. No se abrió Chrome/CUA ni se hizo login. El comportamiento visual, el teclado en navegador y la reconciliación en una sesión real quedan pendientes de recorrido manual.

## Criterios y evidencia

| Criterio | Estado | Evidencia y límite |
| --- | --- | --- |
| Crear solo al usar Enter o el botón, en la columna actual; blur no crea | **Parcial** | El formulario solo maneja Enter y el botón; se quitó el manejador `onBlur`. Sin runner de navegador, falta confirmar foco y eventos en escritorio/móvil. |
| Confirmación vacía el campo, mantiene la captura abierta y permite seguir en la misma columna | **Parcial** | El componente espera la confirmación del hook antes de vaciar y regenerar la operation_id, y vuelve a enfocar el input. Falta recorrido manual autenticado. |
| Ante fallo, conservar título y foco; retirar contenido si se deniega acceso | **Parcial** | `unavailable` conserva el borrador para reconciliar. Un error SQLSTATE `42501` se clasifica como `access_denied`: se limpia el título, se elimina el composer y se enfoca un aviso accesible sin contenido privado. El estado tiene prueba unitaria; el foco y el retiro visual aún no se verificaron en navegador. |
| Resultado durable y consulta por operation_id y carga esperada | **Probado en DB** | `task_capture_receipts` conserva actor, clave, board/column/task y hash. `get_task_creation_result_p` exige la carga esperada y la compara en servidor antes de devolver una tarea. No existe la variante pública solo por operation_id. |
| Replay idéntico devuelve el mismo task; distinta carga con la misma clave se rechaza | **Probado en DB** | `tests/db/task_capture.sql` comprueba que una consulta con la carga igual devuelve la tarea confirmada y que una carga distinta genera `23514` sin devolverla ni alterar tareas. El RPC de creación también rechaza el conflicto sin efecto parcial. |
| Vencimiento requiere reconciliación y evita reintento ciego | **Probado en DB; UI parcial** | Se vence la fila sintéticamente; la consulta con carga coincidente y el replay devuelven `expired_unknown`. Una carga distinta genera `23514` antes de resolver el task; el conteo no cambia. La consulta posterior del tablero solo ocurre después de reconciliar la misma carga. Falta confirmar este recorrido en navegador. |
| Mover una tarea capturada y reconciliar/repetir su intención original | **Probado en DB** | La prueba mueve la tarea a otra columna activa del mismo tablero, luego consulta y repite el RPC con el payload/operation_id original. Ambas respuestas conservan `task_id` y exponen el `column_id` actual; no crean otra tarea. |
| Doble envío y dos sesiones concurrentes crean una tarea | **Probado en DB; UI parcial** | El script retiene el row lock del board y ejecuta dos sesiones `authenticated` con la misma clave/carga; ambas obtienen el mismo task id y queda una receipt y una tarea. `pendingRef` evita doble submit en el componente; no fue verificado con navegador. |
| Respuesta perdida después del commit no duplica la tarea | **Probado en DB** | La primera respuesta se descarta deliberadamente; consulta por operation_id y carga esperada y replay identifican el task ya guardado. |
| Actor/autor derivados del servidor; validar tablero y columna actuales | **Probado en DB** | `created_by` coincide con `auth.uid()`. La creación valida membresía y columna actual. La consulta de recibo exige carga y autoriza el board solicitado antes de consultar la clave. Un miembro revocado recibe `42501` genérico; el estado `unavailable` queda para tablero/columna obsoletos de un actor aún autorizado. |
| Campos protegidos y cruces ajenos no producen escritura parcial | **Probado en DB** | La firma no acepta `created_by` ni `position`; el RPC legacy se elimina, `authenticated` no tiene INSERT directo y un intento directo con `created_by` falla sin agregar filas. Un actor sin membresía recibe `42501` genérico tanto para claves existentes como inexistentes, sin task/hash; un actor autorizado sigue obteniendo `not_found` o `confirmed` según su recibo. |
| Títulos vacíos/solo whitespace rechazados; no deduplicar ni emparejar por título | **Probado en DB** | Se rechazan espacios y `E'\t\n'` en create y consulta, sin recibo. El título normalizado se usa igual para crear y calcular el hash. Dos operation_id distintas con el mismo título crean dos tasks consecutivas; no se emparejan por título. |
| Mensajes y controles nuevos cumplen P12 | **Parcial** | El conflicto muestra «Asignar clave nueva» y «Descartar borrador sin reintentar»; la primera acción solo rota la clave, conserva texto/columna y no envía. Cada composer usa `useId()` para enlazar su `aria-describedby` con un mensaje único. Falta revisar visualmente su presentación y accesibilidad en navegador. |
| Mantener contratos C-01–112 y P/E posteriores | **Pendiente de revisiones finales** | Se mantuvo la base fija y no se modificó alcance. El coordinador hará las revisiones Standards y Spec contra la base después de este commit. |

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `pnpm test:db` | Pasa en PostgreSQL desechable. Incluye migraciones 001–018, replay/respuesta perdida, payload conflictivo, expiración, validación board/column, autoría, acceso/revocación, escritura directa protegida, carrera de dos capturas y carrera de captura contra revocación. Exit code 0. |
| `pnpm test:unit` | Pasa: 5 pruebas, 0 fallas, incluyendo transición de acceso denegado/recuperable y clasificación de `42501`. No reemplaza verificación de UI ni de PostgREST. |
| `pnpm exec biome check src/components/board/add-task.tsx src/lib/db/tasks.ts src/lib/task-capture-state.ts tests/unit/task-capture-state.test.mjs` | Pasa; revisó cuatro archivos, sin fixes. |
| `pnpm build` | Pasa con Next.js 16.4.2: compilación, tipos, generación estática y optimización de rutas terminaron correctamente. |
| `bash -n scripts/test-db.sh` | Pasa. |
| `pnpm exec next typegen` seguido de `pnpm typecheck` | Pasa. Next 16.4.2 generó los tipos locales y `tsc --noEmit` terminó sin errores. `next-env.d.ts` es generado/ignorado y no se incluye en el commit. Se confirmó previamente que este checkout no contiene archivos `.env*`; no se inspeccionó su contenido. |
| Revisión UI/teclado en navegador con Auth sintético | No disponible: no hay runner headless. Pendiente manual; no se simuló con mocks. |
| Supabase Auth/PostgREST local | No verificado. La evidencia DB corresponde a funciones/migraciones ejecutadas directamente en PostgreSQL, no acredita una sesión HTTP/Auth real. |

## Recorrido pendiente

Cuando #6 permita una sesión sintética legítima y exista runner local de navegador, recorrer con dos actores de prueba: crear varias tareas con Enter y botón; comprobar que blur no envía; verificar foco, limpieza y misma columna tras cada confirmación; desconectar la respuesta luego del commit y reconciliar por operation_id; repetir con expiración mostrando `expired_unknown` sin reintento; ante `42501`/`access_denied`, comprobar que se borra el borrador y el foco pasa al aviso accesible; ante errores recuperables (`unavailable`), comprobar que el título/foco se conserva para reconciliar; probar doble clic sin duplicado. Confirmar navegación móvil, teclado y anuncio accesible del estado.

Hasta verificar Auth/UI real y completar las revisiones Standards/Spec, #7 permanece abierto con `Blocked by #6` intacto. Estas pruebas locales no autorizan cierre, integración a `main` ni publicación.

## Corrección del conflicto durante la reconciliación — 31/10/2026

Commit de código: `ba9da528a30b02a6030632d83cd7327c98d0999c` (`fix #7 validate payload during reconciliation`). Se eliminó `get_task_creation_result_p(uuid)`: la única RPC pública de consulta exige operation_id, board, columna, título, descripción y prioridad, normaliza la carga y deriva su hash dentro de PostgreSQL. El resolver verifica acceso vigente antes de comparar ese hash; una clave conocida con carga distinta lanza `23514`, sin retornar la tarea anterior. La ruta de recibos vencidos usa la misma consulta con carga esperada antes de buscar la tarea en el tablero.

La prueba roja extendió `tests/db/task_capture.sql` antes del fix: `pnpm test:db` falló porque aún no existía la RPC de reconciliación con carga esperada. Con el fix, el mismo comando pasó en el clúster desechable con PostgreSQL 16.15. Casos añadidos entonces: carga igual resuelve confirmado y vencido; carga distinta para ambos estados genera `23514`; la variante solo por operation_id no existe ni tiene grant. La respuesta anterior `unavailable` a miembros revocados fue corregida por la regresión y el fix de la sección final. No se usaron mocks para declarar DB/servidor.

El cliente ahora consulta siempre con la intención completa; convierte `23514` a conflicto determinista y no interpreta un resultado anterior como éxito. La UI conserva título y columna y ofrece asignar una clave nueva sin enviar o descartar el borrador. Enter mientras hay conflicto tampoco vuelve a enviar la clave existente. El control conserva foco por código, pero este comportamiento visual/teclado sigue parcial por falta de runner de navegador; Auth/PostgREST real y OAuth también siguen sin verificar. No hay cierre de #7: mantiene `Blocked by #6` y requiere recorrido humano UI/Auth.

Verificación final sobre el HEAD de código indicado: `pnpm test:db` exit 0; `pnpm test:unit` exit 0 (2/2); `pnpm exec next typegen && pnpm typecheck` exit 0; `pnpm exec biome check src/components/board/add-task.tsx src/lib/db/tasks.ts` exit 0; `git diff --check` exit 0; `pnpm build` exit 0. La firma nueva no altera los límites de OAuth/Auth ni fue probada por PostgREST.

## Correcciones de acceso, traslado y whitespace — 31/10/2026

Commit de código: `3a3af46a7cc039d90b64f1b580bc0d174d65e373` (`fix #7 access loss and moved task reconciliation`).

- **Acceso (C-95/ERR-06):** `42501` ahora se distingue de los estados recuperables y se convierte en `access_denied`; `unavailable` conserva el borrador para reconciliar. La transición de acceso denegado borra el título, retira el composer sin diálogo y mueve el foco a un aviso `role="alert"` sin contenido del borrador. `tests/unit/task-capture-state.test.mjs` comprueba código y transición. Sin navegador/Auth real, el foco y retiro visual son evidencia parcial.
- **Asociación ARIA:** cada `AddTask` llama `useId()` y usa el mismo ID para `aria-describedby` y su nodo `output`, evitando colisiones entre composers. No hay runner/render de componentes establecido para una prueba determinística del DOM; queda verificación visual/accesible manual.
- **Tarea movida:** se agregó una regresión roja DB que creaba una tarea, la movía a una segunda columna del mismo board y consultaba/repetía el operation_id/payload original. Antes del fix devolvía `unavailable`; ahora sigue la receipt por `task_id`, mantiene autorización y validación de generación, y entrega estado/columna actuales sin duplicar.
- **Título whitespace:** una regresión con `E'\t\n'` comprueba que `create_task_p` y `get_task_creation_result_p` rechacen con `22023` y no dejen recibo. La normalización común elimina whitespace de ambos extremos y alimenta el hash en ambas rutas.

En el HEAD del commit `3a3af46a7cc039d90b64f1b580bc0d174d65e373` pasaron `pnpm test:db` en PostgreSQL desechable (migraciones 001–018 y actores sintéticos), `pnpm test:unit` (5/5), `pnpm exec next typegen && pnpm typecheck`, `pnpm build`, Biome dirigido y `git diff --check`. No se usaron mocks para declarar servidor/DB verificados. OAuth/PostgREST y recorridos de UI/teclado siguen pendientes; se mantiene `Blocked by #6` y #7 permanece abierto.

## Denegación uniforme después de revocación — 31/10/2026

La regresión DB de `tests/db/task_capture.sql` consulta una clave con recibo y una clave desconocida después de revocar al colaborador, y repite ambos casos con `create_task_p`. Antes del fix, `pnpm test:db` falló porque la consulta a la clave existente no lanzaba `42501`, mientras la clave desconocida sí terminaba en una ruta diferente. Tras el fix, las cuatro solicitudes reciben SQLSTATE `42501` y el mismo mensaje genérico `Board access is required`; la clave desconocida no deja receipt. Un usuario autorizado conserva los estados `not_found`/`confirmed`.

La migración valida y mantiene bloqueadas las filas vigentes de `application_access` y `board_memberships` antes de consultar la clave. El resolver ahora requiere `p_board_id`, limita la búsqueda del receipt a ese board y ya no expone el overload previo `resolve_task_capture_receipt_p(uuid, bytea)`; las funciones internas no tienen grants para `authenticated`. Las diferencias de generación/columna siguen comunicándose como `unavailable` solo después de autorizar al actor. El componente ya clasifica `42501` como `access_denied`, limpia y desmonta el borrador y enfoca un aviso sin texto privado. La transición tiene prueba unitaria existente; el foco visual y Auth/PostgREST real continúan pendientes.

`scripts/test-db.sh` agrega una carrera concurrente con PostgreSQL real: una sesión mantiene sin commit la revocación de la membresía mientras otra reconcilia el recibo. Se comprobó que el resolver espera el lock y devuelve la denegación genérica después del commit de la revocación, sin entregar la tarea.

Evidencia final del commit de código `2f88596beaf7d4ccc34c40d6dccb5b2c02b89bb5`:

- `pnpm test:db`: exit 0 en PostgreSQL desechable 16.15; pasa la comparación de clave existente/inexistente, replay revocado, carrera revoke-vs-resolve y carrera de dos capturas.
- `pnpm test:unit`: exit 0, 5/5. Node muestra warnings existentes de detección de módulo para archivos TypeScript; no hubo fallas.
- `pnpm exec next typegen && pnpm typecheck`: exit 0.
- `pnpm build`: exit 0 con Next.js 16.4.2; compiló y generó las 12 páginas estáticas.
- Biome dirigido a los cuatro archivos TypeScript/JS del flujo de captura: exit 0, sin cambios automáticos.
- `bash -n scripts/test-db.sh` y `git diff --check`: exit 0. Git solo avisó que convertirá LF a CRLF al tocar los tres archivos con LF.

Estas verificaciones no incluyen navegador, foco/DOM real, PostgREST/Auth HTTP ni OAuth. No se usaron sesiones ni credenciales reales. #7 permanece abierto con `Blocked by #6`.
