# Evidencia de implementación — issue #37

Fecha de validación: 2026-11-02

Rama: `codex/issue-37`

Base fija: `b01dd0ba51399a460283b04b81faab97cf5596ab`

Entorno: Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Windows con Bash para los runners DB.

El runner `scripts/test-db.sh` crea un clúster PostgreSQL local nuevo bajo `/tmp/openkanban-db.*`, no consume `DATABASE_URL` ni `PGHOST`, y elimina únicamente ese directorio temporal al terminar. Las fixtures usan actores, identidades, comentarios, tableros y fechas sintéticos. `psql --version` no está disponible en la sesión PowerShell del host; por eso no se declara una versión de PostgreSQL independiente del runner.

## Evidencia por criterio

| Criterio de #37 | Evidencia reproducible | Estado |
| --- | --- | --- |
| Eventos/destinatarios aprobados, deduplicación por destinatario, sin autoavisos ni avisos por pasos, movimientos o repetición automática | `tests/db/task_notifications.sql`: asignación y actor excluido, cambio de vencimiento, comentario/mención, edición que añade una mención, quitar/reponer sin volver a avisar, ocurrencia creada por el worker, edición de checklist y movimiento. | Automático; runner focal y suite completa pasan. |
| Atribución de creador original y creador elegible de serie; persona retirada no se sustituye por el dueño | Fixture sintética con retiro del creador y comentario posterior; compara los destinatarios sin asignar la autoría al dueño. | Automático; runner focal y suite completa pasan. |
| Lectura con permisos actuales al listar, resolver destino y marcar; destino genérico cuando ya no está disponible; ancla precisa de comentario | RPCs de lista, destino y lectura comprueban membresía, identidad habilitada y generación vigente. La prueba de destino exacto verifica `task` + `comment` + ancla. Una tarea borrada no revela título ni permite abrirse, pero su aviso genérico puede marcarse leído mientras el tablero sigue autorizado. Una nueva membresía no recupera avisos de la época revocada. | Automático; runner focal y suite completa pasan. |
| Paginación y estado leído/no leído | Pruebas de filtro, cursor estable sin repetición y conteo no leído bajo autorización de generación actual. | Automático; runner focal y suite completa pasan. |
| 90 días por aviso, incluidos leídos/no leídos; fallos reintentables sin borrar tareas/comentarios | Fixture con reloj sintético al límite, fallo de entrega inyectado y reintento durable. Purga elimina los avisos vencidos, conserva tarea/comentario y purga el aviso dependiente junto a una tarea purgada. | Automático; runner focal y suite completa pasan. |
| Recorrido en español y estados de error | `/notifications`, enlace desde inicio, filtros «Todas»/«Sin leer», actualización, paginación, apertura validada y opción individual «Marcar como leída». Los tests unitarios cubren destino inaccesible, ocultación preventiva de títulos cacheados durante una revalidación y la actualización del filtro después de marcar leído. | Build y pruebas unitarias pasan; aceptación visual y accesible sigue pendiente. |

## TDD y resultados

El tracer inicial falló antes de contar con el contrato de lectura; se añadió el almacenamiento duradero, los productores y las RPC hasta llevarlo a verde. Los ciclos posteriores añadieron casos rojos para edición de menciones, reintento tras caída, autorización por generación, no emisión por trabajo automático y duplicación del listado al haber varias columnas. El último fallo detectado fue una duplicación causada por unir todas las columnas del tablero antes de acotar la tarea; el listado ahora une la columna de la tarea y la regresión queda en la fixture.

Verificaciones finales del árbol con los cambios actuales:

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-37` | Exit 0; fixture #37 sobre clúster descartable. |
| `pnpm test:db` | Exit 0; suite DB completa, incluida migración 062 y fixture #37. |
| `pnpm test:unit:issue-37` | Exit 0; 9/9 tests. |
| `pnpm test:unit` | Exit 0; agregado unitario completo, incluidos focos #33–#37. |
| `pnpm exec next typegen && pnpm typecheck` | Exit 0. |
| `pnpm build` | Exit 0; Next.js 16.4.2 genera la ruta dinámica `/notifications`. |
| `pnpm exec biome check --line-ending=crlf package.json src/app/page.tsx src/app/notifications/page.tsx src/components/notifications/task-notifications-inbox.tsx src/lib/db/task-notifications.ts src/lib/task-notification-state.ts src/lib/unified-search-navigation.ts tests/unit/task-notification-state.test.mjs` | Exit 0; formato y lint focales limpios tras formatear la regresión unitaria. |
| `pnpm exec biome check --formatter-enabled=false` | Exit 0; 262 archivos revisados. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-37.sh` | Exit 0. |
| `git diff --check` | Exit 0. |

Las pruebas unitarias emiten la advertencia de Node `MODULE_TYPELESS_PACKAGE_JSON` para archivos TypeScript con sintaxis ESM; no falla ningún test. La búsqueda de `psql --version` desde PowerShell no encontró el ejecutable, pero los runners Bash DB completaron usando su `pg_config --bindir` local y el clúster temporal descrito arriba.

## Gates que siguen pendientes

- No se completó recorrido manual en navegador con Auth/host; no se usaron OAuth, cuentas ni datos reales.
- Quedan aceptación visual, teclado, lector de pantalla y tamaños móviles. El build y las pruebas de contrato no se reportan como QA manual.
- No se verificó un cron/worker desplegado. La fixture verifica procesamiento separado, idempotente y reintentable en PostgreSQL local.
- La acción de lectura implementada en #37 es individual, como expresa AC3. El marcado por lote de C-99/E07 pertenece al issue #38, que está bloqueado por #37; no se adelanta en esta candidata.
- Se conservan las aristas `Blocked by #13/#16/#23`; ninguna dependencia ni aceptación humana se marca cumplida. El issue debe seguir abierto mientras queden gates humanos.
- Revisión dual Spec/Standards realizada sobre `670dece86d889a3fc73896382d265a0aea3490f9` (`8ea69504ce149c6aac86443616768e12431cdc45`): sin hallazgos; los gates manuales anteriores siguen pendientes.
