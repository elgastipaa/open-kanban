# Issue #43 — evidencia de importación segura v1

**Contrato:** P24/P21, C-92, CF-19, G06; trazabilidad P18/P24. La importación de este ticket lee el respaldo legado v1, reemplaza el tablero destino solo tras confirmación del dueño y permite recuperar la versión anterior durante siete días.

**Base fija:** `97d21d450e42ef51606dda4f89f2bb58a6997cc3` (`codex/openkanban-1-0`).
**Rama:** `codex/issue-43`.
**Estado:** #43 queda abierto. Se conserva `Blocked by #42`; las pruebas sintéticas no satisfacen Storage/G04 ni aceptación humana.

## Criterios y evidencia

| Criterio | Resultado | Evidencia y límites |
| --- | --- | --- |
| Lector v1 valida y mapea al modelo actual sin inventar identidad, etiquetas o series | **Automático** | `parseLegacyBoardImport` acepta solo el sobre v1 y sus campos portables de columnas/tareas. Rechaza campos desconocidos, versiones y límites inválidos; el slug del origen no selecciona el destino. La preparación crea tareas sin autor, responsable, fecha, finalización, pasos, etiquetas ni series. `tests/unit/legacy-board-import.test.mjs` y `tests/db/board_import_v1.sql`. |
| Preparación invisible con preview de versión/capacidad; confirmación revalida dueño y contenido | **Automático** | PostgreSQL prepara una generación `preparing` que la lectura normal no publica. La UI muestra conteos del contenido actual/importado, cuota y vencimiento; confirmar exige la sesión autenticada, propiedad vigente, revisión esperada, hash del archivo y hash del contenido preparado. `tests/db/board_import_v1.sql`, `tests/db/board_import_v1_cleanup.sql` y `tests/db/board_import_v1.sql` prueban también que ni la mutación de tareas ni el incremento directo exacto de `task_order_version` pueden alterar una generación preparada; el contexto de staging no concede `INSERT` a `authenticated` ni `service_role`. |
| Publicación atómica conserva dueño/integrantes y previo siete días contado en cuota | **Automático en PostgreSQL; Storage físico pendiente** | El cambio de estado de generaciones, retención y puntero activo ocurre en una transacción. La fixture verifica dueño e integrantes intactos, adjunto previo de 12 bytes dentro de cuota y vencimiento exactamente a 168 horas. Un trigger de fallo sintético en el último cambio de puntero deja intactos el puntero, generación, retención y recibo. El test de limpieza conserva cuota y adjunto en `cleanup_pending` hasta recibir el ACK sintético de ausencia; no se borró ningún objeto real de Storage. |
| Fallo entre fases, edición concurrente, respuesta perdida tras commit y cuota insuficiente | **Automático** | El error inyectado al publicar revierte todo; dos sesiones PostgreSQL mantienen el lock del tablero mientras una edición se confirma y la importación obsoleta responde `conflict`; cuota insuficiente conserva la preparación reintentable; una segunda confirmación en transacción posterior obtiene el mismo recibo comprometido. `scripts/test-db-issue-43-race.sh`, `tests/db/board_import_v1.sql` y `tests/db/board_import_v1_cleanup.sql`. Son carreras SQL locales, no una prueba HTTP con corte real de red. |
| Controles, errores y estados nuevos en español, permisos y accesibilidad | **Parcial; navegador pendiente** | Las rutas usan la sesión del actor y RPC de dueño; el control se muestra solo a quien puede renombrar el tablero. La UI exige revisar y confirmar, anuncia estado con `<output aria-live="polite">`, presenta errores con `role="alert"`, muestra capacidad insuficiente y evita informar un fallo de confirmación si solo falla refrescar la vista. `tests/unit/board-import-contract.test.mjs`, Biome dirigido, TypeScript y build. No se recorrieron DOM, foco, teclado, lector de pantalla ni tamaños móvil/escritorio en navegador. |
| Conservar contratos C-01–C-112 y P/E; no ampliar ni declarar gates no probados | **Automático / revisión humana pendiente** | Migración aditiva `069_safe_v1_board_import.sql`, regresiones previas completas y tests focales de #43; no se alteran Auth, cuentas reales, Storage externo, otras rutas de recuperación ni tickets posteriores. #43 conserva la arista `Blocked by #42`; no se cierra ni se declara aceptada la revisión humana. |

## Entorno aislado

- Node `24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, PostgreSQL `16.15`.
- `scripts/test-db.sh` crea un cluster PostgreSQL temporal propio bajo `/tmp/openkanban-db.*` y lo elimina al terminar; no usa `DATABASE_URL` ni `PGHOST`.
- Los actores, tableros y adjuntos son sintéticos. La fixture #43 usa dueño y colaborador ficticios, un adjunto de 12 bytes, una falla de publicación y vencimientos locales de una hora/siete días. No se usaron OAuth, cuentas/datos reales, claves reales, SQL remoto, Storage remoto, producción ni despliegue.
- La limpieza de adjuntos se valida hasta el ACK de ausencia simulado. La conexión/objeto Storage real y el recorrido humano en navegador quedan fuera de esta evidencia.

## Verificaciones reproducibles

| Comando | Resultado |
| --- | --- |
| `pnpm test:unit:issue-43` | PASS, 7 tests focales. |
| `pnpm test:db:issue-43` | PASS, migraciones y fixtures focales en PostgreSQL 16.15 descartable; incluye carrera editor/confirm, error de publicación, replay poscommit, guard negativo de orden y limpieza por vencimiento/cuota. |
| `pnpm test:unit` | PASS, suite completa. |
| `pnpm test:db` | PASS, suite completa 001–069 en PostgreSQL 16.15 descartable; incluye las regresiones anteriores de cascada, recuperación, exportación y concurrencia. |
| `pnpm exec next typegen && pnpm typecheck` | PASS. |
| `pnpm build` | PASS; compila rutas de importar, confirmar, listar versiones y restaurar. |
| `pnpm exec biome check --line-ending=crlf` en archivos TS/JS del cambio y `package.json` | PASS, chequeo dirigido. |
| `pnpm lint` | No pasa en el checkout completo: Biome reporta 315 diagnósticos de formato entre 315 archivos y excede el límite de salida. Los archivos TS/JS del cambio pasan el chequeo dirigido; no se reescribió el resto del repositorio. |

## Gates pendientes

- Recorrido en navegador con foco, teclado, lector de pantalla y tamaños móvil/escritorio; confirmar los mensajes/conflictos desde la experiencia real.
- Storage/G04: verificar que los objetos retenidos sigan disponibles siete días y que la purga física solo libere cuota tras comprobar ausencia. Solo se probó el ACK sintético.
- Aceptación humana de #43 y resolución del bloqueo `Blocked by #42`. No cambiar dependencias ni cerrar issues por las pruebas sintéticas.
