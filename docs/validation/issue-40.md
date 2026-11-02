# Issue #40 — Evidencia de implementación

**Contrato:** `CIERRE-MVP-1.0.md` CF-16/CF-17; `DISENO-TECNICO-MVP-1.0.md` §7/G04; `SPEC-OPENKANBAN-1.0.md` P16/P21/P22; `PANTALLAS-MVP-1.0.md` UI-05 y almacenamiento admin. Se conservaron los acuerdos C-01–112. La limpieza del ciclo de vida de tareas sigue CF-12 y la restauración administrativa CF-03.

**Base fija:** `95a57afc2bc70b76012cc81086ac2bf55a083095` (`codex/openkanban-1-0`).
**Commits de código incluidos hasta el HEAD revisado:** `b64481ed5da52a68abb08b6f417ee754797658ec` (`feat: add private task attachments (#40)`), `eee9aecfcbb64eb52f27741b3cdfb45516d981f7` (recuperación admin/paginación/ciclo de tarea), `349da6cc976f55f24a789ab44f80934ce2c057d9` (`fix: reconcile missing task attachment objects (#40)`) y `1d287070ad5cd149157d7d5d6d98fca0f084a3e8` (inventario exacto/completo para confirmar ausencia).
**Estado:** commits locales en `codex/issue-40`; no se publicaron ni integraron. El issue y sus bloqueos `Blocked by #14/#17/#23` no se modificaron.

## Alcance implementado

- La reserva valida extensión `.txt`/`.md`, UTF-8 válido, contenido inerte y límite inclusivo de 24.000 bytes. Las reservas participan del límite de 20 adjuntos por tarea y de la cuota global decimal de 200.000.000 bytes.
- La publicación y la descarga vuelven a autorizar al actor en el servidor. Los objetos permanecen privados y la clave no se puede elegir desde el cliente. La evidencia de almacenamiento real se mantiene pendiente; los tests de DB no simulan esa integración.
- El borrado individual conserva la cuota durante 7×24 horas. La restauración vuelve a usar el objeto existente sin una segunda reserva ni cargo. El worker solo libera cuota tras borrar el objeto y confirmar su ausencia mediante inventario completo/no ambiguo; una lista saturada o fallida conserva la cuota.
- Ante un `StorageApiError` 404 en una descarga autorizada, el servidor consulta el inventario del directorio usando límite 2 y búsqueda UUID. Solo marca `missing` cuando la consulta termina sin error, no satura el límite y la clave completa `attachments/{id}` no aparece. Así, un bucket ausente, inventario parcial o falla de red no se toma por ausencia del objeto. La transición es idempotente tras revalidar actor/tablero/tarea; la fila se oculta, la interfaz muestra un diagnóstico en español sin nombre ni clave y la cuota queda pendiente hasta la confirmación del worker.
- Borrar una tarea marca sus adjuntos activos con el tombstone de la tarea; restaurar la tarea recupera únicamente esos adjuntos cuando siguen dentro del plazo. Los hijos borrados individualmente conservan su actor y vencimiento. Purgar la tarea no libera prematuramente la cuota de un adjunto expirado pendiente de confirmación de Storage.
- La recuperación administrativa comprueba el tablero, la tarea y el propietario vigentes. El listado administrativo devuelve solo metadatos y pagina con cursor estable para no omitir elementos elegibles. La limpieza individual conserva confirmación y registro de auditoría existentes.
- La interfaz ofrece mensajes en español y estados de reintento/continuación para adjuntos; el diagnóstico visible no incluye contenido del archivo ni secretos. El panel de cuota global y sus avisos de umbral/UI-13 quedan fuera de #40 y corresponden a #41.

## Criterios y evidencia automática

| Criterio | Resultado automático | Límite de la evidencia |
| --- | --- | --- |
| Límites de tamaño, formato/texto UTF-8, reservas, concurrencia y permisos en las transiciones | PASS en pruebas unitarias y de PostgreSQL descartable de #40. | La interfaz de Storage real no se inició. |
| Confirmación de ausencia tras descarga 404 o limpieza Storage | PASS en #40: las unitarias del helper prueban NoSuchKey/404, NoSuchBucket, 404 genérico, objeto exacto presente, coincidencia parcial por substring y lista saturada. El mismo helper exact-key/inventario completo protege el diagnóstico y la confirmación de purga. El contrato DB valida transición autorizada/idempotente, ocultar la fila y retener cuota hasta confirmación. | No se ejecutó el handler HTTP contra Storage ni navegador para comprobar la actualización tras 410; tampoco se probó eliminación real. Todo esto sigue pendiente. |
| Borrado suave, retención de cuota, restauración sin cargo duplicado y expiración | PASS en contratos DB, incluidos reintentos/estados y retención. | La eliminación/confirmación física se cubre en código y se deja como gate de Storage real. |
| Autorización vigente al restaurar desde administración | PASS: el restore con tablero no disponible se deniega; al restablecer el contexto válido, la operación autorizada se recupera de forma idempotente. | No se usaron cuentas de Auth reales. |
| Ciclo de adjuntos al borrar/restaurar/purgar una tarea | PASS: solo los adjuntos eliminados por el padre vuelven; el borrado individual conserva su plazo; la cuota del hijo purgado se retiene hasta su limpieza confirmada. | La confirmación contra Storage queda pendiente. |
| Listado de limpieza admin completo, paginado y privado | PASS: contrato DB con más de una página, cursor sin duplicados y datos de metadatos; parser unitario cubre cursores ausentes, inválidos/parciales y precisión temporal. | El recorrido visual y con lector de pantalla queda pendiente. |
| Errores/reintentos y diagnósticos seguros | PASS en unitarias de helpers HTTP/Storage, parser admin y estado de notificación; el contrato DB valida permisos y transiciones. | No se ejecutaron los handlers HTTP contra Storage real, ni se hizo una prueba visual o de navegador. |

## Revisión de código

HEAD de código revisado: `1d287070ad5cd149157d7d5d6d98fca0f084a3e8`. Las revisiones independientes de spec y estándares/seguridad terminaron **PASS**, sin hallazgos accionables/bloqueantes. No ejecutaron pruebas ni modificaron archivos; la evidencia automática indicada arriba proviene de los comandos registrados abajo.

## Entorno y verificaciones

Desarrollo local en Windows/PowerShell; Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2` y PostgreSQL `16.15` descartable. La suite DB crea actores/cuentas/Auth/identidades, tableros y adjuntos sintéticos dentro de esa base aislada; no se usaron Auth ni cuentas reales. No se leyeron archivos `.env`, ni se usaron datos reales, producción o Supabase remoto.

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-40` | PASS; contratos DB focales de adjuntos, ausencia confirmada, autorización, cuota, restore admin, paginación y ciclo de vida de tarea. |
| `pnpm test:db` | PASS; suite DB completa sobre PostgreSQL descartable, incluidas las migraciones 065 y 066. |
| `pnpm test:unit:issue-40` | PASS, 17/17; validación, parser HTTP, respuesta 410 segura, clasificación de errores Storage, inventario exacto/completo, cursor y avisos admin. |
| `pnpm test:unit` | PASS; suite unitaria completa e issues #33–#40, incluidos 17/17 de #40. |
| `pnpm typecheck` | PASS. |
| `pnpm build` | PASS, Next.js 16.4.2; compilación, TypeScript y 17 páginas/rutas. |
| `pnpm exec biome check` dirigido a los archivos de código de #40 | PASS; sin cambios automáticos. |
| `git diff --check` | PASS. |

`pnpm lint` se ejecutó antes de la corrección 065 y falló en el chequeo de formato global del checkout por diagnósticos CRLF/LF en numerosos archivos; no se reformateó código ajeno a #40. La comprobación Biome dirigida de los archivos de este cambio sí pasa.

## Gates pendientes

- **Storage real:** no se pudo levantar el servicio local de Storage; Windows denegó iniciar `com.docker.service`. No se intentó elevar permisos. Quedan pendientes la subida/descarga real, objeto privado, fallos de borrado y confirmación real de ausencia.
- **Worker/cron:** no se verificó su programación ni una ejecución contra Storage real. La prueba DB verifica las transiciones y reclamación del trabajo, no la infraestructura externa.
- **Navegador y QA humana:** quedan pendientes recorridos visuales, teclado/lector de pantalla y móvil/responsive con una sesión autorizada.
- No se infieren de estas pruebas credenciales, Auth real, funcionamiento de servicios externos ni aceptación humana. El issue permanece abierto con `Blocked by #14/#17/#23`.
