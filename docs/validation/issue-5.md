# Issue #5 — evidencia de implementación

Fecha: 31/10/2026. Issue: «Administrar habilitación global». Rama local: `codex/issue-5`. Base fija: `34a73e7f442d05978085d7d52d91d77f946b16d8`. Commit de código revisable antes de esta evidencia: `e3470c2b8de2eec43e0658713632fe699ec4aef5`. El issue remoto sigue abierto y bloqueado por #4.

Se usaron únicamente identidades y claims sintéticos en dos entornos locales aislados: PostgreSQL descartable para regresiones y un proyecto Supabase local separado de la instancia de #4 (API 57421, PostgreSQL 57422; proyecto `supabase-local-issue5-2026-10-31`). No se conectó a Auth remoto ni a producción. Los alias de fixture usan exclusivamente el dominio reservado `.example.test`; no se guardaron correos reales, contraseñas, JWT ni claves. El proyecto local no comparte puertos ni contenedores con `open-kanban-auth-issue-4` (56421/56422).

## Alcance implementado

- Panel privado de administración para habilitar una dirección, retirar una autorización pendiente y suspender o rehabilitar una identidad ya vinculada. La ruta de datos de administración exige facultad global en servidor/base; la lista no se obtiene para personas usuarias comunes.
- Primera vinculación con correo Google verificado, ligada a la identidad Auth/Google estable. Un cambio posterior del correo no crea otra identidad ni elude una suspensión. Los correos se recortan y pasan a minúsculas, sin eliminar acentos ni convertir `ñ`.
- La autorización vigente se comprueba en operaciones de base: suspender bloquea operaciones posteriores hechas incluso con el mismo `sub`/claim sintético previo. Rehabilitar la misma fila de acceso no crea tablero ni restaura permisos que no existen en el modelo actual.
- La suspensión de quien aún posee un tablero falla sin cambiar su acceso, hasta resolver la propiedad conforme al issue #19. La administración no lee contenido de tableros ajenos. No se implementó transferencia ni flujo nuevo de propiedad.
- Se protege la última cuenta administradora activa. Las mutaciones administrativas serializan sobre la tabla de acceso y vuelven a comprobar al actor luego de esperar el lock.
- El campo de correo usa texto con teclado `email` y autocompletado de email, sin validación HTML que rechace local-parts Unicode antes del servidor. La RPC conserva el valor para su validación y los formatos inválidos muestran un error accesible en español.
- Formularios, acciones, estados y errores de la UI están en español; errores de red/RPC se comunican como error accesible y la carga se libera también ante excepción.

## Evidencia automática

Versiones usadas: Node.js 24.14.1, pnpm 11.25.0, Next.js 16.4.2, Supabase CLI 2.122.0 (ejecutada con `pnpm dlx`), Docker 29.4.3; Supabase local con PostgreSQL 17.11. No se requiere instalar Supabase CLI globalmente.

| Criterio | Evidencia reproducible | Resultado |
| --- | --- | --- |
| Solo admin lista o administra el acceso global | `tests/db/admin_authorization.sql`, aplicado por `pnpm test:db`; identidad habilitada no admin intenta listar, habilitar, retirar y suspender | Pasa; operaciones rechazadas sin cambios laterales. |
| Alta pendiente, retiro, correo verificado y vínculo Google estable | `tests/db/authentication.sql`; identidades sintéticas admin, destino habilitado, denegado y no verificado; cambio de correo después de vincular | Pasa; una identidad Google no verificada no se habilita; cambiar correo no mueve ni duplica la identidad vinculada. |
| Suspensión efectiva con un claim anterior | `tests/db/authentication.sql`, bloque «valid token cannot bypass current suspension»: el actor conserva el mismo `request.jwt.claim.sub` sintético luego de suspenderse; se intentan resolver acceso, leer tableros y crear un tablero | Pasa; acceso queda `suspended`, la lectura retorna vacío y la escritura es denegada. |
| Rehabilitar sin restaurar accesos ajenos | `tests/db/authentication.sql` y `tests/db/local_supabase_issue5.sql`; se rehabilita la misma fila vinculada y se comprueba acceso de aplicación y listado de tableros | Pasa para el esquema disponible: se conserva el vínculo estable, no aparece fila bajo el email actualizado y no se recrea un tablero. |
| Correo exacto con diacríticos | `tests/db/authentication.sql`: autoriza por separado `peña`/`pena` y `café`/`cafe` en fixture | Pasa; se conservan las cuatro autorizaciones distintas. |
| Formato del campo de correo | `src/components/auth/access-manager.tsx` usa `type="text"`, `inputMode="email"`, `autoComplete="email"`, `required`; `tests/db/authentication.sql` comprueba el rechazo RPC de una dirección inválida y su mensaje de validación | El navegador permite enviar local-parts Unicode; el servidor valida y la UI traduce el error `23514` a un mensaje accesible en español. |
| Último admin y carreras de administración | `tests/db/authentication.sql` prueba que el único admin no se suspende. `scripts/test-db.sh` retiene el lock como un admin y verifica que un actor habilitado no admin reciba `42501` en habilitar, retirar y suspender antes de esperar; «admin-access-race» fuerza a un segundo admin a esperar mientras pierde la facultad | Pasa; las tres operaciones no admin fallan sin contención, y el RPC del admin suspendido devuelve `42501` tras el lock; queda un admin activo y la segunda suspensión no ocurre. La prueba nueva fue roja antes de mover el primer chequeo, observando al no admin en `wait_event_type = 'Lock'`, y verde con los chequeos previo y posterior al lock. |
| Dueño de tablero y privacidad administrativa | `tests/db/authentication.sql` y `tests/db/local_supabase_issue5.sql` intentan suspender al dueño y comprobar que admin no puede leer el tablero ajeno | Pasa; suspensión da SQLSTATE `55000`, mantiene activa la cuenta y la lectura global de contenido no se concede. |
| Supabase Auth/Postgres real local aislado | Reset sin seed con CLI 2.122.0, migraciones 001–016 y `tests/db/local_supabase_issue5.sql` mediante `psql` dentro del contenedor DB local | Pasa con solo identidades/claims sintéticos; no acredita proveedor OAuth ni una sesión Auth server real. |
| Compilación y tipos | `pnpm build` con URL local y clave publishable placeholder; `pnpm typecheck` | Pasa; Next 16.4.2 compiló las rutas `/admin/access`, `/login` y `/auth/callback`. |
| Lint del archivo modificado | `pnpm exec biome check src/components/auth/access-manager.tsx` | Pasa sin correcciones. |

Comandos de verificación del checkout:

```sh
pnpm exec biome check src/components/auth/access-manager.tsx
pnpm typecheck
pnpm test:db
pnpm build
```

Para repetir el smoke contra la instancia Supabase local aislada, con Docker iniciado:

```sh
pnpm dlx supabase@2.122.0 db reset --workdir <proyecto-local-issue5> --local --no-seed
docker cp tests/db/local_supabase_issue5.sql supabase_db_supabase-local-issue5-2026-10-31:/tmp/issue5-local-smoke.sql
docker exec supabase_db_supabase-local-issue5-2026-10-31 psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/issue5-local-smoke.sql
```

`pnpm test:db` crea su propio PostgreSQL descartable y no consume `DATABASE_URL`, `PGHOST` ni el proyecto Supabase local. En Windows se fijó LF para `scripts/*.sh` mediante `.gitattributes`. El lint general `pnpm lint` se ejecutó y falla por 83 diagnósticos de formato repartidos por archivos preexistentes sin cambios en este diff; el único archivo de código modificado que procesa Biome pasa en el check dirigido.

## Recorrido manual y pendientes

- Recorrido sin sesión: se abrió `http://127.0.0.1:3105/admin/access` en IAB local. La navegación terminó en `/login?next=%2Fadmin%2Faccess`; el árbol accesible mostró «Accede a tus tableros» y no mostró la tabla privada. La consola reportó hydration failure preexistente por `<a>` anidado entre `src/app/login/page.tsx` y `src/components/ui/logo.tsx`; ninguno cambia en este diff. No se inició Google OAuth ni se usó una sesión humana.
- Pendiente por #4: inicio de sesión real Google con identidad habilitada/no habilitada, callbacks y comprobación de la UI privada como administrador autenticado. No se presenta la fixture sintética ni la pantalla sin sesión como evidencia de OAuth. Sin OAuth no fue posible completar el recorrido visual de administración con actor autenticado; no se creó atajo de test ni se debilitó autenticación.
- Parcial C-81/A-04: el esquema presente todavía no implementa membresías, roles de tablero, asignaciones ni avisos. Las pruebas verifican que rehabilitar no cree un tablero ni cambie la autorización vinculada; no pueden demostrar la retirada/no restauración de aquellos objetos ausentes. Esto debe comprobarse cuando existan esos modelos y recorridos.
- Suspensión de propietarios queda diferida al issue #19: la implementación la rechaza hasta la resolución íntegra de propiedad; no ofrece una acción de transferencia ni lee tableros privados para administradores.
- El smoke local usa filas `auth.users`/`auth.identities` y claims SQL sintéticos. Es integración con el esquema Auth/Postgres local, no login en el servicio Auth ni evidencia de cuentas Google.

El issue remoto se actualizó con el comentario de arranque y la evidencia de entrega; permanece abierto, asignado y etiquetado ready-for-human, con la relación Blocked by #4 intacta. El código se integró por fast-forward local en codex/openkanban-1-0 en 85ef1e7656bc7f19c9fd8a60f0cfc93e5cf4e1bf. No hubo push, cambios a main ni operaciones de producción. #5 queda pendiente del bloqueo heredado de OAuth de #4, la UI admin autenticada y la verificación futura de C-81/A-04 cuando existan esos modelos.
