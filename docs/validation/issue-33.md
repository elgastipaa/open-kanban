# Issue #33 — evidencia de validación

## Entorno y alcance

- Worktree `C:\Users\gasto\.codex\worktrees\openkanban-issue-33\open-kanban`, rama `codex/issue-33`, base fija `db0be5d12dc46b49ed8bbd0cfdbf1668612477b5`.
- Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, Biome `2.2.0`, PostgreSQL `16.15`.
- Los runners crean su propio PostgreSQL local en `/tmp`, con `PGHOST`/`DATABASE_URL` ajenos sin usar. Actores, tableros, miembros, tareas, comentarios, etiquetas, fechas y ocurrencias son sintéticos. No hubo OAuth, datos reales, DB remota, producción ni despliegue.
- Se conservan `Blocked by #13/#16/#27/#30`; ningún gate humano se marcó como aceptado. No se cambió el alcance de restauración, autoría, moderación ni creación/reprogramación de series.
- Se leyó la guía instalada de Next.js 16.4.2 antes de editar componentes/rutas. El build identifica `/search` y `/api/search` como rutas dinámicas.

## Evidencia por criterio

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| C108-AC40: buscar títulos/descripciones, comentarios actuales y tableros; etiquetas solo como filtro por etiqueta y tablero; excluir archivos/actividad. | `tests/db/unified_search.sql` comprueba cada fuente, sugerencia de etiqueta con sus IDs de tablero/etiqueta, y ausencia de resultados para fuentes fuera del alcance. La UI distingue «Etiquetas para filtrar» y no navega a una etiqueta. | DB sintética y pruebas unitarias; selección visual/Auth pendiente. |
| C108-AC41: abrir tablero, tarea o comentario precisos; «Ver tareas» separada, deduplicada; escribir no altera el origen. | El fixture DB devuelve IDs de tarea/comentario exactos y la lista de tareas deduplica resultados por tarea con paginación estable. `tests/unit/unified-search-navigation.test.mjs` comprueba enlaces de tarea, comentario y ocurrencia histórica con ancla precisa. El input solo actualiza la consulta local/URL de `/search`. | DB y contrato unitario; recorrido real del comentario paginado y Back en navegador pendiente. |
| C108-AC42: sugerencias exactas/prefijo/palabras incompletas, agrupación con espacio, orden personal en la lista. | `tests/db/unified_search.sql` cubre normalización y relevancia `exact`, `prefix` y `word`; una consulta con muchos comentarios no desplaza la sugerencia de tablero. La función SQL reserva resultados por tipo; el modo tareas deduplica y pagina por vencimiento o creación. | PostgreSQL local descartable. Sin benchmark de rendimiento de producción. |
| C108-AC43: los filtros de tareas se heredan por comentario; Mis tareas mantiene asignación propia; tableros no reciben filtros ficticios. | El fixture DB cubre prioridad, fechas locales al tablero, responsable/sin responsable, completadas, etiquetas OR, ámbito `my_tasks` y comentarios de la tarea padre. Los tableros se consultan como sugerencias de navegación separada; la UI explica qué filtros se aplican a tareas/comentarios. | DB sintética y build; combinación/interacción manual pendiente. |
| C112-AC61: historial apagado e independiente de completadas; encontrar ocurrencias reemplazadas y comentarios con estado/fecha/origen y destino preciso. | El fixture ejecuta el worker con reloj sintético, reemplaza una ocurrencia sin completarla y comprueba que solo `include_history=true` la devuelve, incluso por su comentario. También valida que `include_completed` no habilita el historial. Los resultados incluyen serie, tarea de origen, fecha, estado `replaced`, ocurrencia y comentario; la ruta abre `/series` con IDs exactos y ancla de comentario. «Limpiar» vuelve completadas e historial a desactivado, manteniendo ámbito y orden. | PostgreSQL y contrato unitario. Visita de historial y ausencia de edición/reapertura requieren navegador/Auth humano. El flag se serializa en `history=1`; almacenamiento/recuperación de vistas nombradas es alcance de #35/#34 y no se presenta como implementado aquí. |
| Autorización antes de ranking/extractos, privacidad, moderación y normalización. | El SQL valida actor/aplicación, membresía/board scope, tablero de filtros y etiqueta/tablero antes de producir resultados; el runner comprueba tablero ajeno, miembro revocado, filtros fuera de ámbito y respuesta genérica sin nombres/IDs privados. El fixture crea un comentario de colaborador y lo borra mediante el RPC de moderación del propietario; su marcador confidencial no aparece en búsqueda. La regresión fue roja al retirar temporalmente `comment_row.deleted_at IS NULL` (devolvió el extracto moderado) y verde al restaurarlo. No hay conteos totales; `has_more` se calcula sobre filas autorizadas. Las pruebas cubren acentos y `ñ/n`. El POST requiere `auth.getUser()` y `resolveApplicationAccess() === active`, responde `private, no-store` y nunca devuelve mensajes SQL. | DB sintética, parser de request y build; sesión Auth real no usada. |
| Solicitudes atrasadas, reintento y cambio de cuenta. | El cliente aborta la solicitud anterior y aplica una respuesta solo si coinciden ID de solicitud y cuenta. `tests/unit/unified-search-state.test.mjs` verifica respuestas antiguas y de otra cuenta. Reintentar, recuperar foco, volver a hacer visible la página y el intervalo incrementan el nonce que ahora es dependencia del mismo efecto POST; `tests/unit/unified-search-refresh.test.mjs` comprueba el cableado y dos llamadas POST reales al seam, ambas con respuesta resuelta. Al volver a foco y cada 30 s se revalida el permiso; se limpian resultados mientras la consulta se revalida. | Unitarios; cambio de cuenta/revocación real en navegador pendiente. |
| Ctrl/Cmd+K, botón y contexto. | El botón y el atajo usan el mismo handler. `buildUnifiedSearchHref` conserva ámbito de tablero o Mis tareas, filtros del buscador actual y etiquetas repetidas, pero descarta parámetros ajenos. `isGlobalSearchShortcut` tiene casos para Ctrl/Cmd, input, textarea, select, textbox/searchbox/combobox, contenteditable, Alt y Shift. | Unitario; foco/lector de pantalla/atajos en navegador pendientes. |
| Acceso perdido, filtro inválido y error transitorio. | El cliente descarta los resultados ante `unavailable`, oculta opciones privadas y bloquea la vista; ámbito de tablero no disponible ofrece expansión global solo tras elección explícita. Un filtro inválido no produce resultados; fallos temporales conservan la consulta y ofrecen Reintentar. El POST valida tamaño, campos admitidos, UUID, filtros y cursores antes del RPC. | Parser, DB y contrato UI; inyección de falla de red/revocación interactiva pendiente. |

El parámetro de historial queda dentro del estado serializado de consulta para que el trabajo de vistas lo pueda guardar. Este ticket no incorpora una segunda interfaz de guardado de vistas. No se afirma que el recorrido de comentario paginado, la persistencia de vistas, C-95 frente a cada fallo host, ni la accesibilidad con lector de pantalla hayan pasado aceptación manual.

## Ciclos TDD observables

- Runner DB: rojo por RPC `search_unified_p` inexistente, verde después de migración 058 y fixture #33.
- Comentario moderado: rojo explícito cuando se retiró temporalmente el filtro de comentarios borrados; el resultado expuso el marcador sintético `qzxconfidencial`. Verde al restaurar el filtro. El fixture usa un miembro colaborador como autor y el RPC del propietario para clasificar la eliminación como `moderation`.
- Historial completado: el fixture real crea una serie, completa su ocurrencia actual y deja que el worker la reemplace; con `include_history=true` y completadas desactivadas, el rojo devolvió `results: []` porque `task.is_completed` residual filtraba la rama `replaced`. Verde al quitar solo ese predicado de las cuatro ramas históricas; se prueban las cuatro combinaciones historial/completadas, el match por título y comentario, los dos modos, y que una tarea completada actual siga excluida hasta activar completadas.
- Refresco: rojo unitario primero por export de POST ausente y luego por falta de dependencia del nonce en el efecto; verde con dos POST/respuestas resueltas, verificación de que botón «Reintentar» y revalidación por foco/intervalo incrementan el mismo nonce, y aserción de integración de que el efecto POST depende de él. Se conservan `AbortController`, generación monotónica de request y chequeo de cuenta.
- Enlace contextual, guard de solicitud actual, parser de request, atajo fuera de campos de escritura y limpieza de filtros: cada slice añadió primero una prueba que falló por export/capacidad ausente; luego pasó con la implementación.
- Los errores de acceso del fixture no se sustituyeron por mocks de sesión para producir resultados; la ruta mantiene la comprobación real de Auth del servidor.

## Predicados repetidos en las ramas SQL

La repetición de filtros entre ramas se conserva. Las ramas actuales unen tareas a columna/tablero y excluyen tareas eliminadas, ocurrencias reemplazadas y etiquetas inactivas; las ramas de comentarios agregan autor y comentario no borrado; las históricas se anclan a una ocurrencia `replaced` y ahora son independientes de `task.is_completed`. Todas comparten autorización de miembro/tablero, pero no comparten las mismas relaciones ni la misma identidad de resultado. Una función genérica movería filtros después de la selección de candidatos por fila y podría reducir el pushdown del planner; un CTE común de elegibilidad tendría que volver a unirse a cuatro grafos distintos, con riesgo de multiplicar comentarios/ocurrencias, cambiar ranking/paginación o hacer menos visible el orden autorización→extracto. No se hizo el refactor heurístico; la repetición queda explícita junto a cada `UNION ALL`, con pruebas que fijan las diferencias por tipo.

## Verificaciones reproducibles

| Comando | Resultado |
| --- | --- |
| `pnpm test:db:issue-33` | PASS, exit 0; aplica migraciones 001–058 y pasa `tests/db/unified_search.sql` en PostgreSQL local descartable. El fixture completa la ocurrencia antes del worker y verifica historial `replaced` con ambos toggles, en resultados de título/comentario y ambos modos. |
| `pnpm test:db` | PASS, exit 0; suite global 001–058, incluido el fixture #33 actualizado. |
| `pnpm test:unit` | PASS, 214 existentes + 12 de #33 (226 total). Node muestra advertencias `MODULE_TYPELESS_PACKAGE_JSON` al importar TypeScript en `.mjs`. |
| `pnpm test:unit:issue-33` | PASS, 12/12: navegación/contexto, atajos, stale guard, dos POST/respuestas de refresh, wiring del nonce, clear y parser HTTP. |
| `pnpm exec next typegen` seguido de `pnpm typecheck` | PASS, exit 0 cada uno. |
| `pnpm build` | PASS, Next.js 16.4.2; compiló `/search` y `/api/search` dinámicos. |
| Biome focal normal sobre 13 archivos TS/TSX/MJS del ticket | PASS, sin cambios pendientes. |
| `pnpm exec biome check --formatter-enabled=false` | PASS, 235 archivos; se deshabilitó solo el formatter global para evitar reescritura por finales de línea en `package.json`. |
| `bash -n scripts/test-db-issue-33.sh` y `bash -n scripts/test-db.sh` | PASS. |
| `git diff --check` | PASS antes de stage. |

## Gates humanos pendientes

No se hizo recorrido autenticado en navegador ni se simuló OAuth/sesión para saltar Auth. Pendiente: revisión visual/responsive; teclado/foco/lector de pantalla; búsqueda mientras se escribe y navegación con Back; localizar comentario real dentro de conversación paginada; comportamiento con cuenta/membresía revocadas y error de red; apertura de historial en Series sin mutación; y aprobación humana de host/accesibilidad. El build, DB y contratos unitarios no cuentan como esas pruebas.

Los contratos de C-01–112 y las aristas de dependencia permanecen. C112-AC61 se acredita aquí para consulta/historial; vistas con nombre y preferencias contextuales siguen dependiendo de #34/#35. El issue no debe cerrarse ni sus criterios manuales marcarse completos con esta evidencia sola.
