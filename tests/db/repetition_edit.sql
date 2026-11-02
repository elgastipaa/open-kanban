\set ON_ERROR_STOP on

-- Issue #26 uses a real PostgreSQL cluster and synthetic identity. No
-- application environment or remote database is consulted.
INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue26@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '42600000-0000-4000-8000-000000000002',
  'issue26@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '52600000-0000-4000-8000-000000000002',
  '42600000-0000-4000-8000-000000000002', 'google', 'issue26-google-subject',
  '{"email":"issue26@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '42600000-0000-4000-8000-000000000002',
    google_subject = 'issue26-google-subject', state = 'active'
WHERE email = 'issue26@example.test';

CREATE TABLE public.issue26_repetition_race_ref (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  series_id uuid NOT NULL,
  revision bigint NOT NULL,
  job_id uuid NOT NULL,
  current_occurrence_id uuid NOT NULL,
  current_column_id uuid NOT NULL,
  current_due_on date NOT NULL,
  edit_start_on date NOT NULL,
  next_due_on date NOT NULL
);

BEGIN;
SELECT set_config('request.jwt.claim.sub', '42600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_new_column record;
  v_origin_column uuid;
  v_appearance_column uuid;
  v_created jsonb;
  v_due_edit jsonb;
  v_exception_message text;
  v_exception_detail text;
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_worker_result jsonb;
  v_edit_preview jsonb;
  v_edit_result jsonb;
  v_conflict jsonb;
  v_idempotent jsonb;
  v_task_before jsonb;
  v_history_before jsonb;
  v_history_after jsonb;
  v_template jsonb := '{"title":"Plantilla futura","description":"Descripción futura","priority":"urgent","assignee_id":null}'::jsonb;
  v_new_pattern jsonb := '{"frequency":"weekly","interval":1,"weekdays":[2,4]}'::jsonb;
  v_task_id uuid;
  v_second_task_id uuid;
  v_second_series_id uuid;
  v_new_task_id uuid;
  v_current_slots bigint;
  v_race_start_on date;
  v_edit_start_on date;
  v_pattern jsonb := '{"frequency":"weekly","interval":1,"weekdays":[1,3]}'::jsonb;
BEGIN
  IF public.repetition_minimum_separation_internal_p(
      '2026-01-31', '{"frequency":"monthly","interval":"2","day_of_month":31}'::jsonb
    ) IS DISTINCT FROM 59
    OR public.repetition_minimum_separation_internal_p(
      '2018-01-01', '{"frequency":"yearly","interval":"1","month":1,"ordinal":1,"weekday":1}'::jsonb
    ) IS DISTINCT FROM 364 THEN
    RAISE EXCEPTION 'Calendar minimum separation did not account for monthly clamping and yearly ordinals';
  END IF;
  SELECT * INTO v_board FROM public.create_board_p(
    'Edición de repetición #26', 'America/Argentina/Buenos_Aires',
    '26000000-0000-4000-8000-000000000001'
  );
  SELECT * INTO v_new_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Actuales', 0
  );
  v_origin_column := v_new_column.id;
  SELECT * INTO v_new_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Próximas', 1
  );
  v_appearance_column := v_new_column.id;

  v_created := public.create_task_p(
    '26000000-0000-4000-8000-000000000002',
    v_board.id,
    v_origin_column, 'Tarea actual', 'Descripción original', 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  UPDATE public.tasks AS task
  SET steps = '[{"id":"26000000-0000-4000-8000-000000000023","text":"Paso original","is_completed":true,"position":0,"version":2}]'::jsonb
  WHERE task.id = v_task_id;
  v_due_edit := public.edit_task_fields_p(
    '26000000-0000-4000-8000-000000000003', v_board.slug, v_task_id,
    '{"due_on":"2026-11-02"}'::jsonb, '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic task date setup failed: %', v_due_edit;
  END IF;

  v_created := public.create_task_p(
    '26000000-0000-4000-8000-000000000004',
    v_board.id,
    v_origin_column, 'X fuera de separación', NULL, 'low'
  );
  v_due_edit := public.edit_task_fields_p(
    '26000000-0000-4000-8000-000000000005', v_board.slug,
    (v_created->>'task_id')::uuid, '{"due_on":"2026-11-02"}'::jsonb,
    '{"due_on":1}'::jsonb
  );
  BEGIN
    PERFORM public.create_repetition_with_advance_p(
      '26000000-0000-4000-8000-000000000006', v_board.slug,
      (v_created->>'task_id')::uuid, '2026-11-02', NULL, 4, 2, false, NULL,
      v_pattern, 2
    );
    RAISE EXCEPTION 'Anticipation equal to the 2-day minimum separation was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
  BEGIN
    PERFORM public.create_repetition_with_advance_p(
      '26000000-0000-4000-8000-000000000022', v_board.slug,
      (v_created->>'task_id')::uuid, '2026-11-02', NULL, 4, 2, false, NULL,
      v_pattern, -1
    );
    RAISE EXCEPTION 'A negative anticipation was accepted';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;

  v_result := public.create_repetition_with_advance_p(
    '26000000-0000-4000-8000-000000000007', v_board.slug, v_task_id,
    '2026-11-02', NULL, 4, 2, false, NULL, v_pattern, 1, v_appearance_column
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->>'next_due_on' IS DISTINCT FROM '2026-11-04' THEN
    RAISE EXCEPTION 'A valid one-day anticipation did not create the weekly series: %', v_result;
  END IF;
  v_idempotent := public.create_repetition_with_advance_p(
    '26000000-0000-4000-8000-000000000007', v_board.slug, v_task_id,
    '2026-11-02', NULL, 4, 2, false, NULL, v_pattern, 1, v_appearance_column
  );
  IF v_idempotent->>'status' IS DISTINCT FROM 'confirmed'
    OR v_idempotent->>'series_id' IS DISTINCT FROM v_result->>'series_id' THEN
    RAISE EXCEPTION 'An identical retry did not return the same created series: %', v_idempotent;
  END IF;
  BEGIN
    PERFORM public.create_repetition_with_advance_p(
      '26000000-0000-4000-8000-000000000007', v_board.slug, v_task_id,
      '2026-11-02', NULL, 4, 2, false, NULL, v_pattern, 1, v_origin_column
    );
    RAISE EXCEPTION 'Reusing a create operation with another appearance column was accepted';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    NULL;
  END;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid;
  SELECT job.* INTO v_job
  FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
  ORDER BY job.created_at DESC LIMIT 1;
  IF v_series.advance_days IS DISTINCT FROM 1
    OR v_job.available_at IS DISTINCT FROM '2026-11-03 03:00:00+00'::timestamptz
    OR v_job.scheduled_on IS DISTINCT FROM '2026-11-04'::date THEN
    RAISE EXCEPTION 'The job did not use the anticipation window in board-local time: series %, job %',
      v_series, v_job;
  END IF;

  v_due_edit := public.edit_task_fields_p(
    '26000000-0000-4000-8000-000000000024', v_board.slug, v_task_id,
    '{"due_on":"2026-11-03"}'::jsonb, '{"due_on":2}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT occurrence.due_on_override
        FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.id = v_series.current_occurrence_id)
      IS DISTINCT FROM '2026-11-03'::date THEN
    RAISE EXCEPTION 'An exception strictly before the next occurrence was not accepted: %', v_due_edit;
  END IF;
  BEGIN
    PERFORM public.edit_task_fields_p(
      '26000000-0000-4000-8000-000000000025', v_board.slug, v_task_id,
      '{"due_on":"2026-11-04"}'::jsonb, '{"due_on":3}'::jsonb
    );
    RAISE EXCEPTION 'An exception on the next occurrence date was accepted';
  EXCEPTION WHEN SQLSTATE 'P2301' THEN
    GET STACKED DIAGNOSTICS
      v_exception_message = MESSAGE_TEXT,
      v_exception_detail = PG_EXCEPTION_DETAIL;
    IF v_exception_message NOT LIKE 'La fecha excepcional debe ser anterior%'
      OR v_exception_detail IS DISTINCT FROM '2026-11-04' THEN
      RAISE EXCEPTION 'The strict exception boundary returned the wrong diagnostic: %, %',
        v_exception_message, v_exception_detail;
    END IF;
  END;
  v_worker_result := public.advance_daily_repetition_internal_p(
    v_job, '2026-11-03 02:59:00+00'::timestamptz
  );
  IF v_worker_result->>'status' IS DISTINCT FROM 'not_due' THEN
    RAISE EXCEPTION 'The worker activated before the board-local appearance date: %', v_worker_result;
  END IF;
  SELECT job.* INTO v_job FROM public.daily_repetition_jobs AS job WHERE job.id = v_job.id;
  v_worker_result := public.advance_daily_repetition_internal_p(
    v_job, '2026-11-03 03:00:00+00'::timestamptz
  );
  IF v_worker_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_worker_result->>'occurrence_on' IS DISTINCT FROM '2026-11-04' THEN
    RAISE EXCEPTION 'The worker did not activate the next occurrence at the beginning of its window: %',
      v_worker_result;
  END IF;
  v_new_task_id := (v_worker_result->>'task_id')::uuid;
  SELECT count(*) INTO v_current_slots
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series.id AND occurrence.state = 'current';
  IF v_current_slots <> 1
    OR (SELECT task.column_id FROM public.tasks AS task WHERE task.id = v_task_id)
      IS DISTINCT FROM v_origin_column
    OR (SELECT task.due_on FROM public.tasks AS task WHERE task.id = v_task_id)
      IS DISTINCT FROM '2026-11-03'::date
    OR (SELECT task.column_id FROM public.tasks AS task WHERE task.id = v_new_task_id)
      IS DISTINCT FROM v_appearance_column
    OR (SELECT task.due_on FROM public.tasks AS task WHERE task.id = v_new_task_id)
      IS DISTINCT FROM '2026-11-04'::date THEN
    RAISE EXCEPTION 'Anticipation changed task placement or left duplicate pending occurrences: current %, new %, slots %',
      (SELECT task.column_id FROM public.tasks AS task WHERE task.id = v_task_id),
      (SELECT task.column_id FROM public.tasks AS task WHERE task.id = v_new_task_id),
      v_current_slots;
  END IF;
  IF (SELECT task.steps->0->>'text' FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS DISTINCT FROM 'Paso original'
    OR (SELECT (task.steps->0->>'is_completed')::boolean FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS DISTINCT FROM false
    OR (SELECT task.steps->0->>'id' FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS NOT DISTINCT FROM
      '26000000-0000-4000-8000-000000000023' THEN
    RAISE EXCEPTION 'A generated occurrence did not receive its own unchecked checklist template';
  END IF;

  SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
  WHERE series.id = v_series.id;
  SELECT job.* INTO v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.series_revision = v_series.revision;
  SELECT pg_catalog.to_jsonb(task) INTO v_task_before
  FROM public.tasks AS task WHERE task.id = v_new_task_id;
  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'occurrence_on', occurrence.occurrence_on, 'task_id', occurrence.task_id,
    'state', occurrence.state, 'due_on_override', occurrence.due_on_override
  ) ORDER BY occurrence.occurrence_on, occurrence.id), '[]'::jsonb)
  INTO v_history_before FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series.id
    AND occurrence.occurrence_on <= v_series.latest_occurrence_on;

  -- Synthetic future exclusions exercise the preview/confirmation contract
  -- through the RPC while keeping the current and past occurrences intact.
  INSERT INTO public.daily_repetition_occurrences(series_id, occurrence_on, task_id, state)
  VALUES
    (v_series.id, '2026-11-09', '26000000-0000-4000-8000-000000000020', 'excluded'),
    (v_series.id, '2026-11-10', '26000000-0000-4000-8000-000000000021', 'excluded');

  v_template := v_template || jsonb_build_object(
    'steps', '[{"text":"Paso de plantilla actualizado","position":0}]'::jsonb
  );

  v_edit_preview := public.preview_repetition_edit_p(
    v_board.slug, v_new_task_id, '2026-11-09', 'count', 2, NULL,
    v_pattern, 1, v_appearance_column, v_template, false
  );
  IF v_edit_preview->>'status' IS DISTINCT FROM 'available'
    OR coalesce((v_edit_preview->>'requires_date_choice')::boolean, true)
    OR v_edit_preview->'future_dates' IS DISTINCT FROM
      '["2026-11-09","2026-11-11"]'::jsonb
    OR v_edit_preview->>'final_on' IS DISTINCT FROM '2026-11-11'
    OR v_edit_preview->'preserved_exclusion_dates' IS DISTINCT FROM '["2026-11-09"]'::jsonb
    OR v_edit_preview->'removed_exclusion_dates' IS DISTINCT FROM '["2026-11-10"]'::jsonb
    OR v_edit_preview->'template_snapshot'->'steps' IS DISTINCT FROM
      '[{"text":"Paso de plantilla actualizado","position":0}]'::jsonb
    OR v_edit_preview->>'time_zone' IS DISTINCT FROM 'America/Argentina/Buenos_Aires' THEN
    RAISE EXCEPTION 'The edit preview did not show the future template, final, zone and exclusions: %',
      v_edit_preview;
  END IF;
  v_edit_result := public.edit_repetition_p(
    '26000000-0000-4000-8000-000000000008', v_board.slug, v_new_task_id,
    v_series.revision, '2026-11-09', 'count', 2, NULL, v_pattern, 1,
    v_appearance_column, v_template, false
  );
  IF v_edit_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_edit_result->>'next_due_on' IS DISTINCT FROM '2026-11-09'
    OR v_edit_result->>'final_on' IS DISTINCT FROM '2026-11-11'
    OR (v_edit_result->>'occurrence_limit')::bigint IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Editing only the template did not preserve the 2 remaining future dates: %',
      v_edit_result;
  END IF;

  SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
  WHERE series.id = (v_edit_result->>'series_id')::uuid;
  SELECT pg_catalog.to_jsonb(task) INTO v_created
  FROM public.tasks AS task WHERE task.id = v_new_task_id;
  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'occurrence_on', occurrence.occurrence_on, 'task_id', occurrence.task_id,
    'state', occurrence.state, 'due_on_override', occurrence.due_on_override
  ) ORDER BY occurrence.occurrence_on, occurrence.id), '[]'::jsonb)
  INTO v_history_after FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series.id
    AND occurrence.occurrence_on <= v_series.latest_occurrence_on;
  IF v_created IS DISTINCT FROM v_task_before
    OR v_history_after IS DISTINCT FROM v_history_before
    OR v_series.start_on IS DISTINCT FROM '2026-11-09'::date
    OR v_series.consumed_count IS DISTINCT FROM 0
    OR v_series.occurrence_limit IS DISTINCT FROM 2
    OR v_series.appearance_column_id IS DISTINCT FROM v_appearance_column
    OR v_series.advance_days IS DISTINCT FROM 1
    OR v_series.template_snapshot->>'title' IS DISTINCT FROM 'Plantilla futura'
    OR v_series.template_snapshot->'steps' IS DISTINCT FROM
      '[{"text":"Paso de plantilla actualizado","position":0}]'::jsonb
    OR (SELECT task.steps->0->>'text' FROM public.tasks AS task
        WHERE task.id = v_new_task_id) IS DISTINCT FROM 'Paso original'
    OR (SELECT (task.steps->0->>'is_completed')::boolean FROM public.tasks AS task
        WHERE task.id = v_new_task_id) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Series editing changed current/history or failed to update future settings: %, task %, history %',
      v_series, v_created, v_history_after;
  END IF;
  IF (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.task_id = '26000000-0000-4000-8000-000000000020') IS DISTINCT FROM 'excluded'
    OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.task_id = '26000000-0000-4000-8000-000000000021') IS DISTINCT FROM 'retired' THEN
    RAISE EXCEPTION 'Compatible exclusion was not preserved or an incompatible exclusion was not retired';
  END IF;

  SELECT job.* INTO v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.series_revision = v_series.revision;
  IF v_job.scheduled_on IS DISTINCT FROM '2026-11-09'::date
    OR v_job.available_at IS DISTINCT FROM '2026-11-08 03:00:00+00'::timestamptz THEN
    RAISE EXCEPTION 'The edited job did not carry the new revision and anticipation window: %', v_job;
  END IF;

  v_edit_result := public.edit_repetition_p(
    '26000000-0000-4000-8000-000000000009', v_board.slug, v_new_task_id,
    v_series.revision, '2026-11-09', 'count', 3, NULL, v_pattern, 1,
    v_appearance_column, v_template, false
  );
  IF v_edit_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_edit_result->>'final_on' IS DISTINCT FROM '2026-11-16'
    OR (v_edit_result->>'occurrence_limit')::bigint IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'Editing the final count did not schedule exactly three future dates: %',
      v_edit_result;
  END IF;

  SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
  WHERE series.id = (v_edit_result->>'series_id')::uuid;
  SELECT job.* INTO v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.series_revision = v_series.revision - 1;
  v_worker_result := public.advance_daily_repetition_internal_p(
    v_job, '2026-11-08 03:00:00+00'::timestamptz
  );
  IF v_worker_result->>'status' IS DISTINCT FROM 'superseded' THEN
    RAISE EXCEPTION 'A job from the previous series revision applied after editing: %', v_worker_result;
  END IF;
  v_conflict := public.edit_repetition_p(
    '26000000-0000-4000-8000-000000000010', v_board.slug, v_new_task_id,
    v_series.revision - 1, '2026-11-09', 'count', 3, NULL, v_pattern, 1,
    v_appearance_column, v_template, false
  );
  IF v_conflict->>'status' IS DISTINCT FROM 'conflict'
    OR (v_conflict->>'series_revision')::bigint IS DISTINCT FROM v_series.revision THEN
    RAISE EXCEPTION 'A stale edit did not return a conflict for review: %', v_conflict;
  END IF;

  v_edit_preview := public.preview_repetition_edit_p(
    v_board.slug, v_new_task_id, '2026-11-09', 'count', 3, NULL,
    v_new_pattern, 1, v_appearance_column, v_template, false
  );
  IF v_edit_preview->>'status' IS DISTINCT FROM 'available'
    OR v_edit_preview->>'requires_date_choice' IS DISTINCT FROM 'true'
    OR v_edit_preview->>'selected_date_compatible' IS DISTINCT FROM 'false'
    OR v_edit_preview->>'proposed_start_on' IS DISTINCT FROM '2026-11-10' THEN
    RAISE EXCEPTION 'An incompatible first date did not require an explicit choice: %', v_edit_preview;
  END IF;
  v_edit_preview := public.preview_repetition_edit_p(
    v_board.slug, v_new_task_id, '2026-11-10', 'count', 3, NULL,
    v_new_pattern, 1, v_appearance_column, v_template, true
  );
  IF v_edit_preview->>'status' IS DISTINCT FROM 'available'
    OR v_edit_preview->>'requires_date_choice' IS DISTINCT FROM 'false'
    OR v_edit_preview->'future_dates' IS DISTINCT FROM
      '["2026-11-10","2026-11-12","2026-11-17"]'::jsonb THEN
    RAISE EXCEPTION 'Confirming the compatible first date did not produce the selected calendar: %',
      v_edit_preview;
  END IF;
  v_edit_result := public.edit_repetition_p(
    '26000000-0000-4000-8000-000000000011', v_board.slug, v_new_task_id,
    v_series.revision, '2026-11-10', 'count', 3, NULL, v_new_pattern, 1,
    v_appearance_column, v_template, true
  );
  IF v_edit_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_edit_result->>'next_due_on' IS DISTINCT FROM '2026-11-10'
    OR v_edit_result->>'final_on' IS DISTINCT FROM '2026-11-17' THEN
    RAISE EXCEPTION 'Confirming the incompatible first date failed to edit upcoming occurrences: %',
      v_edit_result;
  END IF;

  v_due_edit := public.edit_task_fields_p(
    '26000000-0000-4000-8000-000000000012', v_board.slug, v_new_task_id,
    '{"title":"Título editado solo en la actual"}'::jsonb, '{"title":1}'::jsonb
  );
  SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
  WHERE series.id = (v_edit_result->>'series_id')::uuid;
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed'
    OR v_series.template_snapshot->>'title' IS DISTINCT FROM 'Plantilla futura'
    OR v_series.occurrence_limit IS DISTINCT FROM 3
    OR v_series.consumed_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'Editing only the current occurrence rewrote the template or reset the future count: % / %',
      v_due_edit, v_series;
  END IF;
  SELECT job.* INTO v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.series_revision = v_series.revision AND job.state = 'queued';
  v_worker_result := public.advance_daily_repetition_internal_p(
    v_job, '2026-11-09 03:00:00+00'::timestamptz
  );
  IF v_worker_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_worker_result->>'occurrence_on' IS DISTINCT FROM '2026-11-10' THEN
    RAISE EXCEPTION 'The edited template did not generate its next occurrence: %', v_worker_result;
  END IF;
  SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
  WHERE series.id = v_series.id;
  IF (SELECT task.steps->0->>'text' FROM public.tasks AS task
      WHERE task.id = (v_worker_result->>'task_id')::uuid)
        IS DISTINCT FROM 'Paso de plantilla actualizado'
    OR (SELECT (task.steps->0->>'is_completed')::boolean FROM public.tasks AS task
      WHERE task.id = (v_worker_result->>'task_id')::uuid) IS DISTINCT FROM false
    OR (SELECT task.steps->0->>'position' FROM public.tasks AS task
      WHERE task.id = (v_worker_result->>'task_id')::uuid) IS DISTINCT FROM '0'
    OR (SELECT task.steps->0->>'version' FROM public.tasks AS task
      WHERE task.id = (v_worker_result->>'task_id')::uuid) IS DISTINCT FROM '1'
    OR (SELECT task.steps->0->>'id' FROM public.tasks AS task
      WHERE task.id = (v_worker_result->>'task_id')::uuid)
      IS NOT DISTINCT FROM (SELECT task.steps->0->>'id' FROM public.tasks AS task
        WHERE task.id = v_new_task_id)
    OR (SELECT task.steps->0->>'text' FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS DISTINCT FROM 'Paso original'
    OR (SELECT task.column_id FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS DISTINCT FROM v_appearance_column
    OR (SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series.id AND occurrence.state = 'current') <> 1 THEN
    RAISE EXCEPTION 'The edited template did not create its own unchecked checklist steps or changed the current task';
  END IF;

  SELECT * INTO v_board FROM public.create_board_p(
    'Issue 26 concurrent edit worker', 'UTC',
    '26000000-0000-4000-8000-000000000099'
  );
  SELECT * INTO v_new_column FROM public.create_column_p(v_board.slug, v_board.id, 'Actual', 0);
  v_created := public.create_task_p(
    '26000000-0000-4000-8000-000000000098', v_board.id, v_new_column.id,
    'Current concurrent task', NULL, 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_edit_start_on := public.board_calendar_day('UTC', pg_catalog.clock_timestamp()) + 1;
  v_race_start_on := v_edit_start_on - 3;
  v_due_edit := public.edit_task_fields_p(
    '26000000-0000-4000-8000-000000000097', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', v_race_start_on), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Concurrent fixture current date setup failed: %', v_due_edit;
  END IF;
  v_result := public.create_repetition_with_advance_p(
    '26000000-0000-4000-8000-000000000096', v_board.slug, v_task_id,
    v_race_start_on, NULL, 4, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_new_column.id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Concurrent fixture series setup failed: %', v_result;
  END IF;
  SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid;
  SELECT job.* INTO v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.series_revision = v_series.revision AND job.state = 'queued';
  IF NOT FOUND OR v_series.next_due_on IS DISTINCT FROM v_race_start_on + 1 THEN
    RAISE EXCEPTION 'Concurrent fixture has no current-revision job: %, %', v_series, v_job;
  END IF;
  INSERT INTO public.issue26_repetition_race_ref(
    board_id, board_slug, task_id, series_id, revision, job_id,
    current_occurrence_id, current_column_id, current_due_on,
    edit_start_on, next_due_on
  ) VALUES (
    v_board.id, v_board.slug, v_task_id, v_series.id, v_series.revision,
    v_job.id, v_series.current_occurrence_id, v_new_column.id,
    v_race_start_on, v_edit_start_on, v_series.next_due_on
  );
END;
$$;
COMMIT;
