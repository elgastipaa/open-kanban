# Instalación de OpenKanban Personal

Esta instancia conserva el producto original sin Auth. Primera evaluación: solo datos ficticios. El fork es público; los archivos `.env*`, salvo el ejemplo vacío, están excluidos de Git.

## 1. Entorno y repositorio

```bash
git clone https://github.com/elgastipaa/open-kanban.git
cd open-kanban
nvm install
nvm use
corepack pnpm install --frozen-lockfile
```

Node local está fijado en `.nvmrc`; Vercel debe usar la rama 24.x. El campo `packageManager` fija pnpm 11.3.0. `upstream` debe apuntar a `https://github.com/Slogllykop/OpenKanban.git` para futuras actualizaciones, revisadas antes de integrarlas.

## 2. Proyecto Supabase Free

El propietario crea un proyecto **dedicado y vacío** en una organización Free. Elegir São Paulo si está disponible y guardar la contraseña de base fuera del repositorio. No activar complementos pagos. No configurar Auth, SMTP, Storage ni Postgres Changes: la aplicación usa PostgreSQL/RPC y Realtime Broadcast/Presence.

En el proyecto, abrir **Connect** para obtener Project URL y Publishable key. También está disponible **Settings → API Keys**. Guardar en `.env.local`:

```dotenv
NEXT_PUBLIC_SUPABASE_PUBLIC_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_your_public_key
NEXT_PUBLIC_SITE_URL=http://localhost:3000
```

No pegar contraseñas o claves secretas en el chat. No usar `sb_secret_...`, `service_role` ni contraseña PostgreSQL en el frontend. URL y clave publicable son configuración pública; RLS y las funciones SQL controlan las operaciones disponibles.

Mantener Realtime y el acceso a canales públicos habilitados. Upstash queda sin configurar y su limitador opcional desactivado.

## 3. Esquema: aprobación separada

Antes de ejecutar SQL remoto, revisar la migración correctiva 012 y la evidencia de las pruebas locales con el propietario. Luego, con su aprobación, aplicar los archivos de `supabase/migrations/` en orden numérico **001 a 012**, sin abrir la aplicación a usuarios entre pasos. La lista exacta está en el README.

Las primeras migraciones crean políticas permisivas; las siguientes las cierran. La 012 retira RPC antiguas sin slug, restringe permisos y evita movimientos de tareas hacia otro tablero. No elimina tablas ni datos del tablero. No ejecutar solo 001–004 ni modificar a mano el historial para omitir pasos.

En un proyecto nuevo se ejecuta todo el historial una sola vez. Si falla un paso, registrar cuál y revisar el estado antes de reintentarlo: varios scripts históricos crean triggers o políticas sin ser idempotentes. En una instancia existente que ya tenga 001–011, revisar primero su estado y aplicar únicamente lo pendiente, con respaldo y aprobación.

## 4. Verificación local

```bash
pnpm lint
pnpm typecheck
pnpm test:db
pnpm audit
pnpm build
pnpm start
```

Las pruebas SQL requieren las herramientas nativas de PostgreSQL (`pg_config` y binarios de servidor/cliente), no un servidor existente. `PG_BINDIR` permite indicar su directorio. El runner utiliza exclusivamente su propio cluster descartable y un socket dentro de `/tmp/openkanban-db.*`; nunca utiliza las variables de conexión de la aplicación.

Abrir `http://localhost:3000`. Verificar también dos clientes simultáneos y móvil según `docs/VALIDATION.md`. Si el puerto 3000 está ocupado, elegir otro al arrancar y ajustar `NEXT_PUBLIC_SITE_URL` antes de compilar. Cambiar variables `NEXT_PUBLIC_*` requiere recompilar producción.

## 5. Vercel Hobby: aprobación separada

Este despliegue se plantea para organización personal no comercial. [Condiciones de Hobby](https://vercel.com/docs/limits/fair-use-guidelines#commercial-usage). No contratar servicios pagos durante esta etapa.

Después de pasar las comprobaciones locales, revisar el PR y autorizar explícitamente la publicación de esa revisión. Recién entonces conectar el repositorio a Vercel y publicar desde `main`.

Configuración:

- Framework: Next.js; Root Directory: raíz del repositorio.
- Node.js: 24.x. Install Command: `pnpm install --frozen-lockfile`.
- Build Command: `pnpm build`. Output Directory: valor automático de Next.js.
- Production Branch: `main`. `vercel.json` impide despliegues automáticos de las demás ramas; no cargar credenciales Supabase en Preview durante esta etapa.
- Variables de Production: las tres anteriores, usando la URL de producción asignada por Vercel para `NEXT_PUBLIC_SITE_URL`. No requiere comprar un dominio.

El proyecto debe tener las variables configuradas antes del primer despliegue. El build no ejecuta migraciones. Comprobar en la URL publicada los recorridos de guardado, recarga, dos clientes, móvil y exportación/importación. Hasta completar esas pruebas, el despliegue no se considera validado.

## 6. Respaldo y actualización

Usar Export para guardar un JSON del tablero fuera de la aplicación. Antes de importar, exportar el estado actual; la importación reemplaza contenido y puede quedar incompleta si falla la red. Comprobar recuperación importando en otra URL ficticia, nunca sobre el único tablero importante.

Supabase Free puede pausar proyectos inactivos. Una página visible no demuestra que sus cambios se hayan persistido: recargar y comprobar desde otro cliente. El aviso offline no guarda una cola durable.

Para actualizar desde el original, traer `upstream`, revisar cambios y migraciones en una rama, ejecutar las comprobaciones y aprobar por separado cambios remotos y despliegue. No restaurar las firmas SQL retiradas por 012. La futura incorporación de Auth deberá proteger también RPC y Realtime; no alcanza con agregar una pantalla de login.
