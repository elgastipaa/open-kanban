# Validación de Issue #15: usar pasos independientes dentro de una tarea

Estado del candidato: migración, lógica, UI y regresiones locales implementadas. También se corrigió el retry de altas con resultado incierto. El issue permanece abierto. Durante la implementación no se alteraron su body, etiqueta ni dependencias; la asignación y kickoff precedieron este trabajo.

Fecha de verificación local: `2026-11-01`.

## Checkout y alcance

- Rama: `codex/issue-15`.
- Base fijada: `c1cbf1f5b1506e2f3445367f27e3db98633dc1ba`.
- Merge-base verificado: `c1cbf1f5b1506e2f3445367f27e3db98633dc1ba`.
- Commit inicial de la función: `3e0e1c63fcfb766a8cc8b797ad77f34239f9b0ed` (`feat: add independent task checklist steps`).
- Commit candidato final de código: `8b191f32ca0bc7c65a091542d968547e3c40498e` (`fix: reconcile uncertain checklist step adds`); la evidencia se agrega en un commit docs-only encima.
- Las verificaciones de esta revisión corresponden al contenido de código de `8b191f32ca0bc7c65a091542d968547e3c40498e`.
- Antes de implementar, #15 ya estaba asignado a `elgastipaa` y tenía el kickoff [issue comment 6553741584](https://github.com/elgastipaa/open-kanban/issues/15#issuecomment-6553741584). El ticket conserva exactamente `Blocked by #10` y `Blocked by #14`. Según el kickoff, ambos blockers seguían OPEN/ready-for-human; esta implementación no los modificó. #15 sigue OPEN y no se cerró.
- Referencias funcionales: acceptance explícitos de #15, MVP §14.2, acuerdos CF-11/14.2 checklist/C-54, C-95, C-110/AC54, P03/P18/P21 y pantallas, estados y permisos vigentes. Una referencia editorial antigua se trató como obsoleta; no se editó el contrato ni se amplió el alcance.
- Exclusiones explícitas: responsable o fecha por paso, jerarquía/subtareas, series/recurrencias y plantillas.

## Matriz de criterios

| Criterio | Evidencia implementada | Verificación |
| --- | --- | --- |
| Los pasos son una lista plana persistida dentro de la tarea y se pueden agregar, editar, marcar, reordenar y borrar. | Migración `028_task_checklist.sql` agrega `tasks.steps` JSONB, revisión independiente de orden y revisión de checklist. Cada acción se guarda en su RPC/recibo y sus marcas/versiones no alteran `field_versions` de la tarea. El detalle ofrece texto/casilla y controles accesibles para cambiar orden. | DB automático y unitario: pasa. Recorrido visual e interacción real: pendiente manual. |
| Editar texto conserva la marca; las acciones y reintentos no duplican cambios. | Las RPC usan acciones de estado deseado, recibos por actor/operation ID/hash y revisión de paso/orden. Las regresiones cubren add/replay, edit/replay conservando `is_completed`, mark/replay, orden, conflictos y las versiones de campo de tarea sin cambios. | `tests/db/task_checklist.sql`: pasa. |
| Una alta incierta conserva el mismo comando hasta reconciliarlo y no admite una alta nueva en su lugar. | El store en memoria de `useTaskOperations` está scoped por actor, tablero y tarea, persiste al cerrar/reabrir `TaskModal` durante ese workspace y vuelve a enviar el mismo `operation_id` y payload. La UI deshabilita el campo y ofrece `Reintentar alta`. `access_lost` limpia todos los comandos del workspace y el texto visible. No se usa `sessionStorage` ni `localStorage`; al desmontar/cambiar sesión el store se elimina. | Unit simula commit, respuesta perdida y retry con el recibo original, una sola inserción, y prueba aislamiento/limpieza. `tests/db/task_checklist.sql` también cubre replay de receipt. Exit 0. |
| Eliminar un paso permite recuperar solo ese paso durante siete días. Membresía vigente y expiración se validan en servidor. | La eliminación registra causa, snapshot y timestamps; la ventana es exactamente 168 horas. El RPC de restauración vuelve a comprobar membresía actual, estado y plazo. La lista expone datos mínimos del paso y no recupera nada al abrirse. | DB cubre membresía/revocación, restore antes del plazo, expiración en el instante exacto y purge. Pasa. La acción en pantalla requiere QA manual. |
| El borrado/restauración de padre e hijo son independientes. | La consulta de pasos eliminados requiere que la tarea padre exista y esté en la generación activa. Restaurar la tarea no revive un paso eliminado por separado; purgar definitivamente al padre elimina snapshots/recibos de sus pasos. Recovery UI restaura con una llamada individual después de que el padre está activo. | DB cubre tarea restaurada sin revivir paso y purga del padre. La visibilidad y acción reales en navegador quedan pendientes manuales. |
| Marcar todos los pasos no completa la tarea. Completar con pasos pendientes muestra el conteo del servidor y exige confirmación explícita. | Marcar pasos solo actualiza la checklist. `set_task_completion_p` devuelve `confirmation_required` con cantidad/revisión vigentes. Aceptar reenvía el mismo operation ID y `checklist_version`; si cambió la checklist durante el diálogo, devuelve el conteo/revisión actuales y no completa hasta aceptar otra vez. No se marcan pasos automáticamente. Cancelar no envía RPC. Reabrir conserva las marcas. | DB prueba preview sin efecto, aceptación, estado stale, conteo nuevo, marcas conservadas, marcar todos sin completar y reabrir. Unit prueba mismo operation ID, revisión nueva y cancelación que produce `null`. Pasa. El diálogo real no tuvo QA visual/interactivo. |
| La checklist se ve en las superficies existentes sin añadir campos por paso. | `TaskModal`: CRUD y progreso discreto. Tarjetas desktop y móvil: progreso discreto y gate al completar. Mis tareas: progreso y mismo gate explícito. Recovery: tipo, texto, padre, causa, estado, eliminado/vence en zona del tablero y acción separada de recuperar paso. | Build, typecheck, unit y Biome pasan. DOM, foco, teclado, lector de pantalla, copy visual y viewport real quedan pendientes manuales. |

## Ejecución reproducible

Entorno local observado: Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0` y PostgreSQL `16.15` (Ubuntu 24.04/WSL). `pnpm test:db` usa `scripts/test-db.sh`, crea un cluster PostgreSQL desechable en `/tmp` y lo elimina al salir; no consume `DATABASE_URL` ni `PGHOST`. Los tests usan roles/claims y UUID sintéticos, incluidos owner `40000000-0000-4000-8000-000000000002` y colaborador `40000000-0000-4000-8000-000000000005`. No se usaron OAuth, cuentas/datos reales, secretos, `.env`, servicios externos ni producción. No hubo cambios al lockfile.

| Comando | Resultado | Detalle |
| --- | --- | --- |
| `pnpm test:db` | Exit 0 | Aplicó migraciones 001–028 al cluster desechable. Resultado final: `Database regression tests passed (disposable PostgreSQL).` Los diez bloques `PASS` de `tests/db/task_checklist.sql` cubren persistencia/replay, marcas/field versions, edición, orden, borrado, padre/hijo, permisos/revocación, 168 horas exactas, purge y completion gate. |
| `pnpm test:unit` | Exit 0, 73/73 | Incluye cinco casos de `task-checklist-state`, incluyendo commit + respuesta perdida + retry con la misma operación/payload, aislamiento actor/tablero/tarea, nueva instancia vacía y borrado de comandos/texto ante `access_lost`. |
| `pnpm build` | Exit 0 | Next.js compiló, ejecutó la fase TypeScript y generó las páginas estáticas/dinámicas del proyecto. |
| `pnpm typecheck` | Exit 0 | `tsc --noEmit`, ejecutado después del build. |
| `pnpm exec biome check` dirigido | Exit 0 | Los 16 archivos TS/TSX/MJS cambiados desde la base pasan; `No fixes applied`. |
| `pnpm exec biome check` global | Exit 1 | El chequeo repo-wide reportó 122 diagnósticos en 138 archivos. Ninguno de los 16 archivos de código/test del candidato tiene diagnósticos en el chequeo dirigido. No se aplicaron fixes. |
| `bash -n scripts/test-db.sh` | Exit 0 | Sintaxis del runner existente. |
| `git diff --check` | Exit 0 | Sin whitespace errors en los cambios de código. |

El check Biome dirigido se ejecutó sobre estos 16 archivos:

```text
src/components/board/task-modal.tsx
src/components/ui/confirm-dialog.tsx
src/components/board/board.tsx
src/components/board/task-recovery-dialog.tsx
src/components/board/task-card.tsx
src/components/board/mobile-task-card.tsx
src/components/my-tasks/my-tasks-list.tsx
src/hooks/use-board/types.ts
src/hooks/use-board.ts
src/hooks/use-board/use-task-operations.ts
src/lib/task-checklist-completion.ts
src/lib/task-checklist-state.ts
src/lib/db/tasks.ts
src/lib/types.ts
tests/unit/task-checklist-completion.test.mjs
tests/unit/task-checklist-state.test.mjs
```

## Evidencia TDD rojo → verde

- Checklist UI puro: `node --experimental-strip-types --test tests/unit/task-checklist-state.test.mjs` inicialmente salió exit 1 con `ERR_MODULE_NOT_FOUND` para `src/lib/task-checklist-state.ts`; después de añadir el helper, el mismo comando salió exit 0, 3/3.
- Gate aceptar/stale/cancel: `node --experimental-strip-types --test tests/unit/task-checklist-completion.test.mjs` inicialmente salió exit 1 con `ERR_MODULE_NOT_FOUND` para `src/lib/task-checklist-completion.ts`; después de implementar el helper que reutiliza operación/revisión vigente, el mismo comando salió exit 0, 3/3. Cancelar produce `null`, por lo que la UI descarta el diálogo sin generar un comando.
- Completion DB gate: la regresión inicial salió con error en `tests/db/task_checklist.sql:1158: ERROR: Completion did not return a fresh, no-effect checklist confirmation preview`; la respuesta confirmaba la tarea aunque el paso estaba pendiente. Después de añadir preview/cantidad/revisión separada de versiones de campo, la prueba `completion reviews fresh checklist state, confirms explicitly, and preserves marks` pasó en `pnpm test:db` exit 0.
- Retry de alta incierta: el nuevo caso en `tests/unit/task-checklist-state.test.mjs` salió RED (exit 1; faltaba exportar `getOrCreateTaskChecklistAddCommand`). Después del store y wiring de Board/TaskModal, `node --experimental-strip-types --test tests/unit/task-checklist-state.test.mjs` salió GREEN, 5/5. El fake server registra el primer commit y pierde su response; la reapertura toma del store el mismo comando; un intento de alta con otra clave/texto conserva el original; el replay devuelve el receipt/step original y solo queda un paso. El test de aislamiento verifica actor, tablero, tarea, nueva instancia de sesión y limpieza global al perder acceso. No simula ni afirma interacción real de navegador.
- La suite completa confirmó GREEN después de la migración 028: CRUD/replay, permisos, recoveries, expiración exacta, purge y gate de completado.

## Pendientes de validación humana y límites

- **UI/browser:** no se ejecutó navegador, CUA/IAB, Playwright ni runner visual nuevo. No se inspeccionaron capturas ni se verificaron foco, escape, layout, viewport móvil/desktop, lector de pantalla, estados visuales de error/loading/empty ni interacción de los controles.
- **Auth:** no se usaron cuentas Google reales ni sesiones OAuth. Permisos/revocación se probaron solo con actores, roles y claims sintéticos contra la base desechable. El flujo real de autenticación permanece sin validar.
- **Límite del retry incierto:** el comando pendiente vive solo en memoria del workspace autenticado, scoped por actor/tablero/tarea, para no persistir texto privado. Cerrar y reabrir el modal conserva la operación. Recargar la página o perder el contexto de sesión elimina el comando pendiente según C-95; no se promete recuperación tras ese evento. Al detectar `access_lost`, el store completo y el texto del input se limpian.
- **Recovery:** la RPC DB filtra los pasos de padres inactivos; la pantalla carga recuperación con dos consultas y restaura solo por acción individual. La relación visual entre padre/hijo y la experiencia tras restaurar cada uno todavía requieren QA manual.
- **Reviews:** las revisiones finales Spec y Standards de este candidato aún están pendientes. Esta evidencia no atribuye resultado o severidad (incluido LOW) a reviews no ejecutadas.
- La asignación y el kickoff precedieron la implementación; durante el trabajo no hubo cambios adicionales en GitHub. No se alteraron #10/#14, no se hizo push ni se integró el commit candidato.
