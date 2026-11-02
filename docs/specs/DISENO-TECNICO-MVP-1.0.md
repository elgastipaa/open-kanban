# Diseño técnico — OpenKanban 1.0

Fecha: 27/10/2026. Revisión DT-0.1. **Diseño recomendado para preparar tickets**, basado en C-01–112 y todas P01–P26/E01–E07. No es implementación, aprobación de infraestructura ni evidencia de pruebas ejecutadas. Las decisiones de ingeniería aquí propuestas no se convierten en nuevos acuerdos C. Los contratos de producto de [Cierre](./CIERRE-MVP-1.0.md), [Permisos](./MATRIZ-PERMISOS-MVP-1.0.md), [Pantallas](./PANTALLAS-MVP-1.0.md) y [Estados](./ESTADOS-Y-ERRORES-MVP-1.0.md) prevalecen.

El diseño fija una solución base y pruebas para comprobarla. Las verificaciones G01–G08 son condiciones concretas de entrega; si fallan, registrar el cambio técnico necesario antes de continuar con las partes dependientes. No rebajar funciones aprobadas ni declarar listo el objetivo por terminar solo sus fundamentos.

## 1. Base y decisiones de arquitectura

Se conserva Next.js/React/TypeScript y Supabase (Auth, PostgreSQL, Storage, Realtime). No fork de Plane, backend separado, motor externo de búsqueda ni broker adicional. La interfaz visual reutiliza los controles accesibles y la navegación móvil existente donde cumplan Pantallas. Los adapters existentes de RPC y SSR son puntos de partida; el modelo anónimo por slug y sus grants no son reutilizables como autorización.

Evidencia local: package.json declara Next16.4.2/React19.2.9/SupabaseJS2.98/SSR0.8, Node24/pnpm11.3. src/lib/db/tasks.ts mezcla movimientos con campos y usa null como ausencia; se separan esas intenciones. src/hooks/use-realtime.ts usa Broadcast público; se reemplaza. vercel.json habilita despliegues Git en main, sin cron declarado: no demuestra plan ni scheduler configurado. Las migraciones 001–012 y el arnés SQL son legado que debe conservarse como antecedente verificable, sin reescribir migraciones aplicadas.

| ID técnico | Elección recomendada | Alternativa considerada y razón |
| --- | --- | --- |
| DT01 | Lecturas RLS + comandos estrechos transaccionales; autoridad en PostgreSQL. | Solo validar en React/Next deja rutas directas y carreras sin proteger. No crear un método genérico que acepte SQL o campos arbitrarios. |
| DT02 | Un cálculo canónico de calendario en PostgreSQL, usado por preview y ejecución. | Cálculos duplicados en navegador/worker divergen ante zonas y cambios de regla. Aislar el módulo permite reemplazarlo con evidencia si el spike G03 lo exige. |
| DT03 | Outbox/jobs en PostgreSQL; despachador pg_cron y ejecutor de objetos por HTTP acotado. | Timers en navegador y tareas en memoria serverless no cumplen persistencia. Cron del alojamiento web no se presupone suficiente; G02 verifica el entorno. |
| DT04 | Cargas/descargas pequeñas mediadas por servidor; rutas de objetos privadas e inmutables. | URLs firmadas son capacidades temporales, difíciles de revocar al retirar permiso; no son la autorización vigente de producto. |
| DT05 | Importación por generación preparada + publicación atómica del puntero del tablero. | Borrar y recrear con varias peticiones produce estados parciales y pierde el previo. Mayor complejidad de lecturas justificada por reemplazo/recuperación aprobados. |
| DT06 | Paquete portable v2 ZIP STORE, JSON versionado y objetos con hash; lector v1. | JSON sin bytes no preserva adjuntos. No adoptar compresión ni extracción arbitraria; procesar por streaming/checkpoints. G06 verifica viabilidad. |
| DT07 | PWA online; caché persistente solo de recursos públicos versionados. | Caché de datos privados y cola offline agregan exposición y sincronización fuera de alcance. Consulta offline limitada conserva únicamente lo ya cargado en memoria durante la sesión. |

Estas elecciones y sus alternativas documentan el razonamiento. Si cambian durante una prueba técnica, registrar revisión/ADR con evidencia y actualizar interfaces y tickets afectados; no pedir al usuario elegir bibliotecas ni cambiar silenciosamente el comportamiento.

## 2. Módulos y sus interfaces

Los nombres siguientes expresan módulos e interfaces lógicas, no carpetas obligatorias. Cada interfaz concentra sus invariantes; los adapters React/Next/Supabase traducen transporte y presentación. No crear repositorios abstractos ni duplicar modelos para cada vista.

| Módulo | Interface de llamadores y pruebas | Responsabilidad oculta |
| --- | --- | --- |
| Identidad y acceso | resolverSesion(); ejecutarAdministracion(comando); aceptarInvitacion(token, operación). | Google/Auth, habilitación, bootstrap explícito, suspensión, membresía, sucesión y revocación. |
| Trabajo del tablero | consultarTablero(consulta); consultarDetalle(id); ejecutar(comando); consultarOperacion(clave). | Identidad, permisos, versiones, orden, acciones independientes, copia, etiquetas, conversación, actividad y recibos. |
| Calendario | previsualizar(regla, contexto); confirmarProgramacion(comando); reconciliarSerie(id). | Fechas nominales/excepciones, conteos, anticipación, una vigente y exclusiones. |
| Consultas personales | consultar(consultaTipada, cursor); guardarPreferencia(comando); guardarVista(comando). | Mis tareas, búsqueda, favoritos, tema, filtros/revisión y paginación autorizada. |
| Novedades | listar(cursor); marcarLeidas(ids, operación). | Destinatarios, caducidad, lote fijo, deduplicación y resultado por ID. |
| Archivos y recuperación | reservarCarga(); recibirCarga(); descargar(); eliminar/restaurar(comando). | Cuota, estados, permisos por causa, Storage, retención y reconciliación. |
| Portabilidad | prepararImportacion(); previsualizar(); publicar(); prepararExportacion(); descargarPaquete(). | Formatos, generaciones, mapeos, snapshot, pins, reservas y limpieza. |
| Ejecución durable | reclamarLote(); ejecutarTrabajo(); confirmarConLease(); diagnosticar(). | Reintentos, token de reclamación, efectos obsoletos y avance sin navegadores. Solo ejecutor confiable, no interfaz pública del usuario. |

El navegador no elige actor, rol, propietario histórico, generation_id activo ni hora de servidor. Se resuelven dentro del módulo. Los comandos administrativos y de Sistema son variantes internas distintas de un comando humano, con permisos restringidos.

## 3. Modelo lógico e invariantes de persistencia

Identificadores opacos y estables; todas las relaciones de contenido incluyen tablero/generación y se validan con claves compuestas. Fechas de vencimiento/nominales son date; ejecución, edición y recuperación usan timestamptz de base. Zona IANA en tablero. El glosario de dominio sigue exclusivamente en CONTEXT.md.

| Familia de registros | Claves/estado y restricciones necesarias |
| --- | --- |
| Persona / identidad / habilitación | Persona ligada de forma única a auth.users; identidad Google estable por proveedor/issuer/subject. Habilitación pendiente/activa/suspendida separada del JWT; administración global explícita. Correo admite el primer vínculo, no es identidad permanente. |
| Tablero / membresía / invitación | Tablero con propietario, zona, content_revision, auth_epoch y active_generation_id. Un episodio activo por miembro/tablero; todo tablero activo tiene exactamente un dueño habilitado y miembro. Invitaciones directas/genéricas con hash de token, 72 h, consumo/revocación y emisor. |
| Generación / columnas / orden | Una generación visible por tablero. Columnas con posición y revisión de orden; tareas con posición dentro de columna. Versionar órdenes de columnas afectadas, sin reenviar campos de tarea al mover. |
| Tarea / cumpleaños | Identidad única en vistas; tipo explícito. Tarea tiene completado, prioridad, fecha opcional y responsable actual; cumpleaños no admite completado. Referencias a serie no equivalen a duplicar tarjeta. |
| Campos / checklist / comentarios / menciones | Revisiones de campos editables; paso y comentario con identidad/versiones propias. Mención al episodio de membresía; retirada deja texto literal, sin reactivar al reingresar. Sin versiones antiguas del texto del comentario. |
| Serie / slot de ocurrencia / exclusión | Serie con regla/revisión, plantilla y estado; slot único por serie/fecha nominal. Vínculo a tarjeta materializada, estado actual/histórico y propiedad vigente del vínculo. Exclusión con causa separada del contenido purgable. A lo sumo una vigente por serie. |
| Etiqueta / asociaciones | Identidad de catálogo por tablero, clave de nombre normalizada y soft-delete. Asociaciones por tarjeta y selección de plantilla independientes. Unicidad solo activa, máximo100 catálogo/10 por elemento. Restauración valida capacidad y colisiones. |
| Vista / preferencias / favorito | Persona/contexto; versión por preferencia o definición de vista. Consulta versionada con inclusión de completadas e historial. Máximo50 vistas activas/persona, nombres60 caracteres únicos por contexto. Favorito no conserva permiso. |
| Archivo / reserva / ledger | Ruta inmutable, hash, tamaño, tarea, estado y causa de borrado; cuota global/puestos reservados. Producto y almacenamiento real conciliados, sin liberar al hacer soft-delete. |
| Borrado / dependencia / retención | Causa, actor, instante, vence, padre causante y transición de purga. Una causa heredada no borra la independiente de un hijo. No usar un único deleted=true para toda la semántica. |
| Recibo / trabajo / actividad / novedad | Registros separados. Recibo de intención; trabajo con lease; actividad solo categorías E05/180 días; novedad evento+destinatario/90 días. No confundir auditoría operativa con producto. |

Q62 exige separar **procedencia** de **dependencia destructiva**: al detener A y programar B, la misma tarea pasa a ser primera vigente de B. El slot de A queda histórico/desvinculado de propiedad vigente y no participa en la cascada destructiva de A sobre esa tarjeta. Conserva referencia de transición autorizada a B; no duplica el contenido ni crea una segunda tarjeta. Borrar/restaurar/purgar A puede retirar sus registros históricos, pero no sigue ese vínculo para borrar o reasignar B. No conservar snapshots de textos purgados para aparentar historial. Exportar/importar preserva esta distinción y prueba C112-AC62.

Las FK de serie a tarea no deben definir CASCADE que contradiga esa regla. El módulo calcula el conjunto que realmente posee la serie al confirmar borrado, bajo lock; una reprogramación concurrente cambia versión e invalida el preview.

## 4. Identidad, autorización y orden de locks

Google se gestiona mediante Supabase Auth. El adapter verifica identidad del proveedor y distingue subject Google de sub del JWT Supabase. Vincula una habilitación pendiente bajo lock solo con correo verificado y elegible; luego usa identidad estable. No usar metadata editable ni un actor enviado por JSON como autoridad. Bootstrap administrativo por identidad elegida y configuración explícita; nunca primer visitante.

Lecturas de tablas, vistas, búsquedas, recibos y objetos comprueban habilitación y permisos actuales. RLS para lecturas con JWT de usuario; vistas invoker cuando corresponda. Escritura de producto únicamente a través de comandos permitidos, sin DML directo alternativo. Función invoker cuando los grants expresen invariantes; si necesita definer, dueño mínimo, search_path fijo, nombres calificados, EXECUTE restringido y autorización explícita. Inventario de todas las firmas antiguas/grants es parte de G01.

Orden inicial de locks para comandos: barrera administrativa cuando corresponda → habilitaciones/personas afectadas ordenadas → contador global si hay bytes/plazas → tableros ordenados → entidades/órdenes dentro del tablero ordenadas. Un comando descubre su conjunto antes de bloquearlo y vuelve a validar bajo lock; si necesita ampliarlo, reinicia con conjunto completo. Los lectores/mutadores comunes toman lock compartido de habilitación; suspensión exclusivo. Comandos de un tablero serializan cambios sobre su fila al inicio, una opción proporcional que evita carreras de ACL. Las transacciones son cortas y no hacen HTTP.

Suspensión/transferencias masivas obtienen conjunto de tableros y revalidan que no apareció otro: crear/tablero y aceptar invitación también coordinan habilitación. Proteger último administrador y sucesor válido en la misma transacción, sin permitir que dos retiradas dejen cero administradores. Si no puede completarse el conjunto en presupuesto, no aplicar una suspensión parcial invisible: preparación/confirmación específica con estado inaccesible y prueba de convergencia antes de relajar atomicidad.

Un comando completa antes de revocación o es denegado después; no hay ventana libre entre validar y escribir. Una lectura en vuelo puede haber tomado snapshot anterior; no se promete retirar bytes ya entregados. Las peticiones nuevas tras confirmar retiro quedan denegadas. Admin global no obtiene lectura de contenido: sus operaciones reciben solo metadatos mínimos previstos por Permisos.

Invitación: validar emisor vigente/tablero/destinatario/72h, consumir y crear membresía en una transacción. No habilitado o ya miembro no consume. Reingreso crea nuevo episodio, sin asignaciones/menciones antiguas restauradas.

## 5. Contrato de comandos, conflictos y resultado incierto

Envoltorio lógico v1:
- command_id aleatorio por intención, action permitida, target, expected_versions y payload de campos permitidos.
- Contexto de actor resuelto de sesión; generación/ACL resueltas en base. Payload canónico+acción+target+versiones se hashean.
- Resultado tipado: confirmed, conflict, invalid, unavailable, retryable; operation_status distingue pending/confirmed/expired_unknown.
- Respuestas incluyen operation_id y revisiones necesarias, nunca snapshots privados a quien perdió acceso. Los errores de existencia/acceso comparten unavailable cuando distinguirlos filtra información.

Recibo único por persona/command_id. Reintento idéntico vuelve al resultado, no repite efecto; misma clave con contenido diferente se rechaza. Resultado mínimo conservado inicialmente7 días; al vencer, ausencia no acredita que nunca se ejecutó. No reenviar automáticamente una intención vencida: reconciliar recurso/clave de origen y pedir nueva intención si sigue siendo desconocida. Creaciones conservan clave de origen y tombstone mínimo mientras sea necesario para evitar duplicados de reintentos admitidos.

PATCH distingue campo ausente de null explícito. Control de versión por campo de tarea, por comentario/paso, por orden y por serie/vista; no una versión global que haga chocar un comentario nuevo con editar título. Reordenar envía IDs/destinos/anclas/versiones, jamás título/descripción. Completar envía estado deseado, no toggle.

Completar con pasos pendientes requiere preview de cantidad/revisión de checklist. Si cambió desde confirmación, devolver revisión para confirmar otra vez. Guardar campos es independiente de comentar/marcar paso/subir archivo. Un conflicto conserva borrador autorizado; retirar acceso lo retira conforme C-95. Copia compara exclusivamente los campos copiables previsualizados; comentario nuevo no invalida.

Importación incrementa content_revision; cambios personales no lo hacen. Cualquier mutación de contenido visible/preparado que afecte un preview debe participar en su revisión o hash; nunca comparar solo updated_at del cliente.

## 6. Calendario y ejecución durable

Regla v1 tipada por día/semana/mes/año, intervalo positivo, inicio explícito, días/ordinal/fecha, anticipación y final sin_fin/hasta_fecha/conteo. Se guarda el ancla original, no el resultado ajustado de febrero. La versión de regla y su significado de conteo son parte del formato exportado.

El módulo canónico recibe regla, exclusiones, contexto actual e instante de referencia. Preview devuelve cinco próximas fechas, tarjeta inicial distinguida, apariciones y frontera estricta de excepción; validación completa no equivale a comprobar solo cinco. Producción usa reloj de base; únicamente el arnés aislado permite reloj controlado, sin parámetro público para viajar en el tiempo.

Crear desde tarjeta: misma identidad primera y cuentaN. Editar explícitamente final por N: N próximas excluyendo actual/pasado; guardar un límite/segmento de conteo con punto de aplicación, sin resetear al cambiar otro campo. Excluir consume fecha; quinto ordinal inexistente no. Las futuras se calculan sin materializarlas todas. Excepción modifica vencimiento, conserva fecha nominal/identidad y debe ser anterior a siguiente aparición.

Reconciliar busca directamente última elegible hasta instante; no recorre ni crea todas las omitidas. Bajo lock valida serie/generación/revisión/columna/exclusiones y crea como máximo vigente. Si sustituye pendiente, queda reemplazada, jamás completada. Restauración finita usa máxima última válida, aunque nunca se materializara; última excluida no retrocede a penúltima. Restaurar una detenida no la activa. No regenerar hijos borrados independientemente.

Aparición D-X se interpreta en zona de tablero; día inexistente civil: primer instante real cuyo día local alcanza/supera D-X, manteniendo fecha nominal. Esto es resolución técnica de zona, no cambio de vencimiento ni fecha inventada. Probar Pacific/Apia2011, DST, dos zonas, 29febrero/31mes/quinto lunes y cambios de zona. El preview debe usar exactamente esta resolución.

Outbox con referencias mínimas se escribe junto al comando. Jobs llevan tipo/target/revisión/dedup/available_at/estado/intentos/lease_token/lease_until. Reclamar por lote con SKIP LOCKED; finalizar requiere token vigente y revalidar objeto. Efectos solo DB se aplican y finalizan en una transacción. Efectos Storage se hacen fuera y confirman con token; rutas inmutables hacen seguro repetir borrado. Worker viejo no publica tras lease vencido.

Parámetros iniciales de ingeniería: despacho1min, hasta25 agregados SQL/5s, hasta10 efectosHTTP por lote y10s por petición, lease120s; reintentos1/5/15/60min y luego6h, jitter; ocho fallos clasificados llevan a diagnóstico persistente. Cada ejecución respeta además límites del runtime real. Reconciliación al entrar y barrido de vencidas reparan pérdida/agotamiento de jobs, sin reemplazar avance autónomo. No prometer SLA de medianoche ni ejecución exactamente una vez.

## 7. Archivos, cuota, recuperación y purga

Carga: reservar → recibir en servidor → validar → subir ruta inmutable privada → publicar. El servidor comprueba sesión/ACL/reserva antes y después de Storage. Lee como máximo24.001bytes para rechazar >24.000, extensión txt/md, UTF-8 válido, sin NUL/firmas binarias; hash/tamaño reales. Texto siempre inerte: descarga attachment/text/plain/nosniff/no-store y vista escapada, sin HTML/Markdown activo ni fetch de URLs.

Cuota producto200.000.000bytes y20 archivos/tarea incluyen activos, recuperables y reservas; import preparado también cuenta. Lock contador/tarea, reserva idempotente15min, máximo inicial5 reservas/persona/20 instancia y30 nuevas/min/persona. Son parámetros técnicos de abuso/recursos, ajustables con evidencia, no cupos de producto nuevos. Si se alcanza, respuesta temporal clara y reintento, sin borrar contenido. Storage privilegiado solo en adapter servidor tras autorización; ninguna service key al cliente.

Transferir reservado→activo no suma dos veces; activo→recuperable no libera; restaurar no cobra de nuevo. Purga reclama bajo lock al vencer7×24h; desde instante límite no se restaura aunque el objeto exista. Borrar por Storage API y liberar ledger únicamente tras confirmar inexistencia; timeout mantiene consumo pendiente. No borrar solo filas de storage.objects. Reconciliación horaria paginada de reservas/huérfanos/faltantes/purgas/ledger; listado parcial o error no prueba que se pueda purgar.

Recuperación genérica usa causas y dependencias: padres antes, permisos actuales por causa, hijos borrados aparte no reviven. Borrar columna traslada tareas/series según preview; recuperarla no revierte esos traslados. Etiquetas/vistas restauran con colisiones/cupos revisados, sin fusión silenciosa ni asociaciones parciales no elegidas. Plazo no se reinicia por import/restore de un padre.

Avisos por persona/umbral se registran con contador durable. Rearmar requiere bajar y un nuevo cruce al menos24h después del aviso previo; permanecer encima no avisa periódicamente ni programa recordatorio por cruce temprano. Carga excedida siempre muestra límite inmediatamente. Limpieza admin solo metadatos permitidos, sin contenido adjunto.

## 8. Consultas, búsqueda, preferencias y UI

Normalización v1 compartida por nombre/búsqueda: normalizar Unicode NFC, recortar y colapsar espacios, plegar mayúsculas y diacríticos incluyendo ñ→n en clave derivada. Guardar texto original; IDs/correos/URLs no usan esta normalización. Para límites40/60, contar puntos de código tras NFC con el mismo contrato SQL/TypeScript; no usar longitud UTF-16 del navegador. Probar equivalencia compuesta/descompuesta, emojis y casos españoles. La tabla de equivalencias se versiona; cambiarla exige detectar colisiones antes de activar, sin fusionar registros.

Etiquetas100 activas/tablero,10 por elemento, nombres40; vistas50 activas/persona, nombres60/contexto. Constraints/locks aplican límites también con dos clientes y restauraciones concurrentes. Etiquetas entre sí OR, entre familias AND. Consulta guardada v1 incluye contexto/alcance, texto, completadas, include_replaced_history, filtros y orden; ausencia de nueva clave en versión anterior equivale a false. Fechas relativas se recalculan en zona correspondiente.

Validar referencias explícitas antes de ejecutar: inválida devuelve review_required sin resultados parciales ni globalización. Q61 separa reemplazadas de completadas: comentarios heredan estado/filtros de tarea; incluir historial permite reemplazadas autorizadas y muestra estado/fecha/origen. Cambiar control es variación temporal de vista; actualizar definición es explícito. Limpiar/Reiniciar conserva semántica C-106 y desactiva historial.

Búsqueda en PostgreSQL, índices de texto normalizado/FTS para título/descripción/comentario actual, pg_trgm solo donde las mediciones lo justifiquen. Toda consulta valida ACL/generación/estado antes de ranking, cupos, conteos o extractos. Índices derivados se mantienen en misma transacción para edición/moderación; si algún proceso es asíncrono, releer texto actual autorizado antes de devolver. No devolver fragmento viejo de comentario borrado.

Sugerencias tipadas por tablero/tarea/comentario/etiqueta-filtro. Relevancia: exacta, prefijo y palabras incompletas; título pesa más, cupos iniciales5/grupo, ampliación explícita y desempate estableID. Solicitudes tras150ms de pausa como valor inicial medible, sin bloquear consultas cortas por un mínimo oculto. Consultas1–2caracteres por prefijo indexado y cupos, sin similitud amplia; no prometer tolerancia a errores/IA. Lista «Ver tareas» deduplica por tarea y usa orden personal, no ranking. Extractos como segmentos de texto, jamás HTML de índice sin escapar.

Páginas iniciales50 tareas/lista y30 comentarios/actividad/novedades, ajustables tras medición; cursor opaco ligado a consulta/orden y últimos valores+ID. No representa snapshot de todas las páginas: cambios concurrentes invalidan/reinician consulta de forma explícita si es necesario. Para comentario preciso, consulta de ventana por ID bajo mismos permisos, aunque no esté en primera página. Exportación no usa estas páginas.

Tablero carga resúmenes activos, completadas progresivas y detalle al abrir. No imponer paginación de pendientes que rompa orden manual: primero medir500 tareas y volumen realista de conversaciones; si hace falta, mover con anclas vecino/versión y probar carga parcial antes de habilitar. Nueva tarea al final manual; orden por fecha la ubica por fecha. Desempates/fecha relativa según C-104/C-106.

UI usa mismos IDs/detalle para todas las vistas, captura explícita solo título, sin blur-submit; bloques opcionales, drawer y menús según Pantallas. Estados de guardado veraces y foco conservado; teclado/móvil y alternativa al arrastre en todas las acciones. Copia puntual prepara preview de título/columna/resumen, crea solo campos E04 y ofrece abrir resultado; no copia adjuntos/conversaciones/responsable/fecha/serie.

Novedades por evento+destinatario, acceso vigente y sin autoavisos; creador de referencia según C-111. marcarLeidas recibe IDs fijos cargados/no leídos al pulsar, devuelve por ID marked/already_read/unavailable/failed; resumen agrega categorías y retry solo failed de conjunto original. Timeout consulta recibo antes de reenviar; no añade las recién llegadas. Activity E05 separada,180d/evento sin renovarse al restaurar; autores históricos no son menciones activas.

## 9. Realtime, sesiones y PWA

Broadcast privado solo servidor, señales sin contenido privado; no Presence nuevo. Topic opaco por tablero/auth_epoch. Revocación incrementa época y cambia destino de nuevas publicaciones. El despachador bloquea tablero, relee auth_epoch y registra la señal mediante realtime.send privado dentro de la transacción SQL; no hace HTTP con locks abiertos ni guarda el topic antiguo como destino permanente de un job. La documentación describe emisión desde base mediante realtime.messages y replicación: [Broadcast de base](https://supabase.com/docs/guides/realtime/broadcast). Confirmar permisos/versión y rollback en G05; si esa primitive no está disponible, el camino queda bloqueado hasta un mecanismo equivalente probado. No exponer conteos/títulos en canales. El canal viejo no recibe nuevas publicaciones posteriores a la revocación; señales ya confirmadas antes pueden llegar tarde por transporte y solo provocan un refetch autorizado. No se promete cancelar bytes en tránsito.

Cliente refetch autorizado tras señal, reconexión, volver de segundo plano y operaciones relevantes. Poll de revalidación inicial30s mientras visible como reparación, no SLA ni capacidad de retirar contenido de un dispositivo offline. Al confirmar denegación, limpiar contenido/borrador; nunca mostrar dato de otra cuenta. Realtime privado solo no acredita revocación: las políticas se cachean durante la conexión. [Autorización Realtime](https://supabase.com/docs/guides/realtime/authorization).

Cada sesión tiene época local: logout/cambio/revocación aborta requests, borra memoria privada y descarta respuestas de época previa. Caché SSR/CDN/RSC privada no compartida, respuestas private/no-store. No almacenar contenido privado ni borradores en localStorage/IndexedDB/CacheStorage; cookies Auth gestionadas por adapter, sin copiarlas a logs o preferencias. Revalidar callbacks y retornos internos allowlist, sin open redirect ni saneamiento que pierda invitaciones.

Manifest/iconos y recursos públicos versionados; SW si se requiere para actualización, con allowlist estática. Offline solo contenido ya en memoria de sesión con aviso, sin recarga privada ni cola. Actualización anuncia y espera decisión; con borrador ofrece guardar/descartar/seguir según contrato antes de recargar. No forzar skipWaiting/reload que pierda edición. Instalación opcional en Cuenta e instrucciones por navegador, sin modal insistente. Probar matriz C-109 en dispositivos/versiones reales, no certificar por tener manifest.

## 10. Portabilidad v2 y recuperación de instancia

Paquete recomendado: ZIP método STORE sin compresión, manifest.json con format/version/fecha/esquema/calendario/normalización, archivos JSON de entidades y objects/<id> con tamaño/SHA256. IDs del paquete son locales, no autoridad ni rutas físicas. Referencias se remapean; sin rutas absolutas/../symlink, entradas duplicadas ni fetch externo. JSON tipado rechaza claves protegidas y relaciones cruzadas. Hash verifica integridad, no autenticidad.

Incluye contenido vigente autorizado, catálogo activo incluso sin uso, series/reglas/exclusiones mínimas y actividad aún vigente, adjuntos vigentes. No papeleras, habilitaciones/membresías/tokens, novedades, preferencias/vistas. Exclusión sin texto puede conservarse para no regenerar pasado purgado. Atribución importada explícita; responsables solo mapeados a identidad/membresía destino válida, nunca por nombre. Dueño/miembros destino intactos y cero avisos de conversación históricos. Lector JSONv1 existente normaliza al modelo nuevo sin inventar etiquetas/series/fechas.

Import: recibir por fragmentos acotados, validar/parsear incrementalmente, reservar bytes/slots y preparar generación invisible con objetos privados. Preview muestra reemplazo, mapeos, zona, cuota y versión actual. Confirmar revalida dueño, contenido esperado, integridad, permisos y capacidad bajo locks; cambia puntero y retiene previa7d en una transacción, sin Storage dentro. Tras pérdida de respuesta consultar operación, no repetir publicación. Preparación expira inicialmente1h; limpiar restos por jobs. Restaurar reemplazo es otra publicación revisada que no pisa trabajo posterior silenciosamente y retiene lo sustituido según contrato.

Export: una transacción de snapshot materializa registros exportables en preparación privada y pins de objetos inmutables; páginas posteriores leen ese snapshot, no datos vivos. Empaquetado streaming con checkpoints y fragmentos iniciales1MiB; verificar hashes/tamaño antes de finalizar, no cargar archivo entero en memoria. Pins iniciales1h renovables por trabajo activo; no permiten restaurar fuera de7d ni leer sin permiso. Descargar revalida actor/ACL y limpia temporales al cancelar/revocar. Tablero reemplazado no convierte un snapshot antiguo en acceso permanente.

No convertir los límites legado2MiB/50columnas/500tareas por columna ni los techos candidatos de investigación en capacidad nueva aprobada. El parser impone presupuestos de recursos medidos y paginación/streaming; si un tablero válido no puede exportarse completo, bloquear G06 y corregir mecanismo antes de entrega, sin truncar. Temporales de paquetes y generaciones cuentan por separado en inventario de infraestructura, con presupuesto y limpieza verificables; cuota de adjuntos no garantiza espacio del hosting.

Respaldo operativo es distinto: dump consistente de base/configuración + inventario y bytes Storage + versiones de app/migraciones + recuperación de secretos por canal autorizado. El backup DB no incluye objetos: [Supabase Backups](https://supabase.com/docs/guides/platform/backups). Primera estrategia: mantenimiento con escrituras/purgas pausadas, checkpoint y copias coordinadas; destino privado cifrado y frecuencia se configuran al preparar operación real, sin contratar aquí. Ensayar restauración aislada con jobs apagados, hashes, identidad/ACL/cuotas y calendario, luego reanudar diagnóstico. Medir RPO/RTO, no prometerlos sin ensayo.

## 11. Verificaciones y criterios de salida

No son nuevas preguntas de producto ni tareas ejecutadas. Pueden desarrollarse/probarse con fixtures cuando se autorice implementación; datos/servicios reales requieren el alcance correspondiente. Cada gate tiene evidencia mínima, evita un cierre automático ficticio y bloquea solo sus dependientes.

| Gate | Verificación concreta | Evidencia requerida / qué bloquea |
| --- | --- | --- |
| G01 — Acceso | Inventariar tablas/vistas/RPC/grants/Storage/canales, bootstrap y revocación; probar cliente directo no cooperativo. | Pruebas integración de dos cuentas+anon, admin ajeno y retirado, sin rutas alternativas. Bloquea habilitar contenido privado. |
| G02 — Ejecutor | Plan/pg_cron/runtime disponibles, avance sin navegador, caída/lease/backlog y reintento; probar pausas. | Historial de ejecuciones aisladas y límites observados; cron SQL/HTTP documentado no prueba nuestra instancia. Bloquea afirmar automatización operativa. [Supabase Cron](https://supabase.com/docs/guides/cron). |
| G03 — Calendario | Preview/ejecución mismo resultado y tiempo acotado, patrones grandes, zonas y C110–112. | Escenarios con reloj controlado + filas persistidas; sin máximo arbitrario que recorte catálogo. Bloquea aceptar programación/recuperación. |
| G04 — Storage/cuota | Validación, carreras, upload timeout/revocación, purge/restore y ledger real. | Objetos/contadores coinciden tras fallos, descarga autorizada y huérfanos recuperables. Bloquea adjuntos/import con objetos. |
| G05 — Sesión/Realtime | Canal viejo abierto, suspensión, cambio de cuenta, respuesta tardía y cliente offline. | Sin publicaciones privadas posteriores en tema revocado, refetch denegado, memoria/caches correctas; documentar límites ya entregados. Bloquea afirmar revocación/sincronización. |
| G06 — Portabilidad | v1/v2 roundtrip, corrupción/rutas, snapshot/pins, import crash y export completo streaming en runtime. | Datos/objetos/identidades/calendario preservados; evidencia de recursos/temporales y ninguna publicación parcial. Bloquea respaldo portable. |
| G07 — Experiencia/carga | Búsqueda1–2letras/acentos/ñ/comentarios/historial,500 tareas, páginas, orden y PWA C-109. | Planes/latencia medidos, teclado/móvil real y P26 observado; sin certificación por viewport simulado. Bloquea calidad/compatibilidad declaradas. |
| G08 — Corte/restore | Inventario real autorizado, propietario/admin explícitos, configuración/rotación pendiente, backup+restore aislado y rollback privado. | Ensayo y autorización de corte; nunca primer-login-dueño ni rollback anónimo. Bloquea producción, no trabajo aislado. |

Pruebas cruzan las tres interfaces acordadas: servidor/base real aislada, navegador y calendario con reloj controlado. El arnés SQL existente no sustituye Auth/Storage/Realtime reales ni el piloto. Lint/typecheck/build son comprobaciones técnicas complementarias. Evidencia por [matriz](./MATRIZ-TRAZABILIDAD-1.0.md), incluyendo C112-AC61–62 y DUR/FILE/IMP/BAK/PWA de investigación, seleccionados por garantía y sin duplicar tests que solo reflejen detalles internos.

## 12. Dependencias para descomponer en tickets

Esta secuencia prepara tickets; no los crea ni habilita un loop. Las entregas serán recorridos completos sobre la base necesaria y conservarán todas las P/E.

| Entrega lógica | Depende de | Resultado revisable |
| --- | --- | --- |
| D0 — Entorno aislado y contratos comunes | Diseño DT-0.1 | Fixtures, reloj de pruebas, errores/recibos, inventario legado y plan de migración aditivo. |
| D1 — Entrada privada y colaboración | D0 | Login/habilitación, tablero/propiedad/invitación/retirada; G01. |
| D2 — Trabajo diario privado | D1 | Capturar/editar/mover/completar, pasos/comentarios/menciones/Mis tareas, conflictos; campos y acciones separados. |
| D3 — Calendario completo | D2 + protocolo de jobs | Crear/editar/detener/restaurar, cumpleaños/historial, Q62; G02/G03. |
| D4 — Archivos y recuperación | D2 + protocolo de jobs | Reserva/carga/descarga/cuota/papelera/purga y limpieza autorizada; G04. |
| D5 — Organización y búsqueda | D2; D3 para históricas | Etiquetas, vistas, filtros/preferencias/favoritos, búsqueda rica/Q61 y copia puntual. |
| D6 — Actividad/novedades y sincronización | Eventos D2; D3/D4 para productores | E05/E07, avisos temporales/cuota, sesiones/Realtime G05; no diferir evidencia de revocación al final del corte. |
| D7 — Respaldo portable y operativo | D3/D4/D5/D6 | Import/export completos y generaciones; G06 y ensayo aislado G08. |
| D8 — Experiencia completa y preparación de corte | Todas | Tema/PWA, accesibilidad/dispositivos, carga/P26/G07, actualización/diagnóstico y corte revisable G08. |

Tema/accesibilidad/estados/foco se aplican desde las primeras pantallas; D8 verifica integración final, no autoriza postergarlos en entregas. Trabajo durable es un fundamento de D3/D4/D6, no una función opcional. Cada ticket debe mapear sus P/E, contratos/escenarios, dependencias y evidencia, y no declarar completado algo que sigue bloqueado por configuración o prueba manual.

## 13. Estado documental y fuentes

No se ejecutó código, SQL, test funcional ni operación remota de infraestructura para producir este diseño. No se inspeccionaron secretos ni datos reales. La verificación realizada es documental/estática; el estado implementado de este objetivo permanece pendiente.

Fuentes oficiales y hechos de plataforma, consultados en las investigaciones del26–27/10 y rechecados en puntos críticos27/10:
- [Identidad, permisos y mutaciones](../research/BASE-TECNICA-IDENTIDAD-Y-MUTACIONES-2026-10-27.md): Google, Auth, RLS, transacciones y revocación.
- [Ejecución, objetos y respaldo](../research/BASE-TECNICA-EJECUCION-Y-RESPALDO-2026-10-27.md): calendario, jobs, Storage, streaming y recuperación.
- [Búsqueda](../research/BUSQUEDA-UNIFICADA-VIABILIDAD-2026-10-26.md) y [PWA/lotes](../research/PWA-Y-NOVEDADES-VIABILIDAD-2026-10-26.md): capacidades documentadas; sus propuestas históricas se subordinan a C-108–112.
- [Descargas privadas Storage](https://supabase.com/docs/guides/storage/serving/downloads): acceso autenticado frente a capacidad firmada. Se elige descarga mediada con permiso vigente.

Siguiente paso: revisar esta versión concreta contra los contratos y convertir entregas en tickets verificables. Implementación, commits/push, migraciones remotas y despliegue no se inician por redactar este documento.
