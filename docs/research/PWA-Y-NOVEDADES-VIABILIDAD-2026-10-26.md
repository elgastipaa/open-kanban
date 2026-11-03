# PWA online y novedades por lote — viabilidad

Fecha: 2026-10-26. Investigación delegada durante el cierre de la spec, después de C-108. **Las recomendaciones de esta nota son propuestas, no acuerdos nuevos.** No modifica contratos, código ni servicios y no acredita pruebas de dispositivos. Conserva todas las P/E aprobadas. Consulta de documentación oficial actual; las versiones exactas probadas deberán registrarse al implementar.

## Lo que ya está cerrado

E06 incluye instalación opcional, icono, login/enlaces y navegación coherentes con la web. Sigue siendo una aplicación online: sin push, aplicación nativa, cola de escrituras offline ni borradores duraderos. Contenido ya cargado puede permanecer durante la sesión abierta con advertencia; al detectar pérdida de acceso se retira. Reconectar/cambiar de cuenta exige revalidar y descartar respuestas anteriores. No se promete revocación instantánea mientras el dispositivo está totalmente desconectado. Fuentes: [Pantallas §2.11](../specs/PANTALLAS-MVP-1.0.md), [Estados y errores, principios y P20/E06](../specs/ESTADOS-Y-ERRORES-MVP-1.0.md), [spec 0001 C-95/C-99](../specs/0001-auth-collaboration.md).

E07 ya fija acción explícita con cantidad, sobre los IDs propios cargados y autorizados al iniciarla; excluye páginas no cargadas y avisos posteriores. Exige revalidar, informar resultados parciales y reintentar solo pendientes autorizadas. No archiva, pospone ni modifica tareas. Novedades leídas/no leídas caducan a 90 días. El resultado incierto se comprueba antes de repetir. Fuentes: [Cierre CF-15 y CF-27](../specs/CIERRE-MVP-1.0.md), [Estados ERR-PL09](../specs/ESTADOS-Y-ERRORES-MVP-1.0.md).

## Evidencia técnica y límites

El checkout usa Next.js 16.4.2, React 19.2.9 y Supabase JS según [package.json](../../package.json). Next.js ofrece manifest en App Router mediante `app/manifest.ts` o JSON. No hace falta cambiar de stack para describir la instalación. La guía incluye ejemplos de push: su existencia no añade push a OpenKanban. [Next.js: guía PWA](https://nextjs.org/docs/app/guides/progressive-web-apps).

La inspección de `src` y `public` no encontró archivos de manifest/service worker ni referencias a `serviceWorker`, `beforeinstallprompt` o `CacheStorage`. Existe [OfflineBanner](../../src/components/ui/offline-banner.tsx), cuyo aviso genérico no prueba seguridad de caché ni funcionamiento instalado. [layout.tsx](../../src/app/layout.tsx) todavía describe la aplicación histórica sin registro. Estos hallazgos identifican trabajo futuro; no autorizan implementarlo.

### Instalación y dispositivos

| Plataforma candidata para validar | Evidencia de capacidad | Implicación para OpenKanban |
| --- | --- | --- |
| Android / Chrome | La instalación existe; Chrome con Google Mobile Services puede producir WebAPK. Otras combinaciones pueden crear solamente un acceso del navegador. | Probar un Android real. No presentar todo acceso directo como aplicación instalada equivalente. |
| iPhone / Safari | Apple documenta Compartir → Añadir a pantalla de inicio y la opción Abrir como app web. | Ofrecer instrucciones manuales ajustadas al sistema. No depender de un diálogo programático. |
| Windows / Chrome y Edge | Chromium admite instalación en escritorio; Edge documenta icono de aplicación disponible e instalación desde la barra. | Probar instalación, apertura y enlaces con ambos navegadores prioritarios. |
| macOS / Safari | Apple permite Añadir al Dock desde macOS Sonoma 14. | Validar ruta manual y sesión propia de la aplicación instalada. |
| Firefox / escritorio, Linux u otras combinaciones | La capacidad de instalar depende de navegador/plataforma; soporte web y promoción por manifest son cosas distintas. | Mantener acceso web; no declarar instalación verificada fuera de la matriz de pruebas. |

Fuentes de la matriz: [MDN: soporte de instalación](https://developer.mozilla.org/en-US/docs/Web/Progressive_web_apps/Guides/Making_PWAs_installable), [Apple: app web en iPhone](https://support.apple.com/guide/iphone/open-as-web-app-iphea86e5236/ios), [Microsoft: instalación en Edge](https://learn.microsoft.com/microsoft-edge/progressive-web-apps/ux), [Apple: apps web en Mac](https://support.apple.com/en-us/104996). Son capacidades documentadas, no pruebas ejecutadas de OpenKanban.

En Mac, Apple especifica que la app web tiene cookies/datos separados de Safari. Por eso no se puede prometer que instalar conserve automáticamente el login o que un cierre local borre todas las sesiones independientes. El alcance global de cierre de sesiones se debe verificar en el contrato de autenticación; no se introduce aquí. [Apple: independencia de las apps web](https://support.apple.com/en-us/104996).

### Caché, privacidad y actualizaciones

Cache API conserva respuestas hasta que el código las actualiza/borra y no respeta automáticamente cabeceras HTTP de caché. El navegador también puede eliminar su almacenamiento. Por tanto, `Cache-Control` por sí solo no resuelve una estrategia de service worker ni garantiza disponibilidad offline. [MDN: Cache](https://developer.mozilla.org/en-US/docs/Web/API/Cache).

**Inferencia de diseño:** cachear únicamente recursos públicos versionados —iconos, estilos, código y una pantalla neutra— reduce el riesgo. No guardar contenido privado de tableros, tareas, búsquedas, comentarios, adjuntos o borradores como respaldo offline. Esto no prohíbe los mecanismos de autenticación del SDK/cookies: contenido privado y credenciales de sesión requieren tratamientos distintos. El cierre/cambio de cuenta debe retirar UI, memoria y respuestas pendientes; la reapertura debe validar autorización antes de volver a mostrar datos. El contrato vigente permite lectura limitada ya cargada en una sesión abierta, no restaurar un tablero privado desde disco al abrir sin conexión. [Estados: C-95 y P20/E06](../specs/ESTADOS-Y-ERRORES-MVP-1.0.md).

Un service worker actualizado normalmente espera; forzar su activación puede mezclar una página vieja con un worker nuevo. La actualización puede coordinarse con una acción del usuario. No debe asumirse que un recargado es inocuo para borradores. [Google: ciclo del service worker](https://web.dev/articles/service-worker-lifecycle). Además, Edge no exige service worker para instalar; su necesidad concreta pertenece al diseño técnico, no a una elección de biblioteca del usuario. [Microsoft: service worker opcional](https://learn.microsoft.com/en-us/microsoft-edge/progressive-web-apps-chromium/get-started).

### Lotes y reintentos

Supabase expone funciones de base como RPC; PostgreSQL permite que una modificación devuelva las filas efectivamente modificadas mediante `RETURNING`. Son herramientas suficientes para diseñar una respuesta por ID y reconciliar resultados; no demuestran por sí mismas idempotencia, permisos ni respuesta parcial correcta. [Supabase: funciones](https://supabase.com/docs/guides/database/functions), [PostgreSQL: RETURNING](https://www.postgresql.org/docs/current/dml-returning.html).

**Inferencia de diseño:** expresar «dejar leída» como estado deseado, no alternar un booleano. Una novedad ya leída por otra pestaña satisface el objetivo sin nuevo efecto. Un ID caducado o inaccesible no debe revelarse ni contarse como lectura recién confirmada. Un timeout no demuestra fracaso: comprobar primero y reintentar únicamente pendientes del conjunto original con autorización actual. La implementación decidirá transacción, clave de operación y formato de resultados; no asumir que un fallo SQL entrega automáticamente resultados parciales. Fuentes de requisitos: [C-95](../specs/0001-auth-collaboration.md), [Cierre CF-15](../specs/CIERRE-MVP-1.0.md).

## Seis decisiones de producto propuestas

| Decisión pendiente | Recomendación para presentar al usuario | Por qué / límite |
| --- | --- | --- |
| 1. Matriz inicial de aceptación | Validar Android/Chrome, iPhone/Safari, Windows/Chrome y Edge, macOS/Safari; uso web también en Firefox. Registrar versión estable vigente y versión anterior disponible para las plataformas de prueba. | Cubre móvil y computadora sin prometer todos los sistemas. La cobertura se acredita con equipos/pruebas, no con documentación; otros navegadores siguen pudiendo usar web sin garantía de instalación verificada. |
| 2. Descubrimiento de instalación | Entrada opcional «Instalar app»: diálogo del navegador cuando esté disponible; instrucciones manuales cuando corresponda. Sin modal obligatorio ni insistencia al rechazar. | La app debe seguir siendo utilizable en web; iPhone y Mac necesitan rutas distintas. No afirmar instalado solo por haber pulsado un botón. |
| 3. Apertura y caché privada | Abrir sin conexión desde cero muestra una pantalla neutra para reconectar; nunca el tablero privado guardado en disco. Durante una sesión abierta se conserva la lectura limitada ya aprobada. Al cambiar cuenta/salir se retira contenido anterior; al recuperar conexión se valida antes de mostrar datos actuales. | Concreta E06 sin ampliar offline. Puede requerir iniciar sesión por separado en web y app instalada; no introduce cierre global de sesiones. |
| 4. Actualizaciones con trabajo abierto | Aviso discreto «Actualización disponible», con Actualizar/Luego. Actualizar resuelve primero Guardar/Descartar/Cancelar y espera o reconcilia envíos inciertos; no fuerza recarga durante edición. | Conserva C-95. No promete supervivencia de borradores si el sistema cierra la app ni exige un service worker específico. |
| 5. Resultado parcial del lote | Resumen con cantidades: quedaron leídas, ya estaban leídas, ya no disponibles y pendientes por error. Mantener los éxitos; no presentar éxito completo si quedan fallos. Mensaje genérico para indisponibles, sin títulos revocados. | Diferencia fracaso real de una operación ya satisfecha o un aviso caducado. La retención de 90 días no cambia. |
| 6. Respuesta incierta y reintento | Mostrar «Comprobando resultado» cuando no se sabe qué llegó al servidor. Tras comprobar, ofrecer reintento explícito solo de fallos pendientes autorizados del lote original. Deshabilitar doble envío mientras se procesa; mantener contador reconciliado. | No incluye nuevos avisos ni páginas posteriores, no repite éxitos ni crea cola offline. Si no puede comprobarse todavía, conservar estado pendiente sin inventar confirmación. |

## Validación necesaria después de especificar

Casos mínimos: instalación y login en equipo real; enlace privado desde navegador y desde instalada; cuenta A → cerrar → cuenta B → Atrás/reabrir; pérdida de permiso con pantalla abierta, desconexión y reconexión; actualización con borrador y con respuesta de guardado incierta. No atribuir a la app control sobre capturas del sistema operativo ni retirada instantánea de información mientras está totalmente desconectada.

Lote: 20 cargadas de 80, llegada posterior, dos fallos parciales, lectura concurrente desde otra pestaña, caducidad/revocación durante envío y respuesta perdida después de confirmación del servidor. Comprobar que nunca se modifican las 60 no cargadas, que el reintento no incorpora las nuevas y que los contadores no filtran datos inaccesibles. Estos escenarios desarrollan ERR-PL09/10; **no fueron ejecutados**.
