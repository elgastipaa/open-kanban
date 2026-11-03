# Issue #48 — carga, páginas y orden

**Fecha:** 2026-11-03. **Rama:** `codex/issue-48`. **Base fija:** `b7d1cc211bdc407b3f8666113888de2c7d118496`.
**Estado:** #48 sigue OPEN; se conservan `Blocked by #33/#36/#37/#42`. Esos issues permanecen `ready-for-human`; esta evidencia sintética no acepta sus gates ni retira dependencias.

El trabajo sigue P23/P08/P09, G07 y trazabilidad P/E P23/P26. No usa cuentas, comentarios, tableros ni otros datos reales. `500` describe únicamente el tamaño reproducible de este fixture; no es límite del producto.

## Resultado por criterio

| Criterio | Evidencia | Estado y límites |
| --- | --- | --- |
| Fixture de 500 tareas y conversaciones voluminosas; resúmenes, detalle bajo demanda, planes y latencia | `tests/db/issue48_scale.sql` crea 500 tareas y 50 comentarios sintéticos por tarea (25.000), además de 90 eventos de actividad y 90 notificaciones. `get_full_board_p` devuelve las 500 tareas sin comentarios anidados; `get_task_comments_p` entrega 30 comentarios a pedido. El plan directo de la página de comentarios usa `task_comments_task_chronological_idx`. | PASS en PostgreSQL descartable. El tablero carga todas sus tareas: esta prueba no acredita paginación de tablero. Cada latencia consignada es una observación local, no un SLO ni un percentil. |
| Páginas de conjunto fijo; edición entre páginas sin pérdida silenciosa | `search_unified_p` reproduce la omisión legacy: una tarea de página 2 desaparece de esa página cuando cambia su `due_on` y se mueve antes del cursor. `search_unified_page_p` ata el cursor al actor, parámetros, revisiones de contenido y día local por tablero cuando `today`, `overdue` o `next_7_days` mueven el conjunto. Al cambiar `due_on`, título, completado, comentarios o borrado/restauración, devuelve `stale_page` sin filas ni cursor. En búsquedas globales, cambiar el conjunto de tableros accesibles también devuelve `stale_page`; si el actor pierde acceso al tablero explícito del scope o del filtro, devuelve `unavailable` antes de comparar el cursor. La primera página vuelve a calcular el filtro relativo con el día actual; `no_date` y búsquedas sin filtro relativo no cambian su revisión solo al pasar el día. Los cursores legacy bien formados también reciben `stale_page`, como HTTP 409 para que los bundles anteriores no anexen una página vacía como si el conjunto siguiera completo. | PASS en RPC sintético. El cliente actual consume el cuerpo antes de comprobar el estado HTTP, descarta páginas/cursor y vuelve a cargar la primera página con un mensaje en español. El control actual de reintento también limpia el cursor antes de renovar. Un bundle ya abierto no puede adoptar código nuevo automáticamente: recibe el error 409 visible y conserva la lista previa sin mezclarle resultados nuevos; debe recargar para obtener reinicio automático. Su control de reintento antiguo puede volver a enviar el mismo cursor y recibir otro 409. El keyset de comentarios usa `(created_at,id)` pero no promete snapshot: un comentario más nuevo insertado entre páginas no duplica filas ni se agrega a la segunda página en curso; aparece tras actualizar. |
| Reordenamiento parcial de tablero | La ruta de tablero obtiene `get_full_board_p` ([`src/app/[slug]/page.tsx`](../../src/app/%5Bslug%5D/page.tsx), [`src/lib/db/boards.ts`](../../src/lib/db/boards.ts)); cada columna contiene la lista completa de tareas y el estado cliente tipa `ColumnWithTasks.tasks` como `Task[]` (`src/lib/types.ts`). | N/A sustentado en el código: la aplicación no pagina las tareas del tablero. No se crea un contrato nuevo de ordenamiento parcial. Los anclajes de movimiento existentes no se ejercitan con páginas de tablero inexistentes. |
| Búsqueda corta, mult término, Unicode, comentarios/historial y export completo | El fixture mide `t`, `ta`, `tarea carga`, `peña`, `comentario voluminoso` y una búsqueda de comentario que solo aparece en una ocurrencia histórica `replaced`. La exportación crea snapshot, lee todos sus ordinales, comprueba conteos y edita/restaura una tarea entre páginas. | PASS en PostgreSQL descartable. El snapshot mantuvo el título previo a la edición y recorrió todos los registros capturados; la búsqueda histórica encontró `is_historical=true` y `occurrence_state=replaced`. |
| Permisos, español y contratos | El RPC valida acceso y filtros antes de inspeccionar el cursor: scope/filtro explícito inaccesible devuelve `unavailable`; en scope global, un cambio del conjunto accesible se refleja en la revisión y devuelve `stale_page`. El cursor incluye actor y conjunto de tableros accesibles. `POST /api/search` mapea stale a HTTP 409. Los controles de búsqueda muestran mensajes en español. Unit tests cubren cursores versionados, legacy, malformed y el contrato HTTP/cliente stale; la prueba DB revoca membresía y confirma stale para una búsqueda global previa. El resto de contratos posteriores no cambia. | Cubierto en código y pruebas SQL/unitarias. No se ejecutó lector de pantalla, aceptación manual ni navegador real. |
| Evidencia reproducible y no ampliación de alcance | `pnpm test:db:issue-48` crea un cluster temporal propio mediante `scripts/test-db.sh`, identidades `*.example.test` y datos deterministas. No lee `DATABASE_URL`/`PGHOST`; no añade servicios externos. | PASS local. No se usó infraestructura compartida ni se hizo despliegue. |

## Fixture y método

- PostgreSQL `16.15` (Ubuntu 16.15-0ubuntu0.24.04.1), cluster local descartable creado por el harness del repositorio.
- Node `v24.14.1`, pnpm `11.25.0` y Next.js `16.4.2`.
- Actores sintéticos: propietario y colaborador activos `issue48-owner@example.test` y `issue48-collaborator@example.test`.
- Un tablero, una columna, 500 tareas, 25.000 comentarios (50 por tarea), 90 eventos de actividad y 90 notificaciones. Las filas de carga inicial se insertan directamente solo en el cluster descartable; las pruebas de cambios usan RPCs autorizados con el actor sintético para ejecutar las revisiones y actividad reales.
- Las mediciones usan `\timing` de `psql`. `N=1` por consulta/escenario; son muestras únicas, no p50/p95 ni estimación de producción. Los resultados varían según caché y entorno local.
- `EXPLAIN (ANALYZE, BUFFERS)` de `SELECT search_unified_page_p(...)` solo muestra el scan externo de la tabla temporal `issue48_fixture`: la consulta interna está dentro de PL/pgSQL y su plan no se desglosa con ese EXPLAIN. Por eso se registran la latencia y buffers/temp de la llamada completa, sin presentarlos como plan de las consultas internas. El plan de comentarios sí es SQL directo y visible.
- La invalidación usa `board_content_revisions` (triggers existentes desde migración 069), que incrementa para mutaciones de tareas, comentarios, actividad, borrados, restauraciones, etiquetas y ocurrencias. La página nueva combina el vector de revisiones accesibles con actor y parámetros de búsqueda. Para filtros relativos (`today`, `overdue`, `next_7_days`) el vector añade `board_calendar_day(board.time_zone, statement_timestamp())`; sin esos filtros y para `no_date` no se incluye el día. El test construye un cursor válido cuyo día local es ayer, comprueba que se invalida antes de la página 2 y que la página 1 actual solo contiene la tarea con vencimiento de hoy. También continúa `no_date` y sin filtro relativo con cursors de la misma revisión. La política es conservadora a nivel de tablero; una mutación no relacionada dentro de un tablero incluido también puede reiniciar la búsqueda.
- Los snapshots de export son ordinales fijos. En cambio, comentarios y búsqueda histórica se consultan con RPCs de páginas vivas; no se afirma que esas páginas compartan un snapshot de base de datos.

## Mediciones observadas

Las cifras siguientes son de una ejecución de `pnpm test:db:issue-48` con el fixture completo. El tiempo del resumen contiene cuatro llamadas a `get_full_board_p`; se registra aparte el `EXPLAIN` de una llamada.

| Escenario | Tamaño/resultado | Tiempo observado | Plan / buffers |
| --- | --- | ---: | --- |
| Carga de comentarios sintéticos | 25.000 comentarios | 345,961 ms de INSERT | — |
| Resumen de tablero | 500 tareas, sin comentarios | 26,784 ms para la consulta del fixture con cuatro RPCs | Una llamada en EXPLAIN: `Seq Scan` exterior, 53 shared hits, 1 local hit, ejecución 2,791 ms. No expone SQL interno. |
| Detalle de comentarios | 30 de 50, `has_more=true` | 6,684 ms | SQL directo: `Index Only Scan Backward` por `task_comments_task_chronological_idx`, 31 filas, 4 shared hits, 31 heap fetches, ejecución 0,037 ms. |
| Actividad | 30 de 90, `has_more=true` | 2,822 ms | Wrapper RPC completo; no se obtuvo plan SQL interno. |
| Notificaciones | 30 de 90, `has_more=true` | 8,729 ms | Wrapper RPC completo; no se obtuvo plan SQL interno. |
| Search `t` / `ta` | 24 filas, `has_more=true` | 2.022,469 / 1.936,013 ms | Llamada completa al RPC. |
| Search `tarea carga` / `peña` | 24 filas, `has_more=true` | 2.058,278 / 2.040,242 ms | Llamada completa al RPC. |
| Search `comentario voluminoso` | 24 filas, `has_more=true` | 1.628,616 ms | Llamada completa al RPC. |
| Search histórica por comentario solo histórico | 24 filas; la validación encontró ocurrencia `replaced` | 2.071,677 ms | Muestra única del RPC con `includeHistory=true`; el bloque de aserción repite la búsqueda en 2.060,459 ms. |
| EXPLAIN de search | Wrapper PL/pgSQL completo | 2.188,700 ms | Solo `Seq Scan` exterior de `issue48_fixture`; 54.233 shared hits, 1 local hit, temp read 1.551 / written 3.088. No describe el plan interno. |
| Export completo | board 1; tareas 500; columnas 1; actividad 90; comentarios 25.000 | 782,024 ms para crear snapshot, recorrer todas las páginas y validar edición posterior | 100 páginas de comentarios, 2 de tareas, una por cada otra entidad capturada. El título antiguo se mantuvo después de editar la tarea entre páginas. |
| Keyset de comentarios | primera página 30; segunda 20 de las 50 originales | 1.554,157 ms incluye el escenario combinado de comentarios y una invalidación de search | Sin duplicados; la inserción más nueva no entra detrás del cursor abierto. No es snapshot estable. |

El archivo de resultados muestra una sola muestra por búsqueda. Las consultas de verificación repetidas dentro de bloques `DO` prueban comportamiento; no se agregan a la tabla como percentiles. No se infiere que una muestra cercana a dos segundos justifique índices o cambios de búsqueda: la consulta interna y un umbral de producto no forman parte de esta evidencia.

## Reproducción y gates

| Comando | Resultado |
| --- | --- |
| Rojos TDD: assertion para revisión ausente antes del parser versionado; contrato API/UI antes de HTTP 409 y parseo del body antes de `response.ok` | FAIL esperados por ausencia de revisión o manejo del conflicto stale. |
| `pnpm test:db:issue-48` | PASS final: repro legacy de omisión por `due_on`; stale explícito y reinicio para fecha, título, completion, comentarios, borrado/restauración, actor, parámetros y permiso; día local anterior vs actual, continuidad `no_date`/sin filtro relativo; historial; comentarios; snapshot/export ordinal completo. |
| `pnpm test:unit:issue-33` | PASS, 14 tests de búsqueda/navegación/request/refresh, incluidos cursores legacy y HTTP 409 stale. |
| `pnpm test:unit` | PASS, 429 tests en 16 grupos; Node emite advertencias `MODULE_TYPELESS_PACKAGE_JSON` en `.ts` existentes. |
| `pnpm test:db:issue-33` | PASS repetido después de añadir invalidación por día local; unified search conserva acceso, identidad, filtros e historial. |
| `pnpm test:db:issue-36`, `:issue-37`, `:issue-42` | PASS focal ya ejecutado en este worktree; el runner de #48 añade solo fixture y no cambia esos escenarios. |
| `pnpm test:db` | FAIL ajeno al diff en esta corrida en `tests/db/repetition_series_recovery.sql:419` (`Finite recovery created intermediate or extended dates`, serie con `occurrence_on=2026-11-02`, `consumed_count=3`). Esas tablas/RPCs no cambian en #48; el runner focal actualiza todas las migraciones y pasa la búsqueda afectada. **Antecedente, en una corrida completa previa de otro ticket:** `tests/db/repetition_series_history.sql:169` (#27, `has_more=false`); es un fallo distinto y no corresponde a esta ejecución. |
| `pnpm exec next typegen` | PASS. |
| `pnpm typecheck` | PASS (`tsc --noEmit`). |
| `pnpm build` | PASS con Next.js 16.4.2. |
| Biome dirigido a los 7 archivos TS/JS/JSON del diff con `--formatter-enabled=false` | PASS, sin fixes; el formatter normal reporta diferencias de saltos de línea CRLF/LF del checkout y no se ejecutó para normalizar archivos. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-48.sh` | PASS. |
| `git diff --check` | PASS. |

No hay aceptación manual de Auth, navegador, lector de pantalla ni datos reales. No se aceptan gates humanos de #33/#36/#37/#42 y sus aristas de bloqueo siguen activas. La suite DB completa de esta corrida no está verde: se detuvo en la prueba de recuperación de series no modificada por #48. No se amplía #48 para repararla.

## Revisiones finales

En `c0551d6d276262d469652ca46db62d6808a98be2`, las revisiones read-only finales Spec y Standards/Privacy pasaron sin hallazgos accionables. La primera revisión Spec había detectado una imprecisión documental sobre los resultados de pérdida de acceso, corregida arriba antes de ambas revisiones finales. El issue permanece abierto y sin cierre.
