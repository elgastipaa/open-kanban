\set ON_ERROR_STOP on

-- Exact occurrence navigation keeps its own task/comment identity across pages.
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
  v_comment jsonb;
  v_history jsonb;
  v_completion jsonb;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Series #27 history', 'America/Argentina/Buenos_Aires',
    '27000000-0000-4000-8000-000000000030'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'A organizar', 0
  );
  v_created := public.create_task_p(
    '27000000-0000-4000-8000-000000000031', v_board.id,
    v_column.id, 'Primera ocurrencia exacta', 'Texto histórico', 'high'
  );
  SELECT task.* INTO v_task FROM public.tasks AS task
  WHERE task.id = (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '27000000-0000-4000-8000-000000000032', v_board.slug, v_task.id,
    pg_catalog.jsonb_build_object('due_on', current_date - 1), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic history task date setup failed: %', v_due_edit;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '27000000-0000-4000-8000-000000000033', v_board.slug, v_task.id,
    current_date - 1, NULL, 2, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic history series setup failed: %', v_series;
  END IF;
  v_completion := public.set_task_completion_p(
    '27000000-0000-4000-8000-000000000035', v_board.slug, v_task.id,
    true, v_task.completion_version, NULL
  );
  IF v_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic completed historical occurrence setup failed: %', v_completion;
  END IF;
  v_comment := public.create_task_comment_p(
    '27000000-0000-4000-8000-000000000034', v_board.slug, v_task.id,
    'Comentario de la primera ocurrencia', '[]'::jsonb
  );
  IF v_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic history comment setup failed: %', v_comment;
  END IF;
  v_history := public.get_repetition_history_page_p(
    (v_series->>'series_id')::uuid, NULL, NULL, 1
  );
  CREATE TEMP TABLE issue27_history_refs (
    board_slug text NOT NULL,
    series_id uuid NOT NULL,
    first_occurrence_id uuid NOT NULL,
    first_task_id uuid NOT NULL,
    comment_id uuid NOT NULL
  ) ON COMMIT PRESERVE ROWS;
  INSERT INTO issue27_history_refs
  SELECT v_board.slug, (v_series->>'series_id')::uuid,
    (v_history->'occurrences'->0->>'id')::uuid,
    v_task.id, (v_comment->>'comment_id')::uuid;
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
  refs issue27_history_refs%ROWTYPE;
  v_page_one jsonb;
  v_page_two jsonb;
  v_occurrence jsonb;
  v_comments jsonb;
  v_cursor_on date;
  v_cursor_id uuid;
  v_completion jsonb;
  v_current_task_id uuid;
  v_current_completion_version bigint;
BEGIN
  SELECT * INTO refs FROM issue27_history_refs;
  v_page_one := public.get_repetition_history_page_p(refs.series_id, NULL, NULL, 1);
  IF v_page_one->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page_one->'occurrences') <> 1
    OR v_page_one->>'has_more' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'First history page omitted continuation: %', v_page_one;
  END IF;
  v_cursor_on := (v_page_one->'next_cursor'->>'occurrence_on')::date;
  v_cursor_id := (v_page_one->'next_cursor'->>'id')::uuid;
  v_page_two := public.get_repetition_history_page_p(
    refs.series_id, v_cursor_on, v_cursor_id, 1
  );
  IF v_page_two->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page_two->'occurrences') <> 1
    OR (v_page_two->'occurrences'->0->>'id')::uuid IS DISTINCT FROM refs.first_occurrence_id
    OR (v_page_two->'occurrences'->0->>'task_id')::uuid IS DISTINCT FROM refs.first_task_id
    OR (v_page_two->'occurrences'->0->>'latest_comment_id')::uuid IS DISTINCT FROM refs.comment_id THEN
    RAISE EXCEPTION 'Second history page lost exact occurrence/comment identity: %', v_page_two;
  END IF;

  v_occurrence := public.get_repetition_history_occurrence_p(
    refs.series_id, refs.first_occurrence_id
  );
  IF v_occurrence->>'status' IS DISTINCT FROM 'available'
    OR (v_occurrence->'occurrence'->>'id')::uuid IS DISTINCT FROM refs.first_occurrence_id
    OR (v_occurrence->'occurrence'->>'task_id')::uuid IS DISTINCT FROM refs.first_task_id
    OR v_occurrence->'occurrence'->'task'->>'title' IS DISTINCT FROM 'Primera ocurrencia exacta'
    OR (v_occurrence->'occurrence'->>'latest_comment_id')::uuid IS DISTINCT FROM refs.comment_id THEN
    RAISE EXCEPTION 'Exact occurrence detail is unavailable or points to a different task: %', v_occurrence;
  END IF;
  v_comments := public.get_task_comments_p(
    refs.board_slug, refs.first_task_id, 20, NULL, NULL, refs.comment_id
  );
  IF v_comments->>'status' IS DISTINCT FROM 'available'
    OR v_comments->>'anchor_id' IS DISTINCT FROM refs.comment_id::text
    OR v_comments->'comments'->0->>'content' IS DISTINCT FROM 'Comentario de la primera ocurrencia' THEN
    RAISE EXCEPTION 'Exact historical comment anchor was not accessible: %', v_comments;
  END IF;

  BEGIN
    v_completion := public.set_task_completion_p(
      '27000000-0000-4000-8000-000000000036', refs.board_slug, refs.first_task_id,
      false, (SELECT task.completion_version FROM public.tasks AS task
        WHERE task.id = refs.first_task_id), NULL
    );
    RAISE EXCEPTION 'Reopening or modifying a replaced occurrence was not rejected: %', v_completion;
  EXCEPTION WHEN SQLSTATE 'P2302' THEN
    NULL;
  END;

  v_current_task_id := (v_page_one->'occurrences'->0->>'task_id')::uuid;
  SELECT task.completion_version INTO v_current_completion_version
  FROM public.tasks AS task WHERE task.id = v_current_task_id;
  v_completion := public.set_task_completion_p(
    '27000000-0000-4000-8000-000000000037', refs.board_slug, v_current_task_id,
    true, v_current_completion_version, NULL
  );
  IF v_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Completing the current occurrence was incorrectly blocked: %', v_completion;
  END IF;
  v_completion := public.set_task_completion_p(
    '27000000-0000-4000-8000-000000000038', refs.board_slug, v_current_task_id,
    false, (v_completion->'task'->>'completion_version')::bigint, NULL
  );
  IF v_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Reopening the current occurrence was incorrectly blocked: %', v_completion;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: paginated history opens the selected occurrence and its exact comment anchor.'
