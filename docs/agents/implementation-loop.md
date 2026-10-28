# Reglas del loop de implementación — LP-0.2

Fecha: 28/10/2026. **LP-0.2 activa por el Goal explícito del usuario.** GPT Luna Max, ejecución continua y skills de implementación por ticket. Autorización vigente en Continuidad y [checkpoint de ejecución](./implementation-run.md). Este documento prescribe el proceso; GitHub guarda el estado de los tickets y Git guarda el código.

Objetivo: completar la spec#2 y todas las33 P/E mediante los51 tickets publicados, con evidencia. El padre no se considera terminado por agotar lo que un agente puede hacer automáticamente. Contexto: [Continuidad](../specs/CONTINUIDAD-SPEC.md), [mapa real](../specs/TICKETS-PUBLICADOS-1.0.md), [diseño](../specs/DISENO-TECNICO-MVP-1.0.md) y [trazabilidad](../specs/MATRIZ-TRAZABILIDAD-1.0.md).

## 1. Acuerdo propuesto para el arranque

| Regla | Recomendación |
| --- | --- |
| Ejecución | Loop continuo bajo un único Goal, un ticket activo y un implementador a la vez. Integrar/cerrar y tomar inmediatamente el siguiente elegible, sin pedir «seguí». Un cambio de turno/contexto no termina el trabajo. |
| Selección | Recorrer todos los hijos #3–#53 por sus bloqueos, no solo el primer ticket. Tomar el menor número elegible, ready-for-agent y sin reclamación ajena. #53 conserva su aprobación específica de producción. |
| Git | Rama de integración codex/openkanban-1-0 y rama de trabajo codex/issue-N por ticket. Commits vinculados al issue; integración por avance rápido después de verificar/revisar. Push ordinario de ramas codex autorizadas y una PR acumulada en borrador. |
| Cierre | Cerrar un hijo solo con criterios verificados, revisión resuelta y código integrado/publicado en la rama de integración. “Cerrado” acredita esa entrega en integración, no despliegue en main. |
| Autonomía | Resolver ingeniería y reparar fallos/regresiones dentro del contrato. Cambio de producto, reducción de alcance, servicio pago o ampliación grande del plan requiere intervención del usuario. |
| Modelo y skills | GPT Luna con razonamiento Max elegido por el usuario para coordinador, implementador, merger y revisores; sin sustitución silenciosa. $implement-spec coordina secuencialmente y $implement se ejecuta en cada ticket, con $tdd y $code-review. |
| Comunicación | Registrar cada entrega en su ticket; dar al usuario un resumen cada cinco tickets y al terminar. Avisar de inmediato decisiones humanas o riesgos confirmados. Evitar avisos repetidos del mismo bloqueo. |
| Límite | Main, merge final, despliegue y migración de producción quedan para aprobación específica. #53 no forma parte del avance automático autorizado por defecto. |

El comando de arranque de §8 acepta LP-0.2 y habilita las operaciones de Git/tracker indicadas para implementación y pruebas aisladas, conservando los límites de main/producción. Si el usuario limita permisos al arrancar, su alcance explícito prevalece. Este turno solo prepara instrucciones: no crea Goal, scheduler ni chat, no cambia el modelo de la conversación ni modifica configuración global.

## 1.1 Skills y modelo obligatorios

Resolver y leer las skills instaladas antes de ejecutarlas. En esta estación están en C:/Users/gasto/.codex/skills, cada una con su SKILL.md. Los subagentes deben recibir el puntero a este documento, issue, spec/diseño relevantes y SHA base; no necesitan toda la conversación histórica.

- **$implement-spec:** coordinador del grafo, integración, revisión final y limpieza. Se usa con la adaptación secuencial solicitada: máximo un implementador activo. Al completar implementación, pruebas, revisión e integración de un ticket, iniciar el próximo sin detener el Goal. El merger actúa después de terminar el implementador; nunca dos escritores simultáneos.
- **$implement:** obligatorio dentro del implementador de cada ticket. Leer el issue y comentarios, anunciar su título, aplicar TDD donde corresponda, verificar, llamar a code-review y hacer commits en su rama de trabajo. El coordinador verifica su evidencia y HEAD; no repite la misma revisión sin cambios que lo justifiquen.
- **$tdd:** rojo→verde por comportamiento observable. Ya están aprobadas las tres interfaces: servidor/base real aislada, navegador y programación con reloj controlado. Registrarlas al planear el ticket y usarlas sin volver a pedir permiso. Una nueva interfaz de prueba realmente distinta requiere acordarla, no cada caso ni cada test.
- **$code-review:** dos revisores de solo lectura, normas y spec, contra SHA base fijado antes de implementar. Pueden correr en paralelo entre sí, con el mismo GPT Luna Max. Corregir hallazgos materiales y asociar informe al HEAD final. Al terminar todo el conjunto implementable, implementar-spec hace además la revisión final de la integración, corrige y verifica antes de anunciar entrega.
- **Ejecución de skills:** usar el mecanismo de invocación disponible; si el entorno no expone una herramienta Skill, leer SKILL.md y seguir sus pasos explícitamente. Registrar la skill aplicada y resultados, sin simular una invocación inexistente.

Typechecking y tests de archivo/caso durante el trabajo; suite completa al terminar cada ejecución de implement, y verificación final del conjunto integrado. No repetir suites completas ya verdes sin cambios, fallos o preocupaciones nuevas que lo justifiquen. Pruebas reales obligatorias que no puedan ejecutarse quedan pendientes y mantienen abierto el issue.

El usuario eligió **GPT Luna + Max**; el selector real del chat y los parámetros del lanzamiento de subagentes deben concordar. Conservar el modelo seleccionado y heredar Max o indicarlo explícitamente según el mecanismo disponible. Si no está disponible, informar bloqueo de configuración; no cambiar a Sol/Astra/u otra versión por iniciativa propia. Este documento no afirma haber cambiado settings globales.

Adaptaciones de implement-spec que prevalecen por las instrucciones del proyecto/usuario: secuencial en vez de máxima concurrencia; worktree limpio basado en integración confirmado sin reset destructivo; PR con referencias al padre y sin cierre automático prematuro; mantenerla en borrador si hay criterios/manuales o corte pendientes. La selección de skills no autoriza main ni producción.

## 2. Preparación única antes del primer ticket

1. **Resolver autorización y base.** Leer Continuidad y pedido de arranque, confirmar repo/checkout/remoto/HEAD y examinar cambios presentes. Guardar en el checkpoint la autorización concreta: alcance, ramas, commits, push, PR/seguimiento, revisores y entornos. Finaliza con alcance inequívoco, o informar exactamente qué falta.
2. **Hacer transportable el contexto.** Las specs/AGENTS/CONTEXT/diseño/reglas siguen locales sin commit al preparar LP-0.2. Con autorización de arranque, preparar un commit de documentación en la rama de integración usando una selección explícita de archivos revisados. Conservar separado el cambio previo de docs/VALIDATION.md y cualquier cambio ajeno. No hacer git add indiscriminado. Finaliza con las fuentes necesarias versionadas y HEAD identificable antes de abrir otro checkout.
3. **Aislar ejecución.** Usar un checkout de trabajo limpio que incluya esa base; conservar el checkout original y sus cambios ajenos. Integración y ramas por ticket parten de la base acordada. No reaprovechar el checkout WSL por suponer que coincide. Finaliza con rama y ruta explícitas, sin depender de archivos ignorados o sin seguimiento que faltarán en otra sesión.
4. **Verificar entorno.** Identificar base/Auth/Storage/Realtime de prueba y su aislamiento; usar datos ficticios y configuración de prueba, sin reutilizar .env.local ni producción. Confirmar herramientas disponibles y pruebas vigentes del repo. Verificar remoto de push y que la configuración de ramas conserva despliegues de main separados; no cambiarla para poder continuar. Finaliza con operaciones de prueba seguras o bloqueo acotado, sin contratar/provisionar un servicio.
5. **Reconciliar tracker.** Leer hijos, etiquetas, comentarios y aristas actuales del padre#2 con el tracker configurado. El mapa local es referencia, no prueba de que el estado remoto sigue igual. Finaliza con frontera actual y primer elegible; en el estado de publicación del27/10 era #3.

Usar las instrucciones de [tracker](./issue-tracker.md), [etiquetas](./triage-labels.md) y [dominio](./domain.md) cuando se alcance su caso. Los archivos de entorno/credenciales no se copian a commits, informes o comentarios.

## 3. Una iteración completa

1. **Elegir.** Aplicar §4. Leer ticket completo y comentarios, documentos dueños y contratos/escenarios afectados. Capturar SHA de integración/base de revisión. Finaliza con lista de criterios y cómo observar cada uno; no empezar si el resultado esperado cambia el producto sin acuerdo.
2. **Reclamar.** Registrar asignación al usuario autenticado y comentario con identificador de ejecución, rama y base. Volver a consultar antes de editar si hay actividad concurrente; ante otra reclamación activa, elegir otro elegible. Una fecha vieja por sí sola no autoriza quitar una reclamación ajena.
3. **Implementar.** El coordinador $implement-spec lanza un único implementador con $implement, en worktree/rama de ticket cuya base sea la integración actual confirmada. Antes de escribir, anunciar título y registrar las interfaces TDD ya aprobadas. Recorrer persistencia/autorización/operación/UI donde aplique. Añadir pruebas observables de las garantías del ticket. Mantener decisiones cerradas y hacer reparaciones pequeñas necesarias en ese recorrido. Finaliza con comportamiento completo o bloqueo diagnosticado, sin marcar una entrega parcial como hecha.
4. **Verificar.** Ejecutar las pruebas apropiadas del recorrido y sus regresiones, con actores/fechas/fallos reales aislados cuando correspondan. Consultar scripts vigentes del repo para lint/tipos/build según el cambio. Una herramienta ausente o un test no ejecutado se registra como pendiente, no aprobado. Finaliza cuando cada criterio tiene evidencia o estado pendiente/fallido explícito.
5. **Revisar.** Dentro de $implement, guardar commits candidatos locales y ejecutar $code-review contra el SHA fijado, citando el issue como spec. Sus dos revisores evalúan normas y contrato. Corregir errores de seguridad, pérdida, calendario, comportamiento y violaciones documentadas; valorar observaciones heurísticas con justificación. Repetir revisión/pruebas afectadas solo cuando la corrección lo justifique. Finaliza con hallazgos materiales resueltos y resultado asociado al HEAD revisado.
6. **Integrar y publicar código.** Una vez terminado el implementador, el merger integra su entrega y el coordinador valida el resultado. Si la base avanzó, actualizar rama y repetir verificaciones/revisión afectadas; nunca integrar un diff viejo sobre otra base sin comprobarlo. Integrar solo entrega completa, mantener integración verde y hacer push ordinario autorizado a ramas codex. Sin force-push, reset destructivo ni merge/push a main. La primera entrega puede abrir la PR acumulada en borrador; después actualizar su alcance/evidencia. Si se crea una PR, adjuntarla al chat con la herramienta disponible.
7. **Cerrar con evidencia.** Publicar resumen de §5 en el hijo, comprobar que commits/revisión/criterios corresponden al código integrado, luego cerrar como completed. Verificar por lectura el estado remoto y actualizar checkpoint mínimo del run. Si publicar código/comentario/cierre tiene resultado incierto, reconciliar antes de repetir. Finaliza con código disponible y estado del ticket concordante.
8. **Continuar inmediatamente.** Consultar de nuevo la frontera y lanzar el siguiente elegible dentro del mismo Goal. Un comentario final de implement, la finalización de un subagente o el cierre de un issue no son el final del objetivo global. Mantener continuación mientras haya trabajo autorizado alcanzable; no pedir confirmación entre tickets. Si no hay elegibles, aplicar §6 sin inventar completitud.

La continuidad entre turnos la aporta el Goal activo; no una automatización por horario ni una cadena de recordatorios. Usar subagente nuevo para el siguiente ticket permite acotar su contexto. Si hay compaction/interrupción, reconstruir estado desde Git/tracker/checkpoint y continuar el mismo objetivo cuando el sistema permita reanudar; no prometer ejecución fuera de los límites reales del entorno.

## 4. Qué significa elegible

Un ticket es elegible cuando cumple todas estas condiciones:
- Es hijo del alcance autorizado, está abierto, ready-for-agent y sin otro trabajo activo sobre él.
- Todos sus bloqueadores están cerrados **con entrega válida**: evidencia y commits presentes en la integración autorizada o prueba equivalente de un trabajo externo revisado. Un cierre como wontfix/not planned o sin código no satisface automáticamente la arista.
- Requisitos de entorno, configuración o participación humana de sus criterios están disponibles.
- No tiene un bloqueo diagnóstico vigente ni reintentos agotados de esta ejecución; el checkpoint y el estado de triage deben reflejarlo antes de recalcular la frontera.
- El checkout se encuentra en estado conocido y sus cambios no mezclan trabajo ajeno ni otro ticket.

Si aristas nativas y texto Blocked by difieren, comprobar antecedentes y registrar discrepancia; conservar ambos como bloqueo hasta aclarar, sin borrar la arista para habilitar trabajo. Si una entrega previa presenta una regresión real, registrar evidencia y reparación dentro del contrato; no usar un issue cerrado como garantía ciega.

Consultar cada vez antes de tomar trabajo. El número de issue resuelve empates entre elegibles; las tareas independientes pueden avanzar aunque otra esté esperando configuración/personas.

## 5. Evidencia y condición de cierre

En cada ticket, dejar:
- SHA base y SHA integrado, rama/PR, contratos/P/E y criterios cubiertos.
- Prueba o recorrido reproducible, fixture/actores/entorno, reloj/zona si corresponde, resultado y referencia de artefacto sin secretos.
- Resultado de revisión de normas y spec sobre el HEAD final.
- Criterios automáticos verificados, manuales verificados, fallidos y pendientes, distinguidos.
- Riesgos/limitaciones reales y siguientes bloqueos.

Cerrar exige que **todos los criterios obligatorios estén verificados**; “implementado”, “compila”, “hay un mock”, “manifest agregado” y “no pude probar” no equivalen a cierre. Un CI verde anterior al último cambio tampoco prueba el HEAD nuevo. Los checks de código no reemplazan Auth/Storage/Realtime, dispositivo real, piloto o restore cuando el ticket los exige.

Las entregas de operación se verifican por su recorrido de operador; no añadir UI de métricas por cumplir literalmente “todas las capas”. Las pruebas históricas de la app anónima no acreditan el modelo privado nuevo. La aceptación final usa la matriz de trazabilidad, no solo el número de issues cerrados.

## 6. Bloqueos, fallos y límites de autonomía

| Situación | Acción del loop |
| --- | --- |
| Falta configuración o evidencia humana | Guardar estado, mantener issue abierto y ready-for-human con un pedido concreto. Seguir con otros elegibles. |
| Falta una decisión de producto/contradicción vigente | Issue abierto needs-info, citar escenario y acuerdos en conflicto; proponer respuesta sin decidirla en nombre del usuario. |
| Fallo de implementación diagnosticable | Reparar dentro del ticket y reejecutar la prueba relevante; no borrar test, debilitar permiso ni reducir alcance para pasar. |
| Mismo fallo sin progreso | Máximo tres intentos sustentados en hipótesis/evidencia. Si sigue sin avance verificable, guardar checkpoint y diagnóstico needs-info con evidencia necesaria para destrabar; excluirlo de la frontera hasta que cambie esa condición. El usuario solo recibe un pedido si puede aportar una decisión/dato realmente faltante. Un fallo transitorio se reconcilia antes de reintentar una escritura. |
| Se agota un turno/contexto con trabajo pendiente | Guardar rama/commits WIP y checkpoint, mantener issue abierto y reanudar el mismo ticket en la siguiente continuación/implementador. Un cambio de contexto no requiere «seguí». Solo proponer división si el alcance real excede el contrato acotado, no por llegar al final de una ventana. |
| Problema grande descubierto fuera del ticket | Registrar referencia y efecto en el issue afectado; buscar duplicados. Proponer reparación/subdivisión sin ampliar el plan aprobado por su cuenta. |
| Seguridad/datos reales comprometidos o entorno equivocado | Detener operaciones afectadas inmediatamente, conservar diagnóstico seguro y avisar; no intentar “reparar” producción sin alcance. |
| Push o integración sin confirmar | Mantener trabajo local seguro; consultar refs/resultado antes de repetir. Sin código publicado/reconciliado no cerrar el issue ni habilitar dependientes. |
| No quedan elegibles pero sí abiertos | Agotar primero los caminos independientes autorizados; informar los bloqueadores concretos restantes, no declarar éxito ni inventar evidencia. El ciclo puede quedar bloqueado de verdad y retomarse cuando cambie el estado. Aplicar el contrato real de la herramienta de Goal para sus estados, no forzar continuaciones vacías. |
| Usuario pausa o cancela | Dejar checkpoint seguro, informar estado y detener; conservar trabajo. |

La orquestación usa los subagentes de implement-spec en secuencia (implementador y luego merger) y los dos revisores de code-review. Máximo un implementador por vez, todos con la selección GPT Luna Max. Delegación adicional no necesaria para este plan queda fuera del arranque base. El límite de intentos es una política del run, no una autorización para cambiar estados de un goal de la aplicación fuera de sus propias reglas.

Las etiquetas se actualizan según el tracker: mantener solo el estado de triage pertinente y preservar categorías ajenas. Un bloqueo humano resuelto se revalida antes de volver a ready-for-agent. No reclamar requisitos resueltos como nuevas preguntas solo por leer notas históricas de pendiente.

## 7. Comunicación, recuperación del contexto y final del objetivo

Registro técnico por ticket, resumen al usuario cada cinco entregas y al terminar, y aviso inmediato si hace falta una decisión humana o aparece un riesgo confirmado. Evitar repetir el mismo bloqueo sin cambio. Durante una sesión interactiva, mantener actualizaciones breves de progreso conforme las instrucciones del entorno. Los comentarios técnicos del tracker son registro autorizado del propio proyecto al arrancar; estas reglas no autorizan mensajes a terceros por correo/chat.

Checkpoint por iteración: run/issue, estado, base/HEAD, ramas/PR, entorno identificado sin credenciales, evidencia/revisión, cambios locales WIP y siguiente acción. Guardarlo junto al estado de ejecución versionado de la rama; no crear otro documento de requisitos ni copiar todos los51 cuerpos en cada sesión. Tras interrupción, leer Git+tracker+checkpoint y reconciliar efectos antes de retomar. La asignación al mismo usuario no prueba que sea la misma ejecución.

Al completar trabajo automatizable, reportar por separado:
1. Entregas implementadas y verificadas en integración.
2. Pendientes de personas/dispositivos/configuración o aprobación de corte.
3. Estado real de main/producción.

El objetivo incluye todos los tickets hasta #53 y todas las P/E. No marcar el Goal global completo solo por terminar #52 si el objetivo aún incluye el corte: #53 sigue abierto/bloqueado hasta autorización específica y requisitos reales. No cerrar el padre#2 ni anunciar producción lista al terminar un hijo o al quedarse sin frontera. La implementación completa en integración, el cierre total de spec y el despliegue son hitos distintos; reportarlos por separado. La PR acumulada queda en borrador hasta cumplir criterios de revisión acordados y sin auto-merge.

## 8. Arranque y controles del Goal

Comando preparado y contexto de uso: [iniciar el Goal de implementación](./start-implementation-goal.md). Ejecutarlo en el chat de este checkout, tras seleccionar GPT Luna y Max. Esa acción futura inicia la ejecución; esta edición no la inició.

Según [OpenAI Docs: Goals](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex), /goal mantiene un objetivo entre turnos y continúa mientras esté activo y dentro de sus límites. Permite inspeccionar con /goal, pausar con /goal pause y reanudar una pausa con /goal resume. Un bloqueo real, pausa/interrupción o límite puede detener el avance; no prometer “sin parar” contra esos estados. La guía de [comandos de Codex](https://developers.openai.com/blog/mastering-codex-remote-for-engineering) documenta /goal y aclara que disponibilidad depende del entorno.

Guardar checkpoint al topar un límite y explicar el mecanismo de reanudación que exponga la app. No indicar /goal resume para cualquier estado por suposición: está documentado para pausados; revisar el estado de presupuesto/bloqueo antes de elegir cómo seguir. Nunca marcar complete por agotarse el presupuesto ni asignar un token_budget si el usuario no lo pidió.
