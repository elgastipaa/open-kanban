# Issue #27 — evidencia de validación

## Entorno

- Worktree `C:\Users\gasto\.codex\worktrees\openkanban-issue-27\open-kanban`, rama `codex/issue-27`; base fija `694be13fb0e6c81804c4d1f3c6ed31d906b94c74`.
- Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0`.
- PostgreSQL `16.15` en un cluster descartable WSL Ubuntu creado por `scripts/test-db.sh`; no usa `DATABASE_URL`/`PGHOST` y se elimina al terminar.
- Fechas y actores sintéticos. No se leyeron `.env.local`, credenciales ni datos reales; no hubo OAuth, Auth externo, SQL remoto, producción ni despliegue.
- No se pudo iniciar el stack local con Docker ni recorrer la ruta con sesión autenticada; el build compila `/series`, pero no se atribuye aceptación manual de UI o accesibilidad.

## Criterios y evidencia

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| Listar series por tablero/estado, aunque no haya tarjeta visible | `tests/db/repetition_series.sql`: cursor estable, filtros por tablero/estado, membresía, tarjeta completada y tombstone; después del borrado, la serie sigue listada con `current_task_id` nulo. La ruta consulta series independientemente de las filas del tablero. | Automatizado en PostgreSQL; recorrido manual pendiente |
| Consultar páginas de historial y abrir ocurrencia/comentario exactos | `tests/db/repetition_series_history.sql`: cursores, detalle de la ocurrencia elegida, enlace del comentario y `get_task_comments_p` con `p_anchor_comment_id`. La URL conserva el cursor de la página abierta. | Automatizado en PostgreSQL; recorrido manual pendiente |
| Reabrir solamente la ocurrencia vigente | La misma suite confirma que cambiar completado en la ocurrencia reemplazada falla con SQLSTATE `P2302`; la tarea enlazada al slot `current` sigue aceptando la operación. | Automatizado en PostgreSQL |
| Detener conserva actual e historial; reprogramar crea una serie distinta con la misma tarjeta como primera | `tests/db/repetition_series_lifecycle.sql`: detención idempotente y versionada, cancela trabajos vencidos/arrendados, conserva slot/conteo/historia y resuelve confirmación `new_series_from_stopped`. A queda `stopped`/`transferred`; B es `active`/`current`, conserva el `task_id`. El ciclo borrar→restaurar de la tarjeta conserva el slot transferido de A y no altera el slot, revisión ni próxima fecha de B. Borrar la fila de A no cascada a B ni a la tarjeta. | Automatizado en PostgreSQL; confirmación visual pendiente |
| Copiar historia sin modificar/reabrir el origen ni crear tareas por solo consultar | `tests/db/repetition_series_copy.sql`: el preview no está disponible para una tarea pendiente ajena al historial; cambios del origen devuelven `source_changed` sin crear tarea y preservan título/destino elegidos; confirmación crea identidad nueva y puntual. Conserva título, descripción, prioridad y pasos sin marcar; omite vencimiento, responsable, repetición, conversación y archivos. Replay no duplica. No agrega campos a E04. | Automatizado en PostgreSQL; recorrido manual pendiente |
| Borrado/restauración/purga no recupera texto purgado desde historial/copia | Se reproduce en rojo que `get_repetition_p` devolvía `template_snapshot` tras borrar una ocurrencia histórica. `045` omite la plantilla de esa respuesta para tareas `deleted`/`purged`. La suite elimina y purga con reloj sintético, comprueba `task_deletions.task_snapshot IS NULL`, y verifica que repetición, historial exacto y preview de copia no devuelven el texto. `task_copy_receipts` no guarda columnas de texto/snapshot. | Automatizado para RPCs y papelera; revisión pendiente sobre snapshots internos de series detenidas/finalizadas |
| Permisos, conversación, autoría, español y estados de error | Los RPCs comprueban identidad activa, membresía actual y generación activa; comentarios se consultan por el RPC existente con ancla precisa. Controles/mensajes nuevos están en español y los errores no devuelven contenido tras perder acceso. | DB automatizada y revisión estática; QA manual de lector/teclado/dispositivo pendiente |

## Ejecuciones

Comandos desde la raíz del worktree:

| Comando | Resultado |
| --- | --- |
| `wsl.exe -d Ubuntu --exec bash /mnt/c/Users/gasto/.codex/worktrees/openkanban-issue-27/open-kanban/scripts/test-db-issue-27.sh` | Exit `0`; migraciones `001–045` y suites `repetition_series.sql`, `repetition_series_history.sql`, `repetition_series_lifecycle.sql`, `repetition_series_copy.sql`; cluster descartable. Incluye borrado/restauración/purga con fixtures sintéticos. |
| `pnpm test:db` | Exit `0`; regresiones completas `001–045`, seguridad y concurrencia, en PostgreSQL descartable, incluido el caso final de borrado/restauración/purga de #27. |
| `pnpm test:unit` | Exit `0`; `173/173` pruebas. Node emite advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` en módulos existentes. |
| `pnpm exec next typegen` | Exit `0`; Next generó tipos de rutas. |
| `pnpm run typecheck` | Exit `0`; `tsc --noEmit`. |
| `pnpm build` | Exit `0`; Next `16.4.2`, incluye ruta dinámica `/series`. |
| `pnpm exec biome check src/app/series/page.tsx src/components/series/stop-series-button.tsx src/components/series/historical-task-copy-action.tsx src/lib/db/repetition-series.ts` | Exit `0`; cuatro archivos dirigidos sin cambios requeridos. Los TSX existentes `src/app/page.tsx` y `src/app/[slug]/page.tsx` solo reciben inserciones pequeñas; no se formatearon archivos completos para evitar churn preexistente. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-27.sh` | Exit `0`. |
| `git diff --check` | Exit `0`; sin errores de whitespace, ejecutado antes del commit final. |

El caso del filtro de copia de tareas pendientes y el de texto purgado se probaron primero en rojo; ambos dieron el error esperado y luego verde con la migración y las aserciones correspondientes. El foco #27 y la corrida completa de DB terminaron con exit `0` después de los cambios finales.

## Pendientes

- No se recorrieron `/series`, el modal de copia ni la confirmación de detención en un browser autenticado. Requiere stack local Auth/Docker y sesión manual; no se usó bypass.
- Accesibilidad manual con teclado/lector, tamaños/dispositivos y revisión visual siguen pendientes.
- **Punto de revisión Spec:** `daily_repetition_series.template_snapshot` se conserva en almacenamiento incluso si una serie termina o se detiene y su tarea se purga; los RPC de historial/copia/lookup no lo exponen después de `deleted`/`purged`. DT §3 prohíbe conservar snapshots de texto purgado para aparentar historial, pero no define explícitamente si se debe borrar también una plantilla de una serie terminal. No se cambió su retención sin un contrato claro; distinguir de la plantilla que todavía necesita una serie activa para generar ocurrencias futuras.
- No se verificó host/cron ni G03 global. `Blocked by #23` permanece intacto; no se cierra ni acepta #23/#27.
- Adjuntos no se copian ni se afirman verificados; el modelo queda fuera del alcance/bloqueo existente.
- Revisión independiente Spec/Standards del SHA final pendiente de coordinación.
