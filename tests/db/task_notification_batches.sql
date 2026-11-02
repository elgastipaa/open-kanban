\set ON_ERROR_STOP on
\echo 'Issue #38 tracer: marking the 20 unread loaded notices never includes later arrivals'

CREATE TEMP TABLE issue38_loaded_notification_ids (
  notification_id uuid PRIMARY KEY
);
GRANT SELECT, INSERT ON issue38_loaded_notification_ids TO authenticated;

DO $$
DECLARE
  v_fixture record;
  v_membership_id uuid;
  v_page jsonb;
  v_unread_before integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  SELECT membership.id INTO STRICT v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = '43700000-0000-4000-8000-000000000003'
    AND membership.revoked_at IS NULL;

  INSERT INTO public.task_notifications(
    board_id, generation_id, task_id, source_kind, source_id,
    recipient_user_id, recipient_membership_id, reason_codes, actor_name,
    occurred_at, state, delivered_at
  )
  SELECT v_fixture.board_id, board.active_generation_id, v_fixture.task_id,
    'task_change', gen_random_uuid(), '43700000-0000-4000-8000-000000000003',
    v_membership_id, ARRAY['assignment']::text[], 'Persona autora',
    clock_timestamp() - (sequence.value * interval '1 second'),
    'delivered', clock_timestamp()
  FROM public.boards AS board
  CROSS JOIN generate_series(1, 80) AS sequence(value)
  WHERE board.id = v_fixture.board_id;

  SELECT count(*) INTO v_unread_before
  FROM public.task_notifications AS notice
  WHERE notice.board_id = v_fixture.board_id
    AND notice.recipient_membership_id = v_membership_id
    AND notice.read_at IS NULL;
  IF v_unread_before <> 80 THEN
    RAISE EXCEPTION 'Expected 80 synthetic unread notices, found %', v_unread_before;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_page jsonb;
  v_items jsonb;
BEGIN
  v_page := public.list_my_task_notifications_p('unread', 20, NULL, NULL);
  v_items := v_page->'items';
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_items) <> 20
    OR (v_page->>'unread_count')::integer <> 80 THEN
    RAISE EXCEPTION 'The synthetic 80-notice inbox should load exactly 20: %', v_page;
  END IF;
  INSERT INTO issue38_loaded_notification_ids(notification_id)
  SELECT (item->>'id')::uuid
  FROM jsonb_array_elements(v_items) AS item;
END;
$$;
COMMIT;
RESET ROLE;

-- Simulate a notification arriving after the click-time page snapshot.
INSERT INTO public.task_notifications(
  board_id, generation_id, task_id, source_kind, source_id,
  recipient_user_id, recipient_membership_id, reason_codes, actor_name,
  occurred_at, state, delivered_at
)
SELECT fixture.board_id, board.active_generation_id, fixture.task_id,
  'task_change', gen_random_uuid(), '43700000-0000-4000-8000-000000000003',
  membership.id, ARRAY['assignment']::text[], 'Persona autora',
  clock_timestamp(), 'delivered', clock_timestamp()
FROM issue37_notification_fixture AS fixture
JOIN public.boards AS board ON board.id = fixture.board_id
JOIN public.board_memberships AS membership
  ON membership.board_id = board.id
  AND membership.user_id = '43700000-0000-4000-8000-000000000003'
  AND membership.revoked_at IS NULL
WHERE fixture.purpose = 'assignment';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_operation_id uuid := '63800000-0000-4000-8000-000000000001';
  v_ids uuid[];
  v_result jsonb;
  v_replay jsonb;
  v_unread_page jsonb;
  v_marked_count integer;
  v_unread_items jsonb;
BEGIN
  SELECT array_agg(snapshot.notification_id ORDER BY snapshot.notification_id)
    INTO STRICT v_ids
  FROM issue38_loaded_notification_ids AS snapshot;
  v_result := public.mark_my_task_notifications_batch_p(
    v_operation_id, v_ids, false
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_result->'items') <> 20 THEN
    RAISE EXCEPTION 'Batch marking did not return all frozen IDs: %', v_result;
  END IF;
  SELECT count(*) INTO v_marked_count
  FROM jsonb_array_elements(v_result->'items') AS item
  WHERE item->>'result' = 'marked';
  IF v_marked_count <> 20
    OR v_result ? 'task_title' THEN
    RAISE EXCEPTION 'Expected 20 private, marked outcomes without task titles: %', v_result;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'items') AS item
    WHERE item ? 'task_title' OR item ? 'actor_name'
  ) THEN
    RAISE EXCEPTION 'Batch outcomes must not contain notification content: %', v_result;
  END IF;

  v_replay := public.mark_my_task_notifications_batch_p(v_operation_id, v_ids, false);
  IF v_replay IS DISTINCT FROM v_result THEN
    RAISE EXCEPTION 'A replay must return the same batch receipt: %, %', v_result, v_replay;
  END IF;
  v_replay := public.get_my_task_notification_batch_p(v_operation_id);
  IF v_replay IS DISTINCT FROM v_result THEN
    RAISE EXCEPTION 'Receipt lookup must reconcile a lost response: %, %', v_result, v_replay;
  END IF;

  v_unread_page := public.list_my_task_notifications_p('unread', 100, NULL, NULL);
  v_unread_items := v_unread_page->'items';
  IF (v_unread_page->>'unread_count')::integer <> 61
    OR jsonb_array_length(v_unread_items) <> 61
    OR EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_unread_items) AS item
      WHERE (item->>'id')::uuid = ANY(v_ids)
    ) THEN
    RAISE EXCEPTION 'The batch changed IDs outside its click-time set: %', v_unread_page;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

\echo 'PASS: the 20-ID click-time snapshot is private, replayable, and excludes later arrivals'

\echo 'Issue #38 tracer: a failed-only retry cannot start a missing operation'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_page jsonb;
  v_id uuid;
  v_result jsonb;
  v_receipt jsonb;
  v_after jsonb;
BEGIN
  v_page := public.list_my_task_notifications_p('unread', 100, NULL, NULL);
  v_id := (v_page->'items'->0->>'id')::uuid;
  IF v_id IS NULL OR (v_page->>'unread_count')::integer <> 61 THEN
    RAISE EXCEPTION 'Expected the unprocessed click-time notices before testing retry: %', v_page;
  END IF;

  v_result := public.mark_my_task_notifications_batch_p(
    '63800000-0000-4000-8000-000000000003', ARRAY[v_id], true
  );
  v_receipt := public.get_my_task_notification_batch_p(
    '63800000-0000-4000-8000-000000000003'
  );
  v_after := public.list_my_task_notifications_p('unread', 100, NULL, NULL);
  IF v_result->>'status' IS DISTINCT FROM 'not_found'
    OR v_result ? 'items'
    OR v_receipt->>'status' IS DISTINCT FROM 'not_found'
    OR (v_after->>'unread_count')::integer <> 61
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_after->'items') AS item
      WHERE item->>'id' = v_id::text
    ) THEN
    RAISE EXCEPTION 'A retry without its original receipt must not mark any ID: %, %, %',
      v_result, v_receipt, v_after;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;
\echo 'PASS: a missing receipt makes failed-only retry inert and requires a fresh read'

\echo 'Issue #38 tracer: mixed outcomes, authorization recheck, and failed-only retry'
CREATE TEMP TABLE issue38_partial_notification_ids (
  notification_id uuid PRIMARY KEY
);
GRANT SELECT, INSERT ON issue38_partial_notification_ids TO authenticated;

WITH inserted AS (
  INSERT INTO public.task_notifications(
    board_id, generation_id, task_id, source_kind, source_id,
    recipient_user_id, recipient_membership_id, reason_codes, actor_name,
    occurred_at, state, delivered_at
  )
  SELECT fixture.board_id, board.active_generation_id, fixture.task_id,
    'task_change', gen_random_uuid(), '43700000-0000-4000-8000-000000000003',
    membership.id, ARRAY['assignment']::text[], 'Persona autora',
    clock_timestamp(), 'delivered', clock_timestamp()
  FROM issue37_notification_fixture AS fixture
  JOIN public.boards AS board ON board.id = fixture.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = '43700000-0000-4000-8000-000000000003'
    AND membership.revoked_at IS NULL
  CROSS JOIN generate_series(1, 4)
  WHERE fixture.purpose = 'assignment'
  RETURNING id
)
INSERT INTO issue38_partial_notification_ids(notification_id)
SELECT inserted.id FROM inserted;

CREATE FUNCTION public.issue38_fail_notification_read_tg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.read_at IS DISTINCT FROM OLD.read_at
    AND NEW.id::text IN (
      current_setting('test.issue38.fail_first', true),
      current_setting('test.issue38.fail_second', true)
    ) THEN
    RAISE EXCEPTION 'Synthetic row failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER issue38_fail_notification_read
BEFORE UPDATE OF read_at ON public.task_notifications
FOR EACH ROW EXECUTE FUNCTION public.issue38_fail_notification_read_tg();

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_operation_id uuid := '63800000-0000-4000-8000-000000000002';
  v_ids uuid[];
  v_fail_first uuid;
  v_fail_second uuid;
  v_already_read uuid;
  v_unknown uuid := '63800000-0000-4000-8000-000000000099';
  v_result jsonb;
  v_marked integer;
  v_already integer;
  v_unavailable integer;
  v_failed integer;
BEGIN
  SELECT array_agg(notification_id ORDER BY notification_id)
  INTO STRICT v_ids FROM issue38_partial_notification_ids;
  v_fail_first := v_ids[1];
  v_fail_second := v_ids[2];
  SELECT notification_id INTO STRICT v_already_read
  FROM issue38_loaded_notification_ids ORDER BY notification_id LIMIT 1;
  v_ids := v_ids || ARRAY[v_already_read, v_unknown];
  PERFORM set_config('test.issue38.fail_first', v_fail_first::text, true);
  PERFORM set_config('test.issue38.fail_second', v_fail_second::text, true);

  v_result := public.mark_my_task_notifications_batch_p(
    v_operation_id, v_ids, false
  );
  SELECT count(*) FILTER (WHERE item->>'result' = 'marked'),
    count(*) FILTER (WHERE item->>'result' = 'already_read'),
    count(*) FILTER (WHERE item->>'result' = 'unavailable'),
    count(*) FILTER (WHERE item->>'result' = 'failed')
  INTO v_marked, v_already, v_unavailable, v_failed
  FROM jsonb_array_elements(v_result->'items') AS item;
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_result->'items') <> 6
    OR v_marked <> 2 OR v_already <> 1 OR v_unavailable <> 1 OR v_failed <> 2 THEN
    RAISE EXCEPTION 'Mixed outcomes should retain success and isolate row failures: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

-- One failed ID remains authorized and should be retried. The other loses its
-- recipient membership episode before retry and must become unavailable.
UPDATE public.task_notifications AS notice
SET recipient_membership_id = owner_membership.id
FROM issue37_notification_fixture AS fixture
JOIN public.board_memberships AS owner_membership
  ON owner_membership.board_id = fixture.board_id
  AND owner_membership.user_id = '43700000-0000-4000-8000-000000000002'
  AND owner_membership.revoked_at IS NULL
WHERE fixture.purpose = 'assignment'
  AND notice.id = (SELECT ids.notification_id FROM issue38_partial_notification_ids AS ids
    ORDER BY ids.notification_id OFFSET 1 LIMIT 1);
DROP TRIGGER issue38_fail_notification_read ON public.task_notifications;
DROP FUNCTION public.issue38_fail_notification_read_tg();

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_operation_id uuid := '63800000-0000-4000-8000-000000000002';
  v_ids uuid[];
  v_retried jsonb;
  v_replay jsonb;
  v_marked integer;
  v_already integer;
  v_unavailable integer;
  v_failed integer;
  v_changed_payload_rejected boolean := false;
BEGIN
  SELECT array_agg(notification_id ORDER BY notification_id)
  INTO STRICT v_ids FROM issue38_partial_notification_ids;
  v_ids := v_ids || ARRAY[
    (SELECT notification_id FROM issue38_loaded_notification_ids
      ORDER BY notification_id LIMIT 1),
    '63800000-0000-4000-8000-000000000099'::uuid
  ];
  v_retried := public.mark_my_task_notifications_batch_p(
    v_operation_id, v_ids, true
  );
  SELECT count(*) FILTER (WHERE item->>'result' = 'marked'),
    count(*) FILTER (WHERE item->>'result' = 'already_read'),
    count(*) FILTER (WHERE item->>'result' = 'unavailable'),
    count(*) FILTER (WHERE item->>'result' = 'failed')
  INTO v_marked, v_already, v_unavailable, v_failed
  FROM jsonb_array_elements(v_retried->'items') AS item;
  IF v_retried->>'status' IS DISTINCT FROM 'confirmed'
    OR v_marked <> 3 OR v_already <> 1 OR v_unavailable <> 2 OR v_failed <> 0 THEN
    RAISE EXCEPTION 'Retry must update only the failed ID still authorized: %', v_retried;
  END IF;
  v_replay := public.mark_my_task_notifications_batch_p(
    v_operation_id, v_ids, true
  );
  IF v_replay IS DISTINCT FROM v_retried THEN
    RAISE EXCEPTION 'Successful and unavailable outcomes must persist on replay: %, %',
      v_retried, v_replay;
  END IF;

  BEGIN
    PERFORM public.mark_my_task_notifications_batch_p(
      v_operation_id,
      v_ids || ARRAY['63800000-0000-4000-8000-000000000098'::uuid],
      true
    );
  EXCEPTION WHEN check_violation THEN
    v_changed_payload_rejected := true;
  END;
  IF NOT v_changed_payload_rejected THEN
    RAISE EXCEPTION 'An operation ID cannot be reused for a different frozen set';
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

UPDATE public.task_notification_batch_receipts AS receipt
SET result_expires_at = clock_timestamp() - interval '1 second'
WHERE receipt.actor_id = '43700000-0000-4000-8000-000000000003'
  AND receipt.operation_id = '63800000-0000-4000-8000-000000000002';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_ids uuid[];
  v_read uuid;
  v_unknown uuid := '63800000-0000-4000-8000-000000000099';
  v_get jsonb;
  v_retry jsonb;
BEGIN
  SELECT array_agg(notification_id ORDER BY notification_id)
  INTO STRICT v_ids FROM issue38_partial_notification_ids;
  SELECT notification_id INTO STRICT v_read
  FROM issue38_loaded_notification_ids ORDER BY notification_id LIMIT 1;
  v_ids := v_ids || ARRAY[v_read, v_unknown];
  v_get := public.get_my_task_notification_batch_p(
    '63800000-0000-4000-8000-000000000002'
  );
  v_retry := public.mark_my_task_notifications_batch_p(
    '63800000-0000-4000-8000-000000000002', v_ids, true
  );
  IF v_get->>'status' IS DISTINCT FROM 'expired_unknown'
    OR v_retry->>'status' IS DISTINCT FROM 'expired_unknown'
    OR v_get ? 'items' OR v_retry ? 'items' THEN
    RAISE EXCEPTION 'Expired receipt must stay uncertain and must not replay IDs: %, %',
      v_get, v_retry;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.get_my_task_notification_batch_p(
    '63800000-0000-4000-8000-000000000002'
  );
  IF v_result->>'status' IS DISTINCT FROM 'not_found' OR v_result ? 'items' THEN
    RAISE EXCEPTION 'A different board user must not inspect a batch receipt: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

DO $$
BEGIN
  IF has_table_privilege(
    'authenticated', 'public.task_notification_batch_receipts', 'SELECT'
  ) OR has_table_privilege(
    'authenticated', 'public.task_notification_batch_receipts', 'INSERT'
  ) THEN
    RAISE EXCEPTION 'Authenticated users must not read or write receipt rows directly';
  END IF;
END;
$$;

\echo 'PASS: per-ID outcomes persist, authorized failures alone retry, and expiry stays uncertain'
