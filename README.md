# OpenKanban

A modern, real-time Kanban board application built with Next.js, React, and Supabase. OpenKanban provides a seamless, collaborative experience for managing tasks and workflows with beautifully fluid animations and drag-and-drop capabilities.

## Features

* **Real-time Collaboration**: Experience instant updates across clients using Supabase Broadcast and Presence.
* **Fluid Drag and Drop**: Intuitively reorganize columns and tasks with `@hello-pangea/dnd` and Framer Motion.
* **Task Management**: Create, edit, and organize tasks with descriptions and priority levels (low, medium, high, urgent).
* **Column Controls**: Customize your board layout by collapsing columns to focus on what matters most.
* **Import and Export**: Easily migrate your board data in and out of the application.
* **Modern UI**: A responsive, accessible, and aesthetically pleasing interface powered by Tailwind CSS v4.

## Tech Stack

* **Framework**: Next.js 16 (App Router)
* **Library**: React 19
* **Database and Real-time**: Supabase (PostgreSQL)
* **Styling**: Tailwind CSS v4
* **Animations**: motion (Framer Motion)
* **Drag and Drop**: `@hello-pangea/dnd`
* **Icons**: Tabler Icons
* **Linting and Formatting**: Biome
* **Language**: TypeScript

## Getting Started

### Prerequisites

Ensure you have the following installed on your local machine:
* Node.js 24 (`nvm use`, version recorded in `.nvmrc`)
* pnpm 11.3.0 (recorded in `packageManager`; available through Corepack)
* A Supabase account and project

### Installation

1. Clone the repository:
```bash
git clone https://github.com/elgastipaa/open-kanban.git
cd open-kanban
```

2. Install dependencies:
```bash
pnpm install --frozen-lockfile
```

### Supabase Setup

1. Create a dedicated Supabase Free project with fictional data only.
2. Navigate to the SQL Editor in your Supabase dashboard.
3. Execute the migration scripts found in the `supabase/migrations` directory in sequential order:
   * `001_create_boards.sql`
   * `002_create_columns.sql`
   * `003_create_tasks.sql`
   * `004_add_is_collapsed_to_columns.sql`
   * `005_hardened_rls.sql`
   * `006_fix_rls.sql`
   * `007_complete_rpc_coverage.sql`
   * `008_get_full_board.sql`
   * `009_slug_locked_mutations.sql`
   * `010_batch_toggle_columns_collapse.sql`
   * `011_batch_size_guards.sql`
   * `012_harden_rpc_access.sql`
   * `013_separate_task_edits_from_moves.sql`
4. Copy the project URL and **publishable** key from the Connect dialog or Settings → API Keys.

Do not expose the instance before migration 013 is applied. Apply these scripts only once to a new dedicated project; do not blindly rerun the full history on an existing database. Remote SQL execution requires the owner's approval.

Keep Realtime and public channels enabled for the original Broadcast/Presence behavior. Auth, email, Storage, and Postgres Changes subscriptions are not required.

### Environment Variables

Create a `.env.local` file in the root of your project and add your Supabase credentials:

```ini
NEXT_PUBLIC_SUPABASE_PUBLIC_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_your_public_key
NEXT_PUBLIC_SITE_URL=http://localhost:3000
```

Never use a secret key, `service_role` key, or database password in `NEXT_PUBLIC_*`. `.env.local` is excluded from Git. The optional Upstash variables can remain empty; the original visit limiter is then disabled.

### Running the Application

Start the development server:
```bash
pnpm dev
```
Open `http://localhost:3000` in your browser to view the application.

### Validation and deployment

```bash
pnpm lint
pnpm typecheck
pnpm test:db
pnpm audit
pnpm build
pnpm start
```

`test:db` requires native PostgreSQL tools (including `pg_config`, `initdb`, `pg_ctl`, and `psql`) on Linux/WSL/macOS. It creates and removes a disposable cluster with local Unix-socket access only; it never reads `DATABASE_URL` or connects to your Supabase project. Run it as a regular user, not root. No Docker or additional npm dependency is required.

See [installation and Vercel instructions (Spanish)](docs/SETUP.md) and [validation evidence and remaining checks](docs/VALIDATION.md). Deployment and remote database changes are separate approval steps; neither happens during install or build. `vercel.json` disables automatic branch previews and permits Git deployments only from `main` once the project is connected.

### Privacy and recovery

This fork retains the original **anonymous, URL-based access**: anyone who knows a board URL can read, edit, and delete it. No Auth or owner accounts have been added. Use fictional data for the initial evaluation and defer sensitive information until access control is implemented.

Export important boards as JSON and keep the files outside the app. Import replaces an existing board's contents and is not atomic across requests: export first and test restoration into a different disposable URL. Supabase Free may pause inactive projects and does not provide the paid plan's automatic backup recovery. The offline banner is a warning, not durable offline storage.

## Project Structure

* `/src/app`: Next.js App Router pages and layouts.
* `/src/components`: Reusable React components.
  * `/board`: Kanban board specific components (columns, tasks, modals).
  * `/landing`: Components for the marketing and landing pages.
  * `/ui`: Shared UI elements.
* `/src/hooks`: Custom React hooks, including real-time synchronization logic (`use-realtime.ts`, `use-board.ts`).
* `/src/lib`: Utility functions, database integrations, and TypeScript definitions.
* `/supabase`: Database migration scripts and configurations.

## Architecture Highlights

* **Optimistic UI Updates**: The board implements optimistic updates for drag-and-drop operations, ensuring immediate visual feedback before the server confirms the change.
* **Component Modularity**: Complex UI parts are broken down into manageable components such as `Board`, `Column`, `TaskCard`, and `ColumnHeader`.
* **Real-time Sync**: Changes are broadcasted across clients instantly, resolving conflicts seamlessly by preferring the latest server truth.

## Contributing

Contributions are welcome. Please ensure that you follow the existing code style. We use Biome for linting and formatting.

1. Fork the project.
2. Create your feature branch: `git checkout -b feature/amazing-feature`
3. Commit your changes: `git commit -m "Add some amazing feature"`
4. Push to the branch: `git push origin feature/amazing-feature`
5. Open a Pull Request.

Make sure to run the following commands before committing:
```bash
pnpm run format
pnpm run lint
```

## License

This project is licensed under the MIT License. See the LICENSE file for more details.
