# Validación de Issue #11: fechas puntuales y zona del tablero

Estado de la evidencia: validación automatizada completada; recorrido visual real pendiente. El issue sigue abierto. La implementación cubre fechas puntuales (`DATE`) y zona del tablero; no extiende recurrencias ni series.

## Matriz de criterios

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| La fecha es opcional, no tiene hora y es independiente de recurrencias. | `tasks.due_on` es `DATE NULL`; la edición versionada permite guardar una fecha o quitarla con `null`. Las tareas nuevas sin fecha mantienen `due_on = null`. `tests/unit/task-date.test.mjs` valida `YYYY-MM-DD`; `tests/db/task_due_date_and_zone.sql` valida persistencia, limpieza y rechazo de `infinity`. | Automático: pasa. |
| El día y los estados hoy/vencida dependen de la zona IANA del tablero, no de la zona del navegador. | `board_calendar_day` calcula el día con la zona del tablero y el reloj SQL; `get_board_p` y `get_full_board_p` devuelven `today`. Las etiquetas comparan fechas civiles y el formato usa UTC para no desplazar el día. Pruebas con el instante fijo `2026-11-01T01:00:00Z` contrastan `America/Los_Angeles` (`2026-10-31`) y `Europe/Paris` (`2026-11-01`). | Automático: pasa. |
| Solo el owner cambia la zona, con vista previa y sin reescribir `due_on`. | Los RPC `preview_board_time_zone_p` y `update_board_time_zone_p` comprueban owner actual. La actualización exige la zona vista en la previa y escribe solo `boards.time_zone`. La regresión SQL verifica resumen antes/después, rechazo al colaborador y conservación de las fechas. | Automático: pasa. |
| Calendario compacto, error junto al campo y mensajes en español. | El detalle ofrece un campo nativo `type="date"`, sin hora; muestra el error junto al campo y los mensajes de validación en español. | Parcial: el código y typecheck pasan; inspección del selector y su presentación requiere recorrido manual en navegador. |
| Una fecha vacía sigue siendo opcional y no deja un hueco obligatorio. | La etiqueta de vencimiento solo se renderiza cuando `due_on` existe; la tarjeta conserva la fecha de creación previa cuando no hay vencimiento. La limpieza a `null` está probada en SQL. | Automático para datos/estado: pasa. Presentación visual: pendiente manual. |
| Con reloj controlado, el cambio de día cambia hoy/vencida y permite volver desde el detalle sin reescribir la fecha. | Las pruebas de unidad comprueban hoy → vencida → hoy con el mismo valor `due_on`; dos zonas IANA cruzan el día en el mismo instante. La base de datos comprueba el cambio de día al actualizar la zona y conserva `due_on`. La suite existente `task-edit-focus.test.mjs` pasa (4 pruebas), pero no simula el flujo de abrir/cerrar el detalle después de cambiar el día. | Automático para clasificación y persistencia: pasa. Reapertura real del detalle: pendiente manual. |

## Ejecución reproducible

Entorno: Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0`, PostgreSQL `16.15` en clúster desechable local creado por `scripts/test-db.sh`. No se usaron cuentas, datos o servicios externos. El escenario SQL usa actores sintéticos owner `40000000-0000-4000-8000-000000000002` y collaborator `40000000-0000-4000-8000-000000000005`.

Resultados:

- `pnpm test:unit`: 34/34 pruebas pasan, incluidos los casos nuevos de `task-date` y `task-edit-workflow`.
- `pnpm test:db`: pasa en PostgreSQL desechable; incluye cruce controlado LA/París, preview/cambio de zona, `due_on` opcional y permisos owner/collaborator.
- `pnpm typecheck`: pasa.
- `pnpm build`: pasa con Next.js 16.4.2.
- `pnpm exec biome check` sobre los 21 archivos de código/configuración modificados: pasa, sin cambios pendientes.
- `git diff --check`: pasa.

## Recorrido manual pendiente

En una sesión de navegador de prueba, comprobar que `⋯` contiene «Zona horaria del tablero» para el owner y que abre el diálogo existente; verificar que no se ofrece al colaborador. Crear una tarea sin fecha y otra con fecha; comprobar el selector y que el campo vacío no reserve un hueco. Guardar una fecha, cambiar la zona como owner y revisar la previa; confirmar que `due_on` conserva exactamente el mismo día. Finalmente, cruzar el día del tablero, comprobar hoy/vencida en tarjeta y detalle, cerrar y volver a abrir el detalle, y confirmar que la fecha se mantiene. Repetir el flujo con dos zonas que estén en días distintos en ese instante.
