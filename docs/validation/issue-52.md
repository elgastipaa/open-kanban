# Evidencia del ensayo de transición privada — issue #52

**Estado:** ensayo local sintético, parcial por criterio. #52 permanece OPEN y sus seis criterios compuestos siguen desmarcados.
**Base fija:** `1ee3142dc101f48a55ffeddd6006a78dc66b42f8` (`codex/openkanban-1-0`).
**Rama:** `codex/issue-52`.
**HEAD final del código ensayado:** `1408c5b15f1483f25fab89f26c1a9bdd91163495`. Este es el commit incluido en el manifiesto y revisado contra la base fija; el SHA del commit de cierre documental se informa también en el comentario de #52.
**Contratos:** P24/P25/P26; C-93/C-98; CF-20; DT-0.1 §10 y G08.
**Skills aplicadas:** `implement`, `tdd`, `code-review`; leídas y seguidas manualmente porque esta sesión no expone Skill tool.

El trabajo añade solo un runner, fixtures/asserts SQL y esta guía. No agrega migraciones, tablas de producto, endpoints, UI ni dependencias. Las tablas `issue52_rehearsal.*` existen únicamente en el clúster de pruebas descartable.

## Fixture y recorrido ejecutado

El runner `scripts/test-db-issue-52.sh` crea una base local descartable y aplica el historial real de migraciones:

1. Aplica 001–014 y carga dos tableros legado inventados, cada uno con una columna y una tarea. Antes del corte, `anon` puede leer ambos por `get_full_board_p(text)`; el assert consulta el contenido de la RPC bajo el rol `anon`.
2. Aplica `015_closed_google_access.sql`, que cierra el acceso anónimo. En ese punto el fixture crea `application_access` sintético y asigna cada `boards.owner_id` desde su mapa explícito, antes de `017_private_boards.sql` genere la membresía de dueño y la generación activa.
3. Aplica 016–073. El assert comprueba integridad de filas, dueños diferentes, identidad habilitada, admin bootstrap y separación entre administración global y membresía/lectura de tableros. El admin no recibe ningún tablero por ser el primer usuario.
4. Ejecuta `tests/db/anonymous_surface.sql`, que revisa privilegios efectivos de `anon` sobre schema/tablas/vistas/secuencias/rutinas de `public`, RLS y el bucket privado del stub Storage.
5. Reutiliza el helper local de #50 para respaldar el estado privado, restaurarlo en un clúster nuevo, inyectar una migración que falla, verificar rollback del DDL y volver a restaurar una copia limpia. Tras el fallo y tras el retry vuelve a comprobar los dueños, contenido y superficie anónima.

Actores elegidos por la fixture (no son personas ni cuentas reales):

| Función sintética | ID local | Correo de fixture | Tableros |
| --- | --- | --- | --- |
| Dueño A | `52100000-0000-4000-8000-000000000001` | `issue52-owner-a@example.test` | `issue52-legacy-a` |
| Dueño B | `52100000-0000-4000-8000-000000000002` | `issue52-owner-b@example.test` | `issue52-legacy-b` |
| Admin bootstrap | `52100000-0000-4000-8000-000000000003` | `issue52-bootstrap-admin@example.test` | Ninguno; no obtiene lectura global |

El inventario conserva dos IDs de tablero sintéticos (`52000000-0000-4000-8000-000000000001/2`) y dos tareas ficticias con IDs `52300000-0000-4000-8000-000000000001/2`. Todos los actores tienen sujetos Google y emails `@example.test` inventados. La elección de propietario se guarda en la tabla de fixture antes de simular el corte; no se infiere de la primera sesión.

El rol local `authenticated` tiene `SELECT` solo sobre las dos tablas sintéticas `issue52_rehearsal.inventory` y `.bootstrap` para que el assert table-driven pruebe el RPC público con cada owner. `anon` no recibe acceso al esquema; esos permisos y tablas existen únicamente en el clúster descartable.

El recorrido de #50 añade un archivo local sintético de 30 bytes. Su SHA-256 restaurado esperado es `3809ddda411bb00f1716d380bc095848b006bf43c459fcee801ca4bfe6fe7e73`. El harness conserva metadata/cuota en PostgreSQL, restaura dos veces y mantiene un job `queued` y ninguno `leased`; los bytes son de un archivo sintético de filesystem, no del servicio Storage alojado.

### Resultado TDD

El primer pase fue rojo por una razón de contrato: sin cargar el mapa de dueños antes de 017, el assert encontró `owner_id IS NULL` para `issue52-legacy-a`. El arreglo aplica el mapa explícito después de 015 y antes de 017 en el fixture local. El pase verde verificó que 017 crea las membresías esperadas, y que restore/rollback conservan identidad, contenido y privacidad.

## Entorno, versiones y límites de ejecución

- Ubuntu 24.04.4 LTS (WSL), PostgreSQL 16.15; clúster independiente en `/tmp/openkanban-db.*`, socket Unix privado, `listen_addresses=''` y autenticación host rechazada.
- Runner focal ejecutado con `bash scripts/test-db-issue-52.sh` dentro de WSL. WSL tiene Node.js 18.19.1 y no tiene pnpm; la corrida SQL no usa pnpm. El build/typecheck del proyecto se ejecutó en Windows con Node.js 24.14.1 y pnpm 11.25.0.
- App/package `1.0.0`, Next.js `16.4.2`, cabeza de migraciones `073_revoke_public_helper_execute.sql`.
- El bundle usa allowlist de configuración sin valores secretos, exporta roles con `--no-role-passwords` y escribe artefactos solo dentro del directorio temporal descartable. No se consultaron archivos `.env`, cuentas, inventario, APIs o servicios remotos; no se usó Docker.
- No se ejecutó navegador, Auth/PostgREST alojado, Storage físico, transporte Realtime, scheduler/worker alojado, dispositivo ni evaluación humana. El harness PostgreSQL contiene stubs de Auth/Realtime/Storage. El login/callback actual solo se revisó estáticamente (`src/app/login/page.tsx`, `src/app/auth/callback/route.ts`, `src/proxy.ts`).

## Resultado por criterio de #52

| Criterio | Evidencia del ensayo | Estado |
| --- | --- | --- |
| Inventario y propietarios explícitos, admin bootstrap y plan de migración/callbacks/Storage/canales/jobs; nunca primer-login-dueño | Dos owners distintos y un admin separado en la fixture; mapa aplicado entre migraciones 015 y 017; checklist real abajo. | **Parcial.** Inventario, owners y configuración reales requieren selección/autorización expresa; callbacks y proveedores reales no se probaron. |
| Snapshot aislado, rollback cerrado y restore; sin login sobre RPC anónimas abiertas ni pérdida silenciosa | RPC anónimas antiguas reproducidas antes del corte; `anonymous_surface.sql` pasa después de migrar, al restaurar, después del fallo y en el retry. IDs, filas, membership y objeto sintético/hash coinciden. | **Parcial.** No es evidencia de despliegue, rollback de servicios alojados, callback, Auth/PostgREST ni bytes/ACL reales de Storage. No hubo navegador que valide pantalla/redirect. |
| Cobertura de tickets/P/E/gates y evidencia de compatibilidad/restauración, sin declarar MVP completo | Mapa existente cubre T01–T51 (`#3–#53`) y las 33 filas P01–P26/E01–E07. La evidencia de esta tarea se limita a P24/P25/P26, con cruces a #21/#50/#51 y G08. | **Parcial.** Cobertura estática no es aceptación de todos los tickets/P/E ni cierre de gates. #21/#50/#51 conservan gates humanos; #53 mantiene autorización separada. |
| Checklist real, rotación histórica pendiente y aprobación de corte | Checklist accionable abajo; no contiene valores secretos ni decide owners reales. | **Pendiente para operación.** Rotación/recuperación por canal seguro y aprobación específica #53 continúan pendientes. |
| Evidencia reproducible por criterio, entorno/actores y estados; español, permisos, accesibilidad y errores | Runner/asserts y mensajes nuevos están en español; actor/ID/fixture/entorno documentados. No se añadió una pantalla ni un control. | **Parcial.** No se hizo aceptación de UI, español visual, teclado, lector, móvil o dispositivos. |
| Conservar C-01–112 y las P/E; no reabrir alcance histórico | No hay cambio de producto ni migración. La matriz de trazabilidad sigue siendo el índice para las 33 P/E; el ensayo no reabre Q61–62 ni declara el MVP completo. | **Parcial.** La implementación/verificación integral y los gates correspondientes siguen pendientes. |

## Cobertura y gates

`docs/specs/MATRIZ-TRAZABILIDAD-1.0.md` contiene P01–P26 y E01–E07; `docs/specs/TICKETS-PUBLICADOS-1.0.md` mapea T01–T51 a #3–#53. Para este ensayo, #52 cubre P24/P25/P26. Los tickets relacionados aportan contexto, no se aceptan por esta entrega: #21 (P13), #50 (P24/P25) y #51 (P08/P09/P12/P26).

La reconciliación de GitHub previa al ensayo confirmó #21, #50 y #51 OPEN/`ready-for-human`, y #52 OPEN/`ready-for-agent`. Se conservan los tres `Blocked by #21/#50/#51` de #52 y sus estados/gates; #53 sigue OPEN y requiere aprobación específica. #3–#50 están integrados según el checkpoint de LP-0.2, pero eso no equivale a aceptar todas sus AC ni a completar las 33 P/E.

| Gate DT-0.1 | Evidencia local relevante | Pendiente que impide declararlo cerrado |
| --- | --- | --- |
| G01 — Acceso | Migraciones locales, roles sintéticos y superficie `anon` vacía tras 015–073. | Auth/PostgREST alojado, callbacks y recorrido completo con cuentas elegibles/ajenas reales. |
| G02 — Ejecutor | Un job fixture `queued`, cero `leased`; worker apagado en restore. | Pausar/reanudar scheduler/worker real y observar lease, caída y backlog. |
| G03 — Calendario | No es el alcance de #52; #50 conserva solo fixture de una serie. | Suite de calendario/zonas y ejecución durable según G03; el ensayo no la certifica. |
| G04 — Storage/cuota | Metadata/ledger y bytes sintéticos; hash coincide tras restore. | Proveedor real, ACL física, descargas/revocación, CDN, purge y reconciliación de objetos. |
| G05 — Sesión/Realtime | Política SQL y canal stub se preservan en el dump. | Transporte alojado, canal abierto/revocación, callback, reconexión y cambio de cuenta. |
| G06 — Portabilidad | Dump/restore local doble y checksum del archivo sintético; #42 aporta evidencia aparte. | Destino/cifrado/retención, restore de bytes del proveedor y recursos reales. |
| G07 — Experiencia/carga | No se modificó UI; #48 aporta muestras sintéticas. | Navegadores/dispositivos reales, P26 con participantes, accesibilidad y aceptación humana. |
| G08 — Corte/restore | Fixture de transición, rollback de DDL fallido, restore privado y cierre anónimo. | Inventario real autorizado, configuración/rotación por canal aprobado, worker/servicios, objetivos RPO/RTO y permiso de corte. |

## Checklist antes de un corte real

Este checklist prepara la operación; no la autoriza ni afirma que su configuración exista.

1. **Autorización y alcance.** Obtener aprobación explícita para #53, ventana, destino, operadores y criterio de abortar. Fijar SHA de app, cabeza de migraciones, versión de PostgreSQL y compatibilidad de callbacks; no inferir permiso de una etiqueta o de este fixture.
2. **Inventario y propiedad.** Con autorización, generar una lista revisable de cada tablero incluyendo papelera, propietario seleccionado, columnas, tareas, attachments, zona y estado. Resolver duplicados/huérfanos antes del corte; preservar contenido identificado. Nunca asignar al primer login. Dejar sin acceso cualquier fila sin dueño confirmado hasta decisión humana.
3. **Bootstrap y credenciales.** Elegir explícitamente el admin bootstrap por canal seguro, confirmar identidad Google estable e independiente de las membresías de tablero, preparar recuperación y rotación de credenciales históricas. La rotación y el canal aún no están definidos/verificados; no escribir correos/token/secretos en GitHub, backups ni este reporte.
4. **Pausa consistente.** Definir mecanismo real de mantenimiento/bloqueo de escrituras; detener creación/edición, cron, scheduler, workers, purge y cargas; esperar transacciones/uploads/leases en vuelo. Registrar checkpoint y jobs `queued`/`leased`. No asumir que una marca de fixture detuvo procesos.
5. **Backup verificable.** Capturar snapshot consistente de DB, inventario/checksums de bytes Storage y manifiesto de versiones/configuración no secreta. Cifrado, destino privado, frecuencia, retención, permisos de restore y canal de secretos requieren decisión/infraestructura. Verificar hashes, conteos y ACL en copia aislada antes de tocar el servicio.
6. **Migración/cierre.** En una copia, ejecutar migraciones en orden. Confirmar que el runner real puede detenerse después de 015 y antes de 017 para poblar el mapa de `owner_id` con aprobaciones por tablero. El fixture demuestra ese orden, no que el runner operativo admita la pausa. Si no puede detenerse allí, no iniciar el corte: preparar y revisar, con autorización, un mecanismo de migración de datos que aplique el mapa antes de que 017 cree generaciones/membresías. Revisar explícitamente filas todavía sin dueño. Verificar callbacks/redirect allowlist y que el ingreso no crea cuentas o membresías automáticamente.
7. **Gate de pantalla y RPC.** Antes de publicar la ruta `/login`, demostrar en Auth/PostgREST real que `anon` y `PUBLIC` no tienen privilegios efectivos sobre rutinas/tablas del producto. Probar solicitud directa anónima, callback faltante/ inválido, cancelación, usuario habilitado/no habilitado, `next` interno, logout y cambio de cuenta. Una pantalla de login no sustituye el cierre en DB.
8. **Storage y canales.** Verificar bucket privado, bytes, metadata, cuota, ACL, URLs temporales, objetos ausentes/huérfanos y descarga después de revocar. Probar canal nuevo privado, denegación del tópico legado, revocación con conexión abierta, cambio de cuenta y respuestas tardías; el stub SQL no sustituye Storage/Realtime alojados.
9. **Jobs y reanudación.** Confirmar que ningún trabajo quedó leased en un proceso pausado; preservar cola/operación idempotente. Reanudar workers gradualmente solo después de comprobar ownership, permisos, Storage, calendario, leases y alertas de reconciliación.
10. **Rollback.** El punto restaurable debe ser una copia privada tomada después del cierre de grants y del mapeo validado. No restaurar un snapshot legado con RPC anónimas abiertas ni publicar login sobre esa superficie. Probar restore en aislamiento, hashes/conteos/ACL, reabrir servicio únicamente al target privado y comprobar disponibilidad/compatibilidad de la app anterior; si el binario anterior depende de RPC anónimas o del esquema viejo, el rollback no está listo.
11. **Go/no-go y medición.** Definir antes RPO/RTO objetivo según volumen/infraestructura, registrar observador, fallas y resultado del restore. Las medidas de esta prueba local no sirven como SLO. Si una verificación externa falla o el ownership es dudoso, mantener la pausa y escalar a decisión humana.

## Verificaciones de código y resultado del ensayo

| Comando | Resultado |
| --- | --- |
| `bash scripts/test-db-issue-52.sh` en Ubuntu 24.04 / PostgreSQL 16.15 | **PASS** sobre el commit ensayado `1408c5b15f1483f25fab89f26c1a9bdd91163495`, en clúster descartable. RPO local `474 ms`, RTO local `1917 ms`, bundle SHA-256 `3bd6ed02e4ebc8f740d8d11d2f39a549c0e0a9921ee5454ffc1e896d0a9ea89c`; el manifiesto registra ese mismo commit. El objeto sintético restaurado coincide con SHA-256 `3809ddda411bb00f1716d380bc095848b006bf43c459fcee801ca4bfe6fe7e73`. La privacidad completa se comprobó sobre el target inicial, tras rollback de la migración fallida y en el retry limpio. |
| `pnpm test:unit` | **PASS**, todas las suites unitarias. |
| `pnpm exec next typegen` | **PASS**, tipos de rutas generados. |
| `pnpm typecheck` | **PASS**. |
| `pnpm build` con URLs/valores sintéticos a loopback | **PASS**, Next.js 16.4.2; no se accedió a servicios remotos. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-52.sh scripts/rehearse-instance-backup.sh` | **PASS**. |
| `pnpm exec biome check --formatter-enabled=false package.json` | **PASS**, 1 archivo, sin cambios automáticos. |
| `git diff --check` | **PASS** para el diff completo de la entrega, incluido el cierre de evidencia; también pasa el diff staged antes de commit. |
| `bash scripts/test-db.sh` completa | **Falla en baseline conocido** en `tests/db/repetition_series_recovery.sql:419`: `Finite recovery created intermediate or extended dates`, ocurrencia `2026-11-02`, `consumed_count=3`. Las demás secciones alcanzadas antes de ese punto pasan; no se modificó esa suite ni el comportamiento de calendario en #52. |
| Revisión Normas | Revisiones read-only sobre la base fija `1ee3142dc101f48a55ffeddd6006a78dc66b42f8`: los hallazgos de los candidatos `d7a0562` y `bd1ce6b` se corrigieron; `6f17421` pidió un loop simétrico A/B, atendido por el loop table-driven de `1408c5b15f1483f25fab89f26c1a9bdd91163495`. **PASS final** en `e7b4791bcccd6793896eaf6845c76f68b07f792b`; la única nota restante fue la redacción futura de `git diff --check`, corregida en este commit documental. |
| Revisión Spec/Privacy | Revisiones read-only sobre la base fija `1ee3142dc101f48a55ffeddd6006a78dc66b42f8`: el assert completo de superficie anónima corre después del retry limpio y el resultado focal/manifiesto está ligado a `1408c5b15f1483f25fab89f26c1a9bdd91163495`. **PASS** en `e7b4791bcccd6793896eaf6845c76f68b07f792b`; sin hallazgos restantes de spec o privacidad. Las verificaciones de servicios reales y gates humanos siguen pendientes. |

Las medidas RPO/RTO son de un fixture local (porción de tiempo entre checkpoint y pérdida/restauración), dependen de la máquina y solo validan el camino ensayado. No son objetivos operativos, SLO ni evidencia sobre la instancia real.

## Compatibilidad, incompatibilidades y gates

- La app anterior puede llamar RPC anónimas; la migración 015 las cierra antes de que el camino privado sea servido. Un rollback de aplicación no debe volver a grants anónimos ni a un dump previo al corte. La compatibilidad del binario anterior sobre el esquema privado necesita ensayo/autorización aparte.
- La ruta actual `/auth/callback` intercambia el código y valida acceso; el proveedor, redirect allowlist, sesión Google y despliegue no se probaron aquí. La URL configurada y el comportamiento real de Auth siguen pendientes.
- `storage.objects`, `auth` y `realtime` en la prueba son stubs PostgreSQL. El archivo sintético y la policy SQL no demuestran ACL física, CDN, OAuth, transporte de canales, jobs alojados ni reinicio de servicio.
- Destino/frecuencia/cifrado/retención de backups y rotación/recuperación de credenciales siguen sin definición operativa. No hubo datos/configuración real, endpoint remoto, `main`, producción, migración/corte desplegado ni deploy.
- #21/#50/#51 permanecen OPEN/ready-for-human; #52 se deja OPEN/ready-for-human; los `Blocked by` no se borran ni se aceptan. #53 queda OPEN y separado por aprobación específica. No se marca MVP completo.

## Revisiones read-only

Las revisiones y el ensayo no sustituyen aceptación humana ni gates externos. Normas y Spec/Privacy dieron PASS read-only contra la base fija; el código ensayado fue `1408c5b15f1483f25fab89f26c1a9bdd91163495`. El cambio posterior a `e7b4791` contiene evidencia documental, no cambios de código.
