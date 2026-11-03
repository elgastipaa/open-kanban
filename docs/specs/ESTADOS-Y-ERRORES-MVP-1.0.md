# Estados y errores de los recorridos — MVP 1.0

Actualización documental C-100–112 (27/10/2026): calendario CF-04/07/09, avisos/cuota/enlaces CF-15/16/18, preferencias/búsqueda CF-13–14 y ampliaciones CF-22–27. Complementa revisión base; todas las P/E se conservan.

Consolidación vigente27/10/2026: C-112 resuelve los dos huecos funcionales de auditoría; [DT-0.1](./DISENO-TECNICO-MVP-1.0.md) fija diseño recomendado y verificaciones G01–G08 pendientes. Los registros de revisiones anteriores son antecedentes, no nuevas preguntas de producto.

Estado: **revisión 0.3, EE-01–05 aprobadas en C-95 y P01–P26 / E01–E07 incorporadas al MVP por C-99. Contratos técnicos restantes identificados; solo documentación**.

C-99 aceptado el 24 de octubre de 2026; consolidación documental del 25 de octubre de 2026.

Complementa [Pantallas](./PANTALLAS-MVP-1.0.md), la [matriz de permisos](./MATRIZ-PERMISOS-MVP-1.0.md) y la aceptación C-99 de [Propuestas desde Plane](./PROPUESTAS-DESDE-PLANE.md). Aplica estados y errores a esas funciones aprobadas; no elige por inferencia librerías o servicios. Las extensiones E01–E07 están dentro del MVP. No acredita pruebas ejecutadas ni autoriza implementación.

## 1. Acuerdos que no se reabren

- Campos de tarea con Guardar; comentarios, pasos y adjuntos tienen persistencia independiente.
- Guardar y cerrar solo cierra tras confirmación. Descartar campos no deshace acciones independientes ya guardadas.
- Error conserva texto mientras la sesión y el acceso sigan vigentes. No prometer recuperación tras cerrar navegador.
- Sin cola de edición offline. Contenido previamente cargado puede verse con advertencia de desactualización mientras siga autorizado.
- No sobrescribir silenciosamente cambios ajenos; servidor valida permisos actuales.
- Revocación, cierre o cambio de cuenta retiran contenido privado de la sesión anterior. Esto prevalece sobre conservar borradores.
- Los roles no permiten saltarse cuotas, moderación, vencimiento de recuperación ni la regla de una ocurrencia vigente.
- PWA mantiene el contrato online y de borradores de sesión; instalar no concede acceso ni habilita cola offline, push o persistencia privada duradera.
- Favoritos, preferencias y vistas guardadas son personales; una copia puntual crea otra identidad y no comparte permisos. Etiquetas no cambian columna ni completado.

## 2. Estados de cualquier operación

Los cinco principios EE-01–05 resumidos en sección 7 fueron aprobados el 2026-10-24 (C-95). C-99 adopta las precisiones de captura, estados, concurrencia, datos privados, archivos y calidad de P01–P26 y las siete extensiones. Los mecanismos y contratos aún no definidos se indican expresamente; EE-06 describe verificación pendiente del alcance aprobado, no pruebas ejecutadas ni autorización para implementar.

| Estado | Qué ve la persona | Acción disponible / garantía |
| --- | --- | --- |
| Cargando | Indicador dentro de la zona afectada, sin inventar un estado vacío. En recarga conservar contenido ya cargado todavía autorizado. | Esperar; error recuperable si no se completa. No mostrar datos de otra cuenta ni conservar contenido tras detectar revocación. |
| Vacío real | Explicación contextual: sin tableros, sin columnas, sin tareas o sin coincidencias. | Crear tablero/columna/tarea según contexto y permiso; aceptar invitación o quitar filtros cuando corresponda. No crear datos automáticamente ni usar el mismo mensaje para todos. |
| Cambios sin guardar | Campos editables, Guardar disponible. | Guardar, descartar o seguir editando al cerrar. |
| Enviando | Progreso de esa operación. | Bloquear su doble envío, no toda la app ni acciones independientes seguras. |
| Confirmado | Cambio reflejado en las vistas de la misma entidad. | Cerrar si se pidió; no anunciar éxito antes de confirmación persistida. |
| Rechazado | Motivo útil junto a la acción/campo, conservando entrada autorizada. Un error de consulta no presenta la lista como vacía. | Corregir y volver a intentar. No reintentar automáticamente un error de validación. Fallo local no bloquea acciones independientes seguras. |
| Resultado desconocido | «No pudimos confirmar si se guardó. Estamos comprobándolo». | Comprobar resultado antes de repetir. No declarar fracaso definitivo ni éxito sin evidencia. |
| Conflicto | Aviso de que cambió el objeto y los valores actuales autorizados. | Revisar antes de guardar; no reemplazar automáticamente lo ajeno. |
| Sin conexión | Indicador persistente de datos posiblemente desactualizados. | Permitir escribir un borrador en el detalle ya abierto, pero no confirmar mutaciones ni encolarlas silenciosamente. |
| Acceso perdido | Mensaje genérico y salida del contenido privado. | Volver a Tableros o cambiar cuenta según el alcance; no conservar vista privada bajo un diálogo. |

EE-01: distinguir envío, rechazo y resultado desconocido. Identificar cada intención de escritura para reconciliar reintentos sin duplicados; el mecanismo técnico se diseña después. No deduplicar comentarios por texto: dos comentarios iguales enviados deliberadamente pueden ser válidos.

**C-99 / P17–P20:** el contrato de cada acción usa campos editables explícitos, precondiciones y una clave de operación para reconciliar reintentos. La representación técnica concreta se diseña después; la UI no envía un objeto completo como autoridad para cambiar roles, autores o referencias protegidas. Un cambio optimista se rotula pendiente hasta confirmación. Completar, marcar paso o marcar leída expresa el estado deseado, no una inversión repetible. La escritura confirmada se distingue de su trabajo de fondo: notificaciones, activaciones o purgas pendientes no justifican repetir la escritura inicial ni informar que nunca se guardó. Reintentos/reconciliación no duplican efectos.

## 3. Aplicación a los recorridos principales

| Recorrido | Validaciones / errores | Resultado y recuperación |
| --- | --- | --- |
| Login | Cancelación de Google, servicio no disponible, cuenta no habilitada/suspendida. | Cancelar vuelve a acceso; error permite reintento. Cuenta identificada no equivale a habilitada. Nunca crear tablero por entrar. |
| Aceptar invitación | Vencida, usada, revocada, permiso del emisor retirado; cuenta no habilitada. | No consumir enlace en intento no autorizado. Si ya es miembro, abrir sin membresía duplicada. Si cambia mientras confirma, explicar indisponibilidad sin revelar quién lo usó. |
| Crear tarea rápida | Título vacío, columna retirada, permiso perdido, red incierta. | Enter o botón explícito envían; perder foco no envía. Conservar título si mantiene acceso; elegir columna válida si desapareció. Tras confirmar, una tarjeta y captura lista para la siguiente en la misma columna. No inventar columna destino ni limpiar antes de confirmar. |
| Guardar campos | Valores inválidos, responsable retirado, versión desactualizada, tarea eliminada. | Error específico; conservar borrador autorizado. No borrar responsable o mover tarea silenciosamente para lograr guardar. Resolver antes de confirmar. |
| Mover tarjeta | Columna destino desaparecida o tarea movida por otro. | Mostrar estado pendiente si hay actualización visual anticipada; ante rechazo recuperar estado confirmado y explicar. Un conflicto requiere volver a elegir destino sobre estado actual. |
| Completar / reabrir | Checklist pendiente, tarea borrada, ocurrencia ya reemplazada. | Confirmación acordada por pasos; histórica no se reabre. Tarea ya completada por otro se reconoce como completada, sin aviso duplicado. No completar sustituta por usar ID de la anterior. |
| Comentar / mencionar | Texto inválido, miembro mencionado retirado, resultado desconocido. | Conservar borrador autorizado; si una mención dejó de ser válida, pedir revisión o enviarla explícitamente como texto sin notificación. No duplicar publicación al reintentar. Editar avisa solo a nuevas menciones válidas, sin reavisar por corregir texto o quitar/agregar la misma mención; deduplicación por evento/destinatario. |
| Marcar paso | Paso borrado/cambiado o padre completado/borrado. | Enviar estado deseado, no una orden de invertir que un reintento pueda deshacer. Si cambió contexto, refrescar y pedir revisión según conflicto. |
| Subir archivo | Tipo/tamaño/cantidad/cuota, archivo local no disponible, corte durante carga. | Reservar → cargar → verificar → publicar; validar contenido y permiso al confirmar. No mostrar adjunto terminado antes de existir accesible y autorizado. Reservas fallidas se liberan/reconcilian; recuperables no liberan cupo. 24.000 bytes/archivo, 20 incluidos recuperables y 200.000.000 bytes globales contando activos/recuperables/reservas. Fallo no borra tarea. |
| Programar serie | Regla inválida, anticipación superpuesta, columna retirada, cambio concurrente. | Error junto al campo y próxima fecha de ejemplo. No guardar una regla aproximada ni mover la tarjeta actual al editar futuras. |
| Borrar / recuperar | Permiso cambiado, padre borrado, plazo vencido, purga concurrente. | Confirmar alcance antes de borrar. Restauración rechazada no revive parcialmente dependientes ni reinicia plazo. Mensaje sin acceso a contenido privado no autorizado. |
| Salir / transferir | Sucesor no elegido, retirado o no elegible al confirmar. | Bloquear salida y pedir elección válida; no usar sucesión excepcional automática como alternativa normal. Transferencia y salida no dejan tablero sin dueño. |
| Importar | Archivo inválido, cuota, permiso cambiado, edición ajena durante previsualización. | Invalidar vista previa desactualizada y requerir otra confirmación. No borrar previo antes de validación ni aceptar reemplazo parcial. Si resultado incierto, consultar operación antes de repetir. |
| Novedad / búsqueda | Objeto eliminado, acceso retirado o filtro sin resultados. | No confundir estados. Enlace obsoleto explica indisponibilidad sin revelar detalles; contadores/resultados se actualizan según acceso vigente. |
| Copiar / abrir enlace privado | Portapapeles denegado, sesión vencida, tarea eliminada o acceso retirado. | Confirmar copia solo cuando ocurrió; ofrecer enlace seleccionable mientras siga autorizado. Login retoma destino tras autorización. No conceder membresía ni exponer título públicamente. |
| Favorito / preferencia personal | Fallo al persistir, cambio concurrente, cuenta o permiso cambiado. | Distinguir pendiente/confirmado; no alterar otra persona ni reiniciar el tablero para recuperar. Retirar favoritos y referencias privadas al perder acceso; resolución técnica de preferencias concurrentes pendiente. |
| Etiquetas | Etiqueta retirada/renombrada, referencia a otro tablero, permiso de catálogo insuficiente. | Validar pertenencia y estado al guardar; no crear etiqueta global ni reasignar silenciosamente. Mantener campos autorizados y pedir revisión. Permisos y límites aprobados en C-100; C-101 fija ocultación y recuperación siete días; C-102 exige resolver nombre/cupo y asociaciones en preview; no omitir ni reemplazar automáticamente. Duplicado o límite excedido conserva entrada y explica el motivo; no anuncia éxito ni crea parcialmente. |
| Vista personal guardada | Referencia explícita inválida/revocada; conflicto entre dispositivos; borrado durante edición. | C-100 fija límites 50/60 y unicidad por contexto. C-101 bloquea resultados hasta revisar/confirmar, sin nombre privado revocado; global dinámico se adapta. Conflicto conserva variación y permite cargar actual/guardar nueva; revisar actual antes de modificar original. Recuperación siete días solo usuario con revalidación. Casos restantes en CF-22.2; no resucitar contenido por guardado tardío. |
| Tema / español | Fallo de persistencia del tema o componente con texto/formato inconsistente. | No recargar ni perder borrador al cambiar tema; no anunciar preferencia sincronizada si no se guardó. Mantener foco/errores distinguibles en Claro/Oscuro/Sistema y textos del producto en español; no traducir contenido del usuario. |
| Duplicar tarea puntual | Origen cambiado/borrado, destino inválido, permiso perdido, respuesta incierta. | Revalidar origen y mismo tablero; crear identidad nueva solo con campos aprobados E04 y checklist sin marcar. No modificar origen, copiar permisos/conversación/archivos ni duplicar por reintento. Si origen es ocurrencia, advertir que será puntual. C-104 propone columna origen elegible del mismo tablero y final manual; C-105: preview revisado si cambia contenido copiable, conservando título/destino; comentario no invalida; borrado/acceso perdido bloquea. |
| Actividad mínima | Evento duplicado, acceso retirado, consulta fallida o retención cumplida. | Evento único por cambio confirmado; actor/fecha y solo categorías E05. No inventar historial vacío ante error ni mostrar versiones de comentarios. C-105 fija 180 días, ocultación con tarea y purga dependiente; historial no restaura valores. |
| Marcar novedades cargadas leídas | Algunas caducaron, se revocó acceso o fallaron; llegaron nuevas durante envío. | Fijar IDs autorizados cargados al iniciar; informar cantidad/resultados parciales reales. No incluir nuevas/páginas sin cargar; reintentar pendientes con autorización vigente, sin cambiar tareas ni marcar futuras. |
| PWA / apertura instalada | Instalación no disponible, actualización, sesión vencida, desconexión o cambio de cuenta. | Web sigue utilizable donde corresponda; misma autorización/rutas. Sin envío offline automático ni datos privados de otra cuenta desde caché. Mensaje de compatibilidad factual; C-109 fija matriz/instalación opcional/aviso de actualización; mecanismos y pruebas de sesión/caché siguen pendientes. |

## 4. Edición simultánea sin pisar trabajo

EE-02: ante conflicto de campos, conservar el borrador autorizado y presentar «Tu edición» y «Versión actual», con énfasis en campos distintos. Opciones: **Usar versión actual** (advertir descarte del borrador) o **Revisar mis cambios**. Esta última permite preparar cambios sobre la versión actual y luego Guardar nuevamente; no es un botón de sobrescritura forzada. Si alguien vuelve a cambiarla, se vuelve a revisar. No añadir fusión automática de texto ni bloqueo exclusivo de tareas en MVP.

La detección debe tener el alcance correcto: un comentario nuevo, un archivo o un paso marcado no invalida por sí solo editar el título. A la inversa, una tarea borrada o una ocurrencia sustituida sí cambia las precondiciones. C-99 / P18 adopta precondiciones de versión de campos separadas de comentarios/pasos/archivos; la elección técnica de versiones/transacciones debe preservar estas distinciones. Cambios remotos no roban foco ni cambian columna activa o pisan borradores.

Ejemplo ficticio: Ana cambia la fecha mientras Bruno edita la descripción. La aplicación no debe enviar el formulario antiguo completo y deshacer la fecha de Ana. Si no puede combinar con seguridad, muestra la fecha actual y conserva la descripción de Bruno para revisión. No se promete un algoritmo de combinación automática.

## 5. Borradores, desconexión y acciones independientes

EE-03: borradores solo durante la sesión de edición en memoria para el MVP; no persistencia local duradera ni promesa de sobrevivir recarga/cierre. Advertencia nativa al recargar/cerrar cuando el navegador la permita. Al volver la red, no enviar automáticamente: comprobar permiso/estado y dejar al usuario guardar. Revocación/cambio de cuenta elimina borrador privado, aunque exista texto no guardado; no ofrecer copiar datos después de perder acceso.

**P20 / E06:** realtime avisa que hay que reconciliar con datos autorizados; no concede permisos ni sustituye consultar el estado vigente. Al reconectar o cambiar cuenta, revalidar antes de recuperar vistas y descartar respuestas tardías de la sesión anterior. La PWA aplica la misma regla a cachés, historial y enlaces. No prometer retirada instantánea mientras se está totalmente desconectado: lectura limitada con advertencia de posible desactualización y retirada al detectar revocación, como en el contrato existente.

EE-04: antes de acciones que cambien contexto (completar, mover, borrar, cambiar de tarea), si hay campos pendientes, resolverlos explícitamente: Guardar y continuar, Descartar y continuar o Cancelar. Si el guardado falla o queda incierto, no ejecutar la segunda acción. Publicar comentario, subir adjunto y marcar paso siguen independientes: no requieren guardar descripción primero. Controles de estas acciones deben estar fuera del formulario de campos no guardados; no guardar ni descartar otros cambios de manera implícita.

Guardar campos y luego fallar al mover no significa que el guardado se haya revertido: informar «Cambios guardados; no se pudo mover». Acciones compuestas deben comunicar el resultado real de cada parte.

EE-05: mensajes contextualizados y accesibles: texto cerca del campo/acción, no solo color ni avisos que desaparecen antes de leer. Indicador global únicamente para problemas globales como conexión/sesión. No exponer SQL, tokens, datos privados, trazas o nombres de otros tableros. Errores inesperados pueden mostrar referencia técnica inocua para soporte, no el contenido sensible.

## 6. Casos de aceptación del alcance aprobado

| ID | Caso | Resultado esperado |
| --- | --- | --- |
| ERR-01 | Doble clic en crear tarea / reenviar tras respuesta perdida. | Una operación lógica, una tarjeta. Resultado reconciliado, no repetición ciega. |
| ERR-02 | Comentario persistió pero respuesta no llegó. | Identificar publicación al reconectar; reintento no duplica ni repite novedades. |
| ERR-03 | Guardar y cerrar con rechazo. | Detalle y campos abiertos; error visible; no «guardado» ficticio. |
| ERR-04 | Descartar descripción después de publicar comentario. | Revierte campos pendientes, conserva comentario confirmado. |
| ERR-05 | Dos editores guardan sobre misma versión. | No sobrescritura silenciosa; segundo conserva su borrador autorizado y puede revisar. |
| ERR-06 | Se pierde permiso con detalle abierto y texto pendiente. | Bloquea nueva escritura, retira contenido/borrador al detectar; no depende de aceptar diálogo. |
| ERR-07 | Sin red se modifica descripción. | Solo borrador, no cola de guardados; conexión recuperada no envía por sí sola. |
| ERR-08 | Otro usuario borra columna de destino o retira responsable. | Guardado requiere selección válida explícita; no elección automática. |
| ERR-09 | Nueva ocurrencia sustituye la que se estaba completando. | Operación sobre anterior no completa la nueva ni revive histórica. |
| ERR-10 | Dos uploads compiten por última plaza. | Solo el admisible se confirma; otro muestra límite real y no adjunto fantasma. |
| ERR-11 | Sucesor sale antes de confirmar transferencia. | Propietario permanece; debe elegir otro, sin sucesión automática normal. |
| ERR-12 | Restauración llega después del plazo. | Denegada aunque no haya terminado purga; sin recuperación parcial. |
| ERR-13 | Cambia contenido durante vista previa de importación. | No reemplazar usando confirmación obsoleta; recalcular y confirmar de nuevo. |
| ERR-14 | Guardar y después mover: solo mover falla. | Mantiene campos guardados, comunica fallo de movimiento sin revertir ni duplicar guardado. |
| ERR-15 | Otra persona publica comentario mientras se edita título. | Comentario no produce un conflicto espurio de campos; se conservan ambos resultados. |
| ERR-16 | Cambiar cuenta, volver con Atrás. | Sin datos, borradores ni resultados privados de la cuenta anterior. |
| ERR-PL01 | Alta rápida: perder foco, enviar, perder respuesta y reintentar. | Perder foco no crea; texto se conserva hasta confirmar; reconciliar clave de operación deja una sola tarjeta y captura lista en la misma columna. |
| ERR-PL02 | Recarga falla cuando existe contenido autorizado; luego se detecta revocación. | Primero conserva datos con error contextual, nunca vacío falso; al detectar revocación retira datos/borradores sin esperar confirmación. |
| ERR-PL03 | Login desde enlace de tarea, renombrado de tablero y cuenta sin acceso. | Identidad estable, destino retenido solo para apertura autorizada; sin membresía ni metadatos públicos. Fallo de portapapeles no anuncia copia. |
| ERR-PL04 | Favorito/vista guardada apuntan a tablero revocado; llega respuesta vieja después de cambiar cuenta. | No expone nombre, resultados ni conteos privados; descarta respuesta anterior y mantiene estado de la cuenta actual. |
| ERR-PL05 | Se elimina etiqueta seleccionada mientras alguien edita una tarea. | Revalida referencia y pide revisión sin sobrescribir campos ni inventar etiqueta; ninguna alteración de columna/completado. C-101 fija recuperación siete días por propietario actual, sin borrar elementos. |
| ERR-PL06 | Abrir vista guardada relativa en otra semana y con otro conjunto de permisos. | Fechas recalculadas en zona correspondiente, datos autorizados actuales; filtros legibles y distinción vacío/error. |
| ERR-PL07 | Duplicar ocurrencia, perder respuesta y volver a intentar. | Una copia puntual pendiente y nueva identidad; checklist sin marcar, sin responsable/fecha/serie/conversación/archivos; origen intacto. |
| ERR-PL08 | Cambio confirmado genera actividad y trabajo de fondo se reintenta. | Un evento por cambio y destinatario/evento de novedad sin duplicados; no repetir la mutación original. Actividad no recupera textos borrados/moderados. |
| ERR-PL09 | Marcar 20 cargadas de 80; llega otra y 2 operaciones fallan. | Solo conjunto inicial autorizado: informa confirmadas/fallidas reales, futura y 60 no cargadas intactas; reintento no repite confirmadas. |
| ERR-PL10 | PWA con otra cuenta, Atrás, cierre/reapertura y desconexión. | Sin datos privados de cuenta anterior ni envíos automáticos; login/destino consistente y capacidades de instalación verificadas por navegador. |
| ERR-PL11 | Fallo de persistencia de tema durante edición; probar Claro/Oscuro/Sistema. | Borrador y foco intactos, error contextual, sin éxito falso de sincronización; estados/controles legibles y español coherente. |
| ERR-PL12 | Carga ocupa reserva, se corta y luego se reintenta cerca de cuota. | Reserva se reconcilia sin objeto fantasma ni doble conteo; publicación solo tras verificación/autorización y límites decimales respetados. |

EE-06: estos casos son criterios de aceptación del MVP. Falta concretar fixtures y pruebas de integración, UI y autorización cuando se apruebe implementación; escenarios con contratos E pendientes deberán detallarse al cerrarlos. La evaluación con personas de los recorridos capturar/encontrar/completar/coordinar/retomar rutina es distinta de estas verificaciones. Este archivo no dice que hayan pasado.

## 7. Decisiones aprobadas — C-95, 2026-10-24

1. Resultado incierto: comprobar antes de repetir y evitar duplicados (EE-01).
2. Conflictos: revisión explícita de ambas versiones, nunca sobrescritura silenciosa (EE-02).
3. Borradores: conservar durante edición, sin prometer recuperación al cerrar/recargar; no envíos offline automáticos (EE-03).
4. Completar/mover/borrar con campos pendientes: resolver Guardar/Descartar/Cancelar antes de continuar; comentarios/pasos/adjuntos independientes (EE-04).
5. Errores concretos y persistentes junto a la acción, sin bloquear toda la app por un fallo local (EE-05).

El usuario aprobó estas cinco reglas. La aprobación fija comportamiento, no prestaciones verificadas. C-99 amplía su aplicación según la sección siguiente. Sigue sin autorización de implementación.

## 8. Integración aprobada — C-99

P01–P26 y E01–E07 se incorporan al alcance de especificación del MVP. Se concretan aquí captura explícita/continua, errores/vacíos, precondiciones de versión y reintentos, privacidad de realtime/caché, ciclo de archivos y estados de enlaces, favoritos, etiquetas, vistas personales, temas, copia puntual, actividad mínima, PWA online y lectura de novedades cargadas. Ninguna de esas funciones permanece como backlog por su anterior clasificación en el anexo.

Quedan por diseñar, sin inferir nuevos acuerdos: medición/normalización técnica y mecanismo de concurrencia de vistas; mecanismo/pruebas de preferencias C-106; mecanismos de copia/actividad C-105; mecanismos/pruebas PWA y lote C-109; mecanismos concretos de versiones, claves de operación, consultas, procesamiento en segundo plano y respaldo. Se aplica la privacidad y conservación de borradores ya acordadas mientras se cierran esos detalles; no se implementa ni se afirma validación en dispositivos por documentarlos.

## C-102 — Fallos de recuperación y guardado tardío

Cupo activo lleno: rechazar restauración sin borrar otro elemento. Nombre reutilizado: exigir renombrar sin fusionar. Asociación que excede diez activas: resolver en preview liberando lugar u omitiendo expresamente; sin cambios parciales silenciosos. Vista borrada durante edición: conservar variación autorizada y ofrecer guardar nueva o recuperar original por su vía; nunca resucitar por Guardar tardío ni aplicar borrador automáticamente al recuperar. Guardar corrección revalida antes de habilitar resultados. Criterios en CF-22.3, todavía sin ejecutar.

### C-103 — Unicidad de etiquetas y vistas

**C-103 / Q18b:** al crear, renombrar o restaurar etiquetas y vistas, la unicidad ignora mayúsculas, espacios sobrantes, acentos y ñ/n. «Reunión»/«Reunion» y «Peña»/«Pena» colisionan dentro del mismo tablero para etiquetas, o del mismo usuario/contexto para vistas. Conservar escritura original; informar coincidencia y mostrar la existente solo si está autorizada. No fusionar automáticamente ni cambiar identidades/asociaciones. Nombres de otros tableros, usuarios o contextos no provocan colisión ni se revelan.

Criterio C103-AC18b en Cierre CF-22.4, todavía no ejecutado.

### C-104 — Preferencias y copia

Preferencias diferentes se combinan; misma preferencia editada desde versión anterior conserva local y exige revisar, con opción cargar guardada o revisar/conservar local. No trasladar esta política de preferencias a actualizar automáticamente una vista guardada. Copiar histórica crea nueva puntual pendiente, no modifica ni reabre original. Casos C104-AC21–26 todavía sin ejecutar.

### C-106/C-107 — Consultas

Filtro recordado inválido bloquea consulta hasta revisar/limpiar explícitamente; nunca globalizar alcance ni revelar nombres revocados. Limpiar/Reiniciar/Restablecer vista tienen efectos distintos en CF-13.2. Sugerencias unificadas deben distinguir carga/sin coincidencias/error, descartar respuestas antiguas de consulta/cuenta y revalidar acceso al elegir; escribir no navega ni modifica tablero. C-108 cierra interacción en CF-14.2. Comentario o destino inaccesible al elegir ofrece indisponibilidad genérica sin texto antiguo; no sustituir silenciosamente por otro objeto.

### C-109 — Actualización y resultado de lote

Actualizar resuelve primero campos pendientes; no recarga forzada con pérdida de borrador. Botón de lote cuenta sin leer cargadas y fija IDs al pulsar, sin diálogo adicional. Resumen distingue marcadas/ya leídas/no disponibles/falladas; preservar éxitos y reintentar solo falladas autorizadas del original. Timeout es resultado incierto que se comprueba antes de repetir, sin cola offline ni incorporación de nuevos avisos. C109-AC44–48 todavía sin ejecutar.

### C-110 — Excepciones y restauración

Vencimiento excepcional igual/posterior a próxima aparición se rechaza con explicación y borrador conservado, sin fusionar. Restauración finita tras final reconcilia solo última válida aun vencida/no materializada, sin sustituta si última excluida ni pila de intermedias. Ocurrencia restaurada quita solo exclusión de su borrado y queda histórica si hay posterior; padres primero. Recuperar columna no revierte traslados. Propietario/colaborador actuales con edición recuperan ordinariamente pasos/series/columnas siete días; moderación/admin mantienen restricciones. C110-AC49–54 todavía sin ejecutar.

### C-111 — Validación de conversión, cuota y enlaces

Fecha inicial incompatible con patrón exige elección/confirmación conservando identidad; editar otros campos no reinicia restante. Aviso de carga bloqueada inmediato aunque aviso de umbral esté deduplicado; no aviso diferido por seguir sobre umbral. URL se reconoce al visualizar y se abre explícitamente; título compacto sigue abriendo tarea. C111-AC55–60 todavía sin ejecutar.

## C-112 — Reemplazada y transición entre series

Reemplazada no equivale a pendiente ni completada; ausencia en búsqueda default no implica pérdida de contenido. Opción explícita de historial y estado/origen visibles según CF-14.3. Reprogramar desde detenida muestra confirmación de nueva serie; no reanuda anterior ni duplica tarjeta. Revocación/conflicto se resuelven antes de publicar y conservan contratos generales; borrar/restaurar anterior no revierte transición (CF-08.1).
