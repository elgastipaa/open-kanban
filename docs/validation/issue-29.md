# Issue #29 — evidencia de validación

## Entorno y alcance

- Worktree `C:\Users\gasto\.codex\worktrees\openkanban-issue-29\open-kanban`, rama `codex/issue-29`, base fija `2d988b68642c96379a927fc5bf68a368e785150f`.
- Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0`, PostgreSQL `16.15`.
- Los runners DB crean un PostgreSQL local descartable, aplican las migraciones `001–047`, usan cuentas/tableros/fechas sintéticos y eliminan la instancia al terminar. No consumen datos de producción.
- No se usaron OAuth, credenciales externas, SQL remoto ni deploy. No se alteraron los bloqueos de #25/#26 ni se cerró el issue.

## Criterios y evidencia

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| El cumpleaños es una fecha anual, no una tarea que se completa | `board_birthdays` guarda nombre, mes/día y anticipación en una entidad separada. Las respuestas RPC no contienen `assignee_id` ni `is_completed`; `get_my_tasks_p('due')` no incluye cumpleaños. | Automatizado en PostgreSQL descartable; recorrido visual pendiente |
| La próxima fecha se resuelve cada vez con el día local del tablero; 29 de febrero cae el 28 en año no bisiesto | `birthday_date_for_year_p` conserva el 29 como regla nominal. Las consultas calculan `next_on` desde el reloj actual y la zona IANA del tablero; pruebas cubren Buenos Aires, New York y el salto DST de marzo de 2026. | Automatizado en PostgreSQL descartable |
| La visibilidad es anual e inclusiva: sin anticipación todo el año; con X días, D−X a D inclusive; máximo 366 días | `tests/db/birthdays.sql` verifica el día anterior a la ventana, ambos extremos inclusivos, el día posterior, el límite 366 aceptado y 367 rechazado por almacenamiento y RPC create/update. Comprueba que delete/restore conserva los 366 días. El control e input de UI también limitan a 366. | PostgreSQL descartable y contrato unitario de UI |
| Una fecha fuera de ventana sigue accesible en Series y no se mueve automáticamente | La RPC de tablero filtra la ventana y `list_my_birthdays_p` devuelve todas las fechas activas accesibles, con `visible` y zona. El panel separado aparece en tablero y Series; las fechas/anuncios se calculan al consultar. | Automatizado en PostgreSQL; browser Auth pendiente |
| Cambiar la zona del tablero vuelve a resolver la lista anual | `BirthdayPanel` depende de `boardTimeZone` en el callback `refresh`; el efecto existente depende de ese callback. `tests/unit/birthday-panel-contract.test.mjs` verifica ambas conexiones. | Contrato unitario de UI; recorrido manual de cambio de zona pendiente |
| Miembros actuales administran; no miembros y lecturas directas quedan denegados | El foco verifica CRUD/restore con miembro colaborador, respuestas genéricas `unavailable` para usuario ajeno con slug/ID conocido, y ACL que impide leer tablas privadas directamente. | Automatizado con actores sintéticos; sesión Auth real pendiente |
| Edición comprueba versión; eliminación se puede recuperar durante siete períodos de 24 horas | La prueba verifica versión obsoleta/conflicto, borrado, lista de recuperables, restore y cierre exactamente a las 168 horas incluso cruzando DST. | Automatizado en PostgreSQL descartable |
| La purga no conserva snapshots después del plazo ni cuando el tablero se purga definitivamente | La purga de cumpleaños limpia el snapshot al vencimiento exacto. `birthday_deletions.board_id` tiene `ON DELETE CASCADE`; el caso de regresión borra/purga un tablero por el batch `service_role` y comprueba que no queden snapshot ni recibos de creación. | Rojo→verde en PostgreSQL descartable |
| Una creación reintentada no duplica cumpleaños ni acepta el mismo key para otro contenido | El receipt guarda actor, tablero, generación, ID y hash del payload, nunca un snapshot. Repetir actor/key/payload retorna el mismo ID; payload distinto produce `23514`; al vencer el receipt responde `expired_unknown` sin crear otra fila. | Rojo→verde y vencimiento controlado en PostgreSQL descartable |
| Copia de texto de cumpleaños no se incorpora a tareas, pendientes ni checklist | Solo hay RPC de cumpleaños y panel anual; no se modificaron los contratos de captura de tareas, checklist ni Mis tareas. La regresión consulta Mis tareas y ACL. | Automatizado en DB; browser Auth pendiente |
| Textos en español, controles sin checkbox, alta secundaria y detalle/edición/borrado en Series | El panel React provee alta junto a la vista de tablero, formato español, campos de mes/día/anticipación, detalle/edición y confirmación de borrado; Series muestra fechas fuera de ventana y recuperación. | Revisión estática/build; teclado, lector de pantalla, foco y revisión responsive pendientes de aceptación humana |

La primera prueba de retry falló al devolver dos IDs para el mismo operation ID. La primera prueba de purge de tablero terminó con el snapshot de cumpleaños aún recuperable. La receipt con payload hash/actor/board/generation y la FK de borrado cambiaron esos casos a verde. La prueba nueva de max advance falló primero insertando 367 días; tras agregar el constraint de almacenamiento, el RPC también falló por exponer el `23514` del constraint en vez de validar como `22023`. La validación explícita de create/update y UI quedó verde en 367 rechazado y 366 aceptado. La UI bloquea el mismo alta si recibe `expired_unknown` y dirige a revisar Cumpleaños en Series antes de iniciar otra alta; no se creó un seam de UI adicional porque el flujo aprobado no disponía de uno aislado sin Auth.

## Exportación e importación diferidas

No se modificó el JSON v1 de legado ni se afirma que el export actual incluya cumpleaños. El alcance permanece en #29: #42 «Exportar un tablero completo» depende de #29 y #43 «Importar un respaldo v1 seguro» depende de #42. Se implementarán en esos tickets con el paquete completo que especifica CF-19.2, sin agregar soporte parcial/inseguro al formato existente.

## Ejecuciones reproducibles

Comandos desde la raíz del worktree:

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-29` | Exit `0`; migration set `001–047` y pruebas enfocadas de fecha, visibilidad, membresía, ACL, receipts, borrado/restore y purge de tablero en PostgreSQL descartable. |
| `pnpm test:db` | Exit `0`; regresión DB completa `001–047`, incluidos los fixtures de concurrencia de tickets previos. |
| `pnpm test:unit` | Exit `0`; `188/188`, incluidos los dos contratos de UI para el límite de anticipación y refresco por zona. Node emite advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` de módulos existentes. |
| `pnpm exec next typegen` | Exit `0`; tipos de rutas generados con Next `16.4.2`. No agregó archivos rastreados fuera del cambio. |
| `pnpm typecheck` | Exit `0`; `tsc --noEmit`, después de `next typegen`. |
| `pnpm build` | Exit `0`; Next `16.4.2` compila el panel y la ruta dinámica `/series`. |
| `pnpm exec biome check --line-ending=crlf package.json scripts/test-db.sh scripts/test-db-issue-29.sh src/app/series/page.tsx src/components/board/board.tsx src/components/birthdays/birthday-panel.tsx src/lib/db/birthdays.ts tests/unit/birthday-panel-contract.test.mjs` | Exit `0`; archivos de código/configuración del ticket, incluido el nuevo contrato unitario, sin diagnósticos. |
| `pnpm exec biome check --formatter-enabled=false` | Exit `0`; chequeo global de los 211 archivos. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-29.sh` | Exit `0`. |
| `git diff --check` | Exit `0`; sin errores de whitespace. |

## Pendientes humanos

- Recorrido manual en browser autenticado: crear/editar cumpleaños, verificar aparición de tablero y consulta fuera de ventana en Series, confirmar fecha real en distintos husos y completar borrado/recuperación. No se usó bypass de Auth.
- Aceptación manual de teclado, lector de pantalla, anuncios de estado, foco y presentación responsive/móvil. Build y pruebas DB no sustituyen ese recorrido.
- No se probó scheduler/host para invocar el batch de purga ni ninguna base/instancia de producción.
- #25 y #26 permanecen abiertos como dependencias bloqueantes; #29 queda pendiente de revisión independiente Spec/Standards sobre el árbol final.
