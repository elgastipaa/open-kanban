# MVP 1.0 — Organización personal y colaborativa

Actualización documental C-100–112 (27/10/2026): calendario CF-04/07/09, avisos/cuota/enlaces CF-15/16/18, preferencias/búsqueda CF-13–14 y ampliaciones CF-22–27. Complementa revisión base; todas las P/E se conservan.

Consolidación vigente27/10/2026: C-112 resuelve los dos huecos funcionales de auditoría; [DT-0.1](./DISENO-TECNICO-MVP-1.0.md) fija diseño recomendado y verificaciones G01–G08 pendientes. Los registros de revisiones anteriores son antecedentes, no nuevas preguntas de producto.

Estado: **borrador de producto 0.25; P01–P26 y E01–E07 incorporadas al alcance por C-99, sin autorización de implementación**. Consolidación: 25 de octubre de 2026.

Este documento reúne el alcance objetivo, los recorridos y los contratos de la primera versión. La [spec 0001, revisión 0.33](./0001-auth-collaboration.md) conserva acuerdos C-01–112, propuestas aún abiertas, criterios y evidencia del código, seguridad y transición. El [glosario](../../CONTEXT.md) fija términos. El [cierre funcional](./CIERRE-MVP-1.0.md), revisión 0.6, [Pantallas](./PANTALLAS-MVP-1.0.md), revisión 0.5, [matriz de permisos](./MATRIZ-PERMISOS-MVP-1.0.md), revisión 0.3, y [Estados y errores](./ESTADOS-Y-ERRORES-MVP-1.0.md), revisión 0.3, consolidan C-99. La sección 16 incorpora las 33 filas del [anexo de Plane](./PROPUESTAS-DESDE-PLANE.md), incluidas todas las E, al mismo MVP. Ninguno de estos documentos autoriza código, SQL remoto, despliegue o creación de automatizaciones.

**Alcance temporal vigente:** recurrencia de calendario y aparición anticipada opcional elegida por el usuario. La aparición sustituye la propuesta de movimiento automático: nuevas ocurrencias nacen en la columna de aparición de la serie y luego se mueven manualmente. No hay campo de destino automático ni repetición relativa al completado. El límite de anticipación para evitar solapamientos está confirmado (sección 9).

## 1. Producto que queremos construir

Una aplicación privada de organización personal y colaborativa: capturar una tarea sencilla, ubicarla en un tablero, compartir trabajo con personas elegidas y programar actividades repetidas cuando haga falta. La navegación principal sigue siendo por tableros.

La ambición expresada por el usuario es superar su experiencia con Asana, Trello, Google Tasks y Microsoft To Do combinando lo que necesita de esos mundos. Para hacerla verificable, el MVP debe resolver sus recorridos completos con poca fricción. No se declara superioridad demostrada, paridad de catálogos ni integración con esos productos. No se ha realizado aquí una auditoría de sus funciones actuales.

OpenKanban aporta una base operativa que se reutiliza. Conservarla significa preservar las capacidades útiles y evitar reconstrucciones gratuitas; **no significa conservar creación pública, anonimato o acceso por conocer una URL**. Esas capacidades desaparecen del producto objetivo al realizar el corte aprobado. La instancia desplegada todavía conserva su comportamiento anterior.

Criterio de valor aprobado P26: el usuario puede capturar, encontrar, completar, coordinar y retomar sus pendientes y rutinas desde móvil y computadora; solo abre configuración avanzada cuando la necesita. Se validará con personas del piloto, sin analítica externa ni puntajes de productividad. El español es el idioma inicial P12, incluidos errores y nombres accesibles; las fechas preservan el día elegido y se interpretan con la zona del tablero. No se traduce el contenido de usuarios ni se incorpora selector multidioma.

## 2. Acuerdos y límites de este borrador

Confirmados:

- Google como identidad; solo el solicitante administra la admisión a la aplicación. Los usuarios no pueden habilitar amigos nuevos mediante una invitación de tablero. No se busca un lanzamiento público.
- Cada habilitado puede crear tableros y ser propietario de los que crea; administra sus miembros entre personas ya habilitadas. Roles iniciales: propietario y colaborador; visibilidad de todo el tablero para sus miembros. No hay tableros públicos del MVP ni creación anónima por URL.
- Navegación por tableros; tareas con cero o un responsable. Los colaboradores pueden editar todas las tareas, estén o no asignadas a ellos.
- Completar mediante casilla conserva tablero/columna. Completadas visibles y atenuadas por defecto; la visualización de completadas/historial es una preferencia personal configurable, sin borrar contenido ni cambiar lo que ven otros.
- Fechas por día, sin hora. Una tarea puntual vencida permanece y se destaca.
- Las repeticiones del mismo pendiente no acumulan una pila de atrasos: cuando corresponde la nueva, solo esa queda pendiente vigente. No se marcan hechas las anteriores por el mero paso del tiempo.
- Programación genérica opcional por tarea desde un control tipo reloj; no exclusiva de cumpleaños.
- Aparición anticipada opcional: cada usuario elige cuántos días antes del vencimiento aparece una repetición en la columna de su serie. Sustituye el movimiento automático propuesto antes. Al activarse la nueva se conserva la regla de reemplazar la anterior pendiente de la misma serie sin marcarla hecha; validar solapamientos según el límite confirmado de sección 9.
- Movimiento manual entre columnas para mantener el flujo Kanban, independiente del completado. La corrección del usuario de «tablero» a «columna» no autoriza traslado entre tableros.
- Repeticiones únicamente por calendario: cada N días, días elegidos de la semana/cada N semanas, fechas del mes y demás patrones de calendario del catálogo. Se excluye «N días después de completar»; completar tarde no desplaza el calendario.
- Calendario de apoyo con resumen pequeño y opciones en el reloj; las tareas son el foco, sin calendario persistente dominante.
- «Mis tareas» forma parte del MVP: reúne asignadas al usuario de distintos tableros/columnas y permite completarlas sobre la misma tarea de origen. Vencimientos más antiguos primero, luego próximos y sin fecha al final; opción por creación con nuevas debajo. El orden manual de columnas se conserva, no se sustituye por un ordenamiento global.
- Tareas de usuarios retirados permanecen en tableros que siguen activos; los miembros que conservan permisos pueden borrarlas explícitamente. Excepción confirmada: al retirar al propietario sin otro miembro elegible, eliminar el tablero con recuperación durante 7 días y nuevo dueño obligatorio al restaurar (4.4–4.6).
- Series muestra todas las de tableros accesibles, incluidas las creadas por otros miembros, con filtro por tablero. Se confirma ese alcance; detalles de presentación siguen propuestos.
- El usuario define sus columnas y su forma de trabajar. Una sola columna con tareas es válida; no hay nombres, etapas ni recorrido Kanban obligatorios.
- Desde una tarea recurrente se puede editar su serie y cambiar la columna donde aparecerán las próximas repeticiones, por ejemplo de A a B. Editar la serie afecta solo a las próximas: la actual ya visible se modifica por separado.
- Al borrar una tarea recurrente se elige el alcance: esa repetición o la serie entera. Además existe «Dejar de repetir», que conserva lo existente; «Eliminar toda la serie» elimina también sus repeticiones e historial con confirmación explícita. Una tarea no recurrente mantiene borrado simple.
- Al eliminar una columna usada por series se identifican las afectadas y se resuelve la ubicación sustituta; no quedan referencias sin destino. CF-12/C-76/C-110 exige destino explícito y traslados coherentes de tareas/series antes de borrar; restaurar no deshace esos traslados.
- Cumpleaños siguen siendo fechas anuales sin completado. El ejemplo no restringe el sistema de repetición a cumpleaños.
- Destacados dentro de la app bastan para la base. Celular y Google Calendar son deseables a evaluar aparte.
- Confirmados el límite de anticipación, el orden acordado, el grupo de completadas con reapertura desde detalle y la regla mensual de último día disponible sin cambiar el ancla original. Detalles restantes de fechas especiales en sección 7.
- Incluir comentarios, menciones y adjuntos; checklist sencilla de pasos sin configuración propia de tareas independientes; búsqueda y filtros; bandeja de novedades dentro de la app. Son alcance confirmado, con contratos detallados aún propuestos en sección 14.
- Confirmadas las recomendaciones presentadas sobre checklist, herencia de contenido recurrente, eventos básicos de novedades y privacidad (C-54–57). Completar con pasos pendientes requiere confirmación y no los marca realizados; la próxima repetición recibe pasos sin marcar, no conversaciones ni archivos copiados. Sección 14 distingue estos acuerdos de los detalles todavía pendientes.
- Navegación de primera prueba confirmada C-84–86: ☰ abre panel desde izquierda con Tableros/Mis tareas/Series/Novedades; al pie cuenta/preferencias, administración autorizada y cerrar sesión. Búsqueda visible en cabecera, acciones del tablero en ⋯ y acciones de tarea en detalle. Sin barra inferior ni sidebar permanente inicial. Contrato de ubicación en Pantallas, sección 2.

**C-99 incorpora todas las P01–P26 y E01–E07 al alcance actual**, con sus criterios presentados. E es un identificador histórico, no una fase futura fuera de este MVP. Las precisiones aprobadas prevalecen sobre marcas históricas de pendiente; los aspectos que las filas no definieron se cierran en §16.5. Aceptar el alcance no selecciona dependencias o servicios ni certifica viabilidad técnica.

## 3. Alcance del MVP

| Bloque | Resultado de usuario | Estado del alcance |
| --- | --- | --- |
| Acceso controlado | Personas habilitadas entran con Google; el administrador controla admisión y suspensión. | Comportamiento confirmado; implementación de identidad/admisión en DT-0.1. |
| Tableros privados | Crear, listar y navegar tableros propios/compartidos, con columnas libres. | Propietario = creador; recuperación CF-12/CF-09.1 y rutas como detalle técnico. |
| Trabajo cotidiano | Capturar, editar, priorizar, ordenar, mover y completar tareas, manteniendo controles móviles y accesibles. | Base existente más acuerdos de completado. |
| Colaboración | Compartir por enlace, administrar miembros/roles y asignar un responsable. | Propietario/colaborador; salida con sucesor y recuperación por causa confirmadas CF-02/CF-12. |
| Programación | Fecha opcional, catálogo de repetición y gestión de series desde reloj. | Catálogo confirmado C-73; precisión de calendario C-110/C-111 y sección 7. |
| Aparición anticipada | Hacer visible una nueva repetición X días antes en la columna de su serie. | Confirmado, incluido límite de anticipación de sección 9. Movimiento automático descartado para el MVP. |
| Fechas anuales | Representar cumpleaños sin convertirlos en trabajo a completar. | Contrato CF-10 y Pantallas: cumpleaños sin completado, calendario anual y visibilidad acordada. |
| Confianza operativa | Aislamiento, sincronización privada, errores claros y conservación de información. | Condiciones de entrega, no funciones optativas. |
| Vista personal secundaria | Reunir tareas asignadas y completarlas sin duplicarlas ni moverlas de origen. | Confirmado; contrato en 6.3. |
| Acceso compacto a series | Encontrar y administrar series aunque no tengan una tarjeta visible o estén ocultas las completadas. | Alcance confirmado: todos los tableros accesibles, filtrable por tablero. Presentación en 8.5. |
| Conversación y archivos | Comentar, mencionar miembros y adjuntar archivos a tareas. | Incluidos; autoría, seguridad, límites y relación con series en 14.1 y 14.3. |
| Pasos de trabajo | Checklist sencilla dentro de una tarea. | Incluida; sin responsables, fechas ni recurrencia por paso. Contrato 14.2/CF-11; permisos ordinarios precisados C-110. |
| Búsqueda y organización | Búsqueda unificada C-107 con coincidencias por tipo/campo/contexto, filtros visibles, etiquetas y vistas personales. | Incluido C-99/P05/E01/E02; 14.4 y 16.3. |
| Novedades | Avisos relevantes, lectura individual y lote explícito de novedades cargadas. | Incluido P15/E07; 14.5. Sin avisos externos. |
| Experiencia personal | Español, favoritos, enlace privado a tarea, atajo de búsqueda, preferencias entre dispositivos y tema claro/oscuro/sistema. | Incluido P06/P11–P14/E03; 16.1 y 16.3. |
| Reutilización y actividad | Copiar tarea puntual y consultar actividad mínima de campos dentro del detalle. | Incluido E04/E05; 16.3, con decisiones acotadas en 16.5. |
| Acceso instalable | PWA online, icono y apertura con login/enlaces consistentes. | Incluido E06; compatibilidad por validar, sin app nativa ni sincronización offline. |

Sin compromiso en este MVP: integraciones externas, avisos push, roles personalizados, motor general de automatizaciones, sincronización de calendarios, jerarquías de organizaciones, dependencias entre tareas o funciones de referencia no incorporadas expresamente en C-99. Las 33 P/E sí pertenecen al MVP. Esta exclusión evita que una referencia comercial amplíe silenciosamente el alcance. Una necesidad concreta puede reabrir el límite antes de aprobarlo.

## 4. Acceso a la aplicación y a los tableros

### 4.0 Entrada privada en lugar de creador público — confirmado C-93

La página raíz deja de ofrecer la landing de creación pública: sin formulario para elegir una URL de tablero, botón de tablero aleatorio, llamada a crear sin cuenta ni mensajes de «conocer URL = acceso». No es solo ocultar esos controles: el modelo público/anónimo se elimina de creación, lecturas, escrituras y canales al ejecutar el corte aprobado. No se implementa en esta fase.

Flujo explícito:

| Estado de quien visita | Qué ve / puede hacer |
| --- | --- |
| Sin sesión | Entrada mínima con identidad de app y Continuar con Google. No crea, abre ni previsualiza tableros. |
| Google válido, pero sin habilitación o suspendido | Acceso restringido; cambiar cuenta/cerrar sesión. No crea ni gestiona tableros ni consume una invitación inelegible. |
| Sesión válida y habilitación vigente | En raíz, Tableros propios/compartidos; crear privados y gestionar dentro de sus permisos. |
| URL directa de tablero | Login si hace falta; después comprobar habilitación y membresía. Conocer URL no concede acceso ni crea un tablero inexistente. |

El administrador habilita el correo Google de la persona antes de usar la aplicación. No crea su cuenta Google ni entrega una contraseña propia de OpenKanban. Que el proveedor Auth genere una identidad al autenticarse no la convierte en persona habilitada ni miembro de tablero. No autoaprobar al primer visitante; cuenta administrativa inicial explícita.

Las nuevas pantallas internas tienen rutas reservadas que no se interpretan como slugs para crear tableros. Conservar correctamente retorno de OAuth e invitaciones, sin el saneamiento destructivo de query strings del proxy actual. La elección exacta de rutas es técnica y queda por diseñar. Las rutas mínimas de acceso/callback y documentos públicos necesarios no ofrecen datos privados ni un bypass de admisión; no eliminar avisos legales/licencia por confundirlos con promoción pública.

Inspección local de esta revisión: `src/app/page.tsx` compone hero/marketing/CTA, `src/components/landing/hero-section.tsx` ofrece slug y URL aleatoria, y `src/proxy.ts` normaliza paths/query como slugs. Es evidencia del punto de partida, no de que ya esté corregido. La migración no se resuelve reemplazando solo la pantalla inicial.

Casos de aceptación adicionales: visitar raíz sin sesión no ofrece crear tablero; Google no habilitado permanece restringido; visitar URL inventada no crea contenido; antiguo enlace no abre tablero sin membresía; llamadas directas anónimas/no habilitadas y canales públicos quedan cerrados; usuario habilitado entra a Tableros con sesión existente sin login repetido. No filtrar títulos/previews ni URLs privadas por metadatos/sitemap. Estos controles deben probarse antes de publicar, sin tocar producción ahora.

### 4.1 Tres preguntas distintas

1. **Identidad:** ¿quién inició sesión con Google?
2. **Habilitación:** ¿esa persona está autorizada para usar esta aplicación?
3. **Permiso de tablero:** ¿a qué tablero pertenece y qué puede hacer allí?

Las tres se comprueban en el servicio/base, no solo en la interfaz. Iniciar sesión o recibir un enlace no contesta por sí solo las otras preguntas. Ser responsable de una tarea tampoco concede membresía.

El administrador inicial será el solicitante, identificado explícitamente durante la futura configuración. No se asigna ese rol al primer visitante. La recomendación aceptada separa admisión de membresía: administrar acceso **no concede lectura desde la app de todos los tableros**. El acceso administrativo a la infraestructura es una capacidad distinta; no se promete cifrado que oculte los datos al operador de la base.

### 4.2 Admisión confirmada — C-22/C-71/C-93

Contrato vigente: el administrador habilita una identidad mediante un correo Google verificado; el primer acceso válido vincula la autorización al identificador estable de esa cuenta. No basta escribir un correo en el navegador. No se usará un listado público de personas habilitadas.

Estados de admisión: autorizado pendiente de primer acceso, activo y suspendido. Sin autorización, la persona puede autenticarse pero recibe una explicación de acceso restringido y puede cerrar sesión; no obtiene tableros ni puede crearlos. Evitar crear datos de producto para cada intento de login; si el proveedor crea una identidad Auth, eso no constituye habilitación.

El administrador debe poder ver autorizaciones, habilitar, retirar autorizaciones pendientes y suspender acceso. La admisión puede comenzar con una pantalla mínima de administración; no se decide aún el mecanismo técnico ni se propone depender de editar SQL manualmente en cada alta.

### 4.3 Compartir con alguien todavía no habilitado — admisión cerrada

**Confirmado en C-22:** solo el solicitante decide quién entra a la aplicación. Los demás usuarios comparten únicamente con personas habilitadas. Si quieren incorporar a alguien nuevo, el solicitante debe habilitarlo primero. La invitación de tablero sola no abre la aplicación. La alternativa de admisión delegada queda descartada para el MVP.

Propuesta para mantener simple la admisión entre amigos: coordinar el pedido fuera de la app y usar una administración mínima para habilitarlo. No incluir automáticamente bandejas de solicitudes, correos ni aprobaciones multinivel. Alta y suspensión confirmadas; sus mecanismos se diseñan en DT-0.1 §§3–5, sin nueva admisión delegada.

La invitación de tablero conserva un solo uso y revocación; duración de 72 horas confirmada en C-71. Verificar habilitación, membresía y rol del emisor antes de aceptarla; no consumirla si el destinatario no es elegible. C-97/C-98 distingue genérica transferible entre elegibles de directa al destinatario habilitado; no intercambiar sus condiciones. El usuario aprueba habilitación por correo Google desde administración sencilla.

### 4.4 Suspender no es borrar

Confirmado: retirar acceso conserva el contenido en tableros que siguen activos. Si el administrador retira al propietario, debe elegir un nuevo dueño entre las otras personas con acceso; si no queda ninguna, eliminar el tablero con recuperación durante 7 días. Restaurarlo exige asignar un nuevo propietario. Esta excepción sustituye la propuesta anterior de conservar siempre la propiedad original. Contrato técnico candidato: impedir nuevas lecturas/escrituras y eventos privados de la persona retirada, incluyendo sesiones existentes, y coordinar revocación, transferencia o borrado sin dejar tableros activos sin dueño.

Ampliación confirmada: las tareas del usuario retirado se dejan donde están; quienes conservan permisos pueden decidir borrarlas después con el mismo flujo de confirmación. Confirmado en C-69: dejar sin responsable tareas pendientes y quitarlo del valor predeterminado de serie, conservando autoría histórica. No volver a asignarle próximas repeticiones automáticamente ni borrar las tareas de tableros que permanecen activos.

Retirar a alguien de **un tablero** no lo suspende de toda la aplicación. Rehabilitar globalmente no restaura membresías retiradas deliberadamente. Invitaciones emitidas por alguien que ya no tiene permiso no pueden seguir otorgando acceso por omisión. La revocación de canales existentes es un requisito técnico pendiente de demostrar, documentado en T-05/T-09.

### 4.5 Propiedad y permiso de creación — recomendación aceptada

Al aceptar la recomendación de roles y privacidad se adopta el modelo presentado: cada usuario habilitado puede crear tableros y es propietario de los que crea. Administra sus miembros entre usuarios ya habilitados. El solicitante conserva control de acceso global, sin administrar cotidianamente los tableros de todos ni aparecer como miembro invisible. No hay permiso independiente de creación en este MVP.

**Confirmado al retirar acceso por decisión del administrador:** revisar los tableros propios de esa persona y elegir explícitamente un nuevo dueño por tablero entre quienes conservan acceso. Si no queda nadie, borrar ese tablero de forma recuperable durante 7 días. No transferirlo automáticamente al administrador ni concederle lectura de las tareas por realizar esta gestión. La administración debe disponer de los metadatos mínimos necesarios para elegir dueño y recuperar; el detalle de esa pantalla sigue candidato.

Propuesta de elegibilidad: nuevo dueño activo y habilitado, miembro actual para una transferencia normal. Para restaurar un tablero que quedó sin miembros, el administrador elige una persona habilitada y se le concede explícitamente propiedad y membresía. La persona retirada no recupera acceso ni invitaciones por esta operación. Antes de confirmar, resumir transferencias y tableros enviados a recuperación. Volver a validar elegibilidad al guardar; una carrera no debe dejar un tablero activo sin propietario. Salida voluntaria: sucesor explícito según C-80/CF-02. Eliminar autónomamente la identidad Google/Auth no forma parte del MVP.

### 4.6 Recuperación durante 7 días

**Confirmado:** ofrecer 7 días de recuperación de contenido eliminado, incluyendo el tablero que queda sin otros miembros al retirar a su dueño. Para recuperar ese tablero hay que asignarle nuevo propietario. No equivale a una copia de seguridad de Supabase ni autoriza borrar contenido real durante esta fase.

Contrato candidato para cerrar los detalles:

- Contar 7 períodos de 24 horas desde el borrado registrado por el servidor; mostrar fecha/hora exacta de vencimiento. Después no se ofrece restauración desde la app; purga física posterior mediante proceso controlado, cuya frecuencia debe verificarse técnicamente.
- Recuperación de tablero/columna/tarea/serie conserva su contenido dependiente, incluidos checklist, comentarios y adjuntos, sin reabrir permisos retirados. Borrados independientes anteriores mantienen sus propios plazos: borrar después el padre no reinicia esos plazos ni revive contenido ya eliminado por separado.
- Tablero o serie en recuperación no genera nuevas ocurrencias, avisos ni resultados normales de búsqueda. Restaurar aplica CF-09.1/C-110: máxima última válida, sin intermedias ni sustituta si la última está excluida; detenida sigue detenida.
- Proponer recuperación de contenido dentro de un tablero a quienes mantienen permiso equivalente para editarlo; restauración de tablero ordinario por su propietario habilitado, y caso de dueño retirado por el administrador con elección de nuevo dueño. Precisar permisos para comentarios/archivos eliminados individualmente, para no deshacer moderaciones sin autorización.
- Restaurar una tarea cuya columna ya no existe requiere elegir columna válida; si el tablero está eliminado, recuperar primero el tablero con los permisos correspondientes. No recrear silenciosamente miembros, columnas ni series que fueron eliminados por separado.
- Datos y archivos retenidos durante esos 7 días siguen consumiendo cuota. No purgarlos antes para liberar espacio; al alcanzar un límite, rechazar nuevas cargas con explicación. La recuperación no promete revertir ediciones ni reconstruir archivos ya purgados.

C-94/C-98/C-110 cierran actores y dependencias de recuperación ordinaria/moderación y casos de series; plazos siete días y reasignación sin dueño confirmados. Restan mecanismos de purga/concurrencia y casos delimitados, no volver a tratar permisos ordinarios como candidatos.

## 5. Roles de tablero — propietario y colaborador

Los roles son por tablero: una persona puede ser propietaria de uno y colaboradora de otro. El responsable de una tarea no es un rol. El usuario acepta empezar con propietario y colaborador. Lector y administrador delegado no forman parte del alcance actual; no hay caso concreto que los requiera.

La [matriz de permisos](./MATRIZ-PERMISOS-MVP-1.0.md) es la referencia única por operación y distingue acuerdos (A) de propuestas pendientes (P). Incluye administración global, tareas, series, comentarios, archivos, recuperación e importación; reemplaza la tabla resumida anterior para evitar versiones divergentes. Todos los colaboradores conservan edición general según C-07. La membresía permite ver todo el tablero: no hay tareas secretas dentro de un tablero compartido. Esta visibilidad se explica al compartir.

Un propietario por tablero; un colaborador no puede elevar su rol ni retirar al dueño. Asignación y retirada concurrentes no dejan un responsable inelegible. Transferencia por retirada administrativa confirmada en 4.5; eso no habilita a colaboradores a apropiarse de un tablero.

## 6. Experiencia cotidiana y control de programación

### 6.1 Recorrido simple

Entrar → elegir o crear tablero → elegir columna → escribir título → guardar. No exige fecha, responsable ni repetición. Los controles originales de descripción, prioridad, movimiento y edición se reutilizan. La captura no obliga a configurar una serie para una tarea puntual.

Confirmado: no hay columnas obligatorias «Pendientes», «En curso» o «Hecho». Los nombres utilizados en ejemplos no son configuración requerida. Un tablero con una sola columna y tareas que nunca se mueven satisface el producto; otro puede tener varias columnas elegidas por sus miembros. Ninguna serie debe crear columnas de flujo ni forzar un recorrido. La columna de aparición selecciona una ubicación existente del usuario, no una etapa de trabajo definida por el sistema.

Completar actúa sobre la ocurrencia visible, conserva su columna y refleja el cambio a los demás miembros. Confirmado: visibilidad de completadas/historial configurable por persona, sin alterar otras vistas ni borrar contenido. P06 confirma persistencia por usuario y tablero/vista, sincronizada entre sus dispositivos, con reinicio explícito. Scroll y columna activa son estado de navegación. Reapertura según C-74 y sección 8.2.

**Confirmado:** reabrir desde el detalle de la tarea y agrupar completadas en «Completadas (N)» al pie de cada columna (y un grupo en Mis tareas), sin cambiar columna ni posición persistidas. Solo en el detalle se ofrece destildar; la casilla de una tarjeta completada en la vista compacta es indicativa, no un control de reapertura accidental. Mantener la capacidad de abrirla por teclado y móvil.

El colapsado es personal y no elimina datos. C-106 confirma grupo expandido y completadas visibles por defecto; recordar después la preferencia del usuario. Una tarea reaparece en su propia columna al reabrirla; si ya hay otra pendiente de la misma serie se necesita la política específica de sección 8.2.

Orden de captura: la preferencia expresada es añadir nuevas debajo en orden de creación/manual, conservando reordenamiento manual. En un modo de ordenación por vencimiento, una nueva tarea se coloca según su fecha, no necesariamente al final. Ninguna afirmación de esta spec supone que todas las aplicaciones externas ordenen igual.

Confirmado: mover manualmente tareas entre columnas para el flujo Kanban. Mover no completa ni reabre una tarea; completar no la mueve. Se conserva el estado y la fecha al mover, también en tareas recurrentes. El movimiento manual de una ocurrencia no cambia por sí solo la ubicación de las futuras: ese alcance se determina al editar la programación. No se incorpora traslado entre tableros a partir de este pedido, que el usuario corrigió expresamente a columnas.

### 6.2 Reloj: «Programar»

Control opcional con nombre accesible «Programar», operable por teclado y en móvil. El icono no es la única explicación. Al abrirlo, propuesta de campos progresivos:

| Control | Valor inicial propuesto | Qué habilita |
| --- | --- | --- |
| Fecha | Sin fecha | Día de vencimiento de tarea o fecha de la tarjeta de cumpleaños. |
| Repetir | No se repite | Frecuencia, intervalo, calendario y final de serie. |
| Mostrar antes | Desactivado / 0 días | Anticipación opcional por serie, calculada desde la fecha de cada repetición; no mueve tarjetas existentes. |

Repetir no activa anticipación por defecto. Tener fecha no activa repetición. «Mostrar antes» necesita una serie y fecha de referencia válidas; no oculta tareas puntuales ya creadas. Una tarjeta de cumpleaños mantiene su naturaleza sin checkbox; su presentación anual sin completado se termina de especificar aparte. No se añade tipo genérico de evento por inferencia.

Confirmado: mostrar un resumen pequeño del calendario, al servicio de gestionar tareas; no una vista de calendario siempre visible. Antes de guardar se propone resumen y próximas tres fechas dentro del panel, por ejemplo «Lun/mié cada 2 semanas · aparece 1 día antes». Los detalles de inicio/final se consultan en el reloj. Cancelar no modifica nada. Guardar aplica la configuración completa de forma coherente. La tarjeta cerrada muestra solo un resumen breve cuando hay programación.

Los valores imposibles se explican junto al campo. Desactivar una opción no borra silenciosamente historial ni otras opciones independientes. Quitar una fecha necesaria para recurrencia/aparición exige resolver o desactivar esas reglas explícitamente antes de guardar.

### 6.3 Mis tareas — vista personal confirmada

Reúne las tareas cuyo responsable es el usuario actual en todos los tableros a los que conserva acceso, aunque estén en columnas diferentes. Es otra vista de la misma tarea: conserva identidad, tablero y columna originales. No crea una copia ni mueve nada a un tablero personal. Los tableros siguen siendo la entrada principal.

Confirmado: completar desde Mis tareas actualiza el mismo completado que ve el tablero y sus miembros. Cambiar la tarea desde el tablero se refleja en Mis tareas. La misma regla de permisos y de ocurrencias vigentes aplica en ambos lugares, sin un estado de completado local independiente.

Presentación propuesta: título, tablero/columna de origen, responsable implícito (el usuario), prioridad, fecha/resumen breve y casilla. Acceso al tablero/editor original para el resto de operaciones; no se agrega un segundo editor completo por inferencia. **Orden confirmado:** fecha límite ascendente, más antiguas primero, después próximas y sin fecha al final. Alternativa por creación ascendente, nuevas debajo. C-104 confirma desempate por creación ascendente e identidad estable. El orden por fecha prevalece sobre añadir al final mientras ese modo esté activo. Ordenar esta vista no reordena las columnas de origen ni cambia preferencias de otros. El grupo de completadas propuesto en 6.1 ordena esas tareas dentro de su propio grupo.

Casos obligatorios del contrato: una tarea que cambia de columna mantiene una sola entrada con su nueva ubicación; al desasignar/cambiar responsable, borrar la tarea o retirar acceso deja de aparecer donde corresponda. Una repetición nueva sustituye a la anterior pendiente también en Mis tareas. Completar en dos vistas simultáneamente es una operación de establecer completado, no dos alternancias que puedan reabrirla; ante pérdida de permiso se rechaza y se reconcilia la vista sin anunciar éxito.

El listado se filtra con autorización en servidor/base. No descargar tareas ajenas al navegador para ocultarlas después. Tareas creadas por el usuario pero asignadas a otra persona no pertenecen a esta vista; una tarea propia sin responsable tampoco se autoasigna para hacerla aparecer. No se incorpora agenda de cumpleaños a esta vista de tareas asignadas por defecto.

### 6.4 Confianza durante el trabajo compartido — confirmado

- Mostrar guardando, guardado o error; nunca anunciar persistencia que falló.
- Sin conexión, consultar contenido ya cargado con aviso de desactualización y conservar el texto que se estaba escribiendo. No se promete edición offline sincronizada ni funcionamiento completo al recargar sin red.
- Si dos personas modifican el mismo contenido, no sobrescribir silenciosamente; conservar borrador y permitir revisar el conflicto antes de intentar guardar otra vez. El mecanismo técnico y duración de conservación del borrador siguen por diseñar.
- P06: orden, filtros y visibilidad de completadas se recuerdan por persona y contexto (vista/tablero), también entre sus dispositivos, con reinicio explícito; no cambian el orden manual común ni las preferencias de otros. Valores iniciales y contrato técnico se consolidan en CF-13.

Estos contratos se aplican también a Mis tareas y al detalle común, no solo al tablero. Consultar datos ya cargados sin red no garantiza detectar de inmediato una revocación remota: al conocerla, cerrar acceso y limpiar estado privado activo. Nunca prometer retirar copias que una persona ya descargó.

## 7. Catálogo confirmado de recurrencias — detalles de ejecución por cerrar

El usuario pidió opciones amplias similares a series de calendario. Esta tabla hace revisable esa intención; **no afirma equivalencia exacta con Outlook ni incorpora horarios, duración de reuniones o asistentes**. La precisión por día sigue vigente.

| Patrón candidato | Configuración | Ejemplo ficticio |
| --- | --- | --- |
| Sin repetición | Fecha opcional | Investigar un crédito una sola vez. |
| Cada N días | N entero positivo y fecha de inicio | Revisar gastos cada 10 días. |
| Cada día laborable | Lunes a viernes como selección de días | Revisar pendientes de lunes a viernes; no supone feriados nacionales. |
| Cada N semanas | N, uno o varios días y semana de anclaje | Estirar lunes y miércoles; o esos días cada 2 semanas. |
| Cada N meses, por fecha | N y día del mes | Día 15 cada mes; día 10 cada 3 meses. |
| Cada N meses, por posición semanal | N, primero/segundo/tercero/cuarto/quinto/último y día de semana | Segundo lunes de cada mes; último viernes cada 2 meses. |
| Cada N años, por fecha | N, mes y día | Cumpleaños anual; revisión cada 2 años. |
| Cada N años, por posición semanal | N, mes, ordinal y día de semana | Segundo miércoles de noviembre de cada año. |

Catálogo y finales confirmados C-73, anclajes/excepciones C-110 y conteo de conversión/edición C-111. CF-04–08 los concretan; no recortar patrones aprobados a escondidas durante la implementación.

«Los segundos días de la semana» no tiene una interpretación única: podría referirse a martes o al segundo día de semana elegido de un mes. El panel usaría nombres explícitos como «martes» o «segundo lunes del mes». No se incorpora esa frase como regla ambigua.

### 7.1 Inicio, final y previsualización

C-110 confirma inicio/anclaje/final/conteo. Validaciones y límites técnicos se diseñarán sin cambiar estos contratos:

- Fecha de inicio obligatoria al activar repetición; si ya hay fecha de tarea se propone reutilizarla, mostrando el resultado antes de guardar.
- Para semanas alternas, semana de lunes a domingo anclada a la semana de inicio; se muestran únicamente fechas iguales o posteriores al inicio. Completar tarde no cambia esa fase.
- Final: sin final, hasta una fecha inclusiva o después de N ocurrencias. N cuenta fechas generadas por la regla, no cantidad de tareas completadas. Omitir una fecha no extiende la serie automáticamente.
- Validar intervalo/conteo positivos, días seleccionados y existencia de al menos una fecha entre inicio y final. Los máximos admitidos se fijarán en el contrato técnico para evitar reglas o vistas imposibles de procesar.
- No generar todas las ocurrencias futuras de una serie infinita. La UI solo necesita una vista acotada y la actividad vigente; la estrategia de persistencia queda para diseño técnico.

### 7.2 Fechas difíciles — reglas confirmadas C-73/C-110

Zona horaria confirmada **por tablero**, inicialmente la del creador; solo propietario la cambia según C-94. Todas las personas del tablero ven el mismo día de vencimiento; el cambio de día se evalúa en esa zona. Durante la fecha: «vence hoy»; al día siguiente: «vencida» si sigue pendiente. No se convierten fechas simples en medianoches UTC que cambien de día entre clientes.

**Confirmado:** para fecha mensual inexistente, usar el último día disponible y conservar la regla original (31 de enero → 28/29 de febrero → 31 de marzo), explicándolo en el resumen. Reemplaza la propuesta previa de omitir ese mes. Microsoft documenta que distintos formatos resuelven estos casos de forma diferente; no es una regla universal. [Referencia oficial](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxcical/4f8a95e3-542a-4c8b-88b3-1b00355286e7).

Confirmados en C-73: 29 de febrero anual → 28 de febrero en años no bisiestos, manteniendo 29 como regla; quinto día semanal inexistente → omitir ese mes, sin convertirlo en «último». Ofrecer «último día» y «último lunes» como patrones explícitos. La elección anual es diseño propio, no comportamiento comprobado de todos los clientes Outlook. Mostrar fechas resultantes antes de guardar. Finales sin final, hasta fecha o N repeticiones aprobados; C-110 confirma conteo de fechas efectivas/frontera inclusiva en CF-04.1.

Cambiar la zona horaria o la fecha ancla requiere previsualizar el próximo calendario. Un cambio no reescribe completados históricos ni activa dos veces la misma ocurrencia. Cruces de mes/año, horario estacional y febrero deben quedar cubiertos por pruebas con reloj controlado.

### 7.3 Calendario fijo confirmado; completado independiente

Confirmado: todas las recurrencias de este MVP dependen del calendario, no de completar la tarea. «Cada 3 días desde el 1 de noviembre» produce 1, 4, 7, 10 de noviembre, aunque se complete tarde; «martes cada 2 semanas» respeta su semana de anclaje; «día 23 de cada mes» mantiene ese día. Se excluye la variante «N días después de completar». Tampoco hay repeticiones calculadas antes de un completado futuro. Fechas difíciles ya aprobadas; C-110 precisa fin/conteo y frontera de excepciones. Solo quedan los detalles delimitados en CF-04.1/CF-07.1/CF-09.1. No se afirma qué permite Outlook: esta es una decisión de nuestro producto.

## 8. Serie, ocurrencias y cambios

Una serie tiene identidad propia, incluso si cambia de título. Una ocurrencia representa una fecha de esa serie. Propuesta: hereda título, descripción, prioridad y responsable predeterminados, con pertenencia al mismo tablero y columna de aparición configurada. No identificar series comparando títulos.

Estados confirmados de ocurrencia: pendiente vigente, completada y reemplazada; eliminación recuperable es otra dimensión. «Vencida» se calcula para una pendiente pasada de fecha. «Reemplazada» no es «hecha». Conservar suficiente información de la anterior para no perder un completado ni confundir una omisión; historial compacto paginado acordado en CF-06/UI-09, con acceso a contenido autorizado; no es una auditoría de versiones de texto.

### 8.1 Aparición y no acumulación

Acuerdo: no apilar pendientes vencidos de la misma serie. Sin anticipación, la siguiente se activa en su fecha; con anticipación, en D−X. Reemplaza como vigente a la anterior pendiente y conserva las completadas como completadas. Si se vuelve tras varios períodos, reconciliar al período vigente sin crear una pila de tarjetas atrasadas ni marcar trabajo realizado.

CF-06/CF-08 y C-74: la actual completada permanece consultable, sin generar la siguiente antes de su aparición; Series muestra próxima fecha. Historial/completadas cargan progresivamente, sin borrado automático por antigüedad. C-106 fija visibilidad inicial; Q61 añade historial explícito a búsqueda.

Final de serie: propuesta, no crear fechas fuera del límite; si la última ocurrencia sigue sin completar, conservarla y destacarla. Detener repetición conserva la ocurrencia actual como tarea puntual y su estado. Borrar serie es otra acción explícita con confirmación de alcance; no equivale a detenerla (8.4).

### 8.2 Edición y excepciones confirmadas

- Completar/destildar afecta solo a la ocurrencia vigente, nunca a toda la serie. Confirmado C-74: reabrir desde detalle solo la vigente mientras no haya aparecido una posterior. Las antiguas se consultan con sus comentarios/archivos, pero no vuelven a pendientes, aunque la posterior esté completada.
- Edición de contenido/fecha/responsable: distinguir «esta repetición» de «Editar serie». Confirmado: editar la serie afecta solo a las próximas; la actual visible se edita aparte y las anteriores conservan su información. No pedir ese alcance al tildar una tarea sencilla.
- Cambiar patrón, inicio o final de serie: previsualizar el calendario futuro desde el punto de cambio, preservando la actual y el pasado. Conservar identidad de serie y excepciones compatibles; explicar qué excepciones futuras quedarían fuera antes de aplicar. No generar nuevas ocurrencias retroactivas por editar una serie histórica.
- «Omitir esta fecha» no completa ni elimina toda la serie. «Detener repetición» no elimina su historial. Borrar una repetición frente a toda la serie es una elección confirmada; el contrato de contenido/historial se concreta en 8.4. No añadir dos botones sinónimos para omitir/borrar una ocurrencia mientras no se defina una diferencia útil.
- La edición excepcional de una fecha no desplaza por sí sola los próximos lunes/miércoles. C-110/CF-07.1: nuevo vencimiento estrictamente anterior a siguiente aparición; igualdad o posterior se rechaza conservando borrador.
- Si se retira al responsable, resolver tanto la ocurrencia activa como la asignación predeterminada de próximas ocurrencias, sin volver a asignarle trabajo automáticamente.

Estas opciones cubren las operaciones de una serie de tareas; no añaden un calendario de reuniones. C-95 confirma conflicto sin sobrescritura y borrador autorizado conservado para revisión; DT-0.1 concreta versiones de regla y preview.

### 8.3 Columna de aparición y edición de la serie

**Confirmado:** abrir una tarea recurrente ofrece acceso a «Editar serie». Allí se puede elegir en qué columna del mismo tablero aparecerán las nuevas ocurrencias. Ejemplo: la serie nació en A; al elegir B, las próximas aparecen en B. A y B representan columnas creadas por el usuario, sin significado de estado impuesto.

Propuesta de valor inicial: usar la columna donde se creó la tarea, mostrando esa selección en la configuración de serie. Mover manualmente una ocurrencia de A a C no cambia la regla de aparición de las siguientes; editar la serie sí la cambia. Completar sigue siendo independiente de ambas ubicaciones.

Al guardar debe mostrarse el alcance en lenguaje directo, por ejemplo «Las próximas repeticiones aparecerán en B». **Confirmado:** la actual ya visible conserva su posición/configuración; el usuario puede cambiarla aparte. Los completados anteriores tampoco se trasladan. Editar una serie no reubica retroactivamente sus tarjetas ni deshace el trabajo de otros miembros.

La columna de aparición es la única ubicación configurada por la serie. «Mostrar antes» cambia la fecha de aparición, no agrega otro destino: las nuevas ocurrencias aparecen directamente en esa columna. Cambiar A por B afecta solo próximas. La actual puede permanecer en C si alguien ya la movió; no se la devuelve automáticamente al origen.

Si se elimina una columna referenciada por series, no crear «Pendientes» automáticamente ni elegir otra al azar. **Confirmado al aceptar la recomendación:** identificar las series afectadas y pedir ubicación sustituta antes del borrado. CF-12 exige mostrar y resolver por separado tareas presentes y series referenciadas; confirmar traslados y borrado coherentemente, sin destino implícito. No hay destinos de movimiento automático que mantener. El borrado general sigue en MVP-D-11.

### 8.4 Borrado de tarea, ocurrencia y serie

**Confirmado:** ofrecer alcance al borrar una tarea recurrente. Propuesta de etiquetas sin ambigüedad:

- Tarea puntual: «Eliminar tarea», con la confirmación habitual.
- Tarea de una serie: «Eliminar solo esta repetición» o «Eliminar toda la serie», además de cancelar. «Tarea» y «esta repetición» no son dos alternativas diferentes para la misma tarjeta.

Contrato confirmado de **solo esta repetición**, complementado por C-98/C-110: retirar esa ocurrencia de tablero y Mis tareas, conservar la serie y las otras ocurrencias. Recordar su exclusión para que no reaparezca al recargar, al ejecutar el programador o al reconciliar tras inactividad. No marcarla completada, no reactivar una anterior reemplazada y no adelantar automáticamente la próxima; esperar su activación programada. El alcance debe mantenerse ante reintentos y dos usuarios; un trabajo en curso no puede resucitarla.

**Confirmado al aceptar ambas opciones con su significado:** «Dejar de repetir» conserva las ocurrencias e historial existentes y deja de generar próximas; «Eliminar toda la serie» elimina la serie y sus ocurrencias, incluidas completadas e historial, con advertencia explícita. La recuperación durante 7 días se rige por 4.6, con contratos de restauración C-110 y mecanismos/pruebas todavía pendientes. Detener no borra la actual ni la marca hecha.

Contrato técnico candidato: cancelar las activaciones futuras que correspondan a lo detenido o eliminado y evitar que un trabajo concurrente lo regenere. Diferenciar «futura» de una actual que ya se activó anticipadamente, aunque su vencimiento todavía no haya llegado. Al detener, la actual visible permanece con fecha, ubicación y estado intactos. No hay movimientos automáticos pendientes que conservar o cancelar.

Borrar una ocurrencia no concede permiso para borrar el tablero. Se conserva la autorización de edición general de tareas para propietario y colaborador; el alcance destructivo se confirma aunque el usuario sea propietario. Mis tareas ofrece el mismo resultado sobre el origen si en el futuro expone estas acciones; por ahora solo está confirmado completar desde esa vista.

Casos pendientes: cambiar el patrón después de excluir una fecha (mantener o invalidar excepciones explícitamente), eliminar la última repetición y recuento final, colisión de edición con borrado y opciones de recuperación. No deducir la semántica de estas opciones por una supuesta paridad con Outlook; son contratos de nuestra app.

### 8.5 Vista compacta de series — alcance confirmado, presentación propuesta

El usuario pide un botón discreto para acceder a las series creadas y recordar qué sigue programado, incluso si completó la última tarea y la ocultó. La lista se obtiene de las series, no de las tarjetas visibles: ocultar completadas no oculta ni detiene una serie.

Propuesta de acceso: botón «Series», operable por teclado y móvil, abre una sección secundaria que no ocupa espacio permanente del tablero ni reemplaza la navegación principal. La ubicación exacta del botón queda para el diseño; no agregar otro panel siempre abierto.

**Alcance confirmado:** todas las series de tableros a los que tiene acceso, con filtro por tablero, incluidas las creadas por otros colaboradores. No solo las que creó personalmente ni solo las que tienen una tarea asignada a él. No es un inventario global de la aplicación. La agrupación y ubicación visual exacta siguen siendo decisiones de presentación.

Contenido compacto propuesto por fila: nombre de la serie, tablero, resumen de repetición y próxima aparición. La próxima aparición puede ser anterior al vencimiento; mostrar «Aparece el…» y, cuando difieran, «Vence el…», evitando llamar a ambas «próxima fecha». Columna de aparición, responsable y final de serie pueden consultarse en el editor; no llenar la fila de campos.

Desde una fila se abre el mismo editor de serie accesible desde una tarjeta, con cambio de próximas, «Dejar de repetir» y «Eliminar toda la serie». No se crea un segundo modelo de edición ni se exige que haya una ocurrencia visible. Las comprobaciones de acceso son las del tablero: propietario y colaborador pueden administrar las series, independientemente de su creador o responsable de tarea.

Estados de presentación candidatos: activa, detenida y finalizada (por fecha/conteo). Si está activa sin una tarjeta pendiente, mostrar igualmente cuándo vuelve a aparecer. Si una regla tiene un problema de destino, indicarlo en esa fila sin inventar una próxima ejecución válida. Propuesta: activas visibles por defecto y control para consultar detenidas/finalizadas; ocultar completadas no modifica ese control. Una serie eliminada no aparece como activa ni detenida. C-112 no agrega reanudación de la anterior: volver a programar crea otra serie desde la misma tarea; CF-08.1.

Propuesta de estado vacío: «Todavía no hay series en este alcance». Crear una serie sigue partiendo de una tarea y su reloj; no se agrega un flujo de creación independiente por inferencia. Suspender al usuario o retirarlo del tablero elimina acceso también a nombres, resúmenes y acciones de esta sección. No exponer un directorio global de series de toda la aplicación.

Escenario principal: una persona completa su tarea diaria y oculta completadas; el tablero queda sin esa tarjeta. En Series sigue viendo la regla y la próxima aparición, puede cambiar su columna futura o dejar de repetir sin desocultar la tarea. Ninguna de esas acciones mueve o reescribe la actual por sí sola.

## 9. Aparición anticipada opcional — sin movimiento automático

**Confirmado:** «Mostrar X días antes» es opcional y elegido por el usuario para una serie. Para vencimiento D y anticipación X, aparición A = D−X, por días de calendario. Con X = 0 aparece el día que toca. La ubicación es la columna de aparición configurada, no una columna destino adicional. Una vez visible, la tarjeta solo cambia de columna por una acción manual permitida; no hay movimiento programado.

La tarea puntual se ve al crearla; no se introduce ocultamiento programado de tareas puntuales por inferencia. Cumpleaños sigue como fecha anual sin completado y necesita cerrar su ciclo visible después de la fecha; no hereda estados de trabajo realizado/omitido.

### 9.1 Activación y reemplazo

Cuando se activa una nueva ocurrencia, sustituye como pendiente vigente a la anterior pendiente de la misma serie. La anterior se conserva como omitida/reemplazada, nunca como realizada. Si estaba completada conserva ese estado. En tablero y Mis tareas se aplica el mismo resultado sin duplicados. La fecha límite de la nueva no cambia por aparecer antes.

Ejemplo ficticio: serie de lunes con 3 días de anticipación y columna de aparición A. La del lunes 16 de noviembre de 2026 aparece el viernes 13 en A. Si la del lunes 9 seguía pendiente, queda reemplazada, no completada; si estaba hecha, conserva ese estado. El usuario puede mover la nueva de A a B y seguirá en B al recargar.

Tras inactividad, propuesta de reconciliación: considerar la última activación alcanzada por la fecha actual, sin recrear la pila de anteriores ni adelantar la siguiente. Respetar las ocurrencias explícitamente eliminadas y las series detenidas/finalizadas. La especificación técnica debe definir materialización sin convertir el navegador en autoridad del reloj ni omitir actualizaciones en clientes que ya estaban abiertos.

### 9.2 Límite de anticipación — confirmado

El caso «cada 3 días, mostrar 4 antes» no es una fecha matemáticamente inválida. El conflicto surge con nuestro contrato de un único pendiente vigente: la nueva reemplazaría a la anterior antes de que esta llegara a su vencimiento. No presentarlo como una limitación universal de calendarios ni como una restricción impuesta por Microsoft.

Recomendación candidata: para series con próximas ocurrencias consecutivas, exigir **0 ≤ X < separación mínima entre vencimientos**. Así la nueva no reemplaza a la anterior antes de terminar el día de su vencimiento. Usar días de calendario y comprobar también los límites de la serie actual/futuras al editar, conservando la actual visible.

| Calendario | Separación mínima | Anticipación máxima propuesta |
| --- | --- | --- |
| Cada día | 1 día | 0 días |
| Cada 3 días | 3 días | 2 días |
| Cada lunes | 7 días | 6 días |
| Lunes y miércoles | 2 días | 1 día |

Si se intenta guardar 4 días para una serie cada 3, mantener el formulario y explicar «Para esta serie podés anticipar hasta 2 días». No guardar una regla parcialmente válida, no recortar el número silenciosamente y no lanzar un error técnico. Revalidar si se modifica frecuencia, días, fecha excepcional o política de calendario. Sin otra ocurrencia con la que solaparse no se inventa un conflicto, pero siguen vigentes fecha de inicio y límites de entrada.

En calendarios variables (meses, ordinales, años) calcular la separación real según la política aprobada. Tres fechas de previsualización no prueban que el resto de la serie sea válido: verificar el intervalo completo si es finito o un ciclo suficiente de la regla si es indefinido, con un cálculo acotado y probado. No usar 30 días como duración fija del mes. El método se concreta en diseño técnico; no crear infinitas ocurrencias para validar.

Esta política está aprobada. Permitir varias ocurrencias pendientes simultáneas cambiaría el acuerdo vigente; no se incluye esa alternativa.

### 9.3 Cambios, fallos y ejecución

- Editar la serie cambia próximas; no modifica la actual. Si la nueva regla implicara reemplazar inmediatamente la actual todavía no vencida o una activación ya pasada, mostrar el conflicto antes de guardar y resolverlo explícitamente, sin hacerlo en silencio.
- Completar temprano no activa la siguiente. Detener conserva actual e historial; eliminar cancela próximas y no permite regenerarlas por reintentos.
- Si desaparece la columna de aparición, exigir la sustitución en el flujo aprobado. Ante una referencia inválida inesperada, no perder la serie ni crear una columna arbitraria; comunicar y permitir corregir.
- La misma activación ejecutada por dos clientes o reintentada produce una sola ocurrencia y una sola transición de anterior a reemplazada.
- Propiedad de la programación: se propone que pertenezca al tablero y siga existiendo aunque se retire su creador, con responsable elegible y permisos vigentes. Retirar acceso no elimina contenido, pero no concede privilegios a futuros trabajos de fondo.

Pendiente técnico: elegir materialización en segundo plano o reconciliación al consultar con actualización de clientes abiertos. En ambos casos debe verse el estado correcto al entrar después de varios días. No se promete scheduler, precisión horaria o compatibilidad con plan gratuito sin verificación de infraestructura; avisos externos siguen fuera del alcance base.

## 10. Recorridos candidatos de aceptación

Los IDs MVP-AC complementan AC-01–28, sin sustituirlos. Cada criterio depende de cerrar las opciones citadas; no representa una prueba ya ejecutada.

| ID | Escenario | Resultado verificable |
| --- | --- | --- |
| MVP-AC-01 | Persona con Google válida pero no habilitada conoce una URL/invitación. | No crea ni lee tableros; enlace no concede admisión ni se consume por intento inelegible. |
| MVP-AC-02 | Usuario habilitado crea tablero y lo comparte. | Se establece dueño correcto y solo miembros elegibles acceden; cada llamada directa respeta roles. |
| MVP-AC-03 | Suspensión con sesión y canal abiertos. | Nuevas solicitudes y eventos privados se deniegan según contrato de revocación; contenido conservado, sin cascadas destructivas. |
| MVP-AC-04 | Tarea sencilla «Analizar gastos de gas». | Se crea solo con título y ubicación; reloj cerrado, sin campos temporales obligatorios. |
| MVP-AC-05 | Tarea con vencimiento, responsable y completado. | Se conserva ubicación, vence por día y se destaca si corresponde; completada atenuada y ocultable sin cambiar datos. |
| MVP-AC-06 | Regla diaria, semanal alterna, mensual ordinal y anual. | Resumen/previsualización concuerdan con fechas reales de cada patrón aprobado; completar tarde no cambia un calendario fijo. |
| MVP-AC-07 | Serie con final por fecha o conteo. | No se generan fechas fuera de rango; contar ocurrencias no depende de marcar tareas como hechas. |
| MVP-AC-08 | Editar una repetición o editar la serie. | Editar serie cambia próximas, preserva actual ya visible y pasadas. Editar la actual no cambia futuras por inferencia. Previsualización coherente. |
| MVP-AC-09 | Mes sin día 31, quinto lunes inexistente o 29 de febrero. | Resultado coincide con política explícita aprobada y con la previsualización; nunca una fecha imposible. |
| MVP-AC-10 | Regreso tras varios períodos sin uso. | Solo el pendiente vigente de cada serie, sin falsos completados ni pérdida de tareas puntuales atrasadas. |
| MVP-AC-11 | Aparición anticipada con dos clientes y reintentos. | Una ocurrencia por activación, sin copias; fecha intacta, permiso vigente y columna de aparición correcta. |
| MVP-AC-12 | Columna de aparición eliminada o edición de programación concurrente. | No se pierde contenido ni se anuncia éxito falso; conflicto o regla fallida se puede comprender y corregir. |
| MVP-AC-13 | Anticipación solapada con ocurrencia anterior pendiente. | En D−X se activa la nueva y reemplaza a la anterior pendiente de la misma serie en tablero y Mis tareas; anterior omitida, no completada. Fecha de vencimiento de la nueva intacta. |
| MVP-AC-14 | Cumpleaños anual. | Sigue siendo fecha sin checkbox; visibilidad y siguiente año respetan ciclo que se acuerde, sin movimiento automático. |
| MVP-AC-15 | Quitar miembro/cambiar rol de responsable con serie activa. | Ninguna próxima ocurrencia vuelve a asignarse a alguien inelegible; contenido conservado. |
| MVP-AC-16 | Teclado, pantalla móvil y lector de pantalla. | Programar, editar, completar y compartir son operables; resúmenes, estados y errores no dependen solo de icono/color. |
| MVP-AC-17 | Exportar/importar datos nuevos. | Contrato versionado preserva fechas/series acordadas; no importa membresías ni revive programaciones o permisos inválidos. Ensayo en base descartable. |
| MVP-AC-18 | Mis tareas reúne asignadas desde dos tableros y distintas columnas. | Una entrada por tarea autorizada, origen identificable, sin copiar ni mover. Tareas ajenas/no asignadas al usuario no aparecen. |
| MVP-AC-19 | Completar desde Mis tareas y desde tablero, incluso simultáneamente. | Mismo estado persistido y sincronizado, sin duplicar ni reabrir por doble solicitud de completado. Pérdida de permiso no produce éxito falso. |
| MVP-AC-20 | Mover una tarea manualmente entre columnas. | Mantiene identidad, fecha, asignación y completado; Mis tareas refleja nueva ubicación sin segunda entrada. No se mueve entre tableros. |
| MVP-AC-21 | Dos miembros eligen distinta visualización de completadas/historial. | Cada uno ve su preferencia; mismos datos compartidos, ningún borrado ni cambio de estado por ocultarlos. |
| MVP-AC-22 | Cambiar asignación o retirar membresía mientras Mis tareas está abierta. | Se retira resultado que dejó de corresponder; llamadas directas no permiten seguir leyendo/editando; no se conserva copia personal. |
| MVP-AC-23 | Usuario trabaja con una sola columna o varias de nombres libres. | Puede crear, completar y programar sin etapas ni movimientos obligatorios; la app no crea un flujo estándar para las series. |
| MVP-AC-24 | Abrir una recurrente y cambiar su columna de aparición de A a B. | Próximas ocurrencias usan B; el efecto de anticipación se explica según 8.3. La actual visible y las pasadas no se mueven. |
| MVP-AC-25 | Borrar solo una repetición y recargar desde dos clientes. | Según contrato candidato 8.4, desaparece esa ocurrencia de todas las vistas sin regenerarse, completar ficticiamente, eliminar la serie ni adelantar otra. |
| MVP-AC-26 | Borrar toda la serie mientras hay una activación en curso. | Tras confirmar alcance, ninguna ejecución posterior recrea ocurrencias eliminadas; cambios atómicos o conflicto informado. |
| MVP-AC-27 | Borrar columna utilizada como aparición. | Se resuelven referencias mediante el flujo aprobado; nunca columnas automáticas, ubicaciones arbitrarias ni pérdida silenciosa de tarjetas. |
| MVP-AC-28 | Completar y ocultar la última tarjeta de una serie activa. | Series sigue mostrando la regla y su próxima aparición y permite abrir el editor aunque no haya tarjeta visible. |
| MVP-AC-29 | Dejar de repetir frente a eliminar toda la serie. | Detener conserva actual/historial y evita próximas; eliminar advierte el alcance y retira también ocurrencias/historial. Ningún reintento las regenera. |
| MVP-AC-30 | Consultar Series con tableros propios, compartidos y ajenos. | Lista todas las series de tableros accesibles y permite filtrar por tablero, incluidas las creadas por otros miembros. No revela reglas ajenas y revalida acceso al editar/detener/eliminar. |
| MVP-AC-31 | Ordenar Mis tareas por vencimiento o creación. | Fecha límite ascendente, sin fecha al final; creación ascendente con nuevas debajo. Empates según política estable propuesta; no mueve tareas ni reordena columnas originales. |
| MVP-AC-32 | Completar tarde una tarea de calendario fijo. | Próximas fechas permanecen ancladas al calendario de la serie; no se calculan desde el completado. |
| MVP-AC-33 | Retirar usuario con tareas creadas o asignadas en tablero que permanece activo. | Conserva tareas en sus ubicaciones, no las completa ni borra; pendientes y próximas quedan sin ese responsable, conservando autoría histórica. Los miembros restantes pueden borrarlas expresamente según permisos. Tablero sin otros miembros sigue 4.5. |
| MVP-AC-34 | Anticipación de 4 días con serie cada 3 días. | No se guarda y se explica máximo 2; con 2 se acepta. Comprobar igualdad, cero, semanal variable y edición/excepciones, no solo ejemplo fijo. |
| MVP-AC-35 | Grupo de completadas y reapertura desde detalle. | Colapsar no mueve ni borra tarjetas ni afecta a otros; vista compacta evita destildado accidental y detalle permite reapertura autorizada con política de series. |
| MVP-AC-36 | Conversación y mención en tarea compartida. | Candidato 14.1: otro miembro ve el comentario y su autor; una mención no concede acceso; no puede editar silenciosamente texto ajeno. |
| MVP-AC-37 | Checklist de una tarea recurrente. | Confirmado: la siguiente ocurrencia nace con pasos de plantilla sin marcar; editar la actual no cambia la plantilla ni otras ocurrencias. |
| MVP-AC-38 | Archivo privado y retirada de acceso. | Candidato 14.3: usuario ajeno no descarga ni enumera; la revocación impide nuevos accesos. Prueba específica del plazo máximo de URLs temporales según contrato técnico. |
| MVP-AC-39 | Búsqueda entre tableros y filtros combinados. | Candidato 14.4: solo resultados autorizados, sin duplicados ni filtración de títulos/conteos; se puede incluir completadas expresamente. |
| MVP-AC-40 | Asignación y mención en una misma acción. | Candidato 14.5: una novedad relevante por destinatario/acción, no duplicados por reintentos; leer no completa la tarea ni marca leída la bandeja de otro. |
| MVP-AC-41 | Completar con pasos pendientes desde tablero o Mis tareas. | Confirmado: pedir confirmación con cantidad pendiente; cancelar no modifica la tarea; aceptar la completa sin marcar los pasos faltantes. Marcar todos los pasos no completa automáticamente la tarea. Reabrir conserva sus casillas. |
| MVP-AC-42 | Reemplazar una ocurrencia con conversación y archivos. | Confirmado: no copiar comentarios/archivos a la siguiente ni borrarlos por el reemplazo. Quedan asociados a la anterior; historial sujeto a permisos vigentes. |
| MVP-AC-43 | Fallo de guardado o desconexión mientras se escribe. | Mostrar error/no guardado, conservar texto y distinguir contenido ya cargado de estado actualizado. No presentar una operación offline como confirmada. |
| MVP-AC-44 | Dos miembros editan el mismo contenido. | Detectar conflicto, conservar borrador y permitir revisar; no aplicar una sobrescritura silenciosa ni perder cambios con un reintento. |
| MVP-AC-45 | Dos usuarios cambian preferencias de vista. | Cada uno conserva sus elecciones al volver; no reordenan las columnas compartidas ni cambian la preferencia del otro. Persistencia entre dispositivos aprobada P06; contrato técnico en CF-13. |

No incluir pruebas ni desarrollo de repetición relativa al completado ni movimiento automático: ambos están excluidos. Aparición anticipada, su límite y agrupación de completadas están confirmados. Los criterios 37, 41 y 42 reflejan acuerdos; 36, 38–40 aún contienen detalles candidatos que deben cerrarse. Usar fechas/relojes controlados y datos ficticios, pruebas SQL entre identidades, regresión móvil/escritorio y sincronización privada. No tocar producción para especificar.

## 11. Contrato técnico que habrá que diseñar

Conservar Next.js, Supabase y la base de UI/RPC salvo necesidad demostrada. La implementación se diseñará después del cierre funcional. No se elige ahora una dependencia de recurrencias ni se inventa un nuevo servicio.

Antes de programar, especificar los mecanismos que satisfacen los resultados aprobados P16–P25 (detalle en §16.2):

1. Modelo de habilitación, bootstrap administrativo y matriz de autorización única en servidor/base/canales.
2. Modelo de serie, ocurrencias, excepciones y activaciones; restricciones que aseguren un solo pendiente vigente y un solo efecto por disparo. No sobrecargar la fecha de una tarea con todas esas identidades.
3. Reglas de calendario compartidas por previsualización, persistencia y ejecución; representación de día sin desplazamiento horario. La zona horaria afecta cambio de día, no el día elegido.
4. Contrato de edición concurrente, reintentos, errores y recuperación; integración con sincronización existente.
5. Ejecución de programación: aparición, vencimiento y recuperación tras inactividad. Documentar precisión y límites del hosting real antes de prometer trabajo en segundo plano.
6. Exportación/importación versionadas, historia mínima y migración de datos actuales. Importar un archivo no otorga permisos, admisión o acceso a otro tablero, ni ejecuta todas las fechas pasadas.
7. Presupuesto de consultas/trabajos y límites de reglas; evidencia de viabilidad en infraestructura elegida. Ninguna evaluación de planes de este documento sustituye una verificación técnica actualizada.
8. P17/P18: contratos por acción con campos permitidos, referencias autorizadas, versiones de edición y claves de operación; separar campos de tarea de comentarios/pasos/archivos y enviar estado de completado deseado.
9. P19/P20: trabajo pendiente durable, reintentable y deduplicado; canales privados usados como señal de reconciliación; invalidar sesiones/respuestas antiguas y preservar borradores mientras exista acceso.
10. P21/P22: borrado con causa, actor, vencimiento y dependencias; coordinación restauración/purga; reserva/carga/verificación/publicación de archivos y reconciliación de residuos.
11. P23/P24/P25: resúmenes separados del detalle, paginación autorizada y estable, exportación completa, respaldo de instancia además del portable; versiones, migraciones, diagnóstico sin contenido privado y recuperación ensayada.
12. E01–E07: modelo y ciclo de vida de etiquetas, consultas guardadas, tema, copia, actividad, instalación y lectura por lote. No materializar vistas como tareas ni convertir preferencias en permisos.

El corte de anónimo a privado es un cambio completo de autorización. Se ensaya en local con datos ficticios, se preservan los tableros aprobados y se asignan dueños explícitos. No se publica solo un login mientras siguen abiertas las RPC/canales. Seguir la sección 8 de spec 0001 para respaldo, ensayo, corte y recuperación cerrada.

## 12. Índice de decisiones cerradas y verificación técnica

Esta tabla reemplaza la antigua lista de preguntas D-01–13: no reabre decisiones aprobadas. Los registros de revisión posteriores conservan lo que se sabía en cada fecha.

| ID | Contrato vigente | Verificación técnica |
| --- | --- | --- |
| MVP-D-01 | Admisión por administrador, Google verificado, habilitación separada. C-22/C-71/C-93. | DT-0.1 §§3–5 / G01. |
| MVP-D-02 | Habilitado crea y es dueño; propietario/colaborador y tablero privado. | Integridad de propietario, RLS y grants G01. |
| MVP-D-03 | Catálogo completo fijo C-73; inicio/ancla/conteo C-110/C-111. | Calendario canónico G03. |
| MVP-D-04 | Zona de tablero y fechas difíciles CF-05. | Zonas, febrero/ordinales y cambios G03. |
| MVP-D-05 | Solo vigente reabrible, historia consultable, excepción acotada, detener/reprogramar C-112. | CF-06/07/08, C110–112 y G03. |
| MVP-D-06 | Aparición D−X en columna de serie; límite de anticipación §9.2. | Preview/validación/ejecución iguales G03. |
| MVP-D-07 | Movimiento manual; P19 exige ejecución durable con app cerrada. | Jobs y progreso autónomo G02. |
| MVP-D-08 | Mis tareas, orden/defaults y preferencias C-104/C-106; historial de búsqueda C-112. | Consultas/versiones, normalización y G07. |
| MVP-D-09 | Sucesor explícito; excepción reparadora; revocación y reingreso sin recuperar permisos. | Locks/episodios de membresía, G01/G05. |
| MVP-D-10 | Guardado/conflicto C-95; reemplazo previsualizado y previo retenido C-92. | Recibos/versiones y generaciones, G06. |
| MVP-D-11 | Recuperación7d por causa/actor; hijos independientes y traslados de columnas preservados. | Ledger/borrado/restaurar-purgar, G04. |
| MVP-D-12 | Series accesibles sin depender de tarjeta visible; historial paginado, sin reanudar A al programar B. | UI-09/CF-08.1 y C112-AC62. |
| MVP-D-13 | Colaboración, búsqueda unificada, novedades y33 P/E incluidas. | Matriz de trazabilidad y G01–G08. |

Condición para declarar la spec lista: alcance cerrado, decisiones sin ambigüedades que cambien comportamiento, matriz de permisos consistente, recorridos normales y fallidos con criterios verificables, plan técnico viable y estrategia de corte/recuperación. El usuario aprueba esa versión concreta antes de implementar. Las autorizaciones remotas siguen separadas.

### 12.1 Revisión de huecos con recorridos completos

Para cerrar el documento, cada recorrido debe describir actor autorizado, estado inicial, acción, resultado visible, datos que se conservan y respuesta ante error. Los siguientes son casos de revisión, no nuevas funciones aprobadas:

| Recorrido | Borde que debe quedar resuelto | Decisiones relacionadas |
| --- | --- | --- |
| Habilitar a un amigo, crear tablero y compartirlo | Quién es dueño, quién puede crear, qué ve cada miembro, duración/revocación del enlace. | D-01, D-02, D-09 |
| Asignar una tarea compartida y luego retirar al responsable | La tarea permanece; resolver responsable actual y de próximas repeticiones. No recuperar acceso con una invitación vieja. | D-02, D-09 |
| Completar, ocultar, mostrar y reabrir | Preferencia personal, reapertura de ocurrencia anterior y ubicación intacta. | D-05, D-08 |
| Programar una serie, omitir una fecha y terminarla | Calendario fijo, excepciones, última pendiente e historial de hechas frente a omitidas. | D-03, D-04, D-05 |
| Aparecer anticipadamente cuando queda trabajo anterior | Frontera de activación, límite de anticipación y respeto de movimientos manuales; no acumular pendientes. | D-06, D-07 |
| Borrar columna/tablero con series o reglas activas | Alcance exacto, confirmación, conservación o eliminación de contenido, invalidación de destinos y recuperación acordada. | D-11 |
| Perder conexión, editar desde dos dispositivos o perder acceso | Borrador no perdido silenciosamente, guardado veraz, conflicto explicable y autorización efectiva. | D-09, D-10 |
| Exportar, restaurar y migrar la instancia actual | Dueños explícitos, contenido y calendario coherentes, ningún permiso heredado de archivos o URLs. | D-09, D-10, D-11 |

En esta tabla D-xx abrevia MVP-D-xx. Cada resultado se convierte en criterio de aceptación al acordarlo; una casilla «pendiente» no puede pasar inadvertida al declarar el alcance listo.

### 12.2 Responsabilidad de cerrar decisiones

El usuario decide lo que cambia su experiencia: propiedad, roles, recurrencias, visibilidad, movimiento y expectativas de recuperación. El agente prepara recomendaciones y ejemplos para decidir por bloques, sin trasladar todos los detalles de ingeniería al usuario.

El agente debe concretar y verificar el contrato técnico correspondiente: autorización en todas las operaciones, idempotencia, conflictos, zonas horarias, formato de respaldo y viabilidad del hosting. Durante la fase de spec puede inspeccionar e investigar; no implementa ni modifica infraestructura. Las dudas técnicas se registran con evidencia pendiente y no se presentan como garantías cumplidas.

Para evaluar la ambición de producto, se propone una sesión guiada con los ejemplos ficticios ya aportados: crear una tarea sencilla sin configuración avanzada, compartir sin explicar conceptos técnicos, programar una rutina y anticipar dónde aparecerá, y volver días después entendiendo qué queda pendiente. Registrar fricciones y errores de expectativa antes de agregar nuevas capacidades. No declarar una superioridad frente a otros productos sin esa evaluación.

## 13. Orden candidato de construcción posterior

Una vez cerrada la spec y autorizada la implementación, las entregas serían: acceso cerrado y privacidad; tableros/miembros/roles y favoritos; captura/detalle/completado/fechas/checklist y copia puntual; series/excepciones/aparición anticipada; comentarios/menciones/adjuntos/actividad; Mis tareas/Series, búsqueda/filtros/etiquetas/vistas guardadas y novedades con lote; temas, instalación PWA y validación de recorridos; regresión y ensayo de migración. Español, accesibilidad, móvil, enlaces, preferencias y garantías P16–P25 atraviesan las entregas. Es un orden de construcción del mismo MVP, no permiso para desplegar versiones parciales inseguras ni para recortar el alcance acordado.

La evaluación final usa los ejemplos del usuario, convertidos en fixtures ficticios: gastos, investigación de crédito, estiramiento lunes/miércoles, tarea compartida de viaje, acción semanal, rutina diaria y cumpleaños. Se añade una serie quincenal y una mensual ordinal para comprobar que la programación es genérica. La decisión de qué producto usar después se apoya en esa experiencia, no en una promesa de ganar por tener más opciones.

Registro 0.1: amplía la visión con acceso controlado, roles candidatos, programación opcional genérica, catálogo de series, recorridos, criterios y decisiones de cierre. Solo documentación local.

Registro 0.2: admisión exclusivamente central confirmada; se descarta habilitación delegada. Propiedad y permiso de creación se mantienen abiertos ante la duda explícita del usuario. Se recomienda autonomía de propietarios dentro del grupo admitido y se agregan recorridos de revisión de huecos, incluido ciclo de borrado/recuperación. Solo documentación local.

Registro 0.3: el usuario acepta recomendaciones de roles/privacidad y repeticiones; confirma reemplazo de la anterior pendiente al aparecer la nueva anticipadamente, preferencias personales de completadas/historial, flujo manual entre columnas, calendario discreto, conservación al retirar acceso y Mis tareas sobre las mismas entidades con completado sincronizado. Se retiran alternativas descartadas, se agrega contrato de vista y criterios MVP-AC-18–22. Solo documentación local.

Registro 0.4: el usuario aclara que cada persona define su flujo, incluso sin mover tareas; no hay columnas obligatorias. Confirma acceso a editar serie para cambiar columna de aparición y elección de borrado por ocurrencia/serie. Se agregan contratos 8.3–8.4 y MVP-AC-23–27, con efectos sobre actual, historial y columna eliminada aún pendientes. Solo documentación local.

Registro 0.5: confirmados cambios de serie solo hacia próximas, opciones separadas de detener/eliminar y resolución de series afectadas al borrar columna. Se incorpora necesidad de vista compacta de Series independiente de tarjetas visibles, con diseño/alcance propuestos y MVP-AC-28–30. Solo documentación local.

Registro 0.6: solo recurrencia de calendario; excluida repetición tras completar. Movimiento automático/anticipación reabiertos, con contrato anterior condicional. Confirmados orden por vencimiento con alternativa por creación, permanencia de tareas de retirados y alcance de Series entre todos los tableros accesibles. Solo documentación local.

Registro 0.7: aparición anticipada opcional confirmada sustituye movimiento automático; se propone límite seguro para intervalos solapados. Orden por vencimiento/sin fecha confirmado y nuevas debajo en orden por creación. Grupo colapsable y reapertura desde detalle quedan propuestas del usuario; política de fechas especiales revisada con fuentes. Investigación compara huecos reales frente a Asana sin incorporarlos automáticamente.

Registro 0.8: confirmados anticipación/solapamientos, orden, completadas y regla mensual de fechas especiales. Se incluyen por decisión explícita comentarios, menciones, adjuntos, checklist sencilla, búsqueda/filtros y bandeja de novedades. Se proponen contratos y criterios 36–40 para cerrar interacciones, no más funciones. Solo documentación local.

Registro 0.9: el usuario acepta todas las recomendaciones presentadas en la respuesta anterior, incluida confirmación por pasos pendientes. Quedan confirmados checklist, herencia de pasos sin marcar, conversación/archivos por ocurrencia, eventos básicos de novedades y privacidad. No se interpreta esta aprobación como aceptación de detalles solo presentes en documentos ni como autorización para implementar. Criterios 41–42 y trazabilidad C-54–57. Solo documentación local.

Registro 0.10: acordados 7 días de recuperación y resolución de propiedad al retirar al dueño; sin otro miembro, tablero eliminado y recuperable solo con nuevo propietario. Adjuntos: intención de excluir Excel, imágenes, videos y archivos grandes; 24 KB tentativos, no cuota final. Verificación oficial distingue 500 MB de base de datos por proyecto de 1 GB de Storage del plan Free. Solo documentación local.

Registro 0.11: confirmados adjuntos solo de texto `.txt`/`.md`, límite presentado de 24 KB y enlaces para otros archivos; URLs pegadas deben ser clickeables. El usuario propone cuota global de 200 MB con eliminación de archivos antiguos. Se registra esa propuesta y se recomienda advertir/bloquear nuevas cargas sin borrar contenido vigente; política al alcanzar cuota pendiente de resolver por conflicto con conservación y recuperación de 7 días. Solo documentación local.

Registro 0.12: aceptada cuota global de 200 MB con aviso al 80 %, bloqueo de nuevas cargas que excedan el máximo y sin borrado automático por antigüedad. Se incorpora limpieza manual de adjuntos de tareas completadas para administrador/propietarios y avisos a propietarios. Alcance exacto de visibilidad administrativa y presentación candidatos; no se aprueba lectura global de contenido privado ni se crean cuotas por tablero. Solo documentación local.

Registro 0.13: aprobado el bloque presentado de uso cotidiano: guardado veraz, consulta limitada sin red y conservación de texto, conflicto sin sobrescritura silenciosa, desasignación de usuario retirado y preferencias personales recordadas. Se agregan C-66–70, criterios 43–45 y documento de cierre con recomendaciones pendientes CF-01–20. Solo documentación local.

Registro 0.14: aceptadas recomendaciones presentadas de acceso, fechas/patrones, reapertura/restauración, cumpleaños, borrado, moderación, búsqueda/preferencias y límites 90 días/20 adjuntos. Nueva precisión: sucesor automático al salir sin elegir y reasignación administrativa; menciones históricas de retirados pasan a texto sin vínculo. C-71–79 y sección 15 fijan el alcance, sin aprobar detalles no presentados ni implementación.

Registro 0.15: el usuario corrige la salida del propietario: elección de sucesor obligatoria, automática solo como protección excepcional por mayor antigüedad. Confirma reingreso sin recuperar permisos/asignaciones/menciones, recuperables dentro de 20 adjuntos y caducidad de novedades no leídas a 90 días. Se prepara propuesta de pantallas con inspección limitada del código actual, sin implementar. C-80–83 sustituyen los puntos anteriores incompatibles.

Registro 0.16: el usuario adopta panel lateral y separación global/tablero/tarea como navegación de primera prueba. Se detallan ubicaciones, permisos, regreso, móvil/teclado y criterios NAV-01–10 en Pantallas 0.2. C-84–86 registran lo acordado; no se aprueban por inferencia los contratos pendientes de edición/importación ni se implementa.

Registro 0.17: confirmados captura rápida, campos con Guardar, acciones independientes, cierre con opciones y detalle móvil sin scroll horizontal, C-87–91. Se inspecciona import/export original y se amplía CF-19 como propuesta de respaldo privado y reemplazo seguro; no aprobación automática ni implementación.

Registro 0.18: aceptado respaldo completo y reemplazo protegido 7 días, sin importar permisos ni avisos históricos y respetando cuotas. El usuario reafirma aplicación cerrada y pide reemplazar explícitamente la landing pública por login/habilitación antes de crear o gestionar tableros; se agrega contrato 4.0 y evidencia local de portada/proxy. C-92–93. Solo documentación.

Registro 0.19: creada la matriz única de permisos, separando administrador global de membresía de tablero. Se detallan recuperación, moderación, adjuntos, importación y revocación; MP-01–05 quedan como recomendaciones pendientes, no aprobaciones inferidas. PERM-01–22 son escenarios de aceptación, no pruebas ejecutadas. Solo documentación.

Registro 0.20: C-94 aprueba las cinco recomendaciones de permisos presentadas; matriz 0.2 conserva separados detalles granulares no presentados. Se propone [Estados y errores](./ESTADOS-Y-ERRORES-MVP-1.0.md), revisión 0.1: EE-01–06 y ERR-01–16, sin implementación ni pruebas ejecutadas.

Registro 0.21 (2026-10-24): C-95 aprueba los cinco principios EE-01–05 de [Estados y errores](./ESTADOS-Y-ERRORES-MVP-1.0.md), revisión 0.2. Detalles adicionales no presentados siguen propuestos; ERR-01–16 son casos futuros, no pruebas ejecutadas. Sin implementación.

Registro 0.22 (2026-10-24): C-96 aprueba primer recorrido y agrega llegada con invitación pendiente, sin exigir tablero propio. Pantallas 2.9 distingue aceptación desde enlace de descubrimiento de invitaciones dirigidas PE-01, todavía propuesto. Solo spec.

Registro 0.23 (2026-10-24): C-97 confirma invitación directa y genérica; PE-01 deja de estar pendiente. Directas a identidad habilitada con pendientes en Tableros; genéricas por enlace sin destinatario fijo. Mantener 72 h, revocación, un uso y habilitación previa. Pantallas 2.9–2.10 y matriz de permisos sincronizadas. Sin implementación.

Registro 0.24 (2026-10-24): C-98 aprueba últimos cierres de invitaciones, recuperación, principio de excepciones de series y transición con inventario autorizado. [Continuidad de la spec](./CONTINUIDAD-SPEC.md) guarda índice y punto de reanudación para nuevo chat. Aún falta consolidar textos históricos y diseño técnico, sin implementar ni operar servicios remotos.

## 14. Colaboración y localización — acuerdos y contratos pendientes

La comparación documentada está en [Referencias de producto](./REFERENCIAS-PRODUCTO.md). Asana tiene capacidades que la spec no cubre; la meta declarada no equivale a paridad de funciones. La investigación usa documentación oficial, no pruebas de interfaz ni una comparación completa por planes. Verificar esa diferencia responde al pedido del usuario y no autoriza implementación ni incorporación automática.

El usuario aprobó los cuatro bloques siguientes y las recomendaciones presentadas sobre checklist, repeticiones, novedades y privacidad. Las subsecciones distinguen **confirmado** de **propuesta**; los detalles no presentados siguen pendientes.

| Necesidad | Capacidad incluida | Contrato pendiente |
| --- | --- | --- |
| Hablar de la tarea del viaje sin perder contexto | Comentarios, menciones y adjuntos. | Autoría, edición/borrado, permisos, almacenamiento y contenido de una ocurrencia frente a serie. |
| Separar la investigación en pasos marcables | Checklist sencilla interna. | Confirmados reinicio de pasos, confirmación al completar con pendientes y reapertura sin alterar casillas. Permisos ordinarios C-110; interacción en Pantallas/CF-11. |
| Encontrar la tarea entre varios tableros | Búsqueda por texto y filtros. | Campos, alcance autorizado, incluidas/ocultas completadas y resultados sin duplicados. No confundir filtro de Series con búsqueda general. |
| Enterarse de asignaciones/cambios de amigos | Bandeja de novedades dentro de la app. | Confirmados eventos básicos, destinatarios y lectura/no leída. Edición/deduplicación y retención90 días confirmadas; lote C-109 y creador C-111. No implica push, correo ni nuevo proveedor. |

No agregar dependencias, campos personalizados, portafolios ni subtareas independientes por asociación con estos bloques. Fuentes y distinciones frente a funciones de Asana están en el documento de referencias.

Pulido transversal que debe cubrir los recorridos ya incluidos: captura rápida sin campos opcionales forzados; foco/teclado y móvil; estado guardando/error veraz; conservar borrador ante fallo; estados vacíos comprensibles; confirmaciones con alcance real; no cambiar orden o ubicación inesperadamente; recuperar de errores según política aprobada. Recuperación de borrados durante 7 días incluida según 4.6; no implica historial de versiones ni cola offline.

### 14.1 Comentarios y menciones

Propuesta: conversación plana y cronológica dentro de la tarea, con autor y fecha; sin hilos anidados ni chat separado. Solo el autor edita su texto, dejando marca de editado. Autor y propietario del tablero pueden eliminar comentarios con confirmación; moderar no permite atribuir texto nuevo a otra persona. Definir conservación de la marca de borrado al cerrar recuperación.

**Confirmado:** mencionar no habilita usuarios ni comparte contenido automáticamente. Solo se menciona a miembros actuales; cuando alguien sale, sus menciones históricas quedan como texto literal sin vínculo al usuario, perfil ni notificación. Esto no borra autoría histórica de comentarios. CF-03/C-81 confirma que un reingreso no revincula menciones anteriores. En series, comentarios pertenecen a la ocurrencia concreta y no se copian a la próxima. Que una pendiente sea reemplazada no debe borrar su conversación: queda asociada a la ocurrencia anterior y accesible mediante el historial acordado.

### 14.2 Checklist sencilla

**Confirmado:** lista plana de pasos con texto, casilla y orden manual; agregar, editar, marcar y eliminar. Sin responsables, fechas ni configuraciones propias de tareas independientes. Permisos de edición ordinarios C-110/CF-11; pasos no aparecen como tareas independientes en búsqueda/Mis tareas y muestran progreso discreto.

**Confirmado:** marcar todos los pasos no completa automáticamente la tarea. Al completar la tarea con pasos pendientes, pedir confirmación «Quedan 2 pasos sin marcar. ¿Completar igual?». Aceptar completa la tarea sin marcar esos pasos; cancelar no cambia nada. Reabrir conserva las casillas como estaban. Aplicar la misma regla desde tablero, detalle y Mis tareas.

**Confirmado para series:** checklist de plantilla; cada ocurrencia recibe sus propios pasos inicialmente sin marcar. Cambiar los de la actual solo afecta esa ocurrencia; editar la plantilla de serie afecta próximas, siguiendo el acuerdo general. Ejemplo: una revisión semanal con «revisar gastos» y «guardar resumen» no hereda los tildes de la semana anterior.

### 14.3 Adjuntos y su ciclo de vida

**Confirmado:** archivos privados del tablero, asociados a la tarea/ocurrencia concreta, no copiados automáticamente a próximas repeticiones ni borrados por el reemplazo de una pendiente. Propuesta para material permanente: referenciarlo desde la descripción de la serie mediante enlace, pero ese enlace no equivale a un adjunto privado ni garantiza permisos en otro servicio. Si se requieren archivos de plantilla repetidos, decidirlo expresamente antes de cerrar este contrato.

Todos los miembros actuales pueden consultar; propuesta de borrado ordinario: quien subió el archivo y el propietario del tablero pueden eliminarlo con confirmación. Confirmada además la necesidad de limpieza manual por administrador y propietarios, detallada debajo. Revocar acceso al tablero revoca nuevas consultas/descargas. No se puede retirar una copia ya descargada. Definir duración de enlaces temporales y su exposición residual al revocar antes de prometer revocación instantánea.

Almacenamiento privado y autorización efectiva para listar, subir, descargar y borrar; nombres y metadatos tampoco públicos. Validar tipo real, tamaño y nombre; no ejecutar HTML/SVG u otro contenido activo subido. La estrategia de entrega segura y si hace falta análisis adicional se evalúan técnicamente, sin prometer escaneo antivirus inexistente.

**Confirmado:** solo adjuntos de texto `.txt` y `.md`, hasta 24 KB según la recomendación aceptada. Para el resto de archivos se usan enlaces, sin subir copias a la app. Excel, imágenes, videos, comprimidos y ejecutables no están permitidos aunque sean pequeños. P22 confirma máximo inclusivo decimal de 24.000 bytes y verificación de contenido/permiso antes de publicar. Validar texto y extensión sin confiar solo en MIME enviado por el navegador; la entrega segura no ejecuta contenido activo. Un binario renombrado a `.txt` no debe aceptarse. No se integra otro proveedor ni se administran permisos del destino de un enlace.

**Confirmado sobre enlaces:** el texto pegado que represente una URL debe mostrarse clickeable. C-111 confirma detección en descripciones, comentarios y pasos, conservando edición como texto y activando enlaces al visualizar; admitir URLs `https://` y `http://`, y reconocer `www.` normalizándolo a HTTPS al abrir. C-111: dominios sin esquema ni www. quedan texto; excluir puntuación exterior, con pruebas. No activar esquemas ejecutables/locales como `javascript:`, `data:` o `file:`, ni interpretar HTML pegado. Abrir enlaces externos de forma segura sin navegación automática, descarga previa, previsualización remota ni rastreo del destino desde el servidor. Mostrar el destino reconocible; enlazar no concede acceso ni garantiza que el recurso externo siga disponible. C-111: título compacto abre detalle; URL de título en control externo separado dentro del detalle. Pasos enlazan al visualizar.

**Cuota global confirmada:** 200 MB para adjuntos de toda la aplicación, compartida entre todos los tableros, no 200 MB por tablero ni por usuario. P22 confirma 200.000.000 bytes; alcanza para aproximadamente 8.333 archivos del máximo de 24.000 bytes, sin contar metadatos y otros consumos de infraestructura. Es un límite propio del producto, no una garantía sobre el espacio libre real del servicio.

**Descartado por aceptación de la alternativa:** borrar archivos vigentes automáticamente por antigüedad para liberar cuota. Edad no significa que el archivo haya dejado de ser útil. La limpieza manual no equivale a vaciado inmediato ni a reducción de los 7 días de recuperación.

**Confirmado:** avisar al administrador al 80 % (160 MB); al llegar a 200 MB, rechazar solo nuevas cargas que excedan el límite. Mantener lectura/descarga, tareas, comentarios y enlaces funcionando. Borrado automático únicamente de archivos cuyo plazo de recuperación ya venció y de residuos de cargas fallidas según política técnica; nunca de archivos vigentes solo por antigüedad. No reducir los 7 días para liberar capacidad.

**Nueva necesidad confirmada:** poder seleccionar manualmente adjuntos para borrar, incluidos los asociados a tareas completadas, y avisar también a los propietarios de tableros al llegar al límite. Interpretación de alcance propuesta: cada propietario administra archivos de sus tableros; el administrador dispone de gestión global de almacenamiento. Completar una tarea no elimina sus adjuntos por sí solo, y eliminar un adjunto no borra ni reabre la tarea, su conversación o su checklist.

Contrato candidato de limpieza: lista filtrable por tareas completadas, selección explícita y confirmación de archivos/cantidad/tamaño. Para el propietario, contexto de tareas dentro de sus tableros; para el administrador no miembro, metadatos mínimos de almacenamiento (referencia, tamaño, fecha, tablero/propietario y condición de completado), sin leer/descargar adjuntos ni conversaciones privadas. Concretar identificadores visibles y permisos de esta excepción administrativa antes de implementar; no convertirla en membresía global. Registrar quién borró y permitir recuperación bajo el contrato de 7 días; volver a comprobar estado y permisos al confirmar una selección obsoleta.

El borrado manual oculta el archivo pero **no libera cuota hasta que se purga tras su plazo de recuperación**. Mostrar esa diferencia al confirmar, incluido espacio retenido y vencimiento. No ofrecer por inferencia «borrar definitivamente ahora», pues modificaría el acuerdo de recuperación. Solo borrar archivos, no las tareas completadas, al usar este flujo.

Contrato candidato de avisos a propietarios: al cruzar 160 MB y al alcanzar el máximo de 200 MB, avisos dentro de la app al administrador y propietarios activos, deduplicados por persona y cruce de umbral. Un intento de carga que exceda el saldo muestra el límite aunque aún no haya exactamente 200 MB almacenados. Explicar «cuota compartida de la aplicación», no «tu tablero alcanzó 200 MB». Mostrar a cada propietario el consumo de sus tableros sin enumerar contenido privado ajeno. No implica correo/push ni una cuota individual por tablero; límites por tablero requerirían decisión aparte. Rearme confirmado C-111/CF-16.1: bajar y nuevo cruce tras24h desde aviso previo; sin aviso periódico ni diferido por permanecer encima.

Contabilidad aprobada P22: sumar archivos activos, retenidos por recuperación y reservas de cargas en curso; comprobar cuota en servidor y reservar capacidad de forma atómica para cargas simultáneas. Reintentos no duplican consumo; liberar reservas fallidas con reconciliación de objetos huérfanos. La cuota global no da acceso de lectura al administrador a archivos privados ajenos; su facultad de limpieza requiere el contrato acotado de metadatos descrito arriba. Aun con archivos pequeños, definir límite de cantidad/ritmo de cargas para proteger metadatos y evitar que una persona monopolice la cuota.

**Verificado el 2026-10-23:** Supabase Free distingue 500 MB de base de datos por proyecto de 1 GB de Storage, cuya cuota se aplica a la organización. [Cuotas oficiales](https://supabase.com/docs/guides/platform/billing-on-supabase). Storage guarda archivos y usa Postgres para metadatos: los binarios no necesitan guardarse dentro de esos 500 MB, pero sus registros sí consumen base de datos. [Documentación de Storage](https://supabase.com/docs/guides/storage). No se inspeccionó consumo real del proyecto ni se configuró Storage. El plan también tiene límites de transferencia; separar cuotas no equivale a capacidad ilimitada.

Diseño técnico recomendado DT-0.1 §§7/10: reserva15min, carga mediada, reconciliación horaria y paquete v2/generaciones; límites de infraestructura y ejecución se verifican en G04/G06. Las unidades decimales, ciclo reservar → cargar → verificar → publicar, contabilidad, 20 archivos por tarea incluidos recuperables, cuota global y respuesta al máximo ya están aprobados. Los archivos retenidos por recuperación cuentan en la cuota hasta purgarse. Verificar implementación y margen operativo del plan antes de habilitar; no provisionar ni introducir otro servicio durante la spec. Pruebas candidatas: archivo en el límite y uno mayor, binario renombrado, dos cargas compitiendo por el último espacio, borrado sin liberar cuota prematuramente, recuperación sin doble conteo, limpieza sin borrar tarea ni revelar contenido a admin, avisos sin duplicación ni cuotas por tablero ficticias, enlace HTTPS clickeable y esquema ejecutable no activado.

### 14.4 Búsqueda y filtros

C-107 amplía C-78/P05: búsqueda unificada con sugerencias en múltiples campos y entidades, incluidos comentarios/tableros, con campo/tipo/contexto y selección explícita para navegar/filtrar. C-108 fija fuentes/destinos/ranking/filtros por tipo en CF-14.2: etiquetas como filtros, archivos/actividad excluidos, apertura precisa, lista deduplicada y relevancia de sugerencias separada de orden de tareas. Mantener todos los accesibles o alcance contextual autorizado. Filtros combinables: tablero, responsable (incluido sin asignar), completado, prioridad y vencimiento. Alcance visible, chips eliminables y Limpiar. Atajos Hoy/Vencidas/Próximos 7 días/Sin fecha reutilizan esta búsqueda: Próximos abarca desde mañana hasta hoy+7 inclusive según la zona de cada tablero; no se solapa con Hoy. En alcance global mostrar tablero/fecha de contexto. E01 agrega filtro de etiquetas; E02 permite guardar filtros y orden personales con nombre y recalcular fechas relativas, sin guardar copias de resultados. P14 abre el mismo buscador con Ctrl/Cmd+K fuera de campos de escritura; el botón visible sigue disponible.

Mostrar tablero y columna de origen y abrir la misma tarea, sin copiarla. Por defecto buscar pendientes e indicar claramente el filtro; permitir incluir completadas aunque su grupo esté colapsado. No mezclar la preferencia visual de una columna con permisos o eliminación de resultados. Respetar el orden elegido y explicar cero resultados/filtros activos. Ni resultados, sugerencias, conteos ni cachés deben revelar datos al perder acceso.

### 14.5 Bandeja de novedades

**Confirmado P15/E07:** bandeja personal con leídas/no leídas; leer no completa la tarea. Verificar acceso antes de marcar leída y abrir el detalle autorizado. Si el destino no existe, explicar sin restaurarlo ni filtrar datos. Acción explícita «Marcar visibles como leídas», con cantidad, sobre el conjunto actualmente cargado y autorizado al confirmar; no incluye páginas no cargadas ni avisos que lleguen después. Explicar resultados parciales. No archiva, pospone ni sustituye la actividad mínima E05.

**Eventos y destinatarios confirmados:** asignación al nuevo responsable; mención al mencionado; nuevo comentario al responsable y creador de la tarea; cambio de vencimiento hecho por otro al responsable. Confirmados C-78/P15: excluir al autor de la acción y deduplicar por evento/destinatario cuando coincidan motivos; nunca por igualdad del texto. C-111: creador de referencia de nuevas ocurrencias es creador de serie con acceso; original conserva creador y retirado no se reemplaza por owner. Todos los destinatarios están sujetos a permisos vigentes; no es una suscripción implícita de todo el tablero.

**Confirmado:** no avisar por cada paso tildado, movimiento de columna ni repetición automática. Propuestas de detalle: tampoco por reordenamiento; notificar asignación explícita al crear/editar, no cada materialización idéntica. Comentarios propios, reintentos de guardado y eventos duplicados no producen avisos duplicados. P15 confirma agrupar motivos por evento/destinatario y avisar una vez por cada destinatario nuevo mencionado al editar; quitar y reañadir la misma mención no vuelve a avisar. El contrato técnico conserva esa deduplicación ante reintentos.

**Privacidad confirmada:** búsqueda y novedades no pueden mostrar información de tableros a los que ya no se tiene acceso. Verificar acceso al consultar y al abrir la novedad; tras revocación no mostrar títulos ni extractos privados persistidos. Propuesta para tarea eliminada: referencia no disponible sin romper navegación. Retención de 90 días para leídas y no leídas ya aprobada C-79/C-83; paginación estable y contrato de ejecución por concretar. Sin correo, push ni Google Calendar implícitos.

### 14.6 Cierre de alcance, no más funciones por defecto

Ya resueltos: checklist incompleta al completar, herencia de pasos frente a conversación/archivos de cada ocurrencia, destinatarios básicos de novedades, recuperación durante 7 días y decisión de propiedad al retirar un dueño. Pendientes: detalles de restauración de 4.6, formatos/cuotas de adjuntos de 14.3, otros casos señalados y viabilidad técnica. Completar matriz de permisos/retención sin pedir al usuario decisiones sobre cada detalle de ingeniería.

Recorrido de validación candidato: crear «Investigar Brasil», asignarla a un amigo, añadir tres pasos, comentar y mencionarlo, adjuntar un `.txt` ficticio permitido y pegar un enlace a otro documento, encontrarla por filtro, abrir su novedad y completarla desde Mis tareas. Luego repetir el flujo con una serie semanal y retirar un miembro: comprobar qué se hereda, qué se conserva y qué deja de ser accesible. Todos los resultados deben convertirse en criterios aprobados antes de declarar cerrada la spec.

## 15. Cierre conversacional aceptado y precisiones vigentes

Esta sección integra lo aceptado en la última revisión y prevalece sobre etiquetas anteriores de «pendiente» para esas mismas reglas. Detalles complementarios solo escritos en CF no se aprueban por inferencia. La consolidación final debe eliminar marcadores obsoletos y actualizar toda la matriz de aceptación, sin borrar trazabilidad.

| Acuerdo | Regla aceptada | Detalle todavía candidato |
| --- | --- | --- |
| C-71 | Habilitación por correo Google desde administración; invitación revocable de un uso por 72 horas para ya habilitados. | Manejo de ya-miembro y revocación de enlaces en carreras CF-01. |
| C-72, sustituido por C-80 | Propietario debe elegir sucesor para salir. No ofrecer salida sin elección. Administrador puede reasignar después; sin otros miembros, borrado recuperable confirmado. | Sucesión automática por mayor antigüedad solo como protección ante fallo, nunca fallback de validación normal ni sustitución silenciosa del elegido. Registrar reparación y cerrar operaciones si no puede resolverse propiedad. |
| C-73 | Catálogo diario/semanal/mensual/anual con intervalos y ordinales; finales nunca/fecha/N; previsualización; zona por tablero inicialmente del creador; 29 febrero→28 y quinto día inexistente se omite. | Anclaje exacto de semana/inicio, conteo de exclusiones, permisos de cambio de zona y límites técnicos. |
| C-74 | Solo reabrir repetición vigente antes de que aparezca posterior; antiguas consultables. Restaurar serie conserva activa/detenida, actualiza calendario sin acumular atrasos ni reasignar retirados. | Excepciones, última ocurrencia finita restaurada, paginación/historial y restauración individual CF-07–09. |
| C-75 | Cumpleaños sin completado: todo el año si no se configura anticipación, actualizando próxima fecha al día siguiente; si se configura, visible D−X a D inclusive y luego oculto hasta próxima ventana, siempre localizable en Series. | Presentación compacta compartida y validación de configuración. |
| C-76/C-94/C-110 | Siete días desde borrado, vencimiento exacto visible; borrar columna con contenido requiere destino para tareas/series. Restaurar no devuelve accesos/invitaciones ni deshace ediciones. | Actores/cause/dependencias cerrados CF-12 y Matriz; faltan implementación y pruebas. |
| C-77, C-81 | Solo autor edita su comentario; propietario modera borrando, no reescribiendo; solo propietario restaura lo que moderó. Menciones de quien sale pasan a texto; reingresar no las revincula ni devuelve permisos/asignaciones o avisos retroactivos. | Desvinculación de contenido recuperable/caches y concesión explícita de membresía nueva. |
| C-78, ampliado C-107/C-108/C-112 | Búsqueda unificada con títulos/descripciones, comentarios, tableros y etiquetas-filtro; historial explícito independiente de completadas; próximos desde mañana hasta hoy+7 en zona del tablero; completadas inicialmente visibles; preferencias por usuario/contexto entre dispositivos; sin avisos propios/duplicados; nuevas menciones al editar avisan una vez. | C-104 fija desempates; quedan mecanismos técnicos. |
| C-79, C-82–83, precisado C-99 | Novedades caducan a 90 días sin borrar contenido. 20 adjuntos por tarea incluidos recuperables; máximo 24.000 bytes/archivo y 200.000.000 globales contando reservas/recuperables. | Ritmo de cargas, vencimiento de reservas y ejecución de purga/expiración. |

Criterios de aceptación nuevos para integrar a la matriz final: salida normal sin sucesor seleccionado bloqueada; sucesor inelegible devuelve conflicto en vez de elegir otro silenciosamente; simulación de inconsistencia repara propiedad con miembro elegible de mayor antigüedad sin dejar tablero activo huérfano; cambio administrativo no concede lectura de contenido; mención de exmiembro es texto sin destino; reingreso/restauración no reactivan enlaces históricos; intento de reabrir anterior explica restricción; calendario/cumpleaños coinciden con zona/ventana; avisos leídos y no leídos caducan sin borrar tareas; archivo número 21 se rechaza aunque algunos estén recuperables. No son pruebas ejecutadas.

**C-84–86, navegación acordada:** usar la estructura de Pantallas 0.2, sección 2, para la primera prueba: drawer global, búsqueda visible, menú contextual de tablero y detalle de tarea. La disposición se podrá revisar a partir de uso real, no se diseñan ahora múltiples variantes ni barra inferior adicional. Criterios NAV-01–10 complementan los de producto y todavía no se ejecutaron.

**C-87–91, flujo de tarea confirmado:** captura por título dentro de columna; campos con Guardar; checklist/comentario/archivo persistidos por su propia acción; cierre de borrador con Guardar y cerrar / Descartar / Seguir editando; error conserva texto; móvil ocupa pantalla disponible sin scroll horizontal. Descartar campos no revierte acciones independientes ya persistidas. Recargar/cerrar navegador no tiene garantía de restauración automática de borradores por esta aprobación. Pantallas UI-05 contiene los detalles.

**C-92, respaldo aceptado:** exportar contenido del tablero con nuevas funciones y adjuntos permitidos, no secretos/invitaciones/permisos reutilizables ni archivos de enlaces externos. Solo propietario importa, con previsualización y reemplazo explícito, sin mezclar tableros. Conservar lectura v1; responsables incompatibles sin asignar, no avisos de comentarios históricos ni pila de atrasos de series. Preservar previo 7 días contando capacidad; rechazar antes de borrar si no cabe. Fallo no deja tablero parcial. Formato y mecanismo seguro por diseñar; no se afirma atomicidad técnica ya implementada.

**C-93, entrada privada:** sección 4.0 sustituye landing creadora pública por acceso Google y habilitación administrativa previa; root autenticado/habilitado entra a Tableros. No registro de uso libre ni creación por URL, tampoco bypass por invitación o API. No implica que el administrador cree contraseñas Google.

Próxima revisión: consolidar matriz de permisos/pruebas, pendientes concretos de alta y verificar viabilidad técnica del contrato antes de implementar. Respaldo funcional, acceso privado, navegación, sucesión y edición básica no vuelven a plantearse como preguntas abiertas. No agregar funciones por asociación con otros productos ni declarar viabilidad técnica por aprobación funcional.

## 16. Incorporaciones desde Plane — aprobadas C-99

Aceptación: 24/10/2026; consolidación documental: 25/10/2026. **Las 26 P y las 7 E forman parte de esta spec y del mismo MVP objetivo.** Se conservan los identificadores del [anexo](./PROPUESTAS-DESDE-PLANE.md), que contiene el contraste con código/spec anteriores, las fuentes y un criterio de aceptación por fila. E ya no expresa una entrega posterior. El orden de construcción depende de contratos compartidos, sin retirar capacidades aprobadas por falta de prioridad inicial.

Se adaptan conceptos a OpenKanban y su base Next.js/Supabase; esta incorporación no decide un fork ni copia literal del código de Plane. Tablero sigue siendo la unidad de colaboración; no se agregan workspaces, jerarquías de proyectos o un proceso obligatorio. Las capacidades avanzadas son opcionales al usar una tarea sencilla.

### 16.1 Experiencia y funciones cotidianas

| ID | Contrato incorporado | Documento dueño |
| --- | --- | --- |
| P01 | Identidad única de tarea en tablero, Mis tareas, búsqueda, novedades y enlaces; columna, completado y programación independientes. Una vista nunca crea una copia. | Glosario; §6.3/§8/§11. |
| P02 | Alta por título con Enter o botón; perder foco no envía. Tras éxito queda lista para otra tarea en la misma columna. Fallo conserva título; resultado incierto se reconcilia antes de repetir. | Pantallas UI-04/UI-05; Estados y errores. |
| P03 | Un detalle adaptable: título/acciones, campos cotidianos, luego pasos/archivos/conversación. Bloques opcionales vacíos ofrecen añadir sin imponer configuración. Guardar campos y acciones independientes mantienen sus contratos. | Pantallas UI-05. |
| P04 | Tarjeta con título, casilla cuando corresponda, responsable, vencimiento, prioridad y progreso si existen; descripción secundaria, creación/autoría en detalle. Abrir, completar y mover son acciones distintas. | Pantallas UI-04/UI-05. |
| P05 | Búsqueda con alcance visible, chips y Limpiar; Hoy/Vencidas/Próximos 7 días/Sin fecha. Próximos desde mañana a hoy+7 inclusive por zona de tablero, con contexto en resultados globales. | §14.4; Cierre CF-14; Pantallas UI-10. |
| P06 | Orden/filtros/completadas personales por vista/tablero, sincronizados entre dispositivos, con defaults y reinicio explícitos. Scroll/columna activa son navegación; no cambian configuración común. | §6.4; Cierre CF-13; Pantallas UI-16. |
| P07 | Abrir y cerrar detalle preserva origen, filtros, columna y posición; Atrás respeta borradores. Entrada directa sin origen regresa al tablero autorizado. | Pantallas §2.6; Estados y errores. |
| P08 | Controles y tokens coherentes con negro/blanco/amarillo; nombres accesibles, foco, teclado, zoom 200 %, movimiento reducido y alternativas táctiles al arrastre/hover. | Pantallas reglas transversales y §4. |
| P09 | Recorridos verificables en 360/390 px y escritorio, teclado virtual, orientación y Atrás. Cambios remotos no roban foco ni cambian columna activa. | Pantallas; aceptación §16.4. |
| P10 | Distinguir sin tableros/columnas/tareas/resultados, carga, fallo local y acceso perdido. Cada estado ofrece una acción válida; error no equivale a vacío y recarga conserva contenido autorizado. | Pantallas; Estados y errores. |
| P11 | Copiar enlace privado estable a tarea u ocurrencia concreta; login recupera destino tras autorizar. No invita ni revela títulos públicamente; renombrar tablero no invalida. Ocurrencia antigua abre su historial autorizado, nunca la actual por sustitución. | Pantallas UI-05/§2.6; Matriz. |
| P12 | Español inicial en interfaz, errores y accesibilidad; textos/formatos centralizados. Fechas legibles, día estable y zona visible al programar. Sin traducir contenido del usuario ni agregar selector de idiomas. | §1; Pantallas transversal. |
| P13 | Estrella personal y sección Favoritos dentro de Tableros, sin nuevas entradas globales ni carpetas. Revocación retira nombre y acceso; no altera membresía ni favoritos ajenos. | Pantallas UI-03; Matriz; preferencias. |
| P14 | Ctrl/Cmd+K abre el buscador existente con alcance contextual; no intercepta escritura. Atajo documentado y botón visible disponible en móvil/escritorio. No paleta general de comandos. | Pantallas UI-10/§4. |
| P15 | Acceso antes de lectura/destino, referencia no disponible cuando corresponda y deduplicación por evento/destinatario. Mención nueva al editar avisa una vez; quitar/reponer no reavisa. | §14.5; Cierre CF-15; Pantallas UI-11. |

### 16.2 Garantías técnicas y de calidad

Los resultados son obligatorios; los mecanismos concretos se diseñan y verifican antes de construir. Ninguna fila exige por sí sola servicios nuevos, pagos o infraestructura de Plane.

| ID | Contrato incorporado | Documento dueño |
| --- | --- | --- |
| P16 | Autorización comprobable en servidor, consultas, canales, archivos y superficies secundarias. Casos con dos tableros, propietario/colaborador, admin no miembro, retirado/no habilitado e identificadores manipulados; ni URL, autoría ni asignación conceden membresía. | Matriz completa; spec 0001 seguridad/transición. |
| P17 | Mutaciones por acción y listas de campos permitidos; servidor deriva autor/rol, valida referencias y rechaza campos protegidos. Separar editar/completar/mover/invitar/transferir/borrar/restaurar. | §11; Matriz; Cierre H. |
| P18 | Precondición de versión y clave de operación para reconciliar reintentos; comentarios/pasos/archivos independientes de versión de campos. Estado pendiente visible y completado como valor deseado, no toggle. | Estados y errores; §11. |
| P19 | Trabajo pendiente durable ligado al cambio cuando corresponda; avisos/activaciones/purgas reintentables y deduplicados, con reconciliación tras inactividad. Sin prometer ejecución exactamente una vez. | §8/§9/§11; Cierre H. |
| P20 | Realtime señala cambios para consultar datos autorizados. Canales privados y revalidación al reconectar/cambiar cuenta; descartar respuestas antiguas, preservar borrador autorizado y retirar estado privado cuando se pierde acceso. | Estados y errores; Matriz; spec 0001. |
| P21 | Borrado registra causa, actor, plazo y dependencias. Restaurar/purgar coordinados con permisos/cuota; no reviven accesos, invitaciones ni hijos borrados por separado. | Matriz recuperación; Cierre CF-12. |
| P22 | Reservar → cargar → verificar → publicar; liberar reservas fallidas y reconciliar objetos. Cuota incluye activos/recuperables/reservas; validar permiso/contenido al confirmar. Límites decimales 24.000 bytes/archivo y 200.000.000 globales; 20 adjuntos por tarea incluidos recuperables. Definir residuo de enlaces temporales. | §14.3; Cierre CF-16/17; Matriz archivos. |
| P23 | Tarjetas cargan resúmenes; conversaciones/archivos/actividad bajo demanda. Listas globales y conversaciones con paginación estable y filtros autorizados en servidor. Exportación completa; carga parcial del tablero y reordenamiento se diseñan juntos. | §11; Cierre H; Pantallas. |
| P24 | Separar exportación portable de tablero de respaldo operativo de instancia (base, objetos y configuración). Formato versionado, lector v1, importación preparada/validada y publicación protegida; ensayo de restauración fuera de producción. | Cierre CF-19/20; spec 0001 transición. |
| P25 | Versiones/migraciones/dependencias y diagnósticos de errores, trabajos, purgas/cuotas sin cuerpos privados ni tokens; procedimientos de actualización/recuperación y origen/licencia de código reutilizado. Sin telemetría externa ni pantalla de métricas por defecto. | Cierre H; documentación de operación posterior. |
| P26 | Trazar cada regla a escenario y evidencia; observar capturar/encontrar/completar/coordinar/retomar con personas del piloto. Registrar fricción sin analítica externa ni puntajes. Separar facilidad de uso de pruebas automáticas. | §1/§10/§13/§16.4; matriz final de aceptación. |

### 16.3 Las siete extensiones también son alcance actual

| ID | Contrato incorporado | Documento dueño |
| --- | --- | --- |
| E01 | Etiquetas de tareas/cumpleaños y plantilla de serie. C-100: facultades y límites 40/100/10, paleta y OR. C-101: recuperación siete días solo propietario actual, herencia de activas al generar, copia de activas del origen y respaldo de catálogo activo completo/asociaciones. C-102: cupos solo activos, resolver nombre/cupo y asociaciones por preview sin omisiones silenciosas. | Cierre CF-22.1–2; Pantallas; Matriz. |
| E02 | Vistas personales con texto/alcance/completadas/filtros/orden; global dinámico, tablero específico y asignación propia en Mis tareas. C-100: edición explícita y límites 50/60. C-101: referencia explícita inválida bloquea hasta revisar/confirmar, recuperación siete días solo usuario y conflicto sin sobrescritura. | Cierre CF-22.1–2; Pantallas; Matriz. |
| E03 | Tema personal claro/oscuro/sistema, conservando marca, contraste y estados; cambio sin recarga ni pérdida del editor. Sin editor de colores ni tema común del tablero. | Cierre CF-23; Pantallas UI-16 y reglas visuales. |
| E04 | Duplicar tarea en el mismo tablero: nueva identidad pendiente, título/descripción/prioridad, checklist sin marcar y etiquetas activas del origen (C-101; si es ocurrencia, no de plantilla). No copiar responsable, fecha, serie, comentarios, archivos ni membresías. Si origen es ocurrencia, explicar que la copia es puntual. | Cierre CF-24; Pantallas UI-05; Matriz; Estados y errores. |
| E05 | Actividad de categorías E05 con actor/fecha-hora y valores anterior/nuevo; recientes primero/progresiva. C-105: 180 días por evento, ocultar con tarea y purgar dependiente; atribución histórica/Sistema/Importada y respaldo de vigentes sin avisos retroactivos. Sin versiones de textos ni edición individual. | Cierre CF-25.1; Pantallas; Matriz; Estados. |
| E06 | PWA online opcional. C-109: matriz inicial AndroidChrome/iPhoneSafari/Chrome–Edge escritorio/SafariMac, Firefoxweb; Instalar en cuenta directo/manual, actualización elegida sin perder borrador. Probar versiones/dispositivos; mismo login/enlaces, sin push/cola offline/app nativa. | Cierre CF-26.1; Pantallas; Estados. |
| E07 | C-109: botón con cantidad sin leer cargada, una pulsación sin diálogo extra y conjunto fijo al pulsar. Resumir marcadas/ya leídas/no disponibles/falladas; reintentar solo falladas autorizadas del original, reconciliar incertidumbre. Sin nuevas/páginas restantes/archivar/posponer. | Cierre CF-27.1; Matriz; Estados. |

### 16.4 Trazabilidad y condición de aceptación

Cada P/E tiene su criterio en la tabla «Destino y aceptación» del [anexo](./PROPUESTAS-DESDE-PLANE.md). Sus escenarios se desarrollan en Pantallas (NAV/UI-PL), Estados y errores (ERR-PL), Matriz (PERM) y Cierre (TEC), sin sustituir los criterios previos de calendario, admisión y recuperación. Estado de todos los escenarios nuevos: **especificados, no ejecutados**.

La matriz de ejecución futura deberá vincular ID → contrato dueño → escenario → evidencia/resultado. Se verifica tanto recorrido normal como permiso perdido, conflicto, fallo e incertidumbre. El fixture de 500 tareas de P23 y los anchos de P09 son objetivos de evaluación, no capacidad certificada ni límites de uso.

La entrega debe demostrar los cinco recorridos P26 en computadora y móvil, con todas las P/E incluidas. Un bloqueo de acceso/privacidad, pérdida de datos o calendario incorrecto impide declarar listo el MVP. Tampoco se declara completa una extensión por tener solo botones, tablas de spec o un manifest. La aprobación de alcance no reemplaza la autorización de implementar.

### 16.5 Preparación técnica dentro del alcance aprobado

C-112 cierra los dos huecos funcionales detectados en la auditoría. Esta tabla conserva las verificaciones técnicas, no una nueva entrevista de alcance. El [diseño DT-0.1](./DISENO-TECNICO-MVP-1.0.md) fija interfaces, mecanismos y gates G01–G08; sus parámetros son decisiones de ingeniería propuestas y sus pruebas todavía no se ejecutaron.

| Área | Precisión todavía necesaria |
| --- | --- |
| E01 etiquetas | C-100–102 cierran contrato funcional de recuperación/herencia/copia/respaldo. C-103 cierra unicidad; resta normalización técnica, medición de caracteres y validación/mapeo de importación. |
| E02 vistas | C-100–102 cierran consulta, gestión, cupos activos, recuperación/revisión y conflicto. C-103 cierra unicidad; resta medición/normalización técnica y mecanismo de concurrencia. |
| E03/P06 preferencias | C-104/C-106 cierran tema, defaults/contextos, orden, conflictos y reinicio. Faltan mecanismos/pruebas; contrato CF-13.1–2. |
| E04 copia | C-104/C-105 cierran título/destino/orígenes, confirmación/resultado y cambio de origen. Faltan mecanismos/pruebas. Borrador resuelto antes por C-95, sin guardar sobre histórica no editable. |
| E05 actividad | C-105 cierra datos/orden, 180 días, borrado/recuperación/purga, atribución y respaldo; faltan mecanismos/pruebas. No usar para exponer textos eliminados ni agregar categorías. |
| E06 PWA | C-109 fija matriz inicial, descubrimiento/actualización. Faltan mecanismos/pruebas de instalación/login/enlaces, sesión/caché privada, cambio cuenta y compatibilidad por versión. |
| E07 lote | C-109 fija UX una pulsación y categorías/reintento del lote original. Faltan respuesta por ID, reconciliación/concurrencia y pruebas. No ampliar conjunto ni tratar ya leídas como fallos. |
| P17–P25 | Versiones/claves y retención técnica, ejecución durable proporcional al hosting, reconciliación, duración de enlaces/reservas, consultas/paginación/orden, formatos de respaldo y recuperación ensayable. Resultados aceptados y mecanismos recomendados en DT-0.1; falta comprobarlos en G01–G08. |
| Dominio anterior | C-110–112 cierran calendario/conversión, restauración, historial de búsqueda y reprogramación. Conservar contratos previos y probar DT-0.1, sin reabrir decisiones por marcadores históricos. |

Registro 0.25: se incorpora C-99 completo, con 33 contratos y criterios trazables, y se corrigen marcas anteriores incompatibles. Solo documentación local; ninguna de estas capacidades nuevas se declara implementada.

### C-102 — Búsquedas y filtros

**Q18 corregida · Coincidencia textual:** búsquedas y filtros ignoran acentos y la diferencia ñ/n: «reunión»/«reunion» y «Peña»/«Pena» encuentran lo mismo. Conservar escritura original al mostrar/guardar. Es comparación textual, no fusión de identidades: seleccionar una etiqueta sigue filtrando por esa etiqueta y su tablero. No confiere permisos; C-107 amplía los campos buscables. C-103 confirma esa misma equivalencia para unicidad de nombres de etiquetas/vistas dentro de sus ámbitos.

### C-103 — Unicidad de etiquetas y vistas

**C-103 / Q18b:** al crear, renombrar o restaurar etiquetas y vistas, la unicidad ignora mayúsculas, espacios sobrantes, acentos y ñ/n. «Reunión»/«Reunion» y «Peña»/«Pena» colisionan dentro del mismo tablero para etiquetas, o del mismo usuario/contexto para vistas. Conservar escritura original; informar coincidencia y mostrar la existente solo si está autorizada. No fusionar automáticamente ni cambiar identidades/asociaciones. Nombres de otros tableros, usuarios o contextos no provocan colisión ni se revelan.

Criterio C103-AC18b en Cierre CF-22.4, todavía no ejecutado.

### C-110 — Calendario y recuperación

- **Q49 · Inicio/anclaje:** fecha de inicio explícita, proponiendo fecha existente de tarea. Semanas lunes–domingo ancladas a semana del inicio; no generar fechas anteriores. Preview distingue tarjeta actual y próximas. Inicio miércoles: lunes/miércoles cada dos semanas incluye ese miércoles y siguiente semana habilitada, no la intermedia.
- **Q50 · Final/conteo:** fecha final inclusiva. N cuenta fechas efectivas del calendario, no completados; exclusión explícita consume su fecha y no extiende serie. Mes sin quinto lunes no genera fecha que contar. Preview identifica fechas contadas; 1/4/7 con exclusión del 4 no agrega el 10.
- **Q51 · Excepción:** nueva fecha límite actual debe ser anterior a aparición siguiente. Rechazar fecha igual o posterior, explicar máximo y conservar borrador; no fusionar ni cambiar calendario posterior. Si próxima aparece sábado14, máximo viernes13.
- **Q52 · Recuperación finita:** serie cuyo final pasó reconcilia como máximo última ocurrencia válida, aunque vencida y aún no materializada, sin pendientes intermedios ni extender final. 1/3/5, borrada2 y recuperada6: historial y una vigente del5. Si última fecha excluida no crear sustituta. No regenerar una ocurrencia eliminada/purgada independientemente al restaurar su padre. Detenida sigue detenida.
- **Q53 · Recuperación individual:** deshacer solo exclusión causada por borrar esa misma ocurrencia; conservar otras exclusiones y no reactivar serie. Si hay posterior activada, recuperar como histórica. Exigir padres autorizados recuperados; recuperar serie no revive hijos borrados antes por separado.
- **Q54 · Actores:** propietario o colaborador actual con permiso de edición recupera pasos, series y columnas ordinariamente borrados dentro de siete días, como tareas; no exclusividad del que borró. Moderación/limpieza administrativa conservan restricciones. Recuperar columna no revierte traslados.

Criterios C110-AC49–54 en Cierre, todavía sin ejecutar. Conservar acuerdos C-98 sobre exclusiones compatibles al cambiar regla; no son un pendiente nuevo.

### C-111 — Conversión, avisos y autovínculos

- **Q55 · Conversión:** conservar misma tarjeta como primera ocurrencia, contada en N; con N=3 quedan dos fechas adicionales. Preview distingue actual/próximas. Si vencimiento no encaja, elegir y confirmar primera fecha compatible; no cambiarlo silenciosamente ni duplicar tarjeta.
- **Q56 · Editar cantidad:** mostrar «N próximas repeticiones», fuera actual/pasado. Elegir3 próximas programa tres futuras y muestra nuevo final. Cambiar solo título/responsable/columna conserva restante; no reinicia contador.
- **Q57 · Creador de referencia:** nuevas ocurrencias automáticas usan creador de serie mientras conserve acceso; tarjeta original conserva creador original. Comentario avisa a creador/responsable elegibles, sin autoavisos/duplicados. Si creador sale, no sustituirlo por propietario.
- **Q58 · Rearme:** avisar por nuevo cruce de umbral solo después de haber bajado de él y transcurrido 24 h desde aviso anterior, por persona/umbral. Seguir encima al día siguiente no crea recordatorio ni aviso diferido. Carga bloqueada siempre informa inmediatamente.
- **Q59 · Ubicaciones:** enlaces clickeables al visualizar descripción/comentarios/pasos. Título compacto sigue abriendo detalle; URL de título abrible allí mediante control distinguible de editar.
- **Q60 · Detección/apertura:** HTTP/HTTPS y www.; www. abre HTTPS. Dominio suelto queda texto, excluir puntuación exterior y conservar original. Apertura explícita externa segura sin HTML/esquemas activos/locales, descargas ni previews automáticas.

Criterios C111-AC55–60 en Cierre, todavía sin ejecutar. Mantener C-110/C-98; atribución importada no da identidad autenticada por nombre.

## C-112 — Historial de búsqueda y nueva programación

Q61–62 aprobadas: contratos vigentes CF-14.3 y CF-08.1 de Cierre. Incluir historial es opción explícita desactivada, independiente de completadas, guardada en vistas/preferencias; encuentra reemplazadas y comentarios autorizados sin reabrir. Volver a programar tras detener crea nueva serie con misma tarjeta inicial, anterior detenida conserva historia; borrado/restauración anterior no afecta nueva. Estos acuerdos prevalecen sobre marcas históricas de pendiente.
