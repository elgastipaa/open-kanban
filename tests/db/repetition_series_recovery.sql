\set ON_ERROR_STOP on

-- Issue #28: complete series deletion is reversible for seven days, and a
-- column deletion resolves future appearance without changing the series rule.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_source record;
  v_destination record;
  v_task jsonb;
  v_series jsonb;
  v_preview jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_column_preview jsonb;
  v_column_deleted jsonb;
  v_column_restored jsonb;
  v_series_id uuid;
  v_task_id uuid;
  v_task_count integer;
  v_next_due_on date;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Series recovery #28', 'UTC', '42800000-0000-4000-8000-000000000040'
  );
  SELECT * INTO v_source FROM public.create_column_p(
    v_board.slug, v_board.id, 'Aparición', 0
  );
  SELECT * INTO v_destination FROM public.create_column_p(
    v_board.slug, v_board.id, 'Respaldo', 1
  );
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000041', v_board.id,
    v_source.id, 'Tarea de la serie', 'Texto recuperable por siete días', 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  IF public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000042', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic task due date setup failed';
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000043', v_board.slug, v_task_id,
    current_date, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_source.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic repetition setup failed: %', v_series;
  END IF;
  v_series_id := (v_series->>'series_id')::uuid;
  SELECT series.next_due_on INTO v_next_due_on
  FROM public.daily_repetition_series AS series WHERE series.id = v_series_id;

  v_preview := public.preview_delete_repetition_series_p(v_board.slug, v_series_id);
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'series_id' IS DISTINCT FROM v_series_id::text
    OR v_preview->>'occurrence_count' IS DISTINCT FROM '1'
    OR v_preview->>'state' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Full-series deletion preview omitted its scope: %', v_preview;
  END IF;

  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000044', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint, true
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_deleted->>'expires_at')::timestamptz
      IS DISTINCT FROM (v_deleted->>'deleted_at')::timestamptz + interval '168 hours' THEN
    RAISE EXCEPTION 'Complete series deletion lacked its exact recovery window: %', v_deleted;
  END IF;
  v_series := public.list_deleted_repetition_series_p(v_board.id);
  IF v_series->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_series->'series') <> 1
    OR v_series->'series'->0->>'can_restore' IS DISTINCT FROM 'true'
    OR v_series->'series'->0->>'generation_available' IS DISTINCT FROM 'true'
    OR v_series->'series'->0->>'appearance_column_available' IS DISTINCT FROM 'true'
    OR v_series->'series'->0->>'child_columns_available' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Deleted-series recovery list omitted current eligibility: %', v_series;
  END IF;
  IF EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id AND deletion.state = 'deleted'
        AND deletion.cause = 'series_requested'
        AND deletion.parent_series_id = v_series_id
    ) THEN
    RAISE EXCEPTION 'Deleting a series did not tombstone its live occurrence by parent cause';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.daily_repetition_jobs AS job
    WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
      AND job.state IN ('queued', 'retry_wait', 'leased')
  ) THEN
    RAISE EXCEPTION 'Deleting a series left an advance job runnable';
  END IF;
  IF jsonb_array_length(public.list_repetition_series_p(
    v_board.id, NULL, NULL, 20, NULL
  )->'series') <> 0 THEN
    RAISE EXCEPTION 'A deleted series remained in the accessible series list';
  END IF;

  v_restored := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000045', v_board.slug, v_series_id,
    v_source.id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id AND series.state = 'active'
        AND series.next_due_on = v_next_due_on
    ) THEN
    RAISE EXCEPTION 'Series recovery did not restore the same active schedule: %', v_restored;
  END IF;

  v_column_preview := public.preview_delete_column_p(v_board.slug, v_source.id);
  IF v_column_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_column_preview->>'series_count' IS DISTINCT FROM '1' THEN
    RAISE EXCEPTION 'Column deletion preview omitted its future-appearance series: %', v_column_preview;
  END IF;
  v_column_deleted := public.delete_column_p(
    '42800000-0000-4000-8000-000000000046', v_board.slug, v_source.id,
    NULL, (v_column_preview->>'task_order_version')::bigint
  );
  IF v_column_deleted->>'status' IS DISTINCT FROM 'needs_destination' THEN
    RAISE EXCEPTION 'Column deletion did not require a future appearance destination: %', v_column_deleted;
  END IF;
  v_column_deleted := public.delete_column_p(
    '42800000-0000-4000-8000-000000000047', v_board.slug, v_source.id,
    v_destination.id, (v_column_preview->>'task_order_version')::bigint,
    v_column_preview->>'series_token'
  );
  IF v_column_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Column deletion with an appearance destination failed: %', v_column_deleted;
  END IF;
  IF (SELECT series.appearance_column_id FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id) IS DISTINCT FROM v_destination.id THEN
    RAISE EXCEPTION 'Column deletion did not retarget only future appearance';
  END IF;
  v_column_restored := public.restore_column_p(
    '42800000-0000-4000-8000-000000000048', v_board.slug, v_source.id
  );
  IF v_column_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT series.appearance_column_id FROM public.daily_repetition_series AS series
        WHERE series.id = v_series_id) IS DISTINCT FROM v_destination.id THEN
    RAISE EXCEPTION 'Restoring a column reversed its confirmed future-appearance move';
  END IF;
  SELECT count(*) INTO v_task_count FROM public.tasks AS task
  WHERE task.id = v_task_id AND task.column_id = v_destination.id;
  IF v_task_count <> 1 THEN
    RAISE EXCEPTION 'The task in the removed column was not moved to its chosen destination';
  END IF;
END;
$$;
COMMIT;

-- If the future-appearance column is removed while the series is in recovery,
-- the owner may choose a current column. The deleted occurrence keeps its own
-- original task column.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_appearance record;
  v_task_column record;
  v_destination record;
  v_created jsonb;
  v_series jsonb;
  v_deleted jsonb;
  v_column_preview jsonb;
  v_column_deleted jsonb;
  v_recovery_list jsonb;
  v_restored jsonb;
  v_task_id uuid;
  v_series_id uuid;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Deleted appearance recovery #28', 'UTC', '42800000-0000-4000-8000-000000000180'
  );
  SELECT * INTO v_appearance FROM public.create_column_p(
    v_board.slug, v_board.id, 'Aparición futura', 0
  );
  SELECT * INTO v_task_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Tarjeta vigente', 1
  );
  SELECT * INTO v_destination FROM public.create_column_p(
    v_board.slug, v_board.id, 'Destino de recuperación', 2
  );
  v_created := public.create_task_p(
    '42800000-0000-4000-8000-000000000181', v_board.id,
    v_task_column.id, 'Tarea reprogramada', 'Mantener su columna actual', 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  IF public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000182', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic appearance task date setup failed';
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000183', v_board.slug, v_task_id,
    current_date, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_appearance.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000184', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint, true
  );
  v_column_preview := public.preview_delete_column_p(v_board.slug, v_appearance.id);
  v_column_deleted := public.delete_column_p(
    '42800000-0000-4000-8000-000000000185', v_board.slug, v_appearance.id,
    NULL, (v_column_preview->>'task_order_version')::bigint
  );
  v_recovery_list := public.list_deleted_repetition_series_p(v_board.id);
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_column_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_recovery_list->'series'->0->>'can_restore' IS DISTINCT FROM 'true'
    OR v_recovery_list->'series'->0->>'appearance_column_available' IS DISTINCT FROM 'false'
    OR v_recovery_list->'series'->0->>'child_columns_available' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Deleted appearance column did not expose a selectable series recovery: % / % / %',
      v_deleted, v_column_deleted, v_recovery_list;
  END IF;
  v_restored := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000186', v_board.slug, v_series_id,
    v_destination.id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT series.appearance_column_id FROM public.daily_repetition_series AS series
        WHERE series.id = v_series_id) IS DISTINCT FROM v_destination.id
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task
                   WHERE task.id = v_task_id AND task.column_id = v_task_column.id) THEN
    RAISE EXCEPTION 'Series recovery did not use selected appearance while preserving task placement: %',
      v_restored;
  END IF;
END;
$$;
COMMIT;

-- Recovery after downtime creates only the latest valid finite occurrence.
-- If that last date was explicitly excluded, the series stays finished and
-- does not substitute an earlier missed date.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_due_edit jsonb;
  v_series jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_job_result jsonb;
  v_task_id uuid;
  v_series_id uuid;
  v_last_task_id uuid;
  v_start_on date := current_date - ((extract(isodow FROM current_date)::integer - 1)) - 14;
  v_pattern jsonb := pg_catalog.jsonb_build_object(
    'frequency', 'weekly', 'interval', 1,
    'weekdays', pg_catalog.jsonb_build_array(1)
  );
  v_now timestamptz := current_date::timestamptz + interval '12 hours';
  v_occurrence_count integer;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Finite recovery #28', 'UTC', '42800000-0000-4000-8000-000000000090'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000091', v_board.id,
    v_column.id, 'Primera fecha válida', 'La fecha final se calcula', 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000092', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', v_start_on), '{"due_on":1}'::jsonb
  );
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000093', v_board.slug, v_task_id,
    v_start_on, NULL, 3, 2, false, NULL, v_pattern, 0, v_column.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000094', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint, true
  );
  v_restored := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000095', v_board.slug, v_series_id, NULL
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Finite past series recovery failed: % / %', v_deleted, v_restored;
  END IF;
  UPDATE public.daily_repetition_jobs AS job
  SET state = 'leased', lease_token = '42800000-0000-4000-8000-000000000096',
      lease_expires_at = v_now + interval '5 minutes', available_at = v_now,
      attempt_count = job.attempt_count + 1
  WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait')
  RETURNING job.* INTO v_job;
  IF NOT FOUND THEN RAISE EXCEPTION 'Restored finite series has no reconcile job'; END IF;
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  v_job_result := public.process_daily_repetition_job_internal_p(
    v_job.id, v_job.lease_token, v_now
  );
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  SELECT count(*) INTO v_occurrence_count
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_id;
  IF v_job_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_occurrence_count <> 2
    OR EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id
        AND occurrence.occurrence_on NOT IN (v_start_on, current_date)
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id
        AND occurrence.occurrence_on = current_date AND occurrence.state = 'current'
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id AND series.state = 'finished'
        AND series.consumed_count = 3 AND series.latest_occurrence_on = current_date
        AND series.next_due_on IS NULL
    ) THEN
    RAISE EXCEPTION 'Finite recovery created intermediate or extended dates: %', v_job_result;
  END IF;

  v_start_on := v_start_on - 7;
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000097', v_board.id,
    v_column.id, 'Ocurrencia con final excluido', 'No crear sustituta', 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000098', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', v_start_on), '{"due_on":1}'::jsonb
  );
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000099', v_board.slug, v_task_id,
    v_start_on, NULL, 3, 2, false, NULL, v_pattern, 0, v_column.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  UPDATE public.daily_repetition_jobs AS job
  SET state = 'leased', lease_token = '42800000-0000-4000-8000-000000000100',
      lease_expires_at = v_now + interval '5 minutes', available_at = v_now,
      attempt_count = job.attempt_count + 1
  WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait')
  RETURNING job.* INTO v_job;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected a final-date worker job'; END IF;
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  v_job_result := public.process_daily_repetition_job_internal_p(
    v_job.id, v_job.lease_token, v_now
  );
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  SELECT occurrence.task_id INTO v_last_task_id
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_id AND occurrence.state = 'current';
  IF v_job_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_last_task_id IS NULL
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id AND series.state = 'finished'
        AND series.consumed_count = 3 AND series.next_due_on IS NULL
    ) THEN
    RAISE EXCEPTION 'Synthetic final occurrence did not finish its finite series';
  END IF;
  IF public.delete_task_p(
    '42800000-0000-4000-8000-000000000101', v_board.slug, v_last_task_id,
    'user_requested'
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Excluding the finite final occurrence failed';
  END IF;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000102', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint + 1, true
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Deleting a finite series with excluded final slot failed: %', v_deleted;
  END IF;
  v_restored := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000103', v_board.slug, v_series_id, NULL
  );
  SELECT count(*) INTO v_occurrence_count
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_id;
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR v_occurrence_count <> 2
    OR EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id
        AND occurrence.occurrence_on = v_start_on + 7
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id
        AND occurrence.occurrence_on = v_start_on + 14
        AND occurrence.state = 'excluded'
    )
    OR EXISTS (
      SELECT 1 FROM public.daily_repetition_jobs AS job
      WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
        AND job.state IN ('queued', 'retry_wait', 'leased')
    ) THEN
    RAISE EXCEPTION 'An excluded finite final slot was replaced or extended';
  END IF;
END;
$$;
COMMIT;

-- Deleting a historical occurrence records its own exclusion. Restoring it
-- after a later slot is current leaves it historical and does not move the
-- series pointer or its next due date backwards.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_created jsonb;
  v_due_edit jsonb;
  v_series jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_task_id uuid;
  v_current_task_id uuid;
  v_current_occurrence_id uuid;
  v_series_id uuid;
  v_next_due date;
  v_now timestamptz := current_date::timestamptz + interval '12 hours';
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Occurrence recovery #28', 'UTC', '42800000-0000-4000-8000-000000000050'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_created := public.create_task_p(
    '42800000-0000-4000-8000-000000000051', v_board.id,
    v_column.id, 'Primera ocurrencia', 'Se recupera como historial', 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000052', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date - 1), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic prior task date setup failed: %', v_due_edit;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000053', v_board.slug, v_task_id,
    current_date - 1, NULL, 4, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic occurrence series setup failed: %', v_series;
  END IF;
  v_series_id := (v_series->>'series_id')::uuid;
  UPDATE public.daily_repetition_jobs AS job
  SET state = 'leased', lease_token = '42800000-0000-4000-8000-000000000054',
      lease_expires_at = v_now + interval '5 minutes', available_at = v_now,
      attempt_count = job.attempt_count + 1
  WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait')
  RETURNING job.* INTO v_job;
  IF NOT FOUND THEN RAISE EXCEPTION 'Expected a scheduled occurrence job'; END IF;
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  IF public.process_daily_repetition_job_internal_p(
    v_job.id, v_job.lease_token, v_now
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The next occurrence did not materialize';
  END IF;
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  SELECT series.current_occurrence_id, series.next_due_on,
    occurrence.task_id
  INTO v_current_occurrence_id, v_next_due, v_current_task_id
  FROM public.daily_repetition_series AS series
  JOIN public.daily_repetition_occurrences AS occurrence
    ON occurrence.id = series.current_occurrence_id
  WHERE series.id = v_series_id;
  IF v_current_task_id = v_task_id THEN
    RAISE EXCEPTION 'A later occurrence did not replace the first slot';
  END IF;

  v_deleted := public.delete_task_p(
    '42800000-0000-4000-8000-000000000055', v_board.slug, v_task_id,
    'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.series_id = v_series_id
          AND occurrence.task_id = v_task_id) IS DISTINCT FROM 'excluded'
    OR (SELECT series.current_occurrence_id FROM public.daily_repetition_series AS series
        WHERE series.id = v_series_id) IS DISTINCT FROM v_current_occurrence_id
    OR (SELECT series.next_due_on FROM public.daily_repetition_series AS series
        WHERE series.id = v_series_id) IS DISTINCT FROM v_next_due THEN
    RAISE EXCEPTION 'Deleting the earlier occurrence moved the active slot or next date';
  END IF;
  v_restored := public.restore_task_internal_p(
    '42800000-0000-4000-8000-000000000056', v_board.slug, v_task_id,
    v_column.id, clock_timestamp()
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.series_id = v_series_id
          AND occurrence.task_id = v_task_id) IS DISTINCT FROM 'replaced'
    OR (SELECT series.current_occurrence_id FROM public.daily_repetition_series AS series
        WHERE series.id = v_series_id) IS DISTINCT FROM v_current_occurrence_id
    OR (SELECT series.next_due_on FROM public.daily_repetition_series AS series
        WHERE series.id = v_series_id) IS DISTINCT FROM v_next_due THEN
    RAISE EXCEPTION 'Restoring an earlier occurrence reactivated it or moved the schedule: %',
      v_restored;
  END IF;
END;
$$;
COMMIT;

-- Parent restoration is required before its child task; separately deleted
-- children keep their own cause and remain absent after series recovery.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_created jsonb;
  v_due_edit jsonb;
  v_series jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_task_id uuid;
  v_series_id uuid;
  v_parent_blocked boolean := false;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Series parent recovery #28', 'UTC', '42800000-0000-4000-8000-000000000060'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_created := public.create_task_p(
    '42800000-0000-4000-8000-000000000061', v_board.id,
    v_column.id, 'Hija de la serie', 'Solo se recupera con su padre', 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000062', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic parent task date setup failed';
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000063', v_board.slug, v_task_id,
    current_date, NULL, 3, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000064', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint, true
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT count(*) FROM public.list_deleted_tasks_p(v_board.slug)
        WHERE task_id = v_task_id) <> 0
    OR (SELECT count(*) FROM pg_catalog.jsonb_array_elements(
          public.list_deleted_repetition_series_p(NULL)->'series'
        ) AS item(value)
        WHERE item.value->>'series_id' = v_series_id::text) <> 1 THEN
    RAISE EXCEPTION 'Series child leaked into task trash or parent recovery list';
  END IF;

  BEGIN
    PERFORM public.restore_task_internal_p(
      '42800000-0000-4000-8000-000000000065', v_board.slug,
      v_task_id, v_column.id, clock_timestamp()
    );
  EXCEPTION WHEN SQLSTATE '23503' THEN
    v_parent_blocked := true;
  END;
  IF NOT v_parent_blocked THEN
    RAISE EXCEPTION 'A child task restored before its deleted series parent';
  END IF;
  v_restored := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000066', v_board.slug, v_series_id, NULL
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id) THEN
    RAISE EXCEPTION 'Parent recovery did not restore its own occurrence: %', v_restored;
  END IF;

  v_created := public.create_task_p(
    '42800000-0000-4000-8000-000000000067', v_board.id,
    v_column.id, 'Ocurrencia eliminada aparte', 'No revive con la serie', 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000068', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000069', v_board.slug, v_task_id,
    current_date, NULL, 3, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  IF public.delete_task_p(
    '42800000-0000-4000-8000-000000000070', v_board.slug, v_task_id,
    'user_requested'
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Independent child deletion failed';
  END IF;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000071', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint, true
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Series with independently deleted child did not delete: %', v_deleted;
  END IF;
  v_restored := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000072', v_board.slug, v_series_id, NULL
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id AND deletion.state = 'deleted'
        AND deletion.cause = 'user_requested' AND deletion.parent_series_id = v_series_id
    ) THEN
    RAISE EXCEPTION 'Parent recovery revived a separately deleted occurrence';
  END IF;
END;
$$;
COMMIT;

-- An individually deleted task stays in its own trash cause, but must not be
-- restored while its series parent is detached in the series trash. Restoring
-- the parent alone must not revive that separately deleted child.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_created jsonb;
  v_series jsonb;
  v_task_deleted jsonb;
  v_series_deleted jsonb;
  v_task_restore jsonb;
  v_series_restore jsonb;
  v_task_id uuid;
  v_series_id uuid;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Individually deleted child while parent is trashed #28', 'UTC',
    '42800000-0000-4000-8000-000000000580'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_created := public.create_task_p(
    '42800000-0000-4000-8000-000000000581', v_board.id,
    v_column.id, 'Ocurrencia borrada por separado', NULL, 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000582', v_board.slug, v_task_id,
    current_date, NULL, 3, 1, true, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic series setup failed: %', v_series;
  END IF;
  v_series_id := (v_series->>'series_id')::uuid;
  v_task_deleted := public.delete_task_p(
    '42800000-0000-4000-8000-000000000583', v_board.slug, v_task_id,
    'user_requested'
  );
  IF v_task_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Individual task deletion failed: %', v_task_deleted;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.task_deletions AS deletion
    WHERE deletion.task_id = v_task_id AND deletion.state = 'deleted'
      AND deletion.cause = 'user_requested'
      AND deletion.parent_series_id = v_series_id
  ) THEN
    RAISE EXCEPTION 'Individual task trash did not retain its series relation';
  END IF;
  v_series_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000584', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint, true
  );
  IF v_series_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Parent series deletion failed: %', v_series_deleted;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.list_deleted_tasks_p(v_board.slug) AS item
    WHERE item.task_id = v_task_id
  ) THEN
    RAISE EXCEPTION 'An individually deleted child was listed while its parent is in series trash';
  END IF;
  v_task_restore := public.restore_task_p(
    '42800000-0000-4000-8000-000000000585', v_board.slug, v_task_id, v_column.id
  );
  IF v_task_restore->>'status' IS DISTINCT FROM 'unavailable'
    OR EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id AND deletion.state = 'deleted'
        AND deletion.cause = 'user_requested' AND deletion.parent_series_id = v_series_id
    ) THEN
    RAISE EXCEPTION 'Individual child restore bypassed its trashed parent: %', v_task_restore;
  END IF;

  v_series_restore := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000586', v_board.slug, v_series_id, NULL
  );
  IF v_series_restore->>'status' IS DISTINCT FROM 'confirmed'
    OR EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id AND deletion.state = 'deleted'
        AND deletion.cause = 'user_requested' AND deletion.parent_series_id = v_series_id
    ) THEN
    RAISE EXCEPTION 'Parent restore revived an individually deleted child: %', v_series_restore;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.list_deleted_tasks_p(v_board.slug) AS item
    WHERE item.task_id = v_task_id AND item.can_restore
  ) THEN
    RAISE EXCEPTION 'The independent child did not become eligible after parent recovery';
  END IF;
  v_task_restore := public.restore_task_p(
    '42800000-0000-4000-8000-000000000585', v_board.slug, v_task_id, v_column.id
  );
  IF v_task_restore->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id AND deletion.state = 'restored'
        AND deletion.cause = 'user_requested' AND deletion.parent_series_id = v_series_id
    )
    OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.series_id = v_series_id AND occurrence.task_id = v_task_id)
      IS DISTINCT FROM 'current'
    OR (SELECT series.current_occurrence_id FROM public.daily_repetition_series AS series
        WHERE series.id = v_series_id) IS DISTINCT FROM (
          SELECT occurrence.id FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.series_id = v_series_id AND occurrence.task_id = v_task_id
        ) THEN
    RAISE EXCEPTION 'The independent child could not be restored after its parent: %',
      v_task_restore;
  END IF;
END;
$$;
COMMIT;

-- Reprogramming transfers ownership to B. Deleting, restoring, and purging A
-- must leave B's current task and calendar untouched.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_created jsonb;
  v_due_edit jsonb;
  v_series_a jsonb;
  v_series_b jsonb;
  v_stopped jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_b_before record;
  v_task_id uuid;
  v_a_id uuid;
  v_a_revision bigint;
  v_purged integer;
  v_expires_at timestamptz;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Series transfer recovery #28', 'UTC', '42800000-0000-4000-8000-000000000080'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_created := public.create_task_p(
    '42800000-0000-4000-8000-000000000081', v_board.id,
    v_column.id, 'La misma tarea', 'La propiedad cambia a B', 'medium'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000082', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  v_series_a := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000083', v_board.slug, v_task_id,
    current_date, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  v_a_id := (v_series_a->>'series_id')::uuid;
  v_stopped := public.stop_repetition_series_p(
    '42800000-0000-4000-8000-000000000084', v_board.slug, v_a_id,
    (v_series_a->>'series_revision')::bigint
  );
  v_series_b := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000085', v_board.slug, v_task_id,
    current_date, NULL, 5, 2, false, v_a_id,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_stopped->>'status' IS DISTINCT FROM 'confirmed'
    OR v_series_b->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic A-to-B transfer setup failed';
  END IF;
  SELECT series.id, series.revision, series.next_due_on, series.state
  INTO v_b_before
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_series_b->>'series_id')::uuid;
  SELECT series.revision INTO v_a_revision
  FROM public.daily_repetition_series AS series WHERE series.id = v_a_id;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000086', v_board.slug, v_a_id,
    v_a_revision, true
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_deleted->>'task_count' IS DISTINCT FROM '0'
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR (SELECT id FROM public.daily_repetition_series
        WHERE id = (v_series_b->>'series_id')::uuid) IS DISTINCT FROM v_b_before.id THEN
    RAISE EXCEPTION 'Deleting A touched the task or B: %', v_deleted;
  END IF;
  v_restored := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000087', v_board.slug, v_a_id, NULL
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT revision FROM public.daily_repetition_series WHERE id = v_b_before.id)
      IS DISTINCT FROM v_b_before.revision
    OR (SELECT next_due_on FROM public.daily_repetition_series WHERE id = v_b_before.id)
      IS DISTINCT FROM v_b_before.next_due_on
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id) THEN
    RAISE EXCEPTION 'Restoring A changed B or its current task';
  END IF;

  v_a_revision := (v_restored->>'series_revision')::bigint;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000088', v_board.slug, v_a_id,
    v_a_revision, true
  );
  v_expires_at := (v_deleted->>'expires_at')::timestamptz;
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Deleting A after restore failed';
  END IF;
  v_purged := public.purge_expired_repetition_series_internal_p(100, v_expires_at);
  IF v_purged <> 1
    OR EXISTS (
      SELECT 1 FROM public.daily_repetition_series_deletions AS deletion
      WHERE deletion.series_id = v_a_id
        AND (deletion.series_snapshot IS NOT NULL OR deletion.occurrences_snapshot IS NOT NULL)
    )
    OR EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.parent_series_id = v_a_id
        AND deletion.state = 'deleted' AND deletion.task_snapshot IS NOT NULL
    )
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (SELECT 1 FROM public.daily_repetition_series AS series WHERE series.id = v_b_before.id) THEN
    RAISE EXCEPTION 'Purging A retained snapshots or changed B';
  END IF;
END;
$$;
COMMIT;
