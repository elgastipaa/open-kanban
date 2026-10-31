# Issue #6 — evidencia de implementación y revisión

Fecha: 31/10/2026. Issue: «Crear y encontrar tableros privados». Rama: `codex/issue-6`. Base fija: `ee2771e75a7c18592b0af7eea814afae66f119da`. HEAD de código revisado: `22da1e221ec607fff7a69d683ba3b151c81a2d13`. El informe y el checkpoint se agregan en un commit documental posterior; la revisión se fija al HEAD de código indicado.

La relación nativa y el texto `Blocked by #4` se conservaron. La excepción autorizada es solo de secuencia: permite implementar y verificar localmente con identidades sintéticas sin satisfacer OAuth/Auth real ni cerrar #4 o #6. No se usaron Google, cuentas reales, datos de producción ni credenciales reales; no se leyó `.env`.

## Entorno y actores

- `pnpm test:db` ejecuta el arnés SQL contra PostgreSQL descartable y aplica las migraciones de la app. Los fixtures representan propietario, miembro actual, miembro revocado, no miembro y administrador ajeno; las sesiones y UUID son sintéticos.
- Se levantó un proyecto Supabase local independiente con CLI 2.122.0 e ID único `open-kanban-issue-6`; aplicó las migraciones 001–017. `/auth/v1/health` devolvió HTTP 200. No se emitió una sesión Auth ni se probó el recorrido Auth→PostgREST. El stack se detuvo usando `supabase stop --workdir` sobre su ruta exacta después de confirmar el ID; no se borraron volúmenes.
- No había un runner de navegador headless preexistente. Conforme a la preferencia del usuario, no se usó IAB/CUA para crear o instalar sesiones. El intento opcional Auth→PostgREST quedó bloqueado por la herramienta al manejar la `service_role` local y un access token en memoria; no se repitió por otro canal.

## Estado de los criterios

| Criterio | Estado | Evidencia y límite |
| --- | --- | --- |
| Crear tablero vacío con nombre, propietario como único miembro inicial y zona del creador | **Parcial** | DB prueba creación, miembro owner único, zona horaria, sin columnas iniciales, validaciones y constraints. La creación visual autenticada no se verificó en navegador. |
| Listar tableros propios/compartidos solo con membresía vigente; solo owner renombra y el slug se mantiene estable | **Parcial** | DB prueba listado/lectura de miembro actual, denegación de no miembro, rename restringido al owner y URL estable. También prueba que revocar membresía corta listado/lectura. El ciclo visual lista→rename no se probó autenticado. |
| Crear, renombrar y ordenar columnas libres; distinguir error de nombre vacío; propiedad según membresía | **Parcial** | DB prueba operaciones de columna por miembro vigente, orden, rechazo de nombre vacío y denegación tras revocación. El render y anuncio accesible de errores no se recorrió en navegador. Los mensajes nuevos de mutación están en español. |
| Controles móviles y de teclado para columnas | **No probado** | El código compila y el estado vacío común está cubierto antes de elegir la vista móvil; no hubo verificación visual/interactiva en viewport móvil ni teclado real. |
| Preparación de identidad y generaciones sin exponer contenido archivado | **Parcial** | DB prueba separación de generación activa y que lecturas no exponen una generación archivada. El helper de intención de alta separa el borrador por UUID Auth validado y rechaza operar sin principal; no se emitió una sesión Auth real/local para probar esa frontera de extremo a extremo. |
| Reintento de alta tras timeout, constraints y aislamiento entre dos sesiones | **Parcial** | DB prueba reintentos idempotentes, carrera con la misma operation_id, constraints y aislamiento entre sesiones sintéticas. La reconciliación visual de una respuesta perdida/timeout no se verificó en navegador. |
| Evidencia reproducible, español, permisos, accesibilidad y estados de error | **Parcial** | Los comandos y fixtures quedan registrados abajo; los errores nuevos están en español y el Spec review no encontró divergencias de permiso. Falta recorrido de accesibilidad/UI autenticada. |
| Conservar contratos posteriores C-01–112 y todas las P/E sin ampliar alcance | **Probado** | La revisión Spec final no encontró hallazgos ni reaperturas fuera del contrato de #6. |

## Verificación del HEAD revisado

| Comando / revisión | Resultado |
| --- | --- |
| `pnpm test:unit` | Pasa; 2 pruebas Node sobre aislamiento del borrador por principal y rechazo cuando falta un UUID Auth válido. La regresión se observó roja antes del arreglo y verde después. |
| `pnpm test:db` | Pasa en PostgreSQL descartable; cubre creación, membresías, permisos, generaciones, columnas, revocación, constraints, reintentos idempotentes y sesiones concurrentes. |
| `pnpm typecheck` | Pasa. |
| `pnpm build` | Pasa con Next.js 16.4.2. |
| Biome dirigido | Pasa en los archivos cambiados y en las iteraciones finales (`package.json`, UI/hook/helper/test); no se formatearon archivos ajenos. |
| `git diff --check` | Sin errores. |
| Revisión Spec | Sin hallazgos sobre `22da1e2` contra la base fija. Los tres P2 previos (borrador compartido entre cuentas, errores en inglés y falta de pruebas de permisos/revocación) quedaron corregidos y verificados. |
| Revisión Standards | Sin hallazgos sobre `22da1e2` contra la base fija. Se eliminó la rama de estado vacío inalcanzable de `MobileBoard` y `pnpm test:unit` hace reproducible la prueba unitaria sin dependencias nuevas. |

Las pruebas SQL no simulan OAuth ni acreditan una sesión de Auth. La respuesta 200 de `/auth/v1/health` solo confirma que el servicio local respondió.

## Recorrido pendiente para completar aceptación

Cuando #4 y el entorno de Auth permitan una sesión legítima de prueba, recorrer el mismo proyecto aislado con principal emitido por Supabase local/harness y dos actores sintéticos: crear y listar tablero, compartir por membresía vigente, denegar no miembro y miembro revocado, renombrar como owner conservando URL, operar columnas por teclado y viewport móvil, anunciar el error vacío, y repetir la misma intención tras simular pérdida de respuesta verificando que no aparezca un segundo tablero. Confirmar que el actor B no ve el borrador pendiente de A. No introducir claims en el navegador ni endpoints/flags de bypass.

Hasta verificar la frontera Auth/UI indicada, #6 queda abierto y `ready-for-human`, con `Blocked by #4` intacto. Este trabajo no satisface el login real de #4 ni autoriza cierre, main o producción.
