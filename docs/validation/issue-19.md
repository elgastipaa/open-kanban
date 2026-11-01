# Issue #19: validación de sucesión al suspender acceso

## Alcance y base

- Trabajo local sintético en `codex/issue-19`.
- Base y merge-base fijados antes de implementar: `1fcd3cd6542f35b37251118017f159e47d671ac6`.
- Commit funcional validado: `355ac32b02f9718f8a5f9396f6d3c5251cbc93ad`.
- LP-0.2 autoriza este avance local. El issue sigue abierto para revisión y QA humana; no se integró, publicó ni cerró.
- #5 y #18 conservan su estado abierto/ready-for-human.

La vista previa devuelve únicamente `board_id`, slug, nombre, estado, relación, cantidad de membresías activas, plazo de papelera, autoridad de recuperación y candidaturas habilitadas. No devuelve columnas, tareas, descripciones ni comentarios. La confirmación verifica de nuevo en PostgreSQL cada sucesor y procesa todos los tableros en una transacción. Sin colaborador habilitado, un tablero activo pasa a recuperación por 168 horas; un tablero ya recuperable conserva `deleted_at` y `expires_at`. Se revocan membresías e invitaciones pendientes, se limpian asignaciones abiertas y se congelan menciones históricas como texto. Habilitar de nuevo la cuenta no restaura esas relaciones. El flujo protege al último administrador.

Los locks de identidad preceden a los locks de tableros. La regresión concurrente prueba que una escritura de tarea y una invitación salientes que esperan durante la suspensión reciben `42501` y no persisten.

## TDD: RED → GREEN

- PostgreSQL: `tests/db/access_suspension.sql` salió RED porque faltaba `public.admin_preview_account_suspension_p(text)`. La migración 036 implementó la vista previa y la sucesión atómica; el escenario pasa en la suite completa.
- Flow de interfaz: `board-recovery-flow.test.mjs` salió RED por el export inexistente `parseAccessSuspensionPreview`. GREEN valida el contrato metadata-only y rechaza campos de contenido privado.
- Estado `unavailable`: el seam salió RED por el export inexistente `accessSuspensionResultEffect`. GREEN confirma que el resultado limpia la vista previa y las opciones obsoletas y solicita refrescar el acceso. La UI cierra el estado viejo y refresca también al recibir conflicto, denegación o cambio de autoridad.
- Resultado de la suite unitaria final: 137/137.

La primera ejecución del nuevo harness detectó que el setup intentaba leer `application_access` bajo `authenticated`; el fixture ahora bloquea la fila como administrador local del cluster desechable antes de asumir el claim sintético. La siguiente ejecución confirmó la carrera de escritura/invitación, y la corrida completa final pasó después de mover los conteos de verificación a la entrada estándar de `psql`.

## Verificación automatizada

| Comando | Resultado |
| --- | --- |
| `pnpm test:db` | Exit 0. Suite completa en PostgreSQL desechable; migraciones 001–036, escenarios #19 y regresiones existentes. Incluye `PASS: suspension serializes with a concurrent task write and outgoing invitation.` y cierre `Database regression tests passed (disposable PostgreSQL).` |
| `pnpm test:unit` | Exit 0; 137/137. |
| `pnpm exec next typegen` | Exit 0; generó los tipos de rutas Next. |
| `pnpm typecheck` | Exit 0. |
| `pnpm build` | Exit 0; Next 16.4.2 generó 13 páginas. |
| `pnpm exec biome check` (6 archivos TS/TSX/MJS dirigidos) | Exit 0; sin correcciones pendientes. |
| `bash -n scripts/test-db.sh` | Exit 0. |
| `git diff --check` | Exit 0. |

El primer typecheck, antes de `next typegen`, falló porque faltaba el `next-env.d.ts` generado en este checkout. Después de generar los tipos, typecheck y build pasaron. No se cambiaron manifests ni lockfile.

## QA manual pendiente

No se hizo una sesión de navegador autenticada: este worktree no tiene runner Playwright y el flujo requiere una sesión Supabase real, que no se creó para esta validación. La compilación y los seams no reemplazan la revisión humana. Sigue pendiente probar en escritorio y móvil, con teclado y lector de pantalla, la vista previa/cancelación, varios tableros, transferencia, tablero sin candidato, autoridad de recuperación existente, conflicto por cambio concurrente, respuesta incierta, rehabilitación sin reconstrucción de membership/asignación/menciones y protección del último administrador.

Todo PostgreSQL y las identidades usados fueron locales, desechables y sintéticos. No se usaron OAuth real, `.env`, cuentas/datos reales, SQL remoto, bypass de autenticación, producción ni despliegue.
