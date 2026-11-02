# Issue #35 — vistas personales guardadas

Fecha de verificación: 2026-11-02. Rama `codex/issue-35`, base `810b01b217a52f505e94f3a191c66a47ac1febcf`.

## Alcance y entorno

Se implementó el catálogo personal de vistas para Búsqueda y Mis tareas, su edición explícita, revisión de referencias, borrado recuperable y recuperación con previsualización. Las vistas conservan solo definición; cada apertura vuelve a consultar contenido usando la autorización actual. Los RPC y pruebas usan identidades, tableros, etiquetas y nombres sintéticos en PostgreSQL descartable local.

Se conserva `Blocked by #14/#34`; esta implementación bajo LP-0.2 no declara cerrados esos tickets ni sus gates humanos. No se usaron OAuth real, datos reales, SQL remoto ni producción.

## Evidencia por criterios

| Criterio | Evidencia ejecutable / estado |
| --- | --- |
| Guardar y listar por persona y contexto (Búsqueda o Mis tareas), sin visibilidad a otra cuenta | `tests/db/saved_views.sql`: dos actores sintéticos; lista y mutaciones ajenas devuelven respuesta genérica sin filtrar contenido. `pnpm test:db:issue-35`: exit 0. |
| Definición permitida, texto/alcance/filtros/orden, referencias autorizadas y nombre de hasta 60 caracteres | Validador exacto en cliente y servidor; pruebas de esquema en `tests/unit/saved-view-state.test.mjs`; casos SQL para alcance/contexto, tablero/etiqueta/responsable accesibles, referencias desconocidas y longitud 60/61. |
| Unicidad normalizada y límite compartido de 50 vistas activas entre ambos contextos | Pruebas SQL de acentos/ñ, mayúsculas, espacios y unicidad por contexto. Runner de dos sesiones PostgreSQL fuerza carrera por el último cupo: una crea, la otra recibe `limit_reached`, quedan 50 activas y solo una fila ganadora. |
| Variación temporal y acciones explícitas Actualizar / Guardar como nueva / Restablecer vista | UI en Búsqueda y Mis tareas: actualizar y guardar como nueva son acciones separadas; “Restablecer vista” reaplica la definición elegida solo al pulsarla. “Reiniciar preferencias” de #34 permanece separado y no elimina vistas. Aplicar no confirma una modificación guardada. |
| Conflicto de versión sin sobrescritura silenciosa; mantener propuesta hasta elección explícita | RPC actualiza solo con `expected_version`; prueba de stale update verifica que la versión del servidor no sea sobrescrita. La UI ofrece usar la versión actual o revisar y conservar la variación local. |
| Referencias revocadas requieren revisión y no se quitan silenciosamente | SQL prueba referencia a tablero inaccesible y etiqueta eliminada. El estado `needs_review` es sticky al volver una referencia; revisar carga la definición y los campos inválidos para corregirla, y el guardado/recuperación revalida antes de limpiar la marca. |
| Borrado propio, nombre reutilizable y recuperación dentro de siete días | SQL prueba borrado, ocultamiento, reutilización de nombre, preview de colisión/cupo/referencias y confirmación revalidada. Recuperación mantiene el mismo ID, incrementa versión y no aplica la vista a la consulta abierta. En `deleted_at = now() - interval '7 days'` responde `expired`; la purga física está limitada a `service_role`. |
| Conflictos de recuperación y atomicidad | Preview y confirmación revisan nombre, cupo total, referencias y versión; los casos de límite/conflicto no mutan el tombstone. Liberar cupo permite una segunda preview y confirmación explícita. |
| Integración de página y contexto | `/search` y `/my-tasks` cargan catálogo con cliente servidor autenticado y montan el panel por cuenta. El atajo/contexto de búsqueda no se reemplaza por un nuevo flujo; Mis tareas limita el tipo de definición a su contexto. |

## Comandos y resultados

Entorno: PostgreSQL local descartable creado por `scripts/test-db.sh`; ejecución con identidades sintéticas. `next` local: 16.4.2.

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-35` | Exit 0; suite focal y carrera de dos clientes sobre cupo 50. |
| `pnpm test:db` | Exit 0; migraciones y regresiones 001–060, incluidas las suites de #35; mensaje final `Database regression tests passed (disposable PostgreSQL).` |
| `pnpm test:unit` | Exit 0; tests existentes y suites unitarias focales de #33, #34 y #35; `saved-view-state.test.mjs` pasa 4/4. |
| `pnpm exec next typegen` | Exit 0; rutas generadas por Next 16.4.2. |
| `pnpm typecheck` | Exit 0 (`tsc --noEmit`). |
| `pnpm build` | Exit 0; build optimizado de Next 16.4.2. |
| `pnpm exec biome check --line-ending=crlf` sobre los 9 archivos TS/TSX/MJS del cambio | Exit 0; sin diagnósticos. |
| `pnpm exec biome check --formatter-enabled=false` | Exit 0; 250 archivos revisados sin diagnósticos de lint. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-35.sh scripts/test-db-issue-35-race.sh` | Exit 0. |
| `git diff --check` | Exit 0. |
| `pnpm lint` | Exit 1 porque el chequeo de formato global usa LF y el repositorio conserva CRLF: reporta diferencias de finales de línea en archivos no relacionados. Los archivos TS/TSX del ticket pasan el chequeo focal con `--line-ending=crlf`; la revisión global sin formatter pasa. No se reformateó el repositorio completo. |

## Gates humanos pendientes

- No se recorrieron Búsqueda ni Mis tareas en navegador con Auth/host; no se acredita la experiencia completa de abrir/variar/restablecer, los lectores de pantalla, teclado ni tamaño móvil.
- Falta validar integración real con Supabase Auth y los servicios/canales del host. PostgreSQL local comprueba RPC, permisos modelados, transacciones y carreras, pero no esos servicios.
- Los criterios automatizados anteriores no equivalen a aceptación manual ni cierran #14/#34.
