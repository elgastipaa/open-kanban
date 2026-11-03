\set ON_ERROR_STOP on
\timing on
\echo 'Issue #48 synthetic load: 500 tasks and 25,000 comments; no real user data.'

INSERT INTO public.application_access (email, state, is_admin)
VALUES
  ('issue48-owner@example.test', 'pending', false),
  ('issue48-collaborator@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES
  ('94800000-0000-4000-8000-000000000001',
    'issue48-owner@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('94800000-0000-4000-8000-000000000005',
    'issue48-collaborator@example.test', clock_timestamp(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES
  ('94800000-0000-4000-8000-000000000002',
    '94800000-0000-4000-8000-000000000001', 'google', 'issue48-owner',
    '{"email":"issue48-owner@example.test","email_verified":true}'),
  ('94800000-0000-4000-8000-000000000006',
    '94800000-0000-4000-8000-000000000005', 'google', 'issue48-collaborator',
    '{"email":"issue48-collaborator@example.test","email_verified":true}');
UPDATE public.application_access
SET auth_user_id = auth_user.id,
    google_subject = identity.provider_id, state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE public.application_access.email = auth_user.email
  AND auth_user.email LIKE 'issue48-%@example.test';
SELECT set_config('request.jwt.claim.sub', '94800000-0000-4000-8000-000000000001', false);

CREATE TEMP TABLE issue48_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  generation_id uuid NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON issue48_fixture TO authenticated;

DO $$
DECLARE
  v_board record;
  v_column record;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 48 synthetic load', 'UTC', '94800000-0000-4000-8000-000000000003'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Carga', 0);
  INSERT INTO public.board_memberships(board_id, user_id, role)
  VALUES (v_board.id, '94800000-0000-4000-8000-000000000005', 'collaborator');
  INSERT INTO issue48_fixture(board_id, board_slug, generation_id, column_id, task_id)
  SELECT v_board.id, v_board.slug, board.active_generation_id, v_column.id,
    md5('issue48-task-1')::uuid
  FROM public.boards AS board WHERE board.id = v_board.id;
END;
$$;

-- Direct fixture inserts are isolated in this disposable database and skip
-- per-row production triggers so the 25,000-row setup remains reproducible.
-- The stale-cursor scenarios below use the authenticated edit RPC and its real
-- revision/activity triggers.
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO public.tasks (
  id, column_id, title, description, priority, position, created_at,
  updated_at, created_by, due_on
)
SELECT
  md5('issue48-task-' || task_number)::uuid,
  fixture.column_id,
  pg_catalog.format('Tarea de carga Peña %s', task_number),
  pg_catalog.repeat('Descripción sintética carga Unicode Peña ', 5),
  CASE task_number % 4
    WHEN 0 THEN 'low' WHEN 1 THEN 'medium' WHEN 2 THEN 'high' ELSE 'urgent'
  END,
  task_number,
  timestamptz '2025-01-01 00:00:00+00' + task_number * interval '1 second',
  timestamptz '2025-01-01 00:00:00+00' + task_number * interval '1 second',
  '94800000-0000-4000-8000-000000000001',
  date '2026-01-01' + (task_number % 365)
FROM issue48_fixture AS fixture
CROSS JOIN generate_series(1, 500) AS task_number;

INSERT INTO public.task_comments (
  id, board_id, task_id, author_id, author_name, content, created_at
)
SELECT
  md5('issue48-comment-' || task_number || '-' || comment_number)::uuid,
  fixture.board_id,
  md5('issue48-task-' || task_number)::uuid,
  '94800000-0000-4000-8000-000000000001',
  'Persona sintética',
  pg_catalog.format(
    'Comentario voluminoso %s de tarea %s: carga de búsqueda, historial y texto Peña. %s',
    comment_number, task_number,
    pg_catalog.repeat('fragmento de conversación sintética ', 5)
  ),
  timestamptz '2025-01-01 00:00:00+00'
    + (task_number * 50 + comment_number) * interval '1 second'
FROM issue48_fixture AS fixture
CROSS JOIN generate_series(1, 500) AS task_number
CROSS JOIN generate_series(1, 50) AS comment_number;
COMMIT;

-- A bounded activity and inbox history exercises their existing keyset pages.
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO public.task_activity_events (
  id, board_id, task_id, category, actor_type, actor_name,
  occurred_at, before_value, after_value
)
SELECT
  md5('issue48-activity-' || item)::uuid,
  fixture.board_id, fixture.task_id, 'due_date', 'user', 'Persona sintética',
  clock_timestamp() - item * interval '1 second',
  '"2026-01-01"'::jsonb, '"2026-01-02"'::jsonb
FROM issue48_fixture AS fixture CROSS JOIN generate_series(1, 90) AS item;

INSERT INTO public.task_notifications (
  id, board_id, generation_id, task_id, source_kind, source_id,
  recipient_user_id, recipient_membership_id, reason_codes, actor_name,
  occurred_at, state, delivered_at
)
SELECT
  md5('issue48-notification-' || item)::uuid,
  fixture.board_id, fixture.generation_id, fixture.task_id,
  'task_change', md5('issue48-notification-source-' || item)::uuid,
  '94800000-0000-4000-8000-000000000001', membership.id,
  ARRAY['due_date'], 'Persona sintética',
  clock_timestamp() - item * interval '1 second', 'delivered', clock_timestamp()
FROM issue48_fixture AS fixture
JOIN public.board_memberships AS membership
  ON membership.board_id = fixture.board_id
  AND membership.user_id = '94800000-0000-4000-8000-000000000001'
  AND membership.revoked_at IS NULL
CROSS JOIN generate_series(1, 90) AS item;
COMMIT;

ANALYZE public.tasks;
ANALYZE public.task_comments;
ANALYZE public.task_activity_events;
ANALYZE public.task_notifications;

\echo 'Board summary and on-demand conversation page'
SELECT
  jsonb_array_length(public.get_full_board_p(fixture.board_slug)::jsonb->'columns') AS columns,
  (SELECT sum(jsonb_array_length(column_row->'tasks'))
   FROM jsonb_array_elements(
     public.get_full_board_p(fixture.board_slug)::jsonb->'columns'
   ) AS column_row) AS summary_tasks,
  (public.get_full_board_p(fixture.board_slug)::jsonb->'columns'->0)
    ? 'tasks' AS summary_contains_tasks,
  (public.get_full_board_p(fixture.board_slug)::jsonb->'columns'->0)
    ? 'comments' AS summary_contains_comments
FROM issue48_fixture AS fixture;
EXPLAIN (ANALYZE, BUFFERS)
SELECT public.get_full_board_p(fixture.board_slug)
FROM issue48_fixture AS fixture;

SELECT
  jsonb_array_length(page->'comments') AS detail_comments,
  page->>'has_more' AS detail_has_more
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.get_task_comments_p(
  fixture.board_slug, fixture.task_id, 30, NULL, NULL, NULL
) AS page;

\echo 'Comments page plan (same task/chronological index used by the RPC)'
EXPLAIN (ANALYZE, BUFFERS)
SELECT comment_row.id
FROM public.task_comments AS comment_row
WHERE comment_row.task_id = md5('issue48-task-1')::uuid
ORDER BY comment_row.created_at DESC, comment_row.id DESC
LIMIT 31;

\echo 'Activity and notification first pages'
SELECT jsonb_array_length(page->'events') AS activity_page,
  page->>'has_more' AS activity_has_more
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.get_task_activity_p(
  fixture.board_slug, fixture.task_id, 30, NULL, NULL
) AS page;
SELECT jsonb_array_length(page->'items') AS notification_page,
  page->>'has_more' AS notification_has_more
FROM public.list_my_task_notifications_p('all', 30, NULL, NULL) AS page;

\echo 'Search latency cases (SQL RPC execution; task mode returns up to 24 rows)'
SELECT 'one_letter' AS case_name,
  jsonb_array_length(result->'results') AS returned_rows,
  result->>'has_more' AS has_more,
  result->>'status' AS status
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.search_unified_page_p(
  't', 'board', fixture.board_id, NULL, false, false, NULL, NULL, false,
  NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
) AS result;
SELECT 'two_letters' AS case_name,
  jsonb_array_length(result->'results') AS returned_rows,
  result->>'has_more' AS has_more,
  result->>'status' AS status
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.search_unified_page_p(
  'ta', 'board', fixture.board_id, NULL, false, false, NULL, NULL, false,
  NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
) AS result;
SELECT 'multiword' AS case_name,
  jsonb_array_length(result->'results') AS returned_rows,
  result->>'has_more' AS has_more,
  result->>'status' AS status
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.search_unified_page_p(
  'tarea carga', 'board', fixture.board_id, NULL, false, false, NULL, NULL, false,
  NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
) AS result;
SELECT 'unicode' AS case_name,
  jsonb_array_length(result->'results') AS returned_rows,
  result->>'has_more' AS has_more,
  result->>'status' AS status
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.search_unified_page_p(
  'peña', 'board', fixture.board_id, NULL, false, false, NULL, NULL, false,
  NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
) AS result;
SELECT 'comments' AS case_name,
  jsonb_array_length(result->'results') AS returned_rows,
  result->>'has_more' AS has_more,
  result->>'status' AS status
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.search_unified_page_p(
  'comentario voluminoso', 'board', fixture.board_id, NULL, false, false, NULL, NULL, false,
  NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
) AS result;
EXPLAIN (ANALYZE, BUFFERS)
SELECT public.search_unified_page_p(
  'carga', 'board', fixture.board_id, NULL, false, false, NULL, NULL, false,
  NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
)
FROM issue48_fixture AS fixture;

\echo 'Full export snapshot and complete ordinal pagination'
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_snapshot jsonb;
  v_page jsonb;
  v_entity text;
  v_expected bigint;
  v_seen bigint;
  v_after bigint;
  v_items jsonb;
  v_pages integer;
  v_edit jsonb;
  v_totals jsonb := '{}'::jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;
  v_snapshot := public.create_board_export_snapshot_p(
    '94800000-0000-4000-8000-000000000001', v_fixture.board_slug
  );
  IF v_snapshot->>'status' <> 'created' THEN
    RAISE EXCEPTION 'Synthetic export snapshot could not be created: %', v_snapshot;
  END IF;
  FOR v_entity, v_expected IN
    SELECT entry.key, entry.value::text::bigint
    FROM jsonb_each(v_snapshot->'record_counts') AS entry
    ORDER BY entry.key
  LOOP
    v_after := 0;
    v_seen := 0;
    v_pages := 0;
    LOOP
      v_page := public.read_board_export_snapshot_page_p(
        '94800000-0000-4000-8000-000000000001', v_fixture.board_slug,
        (v_snapshot->>'export_id')::uuid, v_entity, v_after, 250
      );
      IF v_page->>'status' <> 'page'
        OR (v_page->>'record_count')::bigint <> v_expected THEN
        RAISE EXCEPTION 'Unexpected export page for %: %', v_entity, v_page;
      END IF;
      v_items := v_page->'items';
      v_seen := v_seen + jsonb_array_length(v_items);
      v_pages := v_pages + 1;
      IF v_entity = 'tasks' AND v_pages = 1 THEN
        v_edit := public.edit_task_fields_p(
          gen_random_uuid(), v_fixture.board_slug,
          md5('issue48-task-500')::uuid,
          '{"title":"Tarea editada después del snapshot"}'::jsonb,
          '{"title":1}'::jsonb
        );
        IF v_edit->>'status' <> 'confirmed' THEN
          RAISE EXCEPTION 'Could not edit a task between fixed export pages: %', v_edit;
        END IF;
      ELSIF v_entity = 'tasks' AND v_after = 250 AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_items) AS item
        WHERE item->'payload'->>'title' = 'Tarea de carga Peña 500'
      ) THEN
        RAISE EXCEPTION 'The second export page did not preserve its pre-edit task snapshot';
      END IF;
      IF jsonb_array_length(v_items) > 0 THEN
        v_after := (v_items->(jsonb_array_length(v_items) - 1)->>'ordinal')::bigint;
      END IF;
      EXIT WHEN NOT (v_page->>'has_more')::boolean;
    END LOOP;
    IF v_entity = 'tasks' THEN
      v_edit := public.edit_task_fields_p(
        gen_random_uuid(), v_fixture.board_slug,
        md5('issue48-task-500')::uuid,
        '{"title":"Tarea de carga Peña 500"}'::jsonb,
        '{"title":2}'::jsonb
      );
      IF v_edit->>'status' <> 'confirmed' THEN
        RAISE EXCEPTION 'Could not restore the synthetic task edited during export: %', v_edit;
      END IF;
      RAISE NOTICE 'PASS: export task ordinals kept the pre-edit title across pages';
    END IF;
    IF v_seen <> v_expected OR v_after <> v_expected THEN
      RAISE EXCEPTION 'Export did not return every ordered row for %: % / %',
        v_entity, v_seen, v_expected;
    END IF;
    v_totals := v_totals || jsonb_build_object(v_entity,
      jsonb_build_object('records', v_seen, 'pages', v_pages));
  END LOOP;
  RAISE NOTICE 'Issue #48 export result counts: %', v_snapshot->'record_counts';
  RAISE NOTICE 'Issue #48 export ordinal pages: %', v_totals;
END;
$$;

\echo 'Comment keyset pages while a newer comment is inserted'
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_first jsonb;
  v_second jsonb;
  v_search_first jsonb;
  v_search_stale jsonb;
  v_created jsonb;
  v_search_comment jsonb;
  v_cursor jsonb;
  v_search_cursor jsonb;
  v_comment_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;
  v_first := public.get_task_comments_p(
    v_fixture.board_slug, v_fixture.task_id, 30, NULL, NULL, NULL
  );
  v_cursor := v_first->'next_cursor';
  v_created := public.create_task_comment_p(
    gen_random_uuid(), v_fixture.board_slug, v_fixture.task_id,
    'Comentario sintético insertado entre páginas'
  );
  IF v_created->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not add a synthetic comment between pages: %', v_created;
  END IF;
  v_comment_id := (v_created->>'comment_id')::uuid;
  v_second := public.get_task_comments_p(
    v_fixture.board_slug, v_fixture.task_id, 30,
    (v_cursor->>'created_at')::timestamptz,
    (v_cursor->>'id')::uuid, NULL
  );
  IF jsonb_array_length(v_first->'comments') <> 30
    OR jsonb_array_length(v_second->'comments') <> 20
    OR (v_second->>'has_more')::boolean
    OR EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_first->'comments') AS first_page
      JOIN jsonb_array_elements(v_second->'comments') AS second_page
        ON first_page->>'id' = second_page->>'id'
    )
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_second->'comments') AS item
      WHERE item->>'id' = v_comment_id::text
    ) THEN
    RAISE EXCEPTION 'Comment keyset pages overlapped or shifted after a newer insert: %, %',
      v_first, v_second;
  END IF;
  RAISE NOTICE 'PASS: the in-progress comment cursor returned its original 50 rows; newer insert waits for refresh';

  v_search_first := public.search_unified_page_p(
    'comentario voluminoso', 'board', v_fixture.board_id, NULL,
    false, false, NULL, NULL, false, NULL, '[]'::jsonb,
    'created', 'tasks', 24, NULL
  );
  v_search_cursor := v_search_first->'next_cursor';
  v_search_comment := public.create_task_comment_p(
    gen_random_uuid(), v_fixture.board_slug, v_fixture.task_id,
    'Comentario voluminoso agregado entre páginas de búsqueda'
  );
  IF v_search_comment->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not add a matching comment during search pagination: %',
      v_search_comment;
  END IF;
  v_search_stale := public.search_unified_page_p(
    'comentario voluminoso', 'board', v_fixture.board_id, NULL,
    false, false, NULL, NULL, false, NULL, '[]'::jsonb,
    'created', 'tasks', 24, v_search_cursor
  );
  IF v_search_stale->>'status' <> 'stale_page' THEN
    RAISE EXCEPTION 'A searchable comment insert must invalidate the search cursor: %',
      v_search_stale;
  END IF;
  RAISE NOTICE 'PASS: searchable comment insertion invalidated the unified-search cursor';
END;
$$;

\echo 'Search a synthetic replaced occurrence by its history-only comment'
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_start_on date;
  v_edit jsonb;
  v_series jsonb;
  v_comment jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;
  v_start_on := public.board_calendar_day('UTC', statement_timestamp()) - 1;
  v_edit := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_fixture.task_id,
    jsonb_build_object('due_on', v_start_on), '{"due_on":1}'::jsonb
  );
  IF v_edit->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the synthetic history start date: %', v_edit;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    gen_random_uuid(), v_fixture.board_slug, v_fixture.task_id,
    v_start_on, NULL, 2, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_fixture.column_id
  );
  IF v_series->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the synthetic history series: %', v_series;
  END IF;
  v_comment := public.create_task_comment_p(
    gen_random_uuid(), v_fixture.board_slug, v_fixture.task_id,
    'Historial voluminoso de Peña'
  );
  IF v_comment->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the history-only search comment: %', v_comment;
  END IF;
END;
$$;
BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.run_daily_repetition_jobs_p(20);
COMMIT;
SELECT 'history_only_comment' AS case_name,
  jsonb_array_length(result->'results') AS returned_rows,
  result->>'has_more' AS has_more,
  result->>'status' AS status
FROM issue48_fixture AS fixture
CROSS JOIN LATERAL public.search_unified_page_p(
  'historial voluminoso', 'board', fixture.board_id, NULL, false, true,
  NULL, NULL, false, NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
) AS result;
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;
  v_result := public.search_unified_page_p(
    'historial voluminoso', 'board', v_fixture.board_id, NULL, false, true,
    NULL, NULL, false, NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  IF v_result->>'status' <> 'available'
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_result->'results') AS result
      WHERE result->>'is_historical' = 'true'
        AND result->>'occurrence_state' = 'replaced'
    ) THEN
    RAISE EXCEPTION 'History-only search did not return the replaced occurrence: %',
      v_result;
  END IF;
END;
$$;

\echo 'Legacy cursor mutation reproduction: edit one row from page 2 behind page 1 cursor'
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_first jsonb;
  v_second_before jsonb;
  v_second_after jsonb;
  v_cursor jsonb;
  v_target_id uuid;
  v_old_due date;
  v_edit jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;
  v_first := public.search_unified_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
  );
  v_cursor := v_first->'next_cursor';
  v_second_before := public.search_unified_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, v_cursor
  );
  v_target_id := (v_second_before->'results'->0->>'task_id')::uuid;
  SELECT task.due_on INTO STRICT v_old_due
  FROM public.tasks AS task WHERE task.id = v_target_id;
  v_edit := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_target_id,
    jsonb_build_object('due_on', '1900-01-01'), '{"due_on":1}'::jsonb
  );
  IF v_edit->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not move the synthetic result during pagination: %', v_edit;
  END IF;
  v_second_after := public.search_unified_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, v_cursor
  );
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_second_before->'results') AS old_row
    WHERE old_row->>'task_id' = v_target_id::text
  ) AND NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_second_after->'results') AS new_row
    WHERE new_row->>'task_id' = v_target_id::text
  ) THEN
    RAISE NOTICE 'BASELINE OMISSION: task % was in page 2 before edit and absent after; old due_on=%',
      v_target_id, v_old_due;
  ELSE
    RAISE EXCEPTION 'The synthetic cursor edit did not reproduce an omission: before %, after %',
      v_second_before->'results', v_second_after->'results';
  END IF;
  v_edit := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_target_id,
    jsonb_build_object('due_on', v_old_due), '{"due_on":2}'::jsonb
  );
  IF v_edit->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not restore the synthetic cursor row: %', v_edit;
  END IF;
END;
$$;

\echo 'Revision-aware cursor invalidation and first-page restart'
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_first jsonb;
  v_second_before jsonb;
  v_stale jsonb;
  v_restarted jsonb;
  v_cursor jsonb;
  v_target_id uuid;
  v_old_due date;
  v_due_version bigint;
  v_edit jsonb;
  v_other_actor_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;
  v_first := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
  );
  v_cursor := v_first->'next_cursor';
  IF v_first->>'status' <> 'available' OR v_cursor->>'revision' !~ '^[0-9a-f]{32}$' THEN
    RAISE EXCEPTION 'The first page did not return a revision-bound cursor: %', v_first;
  END IF;
  v_stale := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, v_cursor - 'revision'
  );
  IF v_stale->>'status' <> 'stale_page' OR v_stale->'results' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'A legacy cursor must restart explicitly without returning a mixed page: %',
      v_stale;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '94800000-0000-4000-8000-000000000005', true
  );
  v_other_actor_page := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, v_cursor
  );
  IF v_other_actor_page->>'status' <> 'stale_page' THEN
    RAISE EXCEPTION 'A cursor from another authorized actor must be stale: %',
      v_other_actor_page;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '94800000-0000-4000-8000-000000000001', true
  );
  v_other_actor_page := public.search_unified_page_p(
    'tarea', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, v_cursor
  );
  IF v_other_actor_page->>'status' <> 'stale_page' THEN
    RAISE EXCEPTION 'A task cursor must be stale after its query parameters change: %',
      v_other_actor_page;
  END IF;
  v_second_before := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, v_cursor
  );
  v_target_id := (v_second_before->'results'->0->>'task_id')::uuid;
  SELECT task.due_on, (task.field_versions->>'due_on')::bigint
  INTO STRICT v_old_due, v_due_version
  FROM public.tasks AS task WHERE task.id = v_target_id;
  v_edit := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_target_id,
    jsonb_build_object('due_on', '1900-01-01'),
    jsonb_build_object('due_on', v_due_version)
  );
  IF v_edit->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not edit the task between revision-bound pages: %', v_edit;
  END IF;
  v_stale := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, v_cursor
  );
  IF v_stale->>'status' <> 'stale_page'
    OR v_stale->'results' <> '[]'::jsonb
    OR coalesce((v_stale->>'has_more')::boolean, true)
    OR v_stale->'next_cursor' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'An edited search page must return an explicit stale status: %', v_stale;
  END IF;
  v_restarted := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'due', 'tasks', 24, NULL
  );
  IF v_restarted->>'status' <> 'available' OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_restarted->'results') AS result
    WHERE result->>'task_id' = v_target_id::text
  ) THEN
    RAISE EXCEPTION 'Restarting from the first page did not include the moved task: %',
      v_restarted;
  END IF;
  v_due_version := v_due_version + 1;
  v_edit := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_target_id,
    jsonb_build_object('due_on', v_old_due),
    jsonb_build_object('due_on', v_due_version)
  );
  IF v_edit->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not restore the synthetic page-edit task: %', v_edit;
  END IF;
  RAISE NOTICE 'PASS: changed due_on invalidated the cursor and page one recovered task %',
    v_target_id;
END;
$$;


\echo 'Search cursor invalidation for title, completion, deletion, restoration, and access changes'
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_first jsonb;
  v_stale jsonb;
  v_cursor jsonb;
  v_task_id uuid;
  v_title text;
  v_title_version bigint;
  v_completion_version bigint;
  v_field_edit jsonb;
  v_completion jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_membership_id uuid;
  v_removed jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;

  v_first := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  v_cursor := v_first->'next_cursor';
  v_task_id := (v_first->'results'->0->>'task_id')::uuid;
  SELECT task.title, (task.field_versions->>'title')::bigint
  INTO STRICT v_title, v_title_version
  FROM public.tasks AS task WHERE task.id = v_task_id;
  v_field_edit := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_task_id,
    '{"title":"Tarea renombrada fuera de consulta"}'::jsonb,
    jsonb_build_object('title', v_title_version)
  );
  IF v_field_edit->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not change a matching synthetic title: %', v_field_edit;
  END IF;
  v_stale := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, v_cursor
  );
  IF v_stale->>'status' <> 'stale_page' OR v_stale->'results' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'A title change that removes a result must invalidate its cursor: %', v_stale;
  END IF;
  v_field_edit := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_task_id,
    jsonb_build_object('title', v_title),
    jsonb_build_object('title', v_title_version + 1)
  );
  IF v_field_edit->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not restore the synthetic title: %', v_field_edit;
  END IF;

  v_first := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  v_cursor := v_first->'next_cursor';
  v_task_id := (v_first->'results'->0->>'task_id')::uuid;
  SELECT task.completion_version INTO STRICT v_completion_version
  FROM public.tasks AS task WHERE task.id = v_task_id AND NOT task.is_completed;
  v_completion := public.set_task_completion_p(
    gen_random_uuid(), v_fixture.board_slug, v_task_id, true, v_completion_version
  );
  IF v_completion->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not complete a matching synthetic task: %', v_completion;
  END IF;
  v_stale := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, v_cursor
  );
  IF v_stale->>'status' <> 'stale_page' OR v_stale->'results' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'Completion that removes a result must invalidate its cursor: %', v_stale;
  END IF;
  v_completion := public.set_task_completion_p(
    gen_random_uuid(), v_fixture.board_slug, v_task_id, false,
    v_completion_version + 1
  );
  IF v_completion->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not reopen the synthetic task: %', v_completion;
  END IF;

  v_first := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  v_cursor := v_first->'next_cursor';
  v_task_id := (v_first->'results'->0->>'task_id')::uuid;
  v_deleted := public.delete_task_p(
    gen_random_uuid(), v_fixture.board_slug, v_task_id, 'user_requested'
  );
  IF v_deleted->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not delete the synthetic task: %', v_deleted;
  END IF;
  v_stale := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, v_cursor
  );
  IF v_stale->>'status' <> 'stale_page' OR v_stale->'results' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'Task deletion must invalidate its cursor: %', v_stale;
  END IF;

  v_first := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  v_cursor := v_first->'next_cursor';
  v_restored := public.restore_task_p(
    gen_random_uuid(), v_fixture.board_slug, v_task_id
  );
  IF v_restored->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not restore the synthetic task: %', v_restored;
  END IF;
  v_stale := public.search_unified_page_p(
    'carga', 'board', v_fixture.board_id, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, v_cursor
  );
  IF v_stale->>'status' <> 'stale_page' OR v_stale->'results' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'Task restoration must invalidate the cursor: %', v_stale;
  END IF;

  SELECT membership.id INTO STRICT v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = '94800000-0000-4000-8000-000000000005'
    AND membership.revoked_at IS NULL;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '94800000-0000-4000-8000-000000000005', true
  );
  v_first := public.search_unified_page_p(
    'carga', 'all', NULL, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  v_cursor := v_first->'next_cursor';
  IF v_first->>'status' <> 'available' OR v_cursor IS NULL THEN
    RAISE EXCEPTION 'The authorized collaborator did not receive a search cursor: %', v_first;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '94800000-0000-4000-8000-000000000001', true
  );
  v_removed := public.remove_board_collaborator_p(
    gen_random_uuid(), v_fixture.board_id, v_membership_id
  );
  IF v_removed->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'Could not revoke the synthetic collaborator: %', v_removed;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '94800000-0000-4000-8000-000000000005', true
  );
  v_stale := public.search_unified_page_p(
    'carga', 'all', NULL, NULL, false, false, NULL, NULL, false,
    NULL, '[]'::jsonb, 'created', 'tasks', 24, v_cursor
  );
  IF v_stale->>'status' <> 'stale_page' OR v_stale->'results' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'A permission change must invalidate the prior authorized cursor: %', v_stale;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '94800000-0000-4000-8000-000000000001', true
  );
  RAISE NOTICE 'PASS: title, completion, deletion, restoration, and membership changes returned stale_page';
END;
$$;

\echo 'Relative due-filter cursors bind to the board-local day'
DO $$
DECLARE
  v_fixture issue48_fixture%ROWTYPE;
  v_today date;
  v_yesterday date;
  v_changed integer;
  v_created_at timestamptz;
  v_cursor jsonb;
  v_content_revision text;
  v_cursor_revision text;
  v_stale jsonb;
  v_refreshed jsonb;
  v_no_date_page jsonb;
  v_no_date_second jsonb;
  v_unfiltered_page jsonb;
  v_unfiltered_second jsonb;
  v_revision text;
  v_task_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue48_fixture;
  v_today := public.board_calendar_day('UTC', statement_timestamp());
  v_yesterday := v_today - 1;

  -- Model the prior day without sleeping or changing the test server clock:
  -- 30 matches existed for `today` yesterday; one different task matches today.
  -- Task 1 is intentionally omitted because the history scenario converted it
  -- into a replaced occurrence, which normal task search excludes.
  UPDATE public.tasks AS task
  SET title = pg_catalog.format('Midnight cursor synthetic overdue %s', number),
      due_on = v_yesterday,
      is_completed = false,
      completed_at = NULL,
      completion_version = task.completion_version
        + CASE WHEN task.is_completed THEN 1 ELSE 0 END,
      field_versions = task.field_versions || pg_catalog.jsonb_build_object(
        'title', (task.field_versions->>'title')::bigint + 1,
        'due_on', (task.field_versions->>'due_on')::bigint + 1
      )
  FROM generate_series(2, 31) AS fixture_number(number)
  WHERE task.id = md5('issue48-task-' || fixture_number.number)::uuid;
  GET DIAGNOSTICS v_changed = ROW_COUNT;
  IF v_changed <> 30 THEN
    RAISE EXCEPTION 'Could not prepare the 30 synthetic previous-day tasks: %', v_changed;
  END IF;
  UPDATE public.tasks AS task
  SET title = 'Midnight cursor synthetic today',
      due_on = v_today,
      field_versions = task.field_versions || pg_catalog.jsonb_build_object(
        'title', (task.field_versions->>'title')::bigint + 1,
        'due_on', (task.field_versions->>'due_on')::bigint + 1
      )
  WHERE task.id = md5('issue48-task-32')::uuid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Could not prepare the synthetic current-day task';
  END IF;

  SELECT task.created_at INTO STRICT v_created_at
  FROM public.tasks AS task
  WHERE task.id = md5('issue48-task-24')::uuid;
  SELECT coalesce(pg_catalog.string_agg(
    revision.board_id::text || ':' || revision.revision::text || ':' || v_yesterday::text,
    ',' ORDER BY revision.board_id
  ), '') INTO v_content_revision
  FROM public.board_content_revisions AS revision
  JOIN public.boards AS board ON board.id = revision.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL
  WHERE board.id = v_fixture.board_id;
  v_cursor_revision := pg_catalog.md5(pg_catalog.jsonb_build_array(
    auth.uid(), 'midnight cursor', 'board', v_fixture.board_id, NULL,
    false, false, NULL, NULL, false, 'today', '[]'::jsonb, 'due', 'tasks',
    v_content_revision
  )::text);
  v_cursor := pg_catalog.jsonb_build_object(
    'due_on', v_yesterday,
    'created_at', v_created_at,
    'id', md5('issue48-task-24')::uuid,
    'revision', v_cursor_revision
  );
  v_stale := public.search_unified_page_p(
    'midnight cursor', 'board', v_fixture.board_id, NULL, false, false,
    NULL, NULL, false, 'today', '[]'::jsonb, 'due', 'tasks', 24, v_cursor
  );
  IF v_stale->>'status' <> 'stale_page'
    OR v_stale->'results' <> '[]'::jsonb
    OR coalesce((v_stale->>'has_more')::boolean, true)
    OR v_stale->'next_cursor' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'A prior-board-day `today` cursor must be stale: %', v_stale;
  END IF;
  v_refreshed := public.search_unified_page_p(
    'midnight cursor', 'board', v_fixture.board_id, NULL, false, false,
    NULL, NULL, false, 'today', '[]'::jsonb, 'due', 'tasks', 24, NULL
  );
  v_task_id := md5('issue48-task-32')::uuid;
  IF v_refreshed->>'status' <> 'available'
    OR jsonb_array_length(v_refreshed->'results') <> 1
    OR v_refreshed->'results'->0->>'task_id' <> v_task_id::text
    OR v_refreshed->>'has_more' <> 'false'
    OR v_refreshed->'next_cursor' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Refreshing the due filter did not use the current board day: %',
      v_refreshed;
  END IF;

  UPDATE public.tasks AS task
  SET due_on = NULL,
      field_versions = task.field_versions || pg_catalog.jsonb_build_object(
        'due_on', (task.field_versions->>'due_on')::bigint + 1
      )
  WHERE task.id IN (
    SELECT md5('issue48-task-' || number)::uuid
    FROM generate_series(2, 31) AS number
  );
  GET DIAGNOSTICS v_changed = ROW_COUNT;
  IF v_changed <> 30 THEN
    RAISE EXCEPTION 'Could not prepare the synthetic no-date tasks: %', v_changed;
  END IF;

  v_no_date_page := public.search_unified_page_p(
    'midnight cursor', 'board', v_fixture.board_id, NULL, false, false,
    NULL, NULL, false, 'no_date', '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  v_cursor := v_no_date_page->'next_cursor';
  SELECT coalesce(pg_catalog.string_agg(
    revision.board_id::text || ':' || revision.revision::text,
    ',' ORDER BY revision.board_id
  ), '') INTO v_content_revision
  FROM public.board_content_revisions AS revision
  JOIN public.boards AS board ON board.id = revision.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL
  WHERE board.id = v_fixture.board_id;
  v_revision := pg_catalog.md5(pg_catalog.jsonb_build_array(
    auth.uid(), 'midnight cursor', 'board', v_fixture.board_id, NULL,
    false, false, NULL, NULL, false, 'no_date', '[]'::jsonb, 'created', 'tasks',
    v_content_revision
  )::text);
  v_no_date_second := public.search_unified_page_p(
    'midnight cursor', 'board', v_fixture.board_id, NULL, false, false,
    NULL, NULL, false, 'no_date', '[]'::jsonb, 'created', 'tasks', 24,
    v_cursor || pg_catalog.jsonb_build_object('revision', v_revision)
  );
  IF v_no_date_page->>'status' <> 'available'
    OR jsonb_array_length(v_no_date_page->'results') <> 24
    OR v_no_date_second->>'status' <> 'available'
    OR jsonb_array_length(v_no_date_second->'results') <> 6 THEN
    RAISE EXCEPTION '`no_date` keyset counts/statuses were unexpected: %, %, %, %',
      v_no_date_page->>'status', jsonb_array_length(v_no_date_page->'results'),
      v_no_date_second->>'status', jsonb_array_length(v_no_date_second->'results');
  END IF;

  v_unfiltered_page := public.search_unified_page_p(
    'midnight cursor', 'board', v_fixture.board_id, NULL, false, false,
    NULL, NULL, false, NULL, '[]'::jsonb, 'created', 'tasks', 24, NULL
  );
  v_cursor := v_unfiltered_page->'next_cursor';
  v_revision := pg_catalog.md5(pg_catalog.jsonb_build_array(
    auth.uid(), 'midnight cursor', 'board', v_fixture.board_id, NULL,
    false, false, NULL, NULL, false, NULL, '[]'::jsonb, 'created', 'tasks',
    v_content_revision
  )::text);
  v_unfiltered_second := public.search_unified_page_p(
    'midnight cursor', 'board', v_fixture.board_id, NULL, false, false,
    NULL, NULL, false, NULL, '[]'::jsonb, 'created', 'tasks', 24,
    v_cursor || pg_catalog.jsonb_build_object('revision', v_revision)
  );
  IF v_unfiltered_page->>'status' <> 'available'
    OR jsonb_array_length(v_unfiltered_page->'results') <> 24
    OR v_unfiltered_second->>'status' <> 'available'
    OR jsonb_array_length(v_unfiltered_second->'results') <> 7 THEN
    RAISE EXCEPTION 'Unfiltered keyset counts/statuses were unexpected: %, %, %, %',
      v_unfiltered_page->>'status', jsonb_array_length(v_unfiltered_page->'results'),
      v_unfiltered_second->>'status', jsonb_array_length(v_unfiltered_second->'results');
  END IF;

  RAISE NOTICE 'PASS: previous-day `today` cursor restarts; current page is recalculated; `no_date` and unfiltered cursors do not stale on calendar day alone';
END;
$$;

\echo 'Synthetic load fixture complete.'
