# Issue #39 — Evidencia de implementación

**Contrato:** C-111 / CF-18.1 / C111-AC59–60.

**Base fija:** `db5d3490163cc8f71c577b015c8f6705b57060d9`.
**Commit de código candidato:** `8044c08c6079ec78a76a13bf736a4dce027b26ba` (`fix: preview description links in task detail (#39)`).
**Estado:** código final `8044c08c6079ec78a76a13bf736a4dce027b26ba`; reviews Spec/Standards dieron PASS sobre el árbol `91607d24efb2d7e0697449c963076959c82e6784`. La actualización posterior es solo documental y no cambia código. Sigue aislado en `codex/issue-39`, sin integración ni publicación. El issue permanece abierto; se conservaron las aristas `Blocked by #15/#16` y PR #54 sigue en borrador.

## Alcance implementado

- Un parser de texto reconoce solo `http://`, `https://` y `www.`. `www.` abre con HTTPS; dominios sueltos siguen siendo texto. El texto visible conserva sus caracteres, incluidos acentos y entidades que React muestra como texto. Recorta puntuación exterior y mantiene paréntesis balanceados.
- Los enlaces se renderizan en descripciones visibles de tarjetas, detalle/serie, comentarios, pasos y en la vista previa de la descripción del detalle. La vista previa está separada del textarea, usa `draft.description` y `LinkifiedText`; el valor, `onChange` y `updateDraft` del editor se conservaron. Otros editores y previews permanecen como texto. No se interpreta HTML ni se hace preview remoto o descarga.
- La navegación requiere activación del ancla y abre una pestaña nueva con `rel="noopener noreferrer"` y `referrerPolicy="no-referrer"`. Se rechazan esquemas no HTTP(S), URL inválidas, credenciales, controles y barras invertidas.
- La tarjeta mantiene un botón de apertura por teclado separado de los enlaces de la descripción. El URL del título ofrece un control externo aparte en el detalle. Los controles y el nombre accesible del enlace están en español.
- Los comentarios vuelven a formar el texto completo antes de linkificar y aplican las marcas de menciones sobre rangos del original, para no partir una URL donde se encuentre una mención.

## Criterios y evidencia automática

| Criterio de #39 | Resultado automático |
| --- | --- |
| HTTP/HTTPS/`www.` clickeables al visualizar; dominio suelto y puntuación exterior conservados | PASS en pruebas del parser; contratos UI verifican tarjeta, vista previa del detalle, comentario, paso e historial. |
| Título de tarjeta abre la tarea; URL del título separado en detalle | PASS en contratos UI estáticos para botón de tarea y control externo independiente. El recorrido real del navegador queda pendiente. |
| Rechazo de esquemas activos/locales, HTML no interpretado, sin preview/descarga remota y apertura segura | PASS en pruebas del parser y contratos de ancla/React; no se realizó navegación de red. |
| Acentos, puntuación/paréntesis, texto malicioso, teclado y móvil | PASS para casos de texto y aserciones estáticas de foco/activación; teclado real y dispositivo móvil quedan pendientes de revisión manual. |
| Evidencia reproducible, versión, fixtures y separación entre pruebas automáticas/manuales | Registrado en este archivo. Se usaron únicamente cadenas sintéticas; no hubo Auth, cuentas ni datos reales. |

Pruebas de #39: `pnpm test:unit:issue-39` — PASS, 13/13 (7 del parser, 6 de contratos UI). Incluyen URLs válidas/`www.`, dominios sueltos, signos de puntuación y paréntesis balanceados o no, acentos, URLs inválidas/credenciales/esquemas no permitidos, texto tipo HTML, primer enlace seguro del título y contrato de vista previa junto al editor con un caso de URL.

## Entorno y verificaciones

Entorno de desarrollo local Windows/PowerShell, Node `v24.14.1`, pnpm `11.25.0`, Next.js `16.4.2`. Las pruebas usaron fixtures de texto sintéticos, sin Auth, SQL remoto, datos reales ni producción.

| Comando | Resultado |
| --- | --- |
| `pnpm test:unit:issue-39` | PASS, 13/13. |
| `pnpm test:unit` | PASS, suite unitaria completa e issues #33–#39. |
| `pnpm exec next typegen` | PASS, generó tipos de rutas de Next 16.4.2. |
| `pnpm typecheck` | PASS. |
| `pnpm build` | PASS, Next.js 16.4.2 / Turbopack; compilación, TypeScript y 17 páginas generadas. |
| `pnpm exec biome check` sobre los 10 archivos modificados | PASS, sin cambios. |
| `pnpm lint` en el repo completo | FAIL preexistente de formato: 260 diagnósticos CRLF/LF en 270 archivos, incluidos archivos sin modificar. Los 10 archivos de este cambio pasan la comprobación dirigida. |
| `git show --check HEAD` | PASS. |

## Gates pendientes

- Reviews finales Spec y Standards: PASS sobre el código `91607d24efb2d7e0697449c963076959c82e6784`; el commit posterior de evidencia solo registra la vista previa y el resultado de esas revisiones, sin cambios de código.
- Prueba manual en navegador con teclado, clic en tarjeta y enlace, vista móvil y lector de pantalla; QA humana pendiente.
- No se probó Auth real ni navegación externa desde una sesión real. Esos recorridos no se infieren de los tests sintéticos.
- No se actualizó ni cerró el issue y no se integró/publicó el commit. Los estados de #15/#16 y PR #54 no se modificaron.
