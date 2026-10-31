\set ON_ERROR_STOP on
\echo 'Checking versioned, anchored task ordering and atomic retries'

CREATE TABLE public.issue9_order_fixture (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  source_column_id uuid NOT NULL,
  target_column_id uuid NOT NULL,
  second_source_column_id uuid NOT NULL,
  second_target_column_id uuid NOT NULL,
  external_column_id uuid NOT NULL,
  task_a uuid NOT NULL,
  task_b uuid NOT NULL,
  task_c uuid NOT NULL,
  task_d uuid NOT NULL,
  target_before_id uuid NOT NULL,
  target_after_id uuid NOT NULL,
  external_board_slug text NOT NULL,
  batch_expected_order_versions jsonb NOT NULL DEFAULT '{}'::jsonb
);
GRANT SELECT, INSERT, UPDATE ON public.issue9_order_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_external_board record;
  v_source uuid;
  v_target uuid;
  v_second_source uuid;
  v_second_target uuid;
  v_external_column uuid;
  v_task_a uuid;
  v_task_b uuid;
  v_task_c uuid;
  v_task_d uuid;
  v_before uuid;
  v_after uuid;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 9 anchored ordering',
    'UTC',
    'f9999999-0000-4000-8000-000000000001'
  );
  SELECT id INTO v_source
  FROM public.create_column_p(v_board.slug, v_board.id, 'Origen', 0);
  SELECT id INTO v_target
  FROM public.create_column_p(v_board.slug, v_board.id, 'Destino A', 1);
  SELECT id INTO v_second_source
  FROM public.create_column_p(v_board.slug, v_board.id, 'Origen B', 2);
  SELECT id INTO v_second_target
  FROM public.create_column_p(v_board.slug, v_board.id, 'Destino B', 3);

  v_task_a := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000002', v_board.id, v_source, 'Tarea A', 'Descripción A', 'high'
  )->'task'->>'id')::uuid;
  v_task_b := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000003', v_board.id, v_source, 'Tarea B', 'Descripción B', 'urgent'
  )->'task'->>'id')::uuid;
  v_task_c := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000004', v_board.id, v_source, 'Tarea C', 'Descripción C', 'low'
  )->'task'->>'id')::uuid;
  v_task_d := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000005', v_board.id, v_second_source, 'Tarea D'
  )->'task'->>'id')::uuid;
  v_before := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000006', v_board.id, v_target, 'Antes'
  )->'task'->>'id')::uuid;
  v_after := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000007', v_board.id, v_target, 'Después'
  )->'task'->>'id')::uuid;

  SELECT * INTO STRICT v_external_board
  FROM public.create_board_p(
    'Issue 9 external board',
    'UTC',
    'f9999999-0000-4000-8000-000000000008'
  );
  SELECT id INTO v_external_column
  FROM public.create_column_p(v_external_board.slug, v_external_board.id, 'Otra', 0);

  INSERT INTO public.issue9_order_fixture VALUES (
    'main', v_board.id, v_board.slug, v_source, v_target,
    v_second_source, v_second_target, v_external_column,
    v_task_a, v_task_b, v_task_c, v_task_d,
    v_before, v_after, v_external_board.slug
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '40000000-0000-4000-8000-000000000005', 'collaborator'
FROM public.issue9_order_fixture AS fixture;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_source_version bigint;
  v_target_version bigint;
  v_second_source_version bigint;
  v_second_target_version bigint;
  v_result jsonb;
  v_replay jsonb;
  v_before_task jsonb;
  v_after_task jsonb;
  v_version_after_move bigint;
  v_version_before_replay bigint;
  v_replay_task_id uuid;
  v_source_version_after_move bigint;
  v_source_order text[];
  v_target_order text[];
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture FROM public.issue9_order_fixture WHERE purpose = 'main';
  SELECT task_order_version INTO STRICT v_source_version
  FROM public.columns WHERE id = v_fixture.source_column_id;
  SELECT task_order_version INTO STRICT v_target_version
  FROM public.columns WHERE id = v_fixture.target_column_id;
  SELECT task_order_version INTO STRICT v_second_source_version
  FROM public.columns WHERE id = v_fixture.second_source_column_id;
  SELECT task_order_version INTO STRICT v_second_target_version
  FROM public.columns WHERE id = v_fixture.second_target_column_id;
  SELECT to_jsonb(task) - ARRAY['column_id', 'position', 'updated_at']
  INTO STRICT v_before_task FROM public.tasks AS task WHERE task.id = v_fixture.task_a;

  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000101',
    v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_fixture.task_a,
      'source_column_id', v_fixture.source_column_id,
      'column_id', v_fixture.target_column_id,
      'before_task_id', v_fixture.target_before_id,
      'after_task_id', v_fixture.target_after_id
    )),
    jsonb_build_object(
      v_fixture.source_column_id::text, v_source_version,
      v_fixture.target_column_id::text, v_target_version
    )
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A current anchored move should confirm: %', v_result;
  END IF;

  SELECT array_agg(task.title ORDER BY task.position)
  INTO v_source_order FROM public.tasks AS task WHERE task.column_id = v_fixture.source_column_id;
  SELECT array_agg(task.title ORDER BY task.position)
  INTO v_target_order FROM public.tasks AS task WHERE task.column_id = v_fixture.target_column_id;
  IF v_source_order IS DISTINCT FROM ARRAY['Tarea B', 'Tarea C']::text[]
    OR v_target_order IS DISTINCT FROM ARRAY['Antes', 'Tarea A', 'Después']::text[] THEN
    RAISE EXCEPTION 'Anchors did not place the task deterministically: source %, target %', v_source_order, v_target_order;
  END IF;
  SELECT task_order_version INTO v_version_after_move
  FROM public.columns WHERE id = v_fixture.target_column_id;
  SELECT task_order_version INTO v_source_version_after_move
  FROM public.columns WHERE id = v_fixture.source_column_id;
  IF v_version_after_move <= v_target_version
    OR v_source_version_after_move <= v_source_version
    OR (SELECT task_order_version FROM public.columns WHERE id = v_fixture.second_source_column_id)
      IS DISTINCT FROM v_second_source_version
    OR (SELECT task_order_version FROM public.columns WHERE id = v_fixture.second_target_column_id)
      IS DISTINCT FROM v_second_target_version THEN
    RAISE EXCEPTION 'A move must advance only the affected order versions';
  END IF;

  SELECT to_jsonb(task) - ARRAY['column_id', 'position', 'updated_at']
  INTO STRICT v_after_task FROM public.tasks AS task WHERE task.id = v_fixture.task_a;
  IF v_after_task IS DISTINCT FROM v_before_task
    OR (SELECT field_versions FROM public.tasks WHERE id = v_fixture.task_a)
      IS DISTINCT FROM v_before_task->'field_versions' THEN
    RAISE EXCEPTION 'Moving changed task fields or field versions: before %, after %', v_before_task, v_after_task;
  END IF;

  -- Replays read the current authorized snapshot instead of retaining task
  -- titles in the receipt, and they never apply the move a second time.
  v_replay_task_id := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000118', v_fixture.board_id,
    v_fixture.target_column_id, 'Tarea posterior al recibo'
  )->'task'->>'id')::uuid;
  SELECT task_order_version INTO STRICT v_version_before_replay
  FROM public.get_columns_p(v_fixture.board_id)
  WHERE id = v_fixture.target_column_id;
  v_replay := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000101',
    v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_fixture.task_a,
      'source_column_id', v_fixture.source_column_id,
      'column_id', v_fixture.target_column_id,
      'before_task_id', v_fixture.target_before_id,
      'after_task_id', v_fixture.target_after_id
    )),
    jsonb_build_object(
      v_fixture.source_column_id::text, v_source_version,
      v_fixture.target_column_id::text, v_target_version
    )
  );
  IF v_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT task_order_version FROM public.columns WHERE id = v_fixture.target_column_id)
      IS DISTINCT FROM v_version_before_replay
    OR jsonb_array_length(v_replay->'columns') <> 2
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_replay->'columns') AS snapshot(value)
      WHERE snapshot.value->>'id' = v_fixture.target_column_id::text
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(snapshot.value->'tasks') AS task(value)
          WHERE task.value->>'id' = v_replay_task_id::text
            AND task.value->>'title' = 'Tarea posterior al recibo'
        )
    ) THEN
    RAISE EXCEPTION 'Replaying a confirmed move did not return a fresh authorized snapshot: %', v_replay;
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_attribute AS attribute
    WHERE attribute.attrelid = 'public.task_order_receipts'::regclass
      AND attribute.attname = 'result_payload'
      AND NOT attribute.attisdropped
  ) THEN
    RAISE EXCEPTION 'Task-order receipts still retain private result snapshots';
  END IF;

  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000102',
    v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_fixture.task_b,
      'source_column_id', v_fixture.source_column_id,
      'column_id', v_fixture.target_column_id,
      'before_task_id', v_fixture.target_after_id,
      'after_task_id', NULL
    )),
    jsonb_build_object(
      v_fixture.source_column_id::text, v_source_version,
      v_fixture.target_column_id::text, v_target_version
    )
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_b)
      IS DISTINCT FROM v_fixture.source_column_id THEN
    RAISE EXCEPTION 'A stale order version moved a task instead of requiring review: %', v_result;
  END IF;

  -- Reusing an operation ID with different move details is never a second write.
  BEGIN
    PERFORM public.update_task_positions_p(
      'f9999999-0000-4000-8000-000000000101',
      v_fixture.board_slug,
      jsonb_build_array(jsonb_build_object(
        'id', v_fixture.task_a,
        'source_column_id', v_fixture.target_column_id,
        'column_id', v_fixture.source_column_id,
        'before_task_id', NULL,
        'after_task_id', v_fixture.task_b
      )),
      jsonb_build_object(
        v_fixture.source_column_id::text, v_source_version,
        v_fixture.target_column_id::text, v_target_version
      )
    );
    RAISE EXCEPTION 'A move receipt accepted a different payload under the same operation ID';
  EXCEPTION WHEN check_violation THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A changed move payload was not rejected';
  END IF;
  IF has_function_privilege(
    'anon',
    'public.update_task_positions_p(uuid, text, jsonb, jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'Anonymous callers can execute task-order mutations';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_source_version bigint;
  v_target_version bigint;
  v_second_source_version bigint;
  v_second_target_version bigint;
  v_result jsonb;
  v_denied boolean := false;
  v_order text[];
BEGIN
  SELECT * INTO STRICT v_fixture FROM public.issue9_order_fixture WHERE purpose = 'main';
  SELECT task_order_version INTO v_source_version FROM public.columns WHERE id = v_fixture.source_column_id;
  SELECT task_order_version INTO v_target_version FROM public.columns WHERE id = v_fixture.target_column_id;
  SELECT task_order_version INTO v_second_source_version FROM public.columns WHERE id = v_fixture.second_source_column_id;
  SELECT task_order_version INTO v_second_target_version FROM public.columns WHERE id = v_fixture.second_target_column_id;

  UPDATE public.issue9_order_fixture
  SET batch_expected_order_versions = jsonb_build_object(
    v_fixture.source_column_id::text, v_source_version,
    v_fixture.target_column_id::text, v_target_version,
    v_fixture.second_source_column_id::text, v_second_source_version,
    v_fixture.second_target_column_id::text, v_second_target_version
  )
  WHERE purpose = 'main';

  -- Two source columns move into two destination columns in one atomic batch.
  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000103',
    v_fixture.board_slug,
    jsonb_build_array(
      jsonb_build_object(
        'id', v_fixture.task_c,
        'source_column_id', v_fixture.source_column_id,
        'column_id', v_fixture.target_column_id,
        'before_task_id', v_fixture.target_before_id,
        'after_task_id', v_fixture.task_a
      ),
      jsonb_build_object(
        'id', v_fixture.task_d,
        'source_column_id', v_fixture.second_source_column_id,
        'column_id', v_fixture.second_target_column_id,
        'before_task_id', NULL,
        'after_task_id', NULL
      )
    ),
    jsonb_build_object(
      v_fixture.source_column_id::text, v_source_version,
      v_fixture.target_column_id::text, v_target_version,
      v_fixture.second_source_column_id::text, v_second_source_version,
      v_fixture.second_target_column_id::text, v_second_target_version
    )
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_c)
      IS DISTINCT FROM v_fixture.target_column_id
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_d)
      IS DISTINCT FROM v_fixture.second_target_column_id THEN
    RAISE EXCEPTION 'A valid cross-column batch was not committed as one operation: %', v_result;
  END IF;
  SELECT array_agg(task.title ORDER BY task.position)
  INTO v_order FROM public.tasks AS task WHERE task.column_id = v_fixture.target_column_id;
  IF v_order IS DISTINCT FROM ARRAY[
    'Antes', 'Tarea C', 'Tarea A', 'Después', 'Tarea posterior al recibo'
  ]::text[] THEN
    RAISE EXCEPTION 'The batch did not respect its deterministic anchors: %', v_order;
  END IF;

  v_source_version := (SELECT task_order_version FROM public.columns WHERE id = v_fixture.source_column_id);
  v_target_version := (SELECT task_order_version FROM public.columns WHERE id = v_fixture.target_column_id);
  v_second_source_version := (SELECT task_order_version FROM public.columns WHERE id = v_fixture.second_source_column_id);
  v_second_target_version := (SELECT task_order_version FROM public.columns WHERE id = v_fixture.second_target_column_id);

  -- One invalid cross-board destination rejects the whole batch.
  BEGIN
    PERFORM public.update_task_positions_p(
      'f9999999-0000-4000-8000-000000000104',
      v_fixture.board_slug,
      jsonb_build_array(
        jsonb_build_object(
          'id', v_fixture.task_b,
          'source_column_id', v_fixture.source_column_id,
          'column_id', v_fixture.target_column_id,
          'before_task_id', v_fixture.task_a,
          'after_task_id', v_fixture.target_after_id
        ),
        jsonb_build_object(
          'id', v_fixture.task_d,
          'source_column_id', v_fixture.second_target_column_id,
          'column_id', v_fixture.external_column_id,
          'before_task_id', NULL,
          'after_task_id', NULL
        )
      ),
      jsonb_build_object(
        v_fixture.source_column_id::text, v_source_version,
        v_fixture.target_column_id::text, v_target_version,
        v_fixture.second_source_column_id::text, v_second_source_version,
        v_fixture.second_target_column_id::text, v_second_target_version
      )
    );
    RAISE EXCEPTION 'A cross-board move was accepted';
  EXCEPTION WHEN check_violation THEN
    v_denied := true;
  END;
  IF NOT v_denied
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_b)
      IS DISTINCT FROM v_fixture.source_column_id
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_d)
      IS DISTINCT FROM v_fixture.second_target_column_id
    OR (SELECT task_order_version FROM public.columns WHERE id = v_fixture.target_column_id)
      IS DISTINCT FROM v_target_version THEN
    RAISE EXCEPTION 'A rejected cross-board batch partially changed task order';
  END IF;

  -- Same versions with non-adjacent anchors require the user to review order.
  v_denied := false;
  BEGIN
    PERFORM public.update_task_positions_p(
      'f9999999-0000-4000-8000-000000000107',
      v_fixture.board_slug,
      jsonb_build_array(jsonb_build_object(
        'id', v_fixture.task_b,
        'source_column_id', v_fixture.source_column_id,
        'column_id', v_fixture.target_column_id,
        'before_task_id', '',
        'after_task_id', v_fixture.target_before_id
      )),
      jsonb_build_object(
        v_fixture.source_column_id::text, v_source_version,
        v_fixture.target_column_id::text, v_target_version
      )
    );
    RAISE EXCEPTION 'An empty string was accepted as a task anchor';
  EXCEPTION WHEN invalid_parameter_value THEN
    v_denied := true;
  END;
  IF NOT v_denied
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_b)
      IS DISTINCT FROM v_fixture.source_column_id THEN
    RAISE EXCEPTION 'An empty task anchor was not rejected without a move';
  END IF;

  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000105',
    v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_fixture.task_b,
      'source_column_id', v_fixture.source_column_id,
      'column_id', v_fixture.target_column_id,
      'before_task_id', v_fixture.target_before_id,
      'after_task_id', v_fixture.target_after_id
    )),
    jsonb_build_object(
      v_fixture.source_column_id::text, v_source_version,
      v_fixture.target_column_id::text, v_target_version
    )
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_b)
      IS DISTINCT FROM v_fixture.source_column_id THEN
    RAISE EXCEPTION 'Non-adjacent anchors did not require order review: %', v_result;
  END IF;
END;
$$;
COMMIT;

-- Create/delete each advance the independent order version. A client that
-- refreshes that version through the authorized column RPC can move at once;
-- using the pre-mutation snapshot correctly requires review.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_before_create_version bigint;
  v_after_create_version bigint;
  v_before_delete_version bigint;
  v_after_delete_version bigint;
  v_created_task_id uuid;
  v_deleted_task_id uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM public.issue9_order_fixture WHERE purpose = 'main';
  SELECT task_order_version INTO STRICT v_before_create_version
  FROM public.get_columns_p(v_fixture.board_id)
  WHERE id = v_fixture.source_column_id;

  v_created_task_id := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000111', v_fixture.board_id,
    v_fixture.source_column_id, 'Tarea creada para orden inmediato'
  )->'task'->>'id')::uuid;
  SELECT task_order_version INTO STRICT v_after_create_version
  FROM public.get_columns_p(v_fixture.board_id)
  WHERE id = v_fixture.source_column_id;
  IF v_after_create_version <= v_before_create_version THEN
    RAISE EXCEPTION 'Creating a task did not advance the authorized order version';
  END IF;

  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000112', v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_created_task_id,
      'source_column_id', v_fixture.source_column_id,
      'column_id', v_fixture.source_column_id,
      'before_task_id', NULL,
      'after_task_id', v_fixture.task_b
    )),
    jsonb_build_object(v_fixture.source_column_id::text, v_before_create_version)
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR (SELECT column_id FROM public.tasks WHERE id = v_created_task_id)
      IS DISTINCT FROM v_fixture.source_column_id THEN
    RAISE EXCEPTION 'The pre-create order snapshot did not require review: %', v_result;
  END IF;

  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000113', v_fixture.board_slug,
    jsonb_build_array(
      jsonb_build_object(
        'id', v_created_task_id,
        'source_column_id', v_fixture.source_column_id,
        'column_id', v_fixture.source_column_id,
        'before_task_id', NULL,
        'after_task_id', v_fixture.task_b
      )
    ),
    jsonb_build_object(v_fixture.source_column_id::text, v_after_create_version)
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'An immediate post-create reorder did not use the authorized order version: %', v_result;
  END IF;

  v_deleted_task_id := (public.create_task_p(
    'f9999999-0000-4000-8000-000000000116', v_fixture.board_id,
    v_fixture.source_column_id, 'Tarea descartable para borrar'
  )->'task'->>'id')::uuid;
  SELECT task_order_version INTO STRICT v_before_delete_version
  FROM public.get_columns_p(v_fixture.board_id)
  WHERE id = v_fixture.source_column_id;
  PERFORM public.delete_task_p(v_fixture.board_slug, v_deleted_task_id);
  SELECT task_order_version INTO STRICT v_after_delete_version
  FROM public.get_columns_p(v_fixture.board_id)
  WHERE id = v_fixture.source_column_id;
  IF v_after_delete_version <= v_before_delete_version THEN
    RAISE EXCEPTION 'Deleting a task did not advance the authorized order version';
  END IF;

  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000114', v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_fixture.task_b,
      'source_column_id', v_fixture.source_column_id,
      'column_id', v_fixture.source_column_id,
      'before_task_id', NULL,
      'after_task_id', v_created_task_id
    )),
    jsonb_build_object(v_fixture.source_column_id::text, v_before_delete_version)
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR (SELECT column_id FROM public.tasks WHERE id = v_fixture.task_b)
      IS DISTINCT FROM v_fixture.source_column_id THEN
    RAISE EXCEPTION 'The pre-delete order snapshot did not require review: %', v_result;
  END IF;

  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000115', v_fixture.board_slug,
    jsonb_build_array(
      jsonb_build_object(
        'id', v_fixture.task_b,
        'source_column_id', v_fixture.source_column_id,
        'column_id', v_fixture.source_column_id,
        'before_task_id', NULL,
        'after_task_id', v_created_task_id
      )
    ),
    jsonb_build_object(v_fixture.source_column_id::text, v_after_delete_version)
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'An immediate post-delete reorder did not use the authorized order version: %', v_result;
  END IF;
END;
$$;
COMMIT;

-- The successful receipt cannot be replayed after its reconciliation window.
UPDATE public.task_order_receipts
SET result_expires_at = clock_timestamp() - interval '1 second'
WHERE actor_id = '40000000-0000-4000-8000-000000000002'
  AND operation_id = 'f9999999-0000-4000-8000-000000000103';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_move_count integer;
  v_target_version_before bigint;
  v_second_target_version_before bigint;
BEGIN
  SELECT * INTO STRICT v_fixture FROM public.issue9_order_fixture WHERE purpose = 'main';
  SELECT task_order_version INTO STRICT v_target_version_before
  FROM public.columns WHERE id = v_fixture.target_column_id;
  SELECT task_order_version INTO STRICT v_second_target_version_before
  FROM public.columns WHERE id = v_fixture.second_target_column_id;
  SELECT count(*) INTO v_move_count FROM public.tasks
  WHERE id IN (v_fixture.task_c, v_fixture.task_d)
    AND column_id IN (v_fixture.target_column_id, v_fixture.second_target_column_id);
  v_result := public.update_task_positions_p(
    'f9999999-0000-4000-8000-000000000103',
    v_fixture.board_slug,
    jsonb_build_array(
      jsonb_build_object(
        'id', v_fixture.task_c,
        'source_column_id', v_fixture.source_column_id,
        'column_id', v_fixture.target_column_id,
        'before_task_id', v_fixture.target_before_id,
        'after_task_id', v_fixture.task_a
      ),
      jsonb_build_object(
        'id', v_fixture.task_d,
        'source_column_id', v_fixture.second_source_column_id,
        'column_id', v_fixture.second_target_column_id,
        'before_task_id', NULL,
        'after_task_id', NULL
      )
    ),
    v_fixture.batch_expected_order_versions
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired_unknown'
    OR v_move_count <> 2
    OR v_result ? 'columns'
    OR v_result ? 'task'
    OR v_result->>'operation_id' IS DISTINCT FROM 'f9999999-0000-4000-8000-000000000103'
    OR (SELECT task_order_version FROM public.columns WHERE id = v_fixture.target_column_id)
      IS DISTINCT FROM v_target_version_before
    OR (SELECT task_order_version FROM public.columns WHERE id = v_fixture.second_target_column_id)
      IS DISTINCT FROM v_second_target_version_before THEN
    RAISE EXCEPTION 'An expired move receipt was reapplied or not identified: %', v_result;
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
  SELECT * INTO STRICT v_fixture FROM public.issue9_order_fixture WHERE purpose = 'main';
  BEGIN
    PERFORM public.update_task_positions_p(
      'f9999999-0000-4000-8000-000000000106',
      v_fixture.board_slug,
      jsonb_build_array(jsonb_build_object(
        'id', v_fixture.task_b,
        'source_column_id', v_fixture.source_column_id,
        'column_id', v_fixture.target_column_id,
        'before_task_id', NULL,
        'after_task_id', v_fixture.target_before_id
      )),
      jsonb_build_object(v_fixture.source_column_id::text, 1, v_fixture.target_column_id::text, 1)
    );
    RAISE EXCEPTION 'A global administrator without board membership moved a task';
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A non-member administrator was not denied task movement';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: anchored task order uses independent versions, atomic batches, authorization, and replay-safe receipts'
