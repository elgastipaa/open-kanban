# OpenKanban Personal

Organización de tareas mediante tableros Kanban. Este glosario fija el lenguaje del producto; acuerdos y decisiones pendientes viven en las especificaciones. Actualizado el 27/10/2026 hasta C-112. P01–P26 y E01–E07 conservan el alcance objetivo, todavía sin implementar.

## Language

**Tablero**:
Espacio que reúne columnas y las tarjetas organizadas en ellas.
_Avoid_: Proyecto, workspace, kanban como entidad distinta de tablero.

**Columna**:
Agrupación ordenada de tarjetas dentro de un tablero. Su nombre expresa una organización elegida por sus usuarios, no un estado universal de finalización.
_Avoid_: Lista personal, estado global.

**Tarea**:
Unidad de trabajo organizada en una columna de un tablero.
Conserva una misma identidad en tablero, Mis tareas, búsqueda, vistas guardadas, novedades y enlaces privados. Columna, completado y programación son dimensiones independientes.
_Avoid_: Pendiente como entidad diferente, cumpleaños como trabajo para completar.

**Tarjeta**:
Representación visible de un elemento en una columna. Puede representar una tarea o una fecha de cumpleaños; no constituye una copia independiente del elemento que representa.
_Avoid_: Tarea como sinónimo obligatorio de toda tarjeta.

**Usuario**:
Persona identificada que utiliza la aplicación. No es sinónimo de propietario de todos los tableros a los que accede.
_Avoid_: Cuenta como sinónimo de tablero, cliente.

**Habilitación de acceso**:
Autorización para utilizar la aplicación, distinta de la identidad de la persona y de su pertenencia a un tablero.
_Avoid_: Login, invitación de tablero como sinónimos de acceso global.

**Administrador de la aplicación**:
Persona que decide quién está habilitado para usar la aplicación. Esta función es distinta de ser propietario de un tablero.
_Avoid_: Dueño de todos los tableros, responsable de todas las tareas.

**Membresía de tablero**:
Pertenencia de un usuario a un tablero con un rol que delimita sus permisos en ese tablero.
_Avoid_: Habilitación global, asignación de una tarea como sinónimo de acceso al tablero.

**Rol de tablero**:
Conjunto de permisos de un miembro dentro de un tablero. Es independiente de quién sea responsable de cada tarea.
_Avoid_: Prioridad, responsable, administrador global como roles equivalentes.

**Responsable**:
Usuario encargado de una tarea. No es sinónimo de propietario de la tarea ni de editor exclusivo.
_Avoid_: Propietario de la tarea como sinónimo de responsable.

**Mis tareas**:
Vista personal que reúne las tareas asignadas al usuario en los tableros a los que tiene acceso. Representa las mismas tareas de origen, no copias ni un tablero adicional.
_Avoid_: Bandeja con tareas duplicadas, traslado al tablero personal.

**Fecha límite**:
Día para el que se espera haber terminado una tarea, sin una hora específica. No es sinónimo del momento en que debe aparecer un aviso.
_Avoid_: Recordatorio como sinónimo de vencimiento.

**Recurrencia**:
Patrón que expresa cuándo se repite una actividad, por ejemplo ciertos días de la semana o todos los días. No indica por sí solo cómo se completan o acumulan sus repeticiones.
_Avoid_: Recordatorio como sinónimo de repetición.

**Serie**:
Actividad repetida que reúne una regla de recurrencia y sus ocurrencias. Cambiar una ocurrencia no equivale a cambiar toda la serie. Programar de nuevo una tarea que dejó de repetir crea otra serie; la procedencia histórica no equivale a pertenencia vigente.
_Avoid_: Tareas independientes con el mismo título.

**Columna de aparición**:
Columna elegida para las nuevas ocurrencias de una serie. Es distinta de la ubicación actual de una ocurrencia que alguien ya movió.
_Avoid_: Columna obligatoria Pendientes, etapa inicial universal del flujo.

**Programación**:
Configuración temporal opcional de un elemento: su fecha, su repetición y, cuando corresponda, su aparición anticipada. Estas propiedades expresan decisiones distintas.
_Avoid_: Recurrencia obligatoria, notificación externa implícita.

**Completado**:
Condición que indica que una tarea fue realizada. Es independiente del tablero y de la columna en que se organiza.
_Avoid_: Borrado, cambio de columna como sinónimo automático de completado.

**Tarea vencida**:
Tarea no completada cuya fecha límite ya pasó. El vencimiento no significa que la tarea deje de existir ni que haya sido realizada.
_Avoid_: Tarea descartada, repetición reemplazada.

**Ocurrencia**:
Realización correspondiente a una fecha dentro de una actividad recurrente. No es la actividad completa ni su patrón de repetición.
_Avoid_: Serie completa como sinónimo de una sola repetición.

**Ocurrencia reemplazada**:
Realización histórica que dejó de ser la pendiente vigente al aparecer una posterior. No equivale a completada ni eliminada.
_Avoid_: Tarea pendiente actual, completado automático.

**Cumpleaños**:
Fecha anual asociada a una persona, que puede representarse mediante una tarjeta en una columna. No es una tarea ni tiene condición de completado.
_Avoid_: Tarea anual de saludar como sinónimo de cumpleaños.

**Aparición anticipada**:
Visibilidad de una nueva ocurrencia antes de su fecha límite, con una anticipación elegida para su serie. No cambia la fecha límite ni mueve una tarjeta ya existente entre columnas.
_Avoid_: Movimiento programado, notificación externa, adelanto del vencimiento.

**Checklist**:
Lista sencilla de pasos marcables dentro de una tarea. No es una colección de tareas independientes con responsables o fechas propios.
_Avoid_: Subproyecto, jerarquía de subtareas configurables.

**Paso**:
Elemento de la checklist de una tarea, con texto y condición de realizado. Marcarlo no equivale a completar la tarea que lo contiene.
_Avoid_: Tarea independiente, ocurrencia de una serie.

**Mención**:
Referencia explícita a un miembro del tablero dentro de una conversación de tarea. No equivale a asignarle la tarea ni a darle acceso al tablero.
_Avoid_: Invitación, asignación de responsable.

**Novedad**:
Aviso personal dentro de la aplicación sobre un evento relevante del trabajo compartido. No es una tarea adicional ni una notificación externa.
_Avoid_: Recordatorio de calendario, copia de tarea, historial exhaustivo del tablero.

**Etiqueta**:
Clasificación opcional, plana y propia de un tablero, con nombre y color; clasifica tareas y cumpleaños sin cambiar columna, responsable, prioridad ni completado. Las nuevas ocurrencias reciben la selección activa de su plantilla al generarse; esa selección es independiente de la de cada ocurrencia.
_Avoid_: Estado de trabajo, catálogo global, jerarquía de proyectos.

**Favorito**:
Preferencia de una persona para encontrar un tablero dentro de Tableros. Solo conserva visibilidad mientras tenga acceso; no cambia propiedad, permisos ni favoritos de otros.
_Avoid_: Tablero compartido con todos, carpeta, entrada nueva obligatoria del menú global.

**Vista personal guardada**:
Consulta personal guardada con nombre que conserva texto, alcance, visibilidad de completadas e historial de repeticiones, filtros y orden dentro de Búsqueda o Mis tareas. Consulta datos autorizados actuales y recalcula fechas relativas; modificar temporalmente sus filtros no cambia su definición guardada.
_Avoid_: Tablero adicional, vista pública/compartida, snapshot de tareas, permiso permanente de lectura.

**Actividad de tarea**:
Registro de cambios de responsable, fecha, columna, completado y recuperación, con actor, fecha/hora y valores anterior/nuevo cuando corresponda, dentro del detalle. Distingue atribución histórica, Sistema y actividad importada.
_Avoid_: Conversación, bandeja de novedades, historial de ocurrencias, versiones del texto de comentarios o restauración de valores antiguos.

**Copia puntual**:
Nueva tarea dentro del mismo tablero, con identidad propia y campos acotados por E04. Copiar una ocurrencia, incluso histórica autorizada, no modifica el origen ni crea una serie y toma sus etiquetas activas propias, no las de la plantilla.
_Avoid_: Nueva repetición programada, duplicar conversación/archivos/permisos, trasladar entre tableros.

**Enlace privado a tarea**:
Dirección estable de una tarea u ocurrencia concreta. Quien la abre debe autenticarse, estar habilitado y conservar acceso al tablero.
_Avoid_: Invitación, enlace público, autorización por conocer la dirección.

**Tema personal**:
Preferencia claro, oscuro o sistema que conserva identidad visual, contraste y estados de la aplicación.
_Avoid_: Diseño compartido del tablero, editor de colores, contenido de una tarea.

**PWA**:
Acceso instalable a la misma aplicación web, sujeto a compatibilidad verificada. Conserva login, enlaces privados y el contrato online con borradores durante la sesión.
_Avoid_: App nativa, acceso sin autenticación, sincronización offline, permisos push implícitos.

**Vista pendiente de revisión**:
Vista personal guardada cuya consulta no puede mostrar resultados porque alguna referencia explícita dejó de existir o de estar permitida. Requiere revisar y confirmar sus condiciones, guardando explícitamente cualquier corrección; no es una consulta válida sin coincidencias.
_Avoid_: Vista vacía, permiso recuperado automáticamente, filtro descartado en silencio.

**Búsqueda unificada**:
Consulta que encuentra coincidencias en distintos tipos de contenido autorizado y muestra su tipo, campo y contexto de origen. Escribir presenta sugerencias por relevancia; elegir un destino abre tablero, tarea o comentario, y elegir una etiqueta aplica un filtro concreto. La lista de tareas resultante conserva su orden personal.
_Avoid_: Acceso global sin membresía, ejecución automática al escribir, paleta de comandos de escritura.
