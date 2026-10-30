# Issue #4 — evidencia de implementación y revisión

Fecha: 30/10/2026. Issue: «Entrar con Google a una aplicación cerrada». Rama local: `codex/issue-4`. Base fija de revisión: `d7ebc632a5df207afda34273f6850bce68b3f146`. Código revisado: `94fa29a97fd2e4aae50a358a7d68538ed3c03f8f` (`fix(auth): respect Supabase Realtime ownership (#4)`). Este informe se registra en un commit documental posterior; la revisión se fija al HEAD de código indicado.

No se copiaron correos ni secretos a este repositorio, a la documentación ni a GitHub. En la nueva instancia local aislada existe una fila de acceso `pending` con `is_admin=true` para la identidad que el usuario eligió; el valor de identidad no se reproduce aquí. No se creó una sesión de Google ni un usuario Auth real todavía.

## Alcance implementado

- Inicio de sesión Google por OAuth/PKCE, callback de retorno interno, controles de Auth y admisión en servidor/proxy/RPC, pantallas de acceso y administración.
- Admisión explícita ligada a la identidad Auth y al `sub` estable del proveedor; bootstrap administrador solo por fixture, nunca por ser el primer visitante.
- Lectura, escritura y Realtime privados por identidad/propiedad de tablero; sin sesión, sin habilitación, suspensión, URL conocida o permisos alternativos no conceden acceso.
- La migración 015 no cambia el ownership de `realtime.messages`: verifica que Supabase ya haya habilitado RLS y luego administra solo las políticas de OpenKanban.
- La página de tablero comprueba identidad y estado de admisión; logout, otra identidad o denegación confirmada abortan fetches, desmontan el estado privado y redirigen. Respuestas de refresco de una época anterior se descartan.
- Fallos temporales de Auth/RPC dejan los últimos datos cargados con un aviso accesible de información desactualizada. Revalidar al volver al foco conserva la pantalla mientras espera una confirmación.
- La interfaz y el idioma del documento parten en español.

Los tableros previos sin propietario quedan inaccesibles y con `owner_id` nulo. No hay inventario ni asignación automática; su transición requiere inventario autorizado y asignación explícita a la persona propietaria (D-07/C-98).

## Verificaciones del código

| Comando / recorrido | Resultado |
| --- | --- |
| `pnpm exec biome check -- <24 archivos cambiados>` | Pasa; 24 archivos TS/TSX/JS/JSON/CSS del diff revisados después del formato. |
| `pnpm typecheck` | Pasa. |
| `pnpm build` | Pasa con Next.js 16.4.2; rutas `/`, `/[slug]`, `/admin/access`, `/auth/callback` y `/login` compiladas. |
| `pnpm test:db` | Pasa contra PostgreSQL descartable. Incluye no sesión, acceso habilitado/no habilitado, bootstrap por fixture, identidad Google ligada a Auth estable, propiedad, aislamiento, suspensión, cambios de `sub`, RLS/Realtime y regresiones previas. |
| Supabase local real (CLI 2.122.0; PostgreSQL 17.11; Realtime 2.147.1), migración limpia | Pasa. Se aplican 001–015. En la tabla gestionada `realtime.messages`, owner=`supabase_realtime_admin`, RLS sigue activo y existen las políticas SELECT/INSERT de OpenKanban para `authenticated`. SHA-256 del archivo 015 coincide entre worktree e instancia aislada: `863163A76C849CE2194C646B5FADD8183FD4A47DD37ACFE9AEF744C598EA94A7`. |
| Realtime privado en el tenant local aislado | Se habilitó `private_only=true` en el único tenant de la instancia vacía y se confirmó con lectura. Un cliente `@supabase/supabase-js` con anon key y canal `private:false` fue rechazado con `PrivateOnly`. Esta setting corresponde al tenant local; no es una migración de la app ni evidencia de configuración de producción. [Settings](https://supabase.com/docs/guides/realtime/settings) · [respuesta del equipo Supabase sobre `private_only` local](https://github.com/orgs/supabase/discussions/22484#discussioncomment-11170948). |
| Auth/RLS real local con claims sintéticos | Pasa dentro de transacciones revertidas sobre el esquema Auth/Postgres real de Supabase: identidad habilitada puede acceder a su topic privado, identidad no habilitada, sin sesión y no-propietario no pueden. No se creó ni se usó una cuenta Google real; esto no prueba OAuth/Auth server. |
| Auth real de Supabase y login Google en navegador | Pendiente de interacción manual; las pruebas SQL definen tablas/funciones Auth simuladas y no acreditan esta integración. El `302` del proveedor a `accounts.google.com` tampoco la acredita. La fila local `pending` de administrador debe activarse y ligarse a la identidad Auth/Google al completar el primer login. |

### Lint global

`pnpm lint` falla con 60 errores de categoría `format` en 60 archivos sin cambios. El check dirigido de Biome pasa en los 24 archivos de código compatibles del diff; las tres SQL modificadas no son formatos que Biome procese (`Checked 0 files` para ellas) y se validaron con `pnpm test:db` y la instancia local real. Ningún archivo del check dirigido aparece entre los 60 errores. No se reformatearon archivos ajenos.

Rutas exactas del baseline:

```text
biome.json
next.config.ts
package.json
postcss.config.mjs
src/app/globals.css
src/app/rate-limit/page.tsx
src/app/robots.ts
src/app/sitemap.ts
src/components/board/add-column.tsx
src/components/board/add-task.tsx
src/components/board/board-skeleton.tsx
src/components/board/column-header.tsx
src/components/board/column.tsx
src/components/board/keyboard-shortcuts.tsx
src/components/board/mobile-board.tsx
src/components/board/mobile-column-controls.tsx
src/components/board/mobile-task-card.tsx
src/components/board/task-card.tsx
src/components/board/task-modal.tsx
src/components/landing/background-layer.tsx
src/components/landing/call-to-action.tsx
src/components/landing/footer.tsx
src/components/landing/gradient-overlay.tsx
src/components/landing/hero-section.tsx
src/components/landing/scroll-progress.tsx
src/components/landing/showcase-section.tsx
src/components/landing/story-section.tsx
src/components/ui/button.tsx
src/components/ui/confirm-dialog.tsx
src/components/ui/dropdown-menu.tsx
src/components/ui/input.tsx
src/components/ui/logo.tsx
src/components/ui/modal.tsx
src/components/ui/offline-banner.tsx
src/components/ui/scroll-area.tsx
src/hooks/use-board.ts
src/hooks/use-board/task-mutation-ledger.ts
src/hooks/use-board/use-column-operations.ts
src/hooks/use-board/use-task-operations.ts
src/hooks/use-board/utils.ts
src/hooks/use-click-outside.ts
src/hooks/use-column-swipe.ts
src/hooks/use-device.ts
src/hooks/use-hotkeys.ts
src/hooks/use-online-status.ts
src/lib/constants.ts
src/lib/db.ts
src/lib/db/boards.ts
src/lib/db/columns.ts
src/lib/db/errors.ts
src/lib/db/tasks.ts
src/lib/export.ts
src/lib/ratelimit.ts
src/lib/site.ts
src/lib/supabase/server.ts
src/lib/types.ts
src/lib/utils.ts
src/lib/validations.ts
tsconfig.json
vercel.json
```

## Revisión reproducible

Dos revisores independientes de solo lectura revisaron el HEAD de código `94fa29a97fd2e4aae50a358a7d68538ed3c03f8f` contra la base fija. Comandos capturados:

```sh
git diff d7ebc632a5df207afda34273f6850bce68b3f146...94fa29a97fd2e4aae50a358a7d68538ed3c03f8f
git log d7ebc632a5df207afda34273f6850bce68b3f146..94fa29a97fd2e4aae50a358a7d68538ed3c03f8f --oneline
```

Commits del diff: `6d0d874 feat(auth): add closed Google access (#4)`, `e644a7e docs: record issue #4 verification`, `94fa29a fix(auth): respect Supabase Realtime ownership (#4)`.

### Standards

El revisor detectó que la evidencia del HEAD de código todavía apuntaba a `6d0d874`; este informe y `docs/agents/implementation-run.md` se actualizan en el commit documental siguiente, resolviendo ese hallazgo de proceso. No se encontraron infracciones adicionales de estándares en código. Juicios no materiales de posible código duplicado: formularios de sign-out en dos componentes; encabezados privados compartidos entre callback y Proxy; guarda `relrowsecurity` repetida en migración y test para probar la salvaguarda; verificación `verifySession()` llamada tanto al hacerse visible la página como desde el intervalo.

### Spec

- **Realtime: correcto.** La migración no cambia el ownership de `realtime.messages`, verifica RLS prehabilitado y conserva las políticas ajenas al recrear solo las dos de OpenKanban. El revisor no encontró defecto de código ni scope creep.
- **Parcial — tableros legacy.** Los registros sin `owner_id` siguen inaccesibles hasta inventario y asignación explícitos, como exige D-07/C-98; no se asigna propietario por URL ni por primer login.
- **Evidencia pendiente — Auth real.** Claims/identidades SQL sintéticos y el rechazo del cliente público con `PrivateOnly` no prueban el login real de Google ni producción. P26 exige trazar reglas a escenarios/evidencia. El revisor señaló también que el informe anterior aún describía la evidencia Realtime como futura; esta versión registra los resultados de `94fa29a`.
- No se reporta otra implementación incorrecta.

## Handoff manual

1. En el entorno aislado de prueba, completar manualmente en navegador el selector/inicio de sesión de Google con la identidad elegida; no compartir credenciales ni volver a copiar la identidad a mensajes. La fila local ya está preparada como administrador pendiente; el flujo debe ligarla a la identidad Auth/Google y activarla. Esto no es admisión automática del primer visitante: la fila fue creada explícitamente antes del login.
2. Verificar en la DB aislada, sin imprimir datos personales, que se hayan vinculado el `auth.users.id` y el `provider_id` Google. La segunda identidad válida de prueba no tiene fila de acceso y debe quedar denegada. No habilitarla por correo ni ejecutar estos pasos en producción.
3. Verificar con una identidad habilitada, otra válida pero no habilitada y sin sesión: la primera llega a sus tableros; la segunda queda denegada; la tercera no lee ni crea datos. Probar logout/cambio de cuenta/suspensión y que el contenido desaparece al confirmar denegación; comprobar el aviso ante pérdida temporal de red.
4. La instancia local aislada ya tiene `private_only=true`; la lectura lo confirma y un cliente público recibió `PrivateOnly`. Mantener el setting durante la verificación de login.
5. Resolver por separado la asignación de tableros legacy mediante inventario autorizado y asignación explícita a su propietario. Hasta completar Auth real y los recorridos pendientes, el issue permanece abierto y `ready-for-human`.

Esta entrega es local en `codex/issue-4`; no se hizo push, merge ni operación en producción.
