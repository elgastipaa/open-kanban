# Issue #32 — Duplicar una tarea puntual

## Entorno y alcance

- Rama `codex/issue-32`; base exacta `7c33b69621fa5a952e09b47f0eaacb0a2853c54b`.
- PostgreSQL local descartable creado por `scripts/test-db.sh`; el runner no consume `DATABASE_URL`, `PGHOST` ni un servidor remoto. Todos los actores, tableros, tareas, etiquetas, fechas y comentarios de prueba son sintéticos.
- Aplicación verificada con Next.js 16.4.2. No se usaron OAuth, datos reales, credenciales de producción ni despliegues.
- Esta entrega implementa E04 de C-101/C-104/C-105. P01–P26 y E01–E07 siguen en el alcance aprobado por C-99; no se declara implementado ningún otro ticket ni se cambian sus dependencias.

## Evidencia por criterio

| Criterio | Evidencia automática | Estado |
| --- | --- | --- |
| C-101 AC10 / E04: copiar etiquetas activas del elemento origen, incluidas las propias de una ocurrencia; excluir relaciones de etiquetas retiradas y no leer la plantilla de la serie. | `tests/db/task_copy.sql`: fuente con 10 etiquetas activas y una retirada; se copian exactamente las 10 IDs activas. Para una ocurrencia, la selección de la tarea es A y la plantilla contiene B; preview y copia conservan A aunque cambie B. | Automatizado en PostgreSQL local descartable. |
| C-104 AC21: proponer el título existente, dejarlo editable y no agregar sufijo ni modificar el origen. | `tests/db/task_copy.sql` confirma el título elegido en la tarea nueva y mantiene intacto el título de origen. `tests/unit/task-copy-contract.test.mjs` verifica el campo de título de la acción. | Automatizado; interacción real de navegador pendiente. |
| C-104 AC22: destino inicial de origen, alternativas del mismo tablero e inserción al final manual. | `tests/db/task_copy.sql` crea otra columna del mismo tablero, confirma el destino elegido y comprueba que la copia queda después de la última tarea existente. Rechaza un destino de otro tablero sin escribir. La UI ofrece el selector a partir de las columnas recibidas del tablero autorizado. | Automatizado en DB y contrato UI; recorrido visual pendiente. |
| C-104 AC23: permitir tarea completada/histórica autorizada; no cambiarla ni reabrirla; denegar papelera y cumpleaños. | `tests/db/repetition_series_copy.sql` copia una ocurrencia histórica completada como tarea pendiente sin cambiar el origen. `tests/db/task_copy.sql` comprueba respuesta genérica `unavailable` para tarea en papelera y cumpleaños, sin fila nueva. El contrato UI verifica que cumpleaños no importan ni muestran la acción. | Automatizado; comprobación manual de la pantalla de cumpleaños pendiente. |
| C-105 AC27: cancelar no crea; confirmar crea una tarea nueva pendiente, ofrece abrirla y el reintento no duplica. | El contrato UI comprueba que cancelar solo cierra el preview y que se ofrece «Abrir copia». DB comprueba nueva identidad, pendiente, posición final, receipt único y replay concurrente: dos sesiones con el mismo operation ID reciben la misma tarea. | DB y contrato UI automatizados; recorrido de teclado/navegador pendiente. |
| C-105 AC28: cambios en contenido copiable refrescan preview y exigen revisar, preservando título/destino; comentarios no invalidan; pérdida de acceso bloquea. | `tests/db/repetition_series_copy.sql` cambia descripción después de preview y obtiene `source_changed`, conserva título/destino, no crea hasta confirmar y luego preserva el origen. `tests/db/task_copy.sql` cambia etiquetas tras preview y detecta el cambio; un comentario nuevo no cambia el hash. La prueba también revoca una membresía entre preview y confirmación y confirma denegación sin escritura. `tests/unit/task-copy-state.test.mjs` cubre conservación de título/destino y gate explícito de revisión. | Automatizado en DB y helper UI; interacción real pendiente. |
| P01/P18: identidad propia y reconciliación de resultado incierto sin duplicados. | `tests/db/task_copy.sql` verifica IDs nuevas y un replay concurrente en dos sesiones bloqueado por la fila del tablero. El runner comprueba un solo receipt/tarea pendiente y resultado idéntico en ambas sesiones. El componente conserva el mismo comando/operation ID para reintentar y bloquea una operación nueva ante `expired_unknown`. | Automatizado en DB; falla de red real en navegador pendiente. |

El source hash contiene título, descripción, prioridad, pasos y las IDs/nombres de etiquetas activas. No incluye asignación, fecha, serie ni conversación. La creación y la aplicación de etiquetas ocurren en una transacción y bajo el lock del tablero; un fallo de la asignación revierte también la tarea/receipt.

## Verificaciones reproducibles

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-32` | PASS, exit 0; aplica migraciones 001–057, verifica autorización, copia, etiquetas, papelera/cumpleaños y carrera de reintento. |
| `pnpm test:db:issue-27` | PASS, exit 0; incluye copia histórica y de ocurrencia completada. |
| `pnpm test:db:issue-30` | PASS, exit 0; regresiones de catálogo/asociaciones y sus carreras. |
| `pnpm test:db` | PASS, exit 0; suite completa con migraciones 001–057, incluidas `task_copy.sql` y el race runner de #32 al final. |
| `pnpm test:unit` | PASS, 214/214. Node emite la advertencia existente `MODULE_TYPELESS_PACKAGE_JSON` al importar TypeScript desde los tests; no afecta el resultado. |
| `pnpm exec next typegen` seguido de `pnpm typecheck` | PASS, ambos exit 0. |
| `pnpm build` | PASS, Next.js 16.4.2; compilación, TypeScript y rutas completadas. |
| `pnpm exec biome check --line-ending=crlf` sobre los 9 archivos de código/test del ticket | PASS, sin cambios pendientes. |
| `pnpm exec biome check --formatter-enabled=false` | PASS, 223 archivos revisados. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-32.sh scripts/test-db-issue-32-race.sh` | PASS. |
| `git diff --check` | PASS. |

La migración se comprobó desde una base PostgreSQL temporal recién creada; no hubo consultas SQL remotas.

## Gates humanos pendientes

No se realizó una aceptación manual de navegador con Auth/host. Quedan pendientes la revisión visual/responsive y el recorrido real por TaskModal y Series; teclado, foco, lector de pantalla, cancelación y apertura con retorno al contexto; y la inyección de una caída de red real para confirmar retry e incertidumbre en el navegador. Los contratos unitarios y el build no se contabilizan como pruebas manuales de UI/accesibilidad/host. Las dependencias #15, #27 y #30 permanecen intactas; el issue sigue abierto hasta sus gates humanos y revisiones de coordinación.
