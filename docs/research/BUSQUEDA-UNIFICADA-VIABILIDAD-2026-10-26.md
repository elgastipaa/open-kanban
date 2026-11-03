# Búsqueda unificada: viabilidad y decisiones de producto

Fecha: 26 de octubre de 2026. Investigación breve con código local y fuentes oficiales. Recomendaciones, no acuerdos nuevos ni autorización de implementación. El pedido actual del usuario amplía expresamente la búsqueda anterior de título/descripción hacia varias entidades y comentarios; no debe descartarse por la antigua exclusión de comentarios.

## Conclusión

**Es viable diseñar la experiencia rica pedida sobre Next.js y Supabase/PostgreSQL, sin necesitar de entrada otro motor de búsqueda.** Hay soporte documental para búsqueda textual, prefijos, ponderación, extractos y tolerancia textual. Esto es una inferencia de arquitectura; no acredita latencia, costo ni compatibilidad de una base desplegada concreta. La dificultad principal es unir experiencia, autorizaciones y semántica de filtros, además de implementar entidades que hoy solo están especificadas.

La referencia informal a Vercel se toma como intención de interacción: escribir, ver coincidencias contextualizadas y elegir una acción. No se inspeccionó ni se afirma cómo implementa Vercel su buscador.

## Evidencia local

- Checkout Windows de OpenKanban, HEAD `46c94139bac67aaca1d491b29afc3bc999fc288f`, más especificación local en evolución. No se operó el checkout WSL ni producción.
- [package.json](../../package.json) declara Next 16.4.2, React 19.2.9, Supabase JS 2.98.0 y SSR 0.8.0, Node 24 y pnpm 11.3.0. Son declaraciones locales, no comprobación de paquetes desplegados.
- [Tipos](../../src/lib/types.ts), [tableros](../../supabase/migrations/001_create_boards.sql) y [tareas](../../supabase/migrations/003_create_tasks.sql) contienen el modelo original: tablero con slug, columnas y tareas con título/descripción/prioridad. No existen todavía entidades de comentarios, membresías o etiquetas en esas migraciones. El nombre de tablero del producto nuevo tampoco equivale a un campo ya implementado en ese modelo.
- [Acceso a tareas](../../src/lib/db/tasks.ts) y [tableros](../../src/lib/db/boards.ts) reutilizan RPC. La [migración 012](../../supabase/migrations/012_harden_rpc_access.sql) preserva explícitamente el producto anónimo por URL y concede ejecución a `anon`: no es el modelo privado requerido por la spec. No copiar ese permiso a un endpoint global de búsqueda.
- La búsqueda anterior está en [MVP §14.4](../specs/MVP-1.0.md), [Cierre CF-14](../specs/CIERRE-MVP-1.0.md) y [Pantallas UI-10](../specs/PANTALLAS-MVP-1.0.md). El pedido posterior sustituye su restricción a título/descripción; siguen vigentes privacidad, identidad estable, límites de permisos, contexto y ausencia de modificaciones accidentales al escribir.

## Capacidades verificadas en fuentes primarias

| Capacidad | Evidencia y alcance |
| --- | --- |
| Búsqueda en PostgreSQL | Supabase documenta FTS, índices GIN, campos ponderados, prefijos y acceso mediante RPC. Permite dar más relevancia a un título que a una descripción. No obliga a descargar el tablero entero al navegador. [Supabase: Full Text Search](https://supabase.com/docs/guides/database/full-text-search). |
| Prefijo, relevancia y extractos | PostgreSQL ofrece prefijos de lexemas, funciones de ranking y extractos. `websearch_to_tsquery` no interpreta etiquetas de prefijo; no basta con usarla para prometer autocompletado. El parser debe aceptar texto cotidiano sin exponer sintaxis técnica. `ts_headline` no produce HTML seguro por sí mismo: se debe renderizar texto/segmentos seguros. [PostgreSQL: Controlling Text Search](https://www.postgresql.org/docs/current/textsearch-controls.html). |
| Coincidencias parciales y errores de escritura | `pg_trgm` aporta similitud y soporte de índices para búsquedas parciales. Puede complementar FTS; no equivale automáticamente a un buen ranking. Patrones sin trigramas extraíbles pueden recorrer todo el índice, por lo que consultas muy cortas necesitan una estrategia medida. [PostgreSQL: pg_trgm](https://www.postgresql.org/docs/current/pgtrgm.html). |
| Acentos y ñ/n | `unaccent` permite quitar diacríticos y configurar reglas de transformación. Es una pieza candidata para cumplir C-102/C-103; debe verificarse con ejemplos de ñ y Unicode compuesto/descompuesto sin alterar texto original ni IDs. [PostgreSQL: unaccent](https://www.postgresql.org/docs/current/unaccent.html). |
| Disponibilidad en plataforma | El catálogo oficial de Supabase enumera `pg_trgm` y `unaccent`. No se verificó que estén habilitadas en la instancia concreta ni su versión. [Supabase: extensiones](https://supabase.com/docs/guides/database/extensions). |
| Autorización de resultados | RLS controla filas en base; una vista requiere configuración segura para respetar políticas subyacentes. Supabase documenta `security_invoker` para vistas en PostgreSQL 15+. Es necesario validar versión y permisos reales. [Supabase: Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security). |
| RPC privada | Supabase recomienda funciones `security invoker`; una `security definer` puede devolver filas que el llamador no puede leer. Conceder ejecución a `authenticated` no resuelve por sí solo membresías ni aislamiento. [Supabase: Database functions](https://supabase.com/docs/guides/database/functions). |

Las fuentes PostgreSQL `current` consultadas corresponden a documentación 18; no se presupone esa versión en el proyecto desplegado. No se eligieron extensiones, DDL, servicios pagos ni proveedor adicional como decisiones aprobadas.

## Propuesta mínima rica, pendiente de decisión

Un mismo buscador muestra sugerencias durante la escritura, con grupos de entidades, contexto y acción explícita. No cambia el tablero, la lista ni los filtros de origen al escribir; la elección determina qué se abre o qué consulta se ejecuta.

| Tipo de resultado propuesto | Texto buscado | Presentación | Elección explícita |
| --- | --- | --- | --- |
| Tablero | Nombre del tablero | Tipo Tablero y nombre autorizado | Abrir tablero. Restringir búsqueda a él sería una acción rotulada distinta, no un efecto oculto del clic. |
| Tarea | Título y descripción | Tipo Tarea, título, tablero/columna y fragmento; indicar si coincidió descripción | Abrir el detalle existente, conservando contexto de retorno. |
| Comentario | Texto actual del comentario | Tipo Comentario, extracto, tarea y tablero de origen, autor/fecha autorizados | Abrir detalle y ubicar el comentario concreto, también si la conversación está paginada. |

Una acción visible «Ver tareas que coinciden» puede aplicar texto/filtros a la lista de tareas. En esa lista se deduplica por tarea, aunque coincidan varios comentarios, mostrando la fuente de la coincidencia. En sugerencias, una tarea y un comentario son destinos distintos; no duplicar la misma tarea por cada campo que coincida.

Este conjunto cubre los ejemplos expresos del usuario y conserva descripción. Etiquetas como sugerencias de filtro, cumpleaños, columnas, series, pasos, vistas guardadas y archivos son ampliaciones a decidir si se quieren; no se aceptan todas por decir «búsqueda rica». No indexar textos antiguos/editados ni comentarios borrados/moderados. La recuperación no es un atajo para incluir contenido eliminado en sugerencias normales.

## Filtros: semántica por entidad

Los siguientes comportamientos son recomendaciones de producto, no reglas ya aprobadas:

| Condición | Tareas | Comentarios | Tableros |
| --- | --- | --- | --- |
| Permiso y alcance de tablero | Membresía actual y tarea disponible | Membresía actual, comentario disponible y tarea/antecesores disponibles | Membresía actual y tablero disponible |
| Responsable / Mis tareas | Responsable de tarea | Responsable de la tarea padre; nunca confundir con autor del comentario | No tiene responsable de tarea; condición no aplicable |
| Completado | Estado propio | Estado de tarea padre si se está filtrando tareas/comentarios | No aplicable; no inventar «tablero pendiente» |
| Fecha, prioridad, etiquetas | Propiedades de tarea | Propiedades de tarea padre, no fecha de publicación del comentario | No aplicables |
| Texto | Título/descripción y, al decidirlo, existencia de comentario coincidente para resultados de tareas | Texto del comentario | Nombre del tablero |

Recomendación: hacer visibles grupos y filtros aplicables. En búsqueda global, no ocultar todos los tableros porque esté activo el default «pendientes» de tareas. En contexto Mis tareas, limitar tareas/comentarios a las asignadas al usuario y no insertar tableros como si fueran tareas asignadas. El alcance global explícito puede mostrar las tres familias. Si se mantienen filtros de tarea y grupo Tableros simultáneamente, rotular que dichos filtros afectan tareas/comentarios, evitando aparentar que el tablero cumple una prioridad o vencimiento.

Debe decidirse si las sugerencias de comentarios heredan el default de pendientes o incluyen comentarios de tareas completadas. Recomiendo respetar el estado seleccionado de la tarea padre, con un control visible para incluir completadas; nunca esconder esa condición. Ocurrencias históricas/reemplazadas necesitan incluirse en la política de historial si se desean: no son automáticamente pendientes ni completadas.

## Relevancia de sugerencias y orden de tareas

Son dos propósitos distintos. Recomendación:

- Mientras se escribe, sugerencias por relevancia: coincidencia exacta de nombre/título, prefijo, resto de coincidencias; títulos pesan más que descripciones y comentarios. Cupo por grupo evita que muchos comentarios oculten un tablero claramente coincidente. Desempate determinista.
- Tras elegir «Ver tareas que coinciden», conservar el orden de trabajo por vencimiento/creación definido en preferencias. Mostrar por qué coincidió cada tarea. No aplicar el orden por vencimiento a tableros ni fingir fecha de tarea para un comentario.
- Elegir un resultado navega; elegir una sugerencia de filtro, si se incorpora, modifica la consulta de forma explícita. Teclear no elige automáticamente el primer resultado. Enter no debe navegar a una entidad no seleccionada por accidente.

Esta distinción evita reemplazar silenciosamente defaults ya aceptados de listas por relevancia. No agrega un motor semántico ni recomendaciones basadas en datos externos.

## Ruta técnica candidata

Inferencia de diseño basada en las capacidades citadas y el código local:

1. Implementar primero el modelo privado de entidades/membresías ya especificado. Una consulta global sobre RPC anónimas actuales no cumple el objetivo.
2. Preparar búsqueda por entidad, con texto normalizado derivado y texto original de presentación. Para comentarios, conservar identidad propia y relación con tarea; no concatenar toda la conversación en la fila de tarea como solución automática.
3. Componer una respuesta tipada desde una operación de servidor/RPC que aplique permisos y estado vigente antes de devolver fragmentos, ranking, límites y conteos. Puede unir consultas por entidad; no requiere una tabla pública con todas las conversaciones.
4. Evaluar FTS/prefijos y, si la calidad lo necesita, trigramas para nombres y errores. No confiar en búsqueda simple solo por palabra completa para una experiencia mientras se escribe. Probar consultas cortas, varias palabras, ñ, acentos y puntuación.
5. Retrasar brevemente solicitudes durante tipeo, cancelar/descartar respuestas obsoletas por consulta y sesión, limitar resultados y permitir ampliación. Los milisegundos, longitudes y tamaños se fijan con pruebas, no son límites de producto aprobados en esta nota.
6. Revalidar el destino al elegirlo. Borrado/moderación o pérdida de acceso entre sugerencia y clic produce indisponibilidad sin filtrar texto. Limpiar respuestas de otra sesión/cuenta. Un índice derivado no reemplaza consulta de permisos actuales.

## Límites y verificación necesaria

- No se ejecutó app, migración, consulta remota, benchmark ni prueba de compatibilidad. No se leyó `.env.local`, no se habilitaron extensiones ni se modificó infraestructura.
- Verificar versión de PostgreSQL y disponibilidad real de extensiones en entorno autorizado de prueba. El catálogo oficial acredita posibilidad de plataforma, no estado de esta instancia.
- Medir consultas con varias entidades y volumen representativo de comentarios, no solo el fixture anterior de 500 tareas. Usar planes de consulta y latencia observada; no prometer búsqueda instantánea o escala ilimitada.
- Verificar que no aparecen títulos, extractos, autores, conteos ni sugerencias de tableros ajenos, cuentas suspendidas o contenido eliminado/moderado. Cubrir revocación y edición mientras una solicitud está pendiente.
- Probar teclado/móvil, selección explícita, cancelación, respuestas fuera de orden y retorno. No perder borrador ni cambiar filtros de origen al teclear.
- Probar deduplicación de tareas coincidentes por varios campos/comentarios, destino preciso del comentario y consistencia tras editar/borrar/restaurar/importar.
- Si un índice deriva datos de comentarios, definir sincronización y recuperación ante fallos; evitar resultados con texto moderado obsoleto. La fecha de un comentario no es vencimiento de su tarea.
- Validar ranking con ejemplos reales del dominio: nombres breves, textos largos, coincidencias repetidas y nombres homónimos en distintos tableros. La documentación de ranking no garantiza calidad sin esos ejemplos.

## Cuatro decisiones de producto restantes

1. **Fuentes iniciales y forma de resultados:** recomendar Tableros, Tareas (título/descripción) y Comentarios actuales, con tipo/contexto y fragmento. Definir si también se desean sugerencias de etiquetas u otras entidades; no reducir la intención rica a un buscador solo de títulos.
2. **Acción al elegir:** recomendar abrir tablero/tarea/comentario preciso; acción separada para ver tareas que coinciden o restringir alcance. Teclear nunca navega ni filtra la vista de origen automáticamente.
3. **Alcance y filtros por tipo:** recomendar respetar contexto/Mis tareas, filtros de tarea heredados por comentarios y tableros separados de condiciones inaplicables. Confirmar cómo se incluyen completadas/históricas sin esconder defaults.
4. **Relevancia frente a orden de trabajo:** recomendar sugerencias por relevancia agrupadas, lista de tareas por preferencias; coincidencias tolerantes a acentos/ñ ya aprobadas. La tolerancia a errores tipográficos puede evaluarse técnicamente como mejora, sin prometer semántica o IA.

Esta nota prepara decisiones y diseño; no elige esas cuatro respuestas en nombre del usuario ni modifica la spec. Las restricciones antiguas «no buscar comentarios» deben actualizarse por el acuerdo posterior al consolidar, conservando su trazabilidad histórica.
