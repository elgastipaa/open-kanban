# Plane frente a OpenKanban: evaluación de base y dirección de producto

Fecha: 24 de octubre de 2026. Investigación y propuesta de decisión; no sustituye acuerdos de la spec ni autoriza implementación.

## Recomendación

**Conservar OpenKanban como producto propio, aprovechar Plane como referencia y evitar por ahora un fork profundo o un frontend propio sobre su backend.** Plane gana en capacidades colaborativas ya construidas. OpenKanban ofrece una base más pequeña y adaptable para la experiencia personal que queremos. Esa adaptabilidad todavía hay que convertirla en un producto seguro y completo: nuestra spec no es funcionalidad implementada.

Si la prioridad cambia a disponer cuanto antes de una herramienta general de gestión de proyectos, aceptando sus reglas, instalar Plane casi sin modificar puede ser mejor que construir. Adoptar su producto y transformar su código en nuestro producto son decisiones diferentes. La segunda pierde parte del ahorro inicial cuando exige cambiar entidades, autorización, recurrencias y experiencia móvil.

Esta recomendación es una inferencia de arquitectura y ajuste funcional, no una comparación de usabilidad medida. No se ejecutaron las aplicaciones ni pruebas de rendimiento, accesibilidad o seguridad durante esta investigación.

## Alcance y evidencia

- Plane clonado con historial limitado en `C:\Users\gasto\Documents\GitHub\plane`. Rama predeterminada `preview`, commit `d9726d5c9615756135f3d6cd512ece8e2dd42902`, fechado el 23 de octubre de 2026. El checkout quedó sin modificaciones.
- También se descargó el tag `v1.4.2`, commit `5f7d92784c403f76284f0f16718f320221dc7fec`, que GitHub presenta como [última release estable](https://github.com/makeplane/plane/releases/tag/v1.4.2). Se contrastaron allí frontend, relación entre estado/completado y función de restauración. No se equipara toda la rama preview con la release desplegable.
- OpenKanban: checkout Windows proporcionado en este chat, HEAD `46c94139bac67aaca1d491b29afc3bc999fc288f`, más documentos locales no versionados. El checkpoint histórico menciona otra ubicación WSL; esta investigación corresponde a esta copia Windows. No se presupone sincronización entre ambas.
- Spec leída por acuerdos C-01–98, MVP, glosario, permisos, pantallas y estados/errores. Acuerdos posteriores prevalecen sobre párrafos históricos que aún dicen «pendiente».
- Se revisaron modelos, autorización, mutación/borrado de tareas, configuración de identidad, componentes, dependencias, despliegue y presencia de pruebas de Plane; tipos, RPC, sincronización, móvil e importación de OpenKanban.
- Se consultaron fuentes oficiales actuales para ediciones, móvil, recurrencias, instalación, respaldo y licencia. La documentación general de Plane mezcla capacidades de diferentes ediciones; no se atribuyeron todas a Community.
- No se leyeron secretos, no se conectó a bases remotas y no se instalaron dependencias ni desplegó. Se preservaron cambios existentes. Este documento es el único archivo añadido a OpenKanban por esta investigación.

## Qué tenemos realmente

OpenKanban implementa tablero, columnas, tareas, prioridades, descripción, reordenamiento, sincronización, presencia y JSON v1. El modelo actual no contiene propietarios, membresías, responsables, fecha límite ni completado. La migración 012 mantiene RPC accesibles al rol anónimo y los canales se construyen por slug. Esto coincide con el modelo público documentado, pero no satisface la app privada objetivo.

Hay una base móvil específica: una columna activa, navegación entre columnas y acciones para mover tarjetas. Es una inversión aprovechable, aunque no demuestra todavía buena usabilidad con todas las nuevas funciones. La importación actual elimina columnas y reconstruye mediante varias solicitudes; tampoco cumple aún el reemplazo protegido acordado.

Evidencia local: [tipos](C:/Users/gasto/Documents/GitHub/open-kanban/src/lib/types.ts), [móvil](C:/Users/gasto/Documents/GitHub/open-kanban/src/components/board/mobile-board.tsx), [realtime](C:/Users/gasto/Documents/GitHub/open-kanban/src/hooks/use-realtime.ts), [RPC](C:/Users/gasto/Documents/GitHub/open-kanban/supabase/migrations/012_harden_rpc_access.sql), [importación](C:/Users/gasto/Documents/GitHub/open-kanban/src/lib/import.ts).

Plane sí tiene una estructura extensa de identidades, espacios, proyectos, miembros, tareas, comentarios, notificaciones, archivos, filtros y trabajo personal. Hay pruebas de contratos de autorización y aislamiento de objetos, además de pruebas unitarias. Es evidencia de inversión en ingeniería; no certifica ausencia de vulnerabilidades ni cobertura total. Su código puede enseñarnos especialmente cómo probar límites entre usuarios y proyectos.

Evidencia: [modelos](https://github.com/makeplane/plane/tree/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models), [pruebas de contrato](https://github.com/makeplane/plane/tree/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/tests/contract/app).

## Lo abierto, lo comercial y lo móvil

Community es el código AGPL que clonamos. Commercial tiene otra base, cerrada, y ofrece un nivel gratuito de 12 plazas por espacio junto con niveles pagos. Ese cupo comercial no debe trasladarse automáticamente a Community. Self-hosted describe dónde corre el producto; no garantiza que todas sus funciones sean libres. [Ediciones oficiales](https://developers.plane.so/self-hosting/editions-and-versions).

La app oficial iOS/Android funciona con Cloud y Commercial self-hosted, pero no con Community. Por ello, clonar el repo no nos entrega una app nativa utilizable con nuestra instancia CE. La web sí incluye componentes adaptativos y archivos de manifest/service worker, pero eso por sí solo no verifica instalación PWA, trabajo offline ni una experiencia táctil satisfactoria. [Descargas y restricciones](https://plane.so/download), [documentación móvil](https://docs.plane.so/devices/mobile).

Las recurrencias se documentan como Business. La búsqueda en los modelos y tareas de fondo de Community no encontró el motor equivalente de series personales. La función comercial crea tareas desde una plantilla y conserva instancias ya creadas al editar futuras. No documenta nuestro contrato completo de reemplazar pendientes, anticipación, cumpleaños y exclusiones. No se debe presupuestar ese motor como reutilización disponible. [Recurrencias oficiales](https://docs.plane.so/core-concepts/projects/recurring-work-items).

## Matriz contra la spec vigente

«Parcial» significa que existe una capacidad cercana, pero faltan nuestras reglas. «No encontrada» expresa el alcance de la inspección, no una prueba formal de inexistencia en todo el ecosistema Plane.

| Necesidad de OpenKanban | Plane Community inspeccionado | Ajuste requerido / decisión |
| --- | --- | --- |
| Google + admisión exclusiva del admin (C-01, C-22, C-93) | Google configurable y opción de deshabilitar registro. El adaptador admite excepciones por invitación de workspace. | Parcial: una invitación no debe reemplazar la habilitación global independiente de nuestra spec. |
| Cada amigo crea tableros privados (C-23) | Workspaces y proyectos con membresías; proyectos Secret/Public. | Elegir un mapeo. Un workspace común y proyectos privados se acerca, pero hay que revisar directorios, descubrimiento y altas. Public en el modelo no debe confundirse automáticamente con publicación anónima en Internet. |
| Propietario/colaborador; admin sin lectura automática (C-94) | Roles Admin/Member/Guest a diferentes niveles; autorización por proyecto. | No equivalente a nuestra matriz. Tampoco se afirma que todos los admins de Plane lean todo: debe comprobarse cada alcance. |
| Cero o un responsable (C-06) | Asignación de varios usuarios mediante relación many-to-many. | Restringir en servidor y UI, revisar importadores, edición masiva y API. |
| Columnas libres; completar sin mover (C-10, C-27, C-31) | Estados agrupados en categorías; completado sincronizado con grupo Completed. | Desajuste de dominio importante. Agrupar visualmente por etiqueta no equivale a una columna ordenada independiente del completado. |
| Captura por título, detalle progresivo (C-20, C-87–91) | Quick add y formularios con propiedades. | Buen patrón para estudiar. Conservar captura mínima y ocultar complejidad hasta necesitarla. |
| Mis tareas entre todos los tableros (C-30, C-44) | Trabajo personal/perfil dentro del contexto de workspace. | Cercano con un workspace. Con varios espacios por amigo, no presumir agregación global sin desarrollo. |
| Recurrencia por calendario sin atrasos acumulados (C-11, C-38, C-73) | Motor equivalente no encontrado en CE; recurrencia comercial Business. | Construcción propia en CE o cambio de edición, sin garantía de semántica equivalente. |
| Anticipación, columna de aparición, excepciones (C-43, C-47, C-98) | No se encontró contrato equivalente. | Implementar y probar un dominio temporal propio; editar serie no puede alterar tarjeta actual. |
| Cumpleaños como fecha sin completado (C-75) | No se encontró entidad equivalente. | No representarlo como tarea recurrente completada automáticamente. |
| Checklist plana e independiente (C-54–55) | Listas marcables en editor y jerarquía de sub-work items. | Parcial: no confundir casillas de texto o subtareas completas con nuestros pasos, advertencia al completar y reinicio por ocurrencia. |
| Comentarios y menciones (C-50, C-77, C-81) | Modelos y UI existentes. | Reusar conceptos; revisar moderación, desvinculación histórica y reingreso sin recuperar menciones. |
| Novedades selectivas y caducidad 90 días (C-56, C-83) | Notificaciones y actividad existentes. | Ajustar destinatarios, deduplicación, retención y ocultación tras revocación. |
| Búsqueda/filtros respetan acceso vigente (C-57, C-78) | Búsqueda, filtros y pruebas de alcance. | Gran referencia técnica. Hay que validar título/descripción, próximos 7 días y cachés bajo nuestra política. |
| Invitación directa y genérica, 72 h, un uso, sin correo automático (C-71, C-97–98) | Invitaciones de workspace/proyecto y envío de correo en flujo revisado. | Adaptación importante: destinatario opcional, admisión separada, consumición única, preview y renovación. |
| Recuperar contenido 7 días según autor y motivo (C-58, C-94, C-98) | Soft delete y purga; función general de restauración encontrada vacía. | No disponible como garantía lista. Cambiar plazo de purga no implementa restauración, permisos ni dependencias. |
| Adjuntos txt/md 24 KB, 20/tarea, 200 MB globales (C-61, C-64, C-82) | Almacenamiento y adjuntos más generales. | Implementar límites y contabilidad de activos, retenidos y reservas. Alojamiento propio no exige estos límites exactos; son decisiones nuestras. |
| Conflicto conserva borrador y pide revisión (C-68, C-95) | Edición colaborativa de texto con Yjs y actualizaciones ordinarias de campos. | No equiparar colaboración de texto con control de versiones de toda la tarea. En el PATCH revisado no hay precondición explícita de versión del cliente. |
| Respaldo por tablero con reemplazo protegido (C-92) | Exportación y respaldo de infraestructura disponibles. | Backup de instancia no equivale a importación transaccional del tablero ni a conservar el previo 7 días. |
| Uso cotidiano móvil y escritorio (C-91) | Web adaptable; cliente móvil oficial fuera de CE. | Prueba táctil real indispensable; ni Plane ni nuestro código fueron validados aquí en dispositivos. |

## Tres desajustes que no se arreglan cambiando colores

**1. Completar y organizar son dimensiones distintas para nosotros.** En OpenKanban una tarea puede seguir en «Casa» y estar hecha. En Plane, `Issue._sync_completed_at` deriva el completado del grupo de estado. Crear estados «Casa pendiente» y «Casa hecha» sería una adaptación del usuario al modelo, con más opciones y reglas. Introducir una dimensión nueva de columna afecta consultas, drag-and-drop, filtros, importación y API. El comportamiento se verificó también en v1.4.2. [Modelo Issue](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/issue.py#L240), [estados](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/db/models/state.py).

**2. Nuestra programación busca que una rutina no se convierta en una deuda infinita.** «Regar las plantas» no debería generar veinte pendientes tras una ausencia. Conservar la historia sin marcarla falsamente completada, respetar el calendario y permitir anticipación es una parte distintiva del producto. Habría que construirla también sobre Plane CE. Esto reduce mucho el ahorro de adoptarlo para nuestra spec.

**3. Hay que diseñar recuperación y confianza, aunque la base sea madura.** Plane tiene borrado lógico, pero `restore_related_objects` es un `pass`; la configuración general de purga observada usa 60 días por defecto. Eso no demuestra ninguna papelera funcional de siete días. Asimismo, `ChangeTrackerMixin` observa cambios del modelo, pero no representa por sí solo la versión que el usuario vio antes de editar. Son piezas diferentes de nuestros compromisos de recuperación y conflicto. [Borrado/restauración](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/bgtasks/deletion_task.py), [configuración](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/settings/common.py), [PATCH de tarea](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/plane/app/views/issue/base.py#L629).

## Costo de operar y mantener cada camino

| Camino | Ventaja principal | Trabajo/riesgo que asumimos | Recomendación |
| --- | --- | --- | --- |
| Instalar Plane CE con pocos cambios | Colaboración general disponible antes de construirla | Adoptar su modelo, operar el stack y aceptar carencias frente a nuestra spec | Viable si cambia la prioridad hacia usar un gestor existente. |
| Fork de Plane CE para cumplir toda la spec | Muchas piezas generales ya construidas | Cambios de dominio, móvil, permisos y recurrencia; conflictos con futuras actualizaciones | No recomendado como primer movimiento. |
| Frontend OpenKanban + backend Plane | Control visual con backend existente | Mantener dos arquitecturas; API sigue exponiendo el modelo Plane y faltan funciones centrales | No es un atajo probado; descartarlo como opción inicial. |
| Evolucionar OpenKanban | Control del recorrido diario y modelo pequeño | Construir identidad, aislamiento, colaboración y programación correctamente | Preferido para el objetivo expresado. |
| Plane Commercial self-hosted | Producto con capacidades adicionales y cliente móvil oficial | Código cerrado, licencias/planes y dependencia del proveedor | Alternativa para consumir una herramienta; menor ajuste a una base libre propia. |

Plane no se integra en nuestro despliegue actual como un paquete adicional. El checkout usa React Router/Vite, MobX, Django/DRF y Celery, con servicio de colaboración separado. El Compose raíz declara 13 servicios, incluido un migrador de una ejecución: web, admin, space, API, workers, live, PostgreSQL, Valkey, RabbitMQ, almacenamiento compatible S3 y proxy. No son 13 servidores: pueden compartir una máquina, pero sí son componentes que hay que actualizar y respaldar. [Frontend](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/web/package.json), [backend](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/apps/api/pyproject.toml), [Compose](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/docker-compose.yml).

La guía oficial pide 2 núcleos y 4 GB de RAM, recomendando 8 GB para producción. Son requisitos orientativos de instalación, no consumo medido para nuestros amigos. Docker AIO se presenta para evaluación, mientras que producción usa Compose o Kubernetes. [Requisitos y métodos](https://developers.plane.so/self-hosting/methods/overview).

OpenKanban usa Next.js y Supabase/PostgreSQL. Conservando ese despliegue delegamos parte de la operación, aunque seguimos siendo responsables del modelo de acceso, cuotas, recuperación y jobs futuros. Una base bajo tu cuenta de Supabase puede darte control de datos sin operar vos el servidor físico. Si querés independencia completa del proveedor, hay que evaluar autoalojamiento aparte; no está resuelto solo por usar PostgreSQL.

No se asignan costos mensuales ni fechas de entrega sin dimensionar usuarios, adjuntos, tráfico y capacidad operativa. «Gratis para tus amigos» implica que alguien absorbe alojamiento, respaldos y mantenimiento. En ambos caminos hace falta un respaldo externo probado: exportar un tablero no reemplaza recuperar la instancia. Plane documenta respaldos de base y objetos para Community. [Backup y restore](https://developers.plane.so/self-hosting/manage/backup-restore).

Un fork profundo agrega un costo recurrente: adaptar los cambios del proveedor, revisar migraciones y volver a probar nuestras reglas después de cada actualización. Ese costo depende del tamaño de la divergencia, no de la cantidad de estrellas del proyecto. No es necesario abandonar OpenKanban por el trabajo ya invertido ni conservarlo por apego; debe ganar el camino que reduzca el trabajo total para el producto elegido.

## Qué significa «libre» para esta decisión

Hay tres compromisos distintos: código reutilizable, servicio gratuito para usuarios y datos exportables/controlados. Conviene formular los tres. Un servicio puede ser gratuito y cerrado; un código libre puede tener costos de alojamiento.

OpenKanban lleva licencia MIT. Plane lleva AGPL-3.0-only en sus avisos de copyright. Podemos alojar y modificar Community cumpliendo esa licencia. Si ofrecemos una versión modificada por red, la sección 13 exige ofrecer su código fuente correspondiente a los usuarios remotos. Copiar código de Plane a OpenKanban no permite presentarlo simplemente como MIT: hay que respetar los términos aplicables al trabajo derivado. La AGPL puede encajar bien con una comunidad que quiera compartir mejoras. No obliga a publicar las tareas privadas de los usuarios. Referencia normativa: [licencia del commit inspeccionado](https://github.com/makeplane/plane/blob/d9726d5c9615756135f3d6cd512ece8e2dd42902/LICENSE.txt), especialmente secciones 5 y 13.

Para aprender de Plane sin incorporar su código, podemos estudiar estructuras, recorridos y categorías de pruebas y desarrollar nuestra implementación. Cualquier reutilización literal debe registrar origen y licencia. No se cambió la licencia de OpenKanban.

## Qué tomar de Plane

1. **Una misma tarea, varias vistas.** Tablero y Mis tareas deben consultar la misma entidad, preservando identidad, permisos y acciones. En nuestra spec ya está acordado; Plane es referencia para su organización técnica.
2. **Captura rápida y detalle progresivo.** Primero título; propiedades, conversación y archivos al abrir. Mostrar todo desde el alta aumentaría fricción sin mejorar la captura.
3. **Aislamiento comprobable.** Tomar como guía escenarios de pruebas entre proyectos, miembros inactivos, adjuntos, búsquedas y exportaciones. Adaptarlos a nuestra matriz, sin copiar tests como sustituto del diseño.
4. **Trabajo de fondo separado.** Distinguir confirmar una acción de procesar avisos, purgas y ocurrencias. En nuestro stack elegir la solución mínima suficiente, sin adoptar todas las colas de Plane por imitación.
5. **Preferencias personales y filtros explícitos.** Ocultar completadas u ordenar una vista no debe modificar la experiencia de otro miembro.
6. **Disciplina de operación.** Versiones fijadas, migraciones verificadas, respaldo y restauración ensayada, y revisión de dependencias antes de cada despliegue.

Cycles, modules, estimaciones, wikis, dashboards avanzados y automatizaciones empresariales son capacidades de referencia. No se incorporan a nuestro alcance por existir en Plane. Una herramienta de organización personal puede perder utilidad si obliga a entender conceptos de gestión de proyectos antes de anotar un pendiente.

## Qué conviene reforzar en nuestra spec

Estas son propuestas para la siguiente revisión; ninguna cambia acuerdos vigentes.

- **Reformular «todas las funcionalidades de Asana/Trello» como recorridos verificables.** La spec vigente ya aclara que no promete paridad. Mantener como visión una herramienta completa, y definir «completa para vivir el día a día»: capturar, encontrar, decidir, hacer, repetir y coordinar con otra persona. Una lista ilimitada de features no ofrece un criterio de lanzamiento.
- **Mantener separados comunidad y registro público.** Interpretar inicialmente comunidad como personas habilitadas que colaboran. Una apertura pública futura requeriría decisiones adicionales sobre admisión, abuso, cuotas y administración. No convertir la aspiración de comunidad en autoalta pública silenciosa.
- **Medir uso móvil, no solo tamaño de pantalla.** Comprobar teclado virtual, botón de guardar, volver a la columna, acceso a Mis tareas, acciones sin arrastrar, errores de red y recuperación del texto durante la sesión. La instalación PWA y el envío offline quedarían como decisiones adicionales; la spec actual no promete offline completo.
- **Validar la metodología con usos pequeños.** Probar «anoto lo que no quiero olvidar», «veo lo vencido y lo próximo», «elijo una próxima acción» y «retomo una rutina después de varios días». Respetar que los usuarios eligen columnas y que no hay tutorial obligatorio ni ejemplos insertados automáticamente. Ayudas o plantillas opcionales pueden evaluarse después del uso real.
- **Priorizar confianza en cada entrega.** Login sin control efectivo de API, tablero compartido sin revocación, o importación sin recuperación no son entregas completas. No posponer privacidad y consistencia como un pulido final.
- **Revisar proporcionalidad de límites antes de comunidad abierta.** Los 24 KB y 200 MB acordados son austeros y válidos para el piloto. No afirmar que equivalen al manejo de adjuntos de una suite general. Mantenerlos hasta que se decida explícitamente cambiarlos.

## Secuencia propuesta para avanzar sin perder el objetivo

La spec vigente sigue siendo el contrato. Esta secuencia organiza trabajo y validación; no recorta funciones aceptadas ni autoriza implementarlas.

1. **Diseño técnico de acceso y transición.** Propiedad explícita de tableros existentes, Google, habilitación, membresía, invitaciones y revocación coherente en API, realtime, archivos y vistas.
2. **Primer recorrido privado completo.** Crear tablero/columna/tarea, completar sin mover, asignar, ver Mis tareas y colaborar desde móvil y escritorio, con persistencia y errores verificables.
3. **Colaboración y recuperación.** Checklist, conversación, menciones, novedades, búsqueda, adjuntos permitidos, retirada de miembros y recuperación. Incluir exportación/importación protegida en el corte que vaya a usarse con datos reales.
4. **Programación personal.** Series, anticipación, cumpleaños, exclusiones, zona horaria y no acumulación. El motor debe probarse con calendario simulado, reintentos y períodos sin ejecución.
5. **Piloto con un grupo pequeño.** Medir si realmente reduce esfuerzo cotidiano y ajustar navegación sin añadir pantallas por inercia. La apertura de la comunidad se decide con evidencia de uso y capacidad de mantenimiento.

Las primeras entregas pueden servir a pruebas controladas. No se presenta una entrega intermedia como cumplimiento de todo el MVP acordado.

## Cuándo cambiaría la recomendación a favor de Plane

La cambiaría si aceptamos explícitamente su modelo de proyectos/estados, priorizamos funciones generales de equipo, podemos operar su infraestructura y una prueba de Community en navegador móvil resulta satisfactoria. Para una versión libre propia, la alternativa móvil comercial no resuelve por sí sola ese requisito. Si las recurrencias personales y cumpleaños dejan de ser centrales, la reutilización gana más peso.

Antes de un pivot, propondría un ensayo acotado de CE estable con datos ficticios y estos recorridos. No fue ejecutado en esta investigación:

| Recorrido | Evidencia para decidir |
| --- | --- |
| Entrar desde celular y crear primera tarea | Pasos necesarios, conceptos obligatorios y facilidad con teclado abierto. |
| Crear «Casa», completar sin perder ubicación | Si se logra con configuración simple o exige cambiar el dominio. |
| Compartir un tablero y mantener otro privado | Dos identidades, búsquedas/archivos y revocación comprobadas. |
| Ver asignadas de varios tableros | Alcance real de Mis tareas con el mapeo de workspaces elegido. |
| Volver tras una semana sin usar una rutina | Pendiente vigente e historia sin atrasos acumulados ni completados falsos. |
| Borrar y recuperar / perder conexión durante guardado | Qué garantías vienen dadas y cuáles habría que construir. |

Si exige parches profundos para los recorridos centrales, detener el experimento. Si se resuelve casi todo con configuración y aceptamos las diferencias restantes, reconsiderar adoptar Plane. La prueba debería usar una release estable revisada y verificar fixes necesarios presentes en preview antes de exponer datos; la existencia de una release no constituye una auditoría de seguridad.

**Decisión propuesta:** mantener la dirección personal y colaborativa de OpenKanban; convertir la ambición en entregas completas y verificables; incorporar aprendizaje de Plane sin heredar ahora todo su producto y su operación.
