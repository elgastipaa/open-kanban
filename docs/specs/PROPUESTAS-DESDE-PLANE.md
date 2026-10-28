# Incorporaciones de Plane a la spec de OpenKanban

Fecha de aceptación: 24 de octubre de 2026. Consolidación: 25 de octubre de 2026. Estado: **las 33 propuestas P01–P26 y E01–E07 están aprobadas e incorporadas a la spec actual por C-99; sin autorización de implementación**.

Esta tabla complementa el [análisis de base](C:/Users/gasto/Documents/GitHub/open-kanban/docs/research/PLANE-VS-OPEN-KANBAN-2026-10-24.md). La recomendación sigue siendo evolucionar OpenKanban con su stack y su experiencia personal. El objetivo aquí es identificar cambios concretos del contrato, no comparar catálogos ni reconstruir Plane.

## Lectura y estado aprobado

Se incorporan **26 P: 22 precisiones/consolidaciones y 4 funciones nuevas**, más **las 7 E**, al MVP objetivo. Las cuatro nuevas P son enlace privado a tarea, español coherente, tableros favoritos y atajo de búsqueda. El usuario aceptó «todas las P y todas las E»; E conserva su identificador histórico, pero ya no significa backlog ni una entrega fuera del MVP. Aprobación registrada en [C-99](./0001-auth-collaboration.md); contrato integrado en [MVP §16](./MVP-1.0.md#16-incorporaciones-desde-plane--aprobadas-c-99).

- **Precisión:** fortalece un acuerdo previo o adopta un candidato presentado. C-99 aprueba el cambio descrito, sin convertir cada fila en una función nueva.
- **Nueva:** función añadida mediante C-99 a la primera versión.
- **E:** originalmente planteada como evolución posterior, ahora incluida por decisión explícita. Los detalles aún no definidos se cierran dentro del mismo alcance; no condicionan su inclusión a otra aprobación o al resultado del piloto.
- **Esfuerzo bajo/medio/alto:** estimación relativa del trabajo completo, no de cambiar la spec. Alto suele significar dominio, permisos, concurrencia o varias superficies; no equivale a plazo o presupuesto calculado.

No hay 33 funciones nuevas. Muchas filas fortalecen garantías que ya decidimos. La prioridad práctica es cerrar privacidad, consistencia y recorrido móvil; las comodidades nuevas no deben retrasar esos cimientos.

## Cómo se contrastó

El contraste original tomó C-01–98 como autoridad, diferenciándolos de los candidatos en MVP, Cierre, Pantallas y Estados y errores. C-99 aprueba después los deltas de estas tablas; las columnas de situación previa conservan ese punto de comparación. Se revisaron el código actual de OpenKanban, el informe anterior, componentes/modelos/pruebas concretos del clon de Plane y documentación oficial. Plane se mantiene en el commit `d9726d5c9615756135f3d6cd512ece8e2dd42902`; OpenKanban en HEAD `46c94139bac67aaca1d491b29afc3bc999fc288f` más la spec local.

La investigación es estática. No se ejecutaron las apps ni se observó a usuarios; «beneficio» expresa una hipótesis de diseño que hay que validar. Cuando la propuesta mejora o limita un patrón de Plane, se indica: no se le atribuyen garantías que el código inspeccionado no demuestra. La documentación comercial no prueba disponibilidad en Community.

## Contraste de partida, anterior a C-99

| Capa | Hoy en el código | Ya definido en la spec | Qué aporta esta revisión |
| --- | --- | --- | --- |
| Tablero | Columnas, tareas, prioridades, descripción, arrastre, móvil de una columna. | Completado independiente, responsables, fechas, detalle único, preferencias. | Jerarquía visual, captura, navegación y escenarios de verificación. |
| Comunidad | Acceso anónimo por URL; sin propietarios ni membresías. | Google, habilitación global, tableros privados, roles e invitaciones cerradas. | Matriz técnica verificable; favoritos y enlaces privados como nuevas comodidades. |
| Colaboración | Broadcast/Presence y refresco; sin conversación implementada. | Checklist, comentarios, menciones, novedades y archivos limitados. | Contratos de escritura, reintentos, ciclo de archivos y poco ruido. |
| Tiempo | Sin series ni completado en Task. | Calendario fijo, una pendiente vigente, anticipación, cumpleaños y excepciones. | Ejecución/reconciliación verificables; no reutilizar un motor CE no encontrado. |
| Confianza | RPC endurecidas para el modelo anónimo; JSON v1 no atómico. | Conflictos, siete días de recuperación, importación protegida y revocación. | Diseño de operaciones, pruebas, respaldo y mantenimiento. |
| Lenguaje visual | UI oscura negro/blanco/amarillo; textos ingleses, fechas en-US. | Conservar base visual; copy español en documentos no equivale a traducción aprobada. | Español como propuesta nueva; claridad/accesibilidad ahora, temas después. |

Evidencia OpenKanban: [tipos](C:/Users/gasto/Documents/GitHub/open-kanban/src/lib/types.ts), [alta rápida](C:/Users/gasto/Documents/GitHub/open-kanban/src/components/board/add-task.tsx), [tarjeta](C:/Users/gasto/Documents/GitHub/open-kanban/src/components/board/task-card.tsx), [móvil](C:/Users/gasto/Documents/GitHub/open-kanban/src/components/board/mobile-board.tsx), [modal](C:/Users/gasto/Documents/GitHub/open-kanban/src/components/ui/modal.tsx), [realtime](C:/Users/gasto/Documents/GitHub/open-kanban/src/hooks/use-realtime.ts), [importación](C:/Users/gasto/Documents/GitHub/open-kanban/src/lib/import.ts), [tokens](C:/Users/gasto/Documents/GitHub/open-kanban/src/app/globals.css), [atajos](C:/Users/gasto/Documents/GitHub/open-kanban/src/lib/constants.ts).

## Tabla P: incorporaciones aprobadas a la spec actual

| ID / área | Código y spec antes de C-99 | Cambio aprobado en la spec | Beneficio e impacto | Base |
| --- | --- | --- | --- | --- |
| **P01 · Conceptos y datos** (Precisión) | Código: Board/Column/Task. Spec: C-10, C-30, C-34 ya separan completado, vistas y serie. | Consolidar un contrato único de tarea: identidad estable compartida por tablero, Mis tareas, búsqueda y novedades. Columna, completado y programación son dimensiones independientes; no crear copias para cada vista. | Evita inconsistencias al actuar desde lugares distintos. **Esfuerzo:** Medio; parte del modelo pendiente. | [S01](#s01) |
| **P02 · Captura rápida** (Precisión) | Código: AddTask envía al perder foco y limpia/cierra sin esperar. C-87 y C-95 ya exigen captura sencilla y guardado veraz. | Crear con Enter o botón explícito; perder foco no envía. Tras éxito, dejar captura lista para la siguiente tarea en la misma columna; mantener título al fallar y reconciliar resultados inciertos antes de repetir. Sin alta por lotes ni campos obligatorios adicionales. | Anotar varias cosas con pocos pasos, sin perder texto ni altas accidentales. **Esfuerzo:** Bajo en UI; depende de P18. | [S02](#s02) |
| **P03 · Detalle progresivo** (Precisión) | Código: modal simple. C-85/C-88–91 y UI-05 ya definen detalle único y Guardar. | Consolidar la jerarquía de UI-05: título y acciones principales, campos cotidianos, luego pasos/archivos/conversación. Bloques opcionales vacíos con acción breve para añadirlos. Un único detalle adaptado al tamaño; ningún selector adicional de modos de apertura. | Una tarea sencilla sigue siendo sencilla al crecer la aplicación. **Esfuerzo:** Bajo/medio de diseño, dentro del alcance existente. | [S03](#s03) |
| **P04 · Tarjeta y jerarquía visual** (Precisión) | Código: título, descripción, prioridad y fecha de creación. UI-04 ya propone responsable, vencimiento y progreso. | Definir tarjeta estable: título, casilla cuando corresponde, responsable, vencimiento, prioridad y progreso si existen; descripción breve secundaria. Creación/autoría quedan en detalle. Separar abrir, completar y mover; no añadir selectores de todas las propiedades a cada tarjeta. | Permite reconocer qué toca y a quién sin abrir cada tarea. **Esfuerzo:** Bajo/medio; usa datos ya previstos. | [S04](#s04) |
| **P05 · Búsqueda y filtros** (Precisión) | Código: sin búsqueda global. C-52/C-78 la incluyen; CF-14 y Pantallas §2.4 contienen detalles candidatos. | Cerrar filtros con alcance visible, chips eliminables y Limpiar. Atajos de filtro Hoy/Vencidas/Próximos 7 días/Sin fecha reutilizan la misma búsqueda. Proponer Próximos desde mañana hasta hoy+7 en la zona de cada tablero; mostrar fecha/tablero cuando el alcance sea global. No introducir un lenguaje de consultas. | Facilita decidir qué atender y entender por qué falta una tarea. **Esfuerzo:** Medio; principalmente precisión de la búsqueda acordada. | [S04](#s04) |
| **P06 · Preferencias personales** (Precisión) | C-26/C-70 aprobados. CF-13 propone guardar por usuario y vista/tablero, aún sin implementación. | Adoptar ese alcance: orden, filtros y completadas por persona y contexto, sincronizados entre sus dispositivos. Definir defaults y reinicio explícito; mantener posición de scroll/columna como estado de navegación, no como configuración compartida. | Cada persona adapta su trabajo sin desordenar el del resto. **Esfuerzo:** Medio; persistencia y conflictos de preferencias. | [S05](#s05) |
| **P07 · Navegación y continuidad** (Precisión) | Código: tablero por slug y modal. C-84–91 y Pantallas §2.6 ya contienen regreso al contexto. | Cerrar la tabla de orígenes y retornos: tablero/Mis tareas/búsqueda/novedad → mismo detalle → mismo filtro, columna y posición. Atrás cierra la capa prevista y respeta borradores. Entrada directa sin origen vuelve al tablero autorizado. | Evita perderse al saltar entre una tarea y el trabajo que se estaba revisando. **Esfuerzo:** Medio; historial del navegador y capas. | [S03](#s03) |
| **P08 · Sistema visual y accesibilidad** (Precisión) | Código: tokens y componentes propios. C-86 y Pantallas §2.7/§4 ya piden teclado, foco y movimiento reducido. | Unificar controles y estados de foco/carga/error/destructivo, manteniendo identidad negro/blanco/amarillo. Extender reglas de accesibilidad a tarjeta, detalle, filtros y menús; botones con nombre, acciones táctiles sin hover obligatorio y alternativa a arrastrar. No incorporar el design system completo de Plane. | Reduce aprendizaje, errores y diferencias entre pantallas. **Esfuerzo:** Medio; revisión de componentes existentes. | [S06](#s06) |
| **P09 · Móvil comprobable** (Precisión) | Código: una columna activa y controles móviles. C-91 ya pide detalle a pantalla disponible sin scroll horizontal. | Añadir matriz de prueba a 360/390 px y escritorio, con teclado virtual, orientación y navegación Atrás. Tarea, asignación, comentarios y Programar deben poder operarse sin arrastre preciso; llegada de cambios remotos no roba foco ni cambia columna activa. | Convierte «funciona en móvil» en recorridos verificables. **Esfuerzo:** Medio; validación y ajustes, sin app nativa. | [S03](#s03) + adaptación propia |
| **P10 · Vacíos, carga y errores** (Precisión) | Hay skeleton/banner y toasts. C-95/C-96 y UI-03/UI-04 distinguen varios estados. | Matriz común de sin tableros, sin columnas, sin tareas, sin resultados, cargando, error local y acceso perdido. Cada estado explica una acción válida. Mantener contenido autorizado durante una recarga; un error no se presenta como una lista vacía. | Ayuda al primer uso y evita creer que se perdió información. **Esfuerzo:** Bajo/medio; copy y estados de consulta. | [S07](#s07) |
| **P11 · Enlace privado a tarea** (Nueva) | Código: URL de tablero. Pantallas §2.6 contempla acceso directo, pero no especifica acción Copiar enlace. | Añadir Copiar enlace en detalle para la tarea u ocurrencia concreta, con identidad estable. Login recupera destino solo después de autorizarlo. El enlace no invita, no concede acceso y no expone título en una previsualización pública; renombrar el tablero no debe invalidarlo. | Permite referirse a algo concreto por el canal que ya usan los amigos. **Esfuerzo:** Bajo/medio; depende de rutas y autorización. | [S08](#s08) |
| **P12 · Español y fechas** (Nueva) | Código: textos ingleses y fechas en-US. Pantallas aclara que su copy español no autoriza traducir toda la app. | Definir español como idioma inicial del producto y centralizar textos/formatos para evitar mezcla. Fechas legibles y no ambiguas; día de vencimiento estable, zona del tablero visible al programar. No añadir ahora selector multidioma, traducción automática ni modificar el contenido escrito por usuarios. | Reduce esfuerzo para la comunidad inicial y errores con fechas. **Esfuerzo:** Medio; abarca pantallas, errores y accesibilidad. | [S09](#s09) |
| **P13 · Tableros favoritos** (Nueva) | Sin cuenta/listado de tableros aún. La spec define Tableros, pero no favoritos. | Permitir estrella personal en cada tablero y sección Favoritos dentro del listado Tableros. Solo tableros, sin carpetas ni nuevas entradas del drawer. No altera propiedad/orden de otros y se retira del listado al perder acceso. | Vuelve rápido a los espacios de uso diario sin una navegación más compleja. **Esfuerzo:** Bajo/medio; preferencia por usuario. | [S10](#s10) |
| **P14 · Atajo de búsqueda** (Nueva) | Existen atajos de tablero. La búsqueda visible está acordada, Ctrl/Cmd+K no. | Ctrl/Cmd+K abre la búsqueda existente conservando el alcance inicial del contexto; botón visible sigue disponible. Deshabilitar atajo global al escribir y mostrarlo en ayuda. No sumar una paleta con crear/borrar/cambiar configuraciones. | Acelera escritorio sin agregar otra pantalla o lógica de búsqueda. **Esfuerzo:** Bajo; depende de P05. | [S11](#s11) |
| **P15 · Novedades con poco ruido** (Precisión) | No implementadas. C-56/C-78/C-83 y CF-15 ya definen eventos, deduplicación y 90 días. | Cerrar ciclo de lectura y destino: verificar acceso antes de marcar leída; abrir el detalle autorizado; si el contenido ya no existe, explicar sin restaurarlo. Dedupe por evento/destinatario, no por texto. Resolver explícitamente el candidato de menciones nuevas al editar y no reavisar por quitar/agregar la misma mención. | La bandeja representa atención útil y no una deuda de notificaciones. **Esfuerzo:** Medio; dentro de colaboración prevista. | [S12](#s12) |
| **P16 · Permisos comprobables** (Precisión) | Código: RPC anónimas por slug. Matriz y C-93/C-94 ya exigen acceso privado. | Traducir cada permiso a casos de servidor, consulta, canal y archivo con dos tableros y varios actores. Incluir admin no miembro, retirado, no habilitado y acceso por identificador manipulado. Una URL, autoría o asignación no sustituyen membresía. | Impide que una función secundaria filtre datos aunque el tablero principal esté protegido. **Esfuerzo:** Alto; trabajo obligatorio del corte privado. | [S13](#s13) |
| **P17 · Operaciones e integridad** (Precisión) | Hay RPC y validaciones de pertenencia. Falta el dominio privado; matriz ya prohíbe cambiar autores, roles y tablero por atajos. | Contratos por acción y listas explícitas de campos editables; separar editar, completar, mover, transferir, invitar, borrar y restaurar. El servidor resuelve autoría/rol y valida todas las referencias. Rechazar campos protegidos en escrituras, sin aceptar un objeto completo como autoridad. | Evita escaladas de permisos y cambios laterales no visibles en la UI. **Esfuerzo:** Medio/alto; diseño de mutaciones. | [S14](#s14) |
| **P18 · Concurrencia y reintentos** (Precisión) | Código: optimismo y refresco, sin versión de edición del usuario. C-68/C-95 definen conflicto y resultado incierto. | Diseñar precondiciones de versión para campos editables y clave de operación para reconciliar reintentos. Separar comentarios/pasos/archivos de la versión de esos campos. La UI optimista distingue pendiente de confirmado; completar envía estado deseado, no invertir. | Evita pérdidas de cambios y duplicados con dos personas o mala señal. **Esfuerzo:** Alto; transversal. | [S15](#s15) · contraste |
| **P19 · Trabajo de fondo confiable** (Precisión) | No hay motor de series/avisos. MVP §9.3/§11 y Cierre H requieren elegir mecanismo. | Separar escritura confirmada de avisos, activaciones y purgas; registrar de forma durable trabajo pendiente junto al cambio cuando corresponda. Procesamiento reintentable y deduplicado, con reconciliación tras inactividad. Elegir mecanismo proporcional en nuestro stack; no fijar Celery/RabbitMQ ni prometer ejecución exactamente una vez. | Una caída no pierde avisos ni genera ocurrencias o consumos duplicados. **Esfuerzo:** Alto; scheduler/hosting pendientes de validar. | [S16](#s16) + adaptación propia |
| **P20 · Realtime y estado privado** (Precisión) | Broadcast provoca getFullBoard; Presence público por slug. C-57/C-95 exigen retirada de contenido al perder acceso. | Tratar realtime como señal para reconciliar con datos autorizados, no como permiso ni fuente única de verdad. Autorizar canales, revalidar al reconectar/cambiar cuenta y descartar datos/respuestas de una sesión anterior. Actualizar vistas sin pisar borradores. | La colaboración sigue siendo correcta después de cortes o revocaciones. **Esfuerzo:** Alto; acceso, caché y UX coordinados. | [S05](#s05) / [S13](#s13) · contraste |
| **P21 · Recuperación como dominio** (Precisión) | Borrado actual sin nuestra papelera. C-58/C-76/C-94/C-98 ya acordaron recuperación, actores y límites. | Definir causa, actor, plazo y dependencias de cada borrado; consultas y restauraciones autorizadas; purga coordinada con restauración y cuota. Recuperar no reactiva membresías, invitaciones ni hijos borrados por separado. No basta un deleted_at. | Hace real y coherente la promesa de siete días. **Esfuerzo:** Alto; dependencias y carreras. | [S17](#s17) · contraste |
| **P22 · Archivos y cuotas** (Precisión) | Sin adjuntos. C-61/C-64/C-82 y CF-16 ya definen límites; reserva y reconciliación son candidatos. | Cerrar ciclo reservar → cargar → verificar → publicar, con liberación de reservas fallidas y reconciliación de objetos. Contar activos, recuperables y reservas; comprobar contenido y permiso al confirmar. Adoptar unidades decimales propuestas: 24.000 bytes y 200.000.000 globales; 20 archivos incluidos recuperables. | Evita archivos fantasma y exceder límites con cargas simultáneas. **Esfuerzo:** Alto; Storage y DB coordinados. | [S18](#s18) |
| **P23 · Consultas y crecimiento** (Precisión) | Carga/refresca tablero completo. MVP §11 pide presupuesto de consultas, sin cifras verificadas. | Separar resumen de tarjeta de comentarios/adjuntos/historial cargados al abrir; paginar listas globales y conversaciones con orden estable y filtros en servidor. Contadores autorizados y exportación completa aunque la pantalla esté paginada. Para tablero, diseñar carga parcial y reordenamiento juntos antes de paginar a ciegas. | Mantiene respuesta y consumo razonables al crecer los tableros. **Esfuerzo:** Medio/alto; diseño y medición. | [S19](#s19) |
| **P24 · Portabilidad y respaldo** (Precisión) | JSON v1 con reemplazo en varias solicitudes. C-92 y CF-19 ya exigen importación protegida. | Separar respaldo portable por tablero de recuperación operativa de toda la instancia. Formato versionado, compatibilidad v1, preparación/validación y publicación controlada; respaldo operativo de base/objetos/configuración y ensayo de restauración fuera de producción. | Control de datos comprobable y salida del proveedor sin pérdida silenciosa. **Esfuerzo:** Alto; ya parte de la confianza acordada. | [S20](#s20) |
| **P25 · Operación y mantenimiento** (Precisión) | Versiones fijadas y validación básica ya existen; funciones nuevas aún sin operación definida. | Completar controles de versión/migraciones/dependencias y diagnósticos mínimos de fallos, trabajos pendientes, purgas y cuotas. Mensajes públicos sin trazas; registros operativos sin cuerpos privados/tokens. Documentar procedimiento de actualización, recuperación y licencia/origen de código reutilizado; sin nueva pantalla de métricas ni proveedor de telemetría por defecto. | Permite sostener la herramienta cuando la comunidad dependa de ella. **Esfuerzo:** Medio; proceso operativo. | [S13](#s13) / [S16](#s16) / [S20](#s20) |
| **P26 · Calidad del producto** (Precisión) | La spec tiene AC/NAV/PERM/ERR/BACKUP y propósito personal; no son pruebas ejecutadas. | Trazar reglas → escenarios → evidencia, y sumar validación de cinco recorridos: capturar, encontrar, completar, coordinar y retomar rutina. Observar con personas del piloto; registrar tropiezos y pasos, sin analítica externa ni puntajes de productividad. Separar pruebas automáticas de comportamiento de evaluación de facilidad de uso. | Mide si ayuda a organizar la vida, además de si el software responde. **Esfuerzo:** Medio; criterio de aceptación y piloto. | [S13](#s13) + adaptación propia |

## Tabla E: incorporaciones aprobadas al mismo MVP

| ID / área | Situación antes de C-99 | Incorporación aprobada | Beneficio e impacto | Base |
| --- | --- | --- | --- | --- |
| **E01 · Etiquetas simples** | No incluidas; columnas y prioridad ya organizan. | Etiquetas opcionales del tablero, planas, con nombre/color y filtro. Sin jerarquía ni catálogo global; no reemplazan columna, responsable o prioridad. | Agrupar compras, trámites o ideas dentro del mismo flujo. **Esfuerzo:** Medio; datos, permisos, filtros, import/export. | [S21](#s21) |
| **E02 · Vistas personales guardadas** | C-70 recuerda preferencias; CF-14 excluye vistas compartidas guardadas nuevas. | Guardar con nombre un conjunto de filtros/orden personales sobre datos existentes. Reutilizar buscador/Mis tareas; sin nuevas tareas ni vistas públicas/compartidas. | Volver a consultas repetidas sin armarlas cada vez. **Esfuerzo:** Medio; modelo y gestión de vistas. | [S22](#s22) |
| **E03 · Tema claro/oscuro/sistema** | Solo oscuro; conservar identidad está acordado. | Preferencia personal con tres opciones, manteniendo marca, contraste y estados. Sin editor de colores ni temas por tablero. Adaptar después de validar P08. | Mejora legibilidad según entorno y preferencia. **Esfuerzo:** Medio; QA de todas las pantallas. | [S23](#s23) |
| **E04 · Duplicar tarea puntual** | Sin duplicación; series y su plantilla ya cubren repetición temporal. | Crear copia en el mismo tablero con título, descripción, prioridad y checklist sin marcar. Sin responsable, fecha, serie, comentarios, archivos ni membresías heredadas; pendiente y nueva identidad. Si el origen es ocurrencia, avisar que se crea tarea puntual. | Reutilizar una estructura ocasional sin crear una recurrencia. **Esfuerzo:** Medio; nuevo contrato de copia. | [S24](#s24) |
| **E05 · Actividad mínima de tarea** | Hay autorías, novedades e historial de ocurrencias; no un historial general de cambios aprobado. | Historial dentro de detalle para cambios de responsable, fecha, columna, completado y recuperación, con actor/fecha. Separado de comentarios y novedades; sin versiones del texto de comentarios ni restaurar valores desde el historial. | Ayuda a entender qué cambió al colaborar. **Esfuerzo:** Medio/alto; privacidad, retención y volumen. | [S25](#s25) |
| **E06 · Instalación PWA** | Móvil web ya existe; no instalación ni offline duradero acordados. | Evaluar acceso instalable desde navegador, icono y apertura consistente con login/enlaces. Mantener contrato online y borradores en sesión; sin prometer push, cola offline ni app nativa. | Facilita volver a la herramienta desde el teléfono. **Esfuerzo:** Medio; compatibilidad y caché privada. | [S26](#s26) |
| **E07 · Marcar novedades visibles como leídas** | Lectura individual y todas/no leídas; lote no aprobado. | Acción explícita sobre novedades actualmente cargadas y autorizadas, con cantidad. No marca futuras, páginas no cargadas ni todas las del servidor por inferencia; no archiva ni pospone. | Reduce gestos al ponerse al día sin esconder avisos no revisados. **Esfuerzo:** Bajo/medio; acción por lote y resultado parcial. | [S12](#s12) |

## Reglas para integrar las propuestas sin crear otra spec paralela

1. [Spec 0001](./0001-auth-collaboration.md) registra la aceptación explícita en C-99. Este anexo conserva los 33 identificadores, el contraste de partida, la evidencia y los criterios aceptados.
2. Las filas se consolidan en MVP, Pantallas, Estados y errores, Matriz de permisos y Cierre según la tabla inferior. El permiso lo define la matriz; la interacción, Pantallas; el error, Estados y errores. No crear contratos divergentes.
3. C-99 cierra los detalles presentados: por ejemplo persistencia de preferencias entre dispositivos, intervalo de próximos siete días, nuevas menciones al editar y unidades decimales de adjuntos. Otros detalles de CF no presentados no quedan aprobados por asociación.
4. P11–P14 ya son alcance aprobado. Conservan autorización por membresía y navegación global acordadas.
5. E01–E07 ya pertenecen al MVP. Completar permisos, límites, retención, exportación y relación con series que las filas no definieron antes de construirlas. Inventario de pendientes reales en MVP §16.5.
6. Modelos y mecanismos técnicos se diseñan en documentos técnicos proporcionados al tamaño del repo. Una recomendación de resultado no selecciona automáticamente una librería, servicio pago o proveedor.

## Destino y aceptación de cada propuesta

Son criterios aceptados con C-99, **no pruebas ejecutadas**. Las decisiones no definidas que cada criterio identifica siguen pendientes de diseño. «500 tareas» y anchos de prueba son fixtures/objetivos de evaluación, no límites comerciales ni capacidad certificada.

| ID | Documento dueño y destino de integración | Criterio de aceptación aprobado |
| --- | --- | --- |
| P01 | CONTEXT; MVP §6.3, §8 y §11. | Completar desde Mis tareas actualiza la misma tarea en el tablero, conserva columna y no altera futuras ocurrencias. |
| P02 | Pantallas UI-04/UI-05; Estados y errores, crear tarea. | Escribir tres títulos seguidos; una falla conserva su texto. Doble envío no duplica y tocar fuera no crea. |
| P03 | Pantallas UI-05. | Una tarea de solo título se puede crear, abrir y completar sin abrir Programar ni añadir pasos; cada acción independiente conserva su contrato. |
| P04 | Pantallas UI-04/UI-05; sistema visual. | Sin fecha no muestra un hueco; vencida se entiende sin depender del color; un cumpleaños no tiene casilla; abrir no completa. |
| P05 | MVP §14.4; CF-14; Pantallas UI-10. | Limpiar devuelve resultados; Hoy y Próximos no se solapan; dos tableros con zonas diferentes se evalúan con sus reglas, sin mover tareas. |
| P06 | CF-13; Pantallas UI-16; contrato técnico. | Ana oculta completadas y Bruno sigue viéndolas. Ana conserva preferencia en otro dispositivo sin modificar el orden manual común. |
| P07 | Pantallas §2.6; NAV-03/NAV-09; UI-05. | Abrir y cerrar desde cada origen conserva contexto; Atrás/Adelante no repiten escrituras ni eluden Guardar/Descartar/Cancelar. |
| P08 | Pantallas §2.7 y §4; nueva subsección de reglas visuales. | Flujo principal completo con teclado; foco retorna al invocador; zoom 200 % y movimiento reducido conservan acciones y textos utilizables. |
| P09 | Pantallas UI-04/UI-05; NAV; aceptación del MVP. | Crear, editar, asignar y comentar con teclado abierto; Guardar/cierre alcanzables; ningún desplazamiento horizontal en detalle. |
| P10 | Pantallas UI-03/UI-04/UI-10/UI-11; Estados y errores. | Fallo de búsqueda ofrece reintentar, cero coincidencias ofrece limpiar, y acceso perdido retira contenido. No se insertan ejemplos ni tutorial obligatorio. |
| P11 | Pantallas UI-05/§2.6; matriz B-01; aceptación nueva. | Miembro abre la misma tarea; ajeno recibe mensaje genérico. Repetición reemplazada abre historial autorizado, no la actual por sustitución silenciosa. |
| P12 | MVP §1/§6; Pantallas transversal; glosario y copy. | Login, detalle, errores y nombres accesibles están en español; el mismo vencimiento conserva su día entre dispositivos en distintas zonas. |
| P13 | Pantallas UI-03; preferencias; matriz G-10. | Favorito de Ana no aparece como favorito de Bruno; tras revocación no queda nombre ni acceso en Favoritos. |
| P14 | Pantallas UI-10/§4; catálogo de atajos. | Teclado y botón abren el mismo buscador; no captura escritura ni altera texto del editor; móvil funciona sin atajos. |
| P15 | CF-15; MVP §14.5; Pantallas UI-11. | Una misma acción con varios motivos produce un aviso por persona; reintento no duplica; aviso vencido no borra comentario ni tarea. |
| P16 | Matriz completa; spec 0001 seguridad/transición; suite de aceptación. | Consultas, búsqueda, exportación, adjuntos y novedades rechazan cruces de tablero y no revelan conteos/títulos al actor ajeno. |
| P17 | MVP §11; matriz B/F/A; contratos de API/RPC. | Un PATCH con owner_id/board_id/autor falsos no modifica nada; dos usuarios no consumen la misma invitación ni dejan dos propietarios. |
| P18 | Estados y errores §2/§4/§5; MVP §11. | Dos ediciones incompatibles conservan ambos textos y exigen revisar; repetir operación tras timeout recupera su resultado sin duplicar efectos. |
| P19 | MVP §8/§9/§11; Cierre H; diseño técnico. | Simular caída entre guardar y procesar, repetir ejecución y volver tras una semana: un pendiente vigente, ningún completado ficticio y exclusiones conservadas. |
| P20 | Spec 0001 realtime; Estados y errores; matriz transversal. | Revocar mientras hay detalle abierto y luego reconectar: no reaparecen tarjetas, resultados ni borradores privados de la cuenta anterior. |
| P21 | Matriz §5; CF-12; Pantallas UI-14; modelo técnico. | Restaurar padre conserva el borrado independiente del hijo; moderación respeta actor; restaurar/purgar simultáneamente no publica contenido parcial. |
| P22 | MVP §14.3; CF-16/17; matriz F. | Dos cargas compiten por último cupo y solo una confirma; borrar no libera antes de purga; binario renombrado se rechaza. Denegar nuevas descargas tras revocar y documentar duración/residuo de enlaces temporales emitidos antes, sin prometer retirar copias descargadas. |
| P23 | MVP §11; UI-04/UI-08/UI-10; BACKUP-01. | Dataset ficticio de 500 tareas no carga todas sus conversaciones para mostrar tarjetas; paginar no omite/duplica resultados en un conjunto estable y exportar no trunca. |
| P24 | CF-19/20; BACKUP; operación del proyecto. | Exportar/importar conserva alcance sin permisos reutilizables; falla previa mantiene tablero original; restaurar instancia de prueba recupera también archivos. |
| P25 | Cierre H; docs/VALIDATION y operación futura; política de contribución. | Fallo simulado se puede diagnosticar por referencia/estado sin leer tareas ajenas; migración fallida tiene recuperación ensayada. Mantener auditoría de dependencias existente. |
| P26 | MVP §1/§10/§13; matriz final de aceptación. | Personas del piloto pueden completar recorridos sin intervención del autor; cualquier bloqueo de privacidad, pérdida o calendario impide declarar listo el MVP. |
| E01 | MVP §16.3; Pantallas; matriz; modelo. | Asignar/quitar etiqueta no mueve ni completa; miembros de otro tablero no ven su catálogo. Dentro del alcance aprobado, cerrar permisos, borrado y herencia en series antes de implementar. |
| E02 | MVP §16.3; UI-08/UI-10 y preferencias. | «Esta semana» recalcula fechas relativas al abrir; nunca conserva resultados de un tablero revocado. No confundir con recordar el último filtro. |
| E03 | MVP §16.3; UI-16 y tokens. | Cambiar tema no recarga ni pierde el editor; prioridades/foco/errores se distinguen en ambos modos. |
| E04 | MVP §16.3; UI-05/modelo/exportación. | Copiar no cambia origen ni dispara asignaciones históricas; pasos reiniciados y ningún archivo privado duplicado. |
| E05 | MVP §16.3; UI-05 y retención. | Un reintento no duplica evento y actor sin permiso no ve historia. Retención concreta y efecto de borrado deben cerrarse antes de implementar; la función ya está incluida. |
| E06 | MVP §16.3; Pantallas y contrato de instalación. | Probar instalar/abrir/cerrar sesión/cambiar cuenta en dispositivos reales; un cache no muestra contenido de otra cuenta. Manifest solo no basta. |
| E07 | MVP §14.5/§16.3; UI-11. | Al cargar 20 de 80 solo esas 20 cambian; novedades llegadas durante la acción quedan sin leer y fallos parciales se explican. |

## Qué evitaría copiar

| Patrón/capacidad | Motivo aplicado a nuestra spec |
| --- | --- |
| Workspaces + proyectos como entidades nuevas para el usuario | Nuestra unidad es el tablero. Una capa adicional requiere valor demostrado, no similitud con Plane. |
| Estados que determinan automáticamente el completado | Contradice C-10/C-27/C-31. «Casa» puede contener pendientes y hechas. |
| Varios responsables por tarea | C-06 define cero o uno. Evitar diluir responsabilidad por copiar la relación many-to-many. |
| Autoguardado global y borrado temprano del campo de alta | C-88/C-95 requieren Guardar para campos y conservar borrador cuando falla; checklist/comentarios/archivos sí son independientes. |
| Todas las propiedades visibles, varios modos de detalle y paleta de comandos completa | Añaden decisiones y ruido a tareas simples. Conservar un detalle y búsqueda compartidos. |
| Sidebar permanente, barra inferior, onboarding obligatorio o tablero de ejemplo automático | La navegación y primer uso ya están decididos en C-84–86/C-96. Revisarlos solo con nueva evidencia, no por imitación. |
| Subtareas completas como sustituto de checklist | Los pasos no tienen responsables/fechas propios y su completado no completa la tarea. |
| Wiki, cycles, modules, Gantt, epics, estimaciones, dependencias, automatizaciones genéricas, IA | No resuelven un hueco demostrado del recorrido personal inicial; elevan alcance y conceptos. No se niega su posible valor futuro. |
| Todo el stack y design system de Plane | Next/Supabase y componentes actuales permiten adaptar patrones; no se acreditó necesidad de Django, MobX, Celery, RabbitMQ o Yjs. |
| Soft delete como recuperación lista | La restauración general encontrada está vacía; nuestro dominio exige causa, actor, plazo y dependencias. |
| Aplicación móvil oficial o recurrencias comerciales como código CE reutilizable | El análisis anterior verificó límites de edición. No forman parte del ahorro de clonar Community. |
| Historial íntegro de texto borrado/moderado | Podría eludir nuestra privacidad y recuperación. E05 excluye versiones de comentarios; hay que diseñar retención. |
| Push, correo, calendario externo o sincronización offline implícitos | La spec los deja fuera de la primera versión o para evaluación separada. PWA no los incorpora automáticamente. |
| Métricas de productividad o telemetría externa por defecto | La validación propuesta observa facilidad y confianza, sin nuevas fuentes de datos ni ranking de usuarios. |

## Orden de diseño y construcción posterior del alcance aprobado

- **Cimientos:** P01 y P16–P25. Cierran contratos de datos, acceso, consistencia y operación, con diseño técnico proporcionado al repo. Son necesarios aunque la UI sea sencilla.
- **Recorrido cotidiano:** P02–P10 y P15. Reducen fricción sin modificar el alcance principal aprobado; consolidar candidatos existentes y completar criterios.
- **Mejoras nuevas acotadas:** P11/P12 por comunicación concreta y comprensión; P13/P14 sobre listado y búsqueda. Las cuatro son obligatorias dentro del alcance aprobado, con orden de trabajo ajustable.
- **Validación:** P26 atraviesa las entregas. Una regla importante no se considera cumplida porque exista una tabla o un test pendiente.
- **Incorporaciones E:** E01 después de fijar modelo/permisos; E02 sobre P05/P06; E03 sobre P08; E04 sobre P01/P18; E05 sobre P17–P21; E06 sobre acceso/rutas/estado privado; E07 sobre P15/P18. Son dependencias dentro del mismo MVP, no condiciones para posponerlas fuera de él.

## Fuentes verificadas y límites de lo aprendido

Los enlaces de código están fijados al commit inspeccionado. Se adaptan patrones y pruebas; no se propone copiar código/licencias/estilos literalmente. Si luego se decide reutilización literal, se revisan origen y términos según el [informe de licencia anterior](C:/Users/gasto/Documents/GitHub/open-kanban/docs/research/PLANE-VS-OPEN-KANBAN-2026-10-24.md).

<a id="s01"></a>

**S01 — [Identidad de tarea y estados](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/issue.py)**. Modelo Issue; separar nuestra columna de su state. También aplica al aprendizaje por contraste de P18.

<a id="s02"></a>

**S02 — [Captura rápida](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/components/issues/issue-layouts/quick-add/root.tsx)**. Alta por título y estado de envío. Atención: reset se ejecuta antes de esperar la creación; no copiarlo como garantía de conservación de borrador.

<a id="s03"></a>

**S03 — [Detalle de tarea](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/components/issues/peek-overview/issue-detail.tsx)**. Componentes, propiedades y estados del detalle. Su editor/autoguardado no reemplazan nuestro Guardar explícito.

<a id="s04"></a>

**S04 — [Filtros y propiedades de presentación](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/view.py)**. Definición de filtros/orden/propiedades. No trasladar a nuestra UI todos sus campos.

<a id="s05"></a>

**S05 — [Preferencias por usuario/proyecto](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/project.py)**. ProjectUserProperty, desde línea 392; demuestra separación entre configuración individual y entidad compartida.

<a id="s06"></a>

**S06 — [Primitivas y componentes](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/packages/blocks/src/dialog/confirm-dialog.test.tsx)**. Pruebas del componente de confirmación como referencia de disciplina de interacción; no certifican accesibilidad completa de Plane.

<a id="s07"></a>

**S07 — [Estado vacío reutilizable](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/components/empty-state/simple-empty-state-root.tsx)**. Estructura de título/descripción reutilizable. Nuestra matriz de vacíos/errores es adaptación de los contratos existentes.

<a id="s08"></a>

**S08 — [Copiar enlace de tarea](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/components/issues/issue-detail/issue-detail-quick-actions.tsx)**. Acción de copia y enlace a la entidad. Las garantías de identidad estable y acceso son contrato propuesto para OpenKanban.

<a id="s09"></a>

**S09 — [Idiomas centralizados](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/packages/i18n/src/constants/language.ts)**. Catálogo que incluye español. Tomar organización de textos; no sus traducciones literales ni todos sus idiomas.

<a id="s10"></a>

**S10 — [Favoritos personales](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/favorite.py)**. UserFavorite. Proponemos solo tableros y sin su jerarquía de carpetas.

<a id="s11"></a>

**S11 — [Atajo de búsqueda/comandos](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/components/power-k/core/shortcut-handler.ts)**. Manejo Ctrl/Cmd+K. Propuesta limitada a nuestro buscador existente, no Power K completo.

<a id="s12"></a>

**S12 — [Novedades e inbox](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/components/workspace-notifications/root.tsx)**. UI de novedades. Reglas de destinatarios/retención de OpenKanban siguen siendo propias.

<a id="s13"></a>

**S13 — [Pruebas de autorización](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/tests/contract/app/test_project_member_is_active_authz.py)**. Pruebas de regresión sobre rol y actividad; complementar con tests de alcance de búsqueda, archivos y exportación.

<a id="s14"></a>

**S14 — [Campos de solo lectura](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/tests/contract/app/test_issue_read_only_fields_app.py)**. Verifica campos que PATCH no debe alterar. Plane los ignora; proponemos rechazo explícito para nuestro contrato, a definir técnicamente.

<a id="s15"></a>

**S15 — [Mutación de campos de tarea](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/app/views/issue/base.py)**. partial_update desde línea 629. No se observó allí precondición de versión aportada por cliente. Yjs/ChangeTracker no prueban nuestro control de conflicto de campos.

<a id="s16"></a>

**S16 — [Trabajo de fondo](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/celery.py)**. Plane separa procesos de fondo. La bandeja durable de operaciones y garantías de reintento aquí propuestas son diseño nuestro, no una garantía acreditada de Plane.

<a id="s17"></a>

**S17 — [Borrado y restauración](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/bgtasks/deletion_task.py)**. Borrado diferido y purga; restore_related_objects vacío. No adoptar soft delete como si incluyera la recuperación acordada.

<a id="s18"></a>

**S18 — [Ciclo del archivo](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/asset.py)**. Distingue metadata, tamaño e is_uploaded. No demuestra nuestra reserva atómica ni cuotas; esas reglas se diseñan para OpenKanban.

<a id="s19"></a>

**S19 — [Consultas agrupadas paginadas](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/utils/paginator.py)**. Referencia para paginación; estrategia exacta y consumo deben medirse en nuestro esquema.

<a id="s20"></a>

**S20 — [Backup de Community](https://developers.plane.so/self-hosting/manage/backup-restore)**. Documentación oficial de respaldo de instancia; distinto de importar un tablero con C-92.

<a id="s21"></a>

**S21 — [Etiquetas](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/label.py)**. Modelo presente en CE; nuestra propuesta futura elimina jerarquía y alcance global.

<a id="s22"></a>

**S22 — [Vistas guardadas](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/view.py)**. IssueView. Nuestra variante futura sería exclusivamente personal; no reabre vistas compartidas excluidas en CF-14.

<a id="s23"></a>

**S23 — [Apariencia](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/components/appearance/theme-switcher.tsx)**. Preferencias de tema. No copiar la recarga que ejecuta el componente; nuestra propuesta debe conservar edición.

<a id="s24"></a>

**S24 — [Copia de tareas (documentación de producto)](https://docs.plane.so/work-items/create-and-manage-work-items)**. Referencia conceptual documentada; no se auditó en este turno la disponibilidad de cada variante de copia en CE. Propuesta propia mucho más limitada.

<a id="s25"></a>

**S25 — [Actividad de tarea](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/issue.py)**. IssueActivity y componentes issue-activity. No equivale a nuestro historial de ocurrencias ni habilita revelar versiones de comentarios moderados.

<a id="s26"></a>

**S26 — [Manifest web](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/public/manifest.json)**. Existe manifest y sw.js en el checkout. No se verificó instalación, registro del service worker, offline o privacidad de cachés; E06 es una evaluación e incorporación aprobada para OpenKanban, cuya compatibilidad todavía debe verificarse.

Como apoyo funcional se consultaron [opciones de visualización](https://docs.plane.so/core-concepts/issues/display-options), [filtros](https://docs.plane.so/core-concepts/issues/visualise_filter), [inbox](https://docs.plane.so/communication-and-collaboration/inbox) y [comentarios/actividad](https://docs.plane.so/communication-and-collaboration/comments-and-activity). Son documentación del producto; las diferencias de edición se mantienen explícitas y sus reglas no se trasladan automáticamente.

## Estado del trabajo

Las 33 filas se incorporaron por C-99 al registro de acuerdos, MVP y documentos dueños; se actualizaron glosario y continuidad. No se implementaron funciones ni se ejecutaron pruebas sobre la app; no se accedió a bases remotas ni se hizo commit/push. Las comprobaciones documentales validan cobertura, estructura y referencias locales, no funcionamiento del producto.
