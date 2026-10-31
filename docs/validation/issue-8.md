# Issue #8 — evidencia de implementación

Fecha: 31/10/2026. Issue: «Editar desde un detalle único y resolver conflictos». Rama: `codex/issue-8`. Base fija: `8200bab94d74bd53f7f6148e0259ff787adcc667`.

Se conserva el bloqueo textual `Blocked by #7`. No se cambió el issue, sus labels ni sus relaciones. La implementación usa únicamente los campos editables que existen hoy (`title`, `description`, `priority`); fechas, responsables, etiquetas, comentarios, pasos y adjuntos todavía no están implementados en esta aplicación.

## Entorno y límites

- `pnpm test:db` aplica las migraciones en un clúster PostgreSQL 16.15 desechable creado por `scripts/test-db.sh`; el script retira su directorio temporal al terminar. No consume `DATABASE_URL`, `.env`, `.env.local` ni credenciales externas.
- La fixture es sintética. El actor autenticado `40000000-0000-4000-8000-000000000002` crea el tablero y la tarea; `40000000-0000-4000-8000-000000000005` es colaborador autenticado. Las pruebas asignan claims PostgreSQL y cambian al rol `authenticated`; no crean una sesión HTTP de Supabase Auth ni ejercitan PostgREST.
- No se usaron OAuth, cuentas reales, datos reales, la instancia #4/#6, producción ni permisos debilitados. No se instalaron runners de navegador.
- No hay render/interacción de navegador disponible para verificar el DOM, el flujo real de Auth, la pérdida de red del navegador o la presentación móvil. La matriz distingue el código y las pruebas de DB/unitarias de lo que todavía requiere recorrido humano.

## Criterios y evidencia

| Criterio | Estado | Evidencia y límite |
| --- | --- | --- |
| Abrir un detalle progresivo único en móvil y escritorio, mostrando el tablero y la columna de origen | **Implementado; UI pendiente** | `TaskModal` presenta primero título y descripción; prioridad/fecha se abren bajo «Más detalles». En móvil usa pantalla completa y en escritorio un diálogo centrado. El contexto toma nombre del tablero y columna actual. No se verificó visualmente en navegador móvil/escritorio. |
| Guardar los campos modificados con su versión independiente | **Probado en DB; UI pendiente** | La migración `019_versioned_task_field_edits.sql` agrega versiones independientes para los tres campos existentes. La UI manda solo los campos que cambiaron junto a sus versiones esperadas; no manda movimiento/posición como parte de la edición. |
| «Guardar y cerrar» cierra únicamente después de confirmar el guardado | **Implementado; interacción pendiente** | El cierre ocurre después de recibir `status: confirmed`. Error y conflicto conservan abierto el detalle. Falta comprobar el recorrido con un navegador y Auth real. |
| Descartar o seguir editando conserva el contexto de retorno; el borrador permanece solo en memoria de sesión | **Unitario/parcial** | El borrador se guarda solo en estado de React, sin persistencia local ni garantía tras recarga/cierre; cambios pendientes activan la confirmación nativa `beforeunload`. El selector puro prueba prioridad de tarjeta original, vecino de la columna, contenedor de columna y tablero. La restauración real de foco/scroll, posición y navegación móvil requiere verificación DOM manual. |
| Dos editores cambian el mismo campo: nadie sobrescribe en silencio y se muestran ambos textos para revisión | **Probado en DB; UI pendiente** | `scripts/test-db.sh` hace una carrera real con dos sesiones PostgreSQL `authenticated`, dos operation IDs y una versión inicial común. Una escritura confirma; la otra recibe conflicto con texto actual y borrador. La UI ofrece «Usar el valor actual» o «Conservar mi borrador» y exige revisar cada campo; no combina texto. No se verificó visualmente. |
| Dos editores cambian campos distintos: ambas ediciones se combinan sin invalidar la versión del otro campo | **Probado en DB** | Carrera concurrente de título/description: ambas operaciones confirman; los valores quedan combinados y solo incrementan sus versiones respectivas. `priority` permanece en versión 1. |
| Comentarios, pasos, adjuntos y movimiento independientes no invalidan versiones de campos | **Parcial** | Comentarios, pasos y adjuntos no existen aún en este MVP. La prueba DB sí mueve una tarea y comprueba que no se incrementan las versiones de título/description ni de prioridad. Las futuras acciones deben seguir como comandos separados. |
| Estados de guardando, guardado y error reflejan respuestas reales; un fallo de red conserva el borrador y no reintenta automáticamente | **Unitario; red/UI pendiente** | El estado `saving` se activa antes de la RPC; `saved` solo aparece tras confirmación. Prueba unitaria cubre fallo incierto, conservación del borrador y retry solo tras acción explícita, con la misma intención. La mala conexión real y la actualización accesible en DOM no se probaron. |
| Recibo de operación vencido requiere lectura/revisión antes de crear una nueva operación | **Probado en DB y unitario; UI parcial** | DB vence una receipt en la fixture y comprueba que devuelve `expired_unknown` sin reaplicar la edición. La ruta cliente consulta el tablero autorizado y convierte el resultado en revisión de valores actuales; si la lectura falla, limpia el operation ID del workflow, bloquea Guardar y ofrece una consulta manual. Unit test comprueba que una operación vencida no se puede reintentar. No se ejecutó este recorrido con Auth/PostgREST real. |
| Lectura previamente cargada sin conexión, aviso claro y sin cola/envío al reconectar | **Implementado; manual pendiente** | El detalle avisa cuando `navigator.onLine` es falso, bloquea el envío y explica que no habrá envío automático al reconectar. No existe cola offline. No se manipuló una conexión de navegador en esta entrega; queda recorrido manual. |
| Al conocer revocación se retira el contenido privado y se descartan respuestas de una cuenta anterior | **DB probado; UI/Auth parcial** | DB comprueba que un actor revocado recibe `42501` y no reusa recibos; `useTaskOperations` convierte denegación/stale session en `onAccessLost`, aborta requests de la sesión y desmonta `BoardWorkspace`. La verificación de Auth real y del retiro visual de un borrador queda manual. |
| Replay idéntico, colisión de operation ID, permisos y expiración | **Probado en DB** | La misma intención devuelve el resultado confirmado original; una clave con payload distinto falla `23514`; anónimo y miembro revocado no ejecutan; escritura directa de `tasks` se deniega; mover no toca versiones; global admin sin membresía no obtiene contenido. |
| Contratos vigentes C-95 y C-01–112/P/E | **Pendiente de revisiones finales** | No se reabrieron decisiones ni se agregó merge de texto o bloqueo exclusivo. La revisión final Standards/Spec la realizará el coordinador sobre el HEAD contra la base fija. |

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `pnpm test:db` | Pasa en PostgreSQL 16.15 desechable. Incluye carrera de mismo campo, combinación concurrente de campos distintos, replay/colisión, movimiento, expiración, acceso sin membresía y revocación. |
| `pnpm test:unit` | Pasa: 10 pruebas, 0 fallas. Incluye red/error explícito, no replay de operación vencida y selector puro de destino de foco. Node muestra warnings de detección de módulo TypeScript ya presentes en los tests con `--experimental-strip-types`. |
| `pnpm exec next typegen` y `pnpm typecheck` | Pasa con Next.js 16.4.2. `next-env.d.ts`/tipos son generados; no se incluyen en el commit. |
| `pnpm build` | Pasa con Next.js 16.4.2; compilación, TypeScript, páginas estáticas y optimización completadas. |
| `pnpm exec biome check <archivos modificados>` | Pasa sin fixes sobre los TS/JS/JSON modificados. |
| `bash -n scripts/test-db.sh` y `git diff --check` | Pasan. Git avisa que normalizará LF a CRLF en los archivos editados de este checkout Windows. |
| `pnpm lint` | No pasa en el repositorio completo: `biome check` reporta diagnósticos de formato/lint en archivos no tocados y normalización CRLF/LF. El Biome dirigido a los archivos de esta entrega sí pasa. |
| Navegador móvil/escritorio, PostgREST/Auth HTTP y OAuth | Pendiente manual; no hay runner instalado ni se usaron sesiones reales. |

## Recorrido humano pendiente

Con dos usuarios de prueba habilitados y un entorno local autorizado, abrir la misma tarea desde escritorio y móvil; comprobar el foco y la columna activa tras cerrar, mover/eliminar remotamente la tarjeta durante el detalle, guardar/cerrar tras confirmación, revisar el conflicto con dos textos, probar Guardar/Descartar/Seguir editando, revocar acceso y observar que se retira el borrador, y simular pérdida/restauración de red sin envío automático. También verificar el aviso de cambios sin guardar y lector de pantalla. No instalar un runner de navegador para este recorrido sin autorización independiente.

Hasta completar el recorrido humano y las revisiones Standards/Spec, el issue sigue abierto y conserva `Blocked by #7`. Esta evidencia no autoriza cerrar el issue, integrar a `main` ni publicar.
