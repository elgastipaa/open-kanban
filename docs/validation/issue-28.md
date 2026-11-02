# Issue #28 — evidencia de validación

## Entorno

- Worktree `C:\Users\gasto\.codex\worktrees\openkanban-issue-28\open-kanban`, rama `codex/issue-28`; base fija `9d0661624274c3cd9e5379efabef9e318e13ee0d`.
- Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0`, PostgreSQL `16.15`.
- Las pruebas DB inicializan un clúster local descartable en `/tmp`, usan actores/fechas sintéticos y lo eliminan al salir. El runner no consume `DATABASE_URL`, `PGHOST` ni datos de la aplicación.
- No se usaron OAuth, credenciales externas, SQL remoto, producción ni deploy. No se recorrió el producto con una sesión Auth real.

## Criterios y evidencia

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| Borrar una ocurrencia la excluye sin reactivar la anterior ni adelantar la próxima | `tests/db/repetition_series_recovery.sql` verifica exclusión, slot vigente e invariantes de programación. | Automatizado en PostgreSQL descartable; recorrido UI pendiente |
| Eliminar una serie completa cancela sus futuras, conserva historial y abre recuperación de siete días | La migración `046_repetition_recovery.sql` persiste el motivo/expiración del borrado; `tests/db/repetition_series_recovery.sql` comprueba borrado, cancelación, retención y límite temporal. La UI exige preview y confirmación explícita. | Automatizado en PostgreSQL y unit; confirmación visual pendiente |
| Recuperar individualmente requiere que el padre esté restaurado; restaurar el padre no revive un hijo borrado aparte | El bloque “Individually deleted child while parent is trashed” de `tests/db/repetition_series_recovery.sql` verifica que el primer borrado `user_requested` guarda `parent_series_id`; al mandar el padre a papelera, la tarea queda oculta y restore responde `unavailable` sin alterar causa/estado. Recuperar el padre no la revive; el mismo `operation_id` luego permite recuperación individual explícita. `046` limita el restore del padre a `cause='series_requested'` y el trigger valida tablero/generación del padre vigente. | Rojo→verde en PostgreSQL descartable; browser Auth pendiente |
| Restaurar una serie revierte solo el borrado que la causó; hijos borrados por la serie requieren padre primero | Las pruebas de recuperación cubren causalidad del tombstone, bloqueo de hijos `series_requested` antes del padre y que solo esos hijos se restauran junto con el padre. La lista informa elegibilidad/columnas vigentes y el diálogo selecciona destino cuando hace falta. | Automatizado en PostgreSQL y unit; browser Auth pendiente |
| Una serie finita atrasada materializa solo la última aparición válida, sin intermedias ni extensión; excluir su última aparición no materializa una sustituta | Casos de catch-up finito y exclusión terminal en `tests/db/repetition_series_recovery.sql`. | Automatizado en PostgreSQL descartable |
| Una serie detenida se conserva detenida al recuperarla | La suite comprueba estado terminal y ausencia de un job futuro activo después de restaurar. | Automatizado en PostgreSQL descartable |
| Borrar la columna futura resuelve otra columna de aparición sin mover el historial; restaurar no deshace el traslado | `tests/db/repetition_series_recovery.sql` borra la columna de aparición, asigna destino a la futura y comprueba que ocurrencias/tarjeta actuales retienen su columna. Restaurar la columna no revierte la elección. El flujo unitario requiere destino explícito para series que lo necesitan. | Automatizado en PostgreSQL y unit; revisión visual pendiente |
| Carreras entre job, borrado y restauración no duplican ni pierden cambios | `scripts/test-db-issue-28-race.sh` comprueba que el borrado stale espera al worker y entra en conflicto, y que restauración espera al borrado y rehidrata una única serie/job válido. Fixture aislado en `tests/db/repetition_series_recovery_race_fixture.sql`. | Automatizado en PostgreSQL descartable |
| Permisos actuales, membresía y generación del tablero | `tests/db/repetition_series_recovery_security.sql` prueba usuario externo sin membresía, respuestas genéricas y ACL de tabla privada; el RPC vuelve a comprobar membresía y bloqueo de tablero bajo el lock. | Automatizado con actores sintéticos; aceptación Auth manual pendiente |

Se preservan los triggers de recuperación existentes y el aislamiento A→B de #27. No se alteró el contrato de transferencia/reprogramación. El runner full mantiene el race #26 inmediatamente después de su fixture: `repetition_series_copy.sql` llama al scheduler y podía consumir el job de carrera si se corría antes. La primera corrida full con el orden nuevo falló por esa interacción de orden; al restaurar la ubicación original, `pnpm test:db` pasó.

El orden efectivo del worker sigue siendo tablero→serie→job: `043_edit_repetition_series.sql` reemplaza la definición previa de advance y claim, y `046` conserva ese orden en los paths de borrado de serie/columna. El finding de purge se estrechó tras inspeccionar la pila efectiva: borrar serie completa vs purgar una ocurrencia ya tombstoned no formaba el ciclo porque el borrado excluye ese hijo individual. La inversión real era restore de tarea vs purge de tarea: `restore_task_internal_p` toma tablero→lápida; el batch heredado de `040` tomaba la lápida con `FOR UPDATE SKIP LOCKED` antes de llamar al helper de purge que luego esperaba el tablero.

`046` ahora selecciona candidatos de purga sin bloquear filas, y el helper vuelve a leer la lápida para obtener tablero/serie, toma tablero→series vivas relacionadas ordenadas por id→lápida, y valida de nuevo estado/expiración antes de purgar. Si el padre/ocurrencia ya no existe, no intenta actualizar filas de historial eliminadas; completa la purga del tombstone que siga elegible. El test fixture confirma que el candidate no existe en `tasks`. La prueba de regresión usa dos sesiones PostgreSQL y una retención explícita: restore adquiere el row lock del tablero, purge entra por la interfaz batch real, y luego restore llama a `restore_task_p`. Para registrar el ciclo se fija `deadlock_timeout` solo en la instancia descartable; el runner captura `pg_blocking_pids`, `pg_stat_activity` y `pg_locks` en ambos sentidos. La prueba roja temporal restaurando el `FOR UPDATE SKIP LOCKED` previo reprodujo el ciclo de dos sesiones: restore esperaba el tuple de `task_deletions` mientras purge esperaba la transacción que retenía board. Quitado el prelock, restore-first termina `confirmed` y purge revalida/retorna `0`; en la secuencia inversa purge retorna `1` y restore devuelve `unavailable`. No se cambia el orden de worker advance. Las pruebas separadas purge/serie siguen comprobando serialización en ambos órdenes, sin atribuirles el deadlock.

## Ejecuciones

Comandos desde la raíz del worktree:

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-28` | Exit `0` tras el fix; migraciones `001–046`, recuperación/seguridad y carreras worker/delete, delete/restore, purge/delete-series y restore/purge en PostgreSQL descartable. Rojo TDD previo con el prelock restaurado temporalmente: `ERROR: deadlock detected` observado en la llamada real `restore_task_p`; el cambio temporal se retiró antes de la corrida verde. |
| `pnpm test:db` | Exit `0`; regresiones DB completas `001–046`, seguridad y carreras de concurrencia. |
| `pnpm test:unit` | Exit `0`; `186/186`. Node emitió advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` de módulos existentes. |
| `pnpm exec next typegen` | Exit `0`; tipos de rutas generados con Next `16.4.2`. |
| `pnpm typecheck` | Exit `0`; `tsc --noEmit`. |
| `pnpm build` | Exit `0`; Next `16.4.2`, compila `/series` y el flujo de recuperación. |
| `pnpm exec biome check --line-ending=crlf package.json scripts/test-db.sh scripts/test-db-issue-28.sh scripts/test-db-issue-28-race.sh scripts/test-db-issue-28-restore-purge-race.sh src/app/series/page.tsx src/components/board/board.tsx src/components/board/column-deletion-dialog.tsx src/components/board/task-recovery-dialog.tsx src/components/series/delete-series-button.tsx src/lib/column-deletion-flow.ts src/lib/db/columns.ts src/lib/db/repetition-series.ts src/lib/repetition-series-recovery-state.ts tests/unit/column-deletion-flow.test.mjs tests/unit/repetition-series-recovery-state.test.mjs` | Exit `0`; archivos tocados, sin diagnósticos. |
| `pnpm exec biome check --formatter-enabled=false` | Exit `0`; lint de 208 archivos. |
| `pnpm lint` | Exit `1`; el script global ejecuta Biome con LF y reporta diagnósticos de formato al leer archivos CRLF en Windows. La ejecución global con `--line-ending=crlf` también detecta cinco diferencias de formato en archivos fuera de este cambio. No se reformateó el repositorio ajeno al ticket. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-28.sh scripts/test-db-issue-28-race.sh scripts/test-db-issue-28-restore-purge-race.sh` | Exit `0`. |
| `git diff --check` | Exit `0`; sin errores de whitespace. |

## Pendientes

- Confirmación manual en browser autenticado: diálogo de eliminación completa, recuperación del padre/hijo, destino futuro al faltar la columna y mensajes/resultados ante pérdida de acceso. No se usó bypass de Auth.
- Accesibilidad manual de teclado/lector, nombres/estados anunciados, foco y revisión visual/responsive siguen pendientes. Build y seams unitarios no sustituyen esa aceptación.
- No se verificaron host/cron, datos reales ni comportamiento de producción. #18/#26/#27 siguen como dependencias abiertas; no se cambian sus estados.
- El issue permanece abierto. Revisión independiente Spec/Standards sobre el SHA final pendiente; no integrar antes de esa revisión.
