# Propuesta de tickets — OpenKanban 1.0

Fecha27/10/2026. Versión TT-0.1. **Desglose aprobado y publicado** mediante to-tickets. Basado en issue#2 completo, sin comentarios al consultar, C-01–112 y diseño DT-0.1. Este archivo no es un tracker nuevo ni una autorización de ejecución. GitHub sigue siendo el tracker configurado.

Se prepararon51 cuerpos individuales como borradores locales para revisión. Los51 hijos ya fueron creados: [mapa de IDs reales](./TICKETS-PUBLICADOS-1.0.md). No se modificó/cerró el cuerpo ni el estado del padre. Las preguntas del final se conservan como antecedente de la revisión ya aprobada. T01–T51 son identificadores provisionales, no números de GitHub. Al aprobar, publicar en orden topológico, usar IDs reales, ready-for-agent y relaciones nativas cuando estén disponibles; si no, referencias Parent/Blocked by en hijos. No editar el cuerpo/estado del padre para añadir un índice, conforme to-tickets.

## Criterio de tamaño y dependencias

Cada entrega funcional incluye persistencia/autorización, operación, pantalla y evidencia del recorrido; no hay tickets genéricos de “todas las tablas”, “toda la UI” o “todos los tests”. T01 es prefactoring vertical y acotado del movimiento existente antes de introducir modelo privado; T02 consume esa separación de intenciones al cerrar rutas/grants. No se considera una refactorización mecánica amplia que necesite integración compartida.

Las verificaciones de operación/seguridad/piloto son recorridos verificables por su interfaz adecuada, sin inventar una pantalla de métricas. Toda entrega aporta sus pruebas desde el inicio; las auditorías finales integran evidencia, no postergan toda la seguridad hasta el final.

Se evitó bloquear preferencias por favoritos: pueden avanzar por separado. La preparación final sí depende de favoritos para que P13 no se pierda. Recuperación inicial se demuestra con reloj/control de purga aislado; el ejecutor autónomo posterior conecta purgas sin declarar antes un scheduler operativo. Cada productor nuevo conserva reglas de retirada/suspensión, actividad/novedades y generación activa existentes.

T51 requiere autorización de corte y configuración reales además de sus aristas: no se ejecuta por estar ready-for-agent. T44/T49 requieren personas/dispositivos; no se cierran por viewport simulado. G02/04/05/06/08 necesitan evidencia del entorno aislado o del corte autorizado según corresponda. Una dependencia de entrega no equivale a permiso para tocar producción.

## Desglose para aprobar

1. **Separar mover de editar una tarea.** Bloqueado por: ninguno. Entrega: Mover y ordenar conservan el contenido actual de cada tarea, aunque otro cliente haya editado sus campos.

2. **Entrar con Google a una aplicación cerrada.** Bloqueado por: T01. Entrega: La entrada distingue sin sesión, cuenta no habilitada y persona habilitada; una URL ya no concede acceso.

3. **Administrar habilitación global.** Bloqueado por: T02. Entrega: El administrador admite amigos, retira autorizaciones pendientes y suspende cuentas sin leer tableros ajenos.

4. **Crear y encontrar tableros privados.** Bloqueado por: T02. Entrega: Cada habilitado crea un tablero vacío y sus columnas, y vuelve a él desde Tableros.

5. **Capturar tareas consecutivas sin duplicados.** Bloqueado por: T04. Entrega: Anotar solo un título con Enter o botón permite seguir capturando en la misma columna.

6. **Editar desde un detalle único y resolver conflictos.** Bloqueado por: T05. Entrega: Abrir, guardar y cerrar una tarea conserva el borrador y el contexto de origen.

7. **Mover y ordenar sin perder ediciones.** Bloqueado por: T01, T06. Entrega: Organizar tarjetas y columnas con arrastre o controles mantiene estado y fecha.

8. **Completar, agrupar y reabrir tareas.** Bloqueado por: T06. Entrega: Completar conserva la columna y las hechas quedan visibles en un grupo personal.

9. **Programar una fecha puntual y cambiar zona.** Bloqueado por: T06. Entrega: Elegir un día sin hora muestra hoy/vencida correctamente en cualquier dispositivo.

10. **Invitar y aceptar colaboración.** Bloqueado por: T03, T04. Entrega: Propietario invita directamente o por enlace, y el destinatario entra sin crear tablero propio.

11. **Asignar y trabajar desde Mis tareas.** Bloqueado por: T08, T09, T10. Entrega: Asignar una persona actual reúne sus tareas sin copiarlas; completar afecta el tablero original.

12. **Eliminar y recuperar tareas durante siete días.** Bloqueado por: T06. Entrega: Papelera recupera una tarea autorizada con su vencimiento visible y causa de borrado.

13. **Usar pasos independientes dentro de una tarea.** Bloqueado por: T08, T12. Entrega: Checklist se guarda por su acción y completar con pendientes pide confirmación.

14. **Conversar, mencionar y moderar.** Bloqueado por: T06, T10, T12. Entrega: Comentarios y menciones actuales quedan junto a la tarea con autoría y moderación segura.

15. **Retirar miembros y transferir propiedad.** Bloqueado por: T10, T11, T14. Entrega: Salir, retirar o cambiar dueño conserva trabajo y retira referencias activas al exmiembro.

16. **Borrar columnas y tableros con recuperación.** Bloqueado por: T07, T12, T15. Entrega: Eliminar una columna resuelve destinos; recuperar tablero respeta autoridad y plazos.

17. **Suspender cuentas con sucesión íntegra.** Bloqueado por: T03, T16. Entrega: El administrador suspende a alguien resolviendo todos sus tableros sin leerlos.

18. **Sincronizar con canales privados y revocación.** Bloqueado por: T17. Entrega: Dos sesiones ven cambios sin perder foco ni conservar acceso revocado.

19. **Marcar tableros favoritos.** Bloqueado por: T04. Entrega: Estrella y sección Favoritos ayudan a volver a tableros sin cambiar membresías.

20. **Elegir tema claro, oscuro o Sistema.** Bloqueado por: T02. Entrega: Cambiar tema conserva el editor y aplica la preferencia de la cuenta correcta.

21. **Repetir diariamente con ejecución durable.** Bloqueado por: T09, T12, T13. Entrega: Crear una rutina diaria produce una sola vigente aun sin navegadores abiertos.

22. **Repetir por semanas y días elegidos.** Bloqueado por: T21. Entrega: Elegir días y semanas alternas conserva el calendario aunque se complete tarde.

23. **Repetir por meses, años y ordinales.** Bloqueado por: T21. Entrega: Reglas mensuales/anuales manejan febrero, último día y ordinales sin desplazar el ancla.

24. **Anticipar y editar próximas repeticiones.** Bloqueado por: T22, T23. Entrega: Editar la serie cambia únicamente próximas y permite aparición anticipada segura.

25. **Consultar historial, detener y volver a programar.** Bloqueado por: T21. Entrega: Series localiza rutinas y su historia; reprogramar una detenida crea otra sin duplicar tarjeta.

26. **Eliminar y recuperar series y ocurrencias.** Bloqueado por: T16, T24, T25. Entrega: Elegir alcance de borrado y recuperar respeta exclusiones, última válida y padres.

27. **Recordar cumpleaños sin completarlos.** Bloqueado por: T23, T24. Entrega: Cumpleaños anuales aparecen todo el año o en una ventana elegida, sin casilla.

28. **Clasificar con etiquetas y recuperarlas.** Bloqueado por: T06, T12, T27. Entrega: Gestionar etiquetas del tablero clasifica tareas/cumpleaños sin moverlas ni completarlas.

29. **Heredar etiquetas activas en repeticiones.** Bloqueado por: T24, T28. Entrega: Plantilla y cada ocurrencia tienen etiquetas independientes; las nuevas heredan solo activas.

30. **Duplicar una tarea puntual.** Bloqueado por: T13, T25, T28. Entrega: Un preview permite crear una copia pendiente en el mismo tablero sin heredar programación ni conversación.

31. **Buscar tareas, comentarios y tableros con contexto.** Bloqueado por: T11, T14, T25, T28. Entrega: Escribir muestra coincidencias por tipo/origen y elegir abre destino preciso sin cambiar el origen.

32. **Recordar filtros y orden por contexto.** Bloqueado por: T31. Entrega: Consultas y preferencias se sincronizan sin alterar el trabajo de otros ni ampliar alcances.

33. **Guardar, revisar y recuperar vistas personales.** Bloqueado por: T12, T32. Entrega: Consultas con nombre vuelven a datos actuales y se corrigen explícitamente si pierden referencias.

34. **Consultar actividad mínima de la tarea.** Bloqueado por: T07, T11, T12. Entrega: Ver cambios de campos y recuperaciones explica lo ocurrido sin versionar conversaciones.

35. **Recibir novedades pertinentes sin duplicados.** Bloqueado por: T11, T14, T21. Entrega: Bandeja avisa asignaciones, menciones, comentarios y cambios de vencimiento a destinatarios vigentes.

36. **Marcar novedades cargadas como leídas.** Bloqueado por: T35. Entrega: Una pulsación procesa exactamente el lote visto y explica resultados parciales.

37. **Abrir enlaces de texto de forma segura.** Bloqueado por: T13, T14. Entrega: URLs en descripción, comentarios y pasos se abren explícitamente conservando el texto.

38. **Adjuntar textos privados con cuota y recuperación.** Bloqueado por: T12, T15, T21. Entrega: Subir/descargar/borrar/recuperar txt/md mantiene límites y permisos incluso ante fallos.

39. **Limpiar archivos y avisar capacidad.** Bloqueado por: T17, T35, T38. Entrega: Propietarios y administrador administran espacio con metadatos adecuados y avisos sin spam.

40. **Exportar un tablero completo en formato portable.** Bloqueado por: T26, T27, T29, T34, T38. Entrega: Descargar un paquete consistente conserva contenido autorizado aunque no esté cargado en pantalla.

41. **Importar un respaldo v1 con reemplazo seguro.** Bloqueado por: T40. Entrega: El dueño previsualiza un archivo legado y confirma reemplazo íntegro conservando el previo.

42. **Importar un respaldo v2 completo.** Bloqueado por: T41. Entrega: El paquete nuevo reconstruye contenido y archivos con mapeos privados y calendario coherente.

43. **Recuperar el contenido previo a una importación.** Bloqueado por: T42. Entrega: Revisar y restaurar el reemplazo anterior evita sobrescribir trabajo nuevo silenciosamente.

44. **Instalar la PWA y abrir destinos privados.** Bloqueado por: T06, T18, T20. Entrega: Instalación opcional abre la misma aplicación y respeta login, enlaces y cambio de cuenta.

45. **Actualizar la aplicación sin perder edición.** Bloqueado por: T44. Entrega: Se informa versión disponible y la persona elige cuándo recargar.

46. **Verificar carga, páginas y orden con datos realistas.** Bloqueado por: T31, T34, T35, T40. Entrega: Tableros y listas siguen utilizables al crecer, sin conversaciones completas ni export truncado.

47. **Verificar aislamiento en todos los recorridos.** Bloqueado por: T18, T26, T30, T33, T36, T37, T38, T42, T44. Entrega: Una matriz de dos cuentas confirma que ninguna superficie secundaria elude permisos.

48. **Ensayar respaldo y recuperación de instancia.** Bloqueado por: T33, T39, T43, T45, T47. Entrega: Un operador recupera base, objetos y configuración en un destino aislado.

49. **Validar uso cotidiano con móvil y accesibilidad.** Bloqueado por: T45, T46, T47. Entrega: Personas del piloto pueden capturar, encontrar, completar, coordinar y retomar una rutina.

50. **Ensayar la transición privada y preparar el corte.** Bloqueado por: T19, T48, T49. Entrega: Un ensayo con inventario ficticio demuestra preservación de tableros y dueños antes del despliegue.

51. **Ejecutar el corte privado autorizado.** Bloqueado por: T50. Entrega: La instancia real migra a acceso privado y sus recorridos quedan verificados con recuperación disponible.

## Cobertura de las33 propuestas

Esta matriz asigna responsables; no afirma que estén implementadas ni que pruebas hayan pasado. Los contratos exactos siguen en la spec y criterios de cada borrador.

| Propuesta | Tickets responsables |
| --- | --- |
| P01 | T05, T07, T08, T11 |
| P02 | T05 |
| P03 | T06, T13, T14, T38 |
| P04 | T05, T08, T09, T13, T27 |
| P05 | T31, T32 |
| P06 | T08, T20, T32, T33 |
| P07 | T06, T25, T31 |
| P08 | T04, T06, T07, T20, T49 |
| P09 | T05, T06, T07, T44, T49 |
| P10 | T02, T04, T06, T31 |
| P11 | T06, T25, T31, T44 |
| P12 | T02, T09, T31, T49 |
| P13 | T19 |
| P14 | T31 |
| P15 | T35, T36, T39 |
| P16 | T02, T10, T15, T17, T18, T38, T47 |
| P17 | T01, T02, T05, T06, T10, T15 |
| P18 | T05, T06, T07, T08, T30, T36, T41 |
| P19 | T21, T35, T38, T39 |
| P20 | T18, T44, T47 |
| P21 | T12, T13, T14, T16, T26, T28, T33, T38, T43 |
| P22 | T38, T39, T42 |
| P23 | T14, T25, T31, T34, T35, T40, T46 |
| P24 | T40, T41, T42, T43, T48, T50, T51 |
| P25 | T21, T38, T48, T50, T51 |
| P26 | T46, T49, T50, T51 |
| E01 | T28, T29, T40, T42 |
| E02 | T33 |
| E03 | T20 |
| E04 | T30 |
| E05 | T34, T40, T42 |
| E06 | T44, T45 |
| E07 | T36 |

## Cobertura de los63 escenarios de cierre

Complementan los casos base de Auth/invitaciones/tareas/calendario/archivos/transición; no son el total de tests del producto.

| Escenario | Tickets responsables |
| --- | --- |
| C100-AC01 | T28 |
| C100-AC02 | T28 |
| C100-AC03 | T28 |
| C100-AC04 | T28 |
| C100-AC05 | T33 |
| C100-AC06 | T33 |
| C100-AC07 | T33 |
| C101-AC08 | T28 |
| C101-AC09 | T29 |
| C101-AC10 | T30 |
| C101-AC11 | T40, T42 |
| C101-AC12 | T33 |
| C101-AC13 | T33 |
| C101-AC14 | T33 |
| C102-AC15 | T28, T33 |
| C102-AC16 | T28, T33 |
| C102-AC17 | T28 |
| C102-AC18 | T28, T31 |
| C102-AC19 | T33 |
| C102-AC20 | T33 |
| C103-AC18b | T28, T33 |
| C104-AC21 | T30 |
| C104-AC22 | T30 |
| C104-AC23 | T30 |
| C104-AC24 | T20 |
| C104-AC25 | T11, T32 |
| C104-AC26 | T20, T32 |
| C105-AC27 | T30 |
| C105-AC28 | T30 |
| C105-AC29 | T34 |
| C105-AC30 | T34 |
| C105-AC31 | T34 |
| C105-AC32 | T34 |
| C105-AC33 | T34, T40, T42 |
| C106-AC34 | T32 |
| C106-AC35 | T32 |
| C106-AC36 | T32 |
| C106-AC37 | T32 |
| C106-AC38 | T32 |
| C106-AC39 | T32 |
| C108-AC40 | T31 |
| C108-AC41 | T31 |
| C108-AC42 | T31 |
| C108-AC43 | T31 |
| C109-AC44 | T44 |
| C109-AC45 | T44 |
| C109-AC46 | T45 |
| C109-AC47 | T36 |
| C109-AC48 | T36 |
| C110-AC49 | T21, T22, T23 |
| C110-AC50 | T21, T22, T23 |
| C110-AC51 | T24 |
| C110-AC52 | T26 |
| C110-AC53 | T26 |
| C110-AC54 | T12, T13, T16, T26 |
| C111-AC55 | T21 |
| C111-AC56 | T24 |
| C111-AC57 | T35 |
| C111-AC58 | T39 |
| C111-AC59 | T37 |
| C111-AC60 | T37 |
| C112-AC61 | T31, T32, T33 |
| C112-AC62 | T25, T26 |

## Revisión solicitada por la skill

1. ¿La granularidad se siente adecuada, demasiado gruesa o demasiado fina?
2. ¿Las dependencias bloquean solo donde realmente hace falta terminar lo anterior?
3. ¿Conviene unir o dividir algún ticket?

Recomendación: aprobar TT-0.1 como base; si un agente descubre que un ticket supera una sesión/contexto, proponer subdivisión conservando contratos y aristas antes de tomar una entrega parcial como completa.

Desglose aprobado y51 hijos publicados el27/10/2026; el mapa real de IDs y su verificación están en Tickets publicados. Las preguntas anteriores son registro del paso de revisión ya respondido. La política de ejecución en loop es una preparación posterior; publicar tickets no crea automatización, hilo ni goal y no inicia implementación.
