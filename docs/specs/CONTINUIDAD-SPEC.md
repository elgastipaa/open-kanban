# Continuidad — OpenKanban Personal

Checkpoint: 2026-10-28. Goal activo por instrucción explícita del usuario conforme LP-0.2: GPT Luna Max, loop continuo secuencial, implement-spec coordinador e implement por ticket. Autorizados trabajo/pruebas aisladas, ramas codex/, commits/push a esas ramas, PR acumulada en borrador y seguimiento/cierre de hijos con evidencia. Main, producción y el corte #53 conservan aprobación específica. Las33 P/E y51 tickets mantienen el alcance completo.

## Ubicación y alcance

Workspace de esta sesión: `C:\Users\gasto\Documents\GitHub\open-kanban`, HEAD inspeccionado `46c94139bac67aaca1d491b29afc3bc999fc288f`. Usar este checkout y su contexto para continuar. El checkpoint anterior indicaba `/home/gmendoza/coding/open-kanban` en Ubuntu WSL; no se verificó que ambos directorios estén sincronizados. No editar ni operar el checkout WSL por asumir equivalencia, ni usar el directorio de WodLab.

Fase actual: implementación autorizada en aislamiento y ramas codex conforme al Goal del28/10. C-99 mantiene todas P01–P26/E01–E07 en el MVP. No autoriza SQL/migración de producción, merge/push a main ni despliegue. Vercel: main despliega; conservar desactivadas las otras ramas según configuración y verificar destino antes de push.

App conocida: https://gkanban.vercel.app. Repositorio propio conocido: https://github.com/elgastipaa/open-kanban. Se verificó la publicación del issue de spec; no se verificó el estado de la app desplegada ni de su base. No leer `.env.local`, copiar credenciales del chat ni incorporarlas a documentos. La comprobación histórica de rotación de credenciales antes del uso real sigue sin evidencia de resolución.

## Consolidación con to-spec

El 26/10/2026 el usuario confirmó las tres fronteras de pruebas y la publicación de la spec en GitHub Issues. Se habilitó Issues en el repositorio elegido, que lo tenía deshabilitado, y se publicó [Spec OpenKanban 1.0 — issue #2](https://github.com/elgastipaa/open-kanban/issues/2) con `ready-for-agent`. Se verificaron el cuerpo completo y la etiqueta mediante una lectura posterior.

Copia local: [SPEC-OPENKANBAN-1.0](./SPEC-OPENKANBAN-1.0.md). Contiene las siete secciones de to-spec, 116 historias de usuario, las 33 incorporaciones con sus contratos y criterios, y los detalles aún abiertos. Es una síntesis de los documentos dueños enumerados abajo, no un reemplazo silencioso de sus acuerdos.

Las fronteras de prueba aprobadas son operaciones reales de servidor/base sobre entornos aislados, recorridos de navegador en móvil/escritorio y programación con fechas controladas. Se reutiliza el arnés SQL existente adaptándolo al modelo privado; la validación histórica de navegador no equivale a una suite mantenida de esta spec. No se ejecutaron nuevas pruebas funcionales durante su redacción.

La configuración para agentes está en `AGENTS.md` y `docs/agents/`: GitHub Issues como gestor, cinco etiquetas de triage y `CONTEXT.md` como glosario único. La etiqueta del issue sigue el flujo de la skill; no cierra los detalles pendientes ni autoriza implementación, commit/push o despliegue. El siguiente paso sigue siendo cerrar esos detalles y preparar el diseño técnico antes de dividir la implementación en tickets.

## Lectura y precedencia

1. [Spec 0001](./0001-auth-collaboration.md), revisión base 0.33 + C-100–112: acuerdos C-01–112 y evidencia del código. Un acuerdo posterior explícito prevalece sobre antecedentes incompatibles; C-63 y C-72 están sustituidos.
2. [MVP 1.0](./MVP-1.0.md), revisión 0.25: spec integral; §16 incluye las 33 filas y §16.5 identifica los detalles restantes dentro del alcance.
3. [Incorporaciones desde Plane](./PROPUESTAS-DESDE-PLANE.md): tabla completa aceptada, contraste anterior a C-99, un criterio por fila y fuentes fijadas al commit inspeccionado. E ya no significa backlog.
4. [Matriz de permisos](./MATRIZ-PERMISOS-MVP-1.0.md), revisión 0.3; [Pantallas](./PANTALLAS-MVP-1.0.md), revisión 0.5; [Estados y errores](./ESTADOS-Y-ERRORES-MVP-1.0.md), revisión 0.3: contratos por actor, interacción y fallo. Consultar el documento dueño para evitar reglas duplicadas divergentes.
5. [Cierre funcional](./CIERRE-MVP-1.0.md), revisión 0.6: CF-21–27 y H/H.1 consolidan extensiones y mecanismos por diseñar. No interpretar como aceptados los detalles expresamente candidatos.
6. [CONTEXT](../../CONTEXT.md): glosario de dominio. [Referencias de producto](./REFERENCIAS-PRODUCTO.md) e [informe Plane](../research/PLANE-VS-OPEN-KANBAN-2026-10-24.md) son investigación histórica; no agregan capacidades por asociación.

## Decisiones que deben conservarse

- C-94: admin global no obtiene lectura automática de tableros ajenos. Dueño cambia nombre/zona; recuperación según actor/causa; miembro borra su adjunto y dueño modera; proteger único admin.
- C-95: reconciliar resultado incierto antes de repetir; conflicto conserva edición y exige revisar; borrador durante sesión sin promesa tras cierre. Guardar/Descartar/Cancelar antes de mover/completar/borrar con campos pendientes. Comentarios/pasos/adjuntos independientes; perder acceso retira contenido/borrador.
- C-96: primer uso sencillo sin tutorial obligatorio, ejemplos automáticos ni columnas impuestas. Aceptar tablero compartido no exige crear uno.
- C-97: directa a cuenta habilitada y genérica por enlace coexisten; 72 h, un uso, revocables, colaborador, habilitación previa, sin email automático.
- C-98: una directa pendiente por persona/tablero, renovación explícita, preview solo tablero/invitador/rol. Recuperación con dueño y plazos preservados; resolver propiedad de tableros ya en papelera. Cambiar serie conserva exclusiones aplicables e informa las que dejan de aplicar. Transición con inventario autorizado/propietario explícito, nunca primer login.
- C-99 (aceptación 24/10, consolidación 25/10): **todas P01–P26 y E01–E07 aprobadas para esta spec/MVP**. Incluye etiquetas, vistas personales guardadas, temas, copia puntual, actividad mínima, instalación PWA y lectura por lote de novedades cargadas, además de las 26 P. No volver a preguntar si se incorporan. Quedan abiertos los detalles que las filas no definieron; no se declara implementación ni compatibilidad verificada.

## Cierre por bloques — C-100–112 (26–27/10/2026)

El usuario aprobó las siete recomendaciones E01/E02: facultades, nombres/límites, tareas/cumpleaños/plantilla, OR entre etiquetas, contenido/alcance de vistas, actualización explícita y catálogo personal de vistas. Contrato y escenarios en Cierre CF-22.1; trazabilidad en spec 0001 C-100. Se mantienen todas las P/E. El objetivo posterior es implementación completa por otro agente en loop, con criterios verificables; no se inicia ese loop durante la entrevista.

C-101 registra Q8–14: recuperación etiquetas/vistas siete días con actor actual autorizado, herencia activa al generar, copia de origen, catálogo activo en respaldo; referencia explícita inválida bloquea hasta revisar/confirmar y conflicto sin sobrescritura. Contratos/criterios en CF-22.2; issue #2 y copia local se actualizan juntos.

C-102 registra Q15–17 y Q19–20 aprobadas: cupos activos, resolver nombres/asociaciones al restaurar, reparación explícita y guardado tardío sin resurrección. Q18 corregida: búsquedas/filtros ignoran acentos y ñ/n. Contrato/criterios CF-22.3.

C-103 acepta Q18b: la misma equivalencia de acentos/ñ, mayúsculas y espacios sobrantes impide duplicados en etiquetas/vistas dentro del ámbito correspondiente. Conservar texto e identidad, sin fusionar. Contrato CF-22.4. E01/E02 quedan cerradas funcionalmente en estas rondas; quedan diseño técnico/validación de formato y mecanismos.

C-104 registra Q21–26: copia con título igual editable, columna origen elegible del mismo tablero/final manual, fuentes completadas/históricas; Sistema inicial/cuenta login; desempate creación/ID, completadas recientes y preferencias distintas combinables con revisión de conflictos sobre misma preferencia. Contratos/criterios CF-24.1/CF-13.1. No editar/reabrir histórica al preparar nueva copia.

C-105 registra Q27–33: confirmación/cancelación/resultado de copia y cambio de origen; actividad E05 con valores/atribución, 180 días por evento, ocultar/purgar dependiente y respaldo de vigentes sin avisos antiguos. CF-24.2/CF-25.1 y C105-AC27–33. No copiar actividad por E04 ni añadir categorías de creación/copia.

C-106 registra Q34–39 aprobadas: defaults y contextos, texto de nueva búsqueda, Limpiar/Reiniciar y filtros recordados inválidos. CF-13.2. C-107 amplía búsqueda por pedido explícito del usuario: sugerencias en múltiples campos/entidades, títulos/tareas/comentarios/tableros, tipo/origen visibles y selección antes de navegar/filtrar. Sustituye límite anterior solo título/descripción y exclusión de comentarios; no es paridad asumida con Vercel.

C-108 registra Q40–43: etiquetas como filtros; destinos precisos y acción Ver tareas separada/deduplicada; relevancia por grupos con exactas/prefijos/palabras incompletas y lista por preferencias; filtros de tarea heredados por comentarios y tableros como navegación separada. Archivos/actividad fuera del alcance inicial. CF-14.2/C108-AC40–43. Viabilidad en [investigación de búsqueda](../research/BUSQUEDA-UNIFICADA-VIABILIDAD-2026-10-26.md), que conserva propuestas históricas; C-108 es el acuerdo vigente.

C-109 registra Q44–48: matriz inicial/versión probada, instalación opcional en cuenta directa/manual, actualización avisada/elegida sin pérdida de borrador, botón de lote con cantidad sin leer y una pulsación, conjunto fijo y resumen/reintento solo falladas autorizadas. CF-26.1/CF-27.1/C109-AC44–48. [Investigación PWA/lotes](../research/PWA-Y-NOVEDADES-VIABILIDAD-2026-10-26.md) conserva propuestas técnicas que no se vuelven acuerdos por asociación.

C-110 (27/10) registra Q49–54: inicio/anclaje, final/conteo, excepción anterior a siguiente aparición, recuperación finita máxima última válida aunque no materializada, restauración individual de su exclusión y permisos ordinarios pasos/series/columnas. CF-04.1/CF-07.1/CF-09.1 y C110-AC49–54. Actualizar marcadores obsoletos de candidatos, sin reabrir C-73/C-98.

C-111 registra Q55–60: convertir actual primera cuentaN y fecha explícita compatible; editar N próximas no alteraactual/pasado ni resetporotroscampos; creador de serie elegible; rearme solo cruce tras bajar y 24 h; autolinks porcampos/esquemas/acción. CF-04.2/15.1/16.1/18.1 y C111-AC55–60.

C-112 (2026-10-27): el usuario acepta Q61–62 («Dale»). Búsqueda ofrece «Incluir historial de repeticiones», desactivado por defecto, independiente de «Incluir completadas» y guardable en vistas; incluye ocurrencias reemplazadas y sus comentarios autorizados, con estado/fecha/origen y apertura precisa sin reabrir ni modificar. Volver a programar tras «Dejar de repetir» crea nueva serie usando la misma tarjeta como primera; anterior detenida conserva historial, sin reactivar pasado/exclusiones ni reiniciar sus conteos. Confirmación explica cambio; borrar/restaurar anterior no afecta tarjeta ni calendario de nueva. Todas las P/E permanecen. Contratos CF-14.3/CF-08.1; C112-AC61–62. No implementación.

La [auditoría funcional del 27/10](./AUDITORIA-CIERRE-FUNCIONAL-2026-10-27.md) ya está realizada. Sus dos decisiones H-01/H-02 quedaron aprobadas como Q61–62 en C-112: historial explícito en búsqueda y nueva serie al reprogramar, con protección frente a borrado/restauración de la anterior. No quedan decisiones funcionales identificadas pendientes en esa auditoría; no reabrir Q1–62/Q18b.

La [matriz de trazabilidad](./MATRIZ-TRAZABILIDAD-1.0.md) indexa las 33 P/E y 63 escenarios de aceptación incorporados durante estas rondas, con evidencia prevista, no ejecutada. La investigación técnica está guardada en [identidad y mutaciones](../research/BASE-TECNICA-IDENTIDAD-Y-MUTACIONES-2026-10-27.md) y [ejecución durable y respaldo](../research/BASE-TECNICA-EJECUCION-Y-RESPALDO-2026-10-27.md). Sus propuestas no equivalen a decisiones aprobadas ni a capacidades verificadas en el entorno desplegado. El diseño recomendado [DT-0.1](./DISENO-TECNICO-MVP-1.0.md) ya concreta módulos, modelo lógico, comandos/locks, calendario/jobs, almacenamiento, búsqueda, sesiones/PWA, portabilidad y dependencias D0–D8. La consolidación retiró marcas funcionales obsoletas de admisión, calendario, recuperación, búsqueda y avisos; se conservan registros históricos. G01–G08 separa diseño de verificaciones pendientes. No iniciar implementación.

## Punto de reanudación

La incorporación de las33 propuestas y el cierre funcional C-112 están documentados. DT-0.1 y la matriz de trazabilidad preparan la descomposición; siguiente trabajo:

1. TT-0.1 aprobado por el usuario el27/10/2026 y publicado mediante to-tickets:51 issues #3–#53, ready-for-agent,51 relaciones nativas de subtarea bajo #2 y111 bloqueos nativos. [Mapa de ejecución real](./TICKETS-PUBLICADOS-1.0.md); [desglose aprobado](./PLAN-TICKETS-1.0.md). Cobertura de33 P/E y63 escenarios, dependencias sin ciclos y corte condicionado a autorización real. Cuerpos completos/etiquetas verificados; comprobación final de aristas registrada en el mapa al concluir. Cuerpos publicados individuales y manifiestos conservados en `.scratch/openkanban-1-0/`. No se modificó/cerró cuerpo/estado del padre. #1 es una PR de preparación fusionada, no otra spec que deba descomponerse.
2. Publicación verificada por lectura el27/10:51 cuerpos/títulos/etiquetas y51 subtareas/111 aristas nativas exactas, sin cambiar cuerpo/estado de #2. El28/10 el usuario ajustó las reglas y se escribió [LP-0.2](../agents/implementation-loop.md): Goal continuo, GPT Luna con razonamiento Max, implement-spec como coordinador secuencial, implement por ticket con TDD/revisión/commits, un solo implementador activo y avance automático al siguiente. El [comando de arranque](../agents/start-implementation-goal.md) explicita permisos futuros de implementación/Git/tracker, preserva main/producción y no se ejecutó. No crear un Goal por confundir el pedido de instrucciones con una orden de arrancar. Pruebas manuales/configuración externa siguen requiriendo evidencia; #53 conserva aprobación específica, sin declarar completo el objetivo global al terminar #52.
3. El usuario activó el Goal el28/10 con el comando preparado. Preparar base documental versionada, checkout aislado y primer ticket elegible #3. Estado de ejecución en [checkpoint del run](../agents/implementation-run.md); conservar cambios ajenos y todas las E.
4. Ejecutar G01–G07 durante implementación aislada autorizada; G08 configura y ensaya el corte real antes de despliegue autorizado. Inventario/propietarios reales y credenciales siguen sin verificarse.

Esta consolidación y diseño no ejecutaron pruebas funcionales ni accedieron a infraestructura; los gates no se declaran cumplidos.

Los escenarios AC/MVP-AC/NAV/UI-PL/PERM/ERR/ERR-PL/INV/BACKUP/TEC son criterios, no pruebas ejecutadas. La app desplegada no se afirma actualizada por modificar estos documentos.

## Investigación de Plane

Clon autorizado: `C:\Users\gasto\Documents\GitHub\plane`, rama `preview`, commit `d9726d5c9615756135f3d6cd512ece8e2dd42902`; también se inspeccionó tag `v1.4.2` (`5f7d92784c403f76284f0f16718f320221dc7fec`). Investigación estática, sin ejecutar la app ni modificar ese repositorio.

La recomendación de base sigue siendo evolucionar OpenKanban, adaptar patrones útiles y conservar su experiencia personal/stack. C-99 no decide un fork ni copia literal de Plane. Revisar licencia/origen si se propone reutilizar código.

## Estado del guardado

Archivos locales, sin commit/push. Estado observado: `?? AGENTS.md`, `?? CONTEXT.md`, `?? docs/agents/`, `?? docs/specs/`, `?? docs/research/`, ` M docs/VALIDATION.md`. La síntesis de spec sí está publicada en el issue #2 por autorización explícita; esto no publica los archivos locales en una rama. VALIDATION era un cambio previo y no se editó durante esta incorporación. Preservar cualquier cambio ajeno. No interpretar «guardar» como publicar o confirmar en Git.

Usar Git sobre el workspace explícito de esta sesión; no cambiar configuración global ni copiar archivos entre checkouts por inferencia. No ejecutar pruebas de otro proyecto ni usar producción para datos de prueba.
