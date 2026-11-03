\set ON_ERROR_STOP on
\echo 'Preparando el snapshot de mantenimiento sintético para el ensayo de recuperación'

CREATE SCHEMA issue50_rehearsal;

CREATE TABLE issue50_rehearsal.instance_snapshot (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  snapshot_id uuid NOT NULL UNIQUE,
  checkpoint_at timestamptz NOT NULL,
  maintenance_mode boolean NOT NULL,
  state_marker text NOT NULL,
  app_version text NOT NULL,
  migration_head text NOT NULL
);

CREATE TABLE issue50_rehearsal.fixture (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  owner_id uuid NOT NULL,
  collaborator_id uuid NOT NULL,
  outsider_admin_id uuid NOT NULL,
  board_id uuid NOT NULL,
  generation_id uuid NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  series_id uuid NOT NULL
);

INSERT INTO public.application_access (email, state, is_admin) VALUES
  ('issue50-owner@example.test', 'pending', false),
  ('issue50-collaborator@example.test', 'pending', false),
  ('issue50-outsider-admin@example.test', 'pending', true);

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('85000000-0000-4000-8000-000000000001', 'issue50-owner@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('85000000-0000-4000-8000-000000000002', 'issue50-collaborator@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('85000000-0000-4000-8000-000000000003', 'issue50-outsider-admin@example.test', clock_timestamp(), '{"provider":"google"}');

INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('85100000-0000-4000-8000-000000000001', '85000000-0000-4000-8000-000000000001', 'google', 'issue50-owner', '{"email":"issue50-owner@example.test","email_verified":true}'),
  ('85100000-0000-4000-8000-000000000002', '85000000-0000-4000-8000-000000000002', 'google', 'issue50-collaborator', '{"email":"issue50-collaborator@example.test","email_verified":true}'),
  ('85100000-0000-4000-8000-000000000003', '85000000-0000-4000-8000-000000000003', 'google', 'issue50-outsider-admin', '{"email":"issue50-outsider-admin@example.test","email_verified":true}');

UPDATE public.application_access AS access
SET auth_user_id = auth_user.id,
    google_subject = identity.provider_id,
    state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity
  ON identity.user_id = auth_user.id AND identity.provider = 'google'
WHERE access.email = auth_user.email;

BEGIN;
\o /dev/null
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '85000000-0000-4000-8000-000000000001', true);

SELECT id AS board_id, slug AS board_slug
FROM public.create_board_p(
  'Issue 50 synthetic recovery board', 'UTC',
  '86000000-0000-4000-8000-000000000001'
) \gset issue50_

SELECT id AS column_id
FROM public.create_column_p(:'issue50_board_slug', :'issue50_board_id'::uuid, 'Activas', 0)
\gset issue50_

SELECT id AS second_column_id
FROM public.create_column_p(:'issue50_board_slug', :'issue50_board_id'::uuid, 'Archivadas', 1)
\gset issue50_

SELECT public.create_task_p(
  '86000000-0000-4000-8000-000000000002',
  :'issue50_board_id'::uuid,
  :'issue50_column_id'::uuid,
  'Tarea sintética de recuperación', 'Contenido ficticio', 'high'
) AS task_result
\gset issue50_

SELECT (:'issue50_task_result'::jsonb)->>'task_id' AS task_id
\gset issue50_

SELECT public.edit_task_fields_p(
  '86000000-0000-4000-8000-000000000003',
  :'issue50_board_slug',
  :'issue50_task_id'::uuid,
  jsonb_build_object('due_on', current_date + 7),
  '{"due_on":1}'::jsonb
);

SELECT public.create_repetition_with_advance_p(
  '86000000-0000-4000-8000-000000000004',
  :'issue50_board_slug',
  :'issue50_task_id'::uuid,
  current_date + 7,
  NULL,
  3,
  2,
  false,
  NULL,
  '{"frequency":"daily","interval":1}'::jsonb,
  0,
  :'issue50_column_id'::uuid
) AS series_result
\gset issue50_

SELECT (:'issue50_series_result'::jsonb)->>'series_id' AS series_id
\gset issue50_

COMMIT;
RESET ROLE;
\o

SELECT id AS generation_id
FROM public.board_generations
WHERE board_id = :'issue50_board_id'::uuid AND status = 'active'
\gset issue50_

INSERT INTO public.board_memberships (board_id, user_id, role)
VALUES (
  :'issue50_board_id'::uuid,
  '85000000-0000-4000-8000-000000000002',
  'collaborator'
);

INSERT INTO issue50_rehearsal.fixture (
  owner_id, collaborator_id, outsider_admin_id,
  board_id, generation_id, column_id, task_id, series_id
) VALUES (
  '85000000-0000-4000-8000-000000000001',
  '85000000-0000-4000-8000-000000000002',
  '85000000-0000-4000-8000-000000000003',
  :'issue50_board_id'::uuid,
  :'issue50_generation_id'::uuid,
  :'issue50_column_id'::uuid,
  :'issue50_task_id'::uuid,
  :'issue50_series_id'::uuid
);

INSERT INTO public.daily_repetition_occurrences (series_id, occurrence_on, task_id, state)
VALUES (
  :'issue50_series_id'::uuid,
  current_date + 9,
  '86200000-0000-4000-8000-000000000001',
  'excluded'
);

INSERT INTO storage.objects (bucket_id, name)
VALUES ('task-attachments', 'attachments/issue50/fixture.txt');

INSERT INTO public.task_attachments (
  id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
  size_bytes, sha256, object_key, state
) VALUES (
  '85900000-0000-4000-8000-000000000001',
  :'issue50_board_id'::uuid,
  :'issue50_task_id'::uuid,
  '85000000-0000-4000-8000-000000000001',
  '86000000-0000-4000-8000-000000000005',
  'fixture.txt',
  30,
  decode('3809ddda411bb00f1716d380bc095848b006bf43c459fcee801ca4bfe6fe7e73', 'hex'),
  'attachments/issue50/fixture.txt',
  'active'
);

UPDATE public.task_attachment_quota_ledger
SET active_bytes = 30
WHERE singleton;

INSERT INTO issue50_rehearsal.instance_snapshot (
  singleton, snapshot_id, checkpoint_at, maintenance_mode,
  state_marker, app_version, migration_head
) VALUES (
  true,
  '86100000-0000-4000-8000-000000000001',
  clock_timestamp(),
  true,
  'snapshot-v1',
  '1.0.0',
  '073_revoke_public_helper_execute.sql'
);

\echo 'PASS: instancia sintética, actores, serie, exclusión, cola, cuota y metadatos Storage preparados.'
