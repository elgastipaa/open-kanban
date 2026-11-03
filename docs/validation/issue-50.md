# Evidencia de ensayo de respaldo y recuperación — issue #50

**Estado:** ensayo local reproducible; evidencia parcial por criterio. El issue permanece OPEN/ready-for-human.
**Base fija:** `b0305b50a70736b90ae575bfc1940cdf62b85c2d`.
**Rama:** `codex/issue-50`.
**Contrato:** P24/P25, G08, CF-20 y acuerdos C-94/C-98/C-101.
**Skills aplicadas:** `implement`, `tdd`, `code-review` y `implement-spec`; sus instrucciones se siguieron manualmente porque no hay Skill tool disponible.

El artefacto cubre una rehearsal aislada de PostgreSQL y un objeto sintético en filesystem. No implementa el respaldo operativo de una instalación alojada ni acepta los gates humanos o externos de #35/#41/#45/#47/#49.

## Resultado por criterio de aceptación

| Criterio de #50 | Evidencia local | Estado y pendiente |
| --- | --- | --- |
| Mantenimiento, snapshot de base + bytes + config/versiones; secretos fuera del repo/paquete | `tests/db/issue50_rehearsal_fixture.sql` crea una marca sintética de mantenimiento. `scripts/rehearse-instance-backup.sh` usa `pg_dump` custom, globals sin contraseñas, un archivo local de 30 bytes y un manifiesto allowlist con versión, commit, cabeza de migraciones, versión de PostgreSQL y config sintética. Verifica SHA-256 del archivo de backup, manifiesto, allowlist y objeto antes/después. No lee `.env` ni `.env.local`. | **Parcial.** La marca es del fixture, no un bloqueo de escrituras de la aplicación. El archivo de Storage y la config son sintéticos; no se verifican Storage alojado, configuración real, canal seguro de secretos, cifrado/retención ni destino de backup. |
| Restore aislado, jobs detenidos, hashes/conteos/ACL/cuota/series/exclusiones | Dos restores a una base nueva PostgreSQL, roles y permisos, RLS/policies, identidad de tablero y memberships, columnas/tarea, ledger de cuota, bytes/hash Storage sintéticos, serie/ocurrencias y trabajos en cola/no arrendados. El runner solo expone socket Unix privado en el cluster descartable y no activa el worker. | **Parcial.** `storage.objects` y los esquemas `auth`/`realtime` provienen del harness PostgreSQL; no levantan los servicios. No se probó pausar/reanudar un scheduler real, acceso físico de proveedor, CDN ni permisos de entorno alojado. |
| Fallo/reintento/migración fallida sin RPC anónimas; RPO/RTO medidos | Un DDL de migración que falla revierte su transacción; se descarta esa base restaurada y se repite el restore limpio. La aserción comprueba ausencia del DDL parcial. Se verifica en PostgreSQL que anon no tiene EXECUTE efectivo sobre `get_board_p(text)` y que ACL/RLS se conservan. | **Parcial.** Se midió RPO **584 ms** y RTO **1905 ms** en la última corrida focal registrada abajo. Son medidas del fixture y del entorno local, no objetivos/SLA. No se probó un procedimiento de migración real del despliegue ni el reinicio de procesos externos. |
| Guía, diagnósticos, origen/licencia, telemetría y parámetros del corte | Esta guía separa señales locales y límites. El código nuevo son scripts SQL/shell del repositorio bajo su licencia MIT (`LICENSE`); no se copió código externo. El ensayo escribe salida/logs solo localmente y no envía telemetría. | **Parcial.** Es orientación de laboratorio, no runbook autorizado de producción. Destino real y frecuencia quedan para el corte autorizado. Rotación/recuperación de secretos por canal aprobado, cifrado, retención y diagnóstico de servicios alojados siguen pendientes. |
| Evidencia reproducible por criterio, entorno, actores/fixture, controles en español y recorrido | El runner y los mensajes nuevos son en español. La evidencia identifica entorno, actores `@example.test`, comandos, fixture y resultados. No se agregaron controles ni mensajes de interfaz. | **Parcial.** No hubo aceptación manual, accesibilidad de interfaz ni prueba browser/dispositivo. Las suites PostgreSQL usan stubs locales de Auth/Realtime/Storage; no prueban transporte o servicio alojado. |
| Conservar C-01–112 y las P/E; no ampliar ni reabrir alcance viejo | El diff añade scripts, SQL de fixture/assertion, documentación y el comando focal; no añade migraciones, tablas de producto, endpoints o cambios de UI. Las dependencias de #35/#41/#45/#47/#49 y sus gates no se aceptan ni se quitan. | **Parcial.** No se afirma aceptación de los contratos o gates externos que el ensayo no ejecuta. Se conserva abierto el issue y no se marca completo ningún criterio compuesto. |

Todos los criterios compuestos permanecen sin marcar en GitHub: sus partes locales están documentadas, pero restan verificaciones obligatorias del entorno real o aceptación humana.

## Cómo repetir el ensayo local

Requisitos: Ubuntu 24.04/WSL con PostgreSQL 16 y sus herramientas (`initdb`, `pg_ctl`, `psql`, `pg_dump`, `pg_dumpall`, `pg_restore`, `createdb`, `dropdb`, `pg_config`), Node.js 24 para leer `package.json` y Git accesible desde el worktree. No se necesita Docker, `.env`, cuenta ni endpoint remoto.

Desde la raíz del repositorio en WSL:

```sh
bash scripts/test-db-issue-50.sh
```

El wrapper aplica las migraciones del repo en un cluster descartable creado por `scripts/test-db.sh`, ejecuta `google-access.sql` del fixture local y luego el ensayo. El helper rechaza cualquier `OPENKANBAN_TEST_DB_DIR` fuera de `/tmp/openkanban-db.*`, inicia el segundo cluster con sockets Unix privados y `listen_addresses=''`, y limpia el cluster de destino al salir. El harness limpia el de origen. Los roles se exportan con `--no-role-passwords`; los valores de credenciales no se incluyen en el archivo.

La salida incluye `MEASURED_RPO_MS`, `MEASURED_RTO_MS`, SHA-256 del bundle y del objeto restaurado. RPO se calcula entre el `checkpoint_at` sintético escrito al preparar el snapshot y la escritura/fallo posterior simulada. RTO abarca desde ese fallo hasta el restore limpio, las verificaciones de estado/ACL y la validación de hashes. Ambas medidas incluyen solo este ensayo local; pueden variar por máquina y carga.

## Fixture y aserciones

- App `1.0.0`, migración más reciente `073_revoke_public_helper_execute.sql`, PostgreSQL `16.15`.
- Actores ficticios con correos `issue50-owner@example.test`, `issue50-collaborator@example.test` y `issue50-outsider-admin@example.test`. Los RPC productivos de tablero/tarea/serie se ejecutan en el fixture usando `authenticated`; membresía de colaborador y admin ajeno son sintéticas.
- Tablero con dos columnas y una tarea; owner, colaborador, generación activa y una serie diaria con una ocurrencia actual y una excluida. Hay un trabajo `queued` y ninguno `leased`.
- Cuota activa de 30 bytes y una fila sintética `storage.objects` + metadatos de adjunto. La fila de base no representa los bytes del proveedor: el helper crea aparte `attachments/issue50/fixture.txt` y compara sus bytes SHA-256 reales antes/después.
- El archivo fixture contiene exactamente `Issue 50 synthetic attachment\n`: **30 bytes**, SHA-256 `3809ddda411bb00f1716d380bc095848b006bf43c459fcee801ca4bfe6fe7e73`.
- Snapshot marcador `86100000-0000-4000-8000-000000000001`; el cambio post-snapshot se aplica solo al estado sintético para probar recuperación al checkpoint anterior.
- El comparador normaliza grantee/grantor por nombre, ordena membresías de roles y default ACL por nombres/permisos, y renderiza expresiones RLS con `pg_get_expr`; compara atributos de roles (sin passwords), opciones de membresía, ownership, permisos, políticas y ACL default entre origen y restore. El cluster de destino inicia con `postgres` para no cambiar el grantor de membresías predeterminadas al importar globals. Omite el schema `extensions` y su ownership, que pertenece al entorno PostgreSQL instalado. No demuestra igualdad total del cluster: no compara configuración del servidor, tablespaces, binarios/definiciones externas de extensiones ni la configuración del proyecto alojado.

### Registro TDD y ajustes

1. Primera ejecución roja: el test focal llegó a la aserción del marcador de mantenimiento, aún inexistente en el esquema local del harness. El marcador se implementó en `issue50_rehearsal`, sin migración ni tabla de producto.
2. El primer fixture declaraba 31 bytes y SHA `43811be7…d827f35`; el contenido literal y `printf` generaban 30 bytes. Se corrigieron de manera independiente el tamaño, hash y contador de cuota a los bytes efectivamente escritos: 30 y `3809ddda…fe7e73`.
3. Se corrigieron la lectura de la generación con rol local autorizado, la forma de conexión de `pg_dumpall` y la cantidad de columnas sembradas; el fixture final contiene dos.
4. Las primeras comparaciones ACL diferían por representación/OIDs; al añadir memberships apareció el grantor de los roles `pg_monitor` distinto (`restore_admin` en destino, `postgres` en origen). El destino ahora inicia como `postgres`, filtra solo el `CREATE ROLE postgres` que chocaría con el bootstrap local e importa globals sin contraseñas como ese superuser. El comparador usa nombres/opciones/permisos estables y expresiones de policy con `pg_get_expr`; excluye ownership de extensiones administradas por la instalación.
5. La última corrida focal pasó después de estos ajustes. No se interpretan intentos intermedios como evidencia final.

## Resultados de esta revisión

| Comando | Resultado |
| --- | --- |
| `bash scripts/test-db-issue-50.sh` en Ubuntu 24.04/WSL, PostgreSQL 16.15 | **PASS**. Dump/restore doble; hashes, manifest/config allowlist, roles/memberships/ACL/RLS, conteos y dominio; migración fallida revertida y retry limpio. RPO 584 ms; RTO 1905 ms. Bundle `6f0e0a276f1d8800fac2530a879bda7aa76672059b90a6c9bf30a15f4f91b24c`; objeto `3809ddda411bb00f1716d380bc095848b006bf43c459fcee801ca4bfe6fe7e73`. |
| `pnpm test:unit` | **PASS**, suites principales y por issues 33–47. Node emitió advertencias `MODULE_TYPELESS_PACKAGE_JSON` en módulos existentes. |
| `pnpm build` | **PASS**, Next.js 16.4.2 (Turbopack), compilación, TypeScript y generación de páginas. |
| `pnpm typecheck` | **PASS** tras `pnpm build`, que genera `next-env.d.ts` ignorado por Git; `tsc --noEmit` terminó sin errores. La primera ejecución, antes de generar esos tipos, no encontraba la declaración para `public/OpenKanban-Logo.png`. |
| `pnpm lint` | **FAIL por formato en el checkout base**: Biome reporta CRLF/LF en 339 archivos. El chequeo pertinente `pnpm exec biome check --formatter-enabled=false package.json` pasa. No se reformateó el repo completo. |
| `pnpm test:db` | **FAIL de regresión preexistente** en `tests/db/repetition_series_recovery.sql:419`: `Finite recovery created intermediate or extended dates` (`next_due_on: null`, serie `finished`, `consumed_count: 3`). La suite completa se detuvo ahí; ese archivo y comportamiento no cambian en #50. El test focal de #50 pasa por separado. |
| `bash -n scripts/test-db.sh scripts/test-db-issue-50.sh scripts/rehearse-instance-backup.sh` | **PASS**; `shellcheck` no está instalado en el entorno. |

## Límites/gates pendientes

- Confirmar snapshot coherente con barrera de escrituras y coordinación del worker real; inventariar proceso de aplicación, migraciones y configuración del despliegue autorizado.
- Probar bytes, ACL física, ausencia/reconciliación, cuotas y purge del proveedor Storage real; Auth/PostgREST/Realtime alojados y transporte de eventos.
- Definir destino de backup, frecuencia, retención, cifrado, verificación, acceso a secretos, rotación y credenciales de restore por canal seguro; probar restore en aislamiento autorizado.
- Medir objetivos RPO/RTO con volumen, carga, infraestructura y corte autorizados; validar reinicio seguro de jobs.
- Revisiones humanas de operaciones/privacidad y aceptación browser, accesibilidad y mensajes si el futuro runbook introduce controles.
- #35, #41, #45, #47 y #49 siguen OPEN/ready-for-human; sus edges `Blocked by` permanecen sin cambios.

La rehearsal no transmite datos ni telemetría. `LICENSE` declara MIT (copyright 2026 Slogllykop); los scripts/fixtures de este cambio son originales para este repositorio. No se agregan dependencias de ejecución ni secretos al bundle o al repo.
