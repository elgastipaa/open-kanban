# Issue #9 — evidencia de implementación

Fecha: 31/10/2026. Issue: «Mover y ordenar sin perder ediciones». Rama: `codex/issue-9`. Base fija: `03f3daf31ae38470603eef3ad5740234eaa70471`. Commit de código: `92df01ca18ff64a82581202dbb7c0e410a91c565`.

La entrega mantiene #9 abierto. Las comprobaciones visuales con navegador aún requieren recorrido humano, por lo que el estado esperado es `ready-for-human`; no se infiere aceptación ni se cambia el issue desde esta rama.

## Entorno y límites

- `pnpm test:db` aplica las migraciones en un clúster PostgreSQL 16.15 descartable creado por `scripts/test-db.sh`. No consume `DATABASE_URL`, `.env`, `.env.local` ni credenciales externas.
- Las fixtures usan actores sintéticos: propietario `40000000-0000-4000-8000-000000000002`, colaborador `40000000-0000-4000-8000-000000000005` y administrador global no miembro `40000000-0000-4000-8000-000000000001`. Las pruebas asignan claims PostgreSQL y ejecutan RPC bajo `authenticated`; no crean una sesión HTTP Supabase Auth ni ejercitan PostgREST.
- Interfaces TDD registradas: base/servidor real aislado (ejecutada con PostgreSQL descartable y RPC), navegador (aprobada, sin runner ya instalado en el repo), y reloj controlado (no necesaria para ordenar tareas). No se instalaron dependencias de navegador.
- No se usaron OAuth, cuentas/datos reales, instancia #4/#6, producción, permisos debilitados ni migraciones remotas. #8 permanece abierto; esta implementación consume sus contratos de campo/versiones sin recrearlos ni globalizarlos.

## Criterios y evidencia

| Criterio | Estado | Evidencia y límite |
| --- | --- | --- |
| Mover/reordenar solo dentro del mismo tablero, validando origen, destino y anclas | **Probado en DB** | Cada movimiento lleva `source_column_id`, destino y vecinos anterior/posterior. La función verifica membresía/generación activa y rechaza una solicitud que mezcle tableros antes de mutar cualquier tarea. Anclas vacías, al inicio/final y vecinos contiguos se comprueban con la orden resultante; anclas obsoletas o no contiguas devuelven `conflict`. |
| Orden independiente de campos y contenido intacto | **Probado en DB** | `columns.task_order_version` y `task_order_receipts` son independientes de `field_versions` y los recibos #8. La regresión compara la tarea completa salvo `column_id`, `position` y `updated_at`, comprueba versiones de campos idénticas, y verifica que solo avancen las versiones de las columnas tocadas. La escritura del movimiento modifica `column_id`/`position`; no envía título, descripción, prioridad ni un objeto de tarea como autoridad. |
| Movimiento de lote y rechazo de cruces parciales | **Probado en DB** | Un lote mueve tareas entre varios pares de columnas del mismo tablero en una sola operación. Una tarea con destino externo invalida el lote y las pruebas comparan columnas y versiones para comprobar que no haya efectos parciales. |
| Ediciones pendientes: Guardar, Descartar o Cancelar antes de mover | **Unitario; interacción pendiente** | `TaskModal` solicita la decisión C-95 antes de mover. Solo un guardado `confirmed` o un descarte explícito continúa; Cancelar vuelve a la edición. Error, conflicto, resultado incierto o expiración conservan el detalle y no inician el movimiento. `task-edit-workflow.test.mjs` verifica la condición de seguimiento. El flujo DOM/Auth real no se recorrió en navegador. |
| Conflicto de orden y concurrencia exigen revisión, sin sobrescritura silenciosa | **Probado en DB** | `scripts/test-db.sh` mantiene bloqueado el tablero y lanza dos sesiones `authenticated` con versiones/anclas comunes y operation IDs distintos. Una confirma un lote de dos movimientos; la otra recibe `conflict` porque el origen capturado ya no coincide y no mueve parcialmente ninguna tarea. Cliente y modal refrescan el orden autorizado y piden elegir de nuevo. |
| Reintentos, replay, colisión y recibo vencido | **Probado en DB; recorrido cliente parcial** | Replay confirmado devuelve el recibo original sin incrementar nuevamente el orden; una clave con carga distinta se rechaza; al vencer un recibo, la RPC devuelve `expired_unknown` sin reaplicar. Ante resultado incierto/retryable/expirado, el cliente detiene el movimiento y lee el tablero autorizado antes de permitir una nueva elección. El fallo de red HTTP real no se simuló. |
| Controles de teclado/móvil y etiquetas accesibles | **Código revisado; navegador pendiente** | Las tarjetas presentan acciones subir/bajar con nombres accesibles en español; las tarjetas móviles permiten elegir destino y tienen las mismas acciones de orden. El detalle permite seleccionar otra columna con teclado. El arrastre existente sigue disponible en escritorio. Falta verificar foco visible, secuencia de tabulación, zoom 200 %, movimiento reducido, lector de pantalla y presentación táctil real. |
| Retorno estable de foco y cambios remotos | **Parcial; navegador pendiente** | El detalle captura tarea/columna/posición de origen y, al cerrarse, usa el selector existente para volver a la tarea original, vecina, columna o tablero. Las reconciliaciones remotas no invocan foco programático. Reordenar puede cambiar el DOM entre columnas; se necesita confirmar el retorno y que Realtime no robe foco con navegación humana. |
| Permisos e aislamiento | **Probado en DB** | `anon` no puede ejecutar la mutación. Miembro activo puede mover en el tablero autorizado; admin global sin membresía no recibe acceso a contenido. La mutación valida origen y destino en el tablero/generación activos y no acepta campos protegidos. Auth HTTP/PostgREST real queda pendiente. |
| C-95, P01/P07–P09/P17/P18 relevantes | **Implementado con parcial explícita** | Se conserva el detalle/captura de origen y la decisión Guardar/Descartar/Cancelar; el contrato de mutación está limitado a origen/destino/anclas/versiones. UI móvil, teclado, foco y cambios remotos se reservan para recorrido humano según los límites anteriores. Las revisiones Spec/Standards contra la base fija quedan a cargo del coordinador sobre el HEAD ya comprometido. |

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `pnpm test:db` | Pasa en PostgreSQL 16.15 descartable. Incluye #3/#8 y regresiones de orden, permisos, replay, anclas, lote y carrera concurrente de dos actores. |
| `pnpm test:unit` | Pasa: 23 pruebas, 0 fallas. Incluye anclas intra/intercolumna, destino vacío, versión de orden independiente, decisión de movimiento posterior a guardar/descartar y regresiones de captura/edición/foco. Node emite avisos de detección de módulo TypeScript existentes con `--experimental-strip-types`. |
| `pnpm exec next typegen` y `pnpm typecheck` | Pasan con Next.js 16.4.2; tipos generados localmente no se incluyen. |
| `pnpm build` | Pasa con Next.js 16.4.2; Turbopack compila, verifica TypeScript, genera páginas estáticas y finaliza la optimización. |
| Biome dirigido a archivos TS/TSX/MJS modificados | `biome check --line-ending=crlf` y `biome lint` pasan. |
| `bash -n scripts/test-db.sh` y `git diff --check` | Pasan. |
| Navegador, Auth/PostgREST HTTP y OAuth | Pendientes; no existe runner preinstalado y no se instaló uno. |

Hasta completar las comprobaciones humanas y las revisiones finales, #9 debe seguir OPEN/`ready-for-human`. Esta evidencia no autoriza cerrar #9, modificar relaciones, hacer merge a `main`, ni desplegar o migrar producción.
