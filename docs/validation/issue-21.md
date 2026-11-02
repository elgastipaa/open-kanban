# Validación del issue #21 — Marcar tableros favoritos

## Alcance y estado

Base de trabajo y comparación: `5f6dec53c1aba0d3d3f5b3e42a05acadfb0cf8f7` en `codex/openkanban-1-0`. Implementación en `codex/issue-21`; commit funcional inicial `d6668ab6776f15ffc5c12ad7de8cae4ffbf16f8d`. Contrato: P13/P16, CF-21 y los criterios del issue #21. La relación `Blocked by #6` se conserva.

La UI añade una estrella por tablero y una sección personal «Favoritos» dentro de la lista «Tus tableros». La lectura de favoritos vuelve a comprobar la membresía vigente en cada petición y no concede permisos. Los estados de error no muestran nombres de tableros revocados. La preferencia se guarda por cuenta y tablero; no se agregan carpetas ni entrada global.

## Matriz de aceptación y evidencia

| Criterio | Evidencia reproducible | Resultado y límites |
| --- | --- | --- |
| Favorito propio sincronizado entre dispositivos dentro de Tableros, sin carpetas ni entrada global adicional. | `tests/db/board_favorites.sql` establece preferencias por actor en PostgreSQL y las vuelve a consultar en transacciones posteriores; `tests/unit/board-favorites-state.test.mjs` comprueba agrupación en «Favoritos» y «Otros tableros». | PASS para persistencia por usuario en la base y agrupación de UI. Pendiente comprobar en dos sesiones/dispositivos reales que el cambio aparece al refrescar; no se simuló sincronización visual autenticada. |
| Revocar acceso retira nombre/destino; la preferencia de otra persona no cambia. | La prueba SQL crea dos tableros y dos actores, revoca al colaborador de uno y verifica `list_my_boards`, `list_my_board_favorites_p`, el rechazo de mutaciones posteriores y la preferencia intacta del otro actor. | PASS en el contrato de base: el tablero revocado desaparece de la lectura del colaborador y la preferencia independiente del propietario permanece. La prueba no abre el recorrido visual autenticado. |
| Operación idempotente y errores claros; favorito no es caché permanente de permiso. | El RPC usa estado deseado `true/false`, sin operación toggle; la suite SQL repite solicitudes de alta/baja, intenta IDs ajenos y comprueba ausencia de ACL directa a la tabla. Las pruebas unitarias verifican reintentos y mensajes genéricos. | PASS automático para idempotencia, autorización actual y aislamiento. Mensaje/UI y actualización posterior a una revocación requieren aceptación visual manual. |
| Evidencia reproducible con entorno, actores y límites; textos en español y estados de error/accesibilidad del recorrido. | Suite automatizada, versiones, comandos y límites se listan debajo. Los controles tienen nombre accesible, `aria-pressed`, estado ocupado, conservan/restauran el foco al moverse entre secciones solo si la persona no lo trasladó a otro control, foco visible, errores `role="alert"` y «Reintentar». | PASS estático/automático para el modelo de estado y compilación. Pendiente teclado, lector de pantalla, responsive real, mensajes visuales y recorrido autenticado. |
| Preservar C-01–112 y P/E sin ampliar alcance. | Diff contra la base y revisión del contrato P13/P16/CF-21; migración aditiva y cambios limitados a favoritos. P11 y su enlace a tareas quedan fuera. | Sin ampliación intencional. El resultado de la revisión final Spec/Standards se registrará en el comentario de entrega. |

## Entorno y resultados

- Worktree aislado `C:\Users\gasto\.codex\worktrees\openkanban-issue-21\open-kanban`, rama `codex/issue-21`; no se leyó `.env.local` ni se conectó un proyecto remoto.
- Node.js `v24.14.1`, pnpm `11.3.0`, Next.js `16.4.2`, PostgreSQL `16.15`.
- `corepack pnpm test:db` — PASS; clúster PostgreSQL local descartable de `scripts/test-db.sh`, creado bajo `/tmp`, sin `DATABASE_URL`/`PGHOST`; migraciones 001–038 y pruebas de regresión/concurrencia completas. El fixture nuevo usa UUIDs sintéticos y cuentas `@example.test`; no usa sesiones Google.
- `corepack pnpm test:unit` — PASS; 155 pruebas, 0 fallidas.
- `corepack pnpm exec next typegen` — PASS.
- `corepack pnpm typecheck` — PASS.
- `corepack pnpm build --webpack` — PASS con Next.js 16.4.2; variables sintéticas solo de build apuntando a `127.0.0.1`, no usadas para acceder a servicios.
- `corepack pnpm build` — FAIL del Turbopack predeterminado en este checkout: 53 errores `Module not found` en paquetes ya declarados (`@base-ui/react/*`, `@tabler/icons-react`, `@upstash/*`). El mismo árbol compila con Webpack; no se cambió configuración o lockfile para ocultar el problema.
- Biome focalizado — PASS: `crlf` para `src/app/page.tsx` y `src/components/board/board-favorites-list.tsx`; `lf` para los dos módulos nuevos y el test unitario, respetando finales de línea del checkout. `bash -n scripts/test-db.sh` y `git diff --check` — PASS.

## Aceptación humana y fronteras

- **Pendiente:** iniciar sesión por el flujo normal y comprobar la marca/desmarca visual, persistencia al cambiar de dispositivo, navegación solo desde «Favoritos», estados de carga/error y revocación efectiva en la interfaz con dos usuarios. También comprobar tamaño móvil/escritorio, teclado y lector de pantalla.
- **No ejecutado:** OAuth real, bypass/inyección de autenticación, navegador con sesión del usuario, DB remota, despliegue, SQL de producción o cambios a `main`.
- El issue #21 y su blocker #6 permanecen abiertos hasta la aceptación humana aplicable. La evidencia automatizada no sustituye esos recorridos.
