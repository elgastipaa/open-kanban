\set ON_ERROR_STOP on
\echo 'Cargando el inventario de tableros sintéticos anterior al corte privado'

CREATE SCHEMA issue52_rehearsal;

CREATE TABLE issue52_rehearsal.actors (
  actor_id uuid PRIMARY KEY,
  email text NOT NULL UNIQUE,
  google_subject text NOT NULL UNIQUE,
  intended_role text NOT NULL CHECK (intended_role IN ('board_owner', 'bootstrap_admin'))
);

CREATE TABLE issue52_rehearsal.inventory (
  board_id uuid PRIMARY KEY REFERENCES public.boards(id),
  slug text NOT NULL UNIQUE,
  explicit_owner_id uuid NOT NULL REFERENCES auth.users(id),
  expected_task_id uuid NOT NULL,
  expected_task_title text NOT NULL
);

CREATE TABLE issue52_rehearsal.bootstrap (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  admin_id uuid NOT NULL REFERENCES auth.users(id),
  admin_email text NOT NULL UNIQUE,
  admin_subject text NOT NULL UNIQUE
);

INSERT INTO issue52_rehearsal.actors (actor_id, email, google_subject, intended_role) VALUES
  ('52100000-0000-4000-8000-000000000001', 'issue52-owner-a@example.test', 'issue52-owner-a', 'board_owner'),
  ('52100000-0000-4000-8000-000000000002', 'issue52-owner-b@example.test', 'issue52-owner-b', 'board_owner'),
  ('52100000-0000-4000-8000-000000000003', 'issue52-bootstrap-admin@example.test', 'issue52-bootstrap-admin', 'bootstrap_admin');

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('52100000-0000-4000-8000-000000000001', 'issue52-owner-a@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('52100000-0000-4000-8000-000000000002', 'issue52-owner-b@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('52100000-0000-4000-8000-000000000003', 'issue52-bootstrap-admin@example.test', clock_timestamp(), '{"provider":"google"}');

INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('52200000-0000-4000-8000-000000000001', '52100000-0000-4000-8000-000000000001', 'google', 'issue52-owner-a', '{"email":"issue52-owner-a@example.test","email_verified":true}'),
  ('52200000-0000-4000-8000-000000000002', '52100000-0000-4000-8000-000000000002', 'google', 'issue52-owner-b', '{"email":"issue52-owner-b@example.test","email_verified":true}'),
  ('52200000-0000-4000-8000-000000000003', '52100000-0000-4000-8000-000000000003', 'google', 'issue52-bootstrap-admin', '{"email":"issue52-bootstrap-admin@example.test","email_verified":true}');

INSERT INTO public.boards (id, slug) VALUES
  ('52000000-0000-4000-8000-000000000001', 'issue52-legacy-a'),
  ('52000000-0000-4000-8000-000000000002', 'issue52-legacy-b');

INSERT INTO public.columns (id, board_id, title, position) VALUES
  ('52400000-0000-4000-8000-000000000001', '52000000-0000-4000-8000-000000000001', 'Entrada A', 0),
  ('52400000-0000-4000-8000-000000000002', '52000000-0000-4000-8000-000000000002', 'Entrada B', 0);

INSERT INTO public.tasks (id, column_id, title, description, priority, position) VALUES
  ('52300000-0000-4000-8000-000000000001', '52400000-0000-4000-8000-000000000001', 'Tarea sintética legado A', 'Contenido ficticio A', 'medium', 0),
  ('52300000-0000-4000-8000-000000000002', '52400000-0000-4000-8000-000000000002', 'Tarea sintética legado B', 'Contenido ficticio B', 'high', 0);

INSERT INTO issue52_rehearsal.inventory (
  board_id, slug, explicit_owner_id, expected_task_id, expected_task_title
) VALUES
  ('52000000-0000-4000-8000-000000000001', 'issue52-legacy-a', '52100000-0000-4000-8000-000000000001',
   '52300000-0000-4000-8000-000000000001', 'Tarea sintética legado A'),
  ('52000000-0000-4000-8000-000000000002', 'issue52-legacy-b', '52100000-0000-4000-8000-000000000002',
   '52300000-0000-4000-8000-000000000002', 'Tarea sintética legado B');

INSERT INTO issue52_rehearsal.bootstrap (admin_id, admin_email, admin_subject) VALUES
  ('52100000-0000-4000-8000-000000000003', 'issue52-bootstrap-admin@example.test', 'issue52-bootstrap-admin');

\echo 'PASS: inventario de dos tableros con propietarios y admin sintéticos elegidos antes de migrar.'
