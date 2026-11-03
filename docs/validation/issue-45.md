# Issue #45 — evidencia de recuperación tras importación

**Contrato:** P21/P24, C-92, CF-19.2/CF-19.3; DT05. Recuperar el reemplazo de una importación conserva el contenido relacionado y muestra qué se sustituirá, sin recuperar permisos ni avisos históricos.

**Base fija:** `0c5b83bc88fd9c2063b3f7706e6100ed8495dc69` (`codex/openkanban-1-0`).
**Código validado y revisado:** `bda249c009c9c9d79b4f815fcc03a070b050cf28`.
**Commits de implementación:** `ef3f314` (`#45: restaurar reemplazos de importación`) y `bda249c` (`#45: ocultar avisos históricos al restaurar`).
**Rama:** `codex/issue-45`. Esta evidencia se agregó después de las revisiones y no cambia el código revisado.

El contrato pide republicar la generación retenida. La publicación es una activación lógica nueva y conserva el mismo `generation_id`, contenido e identidades relacionadas; no clona filas ni crea relaciones con otros IDs. El puntero, nombre y zona horaria se actualizan dentro de la misma transacción. Los datos previos de nombre/zona solo se restauran cuando la retención los capturó; filas legacy sin snapshot se presentan como no restaurables.

## Criterios de aceptación

| Criterio | Evidencia automática | Manual y límites |
| --- | --- | --- |
| Ventana de 7 días, propietario actual, preview de lo sustituido/capacidad y revisión ante una nueva versión | `tests/db/board_import_recovery.sql` comprueba lista owner-only, fechas, cabeceras, resumen de contenido/capacidad, rechazo al colaborador, conflicto tras cambiar la revisión y preview nuevo. También comprueba que una retención legacy sin cabecera sea explícitamente `metadata_unavailable`. `tests/unit/board-import-contract.test.mjs` cubre endpoints y contrato de UI. | No se hizo recorrido autenticado en navegador ni validación visual en móvil/escritorio. |
| Publicar el contenido retenido sin recuperar accesos ni avisos históricos | PostgreSQL comprueba que cambien el puntero y las cabeceras, se active la generación retenida y se conserve su contenido, asociaciones, calendario, actividad y adjunto sintético. Owner y membresías siguen siendo los actuales. Un aviso previo conserva exactamente su fila y destinatario; queda oculto en listado y sus APIs de destino/marcado individual/en lote lo rechazan, incluido replay. Un aviso nuevo con el epoch actual sí aparece. La tabla/función de epochs no concede acceso a `authenticated`. | Los avisos se verificaron con el inbox y RPCs en PostgreSQL aislado; no se probaron clientes conectados o entrega externa de notificaciones. |
| Conservar también lo sustituido bajo retención/cuota y no purgar respaldos anteriores | La prueba crea reemplazos sucesivos, confirma que cada generación anterior conserva su ventana, fuerza una cuota insuficiente y verifica que no haya publicación parcial ni purga anticipada. El preview presenta bytes usados/límite y capacidad disponible. | Las cantidades y respuestas de Storage son sintéticas; no representan cupo o comportamiento de un proveedor físico. |
| Expiración, trabajos obsoletos y carrera restore-purge sin mezclar generaciones | SQL verifica preview vencido, objetivo expirado o `cleanup_pending`, operación vieja, y que el cleanup no elimine una generación activa. `scripts/test-db-issue-45-race.sh` fuerza la carrera con dos sesiones: restore conserva el lock del tablero, cleanup respeta `SKIP LOCKED` y no purga el target. | Se verificó la función SQL de limpieza; no la periodicidad ni ejecución del cron alojado. |
| Evidencia reproducible por criterio; español, permisos, accesibilidad y estados de error | Este registro diferencia automatización de validación manual. Las pruebas comprueban propietario, conflicto, expiración, cuota, errores y copy de interfaz en español; el diálogo usa etiquetas/live region y el focus trap existente. | Foco, teclado, lector de pantalla, contraste, movimiento reducido y teclado móvil requieren QA manual pendiente. |
| Mantener C-01–112 y P/E sin ampliar alcance ni declarar gates externos | No se incorpora restauración ordinaria ni edición de alcance. La prueba no reactiva membresías ni avisos. Las revisiones Spec y Standards/Privacy se ejecutaron sobre el SHA de código indicado abajo. | #45 continúa abierto y `Blocked by #44`; no se marca aceptación humana. |

## Verificaciones reproducibles

Entorno: Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, PostgreSQL `16.15`. Los scripts crean una instancia PostgreSQL descartable y no consumen `DATABASE_URL`, `PGHOST` o `.env.local`. El fixture sintético usa al propietario `a4400000-0000-4000-8000-000000000001` (`issue44-owner@example.test`) y al colaborador `a4400000-0000-4000-8000-000000000002`; parte de «Destino previo»/`UTC`, publica «Respaldo completo»/`America/Argentina/Buenos_Aires` y luego prueba otra importación, cambios posteriores y recuperación. Generaciones, membresías, avisos y objetos son sintéticos.

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-45` | PASS. Migraciones y recuperación sobre PostgreSQL descartable; incluye la carrera restore/cleanup de dos sesiones. Los objetos son ACKs de base simulados, no Storage físico. |
| `pnpm test:unit:issue-45` | PASS, 6 pruebas de contrato para API/UI y ruta de recuperación. |
| `pnpm test:unit` | PASS, suite unitaria completa. Node informa advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` en módulos existentes. |
| `pnpm exec next typegen` | PASS. |
| `pnpm typecheck` | PASS (`tsc --noEmit`). |
| `pnpm build` | PASS con Next.js `16.4.2`; aparecen las rutas de lista/preview y confirmación de recuperación. |
| Biome dirigido a `package.json`, `tests/unit/board-import-contract.test.mjs`, `src/components/board/board-import-dialog.tsx`, ambas rutas `src/app/api/boards/[slug]/import/recoveries/`, y `src/app/api/cron/task-attachment-cleanup/route.ts` | PASS, sin cambios pendientes. Los SQL/shell no son archivos compatibles con Biome. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-45.sh scripts/test-db-issue-45-race.sh` | PASS. |
| `git diff --check` | PASS; sin errores de whitespace. Git avisa de su normalización usual LF/CRLF en SQL. |
| `pnpm test:db` | Ejecutado después del código final; se detiene en la regresión ya conocida de #27, `tests/db/repetition_series_history.sql:169`: `First history page omitted continuation`, respuesta `has_more=false` con una ocurrencia `current`. No se modificó #27; el fallo aparece antes de ejecutar la suite #45. |

## Revisiones del código

Ambas revisiones fueron read-only y cubrieron `0c5b83b...bda249c`:

- **Spec:** encontró que faltaba el registro de evidencia exigido por el criterio 5. Este documento lo completa. No encontró scope creep ni otros incumplimientos en el SHA revisado. La revisión también confirmó que republicar el ID retenido concuerda con el AC2 y DT05; “nueva” se refiere a la activación lógica, no a clonar las entidades.
- **Standards/Privacy:** no encontró incumplimientos documentados ni hallazgos firmes de privacidad/autorización. Verificó epochs privados, owner/membresía actuales, filas de avisos antiguas ocultas e intactas y aviso actual visible. Observó como juicio de mantenibilidad una posible duplicación menor del helper JSON/validación UUID en los endpoints.

## Gates y límites pendientes

- **#44 sigue OPEN/`ready-for-human`** con E2E parcial y gates Storage/G04, G06, navegador y cron pendientes. El edge `Blocked by #44` permanece intacto.
- **Storage físico y G04:** no se usó ni aprobó un proveedor remoto; faltan ACK, fallos, lectura/purga y reconciliación físicos.
- **G06:** faltan mediciones de tamaño de tablero/paquete, memoria, CPU y tiempo con el recorrido completo.
- **Navegador/aceptación humana:** no se probó Auth real, foco, teclado, lector de pantalla o recorrido responsive.
- **Cron externo:** el RPC de limpieza y la concurrencia se probaron localmente; no la configuración/cadencia del scheduler alojado.

No se usaron cuentas, secretos/OAuth, datos reales, SQL/Storage remoto, `main`, producción ni deploy. #45 no se cierra; el tracker/checkpoint quedan a cargo del coordinador.
