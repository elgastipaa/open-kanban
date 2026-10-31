# Issue #7 — evidencia de implementación

Fecha: 31/10/2026. Issue: «Capturar tareas consecutivas sin duplicados». Rama: `codex/issue-7`. Base fija: `1312906108fa2a4815dd1a42cd5d889d04a16951`. HEAD de código (antes de este informe): `91c1040364dc3754f97432de79c05e18f200dfcd`.

Se conservó `Blocked by #6`. La autorización de secuencia permitió la implementación y pruebas locales con actores sintéticos; no satisface Auth/OAuth real ni permite cerrar #7.

## Entorno de verificación

- `pnpm test:db` aplica las migraciones 001–018 en un clúster PostgreSQL desechable creado por `scripts/test-db.sh`. La versión local disponible fue PostgreSQL 16.15. El script crea roles `anon` y `authenticated`, ejecuta migraciones, limpia el directorio temporal que él mismo creó y no consume `DATABASE_URL`, `PGHOST` ni credenciales externas.
- Los datos de prueba son sintéticos. El actor `40000000-0000-4000-8000-000000000002` crea y repite capturas; `40000000-0000-4000-8000-000000000001` prueba otra identidad, membresía revocada y consultas aisladas. Los actores y filas Auth solo existen en el clúster temporal.
- No se instaló Supabase CLI ni se probó PostgREST/Auth de extremo a extremo. No se leyó `.env` ni `.env.local`, no se usaron OAuth, sesiones reales, claves reales, personas reales ni producción.
- No hay runner de navegador headless preexistente. No se abrió Chrome/CUA ni se hizo login. El comportamiento visual, el teclado en navegador y la reconciliación en una sesión real quedan pendientes de recorrido manual.

## Criterios y evidencia

| Criterio | Estado | Evidencia y límite |
| --- | --- | --- |
| Crear solo al usar Enter o el botón, en la columna actual; blur no crea | **Parcial** | El formulario solo maneja Enter y el botón; se quitó el manejador `onBlur`. Sin runner de navegador, falta confirmar foco y eventos en escritorio/móvil. |
| Confirmación vacía el campo, mantiene la captura abierta y permite seguir en la misma columna | **Parcial** | El componente espera la confirmación del hook antes de vaciar y regenerar la operation_id, y vuelve a enfocar el input. Falta recorrido manual autenticado. |
| Ante fallo, conservar título y foco | **Parcial** | El hook rechaza la promesa sin limpiar el borrador; el componente conserva el texto y vuelve a enfocar el campo. No se probó visualmente con fallos PostgREST/red. |
| Resultado durable y consulta por operation_id | **Probado en DB** | `task_capture_receipts` conserva actor, clave, board/column/task y hash. La prueba descarta el resultado de la primera llamada y lo recupera con `get_task_creation_result_p`. |
| Replay idéntico devuelve el mismo task; distinta carga con la misma clave se rechaza | **Probado en DB** | `tests/db/task_capture.sql` compara el task id y prueba `23514` ante payload diferente, sin cambiar el número de tareas. |
| Vencimiento requiere reconciliación y evita reintento ciego | **Probado en DB; UI parcial** | Se vence la fila sintéticamente; consulta y replay devuelven `expired_unknown` y el conteo no cambia. Cliente consulta el tablero por el task id del recibo y nunca reenvía un recibo vencido. Falta confirmar este recorrido en navegador. |
| Doble envío y dos sesiones concurrentes crean una tarea | **Probado en DB; UI parcial** | El script retiene el row lock del board y ejecuta dos sesiones `authenticated` con la misma clave/carga; ambas obtienen el mismo task id y queda una receipt y una tarea. `pendingRef` evita doble submit en el componente; no fue verificado con navegador. |
| Respuesta perdida después del commit no duplica la tarea | **Probado en DB** | La primera respuesta se descarta deliberadamente; consulta por clave y replay identifican el task ya guardado. |
| Actor/autor derivados del servidor; validar tablero y columna actuales | **Probado en DB** | `created_by` coincide con `auth.uid()`. La función verifica membresía activa y columna perteneciente al board y a la generación activa; board/column cruzados se rechazan antes de insertar receipt/task. |
| Campos protegidos y cruces ajenos no producen escritura parcial | **Probado en DB** | La firma no acepta `created_by` ni `position`; el RPC legacy se elimina, `authenticated` no tiene INSERT directo y un intento directo con `created_by` falla sin agregar filas. Otro actor obtiene `not_found`; el miembro revocado obtiene `unavailable` sin el task ni el estado del hash. |
| Títulos vacíos rechazados; no deduplicar ni emparejar por título | **Probado en DB** | El título vacío se rechaza sin receipt. Dos operation_id distintas con el mismo título crean dos tasks consecutivas; el cliente resuelve por operation_id/task id, no por título. |
| Mensajes y controles nuevos cumplen P12 | **Parcial** | Los textos nuevos de captura, error y reconciliación están en español; falta revisar visualmente su presentación y accesibilidad en navegador. |
| Mantener contratos C-01–112 y P/E posteriores | **Pendiente de revisiones finales** | Se mantuvo la base fija y no se modificó alcance. El coordinador hará las revisiones Standards y Spec contra la base después de este commit. |

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `pnpm test:db` | Pasa en PostgreSQL desechable. Incluye migraciones 001–018, replay/respuesta perdida, payload conflictivo, expiración, validación board/column, autoría, acceso/revocación, escritura directa protegida y carrera entre dos sesiones. Exit code 0. |
| `pnpm test:unit` | Pasa: 2 pruebas existentes, 0 fallas. No reemplaza verificación de UI ni de PostgREST. |
| `pnpm exec biome check --write` sobre los 8 archivos TypeScript modificados | Pasa; sin fixes pendientes. |
| `bash -n scripts/test-db.sh` | Pasa. |
| `pnpm exec next typegen` seguido de `pnpm typecheck` | Pasa. Next 16.4.2 generó los tipos locales y `tsc --noEmit` terminó sin errores. `next-env.d.ts` es generado/ignorado y no se incluye en el commit. Se confirmó previamente que este checkout no contiene archivos `.env*`; no se inspeccionó su contenido. |
| Revisión UI/teclado en navegador con Auth sintético | No disponible: no hay runner headless. Pendiente manual; no se simuló con mocks. |
| Supabase Auth/PostgREST local | No verificado. La evidencia DB corresponde a funciones/migraciones ejecutadas directamente en PostgreSQL, no acredita una sesión HTTP/Auth real. |

## Recorrido pendiente

Cuando #6 permita una sesión sintética legítima y exista runner local de navegador, recorrer con dos actores de prueba: crear varias tareas con Enter y botón; comprobar que blur no envía; verificar foco, limpieza y misma columna tras cada confirmación; desconectar la respuesta luego del commit y reconciliar por operation_id; repetir con expiración mostrando `expired_unknown` sin reintento; probar error de permisos conservando título/foco y doble clic sin duplicado. Confirmar navegación móvil, teclado y anuncio accesible del estado.

Hasta verificar Auth/UI real y completar las revisiones Standards/Spec, #7 permanece abierto con `Blocked by #6` intacto. Estas pruebas locales no autorizan cierre, integración a `main` ni publicación.
