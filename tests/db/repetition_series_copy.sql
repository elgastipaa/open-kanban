\set ON_ERROR_STOP on

-- Historical E04 copies are confirmed against current source content and stay punctual.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_one record;
  v_column_two record;
  v_created jsonb;
  v_task jsonb;
  v_added jsonb;
  v_marked jsonb;
  v_due_edit jsonb;
  v_series jsonb;
  v_completion jsonb;
  v_comment jsonb;
  v_history jsonb;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Series #27 copy', 'America/Argentina/Buenos_Aires',
    '27000000-0000-4000-8000-000000000050'
  );
  SELECT * INTO v_column_one FROM public.create_column_p(
    v_board.slug, v_board.id, 'Origen', 0
  );
  SELECT * INTO v_column_two FROM public.create_column_p(
    v_board.slug, v_board.id, 'Destino', 1
  );
  v_created := public.create_task_p(
    '27000000-0000-4000-8000-000000000051', v_board.id,
    v_column_one.id, 'Ocurrencia histórica', 'Descripción origen', 'high'
  );
  v_task := v_created->'task';
  v_added := public.mutate_task_checklist_step_p(
    '27000000-0000-4000-8000-000000000052', v_board.slug,
    (v_task->>'id')::uuid, '{"action":"add","text":"Paso conservado sin marca"}'::jsonb
  );
  v_marked := public.mutate_task_checklist_step_p(
    '27000000-0000-4000-8000-000000000053', v_board.slug,
    (v_task->>'id')::uuid, pg_catalog.jsonb_build_object(
      'action', 'mark', 'step_id', (v_added->'task'->'steps'->0->>'id')::uuid,
      'is_completed', true, 'expected_version', 1
    )
  );
  IF v_marked->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic copy checklist setup failed: %', v_marked;
  END IF;
  v_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000054', v_board.slug,
    (v_task->>'id')::uuid, pg_catalog.jsonb_build_object('due_on', current_date - 1),
    '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic copy source date setup failed: %', v_due_edit;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000055', v_board.slug,
    (v_task->>'id')::uuid, current_date - 1, NULL, 2, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column_one.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic copy history series setup failed: %', v_series;
  END IF;
  v_completion := public.set_task_completion_p(
    '27000000-0000-4000-8000-000000000056', v_board.slug,
    (v_task->>'id')::uuid, true,
    (v_marked->'task'->>'completion_version')::bigint, NULL
  );
  IF v_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic historical completion setup failed: %', v_completion;
  END IF;
  v_comment := public.create_task_comment_p(
    '27000000-0000-4000-8000-000000000057', v_board.slug,
    (v_task->>'id')::uuid, 'Comentario no copiable', '[]'::jsonb
  );
  IF v_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic source comment setup failed: %', v_comment;
  END IF;
  CREATE TEMP TABLE issue27_copy_refs (
    board_slug text NOT NULL,
    board_id uuid NOT NULL,
    target_column_id uuid NOT NULL,
    source_task_id uuid NOT NULL,
    series_id uuid NOT NULL,
    occurrence_id uuid NOT NULL,
    source_step_id uuid NOT NULL,
    comment_id uuid NOT NULL
  ) ON COMMIT PRESERVE ROWS;
  v_history := public.get_repetition_history_page_p(
    (v_series->>'series_id')::uuid, NULL, NULL, 1
  );
  INSERT INTO issue27_copy_refs VALUES (
    v_board.slug, v_board.id, v_column_two.id, (v_task->>'id')::uuid,
    (v_series->>'series_id')::uuid,
    (v_history->'occurrences'->0->>'id')::uuid,
    (v_marked->'task'->'steps'->0->>'id')::uuid,
    (v_comment->>'comment_id')::uuid
  );
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.run_daily_repetition_jobs_p(20);
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  refs issue27_copy_refs%ROWTYPE;
  v_history jsonb;
  v_preview jsonb;
  v_changed jsonb;
  v_copy jsonb;
  v_replay jsonb;
  v_source_edit jsonb;
  v_source record;
  v_copy_comments jsonb;
  v_copy_history jsonb;
  v_unfinished jsonb;
BEGIN
  SELECT * INTO refs FROM issue27_copy_refs;
  v_history := public.get_repetition_history_occurrence_p(refs.series_id, refs.occurrence_id);
  IF v_history->>'status' IS DISTINCT FROM 'available'
    OR v_history->'occurrence'->>'state' IS DISTINCT FROM 'replaced'
    OR v_history->'occurrence'->'task'->>'title' IS DISTINCT FROM 'Ocurrencia histórica' THEN
    RAISE EXCEPTION 'The selected source is not an authorized historical occurrence: %', v_history;
  END IF;

  v_preview := public.preview_historical_task_copy_p(refs.board_slug, refs.source_task_id);
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'title' IS DISTINCT FROM 'Ocurrencia histórica'
    OR v_preview->>'description' IS DISTINCT FROM 'Descripción origen'
    OR v_preview->>'priority' IS DISTINCT FROM 'high'
    OR jsonb_array_length(v_preview->'steps') <> 1
    OR v_preview->'steps'->0->>'is_completed' IS DISTINCT FROM 'false'
    OR v_preview->>'source_hash' IS NULL THEN
    RAISE EXCEPTION 'E04 copy preview omitted or changed authorized source content: %', v_preview;
  END IF;
  v_unfinished := public.create_task_p(
    '27000000-0000-4000-8000-000000000060', refs.board_id,
    refs.target_column_id, 'Tarea pendiente ajena al historial', NULL, 'medium'
  );
  IF public.preview_historical_task_copy_p(
    refs.board_slug, (v_unfinished->'task'->>'id')::uuid
  )->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'Historical copy preview exposed a pending non-historical task';
  END IF;

  -- A source edit after preview must return a fresh preview without writing a copy.
  v_source_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000058', refs.board_slug, refs.source_task_id,
    '{"description":"Descripción actualizada"}'::jsonb, '{"description":1}'::jsonb
  );
  IF v_source_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic source change setup failed: %', v_source_edit;
  END IF;
  v_changed := public.copy_historical_task_p(
    '27000000-0000-4000-8000-000000000059', refs.board_slug,
    refs.source_task_id, refs.target_column_id,
    'Título elegido para copia', v_preview->>'source_hash'
  );
  IF v_changed->>'status' IS DISTINCT FROM 'source_changed'
    OR v_changed->>'title' IS DISTINCT FROM 'Título elegido para copia'
    OR (v_changed->>'target_column_id')::uuid IS DISTINCT FROM refs.target_column_id
    OR v_changed->>'description' IS DISTINCT FROM 'Descripción actualizada'
    OR v_changed->>'source_hash' IS NULL THEN
    RAISE EXCEPTION 'Changed source was copied without renewed review or lost the selected title/destination: %', v_changed;
  END IF;
  IF EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.title = 'Título elegido para copia') THEN
    RAISE EXCEPTION 'A source-change review created a task before confirmation';
  END IF;

  v_copy := public.copy_historical_task_p(
    '27000000-0000-4000-8000-000000000059', refs.board_slug,
    refs.source_task_id, refs.target_column_id,
    'Título elegido para copia', v_changed->>'source_hash'
  );
  IF v_copy->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_copy->'task'->>'id')::uuid = refs.source_task_id
    OR v_copy->'task'->>'title' IS DISTINCT FROM 'Título elegido para copia'
    OR v_copy->'task'->>'description' IS DISTINCT FROM 'Descripción actualizada'
    OR v_copy->'task'->>'priority' IS DISTINCT FROM 'high'
    OR v_copy->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_copy->'task'->>'due_on' IS NOT NULL
    OR v_copy->'task'->>'assignee_id' IS NOT NULL
    OR (v_copy->'task'->>'column_id')::uuid IS DISTINCT FROM refs.target_column_id
    OR jsonb_array_length(v_copy->'task'->'steps') <> 1
    OR v_copy->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Paso conservado sin marca'
    OR v_copy->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'false'
    OR v_copy->'task'->'steps'->0->>'id' IS NOT DISTINCT FROM refs.source_step_id::text THEN
    RAISE EXCEPTION 'Copy did not create a punctual task with reset checklist and E04 exclusions: %', v_copy;
  END IF;
  v_replay := public.copy_historical_task_p(
    '27000000-0000-4000-8000-000000000059', refs.board_slug,
    refs.source_task_id, refs.target_column_id,
    'Título elegido para copia', v_changed->>'source_hash'
  );
  IF v_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replay->'task'->>'id' IS DISTINCT FROM v_copy->'task'->>'id' THEN
    RAISE EXCEPTION 'Retrying the E04 copy created a duplicate or lost the original result: %', v_replay;
  END IF;
  SELECT task.* INTO v_source FROM public.tasks AS task WHERE task.id = refs.source_task_id;
  IF v_source.title IS DISTINCT FROM 'Ocurrencia histórica'
    OR v_source.description IS DISTINCT FROM 'Descripción actualizada'
    OR v_source.is_completed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Copy altered or reopened its historical source: %', v_source;
  END IF;
  v_copy_comments := public.get_task_comments_p(
    refs.board_slug, (v_copy->'task'->>'id')::uuid, 20, NULL, NULL, NULL
  );
  v_copy_history := public.get_repetition_p(
    refs.board_slug, (v_copy->'task'->>'id')::uuid
  );
  IF v_copy_comments->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_copy_comments->'comments') <> 0
    OR v_copy_history->>'status' IS DISTINCT FROM 'not_repeating' THEN
    RAISE EXCEPTION 'A punctual copy inherited conversation or recurrence: % / %',
      v_copy_comments, v_copy_history;
  END IF;
END;
$$;
COMMIT;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns AS column_row
    WHERE column_row.table_schema = 'public'
      AND column_row.table_name = 'task_copy_receipts'
      AND column_row.column_name IN ('title', 'description', 'source_snapshot')
  ) THEN
    RAISE EXCEPTION 'Copy receipt stored a recoverable source-text snapshot';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  refs issue27_copy_refs%ROWTYPE;
  v_deleted jsonb;
  v_repetition jsonb;
  v_history jsonb;
  v_preview jsonb;
BEGIN
  SELECT * INTO refs FROM issue27_copy_refs;
  v_deleted := public.delete_task_p(
    '27000000-0000-4000-8000-000000000061', refs.board_slug,
    refs.source_task_id, 'user_requested'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic historical task deletion failed: %', v_deleted;
  END IF;

  v_repetition := public.get_repetition_p(refs.board_slug, refs.source_task_id);
  IF v_repetition->>'status' IS DISTINCT FROM 'available'
    OR v_repetition ? 'template_snapshot'
    OR v_repetition::text LIKE '%Ocurrencia histórica%' THEN
    RAISE EXCEPTION 'A deleted task text remained recoverable from series metadata: %', v_repetition;
  END IF;
  v_history := public.get_repetition_history_occurrence_p(refs.series_id, refs.occurrence_id);
  IF v_history->'occurrence'->>'content_available' IS DISTINCT FROM 'false'
    OR v_history::text LIKE '%Ocurrencia histórica%'
    OR v_history::text LIKE '%Descripción actualizada%' THEN
    RAISE EXCEPTION 'Deleted source content remained visible in precise history: %', v_history;
  END IF;
  v_preview := public.preview_historical_task_copy_p(refs.board_slug, refs.source_task_id);
  IF v_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_preview::text LIKE '%Ocurrencia histórica%' THEN
    RAISE EXCEPTION 'Deleted source content remained available to copy: %', v_preview;
  END IF;
END;
$$;
COMMIT;

RESET ROLE;
DO $$
DECLARE
  refs issue27_copy_refs%ROWTYPE;
  v_expires_at timestamptz;
BEGIN
  SELECT * INTO refs FROM issue27_copy_refs;
  SELECT deletion.expires_at INTO v_expires_at
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = refs.source_task_id AND deletion.state = 'deleted';
  IF public.purge_expired_task_internal_p(refs.source_task_id, v_expires_at)
    IS DISTINCT FROM 'purged' THEN
    RAISE EXCEPTION 'Synthetic task purge did not complete';
  END IF;
END;
$$;

RESET ROLE;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.task_deletions AS deletion
    JOIN issue27_copy_refs AS refs ON refs.source_task_id = deletion.task_id
    WHERE deletion.state IS DISTINCT FROM 'purged'
      OR deletion.task_snapshot IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Purged task recovery snapshot retained its text';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  refs issue27_copy_refs%ROWTYPE;
  v_repetition jsonb;
  v_history jsonb;
  v_preview jsonb;
BEGIN
  SELECT * INTO refs FROM issue27_copy_refs;
  v_repetition := public.get_repetition_p(refs.board_slug, refs.source_task_id);
  v_history := public.get_repetition_history_occurrence_p(refs.series_id, refs.occurrence_id);
  v_preview := public.preview_historical_task_copy_p(refs.board_slug, refs.source_task_id);
  IF v_repetition->>'status' IS DISTINCT FROM 'available'
    OR v_repetition ? 'template_snapshot'
    OR v_repetition::text LIKE '%Ocurrencia histórica%'
    OR v_history->'occurrence'->>'content_available' IS DISTINCT FROM 'false'
    OR v_history::text LIKE '%Ocurrencia histórica%'
    OR v_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_preview::text LIKE '%Ocurrencia histórica%' THEN
    RAISE EXCEPTION 'Purged historical text remained recoverable through RPCs: % / % / %',
      v_repetition, v_history, v_preview;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: historical E04 copy uses fresh preview, new identity and no source snapshots.'
