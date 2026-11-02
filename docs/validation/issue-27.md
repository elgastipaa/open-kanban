# Issue #27 — evidencia de validación

## Entorno

- Worktree `C:\Users\gasto\.codex\worktrees\openkanban-issue-27\open-kanban`, rama `codex/issue-27`; base fija `694be13fb0e6c81804c4d1f3c6ed31d906b94c74`.
- Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0`.
- PostgreSQL `16.15` en un cluster descartable creado por los scripts del repo; no usa `DATABASE_URL`/`PGHOST` y se elimina al terminar.
- Fechas y actores sintéticos. No se leyeron `.env.local`, credenciales ni datos reales; no hubo OAuth, Auth externo, SQL remoto, producción ni despliegue.
- No se pudo iniciar el stack local con Docker ni recorrer la ruta con sesión autenticada; el build compila `/series`, pero no se atribuye aceptación manual de UI o accesibilidad.

## Criterios y evidencia

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| Listar series por tablero/estado, incluso si la tarjeta no aparece en el tablero | `tests/db/repetition_series.sql` verifica cursor/filtros, membresía, tarea completada y tombstone; borrada la tarea, la serie continúa listada con `current_task_id` nulo. `tests/db/repetition_series_lifecycle.sql` comprueba título de tarea completada, patrón semanal, avance, columna y fecha real de aparición (`next_due_on - advance_days`). La ruta presenta “Aparece el” y “Vence el” como fechas distintas; series terminales no anuncian próxima aparición. | Automatizado en PostgreSQL; recorrido manual pendiente |
| Abrir desde serie activa el editor de la próxima repetición aunque la tarjeta esté oculta/completada y regresar al listado filtrado | `tests/unit/repetition-series-navigation.test.mjs` verifica destino interno, task id, origen, filtros y cursor. El servidor autoriza el destino contra el snapshot actual del tablero obtenido por `getFullBoard`; la ruta rechaza tareas que no están ahí y el RPC de repetición vuelve a validar la serie activa. La tarea completada sigue disponible para esa navegación aunque no se vea en la vista normal del tablero. | Seam de URL/autorización automatizado; recorrido browser autenticado pendiente |
| Consultar páginas de historial y abrir la ocurrencia/comentario exactos | `tests/db/repetition_series_history.sql`: cursores, detalle de ocurrencia elegida, ancla precisa de comentario y `get_task_comments_p`. La URL conserva el cursor de página. | Automatizado en PostgreSQL; recorrido manual pendiente |
| Reabrir solo la ocurrencia vigente | La suite de historial confirma que cambiar completado en una ocurrencia reemplazada falla con SQLSTATE `P2302`; la tarea enlazada al slot `current` acepta la operación. | Automatizado en PostgreSQL |
| Detener conserva actual/historial; reprogramar crea serie independiente con la misma tarjeta primero | `tests/db/repetition_series_lifecycle.sql`: detener idempotente y versionado, cancela trabajos vencidos/arrendados, conserva slot/conteo/historia y confirma `new_series_from_stopped`. A queda `stopped`/`transferred`; B es `active`/`current` con el mismo `task_id`. Borrar/restaurar la tarjeta conserva A transferida sin alterar el slot, revisión o fecha de B; borrar A no borra B ni la tarjeta. B mantiene su propio template operacional activo. | Automatizado en PostgreSQL; confirmación visual pendiente |
| Consultar/copiar historia no reabre origen ni crea pendiente | `tests/db/repetition_series_copy.sql`: preview no disponible para tarea pendiente ajena al historial; cambios de origen producen `source_changed` sin crear tarea; confirmación crea identidad nueva y tarea puntual. Conserva título, descripción, prioridad y pasos sin marcar; omite vencimiento, responsable, repetición, conversación y archivos. Replay no duplica. No amplía los campos E04. | Automatizado en PostgreSQL; recorrido manual pendiente |
| Borrado/restauración/purga no recupera texto purgado desde historia o copia | La prueba original fue roja porque `get_repetition_p` devolvía `template_snapshot` después de borrar una ocurrencia histórica. `045` omite contenido de templates en lookups para series terminales y tareas `deleted`/`purged`; historial/copia tampoco devuelven texto purgado y `task_deletions.task_snapshot` queda nulo tras purga. Una prueba roja adicional intentó reinyectar título, descripción y pasos en una plantilla terminal. El trigger los reemplaza con un marcador sin contenido, tanto en transiciones a `stopped`/`finished` como en inserts/updates terminales; el backfill sanea series terminales preexistentes. | Automatizado en PostgreSQL; revisión independiente pendiente |
| Permisos, conversación, autoría, español y estados de error | Los RPC revalidan identidad activa, membresía y generación actual; comentarios usan el RPC existente con ancla. Los mensajes y controles nuevos están en español; el acceso perdido no devuelve contenido. | DB automatizada y revisión estática; QA manual de teclado/lector/dispositivo pendiente |

La redacción terminal implementa DT §3 / CF-08.1: una serie `stopped` o `finished` ya no puede generar ocurrencias y no necesita su texto de plantilla; la migración limpia filas terminales existentes y evita que vuelvan a guardar contenido. La plantilla de una serie `active` sigue disponible para ejecución. Reprogramar crea B con su propio template activo y no altera la relación A→B ni snapshots de recuperación fuera del alcance.

## Ejecuciones

Comandos desde la raíz del worktree:

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-27` | Exit `0`; migraciones `001–045` y suites de series/historial/ciclo/copia, PostgreSQL descartable. Incluye lista, detalle, reabrir, detención, terminal redaction, reinyección de texto, transferencia A→B y purga sintética. |
| `pnpm test:db` | Exit `0`; matriz DB completa `001–045`, seguridad y concurrencia en PostgreSQL descartable. |
| `pnpm test:unit` | Exit `0`; `176/176` pruebas. Node emite advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` en módulos existentes. |
| `pnpm exec next typegen` | Exit `0`; Next generó tipos de rutas. |
| `pnpm run typecheck` | Exit `0`; `tsc --noEmit`. |
| `pnpm build` | Exit `0`; Next `16.4.2`, incluye `/series`. |
| `pnpm exec biome check package.json "src/app/series/page.tsx" "src/app/[slug]/page.tsx" src/components/board/board.tsx src/components/board/task-modal.tsx src/components/board/task-repetition.tsx src/lib/db/repetition-series.ts src/lib/repetition-pattern.ts src/lib/repetition-series-navigation.ts tests/unit/repetition-pattern.test.mjs tests/unit/repetition-series-navigation.test.mjs` | Exit `0`; 11 archivos dirigidos. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-27.sh` | Exit `0`. |
| `git diff --check` | Exit `0`; sin errores de whitespace antes del commit. Git muestra avisos habituales de conversión LF/CRLF en Windows. |

Las pruebas de nuevos contratos siguieron rojo→verde: faltaban el resumen/título/fecha de aparición, el enlace autorizado al editor, el filtro de template terminal y la limpieza física terminal. Cada regresión se ejecutó primero contra la implementación incompleta y falló; luego pasó con la corrección. El foco #27 y la DB completa terminaron con exit `0` en la versión final.

## Pendientes

- No se recorrieron `/series`, la apertura del editor, la copia histórica ni la confirmación de detención en un browser autenticado. Requiere stack local Auth/Docker y sesión manual; no se usó bypass.
- Accesibilidad manual con teclado/lector, tamaños/dispositivos y revisión visual siguen pendientes.
- No se verificó host/cron ni G03 global. `Blocked by #23` permanece intacto; no se cierra ni acepta #23/#27.
- Adjuntos no se copian ni se afirman verificados; ese comportamiento queda fuera del alcance/bloqueo existente.
- Revisión independiente Spec/Standards del SHA corregido pendiente de coordinación; no integrar hasta recibirla.
