# Issue #41 — Evidencia de implementación

**Contrato:** `CIERRE-MVP-1.0.md` C-65, CF-16.1 y C111-AC58; `PANTALLAS-MVP-1.0.md` UI-13/UI-15; `MATRIZ-PERMISOS-MVP-1.0.md` F-05–F-10/A-05; `DISENO-TECNICO-MVP-1.0.md` G04. Se conservaron todas las P/E. La evidencia usa fixtures sintéticos locales y no declara QA humana ni cierre de G04.

**Base fija:** `7029e249a23d7c47d900c94f3572892b8df54653`.
**Commits de código:** `d50e2412c0499eca7d8db2bd1a8c0e9ca069ff58` (funcionalidad inicial) y `27adffd88fd9486a75e1009e69c4e8b9ec38b10b` (desglose global admin).
**HEAD de código final:** `27adffd88fd9486a75e1009e69c4e8b9ec38b10b`, rama `codex/issue-41`. La revisión final del cambio de desglose fijó base `c0b1cc105a529c2337e5130fead17e9c5a30ce4c`; el código quedó congelado durante esas revisiones.
**Estado:** implementación local, todavía no integrada. #41 no se cierra; `Blocked by #19/#37/#40` permanece intacto. La excepción LP-0.2 permite pruebas sintéticas; no acepta QA ni retira bloqueadores.

## Alcance implementado

- La persona propietaria actual ve consumo y categorías únicamente de su tablero, con cuota global explicada como compartida. La respuesta para ese panel solo da el total, límite y aviso global; no revela el desglose de otros tableros.
- La pantalla UI-15 de administración global separa **activos**, **en recuperación**, **reservas** y **limpieza pendiente**, mostrando bytes y cantidades por categoría. El resumen global es agregado y mínimo; no incluye nombres, contenido, claves Storage, referencias de tarea/archivo ni uploader. La API y RPC verifican que el actor sea administrador habilitado.
- El propietario filtra/pagina adjuntos de tareas completadas. Cada limpieza requiere preview y confirmación explícitas; el servidor vuelve a comprobar propietario, estado completado y adjunto vigente al confirmar. Borrar conserva causa y ventana recuperable; el ledger no libera cuota hasta la purga.
- Administración no miembro no gana acceso a metadatos de contenido del tablero. La restauración administrativa sigue limitada a archivos borrados por causa `admin_cleanup`; no restaura una limpieza del propietario. El dueño con acceso vigente sí puede restaurar su propia limpieza dentro del plazo.
- Los avisos se crean para propietarios activos y administradores al cruzar 160.000.000 bytes (80 %) y 200.000.000 bytes. Se deduplican por persona/nivel y solo se rearman después de bajar y volver a cruzar tras 24 horas. Permanecer encima o cruzar dentro del período no difiere aviso; una carga excedida se rechaza inmediatamente según el contrato existente de #40.

## Criterios y evidencia automática

| Criterio | Resultado automático | Evidencia y límite |
| --- | --- | --- |
| Capacidad admin global: activos, recuperables, reservas y limpieza pendiente, con bytes y conteos diferenciados | PASS en PostgreSQL descartable, helpers unitarios y contrato UI | `tests/db/task_attachment_cleanup_capacity.sql` añade filas sintéticas de 7/11/13/17 bytes y exige deltas independientes de bytes/conteos, total +48 y claves exactas del resumen agregado. Un admin ajeno al tablero obtiene el agregado; un no-admin recibe `unavailable`. `task-attachment-admin-summary.test.mjs` verifica el parseo y las tarjetas por separado. No se realizó recorrido visual de navegador. |
| Privacidad: detalle global cross-board solo para administración | PASS en DB y unitarias | La prueba DB comprueba shape agregado sin campos de archivo/tarea/uploader y denegación del no-admin; las pruebas #40 cubren allowlist de filas administrativas. La vista del dueño conserva breakdown de `board_usage` y solo `used/limit/threshold` global. No se usaron cuentas reales. |
| Consumo propio, estados recuperables/reservados/pendientes, unidades exactas y cuota compartida | PASS en DB y UI/build | Contrato DB valida ledger y retención; UI de dueño muestra su propio tablero y comunica el total global. La interfaz compiló, sin recorrido visual. |
| Limpieza solo de adjuntos de tareas completadas, preview, confirmación e invalidación por cambio de estado/contexto | PASS en PostgreSQL descartable y helpers unitarios | El contrato DB previsualiza, reabre la tarea antes de confirmar y espera `unavailable`; tras completarla nuevamente confirma y revisa recibo idempotente. Helpers prueban parsers acotados. No sustituye Auth/browser real. |
| Retención de cuota hasta purga y reglas de restauración por causa | PASS en PostgreSQL descartable | Tras el borrado recuperable el resumen conserva 24.000 bytes; el miembro/uploader y el administrador no restauran limpieza del dueño, mientras el propietario con acceso actual sí. No se ejecutó purga contra Storage físico. |
| Umbrales, deduplicación persona+nivel, rearme y aviso inmediato al cruzar | PASS con reloj DB controlado y trigger de ledger | Pruebas sintéticas verifican cruce, permanencia 25 h, recross dentro de 24 h, rearme posterior, independencia de niveles y audiencia. Una inserción cruza 160 MB en el ledger real de la DB descartable. No se envía correo/push. |
| Exceso de cuota de carga | PASS por regresión #40 | `pnpm test:db:issue-40` ya confirmó el rechazo inmediato con resultado `quota`; #41 no introduce espera ni aviso diferido. |

El resumen global usado por `/api/admin/task-attachments` proviene de `admin_task_attachment_storage_summary_p`; sus campos agregados ya separan bytes/conteos. La corrección `27adffd` extrae y valida ese contrato en `src/lib/admin-task-attachment-storage-summary.ts` y deja de sumar reservas con limpieza pendiente en `src/components/admin/task-attachment-storage.tsx`. La vista normal permanece en `src/components/board/task-attachment-storage.tsx`.

## Revisión de código

La revisión inicial del candidato `d50e241` detectó dos P2: evidencia por criterio ausente y el breakdown UI-15 presentado como total combinado. El primero se registró en el commit documental previo `c0b1cc1`; el segundo queda corregido por `27adffd`.

Reviews finales del diff `c0b1cc105a529c2337e5130fead17e9c5a30ce4c..27adffd88fd9486a75e1009e69c4e8b9ec38b10b`, en paralelo y de solo lectura:

- **Spec: PASS, sin hallazgos.** UI-15 muestra activos/recuperables/reservas separados y limpieza pendiente aparte; la vista de dueño conserva el alcance del tablero. La prueba confirma el breakdown y shape de metadatos mínimo.
- **Standards/Privacy: PASS, sin hallazgos.** El parser reconstruye únicamente campos agregados permitidos. La RPC valida admin habilitado; el nuevo contrato DB confirma que admin ajeno recibe el agregado mínimo y un no-admin no ve totales globales.

## Entorno y verificaciones

Windows local; PostgreSQL 16 descartable creado por `scripts/test-db.sh` en un directorio temporal propio (`initdb`/`pg_ctl`/`psql` locales, sin `DATABASE_URL`, `PGHOST` ni SQL remoto). Actores e identidades sintéticos (`*.example.test`). Next.js 16.4.2. No se usaron OAuth/Auth reales, Storage remoto, credenciales, datos de usuario, producción ni deploy.

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-41` | PASS; limpieza, permisos, revalidación, recibo, cuota/avisos y breakdown admin agregado. |
| `pnpm test:db` | PASS, migraciones 001–067 y suite completa de regresiones en PostgreSQL descartable. |
| `pnpm test:unit:issue-41` | PASS, 12/12, incluidos breakdown admin, parseo y límite de vista de dueño. |
| `pnpm test:unit` | PASS, suite unitaria completa. |
| `pnpm typecheck` | PASS. |
| `pnpm build` | PASS; incluye `/admin/access` y rutas nuevas. |
| `pnpm exec biome check` dirigido a los tres archivos TS/JS nuevos/modificados | PASS, sin cambios automáticos. |
| `git diff --check` / `git show --check` | PASS. |
| `pnpm lint` | No pasa globalmente por diferencias CRLF/LF preexistentes fuera del diff; el chequeo Biome dirigido pasa y no se reformateó código ajeno. |

## Gates pendientes

- **Storage/G04:** Storage local no pudo levantarse porque Windows denegó iniciar `com.docker.service`; no se intentó elevar permisos. No se validaron upload/download/objeto privado, confirmación física de borrado ni purga real. DB prueba contratos del ledger/transiciones, no bytes físicos.
- **Navegador/Auth y aceptación humana:** sin sesión real ni recorrido visual de UI. Siguen pendientes revisión desktop/móvil/responsive, teclado/lector/foco y aceptación manual.
- No se verificó worker/cron desplegado ni se actualizó el tracker tras el kickoff. No se afirma que #19/#37/#40 hayan recibido aceptación humana ni que `Blocked by #19/#37/#40` se haya resuelto.

## Próxima acción

Integrar localmente `codex/issue-41` desde la base fija después de coordinación, repetir verificaciones aplicables y mantener issue/dependencias abiertos hasta satisfacer gates manuales/externos.
