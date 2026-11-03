\set ON_ERROR_STOP on
\echo 'Issue #30: board label catalog has normalized, board-scoped names'

INSERT INTO public.application_access (email, state, is_admin)
VALUES
  ('issue30-owner@example.test', 'pending', false),
  ('issue30-collaborator@example.test', 'pending', false),
  ('issue30-outsider@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES
  ('43000000-0000-4000-8000-000000000002', 'issue30-owner@example.test', now(), '{"provider":"google"}'),
  ('43000000-0000-4000-8000-000000000003', 'issue30-collaborator@example.test', now(), '{"provider":"google"}'),
  ('43000000-0000-4000-8000-000000000004', 'issue30-outsider@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES
  ('53000000-0000-4000-8000-000000000002', '43000000-0000-4000-8000-000000000002', 'google', 'issue30-owner', '{"email":"issue30-owner@example.test","email_verified":true}'),
  ('53000000-0000-4000-8000-000000000003', '43000000-0000-4000-8000-000000000003', 'google', 'issue30-collaborator', '{"email":"issue30-collaborator@example.test","email_verified":true}'),
  ('53000000-0000-4000-8000-000000000004', '43000000-0000-4000-8000-000000000004', 'google', 'issue30-outsider', '{"email":"issue30-outsider@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = users.id,
    google_subject = identity.provider_id,
    state = 'active'
FROM auth.users AS users
JOIN auth.identities AS identity ON identity.user_id = users.id
WHERE access.email = users.email
  AND users.id IN (
    '43000000-0000-4000-8000-000000000002',
    '43000000-0000-4000-8000-000000000003',
    '43000000-0000-4000-8000-000000000004'
  );

CREATE TEMP TABLE issue30_label_board_refs (
  label text PRIMARY KEY,
  board_id uuid NOT NULL UNIQUE,
  board_slug text NOT NULL
);
GRANT SELECT, INSERT ON issue30_label_board_refs TO authenticated;
CREATE TEMP TABLE issue30_label_refs (
  label text PRIMARY KEY,
  board_id uuid NOT NULL,
  label_id uuid NOT NULL UNIQUE
);
GRANT SELECT, INSERT ON issue30_label_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Etiquetas #30', 'America/Argentina/Buenos_Aires',
    '30000000-0000-4000-8000-000000000001'
  );
  INSERT INTO pg_temp.issue30_label_board_refs(label, board_id, board_slug)
  VALUES ('main', v_board.id, v_board.slug);

  SELECT * INTO v_board
  FROM public.create_board_p(
    'Otro tablero #30', 'America/Argentina/Buenos_Aires',
    '30000000-0000-4000-8000-000000000002'
  );
  INSERT INTO pg_temp.issue30_label_board_refs(label, board_id, board_slug)
  VALUES ('other', v_board.id, v_board.slug);
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board.board_id, '43000000-0000-4000-8000-000000000003', 'collaborator'
FROM pg_temp.issue30_label_board_refs AS board
WHERE board.label = 'main';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_slug text;
  v_board_id uuid;
  v_created jsonb;
  v_duplicate jsonb;
  v_catalog jsonb;
BEGIN
  SELECT board_slug, board_id INTO STRICT v_slug, v_board_id
  FROM pg_temp.issue30_label_board_refs
  WHERE label = 'main';

  v_created := public.create_board_label_p(v_slug, 'Peña', 'blue');
  IF v_created->>'status' IS DISTINCT FROM 'confirmed'
    OR v_created->'label'->>'name' IS DISTINCT FROM 'Peña'
    OR v_created->'label'->>'color' IS DISTINCT FROM 'blue' THEN
    RAISE EXCEPTION 'A collaborator can create a board label and retain its original text/color: %',
      v_created;
  END IF;
  INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
  VALUES ('main:base', v_board_id, (v_created->'label'->>'id')::uuid);

  v_duplicate := public.create_board_label_p(v_slug, '  PENA  ', 'green');
  IF v_duplicate->>'status' IS DISTINCT FROM 'conflict'
    OR v_duplicate->>'reason' IS DISTINCT FROM 'duplicate_name'
    OR v_duplicate->'label'->>'name' IS DISTINCT FROM 'Peña' THEN
    RAISE EXCEPTION 'Label uniqueness must ignore accents, ñ/n, case and outer spaces without merging identities: %',
      v_duplicate;
  END IF;

  v_catalog := public.list_board_labels_p(v_slug);
  IF v_catalog->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_catalog->'labels') <> 1
    OR v_catalog->'labels'->0->>'name' IS DISTINCT FROM 'Peña' THEN
    RAISE EXCEPTION 'The authorized catalog must preserve the display spelling and contain one active identity: %',
      v_catalog;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_board_id uuid;
  v_result jsonb;
BEGIN
  SELECT board_slug, board_id INTO STRICT v_slug, v_board_id
  FROM pg_temp.issue30_label_board_refs
  WHERE label = 'other';
  v_result := public.create_board_label_p(v_slug, 'Pena', 'purple');
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Equal names in different boards must remain separate: %', v_result;
  END IF;
  INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
  VALUES ('other:base', v_board_id, (v_result->'label'->>'id')::uuid);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_slug text;
  v_column public.columns%ROWTYPE;
  v_task_result jsonb;
  v_birthday_result jsonb;
  v_safe_birthday_result jsonb;
  v_hidden_birthday_result jsonb;
  v_hidden_birthday_date date;
  v_base_label_id uuid;
  v_result jsonb;
  v_index integer;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_slug
  FROM pg_temp.issue30_label_board_refs
  WHERE label = 'main';

  v_column := public.create_column_p(v_slug, v_board_id, 'Trabajo', 0);
  v_task_result := public.create_task_p(
    '30000000-0000-4000-8000-000000000010', v_board_id, v_column.id,
    'Tarea para clasificar', NULL, 'medium'
  );
  IF v_task_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Task fixture creation failed: %', v_task_result;
  END IF;
  INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
  VALUES ('fixture:task', v_board_id, (v_task_result->>'task_id')::uuid);

  v_birthday_result := public.create_birthday_p(
    '30000000-0000-4000-8000-000000000011', v_slug,
    'Cumpleaños para clasificar', 4, 10, NULL
  );
  IF v_birthday_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Birthday fixture creation failed: %', v_birthday_result;
  END IF;
  INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
  VALUES ('fixture:birthday', v_board_id,
    (v_birthday_result->'birthday'->>'id')::uuid);

  v_safe_birthday_result := public.create_birthday_p(
    '30000000-0000-4000-8000-000000000012', v_slug,
    'Cumpleaños elegible para restauración', 5, 11, NULL
  );
  IF v_safe_birthday_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Safe birthday fixture creation failed: %', v_safe_birthday_result;
  END IF;
  INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
  VALUES ('fixture:birthday_safe', v_board_id,
    (v_safe_birthday_result->'birthday'->>'id')::uuid);

  SELECT label_id INTO STRICT v_base_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'main:base';
  v_result := public.set_birthday_labels_p(
    v_slug,
    (v_safe_birthday_result->'birthday'->>'id')::uuid,
    ARRAY[]::uuid[], ARRAY[v_base_label_id]::uuid[]
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_result->'labels') <> 1 THEN
    RAISE EXCEPTION 'Safe birthday must retain an initial label association: %', v_result;
  END IF;

  v_hidden_birthday_date := public.board_calendar_day(
    'America/Argentina/Buenos_Aires', pg_catalog.clock_timestamp()
  ) + 200;
  v_hidden_birthday_result := public.create_birthday_p(
    '30000000-0000-4000-8000-000000000013', v_slug,
    'Cumpleaños fuera de ventana',
    extract(month FROM v_hidden_birthday_date)::integer,
    extract(day FROM v_hidden_birthday_date)::integer,
    1
  );
  IF v_hidden_birthday_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Hidden birthday fixture creation failed: %', v_hidden_birthday_result;
  END IF;
  INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
  VALUES ('fixture:birthday_hidden', v_board_id,
    (v_hidden_birthday_result->'birthday'->>'id')::uuid);
  v_result := public.set_birthday_labels_p(
    v_slug,
    (v_hidden_birthday_result->'birthday'->>'id')::uuid,
    ARRAY[]::uuid[], ARRAY[v_base_label_id]::uuid[]
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_result->'labels') <> 1 THEN
    RAISE EXCEPTION 'An out-of-window birthday must keep its board label: %', v_result;
  END IF;

  FOR v_index IN 1..10 LOOP
    v_result := public.create_board_label_p(
      v_slug,
      format('Etiqueta %s', v_index),
      (ARRAY['red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'pink', 'gray'])[1 + ((v_index - 1) % 9)]
    );
    IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Could not create label % for association tests: %', v_index, v_result;
    END IF;
    INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
    VALUES (
      format('main:%s', v_index), v_board_id,
      (v_result->'label'->>'id')::uuid
    );
  END LOOP;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_board_id uuid;
  v_task_id uuid;
  v_birthday_id uuid;
  v_hidden_birthday_id uuid;
  v_ten_ids uuid[];
  v_eleven_ids uuid[];
  v_cross_board_ids uuid[];
  v_result jsonb;
  v_current jsonb;
  v_board_assignments jsonb;
  v_series_birthdays jsonb;
BEGIN
  SELECT board_slug, board_id INTO STRICT v_slug, v_board_id
  FROM pg_temp.issue30_label_board_refs
  WHERE label = 'main';
  SELECT label_id INTO STRICT v_task_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:task';
  SELECT label_id INTO STRICT v_birthday_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:birthday';
  SELECT label_id INTO STRICT v_hidden_birthday_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:birthday_hidden';

  SELECT array_agg(label_id ORDER BY label) INTO v_ten_ids
  FROM (
    SELECT label, label_id
    FROM pg_temp.issue30_label_refs
    WHERE label = 'main:base'
    UNION ALL
    (
      SELECT label, label_id
      FROM pg_temp.issue30_label_refs
      WHERE board_id = v_board_id
        AND label LIKE 'main:%'
        AND label <> 'main:base'
      ORDER BY label
      LIMIT 9
    )
  ) AS labels;
  SELECT array_agg(label_id ORDER BY label) INTO v_eleven_ids
  FROM pg_temp.issue30_label_refs
  WHERE board_id = v_board_id AND label LIKE 'main:%';
  SELECT array_agg(label_id ORDER BY label) INTO v_cross_board_ids
  FROM pg_temp.issue30_label_refs
  WHERE label IN ('main:base', 'other:base');

  v_result := public.set_task_labels_p(
    v_slug, v_task_id, ARRAY[]::uuid[], v_ten_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_result->'labels') <> 10 THEN
    RAISE EXCEPTION 'A task can save ten labels as one complete selection: %', v_result;
  END IF;
  v_result := public.set_task_labels_p(
    v_slug, v_task_id, v_ten_ids, v_eleven_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'reason' IS DISTINCT FROM 'too_many_labels' THEN
    RAISE EXCEPTION 'The eleventh label must be rejected: %', v_result;
  END IF;
  v_result := public.set_task_labels_p(
    v_slug, v_task_id, v_ten_ids, v_cross_board_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'reason' IS DISTINCT FROM 'invalid_selection' THEN
    RAISE EXCEPTION 'A cross-board label id must be rejected even when the actor belongs to both boards: %', v_result;
  END IF;
  v_current := public.get_task_labels_p(v_slug, v_task_id);
  IF v_current->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_current->'labels') <> 10 THEN
    RAISE EXCEPTION 'Invalid selection must not partially replace task labels: %', v_current;
  END IF;

  v_result := public.set_birthday_labels_p(
    v_slug, v_birthday_id, ARRAY[]::uuid[], v_ten_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_result->'labels') <> 10 THEN
    RAISE EXCEPTION 'A birthday can save ten labels as one complete selection: %', v_result;
  END IF;
  v_result := public.set_birthday_labels_p(
    v_slug, v_birthday_id, v_ten_ids, v_eleven_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'reason' IS DISTINCT FROM 'too_many_labels' THEN
    RAISE EXCEPTION 'The eleventh birthday label must be rejected: %', v_result;
  END IF;
  v_result := public.set_birthday_labels_p(
    v_slug, v_birthday_id, v_ten_ids, v_cross_board_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'reason' IS DISTINCT FROM 'invalid_selection' THEN
    RAISE EXCEPTION 'A cross-board birthday label id must be rejected: %', v_result;
  END IF;
  v_current := public.get_birthday_labels_p(v_slug, v_birthday_id);
  IF v_current->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_current->'labels') <> 10 THEN
    RAISE EXCEPTION 'Invalid selection must not partially replace birthday labels: %', v_current;
  END IF;

  v_board_assignments := public.get_board_label_assignments_p(v_slug);
  IF v_board_assignments->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_board_assignments->'tasks') AS entry
      WHERE entry->>'task_id' = v_task_id::text
        AND jsonb_array_length(entry->'labels') = 10
    )
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_board_assignments->'birthdays') AS entry
      WHERE entry->>'birthday_id' = v_birthday_id::text
        AND jsonb_array_length(entry->'labels') = 10
    )
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_board_assignments->'birthdays') AS entry
      WHERE entry->>'birthday_id' = v_hidden_birthday_id::text
        AND jsonb_array_length(entry->'labels') = 1
    ) THEN
    RAISE EXCEPTION 'The board-level batch read must return active task and birthday assignments: %',
      v_board_assignments;
  END IF;

  v_series_birthdays := public.list_my_birthdays_p(v_board_id);
  IF v_series_birthdays->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_series_birthdays->'birthdays') AS entry
      WHERE entry->>'id' = v_hidden_birthday_id::text
        AND entry->>'visible' = 'false'
    ) THEN
    RAISE EXCEPTION 'Series must retain the tagged birthday while it is outside the board window: %',
      v_series_birthdays;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_task_id uuid;
  v_board_id uuid;
  v_expected_ids uuid[];
  v_first_ids uuid[];
  v_before jsonb;
  v_first jsonb;
  v_second jsonb;
  v_after jsonb;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  SELECT label_id INTO STRICT v_task_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:task';
  v_before := public.get_task_labels_p(v_slug, v_task_id);
  SELECT array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid)
  INTO v_expected_ids
  FROM jsonb_array_elements(v_before->'labels') AS rows(item);
  SELECT array_agg(label_id ORDER BY label_id) INTO v_first_ids
  FROM pg_temp.issue30_label_refs
  WHERE board_id = v_board_id AND label LIKE 'main:%' AND label <> 'main:base';

  v_first := public.set_task_labels_p(
    v_slug, v_task_id, v_expected_ids, v_first_ids
  );
  v_second := public.set_task_labels_p(
    v_slug, v_task_id, v_expected_ids, v_expected_ids
  );
  v_after := public.get_task_labels_p(v_slug, v_task_id);
  IF v_first->>'status' IS DISTINCT FROM 'confirmed'
    OR v_second->>'status' IS DISTINCT FROM 'conflict'
    OR v_second->>'reason' IS DISTINCT FROM 'stale_selection'
    OR (SELECT array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid)
        FROM jsonb_array_elements(v_after->'labels') AS rows(item))
      IS DISTINCT FROM v_first_ids THEN
    RAISE EXCEPTION 'A stale task label draft must conflict without overwriting the first client selection: %, %, %',
      v_first, v_second, v_after;
  END IF;
  v_after := public.set_task_labels_p(
    v_slug, v_task_id, v_first_ids, v_expected_ids
  );
  IF v_after->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Task concurrency fixture cleanup failed: %', v_after;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_birthday_id uuid;
  v_board_id uuid;
  v_expected_ids uuid[];
  v_first_ids uuid[];
  v_before jsonb;
  v_first jsonb;
  v_second jsonb;
  v_after jsonb;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  SELECT label_id INTO STRICT v_birthday_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:birthday';
  v_before := public.get_birthday_labels_p(v_slug, v_birthday_id);
  SELECT array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid)
  INTO v_expected_ids
  FROM jsonb_array_elements(v_before->'labels') AS rows(item);
  SELECT array_agg(label_id ORDER BY label_id) INTO v_first_ids
  FROM pg_temp.issue30_label_refs
  WHERE board_id = v_board_id AND label LIKE 'main:%' AND label <> 'main:base';

  v_first := public.set_birthday_labels_p(
    v_slug, v_birthday_id, v_expected_ids, v_first_ids
  );
  v_second := public.set_birthday_labels_p(
    v_slug, v_birthday_id, v_expected_ids, v_expected_ids
  );
  v_after := public.get_birthday_labels_p(v_slug, v_birthday_id);
  IF v_first->>'status' IS DISTINCT FROM 'confirmed'
    OR v_second->>'status' IS DISTINCT FROM 'conflict'
    OR v_second->>'reason' IS DISTINCT FROM 'stale_selection'
    OR (SELECT array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid)
        FROM jsonb_array_elements(v_after->'labels') AS rows(item))
      IS DISTINCT FROM v_first_ids THEN
    RAISE EXCEPTION 'A stale birthday label draft must conflict without overwriting the first client selection: %, %, %',
      v_first, v_second, v_after;
  END IF;
  v_after := public.set_birthday_labels_p(
    v_slug, v_birthday_id, v_first_ids, v_expected_ids
  );
  IF v_after->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Birthday concurrency fixture cleanup failed: %', v_after;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_slug text;
  v_column public.columns%ROWTYPE;
  v_task_result jsonb;
  v_task_deleted jsonb;
  v_task_restored jsonb;
  v_task_labels jsonb;
  v_birthday_result jsonb;
  v_birthday_deleted jsonb;
  v_birthday_restored jsonb;
  v_birthday_labels jsonb;
  v_label_id uuid;
  v_task_id uuid;
  v_birthday_id uuid;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  SELECT label_id INTO STRICT v_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'main:base';
  v_column := public.create_column_p(v_slug, v_board_id, 'Recuperación', 20);

  v_task_result := public.create_task_p(
    '30000000-0000-4000-8000-000000000021', v_board_id, v_column.id,
    'Tarea con etiqueta recuperable'
  );
  IF v_task_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Recovery task fixture creation failed: %', v_task_result;
  END IF;
  v_task_id := (v_task_result->>'task_id')::uuid;
  v_task_labels := public.set_task_labels_p(
    v_slug, v_task_id, ARRAY[]::uuid[], ARRAY[v_label_id]::uuid[]
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Recovery task label assignment failed: %', v_task_labels;
  END IF;
  v_task_deleted := public.delete_task_p(
    '30000000-0000-4000-8000-000000000022', v_slug, v_task_id
  );
  v_task_restored := public.restore_task_p(
    '30000000-0000-4000-8000-000000000023', v_slug, v_task_id
  );
  IF v_task_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_task_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Task label recovery fixture did not complete delete/restore: %, %',
      v_task_deleted, v_task_restored;
  END IF;
  v_task_labels := public.get_task_labels_p(v_slug, v_task_id);
  IF jsonb_array_length(v_task_labels->'labels') <> 1
    OR v_task_labels->'labels'->0->>'id' IS DISTINCT FROM v_label_id::text THEN
    RAISE EXCEPTION 'Restoring a task must restore its still-valid label association: %',
      v_task_labels;
  END IF;
  v_task_labels := public.set_task_labels_p(
    v_slug, v_task_id, ARRAY[v_label_id]::uuid[], ARRAY[]::uuid[]
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Recovery task label cleanup failed: %', v_task_labels;
  END IF;

  v_birthday_result := public.create_birthday_p(
    '30000000-0000-4000-8000-000000000024', v_slug,
    'Cumpleaños con etiqueta recuperable', 8, 19, NULL
  );
  IF v_birthday_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Recovery birthday fixture creation failed: %', v_birthday_result;
  END IF;
  v_birthday_id := (v_birthday_result->'birthday'->>'id')::uuid;
  v_birthday_labels := public.set_birthday_labels_p(
    v_slug, v_birthday_id, ARRAY[]::uuid[], ARRAY[v_label_id]::uuid[]
  );
  IF v_birthday_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Recovery birthday label assignment failed: %', v_birthday_labels;
  END IF;
  v_birthday_deleted := public.delete_birthday_p(
    '30000000-0000-4000-8000-000000000025', v_slug, v_birthday_id, 1
  );
  v_birthday_restored := public.restore_birthday_p(
    '30000000-0000-4000-8000-000000000026', v_slug, v_birthday_id
  );
  IF v_birthday_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_birthday_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Birthday label recovery fixture did not complete delete/restore: %, %',
      v_birthday_deleted, v_birthday_restored;
  END IF;
  v_birthday_labels := public.get_birthday_labels_p(v_slug, v_birthday_id);
  IF jsonb_array_length(v_birthday_labels->'labels') <> 1
    OR v_birthday_labels->'labels'->0->>'id' IS DISTINCT FROM v_label_id::text THEN
    RAISE EXCEPTION 'Restoring a birthday must restore its still-valid label association: %',
      v_birthday_labels;
  END IF;
  v_birthday_labels := public.set_birthday_labels_p(
    v_slug, v_birthday_id, ARRAY[v_label_id]::uuid[], ARRAY[]::uuid[]
  );
  IF v_birthday_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Recovery birthday label cleanup failed: %', v_birthday_labels;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_slug text;
  v_assignments jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  v_assignments := public.get_board_label_assignments_p(v_slug);
  IF v_assignments->>'status' IS DISTINCT FROM 'unavailable'
    OR jsonb_array_length(v_assignments->'tasks') <> 0
    OR jsonb_array_length(v_assignments->'birthdays') <> 0 THEN
    RAISE EXCEPTION 'The batch assignment read must not reveal board labels to an outsider: %',
      v_assignments;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_label_id uuid;
  v_task_id uuid;
  v_birthday_id uuid;
  v_before_task jsonb;
  v_before_birthday jsonb;
  v_renamed jsonb;
  v_duplicate jsonb;
  v_stale jsonb;
  v_after_task jsonb;
  v_after_birthday jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_slug
  FROM pg_temp.issue30_label_board_refs
  WHERE label = 'main';
  SELECT label_id INTO STRICT v_label_id
  FROM pg_temp.issue30_label_refs
  WHERE label = 'main:base';
  SELECT label_id INTO STRICT v_task_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:task';
  SELECT label_id INTO STRICT v_birthday_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:birthday';

  v_before_task := public.get_task_labels_p(v_slug, v_task_id);
  v_before_birthday := public.get_birthday_labels_p(v_slug, v_birthday_id);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_before_task->'labels') AS item
    WHERE item->>'id' = v_label_id::text
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_before_birthday->'labels') AS item
    WHERE item->>'id' = v_label_id::text
  ) THEN
    RAISE EXCEPTION 'The base label must be assigned to both fixtures before rename';
  END IF;

  v_renamed := public.update_board_label_p(
    v_slug, v_label_id, 1, '  PEÑA  ', 'orange'
  );
  IF v_renamed->>'status' IS DISTINCT FROM 'confirmed'
    OR v_renamed->'label'->>'id' IS DISTINCT FROM v_label_id::text
    OR v_renamed->'label'->>'name' IS DISTINCT FROM '  PEÑA  '
    OR v_renamed->'label'->>'color' IS DISTINCT FROM 'orange' THEN
    RAISE EXCEPTION 'Rename/color changes must preserve the label identity and exact text: %',
      v_renamed;
  END IF;

  v_duplicate := public.create_board_label_p(v_slug, 'Pena', 'blue');
  IF v_duplicate->>'status' IS DISTINCT FROM 'conflict'
    OR v_duplicate->'label'->>'id' IS DISTINCT FROM v_label_id::text
    OR v_duplicate->'label'->>'name' IS DISTINCT FROM '  PEÑA  ' THEN
    RAISE EXCEPTION 'Normalization may detect a collision but must not replace identity or display text: %',
      v_duplicate;
  END IF;

  v_stale := public.update_board_label_p(
    v_slug, v_label_id, 1, 'Nombre obsoleto', 'red'
  );
  IF v_stale->>'status' IS DISTINCT FROM 'conflict'
    OR v_stale->'label'->>'name' IS DISTINCT FROM '  PEÑA  '
    OR v_stale->'label'->>'color' IS DISTINCT FROM 'orange' THEN
    RAISE EXCEPTION 'A stale label edit must preserve the current catalog entry: %', v_stale;
  END IF;

  v_after_task := public.get_task_labels_p(v_slug, v_task_id);
  v_after_birthday := public.get_birthday_labels_p(v_slug, v_birthday_id);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_after_task->'labels') AS item
    WHERE item->>'id' = v_label_id::text AND item->>'name' = '  PEÑA  '
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_after_birthday->'labels') AS item
    WHERE item->>'id' = v_label_id::text AND item->>'name' = '  PEÑA  '
  ) THEN
    RAISE EXCEPTION 'Renaming must preserve task and birthday associations: %, %',
      v_after_task, v_after_birthday;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_slug text;
  v_result jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_slug
  FROM pg_temp.issue30_label_board_refs
  WHERE label = 'main';
  v_result := public.list_board_labels_p(v_slug);
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR jsonb_array_length(COALESCE(v_result->'labels', '[]'::jsonb)) <> 0 THEN
    RAISE EXCEPTION 'An outsider must not receive a private board label catalog: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_denied boolean := false;
BEGIN
  BEGIN
    PERFORM 1 FROM public.board_labels LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Authenticated clients must not read the private label table directly';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_slug text;
  v_label_id uuid;
  v_result jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  SELECT label_id INTO STRICT v_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'main:base';

  v_result := public.delete_board_label_p(v_slug, v_label_id, 2);
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A collaborator cannot move a label to the owner-only trash: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_label_id uuid;
  v_task_id uuid;
  v_birthday_id uuid;
  v_safe_birthday_id uuid;
  v_deleted jsonb;
  v_catalog jsonb;
  v_trash jsonb;
  v_task_labels jsonb;
  v_birthday_labels jsonb;
  v_replacement jsonb;
  v_over_limit jsonb;
  v_active_ten_ids uuid[];
  v_active_nine_ids uuid[];
  v_expected_ids uuid[];
  v_preview jsonb;
  v_confirm jsonb;
  v_quota_label_id uuid;
  v_index integer;
BEGIN
  SELECT board_slug INTO STRICT v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  SELECT label_id INTO STRICT v_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'main:base';
  SELECT label_id INTO STRICT v_task_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:task';
  SELECT label_id INTO STRICT v_birthday_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:birthday';
  SELECT label_id INTO STRICT v_safe_birthday_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:birthday_safe';

  v_deleted := public.delete_board_label_p(v_slug, v_label_id, 2);
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_deleted->'label'->>'id' IS DISTINCT FROM v_label_id::text THEN
    RAISE EXCEPTION 'The owner can soft-delete a label and retain its identity: %', v_deleted;
  END IF;

  v_catalog := public.list_board_labels_p(v_slug);
  v_trash := public.list_deleted_board_labels_p(v_slug);
  v_task_labels := public.get_task_labels_p(v_slug, v_task_id);
  v_birthday_labels := public.get_birthday_labels_p(v_slug, v_birthday_id);
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_catalog->'labels') AS item
    WHERE item->>'id' = v_label_id::text
  ) OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_task_labels->'labels') AS item
    WHERE item->>'id' = v_label_id::text
  ) OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_birthday_labels->'labels') AS item
    WHERE item->>'id' = v_label_id::text
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_trash->'labels') AS item
    WHERE item->>'id' = v_label_id::text
      AND (item->>'expires_at')::timestamptz = (item->>'deleted_at')::timestamptz + interval '604800 seconds'
  ) THEN
    RAISE EXCEPTION 'Soft-deleted labels and their associations must be hidden from active views';
  END IF;

  v_replacement := public.create_board_label_p(v_slug, 'Pena', 'green');
  IF v_replacement->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replacement->'label'->>'id' = v_label_id::text THEN
    RAISE EXCEPTION 'Deleting a label must free its normalized active name without reusing its identity: %',
      v_replacement;
  END IF;
  INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
  SELECT 'main:replacement', board.board_id,
    (v_replacement->'label'->>'id')::uuid
  FROM pg_temp.issue30_label_board_refs AS board
  WHERE board.label = 'main';

  FOR v_index IN 1..89 LOOP
    v_over_limit := public.create_board_label_p(
      v_slug, format('Cuota %s', v_index), 'gray'
    );
    IF v_over_limit->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Could not fill active label slot %: %', v_index, v_over_limit;
    END IF;
    INSERT INTO pg_temp.issue30_label_refs(label, board_id, label_id)
    SELECT format('quota:%s', v_index), board.board_id,
      (v_over_limit->'label'->>'id')::uuid
    FROM pg_temp.issue30_label_board_refs AS board
    WHERE board.label = 'main';
  END LOOP;

  v_over_limit := public.create_board_label_p(v_slug, 'Cuota excedida', 'gray');
  IF v_over_limit->>'status' IS DISTINCT FROM 'conflict'
    OR v_over_limit->>'reason' IS DISTINCT FROM 'active_limit' THEN
    RAISE EXCEPTION 'The one-hundred-and-first active label must be rejected: %', v_over_limit;
  END IF;
  v_catalog := public.list_board_labels_p(v_slug);
  IF jsonb_array_length(v_catalog->'labels') <> 100 THEN
    RAISE EXCEPTION 'The active catalog must stop at exactly 100 labels: %', v_catalog;
  END IF;

  SELECT array_agg(label_id ORDER BY label) INTO v_active_ten_ids
  FROM (
    (
      SELECT label, label_id
      FROM pg_temp.issue30_label_refs
      WHERE label LIKE 'main:%'
        AND label NOT IN ('main:base', 'main:replacement')
      ORDER BY label
      LIMIT 9
    )
    UNION ALL
    SELECT label, label_id
    FROM pg_temp.issue30_label_refs
    WHERE label = 'main:replacement'
  ) AS selected;
  SELECT coalesce(
    array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid),
    ARRAY[]::uuid[]
  ) INTO v_expected_ids
  FROM jsonb_array_elements(
    public.get_task_labels_p(v_slug, v_task_id)->'labels'
  ) AS rows(item);
  v_task_labels := public.set_task_labels_p(
    v_slug, v_task_id, v_expected_ids, v_active_ten_ids
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_task_labels->'labels') <> 10 THEN
    RAISE EXCEPTION 'A task must be able to replace visible tags after a label was deleted: %',
      v_task_labels;
  END IF;
  SELECT coalesce(
    array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid),
    ARRAY[]::uuid[]
  ) INTO v_expected_ids
  FROM jsonb_array_elements(
    public.get_birthday_labels_p(v_slug, v_birthday_id)->'labels'
  ) AS rows(item);
  v_birthday_labels := public.set_birthday_labels_p(
    v_slug, v_birthday_id, v_expected_ids, ARRAY[]::uuid[]
  );
  IF v_birthday_labels->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_birthday_labels->'labels') <> 0 THEN
    RAISE EXCEPTION 'A birthday must be able to clear visible tags after a label was deleted: %',
      v_birthday_labels;
  END IF;

  v_preview := public.preview_restore_board_label_p(v_slug, v_label_id, 'Pena');
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_preview->'can_restore' IS DISTINCT FROM 'false'::jsonb
    OR NOT (v_preview->'reasons' ? 'duplicate_name')
    OR NOT (v_preview->'reasons' ? 'active_limit') THEN
    RAISE EXCEPTION 'Restore preview must require a rename and a free catalog slot: %',
      v_preview;
  END IF;
  v_confirm := public.restore_board_label_p(
    v_slug, v_label_id, 3, 'Etiqueta restaurada',
    ARRAY[v_task_id]::uuid[], ARRAY[v_birthday_id, v_safe_birthday_id]::uuid[]
  );
  IF v_confirm->>'status' IS DISTINCT FROM 'conflict'
    OR v_confirm->>'reason' IS DISTINCT FROM 'active_limit' THEN
    RAISE EXCEPTION 'Confirm must recheck the board cap and reject without mutation: %', v_confirm;
  END IF;
  v_preview := public.preview_restore_board_label_p(
    v_slug, v_label_id, 'Etiqueta restaurada'
  );
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_preview->'can_restore' IS DISTINCT FROM 'false'::jsonb
    OR NOT (v_preview->'reasons' ? 'active_limit') THEN
    RAISE EXCEPTION 'A full active catalog must make restore preview non-confirmable: %',
      v_preview;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_preview->'associated_tasks') AS item
    WHERE item->>'id' = v_task_id::text
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_preview->'associated_birthdays') AS item
    WHERE item->>'id' = v_birthday_id::text
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_preview->'associated_birthdays') AS item
    WHERE item->>'id' = v_safe_birthday_id::text
  ) THEN
    RAISE EXCEPTION 'Restore preview must resolve retained joins to current authorized task and birthday IDs: %',
      v_preview;
  END IF;

  SELECT label_id INTO STRICT v_quota_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'quota:1';
  v_over_limit := public.delete_board_label_p(v_slug, v_quota_label_id, 1);
  IF v_over_limit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A second owner deletion must free one catalog slot: %', v_over_limit;
  END IF;

  v_confirm := public.restore_board_label_p(
    v_slug, v_label_id, 3, 'Pena',
    ARRAY[v_task_id]::uuid[], ARRAY[v_safe_birthday_id]::uuid[]
  );
  IF v_confirm->>'status' IS DISTINCT FROM 'conflict'
    OR v_confirm->>'reason' IS DISTINCT FROM 'duplicate_name' THEN
    RAISE EXCEPTION 'Confirm must recheck the normalized name and reject without mutation: %', v_confirm;
  END IF;

  v_preview := public.preview_restore_board_label_p(
    v_slug, v_label_id, 'Etiqueta restaurada'
  );
  IF v_preview->'can_restore' IS DISTINCT FROM 'true'::jsonb
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_preview->'associated_tasks') AS item
      WHERE item->>'id' = v_task_id::text
        AND (item->>'active_label_count')::integer = 10
        AND item->'would_exceed_limit' = 'true'::jsonb
    ) OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_preview->'associated_birthdays') AS item
      WHERE item->>'id' = v_safe_birthday_id::text
        AND (item->>'active_label_count')::integer = 0
        AND item->'would_exceed_limit' = 'false'::jsonb
    ) THEN
    RAISE EXCEPTION 'Preview must report per-item ten-label capacity and retain both hidden joins: %',
      v_preview;
  END IF;

  v_confirm := public.restore_board_label_p(
    v_slug, v_label_id, 3, 'Etiqueta restaurada',
    ARRAY[v_task_id]::uuid[], ARRAY[v_birthday_id, v_safe_birthday_id]::uuid[]
  );
  IF v_confirm->>'status' IS DISTINCT FROM 'conflict'
    OR v_confirm->>'reason' IS DISTINCT FROM 'too_many_labels' THEN
    RAISE EXCEPTION 'A selected task over ten labels must reject the whole restore: %', v_confirm;
  END IF;
  v_task_labels := public.get_task_labels_p(v_slug, v_task_id);
  v_trash := public.list_deleted_board_labels_p(v_slug);
  IF jsonb_array_length(v_task_labels->'labels') <> 10
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_trash->'labels') AS item
      WHERE item->>'id' = v_label_id::text
    ) THEN
    RAISE EXCEPTION 'A rejected restore must preserve the ten current labels and deleted label state';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000003', true);
  v_confirm := public.restore_board_label_p(
    v_slug, v_label_id, 3, 'Etiqueta restaurada',
    ARRAY[v_task_id]::uuid[], ARRAY[v_safe_birthday_id]::uuid[]
  );
  IF v_confirm->>'status' IS DISTINCT FROM 'unavailable'
    OR public.list_deleted_board_labels_p(v_slug)->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A collaborator cannot inspect or restore the owner-only trash: %', v_confirm;
  END IF;
  PERFORM set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);

  SELECT array_agg(label_id ORDER BY label) INTO v_active_nine_ids
  FROM (
    (
      SELECT label, label_id
      FROM pg_temp.issue30_label_refs
      WHERE label LIKE 'main:%'
        AND label NOT IN ('main:base', 'main:replacement')
      ORDER BY label
      LIMIT 8
    )
    UNION ALL
    SELECT label, label_id
    FROM pg_temp.issue30_label_refs
    WHERE label = 'main:replacement'
  ) AS selected;
  v_task_labels := public.set_task_labels_p(
    v_slug, v_task_id, v_active_ten_ids, v_active_nine_ids
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_task_labels->'labels') <> 9 THEN
    RAISE EXCEPTION 'Freeing one item slot must succeed while the hidden assignment remains: %',
      v_task_labels;
  END IF;
  v_preview := public.preview_restore_board_label_p(
    v_slug, v_label_id, 'Etiqueta restaurada'
  );
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_preview->'associated_tasks') AS item
    WHERE item->>'id' = v_task_id::text
      AND (item->>'active_label_count')::integer = 9
      AND item->'would_exceed_limit' = 'false'::jsonb
  ) THEN
    RAISE EXCEPTION 'A refreshed preview must allow re-including a task after capacity is freed: %',
      v_preview;
  END IF;

  v_preview := public.preview_restore_board_label_p(
    v_slug, v_label_id, 'Etiqueta restaurada'
  );
  IF v_preview->'can_restore' IS DISTINCT FROM 'true'::jsonb
    OR jsonb_array_length(v_preview->'associated_tasks') <> 1
    OR jsonb_array_length(v_preview->'associated_birthdays') <> 3
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(
        public.get_task_labels_p(v_slug, v_task_id)->'labels'
      ) AS item WHERE item->>'id' = v_label_id::text
    ) THEN
    RAISE EXCEPTION 'Failed confirm must leave the tag deleted and every relationship intact: %', v_preview;
  END IF;

  v_confirm := public.restore_board_label_p(
    v_slug, v_label_id, 3, 'Etiqueta restaurada',
    ARRAY[v_task_id]::uuid[], ARRAY[v_safe_birthday_id]::uuid[]
  );
  IF v_confirm->>'status' IS DISTINCT FROM 'confirmed'
    OR v_confirm->'label'->>'id' IS DISTINCT FROM v_label_id::text
    OR v_confirm->'label'->>'name' IS DISTINCT FROM 'Etiqueta restaurada' THEN
    RAISE EXCEPTION 'A valid explicit restore selection must preserve the tag identity: %',
      v_confirm;
  END IF;
  v_task_labels := public.get_task_labels_p(v_slug, v_task_id);
  v_birthday_labels := public.get_birthday_labels_p(v_slug, v_birthday_id);
  v_birthday_labels := public.get_birthday_labels_p(v_slug, v_safe_birthday_id);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_task_labels->'labels') AS item
    WHERE item->>'id' = v_label_id::text
      AND item->>'name' = 'Etiqueta restaurada'
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_birthday_labels->'labels') AS item
    WHERE item->>'id' = v_label_id::text
      AND item->>'name' = 'Etiqueta restaurada'
  ) OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(
      public.get_birthday_labels_p(v_slug, v_birthday_id)->'labels'
    ) AS item WHERE item->>'id' = v_label_id::text
  ) OR EXISTS (
    SELECT 1 FROM jsonb_array_elements(
      public.list_deleted_board_labels_p(v_slug)->'labels'
    ) AS item WHERE item->>'id' = v_label_id::text
  ) THEN
    RAISE EXCEPTION 'Confirm must reinclude selected task and birthday, omit unselected birthday, and remove the label from trash';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_label_id uuid;
  v_deleted jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  SELECT label_id INTO STRICT v_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'main:base';
  v_deleted := public.delete_board_label_p(v_slug, v_label_id, 4);
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The restored tag must be deletable again with its current version: %', v_deleted;
  END IF;
END;
$$;
COMMIT;

UPDATE public.board_labels
SET deleted_at = clock_timestamp() - interval '604800 seconds'
WHERE id = (
  SELECT label_id FROM pg_temp.issue30_label_refs WHERE label = 'main:base'
);

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text;
  v_label_id uuid;
  v_task_id uuid;
  v_birthday_id uuid;
  v_preview jsonb;
  v_restore jsonb;
  v_trash jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_slug
  FROM pg_temp.issue30_label_board_refs WHERE label = 'main';
  SELECT label_id INTO STRICT v_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'main:base';
  SELECT label_id INTO STRICT v_task_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:task';
  SELECT label_id INTO STRICT v_birthday_id
  FROM pg_temp.issue30_label_refs WHERE label = 'fixture:birthday_safe';

  v_preview := public.preview_restore_board_label_p(v_slug, v_label_id, 'Etiqueta restaurada');
  v_restore := public.restore_board_label_p(
    v_slug, v_label_id, 5, 'Etiqueta restaurada',
    ARRAY[v_task_id]::uuid[], ARRAY[v_birthday_id]::uuid[]
  );
  v_trash := public.list_deleted_board_labels_p(v_slug);
  IF v_preview->>'status' IS DISTINCT FROM 'expired'
    OR v_restore->>'status' IS DISTINCT FROM 'expired'
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_trash->'labels') AS item
      WHERE item->>'id' = v_label_id::text
    ) THEN
    RAISE EXCEPTION 'A label at the exact 168-hour boundary must be expired and non-restorable: %, %, %',
      v_preview, v_restore, v_trash;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_label_id uuid;
  v_purged integer;
  v_label_count integer;
  v_task_assignment_count integer;
  v_birthday_assignment_count integer;
BEGIN
  SELECT label_id INTO STRICT v_label_id
  FROM pg_temp.issue30_label_refs WHERE label = 'main:base';
  v_purged := public.purge_expired_board_labels_p(100);
  SELECT count(*)::integer INTO v_label_count
  FROM public.board_labels WHERE id = v_label_id;
  SELECT count(*)::integer INTO v_task_assignment_count
  FROM public.board_label_task_assignments WHERE label_id = v_label_id;
  SELECT count(*)::integer INTO v_birthday_assignment_count
  FROM public.board_label_birthday_assignments WHERE label_id = v_label_id;
  IF v_purged <> 1 OR v_label_count <> 0
    OR v_task_assignment_count <> 0 OR v_birthday_assignment_count <> 0 THEN
    RAISE EXCEPTION 'Expired purge must remove the catalog row and its retained joins exactly once: %, %, %, %',
      v_purged, v_label_count, v_task_assignment_count, v_birthday_assignment_count;
  END IF;
END;
$$;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column public.columns%ROWTYPE;
  v_task jsonb;
  v_birthday jsonb;
  v_hidden_label jsonb;
  v_active_label jsonb;
  v_active_ids uuid[] := ARRAY[]::uuid[];
  v_initial_ids uuid[];
  v_expected_ids uuid[];
  v_task_id uuid;
  v_birthday_id uuid;
  v_hidden_label_id uuid;
  v_task_labels jsonb;
  v_birthday_labels jsonb;
  v_deleted jsonb;
  v_preview jsonb;
  v_restore jsonb;
  v_index integer;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 30 tombstone label capacity',
    'America/Argentina/Buenos_Aires',
    '30000000-0000-4000-8000-000000000030'
  );
  v_column := public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    '30000000-0000-4000-8000-000000000031',
    v_board.id, v_column.id, 'Tarea con etiquetas recuperables', NULL, 'medium'
  );
  IF v_task->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the task tombstone capacity fixture: %', v_task;
  END IF;
  v_task_id := (v_task->>'task_id')::uuid;

  v_birthday := public.create_birthday_p(
    '30000000-0000-4000-8000-000000000032', v_board.slug,
    'Cumpleaños con etiquetas recuperables', 7, 9, NULL
  );
  IF v_birthday->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the birthday tombstone capacity fixture: %', v_birthday;
  END IF;
  v_birthday_id := (v_birthday->'birthday'->>'id')::uuid;

  v_hidden_label := public.create_board_label_p(
    v_board.slug, 'Etiqueta oculta de recuperación', 'red'
  );
  IF v_hidden_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the hidden recovery label: %', v_hidden_label;
  END IF;
  v_hidden_label_id := (v_hidden_label->'label'->>'id')::uuid;
  FOR v_index IN 1..10 LOOP
    v_active_label := public.create_board_label_p(
      v_board.slug, format('Etiqueta activa de recuperación %s', v_index), 'gray'
    );
    IF v_active_label->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Could not create active recovery label %: %', v_index, v_active_label;
    END IF;
    v_active_ids := array_append(
      v_active_ids, (v_active_label->'label'->>'id')::uuid
    );
  END LOOP;
  SELECT array_agg(label_id ORDER BY label_id) INTO v_active_ids
  FROM unnest(v_active_ids) AS active(label_id);

  v_initial_ids := v_active_ids[1:9] || ARRAY[v_hidden_label_id];
  v_task_labels := public.set_task_labels_p(
    v_board.slug, v_task_id, ARRAY[]::uuid[], v_initial_ids
  );
  v_birthday_labels := public.set_birthday_labels_p(
    v_board.slug, v_birthday_id, ARRAY[]::uuid[], v_initial_ids
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed'
    OR v_birthday_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Initial ten-label assignment failed: %, %',
      v_task_labels, v_birthday_labels;
  END IF;

  v_deleted := public.delete_board_label_p(
    v_board.slug, v_hidden_label_id, 1
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not hide the recovery label: %', v_deleted;
  END IF;
  SELECT coalesce(
    array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid), ARRAY[]::uuid[]
  ) INTO v_expected_ids
  FROM jsonb_array_elements(
    public.get_task_labels_p(v_board.slug, v_task_id)->'labels'
  ) AS rows(item);
  v_task_labels := public.set_task_labels_p(
    v_board.slug, v_task_id, v_expected_ids, v_active_ids
  );
  SELECT coalesce(
    array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid), ARRAY[]::uuid[]
  ) INTO v_expected_ids
  FROM jsonb_array_elements(
    public.get_birthday_labels_p(v_board.slug, v_birthday_id)->'labels'
  ) AS rows(item);
  v_birthday_labels := public.set_birthday_labels_p(
    v_board.slug, v_birthday_id, v_expected_ids, v_active_ids
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed'
    OR v_birthday_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Ten active labels alongside a hidden association must remain valid: %, %',
      v_task_labels, v_birthday_labels;
  END IF;

  v_deleted := public.delete_task_p(
    '30000000-0000-4000-8000-000000000033', v_board.slug, v_task_id
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not delete the task with a label recovery snapshot: %', v_deleted;
  END IF;
  v_deleted := public.delete_birthday_p(
    '30000000-0000-4000-8000-000000000034', v_board.slug, v_birthday_id, 1
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not delete the birthday with a label recovery snapshot: %', v_deleted;
  END IF;

  v_preview := public.preview_restore_board_label_p(
    v_board.slug, v_hidden_label_id, 'Etiqueta recuperada'
  );
  IF v_preview->'can_restore' IS DISTINCT FROM 'false'::jsonb
    OR NOT (v_preview->'reasons' ? 'task_recovery_limit') THEN
    RAISE EXCEPTION 'Preview must block the hidden label while a task tombstone would exceed ten: %',
      v_preview;
  END IF;
  IF NOT (v_preview->'reasons' ? 'birthday_recovery_limit') THEN
    RAISE EXCEPTION 'Preview must also identify the birthday tombstone capacity: %', v_preview;
  END IF;
  v_restore := public.restore_board_label_p(
    v_board.slug, v_hidden_label_id, 2, 'Etiqueta recuperada',
    ARRAY[]::uuid[], ARRAY[]::uuid[]
  );
  IF v_restore->>'status' IS DISTINCT FROM 'conflict'
    OR v_restore->>'reason' IS DISTINCT FROM 'tombstone_association_limit'
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(
        public.list_deleted_board_labels_p(v_board.slug)->'labels'
      ) AS rows(item) WHERE rows.item->>'id' = v_hidden_label_id::text
    ) THEN
    RAISE EXCEPTION 'Confirm must recheck tombstone capacity and leave the hidden tag unchanged: %',
      v_restore;
  END IF;

  v_restore := public.restore_task_p(
    '30000000-0000-4000-8000-000000000035', v_board.slug, v_task_id
  );
  IF v_restore->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The task must restore while the conflicting label stays hidden: %', v_restore;
  END IF;
  v_restore := public.restore_birthday_p(
    '30000000-0000-4000-8000-000000000036', v_board.slug, v_birthday_id
  );
  IF v_restore->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The birthday must restore while the conflicting label stays hidden: %', v_restore;
  END IF;
  v_task_labels := public.get_task_labels_p(v_board.slug, v_task_id);
  v_birthday_labels := public.get_birthday_labels_p(v_board.slug, v_birthday_id);
  v_preview := public.preview_restore_board_label_p(
    v_board.slug, v_hidden_label_id, 'Etiqueta recuperada'
  );
  IF jsonb_array_length(v_task_labels->'labels') <> 10
    OR jsonb_array_length(v_birthday_labels->'labels') <> 10
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_preview->'associated_tasks') AS rows(item)
      WHERE rows.item->>'id' = v_task_id::text
    ) OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_preview->'associated_birthdays') AS rows(item)
      WHERE rows.item->>'id' = v_birthday_id::text
    ) THEN
    RAISE EXCEPTION 'Restoring the elements must preserve ten visible labels and the hidden relation: %, %',
      v_task_labels, v_birthday_labels;
  END IF;

  IF v_preview->'can_restore' IS DISTINCT FROM 'true'::jsonb
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_preview->'associated_tasks') AS rows(item)
      WHERE rows.item->>'id' = v_task_id::text
        AND rows.item->'would_exceed_limit' = 'true'::jsonb
    ) OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_preview->'associated_birthdays') AS rows(item)
      WHERE rows.item->>'id' = v_birthday_id::text
        AND rows.item->'would_exceed_limit' = 'true'::jsonb
    ) THEN
    RAISE EXCEPTION 'After item recovery, preview must expose explicit over-limit association choices: %',
      v_preview;
  END IF;
  v_restore := public.restore_board_label_p(
    v_board.slug, v_hidden_label_id, 2, 'Etiqueta recuperada',
    ARRAY[v_task_id]::uuid[], ARRAY[v_birthday_id]::uuid[]
  );
  IF v_restore->>'status' IS DISTINCT FROM 'conflict'
    OR v_restore->>'reason' IS DISTINCT FROM 'too_many_labels'
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(
        public.list_deleted_board_labels_p(v_board.slug)->'labels'
      ) AS rows(item) WHERE rows.item->>'id' = v_hidden_label_id::text
    ) THEN
    RAISE EXCEPTION 'Selecting both over-limit associations must reject the whole restore: %',
      v_restore;
  END IF;

  v_task_labels := public.get_task_labels_p(v_board.slug, v_task_id);
  v_birthday_labels := public.get_birthday_labels_p(v_board.slug, v_birthday_id);
  SELECT coalesce(
    array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid), ARRAY[]::uuid[]
  ) INTO v_expected_ids
  FROM jsonb_array_elements(v_task_labels->'labels') AS rows(item);
  IF v_expected_ids IS DISTINCT FROM v_active_ids THEN
    RAISE EXCEPTION 'Rejected inclusion must preserve all task labels: %', v_expected_ids;
  END IF;
  SELECT coalesce(
    array_agg((item->>'id')::uuid ORDER BY (item->>'id')::uuid), ARRAY[]::uuid[]
  ) INTO v_expected_ids
  FROM jsonb_array_elements(v_birthday_labels->'labels') AS rows(item);
  IF v_expected_ids IS DISTINCT FROM v_active_ids THEN
    RAISE EXCEPTION 'Rejected inclusion must preserve all birthday labels: %', v_expected_ids;
  END IF;

  v_restore := public.restore_board_label_p(
    v_board.slug, v_hidden_label_id, 2, 'Etiqueta recuperada',
    ARRAY[]::uuid[], ARRAY[]::uuid[]
  );
  IF v_restore->>'status' IS DISTINCT FROM 'confirmed'
    OR v_restore->'restored_task_ids' IS DISTINCT FROM '[]'::jsonb
    OR v_restore->'restored_birthday_ids' IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'Explicitly omitting over-limit associations must restore only the label: %',
      v_restore;
  END IF;
  v_task_labels := public.get_task_labels_p(v_board.slug, v_task_id);
  v_birthday_labels := public.get_birthday_labels_p(v_board.slug, v_birthday_id);
  IF jsonb_array_length(v_task_labels->'labels') <> 10
    OR jsonb_array_length(v_birthday_labels->'labels') <> 10
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_task_labels->'labels') AS rows(item)
      WHERE rows.item->>'id' = v_hidden_label_id::text
    ) OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_birthday_labels->'labels') AS rows(item)
      WHERE rows.item->>'id' = v_hidden_label_id::text
    ) THEN
    RAISE EXCEPTION 'Omission may remove only that association and preserve both recovered items: %, %',
      v_task_labels, v_birthday_labels;
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: board-scoped label CRUD, assignments, recovery, permissions, capacity, and retention'
