# Issue #47 — actualizar sin perder una edición

**Fecha:** 2026-11-03. **Rama:** `codex/issue-47`. **Base fija:** `caf16e96f1f962226f3bbeffe5c5bb8c8d231e88`.

La evidencia automática usa Node `v24.14.1`, pnpm `11.25.0` y Next.js `16.4.2`. El contrato sigue C109-AC46, E06 y CF-26.1; la PWA continúa siendo una mejora opcional para web e instalación. El ticket permanece `OPEN` y `Blocked by #46`. No se usaron cuentas, cookies, tokens, datos privados, despliegue ni dispositivos reales.

## Resultado por criterio

| Criterio | Evidencia automática | Estado y límites |
| --- | --- | --- |
| Avisar que hay una versión nueva y esperar una decisión explícita. | `PwaProvider` busca actualizaciones al abrir, al volver online y al hacer visible la pestaña. Muestra «Hay una actualización disponible» y «Recargar para actualizar» cuando hay un worker esperando y la página ya está controlada. Solo el botón elegido por la persona puede enviar `ACTIVATE_UPDATE`; `controllerchange` recarga si ese mismo tab inició la actualización. `tests/unit/pwa-update-ui-contract.test.mjs` verifica el contrato del componente y `tests/unit/pwa-service-worker.test.mjs` ejecuta el worker con eventos sintéticos. | Cubierto en código y pruebas sintéticas. No se verificó el ciclo de actualización en un navegador real. |
| Preservar el editor abierto con Guardar, Descartar o Seguir editando. | `TaskModal` registra un guard mientras está abierto y consulta sus propios estados de edición y etiquetas; el provider no almacena borradores. El guardado solo libera la activación cuando la operación se confirma. Descartar resuelve explícitamente el borrador y Seguir editando cancela la activación pendiente. Si el guardado no responde, falla o entra en conflicto, no se manda `ACTIVATE_UPDATE`, el diálogo queda y el foco se restaura al botón Save o, si el conflicto lo deshabilita, a «Seguir editando». | El helper y el contrato fuente cubren las decisiones. La restauración de foco se comprueba estructuralmente; faltan teclado y lector de pantalla reales. Un guardado sin respuesta queda esperando la respuesta, sin activar la actualización. |
| Descargar e instalar una actualización con interrupción de red sin perder la versión actual. | El worker nuevo precarga únicamente `/offline.v1.html` y los iconos versionados. El fixture modela el cache público `v1` como activo, hace fallar `addAll` del candidato `v2`, comprueba que solo se borra el cache público candidato y luego verifica que el worker vigente sigue sirviendo su fallback offline. El escenario se repite bajo los modos sintéticos `web` e `installed`. La prueba adicional verifica instalación completa y activación solo tras el mensaje explícito. | PASS en fixture sintético Node. Los dos modos ejecutan el mismo modelo del worker; no son pruebas separadas de navegador instalado/web ni prueban un dispositivo. |
| Eliminar caché pública antigua sin tocar Auth ni guardar contenido privado. | En `activate`, el worker elimina solo nombres anteriores con prefijo `openkanban-public-`; la prueba conserva `auth-session-cache` y un cache ajeno. Solo se precargan recursos estáticos públicos. Las rutas privadas y `/auth/callback` se solicitan a la red; las APIs/POST no se interceptan y no hay escrituras de respuestas privadas en CacheStorage. | PASS en fixture sintético. No se inspeccionó CacheStorage de un navegador real. |
| Conservar retorno de login, logout y cambio de cuenta. | Los tests existentes de proxy verifican que `next` conserva su destino y que `/login`, `/account`, `/api` y `/auth/callback` mantienen sus gates. El fixture pide la misma ruta privada con dos identidades sintéticas, confirma respuestas de red distintas y ninguna reutilización/escritura de contenido privado. | No cambió login, proxy, Auth ni cookies. No se usaron sesiones, logout, OAuth o cuentas reales. |
| Registrar evidencia por criterio y los gates pendientes. | Este documento identifica versión, comandos, escenarios sintéticos y límites. | Manual pendiente: navegador web y PWA instalada, red que se corta durante comprobación/descarga, guardado real con respuesta lenta o fallida, recarga elegida, CacheStorage, teclado, lector de pantalla y matriz de dispositivos. No se afirma prueba real. |

## Verificaciones reproducibles

La prueba del worker ejecuta `public/sw.js` con `node:vm`, CacheStorage, origen, red, respuestas y cuentas sintéticas. La prueba de UI es un contrato estático con el patrón de pruebas UI ya usado en el repositorio; no renderiza React ni simula un navegador. No se modificaron migraciones, RPC ni almacenamiento persistente.

| Comando | Resultado |
| --- | --- |
| Rojo TDD: `pnpm test:unit:issue-47` antes de completar el worker/guard | Los casos nuevos fallaron por ausencia de versionado/activación explícita/limpieza de instalación fallida; el contrato de UI falló al faltar la restauración de foco. |
| `pnpm test:unit:issue-47` | PASS, 16 pruebas: worker/caché, guard, falta de respuesta de Save, decisiones y contrato UI. |
| Pruebas focales de editor y borrador | PASS; también forman parte de `pnpm test:unit`. Incluyen `task-edit-focus`, `task-edit-workflow` y `task-draft-preservation`. |
| `pnpm test:unit` | PASS, suite completa, exit code 0; incluye #47. Node muestra advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` de módulos `.ts` existentes. |
| `pnpm exec next typegen` | PASS. |
| `pnpm typecheck` | PASS (`tsc --noEmit`). |
| `pnpm build` | PASS con Next.js `16.4.2`. |
| Biome dirigido a `public/sw.js`, Provider, TaskModal, helper, pruebas focales y `package.json`, con `--formatter-enabled=false` | PASS, sin fixes. |
| `git diff --check` | PASS. |
| `bash -n` para todos los scripts `.sh` existentes | PASS. No se modificaron scripts shell. |
| Validación DB focal | N/A: no hay SQL, RPC ni datos persistentes en este cambio. |

Las pruebas sintéticas confirman que el worker vigente sigue disponible después de que una precarga candidata falla; no ejercitan el navegador ni la UI instalada. El loop manual de G07 y la matriz real de E06 siguen pendientes. No se amplió #46 ni se alteró Auth real.
