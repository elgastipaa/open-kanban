# Base técnica: identidad, permisos y mutaciones privadas

Fecha de investigación: 27/10/2026. Estado: **propuesta técnica**, no ADR aprobado ni funcionalidad implementada. Investigación estática sobre el checkout de Windows y documentación primaria oficial consultada ese día. No se leyeron secretos, datos remotos ni producción; no se ejecutaron pruebas ni migraciones.

## Resultado

El stack existente puede expresar el modelo privado acordado sin otro proveedor de identidad ni un backend separado: Google mediante Supabase Auth, habilitación persistente propia, membresías actuales, lecturas protegidas con RLS y comandos transaccionales PostgreSQL invocados desde Next.js o el cliente autenticado. La autorización definitiva debe vivir también en la base; proteger solamente páginas o Proxy no alcanza.

Hay dos límites relevantes que condicionan el diseño: **Broadcast/Presence no reevalúa permisos por mensaje** y **una URL firmada de Storage continúa siendo una capacidad hasta su vencimiento**. Por eso no corresponde prometer revocación inmediata mediante esas primitivas por sí solas. Se propone retirar contenido de canales, rotar su época cuando cambia la autorización y descargar archivos mediante petición autenticada con comprobación vigente. El retiro visual de datos ya entregados es una obligación del cliente legítimo; ninguna solución retira capturas o descargas previas.

Esta recomendación conserva C-01–110, P16–P20, C-94–98 y los acuerdos personales de C-100–109. La ronda Q55–60 está aprobada en la conversación y su registro C-111 estaba siendo preparado durante esta investigación: sus reglas de creador de referencia y avisos no se sustituyen por mecanismos técnicos. Se consultaron los documentos dueños, CONTEXT y continuidad, sin modificarlos.

## Evidencia actual del repositorio

| Evidencia local | Implicación |
|---|---|
| `package.json`: Next 16.4.2, React 19.2.9, Supabase JS ^2.98.0 y SSR ^0.8.0. | Ya existe integración del stack propuesto; las versiones efectivas del lockfile y compatibilidad se verificarán al implementar. No se decidió actualizar dependencias. |
| `src/lib/db/tasks.ts`: comandos RPC, identidad de tarea y escritura por slug. | Reutilizar la seam de operaciones, pero reemplazar el slug como supuesto de autoridad por identidad + habilitación + membresía. |
| `supabase/migrations/012_harden_rpc_access.sql`: protege pertenencia de columnas al tablero y conserva explícitamente el producto anónimo por URL. | Es evidencia de aislamiento entre tableros del modelo anterior, no de autenticación privada ya implementada. Revisar todas las firmas antiguas y grants al migrar. |
| La misma migración y `updateTaskPositions` permiten enviar texto/prioridad durante una reordenación; `update_task_p` usa NULL como “sin cambio”. | Separar acciones y campos permitidos; no reenviar un snapshot completo al mover y distinguir ausencia de campo de borrado explícito. |
| `src/hooks/use-realtime.ts`: Broadcast público, eventos sync sin cuerpo y refetch. | Conservar el patrón señal/refetch, cerrar canales públicos y eliminar confianza en publicaciones del navegador. |
| `src/lib/supabase/server.ts`: cliente SSR con cookies. | Reutilizable como adapter; no demuestra verificación de usuario ni habilitación vigente. |
| `tests/db/security.sql`: pruebas con rol anon y RPC reales. | Reutilizar el arnés; sustituir expectativas anónimas por identidades autenticadas y probar revocación, concurrencia y referencias cruzadas. |

## Hechos de las fuentes primarias

1. Google indica que `sub` es el identificador estable y que el correo puede cambiar; documenta `iss`, audiencia y `email_verified`. **No usar correo como identidad permanente.** [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect).
2. Supabase distingue al usuario de sus identidades: `provider_id` identifica la cuenta del proveedor y `user_id` su vínculo con Auth. Un usuario puede tener varias identidades. [Supabase Identities](https://supabase.com/docs/guides/auth/identities). El proveedor Google está soportado sin implementar un validador OAuth propio. [Google en Supabase](https://supabase.com/docs/guides/auth/social-sign-in/auth-google).
3. SSR usa cookies; `getClaims()` verifica el token y `getUser()` obtiene un registro actual de Auth. `getSession()` solo no valida la identidad del objeto guardado. Las respuestas con sesión no deben compartirse mediante CDN/ISR. [Supabase SSR](https://supabase.com/docs/guides/auth/server-side/creating-a-client?framework=nextjs&queryGroups=framework).
4. RLS y grants son controles complementarios. `user_metadata` es modificable por usuarios y no sirve para dar privilegios. [Supabase RLS](https://supabase.com/docs/guides/database/postgres/row-level-security). Propietarios de tablas y roles BYPASSRLS pueden omitir RLS: tampoco se debe presumir que una función privilegiada hereda las restricciones del llamador. [PostgreSQL RLS](https://www.postgresql.org/docs/current/ddl-rowsecurity.html).
5. Supabase recomienda `security invoker` por defecto. Si una función necesita `security definer`, requiere search_path fijo, relaciones calificadas, validación explícita de propiedad/permiso y grants EXECUTE restringidos. [Funciones PostgreSQL en Supabase](https://supabase.com/docs/guides/database/functions).
6. Cada petición PostgREST ocurre dentro de una transacción; varias llamadas HTTP separadas no forman una transacción única. [PostgREST Transactions](https://docs.postgrest.org/en/stable/references/transactions.html). Los locks de fila permiten serializar operaciones concurrentes, con posibilidad de deadlocks si se adquieren en distinto orden. [PostgreSQL Explicit Locking](https://www.postgresql.org/docs/current/explicit-locking.html).
7. Las Server Actions exportadas son invocables por POST y necesitan autenticar y autorizar cada ejecución. Los controles de una página no se propagan a sus acciones. [Next.js Data Security](https://nextjs.org/docs/app/guides/data-security).
8. Realtime autoriza Broadcast/Presence mediante RLS en `realtime.messages`, con canales privados. **Las políticas se cachean durante la conexión** y se renuevan al conectar o enviar nuevo JWT; revocar una fila de membresía no cancela inmediatamente una suscripción ya autorizada. [Realtime Authorization, especialmente Updating RLS policies](https://supabase.com/docs/guides/realtime/authorization).
9. Storage permite políticas en `storage.objects`. Un bucket privado admite descarga autenticada; una URL firmada continúa válida hasta expirar y no queda invalidada por rotar las claves Auth. [Storage Access Control](https://supabase.com/docs/guides/storage/security/access-control), [Serving assets](https://supabase.com/docs/guides/storage/serving/downloads).

Los siguientes apartados son **inferencias y propuestas para OpenKanban**, no garantías de Supabase ni cambios de alcance aprobados automáticamente.

## Módulos profundos e interfaces propuestas

Tres módulos con interfaces acotadas concentran invariantes y dejan adapters pequeños para React/Next/Supabase:

- **Identidad y admisión**: resolver contexto autenticado, vincular primer ingreso elegible, consultar estado propio y ejecutar administración autorizada. Oculta OAuth, claves del proveedor y bootstrap; no devuelve un directorio público.
- **Autorización y comandos**: ejecutar una acción tipada sobre un recurso con precondiciones y clave de operación; consultar su resultado. Oculta locks, versiones, idempotencia, transacciones y eventos. El mismo seam sirve a pruebas y llamadores.
- **Consultas privadas**: leer tablero/detalle, Mis tareas, búsqueda y vistas personales con referencias validadas y paginación. Autoriza antes de devolver resultados, fragmentos, conteos o sugerencias. No necesita una interfaz genérica de SQL ni aceptar nombres de tablas del navegador.

Las acciones administrativas y trabajos de Sistema usan interfaces específicas; no existe un parámetro público `actor`, `is_admin` o `bypass_permissions`. El adapter de servidor para administración de Auth no expone su credencial al cliente. Evitar crear repositorios abstractos sin una variación real que justifique esa seam.

## Identidad, habilitación y esquema lógico

| Registro lógico propuesto | Claves e invariantes |
|---|---|
| Persona de aplicación | ID interno, vínculo único a `auth.users.id`, referencia Google con proveedor/issuer canónico y subject estable, nombre visible. No convertir correo en PK. |
| Autorización global | Correo de admisión pendiente, vínculo opcional a persona/identidad, estado pendiente/activo/suspendido, versión y actor administrativo. Estado durable independiente del JWT. |
| Administración global | Concesión explícita a persona; no implica membresía ni lectura de contenido. La operación que podría quitar al último administrador bloquea el conjunto administrativo durante la comprobación. |
| Tablero | ID, slug estable de navegación, zona, versión de contenido, época de autorización, propietario y estado de recuperación. Slug no es secreto de acceso. |
| Membresía | Tablero/persona, identidad del episodio, fecha de ingreso y retirada. Solo un episodio activo por persona/tablero. El rol propietario se deriva de la referencia única del tablero; restantes miembros son colaboradores. |
| Invitación | ID, token aleatorio guardado como hash si es de enlace, tablero/emisor, destinatario explícito en directa, expiración, revocación/consumo y versión. |
| Contenido dependiente | Identidad propia y `board_id` verificable; FKs compuestas impiden referencias entre tableros. Campos de autoría/creación/borrado resueltos en servidor. |
| Preferencias/vistas | Persona + contexto + clave; versión por preferencia independiente o por definición de vista, no una versión global que haga chocar cambios distintos. |
| Operación y eventos | Recibo de comando separado del evento durable y de actividad/novedad visibles; retenciones distintas. |

La representación física puede usar FK diferible entre propietario y membresía para creación/transferencia atómica. El contrato es que **todo tablero activo tiene exactamente un propietario miembro y habilitado**, nunca dos representaciones divergentes del rol. El tablero recuperable sin miembros es una excepción explícita al estado activo, no una fila que conceda permisos implícitos al administrador.

### Vinculación inicial y suspensión

1. Completar el flujo Google gestionado por Supabase; validar sesión en servidor y obtener la identidad Google desde la representación de Auth mantenida por el proveedor. No aceptar `issuer`, `subject`, correo verificado ni claims privilegiados enviados en JSON por el navegador o en metadata editable.
2. Distinguir **issuer/sub de Google** de **issuer/sub del JWT Supabase**: este último `sub` identifica al usuario Auth, no al subject de Google. El issuer canónico Google se deriva del proveedor/configuración validada; verificar el adapter y los campos efectivos con una cuenta ficticia de prueba. No suponer que `identity_data.iss` siempre existe.
3. En el primer ingreso, transacción bloquea la autorización pendiente, comprueba correo verificado/elegible y la vincula a identidad estable. Mantener unicidad para que no se consuma dos veces. Los ingresos posteriores usan el vínculo estable: un cambio de correo no crea otra persona ni levanta una suspensión.
4. La suspensión conserva el vínculo y estado durable. Cada lectura/comando comprueba habilitación actual; un JWT todavía vigente no vuelve a habilitar. Rehabilitar no reconstruye membresías, asignaciones ni menciones retiradas. No aplicar normalización de búsqueda de acentos/ñ a correos o subjects de identidad; no eliminar puntos ni sufijos `+` por heurística.
5. Bootstrap administrativo mediante identidad previamente elegida y procedimiento explícito, repetible y auditado. Nunca primer login. El mecanismo concreto de provisión se prueba aislado antes del corte; esta investigación no habilita ejecutar SQL remoto.

## Autorización y comandos transaccionales

**Modelo recomendado:** lecturas con JWT del usuario y RLS; mutaciones de producto solo por funciones estrechas con acciones permitidas. Si revocar DML directo exige funciones privilegiadas, `security definer` acotado con dueño de privilegios mínimos y verificación explícita es justificable. No dejar simultáneamente una ruta directa de escritura que omita versiones, eventos o validación de campos. Las funciones invoker siguen siendo preferibles cuando los grants pueden expresar toda la invariancia requerida.

Cada comando resuelve `auth.uid()`, comprueba habilitación vigente y membresía/acción, valida claves permitidas y referencias, revisa versiones, aplica efectos y guarda recibo/evento en **una sola transacción**. Rechaza campos desconocidos/protegidos; ausencia significa no tocar y null explícito significa limpiar solamente si ese campo lo admite. Las respuestas distinguen confirmado, conflicto, inválido, no disponible y error transitorio; no filtran existencia o datos privados a quien perdió acceso.

Para empezar de forma proporcional, serializar comandos estructurales del mismo tablero con lock de su fila; validar otra vez ACL bajo ese lock. La retirada de membresía usa el mismo lock. Una suspensión además bloquea la fila de habilitación, que las mutaciones toman en modo compatible de lectura antes del tablero. Definir orden global para cuentas/tableros afectados y adquirir conjuntos ordenados, evitando ciclos en transferencias y administración de varios tableros. No mantener locks mientras se habla con Google, Storage o Realtime.

Así una mutación autorizada puede completar **antes** de la retirada, o es denegada **después** de ella; no existe un intervalo entre comprobar permiso y escribir sin coordinación. Una lectura ya en vuelo puede haber tomado un snapshot anterior: no prometer retractar bytes entregados. Una petición nueva después de confirmar la retirada debe consultar ACL actual y denegarse. Las transacciones no se mantienen abiertas durante interacción humana.

Invitaciones: consumir bajo lock tras comprobar destinatario/habilitación/emisor actual/tablero/72 h, y crear membresía en la misma transacción. Ineligible o ya miembro no consume. Suspensión, salida y retirada invalidan invitaciones emitidas conforme al contrato. Responsables y menciones usan membresía activa del mismo tablero; una carrera con retirada se resuelve mediante el mismo protocolo. El ID del episodio impide que reingresar relacione automáticamente menciones antiguas.

### Versiones y concurrencia

- PATCH de campos de tarea incluye valores esperados/versiones únicamente de los campos que cambia. Actualizar descripción no debe pisar el responsable o el movimiento de otra persona. Versiones monótonas enteras evitan el problema A→B→A que una comparación de valores no detecta.
- Mover/reordenar usa un comando específico con versión del orden/columnas afectadas; no envía títulos ni descripciones. Los lotes son atómicos dentro de su contrato; validar todos sus elementos antes de modificar.
- Completar expresa `completed=true` o `false`, nunca un toggle ciego. Adjuntos, comentarios y pasos tienen identidad/versiones independientes del editor de campos; completar con checklist incompleta incluye la precondición de revisión correspondiente.
- Series y copias incluyen versiones de la plantilla o del contenido copiable previsualizado. Una copia no necesita quedar en conflicto por un comentario que no forma parte de la copia. Importación usa además una versión de contenido del tablero: detecta cambios desde la previsualización aunque preferencias personales hayan variado aparte.
- Preferencias diferentes se combinan; misma preferencia con versión vencida requiere revisión según C-104. Guardar una vista eliminada no la resucita. Revisión explícita produce nueva intención y nueva clave, conservando el borrador.

## Idempotencia y resultado incierto

No basta bloquear el botón ni pedir que cada consumidor detecte duplicados por texto. Se propone un **recibo durable** con clave aleatoria por intención, identidad autenticada, acción, recurso, versión de formato de comando, hash de carga canónica, resultado mínimo y timestamps. Un índice único `(persona, clave_operación)` evita reutilizar la misma intención para otro tablero/acción; esos datos forman parte del hash.

| Situación | Contrato propuesto |
|---|---|
| Reintento idéntico después de perder respuesta | Reutiliza clave/carga y devuelve el resultado confirmado; ningún segundo comentario, copia, invitación consumida o evento. |
| Misma clave con carga/precondición distinta | Rechazo de reutilización. Revisar y decidir otra edición crea otra clave. |
| Dos peticiones idénticas simultáneas | Una obtiene el recibo; la otra espera/consulta o informa pendiente. Una sola transacción crea el efecto. |
| Fallo de red antes del commit o rollback transitorio | No hay efecto parcial ni recibo confirmado. Reintentar con la misma intención bajo plazo acotado; reconciliar primero cuando se desconoce el resultado. |
| Conflicto o invalidez de dominio | Puede guardarse como resultado estructurado sin producir efectos; repetir devuelve la misma decisión. No lanzar una excepción que deshaga inadvertidamente el recibo si se desea conservar ese resultado. |
| Consulta de resultado tras retirada de acceso | Revalidar habilitación/ACL antes de devolver datos. No devolver un snapshot antiguo para eludir la retirada; responder no disponible sin detalles privados. |

**Retención propuesta, por validar técnicamente:** 7 días para el resultado de reconciliación, configurado con reloj de servidor y limpieza durable. No es una nueva promesa de borrador persistente. Es una opción razonable para el loop de reintentos de una sesión, no una duración elegida por el producto. Una alternativa de 24 h requiere menos espacio pero reduce reconciliación tardía; retención indefinida evita vencimiento a costa de crecimiento y privacidad. Seleccionar 7 días como punto inicial técnico y medir recibos/volumen.

Al vencer un recibo, su ausencia **no demuestra** que el efecto no existió. El cliente no repite automáticamente una intención vencida. Para creaciones importantes, conservar también la clave de origen única con el registro o una marca mínima durante la vida del contenido; un tombstone retenido protege su borrado. Los comandos consultables tienen resultado disponible/pendiente/desconocido-expirado explícito. Este diseño exige definir un horizonte acotado de reintentos; no prometer exactamente una ejecución para siempre con claves purgadas. Las restricciones naturales —una membresía activa, fecha única por serie, evento/destinatario único— complementan el recibo.

### Evento durable, actividad y novedad son registros diferentes

El comando escribe un evento durable/outbox en la misma transacción con ID estable y datos mínimos. La publicación o los jobs pueden reintentarlo; consumidores deduplican por ID. Actividad E05 solo registra categorías aprobadas y retiene 180 días; novedades retienen 90, deduplican por evento/destinatario y excluyen autoavisos. El recibo de comando no se exporta como actividad y su retención no decide la de esos productos. No guardar copias antiguas de textos privados en logs/outbox para imitar un event sourcing no pedido.

Al entregar un aviso diferido, volver a validar acceso actual y actor/destinatarios. Las ocurrencias automáticas preservan creador de referencia conforme Q57/C-111; el job figura como Sistema donde corresponda y no usurpa autoría humana. Importación conserva atribución histórica explícita sin generar eventos nuevos de comentarios anteriores.

## Revocación, Realtime, Storage y búsqueda

### Realtime

Activar canales privados, deshabilitar acceso público y autorizar el join por persona habilitada, membresía y época vigente del tablero. **RLS de canal sola no cumple revocación inmediata** por el caché documentado. No depositar títulos, cuerpos, fragmentos, miembros o eventos sensibles en Broadcast; emitir únicamente una invalidación genérica y volver a leer con ACL actual. Preferir publicación desde el comando confirmado/outbox, no un navegador como autoridad de sync.

Como mecanismo adicional propuesto, incrementar una época del tablero al retirar acceso y enviar las publicaciones futuras únicamente al canal nuevo. El canal anterior queda sin publicaciones oficiales. La época no es una contraseña: la nueva suscripción valida ACL. Coordinar publicación con la época actual, no con una época capturada antes de la retirada. Un outbox atrasado se publica en la época vigente o se descarta si ya no corresponde, sin entregar contenido viejo a un canal abandonado.

El cliente legítimo revalida al recuperar foco/conexión y ante señal de cambio de acceso; cancela peticiones, limpia tablero/detalle/resultados/borradores y abandona canales si perdió permiso. Si se conserva Presence, hay que diseñar y probar su migración de época: no exponer nombres o actividad nueva en el canal viejo; no afirmar que la época expulsa físicamente sockets existentes. La latencia de limpieza visual depende de detección de conectividad; la autorización de nuevas consultas no debe depender de ella. Si no se puede demostrar una presencia privada suficiente, no declarar resuelto P20 por añadir `private:true`.

### Storage

Bucket privado y metadata de adjunto ligada a tablero/tarea/reserva. Políticas de carga/lectura comprueban habilitación y membresía actuales; solo un objeto publicado es descargable normalmente. Nunca conceder acceso solo por prefijo de ruta ni por `owner_id` del archivo: colaboradores autorizados también deben poder descargar y un subidor retirado debe perder acceso.

Preferir descarga autenticada con RLS, mediada por Next si hace falta controlar encabezados: no-store/private, contenido tratado como archivo/texto seguro y sin CDN público. No usar URL firmada como enlace permanente a adjunto; su vencimiento no se acorta al quitar membresía. Las cargas temporales firmadas, si se eligen, requieren reservar, revalidar al publicar y limpiar objetos huérfanos; no conceden lectura de archivos publicados. La coordinación DB/Storage es un protocolo recuperable, no una transacción distribuida supuesta.

### Búsqueda y cachés

Consulta unificada aplica autorización antes de resultados, snippets, ranking y conteos por grupo; comentarios heredan permisos/filtros de su tarea y tableros navegables no heredan filtros inaplicables. No crear índice externo que funcione como otra fuente de permisos. El módulo de consultas puede combinar SQL indexado con FTS/prefijos: la investigación específica de búsqueda decide índices/ranking, mientras este contrato exige ACL actual en todas las ramas.

Las referencias explícitas de filtros/vistas inválidas detienen la consulta; no se eliminan para ampliar resultados. Paginar no congela membresía: cada página revalida. Un cursor solo transporta orden/posición y no concede acceso. Normalización acentos/ñ se aplica a búsqueda y nombres de etiquetas/vistas, **nunca** transforma IDs, permisos ni correos de identidad.

No-cache compartido de contenido privado en Next/CDN/service worker. La clave de caché de memoria incluye persona/contexto y época de acceso; cambiar cuenta o perder acceso limpia también solicitudes en vuelo para que una respuesta antigua no repueble el estado. Metadatos HTML, previews, errores y logs no revelan tableros privados.

## Pruebas necesarias antes de declarar viable la garantía

1. **Identidad real en entorno aislado:** Google ficticio verificado; correo pendiente vinculado una vez; identidad Google y usuario Auth diferenciados; metadata falsificada no habilita; JWT anterior a suspensión no accede; reingreso no revive derechos. No basta simular `auth.uid` para certificar OAuth.
2. **SQL/RPC reales:** dos tableros, dueño/colaborador/admin ajeno/no habilitado/anon; mutaciones por cualquier firma pública; campos protegidos y referencias cruzadas; lectura/exportación/búsqueda/operación contra ACL actual. Invocar con roles reales, no solo postgres.
3. **Carreras en dos conexiones:** retirada frente a guardar/asignar/aceptar invitación; dos dueños saliendo/transferencia; protección del último admin; misma clave idéntica/distinta; movimiento concurrente a editar descripción; conflicto del mismo campo y orden de locks.
4. **Fallo inyectado:** respuesta perdida después del commit, rollback antes de commit, outbox repetido/atrasado, recibo vencido, copia confirmada una vez y evento/novedad únicos. Ningún reintento automático con otra clave ante resultado incierto.
5. **Realtime real:** socket ya conectado que conserva JWT viejo tras retirada/suspensión; no recibe datos/presencia nueva del tablero; antiguo canal queda inerte; nueva época denegada; reconexión y refetch retirados. El arnés SQL no certifica el comportamiento del servidor WebSocket.
6. **Storage real:** descarga nueva tras retirada denegada, publicación de carga pendiente denegada, rutas adivinadas y listados cerrados; comprobar encabezados/cache y que no se emitieron capacidades firmadas duraderas por accidente.
7. **Navegador dos personas/dispositivos:** búsqueda/comentario abierto durante retirada, cambio de cuenta, respuesta vieja en vuelo, pérdida de conexión, detalle con borrador; limpieza de memoria sin promesa de borrar capturas. Preferencias distintas combinadas y misma preferencia conflictiva.

## Límites y decisiones técnicas restantes

- No se verificaron el plan contratado, versiones PostgreSQL/PostgREST efectivas, configuración OAuth, linking de identidades ni disponibilidad de mecanismos operativos; no se infieren de documentación “current”. Probar contra las versiones de un entorno aislado antes de congelar migraciones.
- La documentación oficial consultada respalda las primitivas, pero el protocolo de locks, recibos y épocas es diseño propuesto propio y necesita las pruebas anteriores. No afirma rendimiento certificado ni expulsión instantánea de sockets.
- El formato físico de versiones, recibos y errores debe quedar en el diseño de implementación con ejemplos de petición/respuesta. La elección técnica de 7 días de recibos debe registrarse como tal, sin confundirse con los siete días de recuperación de producto.
- Quedan coordinación con jobs, cuota/reservas, purga, respaldo y transición: otros informes deben utilizar esta misma identidad/ACL y no ofrecer una segunda ruta privilegiada de escritura. Todo corte a privado requiere inventario/propietarios explícitos y autorización separada.
- No se implementó código ni se ejecutó una prueba en esta investigación. Los archivos de especificación y el issue mantienen la autoridad sobre producto; convertir este informe en ADR o ticket exige síntesis explícita, no aprobación por asociación.
