# Matriz de trazabilidad y evidencia — OpenKanban 1.0

Fecha: 27/10/2026. Índice de verificación hasta C-112, no especificación paralela. Las reglas y resultados exactos pertenecen a los documentos enlazados. Todos los escenarios de este índice están **especificados, todavía sin evidencia de implementación**. Las comprobaciones históricas de la app anterior no se trasladan al producto nuevo.

## Contratos y fuentes

- [Spec publicada #2](https://github.com/elgastipaa/open-kanban/issues/2) y [copia consolidada](./SPEC-OPENKANBAN-1.0.md): objetivo completo, siete secciones y 116 historias.
- [Acuerdos C-01–112](./0001-auth-collaboration.md): precedencia de decisiones. [MVP](./MVP-1.0.md): comportamiento integral.
- [Cierre funcional](./CIERRE-MVP-1.0.md): contratos CF y escenarios C100–112. [Permisos](./MATRIZ-PERMISOS-MVP-1.0.md), [Pantallas](./PANTALLAS-MVP-1.0.md) y [Estados](./ESTADOS-Y-ERRORES-MVP-1.0.md): facultades, recorridos y fallos.

Un ticket futuro debe identificar acuerdos/ID P/E, escenarios existentes y evidencia que producirá. Los C100–112 complementan las reglas anteriores; probar solo las 33 incorporaciones no acredita identidad, invitaciones, programación, recuperación ni portabilidad completas.

## Tres interfaces de prueba aprobadas

1. Operaciones reales de servidor/base. Reutilizar arnés SQL/RPC adaptando el modelo anónimo histórico al privado. Integración aislada con Auth/Storage/Realtime para garantías que PostgreSQL solo no acredita.
2. Aplicación desde navegador. Acciones del usuario en dos sesiones, móvil/escritorio, conflicto, desconexión, cambio de cuenta y revocación; dispositivos reales para instalación y teclado.
3. Programación con fechas/reloj controlados. Mismo cálculo para preview/validación/ejecución, observado por interfaz pública y contrastado con persistencia; sin esperar días reales ni probar funciones privadas.

No se agregan interfaces de prueba solo para reflejar detalles internos. Estos son planes de verificación, no tests escritos/ejecutados.

## Cobertura de las 33 incorporaciones

| ID | Contrato | Interfaz/evaluación | Evidencia esperada |
| --- | --- | --- | --- |
| P01 | Identidad de tarea | Servidor/base + navegador | Mis tareas y tablero operan sobre el mismo objeto; completar conserva columna/programación. |
| P02 | Captura explícita | Servidor/base + navegador | Enter/botón, texto conservado ante fallo y reconciliación del timeout sin duplicar. |
| P03 | Detalle progresivo | Navegador | Tarea de título solamente y acciones independientes sin abrir programación obligatoriamente. |
| P04 | Tarjetas | Navegador | Información opcional, vencimiento comprensible y cumpleaños sin completado. |
| P05 | Búsqueda y filtros | Servidor/base + navegador | C-107/C-108: tipos/origen/destino, filtros por tipo, deduplicación y revocación. |
| P06 | Preferencias | Servidor/base + navegador | C-104/C-106: contexto independiente, defaults, conflictos y Limpiar/Reiniciar/Restablecer. |
| P07 | Navegación | Navegador | Abrir/volver conserva consulta/posición; historial no repite escrituras. |
| P08 | Accesibilidad | Navegador + evaluación humana | Teclado/foco, zoom, contraste, movimiento reducido y alternativa a arrastrar. |
| P09 | Móvil | Navegador + dispositivo real | 360/390 px, teclado virtual, acciones alcanzables y sin desplazamiento horizontal en detalle. |
| P10 | Estados | Navegador | Carga/error/vacío/sin coincidencias/acceso perdido diferentes, sin ejemplos impuestos. |
| P11 | Enlace privado | Servidor/base + navegador | Identidad estable, permiso actual, histórica concreta y mensaje genérico a ajeno. |
| P12 | Español y fechas | Navegador + programación controlada | Textos accesibles en español y día preservado entre zonas/dispositivos. |
| P13 | Favoritos | Servidor/base + navegador | Solo propios; pérdida de acceso retira nombre y destino. |
| P14 | Atajo de búsqueda | Navegador | Botón y Ctrl/Cmd+K al mismo buscador; no interceptar edición. |
| P15 | Novedades | Servidor/base + navegador | Destinatarios C-112, sin autoavisos/duplicados, mención nueva al editar y caducidad90d. |
| P16 | Autorización | Servidor/base + integración Auth/Storage/Realtime | Actor ajeno/suspendido/retirado y IDs manipulados en todas las consultas y extractos. |
| P17 | Campos y concurrencia | Servidor/base | Campos protegidos rechazados sin parcialidad; consumo invitación y propiedad únicos. |
| P18 | Versiones y reintentos | Servidor/base + navegador | Conflicto conserva borrador, claves/resultados reconciliados y efectos únicos. |
| P19 | Trabajo durable | Servidor/base + programación controlada | Caída/reintento/semana sin entrar: una vigente, exclusiones conservadas y sin completados ficticios. |
| P20 | Realtime privado | Integración Auth/Realtime/Storage + navegador | Revocación/reconexión/cambio de cuenta y respuestas/canales obsoletos sin reexposición. |
| P21 | Recuperación | Servidor/base + programación controlada | C-110: plazo/dependencias/actores y carreras con purga, sin revivir borrado independiente. |
| P22 | Cuotas y archivos | Integración base/Storage | Carrera último cupo, límites exactos, reservas/recuperables, binario renombrado y descarga tras revocación. |
| P23 | Carga y consultas | Servidor/base + navegador | Fixture500 tareas con conversaciones; lectura acotada, páginas estables y export completo. |
| P24 | Respaldo y transición | Integración base/Storage + ensayo operativo | Reemplazo/publicación controlada, previo7d, rollback privado y restauración base+objetos. |
| P25 | Operación | Integración + revisión operativa | Errores diagnosticables sin contenido/tokens y actualización/recuperación ensayada. |
| P26 | Piloto | Evaluación humana | Capturar/encontrar/completar/coordinar/retomar; registrar fricción, sin analítica externa ni puntajes. |
| E01 | Etiquetas | Servidor/base + navegador | C-100–103: facultades/cupos/unicidad/OR, recuperación/copia/herencia/respaldo. |
| E02 | Vistas guardadas | Servidor/base + navegador | C-100–103: consulta actual, variación/actualización, referencias inválidas, recuperación y conflicto. |
| E03 | Tema | Navegador + dispositivo | Sistema inicial/cuenta correcta, modo por dispositivo y editor conservado. |
| E04 | Copia puntual | Servidor/base + navegador | C-104/C-105: fuentes/destino/preview/cancelación, copia de activas y reintento sin duplicar. |
| E05 | Actividad | Servidor/base + navegador | C-105: categorías, atribución, 180d sin rejuvenecer, purga dependiente y respaldo. |
| E06 | PWA | Dispositivo real + navegador | C-109: matriz registrada, instalación opcional/manual, login/enlaces/cambio cuenta y actualización con borrador. |
| E07 | Lectura por lote | Servidor/base + navegador | C-109: IDs fijados, parciales/caducidad/reintento original y nada de páginas/avisos nuevos. |

Estado de todas las filas: **especificado; pendiente implementación y evidencia**. Los criterios exactos por ID están en MVP§16 y la spec consolidada. Los anchos360/390 y500 tareas son fixtures, no capacidad certificada ni límites comerciales.

## Índice de las 61 precisiones de aceptación

Fuente única del resultado esperado: **Cierre funcional**, buscando el ID de esta tabla. C103-AC18b aparece en prosa; los otros 60 están en tablas. No copiar aquí el resultado para evitar reglas divergentes.

| Escenario | Dominio | Interfaz prevista | Estado |
| --- | --- | --- | --- |
| C100-AC01 | Etiquetas/vistas | Servidor/base + navegador | Sin ejecutar |
| C100-AC02 | Etiquetas/vistas | Servidor/base + navegador | Sin ejecutar |
| C100-AC03 | Etiquetas/vistas | Servidor/base + navegador | Sin ejecutar |
| C100-AC04 | Etiquetas/vistas | Servidor/base + navegador | Sin ejecutar |
| C100-AC05 | Vistas/preferencias | Servidor/base + navegador | Sin ejecutar |
| C100-AC06 | Vistas/preferencias | Servidor/base + navegador | Sin ejecutar |
| C100-AC07 | Vistas/preferencias | Servidor/base + navegador | Sin ejecutar |
| C101-AC08 | Recuperación de etiquetas | Servidor/base + navegador | Sin ejecutar |
| C101-AC09 | Herencia de serie | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C101-AC10 | Copia puntual | Servidor/base + navegador | Sin ejecutar |
| C101-AC11 | Respaldo de etiquetas | Servidor/base + navegador | Sin ejecutar |
| C101-AC12 | Vistas/recuperación/concurrencia | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C101-AC13 | Vistas/recuperación/concurrencia | Servidor/base + navegador | Sin ejecutar |
| C101-AC14 | Vistas/recuperación/concurrencia | Servidor/base + navegador | Sin ejecutar |
| C102-AC15 | Cupos/nombres/reparación | Servidor/base + navegador | Sin ejecutar |
| C102-AC16 | Cupos/nombres/reparación | Servidor/base + navegador | Sin ejecutar |
| C102-AC17 | Cupos/nombres/reparación | Servidor/base + navegador | Sin ejecutar |
| C102-AC18 | Cupos/nombres/reparación | Servidor/base + navegador | Sin ejecutar |
| C102-AC19 | Cupos/nombres/reparación | Servidor/base + navegador | Sin ejecutar |
| C102-AC20 | Cupos/nombres/reparación | Servidor/base + navegador | Sin ejecutar |
| C103-AC18b | Cupos/nombres/reparación | Servidor/base + navegador | Sin ejecutar |
| C104-AC21 | Copia puntual | Servidor/base + navegador | Sin ejecutar |
| C104-AC22 | Copia puntual | Servidor/base + navegador | Sin ejecutar |
| C104-AC23 | Copia puntual | Servidor/base + navegador | Sin ejecutar |
| C104-AC24 | Preferencias/tema/orden | Servidor/base + navegador | Sin ejecutar |
| C104-AC25 | Preferencias/tema/orden | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C104-AC26 | Preferencias/tema/orden | Servidor/base + navegador | Sin ejecutar |
| C105-AC27 | Confirmación de copia | Servidor/base + navegador | Sin ejecutar |
| C105-AC28 | Confirmación de copia | Servidor/base + navegador | Sin ejecutar |
| C105-AC29 | Actividad | Servidor/base + navegador | Sin ejecutar |
| C105-AC30 | Actividad | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C105-AC31 | Actividad | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C105-AC32 | Actividad | Servidor/base + navegador | Sin ejecutar |
| C105-AC33 | Actividad | Servidor/base + navegador | Sin ejecutar |
| C106-AC34 | Defaults/contextos/consulta | Servidor/base + navegador | Sin ejecutar |
| C106-AC35 | Defaults/contextos/consulta | Servidor/base + navegador | Sin ejecutar |
| C106-AC36 | Defaults/contextos/consulta | Servidor/base + navegador | Sin ejecutar |
| C106-AC37 | Defaults/contextos/consulta | Servidor/base + navegador | Sin ejecutar |
| C106-AC38 | Defaults/contextos/consulta | Servidor/base + navegador | Sin ejecutar |
| C106-AC39 | Defaults/contextos/consulta | Servidor/base + navegador | Sin ejecutar |
| C108-AC40 | Búsqueda unificada | Servidor/base + navegador | Sin ejecutar |
| C108-AC41 | Búsqueda unificada | Servidor/base + navegador | Sin ejecutar |
| C108-AC42 | Búsqueda unificada | Servidor/base + navegador | Sin ejecutar |
| C108-AC43 | Búsqueda unificada | Servidor/base + navegador | Sin ejecutar |
| C109-AC44 | PWA/novedades | Servidor/base + navegador | Sin ejecutar |
| C109-AC45 | PWA/novedades | Servidor/base + navegador | Sin ejecutar |
| C109-AC46 | PWA/novedades | Servidor/base + navegador | Sin ejecutar |
| C109-AC47 | PWA/novedades | Servidor/base + navegador | Sin ejecutar |
| C109-AC48 | PWA/novedades | Servidor/base + navegador | Sin ejecutar |
| C110-AC49 | Calendario/recuperación | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C110-AC50 | Calendario/recuperación | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C110-AC51 | Calendario/recuperación | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C110-AC52 | Calendario/recuperación | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C110-AC53 | Calendario/recuperación | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C110-AC54 | Calendario/recuperación | Servidor/base + navegador | Sin ejecutar |
| C111-AC55 | Conversión/final de serie | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C111-AC56 | Conversión/final de serie | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C111-AC57 | Novedades | Servidor/base + navegador | Sin ejecutar |
| C111-AC58 | Cuotas | Servidor/base + navegador + reloj controlado cuando corresponda | Sin ejecutar |
| C111-AC59 | Autovínculos | Servidor/base + navegador | Sin ejecutar |
| C111-AC60 | Autovínculos | Servidor/base + navegador | Sin ejecutar |

El título del dominio es una ayuda de navegación, no reemplaza el escenario fuente ni obliga a que cada caso tenga las tres clases de prueba. Elegir la interfaz más alta que observe la garantía real.

## Verificación base anterior a las 33 incorporaciones

| Bloque | Fuentes a recorrer | Casos que deben quedar cubiertos |
| --- | --- | --- |
| Identidad/admisión | Acuerdos; matriz G/PERM; entrada UI | Google válido pero no habilitado, suspendido con token viejo, cambio cuenta y único administrador. |
| Tableros/invitaciones/propiedad | Matriz B/G/PERM; contratos INV y CF01–03 | Directa/genérica72h, un uso concurrente, renovación/revocación, transferencia explícita y propietario en papelera. |
| Tarea mínima/edición | MVP/Pantallas/Estados y acuerdos C94–95 | Crear solo título, Guardar explícito, acciones independientes, conservación/reconciliación de borradores autorizados. |
| Calendario/series/cumpleaños | MVP§7–9 y CF04–10 | Zona/anclas/final/exclusiones, una vigente, C110/C111, detenida vs eliminada, fechas especiales, cumpleaños sin completado. |
| Colaboración/novedades | CF03/15/25 y matriz | Autoría/menciones/retirada, destinatarios y fechas de retención, no texto moderado en búsqueda. |
| Archivos/recuperación | CF12/16–17 y matriz R/F | Padres/plazos/cupos, retiro de responsables, purga concurrente y descargas con permisos actuales. |
| Portabilidad/transición | CF19–20/BACKUP y acuerdos | v1, contenido completo, importación con previo7d/cuota, sin permisos/avisos históricos; inventario/dueño y ensayo antes del corte. |

Esto es un índice de familias de escenarios existentes, no un conteo exhaustivo de tests ni una afirmación de cobertura ejecutada.

## Evidencia que debe dejar cada entrega

- Referencia de escenario y versión/commit del código verificado, comando o recorrido reproducible y resultado.
- Entorno aislado, fixture y actores usados; para tiempos, reloj/fecha/zona explícitos.
- Fallos provocados relevantes: timeout tras confirmar, revocación/concurrencia, reinicio y estado persistido/visible esperado. No falsificar un éxito mediante mocks del permiso o guardado real.
- Estado separado: implementado, prueba automática verificada, prueba manual verificada, pendiente o bloqueado por configuración externa. Nunca usar «pasó» para un escenario solo redactado.
- Correcciones no regresan contratos anteriores ni amplían permisos; cambios reales de producto vuelven a su documento dueño.

## Condiciones para entregar el proyecto a un loop

1. Resolver las decisiones humanas que indique la auditoría final; registrar cada acuerdo antes de construir su bloque.
2. Documento técnico con modelo lógico, contratos por operación, estados de error/reintento, mecanismos de calendario/archivo/importación y gates de entorno. Distinguir propuesta de ingeniería de capacidad verificada.
3. Tickets verticales con bloqueadores y criterios concretos, revisados mediante to-tickets. Un loop solo toma trabajo con bloqueadores resueltos; el formato de spec o etiqueta no autoriza despliegue.
4. Autorización explícita de implementación y política de commits/ramas para esa fase; la fase de este documento sigue siendo especificación. Mantener el checkpoint y los datos de acceso fuera del repo.
5. No declarar MVP completo mientras haya bloqueos de privacidad/pérdida/calendario. P26 requiere evaluación con personas y E06 dispositivos reales; un loop automatizado no puede inventar esa evidencia.

No se ejecutan migraciones, pruebas sobre producción, commit/push ni despliegue por crear este índice.

## C-112 — cierre de auditoría, escenarios todavía no ejecutados

| ID | Contrato dueño | Evidencia prevista |
| --- | --- | --- |
| C112-AC61 | Cierre CF-14.3, Q61; búsqueda/vistas/preferencias. | Integración autorizada y navegador: comentario único en reemplazada, filtros independientes, destino preciso, guardar/restablecer opción y revocación. |
| C112-AC62 | Cierre CF-08.1, Q62; programación/historial/recuperación. | Integración/calendario y navegador: detener A, programar B, misma tarjeta, consultar historia, borrar/restaurar A sin afectar B ni generar pasado. |

Las 61 filas/escenarios de rondas anteriores más estos dos suman 63; no representan pruebas ejecutadas ni cobertura total de todos los contratos.

## Diseño técnico recomendado DT-0.1

[Diseño técnico](./DISENO-TECNICO-MVP-1.0.md): módulos e interfaces §§2–5, tiempo/jobs §6, archivos/recuperación §7, consultas/UI §8, sesiones/PWA §9 y portabilidad §10. G01–G08 define evidencia y bloqueos; D0–D8 ordena dependencias para preparar tickets. No son gates ejecutados ni autorización para implementar. Sus decisiones de ingeniería no reemplazan C-01–112.
