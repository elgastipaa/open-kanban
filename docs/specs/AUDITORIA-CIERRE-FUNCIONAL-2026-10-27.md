# Auditoría de cierre funcional — 27/10/2026

Estado: revisión documental independiente, sin cambios a documentos dueños ni implementación. No crea acuerdos. Considera C-01–111: al terminar se verificaron Q55–60/C-111 en spec 0001 y Cierre CF-04.2/15.1/16.1/18.1. Su incorporación documental estuvo en curso durante la revisión; las diferencias transitorias de cabeceras no son hallazgos de producto.

Fuentes: [Continuidad](./CONTINUIDAD-SPEC.md), [spec 0001](./0001-auth-collaboration.md), [MVP](./MVP-1.0.md), [Cierre](./CIERRE-MVP-1.0.md), [Pantallas](./PANTALLAS-MVP-1.0.md), [Permisos](./MATRIZ-PERMISOS-MVP-1.0.md), [Estados y errores](./ESTADOS-Y-ERRORES-MVP-1.0.md), [síntesis del issue #2](./SPEC-OPENKANBAN-1.0.md) y [glosario](../../CONTEXT.md). No se consultó producción ni se verificó nuevamente GitHub. No se ejecutaron pruebas.

## Resolución posterior — C-112

El usuario aprobó Q61–62 el 27/10/2026. H-01 y H-02 quedan resueltas por CF-14.3/CF-08.1 y C112-AC61–62 en Cierre. Las recomendaciones y preguntas que siguen son el diagnóstico histórico previo a esa aceptación, no pendientes vigentes. Quedan consolidación/diseño técnico y preparación de implementación.

## Resultado

El alcance de las 33 P/E y la mayor parte del comportamiento funcional están cerrados. No corresponde volver a entrevistar sobre permisos generales, admisión, plazos, fechas difíciles, límites de adjuntos, formato concreto de respaldo, bibliotecas o infraestructura. Persisten **dos fronteras funcionales acotadas** que pueden producir implementaciones incompatibles si un agente decide por su cuenta: búsqueda de ocurrencias históricas reemplazadas y nueva programación de una tarea que dejó de repetir. Se detallan abajo; no bloquean investigar/diseñar otros módulos, pero impiden declarar que todos los recorridos afectados tienen comportamiento único.

No se identificó una contradicción crítica irresoluble entre las aprobaciones C-110/C-111 y los acuerdos anteriores. Sí hacen falta consolidación documental, diseño técnico y pruebas; el estado actual no habilita un loop de implementación ni un despliegue por sí mismo.

## Decisiones humanas realmente pendientes

### H-01 — Búsqueda de ocurrencias históricas reemplazadas

**Escenario:** la ocurrencia del lunes fue reemplazada, sin completarse, por la del miércoles. Un comentario del lunes contiene la única mención a un documento que se quiere encontrar. Se busca ese texto con el default «pendientes» y luego con «incluir completadas».

**Evidencia:** Cierre CF-06 y MVP §8.1/§9.1 distinguen reemplazada de completada y conservan el contenido en historial. C-106/CF-13.2 define búsqueda por defecto de pendientes. C-108/CF-14.2 dispone que los comentarios heredan los filtros de su tarea, pero solo concreta pendientes/completadas; no ubica reemplazadas históricas en esos controles. Pantallas UI-09/Series ofrece historial, pero no define su inclusión/exclusión en búsqueda unificada. Autorización de lectura no equivale a inclusión en una consulta concreta.

**Qué falta decidir:** si esas ocurrencias y comentarios se encuentran únicamente desde historial o también desde búsqueda unificada, y mediante qué opción explícita. No es ranking ni paginación: cambia qué información puede encontrar la persona.

**Recomendación, todavía no aprobada:** excluir reemplazadas del listado de trabajo pendiente y ofrecer inclusión explícita de historial en búsqueda. Mostrar estado «Reemplazada» y fecha, abrir la ocurrencia precisa y aplicar el mismo alcance a sus comentarios. Nunca tratarla como pendiente por tener completado=false ni marcarla completada para hacerla encajar en el filtro. Si se elige consulta exclusiva desde Series, documentar esa limitación de búsqueda. Incorporar cualquier nuevo control al contrato de vistas/preferencias de forma explícita, sin cambiar definiciones guardadas silenciosamente.

**Prueba que cerraría el caso:** una coincidencia única en el comentario histórico se encuentra por la vía acordada; no aparece como trabajo pendiente ni permite reabrir esa antigua ocurrencia. El control de completadas conserva su significado.

### H-02 — Volver a programar la actual después de «Dejar de repetir»

**Escenario:** serie A con historial. Se detiene; la actual queda como tarea puntual. Más tarde se usa el reloj de esa misma tarea para repetirla semanalmente. Después alguien elimina la antigua serie A.

**Evidencia:** C-35 y Cierre CF-08 conservan actual/historial al detener; la actual pasa a gestionarse como puntual. CF-08 indica usar programación con inicio explícito para volver a programar y dice que la UI debe aclarar si crea una nueva serie. Pantallas UI-09 y MVP §8.5 no habilitan un botón de reanudación sin cerrar su contrato. C-111/Q55 conserva la tarjeta al convertirla y Q56 define el final de próximas, pero no fija el vínculo con una serie detenida anterior ni el alcance de borrarla después.

**Qué falta decidir:** si programar de nuevo crea una nueva serie o continúa la anterior y cómo se conserva la pertenencia histórica de esa tarea. Esto afecta historial, conteos, exclusiones y borrado; no es una elección de clave de base de datos.

**Recomendación, todavía no aprobada:** una nueva programación explícita crea una nueva serie, conservando la tarea actual como primera y la anterior detenida con su historial. No reactivar exclusiones/pasado de la anterior ni resetear sus conteos. La confirmación debe explicar el cambio; también debe fijarse que borrar la serie anterior no arrastre la tarea que ahora pertenece a la nueva. La representación del enlace histórico corresponde luego al diseño técnico.

**Prueba que cerraría el caso:** detener A → programar B desde la actual → consultar ambos historiales → borrar/restaurar A. B sigue su calendario sin duplicar la tarea, sin regenerar pasado y sin perder contenido por una relación histórica accidental.

## Áreas funcionalmente cerradas y qué queda realmente

| Área | Contrato cerrado / precedencia | Trabajo restante, sin nueva entrevista por defecto |
| --- | --- | --- |
| Admisión e identidad | C-22/C-71/C-93: instancia cerrada, administrador habilita correo Google verificado; identidad, admisión y membresía separadas. Primer visitante nunca obtiene administración. C-97/C-98: directa/genérica, destinatarios, aceptación, 72 h/un uso y preview mínimo. | Vincular correo autorizado a identidad estable, callbacks, revocación, concurrencia y estados. El administrador inicial concreto es dato de configuración, no un nuevo modelo de roles. MVP §4.2 aún usa «candidata», pero esa marca no reabre el comportamiento aceptado. |
| Propiedad y suspensión | C-59/C-69/C-80/C-81/C-94/C-98: sucesor explícito, reparación excepcional, protección único admin, desasignación, retirada de menciones y recuperación sin restaurar accesos. | Transacciones, canales y sesiones existentes; inventario de tableros activos/recuperables; desempate estable de reparación. No añadir roles ni lectura global. |
| Importación/exportación | C-92/P24 y CF-19: exportación completa autorizada; importación por dueño, reemplazo previsualizado, v1, miembros/dueño destino intactos, asignaciones compatibles, sin avisos históricos, previo siete días/cuota y rechazo sin publicación parcial. C-101/C-105 incluyen etiquetas/actividad. | Paquete/versión, mapeos seguros, integridad, preparación/publicación, restauración del reemplazo y límites medidos. No pedir elegir ZIP, librería o mecanismo de snapshot. |
| Series: creación, edición y final | C-34/C-47/C-49/C-73/C-98/C-110/C-111: actual/pasado intactos al editar, anclas y excepciones, inicio explícito, conteo inicial y «N próximas» al cambiar final; convertir conserva tarjeta y cuenta primera. | Modelo de regla/versiones, fechas consumidas/excluidas, preview común con ejecución, conflictos y pruebas temporales. H-02 es la excepción funcional localizada; no reabre Q49–56. |
| Recuperación | C-58/C-74/C-76/C-94/C-98/P21/C-101–102/C-110: siete períodos de 24 h, autoridad por causa, padres primero, sin hijos borrados aparte, sin accesos restaurados; serie finita puede materializar máxima última válida, detenida no se activa. | Modelo de causas/dependencias, exclusiones conservadas, purga coordinada, atomicidad y comprobaciones de cuota. No nuevas preferencias de recuperación por persona. |
| Búsqueda y vistas | C-100–108: fuentes, normalización, destinos precisos, filtros heredados por comentarios, sugerencias por relevancia y lista por preferencia, invalidez explícita y conflictos. | Índices, consultas autorizadas, consistencia, calidad y paginación. H-01 es la excepción funcional localizada. Buscar no concede edición histórica ni reabre ocurrencias. |
| Avisos, enlaces y cuota | C-56/P15/C-109/C-111: destinatarios, deduplicación, creador de referencia, lote fijo, resultado/reintento, rearme de cuota y autolinks. | Producción de eventos, reconciliación, sanitización/parser y pruebas. No agregar correo/push, avisos periódicos ni descargas de URLs. |
| PWA, preferencias, copia y actividad | C-100–109 fijan experiencia y límites. C-109 no aprobó por asociación todas las políticas de caché de la nota de investigación. | Mecanismos de almacenamiento/sesión/actualización, seguridad entre cuentas y dispositivos reales. No prometer que manifest equivale a compatibilidad. |

## Casos de precedencia que el diseño debe preservar

Estos puntos son verificaciones de consistencia, no preguntas nuevas:

1. **Conteo inicial frente a edición:** C-111 cuenta la tarjeta convertida como primera al crear; al cambiar explícitamente el final son N próximas, sin actual/pasado. Un cambio de título o columna no reinicia el saldo. El resumen y formato exportado deben conservar la distinción; almacenar solo un N sin su significado no alcanza.
2. **Finita recuperada:** C-110 permite materializar únicamente la última fecha admisible aunque no existiera. No autoriza crear intermedias, extender el final ni destildar una última ya completada. «Vigente» y «pendiente» no son sinónimos: C-74 conserva estados.
3. **Última excluida:** no retroceder a la penúltima buscando una alternativa. Recuperar padre tampoco revive una ocurrencia individual eliminada/purgada. La exclusión necesaria para no regenerarla puede sobrevivir al borrado de su contenido; es metadata de calendario, no permiso para conservar texto purgado.
4. **Exportar sin papelera preserva exclusiones:** CF-19 excluye contenido eliminado y exige conservar/validar calendario y exclusiones. Eso no significa eliminar del respaldo la información mínima de exclusión y regenerar tareas al importar. El formato debe separar ambos conceptos.
5. **Identidades importadas:** atribución histórica no prueba autoría autenticada local ni crea destinatarios. Mapeos solo con identidad validada y permisos actuales; nunca por nombre. No convertir al importador en autor histórico ni asignar al propietario todos los avisos por falta de creador elegible. Resolver el mapeo en el contrato técnico respetando C-111, sin inventar avisos.
6. **Recuperación por causa:** R-01 ya incluye pasos/series/columnas por C-110. Comentario/archivo moderado mantiene su excepción aunque su padre se recupere. Una restauración no reinicia plazos independientes ni deshace traslados de columnas.
7. **Históricas consultables no amplía acciones:** Pantallas UI-05 advierte que la edición histórica de campos no tiene contrato. C-104 permite copiar una histórica sin modificarla; no permite usar esa copia o un resultado de búsqueda como autorización para reabrir/reescribir el origen. No introducir edición histórica nueva durante la implementación por asumir B-05 sin validar estado del objeto. Si se pretende añadirla, requiere una decisión aparte; no es necesaria para implementar consulta/copia aprobadas.

## Limpieza documental, sin reabrir decisiones

Los documentos mezclan acuerdos recientes, propuestas antiguas y notas de investigación. La consolidación debe reemplazar marcadores activos incompatibles, conservando antecedentes identificados como históricos:

- Cierre, resumen inicial: «permisos granulares de restauración» ya resueltos por C-110 para R-01.
- MVP §4.2/§4.3: «admisión candidata»/«mecanismo por especificar» no debe ocultar la admisión cerrada y su flujo aprobado. Separar mecanismo técnico de comportamiento.
- MVP §7/§8 y tabla de acuerdos antiguos: marcar como cerrados anclaje, conteo, límites de excepción y recuperación C-110; no conservar casillas que los vuelvan a presentar como opciones.
- Creador de avisos, rearme, autolinks y conversión/N: C-111 prevalece sobre sus marcas anteriores de pendiente. La incorporación C-111 estaba en curso durante esta revisión; no se considera un incumplimiento transitorio de edición.
- Notas de investigación PWA/búsqueda: sus recomendaciones históricas no amplían acuerdos posteriores. No importar automáticamente sus matrices, cacheado o capacidades extra.

La precedencia resuelve esas marcas; no hace falta pedir al usuario que apruebe de nuevo lo mismo. La síntesis publicada y las fuentes locales deben quedar coherentes antes de entregar tickets al agente de implementación.

## Diseño técnico y pruebas pendientes

No son decisiones de producto mientras cumplan los resultados aprobados: entidades/invariantes, autorización de tablas/RPC/Storage/canales, versiones y claves de operación, procesamiento durable proporcional al stack, reconciliación temporal, borrado por causa y purgas, reservas/cuotas, consulta/paginación/orden, formato portable y respaldo de instancia. Comprobar viabilidad antes de prometer un mecanismo entre servicios.

Las fronteras de prueba ya están aprobadas: servidor/base real aislada, navegador móvil/escritorio y fechas controladas. Hace falta la matriz contrato → escenario → evidencia y ejecutar las pruebas correspondientes al implementar. El arnés previo y los escenarios escritos no acreditan la nueva aplicación. Las 33 P/E permanecen dentro del objetivo, no condicionadas al éxito de un subconjunto inicial.

## Bloqueos de datos y autorización para el corte real

No impiden diseñar ni probar con fixtures, pero sí declarar listo un corte de producción:

- Inventario autorizado del contenido real que debe preservarse y propietario explícito por tablero; C-98 prohíbe asignarlo al primer login. Esta auditoría no accedió a ese contenido.
- Identidad verificada del administrador inicial y configuración efectiva de Auth/orígenes/retornos. No copiar credenciales a documentos.
- Evidencia de resolución de la comprobación histórica de rotación de credenciales que Continuidad mantiene sin verificar. No se afirma aquí que las credenciales actuales estén expuestas ni se inspeccionaron secretos.
- Ensayo de migración/respaldo/restauración, capacidad del entorno y verificación de que rollback no reabre acceso anónimo.
- Autorización explícita vigente para implementación y, separadamente, operaciones remotas/despliegue. El estado actual es especificación; `ready-for-agent`, esta auditoría y un diseño terminado no sustituyen esas autorizaciones. No se solicitaron ni se ejecutaron en esta revisión.

## Criterio de cierre

Cerrar H-01/H-02 o documentar una exclusión funcional explícita compatible con el alcance; verificar C-111 consolidado y limpiar contradicciones activas; producir diseño técnico/trazabilidad. Después presentar la versión concreta y plan de implementación. Inventario/configuración reales se obtienen para el corte autorizado, sin bloquear innecesariamente diseño ni pruebas aisladas.

Esta auditoría no certifica ausencia absoluta de defectos; identifica las fronteras críticas encontradas en los recorridos revisados. No recomienda otra ronda de preferencias menores ni transforma todos los «pendientes» históricos en decisiones nuevas.
