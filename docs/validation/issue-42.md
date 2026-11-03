# Issue #42 — Evidencia de implementación

**Contrato:** «Exportar un tablero completo en formato portable»; `DISENO-TECNICO-MVP-1.0.md` G06; `CIERRE-MVP-1.0.md` C-92/CF-19/C-101/C-105/C-112; `MVP-1.0.md`; trazabilidad, matriz de permisos y pantallas de exportación/importación. Se mantienen los acuerdos de `CONTINUIDAD-SPEC.md` y `0001-auth-collaboration.md`. El trabajo usa únicamente identidades, tableros y adjuntos sintéticos locales.

**Base fija:** `50f1a2492d229f207cedce2cfebfe9a63d2d5a2f` (`codex/openkanban-1-0`).
**Rama:** `codex/issue-42`.
**HEAD de código revisado:** `9aa647c3722d8e838fd19e971f97aa1d4c5454eb` (implementación `c660630621f0315f1fca79a74f6c7d161a771920` más correcciones de review).
**Reviews finales:** Spec y Standards/Privacy PASS sobre `50f1a2492d229f207cedce2cfebfe9a63d2d5a2f..9aa647c3722d8e838fd19e971f97aa1d4c5454eb`, sin hallazgos accionables.
**Estado:** código revisado e integrado/publicado en `codex/openkanban-1-0` y `codex/issue-42` (checkpoint integrado `52c861f2efae7fbcd7fe1ec14048f841e6f132fa`). #42 permanece OPEN/`ready-for-human`, asignado a `elgastipaa`; AC1–4/AC6 verificados y AC5 pendiente. `Blocked by #28/#29/#31/#36/#40` queda intacto. LP-0.2 habilita esta verificación sintética sin aceptar QA humana ni retirar dependencias.

## Alcance implementado

- `068_board_export_snapshots.sql` captura una sentencia MVCC del tablero en filas inmutables paginables. La allowlist incluye el tablero, columnas/tareas activas, comentarios visibles, todas las etiquetas activas aunque no tengan asignaciones, asociaciones de tareas/cumpleaños/plantillas de serie, calendarios, patrones y anticipación de series, ocurrencias históricas, actividad de hasta 180 días y adjuntos activos. Series y relaciones se limitan a la generación vigente. No consulta preferencias/vistas, bandeja de novedades, membresías, invitaciones, recibos, permisos ni tokens.
- `POST /api/boards/[slug]/export` crea el snapshot; `GET /api/boards/[slug]/export/[exportId]` vuelve a validar identidad y membresía en cada página, entrega ZIP STORE v2 como `ReadableStream`, pagina NDJSON sin crear un Blob en el navegador y valida SHA-256/tamaño. El manifiesto va al final y registra la integridad de cada archivo. Ante cancelación/error no se escribe directorio central/cierre ZIP, así que un stream incompleto no forma un paquete válido.
- Los UUID de registros solo organizan relaciones dentro del archivo; referencias de personas son seudónimos específicos de cada paquete, calculados con HMAC-SHA256 y una clave aleatoria efímera que no se persiste ni se exporta. Correos usados por eventos históricos se seudonimizan y nunca se exportan permisos, roles o claves Storage. Los paquetes no abren URLs de texto como recursos remotos.
- Cada snapshot fija las claves inmutables de adjuntos activos y crea pins de una hora. Las páginas los renuevan mientras la descarga avanza; no cambian `task_attachments.expires_at`. El limpiador existente elimina snapshots vencidos y el claim de purga ignora objetos con pins vigentes.
- La advertencia en español informa que la copia portable puede conservarse tras un cambio de acceso. Los controles de modal tienen estados ocupado/error accesibles; el lector/importador v1 existente sigue intacto.

## Criterios y evidencia

| Criterio | Fixture / entorno | Resultado automático y alcance |
| --- | --- | --- |
| Snapshot coherente y ZIP v2 versionado, transmitido por streaming, completo y con integridad | `tests/db/board_export_snapshot.sql`; `tests/unit/portable-export-zip.test.mjs`; PostgreSQL 16 descartable y Node local | El DB fixture verifica que una edición posterior no altera páginas capturadas. La prueba ZIP valida STORE/ZIP64, manifiesto, tamaños/SHA-256, ruta insegura y que una fuente truncada no genere cierre. La respuesta HTTP entrega `ReadableStream`; no valida almacenamiento físico. |
| Catálogo, calendario, exclusiones, actividad y relaciones C-112 | PostgreSQL sintético con propietario/colaborador y datos recientes/vencidos | Comprueba etiquetas activas sin asignaciones, asignaciones de tarea/cumpleaños/plantilla, cumpleaños vigente, `calendar_pattern` semanal con `advance_days`, serie anterior detenida, serie nueva, occurrence `transferred_to_series_id`, categoría E05 y actividad dentro de 180 días. Comprueba que no salgan tarea/comentario/etiqueta/cumpleaños/serie eliminados ni actividad vencida. |
| Permisos y privacidad; referencias de paquete no autorizan acceso; no descargar URLs | Identidades sintéticas `*.example.test`; contrato unitario de rutas; sin red remota | Propietario y colaborador activos crean su propia exportación. Admin externo y actor distinto no leen el paquete; membresía revocada bloquea páginas siguientes. La prueba busca correo/rol/owner ID/`object_key` en el payload y rechaza el HMAC reemplazado por el hash predecible de `export_id + email`. El route solo descarga `attachments/<uuid>` con Storage server-side; no llama `fetch` con contenido de registros. |
| Revalidación, temporales/pins, cutoff de recuperación y carrera con purga | `tests/db/board_export_snapshot.sql` y `scripts/test-db-issue-42-race.sh`; dos sesiones locales | Una recuperación vencida queda protegida por pin sin cambiar `expires_at`; al retirar/expirar el pin el snapshot se limpia y la purga vuelve a reclamar el objeto. La carrera real mantiene una transacción de exportación con lock de adjunto mientras otra intenta borrar: el borrado espera, luego observa el pin, no reclama el objeto y conserva el plazo original. |
| Controles, errores y estados en español | `BoardExportDialog`; unit test de contrato; typecheck/build | La confirmación explica copia durable; botones se bloquean al preparar, el error usa `role="alert"`, el diálogo existente retiene foco. Falta el recorrido visual/teclado humano en navegador. |
| No ampliar acuerdos posteriores ni dependencias | Diff, allowlist SQL y permisos de las funciones | RPC de creación/lectura/limpieza solo para `service_role`; el actor se deriva de la sesión del servidor y se verifica junto a la membresía vigente. Los bloqueos originales siguen declarados en el tracker. No se cambió Auth, OAuth, Storage, proveedor, contrato de importación v1 ni tracker. |

## Medición sintética local

`pnpm test:db:issue-42` insertó 5.000 tareas sintéticas además de la tarea de control y creó un snapshot completo de 5.001 tareas: **2.752.031 bytes** de payload JSONB en **124,94 ms** en PostgreSQL 16 descartable. La suite integrada, repetida después de corregir el criterio de actividad y el HMAC, midió **2.752.030 bytes** en **118,55 ms**; la diferencia temporal es variación de ejecución.

`pnpm measure:portable-export` transmitió a un contador (sin retener el ZIP) 5.000 registros de tarea y 500 objetos sintéticos de 24.000 bytes cada uno. Produjo **13.043.796 bytes ZIP**, **7.517 chunks** en **91,14 ms**; delta RSS al finalizar: **13.058.048 bytes**. Mide el serializador/hash local, no Postgres→Storage→navegador ni el tamaño/latencia de un tablero real.

## Entorno y verificaciones

- PostgreSQL 16.15 se ejecutó como cluster descartable creado por `scripts/test-db.sh` dentro de un directorio temporal propio. No se usó `DATABASE_URL`, `PGHOST`, SQL remoto ni base compartida.
- Next.js 16.4.2 fue instalado desde el lockfile y se consultaron sus guías locales de Route Handlers, streaming y runtime antes de implementar.
- El servicio local de Storage/Docker no está disponible por permisos del servicio. No se elevó permiso ni se usó Storage remoto, OAuth, credenciales reales o cuentas/datos reales.

| Comando | Resultado |
| --- | --- |
| `pnpm test:unit:issue-42` | PASS, ZIP/contract focal. |
| `pnpm test:db:issue-42` | PASS, migraciones 001–068, contratos snapshot/permisos/pins, fixture de 5.001 tareas y carreras export-vs-edición/purga. |
| `pnpm measure:portable-export` | PASS, medición sintética de 5.000 tareas y 500 adjuntos. |
| `pnpm typecheck` | PASS. |
| `pnpm test:unit` | PASS, suite completa incluida issue-42. |
| `pnpm test:db` | PASS, suite completa en PostgreSQL 16 descartable; incluye issue-42. |
| `pnpm build` | PASS con URL y claves locales de placeholder; compila ambas rutas de exportación. |
| Biome dirigido (`--formatter-enabled=false`) | PASS en 10 archivos TS/JS del cambio. |
| `pnpm lint` | No PASS: el chequeo global reporta 300 diagnósticos de formato en el checkout CRLF (incluye archivos sin cambios). Los archivos de código del diff pasan el chequeo Biome dirigido. |
| Reviews iniciales Spec y Standards/Privacy | Encontraron dos defectos accionables: faltaba `event.category` (P1) y el hash de correo podía atacarse con el export ID público (P2). Ambos se corrigieron en `9aa647c` con regresiones unitarias/DB. |
| Reviews finales Spec y Standards/Privacy, mismo diff contra base fija | PASS en `50f1a24..9aa647c`, sin hallazgos accionables nuevos. |

## Gates pendientes

- **G04 — Storage/browser físico:** sigue abierto. No se pudo iniciar Storage/Docker por permisos del servicio. Los bytes de adjuntos, upload/descarga, interrupción real de red y purga física no se verificaron.
- **G06 — volumen/runtime extremo y publicación completa:** las mediciones sintéticas pasan, pero la ejecución end-to-end contra Storage local, roundtrip v1/v2 y el mayor tablero válido quedan pendientes hasta que el servicio local esté disponible. No se impone truncamiento; un fallo invalida el ZIP al no escribir su cierre.
- **Auth/navegador y aceptación humana:** no se usaron cuentas reales ni se completó un recorrido visual responsive, teclado/lector o aceptación manual. La interfaz compilada no equivale a QA.

## Próximo paso

Mantener #42 abierto/`ready-for-human`, todos los `Blocked by` originales y los gates G04/G06 hasta que una persona verifique Storage y navegador local. #43 puede avanzar según la excepción secuencial LP-0.2 con fixture sintético y su propia base local aislada, conservando `Blocked by #42`; ni esta implementación ni las mediciones actuales satisfacen los gates de Storage o aceptación humana.
