\set ON_ERROR_STOP on
\echo 'Checking task-field receipts, replay, validation, independent actions, and access loss'

DO $$
DECLARE
  v_same_field_task_id uuid;
  v_other_task_id uuid;
  v_board_id uuid;
  v_versions jsonb;
  v_receipt_count integer;
  v_confirmed_count integer;
  v_conflict_count integer;
BEGIN
  SELECT board_id INTO v_board_id
  FROM public.issue8_task_field_fixture WHERE purpose = 'same-field';
  SELECT task_id INTO v_same_field_task_id
  FROM public.issue8_task_field_fixture WHERE purpose = 'same-field';
  SELECT task_id INTO v_other_task_id
  FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields';

  SELECT count(*), count(*) FILTER (WHERE receipt.result_status = 'confirmed'),
    count(*) FILTER (WHERE receipt.result_status = 'conflict')
  INTO v_receipt_count, v_confirmed_count, v_conflict_count
  FROM public.task_edit_receipts AS receipt
  WHERE receipt.operation_id IN (
    'e8888888-0000-4000-8000-000000000001',
    'e8888888-0000-4000-8000-000000000002'
  );
  IF v_receipt_count <> 2 OR v_confirmed_count <> 1 OR v_conflict_count <> 1 THEN
    RAISE EXCEPTION 'The same-field race did not record one confirmed edit and one conflict';
  END IF;

  SELECT task.field_versions INTO v_versions
  FROM public.tasks AS task WHERE task.id = v_same_field_task_id;
  IF v_versions->>'title' <> '2'
    OR v_versions->>'description' <> '1'
    OR v_versions->>'priority' <> '1' THEN
    RAISE EXCEPTION 'A same-field conflict changed more fields than the confirmed title';
  END IF;

  SELECT task.field_versions INTO v_versions
  FROM public.tasks AS task WHERE task.id = v_other_task_id;
  IF v_versions->>'title' <> '2'
    OR v_versions->>'description' <> '2'
    OR v_versions->>'priority' <> '1' THEN
    RAISE EXCEPTION 'Concurrent edits to separate fields did not retain independent revisions';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.tasks AS task
    WHERE task.id = v_other_task_id
      AND task.title = 'Título independiente'
      AND task.description = 'Descripción independiente'
  ) THEN
    RAISE EXCEPTION 'Different-field edits did not combine into one current task';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.edit_task_fields_p(uuid, text, uuid, jsonb, jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Anonymous callers can execute versioned task edits';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_replay jsonb;
  v_versions jsonb;
  v_denied boolean := false;
  v_task_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields';

  -- The original success response is intentionally ignored. Replaying its
  -- operation and canonical payload confirms the recorded result once.
  v_replay := public.edit_task_fields_p(
    'e8888888-0000-4000-8000-000000000003',
    v_fixture.board_slug,
    v_fixture.task_id,
    '{"title":"Título independiente"}'::jsonb,
    '{"title":1}'::jsonb
  );
  IF v_replay->>'status' <> 'confirmed'
    OR v_replay->'task'->>'title' <> 'Título independiente'
    OR v_replay->'task'->>'description' <> 'Descripción independiente' THEN
    RAISE EXCEPTION 'Retry after a lost edit response did not resolve to the committed task';
  END IF;

  BEGIN
    PERFORM public.edit_task_fields_p(
      'e8888888-0000-4000-8000-000000000003',
      v_fixture.board_slug,
      v_fixture.task_id,
      '{"title":"No debe reemplazar"}'::jsonb,
      '{"title":1}'::jsonb
    );
    RAISE EXCEPTION 'One operation id accepted a different edit payload';
  EXCEPTION WHEN check_violation THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A changed edit payload was not rejected';
  END IF;

  SELECT task.field_versions INTO v_versions
  FROM public.get_tasks_by_board_p(v_fixture.board_id) AS task
  WHERE task.id = v_fixture.task_id;
  IF v_versions->>'title' <> '2' OR v_versions->>'description' <> '2' THEN
    RAISE EXCEPTION 'A replay or rejected key collision changed field revisions';
  END IF;

  PERFORM public.update_task_positions_p(
    v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_fixture.task_id,
      'position', 0
    ))
  );
  SELECT task.field_versions INTO v_versions
  FROM public.get_tasks_by_board_p(v_fixture.board_id) AS task
  WHERE task.id = v_fixture.task_id;
  IF v_versions->>'title' <> '2' OR v_versions->>'description' <> '2' THEN
    RAISE EXCEPTION 'Moving a task invalidated its field versions';
  END IF;

  v_task_id := v_fixture.task_id;
  v_denied := false;
  BEGIN
    UPDATE public.tasks SET title = 'Escritura directa' WHERE id = v_task_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Authenticated users can bypass the versioned task edit command';
  END IF;
END;
$$;
COMMIT;

-- Expiry is controlled by changing only this disposable fixture's result row;
-- a retry after its seven-day window must not silently run the edit again.
UPDATE public.task_edit_receipts AS receipt
SET result_expires_at = clock_timestamp() - interval '1 second'
WHERE receipt.actor_id = '40000000-0000-4000-8000-000000000002'
  AND receipt.operation_id = 'e8888888-0000-4000-8000-000000000003';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_versions jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields';
  v_result := public.edit_task_fields_p(
    'e8888888-0000-4000-8000-000000000003',
    v_fixture.board_slug,
    v_fixture.task_id,
    '{"title":"Título independiente"}'::jsonb,
    '{"title":1}'::jsonb
  );
  IF v_result->>'status' <> 'expired_unknown' THEN
    RAISE EXCEPTION 'An expired edit receipt was replayed without reconciliation';
  END IF;
  SELECT task.field_versions INTO v_versions
  FROM public.get_tasks_by_board_p(v_fixture.board_id) AS task
  WHERE task.id = v_fixture.task_id;
  IF v_versions->>'title' <> '2' OR v_versions->>'description' <> '2' THEN
    RAISE EXCEPTION 'An expired edit operation was applied again';
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
    PERFORM public.edit_task_fields_p(
      'e8888888-0000-4000-8000-000000000005',
      v_fixture.board_slug,
      v_fixture.task_id,
      '{"title":"Admin ajeno"}'::jsonb,
      '{"title":2}'::jsonb
    );
    RAISE EXCEPTION 'Global administration granted task content access';
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A global admin without board membership was not denied';
  END IF;
END;
$$;
COMMIT;

UPDATE public.board_memberships AS membership
SET revoked_at = clock_timestamp()
FROM public.issue8_task_field_fixture AS fixture
WHERE fixture.purpose = 'same-field'
  AND membership.board_id = fixture.board_id
  AND membership.user_id = '40000000-0000-4000-8000-000000000005'
  AND membership.revoked_at IS NULL;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_fixture record;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue8_task_field_fixture WHERE purpose = 'same-field';
  BEGIN
    PERFORM public.edit_task_fields_p(
      'e8888888-0000-4000-8000-000000000006',
      v_fixture.board_slug,
      v_fixture.task_id,
      '{"title":"Texto de sesión revocada"}'::jsonb,
      '{"title":2}'::jsonb
    );
    RAISE EXCEPTION 'A revoked member edited a task';
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A revoked member was not denied without a task response';
  END IF;
END;
$$;
COMMIT;

DROP TABLE public.issue8_task_field_fixture;
\echo 'PASS: edit receipts reconcile retries; key collisions, moves, nonmembers, and revoked actors cannot bypass versions/permissions'
