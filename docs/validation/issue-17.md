# Validación de Issue #17: retirar miembros y transferir propiedad

Estado local: slice de salida/transferencia y protección recuperable listo para revisión. El issue permanece OPEN; no se aceptó ni cerró.

Fecha de verificación: `2026-11-01`.

## Checkout, autorización y alcance

- Rama aislada: `codex/issue-17`.
- Base y merge-base verificados: `120f1ab6f017f856e0934837235a72f734d849ca`.
- Kickoff registrado: [issue comment 6555760179](https://github.com/elgastipaa/open-kanban/issues/17#issuecomment-6555760179). El issue y sus etiquetas/dependencias no se editaron.
- Se conservan los blockers #12/#13/#16. Siguen OPEN/ready-for-human; el trabajo local con claims y usuarios sintéticos no constituye aceptación de sus entregas ni de #17.
- Referencias aplicadas: CF-02/03, C-69/71/80/81/94/95/98; MVP §4.4–4.6; UI-12/UI-15/NAV-05; B-18/B-19/A-02/A-03/A-04/A-06/MP-04 y documentos de errores/sucesión. No se cambiaron contratos.
- El camino de resolución administrativa global de tableros (resumen, sucesor o recuperación) queda en #19. Esta entrega no agrega consola global ni vuelve lector a un admin. #18 conserva la restauración completa y la elección del nuevo owner al restaurar; #17 solo registra y protege el estado recuperable del último owner.
- Se leyeron antes de escribir los documentos locales de Next `16.4.2`: `node_modules/next/dist/docs/01-app/01-getting-started/05-server-and-client-components.md`, `07-mutating-data.md`, `15-route-handlers.md`; `01-app/03-api-reference/01-directives/use-server.md`; y `01-app/02-guides/data-security.md`, `server-actions.md`, `server-and-client-boundary.md`, `04-linking-and-navigating.md`. `pnpm install --offline --ignore-scripts` terminó exit 0, reutilizó caché y no cambió manifests ni lockfile.

## Matriz de criterios

| Criterio | Implementación y evidencia | Verificación |
| --- | --- | --- |
| Colaborador puede salir sin sucesor; autoría y trabajo permanecen. | `leave_board_p` acepta `successor_user_id = NULL` solo para el colaborador. Antes de revocar la membresía, limpia asignaciones pendientes de la generación activa y avanza `assignee_version`, conserva tarea/comentario/autoría, convierte menciones al texto congelado sin identidad y revoca invitaciones pendientes emitidas por esa persona. Reingresar crea otra fila/episodio; no recupera rol, asignación ni identidad de menciones anteriores. | `tests/db/board_membership_departure.sql` cubre salida colaborador, tarea/comentario, versión de asignación, mención, invitación propia, invitación del owner que permanece válida, y reingreso en episodio nuevo. Suite DB final exit 0. `tests/unit/board-departure-flow.test.mjs` verifica salida sin sucesor. |
| Owner elige sucesor explícito, actual y habilitado; transferencia y salida son atómicas. | `BoardDepartureDialog` no preselecciona sucesor. El listado inicial incluye solo miembros actuales con identidad habilitada. `leave_board_p` vuelve a bloquear tablero y revalidar sucesor bajo transacción; si perdió elegibilidad responde conflicto y conserva tablero/membresías/tareas. UI no reemplaza el sucesor; refresca opciones y exige una nueva elección explícita. | DB cubre sucesor revocado antes de confirmar con snapshot intacto, transferencia válida y carrera real de dos sesiones usando la misma operation ID; ambas respuestas reconcilian un receipt, una única transferencia y el actor saliente no recupera acceso. Unit cubre selección explícita, gate sin selección y reintento con el mismo payload/op ID. Exit 0. |
| Owner no puede salir sin sucesor mientras otro miembro activo siga en el tablero. | `leave_board_p(..., NULL)` devuelve conflicto sin mutar owner o membresías. Un RPC separado `has_other_current_board_members_p` (solo owner, solo booleano) determina si existe otro miembro activo, sin confundir miembros suspendidos/no habilitados con lista vacía de candidatos. Error de conteo o de lista se cierra a la acción. | DB verifica conflicto/no cambio con otro miembro, incluido miembro activo suspendido que no aparece como sucesor; el RPC sigue indicando miembro presente. Unit verifica que miembros presentes sin candidatos bloquean borrado recuperable, y `null` de lectura bloquea la confirmación. Exit 0. |
| Si el owner es el último miembro, la persona confirma una acción distinta de salir. | El diálogo separa “Salir del tablero” de “Salir y poner el tablero en recuperación”. Cancelar/cerrar no manda RPC. `delete_last_member_board_p` comprueba de nuevo que no exista otra membresía activa, conserva board/columns/tasks/comments, limpia la asignación propia, revoca invitaciones, guarda actor/causa/fecha/plazo exacto de 168 horas, revoca acceso y oculta lecturas/escrituras ordinarias. No hace hard-delete ni implementa restauración. | DB prueba `leave(..., NULL)` sin cambios; confirmación separada rechazada si hay otro miembro; persistencia completa y metadatos `owner_confirmed_last_member`; plazo `deleted_at + 168 hours`; bloqueo de lecturas/escrituras ordinarias y replay mínimo del receipt. Exit 0. Unit cubre el modo de último miembro y que la lectura desconocida no ofrece esa acción. |
| Cancelar, cargar, conflicto y pérdida de acceso conservan un contexto claro. | Diálogo español ofrece revisión y cancelación; el sucesor no se elige por defecto. Loading deshabilita controles y un gate evita dos RPC simultáneas. Conflicto invalida el comando local y refresca elegibilidad; una respuesta incierta retiene el mismo command/operation ID para replay. `expired_unknown` bloquea cualquier nueva clave del tablero durante la sesión y ofrece salida a la lista. Confirmación/salida o denegación de acceso vuelve a la lista de tableros. | Unit cubre cancelar sin submit, cierre/reapertura sin conservar successor, loading sin RPC duplicada, retry same operation/payload, outcomes de conflicto/retry/access-loss y bloqueo de nueva clave después de `expired_unknown`. Biome dirigido y build pasan. No se afirma QA visual, teclado/lector de pantalla ni Auth real. |
| Mínimos de privacidad y permisos. | Recibos ocultos por RLS, scoped a actor + operation ID, acción, board y hash del payload; devuelven solo estado, operation ID y vencimiento si aplica. Actor distinto no puede leer/reusar receipt; payload distinto para la misma clave se rechaza. El receipt sobrevive a la pérdida de membresía sin restaurar acceso. | DB cubre payload collision, actor diferente, replay tras salida, expiración a 168 horas y carrera de dos sesiones. El contenido de tareas no se incluye en la respuesta de receipt. Exit 0. |

## Evidencia TDD y comandos finales

- RED inicial de transferencia: `pnpm test:db` falló porque `public.leave_board_p(uuid,uuid,uuid)` no existía; luego el mismo slice pasó tras añadir RPC y migración. RED de salida UI: `node --experimental-strip-types --test tests/unit/board-departure-flow.test.mjs` exit 1 con `ERR_MODULE_NOT_FOUND` de `src/lib/board-departure-flow.ts`; el helper/wiring dieron GREEN en la suite completa.
- La instalación inicial fue offline (`pnpm install --offline --ignore-scripts`, exit 0); no descargó paquetes ni cambió `package.json`/`pnpm-lock.yaml` salvo la entrada del runner unitario incorporada después.
- Entorno de verificación: Node `v24.14.1`, pnpm `11.3.0`, Next.js `16.4.2`, Biome `2.2.0`, PostgreSQL local desechable. `pnpm test:db` usa `scripts/test-db.sh`, no consume `DATABASE_URL` ni `PGHOST`; fixtures, usuarios y claims son sintéticos. No se usaron OAuth, cuentas/datos reales, secretos, `.env`, browser runner, CUA/IAB, producción, SQL remoto, main ni #53.

| Comando | Resultado | Evidencia |
| --- | --- | --- |
| `pnpm test:db` | Exit 0 | `issue17-db-final.log`; regresión completa con migraciones 001–030 y PostgreSQL desechable. Resultado: `Database regression tests passed (disposable PostgreSQL).` |
| `pnpm test:unit` | Exit 0, 98/98 | `issue17-unit-final2.log`; incluye estados de cancelar, selección, bloqueo, retry, loading y outcomes. |
| `pnpm typecheck` | Exit 0 | `issue17-typecheck-postbuild-final.log`, ejecutado después del build final. |
| `pnpm build` | Exit 0 | `issue17-build-final.log`; Next 16.4.2 compiló y generó las rutas estáticas/dinámicas. |
| Biome dirigido | Exit 0 | `pnpm exec biome lint` sobre los ocho archivos fuente/test cambiados (`issue17-lint-targeted.log`); `biome check` sobre los cinco archivos nuevos también pasó. |
| `pnpm lint` | Exit 1 | Check global reportó 154 diagnósticos repo-wide, mayormente formato/line endings en archivos fuera del slice. No se aplicó formato global; el linter dirigido sobre el slice queda verde. |
| `git diff --check` | Exit 0 | Sin errores de whitespace en los cambios de código/documentación. |

La interacción visual, Auth real, operación administrativa global y la restauración completa del tablero no se afirman como verificadas aquí.
