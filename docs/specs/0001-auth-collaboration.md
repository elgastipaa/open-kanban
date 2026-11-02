# Spec 0001 — Identidad, tableros privados y colaboración

Actualización documental C-100–112 (27/10/2026): calendario CF-04/07/09, avisos/cuota/enlaces CF-15/16/18, preferencias/búsqueda CF-13–14 y ampliaciones CF-22–27. Complementa revisión base; todas las P/E se conservan.

Estado: **borrador 0.33; alcance P01–P26 y E01–E07 aprobado por C-99, sin autorización de implementación**. Continúa la especificación de la app 1.0.

La definición integral del producto y la programación genérica se desarrollan en [MVP 1.0](./MVP-1.0.md), revisión 0.25. Este documento conserva trazabilidad y seguridad. Rigen C-01–99 distinguiendo acuerdos de propuestas. El [cierre funcional](./CIERRE-MVP-1.0.md), revisión 0.6, [Pantallas](./PANTALLAS-MVP-1.0.md), revisión 0.5, [matriz de permisos](./MATRIZ-PERMISOS-MVP-1.0.md), revisión 0.3, y [Estados y errores](./ESTADOS-Y-ERRORES-MVP-1.0.md), revisión 0.3, consolidan las incorporaciones de Plane. Los escenarios siguen sin ejecutar. C-80 corrige C-72: sucesor elegido obligatorio; automático solo como reparación excepcional. Contratos históricos incompatibles no forman parte del alcance actual.

Base inspeccionada: `main`, commit `46c94139bac67aaca1d491b29afc3bc999fc288f`. La instancia original está operativa en Vercel y Supabase. Esta especificación no modifica ese entorno ni autoriza migraciones o despliegues.

## 1. Objetivo y acuerdos

Permitir que las personas habilitadas por el administrador entren con Google, creen tableros privados, los compartan y organicen tareas personales y colaborativas con programación opcional. OpenKanban es la base funcional; la creación pública/anónima deja de formar parte del MVP objetivo. Las referencias Asana, Trello, Google Tasks y Microsoft To Do expresan una ambición de producto, no una promesa de paridad ni de integración con sus APIs.

Confirmado por el usuario:

- C-01: usar Google como método de acceso.
- C-02: poder compartir tableros con amigos y asignarse tareas.
- C-03: escribir y revisar una buena especificación antes de implementar.
- C-04: conservar stack, interfaz y comportamiento original salvo los cambios necesarios o expresamente acordados.
- C-05: no modificar la base remota ni desplegar sin aprobación separada; no incorporar secretos al repo o al frontend.
- C-06 / D-01: cada tarea tiene cero o un responsable.
- C-07 / D-02: todos los colaboradores pueden editar todas las tareas; asignar indica responsabilidad, no edición exclusiva.
- C-08 / D-03: compartir mediante enlace de un solo uso, con vencimiento y revocable. Su duración exacta sigue pendiente.
- C-09 / D-09: entrada centrada en tableros, que el usuario navega. Una lista global de tareas no reemplaza esa entrada.
- C-10 / D-10: tildar una tarea como hecha conservándola en su tablero y columna, sin borrarla automáticamente.
- C-11 / D-11: para repeticiones del mismo pendiente, cuando llega la nueva solo debe quedar esa como pendiente vigente, sin acumular las anteriores. Una tarea única con fecha límite no desaparece al vencer: se conserva y se destaca.
- C-12 / D-12: destacan los pendientes dentro de la app como base suficiente. Avisos al celular o conexión con Google Calendar son mejoras deseadas a evaluar, no un requisito que bloquee esta primera versión ni autorización para implementarlas.
- C-13 / D-13: cumpleaños son fechas anuales, no tareas de saludar ni acciones que se completan. El usuario propone representarlas en una columna creada por él y mover sus tarjetas con anticipación; visibilidad compartida y ciclo anual aún pendientes.
- C-14 / D-10: completadas visibles por defecto, tildadas y atenuadas; un control permite ocultarlas y volver a mostrarlas sin borrarlas ni modificar su condición de completado. La ubicación exacta y persistencia de la preferencia siguen abiertas.
- C-15 / D-14: fecha límite por día, sin hora. No se agrega una hora opcional por defecto.
- C-16 / D-15: idea inicial de «avisar» moviendo X días antes de la fecha. Se conserva su origen como antecedente; C-43 la sustituye por aparición anticipada sin movimiento automático.
- C-17 / D-16: acceso cerrado a usuarios elegidos por el administrador de la aplicación (inicialmente el solicitante). Google identifica; no habilita por sí solo. Se descarta la propuesta anterior de registro libre y creación pública por URL.
- C-18 / D-17: crear y compartir tableros, asignar tareas y administrar roles. La propiedad, reabierta en 0.10, queda resuelta por aceptación de la recomendación en C-23. La admisión global se resuelve en C-22.
- C-19 / D-18: programación genérica opcional por tarea, con recurrencias configurables: cada X días, días elegidos de la semana, cada dos semanas y opciones de series de calendario. No es una función exclusiva de cumpleaños. El catálogo preciso se desarrolla en MVP 1.0.
- C-20 / D-18: conservar simplicidad de captura/uso y abrir opciones temporales avanzadas desde un botón tipo reloj. Una tarea sencilla no exige fecha, repetición ni movimiento.
- C-21: la meta del MVP es combinar organización personal, Kanban y colaboración; conservar la base operativa no obliga a conservar el modelo público del producto original. No se incorporan funciones no solicitadas por su sola presencia en productos de referencia.
- C-22 / D-16: solo el solicitante controla la admisión a la app; los habilitados no pueden dar entrada global a nuevos amigos. Compartir un tablero requiere destinatario ya habilitado. No se pretende lanzamiento público.
- C-23 / D-04/D-17: acepta recomendación de roles y privacidad: cada habilitado crea y es dueño de sus tableros; propietario y colaborador como roles iniciales; miembros ven todo el tablero. La administración global no otorga membresía automática. Recuperación de propiedad sigue pendiente.
- C-24 / D-11: calendario fijo y alcance explícito de edición. C-38 excluye la variante relativa al completado.
- C-25 / D-15: reemplazo de la anterior pendiente al aparecer anticipadamente una nueva, ahora en la columna de aparición según C-43. La regla general de no acumular pendientes sigue vigente. Ver MVP 1.0, sección 9.
- C-26 / D-10: visualización de completadas e historial como preferencia personal configurable. No cambia lo que ven otros ni elimina contenido; ubicación, alcance de persistencia y presentación del historial por concretar.
- C-27: mover manualmente tareas entre columnas para el flujo Kanban. El usuario corrige «tablero» a «columna»; no solicita traslado entre tableros. Mover y completar siguen siendo acciones independientes.
- C-28: calendario como resumen pequeño; gestión de tareas como foco y opciones temporales adicionales desde reloj, sin calendario siempre visible como pantalla dominante.
- C-29 / D-05/D-06: retirar acceso conserva contenido. Se pospone resolver responsables, recuperación y propiedad; no se interpreta como aprobación de borrados o transferencias automáticos.
- C-30 / D-08: incluir Mis tareas como vista de asignadas de distintos tableros/columnas; permite completarlas y refleja cambios en el origen. Misma tarea, sin copia, traslado ni completado independiente.
- C-31: el flujo y las columnas son definidos por el usuario. Puede usar una sola columna sin mover tareas o varias a elección. No se requieren «Pendientes», «En curso» ni otra etapa estándar; los ejemplos no imponen estructura.
- C-32 / D-11/D-15: abrir una tarea recurrente permite editar la serie y elegir la columna de aparición de próximas ocurrencias, cambiándola por ejemplo de A a B. C-34 resuelve que la actual visible se conserva.
- C-33 / D-11: al borrar una tarea recurrente, ofrecer borrar solo esa repetición o la serie entera. C-35 distingue eliminar toda la serie de detenerla conservando contenido; contrato en MVP 1.0, sección 8.4.
- C-34: editar la serie afecta solo a próximas repeticiones, no a la tarjeta actual ya visible; el usuario puede modificar esa actual por separado.
- C-35: acepta ofrecer «Dejar de repetir» y «Eliminar toda la serie» con los significados propuestos: detener conserva lo existente; eliminar incluye repeticiones e historial, advirtiéndolo explícitamente. Recuperación y carreras técnicas siguen por especificar.
- C-36: al eliminar una columna usada por series, acepta indicar cuáles se afectan y resolver su ubicación sustituta. Falta concretar el flujo conjunto con tarjetas actuales y reglas de movimiento.
- C-37: acceso mediante botón compacto a Series aunque la tarea esté completada/oculta o no haya una visible. C-42 confirma alcance; campos/estados visuales propuestos en MVP 1.0, sección 8.5.
- C-38: solo recurrencias por calendario, por ejemplo lunes, cada N días, martes cada N semanas o día 23 de cada mes. Excluir «N días después de completar»; completar no cambia las siguientes fechas.
- C-39: mover manualmente solo cambia ubicación. Reabrió el movimiento programado; C-43 resuelve elegir aparición anticipada en su lugar.
- C-40: Mis tareas se ordena principalmente por fecha límite, con alternativa por fecha de creación. Dirección, sin fecha y desempates se proponen por separado; no imponer creación como segundo criterio obligatorio.
- C-41: tareas de usuarios retirados permanecen; quien conserve permisos puede borrarlas expresamente. No se aprueba borrado, completado ni traslado por retirada. Responsable inelegible/propiedad por cerrar.
- C-42: acepta Series con todas las series de tableros accesibles, filtrables por tablero, incluidas las creadas por otros colaboradores.
- C-43: acepta aparición anticipada opcional, elegida por el usuario; sustituye movimiento automático. Plantea conflicto cada 3 días/4 de anticipación; C-47 confirma el límite propuesto.
- C-44: acepta vencimientos más antiguos primero, luego próximos y sin fecha al final; expresa nuevas debajo para orden de creación/manual. No se aplica añadir al final cuando contradiga el orden por vencimiento activo.
- C-45: busca prevenir reaperturas accidentales; plantea abrir detalle para destildar y/o grupo colapsable de completadas abajo. C-48 confirma la combinación; colapsado inicial por concretar, sin cambiar silenciosamente el acuerdo anterior de visibles por defecto.
- C-46: pide investigar fechas especiales y diferencias reales frente a Asana para pulir el MVP. Hallazgos en Referencias de producto; ninguna capacidad adicional se incorpora por el solo hecho de estar en Asana.
- C-47: acepta anticipación y solapamientos: X debe ser no negativo y menor que la separación mínima entre vencimientos. Cada 3 días admite máximo 2 de anticipación; no habilita pendientes simultáneas.
- C-48: reafirma orden y acepta completadas: grupo colapsable al pie de cada columna y en Mis tareas, reapertura desde detalle. Preferencia personal; no mueve tarjetas ni cambia lo que ven otros.
- C-49: acepta fechas especiales según la recomendación presentada: fecha mensual inexistente usa último día disponible conservando el ancla original. Detalles adicionales de 29 de febrero anual y ordinales inexistentes siguen candidatos en MVP 1.0, sección 7.2.
- C-50: incluir comentarios, menciones y adjuntos. Confirma necesidad de conversación sobre las tareas; permisos, almacenamiento y relación con series por concretar.
- C-51: incluir checklist sencilla de subtareas/pasos, sin configuración propia de tareas independientes. No implica responsables, fechas o recurrencias por paso.
- C-52: incluir búsqueda y filtros; campos, alcance y comportamiento detallados candidatos en MVP 1.0, sección 14.4.
- C-53: incluir bandeja de novedades dentro de la aplicación. Eventos, destinatarios y lectura por concretar; no equivale a aprobar notificaciones externas.
- C-54: acepta checklist plana con texto/casilla, alta, edición, orden y borrado, sin responsables ni fechas propias. Tildar todos los pasos no completa la tarea; completar con pasos pendientes pide confirmación sin marcarlos realizados. Reabrir conserva las casillas.
- C-55: acepta plantilla de checklist para series, con pasos sin marcar en cada nueva ocurrencia. Cambiar la actual no afecta próximas; editar la serie sí. Comentarios y archivos pertenecen a su ocurrencia, no se copian automáticamente ni se borran al reemplazar una pendiente; se conservan con ella en el historial.
- C-56: acepta novedades por asignación al responsable, mención al mencionado, comentarios al responsable y creador, y cambio de vencimiento por otro al responsable. No avisar por cada paso, movimiento de columna ni repetición automática. Leídas/no leídas; leer no completa la tarea. Casos técnicos y de edición siguen pendientes.
- C-57: acepta que mencionar no concede acceso, los adjuntos son privados del tablero y búsqueda/novedades no muestran información de un tablero tras perder acceso. Implementación de autorización y límites de enlaces temporales por especificar y verificar.

- C-58: recuperación de contenido eliminado durante 7 días. Incluye el tablero eliminado al retirar a su dueño sin otros miembros. Cómputo exacto, permisos, alcance de borrados individuales y purga se concretan en MVP 1.0, sección 4.6.
- C-59: al retirar administrativamente al propietario, ofrecer elegir nuevo dueño entre otras personas con acceso. Si no hay ninguna, eliminar el tablero con recuperación 7 días; al recuperarlo exigir nuevo propietario. No asignar automáticamente al administrador ni restaurar acceso al usuario retirado. Modifica C-29/C-41 solo para este caso de tablero sin otros miembros; las tareas de un retirado en tableros activos permanecen.
- C-60: intención de impedir Excel, imágenes, videos y archivos grandes. Sugiere menos de unos 24 KB por adjunto; es tentativo, no límite final. Diferencia verificada entre cuota de base de datos y Storage y propuesta de formatos en MVP 1.0, sección 14.3.

- C-61: acepta la recomendación de adjuntos solo `.txt` y `.md` hasta 24 KB, con enlaces para todos los demás archivos. Sustituye la indefinición de formatos de C-60. Detalles técnicos de validación y unidades en MVP 1.0, sección 14.3.
- C-62: el texto pegado que parezca una URL debe ser clickeable; detección y apertura seguras sin integrar el proveedor de destino. Ubicaciones y casos de formato candidatos en 14.3.
- C-63 (antecedente resuelto por C-64): propuso cuota total de 200 MB y borrar adjuntos antiguos al alcanzarla. La alternativa aceptada conserva archivos vigentes y bloquea cargas; no hay autorización para eliminar archivos reales durante la spec.
- C-64: acepta cuota global de 200 MB, aviso al 80 %/160 MB, rechazo de cargas que excedan el máximo y conservación de archivos vigentes. Limpieza automática solo tras vencer recuperación o para residuos técnicos de cargas fallidas; archivos en recuperación siguen consumiendo cuota.
- C-65: solicita limpieza manual de adjuntos, incluidos archivos de tareas completadas, con elección por administrador y propietarios, y avisos también a propietarios al alcanzar límites. Alcance propuesto: propietario en sus tableros, administrador con gestión acotada de almacenamiento sin lectura global de contenido. Son avisos de cuota global, no cuotas nuevas por tablero. Detalles de permisos y presentación en MVP 1.0, 14.3.

- C-66: acepta guardado con estados claros de guardando/guardado/error, sin declarar guardado lo que falló.
- C-67: acepta consulta de contenido ya cargado sin conexión, indicando posible desactualización, y conservar texto en edición; sin promesa de edición offline sincronizada en el MVP.
- C-68: acepta detectar conflicto cuando dos personas editan el mismo contenido, conservar borrador y pedir revisar en vez de sobrescribir silenciosamente.
- C-69: acepta dejar pendientes y futuras repeticiones sin responsable cuando se retira a esa persona, conservando las tareas y su autoría histórica. Mantener excepción de tablero sin miembros de C-59.
- C-70: acepta recordar orden, filtros y visibilidad de completadas como preferencias personales, sin cambiar cómo lo ven otros. Persistencia exacta y valores iniciales se concretan en CF-13.

- C-71: acepta acceso por habilitación de correo Google desde administración, invitación de tablero de 72 horas/revocable/un uso para personas habilitadas y salida de colaboradores.
- C-72 (corregido por C-80): se había registrado salida con sucesor opcional/automático; ya no rige esa opción normal. Se conserva reasignación administrativa y borrado recuperable sin otros miembros, sin lectura administrativa implícita.
- C-73: acepta recomendaciones presentadas de catálogo de recurrencias, finales, zona por tablero, previsualización y fechas especiales (29 febrero→28, quinto día inexistente se omite).
- C-74: acepta reabrir solo vigente antes de aparecer posterior; antiguas consultables. Recuperación conserva activa/detenida y actualiza calendario sin pila de atrasos ni responsables retirados.
- C-75: acepta ciclo anual de cumpleaños sin completado: siempre visible sin anticipación, o visible solo de D−X a D inclusive con anticipación; después siguiente año/ventana y configuración accesible en Series.
- C-76: acepta recuperación siete días desde borrado con vencimiento visible, traslado de tareas/series antes de borrar columna y restauración sin recuperar accesos/invitaciones ni deshacer ediciones.
- C-77: acepta autor edita solo su comentario, propietario modera sin reescribir texto ajeno y restaura lo que él moderó; menciones solo a miembros actuales. Precisa que las menciones de quien sale quedan como texto, sin vínculo al usuario.
- C-78: acepta búsqueda título/descripción, filtros presentados, próximos siete días/hoy/vencidas diferenciados, completadas visibles por defecto con preferencias y exclusión de avisos propios/duplicados.
- C-79: acepta retención de novedades 90 días, sin borrar tareas/comentarios, y 20 adjuntos por tarea además de tamaño/cuota ya acordados. Casos de retención/conteo complementarios por cerrar.

- C-80: propietario debe elegir sucesor para salir, sin opción de salir sin elegir. Reasignación automática solo como protección excepcional ante fallo/inconsistencia, al miembro habilitado de mayor antigüedad en el tablero. Nunca tablero activo sin dueño. Administrador conserva facultad de reasignar. Sustituye C-72 donde era incompatible.
- C-81: reingresar no recupera permisos anteriores, asignaciones, menciones activas ni avisos atrasados del período afuera; se conceden permisos actuales explícitamente. Menciones antiguas siguen texto.
- C-82: archivos retenidos por recuperación cuentan dentro del límite de 20 por tarea, con desglose visible; no se libera plaza al borrar hasta purga.
- C-83: novedades no leídas también caducan a los 90 días; tareas y conversaciones permanecen.

- C-84: adopta para primera prueba un botón hamburguesa que abre panel vertical desde la izquierda, con Tableros, Mis tareas, Series, Novedades/contador y bloque inferior de cuenta/preferencias, Administración según rol y cerrar sesión. Búsqueda visible fuera del panel.
- C-85: acepta separar navegación global de menú ⋯ del tablero (miembros, archivos, recuperación, configuración, importar/exportar, salir/eliminar según rol) y de acciones de tarea dentro de su detalle (campos, checklist, conversación, archivos y reloj).
- C-86: acepta panel superpuesto sin comprimir columnas, cierre al elegir/fuera/control explícito, iconos con texto/estado activo, uso por teclado y sin depender de gestos. Sin barra inferior adicional inicial; evaluar cambios por necesidad observada en la primera prueba. Detalle UX en Pantallas 0.2 no equivale a implementación.

- C-87: acepta creación rápida de tarea por título dentro de la columna, sin formulario avanzado obligatorio.
- C-88: acepta confirmar título/descripción/responsable/prioridad/fecha mediante Guardar.
- C-89: acepta acciones independientes: checklist, comentario y archivo se guardan con su acción. Cancelar edición de campos no deshace acciones ya persistidas.
- C-90: acepta cierre con cambios pendientes mediante Guardar y cerrar / Descartar / Seguir editando; fallo de guardado conserva texto y editor. No se interpreta la mención informal a refrescar como garantía de recuperación de borradores tras recarga/cierre del navegador.
- C-91: acepta detalle móvil que ocupa pantalla disponible sin scroll horizontal, con cierre y acciones claros.

- C-92: acepta respaldo/reemplazo protegido presentado: exportar tablero con nuevas funciones/adjuntos, excluir secretos/invitaciones/permisos; importación por propietario previsualizada, compatible con v1, sin mezclar, manteniendo dueño/miembros destino. Responsables incompatibles sin asignar, no avisos históricos ni atrasos acumulados. Conservar previo 7 días contando cuota; sin espacio o fallo, no destruir previo ni dejar contenido parcial. Detalles técnicos CF-19 siguen por diseñar/verificar.
- C-93: reafirma aplicación cerrada: quitar landing de creación pública y ofrecer primero Google; solo cuentas previamente habilitadas por administrador pueden crear/gestionar tableros privados. Sesión existente habilitada entra a Tableros. No acceso por conocer URL ni autoalta por invitación. Administrador habilita identidad, no crea cuenta Google/contraseña. Contrato en MVP 4.0; no autorización de despliegue.

- C-94: acepta las cinco recomendaciones de permisos presentadas: nombre/zona del tablero solo por propietario; quienes editan recuperan tareas, moderación la recupera propietario y limpieza administrativa admin; miembros borran sus propios adjuntos y propietario cualquiera del tablero; panel admin con información mínima sin lectura automática de contenido privado; impedir autosuspensión accidental del único admin. Detalles adicionales de recuperación/metadata no presentados siguen señalados en matriz 0.2. Continúa especificación, sin implementar.

- C-95 (2026-10-24): acepta las cinco reglas de estados y errores presentadas: comprobar resultado incierto antes de repetir sin duplicados; revisión explícita de edición propia/actual ante conflicto, sin sobrescritura silenciosa; conservar borradores durante edición sin prometer recuperación tras cierre/recarga ni envío automático al volver conexión; resolver Guardar/Descartar/Cancelar antes de completar/mover/borrar con campos pendientes, manteniendo comentarios/pasos/adjuntos independientes; errores contextuales sin bloquear toda la app por fallos locales y retirada del contenido al perder acceso. Estados y errores 0.2 registra el alcance; otros detalles técnicos/UX siguen pendientes. No autoriza implementación.

- C-96 (2026-10-24): aprueba primer uso presentado: Google/habilitación, estado vacío sin ejemplos automáticos, crear por nombre y primera columna elegida, tarea rápida por título, compartir opcional y tareas asignadas reflejadas en Mis tareas; sin tutorial obligatorio. Agrega que puede entrar con invitación pendiente: no forzar crear tablero propio. Pantallas 2.9 distingue llegada por enlace ya contemplada de descubrimiento de pendientes sin enlace, que requiere acordar destinatario (PE-01); no se considera aprobada una nueva modalidad de invitación por inferencia.

- C-97 (2026-10-24): exige coexistencia de invitación directa y genérica. Directa según propuesta presentada: por correo de persona ya habilitada, pendiente visible en Tableros solo al destinatario, aceptar/rechazar; genérica mediante enlace compartible sin destinatario fijo. Se conservan login, habilitación global, rol colaborador, 72 h/revocación/un uso acordados; genérica no significa pública ni multiuso. No correo automático ni servicio adicional. Pantallas 2.9–2.10; detalles de duplicados/preview pendientes. Solo spec.

- C-98 (2026-10-24): acepta últimas recomendaciones de cierre: una directa pendiente por persona/tablero, mostrar existente en vez de duplicar, renovación explícita al vencer y «Ya es miembro» si corresponde; preview de invitación válido solo con nombre de tablero, invitador y rol, sin contenido. Recuperación ordinaria de tablero por propietario; comentario/archivo borrado por autor recuperable por autor con acceso vigente o propietario; retirada de dueño incluye tableros ya en papelera y resuelve autoridad de recuperación sin reiniciar plazo. Moderación/limpieza administrativa mantienen restricciones. En cambios de serie, conservar exclusiones aplicables, informar cuáles dejan de aplicar, sin recrear pasado ni modificar silenciosamente tarjeta actual; ejemplos aún por revisar. Transición requiere inventario autorizado y propietario explícito de cada tablero existente, nunca asignación al primer login. Acepta consolidar spec y preparar diseño técnico, no implementación ni operaciones remotas. Solicita guardar progreso y abrir nuevo chat con contexto limpio.

- C-99 (2026-10-24): ante la tabla de incorporaciones de Plane, el usuario acepta **todas las P y todas las E**. Se incorporan P01–P26 y E01–E07, incluidos sus alcances y criterios presentados, a la spec actual y al MVP objetivo. E deja de significar una fase futura fuera del MVP: se conserva el prefijo solo para trazabilidad. Registro completo en [Incorporaciones desde Plane](./PROPUESTAS-DESDE-PLANE.md) y consolidación en MVP §16. Incluye identidad de tarea, captura explícita, detalle y tarjetas progresivos, filtros, preferencias por persona/contexto entre dispositivos, navegación, accesibilidad y móvil; enlaces privados, español inicial, favoritos y atajo de búsqueda; novedades, autorización, mutaciones, concurrencia, trabajo durable, realtime privado, recuperación, cuotas decimales, consultas, respaldo, operación y validación; además etiquetas simples, vistas personales guardadas, temas claro/oscuro/sistema, copia puntual, actividad mínima, instalación PWA y lectura por lote de novedades cargadas. La aprobación del resultado no selecciona servicios ni bibliotecas, no acredita compatibilidad PWA y no define valores que la tabla dejó abiertos (por ejemplo retención de actividad o permisos del catálogo de etiquetas). Esos detalles se completan **dentro del alcance aprobado**, sin volver a someter las 33 propuestas a aprobación. Continúa especificación; no autoriza implementación, migración ni despliegue.

- C-100 (2026-10-26): el usuario acepta las siete recomendaciones de la primera ronda E01/E02 («Sí a las 7»). Propietario y colaboradores crean/renombran/cambian color/aplican/quitan etiquetas; solo propietario elimina catálogo. Etiquetas únicas por tablero ignorando mayúsculas y espacios sobrantes, hasta 40 caracteres, 100 activas/tablero y 10/elemento, paleta accesible. Aplican a tareas y cumpleaños; serie tiene selección propia para próximas ocurrencias, con herencia exacta aún pendiente. Varias etiquetas se combinan con OR y con los demás filtros mediante AND; conservar tablero de origen. Vista guarda texto, alcance, completadas, filtros y orden: global dinámico, tablero específico fijo, Mis tareas siempre asignadas al propio usuario. Cambiar filtros no sobrescribe: Actualizar vista / Guardar como nueva / Restablecer vista. Hasta 50 vistas por persona, nombre hasta 60 caracteres, único por contexto Búsqueda/Mis tareas, personales y sincronizadas. Contrato y criterios C100-AC01–07 en Cierre CF-22.1. Borrado/recuperación, herencia/copia/respaldo, referencias inválidas y concurrencia siguen abiertos. El objetivo es una spec que otro agente pueda implementar posteriormente en loop; esta aceptación sigue siendo documental.

- C-101 (2026-10-26): acepta Q8–Q14. Etiqueta eliminada se oculta sin borrar elementos, conserva asociaciones, solo propietario actual recupera siete días y luego purga. Nueva ocurrencia copia activas de plantilla al generarse; editar ocurrencia no cambia plantilla ni editar plantilla cambia generadas. Copia puntual toma activas de origen, no plantilla. Respaldo incluye catálogo activo completo y asociaciones; importar reconstruye dentro del destino sin vínculo cruzado por nombre, v1 sin etiquetas no inventa; vistas fuera del respaldo de tablero. Referencia explícita inválida bloquea vista hasta revisar/confirmar, con mensaje genérico ante revocación; global dinámico sigue adaptándose. Vista eliminada recuperable siete días solo usuario con revalidación. Conflicto entre dispositivos conserva variación, permite cargar actual/guardar nueva; revisar actual antes de actualizar original. Contratos y criterios C101-AC08–14 en Cierre CF-22.2. Colisiones/cupos/asociaciones al recuperar y casos de revisión siguen pendientes. Se conserva fase de especificación y alcance completo.

- C-102 (2026-10-26): acepta Q15–17 y Q19–20; corrige Q18 para búsquedas/filtros. Solo activos cuentan en límites 100 etiquetas/tablero, 10/elemento, 50 vistas/persona. Recuperar requiere cupo; nombre reutilizado exige renombrar sin fusionar ni cambiar identidad. Preview de asociaciones permite liberar lugar u omitir asociación explícitamente y confirma selección válida completa, sin retroactividad ni revivir tareas. Guardar corrección revalida/actualiza vista; referencia restablecida requiere revisar/confirmar, condición quitada no vuelve sola. Guardado tardío no resucita vista borrada: conservar variación, guardar nueva o recuperar por vía específica sin aplicar borrador automáticamente. Búsquedas/filtros ignoran acentos y ñ/n, conservando texto original y separación de identidades/permisos. Falta precisar si esa misma equivalencia rige unicidad de nombres. Contrato/criterios C102-AC15–20 en CF-22.3. No implementación.

- C-103 (2026-10-26): acepta Q18b: crear/renombrar/restaurar etiquetas y vistas usa equivalencia insensible a acentos, ñ/n, mayúsculas y espacios sobrantes para impedir duplicados dentro de tablero o usuario/contexto, respectivamente. Conservar escritura original; sin fusión automática ni cambio de identidad/asociaciones. Mostrar coincidencia solo autorizada. CF-22.4 y C103-AC18b. Se cierra esa decisión funcional sin iniciar implementación.

- C-104 (2026-10-26): acepta Q21–26. Copia propone mismo título editable sin sufijo y columna origen con selector del mismo tablero, al final manual respetando presentación personal. Completadas/históricas autorizadas se copian como nueva puntual pendiente sin modificar/editar/reabrir fuente; eliminadas requieren recuperar, cumpleaños no tienen Duplicar tarea. Tema inicial Sistema y login aplica preferencia de cuenta; modos fijos sincronizados, Sistema por dispositivo, sin perder editor. Desempates por creación ascendente e identidad estable; completadas reciente primero. Preferencias distintas se combinan entre dispositivos; misma preferencia editada desde versión anterior exige revisión, preserva local y permite cargar guardada o revisar/conservar local. Contratos/criterios CF-24.1/CF-13.1 y C104-AC21–26. Siguen pendientes confirmación/origen cambiado de copia, otros defaults/reinicio y mecanismos. No implementación.

- C-105 (2026-10-26): acepta Q27–33. Copia con panel breve título/columna/resumen, Crear copia/cancelar sin efecto y resultado con apertura opcional/contexto conservado; si cambió contenido copiable actualizar preview y revisar preservando título/destino, comentario nuevo no invalida, borrado/acceso perdido bloquea. Actividad E05 con actor, fecha-hora y anterior/nuevo, recuperación quién/cuándo; recientes primero/progresiva. Retener 180 días desde evento sin reinicio por restaurar/importar; ocultar con tarea y purgar dependiente, sin edición/borrado individual. Actor histórico sin permisos/menciones; distinguir Sistema/Actividad importada sin fingir autenticación local. Respaldo incluye vigentes de tareas exportables, preserva fechas/atribución y no crea avisos retroactivos ni revive vencidos; papelera fuera. CF-24.2/CF-25.1 y C105-AC27–33. Continúa especificación, no implementación.

- C-106 (2026-10-26): acepta Q34–39: defaults por contexto (Tablero manual/sin filtros y completadas visibles; Mis tareas todos accesibles/sin extras/vencimiento y completadas visibles; lista búsqueda pendientes/sin extras/vencimiento y sin fecha al final), respetando preferencias existentes. Contextos independientes, buscar desde tablero acota a él y desde Mis tareas a asignadas; global explícito. Nueva búsqueda vacía texto preservando filtros/orden, retorno conserva consulta y vista recupera texto. Limpiar conserva alcance/orden y restaura completadas de contexto, sin cambiar definición E02 ni asignación. Reiniciar solo contexto/base, preservando favoritos/vistas/tema/otros; tema por Sistema. Filtro recordado inválido bloquea hasta revisión/limpieza sin nombres privados ni ampliar alcance. CF-13.2/C106-AC34–39.

- C-107 (2026-10-26): solicita búsqueda unificada tipo Vercel con coincidencias mientras escribe en múltiples campos/entidades, explícitamente títulos/tareas/comentarios/tableros, tipo/campo y contexto visibles, navegación/filtrado solo al elegir. Prefiere versión rica si viable. Sustituye exclusión de comentarios/límite a título-descripción de tareas de C-78/CF-14; mantiene privacidad/contexto/normalización y no introduce comandos de escritura. Alcance adicional, ranking, destinos y filtros por tipo por cerrar en CF-14.1. No se implementa durante entrevista.

- C-108 (2026-10-26): acepta Q40–43. Búsqueda en título/descripción de tareas, comentarios actuales y tableros, con etiquetas como sugerencias de filtro por ID/tablero; archivos/actividad fuera del alcance inicial. Elegir abre tablero/tarea/comentario preciso; Ver tareas que coinciden es separada y deduplica tareas aunque coincidan varios comentarios. Teclear no navega/filtra origen. Sugerencias relevantes agrupadas con espacio por tipo, priorizando exactas/prefijos y palabras incompletas; lista posterior conserva orden personal. Filtros de tareas aplican a comentarios por tarea padre; Mis tareas propias y sus comentarios, pendientes excluye comentarios de completadas salvo inclusión explícita. Tableros globales navegación separada, filtros aplicables visibles. CF-14.2 y C108-AC40–43. Falta diseño técnico/pruebas, no implementación.

- C-109 (2026-10-26): acepta Q44–48. Matriz inicial AndroidChrome/iPhoneSafari/escritorioChromeEdge inclSafariMac, Firefoxweb; probar instalación/apertura/login/enlaces/cambio cuenta y registrar versiones, instalar opcional. Instalar aplicación en menú de cuenta sin insistencia, directo o instrucciones manuales según soporte. Actualización avisada y recarga elegida resolviendo Guardar/Descartar/Seguir editando sin perder borrador. Lote una pulsación con cantidad sin leer cargadas y conjunto fijo al pulsar; resumen marcadas/ya leídas resueltas/no disponibles/falladas, reintento solo falladas autorizadas del original y reconciliar incertidumbre antes. CF-26.1/CF-27.1 y C109-AC44–48. Mecanismos/pruebas siguen pendientes; no se aprueba caché privada adicional por la nota técnica ni se implementa.

- C-110 (2026-10-27): acepta Q49–54. Inicio explícito proponiendo fecha existente; semanas lunes–domingo ancladas a semana de inicio, fechas no anteriores y preview actual/futuras. Final inclusivo, N cuenta fechas efectivas no completados; exclusión consume fecha, quinto lunes inexistente no cuenta. Excepción actual vence estrictamente antes de siguiente aparición, sin fusionar/alterar futuras y conserva borrador al rechazar. Recuperar serie finita pasada reconstruye máximo última válida incluso no materializada/vencida (1/3/5 borrada2 recuperada6→5), sin intermedias/extender y sin sustituta si última excluida; detenida sigue detenida. Recuperar ocurrencia deshace solo exclusión de su borrado, sin otras exclusiones ni reactivar serie; posterior la deja histórica, padres primero e hijos borrados aparte no reviven. Recuperación ordinaria pasos/series/columnas por dueño/colaborador actual con edición siete días, preserva excepciones de moderación/admin y traslados. CF-04.1/CF-07.1/CF-09.1 y C110-AC49–54. Siguen pendientes conversión incompatible, N al editar y detalles delimitados; no implementación.

- C-111 (2026-10-27): acepta Q55–60. Convertir conserva tarjeta como primera contandoN, previewactual/futuras; incompatibilidad exige elección/confirmación de fecha sin cambios silenciosos/duplicación. Editar final se expresa N próximas fueraactual/pasado, muestra nuevafinal; editarotroscamposnoreinicia. Nuevas ocurrencias usan creador de serie elegible, original conserva autor, sin sustituirretiradoporowner. Avisos de umbral porpersonanivel solo nuevo cruce tras bajar y 24 h desde el anterior; permanecerencima no periódico, blockeduploadsiempreinmediato. Autolinks descripción/comentarios/pasos; tarjetatítuloabre detalle y URLexterna controlseparado. HTTPHTTPSwww→HTTPS, dominiosueltotexto, puntuaciónfuera, texto conservado y apertura explícita segura sin previews/descargas/HTML/esquemasactivos. CF-04.2/15.1/16.1/18.1 y C111-AC55–60. No implementación.
- C-112 (2026-10-27): el usuario acepta Q61–62 («Dale»). Búsqueda ofrece «Incluir historial de repeticiones», desactivado por defecto, independiente de «Incluir completadas» y guardable en vistas; incluye ocurrencias reemplazadas y sus comentarios autorizados, con estado/fecha/origen y apertura precisa sin reabrir ni modificar. Volver a programar tras «Dejar de repetir» crea nueva serie usando la misma tarjeta como primera; anterior detenida conserva historial, sin reactivar pasado/exclusiones ni reiniciar sus conteos. Confirmación explica cambio; borrar/restaurar anterior no afecta tarjeta ni calendario de nueva. Todas las P/E permanecen. Contratos CF-14.3/CF-08.1; C112-AC61–62. No implementación.

**Los comportamientos respaldados por C-01 a C-112 están acordados**; los detalles adicionales no presentados siguen siendo propuestas, distinguiendo C-63 y C-72 como antecedentes sustituidos. Las aceptaciones se refieren a recomendaciones presentadas, no a detalles no presentados de los documentos. Aprobar contratos funcionales no autoriza implementación ni certifica viabilidad técnica. El glosario está en [CONTEXT.md](../../CONTEXT.md).

## 2. Estado actual verificado en el código

| Área | Evidencia | Consecuencia para esta evolución |
| --- | --- | --- |
| Datos | `src/lib/types.ts`: tablero, columna y tarea; sin propietario, miembros ni responsables. | Incorporar identidad y relaciones de acceso; no basta con una pantalla de login. |
| Persistencia | `src/lib/db/` y migraciones 001–012: operaciones mediante RPC. | Reutilizar las operaciones, revisando autorización en todas sus variantes. |
| Seguridad | 012 concede ejecución a `anon`; varias funciones usan `SECURITY DEFINER`. | Cerrar acceso anónimo y controlar cada acceso autenticado por tablero. |
| Colaboración | `use-realtime.ts` y `use-presence.ts`: Broadcast y Presence públicos por slug. | Conservar sincronización, pero autorizar canales y resolver revocación. |
| Navegación | `src/proxy.ts`: normaliza paths y query strings como slugs. | Reservar rutas de Auth/invitación y preservar sus parámetros; el proxy actual rompería callbacks si se reutiliza sin ajustes. |
| Creación | `use-board-sync.ts`: persistencia diferida de tableros visitados por URL. | Definir creación privada explícita y conflictos de URL sin apropiarse de tableros ajenos. |
| Respaldo | `export.ts` / `import.ts`: JSON v1, sin identidades; importación destructiva en varias solicitudes. | Mantener lectura de v1 y definir qué ocurre con asignaciones y permisos. |

La revisión es del repo; no se inventarió el contenido actual de la base remota para preparar este documento.

## 3. Alcance funcional y límites

Primera versión objetivo; las precisiones todavía abiertas se identifican en sus contratos:

- F-01: inicio/cierre de sesión con Google y retorno seguro al destino solicitado.
- F-02: tableros privados por defecto y una entrada «Mis tableros», separando propios y compartidos.
- F-03: compartir por invitación, ver miembros y retirar acceso.
- F-04: asignar y desasignar responsables entre los miembros del tablero.
- F-05: vista secundaria «Mis tareas», confirmada en C-30: reúne asignadas al usuario de tableros accesibles y permite completarlas sobre la misma entidad de origen. No reemplaza la entrada por tableros.
- F-06: completar por casilla, fechas límite, repeticiones y destacados dentro del tablero según C-10–12. Sus detalles y criterios temporales se desarrollan abajo; no se implementan durante esta revisión.
- F-07: aparición anticipada opcional confirmada C-43, sin movimiento automático. Contrato vigente en MVP 1.0, sección 9; límite de anticipación confirmado C-47.
- F-08: habilitación global administrada, cierre de acceso público y gestión de usuarios autorizados. Flujo de admisión y suspensión por cerrar en MVP 1.0.
- F-09: panel opcional de programación por tarjeta, catálogo de recurrencias, edición de series y excepciones; contrato candidato en MVP 1.0.
- F-10: acceso compacto a Series independiente de tarjetas visibles, con alcance confirmado C-42: todos los tableros accesibles y filtro por tablero. Presentación candidata en MVP 1.0, sección 8.5.

- F-11: comentarios, menciones y adjuntos privados, incluidos por C-50.
- F-12: checklist sencilla de pasos, incluida por C-51; no subtareas independientes.
- F-13: búsqueda y filtros, incluidos por C-52.
- F-14: bandeja personal de novedades dentro de la app, incluida por C-53.

- F-15: enlace privado estable a tarea u ocurrencia, español inicial, favoritos de tablero y Ctrl/Cmd+K para búsqueda existente, aprobados P11–P14.
- F-16: etiquetas planas del tablero con nombre/color y filtro, aprobadas E01; C-100 cierra permisos del catálogo, límites, filtros y elementos etiquetables; C-101 cierra recuperación básica, herencia, copia y respaldo; C-102 cierra restauración; C-103 cierra unicidad; queda validación técnica.
- F-17: vistas personales guardadas E02; C-100 cierra contenido/alcance, edición explícita y límites. C-101 fija bloqueo, recuperación y conflicto; C-102 cierra revisión/restauración; C-103 cierra unicidad; quedan mecanismos. No vistas compartidas ni copias de tareas.
- F-18: preferencia personal de tema claro/oscuro/sistema, aprobada E03.
- F-19: duplicación puntual dentro del mismo tablero con nueva identidad y campos acotados, aprobada E04 y ampliada por C-101 con etiquetas activas del origen; nunca una serie implícita.
- F-20: actividad mínima en detalle (responsable, fecha, columna, completado y recuperación), aprobada E05 y precisada por C-105: 180 días por evento, borrado/atribución/respaldo; sin versiones de textos ni restauración de valores desde historial.
- F-21: instalación PWA y validación de acceso/login/enlaces en dispositivos, aprobada E06 con funcionamiento online; no push, cola offline ni app nativa.
- F-22: marcar como leídas las novedades actualmente cargadas y autorizadas mediante acción explícita con cantidad, aprobada E07.

F-01–22 se consolidan con C-01–99 y MVP §16; P01–P10 y P15–P26 precisan contratos transversales. No es necesaria una nueva aprobación del alcance de las 33 filas. Permanecen abiertos únicamente los detalles no definidos, inventariados en MVP §16.5. No se incluye rediseño general, organizaciones/workspaces ni integración con Asana/Google Tasks. Google Calendar y avisos push al celular quedan para evaluación separada, sin convertirlos en dependencias del login ni del funcionamiento básico. No se elige un canal externo ni proveedor de correo por defecto.

Se intenta conservar la infraestructura actual. Cualquier dependencia, proveedor, costo o cambio de plan necesario se justificará antes de incorporarlo. No se contrata un proveedor de correo como parte de este brainstorming.

## 4. Decisiones funcionales y preguntas abiertas

| ID | Pregunta | Decisión o propuesta | Estado |
| --- | --- | --- | --- |
| D-01 | ¿Una tarea tiene uno o varios responsables? | Cero o un responsable. | Confirmado |
| D-02 | ¿La asignación limita quién puede editar? | Todos los colaboradores pueden editar todas las tareas; asignar solo indica responsabilidad. | Confirmado |
| D-03 | ¿Invitación por enlace o ligada a un correo? | Coexisten directa a cuenta habilitada y genérica por enlace; 72 horas, un uso, revocables. Sin correo automático. | Confirmado C-97/C-98 |
| D-04 | ¿Quién administra el tablero? | Un propietario y colaboradores; solo el propietario invita, retira acceso, reemplaza por importación y borra el tablero. | Modelo aceptado; efectos de operaciones destructivas y salida pendientes |
| D-05 | ¿Qué pasa al retirar a alguien con tareas asignadas? | Conservar tareas y desasignar pendientes/próximas; conservar autoría histórica. | Confirmado C-69; atomicidad por diseñar |
| D-06 | ¿Qué ocurre al abandonar un tablero o retirar una cuenta propietaria? | Seleccionar sucesor elegible; automático solo como reparación excepcional C-80. Si no hay otro miembro, borrado recuperable; incluir tableros en papelera sin reiniciar plazo C-98. No agregar borrado autónomo de identidad Auth. | Confirmado; mecanismo técnico pendiente |
| D-07 | ¿Cómo tratar los tableros anónimos existentes? | Inventario autorizado y asignación explícita a su dueño; nunca «el primero que abre la URL se lo queda». | Confirmado C-98 |
| D-08 | ¿Qué incluye «Mis tareas»? | Asignadas al usuario entre tableros/columnas; completar modifica origen. Vencimientos antiguos primero, sin fecha al final; alternativa por creación con nuevas debajo. | Confirmado; C-104 cierra desempates y orden de completadas |
| D-09 | ¿Entrada por tableros o lista global? | Navegar primero por tableros; una vista global, si se incorpora, es secundaria. | Confirmado |
| D-10 | ¿Cómo se termina una tarea? | Casilla, conservando tablero y columna; grupo de completadas visible inicialmente. Reabrir desde detalle según C-74; preferencia por usuario/vista/tablero sincronizada entre dispositivos P06. | Confirmado; contrato técnico de preferencias pendiente |
| D-11 | ¿Cómo funciona una serie? | La nueva sustituye la anterior pendiente; editar serie cambia próximas y preserva actual. Detener conserva contenido; eliminar serie incluye historial con advertencia. Casos límite de calendario, excepciones y reapertura por cerrar. | Reglas base y alcance de edición/borrado confirmados; detalles pendientes |
| D-12 | ¿Qué significa «recordatorio»? | Destacados dentro de la app son suficientes para la base. Celular/Google Calendar son deseables para evaluar aparte; destinatario y reglas de destacados aún pendientes. | Canal básico confirmado; detalles pendientes |
| D-13 | ¿Qué representa un cumpleaños? | Fecha anual, sin tarea de saludar ni casilla «ya saludé». El usuario propone tarjeta en una columna y movimiento anticipado; representación exacta, privacidad y ciclo posterior por cerrar. | Naturaleza confirmada; propuesta ampliada |
| D-14 | ¿Fecha límite con o sin hora? | Solo día, sin hora. Regla de cambio de día y zona horaria de referencia por cerrar. | Confirmado; semántica de calendario pendiente |
| D-15 | ¿Se necesita movimiento automático o anticipación? | Aparición anticipada opcional en columna de serie. No hay movimiento automático. | Confirmado; validar límites y ejecución |
| D-16 | ¿Quién puede usar la app? | Solo personas habilitadas por el solicitante; no hay admisión delegada, registro libre ni creación pública por URL. | Confirmado; mecanismo de alta/suspensión por cerrar |
| D-17 | ¿Qué roles y facultades tienen los habilitados? | Cada habilitado crea y administra sus tableros entre miembros habilitados; propietario y colaborador. Separar administrador de app, roles por tablero y responsable de tarea. | Recomendación aceptada; recuperación de propiedad pendiente |
| D-18 | ¿La programación es especial para cumpleaños? | No: es genérica, opcional por tarea y accesible mediante reloj. Catálogo y casos límite en MVP 1.0. | Enfoque confirmado; reglas detalladas propuestas |

D-03 se rige por C-97/C-98 y la matriz: 72 horas y un uso ya están acordados. La admisión de destinatarios no habilitados queda bajo control exclusivo del solicitante según C-22. **La propuesta de permitir el registro de cualquier cuenta Google queda descartada por C-17.** Un enlace de tablero no habilita acceso global por sí solo. El enlace genérico es transferible entre usuarios elegibles; la directa está ligada a su destinatario. Una eventual invitación de acceso a la app tendría otro contrato explícito.

## 5. Recorridos y criterios de aceptación

Los criterios describen el contrato candidato. Deben actualizarse si cambian las decisiones de la sección 4.

### A. Entrar y salir — F-01

- AC-01: sin sesión, abrir un tablero no devuelve su contenido y permite iniciar sesión con Google. Autenticarse no concede habilitación global ni membresía por sí solo; un usuario no habilitado no puede crear ni acceder a tableros.
- AC-02: después de aceptar Google se vuelve a un destino interno permitido; cancelación, callback inválido y sesión vencida producen estados comprensibles, no un tablero vacío que sobrescriba contenido.
- AC-03: cerrar sesión limpia los datos privados de la vista y cierra las suscripciones locales. Volver atrás o reutilizar una llamada no permite nuevas lecturas sin sesión válida.
- AC-04: no se pide acceso a Gmail, Drive o Google Tasks. Solo identidad básica; credenciales OAuth y tokens de sesión nunca se incluyen en exportaciones o logs.

### B. Mis tableros y privacidad — F-02

- AC-05: un usuario habilitado crea un tablero explícitamente y se establece su propietario desde la sesión verificada, no desde un ID enviado por el navegador. Nadie más lo ve en sus listados. Visitar una URL no crea un tablero público.
- AC-06: el listado incluye solo propios/compartidos autorizados. URL, UUID, slug conocido o manipulado no sustituyen la membresía.
- AC-07: usuario autenticado sin acceso obtiene una respuesta neutra de no disponible; no recibe tareas, nombres de miembros ni confirmación innecesaria de existencia.
- AC-08: conflicto de slug no entrega ni adopta un tablero existente. Antes de implementar se fijarán rutas reservadas y la regla de unicidad; preferencia: conservar enlaces existentes cuando sea viable.

### C. Compartir y retirar acceso — F-03

- AC-09: según D-04, solo el propietario crea/revoca invitaciones o retira miembros. Un colaborador no puede elevar su rol mediante solicitudes directas.
- AC-10: abrir un enlace no lo consume. Aceptar requiere una acción explícita con sesión válida y habilitación global vigente; escáneres de enlaces, precarga y callback de login no agregan miembros automáticamente. Un destinatario no habilitado no consume el enlace ni obtiene contenido privado.
- AC-11: según D-03, el enlace vence, puede revocarse y solo una aceptación lo consume. Dos aceptaciones concurrentes no crean dos permisos; un miembro que ya pertenece no duplica membresía ni consume por accidente una invitación para otro.
- AC-12: token inválido/vencido/revocado no revela datos privados. Una invitación nunca permite entrar sin una sesión válida y su aceptación explícita.
- AC-13: después de confirmar la retirada, nuevas lecturas/escrituras del exmiembro fallan incluso con un JWT todavía vigente. Sus tareas se tratan según D-05. Se prueba también la suscripción que ya estaba abierta, no solo una reconexión.
- AC-14: no queda un propietario inexistente ni un tablero sin propietario por una operación ordinaria. No se permite usar una invitación antigua para eludir una retirada: la política se concreta al cerrar D-03.

### D. Responsables y Mis tareas — F-04/F-05

- AC-15: responsable elegible significa miembro actual de ese mismo tablero, incluido su propietario. Un ID válido de otro usuario no alcanza; la base lo rechaza y conserva el estado anterior.
- AC-16: asignar/desasignar respeta D-01 y D-02, persiste después de recargar y se refleja en otro cliente autorizado.
- AC-17: retirar al responsable y asignarle una tarea concurrentemente no deja asignaciones inválidas. No se borran las tareas al retirar acceso.
- AC-18: «Mis tareas» muestra únicamente las asignadas al usuario actual y todavía accesibles, sin copiarlas ni moverlas. Completar desde ahí actualiza la misma tarea en el tablero; el cambio inverso también se refleja. Cambio de responsable, retirada de membresía o borrado elimina el resultado correspondiente. Casos concurrentes y movimiento manual en MVP-AC-18–22.

### E. Conservar el producto — transversal

- AC-19: se conservan título/descripción/prioridades, orden, drag/drop accesible, controles móviles, plegado, atajos y sincronización. Los cambios visuales se limitan a entrada, listados, miembros, asignación y comportamientos temporales expresamente aprobados.
- AC-20: los borrados siguen confirmándose. Importar/exportar requiere acceso al tablero y, para reemplazo destructivo, el rol que se apruebe en D-04.
- AC-21: JSON v1 sigue siendo importable, sin conceder miembros/propiedad desde el archivo. La compatibilidad de nuevas asignaciones se decide antes de F-04: versión de exportación, referencias portables y tratamiento de responsables ausentes. No se declara «respaldo completo» mientras no esté definido y probado.
- AC-22: ante red fallida o permisos retirados, no se anuncia guardado exitoso. No se incorporan cola offline durable ni edición simultánea tipo documento; se conserva el mecanismo original salvo cambios indispensables.

### F. Completado y tiempo — F-06, criterios candidatos

- AC-23: al tildar una tarea queda completada, conserva tablero y columna y sigue visible, tildada y atenuada por defecto. No equivale a borrar ni se infiere completado por el nombre de columna. Persistencia, permisos y otro cliente deben reflejar el completado. Se propone mantener su posición salvo ordenamiento manual; reapertura y demás detalles de D-10 todavía deben cerrarse.
- AC-24: si una actividad se repite lunes/miércoles, al llegar la ocurrencia del miércoles no quedan dos pendientes por lunes y miércoles; la del lunes no se marca hecha por haber sido reemplazada. La regla afecta solo a ocurrencias de esa misma actividad, nunca a otras tareas con título parecido.
- AC-25: una tarea única vencida sigue en su tablero, sin desplazarse su fecha ni borrarse automáticamente, y presenta un destacado de vencida mientras no se complete. Solo una acción explícita permitida puede completarla, reprogramarla o borrarla.
- AC-26: el usuario distingue visualmente tarea pendiente actual, vencida y completada sin depender solo del color. La forma exacta de los destacados está pendiente; no se afirma entrega de notificaciones fuera de la app.
- AC-27: tras un período sin abrir la app, no se muestra una pila de atrasos de la misma actividad recurrente ni se inventan completados. Cómo se conservan las ocurrencias omitidas y cuándo aparece la próxima se define en D-11. Esta regla no descarta tareas únicas vencidas.
- AC-28: el control personal de completadas permite alternar entre visibles y ocultas sin cambiar lo que ven otros. Volver a mostrarlas recupera las mismas tareas en sus columnas, todavía completadas; no se borran, duplican ni destildan. La preferencia inicial es mostrarlas. P06 confirma alcance por usuario y tablero/vista, persistencia entre dispositivos y reinicio explícito; contrato técnico por diseñar.

La fecha límite es un día sin hora según C-15. Antes de aprobar F-06 deben fijarse zona horaria de referencia y cambio de día, formato de intercambio, creación/edición de repeticiones, cuándo se activa una ocurrencia, qué conserva una ocurrencia nueva y cómo se exportan estos datos. No convertir una fecha de calendario a una hora UTC implícita que pueda cambiar el día mostrado a otro usuario.

## 6. Matriz de permisos — referencia única

Consultar la [matriz de permisos MVP 1.0](./MATRIZ-PERMISOS-MVP-1.0.md): distingue acuerdos (A), propuestas pendientes (P) y criterios de aceptación. Reemplaza la tabla parcial anterior; incluye operaciones sobre comentarios, archivos, series, recuperación y administración global.

Acceder al contenido requiere sesión e identidad válidas, habilitación global vigente y pertenencia al tablero. No concede acceso a un desconocido con sesión. Propietario/colaborador aceptados según C-23; lector y administrador delegado no están incluidos. Ser administrador global no concede automáticamente lectura de todos los tableros desde la app. El propietario debe elegir sucesor antes de salir; si no hay otro miembro, confirmar borrado recuperable. Sucesión automática solo como reparación excepcional, nunca como opción normal de salida (C-80).

## 7. Contrato técnico y de seguridad propuesto

- T-01: reutilizar Supabase Auth y los paquetes `@supabase/ssr` / `@supabase/supabase-js` ya instalados. No incorporar otra plataforma de Auth. Validar identidad en servidor y refrescar sesión según el flujo SSR soportado; no confiar únicamente en una cookie o en esconder controles. [Guía SSR](https://supabase.com/docs/guides/auth/server-side/creating-a-client?queryGroups=framework&framework=nextjs).
- T-02: la autorización debe alcanzar todas las lecturas/escrituras, RPC individuales y por lotes, importación/exportación y listados. Retirar permisos anónimos, cubrir RLS y revisar cada `SECURITY DEFINER`: conceder ejecución a `authenticated` no limita por sí solo las filas a miembros. La elección entre invoker y comprobaciones explícitas se resuelve preservando una única regla de permisos comprobable. [Funciones SQL](https://supabase.com/docs/guides/database/functions).
- T-03: persistir propiedad, membresía, invitaciones y asignaciones con integridad en base. Una propuesta conceptual es ampliar tablero y agregar relaciones de miembros/invitaciones; las asignaciones respetan cero o un responsable según D-01. No fijar DDL ni reescribir migraciones 001–012 antes de cerrar el contrato.
- T-04: checks de permiso y cambios asociados deben ser atómicos. Probar retirada concurrente con edición/asignación y consumo concurrente de invitaciones. Nunca aceptar `owner_id`, rol o emisor de invitación por confianza en el cliente.
- T-05: canales privados de Broadcast/Presence con autorización de miembros; deshabilitar canales públicos al cortar el acceso anónimo. No asumir que cambiar membresía revoca un canal abierto: Supabase cachea permisos de la conexión. Antes de aprobar este tramo hay que demostrar un mecanismo de invalidación/rotación que impida recibir o emitir nuevos eventos después de la retirada, incluso si el cliente no coopera. Solo pedir al navegador que se desconecte no cumple AC-13. No se promete borrar información que el usuario ya descargó. [Autorización y caché de Realtime](https://supabase.com/docs/guides/realtime/authorization).
- T-06: tokens de invitación no predecibles, guardados mediante hash, con expiración y consumo atómico de acuerdo con D-03. No usar el slug como secreto ni registrar tokens completos; definir intercambio y limpieza del enlace para evitar filtraciones por logs, historial y redirecciones.
- T-07: consultas y páginas privadas no comparten caché entre usuarios. Cerrar sesión, cambiar cuenta o perder membresía no conserva datos del usuario anterior en el estado activo ni permite nuevas solicitudes autorizadas por ese estado.
- T-08: Google solo identifica al usuario; nombres/avatar son presentación, nunca prueba de autorización. No publicar un directorio global de emails de usuarios para elegir responsables; mostrar únicamente miembros autorizados.
- T-09: comprobar habilitación global vigente además de membresía en todas las operaciones y canales. Una cuenta Auth existente o un token válido no eluden suspensión. Vincular admisión a identidad verificada, no a un email o rol declarado por el cliente. El administrador inicial se establece explícitamente; nunca por ser el primero en iniciar sesión. Extender las pruebas de revocación de T-05 a suspensión global.

El permiso de retirar acceso se revisa junto con Realtime, no como un detalle cosmético posterior. Si el enfoque actual no permite cumplirlo, documentar la alternativa y su costo antes de cambiar la arquitectura.

## 8. Transición desde la instancia anónima

Plan candidato, aún sin ejecutar:

1. Antes de diseñar SQL final, acordar D-07: qué tableros conservar y a qué usuario pertenecen. No consultar ni modificar tableros por iniciativa propia para esta spec.
2. Preparar respaldo de datos y esquema, inventario aprobado y ensayo de restauración. El JSON v1 es útil para contenido, no equivale a un respaldo administrativo completo.
3. Ensayar nuevas migraciones sobre una base descartable con datos ficticios; preservar IDs, posiciones y contenido de los tableros elegidos.
4. Configurar Google y callbacks con el propietario cuando se autorice esa etapa. Credencial secreta de Google solo en la configuración privada correspondiente; no en `NEXT_PUBLIC_*`. [Configuración de Google](https://supabase.com/docs/guides/auth/social-login/auth-google).
5. Aprobar un corte coordinado de SQL, aplicación y configuración Realtime. Las primeras etapas se desarrollan localmente: no publicar un login sobre RPC todavía anónimas como si la instancia ya fuera privada.
6. Asignar dueños por inventario explícito, cerrar acceso anónimo y activar versión autenticada. No hacer reclamación automática por URL ni asignar todo a quien se registre primero.
7. Verificar con propietario, amigo y tercero sin acceso; repetir en móvil y con sesiones/canales ya abiertos. Mantener acceso bloqueado si falla la verificación.
8. Recuperación debe fallar cerrada: no restaurar acceso anónimo como rollback automático. Acordar recuperación de esquema/datos y versión compatible antes del corte.

Aprobación de esta spec, autorización de implementación y autorización de cambios remotos son hitos distintos. Un merge a `main` puede desplegar automáticamente: no se realiza antes de acordar el corte.

## 9. Plan de pruebas trazable

| Grupo | Criterios | Evidencia requerida antes de darlo por terminado |
| --- | --- | --- |
| Identidad | AC-01–04 | Login Google real de prueba, cancelación, retorno seguro, refresh, logout y cambio de cuenta. |
| Aislamiento | AC-05–08; T-02 | Pruebas SQL/RPC con propietario, miembro, tercero y sin sesión; todas las funciones/overloads inventariadas. Acceso directo y UUID/slug ajenos denegados. |
| Compartir | AC-09–14 | Invitación válida, vencida, revocada, reutilizada y aceptada concurrentemente; no elevación de rol; retirada con sesión y canal existentes. |
| Asignación | AC-15–18 | Elegibilidad por tablero, cardinalidad acordada, desasignación y carreras con retirada; Mis tareas sin filtraciones. |
| Regresión | AC-19–22 | Recorrido original escritorio/móvil y dos clientes; fallos de red; importación v1 y contrato de exportación nuevo. |
| Completado y tiempo | AC-23–28 | Casilla sin mover de tablero/columna, visible y atenuada por defecto, ocultar/mostrar sin alterar datos, repetición que sustituye pendiente sin declararlo hecho, tarea única vencida persistente y destacada, regreso tras varios períodos sin duplicados. Calendario y zona horaria una vez definidos. |
| MVP integral | MVP-AC-01–45 en MVP 1.0 | Admisión, roles, recurrencias, Mis tareas/orden, aparición anticipada, borrado, Series, colaboración y conservación. Límite de anticipación/grupo de completadas confirmados; criterios con detalles candidatos requieren cierre. No movimiento automático. |
| Corte | Sección 8 | Ensayo de migración/restauración, asignación de dueños y denegación anónima antes de abrir la instancia. |

Usar fixtures ficticios y herramientas existentes cuando alcancen. `pnpm lint`, `pnpm typecheck`, `pnpm test:db` y `pnpm build` siguen siendo verificaciones mínimas; no sustituyen las pruebas entre identidades ni OAuth real. Las credenciales administrativas nunca llegan al navegador de prueba.

No se afirma serialización general de toda edición colaborativa: antes de cerrar la spec se documentará el comportamiento de dos ediciones simultáneas y su recuperación, sin introducir un motor colaborativo nuevo por defecto.

## 10. Secuencia spec-driven y puertas de aprobación

1. **Borrador funcional:** D-01–03 confirmados; continuar discovery del producto 1.0 y revisar el resto de recomendaciones, incluyendo F-02–05. Todavía no hay implementación.
2. **Spec aprobable:** cerrar matriz de permisos, admisión global, rutas/creación, ciclo de invitación, retirada/propiedad, respaldo de asignaciones, conflicto de ediciones, completado, recurrencias y aparición anticipada (sin movimiento programado). Usar la lista de cierre de MVP 1.0 y propuestas CF. Vincular cada decisión con AC; registrar ADR solo si hay una decisión arquitectónica difícil de revertir con alternativas reales.
3. **Aprobación del usuario:** marcar versión y alcance aprobados. Cualquier cambio posterior que altere el contrato vuelve a la spec antes de código.
4. **Plan técnico por entregas:** definir orden de identidad + privacidad, invitaciones + colaboración privada, asignaciones, Mis tareas y funciones temporales aprobadas. Son cortes de desarrollo, no autorización para exponer estados de seguridad incompletos.
5. **Construcción contra criterios:** pruebas que fallan, implementación mínima, regresiones y evidencia. No considerar una funcionalidad terminada solo porque existe la pantalla.
6. **Corte remoto aprobado y evaluación:** migrar/desplegar con autorización separada y usar el producto para decidir ajustes posteriores.

## 11. Registro de revisión

- 0.1: primera especificación basada en repo y conversación. Google confirmado; D-01–08 son propuestas o decisiones pendientes. No se creó código funcional, migración, configuración remota ni despliegue para esta evolución.
- 0.2: el usuario confirma D-01–03 y pide continuar brainstorming de la app 1.0 sin implementar. No se interpreta como aprobación de alcance completo, D-04–08 ni solución técnica.
- 0.3: el usuario elige navegación centrada en tableros y aporta siete casos reales que introducen fechas límite, recurrencia, recordatorios y cumpleaños. Se registran como necesidades de discovery; D-10–13 aún no tienen comportamiento acordado. Sin código, migraciones, tareas reales creadas ni cambios remotos.
- 0.4: el usuario prefiere casilla de completado, confirma que la nueva repetición sustituye al pendiente repetido anterior y que las tareas únicas vencidas se conservan y destacan. Avisos dentro de la app son suficientes; celular/Google Calendar quedan como deseables a evaluar. Se agregan AC-23–27 candidatos, sin implementación.
- 0.5: el usuario define cumpleaños como solo fechas; se descarta generar tareas de saludar o un estado «ya saludé». No se elige todavía vista de calendario, avisos o privacidad de esa agenda. Solo documentación.
- 0.6: el usuario confirma completadas visibles, tildadas y atenuadas en su columna por defecto, con un control para ocultarlas y volver a mostrarlas. Se agrega AC-28; alcance/persistencia de la preferencia y reapertura siguen pendientes. Sin implementación.
- 0.7: el usuario confirma fecha límite solo por día, sin hora. Zona horaria de referencia y transición a vencida siguen por acordar. Solo documentación.
- 0.8: el usuario propone columnas de cumpleaños y reglas para mover tarjetas X días antes a una columna/tablero principal. Se distingue tarjeta de tarea y movimiento de notificación, sin introducir completado para cumpleaños. Destino entre tableros, alcance de regla y ciclo anual siguen pendientes. Sin implementación ni automatizaciones reales configuradas.
- 0.9: el usuario aclara programación genérica por tarea desde reloj y series configurables; descarta registro/creación públicos y pide habilitación de usuarios bajo su control, tableros propios, colaboración y roles. Se abre MVP 1.0 como documento integral y se corrigen las propuestas incompatibles. Solo documentación; sin código, migraciones ni cambios remotos.
- 0.10: el usuario confirma admisión central exclusiva y reabre propiedad central frente a propiedad de cada creador. Se actualiza MVP 1.0 a 0.2 con recomendaciones y recorridos para cerrar huecos funcionales, sin interpretar la conversación como aprobación de implementación.
- 0.11: aceptación de roles/privacidad y calendario fijo, solapamiento anticipado por sustitución, preferencias personales, movimiento manual entre columnas, calendario discreto, conservación al retirar acceso y Mis tareas con completado sincronizado. MVP 1.0 pasa a 0.3. Solo documentación; sin implementación ni cambios remotos.
- 0.12: flujo libre sin columnas obligatorias, columna de aparición editable desde la serie y borrado por repetición/serie. MVP 1.0 pasa a 0.4, con políticas de actual/historial/columnas eliminadas aún por cerrar. Solo documentación.
- 0.13: edición de serie solo futura confirmada, detener/eliminar con distinto alcance, identificar y resolver series afectadas al borrar columna. Se registra sección compacta de Series como necesidad con diseño candidato. MVP 1.0 pasa a 0.5. Solo documentación.
- 0.14: excluida repetición relativa al completado; movimiento/anticipación reabiertos. Orden por vencimiento/creación, tareas de retirados conservadas y alcance de Series confirmados. MVP 1.0 pasa a 0.6. Solo documentación.
- 0.15: aparición anticipada opcional confirmada, orden detallado y nuevas debajo; propuestas de límite de anticipación, grupo de completadas/reapertura y políticas de calendario. Comparación oficial con Asana documentada sin ampliar alcance automáticamente. MVP 1.0 pasa a 0.7. Solo documentación.

## 12. Discovery de producto 1.0 — decisiones, casos y preguntas

Esta conversación amplía el diseño de producto; no dispara desarrollo. Las hipótesis solo pasan a requisitos después de contrastarlas con el uso que describe el usuario y aprobar sus reglas.

- H-01 resuelta en C-09/D-09: el usuario prefiere entrar por tableros y navegarlos. No se impone una pantalla «Mi día» o «Mis tareas» como inicio. Esto expresa una decisión para la 1.0, no afirma que el original ya tenga un listado de tableros asociado a cuentas.
- H-02 resuelta en C-30: la misma tarea se ve en tablero y Mis tareas sin duplicarse; completar desde la vista personal modifica el origen. Orden y agrupación por concretar.
- H-03 resuelta en C-10/C-14/D-10 para completado y visibilidad: casilla, conservación de tablero/columna, visibles y atenuadas por defecto, con control para ocultar/mostrar. Las columnas no determinan automáticamente el completado. Faltan reapertura y detalles de la preferencia.
- H-04: la captura rápida de un pendiente puede o no necesitar elegir tablero y columna en ese momento. Falta un caso real que determine si es necesario cambiar el flujo actual.

### 12.1 Casos aportados por el usuario

Los textos se sintetizan para describir comportamiento, no son tareas creadas en producción. «Pasado mañana» se conserva como ejemplo relativo: no se agenda nada ni se fija una fecha real desde esta conversación.

| Caso | Necesidad expresada | Lo que todavía no se puede asumir |
| --- | --- | --- |
| Analizar gastos de gas de los últimos seis meses | Tarea puntual, con título y eventualmente detalle del período a analizar. | «Últimos seis meses» es parte del trabajo, no una recurrencia automática. No se requiere una función de análisis financiero. |
| Simular un crédito | Tarea puntual de investigación. | Plazo, monto o banco en el título no crean un simulador, integración bancaria ni cálculo financiero dentro de la app. |
| Estirar lunes y miércoles | Actividad que se repite en días fijos de la semana. La nueva repetición reemplaza a la anterior como pendiente vigente. | Calendario exacto de activación, conservación y vista de ocurrencias omitidas; no se aprueba una pantalla de historial por defecto. |
| Investigar actividades para un viaje de tres días, asignado a su pareja, con fecha límite «pasado mañana» | Colaboración, un responsable y fecha límite. | «Tres días» describe el viaje, no una duración ni repetición de la tarea. No se sabe si el vencimiento debe avisar y a quién. |
| Recordatorio todos los lunes para saludar a su madre | Repetición semanal y necesidad de recordar una acción. | Si exige completar una tarea o solo recibir un aviso, y si el aviso debe llegar con la app cerrada. |
| Usar los tokens disponibles todos los días | Actividad diaria; la nueva repetición sustituye la anterior pendiente. | No implica integración con cuentas, medición de tokens ni automatización de su uso. El registro de omisiones sigue pendiente. |
| Agenda de cumpleaños de amigos | Fechas que vuelven cada año, sin tarea de saludar ni completado. El usuario propone tarjetas en una columna y movimiento anticipado a un destino. | Representación exacta, alcance de regla, privacidad y ciclo posterior. No se solicita sincronizar contactos. |

### 12.2 Distinciones que debe cerrar la spec

- **Fecha límite, precisión confirmada:** día para el que debería estar terminada la tarea, sin hora. Se propone que durante esa fecha figure como «vence hoy» y desde el día siguiente como «vencida», sin alterar el día elegido; falta cerrar la zona horaria de referencia.
- **Recurrencia:** cuándo vuelve a tocar una actividad. Completarla tarde no necesariamente debe desplazar los siguientes lunes/miércoles.
- **Ocurrencia:** realización correspondiente a una fecha dentro de una actividad repetida. Se acordó que la nueva sustituye a la anterior como pendiente vigente; la conservación de datos y vista de historial no están aprobadas.
- **Recordatorio:** destacados al usar la app son suficientes como base. La nueva propuesta añade un mecanismo distinto: mover una tarjeta anticipadamente. No equivale a notificación en el celular.
- **Cumpleaños, naturaleza confirmada:** fecha anual sin trabajo que completar, representable en una columna según la propuesta del usuario. Mover su tarjeta no lo convierte en tarea ni lo marca realizado; no se incorpora una agenda completa de eventos por inferencia.

### 12.3 Escenarios resueltos y detalles pendientes

1. No se completó el estiramiento del lunes: al aparecer el del miércoles queda solo el nuevo como pendiente vigente. Sigue pendiente precisar qué muestra el martes y cómo conservar la ocurrencia anterior; no se deduce borrado físico ni completado automático.
2. Se completa el lunes el estiramiento del miércoles pasado: ¿el próximo sigue siendo el miércoles de esta semana? ¿Cambiar una repetición modifica solo esa fecha o toda la serie?
3. La tarea del viaje vence en dos días: una fecha sin hora es suficiente, confirmado. Falta definir a quién se destacan vencimientos, la referencia de cambio de día y si cambiar responsable cambia el destinatario del destacado.
4. La app está cerrada el lunes: no se exige aviso externo para la base. Celular y Google Calendar se evaluarán como mejoras deseadas, con autorización específica antes de conectar o transmitir datos.
5. Es un cumpleaños: se conserva la fecha anual y no se presenta «ya saludé» ni se genera una tarea. Puede participar en la propuesta de movimiento anticipado. Pasar la fecha no la elimina ni la convierte en una tarea vencida; falta definir si su tarjeta vuelve al origen y cómo se calcula el próximo año.

### 12.4 Recomendaciones todavía no confirmadas

- Completadas: visibilidad y control confirmados C-14/C-26; reapertura desde detalle según C-74 y controles en Pantallas. P06 confirma preferencias por usuario y vista/tablero entre dispositivos; no quedan pendientes esos comportamientos, sí su mecanismo técnico.
- Repeticiones: conservar la diferencia entre realizada y omitida/reemplazada, sin exigir una vista de historial en esta versión. No destruir datos históricos como consecuencia implícita de «mostrar solo la nueva».
- Calendario fijo confirmado en C-24: lunes/miércoles no cambia a martes/jueves al completar tarde. Alcance explícito de edición; activación anticipada en C-25. Excepciones y catálogo completo por cerrar.

### 12.5 Celular y Google Calendar — deseables, no compromiso de entrega

El usuario expresa interés, pero acepta destacados dentro de la app como suficiente. No se conecta ninguna cuenta, concede permisos, crea eventos ni configura notificaciones durante la especificación.

Una integración mediante Google Calendar API requeriría permisos de calendario aparte de la identidad básica del login; no asumir que «entrar con Google» habilita ese acceso. Debe ser opcional y pedir el alcance mínimo. [Scopes de Google Calendar](https://developers.google.com/workspace/calendar/api/auth).

Antes de incluirla se elegirá qué problema resuelve: añadir un evento puntual, publicar fechas o sincronizar cambios. La sincronización de ida y vuelta no se incluye por inferencia. También deben acordarse privacidad de tableros compartidos, retiro de acceso y el tratamiento de datos que ya hayan salido de la app. Los avisos nativos al celular requieren su propia evaluación de viabilidad; no se elige un proveedor ahora.

Próxima revisión: propuestas de límite de anticipación, fechas difíciles y completadas; decidir cobertura de brechas funcionales documentadas frente a Asana. Admisión/roles ya están acordados. Hoja de cierre en MVP 1.0; no agregar funciones por comparación sin una decisión explícita.

## 13. Movimiento programado — antecedente histórico descartado

**Sustituido por C-43:** el texto que sigue es antecedente histórico, no requisitos vigentes. No implementar movimientos programados ni campos de destino a partir de esta sección. El único contrato vigente es aparición anticipada en la columna de la serie, documentado en MVP 1.0, sección 9. Se conserva este antecedente para entender el cambio de alcance.

### 13.1 Necesidad y ejemplo candidato

El usuario llama «avisar» a hacer visible una tarjeta en una columna/tablero principal mediante movimiento anticipado. Se propone nombrarlo **movimiento programado** para distinguirlo de un destacado visual o una notificación externa.

Ejemplo ficticio para discutir, no una regla creada: una columna «Cumpleaños» contiene una tarjeta con fecha anual 20 de noviembre. Una regla de anticipación de tres días la mueve a «Próximos» el 17 de noviembre. No cambia la fecha del cumpleaños ni crea una tarea de saludar.

Configuración candidata: origen, fecha de referencia, anticipación X días y columna destino. C-19–20 fija programación opcional por tarea desde reloj; la sugerencia anterior de una regla para toda una columna deja de ser el enfoque principal. Una regla de columna sería otra capacidad, sin inclusión automática. «Principal» no pasa a ser un tablero/columna especial del sistema: el destino lo elige el usuario.

### 13.2 Decisiones que faltan

- **Destino confirmado:** columnas del mismo tablero para movimiento programado y manual. Traslado entre tableros fuera del alcance actual; no quitar la protección de las RPC contra cruces de tablero. C-25 resuelve reemplazo anticipado de la ocurrencia pendiente previa; detalles y ejemplo en MVP 1.0, sección 9.2.
- **Mover o reflejar:** el pedido habla de mover; la propuesta candidata conserva una sola tarjeta que deja su columna origen. No se añade una copia independiente. Si se pretende conservarla visible en ambos lugares, revisar explícitamente el modelo antes de implementar.
- **Después de la fecha:** para cumpleaños falta definir si vuelve al origen, cuándo lo hace y cómo prepara el siguiente año. Para una tarea única, pasar la fecha nunca justifica borrarla o descartarla, según C-11.
- **Alcance de la regla:** por tarjeta según C-19–20; excepciones, anticipación cero y edición de la fecha después de programar por cerrar. No asumir que todos los elementos de una columna tienen fecha. Reglas masivas por columna no son requisito confirmado.
- **Ejecución:** falta elegir si se exige movimiento en segundo plano o basta que esté actualizado al entrar. Debe funcionar sin duplicados después de períodos sin usar la app; no se promete un scheduler ni compatibilidad con planes gratuitos antes de evaluar la solución.
- **Interacción manual:** definir qué pasa si alguien mueve, completa, borra o reprograma la tarjeta antes/después del disparo; no devolverla en bucle al destino en cada recarga ni ignorar una cancelación del usuario.

### 13.3 Invariantes candidatos para convertir en criterios

1. Mover no completa, no borra y no cambia la fecha de referencia; los cumpleaños siguen sin casilla de completado.
2. El mismo disparo para la misma ocurrencia/regla no duplica tarjetas ni se repite por cada cliente o recarga. Definir el identificador y ciclo de la regla después de acordar comportamiento.
3. Si el destino dejó de existir, no se borra el origen ni se elige un destino con mayor visibilidad por defecto. El resultado fallido se informa de manera comprensible.
4. Configurar una regla no es un permiso permanente para saltarse la autorización: comprobar acceso vigente al configurarla y al ejecutar, con efecto de retirada y borrado del tablero especificado.
5. Fechas anuales, cambios de año, 29 de febrero y anticipaciones que crucen meses/años necesitan reglas de calendario explícitas. No tratar la fecha de cumpleaños como una tarea única que queda vencida para siempre.

La propuesta no configura ninguna automatización de la cuenta del usuario. Una vez cerradas estas decisiones se definirán criterios de aceptación y viabilidad técnica, todavía con aprobación separada antes de construir o tocar infraestructura.
