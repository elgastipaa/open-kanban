\set ON_ERROR_STOP on
\echo 'Testing complete portable exports, snapshot consistency, access revalidation, and attachment pins'

INSERT INTO public.application_access (email, state, is_admin) VALUES
  ('issue42-owner@example.test', 'pending', false),
  ('issue42-collaborator@example.test', 'pending', false),
  ('issue42-outsider@example.test', 'pending', true);

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('84200000-0000-4000-8000-000000000001', 'issue42-owner@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('84200000-0000-4000-8000-000000000002', 'issue42-collaborator@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('84200000-0000-4000-8000-000000000003', 'issue42-outsider@example.test', clock_timestamp(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('84300000-0000-4000-8000-000000000001', '84200000-0000-4000-8000-000000000001', 'google', 'issue42-owner', '{"email":"issue42-owner@example.test","email_verified":true}'),
  ('84300000-0000-4000-8000-000000000002', '84200000-0000-4000-8000-000000000002', 'google', 'issue42-collaborator', '{"email":"issue42-collaborator@example.test","email_verified":true}'),
  ('84300000-0000-4000-8000-000000000003', '84200000-0000-4000-8000-000000000003', 'google', 'issue42-outsider', '{"email":"issue42-outsider@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = auth_user.id,
    google_subject = identity.provider_id,
    state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE access.email = auth_user.email AND identity.provider = 'google';

CREATE TABLE public.issue42_export_fixture (
  board_id uuid,
  board_slug text,
  generation_id uuid,
  column_id uuid,
  task_id uuid,
  active_label_id uuid,
  unused_label_id uuid,
  deleted_label_id uuid,
  birthday_id uuid,
  deleted_birthday_id uuid,
  old_series_id uuid,
  new_series_id uuid,
  attachment_id uuid,
  deleted_task_id uuid,
  owner_export_id uuid,
  collaborator_export_id uuid
);
GRANT SELECT, INSERT, UPDATE ON public.issue42_export_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '84200000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task_result jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Issue 42 complete export fixture',
    'America/Argentina/Buenos_Aires',
    '84400000-0000-4000-8000-000000000001'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Activas', 0);
  v_task_result := public.create_task_p(
    '84500000-0000-4000-8000-000000000001',
    v_board.id,
    v_column_id,
    'Tarea vigente'
  );
  INSERT INTO public.issue42_export_fixture (
    board_id, board_slug, generation_id, column_id, task_id,
    deleted_task_id
  ) VALUES (
    v_board.id, v_board.slug,
    (SELECT active_generation_id FROM public.boards WHERE id = v_board.id),
    v_column_id, (v_task_result->'task'->>'id')::uuid,
    '84600000-0000-4000-8000-000000000001'
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT fixture.board_id, '84200000-0000-4000-8000-000000000002', 'collaborator'
FROM issue42_export_fixture AS fixture;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '84200000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture record;
BEGIN
  SELECT * INTO fixture FROM public.issue42_export_fixture;
  PERFORM public.set_task_assignee_p(
    '84500000-0000-4000-8000-000000000002', fixture.board_slug,
    fixture.task_id, '84200000-0000-4000-8000-000000000002', 1
  );
END;
$$;
COMMIT;

SELECT set_config('request.jwt.claim.sub', '84200000-0000-4000-8000-000000000001', false);

UPDATE public.tasks AS task
SET description = 'Texto sintético con una URL que el exportador conserva como texto: https://example.invalid/no-fetch',
    steps = '[{"id":"84d00000-0000-4000-8000-000000000001","text":"Paso sintético","is_completed":false,"position":0,"version":1}]'::jsonb
FROM issue42_export_fixture AS fixture
WHERE task.id = fixture.task_id;

INSERT INTO public.task_comments(
  id, board_id, task_id, author_id, author_name, content, created_at
)
SELECT
  '84700000-0000-4000-8000-000000000001', fixture.board_id, fixture.task_id,
  '84200000-0000-4000-8000-000000000001', 'Autora de prueba',
  'Comentario sintético conservado.', clock_timestamp()
FROM issue42_export_fixture AS fixture;
INSERT INTO public.task_comments(
  id, board_id, task_id, author_id, author_name, content, created_at,
  deleted_at, deleted_by, deletion_cause
)
SELECT
  '84700000-0000-4000-8000-000000000002', fixture.board_id, fixture.task_id,
  '84200000-0000-4000-8000-000000000001', 'Autora de prueba',
  'Comentario eliminado que no debe exportarse.', clock_timestamp(),
  clock_timestamp(), '84200000-0000-4000-8000-000000000001', 'moderation'
FROM issue42_export_fixture AS fixture;

INSERT INTO public.board_labels(id, board_id, generation_id, name, color, created_by)
SELECT
  '84800000-0000-4000-8000-000000000001', board_id, generation_id,
  'Etiqueta asignada', 'blue', '84200000-0000-4000-8000-000000000001'
FROM issue42_export_fixture;
INSERT INTO public.board_labels(id, board_id, generation_id, name, color, created_by)
SELECT
  '84800000-0000-4000-8000-000000000002', board_id, generation_id,
  'Catálogo sin asignaciones', 'green', '84200000-0000-4000-8000-000000000001'
FROM issue42_export_fixture;
INSERT INTO public.board_labels(id, board_id, generation_id, name, color, created_by, deleted_at)
SELECT
  '84800000-0000-4000-8000-000000000003', board_id, generation_id,
  'Etiqueta eliminada', 'gray', '84200000-0000-4000-8000-000000000001', clock_timestamp()
FROM issue42_export_fixture;
UPDATE issue42_export_fixture
SET active_label_id = '84800000-0000-4000-8000-000000000001',
    unused_label_id = '84800000-0000-4000-8000-000000000002',
    deleted_label_id = '84800000-0000-4000-8000-000000000003';
INSERT INTO public.board_label_task_assignments(board_id, generation_id, label_id, task_id)
SELECT fixture.board_id, fixture.generation_id, fixture.active_label_id, fixture.task_id
FROM issue42_export_fixture AS fixture;

INSERT INTO public.board_birthdays(
  id, board_id, generation_id, name, birth_month, birth_day, advance_days, created_by
)
SELECT
  '84900000-0000-4000-8000-000000000001', board_id, generation_id,
  'Calendario sintético', 2, 29, 7, '84200000-0000-4000-8000-000000000001'
FROM issue42_export_fixture;
INSERT INTO public.board_birthdays(
  id, board_id, generation_id, name, birth_month, birth_day, advance_days, created_by
)
SELECT
  '84900000-0000-4000-8000-000000000002', board_id, generation_id,
  'Calendario eliminado', 3, 10, NULL, '84200000-0000-4000-8000-000000000001'
FROM issue42_export_fixture;
UPDATE issue42_export_fixture
SET birthday_id = '84900000-0000-4000-8000-000000000001',
    deleted_birthday_id = '84900000-0000-4000-8000-000000000002';
INSERT INTO public.birthday_deletions(
  birthday_id, board_id, generation_id, deleted_by, deleted_at, expires_at,
  birthday_snapshot, state
)
SELECT
  fixture.deleted_birthday_id, fixture.board_id, fixture.generation_id,
  '84200000-0000-4000-8000-000000000001', v.now_at,
  v.now_at + interval '168 hours',
  '{"id":"84900000-0000-4000-8000-000000000002","name":"Calendario eliminado"}'::jsonb,
  'deleted'
FROM issue42_export_fixture AS fixture
CROSS JOIN LATERAL (SELECT clock_timestamp() AS now_at) AS v;
INSERT INTO public.board_label_birthday_assignments(board_id, generation_id, label_id, birthday_id)
SELECT fixture.board_id, fixture.generation_id, fixture.active_label_id, fixture.birthday_id
FROM issue42_export_fixture AS fixture;

INSERT INTO public.daily_repetition_series(
  id, board_id, generation_id, created_by, origin_task_id, first_task_id,
  appearance_column_id, rule, start_on, latest_occurrence_on, next_due_on,
  calendar_pattern, advance_days, state, stopped_at, template_snapshot
)
SELECT
  '84a00000-0000-4000-8000-000000000001', board_id, generation_id,
  '84200000-0000-4000-8000-000000000001', task_id, task_id, column_id,
  'daily', DATE '2026-10-01', DATE '2026-10-02', NULL,
  '{"frequency":"daily","interval":1}'::jsonb, 0,
  'stopped', clock_timestamp(),
  '{"title":"Serie anterior","description":null,"priority":"medium","steps":[]}'::jsonb
FROM issue42_export_fixture;
INSERT INTO public.daily_repetition_series(
  id, board_id, generation_id, created_by, origin_task_id, first_task_id,
  appearance_column_id, rule, start_on, latest_occurrence_on, next_due_on,
  calendar_pattern, advance_days, state, template_snapshot
)
SELECT
  '84a00000-0000-4000-8000-000000000002', board_id, generation_id,
  '84200000-0000-4000-8000-000000000001', task_id, task_id, column_id,
  'weekly', DATE '2026-10-02', DATE '2026-10-02', DATE '2026-11-03',
  '{"frequency":"weekly","interval":2,"weekdays":[1,3]}'::jsonb, 3,
  'active',
  '{"title":"Serie actual","description":null,"priority":"medium","steps":[]}'::jsonb
FROM issue42_export_fixture;
UPDATE issue42_export_fixture
SET old_series_id = '84a00000-0000-4000-8000-000000000001',
    new_series_id = '84a00000-0000-4000-8000-000000000002';
INSERT INTO public.board_label_repetition_assignments(
  board_id, generation_id, label_id, series_id
)
SELECT fixture.board_id, fixture.generation_id,
  fixture.unused_label_id, fixture.new_series_id
FROM issue42_export_fixture AS fixture;
INSERT INTO public.daily_repetition_occurrences(
  id, series_id, occurrence_on, task_id, state, transferred_to_series_id
)
SELECT
  '84a10000-0000-4000-8000-000000000001', fixture.old_series_id,
  DATE '2026-10-01', fixture.task_id, 'transferred', fixture.new_series_id
FROM issue42_export_fixture AS fixture;
INSERT INTO public.daily_repetition_occurrences(id, series_id, occurrence_on, task_id, state)
SELECT
  '84a10000-0000-4000-8000-000000000002', fixture.new_series_id,
  DATE '2026-10-02', fixture.task_id, 'current'
FROM issue42_export_fixture AS fixture;
INSERT INTO public.daily_repetition_occurrences(id, series_id, occurrence_on, task_id, state)
SELECT
  '84a10000-0000-4000-8000-000000000003', fixture.new_series_id,
  DATE '2026-10-03', fixture.task_id, 'excluded'
FROM issue42_export_fixture AS fixture;
INSERT INTO public.daily_repetition_occurrences(id, series_id, occurrence_on, task_id, state)
SELECT
  '84a10000-0000-4000-8000-000000000004', fixture.new_series_id,
  DATE '2026-10-04', fixture.task_id, 'purged'
FROM issue42_export_fixture AS fixture;
UPDATE public.daily_repetition_series AS series
SET current_occurrence_id = CASE series.id
  WHEN '84a00000-0000-4000-8000-000000000001'::uuid THEN '84a10000-0000-4000-8000-000000000001'::uuid
  ELSE '84a10000-0000-4000-8000-000000000002'::uuid END
WHERE series.id IN (
  '84a00000-0000-4000-8000-000000000001',
  '84a00000-0000-4000-8000-000000000002'
);

INSERT INTO public.task_activity_events(
  id, board_id, task_id, category, actor_type, actor_name,
  occurred_at, before_value, after_value
)
SELECT
  '84b00000-0000-4000-8000-000000000001', board_id, task_id,
  'due_date', 'user', 'Autora de prueba', clock_timestamp() - interval '179 days',
  'null'::jsonb, '"2026-11-02"'::jsonb
FROM issue42_export_fixture;
INSERT INTO public.task_activity_events(
  id, board_id, task_id, category, actor_type, actor_name,
  occurred_at, before_value, after_value
)
SELECT
  '84b00000-0000-4000-8000-000000000002', board_id, task_id,
  'due_date', 'user', 'Actividad vencida', clock_timestamp() - interval '181 days',
  'null'::jsonb, '"2026-11-02"'::jsonb
FROM issue42_export_fixture;

INSERT INTO public.task_attachments(
  id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
  size_bytes, sha256, object_key, state
)
SELECT
  '84c00000-0000-4000-8000-000000000001', board_id, task_id,
  '84200000-0000-4000-8000-000000000001', '84c10000-0000-4000-8000-000000000001',
  'acta.txt', octet_length(convert_to('adjunto sintético', 'UTF8')),
  extensions.digest(convert_to('adjunto sintético', 'UTF8'), 'sha256'),
  'attachments/84c00000-0000-4000-8000-000000000001', 'active'
FROM issue42_export_fixture;
UPDATE issue42_export_fixture
SET attachment_id = '84c00000-0000-4000-8000-000000000001';

INSERT INTO public.task_deletions(
  task_id, board_id, original_column_id, deleted_by, cause,
  deleted_at, expires_at, task_snapshot, state
)
SELECT
  fixture.deleted_task_id, fixture.board_id, fixture.column_id,
  '84200000-0000-4000-8000-000000000001', 'user_requested',
  v.now_at, v.now_at + interval '168 hours',
  '{"title":"Tarea eliminada"}'::jsonb, 'deleted'
FROM issue42_export_fixture AS fixture
CROSS JOIN LATERAL (SELECT clock_timestamp() AS now_at) AS v;

DO $$
DECLARE
  fixture record;
  v_created jsonb;
  v_denied jsonb;
  v_collaborator_created jsonb;
  v_page jsonb;
  v_payload jsonb;
  v_entity_names text[];
  v_attachment_expiry timestamptz;
  v_attachment_state text;
  v_pin_count bigint;
  v_pin_expiry timestamptz;
  v_now_at timestamptz;
  v_claimed integer;
  v_cleaned integer;
  v_all_payloads text;
BEGIN
  SELECT * INTO fixture FROM public.issue42_export_fixture;

  v_denied := public.create_board_export_snapshot_p(
    '84200000-0000-4000-8000-000000000003', fixture.board_slug
  );
  IF v_denied->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'An administrator outside the board created an export: %', v_denied;
  END IF;

  v_created := public.create_board_export_snapshot_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug
  );
  IF v_created->>'status' <> 'created'
    OR v_created->>'time_zone' <> 'America/Argentina/Buenos_Aires'
    OR (v_created->>'schema_version')::integer <> 68
    OR (v_created->>'attachment_pins')::integer <> 1 THEN
    RAISE EXCEPTION 'The owner export snapshot was not complete: %', v_created;
  END IF;
  UPDATE public.issue42_export_fixture
  SET owner_export_id = (v_created->>'export_id')::uuid;

  v_collaborator_created := public.create_board_export_snapshot_p(
    '84200000-0000-4000-8000-000000000002', fixture.board_slug
  );
  IF v_collaborator_created->>'status' <> 'created' THEN
    RAISE EXCEPTION 'An active collaborator could not create an export: %', v_collaborator_created;
  END IF;
  UPDATE public.issue42_export_fixture
  SET collaborator_export_id = (v_collaborator_created->>'export_id')::uuid;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000003', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'board', 0, 10
  );
  IF v_page->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'A package ID granted access to a different actor: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000002', fixture.board_slug,
    (v_collaborator_created->>'export_id')::uuid, 'board', 0, 10
  );
  IF v_page->>'status' <> 'page' THEN
    RAISE EXCEPTION 'The collaborator could not read their own export: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'labels', 0, 100
  );
  IF v_page->>'status' <> 'page'
    OR (v_page->>'record_count')::integer <> 2
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'id' = public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'label', fixture.unused_label_id
      )
    )
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'id' = public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'label', fixture.deleted_label_id
      )
    ) THEN
    RAISE EXCEPTION 'The active label catalog or deletion exclusion is wrong: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'birthdays', 0, 100
  );
  IF (v_page->>'record_count')::integer <> 1
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'id' = public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'birthday', fixture.birthday_id
      )
    ) THEN
    RAISE EXCEPTION 'The active calendar did not export with deleted birthdays excluded: %', v_page;
  END IF;
  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'birthday_labels', 0, 100
  );
  IF (v_page->>'record_count')::integer <> 1 THEN
    RAISE EXCEPTION 'Birthday label associations were not captured: %', v_page;
  END IF;
  IF v_page->'items'->0->'payload'->>'birthday_id'
      <> public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'birthday', fixture.birthday_id
      )
    OR v_page->'items'->0->'payload'->>'label_id'
      <> public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'label', fixture.active_label_id
      ) THEN
    RAISE EXCEPTION 'Birthday-label links did not use package-local references: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'repetitions', 0, 100
  );
  IF (v_page->>'record_count')::integer <> 2
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'id' = public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'repetition', fixture.new_series_id
      )
        AND item->'payload'->'calendar_pattern'
          = '{"frequency":"weekly","interval":2,"weekdays":[1,3]}'::jsonb
        AND (item->'payload'->>'advance_days')::integer = 3
    ) THEN
    RAISE EXCEPTION 'The export did not preserve the current calendar pattern and appearance lead: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'repetition_labels', 0, 100
  );
  IF (v_page->>'record_count')::integer <> 3
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'series_id' = public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'repetition', fixture.new_series_id
      )
        AND item->'payload'->>'label_id' = public.board_export_package_ref_p(
          (v_created->>'export_id')::uuid, 'label', fixture.unused_label_id
        )
    ) THEN
    RAISE EXCEPTION 'The export did not preserve repetition template label assignments: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'repetition_occurrences', 0, 100
  );
  IF (v_page->>'record_count')::integer <> 4
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'state' = 'transferred'
        AND item->'payload'->>'transferred_to_series_id' = public.board_export_package_ref_p(
          (v_created->>'export_id')::uuid, 'repetition', fixture.new_series_id
        )
    )
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'state' = 'excluded'
    ) THEN
    RAISE EXCEPTION 'The C-112 transfer or calendar exclusions were lost: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'activity', 0, 100
  );
  IF (v_page->>'record_count')::integer <> 2
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'id' = public.board_export_package_ref_p(
        (v_created->>'export_id')::uuid, 'activity',
        '84b00000-0000-4000-8000-000000000001'
      )
        AND item->'payload'->>'category' = 'due_date'
    )
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'actor_name' LIKE '%@%'
        OR item->'payload'->'after_value' #>> '{}' LIKE '%@%'
    ) THEN
    RAISE EXCEPTION 'Only current, privacy-safe activity should be present in the export: %', v_page;
  END IF;

  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'tasks', 0, 100
  );
  IF (v_page->>'record_count')::integer <> 1
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
      WHERE item->'payload'->>'title' = 'Tarea vigente'
        AND item->'payload'->>'assignee_ref' ~ '^member_[0-9a-f]{64}$'
        AND item->'payload'->'steps'->0->>'id' ~ '^step_[0-9a-f]{64}$'
        AND NOT (item->'payload'->'steps'->0 ? 'version')
        AND item->'payload'->>'column_id' = public.board_export_package_ref_p(
          (v_created->>'export_id')::uuid, 'column', fixture.column_id
        )
        AND item->'payload'->>'description' LIKE '%https://example.invalid/no-fetch%'
        AND NOT (item->'payload' ? 'assignee_id')
        AND NOT (item->'payload' ? 'created_by')
    ) THEN
    RAISE EXCEPTION 'A full active task or its package-local attribution was not exported: %', v_page;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_page->'items') AS item
    WHERE item->'payload'->>'assignee_ref' = 'member_' || pg_catalog.encode(
      extensions.digest(
        pg_catalog.convert_to(
          (v_created->>'export_id') || ':issue42-collaborator@example.test',
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    )
  ) THEN
    RAISE EXCEPTION 'The public export ID is enough to guess a member reference: %', v_page;
  END IF;
  SELECT string_agg(item.payload::text, ' ')
  INTO v_all_payloads
  FROM public.board_export_snapshot_items AS item
  WHERE item.export_id = (v_created->>'export_id')::uuid;
  IF v_all_payloads LIKE '%issue42-owner@example.test%'
    OR v_all_payloads LIKE '%84200000-0000-4000-8000-000000000001%'
    OR v_all_payloads LIKE '%' || fixture.board_id::text || '%'
    OR v_all_payloads LIKE '%' || fixture.task_id::text || '%'
    OR v_all_payloads LIKE '%' || fixture.column_id::text || '%'
    OR v_all_payloads LIKE '%84d00000-0000-4000-8000-000000000001%'
    OR v_all_payloads LIKE '%object_key%'
    OR v_all_payloads LIKE '%"email"%'
    OR v_all_payloads LIKE '%"role"%'
    OR v_all_payloads LIKE '%"owner_id"%' THEN
    RAISE EXCEPTION 'The package contains private access or storage metadata: %', v_all_payloads;
  END IF;

  SELECT array_agg(DISTINCT entity ORDER BY entity)
  INTO v_entity_names
  FROM public.board_export_snapshot_items
  WHERE export_id = (v_created->>'export_id')::uuid;
  IF v_entity_names <> ARRAY[
    'activity', 'attachments', 'birthday_labels', 'birthdays', 'board',
    'columns', 'comments', 'labels', 'repetition_labels',
    'repetition_occurrences', 'repetitions', 'task_labels', 'tasks'
  ]::text[] THEN
    RAISE EXCEPTION 'The export allow-list unexpectedly contains or omits entities: %', v_entity_names;
  END IF;

  -- The content file rows are immutable even when live data changes afterward.
  UPDATE public.tasks
  SET title = 'Editado después de capturar'
  WHERE id = fixture.task_id;
  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug,
    (v_created->>'export_id')::uuid, 'tasks', 0, 100
  );
  IF v_page->'items'->0->'payload'->>'title' <> 'Tarea vigente'
    OR (SELECT title FROM public.tasks WHERE id = fixture.task_id)
      <> 'Editado después de capturar' THEN
    RAISE EXCEPTION 'The export page changed after a concurrent task edit: %', v_page;
  END IF;

  -- Revocation is checked again at each download page.
  UPDATE public.board_memberships
  SET revoked_at = clock_timestamp()
  WHERE board_id = fixture.board_id AND user_id = '84200000-0000-4000-8000-000000000002';
  v_page := public.read_board_export_snapshot_page_p(
    '84200000-0000-4000-8000-000000000002', fixture.board_slug,
    (v_collaborator_created->>'export_id')::uuid, 'tasks', 0, 100
  );
  IF v_page->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'A revoked collaborator downloaded another page: %', v_page;
  END IF;

  v_now_at := clock_timestamp();
  UPDATE public.task_attachments
  SET state = 'recoverable', deleted_at = v_now_at - interval '169 hours',
      deleted_by = '84200000-0000-4000-8000-000000000001',
      deletion_cause = 'author',
      expires_at = v_now_at - interval '1 hour'
  WHERE id = fixture.attachment_id;
  SELECT expires_at INTO v_attachment_expiry
  FROM public.task_attachments WHERE id = fixture.attachment_id;
  SELECT count(*) INTO v_claimed
  FROM public.claim_expired_task_attachment_cleanup_p(
    '84c20000-0000-4000-8000-000000000001', 50
  ) AS claimed
  WHERE claimed.attachment_id = fixture.attachment_id;
  SELECT attachment.state INTO v_attachment_state
  FROM public.task_attachments AS attachment
  WHERE attachment.id = fixture.attachment_id;
  SELECT count(*), max(pin.pin_expires_at)
  INTO v_pin_count, v_pin_expiry
  FROM public.board_export_attachment_pins AS pin
  WHERE pin.attachment_id = fixture.attachment_id
    AND pin.pin_expires_at > clock_timestamp();
  IF v_claimed <> 0
    OR (SELECT expires_at FROM public.task_attachments WHERE id = fixture.attachment_id)
      IS DISTINCT FROM v_attachment_expiry THEN
    RAISE EXCEPTION
      'A live export pin did not defer purge without restoring its recovery window (claimed %, state %, live pins %, latest pin %, cutoff %)',
      v_claimed, v_attachment_state, v_pin_count, v_pin_expiry, v_attachment_expiry;
  END IF;

  UPDATE public.board_export_snapshots
  SET created_at = clock_timestamp() - interval '2 hours',
      expires_at = clock_timestamp() - interval '1 second'
  WHERE id IN (
    (v_created->>'export_id')::uuid,
    (v_collaborator_created->>'export_id')::uuid
  );
  UPDATE public.board_export_attachment_pins
  SET pin_expires_at = clock_timestamp() - interval '1 second'
  WHERE export_id IN (
    (v_created->>'export_id')::uuid,
    (v_collaborator_created->>'export_id')::uuid
  );
  v_cleaned := public.cleanup_expired_board_export_snapshots_p(100);
  SELECT count(*) INTO v_claimed
  FROM public.claim_expired_task_attachment_cleanup_p(
    '84c20000-0000-4000-8000-000000000002', 50
  ) AS claimed
  WHERE claimed.attachment_id = fixture.attachment_id;
  IF v_cleaned <> 2 OR v_claimed <> 1
    OR (SELECT expires_at FROM public.task_attachments WHERE id = fixture.attachment_id)
      IS DISTINCT FROM v_attachment_expiry THEN
    RAISE EXCEPTION 'Expired export pins did not clean up or the recovery cutoff moved';
  END IF;

  IF has_function_privilege('anon',
      'public.create_board_export_snapshot_p(uuid,text)', 'EXECUTE')
    OR has_function_privilege('authenticated',
      'public.read_board_export_snapshot_page_p(uuid,text,uuid,text,bigint,integer)', 'EXECUTE')
    OR NOT has_function_privilege('service_role',
      'public.read_board_export_snapshot_page_p(uuid,text,uuid,text,bigint,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Export snapshot RPC grants are not server-only';
  END IF;
END;
$$;

-- A second synthetic object is reserved for the concurrent export-vs-purge test.
INSERT INTO public.task_attachments(
  id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
  size_bytes, sha256, object_key, state
)
SELECT
  '84c00000-0000-4000-8000-000000000002', board_id, task_id,
  '84200000-0000-4000-8000-000000000001', '84c10000-0000-4000-8000-000000000002',
  'race.txt', 1, extensions.digest(convert_to('x', 'UTF8'), 'sha256'),
  'attachments/84c00000-0000-4000-8000-000000000002', 'active'
FROM public.issue42_export_fixture;

INSERT INTO public.tasks(column_id, title, description, priority, position)
SELECT fixture.column_id,
  'Tarea sintética ' || generated.ordinal::text,
  repeat('contenido de medición ', 4),
  'medium', 10000 + generated.ordinal
FROM public.issue42_export_fixture AS fixture
CROSS JOIN generate_series(1, 5000) AS generated(ordinal);

DO $$
DECLARE
  fixture record;
  v_started timestamptz;
  v_elapsed_ms numeric;
  v_created jsonb;
  v_export_id uuid;
  v_payload_bytes bigint;
BEGIN
  SELECT * INTO fixture FROM public.issue42_export_fixture;
  v_started := pg_catalog.clock_timestamp();
  v_created := public.create_board_export_snapshot_p(
    '84200000-0000-4000-8000-000000000001', fixture.board_slug
  );
  v_elapsed_ms := extract(epoch FROM pg_catalog.clock_timestamp() - v_started) * 1000;
  v_export_id := (v_created->>'export_id')::uuid;
  SELECT COALESCE(sum(octet_length(item.payload::text)), 0)
  INTO v_payload_bytes
  FROM public.board_export_snapshot_items AS item
  WHERE item.export_id = v_export_id;
  RAISE NOTICE 'ISSUE42-SNAPSHOT-METRIC tasks=5001 payload_bytes=% elapsed_ms=%',
    v_payload_bytes, pg_catalog.round(v_elapsed_ms, 2);
  PERFORM public.delete_board_export_snapshot_p(
    '84200000-0000-4000-8000-000000000001', v_export_id
  );
END;
$$;

\echo 'PASS: exports snapshot the full active board, revalidate membership, and expire attachment pins without extending recovery'
