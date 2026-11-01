# Validación de Issue #18: borrar columnas y tableros con recuperación

Estado del candidato: migraciones, RPC, UI y regresiones locales implementadas. El issue permanece abierto; este candidato no se integró ni cerró dependencias.

Fecha de validación local: `2026-11-01`.

## Checkout y alcance

- Rama: `codex/issue-18`.
- Base y merge-base: `a9f6d013c431ee65fae05d38a2d119562bc59d7f` (`codex/openkanban-1-0`).
- Commit de implementación: `8602286` (`feat: recover deleted boards and columns (#18)`).
- Commit adicional de cobertura C110-AC54: `61149ea` (`test: cover collaborator column recovery (#18)`).
- Commit de formato Biome: `9d9d57e` (`style: format issue 18 code with Biome (#18)`); HEAD de código validado: `9d9d57e64e2911cc56dee58f23da8bc6beaa7688`.
- Corrección de acceso durante tombstone: `7aa0916a4f43f8892b35e8eded8062c70ce31d73` (`fix: block legacy board invitation RPCs during recovery (#18)`).
- Este documento se actualiza en un commit separado sobre la corrección.
- El issue #18 continúa asignado a `elgastipaa`, con el kickoff existente `6556830777`. Se conservaron `Blocked by #9`, `#14` y `#17`; siguen abiertos/ready-for-human y no se cerraron ni editaron. No se declara QA humana.
- Referencias: issue #18; C-76, C-94 y C-98; R-02/R-03; P21; C110-AC54; UI-14; CF-01/CF-12 y acuerdos de Estados y errores.
- El borrado de series y sus restricciones de destino siguen en #28. No se añadió lógica de series.
- La sustitución segura de tableros importados pertenece a #43/#45. El callsite falla cerrado sin mutar cuando el destino no existe o ya tiene columnas/contenido; la sustitución de contenido queda pendiente de esos tickets. Un tablero existente vacío aún admite importación.

## Matriz de criterios

| Criterio | Implementación y evidencia | Resultado |
| --- | --- | --- |
| Borrar una columna con tareas requiere preview vigente y destino explícito del mismo tablero. | `preview_delete_column_p` entrega tarea activa, versión y destinos elegibles. La RPC valida versión, pertenencia del destino y lock de tablero; mueve las tareas y registra snapshot/eliminación en una sola transacción. La UI desktop/móvil comparte diálogo, cancelación sin RPC, estados de carga/error y reintento con la misma operación. | `tests/db/board_column_recovery.sql` y `tests/unit/column-deletion-flow.test.mjs`: pasan. |
| Restaurar columna recupera solo la columna; no devuelve tareas trasladadas. | Snapshot y ledger conservan causa, actor, deadline y cantidad trasladada. Restore vuelve a comprobar acceso, generación y plazo; tareas ya trasladadas siguen en destino. Hija borrada aparte mantiene su propia ventana/snapshot. | DB cubre traslado atómico, restore sin traslado inverso e hijo borrado aparte. Pasan. |
| C-110-AC54: miembro actual con edición puede recuperar columna; acceso retirado no. | La restauración de columna exige identidad habilitada y membresía actual. La regresión usa dos episodios sintéticos: el retirado recibe `unavailable` sin materializar columna; el colaborador vigente la restaura con `confirmed`. | `tests/db/board_column_recovery.sql`: pasa en la suite completa. |
| El borrado ordinario de tablero es recuperable por siete días y bloquea todo acceso al contenido durante la papelera. | `delete_board_p` es exclusivo del propietario habilitado, registra `owner_requested`, actor y 168 horas. `is_board_member` ya aplicaba el tombstone desde 030, cerrando las políticas RLS y RPC que comparten ese gate. La regresión confirma SELECT directo de boards/columns/tasks y listas de boards/roster ocultos; `get_full_board_p` y una edición de tarea también quedan denegados. Las membresías actuales se conservan; invitaciones pendientes se revocan y una baja independiente no se revierte al restaurar. | `tests/db/board_recovery.sql`: acceso directo/RPC bloqueado y estado posterior sin mutación. Pasa. |
| R-02/C-98: dueño actual habilitado restaura su tablero; no se restauran invitaciones ni membresías retiradas. | El restore vuelve a comprobar titularidad y estado habilitado bajo locks de identidad, tablero y recuperación. No hace upsert de miembros/invitaciones. Membresías aún vigentes conservan su episodio; una membresía revocada mientras el tablero estuvo en papelera sigue revocada. La recuperación no reinicia vencimiento. | DB comprueba restore owner, acceso de actuales, revocado sin retorno, invitación revocada y vencimiento original. Pasa. |
| R-03/C-76/C-98: tablero sin dueño válido permanece en la lista admin y requiere elegir dueño explícito. | La lista y la consulta de candidatos exponen solo metadatos de recuperación. Si hay colaboradores habilitados actuales, solo ellos son candidatos; si no hay ninguno, se elige otra identidad habilitada y se crea su episodio de owner. El admin no recibe membresía ni lectura por resolver la propiedad. Tableros ya en papelera siguen visibles con deadline original. | DB cubre ownerless/last-member, candidatos, selección, rechazo del antiguo dueño, acceso del admin y deadline. Pasa. UI admin ofrece selección explícita. |
| C-94: administrador no obtiene lectura automática del tablero privado. | Las RPC de recuperación admin devuelven metadatos (id, slug/nombre, titularidad/validez, causa, miembros y vencimiento) o identidades habilitadas; nunca tareas, columnas ni contenido. Listar/candidatos no crea membresía. | DB verifica respuesta de metadatos y deniega lecturas/restauración admin cuando el dueño vigente existe; en caso ownerless, el admin elegido tampoco lee contenido sin ser miembro. Pasa. |
| P21: restore/purge coordinados y sin resucitar hijos borrados por separado. | Restauración y purga serializan por fila del tablero y ledger. Purga elimina snapshots/recibos dependientes junto con el tablero; un hijo borrado aparte conserva su deadline si se restaura el padre y se purga junto con el padre cuando este vence. | DB cubre vencimiento exacto y ambos órdenes de carrera con estado terminal único. Pasa. |
| Borde de siete días y carreras restauración/purga. | El vencimiento es estricto: restore a `expires_at` devuelve `expired`; purge en esa frontera puede ganar. El seam de reloj está privado/revocado a clientes. | Casos controlados en la suite DB, resumidos abajo: pasan. |
| Contenido concurrente con tombstone de tablero. | Ambas escrituras ordenan en el lock de tablero: si edición toma el lock primero, confirma antes del tombstone y queda conservada dentro del contenido oculto; si borrado toma el lock primero, el edit que espera recibe denegación y no cambia el título. | Dos pruebas de sesiones PostgreSQL reales y claims sintéticos: pasan. |
| UI de eliminación/recuperación. | Confirmación de tablero anuncia siete días y revocación de invitaciones; un intento incierto conserva operation ID. Home enumera solo recuperación del dueño vigente. `/admin/access` muestra metadata y flujo de owner explícito sin consultar contenido. Los errores no confirman éxito falso. | Helpers unitarios y build/typecheck pasan. Recorrido visual/interactivo real queda pendiente manual. |

### Resultado de carreras y reloj

| Carrera/caso | Resultado observado |
| --- | --- |
| Purga de tablero toma primero el lock; restore espera en el instante exacto del vencimiento. | `purged` / `unavailable`; no queda tablero ni tarea. |
| Restore de tablero toma primero el lock a `expires_at - 1 microsecond`; purge espera. | `confirmed` / `already_terminal`; tablero y tarea permanecen, sin tombstone. |
| Edición de tarea toma primero el lock; delete de tablero espera. | Edit `confirmed`, delete `recoverable`; el texto confirmado permanece oculto. |
| Delete de tablero toma primero el lock; edición espera. | Delete `recoverable`; el edit recibe denegación de acceso y el texto queda sin cambios. |
| Columna: purge gana al restore en el deadline exacto. | `purged` / `unavailable`; snapshot y fila recuperable no quedan parcialmente restaurados. |
| Columna: restore gana al purge. | Restore `confirmed` / purge `already_terminal`; queda columna activa y desaparece el tombstone. |
| Restore de columna antes / en el deadline. | `confirmed` a un microsegundo antes; `expired` exactamente al vencimiento. |
| Restore de tablero a siete días exactos. | `expired`; purge de servicio elimina tablero, contenido y recuperación independiente hija. |

## Auditoría follow-up: acceso durante tombstone

La regresión dirigida de endpoints de contenido confirmó que `public.is_board_member` de migración 030 ya devuelve `false` para cualquier tablero presente en `board_recoverable_deletions`. Por eso las políticas RLS de boards/columns/tasks, `list_my_boards`, `get_full_board_p`, `list_board_members_p` y las mutaciones basadas en ese gate ya bloqueaban al dueño y colaboradores; el test también verifica que un admin no miembro no obtiene filas por RLS. `restore_board_internal_p` y `delete_last_member_board_p` conservan las comprobaciones directas de episodios de membresía donde deben ejecutarse sobre un tombstone o antes de crearlo.

El RED real adicional encontró dos RPCs antiguos fuera de ese gate: `get_board_creation_result_p` revelaba el slug desde el recibo de creación, y `list_board_invitations_p` exponía correos/estados de invitaciones revocadas. Los RPCs viejos para crear, revocar y renovar invitaciones también autorizaban desde filas owner sin consultar el tombstone. La migración 033 ahora filtra el recibo, protege el helper del emisor, y pone wrappers con `is_board_owner` al frente de creación direct/link, lista de invitaciones, revoke y renew; las implementaciones renombradas quedan sin EXECUTE para clientes. La regresión verifica denial, cero invitaciones pending y ningún receipt nuevo de link. El helper del emisor revisa el tombstone directamente en vez de `is_board_member(auth.uid())`, porque al consultar una invitación activa el actor actual puede ser el destinatario.

TDD: `pnpm test:db` primero salió RED con `A creation receipt exposed the slug of a tombstoned board`. Una primera versión del helper dependía de `is_board_member(auth.uid())`; eso hizo fallar el escenario existente de invitación activa a su destinatario, por lo que se cambió a una condición independiente de tombstone. Un rerun posterior falló por variables declaradas en el bloque PL/pgSQL equivocado; se movieron al bloque correcto. La última repetición completa 001–033 pasó. No se identificaron más RPCs de roster/contenido con autoridad raw que evitaran el gate; el listado de miembros ya depende de `is_board_member`.

## Ejecución reproducible

Entorno observado: Windows con WSL Ubuntu 24.04 para PostgreSQL; Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0`, PostgreSQL `16.15`. `scripts/test-db.sh` crea un cluster desechable bajo `/tmp`, aplica las migraciones `001–033` y lo elimina al terminar. El test usa actores, roles y claims UUID sintéticos. No se usaron OAuth real, datos/cuentas/secretos reales, `.env`, servicios remotos ni producción. No hubo cambio de lockfile.

| Comando | Resultado | Detalle |
| --- | --- | --- |
| `bash scripts/test-db.sh` | Exit 0 | Repetición completa desde migración 001 hasta 033. Salida final: `Database regression tests passed (disposable PostgreSQL).` Incluye suites previas y posteriores (#17, task recovery, invitaciones y concurrencia), todos los casos de columna/tablero de esta matriz y las carreras listadas arriba. |
| `pnpm test:db` tras la auditoría de tombstone | Exit 0 | Última repetición completa 001–033 tras agregar regresiones de SELECT RLS, roster, recibo slug, invitaciones legacy y ausencia de mutaciones. Salida final: `Database regression tests passed (disposable PostgreSQL).` |
| `pnpm test:unit` | Exit 0, 120/120 | Incluye flujos de board recovery, delete/restore de columna y frontera cerrada de importación. |
| `pnpm exec next typegen` | Exit 0 | Tipos de rutas Next generados antes de typecheck. |
| `pnpm typecheck` | Exit 0 | `tsc --noEmit`. El build también terminó su fase TypeScript. |
| `pnpm build` | Exit 0 | Rerun tras la corrección SQL de recuperación. Next.js compiló, terminó TypeScript, generó 13 páginas y finalizó optimización. |
| `pnpm exec biome check --write` dirigido | Exit 0 | Se ejecutó sobre las 22 rutas TS/TSX/MJS/JSON modificadas detectadas desde la base; Biome reportó `Checked 22 files in 51ms. Fixed 21 files.` Incluyó `package.json`. El diff resultante solo altera orden de imports y formato. |
| `pnpm exec biome check` dirigido, sin `--write` | Exit 0 | Las 22 rutas de código soportadas modificadas desde la base: `Checked 22 files in 28ms. No fixes applied.` Las rutas SQL de esta auditoría no son tipos que Biome procese; se validaron con la suite DB. |
| `pnpm lint` | Exit 1 | Repetido después del formato dirigido, sin fixes: `biome check` reportó 144 diagnósticos en 166 archivos, incluidos cambios de formato/CRLF repo-wide. No se aplicaron fixes automáticos globales; el check dirigido pasa. |
| `bash -n scripts/test-db.sh` | Exit 0 | Sintaxis de runner. |
| `git diff --check` | Exit 0 | Repetido al cerrar la auditoría, también contra la base fija. |

El chequeo Biome dirigido abarcó: `src/app/admin/access/page.tsx`, `src/app/page.tsx`, los componentes `board-toolbar`, `board`, `mobile-board`, `task-recovery-dialog`, `admin-board-recovery`, `column-deletion-dialog` y `my-board-recovery`; `src/hooks/use-board.ts`, `use-board-sync.ts`, `use-column-operations.ts`; `src/lib/db/boards.ts`, `columns.ts`, `import.ts`, `board-recovery-flow.ts`, `column-deletion-flow.ts`, `import-replacement-boundary.ts`; y los tres tests unitarios nuevos de esos helpers.

## Evidencia TDD rojo → verde

- Board recovery DB: la regresión nueva salió RED inicialmente con `function public.delete_board_p(uuid, text, uuid) does not exist`. La migración `033_board_recovery.sql` implementó la RPC recuperable y el mismo caso pasó dentro de la suite completa.
- Board recovery UI: el test unitario del helper comenzó RED con módulo/export inexistente; tras añadir `board-recovery-flow.ts`, los casos de owner válido, selección ownerless e idempotencia/reintento pasan dentro de `pnpm test:unit`.
- Column deletion UI: el helper `column-deletion-flow.ts` se añadió desde casos RED para preview pendiente, destino del mismo tablero, cancelación y retry. Los casos pasan en `pnpm test:unit`.
- C110-AC54: los nuevos asserts de colaborador se ejecutaron primero RED al intentar borrar la única columna del tablero; al corregir el fixture para conservar una columna vigente, colaborador retirado queda denegado y miembro actual restaura con éxito en la suite final.

## Pendientes y límites explícitos

- **Navegador móvil/escritorio:** se verificó que `package.json` no declara runner E2E y que `node_modules/playwright` y `node_modules/@playwright/test` no existen. No hay sesión de prueba autenticada disponible sin OAuth real; no se hizo bypass. Quedan pendientes los recorridos manuales de confirmación/cancelación, recuperación owner/admin, errores/loading y layout/teclado/lector de pantalla en móvil y escritorio.
- **Series:** restricciones y destino de series al borrar columna quedan en #28; esta entrega cubre tareas ordinarias y no afirma C110-AC49–53.
- **Importación:** un tablero con contenido falla cerrado antes de cualquier mutación; no se implementó reemplazo con rollback/snapshot. Diseñar esa recuperación sigue en #43/#45.
- **Review:** revisión Spec/Standards e integración por el coordinador siguen pendientes. No hubo merge a main ni push. El issue y sus dependencias no se cerraron.
