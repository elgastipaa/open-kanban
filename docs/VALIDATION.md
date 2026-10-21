# Estado de validación — 2026-10-21

Base: upstream `1cef328fbab93a87bd80a3e770327e9236a6d5d3`. Evaluación inicial exclusivamente con datos ficticios. SQL remoto aplicado con aprobación del propietario; despliegue en Vercel todavía no autorizado ni ejecutado.

## Verificado localmente

Entorno: WSL Ubuntu, Node 24.14.1, pnpm 11.3.0, PostgreSQL 16 descartable. La aplicación no incorpora una dependencia nueva de testing.

| Comprobación | Resultado |
| --- | --- |
| Instalación con lockfile congelado | Aprobada tras adaptar la configuración de scripts de pnpm 11. |
| `pnpm lint` | Aprobado, sin reescribir código. |
| `pnpm typecheck` | Aprobado. |
| `pnpm test:db` | Aprobado; aplica 001–012 en un cluster nuevo y lo elimina al terminar. |
| SQL inicial combinado | Aprobado también como una única transacción con las 12 migraciones, seguido de las mismas regresiones. |
| `pnpm audit` | Cero avisos conocidos de todas las severidades, incluidas dependencias de desarrollo. |
| `pnpm build` | Aprobado con Next.js 16.4.2 / React 19.2.9. |
| Build de producción servido localmente | Landing escritorio/móvil y logo cargan sin errores JavaScript; rutas públicas responden 200. |
| Configuración de instancia | Metadata, sitemap y robots usan el origen local; el prefijo de la landing ya no usa el dominio del autor. |
| Proxy | `/My_Test` redirige con 308 a `/my-test`. |
| Worker bajo la CSP de la aplicación | Aprobado en Chromium después de agregar `worker-src 'self' blob:`. |

Las comprobaciones de navegador utilizaron un runner Playwright ya disponible en el equipo, desde scripts de diagnóstico ignorados en `.temp`; no se agregó al manifest del proyecto. Se revisaron capturas de escritorio y móvil. El build se repitió después de configurar las variables públicas de Supabase para las pruebas conectadas detalladas abajo.

## Evidencia rojo → verde

1. **RPC antigua sin slug:** con 001–011, la llamada anónima `delete_board_p(uuid)` era ejecutable. El test falló con `Legacy mutation is callable without a slug`. Después de 012, las nueve firmas antiguas quedan retiradas y el test pasa.
2. **Movimiento individual:** el RPC actual aceptaba una columna de otro tablero. El test falló con `Task can be moved into another board`; con la comprobación de destino pasa y conserva el estado del origen.
3. **Lote de movimientos:** un lote con un destino ajeno era aceptado. El test falló con `Batch can move a task into another board`; ahora se rechaza completo y se verifica que tampoco persista el primer cambio del lote.
4. **CSP:** Chromium informó que el worker Blob estaba bloqueado por la directiva `script-src` heredada como fallback. La misma prueba obtiene `ready` y cero violaciones con `worker-src` explícita.

Las pruebas SQL usan los RPC reales como `anon`, con tablas y RLS reales. Además verifican ediciones, prioridades, movimientos dentro del tablero, orden de columnas, plegado, borrados en cascada, rechazo de escritura con un slug ajeno, bloqueo de acceso directo a tablas, resistencia a tablas temporales que intenten sombrear nombres y ausencia de permisos implícitos para `authenticated` mientras Auth está fuera de alcance.

El original pasó lint y build antes de los cambios. La instalación de pnpm 11 detectó la opción heredada `ignoredBuiltDependencies`, sustituida por `allowBuilds` conservando las decisiones originales de no ejecutar esos scripts. La auditoría inicial reportó 49 avisos; se actualizaron Next/React y únicamente las dependencias transitivas afectadas. No se cambiaron las versiones resueltas de los componentes visuales.

## Verificado: Supabase dedicado y navegador conectado

El propietario creó el proyecto Free dedicado. Antes de escribir se comprobó que `public` no contenía tablas. Con su aprobación explícita se aplicaron las migraciones 001–012 juntas en una transacción; resultado `COMMIT`. El SQL combinado coincidía exactamente con el historial versionado (SHA-256 `da80e1dafc46e1e2a12ecebca40caa568afa2fcd77f54ccf944a4d960a8db173`). No volver a ejecutar el historial inicial sobre esta instancia.

La conexión administrativa se hizo desde Windows porque WSL no tenía ruta IPv6 al endpoint directo. Se verificó TLS con la CA pública de Supabase y `rejectUnauthorized: true`; no se desactivó la validación de certificados. La contraseña no se guardó en archivos del proyecto. `.env.local`, excluido de Git, contiene solamente URL, clave publicable y origen local.

Se ejecutaron también las regresiones de `tests/db/security.sql` contra Supabase dentro de su transacción con `ROLLBACK`: aprobadas, sin fixtures persistidos. Las tres tablas tienen RLS activo y los 15 RPC de aplicación tienen los permisos y `search_path` esperados. Se recargó la caché de esquema de PostgREST.

Build de producción servido en `127.0.0.1:3017`, conectado por HTTPS/WSS al proyecto real usando exclusivamente la clave publicable:

- [x] Crear un tablero ficticio desde una URL nueva, agregar una tarea y recuperar el contenido después de recargar.
- [x] Crear/editar/borrar tareas; comprobar descripción, las cuatro prioridades y orden. La modificación de título también está cubierta en las regresiones SQL.
- [x] Crear/renombrar/mover/plegar/borrar columnas; comprobar cascadas y confirmaciones.
- [x] Mover tareas entre columnas con el drag/drop accesible por teclado; ordenar y mover entre columnas con controles móviles.
- [x] Plegar/desplegar todas las columnas con los atajos de teclado originales; verificar navegación y controles móviles.
- [x] Abrir dos contextos independientes, comprobar presencia y sincronización después de crear, editar, mover y borrar, incluido el borrado del tablero.
- [x] Exportar e importar en otra URL ficticia; comparar títulos, descripciones, prioridades, posiciones y estructura. Reimportar sobre ese destino y verificar reemplazo sin duplicación.
- [x] Interrumpir la conexión del navegador, comprobar el aviso de error al guardar y verificar que la tarea fallida no existe en la base.
- [x] Confirmar en Supabase que las firmas antiguas no están expuestas y que siguen bloqueados los destinos ajenos.
- [x] Cero errores JavaScript no capturados durante el recorrido conectado.
- [ ] Autorizar y efectuar el despliegue de la revisión aprobada; repetir los recorridos anteriores en la URL pública.

Los tableros de navegador usaron slugs únicos `qa-fictional-<timestamp>` y su destino `-import`. Se eliminaron exclusivamente esos fixtures al terminar, incluidos columnas y tareas. No se usaron datos personales. La aplicación funciona localmente contra Supabase; esto todavía no constituye validación de Vercel ni una prueba exhaustiva de concurrencia o recuperación ante importaciones parcialmente fallidas.

## Límites conservados del original

- Acceso anónimo por URL: cualquiera que la conoce puede leer, escribir y borrar. Auth y propiedad de los tableros quedan para otra fase.
- Upstash sin configurar: no está activo el limitador opcional de visitas. Tampoco cubriría las llamadas directas a Supabase.
- Sin almacenamiento durable offline ni recuperación de URL mediante una cuenta.
- Importación reemplaza contenido mediante varias solicitudes sin transacción global; exportar antes. Su comportamiento ante un fallo parcial queda pendiente de validación con Supabase.
- Borrar el texto de una descripción puede conservar la anterior por el `COALESCE` original; candidato pendiente de reproducción funcional, fuera de estas correcciones.
- Los lotes de posiciones conservan el máximo original de 200 elementos. No se prometen tableros grandes sin probar ese límite.

No se incorporan mejoras de producto a partir de estos límites sin probar el producto y acordar una necesidad concreta.
