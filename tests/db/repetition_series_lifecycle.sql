\set ON_ERROR_STOP on

-- Stopping retains the live card/history; reprogramming creates an independent series.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task record;
  v_created jsonb;
  v_due_edit jsonb;
  v_series jsonb;
  v_stopped jsonb;
  v_replay jsonb;
  v_conflict jsonb;
  v_stopped_filter jsonb;
  v_active_filter jsonb;
  v_repetition_lookup jsonb;
  v_list_task_result jsonb;
  v_list_task record;
  v_list_due_edit jsonb;
  v_list_series jsonb;
  v_list_completion jsonb;
  v_list_page jsonb;
  v_list_item jsonb;
  v_finished_task_result jsonb;
  v_finished_task record;
  v_finished_due_edit jsonb;
  v_finished_series jsonb;
  v_finished_lookup jsonb;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Series #27 lifecycle', 'America/Argentina/Buenos_Aires',
    '27000000-0000-4000-8000-000000000040'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'A organizar', 0
  );
  v_created := public.create_task_p(
    '27000000-0000-4000-8000-000000000041', v_board.id,
    v_column.id, 'La misma tarjeta', 'Se conserva al reprogramar', 'medium'
  );
  SELECT task.* INTO v_task FROM public.tasks AS task
  WHERE task.id = (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000042', v_board.slug, v_task.id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic lifecycle task date setup failed: %', v_due_edit;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000043', v_board.slug, v_task.id,
    current_date, NULL, 3, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic lifecycle series setup failed: %', v_series;
  END IF;
  v_repetition_lookup := public.get_repetition_p(v_board.slug, v_task.id);
  IF v_repetition_lookup->>'status' IS DISTINCT FROM 'available'
    OR v_repetition_lookup->>'state' IS DISTINCT FROM 'active'
    OR v_repetition_lookup->'template_snapshot'->>'title'
      IS DISTINCT FROM 'La misma tarjeta' THEN
    RAISE EXCEPTION 'An active series lost its operational template: %', v_repetition_lookup;
  END IF;

  v_list_task_result := public.create_task_p(
    '27000000-0000-4000-8000-000000000076', v_board.id,
    v_column.id, 'Resumen semanal', 'Tarea completada que se oculta', 'medium'
  );
  SELECT task.* INTO v_list_task FROM public.tasks AS task
  WHERE task.id = (v_list_task_result->>'task_id')::uuid;
  v_list_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000077', v_board.slug, v_list_task.id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_list_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic list task date setup failed: %', v_list_due_edit;
  END IF;
  v_list_series := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000078', v_board.slug, v_list_task.id,
    current_date, NULL, 3, 2, false, NULL,
    pg_catalog.jsonb_build_object(
      'frequency', 'weekly', 'interval', 1,
      'weekdays', pg_catalog.jsonb_build_array(
        extract(isodow FROM current_date)::integer
      )
    ),
    2, v_column.id
  );
  IF v_list_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic list series setup failed: %', v_list_series;
  END IF;
  v_list_completion := public.set_task_completion_p(
    '27000000-0000-4000-8000-000000000079', v_board.slug, v_list_task.id,
    true, v_list_task.completion_version, NULL
  );
  IF v_list_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic completed list task setup failed: %', v_list_completion;
  END IF;
  v_list_page := public.list_repetition_series_p(
    v_board.id, NULL, NULL, 20, 'active'
  );
  SELECT item INTO v_list_item
  FROM pg_catalog.jsonb_array_elements(v_list_page->'series') AS item
  WHERE item->>'id' = v_list_series->>'series_id';
  IF v_list_item->>'current_task_id' IS DISTINCT FROM v_list_task.id::text
    OR v_list_item->>'current_task_title' IS DISTINCT FROM 'Resumen semanal'
    OR v_list_item->'pattern'->>'frequency' IS DISTINCT FROM 'weekly'
    OR NOT (v_list_item->'pattern'->'weekdays' @>
      pg_catalog.jsonb_build_array(extract(isodow FROM current_date)::integer))
    OR v_list_item->>'advance_days' IS DISTINCT FROM '2'
    OR v_list_item->>'next_due_on' IS DISTINCT FROM (current_date + 7)::text
    OR v_list_item->>'next_appearance_on' IS DISTINCT FROM (current_date + 5)::text
    OR v_list_item->>'appearance_column_id' IS DISTINCT FROM v_column.id::text THEN
    RAISE EXCEPTION 'Accessible series row omitted its title or appearance schedule: %', v_list_item;
  END IF;

  v_finished_task_result := public.create_task_p(
    '27000000-0000-4000-8000-000000000080', v_board.id,
    v_column.id, 'Rutina finalizada', 'No debe persistir como historia', 'medium'
  );
  SELECT task.* INTO v_finished_task FROM public.tasks AS task
  WHERE task.id = (v_finished_task_result->>'task_id')::uuid;
  v_finished_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000081', v_board.slug, v_finished_task.id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_finished_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic finished task date setup failed: %', v_finished_due_edit;
  END IF;
  v_finished_series := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000082', v_board.slug, v_finished_task.id,
    current_date, NULL, 1, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_finished_series->>'status' IS DISTINCT FROM 'confirmed'
    OR v_finished_series->>'state' IS DISTINCT FROM 'finished' THEN
    RAISE EXCEPTION 'Synthetic terminal series setup failed: %', v_finished_series;
  END IF;
  v_finished_lookup := public.get_repetition_p(v_board.slug, v_finished_task.id);
  IF v_finished_lookup->>'state' IS DISTINCT FROM 'finished'
    OR v_finished_lookup ? 'template_snapshot'
    OR v_finished_lookup::text LIKE '%No debe persistir como historia%' THEN
    RAISE EXCEPTION 'A finished series exposed its template as history: %', v_finished_lookup;
  END IF;

  CREATE TEMP TABLE issue27_lifecycle_refs (
    board_slug text NOT NULL,
    board_id uuid NOT NULL,
    column_id uuid NOT NULL,
    task_id uuid NOT NULL,
    series_a_id uuid NOT NULL,
    series_a_revision bigint NOT NULL,
    series_b_id uuid,
    stop_operation_id uuid NOT NULL
  ) ON COMMIT PRESERVE ROWS;
  INSERT INTO issue27_lifecycle_refs VALUES (
    v_board.slug, v_board.id, v_column.id, v_task.id,
    (v_series->>'series_id')::uuid, (v_series->>'series_revision')::bigint, NULL,
    '27000000-0000-4000-8000-000000000044'
  );

  v_stopped := public.stop_repetition_series_p(
    '27000000-0000-4000-8000-000000000044', v_board.slug,
    (v_series->>'series_id')::uuid, (v_series->>'series_revision')::bigint
  );
  IF v_stopped->>'status' IS DISTINCT FROM 'confirmed'
    OR v_stopped->>'state' IS DISTINCT FROM 'stopped'
    OR v_stopped->'next_due_on' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Stopping an active series did not preserve its live card: %', v_stopped;
  END IF;
  v_repetition_lookup := public.get_repetition_p(v_board.slug, v_task.id);
  IF v_repetition_lookup->>'state' IS DISTINCT FROM 'stopped'
    OR v_repetition_lookup ? 'template_snapshot'
    OR v_repetition_lookup::text LIKE '%Se conserva al reprogramar%' THEN
    RAISE EXCEPTION 'A stopped series exposed its template as history: %', v_repetition_lookup;
  END IF;
  CREATE TEMP TABLE issue27_terminal_template_refs (
    stopped_series_id uuid NOT NULL,
    finished_series_id uuid NOT NULL
  ) ON COMMIT PRESERVE ROWS;
  INSERT INTO issue27_terminal_template_refs VALUES (
    (v_series->>'series_id')::uuid,
    (v_finished_series->>'series_id')::uuid
  );
  v_replay := public.stop_repetition_series_p(
    '27000000-0000-4000-8000-000000000044', v_board.slug,
    (v_series->>'series_id')::uuid, (v_series->>'series_revision')::bigint
  );
  IF v_replay IS DISTINCT FROM v_stopped THEN
    RAISE EXCEPTION 'Stopping a series was not idempotent: % / %', v_stopped, v_replay;
  END IF;
  v_conflict := public.stop_repetition_series_p(
    '27000000-0000-4000-8000-000000000045', v_board.slug,
    (v_series->>'series_id')::uuid,
    (v_series->>'series_revision')::bigint - 1
  );
  IF v_conflict->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'Stale stop command did not return a conflict: %', v_conflict;
  END IF;
  v_stopped_filter := public.list_repetition_series_p(
    v_board.id, NULL, NULL, 20, 'stopped'
  );
  v_active_filter := public.list_repetition_series_p(
    v_board.id, NULL, NULL, 20, 'active'
  );
  IF jsonb_array_length(v_stopped_filter->'series') <> 1
    OR jsonb_array_length(v_active_filter->'series') <> 1 THEN
    RAISE EXCEPTION 'Series status filter did not match accessible states: % / %',
      v_stopped_filter, v_active_filter;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  refs issue27_terminal_template_refs%ROWTYPE;
  v_stopped_template jsonb;
  v_finished_template jsonb;
BEGIN
  SELECT * INTO refs FROM issue27_terminal_template_refs;
  SELECT series.template_snapshot INTO v_stopped_template
  FROM public.daily_repetition_series AS series
  WHERE series.id = refs.stopped_series_id;
  SELECT series.template_snapshot INTO v_finished_template
  FROM public.daily_repetition_series AS series
  WHERE series.id = refs.finished_series_id;
  IF v_stopped_template->>'title' IS DISTINCT FROM 'Plantilla retirada'
    OR v_stopped_template->>'redacted' IS DISTINCT FROM 'true'
    OR v_stopped_template->'steps' IS DISTINCT FROM '[]'::jsonb
    OR v_stopped_template::text LIKE '%La misma tarjeta%'
    OR v_stopped_template::text LIKE '%Se conserva al reprogramar%'
    OR v_finished_template->>'title' IS DISTINCT FROM 'Plantilla retirada'
    OR v_finished_template->>'redacted' IS DISTINCT FROM 'true'
    OR v_finished_template->'steps' IS DISTINCT FROM '[]'::jsonb
    OR v_finished_template::text LIKE '%Rutina finalizada%'
    OR v_finished_template::text LIKE '%No debe persistir como historia%' THEN
    RAISE EXCEPTION 'A terminal series retained its template text: % / %',
      v_stopped_template, v_finished_template;
  END IF;

  UPDATE public.daily_repetition_series
  SET template_snapshot = pg_catalog.jsonb_build_object(
    'title', 'No debe reintroducirse',
    'description', 'Texto terminal recuperable',
    'steps', pg_catalog.jsonb_build_array('Texto de paso')
  )
  WHERE id = refs.stopped_series_id;
  SELECT series.template_snapshot INTO v_stopped_template
  FROM public.daily_repetition_series AS series
  WHERE series.id = refs.stopped_series_id;
  IF v_stopped_template->>'title' IS DISTINCT FROM 'Plantilla retirada'
    OR v_stopped_template::text LIKE '%Texto terminal recuperable%'
    OR v_stopped_template::text LIKE '%Texto de paso%' THEN
    RAISE EXCEPTION 'A terminal series accepted replacement template text: %',
      v_stopped_template;
  END IF;
END;
$$;

DO $$
DECLARE
  refs issue27_lifecycle_refs%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_current public.daily_repetition_occurrences%ROWTYPE;
BEGIN
  SELECT * INTO refs FROM issue27_lifecycle_refs;
  SELECT * INTO v_series FROM public.daily_repetition_series WHERE id = refs.series_a_id;
  SELECT * INTO v_current FROM public.daily_repetition_occurrences
  WHERE id = v_series.current_occurrence_id;
  IF v_series.state IS DISTINCT FROM 'stopped'
    OR v_series.next_due_on IS NOT NULL
    OR v_series.consumed_count <> 1
    OR v_series.current_occurrence_id IS NULL
    OR v_current.state IS DISTINCT FROM 'current'
    OR v_current.task_id IS DISTINCT FROM refs.task_id
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_jobs AS job
      WHERE job.series_id = refs.series_a_id AND job.job_kind = 'advance'
        AND job.state = 'superseded'
        AND job.lease_token IS NULL AND job.lease_expires_at IS NULL
    ) THEN
    RAISE EXCEPTION 'Stop discarded the current task/history or left a scheduled job: % / %',
      v_series, v_current;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  refs issue27_lifecycle_refs%ROWTYPE;
  v_created jsonb;
  v_confirmed jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_history_a jsonb;
  v_history_b jsonb;
  v_task_after record;
  v_series_before jsonb;
  v_series_after jsonb;
  v_occurrence_before uuid;
  v_repetition_lookup jsonb;
BEGIN
  SELECT * INTO refs FROM issue27_lifecycle_refs;
  v_created := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000046', refs.board_slug, refs.task_id,
    current_date, NULL, 2, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, refs.column_id
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmation_required'
    OR v_created->>'confirmation' IS DISTINCT FROM 'new_series_from_stopped'
    OR (v_created->>'previous_series_id')::uuid IS DISTINCT FROM refs.series_a_id THEN
    RAISE EXCEPTION 'Reprogramming did not request confirmation for a new independent series: %', v_created;
  END IF;
  v_confirmed := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000046', refs.board_slug, refs.task_id,
    current_date, NULL, 2, 2, false, refs.series_a_id,
    '{"frequency":"daily","interval":1}'::jsonb, 0, refs.column_id
  );
  IF v_confirmed->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_confirmed->>'task_id')::uuid IS DISTINCT FROM refs.task_id
    OR (v_confirmed->>'series_id')::uuid = refs.series_a_id THEN
    RAISE EXCEPTION 'Reprogramming did not retain the same card as the first task: %', v_confirmed;
  END IF;
  v_repetition_lookup := public.get_repetition_p(refs.board_slug, refs.task_id);
  IF v_repetition_lookup->>'state' IS DISTINCT FROM 'active'
    OR (v_repetition_lookup->>'series_id')::uuid
      IS DISTINCT FROM (v_confirmed->>'series_id')::uuid
    OR v_repetition_lookup->'template_snapshot'->>'title'
      IS DISTINCT FROM 'La misma tarjeta' THEN
    RAISE EXCEPTION 'The new active series lost its own operational template: %',
      v_repetition_lookup;
  END IF;
  UPDATE issue27_lifecycle_refs
  SET series_b_id = (v_confirmed->>'series_id')::uuid;
  v_history_a := public.get_repetition_history_page_p(refs.series_a_id, NULL, NULL, 20);
  v_history_b := public.get_repetition_history_page_p(
    (v_confirmed->>'series_id')::uuid, NULL, NULL, 20
  );
  IF v_history_a->>'status' IS DISTINCT FROM 'available'
    OR v_history_a->'series'->>'state' IS DISTINCT FROM 'stopped'
    OR v_history_a->'occurrences'->0->>'state' IS DISTINCT FROM 'transferred'
    OR (v_history_a->'occurrences'->0->>'task_id')::uuid IS DISTINCT FROM refs.task_id
    OR v_history_b->>'status' IS DISTINCT FROM 'available'
    OR v_history_b->'series'->>'state' IS DISTINCT FROM 'active'
    OR v_history_b->'occurrences'->0->>'state' IS DISTINCT FROM 'current'
    OR (v_history_b->'occurrences'->0->>'task_id')::uuid IS DISTINCT FROM refs.task_id THEN
    RAISE EXCEPTION 'The two series do not preserve their distinct histories: % / %',
      v_history_a, v_history_b;
  END IF;
  v_series_before := v_history_b->'series';
  v_occurrence_before := (v_history_b->'occurrences'->0->>'id')::uuid;
  v_deleted := public.delete_task_p(
    '27000000-0000-4000-8000-000000000074', refs.board_slug,
    refs.task_id, 'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic task deletion after reprogramming failed: %', v_deleted;
  END IF;
  v_restored := public.restore_task_p(
    '27000000-0000-4000-8000-000000000075', refs.board_slug,
    refs.task_id, refs.column_id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic task restoration after reprogramming failed: %', v_restored;
  END IF;
  v_history_a := public.get_repetition_history_page_p(refs.series_a_id, NULL, NULL, 20);
  v_history_b := public.get_repetition_history_page_p(
    (v_confirmed->>'series_id')::uuid, NULL, NULL, 20
  );
  v_series_after := v_history_b->'series';
  IF v_history_a->'occurrences'->0->>'state' IS DISTINCT FROM 'transferred'
    OR v_history_b->'occurrences'->0->>'state' IS DISTINCT FROM 'current'
    OR v_history_b->'occurrences'->0->>'title' IS DISTINCT FROM 'La misma tarjeta'
    OR (v_history_b->'occurrences'->0->>'id')::uuid IS DISTINCT FROM v_occurrence_before
    OR v_series_after->>'next_due_on' IS DISTINCT FROM v_series_before->>'next_due_on'
    OR v_series_after->>'revision' IS DISTINCT FROM v_series_before->>'revision'
    THEN
    RAISE EXCEPTION 'Recovering the shared task changed old provenance or the new calendar: % / % / %',
      v_history_a, v_history_b, v_series_after;
  END IF;
  SELECT task.* INTO v_task_after FROM public.tasks AS task WHERE task.id = refs.task_id;
  IF v_task_after.title IS DISTINCT FROM 'La misma tarjeta'
    OR v_task_after.description IS DISTINCT FROM 'Se conserva al reprogramar'
    OR v_task_after.due_on IS DISTINCT FROM current_date THEN
    RAISE EXCEPTION 'Reprogramming changed the same task or its content: %', v_task_after;
  END IF;
END;
$$;
COMMIT;

-- Simulate removal of only the old series row: cascades may remove its slots/jobs,
-- but must not cascade through the task identity now owned by series B.
DO $$
DECLARE
  refs issue27_lifecycle_refs%ROWTYPE;
BEGIN
  SELECT * INTO refs FROM issue27_lifecycle_refs;
  DELETE FROM public.daily_repetition_series WHERE id = refs.series_a_id;
  IF NOT EXISTS (
    SELECT 1 FROM public.daily_repetition_series AS series
    WHERE series.id = refs.series_b_id AND series.state = 'active'
      AND series.current_occurrence_id IS NOT NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
    JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
    WHERE series.id = refs.series_b_id AND occurrence.state = 'current'
      AND occurrence.task_id = refs.task_id
  ) OR NOT EXISTS (
    SELECT 1 FROM public.tasks AS task WHERE task.id = refs.task_id
      AND task.title = 'La misma tarjeta'
  ) THEN
    RAISE EXCEPTION 'Removing the old series cascaded into the current series/task';
  END IF;
END;
$$;

\echo 'PASS: stop retains current/history; reprogram creates independent series with same task.'
