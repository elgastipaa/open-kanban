\set ON_ERROR_STOP on

CREATE TABLE public.issue28_recovery_race_fixture (
  scenario text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  series_id uuid NOT NULL,
  series_revision bigint NOT NULL,
  job_id uuid,
  lease_token uuid
);
CREATE TABLE public.issue28_task_purge_race_fixture (
  scenario text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  series_id uuid NOT NULL,
  series_revision bigint NOT NULL,
  purge_at timestamptz NOT NULL
);

BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_series jsonb;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_task_id uuid;
  v_series_id uuid;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Worker/delete race #28', 'UTC', '42800000-0000-4000-8000-000000000230'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000231', v_board.id,
    v_column.id, 'Tarea de carrera', 'Fixture sintético', 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  IF public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000232', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date - 1), '{"due_on":1}'::jsonb
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Race fixture due date failed';
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000233', v_board.slug, v_task_id,
    current_date - 1, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  SELECT job.* INTO v_job
  FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
    AND job.scheduled_on = current_date AND job.state IN ('queued', 'retry_wait')
  ORDER BY job.created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Worker/delete fixture has no due job: %', v_series;
  END IF;
  INSERT INTO public.issue28_recovery_race_fixture VALUES (
    'worker_delete', v_board.id, v_board.slug, v_column.id, v_task_id,
    v_series_id, (v_series->>'series_revision')::bigint,
    v_job.id, '42800000-0000-4000-8000-000000000234'
  );

  SELECT * INTO v_board FROM public.create_board_p(
    'Delete/restore race #28', 'UTC', '42800000-0000-4000-8000-000000000235'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000236', v_board.id,
    v_column.id, 'Tarea recuperable', 'Fixture sintético', 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  IF public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000237', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Delete/restore fixture due date failed';
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000238', v_board.slug, v_task_id,
    current_date, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  INSERT INTO public.issue28_recovery_race_fixture VALUES (
    'delete_restore', v_board.id, v_board.slug, v_column.id, v_task_id,
    v_series_id, (v_series->>'series_revision')::bigint, NULL, NULL
  );
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_series jsonb;
  v_due_edit jsonb;
  v_deleted jsonb;
  v_task_id uuid;
  v_series_id uuid;
  v_purge_at timestamptz;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Purge first race #28', 'UTC', '42800000-0000-4000-8000-000000000590'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000591', v_board.id,
    v_column.id, 'Ocurrencia vencida purge-first', 'Fixture sintético', 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000592', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Purge-first due date setup failed: %', v_due_edit;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000593', v_board.slug, v_task_id,
    current_date, NULL, 4, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Purge-first series setup failed: %', v_series;
  END IF;
  v_series_id := (v_series->>'series_id')::uuid;
  v_deleted := public.delete_task_p(
    '42800000-0000-4000-8000-000000000594', v_board.slug, v_task_id,
    'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id
        AND deletion.parent_series_id = v_series_id
        AND deletion.cause = 'user_requested'
    )
    OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.series_id = v_series_id AND occurrence.task_id = v_task_id)
      IS DISTINCT FROM 'excluded' THEN
    RAISE EXCEPTION 'Purge-first fixture is not an excluded individual occurrence';
  END IF;
  v_purge_at := pg_catalog.clock_timestamp() + interval '2 hours';
  UPDATE public.task_deletions AS deletion
  SET deleted_at = v_purge_at - interval '169 hours',
      expires_at = v_purge_at - interval '1 hour'
  WHERE deletion.task_id = v_task_id;
  INSERT INTO public.issue28_task_purge_race_fixture VALUES (
    'purge_first', v_board.id, v_board.slug, v_column.id, v_task_id,
    v_series_id, (v_series->>'series_revision')::bigint, v_purge_at
  );

  SELECT * INTO v_board FROM public.create_board_p(
    'Delete first race #28', 'UTC', '42800000-0000-4000-8000-000000000600'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000601', v_board.id,
    v_column.id, 'Ocurrencia vencida delete-first', 'Fixture sintético', 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000602', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Delete-first due date setup failed: %', v_due_edit;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000603', v_board.slug, v_task_id,
    current_date, NULL, 4, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Delete-first series setup failed: %', v_series;
  END IF;
  v_series_id := (v_series->>'series_id')::uuid;
  v_deleted := public.delete_task_p(
    '42800000-0000-4000-8000-000000000604', v_board.slug, v_task_id,
    'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id
        AND deletion.parent_series_id = v_series_id
        AND deletion.cause = 'user_requested'
    )
    OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.series_id = v_series_id AND occurrence.task_id = v_task_id)
      IS DISTINCT FROM 'excluded' THEN
    RAISE EXCEPTION 'Delete-first fixture is not an excluded individual occurrence';
  END IF;
  v_purge_at := pg_catalog.clock_timestamp() + interval '2 hours';
  UPDATE public.task_deletions AS deletion
  SET deleted_at = v_purge_at - interval '169 hours',
      expires_at = v_purge_at - interval '1 hour'
  WHERE deletion.task_id = v_task_id;
  INSERT INTO public.issue28_task_purge_race_fixture VALUES (
    'delete_first', v_board.id, v_board.slug, v_column.id, v_task_id,
    v_series_id, (v_series->>'series_revision')::bigint, v_purge_at
  );
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_series jsonb;
  v_due_edit jsonb;
  v_deleted jsonb;
  v_task_id uuid;
  v_series_id uuid;
  v_purge_at timestamptz;
  v_index integer;
  v_scenario text;
BEGIN
  FOR v_index IN 1..2 LOOP
    v_scenario := CASE v_index
      WHEN 1 THEN 'restore_first'
      ELSE 'purge_first_restore'
    END;
    SELECT * INTO v_board FROM public.create_board_p(
      CASE v_index
        WHEN 1 THEN 'Restore first purge race #28'
        ELSE 'Purge first restore race #28'
      END,
      'UTC', pg_catalog.gen_random_uuid()
    );
    SELECT * INTO v_column FROM public.create_column_p(
      v_board.slug, v_board.id, 'Pendientes', 0
    );
    v_task := public.create_task_p(
      pg_catalog.gen_random_uuid(), v_board.id, v_column.id,
      'Ocurrencia borrada ' || v_scenario, 'Fixture sintético', 'medium'
    );
    v_task_id := (v_task->>'task_id')::uuid;
    v_due_edit := public.edit_task_fields_p(
      pg_catalog.gen_random_uuid(), v_board.slug, v_task_id,
      pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
    );
    IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Restore/purge fixture due date setup failed: %', v_due_edit;
    END IF;
    v_series := public.create_repetition_with_advance_p(
      pg_catalog.gen_random_uuid(), v_board.slug, v_task_id,
      current_date, NULL, 4, 2, false, NULL,
      '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
    );
    IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Restore/purge fixture series setup failed: %', v_series;
    END IF;
    v_series_id := (v_series->>'series_id')::uuid;
    v_deleted := public.delete_task_p(
      pg_catalog.gen_random_uuid(), v_board.slug, v_task_id, 'user_requested'
    );
    IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
      OR NOT EXISTS (
        SELECT 1 FROM public.task_deletions AS deletion
        WHERE deletion.task_id = v_task_id
          AND deletion.parent_series_id = v_series_id
          AND deletion.cause = 'user_requested'
          AND deletion.state = 'deleted'
      )
      OR EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
      OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.series_id = v_series_id AND occurrence.task_id = v_task_id)
        IS DISTINCT FROM 'excluded' THEN
      RAISE EXCEPTION 'Restore/purge fixture is not a deleted excluded occurrence';
    END IF;
    v_purge_at := pg_catalog.clock_timestamp() + interval '2 hours';
    UPDATE public.task_deletions AS deletion
    SET deleted_at = v_purge_at - interval '169 hours',
        expires_at = v_purge_at - interval '1 hour'
    WHERE deletion.task_id = v_task_id;
    INSERT INTO public.issue28_task_purge_race_fixture VALUES (
      v_scenario, v_board.id, v_board.slug, v_column.id, v_task_id,
      v_series_id, (v_series->>'series_revision')::bigint, v_purge_at
    );
  END LOOP;
END;
$$;
COMMIT;
\echo 'PASS: issue #28 concurrency fixtures created in disposable PostgreSQL.'
