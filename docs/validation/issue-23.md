# Validación del issue #23 — Repetir diariamente con ejecución durable

## Alcance y estado

Base fija: `9e90d2fd7749b092af83cabcd9c3938e9908cf1c`. Rama: `codex/issue-23`. El trabajo implementa conversión y preview, ocurrencias diarias, outbox/worker SQL durable, diagnóstico, recuperación tras inactividad y purga coordinada con el registro de recuperación existente.

Commit de código candidato: `75d9699b51c04fe122ebba17b1f0224931bd6cba` (`feat: add durable daily repetition (#23)`).

La regla semanal de C110-AC49 se calcula en el mismo helper canónico que usa el preview diario y tiene una regresión sintética. No hay selector ni regla semanal persistida en esta entrega; el ticket #24, que depende de #23, añade la programación semanal. C110-AC50 se prueba para una serie diaria con conteo y exclusión. No se afirma cobertura de quinto lunes ni de ejecución semanal persistida.

El issue #23 continúa **OPEN**. Se conservan `Blocked by #11`, `#14` y `#15`, todos OPEN/`ready-for-human`; su código/evidencia integrados no se aceptan en nombre de una persona. El host/cron de despliegue sigue pendiente y no se configuró. El flujo de archivos/adjuntos aún no existe en el repositorio; la identidad distinta por `task_id` evita que una ocurrencia nueva reasigne/copíe asociaciones, pero la retención por origen no puede probarse hasta que exista ese modelo.

## Criterios y evidencia

| Criterio de #23 | Evidencia reproducible | Resultado y límite |
| --- | --- | --- |
| Convertir conserva la tarea como primera ocurrencia; inicio explícito; final inclusivo, N o sin final; preview canónico. | `tests/db/daily_repetition.sql`: preview diario con reloj de base y `America/Argentina/Buenos_Aires`; el preview semanal AC49 usa inicio miércoles 4/11/2026, cada 2 semanas, lunes y miércoles, y devuelve 16/11 y 18/11 sin 9/11. Conversión con fecha incompatible requiere confirmación, conserva la misma `task_id`, cuenta la actual en N y reintentar la misma operación no duplica serie/job. | **PARCIAL.** La experiencia y persistencia son diarias. AC49 queda reproducido en el helper compartido de preview; no se persisten reglas semanales en #23. AC50 se prueba como conteo diario inclusivo y una exclusión no extiende el final; quinto lunes y catálogo completo quedan para #24/#25 y G03. |
| Al llegar la siguiente fecha se reemplaza solo la vigente y se heredan campos/pasos sin completarlos; conversaciones/archivos quedan por origen. | La regresión adelanta el reloj SQL al día siguiente, comprueba una sola ocurrencia nueva, la anterior reemplazada, título/columna heredados, pasos regenerados sin completar, comentario original ligado a la tarea de origen y cero comentarios en la tarea nueva. | **PARCIAL.** Conversaciones/comentarios pasan en PostgreSQL aislado. No existe tabla ni flujo de adjuntos en esta rama/base, por eso archivos quedan sin verificación; no se inventó su subsistema. |
| Jobs atómicos con lease/dedupe/revisión, reintentos, diagnóstico y reconciliación sin acumulación de atrasos. | `tests/db/daily_repetition.sql`: crea job con conversión; reemplaza lease vencido y rechaza token viejo; repite la respuesta del worker sin duplicar; induce fallo FK y prueba rollback + `retry_wait`; el diagnóstico autorizado expone SQLSTATE/contador sin texto privado; después de inactividad crea solo la última fecha válida 8/11 y finaliza. | **PASS** para el worker SQL y reloj controlado local. El dead-letter conserva código/estado; la operación y política de revisión del host permanecen fuera de esta comprobación. |
| Avance sin navegador; caída y recuperación; host/cron externo sin falsa aprobación. | El fixture llama claim/process con rol sintético `service_role` y tiempos inyectados en PostgreSQL, sin abrir navegador. | **PARCIAL.** El motor funciona sin navegador en pruebas. No se verificó un host/cron real y no se desplegó; queda bloqueo externo explícito. |
| Purga de tareas/pasos vencidos sin revivir hijos y sin borrar antes de siete días. | Prueba de `purge_daily_repetition_tasks_internal_p`: a 167h59m no purga; a 168h purga tarea/ocurrencia y el tombstone del paso borrado, de forma atómica. | **PASS** para tareas y pasos de #14/#15 en base desechable. Adjuntos no tienen modelo disponible y no se declaran cubiertos. |
| Evidencia reproducible, mensajes en español y estados/error accesibles. | UI integrada en `TaskModal`, preview/confirmación, fecha excepcional con `P2301` y máximo seguro visible junto al campo, reintento de operación incierta y diagnóstico con `aria-live`; tests unitarios de intención incierta. Biome, TypeScript y build pasan. | **PARCIAL.** La evidencia automática pasa. No se hizo recorrido manual autenticado, lector de pantalla o dispositivo; no se fabricó una sesión. |
| Conservar contratos posteriores y límites de acceso; no ampliar aceptación humana de dependencias. | La suite completa de base recorre migraciones/regresiones existentes y `tests/db/daily_repetition.sql` usa solo actores `example.test`/UUID sintéticos. No se modificaron #11/#14/#15 ni etiquetas de issues. | **PASS** para regresión automatizada local. La aceptación humana de las dependencias y del host sigue pendiente. |

## Entorno y ejecuciones automáticas

- Worktree: `C:\Users\gasto\.codex\worktrees\openkanban-issue-23\open-kanban`; base y rama indicadas arriba. Node.js `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, PostgreSQL `16.15`.
- `pnpm test:db:issue-23` — PASS. `scripts/test-db.sh` crea un clúster PostgreSQL temporal local, aplica migraciones 001–040 y elimina el directorio desechable al terminar. El test usa actor de aplicación sintético, claims locales, reloj `p_now` controlado y zona IANA; no consume `DATABASE_URL`, `.env.local`, PGHOST/PGPASSWORD ni credenciales.
- `pnpm test:db` — PASS, suite completa en el mismo tipo de clúster desechable; incluyó regresiones de permisos, restauración/purga, comentarios, checklist, fechas, concurrencia y versiones.
- `pnpm test:unit` — PASS, 166 tests, 0 fallidos.
- `pnpm build` — PASS con Next.js 16.4.2/Turbopack; compilación, TypeScript, páginas y trazas terminadas.
- `pnpm typecheck` — PASS después del build, que generó los tipos de Next locales.
- `pnpm exec biome check` — PASS en 11 archivos TS/TSX/JSON/MJS cambiados. `git diff --check` — PASS.
- TDD por rebanadas: pruebas focales inicialmente rojas por falta de preview/worker durable; AC51 fue roja al exigir SQLSTATE/detail contextual y quedó verde con `P2301`; restaurar en columna destino fue roja hasta sincronizar plantilla/revisión/job; AC49 fue roja hasta compartir el helper canónico de preview. La ejecución focal final y la suite completa quedaron verdes.

## Revisión manual y bloqueos

- **No realizada:** flujo visual con usuario autenticado, cambio de fecha excepcional en navegador, accesibilidad con lector de pantalla/dispositivo y programación semanal persistida. El código se compiló; esto no sustituye la aceptación manual.
- **Bloqueo externo:** host/cron de despliegue no está configurado/verificado. La publicación de jobs SQL por sí sola no prueba ejecución operativa autónoma en una instancia.
- **Dependencias humanas:** #11, #14 y #15 siguen OPEN/`ready-for-human`; esta validación local no cambia su estado.
- **Límite de producto/modelo:** no existe almacenamiento/flujo de adjuntos en el repositorio. El criterio de conservar archivos por origen no tiene fixture verificable todavía.
- **Límite de calendario:** el preview AC49 está probado; selector, persistencia y ejecución semanal pertenecen a #24. Patrones mensuales/anuales/ordinales y el caso de quinto lunes no se declaran probados aquí.
- No se usaron OAuth real/bypass, datos personales, `.env.local`, navegador autenticado, SQL remoto, producción, despliegue, `main`, push ni cambios de estado en issues.
