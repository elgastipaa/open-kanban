## Problem Statement

Las personas necesitan capturar pendientes, mantener rutinas y colaborar desde móvil y computadora sin una metodología obligatoria ni configuración compleja. OpenKanban busca reducir olvidos y facilitar retomar lo importante, con control de instancia/datos para una comunidad de amigos admitidos por su administrador.

La base inspeccionada ofrece tablero, columnas, tareas, descripción, prioridades, movimiento, sincronización y exportación/importación básica. Todavía usa acceso anónimo por URL y no implementa el modelo privado, roles, completado, series ni colaboración ampliada. Asana/Trello/Plane son referencias, sin promesa de paridad de catálogo.

## Solution

Evolucionar la base Next.js/Supabase conservando identidad visual, sin decidir fork ni jerarquía workspaces/proyectos. Tableros es la entrada; cada persona crea/gestiona los propios y comparte con habilitadas. Tarea mínima solo título; responsable, fecha, programación, pasos, conversación, archivos y etiquetas opcionales. Misma tarea en tablero, Mis tareas, búsqueda, novedades, vistas y enlace privado; columna/completado/programación independientes.

Integra C-01–111, todas P01–P26/E01–E07 en el mismo MVP y tres fronteras de prueba aprobadas el 26/10/2026. E no es backlog externo. Fase actual: especificación con pendientes explícitos; no acredita implementación ni autoriza despliegue.

## User Stories

### Acceso y comunidad privada

1. Como persona invitada, quiero entrar con mi cuenta Google, para usar una identidad que ya conozco sin otra contraseña.
2. Como administrador de la aplicación, quiero habilitar o suspender personas por su cuenta Google, para controlar quién utiliza la instancia.
3. Como persona habilitada, quiero crear mis propios tableros privados, para organizar mi vida y colaborar con mis amigos.
4. Como propietario, quiero que conocer una URL no conceda acceso, para mantener el contenido dentro de los miembros autorizados.
5. Como administrador, quiero gestionar admisión y capacidad sin obtener lectura automática de tableros ajenos, para separar operación de privacidad.
6. Como usuario, quiero volver al destino privado solicitado después de entrar, para continuar mi recorrido si tengo permiso.
7. Como usuario, quiero cerrar sesión o cambiar de cuenta sin conservar contenido privado de la anterior, para compartir un dispositivo con confianza.
8. Como persona que llega por invitación, quiero aceptar un tablero sin tener que crear uno propio, para empezar por el trabajo compartido.

### Tableros, miembros y propiedad

9. Como usuario, quiero encontrar tableros propios y compartidos en Tableros, para elegir dónde trabajar.
10. Como propietario, quiero crear un tablero por su nombre y elegir sus columnas, para usar mi propia forma de organizarme.
11. Como miembro, quiero poder trabajar con una sola columna o varias, para adaptar el tablero sin etapas obligatorias.
12. Como propietario, quiero cambiar el nombre y la zona horaria del tablero, para mantener coherente su identidad y calendario.
13. Como propietario, quiero invitar directamente a una persona ya habilitada, para que encuentre su invitación pendiente al entrar.
14. Como propietario, quiero generar un enlace genérico de un uso, revocable y de 72 horas para personas habilitadas, para compartir por el canal que ya utilizamos.
15. Como destinatario, quiero aceptar o rechazar una invitación directa viendo tablero, invitador y rol, para decidir sin acceder aún al contenido.
16. Como propietario, quiero ver una invitación directa pendiente existente y renovar explícitamente una vencida, para no duplicar invitaciones.
17. Como propietario, quiero gestionar miembros y retirar acceso, para mantener el grupo actual de colaboración.
18. Como colaborador, quiero editar las tareas del tablero aunque tengan otro responsable, para ayudar al grupo.
19. Como usuario, quiero distinguir propietario, colaborador y responsable de tarea, para entender permisos y responsabilidades.
20. Como colaborador, quiero salir de un tablero, para dejar de participar sin eliminar el trabajo de los demás.
21. Como propietario que sale, quiero elegir un sucesor elegible, para que el tablero siga teniendo responsable de administración.
22. Como administrador, quiero resolver propiedad incluso de tableros en papelera al retirar una cuenta, para conservar una recuperación válida sin reiniciar sus plazos.
23. Como miembro, quiero que retirar a alguien conserve el trabajo y la autoría, desasignando pendientes y futuras repeticiones, para continuar sin responsables inaccesibles.
24. Como persona que reingresa, quiero recibir permisos actuales explícitos, para no recuperar automáticamente roles, asignaciones o menciones históricas.
25. Como administrador único, quiero protección contra mi autosuspensión accidental, para no dejar la instancia sin administración.

### Captura y trabajo cotidiano

26. Como usuario, quiero capturar una tarea escribiendo solo su título, para anotar algo sin configurar fechas o responsables.
27. Como usuario, quiero crear con Enter o un botón y seguir capturando en la misma columna, para registrar varias tareas con pocos pasos.
28. Como usuario, quiero que tocar fuera del campo no cree la tarea, para evitar altas accidentales.
29. Como usuario, quiero conservar el título si el alta falla y no duplicarlo al reintentar, para confiar en la captura.
30. Como usuario, quiero reconocer título, responsable, vencimiento, prioridad y progreso cuando existan, para entender una tarjeta sin abrirla.
31. Como usuario, quiero abrir un único detalle adaptado al tamaño de pantalla, para editar sin aprender varios modos de apertura.
32. Como usuario, quiero confirmar campos mediante Guardar, para decidir cuándo aplicar mis cambios.
33. Como usuario, quiero que pasos, comentarios y archivos se guarden con su propia acción, para trabajar en ellos sin confundirlos con el borrador de campos.
34. Como usuario, quiero elegir Guardar y cerrar, Descartar o Seguir editando ante cambios pendientes, para no perder texto por cerrar el detalle.
35. Como miembro, quiero asignar cero o un responsable actual, para señalar quién se ocupa sin restringir la edición colaborativa.
36. Como usuario, quiero mover y ordenar tareas dentro del tablero sin cambiar su completado, para organizar el flujo a mi manera.
37. Como usuario, quiero completar una tarea manteniendo su columna, para registrar que está hecha sin moverla o borrarla.
38. Como usuario, quiero ver inicialmente las completadas atenuadas en un grupo y poder ocultarlas personalmente, para mantener contexto sin alterar lo que ven otros.
39. Como usuario, quiero reabrir desde el detalle cuando corresponda, para evitar reaperturas accidentales desde una tarjeta compacta.
40. Como usuario, quiero distinguir un guardado pendiente, confirmado o fallido, para saber qué cambios están persistidos.
41. Como usuario, quiero conservar mi borrador y revisar conflictos con otro editor, para evitar sobrescrituras silenciosas.
42. Como usuario, quiero consultar contenido ya cargado sin conexión con aviso de desactualización, para seguir orientándome sin creer que estoy sincronizado.

### Fechas, series y cumpleaños

43. Como usuario, quiero una fecha límite opcional por día y sin hora, para organizar tareas sin convertirlas en reuniones.
44. Como usuario, quiero que una tarea puntual vencida permanezca visible y destacada, para no perder un pendiente.
45. Como usuario, quiero abrir Programar solo cuando lo necesite, para mantener sencilla una tarea puntual.
46. Como usuario, quiero recurrencias diarias, semanales, mensuales y anuales con intervalos y ordinales, para expresar mis rutinas reales.
47. Como usuario, quiero elegir final por fecha, cantidad o sin final, para delimitar la duración de una rutina.
48. Como usuario, quiero previsualizar el calendario resultante y la zona del tablero, para entender qué fechas estoy configurando.
49. Como usuario, quiero que completar tarde no desplace las siguientes fechas, para conservar mi calendario.
50. Como usuario, quiero una sola pendiente vigente por serie, para no acumular una pila de repeticiones atrasadas.
51. Como usuario, quiero que una repetición reemplazada no aparezca como realizada, para conservar un historial honesto.
52. Como usuario, quiero aparición anticipada opcional menor que la separación mínima de vencimientos, para prepararme sin tener dos pendientes vigentes.
53. Como usuario, quiero elegir la columna de aparición de próximas ocurrencias, para mantener la rutina dentro de mi organización.
54. Como usuario, quiero mover la ocurrencia actual sin cambiar la columna de las próximas, para adaptar el trabajo de hoy.
55. Como usuario, quiero que editar la serie afecte solo a próximas ocurrencias, para conservar la actual y el pasado.
56. Como usuario, quiero omitir una repetición sin que reaparezca por recarga o reintento, para respetar una excepción.
57. Como usuario, quiero conocer qué exclusiones siguen aplicando al cambiar la regla, para evitar cambios silenciosos.
58. Como usuario, quiero distinguir eliminar una repetición, detener la serie y eliminarla completa, para controlar el alcance de una acción.
59. Como usuario, quiero consultar ocurrencias antiguas sin reactivarlas cuando ya apareció una posterior, para revisar historia sin romper la rutina vigente.
60. Como miembro, quiero localizar todas las series de tableros accesibles aunque sus tareas estén ocultas, para recordar qué sigue programado.
61. Como usuario, quiero fechas mensuales inexistentes ajustadas al último día conservando el ancla, para que febrero no cambie permanentemente mi regla.
62. Como usuario, quiero una política explícita para 29 de febrero y ordinales inexistentes, para anticipar el calendario.
63. Como usuario, quiero registrar cumpleaños como fechas anuales sin casilla de completado, para recordarlos sin convertirlos en tareas de saludar.
64. Como usuario, quiero ver un cumpleaños todo el año o solo en su ventana anticipada elegida, para controlar su presencia en el tablero.
65. Como usuario que vuelve tras días sin entrar, quiero un calendario reconciliado sin atrasos ficticios, para retomar la rutina con claridad.

### Colaboración, archivos y novedades

66. Como miembro, quiero una checklist plana con texto, casilla y orden, para dividir una tarea en pasos sencillos.
67. Como usuario, quiero confirmar al completar una tarea con pasos pendientes, para decidir sin marcarlos hechos automáticamente.
68. Como usuario, quiero que cada nueva ocurrencia reciba los pasos de plantilla sin marcar, para comenzar cada repetición limpia.
69. Como miembro, quiero comentar y mencionar miembros actuales en el detalle, para coordinar alrededor de una tarea.
70. Como autor, quiero editar mi comentario, para corregirlo sin permitir que otros reescriban mi mensaje.
71. Como propietario, quiero moderar borrando comentarios con recuperación restringida, para cuidar la conversación.
72. Como miembro, quiero que las menciones a personas retiradas queden como texto, para conservar contexto sin enlaces o permisos antiguos.
73. Como miembro, quiero adjuntar textos .txt y .md privados y usar enlaces para otros materiales, para compartir información con límites simples.
74. Como miembro, quiero que comentarios y archivos se conserven con su ocurrencia, para no copiarlos ni perderlos al cambiar la vigente.
75. Como usuario, quiero URLs clickeables y apertura segura, para consultar material externo sin copiar manualmente la dirección.
76. Como usuario, quiero ver límites y espacio retenido por archivos recuperables, para comprender por qué una carga no cabe.
77. Como propietario, quiero limpiar archivos de mis tableros, incluidos los de tareas completadas, para administrar el espacio.
78. Como administrador, quiero gestionar la cuota global con metadatos mínimos y avisos de capacidad, para mantener el servicio sin leer archivos ajenos.
79. Como usuario, quiero novedades por asignación, mención, comentario y cambio de vencimiento relevantes, para enterarme de lo que requiere atención.
80. Como usuario, quiero evitar avisos propios y duplicados, para que la bandeja no se convierta en ruido.
81. Como usuario, quiero que una mención nueva al editar avise una vez, para enterarme sin reavisos por quitarla y reponerla.
82. Como usuario, quiero abrir una novedad autorizada y marcarla leída sin completar la tarea, para separar atención y trabajo realizado.
83. Como usuario, quiero marcar como leídas solo las novedades cargadas con una cantidad explícita, para ponerme al día sin ocultar páginas que no vi.
84. Como usuario, quiero que novedades leídas y no leídas caduquen a los 90 días sin borrar contenido, para mantener una bandeja acotada.

### Encontrar, personalizar y usar desde cualquier dispositivo

85. Como usuario, quiero reunir mis tareas asignadas en una vista secundaria, para atenderlas sin duplicar ni trasladar las originales.
86. Como usuario, quiero ordenar Mis tareas por vencimiento antiguo primero y sin fecha al final, con alternativa por creación, para elegir mi forma de revisar.
87. Como usuario, quiero buscar en contenido autorizado de tareas, comentarios y tableros con sugerencias que indiquen tipo y origen, para encontrar y abrir lo que necesito sin saber dónde estaba.
88. Como usuario, quiero filtros con alcance visible, chips eliminables y Limpiar, para entender por qué veo ciertos resultados.
89. Como usuario, quiero filtros Hoy, Vencidas, Próximos 7 días y Sin fecha con calendario del tablero, para revisar el horizonte correcto.
90. Como usuario, quiero etiquetas simples del tablero y filtros por ellas, para agrupar temas sin cambiar columna o prioridad.
91. Como usuario, quiero guardar con nombre filtros y orden personales, para volver a consultas frecuentes con datos y fechas actualizados.
92. Como usuario, quiero favoritos personales dentro de Tableros, para volver rápido a mis espacios habituales.
93. Como usuario, quiero copiar un enlace privado estable a una tarea u ocurrencia, para referirme a ella sin conceder acceso.
94. Como usuario de escritorio, quiero Ctrl/Cmd+K para abrir la búsqueda existente fuera de campos de escritura, para encontrar más rápido.
95. Como usuario, quiero preferencias de orden, filtros y completadas por contexto sincronizadas entre mis dispositivos, para conservar mi forma de trabajar.
96. Como usuario, quiero elegir tema claro, oscuro o sistema sin perder el editor, para adaptar la legibilidad a mi entorno.
97. Como usuario, quiero la interfaz, errores y nombres accesibles en español, para utilizar la herramienta con naturalidad.
98. Como usuario, quiero duplicar una tarea puntual con descripción, prioridad, etiquetas activas y pasos reiniciados, para reutilizar una estructura sin heredar asignación o programación.
99. Como miembro, quiero ver actividad mínima de responsable, fecha, columna, completado y recuperación, para entender cambios compartidos.
100. Como usuario, quiero volver del detalle al filtro, columna y posición de origen, para no perder el contexto.
101. Como usuario, quiero distinguir vacío, falta de resultados, carga, fallo y acceso perdido, para saber qué acción corresponde.
102. Como usuario móvil, quiero acciones alcanzables con el teclado abierto y alternativas al arrastre, para trabajar cómodamente con una mano o controles táctiles.
103. Como usuario de teclado o tecnología de asistencia, quiero nombres, foco, contraste y zoom utilizables, para realizar los mismos recorridos.
104. Como usuario, quiero que los cambios remotos no roben foco ni cambien mi columna activa, para continuar mi edición.
105. Como usuario móvil, quiero instalar la aplicación web en dispositivos compatibles y abrir enlaces con el mismo login, para acceder desde el inicio del teléfono.

### Recuperación, portabilidad y operación

106. Como usuario autorizado, quiero recuperar contenido durante siete días con vencimiento visible, para corregir borrados accidentales.
107. Como miembro, quiero que recuperar contenido respete permisos actuales y borrados independientes, para no restaurar accesos o contenido moderado indebidamente.
108. Como propietario, quiero resolver el destino de tareas y series al eliminar una columna con contenido, para no dejar elementos sin ubicación.
109. Como usuario autorizado, quiero exportar el contenido completo permitido del tablero, para conservar mis datos aunque la pantalla esté paginada.
110. Como propietario, quiero previsualizar una importación compatible con exportaciones v1, para conocer el reemplazo y las asignaciones incompatibles.
111. Como propietario, quiero conservar el contenido previo siete días y rechazar reemplazos sin capacidad suficiente, para no perder el tablero ante fallos.
112. Como administrador, quiero respaldar y restaurar base, objetos y configuración de la instancia, para recuperar el servicio completo.
113. Como operador, quiero que reintentos y reinicios no dupliquen tareas, avisos, actividad o consumo, para mantener consistencia con mala señal o caídas.
114. Como operador, quiero diagnósticos de trabajos, errores, purgas y cuotas sin contenido privado ni tokens, para resolver problemas respetando la privacidad.
115. Como propietario de la instancia, quiero una transición con inventario y dueños explícitos, para conservar tableros existentes al cerrar el acceso anónimo.
116. Como usuario, quiero poder capturar, encontrar, completar, coordinar y retomar una rutina en móvil y computadora, para organizar mi vida cotidiana con menos fricción.

## Implementation Decisions

### Modelo y límites de los módulos

Responsabilidades: identidad/admisión; tableros/membresías/invitaciones; tareas/columnas/vistas; programación/ocurrencias; colaboración/novedades; archivos/recuperación/respaldo; preferencias/navegación; operación. Son módulos, no servicios desplegables obligatorios. Conservar stack salvo necesidad demostrada; no elegir bibliotecas/proveedores pagos ni DDL sin diseño. Identidades estables de usuario/tablero/membresía/invitación/tarea/serie/ocurrencia separadas de vistas/preferencias. Respetar contratos y cerrar pendientes afectados antes de construir.

### Acceso, invitaciones y propiedad

- Google identifica; la habilitación global administrada permite usar la aplicación; la membresía concede acceso al tablero. Son tres condiciones diferentes.
- Solo el administrador admite/suspende personas. Cada habilitado crea tableros y es su propietario. Roles de tablero: propietario y colaborador; todos los miembros ven el tablero completo.
- Cero o un responsable por tarea; la asignación no limita edición ni otorga membresía. La administración global no concede lectura automática de tableros ajenos.
- La entrada pública creadora se sustituye por Google y acceso restringido. Un usuario autenticado/habilitado llega a Tableros. No se concede acceso por conocer URL, mediante API anónima ni por primer login.
- Solo el propietario invita, administra miembros y configura nombre/zona. Coexisten invitación directa a cuenta habilitada y enlace genérico para elegibles: 72 horas, un uso, revocables, rol colaborador, sin correo automático.
- Una directa pendiente por persona/tablero; mostrar existente, renovar explícitamente si venció y no invitar a quien ya es miembro. Preview autorizado: nombre del tablero, invitador y rol; sin tareas.
- El propietario debe elegir sucesor elegible para salir. Un cambio concurrente de elegibilidad devuelve conflicto; no sustituye silenciosamente al elegido. Asignación automática al miembro elegible más antiguo solo como reparación excepcional de inconsistencia, nunca como flujo normal.
- Al retirar al dueño sin otro miembro elegible, tablero recuperable siete días y nuevo dueño obligatorio al recuperar. Incluir tableros ya en papelera al resolver autoridad, sin reactivar ni reiniciar plazos.
- Retirar acceso conserva contenido y autorías; desasigna pendientes y futuras repeticiones. Menciones antiguas pasan a texto. Reingresar no restaura membresías, roles, asignaciones, menciones o avisos atrasados.
- Proteger al único administrador contra autosuspensión accidental. No incorporar delegación de administración global por inferencia.

### Trabajo cotidiano y navegación

- Columnas elegidas por el usuario, sin nombres ni recorrido obligatorio. Mover entre columnas conserva completado/fecha; no hay traslado entre tableros aprobado.
- Completar conserva columna. Completadas inicialmente visibles y atenuadas en grupo colapsable al pie, también en Mis tareas. Reapertura desde detalle; la casilla compacta de una completada no induce reapertura accidental.
- Mis tareas reúne asignadas de tableros accesibles; completar modifica la misma tarea de origen. Orden principal por vencimiento ascendente, más antiguas primero y sin fecha al final; alternativa por creación ascendente. C-104: desempate por creación ascendente e identidad estable; completadas por completado más reciente.
- Campos editables con Guardar. Checklist/comentarios/archivos usan su propia acción; descartar campos no revierte esos cambios ya confirmados. Resolver borrador antes de completar/mover/borrar con Guardar/Descartar/Cancelar; al cerrar, Guardar y cerrar/Descartar/Seguir editando.
- El detalle ocupa la pantalla disponible en móvil, sin scroll horizontal. Navegación global en drawer superpuesto desde la izquierda: Tableros, Mis tareas, Series y Novedades; cuenta/preferencias/admin autorizado/salir al pie. Búsqueda visible, menú contextual de tablero y acciones de tarea dentro del detalle.
- Primer uso sin tutorial obligatorio, datos de ejemplo automáticos ni columnas impuestas. Quien recibe una invitación puede empezar por ese tablero.
- Captura, detalle, filtros, accesibilidad, favoritos, enlaces, idioma y preferencias se precisan en la tabla P/E de esta sección.

### Programación, series y calendario

- Día sin hora, interpretado con la zona del tablero, inicialmente la del creador. Mantener el mismo día elegido entre dispositivos; fecha de creación no sustituye vencimiento.
- Programar es opcional y progresivo. Fecha no activa repetición; repetición no activa anticipación. Calendario de apoyo pequeño y previsualización de fechas.
- Catálogo aprobado: cada N días; días seleccionados de la semana/cada N semanas; cada N meses por fecha u ordinal semanal; cada N años por fecha u ordinal semanal. Final sin límite, por fecha o por cantidad. Los días laborables representan lunes a viernes, no un calendario de feriados.
- Solo calendario fijo; completar tarde no cambia siguientes fechas. Separar regla de serie y ocurrencias; no inferir serie por título.
- Como máximo una pendiente vigente por serie. Nueva activación reemplaza a la anterior pendiente sin marcarla realizada; conserva las completadas. Tras inactividad, reconciliar sin pila de atrasos.
- Aparición anticipada opcional X días antes del vencimiento: X no negativo y estrictamente menor que la separación mínima entre vencimientos. Las nuevas ocurrencias nacen en la columna de aparición; no hay movimiento automático de tarjetas existentes.
- Editar serie afecta próximas, preservando actual y pasado. Cambiar columna futura no mueve la actual. Mantener exclusiones aplicables e informar las que dejan de aplicar, sin generación retroactiva.
- Borrar solo una repetición conserva su exclusión frente a recarga/reintentos. Detener conserva lo existente; eliminar toda la serie incluye ocurrencias e historial y requiere advertir alcance.
- Reabrir solo la vigente mientras no haya aparecido una posterior; históricas siguen consultables. Recuperar una serie conserva activa/detenida y reconcilia sin responsables retirados ni atrasos acumulados.
- Fecha mensual inexistente: último día disponible conservando el ancla original. 29 de febrero anual: 28 en año no bisiesto, conservando 29 como regla. Quinto día semanal inexistente: omitir, no convertir en último. Patrones explícitos de último día/último día de semana.
- Cumpleaños es una fecha anual sin completado. Sin anticipación se ve todo el año y pasa a la próxima fecha después del día; con anticipación se ve de D−X a D inclusive y luego queda oculto hasta la siguiente ventana. Siempre localizable en Series.
- Series muestra todas las de tableros accesibles, filtrables por tablero, incluso sin tarjeta visible. Al borrar una columna, resolver destino de tareas/series afectadas; no crear una columna obligatoria.
- C-110: inicio explícito (proponer fecha existente); semanas lunes–domingo ancladas a semana de inicio, sin fechas anteriores; preview actual/futuras. Final inclusivo; N fechas efectivas aunque excluidas, no completados; quinto lunes inexistente no cuenta. Ejemplo 1/4/7, excluir4 no agrega10.
- C-111: convertir conserva tarjeta como primera contada en N; fecha incompatible exige elegir/confirmar primera compatible, sin duplicar ni cambio silencioso. Editar final muestra N próximas excluyendo actual/pasado y nuevo final; editar título/responsable/columna no reinicia restante.
- Excepción actual vence estrictamente antes de próxima aparición: si aparece14, máximo13. Rechazar igualdad/posterior con explicación/borrador, sin fusionar ni cambiar futuras.
- Recuperar finita pasada: máximo última válida, aunque vencida/no materializada; 1/3/5 borrada2 recuperada6→solo5, sin3/7 ni extender. Si última excluida no sustituta; no regenerar eliminadas/purgadas independientemente; detenida sigue detenida. Restaurar ocurrencia quita solo exclusión de su borrado; con posterior es histórica, padres primero. Recuperar serie no revive hijos borrados aparte.
- Recuperación ordinaria de tareas/pasos/series/columnas por propietario/colaborador actual con edición, siete días y dependencias válidas; moderación/admin conservan restricciones. Recuperar columna no revierte traslados.

### Colaboración, cuotas y recuperación

- Checklist plana: texto, casilla, orden y borrado; no responsable/fecha/recurrencia por paso. Todos los pasos hechos no completan automáticamente la tarea. Completar con pendientes pide confirmación sin tildarlos; reabrir conserva sus casillas.
- Plantilla de pasos de serie se aplica sin marcar a cada nueva ocurrencia. Cambiar actual no modifica próximas. Comentarios/archivos pertenecen a su ocurrencia y se conservan en historia, sin copiarlos automáticamente.
- Solo autor edita su comentario. Propietario puede moderar borrando, no reescribir texto ajeno. Mencionar requiere miembro actual y no concede acceso.
- Adjuntos solo .txt/.md, máximo inclusivo 24.000 bytes; para otros formatos usar enlaces. Máximo 20 archivos por tarea incluidos recuperables; cuota global 200.000.000 bytes, incluidos activos, recuperables y reservas.
- Aviso al 80 % (160.000.000 bytes); cargas que excedan capacidad se rechazan. Propietarios limpian propios; admin solo metadatos mínimos. C-111: por persona/umbral, nuevo aviso solo nuevo cruce tras bajar y 24 h desde el anterior; no periódico por seguir arriba. Carga bloqueada informa inmediatamente.
- Borrar oculta y conserva capacidad ocupada hasta purga tras siete días. No eliminar archivos vigentes por antigüedad ni acortar recuperación para liberar espacio. Mostrar espacio retenido y vencimiento.
- Recuperación exige plazo, objeto/antecesores válidos y permisos actuales. No revive membresías, invitaciones, menciones ni hijos borrados independientemente. Borrado del padre no reinicia plazos de borrados previos.
- Tareas ordinarias: recuperación por quienes conservan permiso de edición; granularidad adicional de pasos/series/columnas por cerrar donde la matriz la conserva propuesta. Tablero ordinario: propietario con autoridad de recuperación; tablero sin dueño elegible: admin elige nuevo dueño.
- Comentario/archivo borrado por autor/subidor: esa persona con acceso o propietario actual. Moderación de propietario: solo propietario actual. Limpieza administrativa: admin autorizado. Cada operación conserva causa y actor.
- Novedades: asignación/mención a destinatario, comentario a responsable/creador, vencimiento por otro al responsable; sin autoavisos/duplicados por evento/destinatario ni avisos por paso/movimiento/repetición automática. C-111: nuevas ocurrencias usan creador de serie con acceso, original conserva creador, retirado sin sustitución por owner.
- Nuevas menciones al editar avisan una vez; quitar/reponer no reavisa. Novedades leídas y no leídas caducan a 90 días sin borrar tareas/conversación. Creador de referencia de una ocurrencia generada sigue por concretar.
- Acceso se revalida al leer, abrir o marcar una novedad. Lote explícito limitado a las cargadas/autorizadas al confirmar; no incluye páginas restantes ni avisos posteriores.
- C-107: búsqueda unificada con sugerencias por campo/tipo/origen, incluyendo comentarios y tableros además de tareas/títulos; selección explícita para navegar/filtrar. El límite anterior solo título/descripción está sustituido; C-108 fija etiquetas como filtros, apertura precisa, relevancia agrupada y filtros heredados por comentarios; archivos/actividad excluidos. Filtros autorizados por tablero, responsable incluido sin asignar, completado, prioridad, fecha y etiquetas; búsqueda inicialmente de pendientes con control visible para incluir completadas.
- C-111: autolinks HTTP/HTTPS/www. en descripción/comentarios/pasos al visualizar; www. abre HTTPS, dominio suelto texto, puntuación exterior excluida y original conservado. Título compacto abre tarea; URL de título control externo separado en detalle. Apertura explícita segura, sin HTML/esquemas activos/locales ni previews/descargas automáticas.

### Persistencia, operación y portabilidad

- Contratos por acción, campos permitidos y referencias validadas en servidor; ni el objeto enviado por cliente ni el realtime son autoridad de permisos.
- Versiones para edición y claves de operación para reintentos. Comentarios/pasos/archivos independientes de la versión de campos. Completar expresa estado deseado, no invertir dos veces.
- Efectos de fondo durables, reintentables y deduplicados, con reconciliación. No promesa de exactamente una ejecución ni elección implícita de tecnología de Plane.
- Realtime privado como señal para volver a consultar datos autorizados. Revalidar al reconectar/cambiar cuenta y descartar respuestas de sesiones antiguas. Conservar borradores mientras haya acceso; retirarlos al conocer revocación.
- Offline: lectura de contenido cargado con aviso y borrador de sesión, sin envío automático al reconectar ni garantía de recuperar borrador tras recarga/cierre. No se puede detectar instantáneamente una revocación sin red ni retirar copias descargadas.
- Tarjetas consultan resúmenes; detalle carga conversación/archivos/actividad. Paginar listas globales y conversaciones con orden estable, filtros en servidor y contadores autorizados; diseñar carga parcial del tablero junto al reordenamiento.
- Exportación completa por tablero, aunque haya paginación. Excluir secretos, invitaciones, permisos reutilizables y archivos de destinos externos. Preferencias personales no conceden acceso ni se transforman en membresías.
- Importación solo propietario: formato versionado, lector v1, preparación/validación, preview y reemplazo explícito, sin mezcla. Mantener propietario/miembros destino; responsables incompatibles sin asignar; no avisos históricos ni atrasos de series.
- Contenido previo conservado siete días contando capacidad. Rechazar antes de destruir si no cabe; fallos no dejan reemplazo parcial. C-101 incluye catálogo activo completo y asociaciones de etiquetas; C-105 incluye actividad vigente con fecha/atribución histórica e identificación de importados, sin avisos antiguos.
- Respaldo operativo separado: base, objetos y configuración necesaria, con restauración ensayada fuera de producción. No incluir secretos operativos en el archivo portable de tablero.
- Transición privada con inventario autorizado, dueño explícito y ensayo de recuperación; no asignar al primer login ni publicar un login sobre operaciones anónimas todavía abiertas.
- Diagnósticos mínimos de errores, trabajos, purga/cuota sin cuerpos privados ni tokens; migraciones/versiones/dependencias, actualización y recuperación documentadas. Mantener registro de origen/licencia cuando se reutilice código.

### Incorporaciones completas de Plane

Los IDs conservan trazabilidad con C-99. Los documentos dueños desarrollan cada contrato; esta tabla preserva las 33 incorporaciones en la spec publicada.

| ID | Contrato aprobado |
| --- | --- |
| P01 | Identidad única de tarea en tablero, Mis tareas, búsqueda, novedades y enlaces; columna, completado y programación independientes. Una vista nunca crea una copia. |
| P02 | Alta por título con Enter o botón; perder foco no envía. Tras éxito queda lista para otra tarea en la misma columna. Fallo conserva título; resultado incierto se reconcilia antes de repetir. |
| P03 | Un detalle adaptable: título/acciones, campos cotidianos, luego pasos/archivos/conversación. Bloques opcionales vacíos ofrecen añadir sin imponer configuración. Guardar campos y acciones independientes mantienen sus contratos. |
| P04 | Tarjeta con título, casilla cuando corresponda, responsable, vencimiento, prioridad y progreso si existen; descripción secundaria, creación/autoría en detalle. Abrir, completar y mover son acciones distintas. |
| P05 | Búsqueda con alcance visible, chips y Limpiar; Hoy/Vencidas/Próximos 7 días/Sin fecha. Próximos desde mañana a hoy+7 inclusive por zona de tablero, con contexto en resultados globales. |
| P06 | Orden/filtros/completadas personales por vista/tablero, sincronizados entre dispositivos, con defaults y reinicio explícitos. Scroll/columna activa son navegación; no cambian configuración común. |
| P07 | Abrir y cerrar detalle preserva origen, filtros, columna y posición; Atrás respeta borradores. Entrada directa sin origen regresa al tablero autorizado. |
| P08 | Controles y tokens coherentes con negro/blanco/amarillo; nombres accesibles, foco, teclado, zoom 200 %, movimiento reducido y alternativas táctiles al arrastre/hover. |
| P09 | Recorridos verificables en 360/390 px y escritorio, teclado virtual, orientación y Atrás. Cambios remotos no roban foco ni cambian columna activa. |
| P10 | Distinguir sin tableros/columnas/tareas/resultados, carga, fallo local y acceso perdido. Cada estado ofrece una acción válida; error no equivale a vacío y recarga conserva contenido autorizado. |
| P11 | Copiar enlace privado estable a tarea u ocurrencia concreta; login recupera destino tras autorizar. No invita ni revela títulos públicamente; renombrar tablero no invalida. Ocurrencia antigua abre su historial autorizado, nunca la actual por sustitución. |
| P12 | Español inicial en interfaz, errores y accesibilidad; textos/formatos centralizados. Fechas legibles, día estable y zona visible al programar. Sin traducir contenido del usuario ni agregar selector de idiomas. |
| P13 | Estrella personal y sección Favoritos dentro de Tableros, sin nuevas entradas globales ni carpetas. Revocación retira nombre y acceso; no altera membresía ni favoritos ajenos. |
| P14 | Ctrl/Cmd+K abre el buscador existente con alcance contextual; no intercepta escritura. Atajo documentado y botón visible disponible en móvil/escritorio. No paleta general de comandos. |
| P15 | Acceso antes de lectura/destino, referencia no disponible cuando corresponda y deduplicación por evento/destinatario. Mención nueva al editar avisa una vez; quitar/reponer no reavisa. |
| P16 | Autorización comprobable en servidor, consultas, canales, archivos y superficies secundarias. Casos con dos tableros, propietario/colaborador, admin no miembro, retirado/no habilitado e identificadores manipulados; ni URL, autoría ni asignación conceden membresía. |
| P17 | Mutaciones por acción y listas de campos permitidos; servidor deriva autor/rol, valida referencias y rechaza campos protegidos. Separar editar/completar/mover/invitar/transferir/borrar/restaurar. |
| P18 | Precondición de versión y clave de operación para reconciliar reintentos; comentarios/pasos/archivos independientes de versión de campos. Estado pendiente visible y completado como valor deseado, no toggle. |
| P19 | Trabajo pendiente durable ligado al cambio cuando corresponda; avisos/activaciones/purgas reintentables y deduplicados, con reconciliación tras inactividad. Sin prometer ejecución exactamente una vez. |
| P20 | Realtime señala cambios para consultar datos autorizados. Canales privados y revalidación al reconectar/cambiar cuenta; descartar respuestas antiguas, preservar borrador autorizado y retirar estado privado cuando se pierde acceso. |
| P21 | Borrado registra causa, actor, plazo y dependencias. Restaurar/purgar coordinados con permisos/cuota; no reviven accesos, invitaciones ni hijos borrados por separado. |
| P22 | Reservar → cargar → verificar → publicar; liberar reservas fallidas y reconciliar objetos. Cuota incluye activos/recuperables/reservas; validar permiso/contenido al confirmar. Límites decimales 24.000 bytes/archivo y 200.000.000 globales; 20 adjuntos por tarea incluidos recuperables. Definir residuo de enlaces temporales. |
| P23 | Tarjetas cargan resúmenes; conversaciones/archivos/actividad bajo demanda. Listas globales y conversaciones con paginación estable y filtros autorizados en servidor. Exportación completa; carga parcial del tablero y reordenamiento se diseñan juntos. |
| P24 | Separar exportación portable de tablero de respaldo operativo de instancia (base, objetos y configuración). Formato versionado, lector v1, importación preparada/validada y publicación protegida; ensayo de restauración fuera de producción. |
| P25 | Versiones/migraciones/dependencias y diagnósticos de errores, trabajos, purgas/cuotas sin cuerpos privados ni tokens; procedimientos de actualización/recuperación y origen/licencia de código reutilizado. Sin telemetría externa ni pantalla de métricas por defecto. |
| P26 | Trazar cada regla a escenario y evidencia; observar capturar/encontrar/completar/coordinar/retomar con personas del piloto. Registrar fricción sin analítica externa ni puntajes. Separar facilidad de uso de pruebas automáticas. |
| E01 | Etiquetas de tareas/cumpleaños y plantilla de serie. C-100: facultades y límites 40/100/10, paleta y OR. C-101: recuperación siete días solo propietario actual, herencia de activas al generar, copia de activas del origen y respaldo de catálogo activo completo/asociaciones. C-102: solo cupos activos y restauración con resolución explícita de nombre/cupo/asociaciones. |
| E02 | Vistas personales con texto/alcance/completadas/filtros/orden; global dinámico, tablero específico y asignación propia en Mis tareas. C-100: edición explícita y límites 50/60. C-101: referencia explícita inválida bloquea hasta revisar/confirmar, recuperación siete días solo usuario y conflicto sin sobrescritura. |
| E03 | Tema personal claro/oscuro/sistema, conservando marca, contraste y estados; cambio sin recarga ni pérdida del editor. Sin editor de colores ni tema común del tablero. |
| E04 | Duplicar tarea en el mismo tablero: nueva identidad pendiente, título/descripción/prioridad, checklist sin marcar y etiquetas activas del origen (C-101; si es ocurrencia, no de plantilla). No copiar responsable, fecha, serie, comentarios, archivos ni membresías. Si origen es ocurrencia, explicar que la copia es puntual. |
| E05 | Actividad de categorías E05 con actor/fecha-hora y valores anterior/nuevo; recientes primero/progresiva. C-105: 180 días por evento, ocultar con tarea y purgar dependiente; atribución histórica/Sistema/Importada y respaldo de vigentes sin avisos retroactivos. Sin versiones de textos ni edición individual. |
| E06 | PWA online opcional. C-109: matriz inicial AndroidChrome/iPhoneSafari/Chrome–Edge escritorio/SafariMac, Firefoxweb; Instalar en cuenta directo/manual, actualización elegida sin perder borrador. Probar versiones/dispositivos; mismo login/enlaces, sin push/cola offline/app nativa. |
| E07 | C-109: botón con cantidad sin leer cargada, una pulsación sin diálogo extra y conjunto fijo al pulsar. Resumir marcadas/ya leídas/no disponibles/falladas; reintentar solo falladas autorizadas del original, reconciliar incertidumbre. Sin nuevas/páginas restantes/archivar/posponer. |

### Etiquetas y vistas — C-100, actualizado por C-101–103

- Propietario y colaboradores crean/renombran/cambian color/aplican/quitan etiquetas; solo propietario elimina. Renombrar conserva identidad, asociaciones y filtros; admin ajeno sin facultades.
- Etiquetas opcionales del tablero para tareas/cumpleaños y plantilla de serie: nombre hasta 40 caracteres, 100 activas/tablero y 10 activas/elemento; paleta accesible con colores repetibles. No sustituyen columna, responsable, prioridad o completado. Unicidad según C-103; medición de caracteres técnica.
- Serie y ocurrencia conservan selecciones distintas; herencia al generar según C-101. Varias etiquetas usan OR («Cualquiera de estas etiquetas»), combinado mediante AND con otros filtros. En global mostrar tablero de cada etiqueta, sin fusionar homónimas de otros tableros.
- Vista guarda texto, alcance, completadas, filtros y orden. Todos los accesibles es dinámico; un tablero específico permanece acotado; Mis tareas conserva asignación propia. Recalcular fechas relativas y permisos, sin guardar resultados. Nombre «Esta semana» no crea semana calendario ni cambia Próximos 7 días.
- Cambiar filtros crea variación temporal: Actualizar vista, Guardar como nueva y Restablecer vista son explícitos. Distinguir definición guardada de P06/último uso.
- Hasta 50 vistas activas/persona entre Búsqueda y Mis tareas, nombres hasta 60 caracteres únicos por contexto según C-103. Solo su usuario administra; sincronizadas. Recuperación y conflictos según C-101/C-102.

### Etiquetas y vistas — ciclo e identidad C-101–103

- Etiqueta eliminada desaparece de tarjetas/selectores sin borrar tareas/cumpleaños; conserva asociaciones para recuperar siete días solo por propietario actual, luego purga. Nuevas ocurrencias no reciben eliminadas; restaurar no agrega retroactivamente a las nacidas durante ausencia ni revive tareas borradas.
- Cada ocurrencia copia activas de plantilla al generarse; editar una no cambia la otra ni generadas/pasado. Copia puntual toma activas propias del origen, no plantilla, y mantiene exclusiones E04.
- Exportar catálogo activo completo incluso sin uso y asociaciones de elementos exportados. Importar reconstruye dentro del destino sin vincular otro tablero por nombre; v1 sin etiquetas no inventa. Vistas personales fuera del respaldo de tablero.
- Referencia explícita a tablero/etiqueta/miembro inexistente o no permitido bloquea vista hasta revisar/confirmar: «Esta vista necesita revisión», quitar/reemplazar condición. Ante revocación mensaje genérico sin nombres privados. No quitar condiciones silenciosamente. Global dinámico se adapta a membresías actuales.
- Vista borrada se oculta del selector y recupera siete días solo por su usuario en gestión del contexto, revalidando referencias/permisos; inválida queda por revisar. Conflicto conserva variación temporal: cargar actual o guardar nueva; revisar actual antes de actualizar original, sin sobrescritura silenciosa.
- Solo activos cuentan 100 etiquetas/tablero, 10/elemento y 50 vistas/persona entre contextos. Borrar libera lugar; recuperar exige cupo sin eliminar otros. Nombre de eliminado reutilizable; colisión al restaurar exige renombrar conservando identidad, sin fusionar ni trasladar asociaciones por nombre.
- Preview de restauración identifica asociaciones que excederían diez activas: liberar espacio u omitir asociación explícitamente; confirmar solo selección válida completa, sin omisiones silenciosas.
- Guardar corrección actualiza/revalida definición y habilita consulta. Si vuelve referencia original, revisar/confirmar basta; condición ya quitada no se repone sola. Guardado tardío no resucita vista borrada: conservar variación autorizada, guardar nueva con nombres/cupos válidos o recuperar original por su vía sin aplicar borrador automáticamente.
- Búsquedas/filtros textuales y unicidad al crear/renombrar/restaurar nombres ignoran acentos, ñ/n, mayúsculas y espacios sobrantes: reunión/reunion y Peña/Pena. Conservar escritura original. Unicidad por tablero para etiquetas y por usuario/contexto para vistas; ofrecer existente solo autorizada. Sin fusión ni cambio de IDs/asociaciones, campos buscables o permisos. Seleccionar etiqueta usa su identidad/tablero. No normalizar correos/URLs como nombres.

### Copia, preferencias y actividad — C-104/C-105

- Copia: título original editable para nueva tarea sin sufijo; columna origen por defecto con selector mismo tablero y final manual respetando orden personal. Permitidas completadas/históricas accesibles sin editar/reabrir origen; eliminadas requieren recuperar, cumpleaños no ofrecen Duplicar tarea. Campos/exclusiones E04 vigentes; actividad no se copia.
- Panel breve título/columna/resumen con Crear copia y cancelar sin efecto. Confirmar éxito y ofrecer abrir conservando contexto; ocurrencia genera puntual. Si cambió contenido copiable actualizar preview y pedir revisión, conservar título/destino elegidos. Comentario nuevo no interrumpe; borrado/acceso perdido bloquea.
- Tema inicial Sistema; login aplica preferencia de cuenta. Modos Claro/Oscuro sincronizados, Sistema por dispositivo; conserva editor/borradores. Orden empatado por creación ascendente y luego identidad estable; completadas por completado más reciente. Mis tareas por vencimiento ascendente/sin fecha al final, alternativa creación ascendente.
- Preferencias diferentes entre dispositivos se combinan; misma preferencia editada desde versión anterior conserva local y permite cargar guardada o revisar/conservar local, sin sobrescribir silenciosamente.
- Actividad: solo responsable/fecha/columna/completado/recuperación, actor/fecha-hora y anterior/nuevo cuando corresponde; recuperar indica quién/cuándo. Recientes primero/carga progresiva; sin versiones de textos ni nuevas categorías de creación/copia.
- Conservar 180 días desde evento con ventana visible, independiente de novedades 90 días. Restaurar/importar no reinicia ni revive vencidos. Ocultar con tarea; purga definitiva elimina dependientes; recuperar solo vigentes. Sin editar/borrar eventos individuales; acceso actual del contenido.
- Atribución histórica sin permisos/menciones, distinguir Sistema y Actividad importada sin fingir cuenta local verificada. Exportar/importar eventos vigentes de tareas exportables con fechas/atribución histórica, sin avisos antiguos ni vencidos/papelera.

### Defaults y acciones de consulta — C-106

- Sin preferencia o tras reinicio: Tablero manual/sin filtros/completadas visibles y expandidas; Mis tareas todos accesibles/sin extras/vencimiento/completadas visibles y expandidas; lista búsqueda pendientes/sin extras/vencimiento/sin fecha al final. Recuperar preferencias existentes.
- Tableros y búsquedas global/contextuales independientes; desde tablero acotar a él, desde Mis tareas a asignadas propias; global explícito/visible.
- Nueva búsqueda vacía texto, conserva filtros/orden; consulta/retorno de detalle conserva texto y vista guardada repone texto definido.
- Limpiar quita texto/filtros opcionales, conserva alcance/orden y restaura default completadas; Mis tareas conserva asignación. En vista guardada es variación temporal sin modificar definición.
- Reiniciar solo orden/filtros/completadas del contexto; conservar favoritos/vistas/tema/otros contextos. Vista abierta vuelve a base sin modificar definición; tema por Sistema.
- Filtro recordado inválido bloquea hasta revisar/limpiar explícitamente; sin nombres revocados, quitar condiciones ni globalizar silenciosamente.

### Búsqueda unificada — C-107/C-108

**C-107/C-108 · Contrato vigente:** sugerencias al escribir sobre tareas (título/descripción), comentarios actuales y tableros, mostrando tipo/campo, fragmento y origen. Etiquetas coincidentes sugieren filtros por ID/tablero; archivos/actividad excluidos inicialmente. Elegir abre tablero/tarea/comentario preciso; «Ver tareas que coinciden» es separada, deduplica por tarea y conserva orden personal. Escribir no navega/filtra origen. Sugerencias relevantes agrupadas con espacio por tipo, exactas/prefijos/palabras incompletas. Filtros de tareas aplican a comentarios por tarea padre; Mis tareas propias/sus comentarios, pendientes excluye comentarios de completadas salvo inclusión explícita. Tableros globales navegación separada sin prioridad/responsable/vencimiento ficticios; explicar aplicabilidad. Solo datos autorizados, normalización acentos/ñ vigente, comentario paginado debe poder localizarse. Sustituye límite anterior título/descripción; faltan mecanismos y pruebas.

### Instalación y novedades — C-109

- Matriz inicial: Android/Chrome, iPhone/Safari, escritorio Chrome/Edge y SafariMac; Firefoxweb. Probar instalar/abrir/login/enlaces/cambiar cuenta, registrar versiones; instalar no requisito.
- Instalar aplicación opcional en menú de cuenta, directo donde exista o instrucciones manuales; sin insistencia ni éxito por solo clic.
- Actualización disponible y recarga elegida por usuario; resolver Guardar/Descartar/Seguir editando, sin forzar pérdida de borrador. Contrato online vigente.
- Lote: una pulsación sin diálogo extra con cantidad de sin leer cargadas; fijar IDs al pulsar, excluir posteriores y otras páginas. Resumir marcadas/ya leídas resueltas/no disponibles/falladas; reintentar solo falladas del original autorizadas actualmente. No disponibles sin títulos privados; incertidumbre se reconcilia antes de repetir.

## Testing Decisions

### Enfoque aprobado el 26/10/2026

Probar comportamiento observable a través de tres fronteras, usando las existentes antes de crear interfaces de prueba nuevas. Un buen test expresa actor, entrada/acción, resultado visible o persistido y efectos denegados; evita acoplarse a componentes internos, orden de llamadas o estructura de implementación. Los dobles no sustituyen las verificaciones reales de autorización, persistencia y coordinación entre servicios.

| Frontera | Qué se verifica | Base y extensión |
| --- | --- | --- |
| Operaciones reales de servidor/base | Identidad y permisos, cruces de tablero, tareas/vistas, invitaciones/propiedad, reintentos, conflictos, recuperación, cuotas e importación. | Reutilizar el arnés SQL sobre PostgreSQL descartable y las RPC reales. Adaptar actores y expectativas al modelo privado. Completar integración con Auth, Storage, canales y trabajos en entorno aislado; PostgreSQL solo no acredita servicios Supabase. |
| Aplicación desde navegador | Capturar/encontrar/completar/coordinar/retomar; móvil/escritorio, dos usuarios, pérdida de conexión, conflictos, revocación, foco, navegación, preferencias y PWA. | Hay antecedentes documentados de recorridos con Playwright y dos contextos; no constituyen todavía una suite versionada de esta nueva spec. Crear recorridos mantenibles por acciones del usuario, sin probar cada componente por separado. |
| Programación con fechas controladas | Preview y resultados de recurrencias/anticipación/zonas/exclusiones, recuperación e inactividad, sin esperar días reales. | Nueva frontera pública del módulo de programación, con reloj/fecha controlables. Compartir reglas entre preview/validación/ejecución y verificar consistencia con persistencia; no exponer funciones privadas solo para tests. |

### Antecedentes y limitaciones de la evidencia

Arnés SQL en PostgreSQL temporal aislado: CRUD/orden, cruces de tablero, lote rechazado atómico, permisos tabla/RPC y aislamiento de nombres. Expectativas históricas anónimas por slug y RPC denegada a authenticated deben adaptarse al modelo privado. No usa producción.

Validación histórica de navegador/lint/tipos/build/dependencias corresponde a base anterior; no acredita Auth/membresías/series/P/E nuevas. No se ejecutaron pruebas funcionales durante esta redacción.

### Escenarios transversales mínimos

- Datos ficticios, al menos dos tableros y actores propietario, colaborador, admin no miembro, retirado, no habilitado y sin sesión. Probar servidor/base, consulta, archivo y canal, incluyendo cliente que manipula identificadores.
- Capturar solo título, doble envío y timeout: una intención, una tarea; conservar texto hasta resultado confirmado.
- Completar desde Mis tareas refleja mismo objeto en tablero; mover conserva completado y no cambia futuras ocurrencias.
- Dos editores, comentarios concurrentes y reintentos: conservar borrador autorizado, exigir revisión donde corresponde y evitar conflictos espurios por acciones independientes.
- Revocación con detalle/canal abiertos y respuesta demorada de cuenta anterior: denegar nuevas operaciones y limpiar estado al conocer pérdida de acceso, sin reaparecer datos tras reconectar.
- Invitaciones vencidas/revocadas/consumidas, doble aceptación y sucesor que pierde elegibilidad: ningún bypass ni propiedad parcial.
- Calendario: límites mensuales/anuales, 29 de febrero, ordinal inexistente, distinta zona/cambio de día, anticipación máxima y exceso, excepciones, cambio de regla e inactividad. Nunca más de una pendiente vigente ni completados ficticios.
- Restauración/purga concurrentes, hijo borrado por separado, contenido moderado y padre eliminado: respetar actor/plazo/dependencias.
- Dos cargas por último cupo, binario renombrado, límites exactos y un byte de exceso, reserva abandonada/reintentada: sin adjuntos fantasma ni doble consumo.
- Reemplazo/importación que falla antes de publicar y restauración de instancia de prueba: previo conservado, identidad/archivos coherentes y sin reabrir acceso anónimo.
- Fixture de 500 tareas para observar consultas y exportación completa; no es un límite comercial ni capacidad certificada. No fijar presupuestos de latencia sin medir.
- Matriz móvil 360/390 px y escritorio, teclado virtual, orientación, Atrás, teclado, zoom 200 %, movimiento reducido y temas; cambios remotos no roban foco/columna.
- Instalación PWA, login/enlaces, cambio de cuenta y actualización en dispositivos/navegadores admitidos; manifest no prueba instalación ni seguridad de caché.
- Piloto de cinco recorridos P26 con personas: registrar pasos y tropiezos, sin analítica externa o puntuación de productividad. Las pruebas automáticas no sustituyen facilidad de uso.

### Criterio por incorporación

Todos son escenarios especificados, todavía no ejecutados. Si un criterio menciona un detalle pendiente, primero cerrar ese contrato; no inventar el resultado de una prueba a partir de un hueco.

| ID | Criterio de aceptación |
| --- | --- |
| P01 | Completar desde Mis tareas actualiza la misma tarea en el tablero, conserva columna y no altera futuras ocurrencias. |
| P02 | Escribir tres títulos seguidos; una falla conserva su texto. Doble envío no duplica y tocar fuera no crea. |
| P03 | Una tarea de solo título se puede crear, abrir y completar sin abrir Programar ni añadir pasos; cada acción independiente conserva su contrato. |
| P04 | Sin fecha no muestra un hueco; vencida se entiende sin depender del color; un cumpleaños no tiene casilla; abrir no completa. |
| P05 | Limpiar devuelve resultados; Hoy y Próximos no se solapan; dos tableros con zonas diferentes se evalúan con sus reglas, sin mover tareas. |
| P06 | Ana oculta completadas y Bruno sigue viéndolas. Ana conserva preferencia en otro dispositivo sin modificar el orden manual común. |
| P07 | Abrir y cerrar desde cada origen conserva contexto; Atrás/Adelante no repiten escrituras ni eluden Guardar/Descartar/Cancelar. |
| P08 | Flujo principal completo con teclado; foco retorna al invocador; zoom 200 % y movimiento reducido conservan acciones y textos utilizables. |
| P09 | Crear, editar, asignar y comentar con teclado abierto; Guardar/cierre alcanzables; ningún desplazamiento horizontal en detalle. |
| P10 | Fallo de búsqueda ofrece reintentar, cero coincidencias ofrece limpiar, y acceso perdido retira contenido. No se insertan ejemplos ni tutorial obligatorio. |
| P11 | Miembro abre la misma tarea; ajeno recibe mensaje genérico. Repetición reemplazada abre historial autorizado, no la actual por sustitución silenciosa. |
| P12 | Login, detalle, errores y nombres accesibles están en español; el mismo vencimiento conserva su día entre dispositivos en distintas zonas. |
| P13 | Favorito de Ana no aparece como favorito de Bruno; tras revocación no queda nombre ni acceso en Favoritos. |
| P14 | Teclado y botón abren el mismo buscador; no captura escritura ni altera texto del editor; móvil funciona sin atajos. |
| P15 | Una misma acción con varios motivos produce un aviso por persona; reintento no duplica; aviso vencido no borra comentario ni tarea. |
| P16 | Consultas, búsqueda, exportación, adjuntos y novedades rechazan cruces de tablero y no revelan conteos/títulos al actor ajeno. |
| P17 | Un PATCH con owner_id/board_id/autor falsos no modifica nada; dos usuarios no consumen la misma invitación ni dejan dos propietarios. |
| P18 | Dos ediciones incompatibles conservan ambos textos y exigen revisar; repetir operación tras timeout recupera su resultado sin duplicar efectos. |
| P19 | Simular caída entre guardar y procesar, repetir ejecución y volver tras una semana: un pendiente vigente, ningún completado ficticio y exclusiones conservadas. |
| P20 | Revocar mientras hay detalle abierto y luego reconectar: no reaparecen tarjetas, resultados ni borradores privados de la cuenta anterior. |
| P21 | Restaurar padre conserva el borrado independiente del hijo; moderación respeta actor; restaurar/purgar simultáneamente no publica contenido parcial. |
| P22 | Dos cargas compiten por último cupo y solo una confirma; borrar no libera antes de purga; binario renombrado se rechaza. Denegar nuevas descargas tras revocar y documentar duración/residuo de enlaces temporales emitidos antes, sin prometer retirar copias descargadas. |
| P23 | Dataset ficticio de 500 tareas no carga todas sus conversaciones para mostrar tarjetas; paginar no omite/duplica resultados en un conjunto estable y exportar no trunca. |
| P24 | Exportar/importar conserva alcance sin permisos reutilizables; falla previa mantiene tablero original; restaurar instancia de prueba recupera también archivos. |
| P25 | Fallo simulado se puede diagnosticar por referencia/estado sin leer tareas ajenas; migración fallida tiene recuperación ensayada. Mantener auditoría de dependencias existente. |
| P26 | Personas del piloto pueden completar recorridos sin intervención del autor; cualquier bloqueo de privacidad, pérdida o calendario impide declarar listo el MVP. |
| E01 | Asignar/quitar etiqueta no mueve ni completa; miembros de otro tablero no ven su catálogo. C-100: colaborador crea/renombra/aplica/quita, solo propietario elimina catálogo; probar límites 40/100/10, duplicados, cumpleaños y OR con otros filtros. C-101: recuperación siete días solo propietario, herencia activa al generar, copia de origen y respaldo completo de activas. |
| E02 | C-100: recuperar consulta completa; global dinámico, tablero específico fijo, Mis tareas asignadas al propio usuario. Cambiar filtros no sobrescribe; Actualizar/Guardar como nueva/Restablecer conservan sus alcances. Probar límites 50/60 y nombre único por contexto. Fechas relativas se recalculan y acceso se revalida. C-101: referencia explícita inválida bloquea hasta revisar/confirmar; recuperación siete días solo usuario y conflicto conserva variación sin sobrescribir. |
| E03 | Cambiar tema no recarga ni pierde el editor; prioridades/foco/errores se distinguen en ambos modos. |
| E04 | Copiar no cambia origen ni dispara asignaciones históricas; pasos reiniciados y ningún archivo privado duplicado. |
| E05 | Un reintento no duplica evento y actor sin permiso no ve historia. C-105: verificar 180 días por evento, ocultación/restauración sin reinicio, purga dependiente y respaldo/atribución sin avisos antiguos. |
| E06 | Probar instalar/abrir/cerrar sesión/cambiar cuenta en dispositivos reales; un cache no muestra contenido de otra cuenta. Manifest solo no basta. |
| E07 | Al cargar 20 de 80 solo esas 20 cambian; novedades llegadas durante la acción quedan sin leer y fallos parciales se explican. |

### Trazabilidad y condición de entrega

Vincular requisito/acuerdo e ID P/E con escenario, prueba o evaluación y evidencia. Conservar también los criterios previos de acceso, tiempo y recuperación, no solo los 33 del anexo. Bloqueos de privacidad, pérdida de información o calendario incorrecto impiden declarar listo el MVP. Cada extensión requiere su recorrido completo; ni una tabla de spec ni un botón acreditan funcionamiento.

Fixtures y pruebas se ejecutarán cuando exista implementación autorizada, en entornos aislados. Esta publicación no ejecuta SQL remoto, migraciones o pruebas sobre producción.

## Out of Scope

- Registro libre, tableros públicos, creación anónima por URL y habilitación global delegada mediante invitaciones.
- Paridad completa con Asana/Trello/Plane o integraciones con sus APIs; fork de Plane o adopción de su stack por defecto.
- Organizaciones/workspaces, roles personalizados, varios responsables por tarea, traslado entre tableros, subtareas con responsables/fechas propios.
- Estados de columna que completen automáticamente; columnas obligatorias; movimiento automático; recurrencias relativas al completado.
- Push, correo automático, sincronización con Google Calendar, app móvil nativa y cola de escrituras offline. PWA mantiene el contrato online.
- Vistas compartidas/públicas, etiquetas jerárquicas/globales, temas por tablero, editor de colores, selector multidioma o traducción del contenido del usuario.
- Paleta general de comandos, sidebar permanente, barra inferior inicial, tutorial obligatorio o datos de ejemplo automáticos.
- Versiones del texto de comentarios y restaurar valores desde actividad; borrar archivos vigentes por antigüedad; vaciado inmediato que eluda los siete días.
- Adjuntos distintos de .txt/.md, previsualización/descarga remota automática de enlaces, lectura privada universal por admin y copias de conversaciones/archivos al duplicar tarea.
- Wiki, Gantt, cycles/modules/epics, estimaciones, dependencias entre tareas como función del producto, automatizaciones genéricas e IA.
- Telemetría externa por defecto, ranking o puntuación de productividad.
- Implementación, contratación de servicios, commit/push, migración o despliegue por el solo hecho de publicar esta spec. La invocación actual autoriza su publicación.

## Further Notes

C-112/Q61–62: «Incluir historial de repeticiones» apagado por defecto, independiente de completadas y guardable en vistas/preferencias; busca reemplazadas/comentarios autorizados, muestra estado/fecha/origen y abre destino sin reabrir. Limpiar/Reiniciar lo desactiva. Reprogramar tras detener crea nueva serie con misma tarjeta primera; anterior detenida conserva historia/conteos. Borrar/restaurar anterior no afecta nueva ni tarjeta; confirmación explica transición, sin duplicar/regenerar pasado.

### Estado y decisiones todavía abiertas

Actualizada el 27/10/2026 hasta C-112. Alcance completo preservado. `ready-for-agent` sigue la skill; fase actual: especificación/preparación. DT-0.1 local fija diseño recomendado y gates G01–G08; no ejecutados.

Antes de implementar cada bloque afectado, resolver:

| Bloque | Detalle pendiente |
| --- | --- |
| E01–E05 / P06 | Contratos funcionales cerrados C-100–108; faltan normalización/medición, formatos/mapeos de importación, versiones/concurrencia, ranking/índices/destinos de búsqueda y pruebas de copia/actividad/purga. Borradores y permisos conservan contratos vigentes. |
| PWA E06 | C-109 fija matriz inicial e instalación/actualización; faltan mecanismos/pruebas por versión de sesión, caché, login/enlaces y cambio de cuenta. |
| Lote E07 | C-109 fija UX/categorías/reintento; falta respuesta por ID, autorización/concurrencia, reconciliación y pruebas. |
| Calendario y recuperación | C-110–112 cierran contratos; diseño DT-0.1 y pruebas pendientes. |
| Colaboración y enlaces | C-111 cierra creador de referencia, rearme y autovínculos; faltan mecanismos/pruebas, no renegociar estos comportamientos. |
| Diseño técnico P17–P25 | Esquemas/contratos, versiones y claves con retención, ejecución durable y capacidad/costo del hosting, duración de reservas/enlaces, reconciliación, consulta/orden/paginación, formatos de respaldo y recuperación verificable. |

Las 33 propuestas están incluidas. Resolver mecanismos con evidencia y elecciones de experiencia explícitas; antecedentes no sustituyen acuerdos vigentes.

### Fuentes y precedencia

C-01–112: Spec0001 base0.33, MVP0.25, Pantallas0.5, Permisos0.3, Estados0.3, Cierre0.6, CONTEXT y propuestas de Plane, con acuerdos posteriores prevalentes. Fronteras/publicación aprobadas el 26/10/2026. Fuentes locales sin commit/push; conservar coherencia.

Base inspeccionada: 46c94139bac67aaca1d491b29afc3bc999fc288f. Plane: d9726d5c9615756135f3d6cd512ece8e2dd42902. Evidencia estática, no versión implementada del objetivo.

### Continuación del trabajo

Q61–62/C-112 cierran auditoría funcional. Consolidación y diseño DT-0.1 preparados localmente; siguiente: tickets por dependencias/evidencia y reglas del loop. Mantener todas las E en el alcance. Esta publicación no crea automáticamente tickets adicionales ni inicia implementación.
