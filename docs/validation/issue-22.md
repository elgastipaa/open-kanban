# Validación del issue #22 — Elegir tema claro, oscuro o Sistema

## Alcance y estado

Base fija: `bfb70e0964693a8e8739b07a4ca77968dd07e63b`. Rama: `codex/issue-22`. Commit de implementación: `17a64d4` (`feat: add account-synced theme preferences (#22)`). Contratos: E03/P08, C-104/CF-23, UI-16/UI-PL09, G-12 y ERR-PL11.

La preferencia personal vive en **Cuenta**; se guarda por cuenta con versión optimista. Sistema es el valor inicial y lo resuelve el dispositivo. La raíz carga una preferencia solo después de confirmar identidad y acceso activo. Los estilos claros y oscuros usan tokens compartidos para superficies, texto, prioridad, éxito, conexión y foco; el fondo decorativo de la portada resuelve Sistema con `prefers-color-scheme`. El cambio local actualiza `data-theme` sin navegar ni recargar.

El issue #22 permanece **OPEN / `ready-for-human`** por la comprobación humana y de dispositivo pendientes. Conserva la dependencia nativa **Blocked by #4**. El issue #4 permanece **OPEN / `ready-for-human`**. Solo se actualizó la etiqueta de preparación de #22 para reflejar la aceptación pendiente; no se añadió comentario ni se cerró ningún issue.

## Criterios y evidencia

| Criterio | Evidencia reproducible | Resultado y límites |
| --- | --- | --- |
| Tema inicial Sistema; Claro/Oscuro sincronizados por cuenta; Sistema por dispositivo. | `src/app/layout.tsx` valida sesión y acceso activo antes de consultar `get_my_theme_preference_p`; el RPC devuelve Sistema/v0 si no hay fila. `tests/db/theme_preferences.sql` crea dos principales sintéticos y comprueba valores iniciales y aislamiento. `src/app/globals.css` resuelve Sistema con `prefers-color-scheme`. | PASS para carga/autorización y persistencia automática. La pantalla Cuenta y el inicio de sesión normal no se pudieron probar en navegador autenticado: el worktree no trae una configuración Supabase local. |
| Lecturas privadas solo después de autenticar y confirmar acceso a la aplicación. | Pruebas SQL para `anon`, cuenta sin admisión activa y privilegios directos; layout y acción de servidor llaman `auth.getUser()` y `resolveApplicationAccess()` antes del RPC. | PASS en la base aislada y revisión del orden de llamadas. No se usó bypass de autenticación. |
| Conflicto obsoleto: conservar local, mostrar el valor guardado y permitir cargarlo o revisar/conservar local. | `tests/db/theme_preferences.sql` prueba cambio concurrente, versión vieja, versión futura y que una versión no inicial no cree una preferencia. `tests/unit/theme-preference-state.test.mjs` cubre conservar local, cargar guardada y reintentar contra la versión revisada. | PASS automático para persistencia y máquina de estado. El diálogo de conflicto queda pendiente de revisión manual autenticada. |
| Combinar preferencias distintas sin pisarlas ni mezclar cuentas. | La fila se identifica por `(user_id, preference_key)` y el RPC escribe solo `theme`. La regresión SQL conserva `completed_visibility=false` y verifica dos cuentas independientes. | PASS automático en PostgreSQL local descartable. |
| Cambio visual sin recarga; editor, borrador y foco preservados. | `ThemePreferenceProvider` cambia `document.documentElement.dataset.theme` en un efecto de layout, sin `router`, `location` ni remount; el proveedor permanece en el layout raíz. La suite existente incluye `tests/unit/task-draft-preservation.test.mjs`; los tests nuevos verifican estados de sincronización separados del borrador. | PARCIAL: implementación y modelos automáticos verificados; el recorrido UI-PL09 con edición abierta no se pudo ejecutar con una sesión de navegador local válida. No se afirma preservación observada en navegador. |
| Contraste, foco, prioridades, errores y movimiento reducido en Claro/Oscuro. | Barrido de colores fijos en `src/app` y `src/components`; tokens adaptables en `src/app/globals.css`, foco visible global y regla `prefers-reduced-motion`. `ThemeAwareToaster` usa los mismos tokens. En navegador local, `/privacy` cargó bajo Sistema oscuro del dispositivo. | PASS estático para tokens y preferencias de movimiento; observación parcial de Sistema oscuro en una ruta pública. Falta inspección visual manual de Claro/Oscuro en pantallas privadas y dispositivos objetivo. |
| Error de guardado visible sin fingir sincronización y con reintento. | `tests/unit/theme-preference-state.test.mjs` comprueba que el fallo conserva la elección local, no cambia versión y expone un error español con acción Reintentar; la acción servidor traduce errores a resultado genérico. | PASS automático para el estado. Pendiente confirmar visualmente el error y el reintento autenticados. |
| Preferencia personal en Cuenta; sin tema por tablero, selector de colores ni idioma adicional. | `src/app/account/page.tsx` contiene el selector; Tableros, tablero, administración y Mis tareas enlazan a Cuenta. No hay configuración de tema en tablero ni selector de color/idioma. | PASS en la estructura implementada. Aceptación visual de Cuenta pendiente. |

## Entorno y ejecuciones

- Worktree: `C:\Users\gasto\.codex\worktrees\openkanban-issue-22\open-kanban`; base y rama indicadas arriba. Node.js `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, PostgreSQL `16.15`.
- `pnpm install --offline --frozen-lockfile` — PASS; dependencias del lockfile ya instaladas, `node_modules` ignorado por Git.
- TDD: la prueba SQL falló inicialmente porque faltaba `public.user_preferences`; después pasó con la migración `039`. La prueba unitaria falló inicialmente porque faltaba la máquina de estado; después pasaron sus casos de default, conflicto, error y cambio de cuenta.
- `pnpm exec next typegen` — PASS.
- `pnpm typecheck` — PASS.
- `pnpm test:unit` — PASS, 160 pruebas, 0 fallidas.
- `pnpm test:db` — PASS, suite completa de regresión en PostgreSQL descartable creado en `/tmp` por `scripts/test-db.sh`; aplica migraciones 001–039. El script elimina variables `PG*` pertinentes, no usa `DATABASE_URL`/`PGHOST` y enlaza el servidor solo a socket local. Los actores de la prueba nueva son UUIDs sintéticos y claims locales.
- `pnpm build --webpack` — PASS con Next.js 16.4.2; compilación, TypeScript, páginas y trazas terminadas.
- Biome focalizado en los archivos TS/TSX/CSS/MJS/JSON cambiados — PASS con `--line-ending=crlf`, que corresponde al checkout Windows. `git diff --check` — PASS.
- Se usó la base PostgreSQL desechable y el navegador local (`http://127.0.0.1:3100/privacy`) en modo Sistema oscuro. **No se usó reloj controlado**: la lógica de tema no depende del tiempo; `updated_at` es solo metadato.
- El navegador no pudo abrir la app autenticada: no existe `supabase/config.toml` en este worktree y la portada indicó que faltan URL/clave Supabase locales. No se fabricó sesión ni se intentó OAuth real. No se leyó `.env.local`.

## Aceptación humana y límites

- **Pendiente:** iniciar sesión por el flujo normal en entorno aprobado y revisar Cuenta, Claro/Oscuro/Sistema, conflicto entre dos sesiones, error/reintento y UI-PL09 con una tarea en edición; revisar contraste y foco por dispositivo, tamaño y lector de pantalla.
- **No ejecutado:** OAuth real, cuenta o datos reales, bypass de auth, proyecto SQL remoto, producción, despliegue, push, integración a `main` o cierre de issues.
- La evidencia automática no sustituye la aceptación visual/dispositivo. #22 y su dependencia #4 permanecen abiertos.
