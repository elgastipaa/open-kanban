# Checkpoint del loop — 29/10/2026

Run: thread01a16ffa-f041-7380-98e4-33b348d12d08. Alcance spec#2, hijos#3–#53 y todas P/E. LP-0.2 aceptada por el comando explícito del usuario. Autorizados implementación/pruebas aisladas, ramas codex, commits/push de esas ramas, PR acumulada en borrador y seguimiento/cierre con evidencia. Main/producción y corte#53 excluidos sin aprobación específica.

Continuación (29/10–30/10): la API del Goal informa `usageLimited`; no se afirma continuidad automática ni se crea otro Goal. Esta sesión continúa manualmente con la autorización previa del run. No hubo cambio de modelo ni consumo de resets.

Protección de despliegues (29/10): GitHub registró el status Vercel «Deployment has completed» para el commit documental `1aea3ef` (28/10 21:15:30 UTC). El entorno/destino de ese despliegue no pudo verificarse; `main` remoto continúa en `46c9413` y este run no ejecutó SQL de producción. El usuario autorizó explícitamente corregir solo la regla de ramas antes de publicar código. El commit `e1cf746` cambió `"*": false` por `"**": false` y conserva `"main": true`; minimatch local confirmó que `main` sigue habilitada y las ramas anidadas quedan deshabilitadas. GitHub no registró status/check Vercel ni deployment para `e1cf746` tras 75 segundos. Tampoco registró statuses/check-runs/deployments para el head de código `33c213f` después del push y la apertura de PR #54. Esto es evidencia disponible en GitHub, no inspección directa del panel de Vercel. La rama codex queda habilitada para el run; main/producción siguen fuera de alcance. Diagnóstico: `.scratch/deployment-gate-2026-10-29.md`.

Base `main`: `46c94139bac67aaca1d491b29afc3bc999fc288f`. Remoto: `elgastipaa/open-kanban`. La rama `codex/openkanban-1-0` integra la entrega #3, cuya fuente revisada es `33c213f06eacd400b1b937f80cf5f6c7207ade75`; después se publicó el checkpoint de coordinación. La PR acumulada #54 sigue en borrador y sigue la rama; consultar el head actual en GitHub antes de operarla. Checkout de integración: `C:\Users\gasto\Documents\GitHub\open-kanban`. Preservar `docs/VALIDATION.md` ajeno sin stage/commit; SHA256 `B8669EAAFEA1A6D41C1342470E49324D2FAA50BED03DCCCFE7E94AF17D51FD9C`. `.scratch/` contiene evidencia/control local y permanece fuera de Git.

Tracker: 51 hijos al iniciar. #3 «Separar mover de editar una tarea» quedó cerrado como completed con sus cinco criterios marcados y evidencia en el comentario `6504193909`; mantiene asignación histórica. #4 «Entrar con Google a una aplicación cerrada» depende de #3. El usuario confirmó el 30/10 que agregó dos cuentas de prueba a Audience/Test users. El proveedor y el Supabase aislado están listos; #4 vuelve a `ready-for-agent` para implementar, con pruebas Auth reales pendientes antes del cierre. No guardar correos ni secretos. #2 permanece abierto. PR #54 se creó y adjuntó a esta tarea.

Entorno aislado: Windows Node24.14.1 y pnpm11.25.0; Supabase CLI2.122.0 en proyecto local sin enlace remoto `C:\Users\gasto\.codex\test-envs\open-kanban-goal-20261028` (API56421, DB56422), con datos ficticios. Docker Engine responde; `supabase start` y `status` dieron exit 0, 12 contenedores del proyecto. `/auth/v1/authorize?provider=google` respondió 302 hacia `accounts.google.com` e incluyó parámetro de cliente; esto no prueba login ni admisión. El arnés SQL usó un clúster descartable con PostgreSQL16.15 en WSL. No acceder a producción ni leer `.env.local`.

El implementador único `/root/implement_issue_3` terminó. Su rama local `codex/issue-3` se rebasó sobre `e1cf746`; final `33c213f06eacd400b1b937f80cf5f6c7207ade75`, árbol limpio. Dos revisiones finales (Spec y Standards) no hallaron problemas accionables en ese HEAD. Sin escritor, merger o revisor activos.

Entrega #3: diffs de edición y movimiento separados; migraciones aditivas `013`/`014`; 46 escenarios de navegador documentados. `scripts/test-db.sh` pasó para las migraciones `001–014` en PostgreSQL 16.15 descartable; `pnpm typecheck`, Biome en 75 archivos y `pnpm build` pasaron. Los recorridos Chromium usaron Supabase/PostgreSQL 17.11 local. Las pruebas se ejecutaron en el candidato antes del rebase; el rebase preservó el árbol de código y añadió solo la corrección de configuración a su historial, así que no se repitieron suites. Los revisores verificaron el HEAD final. Evidencia reproducible en `docs/validation/issue-3.md`. El antecedente de respuesta perdida del RPC de creación después del commit quedó registrado en #7 (comentario `6493919165`), dentro del alcance de idempotencia de #7/#8; #3 no lo declara resuelto.

Frontera: se consultaron todos los bloqueos nativos de los hijos abiertos. #4 es la única raíz después de #3; los demás tickets mantienen bloqueadores. El usuario confirmó dos test users de Google; no se copiaron sus emails. La configuración local fue revalidada y #4 queda elegible para implementar. La aceptación todavía exige completar Auth real con una identidad habilitada, otra no habilitada y una petición sin sesión; no usar mocks para declarar cumplido el login ni marcar el Goal completo.

## Revisión final de #4 — 30/10/2026

Código revisado en `codex/issue-4`: `94fa29a97fd2e4aae50a358a7d68538ed3c03f8f`, contra la base fija `d7ebc632a5df207afda34273f6850bce68b3f146`. Commits vinculados a #4: `6d0d874` (feature), `e644a7e` (evidencia inicial), `94fa29a` (ownership Realtime). El informe reproducible actualizado está en `docs/validation/issue-4.md`; este checkpoint/documentación se agrega después del HEAD revisado.

La migración `015` ya no ejecuta `ALTER TABLE` sobre `realtime.messages`, tabla cuyo owner es gestionado por Supabase. Comprueba que RLS ya esté activo y luego declara solo las políticas de OpenKanban. Hash SHA-256 de la migración coincide entre el worktree y el proyecto aislado.

Evidencia de entorno aislado `open-kanban-auth-issue-4` (Supabase CLI 2.122.0; PostgreSQL 17.11; Realtime 2.147.1): `supabase start` terminó con código 0 y aplicó las migraciones 001–015. Lectura de la DB real confirmó owner `supabase_realtime_admin`, RLS activo y políticas `openkanban_private_board_read` (SELECT) / `openkanban_private_board_send` (INSERT) para `authenticated`. `private_only=true` se aplicó únicamente al tenant local vacío; un cliente `@supabase/supabase-js` anónimo con canal público fue rechazado por `PrivateOnly`. El test SQL sobre Auth/Postgres real usó principals sintéticos y transacciones revertidas; no se sembró ni inició sesión con ninguna cuenta real. Esto no acredita OAuth/Auth server ni producción.

Verificación del código: `pnpm test:db`, `pnpm typecheck`, `pnpm build` pasan. Biome dirigido pasa en los 24 archivos de código compatibles; SQL no es soportado por Biome y se validó con DB real/tests. `pnpm lint` global falla con 60 errores de formato en 60 rutas baseline sin cambios, listadas en `docs/validation/issue-4.md`; no se formatearon archivos ajenos.

Revisión final en paralelo, solo lectura, HEAD `94fa29a` contra base fija:
- **Standards:** el reviewer marcó documentación stale al fijar `6d0d874`; este informe y checkpoint la actualizan. No hay infracciones adicionales en el código. Posibles smells de duplicación son juicios no materiales.
- **Spec:** el manejo de `realtime.messages` es correcto, sin cambios de ownership ni scope creep. Auth/Google real sigue pendiente. Tableros legacy siguen sin propietario y no se exponen hasta inventario autorizado y asignación explícita, conforme D-07/C-98.

#4 permanece abierto y `ready-for-human`. Handoff pendiente: completar manualmente el selector/login Google en navegador aislado y probar identidad habilitada, identidad válida no habilitada y sesión ausente contra Auth real; la selección de cuentas no se automatiza. Confirmar logout/cambio de cuenta/suspensión y errores temporales con el recorrido real. `private_only=true` y rechazo público ya quedaron verificados en el tenant local aislado. Resolver por separado propietarios de tableros legacy. No publicar correos/secretos, no tocar producción, no hacer push ni merge.

## Actualización del entorno local de #4 — 29/10/2026

- La instancia antigua `C:\Users\gasto\.codex\test-envs\open-kanban-goal-20261028` se detuvo con sus volúmenes preservados. Antes de detenerla se confirmó que contiene 1 tablero, 2 columnas y 3 tareas; no se aplicaron migraciones ni se modificaron esos registros porque su propiedad no está confirmada.
- Para Auth se creó y arrancó la instancia nueva y vacía `C:\Users\gasto\.codex\test-envs\open-kanban-auth-issue-4`. Aplicó las migraciones 001–015; RLS/políticas de Realtime y `private_only=true` quedaron verificados solo en este tenant local.
- La identidad de prueba elegida por el usuario tiene una fila local explícita `pending`, `is_admin=true`, todavía sin `auth_user_id` ni sujeto Google vinculado. El valor de identidad no se copia a documentos, repo ni GitHub. La otra cuenta de prueba no tiene fila de acceso.
- Next.js está ejecutándose con la configuración local aislada en `http://127.0.0.1:3000`; GET `/` devolvió HTTP 200. Aún falta que el usuario complete manualmente «Continuar con Google» y el selector de cuenta. No se afirma que OAuth real esté probado hasta validar la fila activada y los recorridos de acceso/denegación.
- El secreto OAuth permanece fuera del repositorio. No leer ni mostrar `.env`; las claves del entorno local tampoco deben imprimirse.

## Excepción de secuencia temporal para #5 — 2026-10-31

El usuario pidió seguir avanzando sin completar el inicio manual de Google OAuth en Chrome. Para permitir trabajo verificable, se acuerda una excepción de secuencia solo para implementación de #5:

- La integración local avanzó por fast-forward desde d7ebc632a5df207afda34273f6850bce68b3f146 hasta e4a1b8fe00d6d0f09e3cffb4188a462645ce6b40, que contiene el código de #4 ya revisado y las pruebas automatizadas descritas en docs/validation/issue-4.md.
- #4 continúa abierto y ready-for-human. Login real de Google con identidad habilitada, identidad no habilitada y sin sesión, más logout/cambio de cuenta según el ticket, siguen pendientes. Fixtures no satisfacen ni se presentan como evidencia de OAuth real.
- Se permite implementar y verificar #5 aunque la relación GitHub Blocked by #4 siga vigente, exclusivamente en el Supabase local aislado y con identidades/claims Auth sintéticos. Esto no agrega bypass a la aplicación, no debilita autenticación/autorización y no habilita acceso a datos reales.
- Mantener la arista de dependencia en GitHub. No cerrar #4 ni #5 mientras haya criterios pendientes; ante una dependencia de OAuth real, dejar ese criterio accionable y continuar solo con trabajo independiente autorizado.
- Esta excepción no autoriza main, producción ni migraciones remotas. En este checkpoint no se publicó ni se hizo push. Se preservan los cambios locales ajenos en docs/VALIDATION.md y .scratch/.

Base de la próxima rama de trabajo: la punta de codex/openkanban-1-0 luego de este checkpoint. Reconciliar nuevamente el tracker y registrar la excepción en el comentario inicial de #5.

## Entrega local de #5 — 2026-10-31

La implementación de «Administrar habilitación global» se revisó y se integró por fast-forward en codex/openkanban-1-0. El HEAD de código/revisión es 85ef1e7656bc7f19c9fd8a60f0cfc93e5cf4e1bf, basado en 34a73e7f442d05978085d7d52d91d77f946b16d8. Evidencia reproducible en docs/validation/issue-5.md.

- TDD rojo-verde y validación con PostgreSQL descartable y Supabase local separado #5 (migraciones 001–016), solo identidades/claims sintéticos; no se tocó la instancia #4.
- Pasaron pnpm test:db, pnpm typecheck, pnpm build y Biome dirigido. La matriz global de lint informa 83 diagnósticos preexistentes en archivos fuera del diff.
- Revisiones Spec y Standards sobre el HEAD final: sin hallazgos materiales ni infracciones hard. Se corrigió la revalidación de admin antes/después de locks, incluyendo prueba de no contención para no-admin.
- Navegación sin sesión a /admin/access redirige a login sin revelar el listado. No se realizó OAuth ni se probó la vista con admin autenticado.
- GitHub #5 permanece OPEN, asignado a elgastipaa, ready-for-human y con Blocked by #4 intacto. Inicio y evidencia registrados en comentarios de #5; evidencia de entrega: https://github.com/elgastipaa/open-kanban/issues/5#issuecomment-6547286317.
- #4 permanece OPEN y ready-for-human por OAuth/Auth real pendiente. Se observó un error de hidratación en /login por enlaces anidados, fuera del diff de #5; informar y resolver dentro de #4 antes de su recorrido autenticado.
- C-81/A-04 queda parcialmente verificable: aún no hay modelos de membresías, roles, asignaciones y avisos. La suspensión de dueños de tableros se rechaza hasta resolver propiedad conforme a #19.
- No hubo push. Se preservan docs/VALIDATION.md y .scratch/ ajenos; main y producción no se tocaron.

Próximo paso humano cuando el usuario esté en la computadora: continuar OAuth real de #4 en Chrome local y verificar identidades habilitada/no habilitada/sin sesión; luego repetir la vista admin autenticada de #5. El fallo de hidratación observado en el smoke del 31/10 ya se corrigió y verificó en la sección siguiente. La excepción de secuencia no convierte este trabajo local en aceptación de OAuth ni permite cerrar #4/#5.

## Corrección del smoke sin sesión de #4 — 2026-10-31

El smoke de #5 reveló hidratación fallida en login: `src/app/login/page.tsx` envolvía `Logo` en un `Link` aunque `Logo` ya genera el enlace a `/`. El cambio acotado `d810d457c1810d06c516490ddf07bf11783ef291` elimina únicamente el envoltorio redundante y su import. Base fija: `b8b6bb32524070b4cd829ce11302e5a8124c3602`.

- TDD en navegador local, sin sesión: antes, `/admin/access` redirigió con `307` a `/login?next=%2Fadmin%2Faccess`; el DOM tenía dos anchors, uno anidado, y React reportó `Hydration failed`. Después, la misma ruta terminó en login, quedó un solo anchor, cero anidados y no hubo errores/avisos nuevos de consola. No se inició Google OAuth ni se autenticó.
- Pasaron `pnpm typecheck`, `pnpm build`, Biome dirigido para `src/app/login/page.tsx` y `git diff --check`.
- Spec y Standards revisaron el HEAD de código `d810d45` contra `b8b6bb3`: sin hallazgos; Standards no encontró infracciones ni smells accionables.
- #4 sigue OPEN/`ready-for-human`; OAuth/Auth real con identidad habilitada y no habilitada, logout y cambio de cuenta aún requieren recorrido manual. Este hotfix no satisface esos criterios.
- Evidencia comentada en el issue #4: https://github.com/elgastipaa/open-kanban/issues/4#issuecomment-6547402399.
- No se hizo push ni se operó main/producción. Se preservan `docs/VALIDATION.md` y `.scratch/` ajenos.

Integración final de #4: el fast-forward local desde b8b6bb32524070b4cd829ce11302e5a8124c3602 dejó codex/issue-4 y codex/openkanban-1-0 en 5711755888a59d44845d3fb6d2de8ac68c8712ee (corrección de código d810d45, evidencia c0698f1, comentario de issue 5711755). No se hizo push; #4 permanece abierto/ready-for-human hasta OAuth real.

## Extensión de secuencia por instrucción del usuario — 2026-10-31

El usuario pidió continuar cuanto se pueda hasta completar el objetivo sin requerir su presencia local. Se amplía la excepción de secuencia de #5 a los descendientes alcanzables para implementación, sin alterar el contrato del producto:

- Se permite iniciar el siguiente ticket abierto especificado aunque sus dependencias anteriores sigan OPEN/ready-for-human, siempre que el trabajo pueda verificarse con interfaces aprobadas en entornos locales aislados y actores/claims sintéticos.
- Mantener intactas las relaciones Blocked by del tracker y no cerrar ni marcar como aceptados tickets cuyos criterios requieran OAuth/Auth real, UI autenticada no validada, hardware/personas, modelos aún no implementados u otra condición humana. Registrar evidencia parcial y pasar al siguiente trabajo técnicamente independiente cuando sea seguro.
- No agregar rutas, flags, credenciales ni otros bypasses al producto. Sin Google OAuth automatizado, datos reales, main, push a main, migración o despliegue de producción. La aprobación especial del corte #53 continúa vigente.
- Aplicar LP-0.2: menor número de ticket alcanzable por esta excepción, un único implementador activo, skills implement-spec/implement/TDD/code-review, rama y worktree aislados, revisiones e integración. La autorización previa de commits/push a ramas codex y actualización de la PR acumulada sigue vigente; no se hace merge/push a main ni se despliega producción.

Siguiente ticket: #6 «Crear y encontrar tableros privados», contrato C-93/C-96; P01/P07/P10/P12/P16. GitHub conserva Blocked by #4; su avance se autoriza solo como implementación y verificación local. #4/#5 siguen abiertos y su aceptación manual no se infiere.

## Entrega local de #6 — 2026-10-31

La instrucción del usuario amplió la excepción de secuencia para implementar #6 con entorno local aislado y actores sintéticos, manteniendo la dependencia nativa y textual `Blocked by #4`. La rama `codex/issue-6` parte de `ee2771e75a7c18592b0af7eea814afae66f119da`. El HEAD de código revisado es `22da1e221ec607fff7a69d683ba3b151c81a2d13`; commits de código: `fd3af1f` (crear/encontrar tableros), `ffb8981` (aislar borrador de alta por UUID Auth y ampliar pruebas de permisos/revocación) y `22da1e2` (quitar estado móvil duplicado y publicar `pnpm test:unit`). Evidencia criterio por criterio en `docs/validation/issue-6.md`.

- TDD rojo-verde. Pasaron `pnpm test:unit` (2/2), `pnpm test:db` con PostgreSQL descartable, `pnpm typecheck`, `pnpm build` (Next 16.4.2), Biome dirigido y `git diff --check`.
- Spec y Standards revisaron el HEAD de código `22da1e2` contra la base fija `ee2771e`; ambos quedaron sin hallazgos. Se corrigieron los tres P2 de Spec y los dos hallazgos bajos de Standards antes de esa revisión final.
- El proyecto local único `open-kanban-issue-6` respondió en Auth health y aplicó migraciones 001–017; no se emitió sesión. No había browser runner headless existente y el smoke Auth→PostgREST no pudo ejecutarse por el bloqueo de la herramienta al manejar secretos locales en memoria. No se usó Google, IAB/CUA, credencial real ni `.env`.
- La DB prueba owner/member, creación vacía y zona, lista/lectura por membresía vigente, rename owner con slug estable, mutaciones de columnas como miembro, revocación, generación archivada, constraints, idempotencia y carreras entre sesiones sintéticas. UI autenticada, móvil/teclado real y reconciliación visible tras timeout quedan parciales/no probadas; ver la matriz en `docs/validation/issue-6.md`.
- #6 permanece OPEN y pasa a `ready-for-human` mientras falte Auth→PostgREST y recorrido UI autenticado; `Blocked by #4` permanece intacto. No inferir aceptación de #4, no cerrar #6. La excepción solo habilitó el trabajo aislado y no cambia contratos ni autoriza producción.
- La integración fast-forward de código y evidencia y la verificación final de tracker se registran después de esta sección cuando concluyan.

### Integración y tracker de #6 — 2026-10-31

La entrega de código revisada (`22da1e221ec607fff7a69d683ba3b151c81a2d13`) y el informe reproducible se integraron por fast-forward en `codex/openkanban-1-0`, desde `ee2771e75a7c18592b0af7eea814afae66f119da` hasta `af27f275c25526f6074207bd90e28ce906624aaa`. El push ordinario de la rama codex llegó a `origin`; no hubo force-push. La PR acumulada #54 sigue open/draft con esta entrega en su body. Este checkpoint es un commit documental posterior al código y a la evidencia.

GitHub #6 verificado después de integrar: **OPEN**, asignado a `elgastipaa`, con `ready-for-human`; el body y la relación nativa `Blocked by #4` siguen presentes. El comentario de evidencia es `https://github.com/elgastipaa/open-kanban/issues/6#issuecomment-6548679571`. #4 y #5 siguen abiertos. No se cerró ningún issue.

Los cambios ajenos de `docs/VALIDATION.md` conservaron SHA-256 `B8669EAAFEA1A6D41C1342470E49324D2FAA50BED03DCCCFE7E94AF17D51FD9C`; `.scratch/` sigue sin seguimiento y preservado. No se modificó `main`, no se ejecutó SQL remoto y no hubo despliegue de producción.

## Entrega local de #7 — 2026-10-31

La implementación de «Capturar tareas consecutivas sin duplicados» se revisó contra la base fija `1312906108fa2a4815dd1a42cd5d889d04a16951`. Código final revisado: `9ff7421b7aff4b749a8cb706ad416c4c42562469`; evidencia y rama de trabajo: `7b575e2109c7294f6882a50e163efdd14e122eec`. La integración `codex/openkanban-1-0` avanzó por fast-forward desde la base hasta `7b575e2` y se publicó en `origin`; el commit de este checkpoint/documentación queda después de ese HEAD.

- TDD rojo-verde con Postgres 16.15 descartable, migraciones 001–018 y actores sintéticos. Se cubren Enter/botón y no creación por blur en código; recibos durables, replay y respuesta perdida; distintas cargas con la misma clave incluidas colisiones entre tableros; expiración; tarea movida; whitespace; validación de tablero/columna; autoría derivada; campos protegidos; doble captura concurrente; denegación genérica al reconciliar tras revocación y carrera de revoke-vs-resolve.
- Pasaron `pnpm test:db`, `pnpm test:unit` (5/5), `pnpm exec next typegen && pnpm typecheck`, `pnpm build` (Next 16.4.2), Biome dirigido, `bash -n scripts/test-db.sh` y `git diff --check`. Evidencia por criterio: [docs/validation/issue-7.md](../validation/issue-7.md).
- Reviews finales sobre el HEAD de código/evidencia `7b575e2` contra la base fija: Spec sin findings; Standards sin infracciones duras. Se anotaron smells no bloqueantes de duplicación y agrupamiento de argumentos.
- GitHub #7 continúa OPEN, asignado a `elgastipaa`, etiquetado `ready-for-human` y con `Blocked by #6` conservado. No se marcaron criterios humanos como cumplidos ni se cerró el issue. Evidencia comentada: https://github.com/elgastipaa/open-kanban/issues/7#issuecomment-6549429359.
- La PR acumulada #54 continúa OPEN/draft; su body incluye #7 y el informe reproducible. No se cambió el base branch.
- Auth/PostgREST HTTP, OAuth y recorrido real de UI/DOM/foco/teclado siguen pendientes. No se usaron cuentas, sesiones, datos o claves reales; no se operó `main` ni producción.
- Se preservaron los cambios ajenos de `docs/VALIDATION.md` y `.scratch/` sin stage/commit.

Próximo paso: completar Auth/PostgREST y recorrido de navegador con sesión sintética legítima cuando el prerequisito #6 y el runner permitan hacerlo. Mantener #7 abierto y su dependencia intacta hasta verificar todos sus criterios.

## Entrega local de #8 — 2026-10-31

La implementación de «Editar desde un detalle único y resolver conflictos» se completó en `codex/issue-8` desde la base fija `8200bab94d74bd53f7f6148e0259ff787adcc667`. HEAD de código revisado: `8bbc6f33c55ab8282cf61f2667155a170e96820c`; matriz por criterio y estado final de revisiones/tracker: [docs/validation/issue-8.md](../validation/issue-8.md). La rama se integró por fast-forward en `codex/openkanban-1-0`.

- TDD con migración 019, PostgreSQL desechable 16.15 y actores Auth sintéticos. `pnpm test:db` pasa en el árbol con la migración 019; commits posteriores solo modificaron UI y estados de foco/borrado. La DB cubre dos editores sobre mismo campo, combinación de campos distintos, receipts/replay/colisión/expiración, movimiento independiente, permisos y revocación.
- En HEAD final pasan `pnpm test:unit` (18/18), `pnpm typecheck`, `pnpm build` (Next 16.4.2), Biome dirigido y `git diff --check`. El lint completo sigue mostrando diagnósticos de formato/lint previos en archivos fuera del diff.
- Reviews finales Spec y Standards contra la base fija `8200bab`: sin hallazgos materiales ni infracciones de normas. Quedan olores de mantenimiento bajos documentados en `test-db.sh` (andamiaje concurrente duplicado) y `TaskEditOperation` (forma duplicada de `TaskEditCommand`).
- `TaskModal` permanece parcial respecto de UI-05: hoy se abre desde el tablero y edita título, descripción y prioridad; faltan entradas desde Mis tareas/búsqueda/vistas/novedades y acciones/campos todavía no implementados. DOM, Escape, recorrido móvil/escritorio, Auth/PostgREST HTTP y mala conexión real requieren recorrido humano; no se instaló runner de navegador.
- C-95: al borrar con cambios, Guardar y continuar solo abre la confirmación tras `confirmed`; error/conflicto no borran. Se cierra el detalle antes de la confirmación; Cancelar reabre el detalle guardado si la tarea existe y confirmar restaura foco al vecino/columna/tablero después del borrado. Borrado directo desde tarjeta no reutiliza un origen anterior. Transiciones unitarias prueban este flujo; Escape/DOM sigue manual.
- GitHub #8 permanece OPEN, asignado a `elgastipaa`, label `ready-for-human`, con `Blocked by #7` sin cambios; evidencia comentada en https://github.com/elgastipaa/open-kanban/issues/8#issuecomment-6550002568. #7 continúa OPEN/`ready-for-human` y conserva `Blocked by #6`.
- PR acumulada #54 continúa OPEN/draft, base `main`, head `codex/openkanban-1-0`; body actualizado con #8, evidencia y límites. Evidencia remota: https://github.com/elgastipaa/open-kanban/blob/codex/openkanban-1-0/docs/validation/issue-8.md.
- Se preservó el cambio ajeno de `docs/VALIDATION.md` con SHA-256 `B8669EAAFEA1A6D41C1342470E49324D2FAA50BED03DCCCFE7E94AF17D51FD9C` y `.scratch/` sin seguimiento. No se modificó `main`, no se ejecutó SQL remoto ni hubo despliegue.

El issue queda abierto/ready-for-human por bloqueo y verificación manual pendiente. Esta entrega no autoriza cerrar #8/#7, merge a `main`, ni despliegue a producción.

## Entrega local de #9 — 2026-10-31

La implementación de «Mover y ordenar sin perder ediciones» se hizo en `codex/issue-9` desde la base fija `03f3daf31ae38470603eef3ad5740234eaa70471`. HEAD final revisado: `cd868c322c13ba0ffa71034dfe657e21fc4b7868`; commits de implementación/fixes `92df01c`, `3b680cb` y `cd868c3`. Evidencia por criterio: [docs/validation/issue-9.md](../validation/issue-9.md). La entrega local se integró por fast-forward en `codex/openkanban-1-0` desde esa base.

- TDD rojo-verde con PostgreSQL 16.15 descartable y actores/claims sintéticos. `pnpm test:db` pasó con migraciones 001–020, lote atómico de varias columnas, cruce de tablero, anclas/versiones, replay, expiración, permisos y carrera real de dos miembros: un movimiento confirmó y el otro quedó en conflicto sin posiciones parciales. Se probó reordenar enseguida después de crear y borrar una tarea con versiones leídas/autorizadas.
- `pnpm test:unit` pasó 24/24; también pasaron `pnpm typecheck`, `pnpm build` (Next 16.4.2), Biome dirigido, `bash -n scripts/test-db.sh` y `git diff --check`.
- Los recibos no almacenan filas ni snapshots privados. El replay vigente reconstruye el estado actual autorizado; el recibo vencido devuelve `expired_unknown` sin aplicar otra mutación. La reconciliación posterior a altas/bajas adopta el snapshot con `ledger.sync`, conserva ediciones pendientes y no mezcla una versión nueva con anclas locales antiguas.
- Reviews Spec/Standards en paralelo sobre HEAD `cd868c3` contra la base fija `03f3daf`: Spec sin hallazgos; Standards sin infracciones duras ni smells en código de producto. Se resolvieron los hallazgos materiales. Queda un smell menor de fixtures autocontenidas repetidas entre dos pruebas unitarias.
- El DOM/foco real, teclado, móvil, lector de pantalla, Realtime visual y Auth/PostgREST HTTP siguen parciales o pendientes; no había runner de navegador ya instalado y no se instaló uno. La evidencia los distingue de las pruebas automáticas.
- #9 sigue OPEN/`ready-for-human`. #3 está cerrado con entrega; #8 continúa OPEN/`ready-for-human`. Las relaciones nativas/textuales `Blocked by #3` y `Blocked by #8` se conservan. No se cerró #9 ni se aceptó manualmente #8.
- No se usaron Google OAuth, cuentas/datos reales, CUA/IAB, bypass de permisos, migraciones remotas ni producción. No se tocó `main` ni hubo despliegue.

### Integración y tracker de #9 — publicado

La integración de código `cd868c322c13ba0ffa71034dfe657e21fc4b7868` avanzó por fast-forward desde `03f3daf31ae38470603eef3ad5740234eaa70471`; el push ordinario inicial publicó `dadba7dadc2435b59ff2bb2dc6a40dea9def62ec` en `origin/codex/openkanban-1-0`. Este commit registra el estado final de integración y tracker. La PR acumulada #54 está OPEN/draft, base `main`, head `codex/openkanban-1-0`, título `OpenKanban 1.0 — implementación progresiva (#3–#9)`; su body incluye la evidencia de #9 y los pendientes humanos.

- GitHub #9 está OPEN, asignado a `elgastipaa` y etiquetado `ready-for-human`. Evidencia comentada: https://github.com/elgastipaa/open-kanban/issues/9#issuecomment-6550598906. No se cerró ni se cambiaron sus aristas.
- #3 está CLOSED con entrega; #8 continúa OPEN/`ready-for-human`. El body de #9 conserva `Blocked by #3` y `Blocked by #8`; #8 conserva su `Blocked by #7`.
- La PR se mantuvo en borrador y con base `main`; no se hizo merge ni se tocó `main`.

Se preservan los cambios ajenos de `docs/VALIDATION.md` con SHA-256 `B8669EAAFEA1A6D41C1342470E49324D2FAA50BED03DCCCFE7E94AF17D51FD9C` y `.scratch/` sin seguimiento. No hacer force-push, ejecutar SQL remoto ni desplegar producción.

## Entrega local de #10 — 2026-10-31

La implementación de «Completar, agrupar y reabrir tareas» parte de la base fija a374ade3f47991be2a2d5594d082318bfc3b2f2a en la rama aislada codex/issue-10. HEAD de código revisado: bc1313999bcfdcb2f7170f35c3b520f718e38067; evidencia reproducible por criterio en docs/validation/issue-10.md. La entrega de código y evidencia quedó integrada por fast-forward y push ordinario en codex/openkanban-1-0.

- TDD con PostgreSQL 16.15 descartable y actores Auth sintéticos. pnpm test:db aplica migraciones 001–021; cubre estado deseado, reintentos/recibos, permisos, conservación de columna y campos, y una carrera real de completar/reabrir en dos sesiones.
- pnpm test:unit pasó 28/28; también pnpm typecheck, pnpm build (Next 16.4.2), Biome dirigido, bash -n scripts/test-db.sh y git diff --check.
- Reviews finales sobre HEAD de código bc13139 contra base fija a374ade: Spec sin hallazgos accionables; Standards sin infracciones duras. Quedan dos smells heurísticos menores: validación/mapeo repetidos en el adaptador DB y controles locales del grupo completado repetidos entre column.tsx y mobile-board.tsx; no fueron material findings.
- Auth/PostgREST HTTP y validación humana de DOM/foco, móvil, teclado, accesibilidad, dos navegadores y los recorridos de conflicto/borrador C-95 siguen parciales o pendientes. No se instaló runner ni se usaron OAuth, cuentas/datos reales, .env, CUA/IAB, bypass de permisos, migraciones remotas ni producción.
- GitHub #10 permanece OPEN, asignado a elgastipaa, ready-for-human y con Blocked by #8 intacto. Evidencia comentada: https://github.com/elgastipaa/open-kanban/issues/10#issuecomment-6550847738. #8 permanece OPEN/ready-for-human; no se infiere aceptación manual ni se cierra ningún issue.
- PR acumulada #54 continúa OPEN/draft, base main, head codex/openkanban-1-0; body actualizado con #10, su evidencia y los pendientes humanos. No se hizo merge ni se tocó main o producción.
- Se preservan docs/VALIDATION.md con SHA-256 B8669EAAFEA1A6D41C1342470E49324D2FAA50BED03DCCCFE7E94AF17D51FD9C y .scratch/ local sin seguimiento, sin stage/commit.

Siguiente trabajo alcanzable: consultar la secuencia y dependencia vigente antes de seleccionar otro issue. #10 requiere recorrido humano local autorizado y resolución del bloqueador #8 antes de aceptación/cierre.
