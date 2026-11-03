# Validación de #46 — Instalar la PWA y abrir destinos privados

Fecha: 2026-11-03. Rama: `codex/issue-46`. Base: `cbddbe310839d4c98a1fd7b07fada94fd7068f8e`.

La evidencia automática usa Node 24.14.1, pnpm 11.25.0 y Next 16.4.2. Los tests de PWA ejecutan el service worker en un contexto Node con origen, respuestas y sesiones sintéticos; no son recorridos de navegador ni prueban dispositivos. No se usaron cuentas, tokens ni contenido real.

## Resultado por criterio

| Criterio | Resultado y evidencia | Estado |
| --- | --- | --- |
| Instalar desde Cuenta, con opción directa o pasos manuales; sin insistencia y sin exigir instalación. | `/account` muestra la instalación opcional. Solo abre el prompt al pulsar cuando el navegador emite `beforeinstallprompt`; Safari iPhone/Mac, Chrome/Firefox iOS y Chrome/Edge escritorio sin prompt reciben instrucciones manuales para su ruta. Firefox de escritorio conserva el acceso web. `tests/unit/pwa-installation.test.mjs` verifica esas salidas y el manifest. | Implementado; falta aceptación manual en navegadores reales. |
| Manifest e iconos; caché pública versionada; sin contenido privado, borradores persistentes ni cola offline. | El manifest declara los iconos SVG versionados 192/512; Next genera el `apple-icon`. `public/sw.js` solo instala `offline.v1.html` y esos iconos en `openkanban-public-v1`. Las navegaciones privadas se solicitan a la red; el worker no escribe respuestas ni intercepta APIs, POST o recursos sin versión. Ante fallo de red devuelve una página genérica. La prueba focal inspecciona la lista cacheada, las escrituras y la respuesta offline. | Implementado y cubierto con fixture sintético; falta verificación de CacheStorage en navegadores reales. |
| Destino privado y retorno en web/instalada; logout/cambio de cuenta sin contenido previo; offline genérico con contenido privado solo en memoria de sesión. | El worker pasa por red la ruta privada y `/auth/callback`, conserva su query `next` y no guarda respuestas. El fixture pide exactamente la misma URL privada antes y después del logout; un origen sintético cambia la identidad de cuenta y verifica que la respuesta nueva llega de red, sin lectura/escritura privada en CacheStorage. `tests/unit/proxy-path.test.mjs` conserva los destinos privados, `/account`, `/api` y `/auth/callback` fuera del normalizador de slugs. El contrato existente descarta respuestas de otra época de autorización y reinicia preferencias al cambiar cuenta. | Contrato de caché cubierto automáticamente; OAuth, logout/cambio con sesiones reales y memoria de navegador pendientes. |
| Registrar la matriz Android/Chrome, iPhone/Safari, Chrome/Edge escritorio, Safari Mac y Firefox web con versiones reales. | No se conectaron dispositivos ni navegadores reales; no se registraron versiones ni se usó emulación para afirmar compatibilidad. | **Pendiente obligatorio.** |
| Evidencia reproducible por criterio, entorno y actores; distinguir automatización y gates manuales. | Este documento identifica fixtures sintéticos, comprobaciones ejecutadas y gates pendientes. | Documentado; la parte manual continúa pendiente. |
| Controles y mensajes en español; conservar permisos, accesibilidad y estados de error. | Los textos de Cuenta, la instalación manual y el fallback offline están en español. Los botones tienen foco visible; el feedback usa `output` y el aviso offline es genérico. No se hizo recorrido manual de teclado, lector de pantalla ni móvil. | Parcial; revisión manual de accesibilidad pendiente. |
| Conservar C-01–112 y todas las P/E. | No se alteraron acuerdos ni permisos. No se incorporó sincronización offline ni contenido privado a la caché. El aviso/recarga elegida de actualización y la resolución Guardar/Descartar/Seguir editando quedan para #47; este worker no fuerza `skipWaiting` ni recarga. | Implementado dentro del alcance de #46; actualización pendiente de #47. |

## Contratos y gates

- **C109-AC44 / E06 / G07:** matriz real de dispositivos, apertura, login, enlace privado y cambio de cuenta pendiente. No se afirma compatibilidad por disponer de manifest.
- **C109-AC45:** control opcional y guía manual implementados; el prompt y la instalación no se observaron en navegadores reales.
- **C109-AC46:** la experiencia de actualización que preserva borradores queda fuera de este ticket y pendiente de #47. No hay activación/reload forzado en este cambio.
- **P09/P11/P20:** no se hizo QA móvil real, validación OAuth ni prueba Auth/Realtime de revocación/cambio de cuenta. `Blocked by #8/#20/#22` se conserva; esos issues siguen `OPEN/ready-for-human`.
- **Privacidad:** el worker no almacena cookies, credenciales, respuestas privadas, borradores ni cola de operaciones. El único fallback persistido es HTML estático genérico, junto con iconos versionados.

## Comprobaciones

| Comprobación | Resultado |
| --- | --- |
| `pnpm test:unit:issue-46` | PASS, 19/19; incluye rutas de proxy, guía/manifest y comportamiento observable del worker con fixtures sintéticos. |
| `pnpm test:unit` | PASS, exit code 0; incluye la suite existente completa y #46. |
| TDD para cambio de cuenta con URL idéntica | Rojo: el fixture no distinguía la identidad sintética y no podía verificar la respuesta de la cuenta nueva. Verde: mismo URL privado, origen de prueba alterna cuenta A/B y el worker devuelve ambas respuestas directamente de red; 18/18 focales. También se añadió una prueba roja para Chrome/Firefox iOS que detectó el aviso incorrecto «En Safari»; verde con instrucciones neutrales de compartir en el navegador iOS, y 19/19 focales. |
| DB focal #46 | N/A: no se modificaron migraciones, RPC ni datos persistentes y no existe script focal de DB para este ticket. |
| `pnpm test:db` | Falla en el baseline de #27, `tests/db/repetition_series_history.sql:169` (`has_more=false`, «First history page omitted continuation»). Coincide con el bloqueo ya registrado en Continuidad; #46 no cambia SQL. El runner crea su PostgreSQL descartable y no usa `DATABASE_URL`/`PGHOST`. |
| `pnpm exec next typegen` | PASS. |
| `pnpm typecheck` | PASS. |
| `pnpm build` | PASS con Next 16.4.2; se generaron `/apple-icon` y `/manifest.webmanifest`. |
| Biome dirigido | PASS en los archivos PWA, proxy y tests. PASS en `next.config.ts`, `src/app/layout.tsx`, `src/app/account/page.tsx` y `package.json` con formatter desactivado para preservar finales CRLF ya existentes. |
| `git diff --check` | PASS. |
| `bash -n` | N/A: no se modificaron scripts shell. |

## Política de navegador consultada (no es QA de dispositivos)

Las instrucciones manuales se contrastaron con documentación oficial: [Apple para añadir a inicio en iPhone](https://support.apple.com/en-lamr/guide/iphone/iphea86e5236/ios), [Chrome para iPhone/iPad](https://support.google.com/chrome/answer/9658361?co=GENIE.Platform%3DiOS&hl=en-0), [Firefox para iOS](https://support.mozilla.org/en-US/kb/add-website-shortcut-your-home-screen-ios) y [Safari para Mac](https://support.apple.com/en-ca/guide/safari/ibrw9e991864/mac). Esta consulta solo orienta el texto mostrado. Los tests detectan user agents sintéticos; no abren esos navegadores, no verifican versiones ni comprueban la instalación en dispositivos reales.

La instalación real, los flujos Auth/OAuth/Realtime y la matriz de dispositivos siguen pendientes. No hubo cambios en `main`, base remota ni despliegue.
