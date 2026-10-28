# Issue #3: separar mover de editar una tarea

**Fecha:** 2026-10-28

**Base:** `1aea3ef2ebbfbc7b73d493c10b886daa2605775f`

**Entorno:** Node.js 24.14.1, pnpm 11.25.0, Next.js 16.4.2, Chrome 155.0.8059.40 y PostgreSQL 17.11.

## Resultado

- La migración `013_separate_task_edits_from_moves.sql` reemplaza la mutación combinada por `edit_task_fields_p` y limita `update_task_positions_p` a `id`, `column_id` y `position`.
- La edición recibe solo las claves explícitas. Una descripción omitida conserva su valor y `description: null` la borra.
- El movimiento devuelve las filas actuales para que el cliente que partió de una vista desactualizada muestre el contenido más reciente después de mover.
- El batch valida todas las entradas antes de actualizar; rechaza campos de contenido, tareas de otro tablero y batches inválidos sin aplicar cambios parciales.

## Evidencia

### Base de datos

`scripts/test-db.sh` se ejecutó como `postgres` desde una copia temporal dentro del contenedor local aislado y creó allí un clúster PostgreSQL descartable. Aplicó las migraciones 001–013. Pasaron las regresiones de edición/movimiento, descripción omitida y `null`, rechazo atómico de batches, límites entre tableros, RLS y concurrencia real.

La prueba concurrente retuvo el lock de una tarea en una transacción de edición mientras otra sesión iniciaba el RPC de movimiento. El movimiento esperó el lock; tras el commit de edición, ambas modificaciones quedaron presentes.

Resultado: `Database regression tests passed (disposable PostgreSQL).`

### Navegador

Se usaron dos páginas de Chromium contra la aplicación y Supabase locales, con un tablero ficticio `issue-3-browser-fixture`.

1. La página A cargó la tarea con título y descripción originales; se bloqueó su canal realtime para mantener la vista desactualizada.
2. La página B cambió título, descripción y prioridad desde el editor. La página A siguió mostrando los datos originales.
3. Desde A, el teclado movió la tarea de `Source` a `Done`. El RPC registrado incluyó únicamente `{id, column_id, position}`. La interfaz de A mostró los campos editados más recientes y una lectura directa de la base confirmó esos campos con la nueva columna.
4. En una ventana de 390 × 844, el control móvil `Move to` movió la misma tarea de vuelta a `Source`. Su RPC también incluyó únicamente `{id, column_id, position}`.

## Verificaciones

- `pnpm typecheck` — pasó.
- `pnpm exec biome lint next.config.ts src/lib/types.ts src/lib/validations.ts src/lib/db/tasks.ts src/hooks/use-board/use-task-operations.ts` — pasó.
- `pnpm lint` — Biome revisó 74 archivos y pasó después de normalizar temporalmente los finales de texto rastreados a LF.
- `pnpm build` — pasó con Next.js 16.4.2.
- `scripts/test-db.sh` sobre clúster PostgreSQL descartable — pasó.

El checkout volvió a sus finales de línea originales CRLF. Con `core.autocrlf=true`, el chequeo de formato de Biome sobre el checkout solicita LF, mientras los blobs del repositorio están en LF.
