# Issue #49 — verificar aislamiento en todos los recorridos

**Contrato:** P16/P17/P20/P21; G01/G04/G05/G06; C-94/C-99 y permisos de §§7–8 de la matriz.
**Rama:** codex/issue-49. **Base fija:** 395e9ac3b587de6029a0138a460a197a959ab49c (codex/openkanban-1-0).
**Estado:** el issue #49 sigue OPEN y ready-for-agent. Se conservan Blocked by #20/#28/#32/#35/#38/#39/#40/#44/#46; los nueve issues permanecen OPEN/ready-for-human. Esta ejecución sintética no acepta sus gates ni retira dependencias.

La matriz reúne pruebas PostgreSQL existentes y añade una regresión para los grants anónimos efectivos tras aplicar todas las migraciones. La aserción SQL usa has_function_privilege, que incluye privilegios heredados de PUBLIC. La allowlist de privilegios efectivos de anon en el esquema API public es vacía: cualquier privilegio sobre esquema, tabla/vista, secuencia, función o procedimiento hace fallar el test. El callback de autenticación y el cron con secreto son superficies HTTP distintas y se revisaron estáticamente; no son excepciones de ACL de PostgreSQL.

## Resultado por criterio

| Criterio de #49 | Evidencia automática y resultado | Límites y pendiente |
| --- | --- | --- |
| Recorrer dueño, colaborador, admin ajeno, retirado, suspendido y anónimo por consultas/RPC, canales, archivos, import/export y vistas | PASS en PostgreSQL descartable: closed_access.sql, authentication.sql, private_boards.sql, admin_authorization.sql, board_membership_departure.sql, board_member_removal.sql, access_suspension.sql, realtime_epoch.sql, late-revocation.sql, task_attachment_contract.sql, suites de cuota/limpieza de #41, import v2 y recuperación de #45, board_export_snapshot.sql, saved_views.sql y unified_search.sql. Cada fixture usa identidades/datos .example.test; los SQL usan los roles reales anon/authenticated, request.jwt.claim.sub y funciones productivas, sin mocks de autorización. | auth/realtime y storage.objects son stubs del harness. Esto valida SQL, RPC, epochs y RLS de la migración; no valida API alojada de Supabase, transporte Realtime ni bytes/ACL del proveedor Storage. |
| Cliente no cooperativo, revocación concurrente, caché/respuesta tardía y moderación sin filtrar títulos/conteos/borradores | PASS para los límites probados localmente: SQL niega acceso anónimo directo, escritura directa, publicación cliente y cambios de campos protegidos; suspensión revoca un JWT sintético ya emitido y bloquea lecturas/escrituras posteriores. tests/unit/board-auth-epoch.test.mjs descarta snapshots de epoch anterior y respuestas de sesión anterior; unified_search.sql niega cruces entre tableros y excluye comentarios moderados del índice; saved_views.sql filtra datos personales y accesos revocados. | late-revocation.sql prueba la transacción SQL de revocación, no ejecuta tests/realtime/epoch-smoke.mjs, que requiere Supabase local/Docker, JWT de prueba y websocket. Caché/respuesta tardía del navegador se cubre con helpers de estado, no E2E de navegador ni disco/service-worker/PWA. Sin browser/device no se afirma ausencia observada de todo destello en pantalla. |
| Sin grants/rutas anónimas alternativos y rol protegido, sin mocks de autorización real | PASS para el catálogo local: anonymous_surface.sql itera relaciones públicas, secuencias y rutinas y aborta al hallar ACL efectiva de anon; closed_access.sql intenta SELECT, RPC de lectura/creación y publicación Realtime como anon. Se identificó y corrigió el grant efectivo en cuatro funciones. El rol del último admin queda protegido por la aserción tests/db/authentication.sql:107–114: admin_suspend_access('bootstrap-admin@example.test') debe lanzar check_violation e is_application_admin() debe seguir true; el mensaje de fallo es The final administrator could be suspended. | La inspección estática inventaría Route Handlers y Server Actions del checkout; no demuestra ausencia matemática de cualquier ruta dinámica/configurada fuera del repo. La prueba de ACL cubre public; Storage tiene superficie separada y RLS del stub. |
| Registrar resultados, revisión y entorno; un fallo de privacidad bloquea cierre | La primera corrida roja del catálogo listó permisos efectivos para check_active_board_generation(), check_board_owner_membership(), list_my_boards() y validate_board_time_zone(). La migración 073 revoca los helpers internos y deja list_my_boards() ejecutable solo por authenticated; la matriz focal completa se reejecutó en cluster limpio y pasó. No se reduce ningún permiso de propietario/colaborador del contrato. | Cualquier regresión de privacidad mantiene el issue abierto y exige corregir y repetir pruebas relacionadas. Revisiones read-only Normas y Spec/Privacy pendientes de registrar sobre el diff final. |
| Evidencia reproducible, versión, actores/fixture y entorno aislado; controles en español | PASS para regresiones automáticas reproducidas por pnpm test:db:issue-49 y pnpm test:unit. El runner crea clusters PostgreSQL descartables y ejecuta la cadena completa de migraciones, incluida 073. Fixtures y actores se describen en los SQL indicados; late-revocation usa propietario 72000000-0000-4000-8000-000000000001 y colaborador …0002 sembrados por tests/realtime/prepare.sql. | No se hizo aceptación visual, lector de pantalla, teclado/móvil ni recorrido autenticado con Google. La UI no cambia en #49; este artefacto está en español. No se usan servicios ni cuentas remotos. |
| Conservar C-01–112 y todas las P/E, sin reabrir alcance viejo ni declarar probado lo redactado | El diff solo agrega cierre de ACL posterior a los helpers, fixtures/runner y evidencia. Suite unitaria, typegen, typecheck y build pasan; no cambia el alcance de series, restauración ordinaria ni Q61–62. | Los nueve edges permanecen intactos. Estos PASS no equivalen a aceptación humana ni cierre de issues bloqueantes. |

## Matriz reproducible

| Superficie | Prueba PostgreSQL descartable | Qué comprueba |
| --- | --- | --- |
| ACL/lecturas/RPC anónimos | tests/db/anonymous_surface.sql y closed_access.sql | Cero grants efectivos anon en public; lectura directa, get_full_board_p, creación de tablero y publicación privada denegadas. La comprobación de función incluye grants heredados de PUBLIC. |
| Identidad, suspensión y rol protegido | tests/db/authentication.sql, admin_authorization.sql y access_suspension.sql | Vinculación Google sintética, usuario sin habilitar/activo/suspendido, token previo tras suspender, administrador final, denegación de comandos globales a no-admin y rollback atómico. |
| Tablero, miembro y campos manipulados | tests/db/private_boards.sql, board_membership_departure.sql y board_member_removal.sql | Dueño/colaborador, admin ajeno, IDs cruzados, no apropiación de rol, baja de episodio de membresía y límites de autoría. |
| Canales y revocación | tests/db/realtime_epoch.sql, tests/realtime/prepare.sql y late-revocation.sql | Epoch/topic privados, señal sin contenido, publicación directa denegada y transacción que emite señal antes de revocar. epoch-smoke.mjs no se ejecutó. |
| Archivos, administración y cuota | tests/db/task_attachment_contract.sql, suite issue41 (subcluster propio) y anonymous_surface.sql | Autorización de metadatos, cruces de tablero, cuota/limpieza y denegación anon frente al RLS del esquema Storage sintético. Servicio de bytes no levantado. |
| Importación/exportación | suite issue45 (import v2 + recuperación en cluster propio), tests/db/board_export_snapshot.sql y carrera de edición #42 | Preview/confirmación owner-only, contenido importado, recuperación sin revivir accesos y snapshot consistente ante edición concurrente. Objetos físicos simulados por ACK DB. |
| Vistas y búsqueda/índices | tests/db/saved_views.sql, unified_search.sql y tests/unit/view-preference-access.test.mjs | Preferencias por actor, destino revocado, tablero ajeno, resultados moderados ausentes y contenido limitado al conjunto autorizado. |
| Respuestas/caché de cliente | tests/unit/board-auth-epoch.test.mjs y suite unitaria | Invalida snapshot al rotar epoch, descarta resultado con epoch o sesión anterior y conserva solo respuesta de sesión/epoch actual. Es prueba pura del guard cliente; autoridad se prueba por SQL. |

## Inspección estática HTTP/Next

Se inventariaron los 15 Route Handlers: /api/admin/task-attachments; /api/admin/task-attachments/[attachmentId]; /api/boards/[slug]/export; /api/boards/[slug]/export/[exportId]; /api/boards/[slug]/import; /api/boards/[slug]/import/[operationId]/confirm; /api/boards/[slug]/import/[operationId]/labels; /api/boards/[slug]/import/recoveries; /api/boards/[slug]/import/recoveries/[operationId]/confirm; /api/boards/[slug]/task-attachments; /api/boards/[slug]/tasks/[taskId]/attachments; /api/boards/[slug]/tasks/[taskId]/attachments/[attachmentId]; /api/cron/task-attachment-cleanup; /api/search; /api/task-attachment-capacity-notices. También se inspeccionaron src/app/auth/callback/route.ts y los módulos "use server" src/lib/auth-actions.ts, board-departure-actions.ts, board-member-removal-actions.ts, invitation-actions.ts, saved-view-actions.ts, theme-preference-actions.ts y view-preference-actions.ts. Los endpoints privados de tablero/adjuntos/import/export/admin/capacidad pasan por getTaskAttachmentSession(), que llama auth.getUser() y requiere acceso de aplicación activo; /api/search verifica auth.getUser() explícitamente. El cron valida Authorization: Bearer con secreto configurado, comparación de bytes de longitud constante y 404 si no coincide. El callback es una entrada pública al intercambio de código de Auth, no devuelve contenido del tablero y marca éxito/error private, no-store. /invite/[token] requiere sesión antes de obtener la vista previa de invitación dirigida por token.

Todos los módulos Server Actions localizados verifican usuario con auth.getUser() antes de la RPC. Las respuestas JSON/descargas privadas inspeccionadas tienen Cache-Control: private, no-store, max-age=0; no se hallaron directivas use cache en src/app o src/lib. Next.js 16.4.2 documenta que Route Handlers no se cachean por defecto. Es revisión de fuente/configuración del repositorio, no observación de reverse proxy, CDN ni cliente desplegado.

## Hallazgo y corrección de ACL

Con el catálogo ejecutado tras todas las migraciones, has_function_privilege('anon', oid, 'EXECUTE') encontró permisos efectivos en:

| Función | Corrección |
| --- | --- |
| public.check_active_board_generation() | Revocar todos los roles; helper interno/trigger, no RPC. |
| public.check_board_owner_membership() | Revocar todos los roles; helper interno/trigger, no RPC. |
| public.validate_board_time_zone() | Revocar todos los roles; helper interno, no RPC. |
| public.list_my_boards() | Revocar todos y conceder EXECUTE solo a authenticated. |

Se corrige en supabase/migrations/073_revoke_public_helper_execute.sql, después de migraciones que recreaban helpers. La allowlist-vacía pasa con la cadena completa. Esto es evidencia del catálogo PostgreSQL local; no afirma que no existan rutas fuera de los archivos inventariados.

## Entorno y comandos

- Node v24.14.1, pnpm 11.25.0, Next.js 16.4.2, PostgreSQL 16.15.
- pnpm test:db:issue-49 — PASS, cluster PostgreSQL local descartable. Incluye anonymous_surface, suites listadas, carrera export, subcluster issue41 y subcluster issue45. ACK de objetos simulado; Storage bytes y transporte Realtime no están levantados.
- pnpm test:unit — PASS, suite completa; Node emite advertencias no bloqueantes MODULE_TYPELESS_PACKAGE_JSON en módulos existentes.
- pnpm exec next typegen — PASS.
- pnpm typecheck — PASS (tsc --noEmit).
- pnpm build — PASS con Next.js 16.4.2.
- pnpm test:db — FAIL (exit 3) en tests/db/repetition_series_recovery.sql:419. Primer error: “Finite recovery created intermediate or extended dates”; el resultado fue {"status":"confirmed","task_id":"e57f8819-50f5-4e54-b829-61315828e17b","series_id":"fbaede1e-2875-4f2c-8b59-f75a6bd94b66","next_due_on":null,"series_state":"finished","occurrence_on":"2026-11-02","consumed_count":3}. La suite completa se detuvo ahí, antes de terminar la matriz completa; el archivo/funcionalidad no se modifica en este cambio. La matriz focal issue-49 sí terminó PASS.
- git diff --cached --check — PASS.
- bash -n scripts/test-db.sh scripts/test-db-issue-49.sh — PASS.

El harness no lee .env.local, DATABASE_URL o PGHOST; no se usaron credenciales, cuentas, datos, Auth/PostgREST/Realtime/Storage remotos, main, producción ni deploy. Docker Desktop no pudo inicializar su listener dockerInference; no se modificó Docker/configuración de usuario ni se intentó servicio remoto.

## Revisiones finales

Read-only sobre el primer commit de código/evidencia 3eb9d920cca3af4c28e84ddd466ab48fb13a2114, contra la base fija indicada arriba:

- Normas: PASS, sin hallazgos accionables. Se revisaron AGENTS.md, docs/agents/domain.md, docs/agents/implementation-loop.md y el diff completo; no hay CONTRIBUTING/CODING_STANDARDS adicionales.
- Spec/Privacy: PASS, sin hallazgos accionables; confirmó la distinción entre PostgreSQL sintético, inspección estática y gates externos, además de preservar los nueve blockers.
- Se solicita una segunda revisión read-only sobre el HEAD final porque este artefacto añade el resultado de la suite completa después de la primera revisión. El código productivo y SQL no cambian en esa actualización documental.

## Gates que siguen pendientes

- Auth real, PostgREST y configuración de grants de un proyecto Supabase alojado.
- Transporte Realtime real, dos clientes/browser, entrega de señal previa a revocación y rechazo posterior del refetch. epoch-smoke.mjs requiere un proyecto Supabase local y no corre con PostgreSQL standalone.
- Storage real: lectura de bytes, fallos/ACK, ACL física, purge/reconciliación y CDN.
- Cache/CDN/service-worker y respuesta tardía en browser/device real; foco, teclado, lector de pantalla, responsive y aceptación humana.
- Gates humanos/externos de #20/#28/#32/#35/#38/#39/#40/#44/#46. Todos siguen OPEN/ready-for-human y sus edges no cambian.

Un hallazgo de privacidad impide cerrar el issue. No se acepta como evidencia la mera presencia de documentación/copy; cada PASS se limita al seam que ejecuta la prueba.
