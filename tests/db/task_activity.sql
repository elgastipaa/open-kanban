\set ON_ERROR_STOP on
\echo 'Verifying task activity records a confirmed completion change'

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43600000-0000-4000-8000-000000000002',
  'issue36-activity@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53600000-0000-4000-8000-000000000002',
  '43600000-0000-4000-8000-000000000002',
  'google', 'issue36-activity',
  '{"email":"issue36-activity@example.test","name":"Persona sintética","email_verified":true}'
);
INSERT INTO public.application_access (email, auth_user_id, google_subject, state)
VALUES (
  'issue36-activity@example.test',
  '43600000-0000-4000-8000-000000000002',
  'issue36-activity', 'active'
);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43600000-0000-4000-8000-000000000003',
  'issue36-outsider@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53600000-0000-4000-8000-000000000003',
  '43600000-0000-4000-8000-000000000003',
  'google', 'issue36-outsider',
  '{"email":"issue36-outsider@example.test","name":"Persona ajena","email_verified":true}'
);
INSERT INTO public.application_access (email, auth_user_id, google_subject, state)
VALUES (
  'issue36-outsider@example.test',
  '43600000-0000-4000-8000-000000000003',
  'issue36-outsider', 'active'
);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43600000-0000-4000-8000-000000000004',
  'issue36-collaborator@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53600000-0000-4000-8000-000000000004',
  '43600000-0000-4000-8000-000000000004',
  'google', 'issue36-collaborator',
  '{"email":"issue36-collaborator@example.test","name":"Persona colaboradora","email_verified":true}'
);
INSERT INTO public.application_access (email, auth_user_id, google_subject, state)
VALUES (
  'issue36-collaborator@example.test',
  '43600000-0000-4000-8000-000000000004',
  'issue36-collaborator', 'active'
);

CREATE TABLE public.issue36_activity_fixture (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  imported_event_at timestamptz,
  departing_membership_id uuid
);
GRANT SELECT, INSERT ON public.issue36_activity_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43600000-0000-4000-8000-000000000002', true);

DO $$
DECLARE
  v_board record;
  v_column record;
  v_created jsonb;
  v_task_id uuid;
  v_assignee_operation_id uuid := gen_random_uuid();
  v_assignee_result jsonb;
  v_edit_result jsonb;
  v_move_result jsonb;
  v_completion jsonb;
  v_empty_page jsonb;
  v_page jsonb;
  v_first_page jsonb;
  v_second_page jsonb;
  v_initial_page jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_restored_page jsonb;
  v_cursor jsonb;
  v_event jsonb;
  v_source_column record;
  v_target_column record;
  v_event_count integer;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p('Actividad E05', 'UTC', gen_random_uuid());
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Pendiente', 0);
  v_created := public.create_task_p(
    gen_random_uuid(), v_board.id, v_column.id, 'Tarea sintética'
  );
  v_task_id := (v_created->>'task_id')::uuid;

  v_empty_page := public.get_task_activity_p(v_board.slug, v_task_id, 30, NULL, NULL);
  IF v_empty_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_empty_page->'events') <> 0 THEN
    RAISE EXCEPTION 'Creating a task must not create activity: %', v_empty_page;
  END IF;

  v_completion := public.set_task_completion_p(
    gen_random_uuid(), v_board.slug, v_task_id, true, 1
  );
  IF v_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The completion mutation was not confirmed: %', v_completion;
  END IF;

  v_assignee_result := public.set_task_assignee_p(
    v_assignee_operation_id, v_board.slug, v_task_id,
    '43600000-0000-4000-8000-000000000002', 1
  );
  IF v_assignee_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The assignee mutation was not confirmed: %', v_assignee_result;
  END IF;
  PERFORM public.set_task_assignee_p(
    v_assignee_operation_id, v_board.slug, v_task_id,
    '43600000-0000-4000-8000-000000000002', 1
  );

  v_edit_result := public.edit_task_fields_p(
    gen_random_uuid(), v_board.slug, v_task_id,
    '{"due_on":"2026-12-25","title":"Título actualizado"}'::jsonb,
    '{"due_on":1,"title":1}'::jsonb
  );
  IF v_edit_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The due date/title mutation was not confirmed: %', v_edit_result;
  END IF;

  SELECT * INTO STRICT v_target_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Destino', 1);
  SELECT * INTO STRICT v_source_column
  FROM public.get_columns_p(v_board.id)
  WHERE id = v_column.id;
  v_move_result := public.update_task_positions_p(
    gen_random_uuid(), v_board.slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_task_id,
      'source_column_id', v_source_column.id,
      'column_id', v_target_column.id,
      'before_task_id', NULL,
      'after_task_id', NULL
    )),
    jsonb_build_object(
      v_source_column.id::text, v_source_column.task_order_version,
      v_target_column.id::text, v_target_column.task_order_version
    )
  );
  IF v_move_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The column mutation was not confirmed: %', v_move_result;
  END IF;

  v_page := public.get_task_activity_p(v_board.slug, v_task_id, 30, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'available' THEN
    RAISE EXCEPTION 'Current members should read task activity: %', v_page;
  END IF;
  v_event_count := jsonb_array_length(v_page->'events');
  IF v_event_count <> 4
    OR v_page->>'has_more' IS DISTINCT FROM 'false'
    OR v_page->'next_cursor' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Only the four E05 changes should appear; create/title/assignee replay are not new events: %', v_page;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_page->'events') AS item(event)
    WHERE item.event->>'actor_type' IS DISTINCT FROM 'user'
      OR item.event->>'actor_name' IS DISTINCT FROM 'Persona sintética'
      OR (item.event->>'occurred_at')::timestamptz > clock_timestamp()
  ) THEN
    RAISE EXCEPTION 'Each event must preserve its human actor and event time: %', v_page;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_page->'events') AS item(event)
    WHERE item.event->>'category' = 'completion'
      AND item.event->'before_value' = 'false'::jsonb
      AND item.event->'after_value' = 'true'::jsonb
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_page->'events') AS item(event)
    WHERE item.event->>'category' = 'assignee'
      AND item.event->'before_value' = '"Sin responsable"'::jsonb
      AND item.event->'after_value' = '"Persona sintética"'::jsonb
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_page->'events') AS item(event)
    WHERE item.event->>'category' = 'due_date'
      AND item.event->'before_value' = 'null'::jsonb
      AND item.event->'after_value' = '"2026-12-25"'::jsonb
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_page->'events') AS item(event)
    WHERE item.event->>'category' = 'column'
      AND item.event->'before_value' = '"Pendiente"'::jsonb
      AND item.event->'after_value' = '"Destino"'::jsonb
  ) THEN
    RAISE EXCEPTION 'E05 events must expose the appropriate before/after values: %', v_page;
  END IF;
  IF (v_page->'events'->0->>'occurred_at')::timestamptz <
    (v_page->'events'->1->>'occurred_at')::timestamptz THEN
    RAISE EXCEPTION 'Activity must be ordered newest first: %', v_page;
  END IF;

  v_first_page := public.get_task_activity_p(v_board.slug, v_task_id, 2, NULL, NULL);
  v_cursor := v_first_page->'next_cursor';
  IF v_first_page->>'has_more' IS DISTINCT FROM 'true'
    OR jsonb_array_length(v_first_page->'events') <> 2
    OR v_cursor IS NULL OR v_cursor = 'null'::jsonb THEN
    RAISE EXCEPTION 'The first activity page must expose a cursor: %', v_first_page;
  END IF;
  v_second_page := public.get_task_activity_p(
    v_board.slug, v_task_id, 2,
    (v_cursor->>'occurred_at')::timestamptz,
    (v_cursor->>'id')::uuid
  );
  IF v_second_page->>'status' IS DISTINCT FROM 'available'
    OR v_second_page->>'has_more' IS DISTINCT FROM 'false'
    OR jsonb_array_length(v_second_page->'events') <> 2
    OR (v_first_page->'events'->1->>'occurred_at')::timestamptz <
       (v_second_page->'events'->0->>'occurred_at')::timestamptz THEN
    RAISE EXCEPTION 'Activity pages must continue strictly after the cursor: first %, second %',
      v_first_page, v_second_page;
  END IF;
  IF (
    SELECT count(DISTINCT event->>'id')
    FROM (
      SELECT jsonb_array_elements(v_first_page->'events') AS event
      UNION ALL
      SELECT jsonb_array_elements(v_second_page->'events') AS event
    ) AS all_pages
  ) <> 4 THEN
    RAISE EXCEPTION 'Activity pagination must neither repeat nor skip events';
  END IF;

  v_initial_page := v_page;
  v_deleted := public.delete_task_p(
    gen_random_uuid(), v_board.slug, v_task_id, 'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The task delete did not confirm: %', v_deleted;
  END IF;
  v_page := public.get_task_activity_p(v_board.slug, v_task_id, 30, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'unavailable'
    OR v_page ? 'events' THEN
    RAISE EXCEPTION 'Soft-deleted tasks must hide their activity: %', v_page;
  END IF;

  v_restored := public.restore_task_p(
    gen_random_uuid(), v_board.slug, v_task_id, v_target_column.id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The task restore did not confirm: %', v_restored;
  END IF;
  v_restored_page := public.get_task_activity_p(v_board.slug, v_task_id, 30, NULL, NULL);
  IF v_restored_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_restored_page->'events') <> 5
    OR (
      SELECT count(*)
      FROM jsonb_array_elements(v_restored_page->'events') AS item(event)
      WHERE item.event->>'category' = 'recovery'
        AND item.event->>'actor_type' = 'user'
        AND item.event->>'actor_name' = 'Persona sintética'
    ) <> 1 THEN
    RAISE EXCEPTION 'Restore should add one attributed recovery event and show only current events: %',
      v_restored_page;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_initial_page->'events') AS earlier(event)
    WHERE NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_restored_page->'events') AS current_event(event)
      WHERE current_event.event->>'id' = earlier.event->>'id'
        AND current_event.event->'occurred_at' = earlier.event->'occurred_at'
    )
  ) THEN
    RAISE EXCEPTION 'Restoring a task must not reset earlier event timestamps';
  END IF;

  INSERT INTO public.issue36_activity_fixture(
    purpose, board_id, board_slug, column_id, task_id
  ) VALUES ('restored', v_board.id, v_board.slug, v_column.id, v_task_id);
END;
$$;

COMMIT;

WITH membership AS (
  INSERT INTO public.board_memberships(board_id, user_id, role)
  SELECT fixture.board_id, '43600000-0000-4000-8000-000000000004', 'collaborator'
  FROM public.issue36_activity_fixture AS fixture
  WHERE fixture.purpose = 'restored'
  RETURNING id, board_id
)
UPDATE public.issue36_activity_fixture AS fixture
SET departing_membership_id = membership.id
FROM membership
WHERE fixture.purpose = 'restored'
  AND fixture.board_id = membership.board_id;

INSERT INTO public.task_activity_events(
  board_id, task_id, category, actor_type, actor_name,
  before_value, after_value
)
SELECT fixture.board_id, fixture.task_id, 'due_date', 'system', NULL,
  '"2026-12-25"'::jsonb, '"2026-12-26"'::jsonb
FROM public.issue36_activity_fixture AS fixture
WHERE fixture.purpose = 'restored';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43600000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'restored';
  v_result := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_fixture.task_id,
    '{"due_on":"2026-12-24"}'::jsonb,
    '{"due_on":2}'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The collaborator E05 change was not confirmed: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'restored';
  v_result := public.remove_board_collaborator_p(
    gen_random_uuid(), v_fixture.board_id, v_fixture.departing_membership_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The synthetic activity author could not be removed: %', v_result;
  END IF;
  v_page := public.get_task_activity_p(
    v_fixture.board_slug, v_fixture.task_id, 30, NULL, NULL
  );
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_page->'events') AS item(event)
      WHERE item.event->>'category' = 'due_date'
        AND item.event->>'actor_type' = 'user'
        AND item.event->>'actor_name' = 'Persona colaboradora'
        AND NOT (item.event ? 'actor_id')
    ) THEN
    RAISE EXCEPTION 'A removed actor must retain only its historical snapshot: %', v_page;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43600000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'restored';
  v_page := public.get_task_activity_p(
    v_fixture.board_slug, v_fixture.task_id, 30, NULL, NULL
  );
  IF v_page->>'status' IS DISTINCT FROM 'unavailable' OR v_page ? 'events' THEN
    RAISE EXCEPTION 'A removed activity author must not retain board access: %', v_page;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43600000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'restored';
  v_page := public.get_task_activity_p(v_fixture.board_slug, v_fixture.task_id, 30, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'unavailable' OR v_page ? 'events' THEN
    RAISE EXCEPTION 'A nonmember must not learn activity or its contents: %', v_page;
  END IF;
  IF has_table_privilege('authenticated', 'public.task_activity_events', 'SELECT')
    OR has_table_privilege('authenticated', 'public.task_activity_events', 'INSERT')
    OR has_function_privilege(
      'anon', 'public.get_task_activity_p(text,uuid,integer,timestamp with time zone,uuid)', 'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'Activity storage or reads are exposed outside the authorized RPC';
  END IF;
  BEGIN
    PERFORM 1 FROM public.task_activity_events;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Authenticated callers can read activity storage directly';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: E05 capture, cursor paging, ACL, hide/restore and timestamp retention'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_created jsonb;
  v_retention_task_id uuid;
  v_purge_task_id uuid;
  v_deleted jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'restored';
  v_created := public.create_task_p(
    gen_random_uuid(), v_fixture.board_id, v_fixture.column_id, 'Retención sintética'
  );
  v_retention_task_id := (v_created->>'task_id')::uuid;
  PERFORM public.set_task_completion_p(
    gen_random_uuid(), v_fixture.board_slug, v_retention_task_id, true, 1
  );
  INSERT INTO public.issue36_activity_fixture(
    purpose, board_id, board_slug, column_id, task_id
  ) VALUES (
    'retention', v_fixture.board_id, v_fixture.board_slug,
    v_fixture.column_id, v_retention_task_id
  );

  v_created := public.create_task_p(
    gen_random_uuid(), v_fixture.board_id, v_fixture.column_id, 'Purga dependiente'
  );
  v_purge_task_id := (v_created->>'task_id')::uuid;
  PERFORM public.set_task_completion_p(
    gen_random_uuid(), v_fixture.board_slug, v_purge_task_id, true, 1
  );
  v_deleted := public.delete_task_p(
    gen_random_uuid(), v_fixture.board_slug, v_purge_task_id, 'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The purge fixture task could not be soft-deleted: %', v_deleted;
  END IF;
  INSERT INTO public.issue36_activity_fixture(
    purpose, board_id, board_slug, column_id, task_id
  ) VALUES (
    'purge', v_fixture.board_id, v_fixture.board_slug,
    v_fixture.column_id, v_purge_task_id
  );
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_imported_at timestamptz := clock_timestamp() - interval '179 days';
  v_expired_at timestamptz := clock_timestamp() - interval '181 days';
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'retention';
  UPDATE public.task_activity_events AS event
  SET occurred_at = v_expired_at
  WHERE event.task_id = v_fixture.task_id AND event.actor_type = 'user';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The retention fixture did not create its user event';
  END IF;

  INSERT INTO public.task_activity_events(
    board_id, task_id, category, actor_type, actor_name, occurred_at,
    before_value, after_value
  ) VALUES (
    v_fixture.board_id, v_fixture.task_id, 'completion', 'imported',
    'Autor del respaldo', v_imported_at, 'false'::jsonb, 'true'::jsonb
  );
  UPDATE public.issue36_activity_fixture AS fixture
  SET imported_event_at = v_imported_at
  WHERE fixture.purpose = 'retention';

  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'purge';
  UPDATE public.task_deletions AS deletion
  SET deleted_at = deletion.deleted_at - interval '200 days',
      expires_at = deletion.deleted_at - interval '200 days' + interval '168 hours'
  WHERE deletion.task_id = v_fixture.task_id AND deletion.state = 'deleted';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The purge fixture task has no deleted recovery ledger';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_system_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'restored';
  v_system_page := public.get_task_activity_p(
    v_fixture.board_slug, v_fixture.task_id, 30, NULL, NULL
  );
  IF v_system_page->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_system_page->'events') AS item(event)
      WHERE item.event->>'category' = 'due_date'
        AND item.event->>'actor_type' = 'system'
        AND item.event->'actor_name' = 'null'::jsonb
        AND item.event->'before_value' = '"2026-12-25"'::jsonb
        AND item.event->'after_value' = '"2026-12-26"'::jsonb
    ) THEN
    RAISE EXCEPTION 'System activity must be attributed to Sistema: %',
      v_system_page;
  END IF;

  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'retention';
  v_page := public.get_task_activity_p(v_fixture.board_slug, v_fixture.task_id, 30, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page->'events') <> 1
    OR v_page->'events'->0->>'actor_type' IS DISTINCT FROM 'imported'
    OR v_page->'events'->0->>'actor_name' IS DISTINCT FROM 'Autor del respaldo'
    OR (v_page->'events'->0->>'occurred_at')::timestamptz
       IS DISTINCT FROM v_fixture.imported_event_at THEN
    RAISE EXCEPTION 'Expired activity must be hidden and imported attribution/age preserved: %', v_page;
  END IF;

  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'purge';
  v_page := public.get_task_activity_p(v_fixture.board_slug, v_fixture.task_id, 30, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'unavailable' OR v_page ? 'events' THEN
    RAISE EXCEPTION 'A soft-deleted task must hide but retain its activity until purge';
  END IF;
  IF has_function_privilege(
    'authenticated', 'public.purge_expired_task_activity_p(integer)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Authenticated members can invoke activity retention maintenance';
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_task_id uuid;
  v_event_count integer;
BEGIN
  SELECT task_id INTO STRICT v_task_id
  FROM public.issue36_activity_fixture WHERE purpose = 'purge';
  SELECT count(*) INTO v_event_count
  FROM public.task_activity_events WHERE task_id = v_task_id;
  IF v_event_count <> 1 THEN
    RAISE EXCEPTION 'A soft-deleted task should retain one event until permanent purge';
  END IF;
END;
$$;

SET ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', false);
DO $$
BEGIN
  IF public.purge_expired_task_activity_p(10) <> 1 THEN
    RAISE EXCEPTION 'Service retention must purge the single event older than 180 days';
  END IF;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_fixture record;
  v_status text;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue36_activity_fixture WHERE purpose = 'retention';
  IF EXISTS (
    SELECT 1 FROM public.task_activity_events AS event
    WHERE event.task_id = v_fixture.task_id AND event.actor_type = 'user'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.task_activity_events AS event
    WHERE event.task_id = v_fixture.task_id
      AND event.actor_type = 'imported'
      AND event.occurred_at = v_fixture.imported_event_at
  ) THEN
    RAISE EXCEPTION 'Physical activity pruning removed a current imported event or retained an expired one';
  END IF;

  SELECT public.purge_expired_task_internal_p(
    fixture.task_id, clock_timestamp()
  ) INTO v_status
  FROM public.issue36_activity_fixture AS fixture
  WHERE fixture.purpose = 'purge';
  IF v_status IS DISTINCT FROM 'purged'
    OR EXISTS (
      SELECT 1 FROM public.task_activity_events AS event
      JOIN public.issue36_activity_fixture AS fixture
        ON fixture.task_id = event.task_id
      WHERE fixture.purpose = 'purge'
    ) THEN
    RAISE EXCEPTION 'Permanent task purge must remove dependent activity; result %', v_status;
  END IF;
END;
$$;

\echo 'PASS: 180-day age is per event; import preserves age; task purge removes dependent events'
