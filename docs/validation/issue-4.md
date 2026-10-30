# Issue #4 — evidencia de implementación y revisión

Fecha: 30/10/2026. Issue: «Entrar con Google a una aplicación cerrada». Rama local: `codex/issue-4`. Base fija de revisión: `d7ebc632a5df207afda34273f6850bce68b3f146`. Código revisado: `6d0d8748e39016cd9152c5e584ef62513e18635d` (`feat(auth): add closed Google access (#4)`). El commit de este informe se agrega después del código revisado y no cambia su alcance.

No se guardaron correos, secretos ni datos reales de las cuentas de prueba.

## Alcance implementado

- Inicio de sesión Google por OAuth/PKCE, callback de retorno interno, controles de Auth y admisión en servidor/proxy/RPC, pantallas de acceso y administración.
- Admisión explícita ligada a la identidad Auth y al `sub` estable del proveedor; bootstrap administrador solo por fixture, nunca por ser el primer visitante.
- Lectura, escritura y Realtime privados por identidad/propiedad de tablero; sin sesión, sin habilitación, suspensión, URL conocida o permisos alternativos no conceden acceso.
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
| Auth real de Supabase y login Google en navegador | Pendiente de interacción manual; las pruebas SQL definen tablas/funciones Auth simuladas y no acreditan esta integración. El `302` del proveedor a `accounts.google.com` tampoco la acredita. |

### Lint global

`pnpm lint --reporter=json` falla con 60 diagnósticos de categoría `format` en 60 archivos sin cambios; `warnings=0`. Los 24 archivos del diff pasan el check dirigido y ninguno aparece en este conjunto. No se reformatearon archivos ajenos.

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

Revisores de solo lectura sobre el commit de código `6d0d8748e39016cd9152c5e584ef62513e18635d`, contra la base fija. Comandos capturados:

```sh
git diff d7ebc632a5df207afda34273f6850bce68b3f146...6d0d8748e39016cd9152c5e584ef62513e18635d
git log d7ebc632a5df207afda34273f6850bce68b3f146..6d0d8748e39016cd9152c5e584ef62513e18635d --oneline
```

### Standards

Sin infracciones de estándares documentados. Heurísticas posibles de código duplicado: `src/components/auth/sign-out-button.tsx` y `board-sign-out-button.tsx` repiten el formulario y botón de cierre de sesión, con diferencias justificadas de estilo y frontera Server/Client; `src/app/auth/callback/route.ts` y `src/proxy.ts` aplican encabezados privados similares, con necesidades distintas del Proxy. Ninguna es hallazgo material.

### Spec

- Resueltos: cambio de identidad aborta requests, limpia el workspace privado y descarta respuestas de épocas previas (DT-0.1 §9); un fallo transitorio conserva contenido con aviso y revalidar al volver al foco no lo oculta (Estados y errores §1, DT-0.1 §9); el documento declara `lang="es"` (P12).
- Parcial: la migración cierra tableros legacy sin propietario, pero su inventario y asignación explícita siguen pendientes por D-07/C-98; no hay apropiación por URL.
- Evidencia pendiente: inicio de sesión con Supabase Auth/Google real, identidad habilitada y otra no habilitada en navegador. Las fixtures sintéticas no cumplen este criterio.
- No se reporta scope creep ni implementación incorrecta adicional.

## Handoff manual

1. En el entorno aislado de prueba, completar en navegador el selector/inicio de sesión de Google con una identidad de prueba; no compartir sus credenciales ni correos.
2. Obtener el `auth.users.id` y el `provider_id` Google de esa identidad desde el entorno aislado y usar una fixture autorizada para habilitarla explícitamente y, por separado, mapear una identidad administradora. No habilitar por correo, no usar primer login y no ejecutar este paso en producción.
3. Verificar con una identidad habilitada, otra válida pero no habilitada y sin sesión: la primera llega a sus tableros; la segunda queda denegada; la tercera no lee ni crea datos. Probar logout/cambio de cuenta/suspensión y que el contenido desaparece al confirmar denegación; comprobar el aviso ante pérdida temporal de red.
4. Confirmar en Realtime de la instancia aislada que «Allow public access to channels» está desactivado y que los topics privados siguen aislados.
5. Resolver por separado la asignación de tableros legacy mediante inventario autorizado y asignación explícita a su propietario. Hasta entonces el issue permanece abierto y `ready-for-human`.

Esta entrega es local en `codex/issue-4`; no se hizo push, merge ni operación en producción.
