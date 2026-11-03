# Issue #26 — evidencia de validación

## Entorno

- Rama `codex/issue-26`; base y `HEAD` de partida: `2b3b1bdf49dbb2432bf14b4a7e95d0c1a41d748f`.
- Node `v24.14.1`, pnpm `11.3.0`, Next.js `16.4.2`, Biome `2.2.0`.
- Base aislada de prueba: PostgreSQL `16.15` en un cluster desechable creado bajo `/tmp/openkanban-db.*` por `scripts/test-db.sh`. El runner no usa `DATABASE_URL`/`PGHOST` y limpia ese cluster al finalizar.
- Datos de prueba sintéticos, miembros de prueba y fechas controladas en SQL. No se usaron `.env.local`, cuentas ni datos reales, OAuth, servicios/SQL remotos, producción ni despliegues.
- La inspección sintética inicial fue en una ruta local con props y respuestas falsas; esa ruta fue retirada. No usó autenticación ni datos reales. En el segundo ciclo no se completó una interacción con la UI nueva: Computer Use se detuvo al no poder determinar la URL local con suficiente confianza. No se atribuye a esta versión un recorrido manual de los controles nuevos.

## Criterios y evidencia

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| Anticipación `X`: aceptar solo `0 ≤ X < separación mínima`; calcular la fecha visible en la zona del tablero y no crear antes de esa fecha | `tests/db/repetition_edit.sql`: casos de intervalo mínimo (incluye calendario mensual/anual), negativo y exceso; fechas de aparición en `America/Argentina/Buenos_Aires`; worker no activa la ocurrencia antes de su fecha visible. | Automatizado, DB real aislada |
| Crear la serie mantiene la ocurrencia actual donde está, pone las próximas en la columna seleccionada y los reintentos no duplican ni cambian el destino | `tests/db/repetition_edit.sql`: estado de tarea/columna actual, destino de la próxima y replay con el mismo comando; reutilizar la misma operación con otra columna se rechaza. | Automatizado, DB real aislada |
| La vista previa permite revisar plantilla, patrón/fechas, zona, destino, final y exclusiones preservadas o retiradas | `preview_repetition_edit_p` y assertions en `tests/db/repetition_edit.sql`; la UI presenta estos campos y diferencia las exclusiones que se conservan de las que dejan de aplicar. | Automatizado en DB y revisión estática; recorrido manual de UI pendiente |
| Cambiar una serie informa qué exclusiones se retirarán | Preview del RPC y assertions de fechas preservadas/retiradas en `tests/db/repetition_edit.sql`; el formulario renderiza la lista del preview. | Automatizado en DB y revisión estática; recorrido manual de UI pendiente |
| La plantilla de checklist se puede cambiar para próximas tarjetas sin cambiar la checklist de la actual | `tests/db/repetition_edit.sql` comprueba el snapshot en preview/edición, preserva los pasos marcados de la actual y genera la próxima tarjeta con pasos nuevos, sin marcar, posición y versión iniciales propias. `task-repetition.tsx` expone agregar, editar, reordenar y quitar pasos; `editPreviewCommand` los normaliza y los envía a preview/edit. El unit test de `RepetitionEditOperationStore` conserva pasos en el comando pendiente. | Automatizado en DB/unit y revisión estática; prueba manual de los controles pendiente |
| Final `N` representa las próximas `N` ocurrencias, sin contar actual/pasadas; cambios ajenos a la serie no reinician el restante | Assertions de final/restantes en `tests/db/repetition_edit.sql`; edición ordinaria de título de la ocurrencia actual no altera snapshot ni cuenta. | Automatizado, DB real aislada |
| Si la fecha inicial elegida no coincide con la regla, hace falta elegir/confirmar una fecha compatible | `selected_date_compatible` y `date_choice_required` cubiertos en `tests/db/repetition_edit.sql`; el componente muestra una elección explícita según el resultado del preview. | Automatizado en DB y revisión estática; recorrido manual pendiente |
| La primera aparición anticipada debe ser estrictamente posterior al vencimiento actual al crear o editar | `tests/db/repetition_edit.sql`: actual 2026-11-20 y siguiente vencimiento 2026-11-24 con X=5 producen 2026-11-19; creación/edición devuelven `appearance_conflict` sin cambiar tarea, serie ni job. X=3 produce 2026-11-21; elegir 2026-12-01 con X=5 requiere confirmación y produce 2026-11-26. La UI muestra la incompatibilidad y pide fecha posterior o menor anticipación. | Automatizado en DB y revisión estática; recorrido manual pendiente |
| La fecha de una excepción debe ser estrictamente anterior a la próxima aparición | `tests/db/repetition_edit.sql` acepta 2026-11-01, rechaza igualdad 2026-11-03 cuando el próximo vencimiento nominal es 2026-11-04 y X=1, devuelve DETAIL 2026-11-03 y conserva la excepción en la actual después de generar la siguiente tarjeta. | Automatizado, DB real aislada |
| Un conflicto conserva el borrador para revisar o volver a previsualizar | La rama `conflict` mantiene el formulario y sus pasos en estado local y limpia solo el preview. El recorrido manual previo no incluyó los controles de checklist nuevos; no hay E2E persistente. | Revisión de código; verificación manual actual pendiente |
| El worker y la edición usan el mismo orden de locks, y una edición concurrente invalida el job viejo sin mover ni duplicar la ocurrencia actual | `scripts/test-db-issue-26-race.sh` inicia con un job `queued`, ejecuta `run_daily_repetition_jobs_p(100)` en una segunda sesión mientras la edición tiene el lock del board y confirma que espera por board. Tras confirmar la edición, el scheduler no reclama el job viejo; assertions verifican revisión/fecha nuevas, job viejo `superseded`, una sola occurrence actual y sin tarea duplicada ni movimiento de actual. | Automatizado, PostgreSQL real aislado y dos sesiones concurrentes |
| Reclamación revalida leases y conserva el tratamiento de jobs agotados | `tests/db/issue26_worker_claim.sql`: el lease expirado recibe token/attempt nuevos, token viejo devuelve `lease_lost`, job de revisión anterior devuelve `superseded` y lease agotado termina `dead_letter`; el bloque es rollback-only. | Automatizado, DB real aislada |
| Jobs encolados bajo una revisión anterior no aplican cambios a la serie editada | `tests/db/repetition_edit.sql` y `tests/db/issue26_worker_claim.sql` verifican que el worker rechaza jobs de una revisión anterior y no altera la revisión vigente. | Automatizado, DB real aislada |

## Ejecuciones

Comandos ejecutados desde la raíz del worktree:

| Comando | Resultado |
| --- | --- |
| `corepack pnpm test:db:issue-26` | Exit `0`; runner focal, carrera de dos sesiones vía `run_daily_repetition_jobs_p` y pruebas de renovación/dead-letter; `Issue #26 database regression tests passed (disposable PostgreSQL).` |
| `corepack pnpm test:db` | Exit `0`; migraciones `001–044`, regresiones de seguridad y concurrencia, y issue #26; `Database regression tests passed (disposable PostgreSQL).` |
| `corepack pnpm test:db:issue-23` | Exit `3` con HEAD de esta adenda (migraciones 001–044) y en la comparación previa de base fija (migraciones 001–042): `tests/db/daily_repetition.sql:721` hace SELECT directo a `daily_repetition_series` bajo `SET ROLE authenticated` y recibe `permission denied`. El runner general pasa porque no ejecuta `daily_repetition.sql`; la prueba C-110 dedicada de este ticket está en `repetition_edit.sql` y forma parte del foco/full #26. |
| `corepack pnpm test:unit` | Exit `0`; `173` tests, `173` pass, `0` fail. Node informa advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` en módulos existentes. |
| `corepack pnpm typecheck` | Exit `0`; `tsc --noEmit`, después de retirar la ruta temporal sintética. |
| `corepack pnpm build` | Exit `0`; Next compiló, comprobó TypeScript y generó las páginas estáticas. |
| `corepack pnpm exec biome check src/components/board/task-repetition.tsx src/lib/db/daily-repetition.ts tests/unit/daily-repetition-edit-state.test.mjs` | Exit `0`; Biome sin cambios requeridos. |
| `git diff --check` | Exit `0`; sin errores de whitespace. |

La versión nueva de los controles de checklist no recibió recorrido manual con teclado/browser: la sesión de Computer Use se detuvo antes de navegar a la ruta local. La ruta sintética temporal se retiró y no existe un E2E persistente. La revisión humana de pantalla/dispositivo y lector de pantalla sigue pendiente.

## Pendiente

- Revisión independiente de estándares y correspondencia con la especificación por coordinación del run.
- Recorrido manual de la versión actual del formulario, en una aplicación real; la inspección sintética anterior no cubrió los nuevos controles de pasos.
- Revisión humana en pantalla/dispositivo y lector de pantalla.
- No hay dependencia de proveedor externo en esta funcionalidad; no se hizo validación contra servicios externos ni producción.

## Adenda P2 — compatibilidad con el vencimiento actual

- Rama de trabajo: codex/issue-26. Base fija: 2b3b1bdf49dbb2432bf14b4a7e95d0c1a41d748f. HEAD previo al arreglo: bc63149d281fd63bc59f472a7567db2cbc6e9b24.
- Fecha de ejecución: 2026-11-02. Migración añadida: 044_repetition_appearance_deadline.sql.
- Entorno: el mismo runner PostgreSQL 16.15 desechable y actores sintéticos del issue #26. Sin .env.local, servicios remotos, cuentas reales ni producción.

### Criterio y resultado

Con vencimiento actual 2026-11-20, primera fecha nominal futura 2026-11-24 y X=5, la primera aparición es 2026-11-19. El preview ahora la marca incompatible; los RPC de creación y edición responden appearance_conflict antes de cambiar la actual, serie o job. Crear con X=3 produce aparición 2026-11-21 y conserva tarea/columna actuales. En edición, seleccionar explícitamente 2026-12-01 con X=5 exige confirmar la fecha; la aparición 2026-11-26 resulta posterior al actual y la edición confirma sin moverlo.

La confirmación de creación vuelve a revisar la relación con las filas de tablero/tarea bloqueadas y deshace la transacción si la invariante no se cumple. La confirmación de edición bloquea tablero, serie/ocurrencia y tarea, vuelve a ejecutar el preview y solo entonces delega la escritura. El guard de excepción usa la próxima aparición (vencimiento nominal menos X): acepta 2026-11-01 y rechaza 2026-11-03 cuando el vencimiento nominal siguiente es 2026-11-04 y X=1.

La fila C-110 de la tabla anterior queda actualizada: la excepción debe ser estrictamente anterior a la próxima aparición, no solo al vencimiento nominal.

### Verificación de esta adenda

- Rojo inicial, test:db:issue-26 contra la migración 043: exit 1; el preview no señaló aparición 2026-11-19 anterior al vencimiento actual 2026-11-20.
- Rojo de edición: el preview de servidor todavía no ofrecía appearance_compatible y la llamada de edición carecía de un resultado de conflicto por esa condición.
- Rojo de C-110: el trigger anterior aceptó 2026-11-03, fecha igual a la aparición, aunque fuera anterior al vencimiento nominal 2026-11-04.
- Verde focal y full después de 044: test:db:issue-26 y test:db terminaron con exit 0 en PostgreSQL aislado; se aplicaron migrations 001–044. El runner focal también ejecuta el race de dos sesiones y el wrapper run_daily_repetition_jobs_p.
- test:unit terminó con 173/173; typecheck, build Next 16.4.2 y Biome dirigido a los dos TS/TSX modificados terminaron con exit 0.
- test:db:issue-23 terminó con exit 3 en tests/db/daily_repetition.sql:721 por permission denied al leer directamente daily_repetition_series bajo authenticated. La misma falla ya había sido comparada contra la base fija 2b3b1bd con migrations 001–042; el full runner no ejecuta ese archivo standalone.
- El recorrido visual/manual, teclado, lector de pantalla y dispositivo sigue pendiente; no se usó ruta sintética ni se afirmó aceptación manual.
