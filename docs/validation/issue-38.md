# Issue #38 — Evidencia de implementación

**Contrato:** E07 / C-109 / AC47–48 / CF-27.1.

**Base fija:** `705a245ea32d18e8e33d4bf2afbfd291079b36af`.
**Estado:** candidato local aislado en `codex/issue-38`; no integrado ni publicado. Issue #38 permanece abierto para sus gates humanos y conserva `Blocked by #37`.

## Implementación revisada

- La bandeja congela al pulsar los IDs sin leer presentes en las filas cargadas. No agrega páginas no vistas ni avisos que llegan después de esa captura. La acción muestra cuántas filas visibles marcará y no abre un diálogo.
- Cada ID termina como `marked`, `already_read`, `unavailable` o `failed`. El resumen contiene solo cantidades y no títulos ni datos de la notificación.
- El recibo actor/operación permite consultar el resultado de una respuesta perdida. Una repetición conserva el mismo `operation_id` y la lista original; SQL solo intenta de nuevo resultados `failed` y vuelve a comprobar la autorización de cada ID. Ante `GET not_found`, el cliente serializa una llamada `mark` con el mismo ID y lote: recupera el recibo si la operación previa terminó, o recibe el `not_found` inerte del guard SQL cuando realmente no existe recibo.
- Ante un `not_found` definitivo, la UI oculta títulos cacheados y refresca la primera página autorizada antes de soltar el lote viejo. Si ese refresh falla, conserva el bloqueo y deshabilita paginación; un refresh autorizado completo posterior completa la recuperación. Si falla la consulta del recibo, la UI conserva el lote en memoria y muestra «Comprobar resultado». No agrega una cola sin conexión ni genera otra operación a ciegas. Un recibo vencido devuelve `expired_unknown`; la UI oculta títulos cacheados y requiere una recarga autorizada antes de habilitar otro lote.
- Durante el lote, filtros, actualización, paginación y acciones por fila quedan deshabilitados para que el refresh de resultados conserve el filtro activo.
- Los recibos vencen a los **7 días**. Es una elección técnica basada en los recibos operativos existentes en el repo; C-109/CF-27.1 no fijan esa duración. El vencimiento no borra el tombstone de operación ni permite volver a ejecutar el lote incierto.
- La nueva tabla no permite lectura/escritura directa de `authenticated`; sus funciones devuelven IDs y estados por persona, sin guardar texto de novedades.

## Verificación automática

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-38` | PASS. 20 de 80, llegada posterior a la captura, replay/lookup, reintento fallido sin recibo (sin mutar ni guardar receipt), resultados mixtos, fallo sintético por fila, reintento solo de fallidas aún autorizadas, payload distinto, vencimiento y aislamiento del recibo por actor. |
| `pnpm test:unit:issue-38` | PASS, 15/15: snapshot, doble activación, cuatro resultados, reconciliación de timeout, `GET not_found` transitorio y final, refresh antes de liberar, filtros bloqueados, vencimiento, títulos privados y contrato UI/RPC. |
| `pnpm test:unit` | PASS. Suite unitaria completa más issue #38. |
| `pnpm test:db` | PASS. Suite DB completa sobre PostgreSQL descartable; ejecuta también los tres tracers de #38 tras los regresivos anteriores y la migración 063. |
| `pnpm exec next typegen` | PASS, Next.js 16.4.2. |
| `pnpm typecheck` | PASS. |
| `pnpm build` | PASS, Next.js 16.4.2 / Turbopack. |
| `pnpm exec biome check` sobre los 6 archivos TS/JS modificados | PASS. |
| `git diff --check` | PASS; Git informa que normalizará CRLF en dos archivos editados al próximo checkout/escritura. |

`pnpm lint` sobre todo el repo no pasa: Biome informa 260 diagnósticos de formato en el checkout. Un archivo de base no modificado (`src/app/page.tsx`) reproduce el mismo diagnóstico de formato CRLF/LF; los seis archivos TS/JS de este cambio pasan la comprobación dirigida. No se formatearon archivos ajenos al ticket.

## Gates aún pendientes

- **Pendientes:** browser, inicio de sesión real, permisos con cuentas reales, revisión visual, móvil responsive, accesibilidad manual y aceptación humana.
- La ejecución sintética de base de datos no verifica el cron/worker externo de limpieza u operación; esa infraestructura queda por confirmar.
- El issue no se cierra ni se da por aceptada su QA humana.
