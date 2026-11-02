# Cierre funcional del MVP 1.0

Actualización documental C-100–112 (27/10/2026): calendario CF-04/07/09, avisos/cuota/enlaces CF-15/16/18, preferencias/búsqueda CF-13–14 y ampliaciones CF-22–27. Complementa revisión base; todas las P/E se conservan.

Consolidación vigente27/10/2026: C-112 resuelve los dos huecos funcionales de auditoría; [DT-0.1](./DISENO-TECNICO-MVP-1.0.md) fija diseño recomendado y verificaciones G01–G08 pendientes. Los registros de revisiones anteriores son antecedentes, no nuevas preguntas de producto.

Estado: **cierre funcional 0.6, P01–P26 y E01–E07 incorporadas al alcance actual por C-99; brechas técnicas y detalles abiertos identificados. No autoriza implementación**.

Aceptación C-99: 24 de octubre de 2026. Consolidación documental: 25 de octubre de 2026.

Este documento reúne recomendaciones y acuerdos incorporados en [MVP 1.0](./MVP-1.0.md) y [spec 0001](./0001-auth-collaboration.md), hasta C-112. C-71–83 recogen cierre funcional; C-84–91 navegación/edición, C-92 respaldo, C-93 entrada privada, C-94 permisos, C-95 errores y C-96–98 primer uso/invitaciones/recuperación. C-99 acepta todas las filas P01–P26 y E01–E07 del [anexo Plane](./PROPUESTAS-DESDE-PLANE.md), incluidas las precisiones allí presentadas. E01–E07 forman parte del alcance actual: ya no son backlog externo al MVP. La [matriz de permisos, revisión 0.3](./MATRIZ-PERMISOS-MVP-1.0.md) centraliza actores y facultades. C-100–112 cierran las precisiones funcionales identificadas; DT-0.1 define el diseño recomendado y G01–G08, todavía sin evidencia de implementación.

Resumen vigente: aceptados admisión/invitaciones, catálogo/fechas, reapertura solo vigente, restauración sin atrasos, cumpleaños, recuperación, traslado antes de borrar columna, moderación y búsqueda/preferencias. Novedades leídas/no leídas caducan a 90 días; 20 adjuntos incluyen recuperables. Corrección: propietario debe elegir sucesor para salir; automática por antigüedad solo protege ante fallo excepcional. Administrador puede reasignar después. Menciones de quien sale quedan texto sin vínculo y no se reactivan al volver; tampoco se recuperan roles/asignaciones ni avisos atrasados. C-94/C-98/C-110 cierran restauración por causa y excepciones; C-92 fija reemplazo/importación. Restan implementación, verificaciones técnicas y preparación operativa según DT-0.1.

Ampliación C-99: captura explícita, jerarquía de detalle/tarjeta, navegación accesible y móvil verificable, filtros/preferencias personales sincronizadas, enlace privado a tarea, español inicial, tableros favoritos y atajo de búsqueda; además etiquetas, vistas personales guardadas, tema claro/oscuro/sistema, duplicación puntual, actividad mínima, PWA online y lectura por lote de novedades visibles. Las garantías P16–P25 se incorporan al diseño técnico necesario y P26 a la aceptación. No se ejecutaron las pruebas ni se implementó ninguna de estas funciones en esta revisión documental.

## A. Uso cotidiano — aceptado en esta conversación

- Guardado con estados veraces: guardando, guardado y error. No anunciar persistencia antes de confirmación del servicio.
- Sin conexión se puede consultar contenido ya cargado, con aviso de posible desactualización; conservar texto que se estaba escribiendo. No se promete edición offline sincronizada ni recarga offline completa.
- Conflictos sobre el mismo contenido no sobrescriben silenciosamente: conservar borrador y pedir revisar cambios ajenos.
- Al retirar a un responsable, conservar tareas, dejar pendientes y futuras repeticiones sin asignación a esa persona y conservar autoría histórica. Tableros sin otros miembros siguen la excepción de borrado recuperable acordada.
- Recordar orden, filtros y visibilidad de completadas como preferencias personales, sin alterar vistas de otros.

## B. Acceso, propiedad y permisos

### CF-01 — Admisión e invitación

Contrato confirmado: administración mínima para habilitar un correo Google verificado, vinculándolo a su identidad estable tras el primer acceso válido. Estado pendiente de primer ingreso, activo o suspendido. Sin directorio global de correos para miembros comunes; elegir responsables solo entre miembros del tablero.

Invitaciones de tablero de un uso, revocables y válidas por 72 horas. **C-97/C-98:** directa a una identidad habilitada por correo exacto, visible para esa persona en Tableros y aceptable/rechazable; genérica por enlace transferible entre destinatarios elegibles. No se envía correo ni se habilita globalmente por invitar. Una directa pendiente por persona/tablero; repetir muestra existente, renovar vencida es explícito y miembro actual no recibe otra. Preview solo tras validar sesión/habilitación/invitación: nombre de tablero, invitador y rol; ningún contenido privado. Un usuario ya miembro o no habilitado no consume el enlace. Consumo concurrente concede acceso a un único nuevo miembro. Revocar las invitaciones pendientes del emisor que pierde facultades y las del tablero borrado; restaurar no las reactiva.

### CF-02 — Salida voluntaria y reasignación

**Confirmado y corregido por C-80:** colaborador puede salir; propietario debe elegir sucesor habilitado para salir. El flujo no ofrece omitir esa elección. Administrador puede cambiar propietario posteriormente sin convertirse en miembro lector. Si no quedan otros miembros, confirmar borrado recuperable del tablero. Retirada administrativa mantiene elección explícita por el administrador. Un tablero activo nunca puede carecer de propietario válido.

**Protección excepcional confirmada:** si por inconsistencia o fallo se pierde propietario fuera del flujo válido, reasignar al miembro habilitado con mayor antigüedad en el tablero. No es una opción de salida ni una vía para eludir selección; ante elección normal inválida, bloquear salida y pedir otra. Propuestas técnicas: antigüedad de membresía continua, desempate estable, operación atómica, registro/aviso de reparación y cierre de operaciones mientras se resuelve una inconsistencia. Si no hay candidato, aplicar recuperación de tablero sin miembros y escalar al administrador sin dejarlo activo huérfano. Cambios administrativos ordinarios seleccionan miembros habilitados; restauración sin miembros conserva excepción de incorporar explícitamente al nuevo dueño.

**Reingreso confirmado C-81:** nueva membresía con permisos otorgados explícitamente; no devolver rol, asignaciones, menciones activas ni avisos de cuando estuvo afuera. Las menciones antiguas siguen texto aunque vuelva la misma identidad.

No agregar eliminación autónoma de la cuenta Google/Auth como función del MVP.

### CF-03 — Autoría y moderación

Comentarios planos en orden cronológico, con autor/fecha y marca de edición. Solo el autor edita el texto. Autor puede borrar el suyo; propietario puede moderar comentarios y borrar archivos de su tablero. Quien subió un archivo puede borrarlo mientras conserve membresía. Los colaboradores pueden editar tareas, pasos y series, pero no reescribir comentarios ajenos. Menciones solo a miembros actuales.

**Nueva regla confirmada:** cuando alguien deja de pertenecer al tablero, sus menciones existentes quedan como texto literal del nombre que mostraban, sin enlace, referencia activa a perfil ni destinatario de notificaciones. Esto se aplica a contenido que pueda recuperarse después, no solo a comentarios visibles. Propuesta técnica: desvincular el destino de mención al retirar membresía y conservar únicamente la representación textual correspondiente; verificar caches y restauración. No se elimina la autoría histórica de comentarios por confundirla con menciones. Si esa persona vuelve, no revincular menciones viejas ni emitir avisos retroactivos; una mención nueva sí puede dirigirse al miembro actual.

Comentario/archivo borrado por su autor: restaurable por autor con acceso vigente o propietario. Borrado por propietario como moderación: solo propietario restaura. Limpieza administrativa de archivos: solo administrador restaura, verificando tablero y propietario válidos. Así la recuperación no elude moderación. Conservar señal de comentario eliminado sin su texto visible; no incorporar un historial de versiones de comentarios.

## C. Calendario y series

### CF-04 — Catálogo e inicio/final

**Catálogo confirmado:** cada N días; cada N semanas con días seleccionados; cada N meses por número de día o por ordinal semanal; cada N años por fecha o por ordinal semanal en un mes. Finales sin final, por fecha o por N repeticiones, y previsualización de próximas fechas confirmados. Detalles candidatos: «laborables» lunes a viernes sin feriados, muestra de cinco fechas, sin confundirla con validación completa.

C-110 confirma inicio explícito y anclaje semanal lunes–domingo a semana de inicio. Finales: sin final, hasta fecha inclusiva o N fechas de ocurrencia. C-110: contar fechas efectivas, no completados; excluir consume fecha, pero quinto lunes inexistente no genera una que contar. Eliminar repetición no extiende final. La fecha de inicio es la primera fecha elegible de vencimiento, no un bloqueo a la anticipación. Al crear desde una tarjeta ya visible, esa tarjeta es la actual, no se oculta ni duplica; la previsualización debe identificar su fecha y cuál será la primera futura. Inicio en pasado no genera tarjetas para cada fecha omitida: advertir y calcular una sola vigente según el calendario.

### CF-05 — Zona horaria y fechas difíciles

Zona horaria por tablero, inicialmente la del creador. Solo propietario la cambia, con previsualización de efectos futuros; todos ven el mismo día elegido. «Hoy» y «vencida» usan la zona del tablero, también en Mis tareas, con contexto visible si hay tableros en zonas diferentes. Durante el día límite vence hoy; al día siguiente está vencida. Ninguna conversión cambia la fecha que escribió el usuario.

**Confirmadas:** zona por tablero inicialmente la del creador, regla mensual de último día disponible sin desplazar ancla, 29 de febrero usa 28 en años no bisiestos y quinto lunes inexistente omite ese mes. «Último lunes» siempre elige el último. Cambiar zona no reescribe historial ni duplica activaciones; solo propietario según C-94, con preview. Mecanismo y pruebas siguen pendientes.

### CF-06 — Reabrir y consultar ocurrencias antiguas

**Confirmado:** solo reabrir una ocurrencia que siga siendo la vigente y todavía no tenga una posterior activada; las antiguas quedan consultables en historial, sin volver a pendientes. Aplicar aunque la posterior esté completada, para no retroceder el calendario. Mostrar la razón al intentar reabrir. Una tarea puntual completada puede reabrirse desde detalle sin esa restricción.

Historial compacto dentro de la serie, con fechas/estados y acceso a cada ocurrencia, incluidos sus comentarios/archivos. Cargar por páginas, no todas las tarjetas históricas en el tablero. Distinguir completada, reemplazada y eliminada recuperable: ninguna significa automáticamente otra. El grupo de completadas del tablero puede cargar más resultados progresivamente sin borrar datos por antigüedad.

### CF-07 — Excepciones y cambios de regla

Editar una fecha de la actual no desplaza las próximas. C-110 exige nuevo vencimiento estrictamente anterior a la siguiente aparición; rechazar igualdad o posterior con explicación, conservando borrador. Mantener borrador para corregir; no decidir cuál eliminar silenciosamente.

Eliminar solo esta repetición registra exclusión: no se regenera, no vuelve la anterior y no se adelanta la próxima. No agregar un segundo botón «omitir» con el mismo efecto. Al editar la serie, preservar exclusiones que todavía correspondan a fechas de la nueva regla; informar cuáles dejan de aplicar y retirarlas al confirmar. No generar pasado retroactivamente. Una edición de serie debe presentar una próxima activación compatible con la actual; si pretende reemplazarla inmediatamente sin permitir respetar el acuerdo de actual intacta, pedir otro inicio/anticipación.

### CF-08.1 — Programar después de detener (C-112 / Q62)

Tras «Dejar de repetir», volver a programar la tarea actual crea una nueva serie. La confirmación explica que la anterior sigue detenida con su historial y que la misma tarjeta, con su identidad y contenido, será primera de la nueva según C-111: inicio explícito/compatible y conteo inicial, sin duplicado ni modificación silenciosa de fecha. No es reanudar la serie anterior: no reactiva sus exclusiones, no reinicia sus conteos ni genera pasado.

Se conserva la procedencia histórica sin hacer a la tarjeta dependiente del ciclo de borrado de la serie anterior. Borrar/restaurar la anterior no borra, recupera, reasigna ni detiene la tarjeta o serie nuevas. Los permisos actuales y siete días siguen vigentes. Historial de ambas permite comprender la transición sin presentar dos tareas actuales independientes. DT-0.1 §3 propone separar procedencia histórica de propiedad vigente del vínculo; C112-AC62 debe verificarlo.

| ID | Escenario | Resultado a verificar |
| --- | --- | --- |
| C112-AC62 | Detener serie A, programar B desde la misma tarea, consultar historiales y borrar/restaurar A. | A detenida conserva su pasado; B tiene la misma tarjeta como primera sin duplicarla ni regenerar pasado. B y contenido siguen intactos al borrar/restaurar A; conteos/exclusiones no se mezclan. |

### CF-08 — Completar, detener y finalizar

Completar deja la actual atenuada en su grupo y muestra próxima fecha; no crea la siguiente antes de tiempo. Dejar de repetir conserva actual e historial y cancela futuras, sin borrar información de la serie. La actual deja de estar sujeta a reemplazo y puede gestionarse como tarea puntual. Una serie finalizada por fecha/conteo conserva la última pendiente vencida, sin descartarla.

No incluir botón de reanudación de una serie detenida en este MVP: para volver a programar, usar el flujo de programación con un inicio explícito, sin reactivar pasado automáticamente. C-112 confirma que crea una nueva serie; la UI explica ese cambio y la independencia frente al borrado/restauración anterior (CF-08.1).

### CF-09 — Restaurar una serie

**Confirmado:** restaurar conservando el estado anterior: detenida sigue detenida; activa se reconcilia al calendario vigente, sin una pila de atrasos ni responsables retirados. C-110: si final pasó, como máximo última válida aun no materializada/vencida, sin intermedias ni sustituta de última excluida; fechas/final no se extienden. Generar como máximo vigente; una ocurrencia antigua restaurada conserva sus datos pero puede quedar histórica/reemplazada, sin reemplazar una posterior válida. Antes de confirmar mostrar fecha próxima/actual y advertir cambios de vigencia.

Si la columna fue eliminada, pedir destino válido; responsable retirado no se restituye. Restaurar una ocurrencia individual no restaura ni reactiva su serie eliminada. Restaurar el tablero es requisito para recuperar contenido dentro de él.

### CF-10 — Cumpleaños

**Ciclo confirmado:** fecha anual sin checkbox; sin anticipación configurada, visible todo el año y al día siguiente muestra la próxima fecha anual. Con aparición anticipada, visible desde D−X hasta el cumpleaños inclusive; luego se oculta hasta la siguiente ventana y su regla sigue disponible en Series. No se mueve automáticamente de columna. Alcance candidato complementario: sin responsable de trabajo ni subtareas, visible a miembros del tablero, fuera de Mis tareas y sin estado vencido.

## D. Borrado y recuperación

### CF-11 — Borrar columnas

Columna vacía y sin referencias: confirmación simple. Con contenido o series: mostrar tareas presentes y series afectadas; elegir columna destino para trasladar contenido y para aparición futura, o cancelar. Para el MVP no ofrecer borrado masivo implícito de todo el contenido al eliminar una columna. Si es la única, crear explícitamente un destino o dejarla; el usuario puede borrar tareas/series por sus acciones específicas y luego eliminar la columna vacía.

Recuperar esa columna no deshace traslados que fueron confirmados ni mueve de vuelta tareas editadas después. Recupera la estructura eliminada; describir este alcance en confirmación, no prometer restaurar una foto completa del tablero.

### CF-12 — Ventana y permisos de recuperación

Siete períodos de 24 horas, medidos por servidor, con vencimiento visible. Incluir tareas, series, tableros, columnas, pasos, comentarios y adjuntos eliminados. No incluye deshacer modificaciones de texto ni versionado. Contenido dependiente sigue el borrado del padre, salvo que ya estuviera eliminado por separado: conserva su propio plazo y no revive al recuperar al padre.

Tareas: restauración por miembros que conserven permiso de edición. C-110 extiende recuperación ordinaria a series/columnas/pasos por propietario o colaborador actual con edición en plazo; no revierte traslados al recuperar columna. Tablero: propietario habilitado; si fue eliminado por retirada del dueño, administrador elige nuevo propietario habilitado. Comentarios/archivos: permisos de CF-03. No restituir personas retiradas, invitaciones viejas ni asignaciones inelegibles. Restauración y purga concurrentes requieren un resultado único verificable. Tras vencer el plazo no se permite restaurar aunque la purga física aún esté en cola.

**C-99/P21 confirmado:** registrar causa, actor, plazo y dependencias de cada borrado; consultas/recuperaciones autorizadas y purga coordinada con restauración/cuota. El mecanismo no se reduce a un campo de borrado. Restaurar padre no revive hijos eliminados antes por separado, membresías ni invitaciones. Modelo, transacciones y frecuencia operativa aún se verifican técnicamente.

## E. Vistas personales, búsqueda y avisos

### CF-13 — Preferencias y orden

**C-99/P06 confirmado:** guardar orden, filtros y visibilidad de completadas por usuario y contexto de vista/tablero, sincronizados entre sus dispositivos; defaults y reinicio explícito, sin cambiar a otros ni el orden manual común. Scroll/columna activa son contexto de navegación. Pestaña abierta conserva cambios locales hasta guardar correctamente. Completadas inicialmente expandidas, para respetar el acuerdo de visibles por defecto; recordar colapsado/ocultación elegidos. Orden por vencimiento y creación ya acordados. C-104 confirma desempate por creación ascendente e identidad estable, completadas por completado reciente y concurrencia con combinación de preferencias diferentes y revisión si se modifica la misma. C-106/CF-13.2 cierra defaults/reinicio; resta mecanismo técnico. Favoritos/vistas/tema se concretan en CF-21–23.

### CF-14 — Búsqueda

C-107 amplía título/descripción a búsqueda unificada con sugerencias por campo/tipo, incluyendo comentarios y tableros; contratos restantes en CF-14.1. Filtros combinables por tablero, responsable incluido sin asignar, prioridad, estado y fecha. **C-99/P05 confirmado:** alcance visible, chips eliminables, Limpiar y accesos Hoy/Vencidas/Próximos 7 días/Sin fecha sobre el mismo buscador; Próximos desde mañana hasta hoy+7 inclusive en la zona de cada tablero, sin solapar Hoy. Mostrar fecha/tablero al buscar globalmente; sin lenguaje de consultas. Por defecto pendientes, con control explícito para incluir completadas aunque su grupo esté colapsado. Resultados únicos con tablero/columna y acceso al mismo detalle. E01 añade filtro por etiquetas y E02 vistas personales con nombre, sin vistas compartidas/públicas. Ctrl/Cmd+K y botón visible abren esta misma búsqueda conservando alcance inicial; no capturar escritura ni abrir una paleta de acciones generales (C-99/P14).

### CF-15 — Novedades

Aplicar destinatarios ya acordados y excluir autor de la acción. **C-99/P15 confirmado:** deduplicar por evento/destinatario, nunca por texto; si coincide asignación/mención/comentario en una acción, una novedad por destinatario, sin duplicados por reintentos. Una edición de comentario avisa solo por menciones nuevas, no por corregir texto ni por quitar/agregar repetidamente la misma mención al mismo usuario. C-111 confirma creador de serie para nuevas ocurrencias mientras conserve acceso; original conserva creador y retirado no se sustituye por owner.

Leída/no leída es personal; abrir desde bandeja marca leída después de verificar permiso. **Confirmada retención de novedades de 90 días, incluidas no leídas**, sin borrar tareas ni comentarios; mostrar ventana de conservación. Novedades de contenido inaccesible no muestran títulos/extractos. Tarea borrada pero tablero accesible: indicar no disponible, sin restaurarla al abrir. Estados de capacidad siguen avisos ya acordados; no generar correo/push.

**C-99/E07 confirmado:** acción explícita «Marcar visibles como leídas» con cantidad, sobre IDs actualmente cargados y autorizados de la bandeja propia. No incluye otras páginas ni novedades llegadas después. Revalidar permisos al aplicar y comunicar fallos parciales; no archivar, posponer ni convertir el alcance en «todas las del servidor». El contrato técnico debe precisar cómo se reconcilia el resultado sin repetir efectos.

## F. Archivos, enlaces y limpieza

### CF-16 — Unidades y límites operativos

**Confirmado C-82/C-99/P22:** 20 adjuntos por tarea incluyendo retenidos en recuperación; unidades decimales exactas de 24.000 bytes máximos por archivo y 200.000.000 bytes globales. Mostrar desglose activos/recuperables; borrar no libera plaza hasta purga. Ciclo reservar → cargar → verificar → publicar: contar reservas/activos/recuperables, verificar contenido y permiso al confirmar, liberar reservas fallidas y reconciliar objetos. Tipos permitidos `.txt`/`.md`; binario renombrado rechazado. Detalles técnicos aún candidatos: política exacta de codificación UTF-8, descarga sin ejecutar HTML/renderizar Markdown activo, duración de reserva, limpieza y exposición residual de enlaces. Sin nueva cuota por usuario/tablero. Control de ritmo de cargas y tamaño de otros campos se fija técnicamente con pruebas, no como sistema de planes comerciales.

Conservar contabilización de reservas/archivos activos/recuperables, borrado solo tras 7 días y bloqueo de cargas que excedan cuota. Avisos de 160/200 MB deduplicados por usuario y nivel; C-111: nuevo aviso por persona/nivel solo ante nuevo cruce tras bajar del umbral y 24 h desde aviso anterior, sin recordatorio por permanecer encima. El mensaje de carga bloqueada siempre es inmediato, no depende de ese período.

### CF-17 — Gestión administrativa sin lectura global

Propietarios pueden limpiar archivos en sus tableros con contexto completo; administrador no miembro usa referencia de archivo, tamaño, fecha, referencia de tablero, propietario y estado de tarea. No exponer texto de tarea/comentario, contenido del archivo ni nombre de archivo si puede revelar información privada. Selección explícita, confirmación y registro de quién borró; propietario recibe aviso de limpieza administrativa en su tablero. No es acceso global a conversaciones ni descarga de archivos.

### CF-18 — Enlaces clickeables

Autodetectar HTTPS/HTTP y `www.` en descripción/comentarios y en textos de checklist al visualizar el detalle. En título compacto conservar acción de abrir tarea; la URL del título también es abrible desde el detalle mediante enlace distinguible de edición. Dominios sin esquema ni `www.` quedan texto para evitar falsos positivos; excluir puntuación exterior del destino. Sin previsualizaciones ni descargas del servidor. Abrir al hacer clic, con aislamiento de nueva pestaña y sin ejecutar esquemas locales/activos. Markdown pegado no habilita HTML arbitrario.

## G. Respaldo y transición — sin ejecución remota

### CF-19 — Exportación e importación

**Actualización C-92:** el usuario aprueba el comportamiento presentado de respaldo completo, importación por propietario con previsualización/reemplazo, compatibilidad v1, permisos destino intactos, responsables compatibles, ausencia de avisos históricos y series sin pila de atrasos, previo recuperable 7 días contado en cuota y rechazo seguro sin contenido parcial. Los apartados siguientes conservan detalles candidatos de formato, mapping, snapshot, exclusiones y ejecución que todavía requieren diseño/revisión; no afirmar que ya existe una solución técnica validada.

Conservar capacidad de exportar/importar y leer formato original v1. Proponer nuevo formato versionado de contenido con series/fechas/checklist/comentarios y un paquete que incluya adjuntos permitidos; no tokens, admisión ni membresías reutilizables. Exportaciones limitadas al contenido autorizado; no a papeleras ajenas ni historial administrativo global. Atribución importada queda como referencia histórica, no identidad autenticada falsificada.

Solo propietario importa en tablero y revisa previsualización/alcance destructivo. Asignaciones se mapean únicamente a miembros actuales o quedan sin asignar con aviso; no invitar automáticamente. Validación completa, cuota y reemplazo atómico lógico; fallo no deja medio tablero importado. Estado previo reemplazado debe ser recuperable 7 días, sujeto a capacidad disponible y sin sobrescribir cambios posteriores al restaurar. Este caso exige concretar mecanismo técnico antes de aprobar la viabilidad, no prometer atomicidad entre servicios sin diseño.

#### CF-19.1 Evidencia del comportamiento original

Inspección local de `src/lib/export.ts`, `src/lib/import.ts` y `src/lib/types.ts`: exportación JSON versión 1 con slug, columnas (título/posición) y tareas (título/descripción/prioridad/posición). No contiene identidad ni las funciones nuevas de este MVP. Importación actual valida archivo de hasta 2 MiB, hasta 50 columnas y 500 tareas por columna, y luego borra columnas existentes y crea contenido mediante múltiples llamadas. Un fallo intermedio puede dejar contenido parcial; no es un reemplazo atómico. No se ejecutó importación ni se inspeccionaron datos remotos para esta revisión.

Conservar lectura de v1 y validar sus restricciones, sin asumir que su techo de 2 MiB alcanza para el nuevo formato completo. No confundir esta importación de respaldo con subir adjuntos de 24 KB: son operaciones distintas, pero el contenido importado sí debe cumplir cuotas y validaciones de las entidades finales.

#### CF-19.2 Contrato funcional y detalles de diseño pendientes

**C-99/P24 confirmado:** separar respaldo portable por tablero de recuperación operativa de la instancia. El formato de contenido es versionado, conserva lectura v1 y requiere preparación/validación/publicación controlada. El respaldo operativo incluye base, objetos y configuración necesaria, con ensayo de restauración fuera de producción; no se incorporan secretos a la exportación de un tablero. Contenedor, mapeos y mecanismo entre base/Storage siguen pendientes. C-101 incluye catálogo activo completo y asociaciones de etiquetas en exportación/importación; reconstruye relaciones dentro del destino. Validación del formato sigue técnica; C-105 incluye eventos vigentes de tareas exportables con fecha/atribución histórica identificada y sin avisos retroactivos. Preferencias, favoritos y vistas personales siguen fuera del respaldo de tablero.

**Exportar:** respaldo de un tablero completo autorizado, no solo las tarjetas cargadas/filtradas en el navegador. Incluir columnas/orden, tareas y completados, fechas, prioridades, checklist, comentarios con atribución histórica, series/ocurrencias conservadas, cumpleaños, enlaces y archivos activos permitidos. Excluir contenido borrado en recuperación, avisos personales, preferencias de usuario, credenciales, tokens de invitación, habilitaciones y permisos reutilizables. Archivo exportado contiene información privada: advertir que compartirlo entrega una copia que la app no puede revocar. No traer al paquete los documentos externos enlazados.

**Formato:** mantener compatibilidad de lectura del JSON v1 y proponer un nuevo paquete versionado para datos más adjuntos. Su contenedor concreto/librería queda para diseño técnico; no imponer una nueva dependencia por esta spec. El paquete debe permitir relacionar archivos con tareas, validar integridad y mantener historial sin crear nuevas identidades de usuario. Autoría importada se marca histórica/importada, no comentario nuevo firmado por un usuario local.

**Importar:** se mantiene flujo original de reemplazar el contenido del tablero destino; solo propietario, con previsualización y confirmación explícita. No se introduce mezcla/deduplicación ni importación global de toda la aplicación. Para una copia separada, el usuario crea otro tablero y luego importa allí. El archivo no cambia propietario, miembros, URL ni identidad del tablero elegido. Aplicar contenido/orden/zona propuestos mostrando diferencias; mantener las preferencias personales fuera del archivo.

**Responsables y menciones:** asignar por mapeo explícito a miembros actuales; sin coincidencia verificada, dejar sin asignar y advertir. No vincular por nombre visible ni reutilizar IDs de otro entorno sin validación. Menciones importadas quedan texto, sin vínculo ni notificación. No invitar personas ni reactivar accesos por importar. No emitir una avalancha de avisos de comentarios históricos; cualquier aviso de reemplazo administrativo debe definirse aparte.

**Series:** preservar regla, estado y referencias históricas. Previsualizar la vigente y próximas fechas; activa se reconcilia sin pila de atrasos, detenida sigue detenida. Importar no cuenta como completar ni como evento nuevo de cada comentario/archivo. Validar destinos, calendario, responsables y exclusiones antes de confirmar; conflicto o ambigüedad bloquea importación completa con explicación.

**Resguardo del contenido reemplazado:** proponer snapshot recuperable de ese reemplazo por 7 días, privado y con permisos de propietario vigentes; el estado anterior cuenta en capacidad mientras se conserva. Recuperar esa versión advierte que reemplazará contenido actual y requiere una nueva previsualización, sin revivir membresías ni borrar silenciosamente trabajo posterior. Este resguardo puntual por importación no promete versionado de cada edición de tarea. Si no hay capacidad para preservar previo más nuevo, rechazar antes de borrar; no liberar cuota purgando anticipadamente el previo.

**Fallo o concurrencia:** validar paquete completo, autoridad y capacidad antes de publicar el reemplazo. Tablero no debe quedar parcialmente importado ni perder cambios hechos desde la previsualización: detectar versión modificada y pedir revisión nueva. El contrato técnico debe coordinar preparación de archivos y cambio de datos, con limpieza de temporales y reintentos idempotentes. No afirmar que existe una transacción única entre base y Storage. Si ese contrato no es viable en el stack/plan, explicar limitación y revisar la propuesta antes de desarrollar.

**Validaciones y cuotas:** cada adjunto `.txt`/`.md` de hasta 24 KB; máximo 20 por tarea y 200 MB globales contando recuperación/reservas. Límites del paquete completo, cantidad de entidades, tamaño expandido y tiempo de proceso por fijar tras evaluación técnica. Si se usa archivo contenedor, rechazar rutas fuera del paquete, entradas maliciosas y expansión desmedida. No cargar enlaces externos desde el servidor. Importación no es un atajo para archivos prohibidos, miembros nuevos o campos ejecutables.

#### CF-19.3 Recorridos candidatos de aceptación

| ID | Caso | Resultado a verificar según contrato y detalles pendientes |
| --- | --- | --- |
| BACKUP-01 | Exportar con filtros activos/paginación. | Respaldo incluye todo contenido autorizado en alcance, no solo la vista visible. |
| BACKUP-02 | Exportar → importar en tablero de prueba. | Conserva contenido/relaciones/calendario acordados; no importa permisos ni genera avisos históricos. |
| BACKUP-03 | Importar JSON v1 válido. | Conserva columnas/tareas originales; campos nuevos con defaults explícitos (sin fecha, sin responsable, sin serie, pendientes). |
| BACKUP-04 | Persona/archivo/serie incompatible o cuota insuficiente. | Explicación antes de reemplazar; el tablero previo queda intacto. |
| BACKUP-05 | Falla de red o Storage durante preparación. | No publica medio tablero; reintentar no duplica ni consume cuota dos veces. |
| BACKUP-06 | Otro miembro cambia contenido después de previsualización. | Detiene reemplazo y obliga a revisar versión actual; no pisa cambios silenciosamente. |
| BACKUP-07 | Recuperar reemplazo dentro/fuera de plazo. | Dentro, confirmación de alcance y permisos actuales; fuera, no restaurable. Membresías anteriores nunca vuelven por el archivo. |
| BACKUP-08 | Archivo manipulado o v1 con tamaño/cantidad fuera de límites. | Rechazo seguro sin escritura parcial ni filtración de datos. |

Estos resultados no son pruebas ejecutadas ni autorización para ejecutar importaciones. Contenido/alcance presentados y reemplazo protegido están aprobados C-92; detalles técnicos y los casos no presentados aún requieren cierre y verificación antes de declarar implementable CF-19.

### CF-20 — Tableros existentes y corte

Antes de migrar, inventario explícito autorizado por el usuario y elección de dueño por tablero. No acceder ahora a datos remotos ni decidir que todos son del primer login. Proponer conservar todo contenido existente identificado, mapear campos originales sin cambiar diseño, y revisar los casos que no tengan dueño asignado antes del corte. Respaldo/ensayo con datos ficticios y aprobación separada para infraestructura/despliegue. Un rollback nunca reabre anónimamente contenido que ya debe ser privado.

## G.1 Ampliaciones aceptadas desde Plane — C-99

Las siguientes capacidades forman parte de la spec actual. La columna pendiente identifica decisiones todavía necesarias para diseñarlas; no las relega a un backlog posterior ni habilita implementación.

| Contrato | Alcance aprobado | Detalle que resta cerrar |
| --- | --- | --- |
| CF-21 · Enlace privado y favoritos — P11/P13 | Copiar enlace estable a tarea/ocurrencia concreta; login recupera destino autorizado y renombrar tablero no lo rompe. Estrella personal y sección Favoritos dentro de Tableros, solo para tableros accesibles. Sin nueva entrada de drawer ni concesión de acceso. | Esquema exacto de rutas; persistencia/limpieza de favoritos revocados y resultado cuando el destino fue eliminado, respetando los mensajes genéricos y recuperación vigentes. |
| CF-22 · Etiquetas y vistas personales — E01/E02 | C-100–102: contrato en CF-22.1–3, con cupos activos, recuperación explícita, revisión de referencias y búsqueda tolerante a acentos/ñ. | C-103 cierra unicidad; validación técnica de importación/concurrencia/normalización. |
| CF-23 · Español y tema — P12/E03 | Español, modos Claro/Oscuro/Sistema y cambio sin perder editor. C-104: inicial Sistema, login aplica cuenta, modo fijo sincronizado y Sistema sigue dispositivo. | C-106 cierra defaults/reinicio; validación de contraste y mecanismos sin pérdida de borrador. |
| CF-24 · Duplicación puntual — E04 | C-101/C-104 fijan campos/destino/orígenes; C-105 confirma panel Crear copia, cancelación sin efecto, resultado con apertura opcional y revisión si cambió contenido copiable. CF-24.1–2. | Diseño técnico de validación/reintento; no editar original ni copiar eliminadas sin recuperar o cumpleaños. |
| CF-25 · Actividad mínima — E05 | C-105: actor/fecha-hora/valores anterior-nuevo en categorías E05, recientes primero/progresiva, 180 días sin reinicio, ocultar con tarea/purgar dependiente, atribución histórica/Sistema/Importada y respaldo de eventos vigentes. CF-25.1. | Diseño técnico de almacenamiento/consulta/purga/importación, sin nuevas categorías ni edición individual. |
| CF-26 · PWA online — E06 | C-109 fija matriz inicial, instalación opcional en cuenta/directa o manual, actualización avisada/elegida respetando borrador. CF-26.1. Mismo login/enlaces y contrato online. | Mecanismos de sesión/caché/actualización y pruebas reales por versión; no manifest como prueba de compatibilidad. |
| CF-27 · Novedades visibles por lote — E07 | C-109: una pulsación con cantidad sin leer cargada, conjunto fijo al pulsar, resultado por categorías y reintento de falladas autorizadas del original. CF-27.1. | Diseño de respuesta/reconciliación/concurrencia y pruebas. No futuras/no cargadas ni títulos revocados. |

### CF-22.1 — Etiquetas y vistas: primera ronda aprobada (C-100)

El 26/10/2026 el usuario respondió «Sí a las 7». Las siguientes reglas completan E01/E02 sin retirar ninguna P/E. Todavía no cierran todo el bloque.

1. **C100-Q1 · Facultades:** propietario y colaboradores habilitados crean etiquetas, cambian nombre/color y las aplican o quitan dentro del tablero. Solo el propietario elimina una etiqueta del catálogo. Renombrar conserva identidad, asociaciones y filtros. Administrador ajeno no obtiene permisos.

2. **C100-Q2 · Nombres y límites:** nombres de etiqueta de hasta 40 caracteres, únicos por tablero ignorando mayúsculas y espacios sobrantes; «Trabajo» y « trabajo » no crean opciones distintas. Máximo 100 etiquetas activas por tablero y 10 por elemento. Color elegido de una paleta accesible; puede repetirse entre etiquetas. Son límites iniciales de producto. Medición de caracteres y normalización Unicode se precisarán técnicamente; no se inventa aún la política de nombres en recuperación.

3. **C100-Q3 · Elementos etiquetables:** tareas y cumpleaños admiten etiquetas. Las series tienen una selección propia en la plantilla para próximas ocurrencias, distinta de la selección de una ocurrencia concreta. No convertir cumpleaños en tareas completables. C-101/Q8–9 cierra herencia y recuperación básica; casos restantes en CF-22.2; editar serie conserva la regla de no modificar silenciosamente la ocurrencia actual ni el pasado.

4. **C100-Q4 · Filtros:** varias etiquetas seleccionadas significan «Cualquiera de estas etiquetas» (OR); esa condición se combina con los demás filtros (AND). Por ejemplo, prioridad alta y Casa/Compras devuelve elementos de prioridad alta que tengan Casa o Compras. En alcance global cada etiqueta muestra su tablero y conserva identidad separada, aunque sus nombres coincidan.

5. **C100-Q5 · Contenido y alcance de la vista:** guarda texto de búsqueda, alcance, visibilidad de completadas, filtros y orden. «Todos mis tableros accesibles» es dinámico según membresías actuales; el alcance de un tablero específico permanece limitado a él. Mis tareas conserva la condición de asignación al propio usuario. Se recalculan fechas relativas y permisos; no se guardan resultados. Los nombres libres de vista no crean filtros nuevos: llamar «Esta semana» a una vista no convierte Próximos 7 días en semana calendario.

6. **C100-Q6 · Edición explícita de vistas:** modificar filtros de una vista abierta crea una variación temporal; no sobrescribe su definición. «Actualizar vista» persiste la modificación; «Guardar como nueva» crea otra vista; «Restablecer vista» vuelve a lo guardado. Se distingue de P06, que recuerda preferencias del último uso. C-101/Q12–14 fija bloqueo y conflicto; detalles restantes en CF-22.2.

7. **C100-Q7 · Catálogo personal de vistas:** hasta 50 vistas por persona en total; nombres de hasta 60 caracteres, sin duplicados dentro de cada contexto (Búsqueda o Mis tareas). «Esta semana» puede existir una vez en cada contexto. Solo su usuario las administra y se sincronizan entre dispositivos. C-101/Q13 cierra recuperación siete días; C-102 cuenta solo activas; C-103 aplica equivalencia de acentos/ñ, mayúsculas y espacios sobrantes a unicidad dentro de su contexto.

**Criterios nuevos, todavía sin ejecutar:**

| ID | Escenario y resultado esperado |
| --- | --- |
| C100-AC01 | Colaborador crea/renombra/cambia color/aplica/quita; eliminar catálogo se deniega. Propietario puede solicitar eliminación; su ciclo se cierra en la siguiente ronda. Admin ajeno no puede operar. |
| C100-AC02 | «Trabajo» y « trabajo » colisionan en el mismo tablero; otro tablero puede usar ese nombre. 40 caracteres y etiquetas activas 100 se admiten; 41 o alta 101 se rechazan. Se admite selección de 10, no 11. |
| C100-AC03 | Tarea y cumpleaños admiten selección; cumpleaños sigue sin completado. Plantilla y ocurrencia tienen selecciones distintas; herencia activa al generar según C-101. |
| C100-AC04 | Con Casa/Compras y prioridad alta se muestran elementos de alta con una o ambas etiquetas, una sola vez; se excluyen prioridad baja y elementos sin ninguna. Identidad de etiqueta siempre acotada a su tablero. |
| C100-AC05 | Abrir vista restaura texto, alcance, completadas, filtros y orden. Global se evalúa con accesos actuales, específica nunca se convierte en global y Mis tareas nunca incluye asignadas a otro. Referencias inválidas bloquean hasta revisión/confirmación según C-101. |
| C100-AC06 | Cambiar filtros y volver a abrir sin Actualizar conserva definición anterior; Actualizar modifica la misma vista; Guardar como nueva conserva original; Restablecer descarta variación temporal. No borrar vistas al reiniciar preferencias. |
| C100-AC07 | Vistas 50 en total admitidas, alta 51 rechazada; nombre de 60 caracteres válido, 61 inválido. Nombre exacto repetido se rechaza en el mismo contexto, permitido en el otro; otras personas no consultan ni administran esas vistas. |

**Estado posterior:** C-101/CF-22.2 resuelve parte de los pendientes de esta primera ronda. Solo permanecen abiertos los casos enumerados allí.

### CF-22.2 — Ciclo de vida e integración (C-101)

El 26/10/2026 el usuario aceptó Q8–Q14. Completan la primera ronda sin cerrar por inferencia casos restantes.

8. **C101-Q8 · Borrado de etiqueta:** eliminar la oculta de selectores y tarjetas sin borrar tareas/cumpleaños; conserva asociaciones para recuperación. Solo propietario actual puede restaurarla durante siete días; al vencer se purga. Nuevas ocurrencias no reciben etiquetas eliminadas. Vistas que la usan tienen una referencia no disponible. Colisiones de nombres/cupo y recuperación de asociaciones requieren casos restantes.

9. **C101-Q9 · Herencia:** cada ocurrencia nueva copia las etiquetas activas de la plantilla al generarse. Editar selección de ocurrencia solo la cambia a ella; editar plantilla solo afecta a las aún no generadas, nunca a la actual ni al pasado. Quitar Salud de hoy no la quita de mañana; quitarla de plantilla no la quita de hoy.

10. **C101-Q10 · Copia puntual:** conserva etiquetas activas del elemento origen. Si es una ocurrencia, toma su selección, no la plantilla. Mantiene exclusiones de E04: responsable, fecha, recurrencia, comentarios, archivos y permisos no se copian.

11. **C101-Q11 · Respaldo:** exportar tablero incluye catálogo activo completo, incluso etiquetas sin uso, y asociaciones de elementos exportados. Importar reconstruye dentro del destino sin vínculos a otro tablero por coincidencia de nombre. Exportaciones antiguas sin etiquetas se importan sin inventarlas. Vistas personales siguen fuera del respaldo de tablero.

12. **C101-Q12 · Vista por revisar:** referencia explícita a tablero, etiqueta o miembro inexistente/no permitido bloquea resultados hasta revisión y confirmación. Mostrar «Esta vista necesita revisión» y permitir quitar/reemplazar condición; ante acceso perdido, mensaje genérico sin nombres privados. No quitar condiciones silenciosamente. El alcance global dinámico sigue adaptándose a membresías vigentes.

13. **C101-Q13 · Recuperación de vistas:** eliminar oculta del selector, no modifica tareas y permite recuperar siete días solo a su usuario desde gestión del contexto. Restaurar revalida referencias y permisos actuales; si falla alguno, queda pendiente de revisión. Colisiones y cómputo del límite con recuperables aún por precisar.

14. **C101-Q14 · Conflicto de vistas:** si otro dispositivo cambia la definición, conservar variación temporal y avisar. Permitir cargar versión actual o guardar como nueva. Para modificar original, primero revisar su versión actual; ninguna sobrescritura silenciosa. Mecanismo de concurrencia se elige en diseño técnico.

**Criterios todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C101-AC08 | Borrar etiqueta no elimina elementos; oculta y no se hereda. Solo propietario actual restaura en siete días. Vencido se rechaza aunque purga siga pendiente. |
| C101-AC09 | Ocurrencia no cambia plantilla; plantilla no cambia generadas. Nueva ocurrencia recibe solo activas al generarse. |
| C101-AC10 | Copia de ocurrencia toma activas propias aun si difieren de plantilla; conserva exclusiones E04. |
| C101-AC11 | Exportar incluye etiqueta activa sin uso y asociaciones autorizadas; importación sin vínculo cruzado. v1 sin etiquetas no inventa; vistas fuera del respaldo. |
| C101-AC12 | Referencia explícita inválida bloquea vista completa hasta revisar/confirmar sin nombres privados revocados. Global sin esa referencia sigue adaptándose a acceso actual. |
| C101-AC13 | Borrar vista no toca tareas y solo su usuario recupera en siete días; referencia inválida deja pendiente de revisión. |
| C101-AC14 | Conflicto entre dispositivos conserva variación y permite cargar actual/guardar nueva; no sobrescribe original automáticamente. |

**Estado posterior:** restauración y revisión se completan en C-102/CF-22.3. Falta distinguir equivalencia de nombres para unicidad de coincidencia textual de búsqueda; validación de importación y mecanismos siguen técnicos.

### CF-22.3 — Restauración y búsqueda (C-102)

El usuario aprobó Q15–17 y Q19–20 y corrigió Q18 para búsquedas/filtros. No aceptó distinguir acentos y ñ en esas consultas.

- **Q15 · Cupos:** cuentan solo activos: 100 etiquetas/tablero, 10 etiquetas/elemento, 50 vistas/persona entre ambos contextos. Recuperables liberan lugar; restaurar consume cupo y se bloquea si no cabe, sin eliminar otros elementos.
- **Q16 · Nombres al restaurar:** se puede reutilizar nombre de objeto eliminado. Si colisiona al restaurar, renombrar uno explícitamente; conservar identidad original, sin fusionar ni trasladar asociaciones por nombre.
- **Q17 · Asociaciones:** preview de restauración identifica elementos que excederían diez etiquetas. Liberar espacio o elegir explícitamente no recuperar esa asociación. Aplicar solo cuando toda selección confirmada sea válida; no omisiones silenciosas, ocurrencias retroactivas ni restauración de tareas borradas.
- **Q19 · Reparación:** «Guardar corrección» actualiza definición y habilita consulta tras revalidar. Si vuelve la referencia original, revisar/confirmar basta; una condición ya quitada no se repone sola.
- **Q20 · Vista borrada durante edición:** conservar variación temporal autorizada; ofrecer guardar como nueva con nombres/cupos válidos o recuperar original por su vía en plazo. Guardado tardío no resucita; recuperación no aplica borrador automáticamente.

**Q18 corregida · Coincidencia textual:** búsquedas y filtros ignoran acentos y la diferencia ñ/n: «reunión»/«reunion» y «Peña»/«Pena» encuentran lo mismo. Conservar escritura original al mostrar/guardar. Es comparación textual, no fusión de identidades: seleccionar una etiqueta sigue filtrando por esa etiqueta y su tablero. No confiere permisos; C-107 amplía los campos buscables. C-103 confirma esa misma equivalencia para unicidad de nombres de etiquetas/vistas dentro de sus ámbitos.

**Criterios, todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C102-AC15 | Borrar libera cupo activo; recuperar con cupo lleno falla sin quitar otro elemento ni cambiar plazo. Los límites siguen 100/10/50. |
| C102-AC16 | Nombre reutilizado exige renombrar al restaurar; no fusión ni cambio de identidad/asociaciones por homonimia. |
| C102-AC17 | Elemento con diez activas muestra conflicto; usuario libera cupo u omite asociación expresamente. Solo se confirma selección válida completa; no añadir a ocurrencias generadas durante ausencia ni revivir tarea. |
| C102-AC18 | Buscar reunión/reunion o Peña/Pena encuentra mismos datos autorizados; conserva escritura original. Dos etiquetas distintas con coincidencia textual siguen teniendo identidades/filtros independientes. |
| C102-AC19 | Guardar corrección revalida y habilita; referencia original recuperada requiere confirmar revisión, y condición ya quitada no reaparece. |
| C102-AC20 | Guardado tardío de vista borrada no la resucita; nueva vista respeta cupos/nombres, y recuperar original no aplica borrador sin revisar. |

**Estado posterior:** C-103/CF-22.4 cierra equivalencia para unicidad. Validación/mapeo de importación, medición de caracteres y mecanismo de concurrencia siguen como trabajo técnico.

### CF-22.4 — Unicidad de nombres (C-103)

El usuario acepta Q18b el 26/10/2026.

**C-103 / Q18b:** al crear, renombrar o restaurar etiquetas y vistas, la unicidad ignora mayúsculas, espacios sobrantes, acentos y ñ/n. «Reunión»/«Reunion» y «Peña»/«Pena» colisionan dentro del mismo tablero para etiquetas, o del mismo usuario/contexto para vistas. Conservar escritura original; informar coincidencia y mostrar la existente solo si está autorizada. No fusionar automáticamente ni cambiar identidades/asociaciones. Nombres de otros tableros, usuarios o contextos no provocan colisión ni se revelan.

**C103-AC18b, pendiente de ejecutar:** crear/renombrar/restaurar con nombre equivalente se rechaza sin fusión ni cambios parciales, ofreciendo resolverlo; mismo nombre en otro ámbito permitido. Probar reunión/reunion, Peña/Pena, mayúsculas/espacios y escritura conservada. Identificadores, correos y URLs no se normalizan como nombres de producto.

Los contratos funcionales E01/E02 de estas rondas quedan cerrados. La medición de caracteres, normalización consistente en cliente/servidor, validación del formato e integración con restauración/concurrencia deben quedar en diseño técnico y pruebas; esto todavía no acredita implementación.

### CF-24.1 y CF-13.1 — Copia, orden y preferencias (C-104)

El 26/10/2026 el usuario acepta Q21–Q26. Las decisiones completan E04/P06/E03 sin modificar campos/permisos ya aprobados.

- **Q21 · Título de copia:** conservar título original como valor inicial, editable antes de confirmar, sin prefijo/sufijo automático. Dos tareas pueden compartir título. Editar ese valor modifica solo la tarea nueva.
- **Q22 · Destino:** proponer columna del origen y permitir elegir otra del mismo tablero. Insertar al final del orden manual; presentación personal por fecha/creación respeta su orden y no reorganiza otras tareas.
- **Q23 · Orígenes:** copiar tareas completadas y ocurrencias históricas aún disponibles y autorizadas, creando siempre tarea puntual pendiente. Eliminadas requieren recuperación previa. No concede edición/reapertura de la histórica. Cumpleaños no ofrecen Duplicar tarea.
- **Q24 · Tema:** valor inicial Sistema; tras login aplicar preferencia guardada de esa cuenta si existe. Claro/Oscuro se sincronizan y fuerzan ese modo; Sistema sigue el modo de cada dispositivo. Cambiar tema conserva editor/borradores.
- **Q25 · Orden:** desempatar por creación ascendente y luego identidad estable. Grupo de completadas por completado más reciente primero. Conservar Mis tareas por vencimiento ascendente con sin fecha al final y alternativa por creación ascendente.
- **Q26 · Concurrencia de preferencias:** combinar cambios de preferencias diferentes. Si ambos dispositivos modifican la misma desde una versión anterior, conservar elección local y ofrecer cargar guardada o revisar y conservar local, sin sobrescribir silenciosamente. Ejemplo: tema y ocultar completadas se conservan ambos.

**Criterios todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C104-AC21 | Título original propuesto y editable para la copia, sin tocar fuente ni agregar sufijo. |
| C104-AC22 | Columna origen por defecto, alternativa del mismo tablero; inserción al final manual y presentación respeta orden personal. No reordenar restantes. |
| C104-AC23 | Completada/histórica autorizada produce nueva puntual pendiente, fuente intacta; eliminada denegada hasta recuperar y cumpleaños sin acción de duplicar tarea. |
| C104-AC24 | Sin preferencia iniciar Sistema; login aplica cuenta correcta. Claro/Oscuro consistentes entre dispositivos, Sistema sigue cada dispositivo; tema conserva editor/borrador. |
| C104-AC25 | Vencimiento empatado ordena por creación y luego ID estable; completadas por completado descendente. Mis tareas conserva sin fecha al final. |
| C104-AC26 | Tema en un dispositivo y ocultar completadas en otro se combinan; mismo filtro editado desde versión anterior produce revisión conservando elección local y sin sobrescritura. |

**Estado posterior:** C-105/CF-24.2 cierra confirmación/resultado y cambio de origen. C-106 cierra defaults/reinicio; restan mecanismo de concurrencia y validación de temas. Actividad E05 se cierra en CF-25.1 y no se copia por E04.

### CF-24.2 y CF-25.1 — Confirmación de copia y actividad (C-105)

El 26/10/2026 el usuario acepta Q27–Q33. Se conservan campos y permisos anteriores.

- **Q27 · Confirmación de copia:** panel breve con título editable, columna destino y resumen de contenido copiado. «Crear copia» confirma; cancelar no crea nada. Confirmar éxito y ofrecer abrir nueva tarea conservando contexto de origen. Si origen es ocurrencia, aclarar tarea puntual.
- **Q28 · Origen cambiado:** actualizar preview y pedir revisar si cambió contenido que se copiará, conservando título/destino elegidos para nueva tarea. Comentario nuevo no interrumpe porque no se copia. Origen eliminado o acceso perdido bloquea creación.
- **Q29 · Actividad visible:** acción, actor, fecha/hora y valores anterior/nuevo cuando corresponda; recuperación indica quién/cuándo. Recientes primero y carga progresiva en detalle. Solo responsable, fecha, columna, completado y recuperación; sin versiones de título/descripción/comentarios.
- **Q30 · Retención:** 180 días desde cada evento, con ventana indicada en interfaz, independiente de los 90 días de novedades. Recuperar/importar no reinicia antigüedad ni revive eventos vencidos.
- **Q31 · Borrado:** ocultar actividad con tarea; restaurar muestra solo eventos no vencidos. Purga definitiva de tarea elimina actividad dependiente. Sin edición ni borrado individual de eventos; permisos actuales del contenido.
- **Q32 · Atribución:** conservar autor histórico sin vínculo que restituya acceso ni menciones activas. Distinguir Sistema y Actividad importada. Eventos importados conservan atribución histórica, identificada como importada, sin aparentar acciones verificadas de cuenta local.
- **Q33 · Respaldo:** incluir eventos vigentes de tareas exportables, con fecha/atribución histórica. Importar sin rejuvenecer ni revivir vencidos ni generar novedades por cambios antiguos. Contenido en papelera fuera de exportación de tablero.

**Criterios, todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C105-AC27 | Cancelar no crea; Crear copia confirma una nueva puntual y ofrece abrirla conservando origen. Reintento no duplica. |
| C105-AC28 | Cambio en contenido copiable pide revisar preview conservando título/destino; comentario nuevo no invalida. Borrado/acceso perdido impide crear. |
| C105-AC29 | Evento muestra actor/fecha-hora y valores anterior/nuevo de categorías E05; recuperación quién/cuándo. Recientes primero/carga progresiva; no versiones de textos. |
| C105-AC30 | Antes de límite de 180 días visible; al vencer no visible aunque purga pendiente. Restaurar/importar conserva antigüedad; independiente de novedades. |
| C105-AC31 | Borrado oculta actividad; recuperar no revive vencidos. Purga definitiva elimina dependientes; sin edición/borrado individual de eventos. |
| C105-AC32 | Actor retirado conserva atribución sin permisos/mención; Sistema distinguido; importado rotulado y no presentado como acción autenticada local. |
| C105-AC33 | Exportar/importar actividad vigente de tareas activas conserva fecha/atribución, sin avisos retroactivos ni eventos vencidos/papelera. |

**Estado:** confirmación de copia y contrato funcional de actividad cerrados en estas rondas. Faltan diseño técnico de formato, concurrencia/purga, atribución importada y pruebas, junto con mecanismos de preferencias y demás bloques.

### CF-13.2 — Defaults y acciones de consulta (C-106)

El 26/10/2026 el usuario acepta Q34–Q39.

- **Q34 · Defaults:** si no hay preferencia o tras reinicio: Tablero manual/sin filtros opcionales/completadas visibles y expandidas; Mis tareas todos los tableros accesibles/sin filtros adicionales/vencimiento ascendente/completadas visibles y expandidas; lista de búsqueda pendientes/sin filtros adicionales/vencimiento ascendente y sin fecha al final. Si existen preferencias del contexto, recuperarlas.
- **Q35 · Contextos:** cada tablero, búsqueda global y búsquedas contextuales tienen preferencias independientes. Buscar desde tablero inicia acotado a él, desde Mis tareas sobre asignadas propias. Ampliar a global requiere elección explícita visible.
- **Q36 · Texto:** búsqueda nueva con texto vacío, conservando filtros/orden del contexto. Texto se mantiene durante consulta y al volver de detalle. Abrir vista guardada recupera texto de su definición.
- **Q37 · Limpiar:** elimina texto/filtros opcionales de consulta actual, conserva alcance/orden y vuelve completadas al default del contexto. En Mis tareas mantiene asignación propia. En vista guardada genera variación temporal sin modificar definición.
- **Q38 · Reiniciar preferencias:** restablece solo orden/filtros/completadas del contexto actual, preservando favoritos, vistas guardadas, tema y otros contextos. Si hay vista guardada abierta, vuelve a contexto base sin modificarla. Tema vuelve a default eligiendo Sistema.
- **Q39 · Referencia recordada inválida:** detener consulta y pedir revisar o limpiar explícitamente; mensaje genérico sin nombres privados ante revocación. No quitar condiciones silenciosamente ni convertir alcance específico en global.

**Criterios todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C106-AC34 | Defaults por contexto se usan solo sin preferencia o tras reinicio; apertura habitual recuerda elecciones. |
| C106-AC35 | Filtros de A no afectan B/global; Mis tareas mantiene asignación propia; global exige elección explícita. |
| C106-AC36 | Búsqueda nueva vacía texto pero mantiene filtros/orden; volver de detalle conserva consulta; vista guardada repone texto. |
| C106-AC37 | Limpiar conserva alcance/orden, restaura default completadas y no modifica definición de vista ni asignación propia. |
| C106-AC38 | Reiniciar afecta solo contexto y vuelve a base; favoritos/vistas/tema/otros contextos intactos. |
| C106-AC39 | Referencia inválida bloquea sin nombres revocados ni ampliación silenciosa; reparación/limpieza es explícita. |

### CF-14.1 — Evolución de búsqueda (C-107)

**C-107 · Búsqueda unificada solicitada:** el usuario pide ampliar la búsqueda previa de título/descripción con sugerencias mientras escribe en varios campos/entidades, mencionando títulos, tareas, comentarios y tableros. Cada coincidencia identifica tipo/campo y origen/contexto; recién al elegir se navega o filtra. Prefiere esta experiencia rica si es viable. Sustituye la exclusión anterior de comentarios y el límite de buscar solo tareas. Siguen vigentes autorización, contexto, acentos/ñ, teclado/móvil y separación de sugerir frente a ejecutar. C-108 cierra fuentes/destinos/ranking/filtros por tipo en CF-14.2. Faltan mecanismos y validación de calidad, rendimiento y permisos.

Q34 fija orden por vencimiento para la lista de búsqueda de tareas, no un ranking de entidades heterogéneas. C-108 fija sugerencias por relevancia agrupada. Elegir motor/índices/normalización y probar desempeño son trabajo técnico, no preguntas de proveedor para el usuario.

### CF-14.3 — Historial en búsqueda (C-112 / Q61)

«Incluir historial de repeticiones» está desactivado por defecto y es independiente de «Incluir completadas»: las ocurrencias reemplazadas no se convierten en pendientes ni completadas. Al activarlo, la búsqueda unificada puede encontrar sus títulos/descripciones y comentarios según las mismas fuentes y filtros autorizados; muestra estado «Reemplazada», fecha y origen. Abre la ocurrencia o comentario preciso sin modificar/reabrir el origen; copiar conserva C-104. No incluye papelera ni concede acceso nuevo.

El control forma parte de consulta, preferencias de su contexto y vistas guardadas. Vistas existentes sin este dato equivalen a desactivado; no cambiar silenciosamente sus resultados. Cambiarlo en una vista abierta es variación temporal hasta actualizar explícitamente. Limpiar/Reiniciar retorna al default desactivado según C-106; «Incluir completadas» conserva su semántica.

| ID | Escenario | Resultado a verificar |
| --- | --- | --- |
| C112-AC61 | Una ocurrencia del lunes fue reemplazada sin completar; solo su comentario contiene el texto buscado. Consultar con defaults, incluir completadas y luego incluir historial; guardar/abrir vista, limpiar/reiniciar y revocar acceso. | Solo incluir historial habilita esa coincidencia reemplazada; destino/fecha/estado precisos, filtros de su tarea aplicados, sin reapertura/edición ni filtraciones. Vista conserva opción; default y reinicio la desactivan, completadas sigue independiente. |

### CF-14.2 — Búsqueda unificada aprobada (C-108)

El 26/10/2026 el usuario acepta Q40–Q43. Completa C-107 sin alterar permisos, normalización de acentos/ñ, teclado/móvil ni contexto.

- **Q40 · Fuentes:** tareas (título/descripción), comentarios actuales y tableros; añadir etiquetas coincidentes como sugerencias de filtro sobre etiqueta concreta y su tablero. Distinguirlas de destinos de navegación. Archivos y actividad fuera de este alcance inicial.
- **Q41 · Elegir:** tablero abre tablero, tarea abre detalle y comentario abre detalle ubicando comentario preciso. «Ver tareas que coinciden» es acción separada para lista filtrada, deduplicada por tarea aunque coincidan varios comentarios. Escribir no navega ni cambia tablero/filtros de origen.
- **Q42 · Orden:** sugerencias por relevancia agrupadas, priorizando exactas y comienzos de nombres/títulos, con palabras incompletas. Espacio por grupo impide que muchos comentarios oculten un tablero claramente coincidente. Lista posterior conserva vencimiento/creación según preferencias.
- **Q43 · Filtros por tipo:** tareas respetan sus filtros; comentarios heredan los de tarea padre (no confundir responsable de tarea con autor del comentario). Mis tareas incluye asignadas propias y sus comentarios; solo pendientes excluye comentarios de completadas con opción explícita de incluirlas. En global tableros son navegación separada, sin prioridad/responsable/vencimiento ficticios. Interfaz explica resultados afectados por filtros.

**Criterios todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C108-AC40 | Etiqueta sugerida aplica su identidad/tablero como filtro; sin fusión de homónimas ni búsqueda en archivos/actividad. |
| C108-AC41 | Elegir abre entidad precisa, comentario localizable aunque conversación paginada. Ver tareas deduplica; teclear no navega/filtra origen. |
| C108-AC42 | Exacta/prefijo/palabra incompleta produce sugerencias relevantes por grupos con espacio; lista posterior respeta preferencias de orden. |
| C108-AC43 | Filtrar responsable/completado/fecha/prioridad/etiquetas usa tarea padre para comentarios. Mis tareas mantiene propias; global no asigna propiedades de tarea a tableros. Sin datos ajenos ni revocados. |

**Trabajo técnico restante:** parser/ranking, índices/normalización, límites por grupo y paginación, anclaje de comentarios, consistencia tras edición/moderación/borrado, filtros tipados y autorización antes de extractos/conteos. No promete IA, tolerancia tipográfica ilimitada ni un motor externo. Nota de viabilidad en investigación local; no hubo benchmark ni cambio de producción.

### CF-26.1 y CF-27.1 — Instalación, actualización y lotes (C-109)

El 26/10/2026 el usuario acepta Q44–Q48.

- **Q44 · Validación:** priorizar Android/Chrome, iPhone/Safari y escritorio Chrome/Edge, incluyendo Safari en Mac. Probar instalación/apertura/login/enlaces/cambio de cuenta y registrar versiones. Firefox también para uso web. Instalar no es requisito para usar producto; objetivo de pruebas, no compatibilidad ya acreditada.
- **Q45 · Descubrimiento:** «Instalar aplicación» opcional en menú de cuenta, sin ventanas insistentes al entrar. Ofrecer instalación directa donde exista o instrucciones breves manuales específicas. No anunciar instalación exitosa por el solo clic.
- **Q46 · Actualización:** aviso «Hay una actualización disponible», con recarga elegida por usuario. Resolver campos pendientes mediante Guardar/Descartar/Seguir editando; no forzar recarga que pierda borrador. Mantener contrato online y sin promesa de supervivencia al cierre del sistema.
- **Q47 · Lote:** una pulsación sin diálogo extra. Botón con cantidad, por ejemplo «Marcar 12 visibles como leídas», contando sin leer actualmente cargadas. Fijar ese conjunto al pulsar; no incorporar posteriores/otras páginas.
- **Q48 · Resultado:** resumen con marcadas, ya leídas/resueltas, no disponibles y pendientes de reintento. Conservar éxitos, ofrecer reintentar solo falladas del lote original con autorización vigente. No disponibles no se convierten en fallos repetibles; no mostrar títulos revocados. Resultado incierto se reconcilia antes de repetir según C-95.

**Criterios todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C109-AC44 | Registrar versión/dispositivo de matriz; instalar/abrir/login/enlaces/cambio cuenta probados. Firefox uso web; instalar no bloquea acceso web. |
| C109-AC45 | Instalar en menú de cuenta, directo o pasos manuales según soporte; no modal insistente ni éxito ficticio. |
| C109-AC46 | Actualización avisa y permite elegir recarga; borrador se resuelve sin pérdida/recarga forzada. |
| C109-AC47 | 12 sin leer cargadas fijan 12 IDs al pulsar; llegadas posteriores y páginas restantes intactas, sin diálogo adicional. |
| C109-AC48 | Lote parcial resume marcadas/ya leídas/no disponibles/falladas; reintento solo falladas autorizadas del original, sin repetir éxitos ni inventar fracaso por timeout. |

**Trabajo técnico:** manifest/promoción según capacidad, sesión instalada y navegador sin prometer cookies compartidas, política de caché/privacidad, actualización compatible, reconexión/revocación y reconciliación del lote por resultados. No se aprueban por inferencia las propuestas adicionales de la nota de viabilidad; no se elige service worker ni almacén privado offline aquí. Pruebas aisladas/dispositivos reales antes de afirmar compatibilidad.

### CF-04.1, CF-07.1 y CF-09.1 — Calendario y recuperación (C-110)

El 27/10/2026 el usuario acepta Q49–Q54. Complementa fechas difíciles y permisos ya aprobados sin reabrirlos.

- **Q49 · Inicio/anclaje:** fecha de inicio explícita, proponiendo fecha existente de tarea. Semanas lunes–domingo ancladas a semana del inicio; no generar fechas anteriores. Preview distingue tarjeta actual y próximas. Inicio miércoles: lunes/miércoles cada dos semanas incluye ese miércoles y siguiente semana habilitada, no la intermedia.
- **Q50 · Final/conteo:** fecha final inclusiva. N cuenta fechas efectivas del calendario, no completados; exclusión explícita consume su fecha y no extiende serie. Mes sin quinto lunes no genera fecha que contar. Preview identifica fechas contadas; 1/4/7 con exclusión del 4 no agrega el 10.
- **Q51 · Excepción:** nueva fecha límite actual debe ser anterior a aparición siguiente. Rechazar fecha igual o posterior, explicar máximo y conservar borrador; no fusionar ni cambiar calendario posterior. Si próxima aparece sábado14, máximo viernes13.
- **Q52 · Recuperación finita:** serie cuyo final pasó reconcilia como máximo última ocurrencia válida, aunque vencida y aún no materializada, sin pendientes intermedios ni extender final. 1/3/5, borrada2 y recuperada6: historial y una vigente del5. Si última fecha excluida no crear sustituta. No regenerar una ocurrencia eliminada/purgada independientemente al restaurar su padre. Detenida sigue detenida.
- **Q53 · Recuperación individual:** deshacer solo exclusión causada por borrar esa misma ocurrencia; conservar otras exclusiones y no reactivar serie. Si hay posterior activada, recuperar como histórica. Exigir padres autorizados recuperados; recuperar serie no revive hijos borrados antes por separado.
- **Q54 · Actores:** propietario o colaborador actual con permiso de edición recupera pasos, series y columnas ordinariamente borrados dentro de siete días, como tareas; no exclusividad del que borró. Moderación/limpieza administrativa conservan restricciones. Recuperar columna no revierte traslados.

**Criterios todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C110-AC49 | Inicio miércoles4/11/2026 y lunes/miércoles cada2 semanas: 4,16,18…; no 2 ni9/11. Preview diferencia actual/futuras. |
| C110-AC50 | Final incluye su fecha si corresponde a regla. 1/4/7 con4 excluido sigue final7; quinto lunes inexistente no consume fecha. |
| C110-AC51 | Próxima aparece14: nuevo vencimiento13 válido,14/15 rechazados sin borrar borrador ni alterar futuras. |
| C110-AC52 | Calendario1/3/5 borrado2 recuperado6 genera como máximo5 aunque nunca materializado; no3 ni7. Última5 excluida no crea sustituta; detenida no se activa. |
| C110-AC53 | Recuperar lunes borra solo exclusión de su borrado; si miércoles ya apareció, lunes histórico. Padres eliminados bloquean; otras exclusiones y borrados independientes intactos. |
| C110-AC54 | Colaborador habilitado con edición recupera paso/serie/columna borrados por otro en plazo; retirado denegado. No recupera moderación ajena ni revierte traslados al recuperar columna. |

**Estado posterior:** C-111 cierra conversión/cantidad, creador de referencia, rearme y autovínculos. Auditoría final revisa los huecos restantes sin reabrir estas decisiones; mecanismos y pruebas van a diseño técnico.

### CF-04.2, CF-15.1, CF-16.1 y CF-18.1 — Conversión, avisos y enlaces (C-111)

El 27/10/2026 el usuario acepta Q55–Q60.

- **Q55 · Conversión:** conservar misma tarjeta como primera ocurrencia, contada en N; con N=3 quedan dos fechas adicionales. Preview distingue actual/próximas. Si vencimiento no encaja, elegir y confirmar primera fecha compatible; no cambiarlo silenciosamente ni duplicar tarjeta.
- **Q56 · Editar cantidad:** mostrar «N próximas repeticiones», fuera actual/pasado. Elegir3 próximas programa tres futuras y muestra nuevo final. Cambiar solo título/responsable/columna conserva restante; no reinicia contador.
- **Q57 · Creador de referencia:** nuevas ocurrencias automáticas usan creador de serie mientras conserve acceso; tarjeta original conserva creador original. Comentario avisa a creador/responsable elegibles, sin autoavisos/duplicados. Si creador sale, no sustituirlo por propietario.
- **Q58 · Rearme:** avisar por nuevo cruce de umbral solo después de haber bajado de él y transcurrido 24 h desde aviso anterior, por persona/umbral. Seguir encima al día siguiente no crea recordatorio ni aviso diferido. Carga bloqueada siempre informa inmediatamente.
- **Q59 · Ubicaciones:** enlaces clickeables al visualizar descripción/comentarios/pasos. Título compacto sigue abriendo detalle; URL de título abrible allí mediante control distinguible de editar.
- **Q60 · Detección/apertura:** HTTP/HTTPS y www.; www. abre HTTPS. Dominio suelto queda texto, excluir puntuación exterior y conservar original. Apertura explícita externa segura sin HTML/esquemas activos/locales, descargas ni previews automáticas.

**Criterios todavía sin ejecutar:**

| ID | Resultado observable |
| --- | --- |
| C111-AC55 | Convertir con N=3 mantiene ID actual, cuenta primera y muestra dos siguientes; fecha incompatible requiere confirmar ajuste sin duplicación. |
| C111-AC56 | Editar título conserva restante; elegir 3 próximas genera tres futuras fuera actual/pasado y muestra nuevo final sin reescribir historia. |
| C111-AC57 | Ana creadora de serie/Luis responsable/Marta comenta: avisos elegibles dedup sin autoavisos. Ana retirada no recibe ni reemplaza owner; original mantiene autor. |
| C111-AC58 | Cruce80%, bajar/recross1h no reavisa, permanecer encima24h tampoco; nuevo cruce tras24h sí. Umbrales independientes, carga rechazada avisa inmediatamente. |
| C111-AC59 | URL en descripción/comentario/paso abre explícitamente; título de tarjeta abre tarea y enlace externo se ofrece en detalle separado de edición. |
| C111-AC60 | www.ejemplo.com. apunta https://www.ejemplo.com; ejemplo.com queda texto. No previews/descargas/ejecución al pegar ni normalización destructiva de URL. |

**Estado:** estos detalles quedan acordados; auditoría final distingue únicamente decisiones humanas realmente restantes de mecanismos y pruebas. No afirmar cierre técnico ni implementación. Las atribuciones importadas no se convierten por coincidencia de nombre en destinatarios autenticados.

## H. Especificación técnica y UX que prepara el agente

No trasladar estas tareas al usuario como un cuestionario. C-99/P16–P25 aprueba los contratos de resultado y las precisiones presentadas; elegir y verificar mecanismos sigue siendo trabajo técnico. Deben producir documentos/pruebas verificables antes de declarar la spec implementable:

| Área | Entregable necesario | Condición para cerrarlo |
| --- | --- | --- |
| Pantallas | Tableros, detalle, Mis tareas, Series/historial, Novedades, recuperación, administración y ampliaciones CF-21–27; acciones, vacíos, carga/error, español/temas y móvil. | P01–P14: misma tarea, captura explícita, jerarquía progresiva, regreso al origen y recorridos accesibles a 360/390 px, escritorio, teclado/zoom/movimiento reducido. Ningún cambio remoto roba foco/columna. |
| Datos y permisos | Entidades/invariantes, contratos por acción/campos editables y matriz de autorización, incluidas referencias cruzadas y nuevas capacidades. | P16/P17: identidad/habilitación/membresía en cada superficie; campos protegidos rechazados, actor resuelto en servidor, casos con dos tableros y varios roles. |
| Concurrencia | Precondiciones de versión para campos editables y claves de operación; comentarios/pasos/archivos independientes; reconciliación/borradores. | P18: estado deseado al completar, resultado incierto consultable, optimismo marcado pendiente; sin doble pendiente/consumo ni sobrescritura. Revocación vacía estado activo, sin prometer retirar copias descargadas. |
| Tiempo | Una regla de cálculo para previsualización, validación y ejecución; zona, excepciones y límites acotados. | Casos febrero/ordinales/fin/anticipación/reintentos con reloj controlado. |
| Ejecución | P19: registrar trabajo pendiente duradero junto al cambio cuando corresponda; procesamiento separado/reintentable/deduplicado y reconciliación. Elegir mecanismo proporcional en stack actual. | Caída entre guardar y procesar no pierde efecto ni duplica ocurrencias/avisos. Al volver tras inactividad se ve estado correcto. Fijar latencia comprobable; no elegir Celery/RabbitMQ ni prometer ejecución exactamente una vez. |
| Retención/capacidad | P21/P22: causa/actor/plazo/dependencias de borrado; reservas/verificación/publicación, purgas y reconciliación de objetos. | Cuotas reales medidas; hijos borrados aparte no reviven al restaurar padre; plazo vencido impide restauración aunque siga la copia. Sin carreras con purga ni doble reserva. |
| Realtime y sesiones | P20: señales de cambio reconciliadas con consultas autorizadas, canales privados y revocación; descartar respuestas de sesión anterior. Incluir caché PWA de E06. | Probar sesión/canal abiertos y cliente no cooperativo, reconexión/cambio de cuenta; no reaparecen datos privados ni se pisan borradores válidos. |
| Consultas | P23: resúmenes de tarjetas separados de comentarios/adjuntos/actividad, carga de detalle al abrir; listas globales/conversaciones paginadas con orden estable y filtros servidor. | Contadores autorizados, exportación completa; evaluar carga parcial y reordenamiento juntos antes de paginar tablero. Fixture 500 tareas es evaluación, no capacidad certificada ni límite del producto. |
| Respaldo/corte | P24: formato versionado/compatibilidad v1, preparación/publicación; respaldo operativo base/objetos/configuración y restauración de prueba. | Datos preservados, permisos no heredados por archivo, cierre anónimo coordinado y recuperación privada; archivo de tablero no sustituye respaldo de instancia. |
| Operación | P25: versiones/migraciones/dependencias, diagnósticos mínimos de fallos/trabajos/purgas/cuotas, actualización/restauración y origen/licencia de código. | Referencias operativas sin cuerpos privados/tokens ni trazas públicas; sin nueva pantalla de métricas/proveedor de telemetría por defecto. Procedimientos ensayados antes de afirmar confiabilidad. |
| Calidad | P26: reglas → escenarios → evidencia; integración/regresión y observación de capturar, encontrar, completar, coordinar y retomar rutina. | Casos normales/fallidos y personas del piloto, sin producción como prueba ni analítica externa/puntajes de productividad. Diferenciar corrección de facilidad de uso. |

### H.1 Brechas que quedan después de C-99

| Área | Contrato ya incorporado | Brecha pendiente y evidencia para cerrarla |
| --- | --- | --- |
| Autorización/Realtime | P16/P17/P20; matriz 0.3. | Inventario API/RPC/Storage/canales y mecanismo verificado de revocación incluso con cliente no cooperativo; ampliar a favoritos/vistas/etiquetas/actividad/PWA. |
| Escrituras y jobs | P18/P19: versiones, operaciones durables y reintentos. | Esquema/transacciones, vencimiento de claves, entrega/reconciliación, proveedor/latencia/costo verificados; fallos simulados con resultados únicos. |
| Tiempo | Reglas de calendario vigentes y una pendiente actual. | Un único cálculo para preview/validación/ejecución; pruebas de zonas/cambio de día/exclusiones/inactividad, sin suponer motor reutilizable de Plane. |
| Recuperación/archivos | P21/P22: siete días, dependencias y unidades decimales. | Protocolo base/Storage, reservas/huérfanos, plazos de limpieza y enlaces, carreras restauración/purga; no afirmar una transacción única entre servicios. |
| Etiquetas/copia | C-100–102 cierran permisos, cupos activos, recuperación, herencia, copia y respaldo. | C-103 cierra unicidad y C-104 destino de copia; C-105 cierra confirmación/origen cambiado; queda validación técnica de formato. |
| Vistas/tema/actividad | C-100–102 cierran consulta, cupos activos, recuperación, revisión y conflicto. | C-103 cierra unicidad; C-104/C-105 cierran tema y actividad; C-106 cierra defaults/reinicio; quedan mecanismos. |
| Instalación y carga | E06/P23 online y consultas acotadas. | Matriz real de navegadores/caché/actualizaciones/PWA y carga parcial compatible con reordenamiento; medición con datos ficticios. |
| Respaldo/operación | P24/P25, exportación por tablero y recuperación de instancia separadas. | Formato nuevo, alcance de entidades E, restauración ensayada, despliegue/recuperación compatibles y diagnósticos sin contenido privado. |

### H.2 Escenarios de aceptación incorporados — no ejecutados

Se suman a AC/MVP-AC/NAV/PERM/ERR/BACKUP y a la tabla de aceptación P/E del anexo; estas filas no certifican que la aplicación los cumpla.

| ID | Escenario | Resultado a verificar |
| --- | --- | --- |
| TEC-01 | Cruce de IDs entre dos tableros desde búsqueda, exportación, archivo, actividad y canal. | Denegación de contenido/conteos/títulos y ausencia de efectos; admin ajeno tampoco obtiene lectura. |
| TEC-02 | Dos guardados concurrentes y reenvío después de perder respuesta. | Revisión de conflicto preserva borrador autorizado; una intención no duplica tarea/comentario/aviso. Comentario nuevo no invalida título por sí solo. |
| TEC-03 | Caer entre persistir y procesar un efecto, reintentar jobs y volver tras una semana. | Pendiente vigente única, avisos deduplicados, exclusiones conservadas, sin completados ficticios. |
| TEC-04 | Última plaza de adjunto disputada, reserva abandonada y restauración contra purga. | Solo capacidad admisible; liberar reserva fallida sin purgar recuperable antes; sin restauración parcial ni hijo borrado aparte revivido. |
| TEC-05 | Tablero de 500 tareas con conversaciones, paginación y exportación. | Tarjetas no cargan todas las conversaciones; páginas estables sin omisiones/duplicados y respaldo completo autorizado. |
| TEC-06 | Fallo de importación/actualización y restauración operativa fuera de producción. | Previo intacto o recuperación ensayada con base/objetos; no reabre acceso anónimo ni expone secretos en respaldo de tablero. |
| TEC-07 | PWA cambia cuenta y abre enlace; revocación durante edición. | Misma autorización que web; ninguna caché de cuenta anterior ni cola offline; se retira contenido privado al detectar revocación. |
| TEC-08 | Copia de ocurrencia con checklist/archivos; lectura por lote de 20 de 80 novedades. | Copia puntual solo con contenido E04, pasos sin marcar; lote solo sobre 20 cargadas autorizadas y no sobre llegadas posteriores. |
| TEC-09 | Favoritos/vistas/tema entre dos personas y dos dispositivos. | Preferencias propias sincronizadas sin alterar a otro; fechas relativas recalculadas y acceso revocado oculto. C-100: verificar 50 vistas/persona, 60 caracteres y unicidad por contexto; C-104 fija tema y combinación/conflicto de preferencias; probarlos. C-106 fija otros defaults/reinicio; quedan mecanismos. |
| TEC-10 | Piloto en móvil 360/390 px y escritorio: capturar, encontrar, completar, coordinar y retomar rutina. | Recorridos utilizables con teclado/foco/temas/español, sin depender de arrastre ni intervención del autor; registrar dificultades sin analítica externa. |

## I. Puerta de cierre

1. C-99 deja P01–P26/E01–E07 incorporadas; no volver a pedir aprobación de esas capacidades ni de contratos cerrados por C-01–98. Resolver únicamente detalles abiertos identificados, incluyendo etiquetas, vistas, actividad, PWA y relaciones con series/respaldo.
2. Mantener coherencia entre spec principal, criterios, Pantallas y matriz de permisos. H.1 separa diseño técnico pendiente de decisiones funcionales restantes; no rebajar las E aceptadas a backlog.
3. Resolver y verificar el diseño técnico y las pantallas. Si exige costo/servicio/cambio de alcance, explicarlo antes de elegirlo.
4. Revisión final con ejemplos ficticios y situaciones de fallo. No afirmar que la lista actual garantiza ausencia de huecos: cualquier nuevo caso que cambie comportamiento debe quedar explícito.
5. Usuario aprueba una versión concreta para implementar. Migraciones/despliegues requieren autorización separada.
