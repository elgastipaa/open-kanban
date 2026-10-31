# Issue #10 — evidencia de implementación

Fecha: 31/10/2026. Issue: «Completar, agrupar y reabrir tareas». Rama: `codex/issue-10`. Base fija: `a374ade3f47991be2a2d5594d082318bfc3b2f2a`.

La entrega conserva #10 OPEN/`ready-for-human` y su dependencia `Blocked by #8`. El recorrido manual de Auth y la UI todavía está pendiente; esta evidencia no infiere aceptación ni cierre.

## Entorno y límites

- Windows, Node 24.14.1, pnpm 11.25.0, Next.js 16.4.2, React 19.2.9 y PostgreSQL 16.15 descartable.
- `pnpm test:db` aplica las migraciones locales y las regresiones sobre un clúster temporal. Usa dos sesiones PostgreSQL con claims de actores sintéticos: propietario `40000000-0000-4000-8000-000000000002`, colaborador `40000000-0000-4000-8000-000000000005` y admin global no miembro `40000000-0000-4000-8000-000000000001`. No crea sesiones HTTP Auth/PostgREST.
- No se usaron cuentas, tokens, proyectos Supabase ni datos reales, `.env`, OAuth, migraciones remotas, runner/browser/CUA, permisos debilitados, `main` ni producción. No se agregó dependencia.
- La preferencia de mostrar/ocultar o plegar el grupo vive solo en estado de cada vista. No se guarda en la base; su persistencia corresponde a #34.

## Criterios y evidencia

| Criterio | Estado | Evidencia y límite |
| --- | --- | --- |
| Completar mediante un comando de estado deseado `is_completed=true/false`, sin toggle; preservar columna, posición y otros campos | **Probado en DB** | `tests/db/task_completion.sql` llama el RPC con tarea sintética y compara columna, posición, título, descripción, prioridad y `field_versions`. Completar/reabrir solo actualiza estado, fecha de completado y versión independiente. |
| Doble envío, reintento y segundo actor en el mismo estado no duplican ni revierten el resultado | **Probado en DB** | La misma operación reproduce su recibo; una operación distinta del segundo actor con versión vieja y estado ya deseado confirma sin incrementar versión ni cambiar fecha. Una clave reutilizada con carga diferente se rechaza. Reproducir una operación vieja tras una reapertura posterior devuelve `conflict` con el estado actual, sin ocultar ni revertir la reapertura. |
| Dos clientes piden completar/reabrir desde la misma versión | **Probado en DB** | `scripts/test-db.sh` mantiene una transacción autenticada bloqueando la tarea y lanza un segundo cliente con actor/operation ID distintos. Completar confirma una vez; el reabrir opuesto y obsoleto recibe `conflict`; el estado final queda completado en versión 2. |
| Reabrir solo desde el detalle de tarea | **Parcial; UI manual pendiente** | Las tarjetas compactas no ofrecen acción de reapertura; el detalle expone «Reabrir». La RPC de reapertura y versión están cubiertas en DB. Falta verificar visualmente las acciones y que abrir/ver la tarjeta no cambie el estado. |
| Casilla compacta indicativa; abrir no completa | **Parcial; UI manual pendiente** | La tarjeta presenta un indicador no interactivo; solo el botón «Completar» emite el comando. El handler de abrir conserva la edición actual. No se ejecutó el DOM en navegador. |
| Grupo de completadas visible y expandido por defecto, más recientes primero | **Unitario para selección/orden; UI parcial** | `task-completion.test.mjs` verifica que las pendientes retienen orden manual y que las completadas ordenan `completed_at` descendente, con desempate determinista por ID, sin mutar el arreglo de entrada. Column y MobileBoard lo muestran expandido por defecto; el layout real requiere recorrido manual. |
| Ocultar/plegar el grupo es personal y no cambia datos ni la vista de otro actor | **Parcial; persistencia no incluida** | Column y MobileBoard mantienen controles locales independientes por vista; el comando de completado no incluye visibilidad. No hay escritura sincronizada ni persistencia aquí; #34 es dueño de preferencias guardadas. La interacción entre dos navegadores falta verificar manualmente. |
| Reordenar/mover pendientes conserva su orden y mantiene completadas agrupadas | **Unitario; DB de orden regresiva** | Helper unitario verifica índices de inserción entre pendientes aunque las filas estén intercaladas con completadas en el orden persistido. La suite existente de #9 conserva cobertura de orden RPC. No se ejercitó drag-and-drop visual después de completar en un navegador. |
| Borrador sucio antes de completar: Guardar, Descartar o Cancelar; no ejecutar la acción secundaria si guardar falla/conflicta | **Unitario para seguimiento; UI parcial** | El helper solo permite completar tras descarte explícito o guardado `confirmed`; `conflict`, error, reconciliación y cancelación no siguen. `TaskModal` conserva las decisiones C-95 y bloquea el comando durante conflictos/consultas. DOM/Auth real pendiente. |
| Autorización y acceso directo a filas/recibos | **Probado en DB sintética; HTTP/Auth parcial** | Miembro puede usar RPC, `anon` y admin global no miembro no acceden; la escritura directa en `tasks` y el acceso a recibos quedan bloqueados. Falta PostgREST/Auth real, expresamente fuera del entorno usado. |
| Retención de operación vencida y error de red real | **No probado** | El recibo registra expiración de siete días y el RPC devuelve `expired_unknown`, que el cliente reconcilia mediante lectura autorizada. La suite #10 no manipula el reloj ni corta una conexión HTTP; el usuario deberá validar esos recorridos manualmente/por pruebas futuras. |
| Checklist y ocurrencias/repeticiones | **No implementado en #10** | Permanecen fuera del alcance de este ticket. Completar no modifica ni genera esos datos; CF-06 continúa vigente para la funcionalidad futura. |

## Comandos locales

| Comando | Resultado |
| --- | --- |
| `pnpm test:unit` | 28 pruebas, 28 aprobadas. Incluye orden/visibilidad pura, índice de movimiento y decisión C-95 de seguimiento. |
| `pnpm test:db` | Aprobado en PostgreSQL descartable 16.15; incluye migraciones 001–021, regresión de completion y carrera concurrente completar/reabrir con dos clientes sintéticos. |
| `pnpm typecheck` | Aprobado después de que Next generó el `next-env.d.ts` ignorado que faltaba en el checkout inicial. |
| `pnpm build` | Aprobado: compilación Turbopack, TypeScript, páginas estáticas y optimización finalizadas. |
| `pnpm exec biome check` sobre los archivos TS/TSX y el test unitario de #10 | Aprobado tras aplicar formato y correcciones dirigidas. |
| `git diff --check` | Aprobado al cerrar; Git avisa que normalizará LF a CRLF en los TS/TSX del checkout Windows. |

## Recorrido humano pendiente

En un entorno local autorizado con usuarios de prueba, completar una tarjeta desde escritorio y móvil, confirmar que conserva columna, abrirla sin alterar estado y reabrir únicamente desde el detalle. Verificar grupo inicialmente expandido/visible, orden por completado más reciente, ocultar/plegar en una vista sin afectar otra sesión, controles accesibles y tareas movidas entre columnas. Con un borrador sucio, probar Cancelar, Descartar y Guardar; forzar guardado confirmado, conflicto y fallo/transición incierta y comprobar que la acción secundaria solo continúa en los dos caminos autorizados por C-95. Auth/PostgREST, cambio de cuenta, pérdida/restauración real de red, zoom y lector de pantalla también quedan pendientes.

Hasta completar el recorrido y resolver el bloqueo de #8, el issue permanece OPEN/`ready-for-human` y `Blocked by #8`.
