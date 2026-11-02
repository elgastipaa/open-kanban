# Validación del issue #24 — Repetir por semanas y días elegidos

## Alcance y estado

Base fija: `88729397ac37345ff63e0e4ca03d4ac3e691c5bf`. Rama: `codex/issue-24`. Worktree: `C:\Users\gasto\.codex\worktrees\openkanban-issue-24\open-kanban`. Commit de implementación candidato: `c75a332` (`feat: add weekly repetition (#24)`).

El cambio agrega patrones diarios y semanales con intervalo positivo y días ISO lunes–domingo. La semana se ancla al lunes de la semana inicial; la tarea actual cuenta como primera fecha y no se generan fechas anteriores a ella. La opción Laborables selecciona lunes a viernes sin consultar ni excluir feriados. Preview, persistencia, reintentos y ejecución durable usan el mismo patrón canónico.

El issue #24 sigue **OPEN**/`ready-for-agent`; esta entrega local no cambia su estado ni sustituye revisión humana. Se conserva `Blocked by #23`. El issue #23 sigue **OPEN**/`ready-for-human`, y no se aceptó su QA ni se modificó su bloqueo. No se agregan patrones mensuales, anuales ni ordinales de #25. No se declara completo G03 ni se afirma que un host/cron externo esté configurado.

## Criterios y evidencia

| Criterio de #24 | Evidencia reproducible | Resultado y límite |
| --- | --- | --- |
| Semana lunes–domingo anclada a la semana inicial; sin fechas anteriores; intervalos positivos y uno o varios días. | `tests/db/daily_repetition.sql`: inicio miércoles 4/11/2026, cada 2 semanas, lunes/miércoles; el preview devuelve 16/11, 18/11 y 30/11, y no 9/11. El caso que cruza año inicia lunes 28/12/2026 y, con lunes/miércoles, N=4 termina el 13/1/2027. El RPC público rechaza intervalo 0, días vacíos y `weekdays:[null]` con SQLSTATE `22023`. Persistencia, getter y replay verifican patrón/semana/días. | **PASS automático** en PostgreSQL descartable. El fixture con dos días prueba selección múltiple; fechas y conteo se observan por RPC y worker. |
| Laborables es lunes–viernes sin feriados; preview, validación y ejecución comparten el cálculo. | El preview público empieza jueves 31/12/2026, elige lunes–viernes y devuelve viernes 1/1/2027 y lunes 4/1/2027; el 1 de enero se conserva porque es un día elegido. La UI etiqueta la selección `Laborables (lunes a viernes)` y aclara que no excluye feriados. El worker semanal toma el patrón persistido y las mismas funciones de calendario/conteo que usa el preview. | **PASS automático** para selección, preview y ejecución local. No existe calendario de feriados en este alcance. No se hizo recorrido visual manual. |
| N cuenta fechas efectivas, no completados; completar tarde no desplaza la fase; probar año/zona. | La serie lunes/miércoles desde 28/12 cuenta cuatro fechas efectivas hasta 13/1/2027. El worker materializa fechas semanales vencidas, conserva la fase y cuenta una fecha excluida sin reponerla. Otra tarea con fecha inicial 5/1/2026 se completa tarde con timestamp sintético 5/11; el worker con reloj 20/11 materializa 9/11, conserva conteo calendario 23 y programa 23/11. Dos tableros sintéticos con `Pacific/Kiritimati` y `America/Los_Angeles` reciben el mismo instante UTC: Kiritimati avanza en su 1/1 local; Los Ángeles espera y avanza al alcanzar su medianoche local. | **PASS automático** con reloj y zonas controlados en PostgreSQL local. El worker se ejecuta por las funciones durables de claim/process con claim sintético `service_role`; esto no verifica un host externo. |
| Evidencia por criterio, versión, fixture/actor y entorno; mensajes en español y estados accesibles. | Esta matriz registra fecha, patrón, actores sintéticos, entorno y comandos. La UI usa etiquetas, `fieldset`/`legend`, controles nativos, mensajes `aria-live`, preview, confirmación, estados de error y reintento de la misma operación. `node --experimental-strip-types --test tests/unit/daily-repetition-state.test.mjs`, `pnpm typecheck`, `pnpm build` y Biome focal pasan. | **PARCIAL:** comprobación automática y revisión de código disponibles; navegador, lector de pantalla y dispositivo no se verificaron con fixture local sintético. El host/cron sigue separado como bloqueo externo. |
| Conservar C-01–112 y todas las P/E; las menciones antiguas de pendiente no reabren alcance. | La migración amplía el modelo de repetición existente y usa el flujo de permisos, conversión, historial, receipts y worker de #23. La suite DB completa recorre migraciones y regresiones existentes. El diff no modifica contratos, etiquetas ni estados de otros issues; no toca #23 ni #25. | **PASS automático** para regresiones locales. La aceptación humana de #23 y operación de host quedan pendientes; no se amplía la aceptación de ninguna dependencia. |

## Entorno y ejecuciones automáticas

- Windows worktree `codex/issue-24`; Node.js `v24.14.1`, pnpm `11.3.0`, Next.js `16.4.2`, PostgreSQL `16.15`.
- `wsl.exe -d Ubuntu --cd /mnt/c/Users/gasto/.codex/worktrees/openkanban-issue-24/open-kanban --exec bash scripts/test-db-issue-23.sh` — **PASS**. Crea un clúster temporal PostgreSQL y aplica las migraciones hasta `041_weekly_repetition.sql`; ejecuta `tests/db/daily_repetition.sql` con usuarios `example.test`, UUID sintéticos, claims locales y reloj/zona inyectados.
- `pnpm test:db` — **PASS** en la repetición completa sobre esta rama. La primera ejecución falló una vez en la preexistente `tests/db/task_recovery.sql:83`: su lectura de elegibilidad devolvió `2026-11-02T00:38:14.251424Z` frente a `deleted_at=2026-11-02T00:38:15.409328Z` (1.157904 s anterior). No se modificó la prueba ni el modelo de recuperación. La repetición completa con 041 pasó; una ejecución completa del worktree `codex/issue-23` sin 041 también pasó y no reprodujo la diferencia.
- `pnpm test:unit` — **PASS**, 166 tests, 0 fallidos.
- `pnpm exec next typegen` — **PASS**, generó declaraciones/tipos locales de Next.
- `pnpm typecheck` — **PASS**.
- `pnpm build` — **PASS** con Next.js 16.4.2: compilación, TypeScript, datos de páginas y optimización terminados.
- `pnpm exec biome check` sobre los cinco archivos TS/TSX/MJS cambiados — **PASS**, sin correcciones pendientes. `git diff --check` — **PASS**.
- `pnpm lint` global — **FAIL preexistente de formato**: 187 diagnósticos `Formatter` en el repositorio, con diferencias LF/CRLF que también aparecen en archivos y configuraciones no modificados. No se reformateó el repositorio completo; los cinco archivos de código cambiados sí pasan el chequeo focal.

## Pendientes manuales y externos

- **Manual pendiente:** no se abrió navegador autenticado ni se hizo recorrido visual, lector de pantalla o dispositivo. No había fixture de navegador local sintético listo para este flujo; la compilación y el markup semántico no sustituyen esa revisión.
- **Host pendiente:** no se configuró ni verificó cron/worker fuera del clúster descartable. Las pruebas prueban el motor durable SQL local, no operación autónoma desplegada.
- **G03 pendiente:** no se declara terminado el catálogo/calendario global, ni se prueba alcance de #25.
- **Límites de ejecución:** no se usaron `.env.local`, credenciales, OAuth/bypass, usuarios/datos reales, SQL remoto, `main`, producción ni deploy. No se publicó ni se cerró ningún issue.
