# Issue #7 — evidencia de implementación

Fecha: 31/10/2026. Issue: «Capturar tareas consecutivas sin duplicados». Rama: `codex/issue-7`. Base fija: `1312906108fa2a4815dd1a42cd5d889d04a16951`. HEAD de código final antes de este informe: `ba9da528a30b02a6030632d83cd7327c98d0999c`.

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
| Ante fallo, conservar título y foco | **Parcial** | El hook rechaza la promesa sin limpiar el borrador; el componente conserva el texto y vuelve a enfocar el campo. Para conflicto determinista, el borrador queda bloqueado hasta que el usuario asigne explícitamente otra clave o lo descarte. No se probó visualmente con fallos PostgREST/red. |
| Resultado durable y consulta por operation_id y carga esperada | **Probado en DB** | `task_capture_receipts` conserva actor, clave, board/column/task y hash. `get_task_creation_result_p` exige la carga esperada y la compara en servidor antes de devolver una tarea. No existe la variante pública solo por operation_id. |
| Replay idéntico devuelve el mismo task; distinta carga con la misma clave se rechaza | **Probado en DB** | `tests/db/task_capture.sql` comprueba que una consulta con la carga igual devuelve la tarea confirmada y que una carga distinta genera `23514` sin devolverla ni alterar tareas. El RPC de creación también rechaza el conflicto sin efecto parcial. |
| Vencimiento requiere reconciliación y evita reintento ciego | **Probado en DB; UI parcial** | Se vence la fila sintéticamente; la consulta con carga coincidente y el replay devuelven `expired_unknown`. Una carga distinta genera `23514` antes de resolver el task; el conteo no cambia. La consulta posterior del tablero solo ocurre después de reconciliar la misma carga. Falta confirmar este recorrido en navegador. |
| Doble envío y dos sesiones concurrentes crean una tarea | **Probado en DB; UI parcial** | El script retiene el row lock del board y ejecuta dos sesiones `authenticated` con la misma clave/carga; ambas obtienen el mismo task id y queda una receipt y una tarea. `pendingRef` evita doble submit en el componente; no fue verificado con navegador. |
| Respuesta perdida después del commit no duplica la tarea | **Probado en DB** | La primera respuesta se descarta deliberadamente; consulta por clave y replay identifican el task ya guardado. |
| Actor/autor derivados del servidor; validar tablero y columna actuales | **Probado en DB** | `created_by` coincide con `auth.uid()`. La creación valida membresía y columna actual. La consulta de recibo exige carga y la autorización del recibo se valida antes de comparar su hash; un miembro revocado obtiene `unavailable`, incluso al consultar con carga diferente. |
| Campos protegidos y cruces ajenos no producen escritura parcial | **Probado en DB** | La firma no acepta `created_by` ni `position`; el RPC legacy se elimina, `authenticated` no tiene INSERT directo y un intento directo con `created_by` falla sin agregar filas. Otro actor obtiene `not_found`; el miembro revocado obtiene `unavailable` sin el task ni el estado del hash. |
| Títulos vacíos rechazados; no deduplicar ni emparejar por título | **Probado en DB** | El título vacío se rechaza sin receipt. Dos operation_id distintas con el mismo título crean dos tasks consecutivas; el cliente resuelve por operation_id/task id, no por título. |
| Mensajes y controles nuevos cumplen P12 | **Parcial** | El conflicto muestra «Asignar clave nueva» y «Descartar borrador sin reintentar»; la primera acción solo rota la clave, conserva texto/columna y no envía. Falta revisar visualmente su presentación y accesibilidad en navegador. |
| Mantener contratos C-01–112 y P/E posteriores | **Pendiente de revisiones finales** | Se mantuvo la base fija y no se modificó alcance. El coordinador hará las revisiones Standards y Spec contra la base después de este commit. |

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `pnpm test:db` | Pasa en PostgreSQL desechable. Incluye migraciones 001–018, replay/respuesta perdida, payload conflictivo, expiración, validación board/column, autoría, acceso/revocación, escritura directa protegida y carrera entre dos sesiones. Exit code 0. |
| `pnpm test:unit` | Pasa: 2 pruebas existentes, 0 fallas. No reemplaza verificación de UI ni de PostgREST. |
| `pnpm exec biome check --write` sobre los 8 archivos TypeScript modificados | Pasa; sin fixes pendientes en la implementación original. Para la corrección final, `pnpm exec biome check src/components/board/add-task.tsx src/lib/db/tasks.ts` también pasó sin fixes. |
| `pnpm build` | Pasa con Next.js 16.4.2: compilación, tipos, generación estática y optimización de rutas terminaron correctamente. |
| `bash -n scripts/test-db.sh` | Pasa. |
| `pnpm exec next typegen` seguido de `pnpm typecheck` | Pasa. Next 16.4.2 generó los tipos locales y `tsc --noEmit` terminó sin errores. `next-env.d.ts` es generado/ignorado y no se incluye en el commit. Se confirmó previamente que este checkout no contiene archivos `.env*`; no se inspeccionó su contenido. |
| Revisión UI/teclado en navegador con Auth sintético | No disponible: no hay runner headless. Pendiente manual; no se simuló con mocks. |
| Supabase Auth/PostgREST local | No verificado. La evidencia DB corresponde a funciones/migraciones ejecutadas directamente en PostgreSQL, no acredita una sesión HTTP/Auth real. |

## Recorrido pendiente

Cuando #6 permita una sesión sintética legítima y exista runner local de navegador, recorrer con dos actores de prueba: crear varias tareas con Enter y botón; comprobar que blur no envía; verificar foco, limpieza y misma columna tras cada confirmación; desconectar la respuesta luego del commit y reconciliar por operation_id; repetir con expiración mostrando `expired_unknown` sin reintento; probar error de permisos conservando título/foco y doble clic sin duplicado. Confirmar navegación móvil, teclado y anuncio accesible del estado.

Hasta verificar Auth/UI real y completar las revisiones Standards/Spec, #7 permanece abierto con `Blocked by #6` intacto. Estas pruebas locales no autorizan cierre, integración a `main` ni publicación.

## Corrección del conflicto durante la reconciliación — 31/10/2026

Commit de código: `ba9da528a30b02a6030632d83cd7327c98d0999c` (`fix #7 validate payload during reconciliation`). Se eliminó `get_task_creation_result_p(uuid)`: la única RPC pública de consulta exige operation_id, board, columna, título, descripción y prioridad, normaliza la carga y deriva su hash dentro de PostgreSQL. El resolver verifica acceso vigente antes de comparar ese hash; una clave conocida con carga distinta lanza `23514`, sin retornar la tarea anterior. La ruta de recibos vencidos usa la misma consulta con carga esperada antes de buscar la tarea en el tablero.

La prueba roja extendió `tests/db/task_capture.sql` antes del fix: `pnpm test:db` falló porque aún no existía la RPC de reconciliación con carga esperada. Con el fix, el mismo comando pasó en el clúster desechable con PostgreSQL 16.15. Casos nuevos: carga igual resuelve confirmado y vencido; carga distinta para ambos estados genera `23514`; actor revocado recibe `unavailable` sin distinguir hashes; la variante solo por operation_id no existe ni tiene grant. No se usaron mocks para declarar DB/servidor.

El cliente ahora consulta siempre con la intención completa; convierte `23514` a conflicto determinista y no interpreta un resultado anterior como éxito. La UI conserva título y columna y ofrece asignar una clave nueva sin enviar o descartar el borrador. Enter mientras hay conflicto tampoco vuelve a enviar la clave existente. El control conserva foco por código, pero este comportamiento visual/teclado sigue parcial por falta de runner de navegador; Auth/PostgREST real y OAuth también siguen sin verificar. No hay cierre de #7: mantiene `Blocked by #6` y requiere recorrido humano UI/Auth.

Verificación final sobre el HEAD de código indicado: `pnpm test:db` exit 0; `pnpm test:unit` exit 0 (2/2); `pnpm exec next typegen && pnpm typecheck` exit 0; `pnpm exec biome check src/components/board/add-task.tsx src/lib/db/tasks.ts` exit 0; `git diff --check` exit 0; `pnpm build` exit 0. La firma nueva no altera los límites de OAuth/Auth ni fue probada por PostgREST.
