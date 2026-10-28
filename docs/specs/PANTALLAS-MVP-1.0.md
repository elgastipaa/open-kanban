# Pantallas e interacciones — MVP 1.0

Actualización documental C-100–112 (27/10/2026): calendario CF-04/07/09, avisos/cuota/enlaces CF-15/16/18, preferencias/búsqueda CF-13–14 y ampliaciones CF-22–27. Complementa revisión base; todas las P/E se conservan.

Consolidación vigente27/10/2026: C-112 resuelve los dos huecos funcionales de auditoría; [DT-0.1](./DISENO-TECNICO-MVP-1.0.md) fija diseño recomendado y verificaciones G01–G08 pendientes. Los registros de revisiones anteriores son antecedentes, no nuevas preguntas de producto.

Estado: **UX 0.5: acuerdos C-01–112, incluidas P01–P26 y E01–E07 de la revisión de Plane, incorporados al alcance del MVP. Contratos restantes identificados; solo documentación, no implementación**.

C-99 aceptado el 24 de octubre de 2026; consolidación documental del 25 de octubre de 2026.

Basada en MVP 1.0 y acuerdos C-01–112. C-99 acepta las 26 propuestas principales y las 7 extensiones de [Propuestas desde Plane](./PROPUESTAS-DESDE-PLANE.md); las extensiones forman parte del MVP, ya no del backlog. Navegación elegida: panel lateral desde izquierda, búsqueda visible, acciones del tablero en menú contextual y acciones de tarea en detalle, sin barra inferior inicial. Confirmados captura rápida, Guardar, acciones independientes, cierre con cambios y detalle móvil; acceso inicial privado reemplaza creador público. Controles y destinos se rigen por la [matriz de permisos](./MATRIZ-PERMISOS-MVP-1.0.md); ocultar controles no sustituye autorización del servidor. El español es el idioma inicial aprobado, incluidos mensajes y nombres accesibles; el contenido escrito por usuarios no se traduce. Los IDs UI no fijan URLs ni librerías. Aceptar funciones no resuelve por inferencia contratos aún abiertos ni autoriza implementación.

## 1. Base existente y criterio de conservación

Inspección local de código, no prueba visual de la instancia en este turno:

- `src/components/board/board-toolbar.tsx`: cabecera con título derivado del slug, conexión/presencia e importación/exportación/borrado.
- `task-card.tsx`: tarjeta con título, descripción breve, prioridad, fecha de creación, arrastre y apertura de edición.
- `task-modal.tsx`: modal con título, descripción, prioridades low/medium/high/urgent, fecha de creación y guardar/cancelar/borrar. Actualmente solicita guardar y cierra; el MVP deberá esperar confirmación antes de presentar éxito conforme al acuerdo de guardado veraz.
- `mobile-board.tsx`: una columna activa, navegación por gestos/botones y movimiento de tarjetas con controles. `src/lib/constants.ts` define atajos existentes.

Conservar diseño base, jerarquía y controles útiles. Extender autorización y datos donde el MVP lo exige. No sustituir columnas por estados universales, ni introducir calendario dominante, métricas, chat global o nuevas pantallas de marketing. Los controles de presencia requieren privacidad, no conservar canales públicos por continuidad visual.

## 2. Navegación acordada para la primera prueba

```text
Acceso Google → verificación de habilitación → Tableros
                                             ├─ Tablero → Detalle de tarea → Programar
                                             │          ├─ Miembros / salida
                                             │          └─ Ajustes / recuperación / archivos
                                             ├─ Mis tareas → mismo detalle de tarea
                                             ├─ Series → editor / historial de ocurrencias
                                             ├─ Novedades → tarea o destino autorizado
                                             ├─ Búsqueda → mismo detalle / tablero
                                             └─ Cuenta → preferencias / cerrar sesión
Administrador habilitado: acceso adicional a Administración
```

La entrada sigue siendo Tableros. Navegación principal por botón ☰ que abre panel vertical desde la izquierda. No sidebar permanente ni barra inferior en esta primera prueba, tampoco accesos duplicados a todas las secciones en cabecera. Búsqueda visible fuera del panel; Novedades dentro del panel con contador de no leídas. Las acciones de cada tablero quedan en su menú ⋯ y las de tarea en detalle. El calendario discreto sigue siendo apoyo opcional, no otro destino principal añadido.

### 2.1 Estructura del panel lateral

Orden de destinos acordado:

1. Tableros.
2. Mis tareas.
3. Series.
4. Novedades, con contador de no leídas autorizadas.

Separador y bloque inferior: Cuenta y preferencias; Administración solo para el administrador habilitado; Cerrar sesión como acción separada, no como destino. En la cabecera del panel: identidad compacta de la app/cuenta y botón Cerrar menú. No exponer email o datos personales ajenos.

Icono y texto en cada opción; sección actual resaltada y anunciada semánticamente. Dentro de un tablero se marca Tableros como sección principal; abrir tarea desde Mis tareas o Novedades conserva esa sección de origen. No insertar listas de todos los tableros dentro del panel ni submenús profundos en esta versión. La cuenta no tiene tres entradas distintas para lo mismo.

### 2.2 Cabecera por contexto

| Contexto | Izquierda / título | Acciones visibles a la derecha | Acciones dentro del contenido |
| --- | --- | --- | --- |
| Tableros | ☰ y «Tableros» | Buscar; ⋯ de lista solo si hay acciones como recuperar tableros | Crear tablero junto al encabezado del listado, no dentro del drawer. |
| Tablero abierto | ☰ y nombre del tablero | Buscar y ⋯ del tablero | Acceso compacto volver a Tableros; conexión/guardado en línea secundaria; controles de columnas y captura de tareas donde se usan. |
| Mis tareas | ☰ y «Mis tareas» | Buscar | Orden y filtros propios, grupo de completadas. |
| Series | ☰ y «Series» | Buscar general, si se mantiene cabecera común | Filtros de tablero/estado; cada fila abre editor/historial. |
| Novedades | ☰ y «Novedades» | Buscar general, si se mantiene cabecera común | Todas/no leídas y leyenda de 90 días. |
| Cuenta / Administración | ☰ y nombre de sección | Sin menú de un tablero anterior | Acciones específicas por bloque y rol. |
| Detalle de tarea / Programar / diálogo | Cerrar o Volver, con nombre de tarea/contexto | Acciones locales de ese editor | No duplicar la hamburguesa dentro de un modal ni abrir otro drawer sobre un diálogo. |

Las filas de configuración/búsqueda general son detalle de layout de la propuesta, no nuevas capacidades. Buscar permanece accesible al trabajar con tareas, sin obligar a abrir el panel. No agregar campana extra en la cabecera inicial: el indicador de Novedades reside en el panel; se propone punto discreto en ☰ cuando hay no leídas, sin revelar títulos. Si se adopta, solo indica atención, no cuenta total adicional ni una notificación push.

### 2.3 Menú contextual del tablero

El botón ⋯ lleva nombre accesible «Opciones del tablero [nombre]». Orden propuesto por grupos, con separadores:

| Grupo | Opción | Destino / alcance | Visibilidad y permiso |
| --- | --- | --- | --- |
| Colaboración | Miembros e invitaciones | UI-12, del tablero actual. | Miembros ven lista; solo propietario administra invitaciones/retiradas. |
| Contenido | Archivos y almacenamiento | UI-13, archivos de este tablero y cuota global explicada. | Vista/acciones según permiso; propietario dispone de limpieza. No revelar archivos de otros tableros. |
| Contenido | Recuperación | UI-14, contenido eliminado de este tablero. | Solo objetos/acciones que el usuario puede recuperar. |
| Configuración | Configuración del tablero | UI-13, propiedades compartidas como zona horaria. | Propietario; no confundir con preferencias personales. |
| Respaldo | Importar / Exportar | UI-17. | Importar solo propietario; exportar miembros autorizados. Contrato de formato todavía pendiente. |
| Salida | Salir del tablero | UI-12, confirmación o elección obligatoria de sucesor. | Miembros; propietario no puede saltar selección. |
| Destructivo | Eliminar tablero | Confirmación de contenido y recuperación 7 días. | Solo propietario. Separado y claramente rotulado. |

En móvil el menú puede presentarse como hoja vertical de acciones con scroll y cierre, pero no funciona como segunda navegación global. No ocultar «Agregar tarea», casilla de completado o captura rápida dentro de ⋯. Acciones no permitidas no se muestran como utilizables; permiso se revalida al ejecutar.

### 2.4 Distribución de controles restantes

| Componente / opción | Ubicación inicial | Regla de interacción |
| --- | --- | --- |
| Buscar | Icono etiquetado en cabecera, panel reutilizable; Ctrl/Cmd+K como acceso adicional. | Desde tablero comienza con alcance de ese tablero visible y permite cambiar a todos los accesibles; desde vista global comienza global. El atajo no actúa mientras se escribe. |
| Filtros y orden | Línea compacta encima de la lista/tablero, no drawer. | Mostrar alcance, chips eliminables y Limpiar; nunca cambiar orden compartido por preferencia personal. Vistas personales guardadas se gestionan desde búsqueda/Mis tareas, sin nuevo destino global. |
| Visibilidad de completadas | Opciones personales de vista junto a filtros. | Grupo «Completadas (N)» además tiene su propio control de colapsado en cada columna/Mis tareas. No usar Configuración compartida. |
| Columnas | Cabecera y controles existentes de cada columna. | Renombrar, ordenar, eliminar con resolución de contenido; Agregar columna junto al tablero. |
| Agregar tarea | Entrada existente dentro de cada columna; en móvil en la columna activa. | Título suficiente; Enter o botón explícito crean, perder foco no envía. Tras confirmar, captura lista para la siguiente en esa columna. No abrir reloj ni asignar responsable automáticamente. |
| Abrir tarea | Contenido de tarjeta/fila, separado de completar y arrastrar. | UI-05 conserva origen y vuelve al mismo contexto. |
| Responsable / prioridad / descripción / etiquetas | Detalle UI-05. | Reutilizar esquema de edición; etiquetas opcionales del tablero, sin saturar tarjeta con selectores. Facultades según C-100 y matriz B-24/B-24b. |
| Programación | Botón reloj en detalle; resumen discreto en tarjeta recurrente. | UI-06 muestra actual frente a serie y fechas de aparición/vencimiento. |
| Checklist / adjuntos / comentarios | Bloques dentro de UI-05. | Sin destinos globales nuevos. Comentarios y archivos no se copian automáticamente a próximas. |
| Copiar enlace / duplicar tarea puntual | Acciones secundarias del detalle UI-05. | El enlace refiere a la misma tarea; duplicar crea otra con las exclusiones de E04 y no comparte permisos. |
| Actividad mínima | Bloque separado dentro de UI-05. | Actor/fecha de cambios de responsable, fecha, columna, completado y recuperación; no reemplaza comentarios ni Novedades. |
| Historial de serie | Fila/detalle de serie UI-09. | No hace falta desocultar completadas para encontrarlo. |
| Crear cumpleaños | Opción secundaria de alta del tablero/columna. | UI-07; ubicación exacta aún candidata y no reemplaza Agregar tarea. |
| Recuperar tablero eliminado | Menú del listado Tableros; caso sin dueño también Administración. | Hace falta acceso aunque el tablero ya no se pueda abrir. No depender exclusivamente del menú del tablero eliminado. |
| Gestión global de capacidad | Administración. | Solo admin; propietarios gestionan su alcance desde Archivos del tablero. |
| Preferencias / cerrar sesión | Bloque inferior del drawer y UI-16 según corresponda. | Cerrar sesión no equivale a salir de tableros ni a transferir propiedad. |

El acceso global Series no aplica silenciosamente el último tablero abierto: muestra su filtro actual. Si se añade un acceso contextual a Series, debe rotular el alcance y reutilizar UI-09, no crear otra lista. La búsqueda no sustituye el campo de comentario ni inicia navegación por pegar texto.

### 2.5 Apertura, cierre y adaptación

Panel cerrado al entrar y tras elegir destino. Se superpone desde la izquierda con fondo atenuado, bloqueando interacción accidental con tablero; no reduce ni desplaza el ancho de columnas. Igual patrón colapsado en escritorio para esta primera prueba; no modo fijado ni estado persistente abierto. Ancho suficiente para etiquetas, limitado a la pantalla y dejando área de fondo para cierre cuando el tamaño lo permite. El menú puede hacer scroll; pie y cierre nunca quedan inaccesibles en pantallas bajas o con texto ampliado.

Cierra con botón de cierre, toque/clic fuera o Escape. Elegir la sección actual solo cierra, sin recargar/reordenar ni perder posición. No exigir gestos de apertura/cierre ni capturar el swipe del tablero para abrir el panel; respetar navegación del navegador. No animación obligatoria si se solicita movimiento reducido.

Tocar menú no pierde borradores. Si una navegación pretende abandonar edición sin guardar, resolver Guardar/seguir editando/descartar según el contrato aprobado del editor, sin cambiar de sección primero. El drawer no permite eludir confirmaciones de salida de propietario ni controles de permiso.

### 2.6 Atrás, destino y conservación de contexto

Al navegar explícitamente a otra sección, cerrar panel y llevar foco al encabezado del destino. Al cerrar sin navegar, devolver foco a ☰. Cerrar búsqueda/detalle vuelve al origen con filtros, posición y columna activa. Volver desde Programar retorna al detalle o fila de Series que lo abrió; no siempre a Tableros.

El botón Atrás del navegador/móvil debe cerrar primero la capa superior abierta (menú/panel/editor según el caso) sin abandonar inesperadamente la tarea; cualquier borrador protegido mantiene su confirmación. Navegación Atrás/Adelante no repite escrituras ni duplica invitaciones. La representación técnica en historial/rutas se diseñará y probará; estas reglas no fijan implementación.

Un acceso directo a una tarea necesita sesión y autorización. Si no hay origen navegable, cerrar detalle lleva al tablero autorizado, y si ya no se tiene acceso, a Tableros con mensaje genérico. Restaurar contexto no restaura permisos: revalidar al volver y limpiar datos privados al detectar revocación.

**C-99 / P07 y P11:** Copiar enlace refiere a una identidad estable de tarea u ocurrencia concreta, y renombrar el tablero no lo invalida. Login conserva el destino pendiente y lo abre solo después de validar acceso; el enlace no invita, habilita ni concede membresía. Ninguna previsualización pública revela el título. El regreso queda definido por el origen:

| Origen | Al cerrar detalle |
| --- | --- |
| Tablero | Mismo tablero, columna activa, filtros y posición autorizados. |
| Mis tareas | Mismos filtros, orden y posición; la tarea puede dejar de cumplirlos tras editarse. |
| Búsqueda o vista personal guardada | Misma consulta/alcance, filtros y posición, con resultados actualizados. |
| Novedad | Misma bandeja y filtro de lectura; leer no completa la tarea. |
| Enlace directo sin origen | Tablero autorizado; si no está disponible, Tableros con mensaje genérico. |

Una misma tarea conserva identidad y datos en todos estos recorridos. Columna, completado y programación son independientes. Volver no crea copias ni restaura permisos caducados.

### 2.7 Accesibilidad y seguridad del contenedor

☰ tiene nombre «Abrir menú», estado expandido y relación con panel. Panel modal tiene nombre de navegación, foco inicial consistente, recorrido de teclado contenido y fondo no interactivo. Cierre visible, retorno de foco definido y destinos con texto/icono; estado activo no depende solo del color. No atajos globales mientras se escribe en un campo.

**C-99 / P08 y P14:** estas reglas se extienden a tarjetas, detalle, filtros y menús: controles consistentes de foco, carga, error y acciones destructivas; nombres accesibles, alternativa a arrastrar y acciones táctiles sin hover obligatorio. Ctrl/Cmd+K abre la búsqueda existente con su alcance contextual y figura en la ayuda de atajos; no es una paleta adicional de comandos. No actúa desde input, textarea o contenido editable. Se conserva identidad negro/blanco/amarillo, adaptada también a los temas claro/oscuro/sistema de E03.

En drawer y menús se muestran solo destinos y acciones del rol actual. Ocultar Administración no sustituye autorización de URL/API. Cambio de cuenta vacía estado anterior; revocación mientras hay un menú abierto actualiza opciones y no permite ejecutar acciones con permisos viejos. Contadores de novedades no incorporan objetos ya inaccesibles.

### 2.8 Criterios de navegación para la primera prueba

| ID | Caso | Resultado esperado |
| --- | --- | --- |
| NAV-01 | Abrir/cerrar menú en móvil/escritorio. | Panel superpuesto sin reacomodar columnas; cierre por botón/fuera/Escape y foco correcto. |
| NAV-02 | Cambiar Tableros → Mis tareas → Series → Novedades. | Destino y sección activa coherentes; sin barra inferior ni recarga con pérdida de contexto accidental. |
| NAV-03 | Buscar desde tablero. | Alcance visible y modificable; cerrar vuelve a columna/posición de origen. |
| NAV-04 | Colaborador frente a propietario/admin. | Menús no ofrecen acciones ajenas; acceso directo también se deniega. |
| NAV-05 | Salir del tablero frente a cerrar sesión. | Acciones inequívocas; propietario no sale sin sucesor cuando hay miembros elegibles. |
| NAV-06 | Acceder a recuperación de tablero borrado. | Se puede desde listado/admin autorizado, sin necesitar abrir tablero eliminado. |
| NAV-07 | Teclado, zoom, pantalla baja y movimiento reducido. | Etiquetas/cierre alcanzables, foco contenido y no animación obligatoria. |
| NAV-08 | Abrir menú durante navegación móvil por columnas. | Botón funciona; swipe de columnas no abre menú por accidente. |
| NAV-09 | Atrás con menú, búsqueda o detalle abierto. | Cierra capa esperada; no duplica mutaciones ni pierde borrador silenciosamente. |
| NAV-10 | Cambio remoto de permisos con menú abierto. | Opciones y datos se reconcilian sin éxito falso ni contenido de otra cuenta. |
| NAV-PL01 | Abrir tarea desde tablero, Mis tareas, búsqueda, vista guardada y novedad; volver. | Se conserva el origen según §2.6; misma identidad, filtros/posición coherentes y ningún envío repetido. |
| NAV-PL02 | Ctrl/Cmd+K desde tablero y desde campo de texto. | En tablero abre búsqueda con alcance visible; al escribir no intercepta el atajo ni descarta texto. Botón visible sigue disponible. |
| NAV-PL03 | Copiar enlace, renombrar tablero y abrir con/sin acceso. | Identidad estable; login retoma destino autorizado. Otra cuenta no obtiene título, preview privado ni membresía por el enlace. |

No son pruebas ejecutadas. Medir en la primera prueba si se encuentran Mis tareas/Series/Novedades, si se distingue menú global de ⋯, y si las funciones frecuentes requieren navegación incómoda. Solo necesidades observadas justificarán revisar el drawer o evaluar barra inferior; no anticipar ambas variantes.

### 2.9 Primera entrada — C-96

Recorrido base aprobado: Google y habilitación; si no tiene tableros, ofrecer «Crear mi primer tablero» sin generar contenido. Crear pide nombre, luego permite nombrar primera columna sin imponer estados. Primera tarea solo requiere título; detalles opcionales. Compartir desde menú del propietario cuando quiera; responsable actual puede verla en Mis tareas, vinculada al origen. Sin tutorial obligatorio, solo indicaciones contextuales.

El usuario agrega expresamente la posibilidad de llegar con una invitación pendiente: **no exigir crear tablero propio antes de incorporarse a uno compartido**. Diferenciar membresía existente (ya aparece en Tableros) de invitación aún no aceptada (todavía no concede acceso).

Dos formas de llegada a resolver sin confundirlas:

- Enlace de invitación abierto: conservar destino durante login, verificar habilitación y vigencia, luego ofrecer aceptar/cancelar. Aceptar incorpora y abre el tablero; ya miembro abre sin incorporación duplicada. No habilitado no consume enlace ni obtiene contenido. Vencido/revocado no crea un tablero sustituto.
- Entrada por raíz sin enlace: mostrar invitaciones directas pendientes de la identidad actual. Un enlace genérico no permite saber a quién se lo enviaron y no se lista como pendiente para todos los habilitados.

**PE-01 aprobada en C-97: invitación directa y genérica coexisten.** Directa a una persona ya habilitada por correo exacto; aparece en «Invitaciones pendientes» de Tableros aunque ya tenga otros. Aceptar incorpora; rechazar descarta esa invitación sin bloquear invitaciones nuevas. No correo automático ni servicios nuevos. Destinatario por identidad habilitada verificada, no alias/display name. Enlace genérico se mantiene como alternativa. No mostrar tareas antes de membresía; previsualización mínima según el cierre C-98 de §2.10.

Casos de aceptación a futuro: primera entrada por enlace sin tablero propio; entrada ordinaria con membresía previa; invitación vencida durante login; cuenta no habilitada; aceptar con otra cuenta; incorporación duplicada; pendientes directas visibles solo al destinatario. No son pruebas ejecutadas.

### 2.10 Dos modalidades de invitación — C-97

| Modalidad | Creación por propietario | Recepción y aceptación |
| --- | --- | --- |
| Directa | Indicar correo exacto de persona habilitada, sin mostrar directorio global de usuarios. | Solo destinatario ve pendiente y puede aceptar/rechazar. Conocer o reenviar su identificador/enlace no permite a otra cuenta consumirla. |
| Genérica | Generar y copiar enlace sin destinatario fijo. | Una persona habilitada que abra el enlace puede aceptarlo. No aparece en la lista de pendientes de todas las cuentas. |

Ambas incorporan como colaborador, no como propietario; requieren login y habilitación global vigente. Se conservan las condiciones previamente acordadas: 72 horas, revocables por propietario y un uso. «Genérica» significa sin destinatario, no acceso público ni enlace multiuso. El usuario debe aceptar: abrir enlace o iniciar sesión no incorpora automáticamente. El propietario ve ambas modalidades y su estado desde Miembros e invitaciones.

Si ya es miembro, abrir el tablero sin duplicar membresía ni gastar innecesariamente el enlace genérico. Al aceptar se revalidan identidad, habilitación, vigencia, tablero activo y autoridad actual del emisor. No habilitar cuentas por invitarlas. El rechazo de una directa no revoca otros enlaces del tablero ni impide una invitación futura.

Pruebas candidatas INV-01–05: directa reenviada a otra cuenta se deniega sin consumir; directa visible solo al destinatario; genérica disputada por dos personas concede un único acceso; no habilitado no consume ninguna; tener directa y genérica para el mismo tablero nunca genera dos membresías. No son pruebas ejecutadas.

**C-98, cierre aprobado:** una directa pendiente por persona/tablero; repetir alta muestra existente, renovar vencida exige acción explícita. Si ya pertenece, «Ya es miembro» sin nueva invitación. Preview tras validación de sesión/habilitación/invitación: nombre del tablero, invitador y rol; sin tareas, comentarios ni archivos. No mostrar esos metadatos públicamente. No envío de email.

### 2.11 Acceso instalable — C-99 / E06

La instalación PWA forma parte del MVP: acceso instalable desde navegadores compatibles, icono y apertura coherente con login y enlaces privados. La apertura instalada conserva los mismos destinos, permisos y navegación de la web. La instalación es opcional y no bloquea usar la aplicación desde navegador.

El contrato sigue siendo online, con consulta limitada de contenido ya cargado y borradores de sesión. No se añaden push, envío en cola offline, persistencia duradera de borradores ni app nativa. Cachés y datos de cuenta deben respetar cierre de sesión, cambio de identidad y revocación; un recurso cacheado no constituye autorización. C-109 fija matriz y UX en CF-26.1: Instalar aplicación opcional en menú de cuenta, directo o manual según soporte, sin insistencia; actualización disponible y recarga elegida resolviendo borrador. Mecanismos de sesión/caché y pruebas reales siguen pendientes; manifest no acredita garantías.

## 3. Contratos de pantalla

### UI-01 — Acceso y acceso restringido

**Contenido:** identidad de la app y botón Continuar con Google. No crear tableros públicos por URL ni ofrecer registro abierto. Si Google identifica pero no hay habilitación: explicación de acceso restringido, cuenta actual y cerrar sesión/cambiar cuenta; no listar personas o tableros.

**Sustitución de landing confirmada:** la raíz sin sesión es esta entrada, no el hero/CTA original para crear por slug aleatorio. Retirar de la experiencia activa formulario de URL y promesas de uso anónimo. Con sesión habilitada, raíz conduce a Tableros; sin habilitación, restringida. No pedir login de nuevo si sesión válida. Habilitar no significa que el admin cree contraseña: la persona usa Google y el admin autoriza el correo/identidad. Mantener solo documentos públicos necesarios sin puertas laterales a contenido. Rutas profundas no crean tableros por visitarlas; ver contrato MVP 4.0.

**Estados:** verificando sesión; login cancelado; error reintentable; cuenta suspendida. No mostrar datos privados un instante mientras se comprueban permisos. Un enlace profundo recupera el destino tras login solo si se autoriza. Acceso denegado no revela título, miembros ni existencia sensible de otro tablero.

### UI-02 — Invitación recibida

**Contenido:** aceptar invitación de tablero tras sesión/habilitación válidas; rol colaborador y aviso de visibilidad compartida. Nombre y emisor solo si la política de validación permite mostrarlos, no en una página pública previa al control.

**Acciones:** aceptar/cancelar; si ya es miembro, abrir tablero sin consumir inútilmente otro acceso. Estados: vencida (72 h), revocada, usada, emisor sin facultades, persona no habilitada y solicitud concurrente. Mensajes sin exponer identidad de quien la consumió. Ningún error habilita la app por sí solo.

### UI-03 — Tableros, pantalla de entrada

**Contenido:** listado de propios/compartidos, nombre y rol del usuario; acceso claro a crear tablero. Estrella personal en cada tablero y sección Favoritos dentro de este listado, sin agregar entradas al drawer. Favorito no cambia propiedad, membresía ni orden de otros usuarios; desaparece del listado al perder acceso. No mostrar tableros eliminados junto a activos ni incluir los ajenos por ser administrador global. Acceso separado a recuperación autorizada.

**Crear:** nombre del tablero y nombre de primera columna elegidos por usuario; sin «Pendientes/En curso/Hecho» automáticos, ni plantillas impuestas. Una columna basta. Identificador/ruta no concede acceso. La política de nombres/slug y el orden del listado se deben cerrar con la base actual antes de implementar.

**Estados:** aún sin tableros (crear o aceptar invitación); carga; fallo con reintentar; ya no accesible tras cambio remoto. Al abrir un tablero conservar la navegación de origen para volver. Si no hay favoritos, el resto del listado sigue disponible; no crear un tablero por ese estado vacío. No agregar carpetas ni espacios de trabajo.

### UI-04 — Tablero Kanban

**Cabecera:** ☰, nombre, búsqueda visible y ⋯ del tablero según 2.2–2.4. Volver a Tableros y conexión/guardado sin amontonar botones; miembros/invitaciones y acciones secundarias en ⋯, preferencias de completadas junto a filtros de vista. Series se encuentra en el drawer. Borrado separado y exclusivo del propietario.

**Cuerpo:** columnas libres, renombrar/ordenar/agregar, captura rápida de tarea por título en su columna. Crear con Enter o botón explícito; perder foco no crea. Una vez confirmado el alta, limpiar título y dejar captura lista para otra tarea en la misma columna; ante fallo conservar título autorizado y ante resultado incierto reconciliar antes de repetir. Sin alta por lotes ni nuevos campos obligatorios.

**Tarjeta, P04:** título y casilla cuando corresponda; responsable, vencimiento, prioridad y progreso cuando existan; indicador discreto de recurrencia. Descripción breve secundaria. Fecha de creación/autoría quedan en detalle. Etiquetas opcionales tienen presentación compacta y no desplazan la jerarquía principal; no llenar la tarjeta de selectores. Abrir, completar y mover tienen controles separados. Conversación, archivos e historial se consultan al abrir, sin cargarlos íntegramente en cada tarjeta.

**Completadas:** grupo al pie de cada columna, inicialmente visible, tildadas/atenuadas. Colapsado/ocultación personal. Abrir detalle para reabrir; no casilla de reapertura accidental en la tarjeta compacta. Reabrir antigua recurrente no permitido si ya apareció otra posterior.

**Acciones:** completar sin mover; mover/reordenar con arrastre o controles accesibles; abrir detalle. Si hay pasos pendientes, confirmar antes de completar. Cambio remoto actualiza tarjeta sin crear duplicados ni forzar otra columna activa al usuario.

**Estados:** columna vacía invita a agregar tarea; tablero sin columnas permite crear una sin inventarla. Filtro sin coincidencias ofrece limpiar filtros, no «crear tablero». Sin conexión: contenido cargado marcado como posiblemente desactualizado; no guardados ficticios. Al perder acceso, salir del tablero y limpiar estado privado activo al detectar revocación.

**Móvil:** conservar columna activa y navegación por botones/gestos; no exigir drag preciso como único método. El menú de mover elige columna del mismo tablero y no completa tarea. No cambiar de columna solo porque llega otra repetición a un tablero remoto.

### UI-05 — Detalle único de tarea

**Presentación confirmada:** extender modal existente en escritorio; en móvil, ocupar la pantalla disponible con controles claros, sin desplazamiento horizontal. Un único detalle adaptado al tamaño, sin selector de modos de apertura. Mismo detalle desde tablero, Mis tareas, búsqueda, vistas personales y novedades; volver conserva contexto/filtros/posición del origen. Adaptar al teclado virtual para no ocultar Guardar/cierre; esto no implica app nativa ni fullscreen del sistema operativo.

**Contenido en orden:** título y acciones principales; tablero/columna de origen; descripción con enlaces; responsable opcional, prioridad, fecha/reloj y etiquetas opcionales; luego checklist, adjuntos y conversación. Fecha de creación y autoría como información secundaria. Bloques opcionales vacíos muestran una acción breve para añadir contenido; controles Añadir pasos/archivo/comentario disponibles sin configuración de serie obligatoria. La actividad mínima tiene bloque propio, separado de la conversación, sin convertirse en otro destino global.

**Edición de campos confirmada:** título/descripción/responsable/prioridad/fecha y selección de etiquetas se confirman con Guardar. Guardar muestra progreso y no anuncia éxito hasta confirmación. Error conserva texto y permite reintentar. Cerrar con cambios pendientes ofrece «Guardar y cerrar», «Descartar cambios» y «Seguir editando». Guardar y cerrar solo cierra si persiste; descartar revierte únicamente los campos no guardados; seguir editando conserva borrador/foco. Sin cambios se puede cerrar directamente. No sustituir por autoguardado global. La gestión del catálogo es una acción distinta: propietario y colaboradores crean/renombran/cambian color; solo propietario elimina (C-100).

**Acciones independientes confirmadas:** tildar un paso, publicar comentario y cargar archivo se guardan con su acción y resultado propio. Cancelar edición de descripción no deshace un comentario o paso ya guardado. Fallo de un comentario conserva su borrador y no descarta cambios de campos. Completado mantiene sus confirmaciones ya acordadas. C-95/EE-04 exige resolver campos pendientes antes de completar, mover, borrar o cambiar de tarea: Guardar y continuar / Descartar y continuar / Cancelar. Si guardar falla o queda incierto, no ejecutar la segunda acción; no guardar campos silenciosamente ni bloquear comentar por el mero hecho de editar descripción.

**Recargar/cerrar pestaña:** C-95/EE-03 limita borradores a memoria durante la sesión de edición, sin garantía de supervivencia al refrescar/cerrar. Advertencia nativa cuando el navegador la permita, sin prometer texto personalizado. Navegación dentro de la app sí debe respetar las tres opciones anteriores; PWA no amplía esta garantía.

**Checklist:** pasos con texto/casilla/reordenar/borrar; sin campos propios ni navegación a otra tarea. Marcar todos no completa padre. Comentarios cronológicos con autor, edición propia, moderación por propietario, mención a miembro actual; exmiembro se muestra como texto literal sin destino. URLs clickeables seguras.

**Adjuntos:** nombre para miembros, tamaño, subir/descargar/borrar según permiso, límites visibles 24 KB (24.000 bytes) y .txt/.md. Contador «16 activos + 4 en recuperación / 20»; archivos recuperables no se descargan como activos ni liberan plazas antes de purga. Mostrar progreso/error durante reserva, carga y verificación; solo presentar disponible al publicarse con permiso válido. No previsualizar contenido activo subido.

**Serie:** identificar claramente «Esta repetición» y acceso a «Editar serie». Cambiar actual no cambia plantilla. En histórica, mostrar fecha/estado y razón por la que no se puede reabrir; no prometer edición histórica de campos que aún no tiene contrato.

**Borrado:** acción secundaria con alcance tarea / esta repetición / serie y ventana de 7 días. No borrar serie por el simple icono de eliminar tarjeta sin preguntar. Dejar de repetir es acción distinta, conserva contenido.

**Copiar enlace, P11:** acción secundaria explícita sobre esta tarea u ocurrencia; confirmar copia al portapapeles solo si se realizó, con alternativa visible si falla. Aplican §2.6 y autorización vigente; copiar no equivale a invitar.

**Duplicar tarea puntual, E04:** acción secundaria que crea una tarea pendiente con identidad nueva en el mismo tablero. Copia título, descripción, prioridad, checklist sin marcar y etiquetas activas del origen (C-101); no hereda responsable, fecha, serie, comentarios, archivos ni membresías. Origen ocurrencia: selección propia, no plantilla. Origen intacto. Si se parte de una ocurrencia, avisar que la copia será puntual. Resolver campos pendientes antes de continuar; C-104 fija mismo título editable para nueva tarea y columna origen por defecto con selector del mismo tablero, al final del orden manual sin alterar presentación personal. Permite fuentes completadas/históricas autorizadas sin editar original; eliminadas requieren recuperar, cumpleaños sin Duplicar tarea. C-105: panel breve con título/columna/resumen, Crear copia o cancelar sin efecto; resultado permite abrir y conserva origen. Si cambia contenido copiable, actualizar preview y pedir revisión preservando título/destino elegidos. Comentario nuevo no interrumpe; borrado/acceso perdido bloquea. El resultado confirmado permite abrir la nueva tarea; fallo no modifica el origen ni crea duplicados por reintento.

**Actividad mínima, E05/C-105:** bloque de detalle con actor, fecha/hora y valores anterior/nuevo para responsable/fecha/columna/completado; recuperación quién/cuándo. Recientes primero, carga progresiva y estados vacío/error distintos. Retener 180 días desde evento con ventana visible; recuperar/importar no rejuvenece. Ocultar con tarea y purgar dependiente; recuperar solo vigentes. Autor histórico sin permisos/menciones, distinguir Sistema/Actividad importada. Incluir vigentes en respaldo de tareas exportables sin avisos antiguos. No categorías adicionales, versiones de textos ni edición/borrado individual. CF-25.1.

**Etiquetas, E01/C-100:** tareas y cumpleaños admiten etiquetas opcionales del tablero; plantilla de serie tiene selección propia para próximas ocurrencias, copiada con sus etiquetas activas al generar cada ocurrencia (C-101). Cambiar ocurrencia no cambia plantilla, ni cambiar plantilla modifica generadas. Nombre hasta 40 caracteres, único por tablero ignorando mayúsculas/espacios sobrantes; 100 etiquetas activas/tablero y 10 activas/elemento; paleta accesible con colores repetibles. Cualquier miembro crea/renombra/cambia color/aplica/quita; solo propietario elimina catálogo. Renombrar conserva asociaciones y filtros. No cambia columna, completado, prioridad o responsable. C-101: borrar oculta sin borrar elementos; conserva asociaciones para recuperación siete días solo propietario actual, luego purga. Copia y respaldo en CF-22.2; C-102 añade preview con resolución de nombre/cupo/asociaciones y prohíbe omisiones silenciosas.

### UI-06 — Programar y editar serie

Desde reloj de tarea o fila de Series. Opciones progresivas: fecha por día, repetición opcional, patrón/intervalo/días, inicio/final, anticipación opcional y columna de aparición dentro del tablero. En edición de plantilla: título/descripción/prioridad/responsable/checklist de próximas; distinguirlos del contenido de la actual.

Mostrar resumen legible, próximas fechas y zona del tablero. Aparición y vencimiento se rotulan por separado. Validaciones junto al campo: intervalo positivo, días elegidos, fin coherente, anticipación menor que separación mínima, destino válido y responsable elegible. Nunca corregir silenciosamente 4 días a 2.

Guardar edición de serie advierte «Solo cambia las próximas repeticiones». Campos actuales/historial intactos. Si el cambio produciría una activación inmediata incompatible, conservar formulario y explicar qué ajustar. Conflicto colaborativo no sobreescribe otra regla. Cancelar no altera serie ni actual.

### UI-07 — Cumpleaños

No crear otra app de agenda: tipo fecha anual dentro del tablero, con nombre, día/mes y anticipación opcional. Sin checkbox ni tareas automáticas de saludar. Detalle con fecha próxima/regla y edición/borrado según permisos; no forzar responsable ni checklist.

Sin anticipación: visible todo el año y fecha del próximo cumpleaños desde el día siguiente. Con anticipación: visible D−X a D inclusive; fuera de ventana se encuentra desde Series. Mostrar «Cumpleaños» y fecha, nunca «tarea vencida». Flujo de alta propuesto como opción secundaria junto a añadir tarea, por revisar; no reemplaza captura rápida normal.

### UI-08 — Mis tareas

Lista secundaria de asignadas entre tableros accesibles, con título, origen, fecha, prioridad y completado. Orden por vencimiento ascendente, vencidas primero, sin fecha al final; alternativa por creación y preferencias personales. Grupo de completadas al pie y filtros visibles.

Completar actúa sobre origen y confirma pasos pendientes; resto de edición abre UI-05. No mover tareas a un tablero personal ni autoasignar las creadas sin responsable. Si cambia responsable/permisos, retirar resultado apropiadamente. Vacío: «No tenés tareas asignadas»; si hay filtros, aclarar que no hay coincidencias. Sin estadísticas ni planificación diaria obligatoria.

### UI-09 — Series e historial

Acceso compacto global, o prefiltrado desde tablero. Filas: nombre, tablero, patrón, próxima aparición y vencimiento cuando difieran. No depender de que una tarjeta esté visible. Filtro por tablero y estado; alcance todas las series accesibles, propias o creadas por otros.

Abrir editor UI-06; ver historial con fecha/estado y detalle de ocurrencia; dejar de repetir/eliminar con confirmación. Historial paginado, sin borrar información por cargar pocas filas. Si falta destino, mostrar problema y corregir, no próxima fecha inventada. C-112: no reanudar la anterior; nueva programación crea otra serie con la misma tarjeta inicial y confirmación explícita CF-08.1. Estado vacío explica que se crea repetición desde reloj de una tarea/fecha.

### UI-10 — Búsqueda y filtros

C-107: entrada unificada con sugerencias mientras escribe, identificadas por tipo/campo y contexto; incluye comentarios/tableros además de tareas/títulos. Elegir resultado navega o filtra. Alcance todos los accesibles o contexto actual, con filtros de tareas por responsable/prioridad/completado/vencimiento/etiquetas; C-108/CF-14.2 aplica filtros a tareas/comentarios por tarea padre y separa navegación de tableros. Etiquetas sugieren filtro concreto. Resultados abren destino preciso, incluidos comentarios localizables; acción Ver tareas que coinciden separada/deduplicada. Sugerencias por relevancia agrupadas, exactas/prefijos/palabras incompletas, con espacio por tipo; lista respeta orden personal. Archivos/actividad fuera del alcance inicial. Alcance siempre visible, chips de filtros eliminables y Limpiar. Resultados con tablero/columna de origen y UI-05 común, sin duplicados. Preferencia de ocultar completadas en columna no impide incluirlas expresamente en búsqueda. No introducir lenguaje de consultas ni catálogo global de etiquetas; la selección en alcance global debe conservar el tablero de cada etiqueta. C-100: selector «Cualquiera de estas etiquetas», OR entre etiquetas y AND con los demás filtros.

«Hoy», «Vencidas», «Próximos 7 días» y «Sin fecha» son accesos al mismo filtro, no pantallas nuevas. Próximos va desde mañana hasta hoy+7 inclusive según la zona de cada tablero; Hoy y Vencidas se mantienen separados. En alcance global se muestran fecha y tablero para entender resultados de zonas distintas. Solo contenido autorizado, incluyendo conteos/sugerencias. Estado cargando, error, sin coincidencias y acceso retirado no se confunden. C-107/C-108 incluyen comentarios actuales en búsqueda unificada; archivos y actividad quedan fuera. La elección técnica de motor se verifica en el stack actual, sin contratar otro por defecto.

**Vistas personales guardadas, E02/C-100:** crear/abrir/editar/eliminar desde búsqueda o Mis tareas, sin nuevo destino global. Guardar texto, alcance, completadas, filtros y orden. Global sigue accesos actuales; tablero específico permanece acotado; Mis tareas conserva asignación propia. Fechas relativas se recalculan. Editar filtros produce variación temporal con «Actualizar vista», «Guardar como nueva» y «Restablecer vista». Hasta 50 vistas activas/persona en total, nombre hasta 60 caracteres y único por contexto. Son personales y sincronizadas; no resultados congelados, vistas compartidas ni permisos. Distinguir de P06. C-101: referencia explícita inválida bloquea resultados con «Esta vista necesita revisión» hasta revisar/confirmar; permite quitar/reemplazar condición sin nombre privado revocado. Global dinámico se adapta. Borrada se oculta del selector y se recupera siete días solo usuario en gestión del contexto, revalidando referencias. Conflicto conserva variación y permite cargar actual/guardar nueva; revisar actual antes de actualizar original. Casos restantes en CF-22.2.

### UI-11 — Novedades

Acceso «Novedades» en drawer con icono de campana y contador de no leídas; no campana duplicada en la cabecera inicial. Bandeja con motivo, actor si corresponde, referencia autorizada y fecha. Alternar todas/no leídas; verificar acceso antes de marcar leída y abrir detalle autorizado, sin completar tarea. Mostrar «Se conservan 90 días, incluidas las no leídas»; caducar aviso no borra conversación/tarea.

Sin autoavisos ni duplicados: deduplicar por evento/destinatario, no por texto; varios motivos de una misma acción producen una novedad por persona. Editar comentario avisa solo a nuevas menciones válidas; corregir texto o quitar/agregar repetidamente la misma mención no reavisa al mismo usuario. Cuota global puede dirigir a gestión de archivos según rol, sin exponer otros tableros. Tarea borrada: no disponible; pérdida de acceso: no mostrar título/extracto privado. Vacío «No hay novedades» o «No quedan sin leer». No prometer email/push.

**Marcar novedades cargadas como leídas, E07/C-109:** una pulsación sin diálogo adicional, con cantidad de sin leer cargadas en botón («Marcar 12 visibles como leídas»); conjunto de IDs fijado al pulsar. No incluye páginas no cargadas, futuras ni todas las del servidor por inferencia; no archiva ni pospone. Si solo se cargaron 20 de 80, actúa como máximo sobre esas 20. Las que lleguen durante el envío no se incorporan silenciosamente. C-109: resumir marcadas/ya leídas resueltas/no disponibles/falladas, sin éxito global ficticio; reintentar solo falladas autorizadas del original. Reconciliar resultado incierto y contador antes de repetir, sin nombres privados.

### UI-12 — Miembros y salida del tablero

Miembros actuales con nombre/rol; propietario invita, revoca enlaces y retira colaboradores. Colaborador puede ver miembros y salir, no administrar otros ni ascenderse. Selección de responsables nunca muestra un directorio global.

**Salida normal del propietario:** selector obligatorio de sucesor entre otros miembros habilitados. Botón «Transferir y salir» deshabilitado hasta elegir; confirmar quién quedará. Si solo está él, ofrecer «Eliminar tablero y salir», con confirmación explícita de recuperación 7 días. Nunca botón «salir sin elegir» ni sustitución silenciosa de su elección por carrera.

Revalidar al guardar: si el sucesor ya no es elegible, conservar diálogo y pedir otro. Transferencia/salida coherentes sin estado activo huérfano. La reparación automática por mayor antigüedad es una protección excepcional interna ante inconsistencia, no un camino del formulario. Administrador puede reasignar desde UI-15 sin leer tareas.

### UI-13 — Ajustes y gestión de archivos del tablero

Agrupar acciones secundarias sin recargar Kanban: preferencias personales claramente separadas de configuración compartida (p. ej. zona horaria), miembros, recuperación, archivos, exportar/importar y eliminar tablero. Configuración compartida por propietario; preferencias disponibles a cada miembro. Catálogo de etiquetas pertenece al tablero y su gestión se ubica en este contexto, con facultades explícitas C-100 (matriz B-24/B-24b); gestión de catálogo separada de seleccionar etiquetas. Respetar permisos existentes de exportar y contrato de importación aprobado en C-92.

Archivos: consumo propio del tablero, límites globales explicados, filtros por tareas completadas y selección explícita para borrar. Mostrar tamaño activo/recuperable y cuándo se liberará espacio. Borrar no elimina tareas; no botón de purga inmediata que invalide recuperación. Aviso global no se presenta como cuota propia de 200 MB por tablero.

### UI-14 — Recuperación

Lista autorizada con tipo, nombre permitido, fecha de borrado y vencimiento exacto. Restaurar explica dependencias: tablero primero; columna destino si ya no existe; nuevo dueño habilitado en caso de tablero sin miembros. Una eliminación independiente previa no se revierte por recuperar al padre.

Serie: advertir que actualiza calendario sin crear todas las atrasadas, conservando activa/detenida. No recuperar asignaciones de retirados ni enlaces de menciones antiguas. Moderación conserva permisos restringidos. Expirado: no ofrecer restaurar aunque falte purga física; error concurrente explica que no pudo restaurarse. No restaurar tareas/archivos solo por abrir la lista.

### UI-15 — Administración de aplicación

Solo administrador global. Tres bloques propuestos: personas (habilitar/suspender), propiedad/recuperación excepcional de tableros y capacidad/limpieza de adjuntos. No tablero universal de todas las tareas ni permisos de lectura implícitos.

Retirar persona: resumen de tareas desasignadas y tableros propios, elegir sucesor por tablero con otros miembros; si no hay, advertir borrado recuperable. Confirmación conjunta con revalidación; no retirar a medias dejando propiedad rota. Rehabilitar acceso no devuelve membresías, asignaciones ni menciones antiguas. Reasignar propietario es explícito y registrado.

Capacidad: 200 MB globales (200.000.000 bytes), aviso 160 MB, activos/recuperables/reservas, filas de metadatos mínimos y limpieza autorizada sin leer/descargar archivos de tableros ajenos. No nombres privados de tareas/comentarios. Normalmente el propietario limpia con su contexto. Definir metadatos exactos y avisos de cambios administrativos en contrato técnico, no por accidente visual.

### UI-16 — Cuenta y preferencias

Cuenta Google actual, cerrar sesión y preferencias personales ya incluidas. No cambio de identidad/contraseña Google dentro de esta app, ni eliminación de cuenta completa añadida por inferencia. Separar cerrar sesión de salir de un tablero.

**P06 / E03:** orden, filtros y visibilidad de completadas se recuerdan por usuario y contexto de vista/tablero y se sincronizan entre sus dispositivos. Favoritos, vistas guardadas y tema también son personales; no modifican configuración de otros. Ofrecer reinicio explícito de preferencias del contexto a sus valores iniciales, sin borrar tareas ni vistas guardadas. C-104 combina preferencias diferentes; conflicto si se modifica la misma conserva local y exige revisar, con opción de cargar guardada o revisar/conservar local. Tema inicial Sistema y login aplica cuenta; modos fijos sincronizados, Sistema por dispositivo. C-106 cierra defaults/reinicio, texto nuevo, contextos y Limpiar en CF-13.2; quedan mecanismos. Posición de scroll y columna activa se conservan como navegación, no como orden compartido ni garantía de sincronización entre dispositivos.

Tema con opciones Claro, Oscuro y Sistema, manteniendo identidad negro/blanco/amarillo, contraste y estados distinguibles. Cambiar tema no recarga ni pierde el editor. No editor de colores ni tema por tablero. Español es el idioma inicial en pantallas, errores, estados y etiquetas accesibles; textos/formatos centralizados, fechas legibles y no ambiguas. No selector multidioma ni traducción automática del contenido de usuarios.

Cerrar sesión limpia datos activos de la cuenta. Si hay texto sin guardar, advertir; cierre por revocación no puede depender de que el usuario acepte un diálogo. Definir duración/ubicación de borradores sin prometer recuperar texto después de cerrar navegador o cambiar de cuenta.

### UI-17 — Importación/exportación

Reutilizar entrada existente. Exportar muestra alcance y obtiene solo contenido autorizado. Importar exclusivo de propietario: selección de archivo, validación, previsualización de reemplazo, asignaciones incompatibles/cuota y confirmación. No habilitar usuarios ni adoptar permisos del archivo.

**Funcional confirmado C-92:** contenido/adjuntos, compatibilidad v1, reemplazo previsualizado por propietario sin cambiar dueño/miembros, previo recuperable 7 días con consumo de capacidad y rechazo antes de borrar si no alcanza. Ante error, conservar tablero previo y no anunciar importación parcial. **Pendiente técnico:** formato y mecanismo de reemplazo/recuperación seguro entre base y archivos, validaciones y concurrencia de CF-19. No se declara resuelto por aprobación funcional ni se simula un botón funcional durante fase de spec.

## 4. Interacciones transversales

Desarrollo en [Estados y errores](./ESTADOS-Y-ERRORES-MVP-1.0.md), revisión 0.3: C-95 aprueba los cinco principios EE-01–05; C-99 integra las precisiones y extensiones de Plane. Incluye ERR-01–16 y ERR-PL para verificar el alcance aprobado; son escenarios de aceptación, no pruebas ejecutadas. Los mecanismos y contratos que aún no quedaron definidos permanecen identificados.

| Caso | Respuesta exigida/propuesta |
| --- | --- |
| Guardado fallido | Borrador y error visibles; reintentar sin duplicar acción ni perder contexto. |
| Conflicto de edición | Explicar que hubo cambio ajeno, conservar texto y permitir revisar; no botón ambiguo que sobreescriba automáticamente. |
| Acción no autorizada | No ofrecer control engañoso; comprobar también en servidor y explicar si cambió el permiso durante la sesión. |
| Sin conexión | Lectura de lo ya cargado con advertencia; no cola offline de escrituras prometida. |
| Borrado | Confirmar objeto, alcance, dependientes y 7 días; no usar una confirmación genérica para tarea/serie/tablero. |
| Foco y teclado | Recuperar foco al cerrar diálogo; formularios etiquetados; no atajos mientras se escribe; conservar atajos originales aplicables. |
| Móvil | Formularios sin desplazamiento horizontal, botones accesibles, acciones no dependientes de hover y navegación de columnas por botones además de gestos. |
| Tiempo y fechas | Español y fechas no ambiguas; día visible coherente con zona del tablero; creación distinta de vencimiento; cambio de día actualiza vista sin recarga manual. Próximos 7 días excluye hoy y usa cada zona de tablero. |
| Enlaces | Clic explícito seguro, sin ejecutar HTML/esquemas peligrosos; no activar automáticamente un destino por pegarlo. |
| Cuotas | Mensaje antes de cargar cuando límite conocido y validación real al guardar; conteo incluye recuperables y carga concurrente puede agotar saldo. |

## 5. Recorridos de aceptación y contratos pendientes

Recorridos del alcance aprobado para verificar durante implementación y piloto, todavía sin pruebas ejecutadas:

1. Persona habilitada → crea tablero con una columna propia → crea tarea solo con título → completa sin programar nada.
2. Comparte → asigna → agrega checklist/comenta/menciona → destinatario abre novedad → completa desde Mis tareas y cambia origen.
3. Programa lunes/miércoles → mueve actual → cambia columna futura → completa → encuentra la serie aunque oculte completadas → consulta histórica sin reabrirla.
4. Se corta red al editar → ve no guardado → recupera conexión y resuelve cambio ajeno sin perder borrador.
5. Propietario intenta salir sin elegir sucesor → no puede confirmar; elige → transfiere y sale; reingresa después sin recuperar roles/asignaciones/menciones viejas.
6. Tarea con 16 archivos activos y 4 recuperables → carga rechazada por 20; borrado de otro no libera plaza hasta purga; resto de app funciona.
7. Tablero eliminado → dentro de plazo se restaura con propiedad/destino válidos; después del plazo no se ofrece restaurar.
8. Administrador limpia adjuntos mediante metadatos sin leer contenido; propietario recibe avisos de capacidad sin acceder a tableros ajenos.

Navegación global/contextual y edición básica acordadas para primera prueba. Casos adicionales de aceptación: guardar y cerrar con error mantiene editor/borrador; descartar campos no deshace comentario/checklist/archivo ya guardado; guardar por reintento no duplica; teclado móvil no fuerza scroll horizontal ni oculta controles críticos. No son pruebas ejecutadas.

**C-99 / P09 y P26:** validar captura, búsqueda, completado, coordinación y retomar una rutina con personas del piloto, registrando pasos y tropiezos sin analítica externa ni puntajes de productividad. La evaluación de facilidad de uso es distinta de las pruebas automáticas. Matriz móvil: anchos de 360 y 390 px y escritorio, teclado virtual abierto/cerrado, cambio de orientación y Atrás. Crear/editar, asignar, comentar y Programar deben ser operables sin arrastre preciso; cambios remotos no roban foco ni cambian columna activa.

| ID | Caso | Resultado esperado |
| --- | --- | --- |
| UI-PL01 | Capturar tres tareas sucesivas y perder foco con un cuarto título. | Cada envío explícito confirmado deja captura lista en la misma columna; perder foco no crea ni pierde el cuarto título de sesión. |
| UI-PL02 | Tarea mínima frente a una con pasos, archivos, etiquetas y comentarios. | Jerarquía estable, bloques vacíos compactos, creación/autoría en detalle y acciones de abrir/completar/mover independientes. |
| UI-PL03 | Búsqueda Hoy/Vencidas/Próximos 7 días con dos zonas de tablero. | Chips y alcance visibles; Próximos incluye mañana a hoy+7 de cada tablero, con fecha/origen; Limpiar no altera orden de otra persona. |
| UI-PL04 | Cambiar filtros, completadas y favorito; abrir en segundo dispositivo. | Preferencias personales por contexto; otro miembro conserva las suyas. Revocación retira tablero y datos de los favoritos/resultados. |
| UI-PL05 | Buscar sin coincidencias, tablero sin columnas y fallo de recarga. | Acciones diferentes: limpiar filtros, crear columna o reintentar; el fallo no simula vaciado ni elimina contenido todavía autorizado. |
| UI-PL06 | Tarea/asignación/comentario/Programar en 360/390 px, escritorio y con teclado. | Sin desplazamiento horizontal ni controles críticos inaccesibles; alternativa al arrastre, foco y regreso correctos, sin robo de foco por realtime. |
| UI-PL07 | Seleccionar/quitar etiqueta y consultar otro tablero. | No mueve ni completa; catálogo limitado al tablero, filtro con origen; no herencia de serie ni permisos de catálogo implícitos. |
| UI-PL08 | Guardar vista «Esta semana» y abrirla otra semana o tras revocación. | Recalcula fechas relativas sobre datos autorizados; no copia tareas ni recupera resultados privados antiguos. |
| UI-PL09 | Cambiar Claro/Oscuro/Sistema durante edición. | Borrador intacto, sin recarga; foco, prioridades y errores legibles. Textos del producto en español, contenido del usuario intacto. |
| UI-PL10 | Duplicar tarea y duplicar ocurrencia con checklist marcada. | Nueva puntual pendiente en mismo tablero, pasos sin marcar y exclusiones E04; origen intacto y aviso de salida de serie. |
| UI-PL11 | Consultar actividad de cambio de responsable/fecha/columna/completado/recuperación. | Actor/fecha, acceso actual y evento único; sin versiones de comentarios ni restauración desde historial. C-105: verificar 180 días, recuperación sin reinicio y purga dependiente. |
| UI-PL12 | Instalar y abrir PWA, seguir enlace privado, cerrar sesión/cambiar cuenta. | Mismo login/destino autorizado, sin contenido de otra cuenta ni cola offline. Compatibilidad se acredita por dispositivo/navegador probado. |
| UI-PL13 | Marcar cargadas leídas con 20 de 80 y una novedad que llega durante envío. | Solo conjunto inicial autorizado; futura/no cargadas intactas, cantidad/contador reales y errores parciales comprensibles. |

**Pendientes reales:** layout fino del alta de cumpleaños/primera columna y gestión de vistas; mecanismos/pruebas de preferencias y búsqueda unificada C-107; medición/normalización técnica y mecanismo de concurrencia de vistas; mecanismos/pruebas de copia y actividad C-105; mecanismos/pruebas de PWA y lote C-109; diseño técnico del respaldo y verificación de todos los recorridos. Estas tareas completan contratos de funciones ya incluidas, no las devuelven al backlog. No reabrir reglas confirmadas ni interpretar documentación como implementación.

## C-102 — Recuperación, reparación y coincidencia textual

- **Q15 · Cupos:** cuentan solo activos: 100 etiquetas/tablero, 10 etiquetas/elemento, 50 vistas/persona entre ambos contextos. Recuperables liberan lugar; restaurar consume cupo y se bloquea si no cabe, sin eliminar otros elementos.
- **Q16 · Nombres al restaurar:** se puede reutilizar nombre de objeto eliminado. Si colisiona al restaurar, renombrar uno explícitamente; conservar identidad original, sin fusionar ni trasladar asociaciones por nombre.
- **Q17 · Asociaciones:** preview de restauración identifica elementos que excederían diez etiquetas. Liberar espacio o elegir explícitamente no recuperar esa asociación. Aplicar solo cuando toda selección confirmada sea válida; no omisiones silenciosas, ocurrencias retroactivas ni restauración de tareas borradas.
- **Q19 · Reparación:** «Guardar corrección» actualiza definición y habilita consulta tras revalidar. Si vuelve la referencia original, revisar/confirmar basta; una condición ya quitada no se repone sola.
- **Q20 · Vista borrada durante edición:** conservar variación temporal autorizada; ofrecer guardar como nueva con nombres/cupos válidos o recuperar original por su vía en plazo. Guardado tardío no resucita; recuperación no aplica borrador automáticamente.

**Q18 corregida · Coincidencia textual:** búsquedas y filtros ignoran acentos y la diferencia ñ/n: «reunión»/«reunion» y «Peña»/«Pena» encuentran lo mismo. Conservar escritura original al mostrar/guardar. Es comparación textual, no fusión de identidades: seleccionar una etiqueta sigue filtrando por esa etiqueta y su tablero. No confiere permisos; C-107 amplía los campos buscables. C-103 confirma esa misma equivalencia para unicidad de nombres de etiquetas/vistas dentro de sus ámbitos.

### C-103 — Unicidad de etiquetas y vistas

**C-103 / Q18b:** al crear, renombrar o restaurar etiquetas y vistas, la unicidad ignora mayúsculas, espacios sobrantes, acentos y ñ/n. «Reunión»/«Reunion» y «Peña»/«Pena» colisionan dentro del mismo tablero para etiquetas, o del mismo usuario/contexto para vistas. Conservar escritura original; informar coincidencia y mostrar la existente solo si está autorizada. No fusionar automáticamente ni cambiar identidades/asociaciones. Nombres de otros tableros, usuarios o contextos no provocan colisión ni se revelan.

Criterio C103-AC18b en Cierre CF-22.4, todavía no ejecutado.

### C-106/C-107 — Preferencias y búsqueda

- **Q34 · Defaults:** si no hay preferencia o tras reinicio: Tablero manual/sin filtros opcionales/completadas visibles y expandidas; Mis tareas todos los tableros accesibles/sin filtros adicionales/vencimiento ascendente/completadas visibles y expandidas; lista de búsqueda pendientes/sin filtros adicionales/vencimiento ascendente y sin fecha al final. Si existen preferencias del contexto, recuperarlas.
- **Q35 · Contextos:** cada tablero, búsqueda global y búsquedas contextuales tienen preferencias independientes. Buscar desde tablero inicia acotado a él, desde Mis tareas sobre asignadas propias. Ampliar a global requiere elección explícita visible.
- **Q36 · Texto:** búsqueda nueva con texto vacío, conservando filtros/orden del contexto. Texto se mantiene durante consulta y al volver de detalle. Abrir vista guardada recupera texto de su definición.
- **Q37 · Limpiar:** elimina texto/filtros opcionales de consulta actual, conserva alcance/orden y vuelve completadas al default del contexto. En Mis tareas mantiene asignación propia. En vista guardada genera variación temporal sin modificar definición.
- **Q38 · Reiniciar preferencias:** restablece solo orden/filtros/completadas del contexto actual, preservando favoritos, vistas guardadas, tema y otros contextos. Si hay vista guardada abierta, vuelve a contexto base sin modificarla. Tema vuelve a default eligiendo Sistema.
- **Q39 · Referencia recordada inválida:** detener consulta y pedir revisar o limpiar explícitamente; mensaje genérico sin nombres privados ante revocación. No quitar condiciones silenciosamente ni convertir alcance específico en global.

**C-107 · Búsqueda unificada solicitada:** el usuario pide ampliar la búsqueda previa de título/descripción con sugerencias mientras escribe en varios campos/entidades, mencionando títulos, tareas, comentarios y tableros. Cada coincidencia identifica tipo/campo y origen/contexto; recién al elegir se navega o filtra. Prefiere esta experiencia rica si es viable. Sustituye la exclusión anterior de comentarios y el límite de buscar solo tareas. Siguen vigentes autorización, contexto, acentos/ñ, teclado/móvil y separación de sugerir frente a ejecutar. C-108 cierra fuentes/destinos/ranking/filtros por tipo en CF-14.2. Faltan mecanismos y validación de calidad, rendimiento y permisos.

### C-108 — Interacción de búsqueda unificada

- **Q40 · Fuentes:** tareas (título/descripción), comentarios actuales y tableros; añadir etiquetas coincidentes como sugerencias de filtro sobre etiqueta concreta y su tablero. Distinguirlas de destinos de navegación. Archivos y actividad fuera de este alcance inicial.
- **Q41 · Elegir:** tablero abre tablero, tarea abre detalle y comentario abre detalle ubicando comentario preciso. «Ver tareas que coinciden» es acción separada para lista filtrada, deduplicada por tarea aunque coincidan varios comentarios. Escribir no navega ni cambia tablero/filtros de origen.
- **Q42 · Orden:** sugerencias por relevancia agrupadas, priorizando exactas y comienzos de nombres/títulos, con palabras incompletas. Espacio por grupo impide que muchos comentarios oculten un tablero claramente coincidente. Lista posterior conserva vencimiento/creación según preferencias.
- **Q43 · Filtros por tipo:** tareas respetan sus filtros; comentarios heredan los de tarea padre (no confundir responsable de tarea con autor del comentario). Mis tareas incluye asignadas propias y sus comentarios; solo pendientes excluye comentarios de completadas con opción explícita de incluirlas. En global tableros son navegación separada, sin prioridad/responsable/vencimiento ficticios. Interfaz explica resultados afectados por filtros.

Criterios C108-AC40–43 en Cierre CF-14.2, todavía sin ejecutar. Tipos/campos, fragmentos y tarea/tablero de origen visibles; no duplicar fila de tarea por cada campo coincidente. Abrir comentario requiere autorización vigente y localización precisa incluso con paginación.

### C-109 — Instalación y novedades

- **Q44 · Validación:** priorizar Android/Chrome, iPhone/Safari y escritorio Chrome/Edge, incluyendo Safari en Mac. Probar instalación/apertura/login/enlaces/cambio de cuenta y registrar versiones. Firefox también para uso web. Instalar no es requisito para usar producto; objetivo de pruebas, no compatibilidad ya acreditada.
- **Q45 · Descubrimiento:** «Instalar aplicación» opcional en menú de cuenta, sin ventanas insistentes al entrar. Ofrecer instalación directa donde exista o instrucciones breves manuales específicas. No anunciar instalación exitosa por el solo clic.
- **Q46 · Actualización:** aviso «Hay una actualización disponible», con recarga elegida por usuario. Resolver campos pendientes mediante Guardar/Descartar/Seguir editando; no forzar recarga que pierda borrador. Mantener contrato online y sin promesa de supervivencia al cierre del sistema.
- **Q47 · Lote:** una pulsación sin diálogo extra. Botón con cantidad, por ejemplo «Marcar 12 visibles como leídas», contando sin leer actualmente cargadas. Fijar ese conjunto al pulsar; no incorporar posteriores/otras páginas.
- **Q48 · Resultado:** resumen con marcadas, ya leídas/resueltas, no disponibles y pendientes de reintento. Conservar éxitos, ofrecer reintentar solo falladas del lote original con autorización vigente. No disponibles no se convierten en fallos repetibles; no mostrar títulos revocados. Resultado incierto se reconcilia antes de repetir según C-95.

Criterios C109-AC44–48 en Cierre CF-26.1/CF-27.1, todavía sin ejecutar.

### C-110 — Calendario visible y recuperación

- **Q49 · Inicio/anclaje:** fecha de inicio explícita, proponiendo fecha existente de tarea. Semanas lunes–domingo ancladas a semana del inicio; no generar fechas anteriores. Preview distingue tarjeta actual y próximas. Inicio miércoles: lunes/miércoles cada dos semanas incluye ese miércoles y siguiente semana habilitada, no la intermedia.
- **Q50 · Final/conteo:** fecha final inclusiva. N cuenta fechas efectivas del calendario, no completados; exclusión explícita consume su fecha y no extiende serie. Mes sin quinto lunes no genera fecha que contar. Preview identifica fechas contadas; 1/4/7 con exclusión del 4 no agrega el 10.
- **Q51 · Excepción:** nueva fecha límite actual debe ser anterior a aparición siguiente. Rechazar fecha igual o posterior, explicar máximo y conservar borrador; no fusionar ni cambiar calendario posterior. Si próxima aparece sábado14, máximo viernes13.
- **Q52 · Recuperación finita:** serie cuyo final pasó reconcilia como máximo última ocurrencia válida, aunque vencida y aún no materializada, sin pendientes intermedios ni extender final. 1/3/5, borrada2 y recuperada6: historial y una vigente del5. Si última fecha excluida no crear sustituta. No regenerar una ocurrencia eliminada/purgada independientemente al restaurar su padre. Detenida sigue detenida.
- **Q53 · Recuperación individual:** deshacer solo exclusión causada por borrar esa misma ocurrencia; conservar otras exclusiones y no reactivar serie. Si hay posterior activada, recuperar como histórica. Exigir padres autorizados recuperados; recuperar serie no revive hijos borrados antes por separado.
- **Q54 · Actores:** propietario o colaborador actual con permiso de edición recupera pasos, series y columnas ordinariamente borrados dentro de siete días, como tareas; no exclusividad del que borró. Moderación/limpieza administrativa conservan restricciones. Recuperar columna no revierte traslados.

Preview distingue actual y próximas, fechas contadas/excluidas y efecto de recuperación. Rechazo de excepción conserva edición y explica máximo permitido. Recuperar finita explica única vigente posible, incluso vencida, sin lista de atrasos. C110-AC49–54 todavía sin ejecutar.

### C-111 — Calendario, avisos y enlaces

- **Q55 · Conversión:** conservar misma tarjeta como primera ocurrencia, contada en N; con N=3 quedan dos fechas adicionales. Preview distingue actual/próximas. Si vencimiento no encaja, elegir y confirmar primera fecha compatible; no cambiarlo silenciosamente ni duplicar tarjeta.
- **Q56 · Editar cantidad:** mostrar «N próximas repeticiones», fuera actual/pasado. Elegir3 próximas programa tres futuras y muestra nuevo final. Cambiar solo título/responsable/columna conserva restante; no reinicia contador.
- **Q57 · Creador de referencia:** nuevas ocurrencias automáticas usan creador de serie mientras conserve acceso; tarjeta original conserva creador original. Comentario avisa a creador/responsable elegibles, sin autoavisos/duplicados. Si creador sale, no sustituirlo por propietario.
- **Q58 · Rearme:** avisar por nuevo cruce de umbral solo después de haber bajado de él y transcurrido 24 h desde aviso anterior, por persona/umbral. Seguir encima al día siguiente no crea recordatorio ni aviso diferido. Carga bloqueada siempre informa inmediatamente.
- **Q59 · Ubicaciones:** enlaces clickeables al visualizar descripción/comentarios/pasos. Título compacto sigue abriendo detalle; URL de título abrible allí mediante control distinguible de editar.
- **Q60 · Detección/apertura:** HTTP/HTTPS y www.; www. abre HTTPS. Dominio suelto queda texto, excluir puntuación exterior y conservar original. Apertura explícita externa segura sin HTML/esquemas activos/locales, descargas ni previews automáticas.

Creación muestra N total con actual incluida; edición explícita del final muestra N próximas y nuevo final. Criterios C111-AC55–60 todavía sin ejecutar.

## C-112 — UI-09/UI-10

UI-10 añade «Incluir historial de repeticiones», apagado por defecto, independiente de completadas y guardable en vistas; resultados reemplazados muestran estado, fecha y origen; selección abre ocurrencia/comentario preciso sin reabrir. Limpiar/Reiniciar y variantes de vista siguen CF-14.3. UI-09 confirma que volver a programar crea nueva serie con misma tarjeta como primera, conserva anterior detenida/historial y explica independencia frente a su borrado/restauración (CF-08.1).
