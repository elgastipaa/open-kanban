# Referencias de producto para cerrar el MVP

Fecha de consulta: **2026-10-22**. Investigación de documentación oficial; no es prueba práctica de interfaces ni una auditoría completa de paridad. Se contrastó con [MVP-1.0](./MVP-1.0.md), revisión 0.6 al iniciar la investigación. Esta nota no incorpora funciones al alcance ni autoriza implementación. Los productos y sus distintas plataformas pueden diferir; no se evaluaron precios ni disponibilidad por plan.

**Decisión posterior, 2026-10-23:** el usuario aprobó comentarios, menciones, adjuntos, checklist sencilla (no subtareas independientes), búsqueda/filtros y bandeja de novedades. La tabla siguiente conserva la comparación histórica al investigar; el alcance vigente y sus contratos pendientes están en MVP 1.0, revisión 0.8, sección 14. Esta nota no representa una nueva verificación externa.

## 1. Diferencias verificadas frente a Asana

La spec ya cubre tableros, tareas, responsables, fechas, completado, privacidad, colaboración y recurrencias. **No cubre todo lo que tiene Asana**. Estas son diferencias concretas, no razones automáticas para ampliarla:

| Capacidad documentada de Asana | Cobertura de nuestra spec al revisar | Propuesta para discutir, todavía no aprobada |
| --- | --- | --- |
| Comentarios en tareas, respuestas, menciones y archivos adjuntos. [Comentarios y adjuntos](https://help.asana.com/s/article/task-comments-and-attachments) | Descripción sí; conversaciones, menciones y archivos no especificados. | Decidir si hace falta conversar sobre una tarea dentro de ella. Para el viaje, permitir registrar una propuesta y preguntarle algo a la responsable. Definir comentarios primero; menciones y archivos son decisiones separadas. |
| Subtareas con campos propios, que funcionan como tareas individuales dentro de otra. [Tareas y subtareas](https://help.asana.com/s/article/tasks-and-subtasks) | Sin subtareas ni checklist especificados. | Evaluar si «Investigar Brasil» necesita pasos marcables. Una checklist sencilla no equivale a subtareas asignables, fechadas y recurrentes; no prometer lo segundo al aprobar lo primero. |
| Búsqueda por texto y vistas de búsqueda con filtros; resultados sujetos a permisos. [Búsquedas](https://help.asana.com/s/article/search-and-search-views?language=es) | Mis tareas reúne asignadas y Series filtra por tablero; falta un contrato general de búsqueda y filtros de tareas. | Acordar cómo encontrar una tarea cuando ya hay varios tableros: título/descripción, responsable, vencimiento y estado. Nada de búsquedas globales que revelen tableros ajenos. |
| Inbox reúne novedades como asignaciones, comentarios, cambios de fecha y completados. [Inbox](https://help.asana.com/s/article/inbox) | Destacados por fecha y sincronización sí; bandeja de novedades no especificada. | Resolver «¿cómo me entero de que mi amigo me asignó o cambió algo?». Historial visible dentro de una tarea y avisos de novedades son dos necesidades distintas; no implican push ni correo. |

Estas cuatro son las candidatas más próximas al uso cotidiano entre amigos, como **juicio de producto**, no como conclusión obligatoria de las fuentes. No se ha demostrado que todas sean necesarias para el MVP.

Asana también documenta dependencias, campos personalizados, formularios, reglas, cronograma, portafolios y gestión de carga. Son capacidades reales adicionales y nuestra spec no plantea paridad con ellas. La recomendación es mantenerlas fuera hasta que aparezca un recorrido concreto que las requiera. [Catálogo oficial de Asana](https://help.asana.com/s/article/all-asana-features)

Adjuntos no son un detalle gratuito: si el usuario los considera necesarios, habrá que especificar permisos de descarga, almacenamiento, tipos/tamaño, borrado y alcance de exportación. Esa es una inferencia de diseño propia, no una limitación atribuida a Asana. Enlaces en descripción pueden cubrir algunos casos, pero no equivalen a adjuntar archivos privados.

## 2. Recurrencias: qué verifica Microsoft y qué no

Microsoft Graph para eventos de Outlook separa patrón e intervalo de la duración de la serie. Documenta repetición diaria, semanal, mensual por fecha o posición y anual; el final puede ser por cantidad de ocurrencias, fecha o sin final. Eso respalda la familia de opciones que solicita el usuario; no exige repetir después de completar tareas ni copiar el modelo de reuniones. [Patrones y rangos de Outlook](https://learn.microsoft.com/en-us/graph/outlook-schedule-recurring-events)

### Meses sin día 29, 30 o 31

**Verificado:** la documentación de interoperabilidad de Exchange reconoce explícitamente dos políticas distintas: el formato RFC2445 omite los meses que carecen del día; el protocolo MS-OXOCAL usa el último día disponible en esos meses. Por eso no corresponde afirmar que todas las aplicaciones hacen lo mismo. Esta es evidencia de protocolo; no se ensayó cada cliente de Outlook. [End-of-Month Concerns](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxcical/4f8a95e3-542a-4c8b-88b3-1b00355286e7)

**Propuesta propia para revisar:** para una rutina mensual «día 31», usar el último día del mes cuando falte ese número, explicándolo en el resumen y conservando el 31 como regla original. Enero 31 → febrero 28/29 → marzo 31; nunca derivar marzo desde la fecha ajustada de febrero. Esto difiere de la propuesta de omitir meses de la revisión 0.6, por lo que requiere decisión explícita en la spec.

**No verificado aquí:** una regla universal de todos los clientes Microsoft para cumpleaños anuales del 29 de febrero. La documentación de Graph consultada enumera el patrón anual, pero no basta para afirmar qué hace cada interfaz en años no bisiestos. Para nuestra app, acordar una política visible de 28 de febrero, 1 de marzo o solo años bisiestos, sin atribuirla a Outlook. Tampoco equiparar «quinto lunes» con «último lunes»: no son el mismo calendario.

### Anticipación y reemplazo

La combinación «solo una ocurrencia pendiente vigente» + «aparición anticipada» es una regla de nuestra app; no se encontró en estas fuentes un comportamiento de Outlook que resuelva por nosotros el reemplazo de tareas pendientes. Validar anticipación contra intervalos variables, días seleccionados y excepciones es diseño propio. No confundir una reunión futura visible en calendario con una tarea activa única.

## 3. Orden y completadas en Microsoft To Do

**Verificado:** Microsoft To Do permite ordenar por importancia, fecha límite, incorporación a Mi día, alfabéticamente y fecha de creación. La página consultada no establece una dirección universal ni prueba que toda tarea recién creada aparezca abajo en cualquier vista. [Ordenar y buscar en listas](https://support.microsoft.com/en-us/todo/sort-and-search-in-lists)

**Propuesta propia:** en orden manual, insertar tareas nuevas al final; con un orden por vencimiento activo, colocarlas donde corresponda a su fecha. Para orden por creación ascendente, las nuevas quedan abajo. Definir empates estables y separar siempre la preferencia personal de Mis tareas del orden compartido de las columnas. No atribuir estos detalles a todas las aplicaciones.

**Verificado:** la guía accesible de To Do para Web documenta un botón de completadas que se expande o contrae; en sus otras secciones por plataforma también explica mostrar/ocultar completadas y describe valores iniciales diferentes. Es una referencia válida para un grupo colapsable, sin afirmar una interfaz idéntica en todos los dispositivos. [Listas y completadas en To Do](https://support.microsoft.com/en-us/accessibility/todo/use-a-screen-reader-to-work-with-lists-in-to-do)

**Propuesta propia:** grupo «Completadas (N)» al pie de cada columna y al pie de Mis tareas, con expansión personal persistida. Cada tarea conserva su columna real. Reabrir desde el detalle puede reducir toques accidentales, pero implica más pasos; elegir ese contrato expresamente en vez de confundirlo con colapsar el grupo. La documentación consultada no prueba cuál alternativa es mejor para este grupo de usuarios.

## 4. Cómo cerrar la comparación sin ampliar el alcance por inercia

Registrar para cada diferencia si se incluye, se excluye o necesita un caso real. Para lo incluido, definir creación, edición, permisos, móvil, errores y relación con series. Ejemplos: si una serie tiene checklist, ¿la siguiente empieza limpia? Si tiene comentarios, ¿son de la ocurrencia o de toda la serie? Si alguien pierde acceso, ¿desaparece también de búsqueda y avisos? Son preguntas de coherencia que deben resolverse solo si se incorpora esa capacidad.

La documentación confirma diferencias funcionales; no demuestra que Asana sea mejor para este caso ni que nuestra futura app lo supere. La evaluación debe usar los recorridos concretos del usuario y medir si puede capturar, encontrar, colaborar y anticipar el comportamiento sin explicaciones adicionales.
