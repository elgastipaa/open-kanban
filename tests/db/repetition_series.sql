\set ON_ERROR_STOP on

-- Series queries use a real disposable PostgreSQL cluster and synthetic users.
INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue27@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '42700000-0000-4000-8000-000000000002',
  'issue27@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '52700000-0000-4000-8000-000000000002',
  '42700000-0000-4000-8000-000000000002', 'google', 'issue27-google-subject',
  '{"email":"issue27@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '42700000-0000-4000-8000-000000000002',
    google_subject = 'issue27-google-subject', state = 'active'
WHERE email = 'issue27@example.test';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_one record;
  v_board_two record;
  v_column_one record;
  v_column_two record;
  v_task record;
  v_created jsonb;
  v_due_edit jsonb;
  v_completion jsonb;
  v_series_a jsonb;
  v_series_b jsonb;
  v_list jsonb;
  v_next jsonb;
  v_history jsonb;
  v_deleted jsonb;
  v_hidden_list jsonb;
  v_first_series_id uuid;
  v_second_series_id uuid;
  v_page_one_series_id uuid;
  v_cursor_created_at timestamptz;
  v_cursor_id uuid;
  v_start_on date := (current_date + 7);
  v_pattern jsonb := '{"frequency":"daily","interval":1}'::jsonb;
BEGIN
  SELECT * INTO v_board_one FROM public.create_board_p(
    'Series #27 principal', 'America/Argentina/Buenos_Aires',
    '27000000-0000-4000-8000-000000000010'
  );
  SELECT * INTO v_column_one FROM public.create_column_p(
    v_board_one.slug, v_board_one.id, 'A organizar', 0
  );
  SELECT * INTO v_board_two FROM public.create_board_p(
    'Series #27 segundo', 'America/Argentina/Buenos_Aires',
    '27000000-0000-4000-8000-000000000011'
  );
  SELECT * INTO v_column_two FROM public.create_column_p(
    v_board_two.slug, v_board_two.id, 'A organizar', 0
  );

  v_created := public.create_task_p(
    '27000000-0000-4000-8000-000000000012', v_board_one.id,
    v_column_one.id, 'Ocurrencia completada oculta', 'Descripción original', 'high'
  );
  SELECT task.* INTO v_task FROM public.tasks AS task
  WHERE task.id = (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000013', v_board_one.slug, v_task.id,
    pg_catalog.jsonb_build_object('due_on', v_start_on), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic first task date setup failed: %', v_due_edit;
  END IF;
  v_series_a := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000014', v_board_one.slug, v_task.id,
    v_start_on, NULL, 3, 2, false, NULL, v_pattern, 0, v_column_one.id
  );
  IF v_series_a->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic first series setup failed: %', v_series_a;
  END IF;
  v_first_series_id := (v_series_a->>'series_id')::uuid;
  v_completion := public.set_task_completion_p(
    '27000000-0000-4000-8000-000000000015', v_board_one.slug, v_task.id,
    true, (v_task.completion_version)::bigint, NULL
  );
  IF v_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic hidden completed occurrence setup failed: %', v_completion;
  END IF;

  v_created := public.create_task_p(
    '27000000-0000-4000-8000-000000000016', v_board_one.id,
    v_column_one.id, 'Segunda serie del tablero', NULL, 'medium'
  );
  SELECT task.* INTO v_task FROM public.tasks AS task
  WHERE task.id = (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000017', v_board_one.slug, v_task.id,
    pg_catalog.jsonb_build_object('due_on', v_start_on + 1), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic second task date setup failed: %', v_due_edit;
  END IF;
  v_series_b := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000018', v_board_one.slug, v_task.id,
    v_start_on + 1, NULL, 2, 2, false, NULL, v_pattern, 0, v_column_one.id
  );
  IF v_series_b->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic second series setup failed: %', v_series_b;
  END IF;
  v_second_series_id := (v_series_b->>'series_id')::uuid;

  v_created := public.create_task_p(
    '27000000-0000-4000-8000-000000000019', v_board_two.id,
    v_column_two.id, 'Serie de otro tablero', NULL, 'low'
  );
  SELECT task.* INTO v_task FROM public.tasks AS task
  WHERE task.id = (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000020', v_board_two.slug, v_task.id,
    pg_catalog.jsonb_build_object('due_on', v_start_on + 2), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic second board task date setup failed: %', v_due_edit;
  END IF;
  v_created := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000021', v_board_two.slug, v_task.id,
    v_start_on + 2, NULL, 2, 2, false, NULL, v_pattern, 0, v_column_two.id
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic second board series setup failed: %', v_created;
  END IF;

  -- A completed/hidden current task must not hide its series from Series.
  v_list := public.list_repetition_series_p(v_board_one.id, NULL, NULL, 1);
  IF v_list->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(v_list->'series') <> 1
    OR v_list->>'has_more' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Series list was coupled to visible task rows or ignored its page size: %', v_list;
  END IF;
  v_cursor_created_at := (v_list->'next_cursor'->>'created_at')::timestamptz;
  v_cursor_id := (v_list->'next_cursor'->>'id')::uuid;
  v_page_one_series_id := (v_list->'series'->0->>'id')::uuid;
  v_next := public.list_repetition_series_p(
    v_board_one.id, v_cursor_created_at, v_cursor_id, 1
  );
  IF v_next->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(v_next->'series') <> 1
    OR (v_next->'series'->0->>'id')::uuid = v_page_one_series_id
    OR v_next->>'has_more' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'Series cursor pagination repeated or lost an accessible series: %', v_next;
  END IF;
  IF (v_next->'series'->0->>'id')::uuid NOT IN (v_first_series_id, v_second_series_id)
    OR (v_next->'series'->0->>'board_id')::uuid IS DISTINCT FROM v_board_one.id THEN
    RAISE EXCEPTION 'Filtering by board returned a series from another board: %', v_next;
  END IF;

  v_history := public.get_repetition_history_page_p(
    v_first_series_id, NULL, NULL, 20
  );
  IF v_history->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(v_history->'occurrences') <> 1
    OR v_history->'occurrences'->0->>'state' IS DISTINCT FROM 'current'
    OR v_history->'occurrences'->0->>'title' IS DISTINCT FROM 'Ocurrencia completada oculta'
    OR v_history->'occurrences'->0->>'is_completed' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Accessible occurrence history omitted its current hidden task: %', v_history;
  END IF;

  IF public.list_repetition_series_p(
      '27000000-0000-4000-8000-000000000099', NULL, NULL, 20
    )->'series' IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'Series list disclosed a board the actor cannot access';
  END IF;

  v_deleted := public.delete_task_p(
    '27000000-0000-4000-8000-000000000024', v_board_one.slug,
    (v_series_a->>'task_id')::uuid, 'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic hidden-card setup failed: %', v_deleted;
  END IF;
  v_hidden_list := public.list_repetition_series_p(v_board_one.id, NULL, NULL, 20);
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_hidden_list->'series') AS entry(value)
    WHERE entry.value->>'id' = v_first_series_id::text
      AND entry.value->>'current_task_id' IS NULL
  ) THEN
    RAISE EXCEPTION 'A series became inaccessible when its card was not visible: %', v_hidden_list;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: accessible series remain listed without visible cards through stable authorized pages.'
