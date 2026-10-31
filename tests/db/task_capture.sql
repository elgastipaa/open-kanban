\set ON_ERROR_STOP on
\echo 'Testing durable task-capture replay after a discarded response'

CREATE TEMP TABLE issue7_capture_fixture (
  board_id uuid NOT NULL,
  column_id uuid NOT NULL
);
GRANT SELECT, INSERT ON issue7_capture_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  created_board record;
  created_column_id uuid;
BEGIN
  SELECT * INTO created_board
  FROM public.create_board_p(
    'Issue 7 capture fixture',
    'UTC',
    'f7777777-0000-4000-8000-000000000001'
  );
  SELECT id INTO created_column_id
  FROM public.create_column_p(
    created_board.slug,
    created_board.id,
    'Captura',
    0
  );
  INSERT INTO pg_temp.issue7_capture_fixture(board_id, column_id)
  VALUES (created_board.id, created_column_id);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_column_id uuid;
  v_operation_id constant uuid := 'a7777777-0000-4000-8000-000000000001';
  v_result jsonb;
  v_replay jsonb;
  v_second_intent jsonb;
  v_task_id uuid;
  v_other_board record;
  v_other_board_id uuid;
  v_other_column_id uuid;
  v_rejected boolean := false;
  v_task_count integer;
BEGIN
  SELECT board_id, column_id INTO v_board_id, v_column_id
  FROM pg_temp.issue7_capture_fixture;

  -- Deliberately discard the first returned result, like a response lost after
  -- the server committed. Reconciliation must resolve the same task by intent.
  PERFORM public.create_task_p(
    p_operation_id => v_operation_id,
    p_board_id => v_board_id,
    p_column_id => v_column_id,
    p_title => 'Comprar leche'
  );

  v_result := public.get_task_creation_result_p(v_operation_id);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'board_id')::uuid IS DISTINCT FROM v_board_id
    OR (v_result->>'column_id')::uuid IS DISTINCT FROM v_column_id THEN
    RAISE EXCEPTION 'The committed capture could not be reconciled: %', v_result;
  END IF;
  v_task_id := (v_result->'task'->>'id')::uuid;
  IF v_task_id IS NULL
    OR v_result->'task'->>'created_by' IS DISTINCT FROM auth.uid()::text
    OR v_result->'task'->'description' IS DISTINCT FROM 'null'::jsonb
    OR v_result->'task'->>'priority' IS DISTINCT FROM 'medium' THEN
    RAISE EXCEPTION 'The server did not derive the capture author/defaults: %', v_result;
  END IF;

  v_replay := public.create_task_p(
    p_operation_id => v_operation_id,
    p_board_id => v_board_id,
    p_column_id => v_column_id,
    p_title => 'Comprar leche'
  );
  IF v_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_replay->'task'->>'id')::uuid IS DISTINCT FROM v_task_id THEN
    RAISE EXCEPTION 'An identical replay did not return the committed task: %', v_replay;
  END IF;

  SELECT count(*) INTO v_task_count
  FROM public.tasks WHERE column_id = v_column_id AND title = 'Comprar leche';
  IF v_task_count <> 1 THEN
    RAISE EXCEPTION 'One capture intent created % tasks instead of one', v_task_count;
  END IF;

  BEGIN
    PERFORM public.create_task_p(
      p_operation_id => v_operation_id,
      p_board_id => v_board_id,
      p_column_id => v_column_id,
      p_title => 'Título alterado'
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An operation id accepted a different task payload';
  END IF;
  SELECT count(*) INTO v_task_count
  FROM public.tasks WHERE column_id = v_column_id;
  IF v_task_count <> 1 THEN
    RAISE EXCEPTION 'A conflicting operation changed task state';
  END IF;

  -- Equal titles are not an identity key. A new operation is a new intent.
  v_second_intent := public.create_task_p(
    'a7777777-0000-4000-8000-000000000002',
    v_board_id,
    v_column_id,
    'Comprar leche'
  );
  IF (v_second_intent->'task'->>'id')::uuid = v_task_id
    OR (v_second_intent->'task'->>'position')::integer <> 1 THEN
    RAISE EXCEPTION 'A separate same-title capture was deduplicated or not appended: %', v_second_intent;
  END IF;
  SELECT count(*) INTO v_task_count
  FROM public.tasks WHERE column_id = v_column_id AND title = 'Comprar leche';
  IF v_task_count <> 2 THEN
    RAISE EXCEPTION 'Tasks were incorrectly paired or deduplicated by title';
  END IF;

  SELECT * INTO STRICT v_other_board
  FROM public.create_board_p(
    'Issue 7 second board',
    'UTC',
    'f7777777-0000-4000-8000-000000000002'
  );
  v_other_board_id := v_other_board.id;
  SELECT id INTO v_other_column_id
  FROM public.create_column_p(
    v_other_board.slug,
    v_other_board_id,
    'Otra captura',
    0
  );

  v_rejected := false;
  BEGIN
    PERFORM public.create_task_p(
      'a7777777-0000-4000-8000-000000000003',
      v_board_id,
      v_other_column_id,
      'Cruce de tablero'
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A column from another board was accepted';
  END IF;
  IF public.get_task_creation_result_p(
      'a7777777-0000-4000-8000-000000000003'
    )->>'status' IS DISTINCT FROM 'not_found' OR EXISTS (
    SELECT 1 FROM public.tasks WHERE column_id = v_other_column_id
  ) THEN
    RAISE EXCEPTION 'A cross-board request left a partial receipt or task';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.create_task_p(
      'a7777777-0000-4000-8000-000000000004',
      v_board_id,
      v_column_id,
      '   '
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected OR public.get_task_creation_result_p(
      'a7777777-0000-4000-8000-000000000004'
    )->>'status' IS DISTINCT FROM 'not_found' THEN
    RAISE EXCEPTION 'An empty task title was accepted or left a receipt';
  END IF;

  IF NOT has_function_privilege(
      'authenticated',
      'public.create_task_p(uuid, uuid, uuid, text, text, text)',
      'EXECUTE'
    )
    OR has_table_privilege('authenticated', 'public.tasks', 'INSERT')
    OR EXISTS (
      SELECT 1 FROM pg_catalog.pg_proc AS procedure
      JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
      WHERE namespace.nspname = 'public'
        AND procedure.proname = 'create_task_p'
        AND pg_catalog.pg_get_function_identity_arguments(procedure.oid)
          = 'text, uuid, text, text, text, integer'
    ) THEN
    RAISE EXCEPTION 'Task creation still exposes a client-controlled legacy/protected-field path';
  END IF;

  v_rejected := false;
  BEGIN
    INSERT INTO public.tasks(column_id, title, position, created_by)
    VALUES (v_column_id, 'Direct protected-field write', 100, auth.uid());
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  SELECT count(*) INTO v_task_count
  FROM public.tasks WHERE column_id = v_column_id;
  IF NOT v_rejected OR v_task_count <> 2 THEN
    RAISE EXCEPTION 'A direct protected-field write was accepted or had partial effects';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: capture replay, explicit intent, payload conflict, append, and board validation'

-- A revoked collaborator cannot resolve a prior receipt or use a changed hash
-- to learn whether the operation key exists.
RESET ROLE;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.get_task_creation_result_p('a7777777-0000-4000-8000-000000000001');
  IF v_result->>'status' IS DISTINCT FROM 'not_found' OR v_result ? 'task' THEN
    RAISE EXCEPTION 'Another actor resolved a task capture receipt: %', v_result;
  END IF;
END;
$$;
COMMIT;
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, '40000000-0000-4000-8000-000000000001', 'collaborator'
FROM pg_temp.issue7_capture_fixture;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board_id uuid;
  v_column_id uuid;
  v_result jsonb;
BEGIN
  SELECT board_id, column_id INTO v_board_id, v_column_id
  FROM pg_temp.issue7_capture_fixture;
  PERFORM public.create_task_p(
    'a7777777-0000-4000-8000-000000000005',
    v_board_id,
    v_column_id,
    'Revoked collaborator task'
  );
END;
$$;
COMMIT;
RESET ROLE;
UPDATE public.board_memberships
SET revoked_at = clock_timestamp()
WHERE board_id = (SELECT board_id FROM pg_temp.issue7_capture_fixture)
  AND user_id = '40000000-0000-4000-8000-000000000001'
  AND revoked_at IS NULL;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_result jsonb;
  v_board_id uuid;
  v_column_id uuid;
BEGIN
  v_result := public.get_task_creation_result_p('a7777777-0000-4000-8000-000000000005');
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR v_result ? 'task' THEN
    RAISE EXCEPTION 'A revoked member resolved a receipt: %', v_result;
  END IF;

  SELECT board_id, column_id INTO v_board_id, v_column_id
  FROM pg_temp.issue7_capture_fixture;
  v_result := public.create_task_p(
    'a7777777-0000-4000-8000-000000000005',
    v_board_id,
    v_column_id,
    'Changed after revocation'
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR v_result ? 'task' THEN
    RAISE EXCEPTION 'A revoked member learned the operation hash state: %', v_result;
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: revoked members cannot resolve task capture receipts'

-- Expired receipts are an unknown outcome. They require reconciliation, and a
-- repeated request must not silently produce another task.
RESET ROLE;
UPDATE public.task_capture_receipts
SET result_expires_at = clock_timestamp() - interval '1 second'
WHERE actor_id = '40000000-0000-4000-8000-000000000002'
  AND operation_id = 'a7777777-0000-4000-8000-000000000001';
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_result jsonb;
  v_task_count integer;
  v_board_id uuid;
  v_column_id uuid;
  v_rejected boolean := false;
BEGIN
  v_result := public.get_task_creation_result_p('a7777777-0000-4000-8000-000000000001');
  IF v_result->>'status' IS DISTINCT FROM 'expired_unknown'
    OR v_result->>'task_id' IS NULL THEN
    RAISE EXCEPTION 'An expired result was not reported as unknown: %', v_result;
  END IF;

  v_board_id := (v_result->>'board_id')::uuid;
  v_column_id := (v_result->>'column_id')::uuid;
  v_result := public.create_task_p(
    'a7777777-0000-4000-8000-000000000001',
    v_board_id,
    v_column_id,
    'Comprar leche'
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired_unknown' THEN
    RAISE EXCEPTION 'Expired replay retried without reconciliation: %', v_result;
  END IF;

  BEGIN
    PERFORM public.create_task_p(
      'a7777777-0000-4000-8000-000000000001',
      v_board_id,
      v_column_id,
      'Título cambiado'
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An expired operation id accepted different payload details';
  END IF;

  SELECT count(*) INTO v_task_count
  FROM public.tasks WHERE column_id = v_column_id AND title = 'Comprar leche';
  IF v_task_count <> 2 THEN
    RAISE EXCEPTION 'Expired replay changed the number of tasks';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: expired results require reconciliation and never create on blind replay'
