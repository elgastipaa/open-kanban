# Issue #44 — evidencia de importación completa v2

**Contrato:** P24/P22; C-101/C-105/C-110–112; CF-19; G06. Trazabilidad P/E: P22, P24, E01, E05. El reemplazo importa el modelo portable completo, protege la generación activa y conserva calendario, relaciones, actividad válida y adjuntos bajo las reglas de cuota.

**Base fija de implementación/revisión:** `ba29e2a9d758fcf5ff9761dc4e66fd4e32c2756f` (`codex/openkanban-1-0`).
**Código validado:** `6ea31011b806fc5505f91d684f4ab4ee7ba91987`.
**Rama:** `codex/issue-44`.
**Estado del tracker:** #44 permanece OPEN/`ready-for-human`; AC1–3 y AC6 están marcados, AC4/AC5 quedan parciales por E2E, Storage/G04, G06 y QA humana. Conserva `Blocked by #43`; #43 sigue OPEN/`ready-for-human` con Storage/G04, navegador/aceptación y cron pendientes. Esta evidencia sintética no cambia dependencias.

## Alcance implementado

- El lector v2 inspecciona ZIP STORE/ZIP64 y valida versión, manifiesto, rutas, relaciones, cantidades, tamaños, CRC/SHA-256, entradas centrales/locales, nombres duplicados, traversal y enlaces simbólicos. Rechaza entradas comprimidas y rutas que no correspondan al manifiesto. El manifiesto y directorio central tienen límites de lectura; los registros NDJSON y lotes se procesan incrementalmente, y el lector no descarga URLs contenidas en el respaldo.
- Antes de leer el body o crear un spool, la ruta valida en la sesión activa que el actor siga siendo propietario del slug. Luego registra una operación idempotente, materializa una generación invisible, calcula y reserva objetos antes de exponer un preview, carga a claves privadas construidas en servidor y verifica tamaño/hash antes de guardar recibos. Las RPC vuelven a validar owner al preparar/finalizar. El spool de ZIP vive dentro de la solicitud y se elimina al terminar.
- El preview permite mapear cada referencia de persona a un miembro actual del destino o dejarla sin asignar. No busca personas por nombre/correo ni concede acceso desde el paquete. Menciones y autores históricos permanecen texto/atribución importada; no crean avisos históricos. Si una etiqueta colisiona tras normalización, el dueño debe proporcionar un nombre libre explícito. La decisión se guarda contra la operación preparada, se puede reintentar sin volver a subir el archivo y se valida de nuevo al confirmar.
- La vista previa muestra nombre y zona horaria actuales frente a los propuestos por el paquete. La confirmación revalida dueño, revisión de contenido, capacidad, catálogo de etiquetas y membresías seleccionadas. En una transacción cambia nombre/zona del tablero y puntero activo juntos, retiene la generación previa por siete días y solo publica la nueva generación cuando reservas/objetos verificados están listos. La migración guarda explícitamente el contexto restringido para asignaciones, que solo permite filas elegibles y el cambio de responsable/versionado esperado.
- Un fixture ZIP poblado encadena `createPortableZipStream` → `openPortableBoardImportZip` → `preparePortableBoardImport` y el adapter simulado; comprueba que las 13 entidades llegan en lotes no vacíos, relaciones representativas y bytes de un adjunto verificado. Es una prueba del escritor ZIP→parser→staging adapter; el fixture SQL de materialización consume registros sintéticos preparados directamente, no el mismo archivo producido por la ruta/exportador HTTP. Los focos DB comprueban etiquetas/asociaciones, calendario/exclusiones, series detenidas, relación A→B, ocurrencias/historia, actividad E05 (incluidos eventos de sistema etiquetados como importados) y ausencia de notificaciones antiguas o acumulación de atrasos.

## Criterios de aceptación y evidencia

| Criterio | Resultado | Evidencia y límites |
| --- | --- | --- |
| Validar manifiesto, relaciones, rutas, hashes/tamaños; rechazar traversal, symlinks, duplicados y lectura remota; preparar incrementalmente | **Automático** | `tests/unit/portable-board-import-zip.test.mjs` cubre lectura incremental STORE, hashes, ZIP comprimido, nombres duplicados, traversal y symlink. `tests/unit/portable-board-import.test.mjs` verifica materialización por lotes, adjuntos invalidados y cancelación de staging inválido. `tests/db/board_import_v2.sql` comprueba que solo se publican datos preparados y recibos verificados. La ruta no usa campos/URLs del ZIP como destinos de red o claves Storage. |
| Remapear catálogo/asociaciones sin unir por nombre; asignaciones compatibles explícitas o sin asignar; menciones como texto y atribución importada | **Automático** | Preview presenta referencias de origen con etiquetas neutrales y opciones para miembro vigente o sin asignar. El endpoint de decisiones conserva las selecciones y es idempotente; nombres de etiqueta en colisión requieren una nueva etiqueta disponible, sin sufijo automático ni fusión. SQL focal verifica selección válida, usuario externo rechazado, retry idempotente y revocación de membresía antes de confirmar. No se infieren identidades por nombre/correo. |
| Preservar reglas/exclusiones, series detenidas, relación A→B y actividad vigente sin avisos antiguos ni pila de atrasos | **Automático en fixture sintético** | `tests/db/board_import_v2.sql` valida calendario/zona, exclusiones, serie detenida y su plantilla, relación de serie transferida, ocurrencias e historia, actividad E05 y que la importación no cree notificaciones previas ni tareas de recuperación de atrasos. Eventos de sistema importados quedan `actor_type='imported'` con actor sin nombre, que la UI muestra como «Actividad importada». Las tareas y plantillas resuelven responsables con la misma decisión vigente/unassigned. |
| Reservar objetos/capacidad antes del puntero; capacidad para previo + nuevo; roundtrip de todos los tipos y Storage failures | **ZIP poblado→parser→adapter automático; E2E completo parcial; Storage físico y G06 parcial** | portable-board-import-adapter.test.mjs comprueba que el escritor ZIP v2 produce un paquete poblado que parser/validator/staging adapter recorren para las 13 entidades y un adjunto; tests/db/board_import_v2.sql comprueba aparte la materialización SQL de relaciones/historia y publicación. No se procesa el mismo snapshot hasta materializarlo por HTTP/SQL. Dobles locales cubren ACK/reintento, error de Storage y remove sin error con objeto aún listado o inventario incompleto; en ambos casos se conserva metadata/cuota. La ausencia listada es requisito para llamar el RPC de cleanup. No se conectó Storage físico. El lector/exportador comparten límites de paquete (220.000.000 bytes), entradas (25.000), manifiesto (8.000.000 bytes), directorio central (32.000.000 bytes) y registros (100.000); adjuntos individuales mantienen el contrato de 24.000 bytes. Los límites globales de paquete/conteo son presupuestos de protección implementados, no capacidad aprobada ni prueba del mayor tablero válido: deben medirse contra presupuestos del runtime y el exportador para cerrar G06. La cuota de adjuntos continúa siendo 200.000.000 bytes globales y se valida además de la retención/reserva. |
| Evidencia reproducible, controles/mensajes en español, permisos, accesibilidad y estados de error | **Parcial; navegador/accesibilidad manual pendiente** | La evidencia registra versiones, actores sintéticos y entorno aislado. Unit tests revisan preflight owner antes de lectura/spool (actor sin propiedad no invoca el callback de lectura), contrato de rutas/UI, mapeos, preview de nombre/zona, textos en español, límites de decisiones y estados de error. Las RPCs revalidan dueño/miembros. No se probaron visualmente foco, teclado, lector de pantalla, contraste, tamaños responsive ni recorrido con Auth en navegador. |
| Conservar contratos C-01–C-112 y P/E, sin ampliar el ticket ni declarar gates no probados | **Implementado; reviews Spec y Standards/Privacy cerradas en 6ea3101** | Ambas revisiones cubrieron 6ea31011b806fc5505f91d684f4ab4ee7ba91987 contra base ba29e2a9d758fcf5ff9761dc4e66fd4e32c2756f. Spec no halló otros comportamientos que contradigan el issue y confirma que el roundtrip E2E permanece parcial. Standards/Privacy no encontró nuevas violaciones duras ni hallazgos materiales; mantiene solo el smell no bloqueante de escaneo duplicado de controles. No hay expansión a #45; se conserva Blocked by #43. |

## Entorno aislado

- Node `24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, PostgreSQL `16.15` descartable.
- `scripts/test-db.sh` usa un cluster temporal local y lo elimina al terminar; no usa `DATABASE_URL`, `PGHOST` ni SQL remoto. Los tests de DB #42/#43/#44 corren sobre esa base descartable y aplican la migración 070.
- Los actores, tableros, miembros, respaldos y objetos son sintéticos. En el fixture SQL el owner es `a4400000-0000-4000-8000-000000000001` (`issue44-owner@example.test`), el miembro destino es `a4400000-0000-4000-8000-000000000002`, y el tablero parte como «Destino previo»/`UTC`; el paquete propone «Respaldo completo»/`America/Argentina/Buenos_Aires`. Los tests de ruta usan el slug `synthetic-board`; el ZIP poblado incluye las 13 entidades y un adjunto sintético. Se simularon ACKs de Storage desde el arnés local; no se emplearon cuentas/OAuth/secrets reales, Storage remoto, datos reales, `main`, producción ni deploy.
- Se leyó la guía local de Next.js `16.4.2` bajo `node_modules/next/dist/docs/` antes de cambiar rutas/handlers.

## Verificaciones reproducibles

| Comando | Resultado |
| --- | --- |
| `pnpm test:unit:issue-44` | PASS, 13 tests de owner preflight, preview de cabeceras, ZIP, validación, staging/relaciones, idempotencia y fallos/incertidumbre de Storage simulado. |
| `pnpm test:unit:issue-43` | PASS, 9 tests; incluye contrato de rutas/UI, staging invisible y decisiones explícitas. |
| `pnpm test:unit:issue-36` | PASS, 8 tests de actividad; conserva imported/actor_name=NULL y rechaza user sin nombre. |
| `pnpm test:db:issue-42` | PASS, regresión del exportador/snapshot con migraciones hasta 070. |
| `pnpm test:db:issue-43` | PASS, regresión de importación v1 con migraciones hasta 070. |
| `pnpm test:db:issue-44` | PASS, PostgreSQL descartable; relaciones/historia v2, cuota/reservas, mapeos/reintentos, revocación, stale edit y publicación atómica. Storage es doble SQL/local, no físico. |
| `pnpm test:unit` | PASS, suite completa incluyendo tests de exportación, importación v1 y v2. |
| `pnpm exec next typegen` | PASS. |
| `pnpm typecheck` | PASS. |
| `pnpm build` | PASS en Next.js 16.4.2; expone import, confirm y `labels`, sin UI de restore #45. |
| Biome dirigido (`pnpm exec biome check --line-ending=crlf`) | PASS, 24 archivos TS/TSX/MJS del diff completo, sin fixes pendientes. |
| `git diff --check` | PASS, sin errores de whitespace. Git avisó de normalización CRLF en SQL, sin cambiar el resultado. |
| `pnpm test:db` | Ejecutado al cierre; se detiene en la regresión previa #27: `tests/db/repetition_series_history.sql:169`, `First history page omitted continuation`, `has_more=false` y una ocurrencia `current` (`latest_occurrence_on=2026-11-02`, `next_due_on=2026-11-03`) mientras el fixture espera dos. La base limpia `ba29e2a` presenta el mismo error en `pnpm test:db:issue-27`; no se cambió #27. Los focos #42/#43/#44 pasan en este candidato. |

## Gates pendientes

- **Storage/G04:** verificar carga/lectura/purga físicas, ACK real tras éxito, timeouts/interrupciones y reconciliación de cuotas; el doble local no demuestra comportamiento del proveedor.
- **G06:** medir el máximo tablero/ZIP válido, memoria/CPU/tiempo y espacio temporal con el exportador real y Storage local. Los límites de paquete/conteo anteriores no prueban esa capacidad; no se trunca silenciosamente y G06 queda parcial.
- **Navegador y accesibilidad:** recorrido manual de preview, resolver membresías/colisiones, confirmar/cancelar y errores con foco/teclado/lector de pantalla y tamaños móvil/escritorio.
- **Cron/aceptación:** la limpieza SQL se probó focalmente, pero no la cadencia/ejecución externa del worker. Aceptación humana sigue pendiente.

Mantener #44 OPEN y `Blocked by #43`; no cerrar issues ni interpretar las pruebas sintéticas como aceptación del gate de Storage o del navegador.
