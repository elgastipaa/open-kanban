# Issue #44 — evidencia de importación completa v2

**Contrato:** P24/P22; C-101/C-105/C-110–112; CF-19; G06. Trazabilidad P/E: P22, P24, E01, E05. El reemplazo importa el modelo portable completo, protege la generación activa y conserva calendario, relaciones, actividad válida y adjuntos bajo las reglas de cuota.

**Base fija de implementación/revisión:** `ba29e2a9d758fcf5ff9761dc4e66fd4e32c2756f` (`codex/openkanban-1-0`).
**Código validado:** `f424552a98ed1864cd119407629e0b76e98a4af5`.
**Rama:** `codex/issue-44`.
**Estado del tracker:** #44 sigue OPEN/`ready-for-agent`; conserva `Blocked by #43`. #43 sigue OPEN/`ready-for-human` con Storage/G04, navegador/aceptación y cron pendientes. Esta evidencia sintética no cambia estados ni dependencias.

## Alcance implementado

- El lector v2 inspecciona ZIP STORE/ZIP64 y valida versión, manifiesto, rutas, relaciones, cantidades, tamaños, CRC/SHA-256, entradas centrales/locales, nombres duplicados, traversal y enlaces simbólicos. Rechaza entradas comprimidas y rutas que no correspondan al manifiesto. El manifiesto y directorio central tienen límites de lectura; los registros NDJSON y lotes se procesan incrementalmente, y el lector no descarga URLs contenidas en el respaldo.
- La preparación autentica al actor y comprueba que sea propietario actual del destino. Registra una operación idempotente, materializa una generación invisible, calcula y reserva objetos antes de exponer un preview, carga a claves privadas construidas en servidor y verifica tamaño/hash antes de guardar recibos. El spool de ZIP vive dentro de la solicitud y se elimina al terminar.
- El preview permite mapear cada referencia de persona a un miembro actual del destino o dejarla sin asignar. No busca personas por nombre/correo ni concede acceso desde el paquete. Menciones y autores históricos permanecen texto/atribución importada; no crean avisos históricos. Si una etiqueta colisiona tras normalización, el dueño debe proporcionar un nombre libre explícito. La decisión se guarda contra la operación preparada, se puede reintentar sin volver a subir el archivo y se valida de nuevo al confirmar.
- La confirmación revalida dueño, revisión de contenido, capacidad, catálogo de etiquetas y membresías seleccionadas. En una transacción cambia el nombre/zona del tablero y el puntero activo juntos, retiene la generación previa por siete días y solo publica la nueva generación cuando las reservas/objetos verificados están listos. La migración guarda explícitamente el contexto restringido para asignaciones, que solo permite las filas elegibles y el cambio de responsable/versionado esperado.
- El roundtrip sintético exportador→importador cubre los tipos incluidos en el formato v2. Los fixtures SQL comprueban etiquetas/asociaciones, calendario/exclusiones, series detenidas, relación A→B, ocurrencias/historia, actividad E05 y ausencia de notificaciones antiguas o acumulación de atrasos.

## Criterios de aceptación y evidencia

| Criterio | Resultado | Evidencia y límites |
| --- | --- | --- |
| Validar manifiesto, relaciones, rutas, hashes/tamaños; rechazar traversal, symlinks, duplicados y lectura remota; preparar incrementalmente | **Automático** | `tests/unit/portable-board-import-zip.test.mjs` cubre lectura incremental STORE, hashes, ZIP comprimido, nombres duplicados, traversal y symlink. `tests/unit/portable-board-import.test.mjs` verifica materialización por lotes, adjuntos invalidados y cancelación de staging inválido. `tests/db/board_import_v2.sql` comprueba que solo se publican datos preparados y recibos verificados. La ruta no usa campos/URLs del ZIP como destinos de red o claves Storage. |
| Remapear catálogo/asociaciones sin unir por nombre; asignaciones compatibles explícitas o sin asignar; menciones como texto y atribución importada | **Automático** | Preview presenta referencias de origen con etiquetas neutrales y opciones para miembro vigente o sin asignar. El endpoint de decisiones conserva las selecciones y es idempotente; nombres de etiqueta en colisión requieren una nueva etiqueta disponible, sin sufijo automático ni fusión. SQL focal verifica selección válida, usuario externo rechazado, retry idempotente y revocación de membresía antes de confirmar. No se infieren identidades por nombre/correo. |
| Preservar reglas/exclusiones, series detenidas, relación A→B y actividad vigente sin avisos antiguos ni pila de atrasos | **Automático en fixture sintético** | `tests/db/board_import_v2.sql` valida calendario/zona, exclusiones, serie detenida y su plantilla, relación de serie transferida, ocurrencias e historia, actividad E05 y que la importación no cree notificaciones previas ni tareas de recuperación de atrasos. Las tareas y plantillas resuelven responsables con la misma decisión vigente/unassigned. |
| Reservar objetos/capacidad antes del puntero; capacidad para previo + nuevo; roundtrip de todos los tipos y Storage failures | **Automático con doble local; Storage físico y máximo G06 pendientes** | Tests unitarios y DB simulan ACK de objetos y fallo de Storage, reintento idempotente, cancelación/pending sin liberar cuota antes de ACK, reserva bajo cuota compartida y publicación atómica. El fixture de export→import recorre los tipos v2. No se conectó Storage físico. El lector/exportador comparten límites de paquete (220.000.000 bytes), entradas (25.000), manifiesto (8.000.000 bytes), directorio central (32.000.000 bytes) y registros (100.000); adjuntos individuales mantienen el contrato de 24.000 bytes. Los límites globales de paquete/conteo son presupuestos de protección implementados, no capacidad aprobada ni prueba del mayor tablero válido: deben medirse contra presupuestos del runtime y el exportador para cerrar G06. La cuota de adjuntos continúa siendo 200.000.000 bytes globales y se valida además de la retención/reserva. |
| Evidencia reproducible, controles/mensajes en español, permisos, accesibilidad y estados de error | **Parcial; navegador/accesibilidad manual pendiente** | La evidencia registra versiones, actores sintéticos, entorno aislado y resultados automáticos. Unit tests revisan contrato de rutas/UI, mapeos explícitos, textos en español, límites de decisiones y estados de error. Las rutas derivan actor de sesión; las RPCs revalidan dueño/miembros. No se probaron visualmente foco, teclado, lector de pantalla, contraste, tamaños responsive ni recorrido con Auth en navegador. |
| Conservar contratos C-01–C-112 y P/E, sin ampliar el ticket ni declarar gates no probados | **Implementado; revisión final pendiente** | La implementación se limita a importación v2 y conserva la arista `Blocked by #43`; no agrega restauración UI de #45, creador ordinario de series ni Q61–62. La revisión Spec y Standards/Privacy del SHA final se registrará al completarse. |

## Entorno aislado

- Node `24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, PostgreSQL `16.15` descartable.
- `scripts/test-db.sh` usa un cluster temporal local y lo elimina al terminar; no usa `DATABASE_URL`, `PGHOST` ni SQL remoto. Los tests de DB #42/#43/#44 corren sobre esa base descartable y aplican la migración 070.
- Los actores, tableros, miembros, respaldos y objetos son sintéticos. Se simularon ACKs de Storage desde el arnés local; no se emplearon cuentas/OAuth/secrets reales, Storage remoto, datos reales, `main`, producción ni deploy.
- Se leyó la guía local de Next.js `16.4.2` bajo `node_modules/next/dist/docs/` antes de cambiar rutas/handlers.

## Verificaciones reproducibles

| Comando | Resultado |
| --- | --- |
| `pnpm test:unit:issue-44` | PASS, 7 tests de ZIP, preparación y adapter/idempotencia/fallo de Storage simulado. |
| `node --experimental-strip-types --test tests/unit/board-import-contract.test.mjs` | PASS, 4 contratos de ruta, UI, staging invisible y decisiones explícitas. |
| `pnpm test:db:issue-42` | PASS, regresión del exportador/snapshot con migraciones hasta 070. |
| `pnpm test:db:issue-43` | PASS, regresión de importación v1 con migraciones hasta 070. |
| `pnpm test:db:issue-44` | PASS, PostgreSQL descartable; relaciones/historia v2, cuota/reservas, mapeos/reintentos, revocación, stale edit y publicación atómica. Storage es doble SQL/local, no físico. |
| `pnpm test:unit` | PASS, suite completa incluyendo tests de exportación, importación v1 y v2. |
| `pnpm exec next typegen` | PASS. |
| `pnpm typecheck` | PASS. |
| `pnpm build` | PASS en Next.js 16.4.2; expone import, confirm y `labels`, sin UI de restore #45. |
| Biome dirigido (`pnpm exec biome check --line-ending=crlf`) | PASS, los 8 archivos TS/TSX/MJS tocados. |
| `git diff --check` | PASS, sin errores de whitespace. Git avisó de normalización CRLF en SQL, sin cambiar el resultado. |
| `pnpm test:db` | Falla en la regresión previa #27: `tests/db/repetition_series_history.sql:169`, `First history page omitted continuation`. Base fija limpia `ba29e2a` presenta el mismo fallo en `pnpm test:db:issue-27`: un current con `latest_occurrence_on=2026-11-02`, `next_due_on=2026-11-03`, mientras el fixture espera dos. Se registra como fallo baseline y no se cambió #27; los focos #42/#43/#44 pasan en este candidato. |

## Gates pendientes

- **Storage/G04:** verificar carga/lectura/purga físicas, ACK real tras éxito, timeouts/interrupciones y reconciliación de cuotas; el doble local no demuestra comportamiento del proveedor.
- **G06:** medir el máximo tablero/ZIP válido, memoria/CPU/tiempo y espacio temporal con el exportador real y Storage local. Los límites de paquete/conteo anteriores no prueban esa capacidad; no se trunca silenciosamente y G06 queda parcial.
- **Navegador y accesibilidad:** recorrido manual de preview, resolver membresías/colisiones, confirmar/cancelar y errores con foco/teclado/lector de pantalla y tamaños móvil/escritorio.
- **Cron/aceptación:** la limpieza SQL se probó focalmente, pero no la cadencia/ejecución externa del worker. Aceptación humana sigue pendiente.

Mantener #44 OPEN y `Blocked by #43`; no cerrar issues ni interpretar las pruebas sintéticas como aceptación del gate de Storage o del navegador.
