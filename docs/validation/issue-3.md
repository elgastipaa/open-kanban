# Issue #3: separar mover de editar una tarea

**Fecha:** 2026-10-28–29

**Base:** `1aea3ef2ebbfbc7b73d493c10b886daa2605775f`

**Entorno:** Node.js 24.14.1, pnpm 11.25.0, Next.js 16.4.2 y Chrome 155.0.8059.40. Las pruebas de navegador usaron Supabase local con PostgreSQL 17.11; la corrida final de `scripts/test-db.sh` usó PostgreSQL 16.15 en WSL.

## Resultado

- La migración `013_separate_task_edits_from_moves.sql` reemplaza la mutación combinada por `edit_task_fields_p` y limita `update_task_positions_p` a `id`, `column_id` y `position`.
- La edición recibe solo las claves explícitas. Una descripción omitida conserva su valor y `description: null` la borra.
- El movimiento devuelve las filas actuales para que el cliente que partió de una vista desactualizada muestre el contenido más reciente después de mover.
- El ledger mantiene separadas las filas confirmadas y las intenciones optimistas pendientes. Al confirmar o fallar una petición, vuelve a proyectar solo las intenciones que siguen pendientes, sin restaurar snapshots de todo el tablero. Las respuestas de refresh y de verificación de una creación usan revisiones para descartar resultados atrasados.
- Las respuestas retrasadas no recuperan tareas borradas; las creaciones pendientes conservan su intención explícita de borrado, y los movimientos en cola remapean IDs temporales y quitan solo tareas borradas del batch. Los refreshes que cruzan un commit local se descartan.
- La migración `014_monotonic_task_updated_at.sql` asigna a cada escritura de una tarea un `updated_at` posterior al valor anterior, incluso cuando la transacción que actualiza la tarea empezó antes que otra escritura concurrente.
- El batch valida todas las entradas antes de actualizar; rechaza campos de contenido, tareas de otro tablero y batches inválidos sin aplicar cambios parciales.

## Evidencia

### Base de datos

Antes de agregar la migración 014, las migraciones 001–013 y los escenarios de navegador se comprobaron contra el Supabase local aislado (PostgreSQL 17.11). La corrida final de `scripts/test-db.sh` aplicó 001–014 como `postgres` en un clúster descartable de PostgreSQL 16.15 en WSL. Para Bash se usó una copia LF temporal del runner, sin normalizar el archivo rastreado. Pasaron las regresiones de edición/movimiento, descripción omitida y `null`, rechazo atómico de batches, límites entre tableros, RLS y concurrencia real.

La prueba concurrente retuvo el lock de una tarea en una transacción de edición mientras otra sesión iniciaba el RPC de movimiento. El movimiento esperó el lock; tras el commit de edición, ambas modificaciones quedaron presentes.

Una segunda prueba abrió primero una transacción que esperó seis segundos antes de mover la tarea. Durante la espera, otra sesión editó y confirmó título, descripción y prioridad. El movimiento conservó esos campos y dejó `updated_at` después del timestamp de la edición, según el orden efectivo de escritura.

Resultado: `Database regression tests passed (disposable PostgreSQL).`

### Navegador

Se usaron dos páginas de Chromium contra la aplicación y Supabase locales, con un tablero ficticio `issue-3-browser-fixture`.

1. La página A cargó la tarea con título y descripción originales; se bloqueó su canal realtime para mantener la vista desactualizada.
2. La página B cambió título, descripción y prioridad desde el editor. La página A siguió mostrando los datos originales.
3. Desde A, el teclado movió la tarea de `Source` a `Done`. El RPC registrado incluyó únicamente `{id, column_id, position}`. La interfaz de A mostró los campos editados más recientes y una lectura directa de la base confirmó esos campos con la nueva columna.
4. En una ventana de 390 × 844, el control móvil `Move to` movió la misma tarea de vuelta a `Source`. Su RPC también incluyó únicamente `{id, column_id, position}`.
5. En otra página, el servidor aplicó un movimiento y retuvo su respuesta. Antes de liberarla, la misma página editó título, descripción y prioridad. La edición quedó en cola; después de liberar la respuesta del movimiento, la interfaz y la base conservaron los nuevos campos en `Done`.
6. Se retuvo el movimiento siguiente y se respondió con un 500 simulado. Mientras esperaba, la página editó la tarea. Al fallar el movimiento, la tarea volvió a `Source`; la edición encolada quedó visible y persistida.
7. Se retuvo una edición y se respondió con un 500 simulado mientras la página movía la tarea. La edición falló, pero el movimiento encolado terminó en `Done` y la base conservó los campos originales.
8. Se retuvo un movimiento y se respondió con un 500 simulado mientras se eliminaba una tarea hermana. El rollback devolvió la tarea a `Source` delante de la hermana restante; la interfaz y la base conservaron el orden `Fixture task`, `Third task` y la tarea eliminada no volvió.
9. Se retuvo una edición optimista, se inició una segunda edición de la misma tarea y se respondieron ambas con 500. La interfaz volvió al título, descripción y prioridad confirmados; la consulta directa confirmó que la base no recibió ninguna de las dos ediciones.
10. Se retuvo un movimiento y se eliminó optimistamente una tarea hermana. El movimiento y el borrado fallaron; la interfaz volvió al orden `Fixture task`, `Neighbor task`, `Third task`, y una consulta directa confirmó las tres tareas en `Source` con posiciones 0, 1 y 2.
11. Se retuvo un movimiento que falló y se encoló una edición de la misma tarea. La edición llegó después del fallo; la interfaz y la base conservaron el título, descripción y prioridad nuevos en `Source`.
12. Se retuvo una edición que falló y se encoló un movimiento. El movimiento llegó después del fallo; la interfaz y la base conservaron los campos originales en `Done`.
13. Se retuvo la respuesta de un movimiento después de que el servidor lo aplicó. Un segundo cliente editó la tarea y emitió realtime; la primera página actualizó sus campos mientras la respuesta seguía retenida. Al liberar la respuesta antigua, la interfaz y la base conservaron el título, descripción y prioridad más recientes en `Done`.
14. Se retuvo un movimiento que falló mientras el borrado de una tarea hermana sí se completó. El rollback conservó `Fixture task` y `Third task` en `Source`; la tarea eliminada no reapareció.
15. Se retuvo la respuesta de creación después de que el servidor guardó una tarea nueva. Antes de liberarla, se movió la tarjeta local a `Done`. El RPC de posiciones encolado incluyó el ID persistido de la tarea nueva y una consulta directa confirmó que quedó en `Done`.
16. Se retuvo la respuesta exitosa de un movimiento y un segundo cliente borró esa tarea. La primera página la quitó al recibir realtime y no la recuperó al liberar la respuesta; la base confirmó que seguía borrada.
17. Se retuvo el primer refresh realtime con una edición externa, luego se permitió completar el refresh de una segunda edición. Al liberar el primer resultado atrasado, la interfaz conservó la segunda edición.
18. Se repitió la edición externa durante un movimiento retenido con respuestas de red que diferían únicamente en 1 μs (`.123455` y `.123456`) dentro del mismo milisegundo. La interfaz conservó el título y descripción recientes después de liberar la respuesta anterior; una lectura directa confirmó los campos en `Done`.
19. En un tablero nuevo se retuvo la respuesta de creación del tablero después del commit. Se añadieron dos tareas temporales y se reordenaron antes de liberar esa respuesta. Al terminar la cola, el RPC de posiciones incluyó ambos IDs persistidos y la columna creada; la consulta directa confirmó `Local second` en posición 0 y `Local first` en posición 1.
20. Se retuvo una creación de tarea después del commit, se eliminó la tarjeta temporal antes de liberar la respuesta y la cola llamó al RPC de borrado con el ID persistido. La tarjeta no reapareció y una lectura directa confirmó que la fila no existía.
21. Se retuvo un refresh externo anterior a un movimiento local exitoso. Al liberar el snapshot después del commit, la interfaz y la base conservaron la tarea en `Done`.
22. Se retuvo una respuesta de creación después del commit y otro cliente provocó un refresh que sustituyó la tarjeta temporal por su fila persistida. Al liberar la respuesta, no se llamó al RPC de borrado; la interfaz conservó una sola tarjeta y la consulta directa confirmó la fila.
23. En móvil se retuvo y falló la creación de una tarjeta temporal mientras se movía una tarea persistida de `Source` a `Done`. La petición de posiciones posterior incluyó dos IDs persistidos y ninguno temporal; la base confirmó `Move B` en `Done`.
24. Se creó una tarea sin refresh concurrente. La interfaz reemplazó el ID temporal por uno persistido y mostró exactamente una tarjeta.
25. Se retuvo un movimiento ya aplicado, otro cliente movió la misma tarea de vuelta a `Source` y su refresh terminó primero. Al liberar la respuesta de movimiento anterior, la interfaz y la base conservaron la columna más reciente.
26. En un tablero nuevo se retuvo la primera creación después de persistir la columna local. La tarjeta siguió visible tras sustituir el ID de columna; se añadió una segunda tarjeta antes de liberar la primera respuesta. Una consulta directa confirmó posiciones 0 y 1, sin duplicados.
27. Se retuvo la creación de una tarjeta temporal, se la movió a `Done` y otro cliente provocó un refresh antes de liberar la respuesta. La operación encolada usó el UUID persistido después del remapeo; la base confirmó la tarea en `Done`.
28. Se borró explícitamente una tarjeta temporal mientras su creación estaba retenida. Un refresh de otro cliente mostró la fila ya confirmada; al liberar la creación, la intención de borrado emitió un único RPC, quitó la tarjeta de la interfaz y la base confirmó que no quedaba la fila.
29. Se retuvo una edición para encolar un movimiento que incluía tres tareas. Otro cliente borró una hermana y emitió refresh antes de liberar la edición; el movimiento se envió con las dos tareas restantes y tuvo éxito. La base confirmó la tarea movida y la hermana borrada.
30. Se retuvo la respuesta de creación después del commit. Otro cliente borró la tarea y actualizó el tablero; luego se retuvo la verificación autoritativa de la creación y un segundo refresh llegó primero. Al liberar la lectura anterior, la interfaz y la base mantuvieron la tarea borrada; el cliente creador no llamó al RPC de borrado.
31. Se retuvo la respuesta de borrado de una tarea persistida después de que el servidor confirmó el commit. La tarjeta desapareció de inmediato, antes de liberar la respuesta; la respuesta fue 204 y una consulta directa confirmó cero filas.
32. Se repitió la creación pendiente con borrado remoto, pero la lectura autoritativa posterior respondió 500. La tarea borrada no reapareció y el cliente creador no intentó borrarla de nuevo; la base confirmó cero filas.
33. Se retuvo la respuesta de creación después del commit, se canceló la tarjeta temporal y otro cliente provocó el refresh que la reemplazó por su UUID. Al liberar la creación, el cliente emitió el borrado esperado; se retuvo su respuesta tras el commit y la tarjeta ya estaba oculta. El DELETE fue 204 y la lectura directa confirmó que solo quedaban `Seed A` y el trigger de refresh.
34. Se retuvo la llamada de creación antes del commit mientras otro cliente provocaba un refresh anterior a ella. Tras liberar el create exitoso, la primera verificación respondió 500. El toast indicó que el estado era incierto y ofreció `Volver a verificar`; esa acción solo leyó el tablero, mostró la tarea persistida y no repitió el RPC de creación (una llamada total).
35. Se encoló un movimiento móvil de una tarjeta temporal a `Done`, se aplicó un refresh anterior al commit, y la verificación posterior al create respondió 500. El movimiento encolado se remapeó al UUID persistido y el RPC de posiciones respondió 200; luego `Volver a verificar` respondió 200. La lectura directa confirmó la tarea en `Done`, posición 0, con un solo RPC de creación.
36. En un tablero nuevo se retuvo la creación de la columna inicial mientras otro cliente creó su propia columna y emitió refresh. Después de liberar la columna y crear la tarea local, la reconciliación consultó el tablero completo y mostró la tarjeta en su columna persistida; la lectura directa confirmó ambas tareas en sus columnas.
37. Se retuvo la lectura de verificación que incluía una tarea en `Source`. Mientras esperaba, el mismo cliente borró esa columna y su DELETE respondió 204. Al liberar el snapshot anterior, no reaparecieron `Source` ni la tarea; la base confirmó que solo quedaba `Done` sin tareas.
38. Se retuvo la verificación de una creación borrada por otro cliente y luego se forzó un 500 en esa lectura. Mientras estaba retenida, un refresh posterior confirmó la ausencia. Al liberar el error anterior, el cliente usó el estado del refresh vigente: no mostró la tarea ni ofreció una verificación innecesaria; la base confirmó cero filas y no hubo un RPC de borrado desde el creador.

## Verificaciones

- `pnpm typecheck` — pasó.
- `pnpm exec biome check . --line-ending=crlf` — pasó en los 75 archivos del checkout Windows.
- `pnpm build` — pasó con Next.js 16.4.2.
- `scripts/test-db.sh` sobre clúster PostgreSQL descartable en PostgreSQL 16.15 — pasó, con la prueba de orden de escritura de `updated_at`.

El checkout conserva sus finales de línea originales CRLF. Con `core.autocrlf=true`, se usó `--line-ending=crlf` para que Biome comprobara los finales presentes en Windows sin cambiar la configuración del repositorio. Para el runner Bash de base de datos se usó una copia LF temporal en PostgreSQL 16.15; el archivo rastreado no se normalizó.

El resultado ambiguo del propio RPC `create_task_p` (el servidor podría confirmar la escritura y perderse su respuesta antes de devolver el UUID) sigue siendo antecedente para los tickets de idempotencia/captura #7 y conflicto #8. Este cambio reconcilia únicamente una creación cuyo RPC respondió exitosamente y cuya lectura posterior quedó incierta; no reintenta una creación sin conocer su UUID.
