\set ON_ERROR_STOP on

CREATE TEMP TABLE issue14_task_refs (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL
);
GRANT SELECT, INSERT ON issue14_task_refs TO authenticated;
CREATE TABLE public.issue14_task_recovery_race_fixture (
  scenario text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  expires_at timestamptz NOT NULL
);
GRANT SELECT, INSERT ON public.issue14_task_recovery_race_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);

DO $$
DECLARE
  v_board record;
  v_column public.columns%ROWTYPE;
  v_created jsonb;
  v_deleted jsonb;
  v_task_id uuid;
  v_started_at timestamptz := clock_timestamp();
  v_trash record;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Tareas recuperables #14',
    'UTC',
    '14000000-0000-4000-8000-000000000001'
  );
  SELECT * INTO v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Pendientes', 0);
  v_created := public.create_task_p(
    '14000000-0000-4000-8000-000000000002',
    v_board.id,
    v_column.id,
    'Tarea que conserva su plazo'
  );
  v_task_id := (v_created->>'task_id')::uuid;

  v_deleted := public.delete_task_p(
    '14000000-0000-4000-8000-000000000003',
    v_board.slug,
    v_task_id,
    'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Task deletion was not confirmed: %', v_deleted;
  END IF;

  SELECT * INTO v_trash
  FROM public.list_deleted_tasks_p(v_board.slug)
  WHERE task_id = v_task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The deleted task is absent from the authorized recovery list';
  END IF;
  IF v_trash.title IS DISTINCT FROM 'Tarea que conserva su plazo'
    OR v_trash.cause IS DISTINCT FROM 'user_requested'
    OR v_trash.deleted_at < v_started_at
    OR v_trash.deleted_at > clock_timestamp()
    OR v_trash.expires_at IS DISTINCT FROM v_trash.deleted_at + interval '168 hours' THEN
    RAISE EXCEPTION 'Deletion metadata did not use the server clock and exact 7x24h window: %',
      row_to_json(v_trash);
  END IF;
  INSERT INTO pg_temp.issue14_task_refs(
    purpose, board_id, board_slug, column_id, task_id
  ) VALUES (
    'restored', v_board.id, v_board.slug, v_column.id, v_task_id
  );
END;
$$;
COMMIT;

-- A controlled deletion crosses the Denver DST transition but retains a
-- fixed 168-hour deadline, independent of the session's calendar-day rules.
BEGIN;
SET LOCAL TIME ZONE 'America/Denver';
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_reference record;
  v_created jsonb;
  v_deleted jsonb;
  v_task_id uuid;
  v_deleted_at timestamptz := '2005-04-02 12:00:00-07';
  v_expires_at timestamptz;
  v_elapsed_seconds numeric;
BEGIN
  SELECT * INTO STRICT v_reference FROM pg_temp.issue14_task_refs
  WHERE purpose = 'restored';
  v_created := public.create_task_p(
    gen_random_uuid(),
    v_reference.board_id,
    v_reference.column_id,
    'Tarea de prueba alrededor del cambio de horario'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_deleted := public.delete_task_internal_p(
    gen_random_uuid(),
    v_reference.board_slug,
    v_task_id,
    'user_requested',
    v_deleted_at
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Controlled deletion across DST was not confirmed: %', v_deleted;
  END IF;

  SELECT deletion.deleted_at, deletion.expires_at
  INTO STRICT v_deleted_at, v_expires_at
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = v_task_id;
  v_elapsed_seconds := extract(epoch FROM (v_expires_at - v_deleted_at));
  IF v_deleted_at IS DISTINCT FROM '2005-04-02 12:00:00-07'::timestamptz
    OR v_expires_at IS DISTINCT FROM '2005-04-09 13:00:00-06'::timestamptz
    OR v_elapsed_seconds IS DISTINCT FROM 604800 THEN
    RAISE EXCEPTION 'Expected 2005-04-09 13:00:00-06 / 604800 seconds; got % / % seconds',
      v_expires_at, v_elapsed_seconds;
  END IF;
  IF public.purge_expired_task_internal_p(v_task_id, v_expires_at)
    IS DISTINCT FROM 'purged' THEN
    RAISE EXCEPTION 'Could not remove the controlled expired DST test snapshot';
  END IF;
  RAISE NOTICE 'PASS: controlled 168-hour deletion expires at % (% seconds elapsed)',
    v_expires_at, v_elapsed_seconds;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_reference record;
  v_restored jsonb;
  v_task_count integer;
  v_trash_count integer;
BEGIN
  SELECT * INTO STRICT v_reference FROM pg_temp.issue14_task_refs
  WHERE purpose = 'restored';
  v_restored := public.restore_task_p(
    '14000000-0000-4000-8000-000000000004',
    v_reference.board_slug,
    v_reference.task_id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Task recovery was not confirmed: %', v_restored;
  END IF;
  SELECT count(*) INTO v_task_count
  FROM public.get_tasks_by_board_p(v_reference.board_id) AS task
  WHERE task.id = v_reference.task_id
    AND task.title = 'Tarea que conserva su plazo'
    AND task.column_id = v_reference.column_id;
  SELECT count(*) INTO v_trash_count
  FROM public.list_deleted_tasks_p(v_reference.board_slug) AS item
  WHERE item.task_id = v_reference.task_id;
  IF v_task_count <> 1 OR v_trash_count <> 0 THEN
    RAISE EXCEPTION 'Restoration did not atomically return the task to its board';
  END IF;
END;
$$;
COMMIT;

-- A lost response can be replayed with the same operation key and payload.
-- Reusing either key for a different command payload is rejected.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_reference record;
  v_result jsonb;
  v_collision_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_reference FROM pg_temp.issue14_task_refs
  WHERE purpose = 'restored';
  v_result := public.delete_task_p(
    '14000000-0000-4000-8000-000000000003',
    v_reference.board_slug,
    v_reference.task_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Discarded delete response did not replay its result: %', v_result;
  END IF;
  v_result := public.restore_task_p(
    '14000000-0000-4000-8000-000000000004',
    v_reference.board_slug,
    v_reference.task_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Discarded restore response did not replay its result: %', v_result;
  END IF;

  BEGIN
    PERFORM public.delete_task_p(
      '14000000-0000-4000-8000-000000000003',
      v_reference.board_slug,
      '14000000-0000-4000-8000-000000000099'
    );
  EXCEPTION WHEN check_violation THEN
    v_collision_denied := true;
  END;
  IF NOT v_collision_denied THEN
    RAISE EXCEPTION 'A delete receipt accepted a different task payload';
  END IF;
  v_collision_denied := false;
  BEGIN
    PERFORM public.restore_task_p(
      '14000000-0000-4000-8000-000000000004',
      v_reference.board_slug,
      v_reference.task_id,
      '14000000-0000-4000-8000-000000000098'
    );
  EXCEPTION WHEN check_violation THEN
    v_collision_denied := true;
  END;
  IF NOT v_collision_denied THEN
    RAISE EXCEPTION 'A restore receipt accepted a different destination payload';
  END IF;
END;
$$;
COMMIT;

-- Create a separate item whose expiry is advanced only by the private,
-- test-only clock seam below.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_reference record;
  v_created jsonb;
  v_deleted jsonb;
  v_task_id uuid;
BEGIN
  SELECT * INTO STRICT v_reference FROM pg_temp.issue14_task_refs
  WHERE purpose = 'restored';
  v_created := public.create_task_p(
    '14000000-0000-4000-8000-000000000009',
    v_reference.board_id,
    v_reference.column_id,
    'Tarea para el límite exacto'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_deleted := public.delete_task_p(
    '14000000-0000-4000-8000-000000000010',
    v_reference.board_slug,
    v_task_id
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the exact-boundary recovery item: %', v_deleted;
  END IF;
  INSERT INTO pg_temp.issue14_task_refs(
    purpose, board_id, board_slug, column_id, task_id
  ) VALUES (
    'boundary', v_reference.board_id, v_reference.board_slug,
    v_reference.column_id, v_task_id
  );
END;
$$;
COMMIT;

-- A board administrator who is not a member receives no task content and
-- cannot consume a restore operation.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_reference record;
  v_result jsonb;
  v_list_count integer;
BEGIN
  SELECT * INTO STRICT v_reference FROM pg_temp.issue14_task_refs
  WHERE purpose = 'restored';
  SELECT count(*) INTO v_list_count
  FROM public.list_deleted_tasks_p(v_reference.board_slug);
  v_result := public.restore_task_p(
    '14000000-0000-4000-8000-000000000005',
    v_reference.board_slug,
    v_reference.task_id
  );
  IF v_list_count <> 0 OR v_result <> jsonb_build_object(
    'status', 'unavailable',
    'operation_id', '14000000-0000-4000-8000-000000000005'::uuid
  ) THEN
    RAISE EXCEPTION 'A nonmember learned about or restored a private task: %, %',
      v_list_count, v_result;
  END IF;
END;
$$;
COMMIT;

-- A deleted task stays recoverable when its old column is removed, keeps the
-- original deadline, and can be restored to a valid current destination.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_reference record;
  v_parent_column public.columns%ROWTYPE;
  v_destination public.columns%ROWTYPE;
  v_created jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_needs_destination jsonb;
  v_task_id uuid;
  v_before_expiry timestamptz;
  v_after_expiry timestamptz;
  v_final_column uuid;
BEGIN
  SELECT * INTO STRICT v_reference FROM pg_temp.issue14_task_refs
  WHERE purpose = 'restored';
  SELECT * INTO v_parent_column
  FROM public.create_column_p(v_reference.board_slug, v_reference.board_id, 'Columna eliminable', 1);
  SELECT * INTO v_destination
  FROM public.create_column_p(v_reference.board_slug, v_reference.board_id, 'Destino válido', 2);
  v_created := public.create_task_p(
    '14000000-0000-4000-8000-000000000006',
    v_reference.board_id,
    v_parent_column.id,
    'Tarea con columna de origen eliminable'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_deleted := public.delete_task_p(
    '14000000-0000-4000-8000-000000000007',
    v_reference.board_slug,
    v_task_id
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Independent task deletion failed before parent removal: %', v_deleted;
  END IF;
  SELECT item.expires_at INTO STRICT v_before_expiry
  FROM public.list_deleted_tasks_p(v_reference.board_slug) AS item
  WHERE item.task_id = v_task_id;

  PERFORM public.delete_column_p(v_reference.board_slug, v_parent_column.id);

  SELECT item.expires_at INTO STRICT v_after_expiry
  FROM public.list_deleted_tasks_p(v_reference.board_slug) AS item
  WHERE item.task_id = v_task_id;
  IF v_after_expiry IS DISTINCT FROM v_before_expiry THEN
    RAISE EXCEPTION 'Removing the parent column changed the independently deleted task deadline';
  END IF;
  v_needs_destination := public.restore_task_p(
    '14000000-0000-4000-8000-000000000012',
    v_reference.board_slug,
    v_task_id
  );
  IF v_needs_destination->>'status' IS DISTINCT FROM 'needs_destination'
    OR NOT EXISTS (
      SELECT 1 FROM public.list_deleted_tasks_p(v_reference.board_slug) AS item
      WHERE item.task_id = v_task_id
    ) THEN
    RAISE EXCEPTION 'A missing parent destination did not remain safely recoverable: %',
      v_needs_destination;
  END IF;
  v_restored := public.restore_task_p(
    '14000000-0000-4000-8000-000000000008',
    v_reference.board_slug,
    v_task_id,
    v_destination.id
  );
  SELECT task.column_id INTO v_final_column
  FROM public.get_tasks_by_board_p(v_reference.board_id) AS task
  WHERE task.id = v_task_id;
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR v_final_column IS DISTINCT FROM v_destination.id THEN
    RAISE EXCEPTION 'A task was not restored into the explicitly selected current column: %, %',
      v_restored, v_final_column;
  END IF;
END;
$$;
COMMIT;

-- The exact 7x24h boundary is already expired. Recovery has no partial effect;
-- purge is early just before the boundary, then drops content at the boundary.
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', false);
WITH controlled_clock AS (
  SELECT clock_timestamp() AS now
)
UPDATE public.task_deletions AS deletion
SET deleted_at = controlled_clock.now - interval '168 hours',
    expires_at = controlled_clock.now
FROM controlled_clock
WHERE deletion.task_id = (
  SELECT task_id FROM pg_temp.issue14_task_refs WHERE purpose = 'boundary'
);
DO $$
DECLARE
  v_reference record;
  v_expires_at timestamptz;
  v_can_restore boolean;
  v_original_column_available boolean;
  v_result jsonb;
  v_snapshot jsonb;
  v_state text;
  v_purged_at timestamptz;
BEGIN
  SELECT * INTO STRICT v_reference FROM pg_temp.issue14_task_refs
  WHERE purpose = 'boundary';
  SELECT item.expires_at, item.can_restore, item.original_column_available
  INTO STRICT v_expires_at, v_can_restore, v_original_column_available
  FROM public.list_deleted_tasks_p(v_reference.board_slug) AS item
  WHERE item.task_id = v_reference.task_id;
  IF v_can_restore OR NOT v_original_column_available THEN
    RAISE EXCEPTION 'The server did not close restore at the exact deadline: %, %',
      v_can_restore, v_original_column_available;
  END IF;
  v_result := public.restore_task_internal_p(
    '14000000-0000-4000-8000-000000000011',
    v_reference.board_slug,
    v_reference.task_id,
    NULL,
    v_expires_at
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired' THEN
    RAISE EXCEPTION 'Recovery at the exact expiration instant was not denied: %', v_result;
  END IF;
  SELECT deletion.state, deletion.task_snapshot INTO v_state, v_snapshot
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = v_reference.task_id;
  IF v_state IS DISTINCT FROM 'deleted'
    OR v_snapshot->>'title' IS DISTINCT FROM 'Tarea para el límite exacto'
    OR EXISTS (
      SELECT 1 FROM public.tasks AS task WHERE task.id = v_reference.task_id
    ) THEN
    RAISE EXCEPTION 'Boundary denial partially restored or discarded task content';
  END IF;
  IF public.purge_expired_task_internal_p(
    v_reference.task_id, v_expires_at - interval '1 microsecond'
  ) IS DISTINCT FROM 'too_early' THEN
    RAISE EXCEPTION 'Purge ran before the exact expiration instant';
  END IF;
  IF public.purge_expired_task_internal_p(
    v_reference.task_id, v_expires_at
  ) IS DISTINCT FROM 'purged' THEN
    RAISE EXCEPTION 'Purge did not run at the exact expiration instant';
  END IF;
  SELECT deletion.state, deletion.task_snapshot, deletion.purged_at
  INTO v_state, v_snapshot, v_purged_at
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = v_reference.task_id;
  IF v_state IS DISTINCT FROM 'purged'
    OR v_snapshot IS NOT NULL OR v_purged_at IS DISTINCT FROM v_expires_at THEN
    RAISE EXCEPTION 'Purge did not leave only a minimal tombstone at the boundary';
  END IF;
END;
$$;

DO $$
BEGIN
  IF has_function_privilege(
      'authenticated',
      'public.restore_task_internal_p(uuid,text,uuid,uuid,timestamp with time zone)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'authenticated',
      'public.delete_task_internal_p(uuid,text,uuid,text,timestamp with time zone)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'anon',
      'public.delete_task_internal_p(uuid,text,uuid,text,timestamp with time zone)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'service_role',
      'public.delete_task_internal_p(uuid,text,uuid,text,timestamp with time zone)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'service_role',
      'public.restore_task_internal_p(uuid,text,uuid,uuid,timestamp with time zone)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'authenticated',
      'public.purge_expired_task_internal_p(uuid,timestamp with time zone)',
      'EXECUTE'
    )
    OR has_function_privilege(
      'service_role',
      'public.purge_expired_task_internal_p(uuid,timestamp with time zone)',
      'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'An internal controlled-clock or purge helper is executable by app roles';
  END IF;
END;
$$;

-- Persistent synthetic IDs let the shell harness run two separate psql
-- sessions against this disposable cluster for the restore/purge race.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_index integer;
  v_board record;
  v_column public.columns%ROWTYPE;
  v_created jsonb;
  v_deleted jsonb;
  v_task_id uuid;
  v_expires_at timestamptz;
  v_scenario text;
BEGIN
  FOR v_index IN 1..2 LOOP
    v_scenario := CASE v_index WHEN 1 THEN 'purge_wins' ELSE 'restore_wins' END;
    SELECT * INTO v_board
    FROM public.create_board_p(
      'Carrera restaurar o purgar ' || v_scenario,
      'UTC',
      gen_random_uuid()
    );
    SELECT * INTO v_column
    FROM public.create_column_p(v_board.slug, v_board.id, 'Pendientes', 0);
    v_created := public.create_task_p(
      gen_random_uuid(), v_board.id, v_column.id, 'Tarea sintética de carrera ' || v_scenario
    );
    v_task_id := (v_created->>'task_id')::uuid;
    v_deleted := public.delete_task_p(gen_random_uuid(), v_board.slug, v_task_id);
    IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Could not prepare recovery race fixture: %', v_deleted;
    END IF;
    SELECT item.expires_at INTO STRICT v_expires_at
    FROM public.list_deleted_tasks_p(v_board.slug) AS item
    WHERE item.task_id = v_task_id;
    INSERT INTO public.issue14_task_recovery_race_fixture(
      scenario, board_id, board_slug, task_id, expires_at
    ) VALUES (
      v_scenario, v_board.id, v_board.slug, v_task_id, v_expires_at
    );
  END LOOP;
END;
$$;
COMMIT;

\echo 'PASS: authorized task deletion records a server timestamp and a 7x24h recovery deadline'
