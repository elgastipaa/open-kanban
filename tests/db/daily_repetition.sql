\set ON_ERROR_STOP on

-- Database contract tests use a disposable PostgreSQL cluster and synthetic actors.
CREATE TEMP TABLE issue23_refs (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT ON issue23_refs TO authenticated;
CREATE TEMP TABLE issue23_results (series_id uuid NOT NULL);
GRANT INSERT, SELECT ON issue23_results TO authenticated;
CREATE TEMP TABLE issue24_series_refs (
  purpose text PRIMARY KEY,
  series_id uuid NOT NULL,
  task_id uuid NOT NULL,
  board_id uuid NOT NULL,
  slug text NOT NULL
);
GRANT INSERT, SELECT ON issue24_series_refs TO authenticated;
CREATE TEMP TABLE issue23_transfer_results (
  series_a uuid NOT NULL,
  series_b uuid,
  revision_after_stop bigint,
  consumed_count_after_stop bigint,
  latest_on_after_stop date,
  start_on_after_stop date,
  end_on_after_stop date,
  template_snapshot_after_stop jsonb,
  occurrence_count_after_stop bigint,
  occurrence_id_after_stop uuid,
  occurrence_on_after_stop date,
  occurrence_task_id_after_stop uuid,
  occurrence_override_after_stop date,
  occurrence_created_at_after_stop timestamptz
);
GRANT INSERT, SELECT, UPDATE ON issue23_transfer_results TO authenticated;

-- The focused runner does not execute the authentication regression first.
-- Admit only these synthetic principals through the same Google identity gate.
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('40000000-0000-4000-8000-000000000002', 'enabled-user@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('50000000-0000-4000-8000-000000000002', '40000000-0000-4000-8000-000000000002',
   'google', 'google-subject-enabled',
   '{"email":"enabled-user@example.test","email_verified":true}');
UPDATE public.application_access
SET auth_user_id = '40000000-0000-4000-8000-000000000002',
    google_subject = 'google-subject-enabled', state = 'active'
WHERE email = 'enabled-user@example.test';

BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_created jsonb;
  v_weekly_created jsonb;
  v_transfer_created jsonb;
  v_due_edit jsonb;
  v_step_result jsonb;
  v_comment_result jsonb;
  v_task_id uuid;
  v_weekly_task_id uuid;
  v_transfer_task_id uuid;
  v_step_id uuid;
  v_operation_id uuid := '23000000-0000-4000-8000-000000000001';
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Repetición diaria #23', 'America/Argentina/Buenos_Aires',
    '23000000-0000-4000-8000-000000000010'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_created := public.create_task_p(
    '23000000-0000-4000-8000-000000000011', v_board.id, v_column.id,
    'Preparar la revisión', 'Descripción de la tarea', 'high'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '23000000-0000-4000-8000-000000000012', v_board.slug, v_task_id,
    '{"due_on":"2026-11-05"}'::jsonb, '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic task date setup failed: %', v_due_edit;
  END IF;
  v_step_result := public.mutate_task_checklist_step_p(
    '23000000-0000-4000-8000-000000000013', v_board.slug, v_task_id,
    '{"action":"add","text":"Revisar el informe"}'::jsonb
  );
  v_step_id := (v_step_result->'task'->'steps'->0->>'id')::uuid;
  v_step_result := public.mutate_task_checklist_step_p(
    '23000000-0000-4000-8000-000000000014', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object(
      'action', 'mark', 'step_id', v_step_id,
      'is_completed', true, 'expected_version', 1
    )
  );
  IF v_step_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic checklist setup failed: %', v_step_result;
  END IF;
  v_comment_result := public.create_task_comment_p(
    '23000000-0000-4000-8000-000000000015', v_board.slug, v_task_id,
    'Comentario original de la ocurrencia'
  );
  IF v_comment_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic comment setup failed: %', v_comment_result;
  END IF;

  INSERT INTO issue23_refs(purpose, board_id, slug, column_id, task_id, operation_id)
  VALUES ('conversion', v_board.id, v_board.slug, v_column.id, v_task_id, v_operation_id);

  v_weekly_created := public.create_task_p(
    '23000000-0000-4000-8000-000000000031', v_board.id, v_column.id,
    'Preview semanal', NULL, 'low'
  );
  v_weekly_task_id := (v_weekly_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '23000000-0000-4000-8000-000000000032', v_board.slug, v_weekly_task_id,
    '{"due_on":"2026-11-04"}'::jsonb, '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic weekly preview task setup failed: %', v_due_edit;
  END IF;
  INSERT INTO issue23_refs(purpose, board_id, slug, column_id, task_id, operation_id)
  VALUES ('weekly_preview', v_board.id, v_board.slug, v_column.id,
    v_weekly_task_id, '23000000-0000-4000-8000-000000000033');

  v_transfer_created := public.create_task_p(
    '23000000-0000-4000-8000-000000000034', v_board.id, v_column.id,
    'Transferir serie detenida', NULL, 'medium'
  );
  v_transfer_task_id := (v_transfer_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '23000000-0000-4000-8000-000000000035', v_board.slug, v_transfer_task_id,
    '{"due_on":"2026-11-05"}'::jsonb, '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic stopped-series transfer task setup failed: %', v_due_edit;
  END IF;
  INSERT INTO issue23_refs(purpose, board_id, slug, column_id, task_id, operation_id)
  VALUES ('series_transfer', v_board.id, v_board.slug, v_column.id,
    v_transfer_task_id, '23000000-0000-4000-8000-000000000036');
END;
$$;
COMMIT;

-- AC49: the shared calendar preview anchors biweekly weeks to the start week.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_preview jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'weekly_preview';
  v_preview := public.preview_daily_repetition_internal_p(
    v_ref.slug, v_ref.task_id, '2026-11-04'::date, NULL, NULL,
    '2026-11-04 15:00:00+00'::timestamptz,
    '{"frequency":"weekly","interval":2,"weekdays":[1,3]}'::jsonb
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'time_zone' IS DISTINCT FROM 'America/Argentina/Buenos_Aires'
    OR v_preview->>'today' IS DISTINCT FROM '2026-11-04'
    OR v_preview->'current'->>'due_on' IS DISTINCT FROM '2026-11-04'
    OR v_preview->'future_dates'->>0 IS DISTINCT FROM '2026-11-16'
    OR v_preview->'future_dates'->>1 IS DISTINCT FROM '2026-11-18'
    OR v_preview->'future_dates' ? '2026-11-09'
    OR (v_preview->>'requires_start_confirmation')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'AC49 weekly preview did not honor the start-week anchor: %', v_preview;
  END IF;
END;
$$;
COMMIT;

-- Issue #24: preview counts effective weekly dates from the current task,
-- using the Monday-anchored interval and a controlled board-local clock.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_preview jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'weekly_preview';
  v_preview := public.preview_repetition_internal_p(
    v_ref.slug, v_ref.task_id, '2026-11-04'::date, NULL, 4,
    '2026-11-04 15:00:00+00'::timestamptz,
    '{"frequency":"weekly","interval":2,"weekdays":[1,3]}'::jsonb
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'time_zone' IS DISTINCT FROM 'America/Argentina/Buenos_Aires'
    OR v_preview->>'today' IS DISTINCT FROM '2026-11-04'
    OR v_preview->'current'->>'due_on' IS DISTINCT FROM '2026-11-04'
    OR v_preview->'future_dates' IS DISTINCT FROM '["2026-11-16","2026-11-18","2026-11-30"]'::jsonb
    OR v_preview->>'final_on' IS DISTINCT FROM '2026-11-30'
    OR (v_preview->>'occurrence_limit')::bigint IS DISTINCT FROM 4
    OR (v_preview->>'remaining_dates_after_current')::bigint IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'Issue #24 weekly preview did not share anchored calendar/count semantics: %', v_preview;
  END IF;
END;
$$;
COMMIT;

-- Issue #24: selected weeks/days are part of the idempotent operation and
-- durable series/job snapshot.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_result jsonb;
  v_replay jsonb;
  v_status jsonb;
  v_mismatch_rejected boolean := false;
  v_pattern jsonb := '{"frequency":"weekly","interval":2,"weekdays":[1,3]}'::jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'weekly_preview';
  v_result := public.create_repetition_p(
    '24000000-0000-4000-8000-000000000001', v_ref.slug, v_ref.task_id,
    '2026-11-04'::date, NULL, 4, 2, false, NULL, v_pattern
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'task_id')::uuid IS DISTINCT FROM v_ref.task_id
    OR (v_result->>'next_due_on')::date IS DISTINCT FROM '2026-11-16'::date THEN
    RAISE EXCEPTION 'Weekly series did not keep the first task and first eligible date: %', v_result;
  END IF;
  INSERT INTO issue24_series_refs(purpose, series_id, task_id, board_id, slug)
  VALUES ('biweekly_count', (v_result->>'series_id')::uuid,
    v_ref.task_id, v_ref.board_id, v_ref.slug);

  v_status := public.get_repetition_p(v_ref.slug, v_ref.task_id);
  IF v_status->>'status' IS DISTINCT FROM 'available'
    OR v_status->>'rule' IS DISTINCT FROM 'weekly'
    OR v_status->'pattern' IS DISTINCT FROM v_pattern
    OR (v_status->>'consumed_count')::bigint IS DISTINCT FROM 1
    OR v_status->>'next_due_on' IS DISTINCT FROM '2026-11-16' THEN
    RAISE EXCEPTION 'The selected weekly rule and durable date were not persisted together: %', v_status;
  END IF;

  v_replay := public.create_repetition_p(
    '24000000-0000-4000-8000-000000000001', v_ref.slug, v_ref.task_id,
    '2026-11-04'::date, NULL, 4, 2, false, NULL, v_pattern
  );
  IF v_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_replay->>'series_id')::uuid IS DISTINCT FROM (v_result->>'series_id')::uuid THEN
    RAISE EXCEPTION 'Replaying the same weekly operation created another series';
  END IF;

  BEGIN
    PERFORM public.create_repetition_p(
      '24000000-0000-4000-8000-000000000001', v_ref.slug, v_ref.task_id,
      '2026-11-04'::date, NULL, 4, 2, false, NULL,
      '{"frequency":"weekly","interval":2,"weekdays":[1,2]}'::jsonb
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_mismatch_rejected := true;
  END;
  IF NOT v_mismatch_rejected THEN
    RAISE EXCEPTION 'A repeated operation silently changed its selected weekdays';
  END IF;
END;
$$;
COMMIT;

-- C112: changing the first date while transferring a stopped series to a new
-- series must not rewrite the old occurrence's exception/history.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_series_a uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'series_transfer';
  v_result := public.create_daily_repetition_p(
    v_ref.operation_id, v_ref.slug, v_ref.task_id,
    '2026-11-05'::date, NULL, 3, 2, false, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'task_id')::uuid IS DISTINCT FROM v_ref.task_id THEN
    RAISE EXCEPTION 'Synthetic source series creation failed: %', v_result;
  END IF;
  v_series_a := (v_result->>'series_id')::uuid;
  INSERT INTO issue23_transfer_results(series_a) VALUES (v_series_a);
END;
$$;
COMMIT;

BEGIN;
DO $$
DECLARE
  v_series_a uuid;
BEGIN
  SELECT series_a INTO v_series_a FROM issue23_transfer_results;
  UPDATE public.daily_repetition_jobs AS job
  SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
      completed_at = '2026-11-05 12:00:00+00'::timestamptz,
      updated_at = '2026-11-05 12:00:00+00'::timestamptz
  WHERE job.series_id = v_series_a AND job.state IN ('queued', 'retry_wait', 'leased');
  UPDATE public.daily_repetition_series AS series
  SET state = 'stopped', next_due_on = NULL,
      stopped_at = '2026-11-05 12:00:00+00'::timestamptz,
      revision = series.revision + 1,
      updated_at = '2026-11-05 12:00:00+00'::timestamptz
  WHERE series.id = v_series_a AND series.state = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Synthetic source series could not be stopped'; END IF;

  UPDATE issue23_transfer_results AS snapshot
  SET revision_after_stop = series.revision,
      consumed_count_after_stop = series.consumed_count,
      latest_on_after_stop = series.latest_occurrence_on,
      start_on_after_stop = series.start_on,
      end_on_after_stop = series.end_on,
      template_snapshot_after_stop = series.template_snapshot,
      occurrence_count_after_stop = occurrence_stats.occurrence_count,
      occurrence_id_after_stop = occurrence.id,
      occurrence_on_after_stop = occurrence.occurrence_on,
      occurrence_task_id_after_stop = occurrence.task_id,
      occurrence_override_after_stop = occurrence.due_on_override,
      occurrence_created_at_after_stop = occurrence.created_at
  FROM public.daily_repetition_series AS series
  JOIN public.daily_repetition_occurrences AS occurrence
    ON occurrence.series_id = series.id
  CROSS JOIN LATERAL (
    SELECT pg_catalog.count(*) AS occurrence_count
    FROM public.daily_repetition_occurrences AS all_occurrences
    WHERE all_occurrences.series_id = series.id
  ) AS occurrence_stats
  WHERE snapshot.series_a = series.id;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_series_a uuid;
  v_series_b uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'series_transfer';
  SELECT series_a INTO v_series_a FROM issue23_transfer_results;
  v_result := public.create_daily_repetition_p(
    '23000000-0000-4000-8000-000000000037', v_ref.slug, v_ref.task_id,
    '2026-11-06'::date, NULL, 3, 2, true, v_series_a
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'task_id')::uuid IS DISTINCT FROM v_ref.task_id
    OR (v_result->>'due_on')::date IS DISTINCT FROM '2026-11-06'::date THEN
    RAISE EXCEPTION 'New series did not preserve the source task identity and chosen first date: %', v_result;
  END IF;
  v_series_b := (v_result->>'series_id')::uuid;
  UPDATE issue23_transfer_results SET series_b = v_series_b;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_series_a uuid;
  v_series_b uuid;
  v_snapshot issue23_transfer_results%ROWTYPE;
  v_series_a_after public.daily_repetition_series%ROWTYPE;
  v_series_b_after public.daily_repetition_series%ROWTYPE;
  v_occurrence_a_after public.daily_repetition_occurrences%ROWTYPE;
  v_occurrence_b_after public.daily_repetition_occurrences%ROWTYPE;
  v_occurrence_count_after bigint;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'series_transfer';
  SELECT * INTO v_snapshot FROM issue23_transfer_results;
  v_series_a := v_snapshot.series_a;
  v_series_b := v_snapshot.series_b;
  SELECT * INTO v_series_a_after FROM public.daily_repetition_series AS series
  WHERE series.id = v_series_a;
  SELECT * INTO v_series_b_after FROM public.daily_repetition_series AS series
  WHERE series.id = v_series_b;
  SELECT * INTO v_occurrence_a_after FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_a;
  SELECT * INTO v_occurrence_b_after FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_b;
  SELECT pg_catalog.count(*) INTO v_occurrence_count_after
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_a;

  IF v_series_a_after.state IS DISTINCT FROM 'stopped'
    OR v_series_a_after.next_due_on IS NOT NULL
    OR v_series_a_after.revision IS DISTINCT FROM v_snapshot.revision_after_stop
    OR v_series_a_after.consumed_count IS DISTINCT FROM v_snapshot.consumed_count_after_stop
    OR v_series_a_after.latest_occurrence_on IS DISTINCT FROM v_snapshot.latest_on_after_stop
    OR v_series_a_after.start_on IS DISTINCT FROM v_snapshot.start_on_after_stop
    OR v_series_a_after.end_on IS DISTINCT FROM v_snapshot.end_on_after_stop
    OR v_series_a_after.template_snapshot IS DISTINCT FROM v_snapshot.template_snapshot_after_stop
    OR v_occurrence_count_after IS DISTINCT FROM v_snapshot.occurrence_count_after_stop
    OR v_series_b_after.state IS DISTINCT FROM 'active'
    OR v_occurrence_a_after.id IS DISTINCT FROM v_snapshot.occurrence_id_after_stop
    OR v_occurrence_a_after.task_id IS DISTINCT FROM v_snapshot.occurrence_task_id_after_stop
    OR v_occurrence_a_after.occurrence_on IS DISTINCT FROM v_snapshot.occurrence_on_after_stop
    OR v_occurrence_a_after.state IS DISTINCT FROM 'transferred'
    OR v_occurrence_a_after.transferred_to_series_id IS DISTINCT FROM v_series_b
    OR v_occurrence_a_after.due_on_override IS DISTINCT FROM v_snapshot.occurrence_override_after_stop
    OR v_occurrence_a_after.created_at IS DISTINCT FROM v_snapshot.occurrence_created_at_after_stop
    OR v_occurrence_b_after.task_id IS DISTINCT FROM v_ref.task_id
    OR v_occurrence_b_after.occurrence_on IS DISTINCT FROM '2026-11-06'::date
    OR v_occurrence_b_after.state IS DISTINCT FROM 'current' THEN
    RAISE EXCEPTION 'C112 transfer changed source history or failed to preserve the new first occurrence';
  END IF;
END;
$$;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_preview jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  v_preview := public.preview_daily_repetition_internal_p(
    v_ref.slug, v_ref.task_id, '2026-11-05'::date, NULL, 3,
    '2026-11-05 12:00:00+00'::timestamptz
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'time_zone' IS DISTINCT FROM 'America/Argentina/Buenos_Aires'
    OR v_preview->>'today' IS DISTINCT FROM '2026-11-05'
    OR (v_preview->'current'->>'due_on')::date IS DISTINCT FROM '2026-11-05'::date
    OR v_preview->'future_dates' <> '["2026-11-06","2026-11-07"]'::jsonb
    OR (v_preview->>'current_task_id')::uuid IS DISTINCT FROM v_ref.task_id
    OR (v_preview->>'requires_start_confirmation')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Daily preview did not preserve the first task and canonical dates: %', v_preview;
  END IF;

END;
$$;
COMMIT;

-- A changed start date is visible in preview and requires an explicit confirmation.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_preview jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  v_preview := public.preview_daily_repetition_internal_p(
    v_ref.slug, v_ref.task_id, '2026-11-06'::date, NULL, 3,
    '2026-11-05 12:00:00+00'::timestamptz
  );
  IF (v_preview->>'requires_start_confirmation')::boolean IS DISTINCT FROM true
    OR v_preview->>'existing_due_on' IS DISTINCT FROM '2026-11-05'
    OR v_preview->>'proposed_start_on' IS DISTINCT FROM '2026-11-06' THEN
    RAISE EXCEPTION 'A changed first date was not called out for confirmation: %', v_preview;
  END IF;

END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_result jsonb;
  v_status jsonb;
  v_task_id uuid;
  v_detail text;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  v_result := public.create_daily_repetition_p(
    v_ref.operation_id, v_ref.slug, v_ref.task_id,
    '2026-11-06'::date, NULL, 3, 2, false, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmation_required'
    THEN
    RAISE EXCEPTION 'A date change mutated the task before explicit confirmation: %', v_result;
  END IF;

  v_result := public.create_daily_repetition_p(
    v_ref.operation_id, v_ref.slug, v_ref.task_id,
    '2026-11-06'::date, NULL, 3, 2, true, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'task_id')::uuid IS DISTINCT FROM v_ref.task_id
    OR (v_result->>'due_on')::date IS DISTINCT FROM '2026-11-06'::date THEN
    RAISE EXCEPTION 'Confirmed conversion did not preserve the same task identity: %', v_result;
  END IF;
  v_task_id := (v_result->>'task_id')::uuid;
  INSERT INTO issue23_results(series_id) VALUES ((v_result->>'series_id')::uuid);

  -- The same actor/operation/payload returns the one committed series.
  v_result := public.create_daily_repetition_p(
    v_ref.operation_id, v_ref.slug, v_ref.task_id,
    '2026-11-06'::date, NULL, 3, 2, true, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'series_id')::uuid IS DISTINCT FROM (SELECT series_id FROM issue23_results) THEN
    RAISE EXCEPTION 'Conversion replay duplicated a series or its durable job: %', v_result;
  END IF;

  BEGIN
    PERFORM public.edit_task_fields_p(
      '23000000-0000-4000-8000-000000000020', v_ref.slug, v_task_id,
      '{"due_on":"2026-11-07"}'::jsonb, '{"due_on":3}'::jsonb
    );
    RAISE EXCEPTION 'An exception on or after the next daily occurrence was accepted';
  EXCEPTION WHEN SQLSTATE 'P2301' THEN
    GET STACKED DIAGNOSTICS v_detail = PG_EXCEPTION_DETAIL;
    IF SQLERRM NOT LIKE 'La fecha excepcional debe ser anterior%'
      OR v_detail IS DISTINCT FROM '2026-11-07' THEN
      RAISE EXCEPTION 'Daily exception diagnostic mismatch: %, %', SQLERRM, v_detail;
    END IF;
  END;

  v_result := public.edit_task_fields_p(
    '23000000-0000-4000-8000-000000000021', v_ref.slug, v_task_id,
    '{"due_on":"2026-11-05"}'::jsonb, '{"due_on":3}'::jsonb
  );
  v_status := public.get_daily_repetition_p(v_ref.slug, v_task_id);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_status->'occurrences') AS item(value)
      WHERE item.value->>'task_id' = v_task_id::text
        AND item.value->>'due_on_override' = '2026-11-05'
    ) THEN
    RAISE EXCEPTION 'A valid earlier date override was not retained separately from the series';
  END IF;

  v_result := public.edit_task_fields_p(
    '23000000-0000-4000-8000-000000000022', v_ref.slug, v_task_id,
    '{"due_on":"2026-11-06"}'::jsonb, '{"due_on":4}'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The current task could not restore its original due date';
  END IF;

  v_result := public.edit_task_fields_p(
    '23000000-0000-4000-8000-000000000023', v_ref.slug, v_task_id,
    '{"title":"Preparar la revisión diaria"}'::jsonb, '{"title":1}'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->'task'->>'title' IS DISTINCT FROM 'Preparar la revisión diaria' THEN
    RAISE EXCEPTION 'Updating the current task did not update the series template';
  END IF;
END;
$$;
COMMIT;

-- Keep a synthetic recovery destination available for the active-series case.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_target record;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  SELECT * INTO v_target FROM public.create_column_p(
    v_ref.slug, v_ref.board_id, 'Restauradas', 1
  );
  INSERT INTO issue23_refs(purpose, board_id, slug, column_id, task_id, operation_id)
  VALUES ('restore_target', v_ref.board_id, v_ref.slug, v_target.id,
    v_ref.task_id, '23000000-0000-4000-8000-000000000024');
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_series_id uuid;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  SELECT series_id INTO v_series_id FROM issue23_results;
  IF (SELECT count(*) FROM public.daily_repetition_series AS series
      WHERE series.origin_task_id = v_ref.task_id) <> 1
    OR (SELECT count(*) FROM public.daily_repetition_jobs AS job
      WHERE job.job_kind = 'advance' AND job.series_id = v_series_id
        AND job.state = 'queued') <> 1
    OR (SELECT count(*) FROM public.daily_repetition_jobs AS job
      WHERE job.job_kind = 'advance' AND job.series_id = v_series_id
        AND job.state = 'superseded') <> 1 THEN
    RAISE EXCEPTION 'Conversion replay duplicated a series or its durable job';
  END IF;
END;
$$;

-- A worker claim before the next board-local date does not materialize a task.
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_job record;
  v_series_id uuid;
  v_purge_result jsonb;
  v_claimed_advance boolean := false;
BEGIN
  SELECT series_id INTO v_series_id FROM issue23_results;
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2026-11-06 12:00:00+00'::timestamptz
    )
  LOOP
    IF v_job.job_kind = 'purge' THEN
      v_purge_result := public.process_daily_repetition_job_internal_p(
        v_job.id, v_job.lease_token, '2026-11-06 12:00:00+00'::timestamptz
      );
      IF v_purge_result->>'status' IS DISTINCT FROM 'confirmed' THEN
        RAISE EXCEPTION 'The first durable purge job did not complete: %', v_purge_result;
      END IF;
    ELSIF v_job.series_id = v_series_id THEN
      v_claimed_advance := true;
    END IF;
  END LOOP;
  IF v_claimed_advance THEN
    RAISE EXCEPTION 'A daily occurrence was claimable before the next date in the board zone';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.series_id = v_series_id AND occurrence.occurrence_on > '2026-11-06'
  ) THEN
    RAISE EXCEPTION 'A future occurrence was materialized before its board-local date';
  END IF;
END;
$$;
COMMIT;

-- The worker drops after claim. An expired lease gets a new token; the old
-- token cannot mutate the task, and replay after commit is a no-op.
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_series_id uuid;
  v_original_column_id uuid;
  v_job record;
  v_old_job record;
  v_new_job record;
  v_result jsonb;
  v_new_task_id uuid;
BEGIN
  SELECT series_id INTO v_series_id FROM issue23_results;
  SELECT column_id INTO v_original_column_id
  FROM issue23_refs WHERE purpose = 'conversion';
  SELECT * INTO v_job
  FROM public.claim_daily_repetition_jobs_internal_p(
    100, '2026-11-07 05:00:00+00'::timestamptz
  )
  WHERE job_kind = 'advance' AND series_id = v_series_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No daily job was leased at the next board-local date';
  END IF;
  v_old_job := v_job;

  SELECT * INTO v_new_job
  FROM public.claim_daily_repetition_jobs_internal_p(
    100, '2026-11-07 05:03:00+00'::timestamptz
  )
  WHERE id = v_old_job.id;
  IF NOT FOUND OR v_new_job.lease_token = v_old_job.lease_token THEN
    RAISE EXCEPTION 'An expired worker lease was not replaced with a new token';
  END IF;

  v_result := public.process_daily_repetition_job_internal_p(
    v_old_job.id, v_old_job.lease_token, '2026-11-07 05:03:00+00'::timestamptz
  );
  IF v_result->>'status' IS DISTINCT FROM 'lease_lost' THEN
    RAISE EXCEPTION 'An old worker changed a re-leased job: %', v_result;
  END IF;

  v_result := public.process_daily_repetition_job_internal_p(
    v_new_job.id, v_new_job.lease_token, '2026-11-07 05:03:00+00'::timestamptz
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->>'occurrence_on' IS DISTINCT FROM '2026-11-07'
    OR (v_result->>'task_id')::uuid IS NULL THEN
    RAISE EXCEPTION 'The current daily occurrence was not generated: %', v_result;
  END IF;
  v_new_task_id := (v_result->>'task_id')::uuid;

  v_result := public.process_daily_repetition_job_internal_p(
    v_new_job.id, v_new_job.lease_token, '2026-11-07 05:03:00+00'::timestamptz
  );
  IF v_result->>'status' IS DISTINCT FROM 'already_processed' THEN
    RAISE EXCEPTION 'A lost worker response replayed its occurrence: %', v_result;
  END IF;

  IF (SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id AND occurrence.occurrence_on = '2026-11-07') <> 1
    OR (SELECT count(*) FROM public.tasks WHERE id = v_new_task_id) <> 1
    OR (SELECT count(*) FROM public.task_comments WHERE task_id = v_new_task_id) <> 0
    OR (SELECT count(*) FROM public.task_comments AS comment_row
      JOIN issue23_refs AS ref ON ref.task_id = comment_row.task_id
      WHERE ref.purpose = 'conversion'
        AND comment_row.content = 'Comentario original de la ocurrencia') <> 1
    OR (SELECT task.created_by FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS DISTINCT FROM
        '40000000-0000-4000-8000-000000000002'::uuid
    OR (SELECT task.title FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS DISTINCT FROM 'Preparar la revisión diaria'
    OR (SELECT task.column_id FROM public.tasks AS task
      WHERE task.id = v_new_task_id) IS DISTINCT FROM v_original_column_id
    OR (SELECT (step->>'is_completed')::boolean FROM public.tasks AS task
      CROSS JOIN LATERAL jsonb_array_elements(task.steps) AS step
      WHERE task.id = v_new_task_id) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'Occurrence generation mismatch: id %, count %, comments %, creator %, title %, column %, target %, steps %',
      v_new_task_id,
      (SELECT count(*) FROM public.tasks WHERE id = v_new_task_id),
      (SELECT count(*) FROM public.task_comments WHERE task_id = v_new_task_id),
      (SELECT task.created_by FROM public.tasks AS task WHERE task.id = v_new_task_id),
      (SELECT task.title FROM public.tasks AS task WHERE task.id = v_new_task_id),
      (SELECT task.column_id FROM public.tasks AS task WHERE task.id = v_new_task_id),
      v_original_column_id,
      (SELECT task.steps FROM public.tasks AS task WHERE task.id = v_new_task_id);
  END IF;
END;
$$;
COMMIT;

-- Restoring the current occurrence into another chosen column updates the
-- active template, just like a normal column change, without moving its dates.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_target_column_id uuid;
  v_task_id uuid;
  v_status jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  v_status := public.get_daily_repetition_p(v_ref.slug, v_ref.task_id);
  SELECT (item.value->>'task_id')::uuid INTO v_task_id
  FROM jsonb_array_elements(v_status->'occurrences') AS item(value)
  WHERE item.value->>'state' = 'current';
  SELECT column_id INTO v_target_column_id
  FROM issue23_refs WHERE purpose = 'restore_target';
  v_result := public.delete_task_p(
    '23000000-0000-4000-8000-000000000025', v_ref.slug, v_task_id,
    'user_requested'
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The active current occurrence could not be deleted for recovery coverage';
  END IF;
  v_result := public.restore_task_p(
    '23000000-0000-4000-8000-000000000026', v_ref.slug, v_task_id,
    v_target_column_id
  );
  v_status := public.get_daily_repetition_p(v_ref.slug, v_task_id);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_status->>'status' IS DISTINCT FROM 'available'
    OR v_status->>'state' IS DISTINCT FROM 'active'
    OR v_status->>'next_due_on' IS DISTINCT FROM '2026-11-08'
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_status->'occurrences') AS item(value)
      WHERE item.value->>'task_id' = v_task_id::text
        AND item.value->>'state' = 'current'
    ) THEN
    RAISE EXCEPTION 'Recovery did not preserve the current active occurrence and its schedule';
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_series_id uuid;
  v_revision bigint;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  SELECT series_id INTO v_series_id FROM issue23_results;
  SELECT series.revision INTO v_revision
  FROM public.daily_repetition_series AS series WHERE series.id = v_series_id;
  IF (SELECT series.state FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id) IS DISTINCT FROM 'active'
    OR (SELECT series.appearance_column_id FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id) IS DISTINCT FROM
        (SELECT ref.column_id FROM issue23_refs AS ref WHERE ref.purpose = 'restore_target')
    OR (SELECT task.column_id FROM public.tasks AS task
      WHERE task.id = (SELECT occurrence.task_id
        FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.series_id = v_series_id AND occurrence.state = 'current'))
      IS DISTINCT FROM
        (SELECT ref.column_id FROM issue23_refs AS ref WHERE ref.purpose = 'restore_target')
    OR (SELECT series.current_occurrence_id FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id) IS DISTINCT FROM
        (SELECT occurrence.id FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.series_id = v_series_id AND occurrence.state = 'current')
    OR v_revision < 3
    OR (SELECT count(*) FROM public.daily_repetition_jobs AS job
      WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
        AND job.state = 'queued' AND job.scheduled_on = '2026-11-08') <> 1 THEN
    RAISE EXCEPTION 'Recovery did not preserve the active series and selected future column';
  END IF;
END;
$$;

-- An excluded date consumes its position and does not extend a finite daily
-- series; the same final date remains queued after deletion.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_task_id uuid;
  v_status jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  v_status := public.get_daily_repetition_p(v_ref.slug, v_ref.task_id);
  SELECT (item.value->>'task_id')::uuid INTO v_task_id
  FROM jsonb_array_elements(v_status->'occurrences') AS item(value)
  WHERE item.value->>'state' = 'current';
  v_result := public.delete_task_p(
    '23000000-0000-4000-8000-000000000027', v_ref.slug, v_task_id,
    'user_requested'
  );
  v_status := public.get_daily_repetition_p(v_ref.slug, v_ref.task_id);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_status->>'state' IS DISTINCT FROM 'active'
    OR v_status->>'next_due_on' IS DISTINCT FROM '2026-11-08'
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_status->'occurrences') AS item(value)
      WHERE item.value->>'task_id' = v_task_id::text
        AND item.value->>'state' = 'excluded'
    ) THEN
    RAISE EXCEPTION 'The excluded occurrence extended or stopped the finite daily series';
  END IF;
END;
$$;
COMMIT;

-- A failed attempt rolls back its occurrence and exposes only a stable SQLSTATE
-- to an authorized board member; the durable retry succeeds after repair.
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_series_id uuid;
  v_ref issue23_refs%ROWTYPE;
  v_job record;
  v_result jsonb;
  v_advance_failed boolean := false;
BEGIN
  SELECT series_id INTO v_series_id FROM issue23_results;
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  UPDATE public.daily_repetition_series AS series
  SET appearance_column_id = '99999999-0000-4000-8000-000000000023'
  WHERE series.id = v_series_id;
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2026-11-10 12:00:00+00'::timestamptz
    )
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2026-11-10 12:00:00+00'::timestamptz
    );
    IF v_job.job_kind = 'advance' AND v_job.series_id = v_series_id THEN
      v_advance_failed := v_result->>'status' = 'retry_wait'
        AND v_result->>'error_code' = '23503';
    END IF;
  END LOOP;
  IF NOT v_advance_failed
    OR (SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id) <> 2
    OR (SELECT series.latest_occurrence_on FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id) <> '2026-11-07' THEN
    RAISE EXCEPTION 'A failed worker attempt was not retried atomically';
  END IF;
  UPDATE public.daily_repetition_series AS series
  SET appearance_column_id = (
    SELECT ref.column_id FROM issue23_refs AS ref WHERE ref.purpose = 'restore_target'
  )
  WHERE series.id = v_series_id;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_status jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  v_status := public.get_daily_repetition_p(v_ref.slug, v_ref.task_id);
  IF v_status->>'status' IS DISTINCT FROM 'available'
    OR v_status->'diagnostic'->>'status' IS DISTINCT FROM 'retry_wait'
    OR v_status->'diagnostic'->>'last_error_code' IS DISTINCT FROM '23503' THEN
    RAISE EXCEPTION 'The authorized diagnostic did not expose the retry safely: %', v_status;
  END IF;
END;
$$;
COMMIT;

-- Reconciliation after inactivity creates only the last valid occurrence of
-- the finite series; it does not stack the missed dates or extend its end.
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_series_id uuid;
  v_target_column_id uuid;
  v_recovered_task_id uuid;
  v_job record;
  v_result jsonb;
  v_retried boolean := false;
BEGIN
  SELECT series_id INTO v_series_id FROM issue23_results;
  SELECT column_id INTO v_target_column_id
  FROM issue23_refs WHERE purpose = 'restore_target';
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2026-11-10 12:00:31+00'::timestamptz
    )
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2026-11-10 12:00:31+00'::timestamptz
    );
    IF v_job.job_kind = 'advance' AND v_job.series_id = v_series_id THEN
      v_retried := v_result->>'status' = 'confirmed'
        AND v_result->>'occurrence_on' = '2026-11-08';
      IF v_retried THEN
        v_recovered_task_id := (v_result->>'task_id')::uuid;
      END IF;
    END IF;
  END LOOP;
  IF NOT v_retried
    OR (SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id) <> 3
    OR EXISTS (SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id AND occurrence.occurrence_on > '2026-11-08')
    OR (SELECT series.state FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id) IS DISTINCT FROM 'finished'
    OR (SELECT series.consumed_count FROM public.daily_repetition_series AS series
      WHERE series.id = v_series_id) <> 3
    OR (SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series_id AND occurrence.state = 'current') <> 1 THEN
    RAISE EXCEPTION 'Inactivity reconciliation stacked missed dates or extended the final date';
  END IF;
  IF (SELECT task.column_id FROM public.tasks AS task
      WHERE task.id = v_recovered_task_id) IS DISTINCT FROM v_target_column_id THEN
    RAISE EXCEPTION 'The recovered last valid occurrence did not follow the restored current column';
  END IF;
END;
$$;
COMMIT;

-- A restored latest occurrence only undoes its own deletion exclusion. The
-- subsequent exact-window purge must also purge its checklist tombstone.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_series_id uuid;
  v_task_id uuid;
  v_step_id uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'conversion';
  SELECT series_id INTO v_series_id FROM issue23_results;
  SELECT task_id INTO v_task_id
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_id AND occurrence.state = 'current';
  SELECT (step->>'id')::uuid INTO v_step_id
  FROM public.tasks AS task
  CROSS JOIN LATERAL jsonb_array_elements(task.steps) AS step
  WHERE task.id = v_task_id;
  v_result := public.mutate_task_checklist_step_p(
    '23000000-0000-4000-8000-000000000016', v_ref.slug, v_task_id,
    pg_catalog.jsonb_build_object(
      'action', 'delete', 'step_id', v_step_id, 'expected_version', 1
    )
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT count(*) FROM public.task_checklist_deletions AS deletion
      WHERE deletion.task_id = v_task_id AND deletion.state = 'deleted') <> 1 THEN
    RAISE EXCEPTION 'The synthetic checklist deletion was not retained for parent-purge coverage';
  END IF;

  v_result := public.delete_task_internal_p(
    '23000000-0000-4000-8000-000000000017', v_ref.slug, v_task_id,
    'user_requested', '2026-11-10 06:00:00+00'::timestamptz
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT state FROM public.daily_repetition_occurrences
      WHERE task_id = v_task_id) IS DISTINCT FROM 'excluded' THEN
    RAISE EXCEPTION 'Deleting a current task did not create its occurrence exclusion';
  END IF;

  v_result := public.restore_task_internal_p(
    '23000000-0000-4000-8000-000000000018', v_ref.slug, v_task_id, NULL,
    '2026-11-17 05:59:59+00'::timestamptz
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT state FROM public.daily_repetition_occurrences
      WHERE task_id = v_task_id) IS DISTINCT FROM 'current'
    OR (SELECT state FROM public.daily_repetition_series
      WHERE id = v_series_id) IS DISTINCT FROM 'finished' THEN
    RAISE EXCEPTION 'Restoring the latest occurrence failed or reactivated its finished series';
  END IF;

  v_result := public.delete_task_internal_p(
    '23000000-0000-4000-8000-000000000019', v_ref.slug, v_task_id,
    'user_requested', '2026-11-10 06:00:00+00'::timestamptz
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT state FROM public.daily_repetition_occurrences
      WHERE task_id = v_task_id) IS DISTINCT FROM 'excluded' THEN
    RAISE EXCEPTION 'A second deletion did not reinstate the occurrence exclusion';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_task_id uuid;
  v_purged integer;
BEGIN
  SELECT deletion.task_id INTO v_task_id
  FROM public.task_deletions AS deletion
  JOIN public.daily_repetition_occurrences AS occurrence
    ON occurrence.task_id = deletion.task_id
  WHERE deletion.state = 'deleted';
  v_purged := public.purge_daily_repetition_tasks_internal_p(
    1000, '2026-11-17 05:59:59+00'::timestamptz
  );
  IF v_purged <> 0
    OR (SELECT state FROM public.task_deletions WHERE task_id = v_task_id) <> 'deleted'
    OR (SELECT state FROM public.daily_repetition_occurrences
      WHERE task_id = v_task_id) <> 'excluded' THEN
    RAISE EXCEPTION 'Task or occurrence purged before the exact seven-day window';
  END IF;
  v_purged := public.purge_daily_repetition_tasks_internal_p(
    1000, '2026-11-17 06:00:00+00'::timestamptz
  );
  IF v_purged <> 1
    OR (SELECT state FROM public.task_deletions WHERE task_id = v_task_id) <> 'purged'
    OR (SELECT state FROM public.daily_repetition_occurrences
      WHERE task_id = v_task_id) <> 'purged'
    OR (SELECT state FROM public.task_checklist_deletions
      WHERE task_id = v_task_id) <> 'purged' THEN
    RAISE EXCEPTION 'Parent purge did not atomically purge the occurrence and checklist tombstone';
  END IF;
END;
$$;
COMMIT;

-- Issue #24: a late durable run uses the latest eligible weekly date, counts
-- effective dates (not completions), and keeps the original two-week phase.
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_ref issue24_series_refs%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_job record;
  v_result jsonb;
  v_processed boolean := false;
BEGIN
  SELECT * INTO v_ref FROM issue24_series_refs WHERE purpose = 'biweekly_count';
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2026-11-20 15:00:00+00'::timestamptz
    )
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2026-11-20 15:00:00+00'::timestamptz
    );
    IF v_job.series_id = v_ref.series_id THEN
      v_processed := v_result->>'status' = 'confirmed';
    END IF;
  END LOOP;

  SELECT * INTO v_series FROM public.daily_repetition_series
  WHERE id = v_ref.series_id;
  IF NOT v_processed
    OR v_series.state IS DISTINCT FROM 'active'
    OR v_series.latest_occurrence_on IS DISTINCT FROM '2026-11-18'::date
    OR v_series.consumed_count IS DISTINCT FROM 3
    OR v_series.next_due_on IS DISTINCT FROM '2026-11-30'::date
    OR (SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_ref.series_id AND occurrence.state = 'current') <> 1
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_ref.series_id
        AND occurrence.occurrence_on = '2026-11-18'::date
        AND occurrence.state = 'current'
    ) THEN
    RAISE EXCEPTION 'Late weekly execution shifted phase or counted completions: %, %',
      v_series, v_processed;
  END IF;
END;
$$;
COMMIT;

-- Issue #24 / C110-AC50: an excluded weekly date consumes its position and
-- does not create an extra date after the finite count is reached.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_created jsonb;
  v_due_edit jsonb;
  v_preview jsonb;
  v_result jsonb;
  v_task_id uuid;
  v_pattern jsonb := '{"frequency":"weekly","interval":2,"weekdays":[1,3]}'::jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'weekly_preview';
  v_created := public.create_task_p(
    '24000000-0000-4000-8000-000000000011', v_ref.board_id, v_ref.column_id,
    'Conteo semanal con exclusión', NULL, 'low'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '24000000-0000-4000-8000-000000000012', v_ref.slug, v_task_id,
    '{"due_on":"2026-12-28"}'::jsonb, '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic weekly count task setup failed: %', v_due_edit;
  END IF;
  v_preview := public.preview_repetition_internal_p(
    v_ref.slug, v_task_id, '2026-12-28'::date, NULL, 4,
    '2026-12-28 15:00:00+00'::timestamptz, v_pattern
  );
  IF v_preview->>'final_on' IS DISTINCT FROM '2027-01-13'
    OR v_preview->'future_dates' IS DISTINCT FROM '["2026-12-30","2027-01-11","2027-01-13"]'::jsonb THEN
    RAISE EXCEPTION 'Weekly N-count preview did not stop at the fourth effective date: %', v_preview;
  END IF;
  v_result := public.create_repetition_p(
    '24000000-0000-4000-8000-000000000013', v_ref.slug, v_task_id,
    '2026-12-28'::date, NULL, 4, 2, false, NULL, v_pattern
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->>'next_due_on' IS DISTINCT FROM '2026-12-30' THEN
    RAISE EXCEPTION 'Finite weekly series did not schedule its first effective date: %', v_result;
  END IF;
  INSERT INTO issue24_series_refs(purpose, series_id, task_id, board_id, slug)
  VALUES ('count_exclusion', (v_result->>'series_id')::uuid,
    v_task_id, v_ref.board_id, v_ref.slug);
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_ref issue24_series_refs%ROWTYPE;
  v_job record;
  v_result jsonb;
  v_processed boolean := false;
BEGIN
  SELECT * INTO v_ref FROM issue24_series_refs WHERE purpose = 'count_exclusion';
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2027-01-11 15:00:00+00'::timestamptz
    )
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2027-01-11 15:00:00+00'::timestamptz
    );
    IF v_job.series_id = v_ref.series_id THEN
      v_processed := v_result->>'status' = 'confirmed';
    END IF;
  END LOOP;
  IF NOT v_processed OR NOT EXISTS (
    SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.series_id = v_ref.series_id
      AND occurrence.occurrence_on = '2027-01-11'::date
      AND occurrence.state = 'current'
  ) THEN
    RAISE EXCEPTION 'The second effective weekly date was not materialized';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue24_series_refs%ROWTYPE;
  v_task_id uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO v_ref FROM issue24_series_refs WHERE purpose = 'count_exclusion';
  SELECT occurrence.task_id INTO v_task_id
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_ref.series_id
    AND occurrence.occurrence_on = '2027-01-11'::date;
  v_result := public.delete_task_internal_p(
    '24000000-0000-4000-8000-000000000014', v_ref.slug, v_task_id,
    'user_requested', '2027-01-11 16:00:00+00'::timestamptz
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT occurrence.state FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_ref.series_id
        AND occurrence.occurrence_on = '2027-01-11'::date) IS DISTINCT FROM 'excluded' THEN
    RAISE EXCEPTION 'Deleting the weekly date did not retain its consumed exclusion';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_ref issue24_series_refs%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_job record;
  v_result jsonb;
  v_processed boolean := false;
BEGIN
  SELECT * INTO v_ref FROM issue24_series_refs WHERE purpose = 'count_exclusion';
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2027-01-14 15:00:00+00'::timestamptz
    )
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2027-01-14 15:00:00+00'::timestamptz
    );
    IF v_job.series_id = v_ref.series_id THEN
      v_processed := v_result->>'status' = 'confirmed';
    END IF;
  END LOOP;
  SELECT * INTO v_series FROM public.daily_repetition_series
  WHERE id = v_ref.series_id;
  IF NOT v_processed
    OR v_series.state IS DISTINCT FROM 'finished'
    OR v_series.latest_occurrence_on IS DISTINCT FROM '2027-01-13'::date
    OR v_series.consumed_count IS DISTINCT FROM 4
    OR v_series.next_due_on IS NOT NULL
    OR (SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_ref.series_id
        AND occurrence.occurrence_on = '2027-01-11'::date
        AND occurrence.state = 'excluded') <> 1
    OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_ref.series_id
        AND occurrence.occurrence_on = '2027-01-13'::date
        AND occurrence.state = 'current'
    )
    OR EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_ref.series_id
        AND occurrence.occurrence_on > '2027-01-13'::date
    ) THEN
    RAISE EXCEPTION 'C110-AC50 extended or skipped an effective weekly date: %', v_series;
  END IF;
END;
$$;
COMMIT;

-- Issue #24: local calendar days differ by zone, and invalid patterns are
-- rejected through the public preview RPC before durable state is created.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_now timestamptz := '2027-01-01 01:00:00+00'::timestamptz;
  v_invalid_intervals_rejected boolean := false;
  v_empty_days_rejected boolean := false;
  v_null_day_rejected boolean := false;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'weekly_preview';
  IF public.board_calendar_day('Pacific/Kiritimati', v_now) IS DISTINCT FROM '2027-01-01'::date
    OR public.board_calendar_day('America/Los_Angeles', v_now) IS DISTINCT FROM '2026-12-31'::date
    OR public.board_calendar_day(
      'America/Los_Angeles', '2027-01-01 09:00:00+00'::timestamptz
    ) IS DISTINCT FROM '2027-01-01'::date THEN
    RAISE EXCEPTION 'Synthetic clock did not cross local midnight independently by board zone';
  END IF;
  BEGIN
    PERFORM public.preview_repetition_p(
      v_ref.slug, v_ref.task_id, '2026-12-28'::date, NULL, 3,
      '{"frequency":"weekly","interval":0,"weekdays":[1]}'::jsonb
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_invalid_intervals_rejected := true;
  END;
  BEGIN
    PERFORM public.preview_repetition_p(
      v_ref.slug, v_ref.task_id, '2026-12-28'::date, NULL, 3,
      '{"frequency":"weekly","interval":1,"weekdays":[]}'::jsonb
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_empty_days_rejected := true;
  END;
  BEGIN
    PERFORM public.preview_repetition_p(
      v_ref.slug, v_ref.task_id, '2026-12-28'::date, NULL, 1,
      '{"frequency":"weekly","interval":1,"weekdays":[null]}'::jsonb
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_null_day_rejected := true;
  END;
  IF NOT v_invalid_intervals_rejected OR NOT v_empty_days_rejected
    OR NOT v_null_day_rejected THEN
    RAISE EXCEPTION 'Weekly pattern validation accepted a nonpositive interval or invalid weekday selection';
  END IF;
END;
$$;
COMMIT;

-- Issue #24: local weekly patterns cross ISO years without holiday lookup,
-- while durable job availability and catch-up use each board's local day.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_created jsonb;
  v_due_edit jsonb;
  v_preview jsonb;
  v_task_id uuid;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'weekly_preview';
  v_created := public.create_task_p(
    '24000000-0000-4000-8000-000000000015', v_ref.board_id, v_ref.column_id,
    'Preview semanal entre años', NULL, 'low'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '24000000-0000-4000-8000-000000000016', v_ref.slug, v_task_id,
    '{"due_on":"2026-12-28"}'::jsonb, '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic year-boundary preview task setup failed: %', v_due_edit;
  END IF;
  v_preview := public.preview_repetition_p(
    v_ref.slug, v_task_id, '2026-12-28'::date, NULL, 4,
    '{"frequency":"weekly","interval":2,"weekdays":[1,3]}'::jsonb
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'final_on' IS DISTINCT FROM '2027-01-13'
    OR v_preview->'future_dates' IS DISTINCT FROM '["2026-12-30","2027-01-11","2027-01-13"]'::jsonb THEN
    RAISE EXCEPTION 'Weekly preview did not preserve its Monday anchor across the year boundary: %', v_preview;
  END IF;
  v_preview := public.preview_repetition_p(
    v_ref.slug, v_task_id, '2026-12-31'::date, NULL, 3,
    '{"frequency":"weekly","interval":1,"weekdays":[1,2,3,4,5]}'::jsonb
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->'future_dates' IS DISTINCT FROM '["2027-01-01","2027-01-04"]'::jsonb THEN
    RAISE EXCEPTION 'Laborables did not include a selected weekday holiday: %', v_preview;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_board record;
  v_column record;
  v_created jsonb;
  v_due_edit jsonb;
  v_result jsonb;
  v_task_id uuid;
BEGIN
  FOR v_fixture IN
    SELECT fixture.purpose, fixture.time_zone, fixture.board_operation,
      fixture.column_operation, fixture.task_operation, fixture.due_operation,
      fixture.series_operation
    FROM (VALUES
      ('zone_kiritimati', 'Pacific/Kiritimati',
        '24000000-0000-4000-8000-000000000021'::uuid,
        '24000000-0000-4000-8000-000000000022'::uuid,
        '24000000-0000-4000-8000-000000000023'::uuid,
        '24000000-0000-4000-8000-000000000024'::uuid,
        '24000000-0000-4000-8000-000000000025'::uuid),
      ('zone_los_angeles', 'America/Los_Angeles',
        '24000000-0000-4000-8000-000000000026'::uuid,
        '24000000-0000-4000-8000-000000000027'::uuid,
        '24000000-0000-4000-8000-000000000028'::uuid,
        '24000000-0000-4000-8000-000000000029'::uuid,
        '24000000-0000-4000-8000-000000000030'::uuid)
    ) AS fixture(
      purpose, time_zone, board_operation, column_operation,
      task_operation, due_operation, series_operation
    )
  LOOP
    SELECT * INTO v_board FROM public.create_board_p(
      'Issue 24 ' || v_fixture.purpose, v_fixture.time_zone, v_fixture.board_operation
    );
    SELECT * INTO v_column FROM public.create_column_p(
      v_board.slug, v_board.id, 'Pendientes', 0
    );
    v_created := public.create_task_p(
      v_fixture.task_operation, v_board.id, v_column.id,
      'Semana de cambio de año', NULL, 'low'
    );
    v_task_id := (v_created->>'task_id')::uuid;
    v_due_edit := public.edit_task_fields_p(
      v_fixture.due_operation, v_board.slug, v_task_id,
      '{"due_on":"2026-12-31"}'::jsonb, '{"due_on":1}'::jsonb
    );
    IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Synthetic timezone task setup failed: %', v_due_edit;
    END IF;
    v_result := public.create_repetition_p(
      v_fixture.series_operation, v_board.slug, v_task_id,
      '2026-12-31'::date, NULL, 3, 2, false, NULL,
      '{"frequency":"weekly","interval":1,"weekdays":[5]}'::jsonb
    );
    IF v_result->>'status' IS DISTINCT FROM 'confirmed'
      OR v_result->>'next_due_on' IS DISTINCT FROM '2027-01-01' THEN
      RAISE EXCEPTION 'Synthetic timezone weekly series setup failed: %', v_result;
    END IF;
    INSERT INTO issue24_series_refs(purpose, series_id, task_id, board_id, slug)
    VALUES (v_fixture.purpose, (v_result->>'series_id')::uuid,
      v_task_id, v_board.id, v_board.slug);
  END LOOP;
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_kiritimati issue24_series_refs%ROWTYPE;
  v_los_angeles issue24_series_refs%ROWTYPE;
  v_job record;
  v_result jsonb;
  v_kiritimati_processed boolean := false;
  v_los_angeles_claimed boolean := false;
BEGIN
  SELECT * INTO v_kiritimati FROM issue24_series_refs WHERE purpose = 'zone_kiritimati';
  SELECT * INTO v_los_angeles FROM issue24_series_refs WHERE purpose = 'zone_los_angeles';
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2027-01-01 01:00:00+00'::timestamptz
    )
  LOOP
    IF v_job.series_id = v_los_angeles.series_id THEN
      v_los_angeles_claimed := true;
    END IF;
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2027-01-01 01:00:00+00'::timestamptz
    );
    IF v_job.series_id = v_kiritimati.series_id THEN
      v_kiritimati_processed := v_result->>'status' = 'confirmed'
        AND v_result->>'occurrence_on' = '2027-01-01';
    END IF;
  END LOOP;
  IF NOT v_kiritimati_processed OR v_los_angeles_claimed
    OR (SELECT latest_occurrence_on FROM public.daily_repetition_series
      WHERE id = v_kiritimati.series_id) IS DISTINCT FROM '2027-01-01'::date
    OR (SELECT latest_occurrence_on FROM public.daily_repetition_series
      WHERE id = v_los_angeles.series_id) IS DISTINCT FROM '2026-12-31'::date THEN
    RAISE EXCEPTION 'Year-boundary worker did not honor each board-local midnight';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_los_angeles issue24_series_refs%ROWTYPE;
  v_job record;
  v_result jsonb;
  v_processed boolean := false;
BEGIN
  SELECT * INTO v_los_angeles FROM issue24_series_refs WHERE purpose = 'zone_los_angeles';
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2027-01-01 09:00:00+00'::timestamptz
    )
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2027-01-01 09:00:00+00'::timestamptz
    );
    IF v_job.series_id = v_los_angeles.series_id THEN
      v_processed := v_result->>'status' = 'confirmed'
        AND v_result->>'occurrence_on' = '2027-01-01';
    END IF;
  END LOOP;
  IF NOT v_processed OR (SELECT latest_occurrence_on
      FROM public.daily_repetition_series WHERE id = v_los_angeles.series_id)
      IS DISTINCT FROM '2027-01-01'::date THEN
    RAISE EXCEPTION 'Los Angeles worker did not advance after its local midnight';
  END IF;
END;
$$;
COMMIT;

-- A late task completion does not become the anchor for later weekly dates;
-- the finite count and latest materialized date still follow the calendar.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue23_refs%ROWTYPE;
  v_created jsonb;
  v_due_edit jsonb;
  v_series_result jsonb;
  v_completed jsonb;
  v_task_id uuid;
BEGIN
  SELECT * INTO v_ref FROM issue23_refs WHERE purpose = 'weekly_preview';
  v_created := public.create_task_p(
    '24000000-0000-4000-8000-000000000031', v_ref.board_id, v_ref.column_id,
    'Completar tarde sin mover la fase', NULL, 'low'
  );
  v_task_id := (v_created->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '24000000-0000-4000-8000-000000000032', v_ref.slug, v_task_id,
    '{"due_on":"2026-01-05"}'::jsonb, '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic late-completion task setup failed: %', v_due_edit;
  END IF;
  v_series_result := public.create_repetition_p(
    '24000000-0000-4000-8000-000000000033', v_ref.slug, v_task_id,
    '2026-01-05'::date, NULL, NULL, 2, false, NULL,
    '{"frequency":"weekly","interval":2,"weekdays":[1]}'::jsonb
  );
  IF v_series_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_series_result->>'next_due_on' IS DISTINCT FROM '2026-01-19' THEN
    RAISE EXCEPTION 'Synthetic late-completion weekly series setup failed: %', v_series_result;
  END IF;
  v_completed := public.set_task_completion_p(
    '24000000-0000-4000-8000-000000000034', v_ref.slug, v_task_id, true, 1
  );
  IF v_completed->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic late-completion task setup failed: %', v_completed;
  END IF;
  -- Freeze the synthetic completion time so the test stays independent of
  -- the machine date while exercising a completion months after the due date.
  UPDATE public.tasks SET completed_at = '2026-11-05 12:00:00+00'::timestamptz
  WHERE id = v_task_id;
  INSERT INTO issue24_series_refs(purpose, series_id, task_id, board_id, slug)
  VALUES ('late_completed_task', (v_series_result->>'series_id')::uuid,
    v_task_id, v_ref.board_id, v_ref.slug);
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_ref issue24_series_refs%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_job record;
  v_result jsonb;
  v_processed boolean := false;
BEGIN
  SELECT * INTO v_ref FROM issue24_series_refs WHERE purpose = 'late_completed_task';
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(
      100, '2026-11-20 15:00:00+00'::timestamptz
    )
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(
      v_job.id, v_job.lease_token, '2026-11-20 15:00:00+00'::timestamptz
    );
    IF v_job.series_id = v_ref.series_id THEN
      v_processed := v_result->>'status' = 'confirmed'
        AND v_result->>'occurrence_on' = '2026-11-09';
    END IF;
  END LOOP;
  SELECT * INTO v_series FROM public.daily_repetition_series
  WHERE id = v_ref.series_id;
  IF NOT v_processed
    OR v_series.latest_occurrence_on IS DISTINCT FROM '2026-11-09'::date
    OR v_series.consumed_count IS DISTINCT FROM 23
    OR v_series.next_due_on IS DISTINCT FROM '2026-11-23'::date
    OR (SELECT is_completed FROM public.tasks WHERE id = v_ref.task_id) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Late completion changed the anchored weekly phase or effective-date count: %', v_series;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: daily preview, explicit first-date confirmation, identity preservation, and conversion deduplication.'
