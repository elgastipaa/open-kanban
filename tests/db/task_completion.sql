\set ON_ERROR_STOP on
\echo 'Verifying desired-state task completion with two synthetic actors'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_before public.tasks%ROWTYPE;
  v_completed jsonb;
  v_replay jsonb;
  v_same_state jsonb;
  v_old_replay_after_reopen jsonb;
  v_reopened jsonb;
  v_conflict jsonb;
  v_replayed_conflict jsonb;
  v_denied boolean := false;
  v_hash_collision boolean := false;
  v_completed_at timestamptz;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue8_task_field_fixture WHERE purpose = 'same-field';

  SELECT * INTO STRICT v_before FROM public.tasks WHERE id = v_fixture.task_id;
  IF v_before.is_completed IS DISTINCT FROM false
    OR v_before.completed_at IS NOT NULL
    OR v_before.completion_version IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'A newly created task did not start pending at completion version 1';
  END IF;

  v_completed := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    true,
    1
  );
  IF v_completed->>'status' IS DISTINCT FROM 'confirmed'
    OR v_completed->'task'->>'is_completed' IS DISTINCT FROM 'true'
    OR v_completed->'task'->>'completion_version' IS DISTINCT FROM '2'
    OR v_completed->'task'->>'completed_at' IS NULL
    OR (v_completed->'task'->>'column_id')::uuid IS DISTINCT FROM v_before.column_id
    OR (v_completed->'task'->>'position')::integer IS DISTINCT FROM v_before.position
    OR v_completed->'task'->>'title' IS DISTINCT FROM v_before.title
    OR v_completed->'task'->>'description' IS DISTINCT FROM v_before.description
    OR v_completed->'task'->>'priority' IS DISTINCT FROM v_before.priority
    OR v_completed->'task'->'field_versions' IS DISTINCT FROM to_jsonb(v_before.field_versions) THEN
    RAISE EXCEPTION 'Completing changed more than the desired completion state: %', v_completed;
  END IF;
  v_completed_at := (v_completed->'task'->>'completed_at')::timestamptz;

  -- The same operation may be sent twice after a lost response. It replays the
  -- receipt without advancing the completion version or completion time.
  v_replay := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    true,
    1
  );
  IF v_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replay->'task'->>'completion_version' IS DISTINCT FROM '2'
    OR (v_replay->'task'->>'completed_at')::timestamptz IS DISTINCT FROM v_completed_at THEN
    RAISE EXCEPTION 'Replaying a completion operation applied it twice: %', v_replay;
  END IF;

  -- A second client with an older snapshot can ask for the same completed
  -- state. It is a no-op confirmation, not a toggle or a version conflict.
  v_same_state := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    true,
    1
  );
  IF v_same_state->>'status' IS DISTINCT FROM 'confirmed'
    OR v_same_state->'task'->>'completion_version' IS DISTINCT FROM '2'
    OR (v_same_state->'task'->>'completed_at')::timestamptz IS DISTINCT FROM v_completed_at THEN
    RAISE EXCEPTION 'A duplicate desired state changed the task: %', v_same_state;
  END IF;

  v_reopened := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000003',
    v_fixture.board_slug,
    v_fixture.task_id,
    false,
    2
  );
  IF v_reopened->>'status' IS DISTINCT FROM 'confirmed'
    OR v_reopened->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_reopened->'task'->>'completed_at' IS NOT NULL
    OR v_reopened->'task'->>'completion_version' IS DISTINCT FROM '3'
    OR (v_reopened->'task'->>'column_id')::uuid IS DISTINCT FROM v_before.column_id
    OR (v_reopened->'task'->>'position')::integer IS DISTINCT FROM v_before.position THEN
    RAISE EXCEPTION 'Reopening did not clear only completion state: %', v_reopened;
  END IF;

  v_old_replay_after_reopen := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    true,
    1
  );
  IF v_old_replay_after_reopen->>'status' IS DISTINCT FROM 'conflict'
    OR v_old_replay_after_reopen->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_old_replay_after_reopen->'task'->>'completion_version' IS DISTINCT FROM '3' THEN
    RAISE EXCEPTION 'An old completed operation replay hid a later explicit reopen: %', v_old_replay_after_reopen;
  END IF;

  v_completed := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000004',
    v_fixture.board_slug,
    v_fixture.task_id,
    true,
    3
  );
  IF v_completed->>'status' IS DISTINCT FROM 'confirmed'
    OR v_completed->'task'->>'completion_version' IS DISTINCT FROM '4' THEN
    RAISE EXCEPTION 'The task could not be completed after an explicit reopen';
  END IF;

  -- A stale opposite action is a reviewable conflict; it cannot revert the
  -- latest completion or steal the task's column/order.
  v_conflict := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000005',
    v_fixture.board_slug,
    v_fixture.task_id,
    false,
    3
  );
  IF v_conflict->>'status' IS DISTINCT FROM 'conflict'
    OR v_conflict->'task'->>'is_completed' IS DISTINCT FROM 'true'
    OR v_conflict->'task'->>'completion_version' IS DISTINCT FROM '4'
    OR (v_conflict->'task'->>'column_id')::uuid IS DISTINCT FROM v_before.column_id
    OR (v_conflict->'task'->>'position')::integer IS DISTINCT FROM v_before.position THEN
    RAISE EXCEPTION 'A stale opposite completion action was not returned as a conflict: %', v_conflict;
  END IF;
  v_replayed_conflict := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000005',
    v_fixture.board_slug,
    v_fixture.task_id,
    false,
    3
  );
  IF v_replayed_conflict->>'status' IS DISTINCT FROM 'conflict'
    OR v_replayed_conflict->'task'->>'is_completed' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Replaying a stale completion conflict changed the task';
  END IF;

  BEGIN
    PERFORM public.set_task_completion_p(
      'a8888888-0000-4000-8000-000000000001',
      v_fixture.board_slug,
      v_fixture.task_id,
      false,
      2
    );
    RAISE EXCEPTION 'One operation ID accepted a different completion command';
  EXCEPTION WHEN check_violation THEN
    v_hash_collision := true;
  END;
  IF NOT v_hash_collision THEN
    RAISE EXCEPTION 'A changed completion payload was not rejected';
  END IF;

  BEGIN
    UPDATE public.tasks SET is_completed = false WHERE id = v_fixture.task_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Authenticated callers can bypass the completion command';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields';
  BEGIN
    PERFORM public.set_task_completion_p(
      'a8888888-0000-4000-8000-000000000006',
      v_fixture.board_slug,
      v_fixture.task_id,
      true,
      1
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Global admin without board membership completed a private task';
  END IF;
END;
$$;
COMMIT;

DO $$
BEGIN
  IF has_function_privilege(
    'anon',
    'public.set_task_completion_p(uuid, text, uuid, boolean, bigint)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Anonymous callers can execute task completion';
  END IF;
  IF has_table_privilege('authenticated', 'public.task_completion_receipts', 'SELECT')
    OR has_table_privilege('authenticated', 'public.task_completion_receipts', 'INSERT') THEN
    RAISE EXCEPTION 'Authenticated callers can read or write operation receipts directly';
  END IF;
END;
$$;

\echo 'PASS: completion is desired-state, versioned, retry-safe, column-preserving, and member-authorized'
