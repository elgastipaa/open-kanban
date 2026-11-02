# Issue #26 — evidencia de validación

## Entorno

- Rama `codex/issue-26`; base y `HEAD` de partida: `2b3b1bdf49dbb2432bf14b4a7e95d0c1a41d748f`.
- Node `v24.14.1`, pnpm `11.3.0`, Next.js `16.4.2`, Biome `2.2.0`.
- Base aislada de prueba: PostgreSQL `16.15` en un cluster desechable creado bajo `/tmp/openkanban-db.*` por `scripts/test-db.sh`. El runner no usa `DATABASE_URL`/`PGHOST` y limpia ese cluster al finalizar.
- Datos de prueba sintéticos, miembros de prueba y fechas controladas en SQL. No se usaron `.env.local`, cuentas ni datos reales, OAuth, servicios/SQL remotos, producción ni despliegues.
- La inspección de UI se hizo en una ruta temporal local con props y respuestas sintéticas. La ruta fue retirada al terminar; no usó autenticación ni datos reales.

## Criterios y evidencia

| Criterio | Evidencia | Estado |
| --- | --- | --- |
| Anticipación `X`: aceptar solo `0 ≤ X < separación mínima`; calcular la fecha visible en la zona del tablero y no crear antes de esa fecha | `tests/db/repetition_edit.sql`: casos de intervalo mínimo (incluye calendario mensual/anual), negativo y exceso; fechas de aparición en `America/Argentina/Buenos_Aires`; worker no activa la ocurrencia antes de su fecha visible. | Automatizado, DB real aislada |
| Crear la serie mantiene la ocurrencia actual donde está, pone las próximas en la columna seleccionada y los reintentos no duplican ni cambian el destino | `tests/db/repetition_edit.sql`: estado de tarea/columna actual, destino de la próxima y replay con el mismo comando; reutilizar la misma operación con otra columna se rechaza. | Automatizado, DB real aislada |
| La vista previa permite revisar plantilla, patrón/fechas, zona, destino, final y exclusiones preservadas o retiradas | `preview_repetition_edit_p` y assertions en `tests/db/repetition_edit.sql`; la UI presenta estos campos y diferencia las exclusiones que se conservan de las que dejan de aplicar. | Automatizado en DB y revisión de UI sintética |
| Cambiar una serie informa qué exclusiones se retirarán | Preview del RPC y assertions de fechas preservadas/retiradas en `tests/db/repetition_edit.sql`; mensaje visible en el formulario de edición. | Automatizado en DB y revisión de UI sintética |
| Final `N` representa las próximas `N` ocurrencias, sin contar actual/pasadas; cambios ajenos a la serie no reinician el restante | Assertions de final/restantes en `tests/db/repetition_edit.sql`; edición ordinaria de título de la ocurrencia actual no altera snapshot ni cuenta. | Automatizado, DB real aislada |
| Si la fecha inicial elegida no coincide con la regla, hace falta elegir/confirmar una fecha compatible | `selected_date_compatible` y `date_choice_required` cubiertos en `tests/db/repetition_edit.sql`; en la UI sintética el botón de confirmar no aparece hasta elegir la fecha sugerida. | Automatizado en DB; inspección de UI |
| La fecha de una excepción debe ser estrictamente anterior a la siguiente ocurrencia | Regresión de C-110 en `tests/db/daily_repetition.sql`: una excepción anterior se acepta y la igualdad/lateridad se rechaza. La suite completa sigue ejecutando esta prueba junto con la migración 043. | Automatizado, DB real aislada |
| Un conflicto conserva el borrador para revisar o volver a previsualizar | Verificación manual local de teclado: modifiqué plantilla y cantidad; al simular `conflict`, el aviso informó que el borrador se conserva y los valores siguieron presentes. | Inspección manual de UI sintética; sin E2E persistente |
| Jobs encolados bajo una revisión anterior no aplican cambios a la serie editada | El worker comprueba revisión/`next_due_on`; `tests/db/repetition_edit.sql` edita la serie y comprueba que un trabajo anterior no crea una ocurrencia ni altera la revisión vigente. | Automatizado, DB real aislada |

## Ejecuciones

Comandos ejecutados desde la raíz del worktree:

| Comando | Resultado |
| --- | --- |
| `corepack pnpm test:db:issue-26` | Exit `0`; `Issue #26 database regression tests passed (disposable PostgreSQL).` |
| `corepack pnpm test:db` | Exit `0`; migraciones `001–043`, suites de seguridad, regresiones, concurrencia e issue #26; `Database regression tests passed (disposable PostgreSQL).` |
| `corepack pnpm test:unit` | Exit `0`; `173` tests, `173` pass, `0` fail. Node informa advertencias no bloqueantes `MODULE_TYPELESS_PACKAGE_JSON` en módulos existentes. |
| `corepack pnpm typecheck` | Exit `0`; `tsc --noEmit`. Se regeneraron tipos con `next typegen` y se retiraron cuatro archivos de `.next/dev/types` que aún apuntaban a la ruta temporal ya borrada. |
| `corepack pnpm build` | Exit `0`; Next compiló, comprobó TypeScript y generó las páginas estáticas. |
| `corepack pnpm exec biome check` en los 9 archivos TS/MJS modificados | Exit `0`; `Checked 9 files ... No fixes applied.` |
| `git diff --check` | Exit `0`; sin errores de whitespace. |

La comprobación de teclado/semántica usó el árbol accesible y controles con nombre, edición de inputs por teclado, incompatibilidad de fecha sin acción de confirmación y preservación del borrador tras conflicto. Fue una sesión manual asistida por navegador, no una prueba de navegador automatizada guardada en el repositorio.

## Pendiente

- Revisión independiente de estándares y correspondencia con la especificación por coordinación del run.
- Recorrido humano completo en la aplicación, con pantalla/dispositivo y lector de pantalla; el formulario se revisó en el harness sintético local.
- No hay dependencia de proveedor externo en esta funcionalidad; no se hizo validación contra servicios externos ni producción.
