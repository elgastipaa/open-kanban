# Base técnica candidata — ejecución, archivos y respaldo

Fecha de investigación: 27/10/2026. Estado: propuesta técnica para cerrar P19/P21/P22/P24 y la privacidad de E06; no es implementación, ADR aprobado ni evidencia de infraestructura desplegada. Las fuentes públicas se consultaron hoy. No se leyeron archivos de entorno, credenciales ni datos de producción; no se ejecutaron servicios, migraciones ni importaciones.

## 1. Conclusión y límites de evidencia

El stack Next.js + Supabase permite proponer una base proporcional: transacciones PostgreSQL para las invariantes, trabajo pendiente en la misma base, procesamiento en lotes y objetos privados inmutables. No hace falta introducir Celery, RabbitMQ ni un motor externo para escribir los contratos. Sin embargo, **la capacidad real de ejecutar trabajos sin usuarios conectados y de restaurar una instancia sigue siendo un gate de verificación**, no una garantía derivada de la documentación.

Vercel Hobby documenta cron una vez al día, con ejecución dentro de una ventana horaria; no sirve como único reloj para activaciones por zona de tablero. Sus invocaciones fallidas no se reintentan automáticamente. Estas son limitaciones del producto documentado, no constataciones del plan de esta cuenta. [Uso y precios de Vercel Cron](https://vercel.com/docs/cron-jobs/usage-and-pricing), [gestión y errores](https://vercel.com/docs/cron-jobs/manage-cron-jobs).

Supabase Cron ofrece SQL/funciones de base y llamadas HTTP mediante pg_cron. Recomienda no superar ocho trabajos concurrentes y diez minutos por trabajo; no son ocho workers que debamos crear. Un despachador periódico de lotes pequeños es candidato, condicionado a comprobar extensión, permisos, límites y actividad del proyecto elegido. La página no permite certificar nuestro plan ni su disponibilidad. [Supabase Cron](https://supabase.com/docs/guides/cron).

El plan Free público anuncia 500 MB de base, 1 GB de archivos y pausa tras una semana de inactividad; no equivale a 200 MB de cuota de producto ni garantiza programación continua. No proponemos actividad artificial para evitar pausas ni contratar un plan por esta investigación. [Planes oficiales de Supabase](https://supabase.com/pricing).

## 2. Acuerdos y base local inspeccionada

Autoridad de producto: `CONTEXT.md`, `docs/specs/CONTINUIDAD-SPEC.md`, acuerdos en `0001-auth-collaboration.md`, MVP §§7–9/14.3/16 y Cierre CF-04.1/07.1/09.1/16/17/19/26/H. No sustituir estas fuentes por esta nota.

- C-110 fija fechas efectivas, exclusiones que consumen su fecha, recuperación finita sin pila intermedia, recuperación individual sin reactivar padre y permiso actual. Q55–60 fueron aceptadas por el usuario el 27/10 y están registradas como C-111: tarjeta inicial cuenta, editar N próximas excluye actual/pasado, creador de referencia de serie y rearme de cuota. Esta nota no reabre esas decisiones.
- P19 exige trabajo durable y deduplicado, sin prometer exactamente una vez. P21/P22 exigen siete días reales de recuperación, no revivir hijos borrados aparte y cuota atómica que cuenta reservas y recuperables. P24 separa respaldo portable y operativo.
- `src/lib/import.ts` valida JSON v1 de hasta 2 MiB, 50 columnas y 500 tareas por columna, borra las columnas anteriores y luego crea mediante llamadas separadas. No es atomicidad de reemplazo; esos techos son legado del lector, no límites nuevos aprobados del producto.
- `src/lib/export.ts` toma columnas/tareas recibidas por el navegador y escribe JSON v1; no incluye series, archivos ni las nuevas entidades. Una exportación completa futura debe consultar el conjunto autorizado, no reutilizar sin más la vista cargada.
- `package.json`: Next 16.4.2, React 19.2.9, clientes Supabase y scripts lint/typecheck/test:db/build. La búsqueda de jobs/recurrencias/Storage no encontró motor implementado en `src`/migraciones. No se presume que dependencias instaladas prueben una capacidad operativa.
- `scripts/test-db.sh` crea PostgreSQL descartable propio y `tests/db/security.sql` prueba RPC/RLS; puede ampliarse para transacciones y carreras. No simula Auth/Storage/cron hospedados ni sustituye su ensayo aislado.

## 3. Tiempo: una función autoritativa de calendario

**Candidato recomendado:** un módulo de calendario de servidor, con implementación canónica en funciones PostgreSQL versionadas. Preview, validación y reconciliación llaman la misma función; el navegador solo presenta el resultado. Evita mantener un cálculo distinto en Next, Edge y SQL. Si una evaluación demostrara que una biblioteca compartida es preferible, documentar ese ADR antes de implementar: ningún ejecutor puede inventar otra semántica.

Separar tres representaciones: día de vencimiento como `date`, zona IANA del tablero como identificador, e instantes de ejecución/retención como `timestamptz`. No guardar un vencimiento de día entero como medianoche del navegador ni sumar 86.400 segundos para avanzar un día de calendario. PostgreSQL distingue esos tipos y aplica reglas de zonas; se debe probar la versión concreta instalada, no adoptar PostgreSQL 18 por haber consultado documentación current. [Tipos temporales PostgreSQL](https://www.postgresql.org/docs/current/datatype-datetime.html).

Contrato propuesto del módulo:

| Operación | Entradas | Salida/invariante |
| --- | --- | --- |
| Previsualizar | regla normalizada, zona, inicio, final/conteo, anticipación, exclusiones, tarjeta actual, instante de referencia explícito | Fechas contadas, próximas apariciones y máximo permitido para excepción; misma revisión de regla que se confirmará. |
| Encontrar vigente | regla/revisión, instante, exclusiones, estado detenido/borrado | Como máximo última fecha elegible cuya aparición ocurrió; no fabricar todas las omitidas. Si última fecha finita fue excluida, no buscar una sustituta anterior para crearla. |
| Confirmar edición | versión esperada, regla propuesta, preview/hash, clave de operación | Revalida calendario y dependencias; actual/pasadas intactas, exclusiones compatibles conservadas; conflictos devuelven revisión nueva. |
| Reconciliar | ID de serie, revisión esperada, instante de base | Bajo lock de serie materializa como máximo una vigente, sustituye pendiente anterior sin completarla y actualiza próxima ejecución. |

Guardar por separado la **fecha nominal de ocurrencia** y su fecha límite excepcional. Una exclusión se identifica por serie + fecha nominal + causa; mover un vencimiento no cambia la identidad de la ocurrencia ni el contador. Una revisión nueva invalida trabajos antiguos, pero no crea otra identidad para una fecha ya materializada. Constraint única serie/fecha nominal y constraint parcial de una sola vigente no borrada son defensas finales, además de validación de negocio.

Para días locales con cambio de zona/horario: las fechas de calendario permanecen fechas; calcular el siguiente instante que alcanza el día de aparición en esa zona y verificar el día local al ejecutar. Candidato para un día civil inexistente por cambio de huso: primera fecha civil válida posterior, sin cambiar la fecha nominal; debe constar en ADR y prueba antes de cerrar el caso. Cambiar la zona del tablero invalida ejecuciones futuras y recalcula; no mueve vencimientos históricos. No se promete latencia de medianoche exacta.

## 4. Trabajos durables, exclusión y reintentos

### 4.1 Datos mínimos y transición

Tabla privada de trabajo: ID, tipo permitido, referencia mínima de agregado, revisión, clave de deduplicación única, `available_at`, estado, intentos, lease/token, `lease_until`, error clasificado, tiempos. No poner títulos, comentarios, tokens ni cuerpos de archivos en payload/logs. El comando que requiere efecto posterior inserta la fila en la **misma transacción** que el cambio; si hace rollback no queda un trabajo huérfano.

Estados candidatos: pendiente → reclamado → completado; reclamado → pendiente con backoff; reclamado vencido → pendiente reclamable; cancelado por precondición inválida; revisión operativa si error persistente. La deduplicación se aplica al efecto de negocio (ocurrencia, evento/destinatario, objeto a purgar), no solo al mensaje. Reintentar cien veces no crea cien novedades.

Reclamar lotes con locks de fila y `SKIP LOCKED` evita que consumidores compitan por el mismo trabajo; esa lectura está documentada para colas, no debe usarse para devolver un listado consistente de tareas al usuario. Confirmar una reclamación otorga token creciente de lease. Un worker expirado no puede confirmar ni publicar cambios usando un token anterior. [SELECT y bloqueos PostgreSQL](https://www.postgresql.org/docs/current/sql-select.html).

- Efectos solo DB: lock de agregado, precondiciones y efecto + finalizar trabajo en una transacción corta. No mantener una transacción abierta durante HTTP.
- Efectos Storage: reclamar, hacer petición acotada fuera de la transacción y confirmar con token. Repetir eliminación por ruta inmutable ya inexistente se considera éxito; nunca reutilizar esa ruta para un archivo nuevo.
- Notificaciones: identidad de evento + usuario receptor única, excluir actor y volver a comprobar habilitación/membresía y condición temporal. Referencia de creador según C-111, sin sustituir a retirados por propietario. Un import no emite eventos de conversación antiguos.
- Cambios de regla, borrar padre/hijo, detener, reemplazar generación o perder permisos invalidan precondiciones. Marcar obsoleto/cancelado y volver al estado actual; un payload viejo nunca es autorización permanente.
- Fallo persistente no puede esconderse al llegar a máximo de intentos: queda visible para diagnóstico mínimo y reejecución controlada. Las activaciones recuperables vuelven a evaluarse por reconciliación de estado aunque un trabajo haya agotado reintentos.

### 4.2 Parámetros candidatos verificables

No son SLA ni límites de producto. Arranque para medir en entorno aislado: un despachador cada minuto, lote máximo 25 agregados, presupuesto de SQL de 5 s por lote; para efectos HTTP, lote máximo 10, solicitud individual de 10 s, ejecución total inferior al límite real verificado del runtime. Lease 120 s, sin trabajo individual que supere su lease; para fases más largas, partir con checkpoints y renovar de forma autenticada. Reintentos transitorios con jitter a 1/5/15/60 min y luego cada 6 h; después de ocho fallos clasificados, revisión operativa. Medir backlog/antigüedad y ajustar antes del piloto.

Supabase Edge publica 256 MB, 150 s de wall time Free, 400 s paid y 2 s CPU por request; no asumir que la ventana total permite un parser/ZIP grande ni un loop infinito. El trabajo debe poder continuar tras una invocación que desaparece. [Límites Edge Functions](https://supabase.com/docs/guides/functions/limits).

**Gate de scheduler:** comprobar en entorno autorizado plan/extensiones/runtime, que cron hace progreso sin navegador, sobreviven jobs a reinicio, y cómo se detecta pausa/fallo. Preferencia candidata: PgCron despacha SQL y solicita procesamiento externo solo para Storage/paquetes. Alternativa si no hay cron usable: proceso supervisado en infraestructura explícitamente aprobada que llama el mismo protocolo; no instalarlo ni contratarlo desde esta nota. La reconciliación al entrar/reconectar es una reparación adicional autorizada y acotada al tablero, **no reemplaza** la ejecución autónoma aprobada.

### 4.3 Reconciliar sin resurrecciones

Consultar series con próximo instante vencido por índice, sin scan de toda la historia por cada página. Bajo lock: comprobar generación de contenido activa, tablero, serie activa, revisión, columna/miembros y exclusiones. Si pasaron diez fechas, encontrar directamente la última elegible y marcar reemplazada la pendiente anterior cuando corresponda; no crear diez pendientes ni una cascada de avisos atrasados. Una fecha borrada individualmente conserva tombstone/exclusión suficiente aun después de purgar su contenido. Restaurar padre no borra esa exclusión; restauración explícita de esa ocurrencia revierte únicamente la causa correspondiente dentro de plazo.

## 5. Archivos: contabilidad conservadora y publicación veraz

### 5.1 Reserva y carga

El ledger de producto reside en tablas propias. La cuota incluye bytes de activos + recuperables + preparados para importación + reservas pendientes, sin doble contabilizar el mismo objeto. 200.000.000 bytes globales, 24.000 bytes por archivo, 20 archivos por tarea contando recuperables. Reservas también ocupan provisionalmente un puesto para que dos cargas no eludan el límite de 20. La cuota de infraestructura y bytes huérfanos se observan aparte: ningún contador de producto certifica espacio real libre.

Reservar toma lock de contador global y tarea en orden fijo y comprueba permiso, padres activos, cupos y versión. Clave de operación repetida devuelve la misma reserva; el mismo identificador con contenido distinto es conflicto. Recomendación inicial: 5 reservas simultáneas por usuario, 20 por instancia, expiración 15 min y tasa de 30 intentos nuevos/minuto por usuario. Son parámetros de ingeniería candidatos ajustables por medición; los reintentos de una reserva existente no consumen otra.

Para archivos tan pequeños se recomienda **carga mediada por servidor**, sin entregar URL firmada de upload al navegador: autenticar, comprobar reserva, leer como máximo 24.001 bytes, validar extensión `.txt`/`.md`, UTF-8 válido y rechazar NUL/firmas binarias conocidas, verificar tamaño/hash, subir objeto inmutable privado sin upsert y confirmar publicación en DB. Si el permiso vence durante upload, no publicar y programar limpieza. MIME del cliente no es prueba de texto; no existe detector perfecto de intención, por lo que la descarga debe ser inerte incluso para texto malicioso.

La API de upload estándar está prevista para archivos pequeños. Una URL firmada de subida documentada tiene validez de dos horas y permite upload sin autenticación adicional: expiración de nuestra reserva no revoca por sí misma esa capacidad. Elegirla exigiría conservar capacidad/quarantena hasta su vencimiento más margen y probar cargas tardías; no presentarla como un token revocable de quince minutos. [Uploads estándar](https://supabase.com/docs/guides/storage/uploads/standard-uploads), [createSignedUploadUrl](https://supabase.com/docs/reference/javascript/storage-from-createsigneduploadurl).

Estados propios: reservado → recibiendo → verificado → publicado → eliminado recuperable → purga reclamada → purgado. Fallos: reserva expirada/cancelada y residuo pendiente de eliminación. Al pasar de reserva a publicado, transferir bytes reservados a activos en la misma transacción; al borrar, pasar a retenidos sin liberar espacio; restaurar transfiere retenidos a activos sin cobro adicional. Solo liberar definitivamente al confirmar inexistencia física o no materialización.

Storage tiene políticas RLS y su service key puede saltarlas: el backend privilegiado debe validar el dominio antes de actuar y no exponer la clave. Propuesta: bucket privado; usuario no inserta/borra objetos directamente, solo RPC/servidor autorizado. Las lecturas pasan por servidor con permiso vigente y sin caché privada persistente. [Control de acceso Storage](https://supabase.com/docs/guides/storage/security/access-control).

### 5.2 Descarga, purga y reconciliación

Recomendación: entregar texto como adjunto con `Content-Disposition: attachment`, `text/plain; charset=utf-8`, `nosniff`, autorización actual y no-store. Para una vista de texto en app, escapar contenido; no renderizar Markdown/HTML activo. No usar URL pública ni URL de descarga firmada longeva como permiso permanente. Lo ya descargado no se puede revocar.

El soft-delete mantiene objeto intacto hasta su `purge_after`, calculado al borrar con reloj de base. `now >= purge_after` bloquea recuperación aunque worker se haya retrasado. Purga y restauración adquieren el mismo lock y transición condicional; purga primero reclama y hace irrecuperable la entidad, después borra objeto mediante Storage API, finalmente libera ledger. Ante error conserva conteo y reintenta; no marca liberado por haber enviado una petición.

Storage documenta que borrar mediante API elimina permanentemente; borrar su fila por SQL deja el objeto físico huérfano. Por eso no se modifica directamente su esquema y no se promete atomicidad entre DB y Storage. [Borrado de objetos](https://supabase.com/docs/guides/storage/management/delete-objects), [esquema Storage](https://supabase.com/docs/guides/storage/schema/design).

Reconciliador candidato cada hora, en páginas/checkpoints: reservas vencidas; objeto sin publicación; publicación sin objeto; purge reclamada pendiente; ledger frente al inventario. No borrar por un único listado inconsistente o una petición fallida; comprobar identidad, antigüedad, lease e inexistencia de referencias/exportación/importación vivas. Mantener carga fallida como consumo reservado hasta probar que no hay objeto o borrarlo; no soltar cuota y dejar un upload tardío creando bytes sin contar. Un archivo publicado faltante provoca incidencia recuperable, no éxito ficticio ni borrado silencioso de su referencia.

Aviso del 80 % usa transición durable de contador + evento deduplicado. C-111 exige bajar del umbral y 24 h desde aviso previo para un nuevo cruce; si cruza antes de 24 h no programar un recordatorio mientras sigue encima, ya que no es otro cruce. CF-16.1/Q58 confirma que no hay aviso diferido por permanecer encima. La carga excedida responde inmediatamente al usuario, independiente del aviso al administrador.

## 6. Reemplazo de tablero: preparar primero, publicar una generación

**Candidato:** generaciones de contenido por tablero. Tablero conserva identidad, URL, propietario/membresías y puntero a generación activa. Columnas/tareas/series/etiquetas/archivos y trabajos llevan generación. Una generación preparada no aparece en listados, búsqueda, Realtime ni scheduler ordinario. Todas las rutas de lectura y escritura validan generación activa para evitar que IDs anteriores permitan modificar una copia archivada.

Estados de import: recibida → validando → preparada → esperando confirmación → publicada; alternativa fallida/cancelada/expirada. Validar y cargar objetos inmutables antes del commit visible. La previsualización captura versión de contenido del tablero y mapeo de responsables. Confirmar exige clave de operación, propietario vigente, habilitación, versión idéntica y reservas válidas; cualquier cambio de contenido obliga nueva revisión. La caducidad candidata de preparación es una hora; expirarla limpia objetos y reservas sin cambiar el tablero.

Publicación en una transacción: bloquear tablero y contador, comprobar generación/versiones/permisos/capacidad, archivar la previa por siete días y cambiar puntero a nueva; insertar reconciliaciones/avisos permitidos en el outbox. No hacer llamadas Storage dentro de esa transacción. Los bytes nuevos ya están preparados y reservados; la generación anterior sigue contando. Si falla antes del commit se sigue viendo íntegro lo anterior; si el commit ocurrió pero la respuesta se perdió, consultar operación devuelve nueva generación sin ejecutar otra importación.

Importar zona cambia el calendario de la generación nueva, con diferencia visible en preview, sin cambiar permisos. Responsables se mapean a membresías actuales verificadas, menciones quedan texto, atribución es importada y no autenticación local; series activas se reconcilian una vez, detenidas siguen detenidas y no se envían avisos históricos. Restaurar el reemplazo usa el mismo protocolo de preview/versiones/puntero y retiene también lo que reemplaza si corresponde al contrato, sin sobrescribir trabajo posterior ni superar cuota.

La publicación lógica es atómica en PostgreSQL; no implica que archivos y base compartan una transacción distribuida. Aislamiento, locks y conflictos deben probarse; errores de serialización se reintentan en toda la transacción con su misma clave. [Aislamiento PostgreSQL](https://www.postgresql.org/docs/current/transaction-iso.html).

### 6.1 Formato portable candidato y techos

Proponer formato v2 como ZIP de entradas **sin compresión** (método STORE): `manifest.json`, datos JSON por entidades/páginas y `attachments/<id opaco>`. Manifest declara versión de formato, versión del cálculo de calendario, exportación/fecha/zona y lista exacta de rutas, tamaños y SHA-256. Hash acredita integridad accidental, no confianza en autoría ni firma de usuario. Elegir biblioteca mantenida tras comprobar licencia/dependencias; no incorporar una ahora.

Rechazar entradas duplicadas, rutas absolutas, `..`, enlaces simbólicos, rutas que no coinciden con manifest, métodos de compresión no soportados, referencias inexistentes, IDs repetidos, campos prohibidos y bytes/hash incorrectos. Nunca extraer a rutas arbitrarias del host ni descargar URLs externas. Límites de ingeniería candidatos: manifest 1 MB, metadatos JSON acumulados 32 MB, 100.000 registros totales, 25.000 entradas y paquete 250 MB; todos contados también durante streaming, sin cargarlo completo en una función. Archivos internos siguen límite de 24.000/20/cuota. **Estos techos requieren benchmark y decisión técnica antes de adoptarlos**: no declarar que exportación completa funciona si datos válidos superan un techo; en ese caso bloquear rollout/ajustar formato o límites de almacenamiento con acuerdo, no truncar exportación silenciosamente.

Subir paquete/importar no es una carga de adjunto de tarea. Un ZIP de 250 MB no puede asumirse válido en una única petición serverless: usar preparación en trozos acotados y pipeline con checkpoints; el contenedor temporal no debe duplicar sin control la cuota de objetos del proyecto. Gate: demostrar estrategia de streaming/almacén temporal que cabe en runtime/plan real y no deja secretos o paquetes privados públicos. Si no cabe, el diseño no está cerrado todavía.

Exportar desde un snapshot consistente de DB: materializar manifiesto/JSON privados, fijar versiones de objetos inmutables y poner referencias temporales que eviten su purga durante empaquetado. No paginar datos vivos mezclando revisiones. Pin candidato de una hora renovable solo por export activo; vencido no alarga la recuperación del usuario. Entrega al propietario/actor autorizado nuevamente al descargar; cancelar tras pérdida de acceso y limpiar temporales. Incluir catálogo activo de etiquetas incluso sin uso, datos y actividad todavía vigentes; excluir papeleras, preferencias, vistas, novedades, admisión/permisos/tokens. Lector v1 conserva semántica/validación histórica y normaliza a pendiente/sin fecha/responsable/serie según contrato.

## 7. Respaldo operativo y recuperación de instancia

Un archivo de tablero no recupera Auth, configuración ni otras personas. Supabase documenta que sus backups de base **no incluyen bytes de objetos Storage** y recomienda exportaciones externas para Free; también distingue retenciones de backups pagos. No asumir backups diarios disponibles en la cuenta. [Backups Supabase](https://supabase.com/docs/guides/platform/backups).

Artefacto operativo candidato: dump consistente de esquema/datos/roles necesarios con versión de herramienta y migraciones; inventario de objetos con rutas/versiones/hash y copias; manifiesto de configuración (buckets, Auth/OAuth URLs, RLS, canales, cron, secretos requeridos por nombre y forma de restauración); registro de versión de app. Secretos reales se respaldan por un canal seguro separado y autorizado, nunca en repo, informe, issue ni paquete portable. La guía CLI requiere tratar roles/políticas gestionadas y configuración de funciones explícitamente: un dump genérico no demuestra restauración completa. [Backup y restore CLI](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore).

Primer procedimiento proporcional: ventana de mantenimiento que pausa publicaciones/purgas, registra checkpoint y copia base + inventario/objetos + configuración antes de reabrir. Para quitar mantenimiento después, necesitaríamos protocolo probado de snapshots/pins/versiones; no llamar consistente a dos copias independientes que cambian mientras se crean. Almacén externo privado, cifrado y retención concreta deben ser acordados y verificados antes de operar; esta nota no selecciona proveedor, compra ni instala destino. RPO/RTO se miden con ensayo y frecuencia autorizada: no prometer cero pérdida ni minutos de recuperación.

Restauración de prueba en destino aislado sin conexión a usuarios: restaurar configuración/datos/objetos según dependencias, deshabilitar despachador y salida de avisos, revisar claves y callbacks del entorno, comprobar roles/permisos/canales privados y ledger. Antes de habilitar jobs ejecutar modo diagnóstico para trabajos antiguos; leases previos expiran y versiones/claves no se pierden. Verificar objetos con hashes, conteos por entidad y vínculos, cuotas, series, exclusiones, restauraciones y contenido archivado; no basta con que termine el comando SQL. El rollback nunca reabre RPC anónimas.

## 8. PWA online y caché privada

Next documenta manifest mediante App Router; su ejemplo incluye otras capacidades que no aprobamos por asociación. Candidato mínimo: manifest/iconos/instrucciones y detección de versión disponible; si se necesita service worker para experiencia de actualización, caché con allowlist únicamente de recursos estáticos públicos versionados. [Guía PWA Next.js](https://nextjs.org/docs/app/guides/progressive-web-apps).

No almacenar HTML/RSC autenticado, consultas/API, adjuntos, paquetes, credenciales ni respuestas de errores con contenido privado en Cache Storage, IndexedDB, localStorage o caché compartida del servidor. Fetch privado y respuestas privadas con `Cache-Control: private, no-store`; verificar también CDN/SSR/RSC y cualquier caché de consulta cliente. HTTP no-store no sustituye las decisiones del service worker: Cache API es un almacén manejado por script que debe excluir estas rutas. [Cache-Control](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control), [modelo de Service Workers W3C](https://www.w3.org/TR/service-workers/).

Logout/cambio de cuenta/revocación incrementan época de sesión, abortan requests y descartan respuestas tardías; limpian estado privado en memoria, selección, detalle, resultados y borradores según autorización. Revalidar al reconectar y al volver del segundo plano antes de presentar contenido como actual. Borrador autorizado vive en sesión en memoria, sin promesa tras cierre; ninguna cola de mutaciones offline. Pantalla offline genérica sin tareas cacheadas. Back/forward cache y pestañas abiertas requieren prueba de retorno y cambio de cuenta: no afirmar que no-store elimina universalmente capturas del sistema o archivos descargados.

Actualización avisa y espera elección; Guardar/Descartar/Seguir editando según C-109. No `skipWaiting`/recarga forzada que quite borradores ni worker viejo incompatible con API nueva sin estrategia de compatibilidad. Versionar esquema de caché pública y retirar la anterior al activar de forma segura; no borrar almacenamiento Auth a ciegas. Matriz de dispositivos/versiones acordada sigue siendo gate de prueba real.

## 9. Escenarios para convertir en tickets y evidencia

Estos son criterios propuestos de ingeniería, **no pruebas ejecutadas**. Reutilizar SQL descartable para invariantes; Auth/Storage/cron requieren Supabase local o entorno aislado explícito además de navegador y dobles de fallo controlados.

| ID | Estímulo reproducible | Resultado exigido |
| --- | --- | --- |
| DUR-01 | Rollback del cambio, caída tras commit y dos consumidores | Rollback no deja efecto pendiente; commit sí; un resultado de negocio aunque se procese dos veces. |
| DUR-02 | Lease vence y worker viejo confirma después | Token viejo rechazado; nuevo consumidor completa sin duplicación. |
| DUR-03 | Editar/detener/borrar serie mientras job está reclamado | Revalidación cancela efecto obsoleto; no vuelve una ocurrencia borrada ni cambia actual protegida. |
| DUR-04 | Reloj avanza meses con exclusiones/conteo finito | Como máximo última vigente válida, sin pila ni extensión de N; fin excluido sin sustituta. |
| DUR-05 | Zonas con distinto día, DST, febrero y ordinales | Preview/validar/ejecutar iguales con reloj explícito; sin fecha del navegador ni suma de segundos. |
| DUR-06 | Restaurar padre con hijo individualmente borrado/purgado | Conserva su exclusión; solo recuperación individual vigente puede revertir su causa. |
| DUR-07 | No hay navegadores, falla cron y luego vuelve | Evidencia de progreso autónomo en entorno elegido, backlog diagnosticable y reconciliación convergente; medir demora sin inventar SLA. |
| FILE-01 | 24.000/24.001 bytes, binario renombrado, HTML/Markdown malicioso | Límites exactos; rechazo de binario; texto servido inerte sin ejecución ni preview remoto. |
| FILE-02 | Dos usuarios compiten por último byte/puesto | Una reserva válida; otra rechazada; reintento misma operación no cobra otra vez. |
| FILE-03 | Permiso revocado después de subir antes de publicar | No visible, no enlace reutilizable; residuo contado hasta limpieza confirmada. |
| FILE-04 | Timeout de upload/delete, proceso muerto, inventario parcial | Reconciliar antes de repetir; sin doble consumo ni liberación prematura; faltantes visibles como incidencia. |
| FILE-05 | Restaurar y purgar exactamente al vencimiento | Un ganador por lock/transición; pasada frontera nunca restaura aunque objeto exista. |
| FILE-06 | Cruces 80 %, bajar/subir y 24 h con reloj controlado | Avisos deduplicados y rearme C-111, bloqueo de carga siempre inmediato; admin no lee archivos ajenos. |
| IMP-01 | Fallo después de cada fase de preparación/publicación | Tablero completo previo o nuevo; nunca parcial; cada residuo trazable y recuperable. |
| IMP-02 | Otro miembro edita tras preview y propietario reintenta | Conflicto conserva cambios; revisión nueva; resultado incierto consultable por clave. |
| IMP-03 | Previo + nuevo exceden cuota, y reemplazo de reemplazo | Rechazo antes de cambiar puntero; ningún resguardo anterior se purga anticipadamente. |
| IMP-04 | Archivo v1/v2, relaciones corruptas, objeto faltante, rutas maliciosas | Validación total; v1 compatible; v2 roundtrip conserva entidades sin permisos ni avisos falsos. |
| IMP-05 | Exportar mientras paginan/editan/purgan | Snapshot completo consistente, sin truncar por filtros/página; objetos fijados y hash comprobado. |
| BAK-01 | Restaurar backup en destino limpio aislado | Base+objetos+config coinciden, permisos cerrados, jobs inicialmente detenidos, mediciones RPO/RTO publicables sin secretos. |
| PWA-01 | A abre tablero, logout, B login, Atrás/reconexión y respuesta tardía | B nunca recibe contenido A; caches privadas vacías y estados antiguos descartados. |
| PWA-02 | Offline en app instalada y actualización con borrador | Mensaje sin datos cacheados/cola de escritura; actualización elegida sin perder edición. |

## 10. Cierre técnico antes de implementación autónoma

Esta investigación reduce alternativas, pero no certifica un sistema listo. Para que un agente implemente en loop sin inventar decisiones: registrar ADR sobre motor canónico de calendario, protocolo de jobs, generaciones/paquetes, cargas mediadas y caché; congelar esquema/versiones/errores y parámetros operativos iniciales; preparar fixtures/fallos de la tabla; hacer tickets con dependencias; dejar gates operativos fuera del cierre automático hasta que exista evidencia real del entorno y aprobación de acciones remotas necesarias.

El agente puede desarrollar y probar localmente los contratos una vez autorizado. No puede marcar completos scheduler, exportación de volumen máximo, recuperación de instancia o compatibilidad móvil por haber escrito código o leído estas páginas. No se rebajan P/E por una limitación del hosting: si una prueba de viabilidad falla, se registra el bloqueo concreto y se elige una alternativa autorizada antes de declarar terminado el objetivo.
