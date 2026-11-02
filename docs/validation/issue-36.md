# Issue #36 — evidencia de validación

## Entorno y alcance

- Worktree `C:\Users\gasto\.codex\worktrees\openkanban-issue-36\open-kanban`, rama `codex/issue-36`, base fija `640cfd48e70f3f895276829affc17950129e5638`.
- Node 24.14.1, pnpm 11.25.0, Next.js 16.4.2, PostgreSQL 16.15 del runner descartable y Biome 2.2.0.
- Se leyó la guía local de Next 16.4.2 antes de cambiar `task-modal.tsx`. El test DB crea un clúster local temporal en `/tmp`; identidades, tableros, tareas, eventos y fechas son sintéticos. No se usaron OAuth, datos reales, SQL remoto ni producción.
- Las aristas `Blocked by #9/#13/#14` siguen intactas. El trabajo bajo LP-0.2 no declara esos tickets ni sus gates humanos cerrados.
- Solo se registran eventos E05: responsable, fecha límite, columna, completado y recuperación. Título, descripción, prioridad, creación y copia no crean eventos.

## Evidencia por criterio

| Criterio | Evidencia y estado |
| --- | --- |
| C105-AC29 — actor, fecha/hora, antes/después; más recientes primero y carga progresiva | `tests/db/task_activity.sql` muta responsable, fecha, columna y completado por RPC; comprueba autor/instante, snapshots, orden, cursor sin saltos/repeticiones y ausencia de eventos por crear/título/replay. `task-modal.tsx` monta el panel de actividad; `task-activity.tsx` muestra actor, valores, hora y “Cargar más actividad”. |
| C105-AC30 — retención de 180 días por evento | El fixture marca un evento a 181 días e inserta una actividad importada a 179 días; la consulta oculta solo el vencido. La UI anuncia “últimos 180 días”. La recuperación no cambia `occurred_at`; la antigüedad importada tampoco se reinicia. |
| C105-AC31 — ocultar con tarea, recuperar sin rejuvenecer, purga dependiente | El test comprueba que la RPC responde `unavailable` para la tarea eliminada, que al restaurar aparece un solo evento E05 de recuperación junto con eventos aún vigentes, y que la purga permanente elimina los eventos de esa tarea. No hay API de editar/borrar eventos individuales. |
| C105-AC32 — actor histórico, Sistema e importado sin restituir permisos | El modelo guarda `actor_name` como snapshot y no guarda `actor_id`; la consulta exige membresía actual y devuelve `unavailable` fuera del tablero. El fixture crea un colaborador sintético, registra un cambio, lo retira y verifica que el owner aún ve solo el nombre histórico mientras el colaborador recibe `unavailable`. Los fixtures `system` e `imported` y los unit tests validan las etiquetas “Sistema” y “Actividad importada”. |
| C105-AC33 — respaldo/importación | No se amplía el JSON de exportación/importación v1. El roundtrip de actividad, exclusión de eventos vencidos/papelera y no generar avisos retroactivos corresponde al paquete v2 de #42/#44. En #36 solo se verifica la semántica de evento importado con su fecha original y antigüedad por evento; el roundtrip extremo a extremo no se acredita aquí. |

## Ciclos TDD y verificaciones observadas

- Rojo de persistencia: tras confirmar una mutación E05, la llamada a `get_task_activity_p` falló porque la RPC aún no existía. Verde al añadir la tabla protegida, triggers de cambio/recuperación y consulta paginada.
- Rojo de fechas: la transición de fecha límite `null` produjo `to_jsonb(NULL)` SQL NULL y violó la forma de valores JSON; verde al representar explícitamente los valores fecha ausentes como JSON `null`.
- Rojo de retención: el fixture inicial intentó leer la tabla como `authenticated` y falló por el ACL correcto; se trasladó la comprobación de existencia a la conexión de pruebas privilegiada. Otro fallo fue solo de fixture: sus dos límites de borrado usaban llamadas de reloj distintas; ambos extremos se derivan ahora del mismo `deleted_at`.
- `bash scripts/test-db-issue-36.sh`: exit 0; migraciones 001–061, categorías E05, ACL, paginación, recuperación, retención, sistema/importado, retiro de actor y purga dependiente.
- `pnpm test:unit:issue-36`: exit 0, 7/7 tests para RPC/cursor/shape, acceso no disponible, etiquetas E05 y contrato de UI/cargas/paginación.
- `pnpm test:unit`: exit 0; suites generales y focales #33–#35 también verdes. Node 24 imprime el warning `MODULE_TYPELESS_PACKAGE_JSON` ya presente en los imports TypeScript de tests; no es fallo.
- `pnpm exec next typegen`: exit 0; `pnpm typecheck`: exit 0; `pnpm build`: exit 0 con Next.js 16.4.2.
- `pnpm exec biome check --line-ending=crlf` focal sobre los TS/TSX/MJS del cambio: exit 0, 9 archivos. `pnpm exec biome check --formatter-enabled=false`: exit 0, 257 archivos sin diagnósticos de lint. `bash -n scripts/test-db.sh scripts/test-db-issue-36.sh`: exit 0.
- `pnpm lint`: exit 1 por formato CRLF/LF previo en 257 archivos (incluido `biome.json` y config global); no se reformateó fuera del ticket. El formato focal con CRLF pasa.
- `git diff --check`: exit 0 para los archivos rastreados; se volverá a ejecutar en el índice final.
- `pnpm test:db`: suite global 001–061 corriendo en el runner descartable, con `tests/db/task_activity.sql` ya conectado al camino global. La sección final aún no ha terminado.

## Gates humanos pendientes

- No se recorrió el detalle de tarea en navegador con Auth/host real; no se acredita el aspecto visual, teclado, lector de pantalla ni móvil.
- No se verificó un despliegue o un servicio remoto de PostgreSQL/Supabase; esos entornos no se usaron.
- El roundtrip v2 queda pendiente de #42/#44; el archivo v1 actual no se declara compatible con actividad.
- Los criterios automáticos no equivalen a aceptación humana ni cierran las dependencias #9/#13/#14.
