\set ON_ERROR_STOP on

-- 056 must backfill only labels that are active in the legacy current-task
-- tombstone, before restoring the task snapshot consumes its saved label IDs.
DO $$
DECLARE
  v_ref public.issue31_upgrade_refs%ROWTYPE;
  v_deletion public.daily_repetition_series_deletions%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_ref FROM public.issue31_upgrade_refs;
  SELECT * INTO STRICT v_deletion FROM public.daily_repetition_series_deletions
  WHERE series_id = v_ref.series_id;
  IF v_deletion.series_snapshot->'template_label_ids'
    IS DISTINCT FROM jsonb_build_array(v_ref.active_label_id) THEN
    RAISE EXCEPTION 'Migration 056 did not initialize the legacy series template baseline: %',
      v_deletion.series_snapshot;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43110000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref public.issue31_upgrade_refs%ROWTYPE;
  v_restore jsonb;
  v_series jsonb;
  v_current_labels jsonb;
BEGIN
  SELECT * INTO STRICT v_ref FROM public.issue31_upgrade_refs;
  v_restore := public.restore_repetition_series_p(
    '31500000-0000-4000-8000-000000000006', v_ref.board_slug,
    v_ref.series_id, v_ref.column_id
  );
  IF v_restore->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not restore the pre-056 series tombstone: %', v_restore;
  END IF;
  v_series := public.get_repetition_p(v_ref.board_slug, v_ref.task_id);
  IF v_series->>'state' IS DISTINCT FROM 'active'
    OR v_series->'template_label_ids' IS DISTINCT FROM jsonb_build_array(v_ref.active_label_id) THEN
    RAISE EXCEPTION 'The legacy baseline did not restore as an active template: %', v_series;
  END IF;
  v_current_labels := public.get_task_labels_p(v_ref.board_slug, v_ref.task_id);
  IF (SELECT coalesce(array_agg((item->>'id')::uuid ORDER BY item->>'id'), ARRAY[]::uuid[])
      FROM jsonb_array_elements(v_current_labels->'labels') AS item)
    IS DISTINCT FROM ARRAY[v_ref.active_label_id]::uuid[] THEN
    RAISE EXCEPTION 'The active current task labels changed during legacy series restore: %',
      v_current_labels;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref public.issue31_upgrade_refs%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_result jsonb;
  v_current_assignment_ids uuid[];
  v_future_assignment_ids uuid[];
  v_expected_current uuid[];
  v_now timestamptz;
BEGIN
  SELECT * INTO STRICT v_ref FROM public.issue31_upgrade_refs;
  SELECT * INTO STRICT v_job FROM public.daily_repetition_jobs
  WHERE series_id = v_ref.series_id AND job_kind = 'advance' AND state = 'queued'
  ORDER BY created_at DESC LIMIT 1;
  v_now := ((v_job.scheduled_on::timestamp + interval '12 hours')
    AT TIME ZONE 'America/Argentina/Buenos_Aires');
  v_result := public.advance_daily_repetition_internal_p(v_job, v_now);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not generate the first post-upgrade occurrence: %', v_result;
  END IF;
  SELECT coalesce(array_agg(assignment.label_id ORDER BY assignment.label_id), ARRAY[]::uuid[])
  INTO v_current_assignment_ids FROM public.board_label_task_assignments AS assignment
  WHERE assignment.task_id = v_ref.task_id;
  SELECT coalesce(array_agg(assignment.label_id ORDER BY assignment.label_id), ARRAY[]::uuid[])
  INTO v_future_assignment_ids FROM public.board_label_task_assignments AS assignment
  WHERE assignment.task_id = (v_result->>'task_id')::uuid;
  SELECT array_agg(selected.id ORDER BY selected.id)
  INTO v_expected_current FROM unnest(ARRAY[v_ref.active_label_id, v_ref.hidden_label_id]) AS selected(id);
  IF v_current_assignment_ids IS DISTINCT FROM v_expected_current
    OR v_future_assignment_ids IS DISTINCT FROM ARRAY[v_ref.active_label_id]::uuid[] THEN
    RAISE EXCEPTION 'Upgrade restore rewrote the current labels or inherited the inactive label: current %, future %',
      v_current_assignment_ids, v_future_assignment_ids;
  END IF;
  DROP TABLE public.issue31_upgrade_refs;
END;
$$;
