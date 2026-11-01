\set ON_ERROR_STOP on

CREATE TEMP TABLE issue18_column_recovery_refs (
  purpose text PRIMARY KEY,
  board_slug text NOT NULL,
  board_id uuid NOT NULL,
  source_column_id uuid NOT NULL,
  destination_column_id uuid NOT NULL,
  live_task_id uuid NOT NULL,
  deleted_task_id uuid NOT NULL,
  deleted_task_expires_at timestamptz NOT NULL
);
GRANT SELECT, INSERT ON issue18_column_recovery_refs TO authenticated;

CREATE TABLE public.issue18_column_recovery_race_fixture (
  scenario text PRIMARY KEY,
  board_slug text NOT NULL,
  board_id uuid NOT NULL,
  column_id uuid NOT NULL,
  expires_at timestamptz NOT NULL
);
GRANT SELECT, INSERT ON public.issue18_column_recovery_race_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);

DO $$
DECLARE
  v_board record;
  v_source public.columns%ROWTYPE;
  v_destination public.columns%ROWTYPE;
  v_created jsonb;
  v_preview jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_live_task_id uuid;
  v_deleted_task_id uuid;
  v_expires_at timestamptz;
  v_task_count integer;
  v_destination_count integer;
  v_deleted_task_count integer;
  v_source_version bigint;
  v_destination_version bigint;
  v_anchor_task_id uuid;
  v_move_result jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Recuperación de columnas #18',
    'UTC',
    '18000000-0000-4000-8000-000000000001'
  );
  SELECT * INTO v_source
  FROM public.create_column_p(v_board.slug, v_board.id, 'Origen', 0);
  SELECT * INTO v_destination
  FROM public.create_column_p(v_board.slug, v_board.id, 'Destino', 1);

  v_created := public.create_task_p(
    '18000000-0000-4000-8000-000000000002', v_board.id, v_destination.id,
    'Ya estaba en destino'
  );
  v_created := public.create_task_p(
    '18000000-0000-4000-8000-000000000003', v_board.id, v_source.id,
    'Se traslada al borrar columna'
  );
  v_live_task_id := (v_created->>'task_id')::uuid;
  v_created := public.create_task_p(
    '18000000-0000-4000-8000-000000000004', v_board.id, v_source.id,
    'Hija borrada independientemente'
  );
  v_deleted_task_id := (v_created->>'task_id')::uuid;
  v_deleted := public.delete_task_p(
    '18000000-0000-4000-8000-000000000005', v_board.slug, v_deleted_task_id,
    'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The independent task deletion did not succeed: %', v_deleted;
  END IF;
  SELECT item.expires_at INTO STRICT v_expires_at
  FROM public.list_deleted_tasks_p(v_board.slug) AS item
  WHERE item.task_id = v_deleted_task_id;

  v_preview := public.preview_delete_column_p(v_board.slug, v_source.id);
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR (v_preview->>'task_count')::integer <> 1
    OR (v_preview->>'task_order_version')::bigint IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_preview->'destinations') AS destination
      WHERE destination->>'id' = v_destination.id::text
    ) THEN
    RAISE EXCEPTION 'Column preview must offer the current same-board destination and active task count: %',
      v_preview;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(v_preview->'destinations') AS destination
    WHERE destination->>'id' = v_source.id::text
  ) THEN
    RAISE EXCEPTION 'Column preview offered the source as its own destination';
  END IF;

  v_deleted := public.delete_column_p(
    '18000000-0000-4000-8000-000000000006', v_board.slug, v_source.id,
    v_destination.id, (v_preview->>'task_order_version')::bigint
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Column deletion with an explicit destination failed: %', v_deleted;
  END IF;

  SELECT count(*) INTO v_task_count
  FROM public.get_tasks_by_board_p(v_board.id) AS task
  WHERE task.id = v_live_task_id AND task.column_id = v_destination.id;
  SELECT count(*) INTO v_destination_count
  FROM public.get_tasks_by_board_p(v_board.id) AS task
  WHERE task.column_id = v_destination.id;
  SELECT count(*) INTO v_deleted_task_count
  FROM public.list_deleted_tasks_p(v_board.slug) AS item
  WHERE item.task_id = v_deleted_task_id AND item.expires_at = v_expires_at;
  IF v_task_count <> 1 OR v_destination_count <> 2 OR v_deleted_task_count <> 1 THEN
    RAISE EXCEPTION 'Column deletion must move active tasks atomically and preserve independent task recovery';
  END IF;

  v_restored := public.restore_column_p(
    '18000000-0000-4000-8000-000000000007', v_board.slug, v_source.id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Column restoration failed: %', v_restored;
  END IF;
  SELECT count(*) INTO v_task_count
  FROM public.get_tasks_by_board_p(v_board.id) AS task
  WHERE task.id = v_live_task_id AND task.column_id = v_destination.id;
  SELECT count(*) INTO v_destination_count
  FROM public.get_tasks_by_board_p(v_board.id) AS task
  WHERE task.column_id = v_source.id;
  SELECT count(*) INTO v_deleted_task_count
  FROM public.list_deleted_tasks_p(v_board.slug) AS item
  WHERE item.task_id = v_deleted_task_id AND item.expires_at = v_expires_at;
  IF v_task_count <> 1 OR v_destination_count <> 0 OR v_deleted_task_count <> 1 THEN
    RAISE EXCEPTION 'Restoring a column must preserve task transfers and independent child deletion';
  END IF;

  v_created := public.create_task_p(
    '18000000-0000-4000-8000-000000000008', v_board.id, v_source.id,
    'Tarea movida durante la vista previa'
  );
  v_live_task_id := (v_created->>'task_id')::uuid;
  v_preview := public.preview_delete_column_p(v_board.slug, v_source.id);
  v_source_version := (v_preview->>'task_order_version')::bigint;
  SELECT column_row.task_order_version INTO STRICT v_destination_version
  FROM public.columns AS column_row WHERE column_row.id = v_destination.id;
  SELECT task.id INTO STRICT v_anchor_task_id
  FROM public.tasks AS task
  WHERE task.column_id = v_destination.id
  ORDER BY task.position DESC, task.id DESC
  LIMIT 1;
  v_move_result := public.update_task_positions_p(
    '18000000-0000-4000-8000-000000000009', v_board.slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_live_task_id,
      'source_column_id', v_source.id,
      'column_id', v_destination.id,
      'before_task_id', v_anchor_task_id,
      'after_task_id', NULL
    )),
    jsonb_build_object(
      v_source.id::text, v_source_version,
      v_destination.id::text, v_destination_version
    )
  );
  IF v_move_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Concurrent content move fixture failed: %', v_move_result;
  END IF;
  v_deleted := public.delete_column_p(
    '18000000-0000-4000-8000-000000000010', v_board.slug, v_source.id,
    v_destination.id, v_source_version
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'conflict'
    OR (SELECT task.column_id FROM public.tasks AS task WHERE task.id = v_live_task_id)
      IS DISTINCT FROM v_destination.id
    OR NOT EXISTS (
      SELECT 1 FROM public.columns AS column_row WHERE column_row.id = v_source.id
    ) THEN
    RAISE EXCEPTION 'A task moved after preview must keep the stale column deletion from applying: %', v_deleted;
  END IF;

  INSERT INTO pg_temp.issue18_column_recovery_refs(
    purpose, board_slug, board_id, source_column_id, destination_column_id,
    live_task_id, deleted_task_id, deleted_task_expires_at
  ) VALUES (
    'confirmed-transfer', v_board.slug, v_board.id, v_source.id, v_destination.id,
    v_live_task_id, v_deleted_task_id, v_expires_at
  );
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_destination public.columns%ROWTYPE;
  v_source public.columns%ROWTYPE;
  v_preview jsonb;
  v_deleted jsonb;
  v_column_id uuid;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Límites de recuperación de columnas #18',
    'UTC',
    '18000000-0000-4000-8000-000000000101'
  );
  SELECT * INTO v_destination
  FROM public.create_column_p(v_board.slug, v_board.id, 'Vigente', 0);

  FOREACH v_column_id IN ARRAY ARRAY[
    '18000000-0000-4000-8000-000000000111'::uuid,
    '18000000-0000-4000-8000-000000000112'::uuid,
    '18000000-0000-4000-8000-000000000113'::uuid,
    '18000000-0000-4000-8000-000000000114'::uuid
  ] LOOP
    SELECT * INTO v_source
    FROM public.create_column_p(
      v_board.slug, v_board.id, 'Recuperable ' || right(v_column_id::text, 2),
      (SELECT count(*)::integer FROM public.get_columns_p(v_board.id))
    );
    v_preview := public.preview_delete_column_p(v_board.slug, v_source.id);
    v_deleted := public.delete_column_p(
      gen_random_uuid(), v_board.slug, v_source.id, NULL,
      (v_preview->>'task_order_version')::bigint
    );
    IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Boundary fixture column deletion failed: %', v_deleted;
    END IF;
    INSERT INTO public.issue18_column_recovery_race_fixture(
      scenario, board_slug, board_id, column_id, expires_at
    ) VALUES (
      CASE right(v_column_id::text, 2)
        WHEN '11' THEN 'restore_before'
        WHEN '12' THEN 'restore_at'
        WHEN '13' THEN 'purge_wins'
        ELSE 'restore_wins'
      END,
      v_board.slug, v_board.id, v_source.id,
      '2035-10-26 12:00:00+00'::timestamptz
    );
  END LOOP;
END;
$$;
COMMIT;

-- Set controlled deadlines after the authenticated creation path, then check
-- the strict restore boundary independently of the machine clock.
UPDATE public.column_deletions AS deletion
SET deleted_at = '2035-10-26 12:00:00+00'::timestamptz - interval '168 hours',
    expires_at = '2035-10-26 12:00:00+00'::timestamptz
FROM public.issue18_column_recovery_race_fixture AS fixture
WHERE fixture.column_id = deletion.column_id;

SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', false);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue18_column_recovery_race_fixture
  WHERE scenario = 'restore_before';
  v_result := public.restore_column_internal_p(
    '18000000-0000-4000-8000-000000000121', v_fixture.board_slug,
    v_fixture.column_id, v_fixture.expires_at - interval '1 microsecond'
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A column must restore one microsecond before expiry: %', v_result;
  END IF;

  SELECT * INTO STRICT v_fixture
  FROM public.issue18_column_recovery_race_fixture
  WHERE scenario = 'restore_at';
  v_result := public.restore_column_internal_p(
    '18000000-0000-4000-8000-000000000122', v_fixture.board_slug,
    v_fixture.column_id, v_fixture.expires_at
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired'
    OR EXISTS (
      SELECT 1 FROM public.columns AS column_row
      WHERE column_row.id = v_fixture.column_id
    ) THEN
    RAISE EXCEPTION 'At the exact deadline a column must remain unavailable: %', v_result;
  END IF;
END;
$$;

SELECT 'PASS: column preview, explicit same-board destination, atomic task transfer, and restore without reversing moves'
  AS result;
