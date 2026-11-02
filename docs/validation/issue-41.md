# Issue #41 — Evidencia de implementación

**Contrato:** `CIERRE-MVP-1.0.md` C-65, CF-16.1 y C111-AC58; `PANTALLAS-MVP-1.0.md` UI-13/UI-15; `MATRIZ-PERMISOS-MVP-1.0.md` F-05–F-10/A-05; `DISENO-TECNICO-MVP-1.0.md` G04. Se conservaron todas las P/E. La evidencia de este archivo corresponde a fixtures sintéticos locales y no declara QA humana ni cierre de G04.

**Base fija:** `7029e249a23d7c47d900c94f3572892b8df54653`.
**HEAD de código revisado:** `d50e2412c0499eca7d8db2bd1a8c0e9ca069ff58` (`feat: clean completed task attachments and warn on capacity (#41)`, rama `codex/issue-41`). El código se revisó antes de crear este documento; las dos revisiones aplican a ese HEAD. Este archivo y el checkpoint del run se registran en un commit documental separado.
**Estado:** implementación local, todavía no integrada. #41 no se cierra; `Blocked by #19/#37/#40` permanece intacto. La excepción LP-0.2 habilita evidencia sintética, no acepta QA ni retira bloqueadores.

## Alcance implementado

- Quien posee actualmente un tablero ve el consumo de adjuntos de su tablero, separado por activos/recuperables y con fechas de vencimiento, junto a la cuota global, límite y umbrales. La vista no presenta 200 MB como cuota del tablero. El desglose global administrativo continúa bajo UI-15 y limitado a metadatos agregados/mínimos.
- La limpieza del propietario filtra y pagina adjuntos de tareas completadas. Cada archivo requiere previsualización y confirmación explícitas. El servidor vuelve a verificar propietario, tarea completada y adjunto vigente en la confirmación; una tarea reabierta o un contexto revocado invalida el cambio. La limpieza es borrado recuperable: mantiene su causa, ventana de recuperación y consumo de cuota hasta la purga.
- Administración fuera de un tablero no habilita lectura/listado de archivos ni de contenido de tarea. La restauración administrativa conserva la condición de causa administrativa; no restaura un archivo eliminado por limpieza del propietario. El propietario aún puede restaurar su propia limpieza dentro de la ventana y con acceso actual.
- Los avisos globales se crean para cada propietario activo y administrador, deduplicados por persona y nivel: 160.000.000 bytes (80 %) y 200.000.000 bytes. El nivel vuelve a armarse solo tras bajar del umbral y cruzarlo nuevamente después de 24 horas; permanecer arriba o cruzar durante el enfriamiento no difiere un aviso. La carga que supera la cuota sigue rechazándose inmediatamente según el contrato de #40, independientemente del ciclo de avisos.

## Matriz de criterios y evidencia

| Criterio | Resultado automático | Evidencia y límite |
| --- | --- | --- |
| Consumo propio y global, estados activos/recuperables/reservados/pendientes, unidades exactas y explicación de cuota compartida | PASS en DB y UI/build | `tests/db/task_attachment_cleanup_capacity.sql` valida agregados y metadatos permitidos; `src/components/board/task-attachment-storage.tsx` muestra el resumen propio y cuota global. La interfaz compiló; no se hizo recorrido visual en navegador. |
| Limpieza solo de adjuntos de tareas completadas, con preview, confirmación e invalidación al cambiar estado/contexto | PASS en PostgreSQL descartable y helpers unitarios | El contrato DB previsualiza el adjunto, reabre la tarea antes de confirmar y espera `unavailable`; luego vuelve a completarla, confirma la limpieza e inspecciona el recibo idempotente. Los helpers `task-attachment-board-cleanup` prueban parsers acotados. No reemplaza una sesión real de Auth/browser. |
| Permisos de propietario y administrador ajeno; privacidad de metadatos/contenido | PASS en PostgreSQL descartable y rutas/helpers unitarios | Fixtures aislados de propietario, miembro, administrador y persona ajena comprueban que solo el dueño lista/limpia su tablero; el administrador ajeno no recibe filas y una persona sin membresía no obtiene preview. Avisos son propios y no incluyen nombres/clave/contenido. Restauración administrativa de causa de limpieza del dueño se rechaza. No se usaron cuentas reales. |
| Retención de cuota hasta purga y reglas de restauración por causa | PASS en PostgreSQL descartable | Tras el borrado recuperable, el resumen mantiene los 24.000 bytes en recuperables; miembro/uploader y administrador no restauran una limpieza del dueño, y el dueño con acceso actual sí. Los tests no ejecutan purga contra Storage físico. |
| Umbrales 80 %/200 MB, deduplicación persona+nivel, rearme por cruce y aviso sin diferimiento | PASS con reloj DB controlado y trigger de ledger | Pruebas con timestamps sintéticos comprueban cruce, permanencia de 25 h, baja/recross dentro de 24 h, rearme tras 24 h, niveles independientes y audiencia. Una inserción real de adjunto en el PostgreSQL de prueba cruza 160 MB en el ledger y produce avisos agregados. No se envía correo/push. |
| Carga sobre cuota rechazada de forma inmediata | PASS por regresión existente de #40 | `pnpm test:db:issue-40` confirma el resultado `quota` para exceso; #41 no introduce espera ni aviso diferido en esa ruta. No se contactó Storage. |

Los archivos de contrato y rutas nuevas están en `supabase/migrations/067_task_attachment_cleanup_and_capacity_notices.sql`, `src/app/api/boards/[slug]/task-attachments/route.ts` y `src/app/api/task-attachment-capacity-notices/route.ts`. Las verificaciones DB y unitarias focales están en `tests/db/task_attachment_cleanup_capacity.sql` y `tests/unit/task-attachment-board-cleanup.test.mjs` / `tests/unit/task-attachment-capacity-notice.test.mjs`.

## Revisión de código

Las revisiones Spec y Standards/Privacy corrieron en paralelo y fueron de solo lectura sobre `d50e2412c0499eca7d8db2bd1a8c0e9ca069ff58`.

- **Spec:** una observación P2 pidió esta matriz de evidencia; queda atendida por este documento, sin cambiar el HEAD de código revisado. La observación sobre desglose global se evaluó contra los contratos: UI-13 expone desglose de consumo propio y explica la cuota global; UI-15 reserva activos/recuperables/reservas globales al administrador. No se amplió el acceso de una persona dueña a otros tableros; el desglose administrativo está en la pantalla admin existente de #40.
- **Standards/Privacy:** PASS, sin infracciones de privacidad ni hallazgos accionables. Se anotaron señales heurísticas no bloqueantes de duplicación en la comprobación del recibo idempotente bajo lock y en un helper JSON repetido, consistente con los Route Handlers ya existentes del repositorio.

## Entorno y verificaciones

Verificación local sobre PostgreSQL 16 descartable creado por `scripts/test-db.sh` en un directorio temporal propio. El script usa `initdb`/`pg_ctl`/`psql` locales y elimina solo ese directorio; no consume `DATABASE_URL`, `PGHOST` ni SQL remoto. Actores, identidad y contenido fueron sintéticos (`*.example.test`). Next.js local: 16.4.2. No se usaron OAuth/Auth reales, Storage remoto, credenciales, datos de usuario, producción ni deploy.

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-41` | PASS; limpieza, permisos, revalidación, recibo, cuota retenida y ciclo de avisos. |
| `pnpm test:db:issue-40` | PASS; regresión de reservas/cuota y rechazo inmediato al exceder el límite. |
| `pnpm test:db` | PASS con las migraciones 001–067 y regresiones previas. |
| `pnpm test:unit:issue-41` | PASS, 8/8. |
| `pnpm test:unit` | PASS, suite unitaria completa. |
| `pnpm typecheck` | PASS después de `pnpm exec next typegen`. |
| `pnpm build` | PASS con Next.js 16.4.2; incluye las rutas nuevas. |
| `pnpm exec biome check` dirigido a los archivos modificados de código/pruebas | PASS, sin aplicar formato automático. |
| `bash -n scripts/test-db.sh` y `bash -n scripts/test-db-issue-41.sh` | PASS. |
| `git diff --check` | PASS en el candidato de código. |
| `pnpm lint` | No pasa globalmente: Biome informa diferencias CRLF/LF en el checkout/base, fuera de los archivos modificados. El chequeo dirigido de los archivos de #41 sí pasa; no se reformateó código ajeno. |

## Gates pendientes

- **Storage/G04:** el servicio local de Storage no pudo levantarse porque Windows denegó iniciar `com.docker.service`; no se intentó elevar permisos. No se validaron upload/download/objeto privado, ACK de eliminación física ni purga real. La suite de PostgreSQL prueba contratos de ledger/transiciones solamente.
- **Navegador/Auth y aceptación humana:** no se realizó recorrido de UI con sesión autorizada, revisión visual desktop/móvil/responsive ni auditoría manual de teclado/lector de pantalla/foco. Typecheck/build y helpers no sustituyen esos gates.
- No se verificó worker/cron desplegado ni se alteró el tracker tras el kickoff. No se afirma que #19/#37/#40 tengan aceptación humana ni que `Blocked by #19/#37/#40` se haya resuelto.

## Próxima acción

Integrar localmente la rama `codex/issue-41` desde la base fija después de la coordinación correspondiente, manteniendo el issue abierto y sus dependencias. Repetir las verificaciones aplicables en la integración y dejar Storage/G04, worker/cron y QA manual como gates explícitos hasta contar con entorno y aceptación autorizados.
