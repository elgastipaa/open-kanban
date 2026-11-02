# Validación del issue #25 — Repetir por meses, años y ordinales

## Alcance y estado

Rama `codex/issue-25`; base fija `1e05fec55d019b591383813ed852d77a096ec2e7`; worktree `C:\Users\gasto\.codex\worktrees\openkanban-issue-25\open-kanban`.

La regla canónica agrega recurrencias mensuales y anuales por fecha, último día disponible y ordinal semanal. El cálculo usa el mismo calendario para preview, conteo, creación y worker. Los patrones quinto inexistentes se omiten sin consumir N; el 31 y el 29 de febrero conservan el valor original y se ajustan al último día disponible cuando corresponde. El ordinal «último» es una regla explícita, distinta del quinto.

El cambio extiende el contrato común de #23/#24 y conserva intactos los cálculos diarios y semanales. #25 sigue abierto y conserva `Blocked by #23`; #23 continúa OPEN/`ready-for-human`. No se aceptó QA ni se cerró ningún blocker.

## Criterios y evidencia automática

| Criterio | Fixture y evidencia | Resultado |
| --- | --- | --- |
| Día mensual 31 mantiene el ancla y se ajusta al último día disponible; el final por fecha es inclusivo. | `tests/db/daily_repetition.sql`: inicio 31/1/2026, regla mensual 31, final inclusivo 30/4/2026. Preview: 28/2, 31/3 y 30/4. Create/get/replay conservan el patrón y su próxima fecha; el worker procesa 28/2 y, al ejecutarse tarde el 30/4, termina en la última fecha sin materializar el 31/3 intermedio. | **PASS automático** en PostgreSQL descartable. |
| El último día disponible es seleccionable como patrón explícito. | La regla mensual `day_of_month=-1` queda normalizada y se conserva en el preview; desde 31/1/2024 devuelve 29/2, 31/3 y 30/4. La UI ofrece «Último día». | **PASS automático** para normalización y calendario; pendiente recorrido visual manual. |
| Ordinales mensuales primero–quinto/último y catálogo de lunes a domingo; el quinto inexistente se omite y no consume N. | Preview con quinto lunes desde 5/1/2026 y N=4 devuelve 30/3, 29/6 y 31/8; febrero, abril, mayo y julio no consumen ocurrencias. Regla explícita del último lunes devuelve 26/1 y 23/2. El worker, ejecutado primero el 29/6, devuelve `consumed_count=3` y próxima fecha 31/8; ejecutado luego el 31/8, finaliza con N=4 y no materializa el 30/3 intermedio. La UI ofrece primero, segundo, tercero, cuarto, quinto, último y lunes–domingo. | **PASS automático** para preview, worker y serialización. |
| Reglas anuales por fecha y ordinal en cualquiera de los doce meses. | Desde 29/2/2024, regla anual mes 2/día 29, preview devuelve 28/2/2025, 28/2/2026, 28/2/2027, 29/2/2028 y 28/2/2029. El patrón persistido sigue siendo mes 2/día 29. El quinto lunes de marzo omite 2028–2030 y devuelve 31/3/2025, 30/3/2026, 29/3/2027, 31/3/2031 y 29/3/2032. El worker anual llega tarde a 29/3/2027 con N=4 y próxima fecha 31/3/2031; al 29/3/2032 termina en N=6. | **PASS automático** para preview, persistencia y worker. |
| Preview y worker comparten el resultado; el conteo finito incluye la tarea inicial y cuenta fechas efectivas. | Serie mensual N=4 se procesa primero en 28/2/2026 y tarde en 30/4/2026; serie mensual ordinal N=4 llega tarde al quinto lunes del 31/8/2026 sin consumir fechas inexistentes. Serie anual iniciada en 29/2/2024 se crea con próxima fecha 28/2/2025 y el worker la materializa, avanza a 28/2/2026 y deja el conteo en 2. Todos los actores son UUID sintéticos y el worker recibe instantes controlados. | **PASS automático** mediante funciones locales de claim/process; no verifica un host de cron. |
| Intervalos y catálogo no reciben topes artificiales ni pierden precisión de extremo a extremo. | UI y estado de retry conservan el intervalo como texto. Preview mensual/anual, create, recibo, get y replay conservan `9007199254740993` literalmente; el worker usa el patrón ya persistido como texto. El helper acepta el rango positivo completo de `bigint` de PostgreSQL (`9223372036854775807`) y rechaza el siguiente valor. Intervalos grandes no generan fechas fuera del calendario representable. | **PASS automático** para el rango representable por PostgreSQL y su roundtrip JSON. |
| UI en español y compatible con teclado/lectores de pantalla. | Frecuencia, mes, día del mes, modo de calendario, ordinal, día semanal e intervalo usan controles nativos etiquetados. Preview, mensajes y confirmación conservan las regiones `aria-live` existentes. | **Parcial:** typecheck/build y pruebas de serialización pasan; no se hizo recorrido con navegador o lector de pantalla. |

## TDD y verificaciones

- **Rojo inicial de base de datos:** el primer caso mensual falló con `Elige un intervalo de repetición positivo` porque el normalizador anterior aceptaba solo daily/weekly. El caso anual 29-feb mostró el mismo rechazo antes de implementar yearly.
- **Rojo inicial de UI:** la prueba focal `tests/unit/repetition-pattern.test.mjs` falló al importar el módulo de selección todavía inexistente.
- **Verde focal:** `bash scripts/test-db-issue-23.sh` dentro de WSL pasa con los casos #25 y las regresiones #23/#24; `node --experimental-strip-types --test tests/unit/repetition-pattern.test.mjs tests/unit/daily-repetition-state.test.mjs` pasa 7/7.
- **Suite DB completa:** `bash scripts/test-db.sh` dentro de WSL — **PASS**, incluida la suite de seguridad y las pruebas de concurrencia, en un clúster local descartable.
- **Suite unitaria completa:** `pnpm test:unit` — **PASS**, 171/171.
- `pnpm exec next typegen` — **PASS**; `pnpm typecheck` — **PASS**; `pnpm build` — **PASS** con Next.js 16.4.2.
- `pnpm exec biome check --line-ending=crlf` sobre los seis archivos TS/TSX/MJS/JSON tocados — **PASS**. `git diff --check` — **PASS**.

Entorno: Node.js `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`, PostgreSQL `16.15` bajo WSL Ubuntu. Las dependencias de interfaz se instalaron con `pnpm install --offline --frozen-lockfile`, sin descargas. Las fixtures usan actores, tareas y operaciones sintéticos; fecha, zona del tablero e instantes del worker se fijan dentro de la prueba.

## Pendientes manuales y externos

- **Manual:** falta un recorrido visual de la UI con un fixture de navegador local sintético y una comprobación con lector de pantalla/dispositivo. No se abrió una sesión real.
- **Externo:** G03 global y la configuración/verificación de host/cron permanecen pendientes. Las pruebas demuestran funciones PostgreSQL locales; no se desplegó ni se afirmó ejecución autónoma en alojamiento.
- **Límites:** no se usaron `.env.local`, credenciales, OAuth/bypass, usuarios reales, SQL remoto, `main`, producción ni deploy. No se publicó, integró ni cerró ningún issue.
