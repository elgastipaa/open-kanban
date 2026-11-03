# Matriz única de permisos — OpenKanban Personal 1.0

Actualización documental C-100–112 (27/10/2026): calendario CF-04/07/09, avisos/cuota/enlaces CF-15/16/18, preferencias/búsqueda CF-13–14 y ampliaciones CF-22–27. Complementa revisión base; todas las P/E se conservan.

Consolidación vigente27/10/2026: C-112 resuelve los dos huecos funcionales de auditoría; [DT-0.1](./DISENO-TECNICO-MVP-1.0.md) fija diseño recomendado y verificaciones G01–G08 pendientes. Los registros de revisiones anteriores son antecedentes, no nuevas preguntas de producto.

Estado: **revisión 0.3, permisos C-94/C-98 y ampliación C-99 integrados; detalles abiertos señalados expresamente; solo spec, no autorización para implementar**.

Aceptación C-99: 24 de octubre de 2026. Consolidación documental: 25 de octubre de 2026.

Fuentes: MVP 1.0, acuerdos C-01–112 en spec 0001, Cierre funcional, Pantallas y [propuestas de Plane aceptadas en C-99](./PROPUESTAS-DESDE-PLANE.md). Esta matriz reemplaza las tablas parciales de permisos de esos documentos. C-99 incorpora P01–P26 y E01–E07 al alcance actual, incluidas las precisiones presentadas; no resuelve por inferencia los puntos que el anexo dejó por cerrar. No contiene SQL ni afirma que la app desplegada ya cumpla estos permisos. La app original sigue pendiente de corte a acceso privado.

## 1. Cómo leerla

- **A:** regla acordada o consolidación directa del modelo acordado. Referencias C o sección de spec en cada bloque.
- **P:** detalle pendiente de aprobación, identificado en su fila o como MP al final. Que una capacidad esté aprobada no concede un permiso granular todavía abierto. Mientras siga abierto no se implementa ni se trata como permiso concedido.
- **Sí:** únicamente dentro del alcance y condiciones de la fila; no autorización global por conocer un ID.
- **No:** denegado. Toda acción no concedida expresamente se deniega por defecto; un diseño pendiente no se resuelve con acceso abierto.

Roles separados:

| Actor | Significado |
| --- | --- |
| Sin sesión | Visitante anónimo. Puede llegar a login/documentos públicos necesarios, no usar datos de producto. |
| No habilitado / suspendido | Google puede identificarlo, pero no tiene admisión vigente. No puede usar producto aunque conserve tokens o antigua membresía. |
| Habilitado ajeno al tablero | Usa la app y crea sus propios tableros; no accede al tablero ajeno. |
| Propietario | Miembro habilitado que tiene propiedad actual de ese tablero. Un dueño válido por tablero activo. |
| Colaborador | Miembro habilitado del tablero, con edición compartida pero sin administración de membresía. |
| Administrador global | Gestiona admisión y excepciones administrativas acordadas. No es miembro ni lector automático de todos los tableros. |

Un administrador que además sea colaborador/propietario utiliza los permisos de ese rol para leer/editar contenido. En las tablas, **Admin ajeno** significa que no es miembro del tablero. Ser autor de tarea/comentario, responsable, expropietario o poseer una URL no sustituye membresía vigente. La cuenta operadora de infraestructura no es un rol de usuario del producto ni una promesa de cifrado frente a ese operador.

## 2. Acceso global y datos personales

| ID | Acción | Sin sesión | No habilitado / suspendido | Habilitado común | Admin habilitado | Estado / fuente |
| --- | --- | --- | --- | --- | --- | --- |
| G-01 | Autenticarse/cambiar cuenta/cerrar sesión | Entrar con Google | Sí, solo gestión de sesión | Sí | Sí | A, C-01/C-93. Autenticar no habilita. |
| G-02 | Crear un tablero privado propio | No | No | Sí | Sí | A, C-23/C-93. Crear explícitamente; URL visitada no crea. |
| G-03 | Crear/publicar tablero anónimo o público | No | No | No | No | A, C-17/C-93. No es una opción de configuración. |
| G-04 | Habilitar, suspender o rehabilitar acceso a la app | No | No | No | Sí | A, C-22/C-71. Resolver tableros propios y asignaciones en retirada. |
| G-05 | Listar personas habilitadas y sus estados para administración | No | No | No | Sí | A, administración mínima; solo datos necesarios. No directorio global para colaboradores. |
| G-06 | Aceptar invitación de tablero vigente | No, primero login | No | Sí, según destinatario/modalidad | Sí, mismas condiciones | A, C-08/C-71/C-97. Directa solo destinatario; genérica habilitado con enlace. Un uso/72 h/revocable; no eleva admisión. |
| G-07 | Ver Mis tareas, Series y búsqueda | No | No | Solo datos autorizados | Solo datos autorizados | A, C-30/C-42/C-57. Admin no elude alcance. |
| G-08 | Leer/marcar novedades y guardar preferencias | No | No | Solo propias | Solo propias | A, C-56/C-70/C-83/C-99. Incluye lote visible autorizado de E07; nadie marca leída la bandeja ajena. |
| G-09 | Delegar administración global, crear roles personalizados | No | No | No | Fuera de alcance MVP | A, modelo cerrado; no segundo administrador por accidente. |
| G-10 | Marcar/desmarcar tableros favoritos | No | No | Solo propios favoritos de tableros accesibles | Igual que cualquier habilitado | A, C-99/P13. No cambia orden ni preferencias de otros; perder membresía retira nombre/acceso de Favoritos. |
| G-11 | Crear, consultar, editar o eliminar vistas personales guardadas | No | No | Solo propias, resultados autorizados | Solo propias, resultados autorizados | A, C-99/E02. Guarda filtros/orden, no copias ni permisos. C-100: 50 vistas activas/persona, nombres hasta 60 caracteres únicos por contexto y edición explícita; C-101: referencia explícita inválida bloquea hasta revisar/confirmar, recuperación siete días solo usuario y conflicto sin sobrescritura; no vistas compartidas/públicas. |
| G-12 | Elegir tema claro/oscuro/sistema y preferencias entre dispositivos | No como datos de cuenta | No como datos de cuenta | Solo propias | Solo propias | A, C-99/P06/E03. No tema por tablero; presentación previa a login no concede lectura de preferencias privadas. |

Cierre de sesión no borra cuenta ni implica salir del tablero. Rehabilitar globalmente no restaura membresías/roles/asignaciones retirados. Nueva incorporación exige membresía explícita y no activa menciones viejas ni avisos del período afuera (C-81).

## 3. Tablero y trabajo compartido

Para todas estas acciones, anónimo/no habilitado/suspendido/ajeno común = **No**. Se requiere objeto del tablero autorizado y estado que permita la acción; una tarea eliminada no se edita como activa.

| ID | Acción | Propietario | Colaborador | Admin ajeno | Estado / condiciones |
| --- | --- | --- | --- | --- | --- |
| B-01 | Leer tablero, columnas, tareas, historial, comentarios y archivos activos | Sí | Sí | No | A, C-23. Miembros ven tablero completo; no tarjetas secretas. |
| B-02 | Ver lista de miembros para colaborar/asignar | Sí | Sí | Solo metadatos administrativos necesarios, no vista normal | A; admin necesita elegir sucesor, alcance exacto en MP-04. |
| B-03 | Crear/renombrar/ordenar columnas | Sí | Sí | No | A, matriz previa MVP §5. Sin flujo obligatorio. |
| B-04 | Eliminar columna | Sí | Sí | No | A, C-36/C-76. Resolver destino de tareas/series y confirmar, no borrado masivo implícito. |
| B-05 | Crear/editar/reordenar/mover tareas entre columnas del mismo tablero | Sí | Sí | No | A, C-07/C-27. No depende de autor/responsable. |
| B-06 | Completar tarea o reabrir desde detalle | Sí | Sí | No | A, C-48/C-54/C-74. Confirmación por pasos pendientes; antigua de serie no vuelve a pendiente. |
| B-07 | Asignar/desasignar responsable | Sí | Sí | No | A, C-06/C-07/C-69. Cero/uno, miembro actual habilitado; no asignar por nombre libre. |
| B-08 | Crear/editar/reordenar/marcar/borrar pasos | Sí | Sí | No | A, checklist y edición general. Sin permisos independientes por paso. |
| B-09 | Crear/editar serie y columna de aparición futura | Sí | Sí | No | A, C-32/C-34/C-42. Cambios futuros no reescriben actual/historial. |
| B-10 | Dejar de repetir / eliminar ocurrencia / eliminar serie | Sí | Sí | No | A, C-33/C-35, MVP §8.4. Elección de alcance y ventana de recuperación; detener no borra. |
| B-11 | Borrar tarea puntual | Sí | Sí | No | A, edición general y contrato de borrado de tareas. Recuperable 7 días. |
| B-12 | Crear/editar/borrar cumpleaños del tablero | Sí | Sí | No | A, edición compartida + C-75. No casilla de completado. |
| B-13 | Editar configuración compartida: nombre/propiedades y zona horaria | Sí | No | No | A, MP-01/C-94. Cambio de nombre y zona exclusivo del propietario; otros ajustes deben tener contrato definido. |
| B-14 | Administrar invitaciones directas/genéricas; retirar colaboradores | Sí | No | No por esta vía | A, C-23/C-97. Destinatario puede ver/aceptar/rechazar su propia directa sin ser aún miembro, no administrar invitaciones del tablero. Admin suspende globalmente o reasigna por vías administrativas explícitas. |
| B-15 | Eliminar tablero por acción ordinaria | Sí | No | No | A, matriz previa §5. Excepción administrativa sin otros miembros en sección 6. |
| B-16 | Exportar tablero completo autorizado | Sí | Sí | No | A, matriz previa §5/C-92. Exportación puede contener copia de archivos; no se puede revocar copia descargada. |
| B-17 | Importar/reemplazar contenido o recuperar previo a importación | Sí | No | No | A, C-92. Vista previa, validar cuota y autoridad actual; archivo no restaura permisos. |
| B-18 | Salir como colaborador | No aplica al dueño: B-19 | Sí | No aplica | A, C-71/C-81. Desasignación y menciones a texto. |
| B-19 | Transferir a sucesor y salir como propietario | Sí, sucesor obligatorio | No | No por esta vía | A, C-80. Elegir otro miembro habilitado; no salida sin elegir. |
| B-20 | Trasladar una tarea a otro tablero | No incluido | No incluido | No incluido | A, C-27 limita a columnas. No habilitarlo indirectamente cambiando board_id. |
| B-21 | Copiar enlace privado a tarea u ocurrencia concreta | Sí | Sí | No | A, C-99/P11. No invita ni concede acceso; destino revalida membresía. Sin título/previsualización pública. |
| B-22 | Duplicar tarea como puntual en el mismo tablero | Sí | Sí | No | A, C-99/E04 y B-05. Nueva identidad pendiente; copia título/descripción/prioridad/checklist sin marcar. Sin responsable, fecha, serie, comentarios, archivos ni permisos heredados. C-101: copia activas del origen, no de plantilla. C-104: permite completadas/históricas autorizadas sin editar fuente; eliminadas requieren recuperación y cumpleaños no son tareas duplicables. |
| B-23 | Consultar catálogo de etiquetas y filtrar tareas del tablero por ellas | Sí | Sí | No | A, C-99/E01 y alcance de B-01. Etiquetas planas de ese tablero; no catálogo global ni lectura cruzada. |
| B-24 | Crear/renombrar/cambiar color y aplicar/quitar etiquetas del tablero en tareas, cumpleaños y plantilla de serie | Sí | Sí | No | A, C-100/Q1–3; selección con Guardar, catálogo separado. Renombrar conserva identidad/asociaciones/filtros. |
| B-24b | Eliminar etiqueta del catálogo del tablero | Sí | No | No | A, C-100/C-101. Ocultar, conservar asociaciones para recuperación siete días y luego purga; no borrar elementos. |
| B-25 | Leer actividad mínima de una tarea | Sí, con acceso vigente | Sí, con acceso vigente | No | A, C-99/E05. Responsable/fecha/columna/completado/recuperación con actor y fecha; C-105: 180 días, ocultar con tarea, recuperar solo vigentes y purga dependiente. No edición de eventos ni restauración de valores desde historial. |

Vista Mis tareas no es un rol adicional: completar/editar usa B-05/B-06 del origen. Ser responsable no da edición exclusiva ni concede membresía. Mover/crear objetos con IDs de columna/serie de otro tablero se deniega aunque el usuario sea miembro de ambos: el contrato no incluye traslado entre tableros.

Español, búsqueda por Ctrl/Cmd+K, temas e instalación PWA cambian presentación o acceso al mismo producto; no agregan roles. La PWA conserva login/habilitación/membresía y funcionamiento online. Una vista guardada, favorito, enlace o evento de actividad tampoco constituye una concesión persistente de acceso.

## 4. Conversaciones, archivos y moderación

| ID | Acción | Propietario miembro | Colaborador miembro | Admin ajeno | Estado / condiciones |
| --- | --- | --- | --- | --- | --- |
| F-01 | Comentar / mencionar | Sí | Sí | No | A, C-50/C-77. Mencionar solo actuales; texto pasado de retirados sin vínculo. |
| F-02 | Editar comentario | Solo si es autor | Solo si es autor | No | A, C-77. Ser dueño/admin no autoriza reescribir texto ajeno. |
| F-03 | Borrar comentario propio | Sí | Sí | No | A, C-77. Solo mientras mantiene acceso. |
| F-04 | Borrar comentario de otra persona | Sí, moderación | No | No | A, C-77. Confirmar y registrar alcance; no es edición de autoría. |
| F-05 | Subir adjunto permitido a tarea | Sí | Sí | No | A, C-50/C-61/C-82/C-99/P22. Reservar/cargar/verificar/publicar revalida permiso; máximo 24.000 bytes, 20 por tarea incluidos recuperables, 200.000.000 bytes globales contando reservas/activos/recuperables. |
| F-06 | Descargar adjunto activo | Sí | Sí | No | A, C-57. Validación vigente; no bucket público. Descargas previas no pueden retirarse. |
| F-07 | Borrar adjunto propio subido por el actor | Sí | Sí | Solo excepción administrativa F-09 | A, MP-03/C-94; propietario conserva limpieza de cualquier adjunto del tablero. |
| F-08 | Borrar/seleccionar adjuntos ajenos del tablero para limpieza | Sí | No | Solo F-09 | A, C-65. No borrar tarea ni completar por borrar archivo. |
| F-09 | Limpieza administrativa global de adjuntos | Según membresía o facultad admin separada | No por rol colaborador | Sí, selección explícita y metadatos mínimos | A, C-65; límites de información MP-04. No lectura/descarga implícita. |
| F-10 | Borrar definitivamente antes de 7 días / forzar cupo | No | No | No | A, C-58/C-64/C-82. Solo purga controlada después de plazo. |
| F-11 | Cambiar autor de comentario/atribuir archivo a otra identidad | No | No | No | Regla de integridad del modelo. Importación usa atribución histórica, no suplantación. |

F-07 confirma borrado propio por el subidor miembro y limpieza por el propietario. Una decisión sobre borrado directo de archivos no puede ser evadida a través de APIs de upload/replace. El borrado de tarea/serie por colaboradores sí elimina su contenido dependiente dentro del alcance confirmado; esta matriz no promete a un comentario retención independiente frente al borrado autorizado de su tarea.

## 5. Recuperación: ventana, actor y motivo de borrado

Toda recuperación exige plazo no vencido, objeto/antecesores válidos y autorización **actual**, no la que el actor tenía cuando borró. Leer contenido de recuperación también exige permiso; no listar texto de un comentario moderado a un autor sin permiso para restaurarlo. Fuera de ventana nadie puede restaurar desde la app aunque aún exista una copia pendiente de purga. No restaurar membresías/invitaciones ni menciones activas antiguas.

| ID | Objeto / causa | Quién podría recuperar | Estado / referencia |
| --- | --- | --- | --- |
| R-01 | Tarea, paso, serie o columna borrados ordinariamente | Propietario o colaborador actual con permiso de edición; no solo quien borró | A, C-94/C-110; siete días y padres/destinos válidos. Recuperar columna no revierte traslados; moderación/limpieza administrativa conservan restricciones. |
| R-02 | Tablero borrado por propietario que sigue habilitado y conserva propiedad de recuperación | Propietario actual de recuperación | A, C-98. No restauración por cualquier exmiembro. |
| R-03 | Tablero eliminado al retirar a dueño sin otros miembros | Administrador elige nuevo dueño habilitado y lo incorpora explícitamente | A, C-59/C-76. Operación administrativa no abre contenido al admin por defecto. |
| R-04 | Comentario borrado por su autor | Autor si sigue miembro, o propietario actual | A, C-98; plazo confirmado. |
| R-05 | Comentario borrado por propietario como moderación | Solo propietario actual, no su autor ni anterior dueño sin rol | A, C-77. Identificar «propietario actual» evita privilegio perpetuo al moderador anterior. |
| R-06 | Archivo borrado por subidor | Subidor si sigue miembro, o propietario actual | A, C-98. |
| R-07 | Archivo eliminado por propietario como moderación/limpieza | Solo propietario actual | A, MP-02/C-94. No reintroducir por subidor un archivo retirado por propietario. |
| R-08 | Archivo borrado por limpieza administrativa | Solo administrador habilitado, verificando tablero/restauración/destino válidos | A, MP-02/C-94; metadatos mínimos MP-04. No puede leer contenido para decidir si no es miembro. |
| R-09 | Contenido previo reemplazado por importación | Propietario actual; vista previa y confirmación de lo que reemplazará al recuperar | A, C-92. No borra trabajo posterior sin explicitar alcance; mecanismo técnico pendiente. |
| R-10 | Etiqueta eliminada del catálogo | Solo propietario actual habilitado del tablero | A, C-101/Q8. Recuperable siete días con acceso/destino válidos; C-102: exigir cupo activo, resolver nombre y confirmar asociaciones válidas; sin omisiones silenciosas. |
| R-11 | Vista personal eliminada | Solo su usuario habilitado | A, C-101/Q13. Recuperable siete días; revalidar referencias/permisos. Referencia inválida deja pendiente de revisión; no restaurar tareas ni permisos. |

Restaurar una columna no deshace traslados ya confirmados; tarea requiere columna válida; serie activa se reconcilia sin atrasos acumulados. Una ocurrencia histórica recuperada no se convierte en vigente si ya hay otra posterior. Si el padre está borrado, primero recuperar padre con autoridad correspondiente, no usar restauración de hijo como bypass. Cada borrado independiente conserva su plazo; restaurar padre no revive hijos ya borrados separadamente.

**C-98 aprobado:** retirada del propietario mientras su tablero ya está eliminado/recuperable incluye ese tablero en el inventario administrativo; resolver autoridad de recuperación válida sin activar el tablero ni reiniciar plazo. No depender de identidad suspendida ni extender retención. Mecanismo técnico pendiente.

## 6. Facultades administrativas y propiedad

| ID | Operación administrativa | Actor | Alcance y límites | Estado |
| --- | --- | --- | --- | --- |
| A-01 | Retirar acceso global | Admin habilitado | Impedir uso; desasignar pendientes/futuras, desvincular menciones, resolver propiedad por tablero. Conservar autorías. | A, C-22/C-59/C-69/C-77. |
| A-02 | Reasignar propietario de tablero | Admin habilitado | Elegir miembro habilitado; excepción de recuperar tablero sin miembros incorpora nuevo dueño explícito. Sin lectura automática de tareas. | A, C-72/C-80, elegibilidad detallada en MP-04. |
| A-03 | Eliminar tablero al retirar dueño y no quedar miembros elegibles | Admin, como efecto explícitamente confirmado de retirada | 7 días recuperable; no facultad genérica de borrar cualquier tablero ocupado. | A, C-59. |
| A-04 | Rehabilitar identidad | Admin habilitado | Habilitación global, no restaurar roles/membresías/asignaciones antiguas ni entregar avisos retroactivos. | A, C-81. |
| A-05 | Ver capacidad global y limpiar adjuntos | Admin habilitado | Solo metadatos mínimos y acciones F-09; selección/confirmación; no descargar archivos ajenos. | A, C-65; granularidad MP-04. |
| A-06 | Reparar tablero activo sin dueño válido | Operación controlada del sistema, no botón de salir sin sucesor | Elegible de mayor antigüedad en tablero; sin candidato, cerrar uso y resolver caso de recuperación. Registro y aviso a admin. | A, C-80; implementación técnica pendiente. |
| A-07 | Autoasignarse miembro/lector de todos los tableros | Nadie por defecto | Administración no crea membresía global. Una concesión explícita válida de propiedad es otro acto, registrado. | A, C-23/C-72. |
| A-08 | Autoeliminar único administrador o delegar su rol | Sin flujo en MVP | Proteger la única identidad administradora de autosuspensión accidental; sin delegación en MVP. Recuperación operativa pendiente de diseño. | A, MP-05/C-94. |

El admin controla infraestructura y reasignación acordada: no prometer que jamás podrá obtener acceso por una transferencia explícita de propiedad. Sí exigir que no haya lectura invisible automática por el rol global. No introducir un rol delegado o superusuario oculto como solución a una falta de autorización.

## 7. Revocación, estados y condiciones transversales

1. Toda lectura/mutación valida sesión, habilitación y alcance del objeto en el servidor/base. El cliente no suministra una propiedad/rol confiable. Acciones de administración validan facultad global y su alcance estrecho, no membresía ficticia.
2. Estado bloquea operaciones ordinarias: tablero/serie eliminados no se editan ni ejecutan como activos; solo recuperación autorizada. Una tarea vencida sigue editable/completable; antigua ocurrencia no puede reabrirse aunque el actor sea dueño.
3. Retirada de membresía o suspensión revoca solicitudes y eventos futuros. Debe probarse con sesiones, descargas y canales ya abiertos y cliente no cooperativo. Diseñar invalidación real; esconder pantalla o pedir desconexión al cliente no basta.
4. Copias ya descargadas no se revocan. Si se usan enlaces temporales de archivos, especificar y limitar exposición residual; no declarar revocación instantánea de un enlace firmado sin una solución verificada.
5. Mis tareas, Series, búsqueda, conteos, notificaciones y caches respetan acceso actual. No descargar datos ajenos para ocultarlos después ni revelar títulos mediante error, URL, preview o logs públicos.
6. Una acción iniciada antes de perder rol revalida al confirmar. Retirada frente a asignación, aceptación simultánea de invitación, restauración frente a purga y salida simultánea de sucesores requieren resultado consistente, sin privilegios viejos ni doble efecto.
7. Salida del dueño normal exige sucesor. Si el elegido deja de ser miembro, bloquear y pedir otro; no usar reparación automática como sustitución silenciosa de la elección. La reparación por antigüedad es excepcional y observable.
8. Recuperación/importación no concede permisos; exportación entrega copia privada irreversible desde la app. No usar estos flujos como bypass de moderación o cuotas. Un usuario retirado no puede borrar su antiguo comentario alegando autoría.
9. Preferencias y novedades son de su usuario. Admin no las lee ni modifica para otro por su rol. Caducidad de avisos leídos/no leídos a 90 días no toca datos de trabajo.
10. Procesos internos (series, purga, cuotas, avisos) tienen alcance acotado a reglas y estados autorizados, no derechos heredados del antiguo creador. No exponer credenciales privilegiadas al frontend. Elección del mecanismo es trabajo técnico pendiente.
11. C-99/P16–P17: cada acción tiene campos editables explícitos y valida referencias de tablero/columna/serie/persona; autoría, propietario, rol y demás campos protegidos no se aceptan del cliente. Rechazarlos no deja cambios parciales. Repetir las pruebas entre dos tableros y con identificadores manipulados en consulta, API/RPC, canal y archivo.
12. C-99/P18–P20: comprobar versión de campos y reconciliar claves de operación/reintentos; comentarios, pasos y archivos no invalidan por sí solos la versión de esos campos. Realtime avisa de cambios y obliga a reconciliar datos autorizados; no confiere permisos ni sustituye persistencia. Descartar respuestas/cachés de otra sesión sin pisar borradores todavía autorizados.
13. C-99/P19/P21/P22: efectos de fondo durables y reintentables, borrados con causa/actor/plazo/dependencias y ciclo de reservas de archivos. Confirmación y procesamiento comprueban su alcance vigente; ningún job restaura accesos antiguos ni libera cuota de objetos aún recuperables. Mecanismos concretos pendientes de diseño/verificación.
14. C-99/E07: marcar leídas exige conjunto explícito de novedades cargadas y autorizadas de la propia persona, mostrando cantidad. No alcanza páginas no cargadas ni novedades futuras; revalidar al aplicar y explicar resultados parciales sin revelar objetos inaccesibles.
15. C-99/P11/P13/E02/E05/E06: enlaces, favoritos, vistas, actividad y caché PWA respetan revocación/cambio de cuenta. La instalación no habilita uso offline duradero ni colas de edición; no mostrar contenido de otra cuenta desde caché. Definir estrategia de caché antes de declarar segura la instalación.

## 8. Casos de aceptación de autorización

Preparar fixtures con: anónimo, Google no habilitado, suspendido con token previo, habilitado ajeno, propietario, dos colaboradores (autor/responsable y otro) y administrador sin membresía. Repetir casos relevantes con admin como colaborador y como propietario: esa combinación no aumenta facultades de edición de comentarios ajenos.

| ID | Escenario | Resultado esperado |
| --- | --- | --- |
| PERM-01 | Anónimo abre raíz/URL inventada o invoca crear directamente. | Login sin creación/lectura; no nace tablero por visitar URL. |
| PERM-02 | Google no habilitado intenta invitación/API. | Denegación, sin consumir invitación ni adquirir membresía. |
| PERM-03 | Habilitado ajeno usa ID de tablero/tarea/archivo. | Sin lectura/escritura/listado/conteo ni título filtrado. |
| PERM-04 | Colaborador edita/completa tarea asignada a otro. | Permitido dentro del mismo tablero y reglas de negocio. |
| PERM-05 | Colaborador importa, elimina tablero o invita directamente. | Denegado sin efectos parciales. |
| PERM-06 | Propietario o admin miembro intenta reescribir comentario ajeno. | Denegado; propietario puede moderar por vía de borrado, no atribuir texto. |
| PERM-07 | Admin ajeno lee/exporta/descarga contenido del tablero. | Denegado; solo facultades administrativas específicas permiten metadatos/acciones acotadas. |
| PERM-08 | Miembro retirado con sesión/canal abiertos y archivo temporal. | No nuevas operaciones/eventos privados; exposición residual de archivo cumple contrato verificado. Copias previas explícitamente fuera de control. |
| PERM-09 | Retirada y asignación al retirado concurrentes. | Pendientes/futuras sin asignación inelegible; contenido conservado. |
| PERM-10 | Dos personas consumen mismo enlace. | Solo una nueva membresía; una persona no habilitada no consume el enlace. |
| PERM-11 | Dueño intenta salir sin sucesor o con sucesor retirado. | Bloquear salida, no tablero activo huérfano ni asignación normal automática. |
| PERM-12 | Simular inconsistencia de dueño fuera de flujo normal. | Reparación controlada por antigüedad elegible; sin candidato, cierre seguro y resolución administrativa. |
| PERM-13 | Exmiembro reingresa. | Permisos nuevos explícitos; menciones viejas texto, sin asignaciones/restauraciones/avisos retroactivos automáticos. |
| PERM-14 | Autor restaura comentario moderado por dueño. | Denegado; propietario actual puede restaurar en plazo. |
| PERM-15 | Recuperar hijo con padre eliminado o expirado. | No bypass; exigir resolver padre/plazo/autoridad correspondiente. |
| PERM-16 | Importación incluye miembros/roles/autoría falsificada y archivos prohibidos. | No eleva permisos ni suplanta identidad; rechazo/mapeo explícito antes de reemplazo. |
| PERM-17 | Dos cargas compiten por plaza 20 o cuota global. | Como máximo admisiones válidas; recuperables cuentan; ningún cambio de rol salta cuota. |
| PERM-18 | Limpieza administrativa vs lectura privada. | Solo selección autorizada por metadatos; tarea permanece y archivo recuperable sigue contando. |
| PERM-19 | Restauración/purga o importación/edición concurrentes. | Resultado único, no mitad de tablero ni resurrección fuera de plazo. |
| PERM-20 | Actor cambia board_id/column_id/series_id para apuntar otro tablero. | Denegar combinación inválida, incluso si tiene membresía en ambos. |
| PERM-21 | Petición de preferencias/novedades de otro usuario. | Denegar, incluido admin global. |
| PERM-22 | Usuario intenta abrir/guardar tras cambio de cuenta. | No aparecen caches, borradores o resultados privados de la cuenta anterior. |
| PERM-23 | Ajeno/admin no miembro abre enlace privado de una tarea o de una ocurrencia histórica. | Login y autorización según corresponda, sin título/preview ni sustitución por otra tarea; URL no invita ni concede membresía. |
| PERM-24 | Consultar/alterar favorito, vista guardada o tema de otra persona; revocar tablero presente en una vista propia. | Datos personales aislados, incluido admin. Ningún resultado/nombre privado permanece accesible por favorito/vista; C-101: referencia explícita inválida bloquea hasta revisar/confirmar, sin nombres privados; global dinámico se adapta. |
| PERM-25 | Duplicar tarea con responsable, serie, comentarios y archivos; retirar permiso antes de confirmar. | Solo copia permitida de E04 en mismo tablero con nueva identidad; no herencia excluida. Si pierde permiso, denegar sin copia parcial. C-101: copia activas del origen, no de plantilla. |
| PERM-26 | Cambiar referencia de etiqueta por la de otro tablero. | No consultar catálogo ni vincular etiqueta ajena, aunque exista membresía en ambos. C-100 permite crear/renombrar/cambiar color/asignar/quitar al colaborador; eliminar catálogo se deniega, reservado al propietario. |
| PERM-27 | Retirado o admin ajeno consulta actividad; reintento intenta duplicar un evento. | Sin lectura de historia privada ni duplicados por la misma operación. C-105: retención 180 días y recuperación sin reinicio; purga dependiente. Sin edición/borrado individual ni privilegio del autor retirado. |
| PERM-28 | Cargar 20 de 80 novedades y marcar visibles; llegan otras durante la acción. | Solo IDs cargados/autorizados de esa persona cambian; nuevas/no cargadas intactas. Resultado parcial explica lo ocurrido sin datos ajenos. |
| PERM-29 | PWA instalada: cerrar sesión/cambiar cuenta y reabrir por icono o enlace. | Mismas barreras que web; no contenido anterior desde caché ni escrituras offline automáticas. Compatibilidad se prueba en dispositivos reales. |
| PERM-30 | Escritura añade campos protegidos de rol/autoría/propiedad; repetición tras timeout. | Rechazo sin cambio lateral; petición válida reconciliada por operación sin efectos duplicados. Validar casos normales y negativos por superficie. |

Son criterios para futura implementación, no pruebas ejecutadas. Cada operación permitida requiere también prueba negativa con actor ajeno, objeto ajeno, rol revocado y estado inválido. UI, RPC/DB, API/Storage y canales privados deben concordar; enumerar todos los puntos de entrada existentes antes de dar por completada seguridad.

## 9. Decisiones aprobadas y límites de la aprobación

| ID | Decisión | Regla y alcance |
| --- | --- | --- |
| MP-01 | Aprobada, C-94. | Solo propietario cambia nombre y zona del tablero; colaboradores siguen administrando columnas y tareas. Preferencias personales libres para cada uno. |
| MP-02 | Aprobado C-94, ampliado C-98. | Quienes editan recuperan tareas; moderación solo propietario y limpieza administrativa solo admin. Actor conserva acceso. C-98 confirma R-02/R-04/R-06 y resolución de propiedad de tableros ya en papelera sin reiniciar plazo. C-110 confirma extensión a pasos/series/columnas R-01, con permisos actuales/plazo/dependencias y sin revertir traslados. |
| MP-03 | Aprobada, C-94. | Miembro puede borrar su propio archivo; propietario puede borrar cualquiera del tablero; nadie revierte moderación por autoría. Autor retirado pierde esta facultad. |
| MP-04 | Principio aprobado, C-94; campos exactos propuestos. | Referencias estables de tablero/archivo, propietario, membresías necesarias para sucesión, tamaño/fecha/estado y consumo; no textos de tareas, nombres de archivo sensibles, comentarios ni contenido. Transferir ordinariamente solo a miembros habilitados; recuperar sin miembros permite incorporación explícita. |
| MP-05 | Protección aprobada, C-94. | Impedir autosuspensión accidental del único administrador; no habilitar eliminación/delegación que deje la app sin administración. Procedimiento de recuperación de identidad pendiente de diseño. No crear otro administrador automáticamente. |
| C99-PERM | P01–P26 y E01–E07 incorporadas al alcance actual, C-99. | Permisos personales/lecturas según G-10–12 y B-21–25, garantías transversales P16–22 y aceptación PERM-23–30. No se aprueban por inferencia facultades de etiquetas, retención/efectos de borrado de actividad ni otros detalles que E dejó abiertos. |

La elección del diseño técnico, revocación de canales, permisos de archivos temporales y ejecución de trabajos no se trasladan al usuario como preguntas de producto: el agente debe verificarlos. Si para satisfacer esta matriz se necesita otro servicio/costo o cambia un contrato, elevarlo antes de implementar.

## 10. Cierre y referencia única

Esta es la referencia operativa única de permisos: acuerdos A vigentes, detalles P por revisar. Las tablas resumidas antiguas en MVP/spec 0001 se reemplazaron por enlaces, no se mantienen copias divergentes. C-94 aprueba las cinco recomendaciones presentadas y C-99 integra todas las propuestas P/E con el alcance descrito; ninguna autoriza implementación/despliegue ni convierte mecanismos sin verificar en garantías cumplidas. Pantallas deben ocultar/explicar acciones conforme a esta matriz sin convertirse en la única defensa.

### C-103 — Unicidad de etiquetas y vistas

**C-103 / Q18b:** al crear, renombrar o restaurar etiquetas y vistas, la unicidad ignora mayúsculas, espacios sobrantes, acentos y ñ/n. «Reunión»/«Reunion» y «Peña»/«Pena» colisionan dentro del mismo tablero para etiquetas, o del mismo usuario/contexto para vistas. Conservar escritura original; informar coincidencia y mostrar la existente solo si está autorizada. No fusionar automáticamente ni cambiar identidades/asociaciones. Nombres de otros tableros, usuarios o contextos no provocan colisión ni se revelan.

Criterio C103-AC18b en Cierre CF-22.4, todavía no ejecutado.

### C-107 — Autorización de sugerencias

Coincidencias, extractos, tipos, conteos y nombres/contextos de búsqueda unificada solo sobre datos actualmente autorizados. Revalidar destino al seleccionar; no mostrar comentarios/tableros de ajenos ni datos borrados/revocados por índices o respuestas atrasadas. El nuevo alcance funcional no concede membresía ni lectura administrativa global. C-108 cierra contrato en CF-14.2: comentarios heredan filtros de tarea padre, etiquetas conservan ID/tablero y navegación de tableros se distingue. Faltan mecanismos/pruebas de autorización de todos los tipos.

### C-109 — Revalidación del lote

Solo novedades propias sin leer cargadas en conjunto original fijado al pulsar; revalidar cada intención/reintento. Ya leídas resueltas, no disponibles sin títulos privados, falladas reintentables únicamente si siguen autorizadas. Instalación no concede membresía ni garantiza sesión compartida entre navegador/app. No se agregan roles ni lectura por admin.

### C-111 — Destinatarios y URLs

Nuevas ocurrencias conservan creador de serie como destinatario solo con acceso vigente, sin sustituirlo por owner. Original conserva creador original. Atribución importada por nombre no da destino autenticado. URL externa no concede membresía ni acceso al recurso externo; apertura explícita no debe ejecutar esquemas activos/locales. Roles existentes no se amplían.

## C-112 — Alcance histórico y nueva serie

Buscar historial conserva lectura autorizada actual; no habilita edición/reapertura de reemplazadas ni acceso a papelera. Programar de nuevo exige facultad vigente y crea serie independiente con misma tarjeta inicial. Borrar/restaurar serie anterior respeta causa/actor/plazo pero no afecta tarjeta ni calendario ahora en nueva. CF-14.3/CF-08.1 prevalecen.
