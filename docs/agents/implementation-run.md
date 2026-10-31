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
- Aplicar LP-0.2: menor número de ticket alcanzable por esta excepción, un único implementador activo, skills implement-spec/implement/TDD/code-review, rama y worktree aislados, revisiones y fast-forward local; push queda desactivado para este tramo por el pedido de avanzar sin intervención local.

Siguiente ticket: #6 «Crear y encontrar tableros privados», contrato C-93/C-96; P01/P07/P10/P12/P16. GitHub conserva Blocked by #4; su avance se autoriza solo como implementación y verificación local. #4/#5 siguen abiertos y su aceptación manual no se infiere.
