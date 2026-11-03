BEGIN;

ALTER TABLE public.daily_repetition_series
  ADD COLUMN advance_days integer NOT NULL DEFAULT 0
    CHECK (advance_days >= 0);
ALTER TABLE public.daily_repetition_series
  DROP CONSTRAINT daily_repetition_series_consumed_count_check,
  ADD CONSTRAINT daily_repetition_series_consumed_count_check
    CHECK (consumed_count >= 0);
ALTER TABLE public.daily_repetition_receipts
  ADD COLUMN advance_days integer CHECK (advance_days IS NULL OR advance_days >= 0);
ALTER TABLE public.daily_repetition_receipts
  DROP CONSTRAINT daily_repetition_receipts_action_check,
  ADD CONSTRAINT daily_repetition_receipts_action_check
    CHECK (action IN ('create', 'stop', 'set_count', 'edit'));
ALTER TABLE public.daily_repetition_occurrences
  DROP CONSTRAINT daily_repetition_occurrences_state_check,
  ADD CONSTRAINT daily_repetition_occurrences_state_check
    CHECK (state IN ('current', 'replaced', 'excluded', 'retired', 'purged', 'transferred'));
ALTER TABLE public.daily_repetition_occurrences
  DROP CONSTRAINT daily_repetition_one_slot_per_date;
CREATE UNIQUE INDEX daily_repetition_one_live_slot_per_date_idx
  ON public.daily_repetition_occurrences(series_id, occurrence_on)
  WHERE state IN ('current', 'excluded');
DROP TRIGGER tasks_sync_daily_repetition_template ON public.tasks;
DROP FUNCTION public.sync_daily_repetition_template_tg();

-- Returns the shortest distance between effective dates in the Gregorian
-- calendar cycle. Large values are capped above the largest accepted X.
CREATE FUNCTION public.repetition_minimum_separation_internal_p(
  p_start_on date,
  p_pattern jsonb
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_frequency text;
  v_interval numeric;
  v_minimum numeric;
  v_gap numeric;
  v_previous_serial numeric;
  v_serial numeric;
  v_absolute_month numeric;
  v_absolute_year numeric;
  v_cycle numeric;
  v_phase integer;
  v_start_month integer;
  v_start_year integer;
  v_remainder integer;
  v_left integer;
  v_right integer;
  v_next integer;
  v_gcd integer;
  v_period integer;
  v_index integer;
  v_year integer;
  v_month integer;
  v_target date;
  v_weekdays integer[];
BEGIN
  IF p_start_on IS NULL OR NOT pg_catalog.isfinite(p_start_on) THEN
    RAISE EXCEPTION 'Revisa la fecha inicial de la repetición' USING ERRCODE = '22023';
  END IF;
  v_frequency := v_pattern->>'frequency';
  v_interval := (v_pattern->>'interval')::numeric;

  IF v_frequency = 'daily' THEN
    RETURN least(v_interval, 2147483648::numeric)::bigint;
  ELSIF v_frequency = 'weekly' THEN
    SELECT pg_catalog.array_agg(value::integer ORDER BY value::integer)
      INTO v_weekdays
    FROM pg_catalog.jsonb_array_elements_text(v_pattern->'weekdays') AS day(value);
    FOR v_index IN 2..coalesce(pg_catalog.array_length(v_weekdays, 1), 1) LOOP
      v_gap := v_weekdays[v_index] - v_weekdays[v_index - 1];
      v_minimum := least(coalesce(v_minimum, v_gap), v_gap);
    END LOOP;
    v_gap := 7 * v_interval - v_weekdays[pg_catalog.array_length(v_weekdays, 1)]
      + v_weekdays[1];
    v_minimum := least(coalesce(v_minimum, v_gap), v_gap);
    RETURN least(v_minimum, 2147483648::numeric)::bigint;
  ELSIF v_frequency = 'monthly' THEN
    v_remainder := pg_catalog.mod(v_interval, 4800)::integer;
    v_left := 4800;
    v_right := CASE WHEN v_remainder = 0 THEN 4800 ELSE v_remainder END;
    WHILE v_right <> 0 LOOP
      v_next := pg_catalog.mod(v_left, v_right);
      v_left := v_right;
      v_right := v_next;
    END LOOP;
    v_gcd := v_left;
    v_period := 4800 / v_gcd;
    v_start_year := pg_catalog.mod(
      pg_catalog.mod(extract(year FROM p_start_on)::integer - 2000, 400) + 400,
      400
    );
    v_start_month := v_start_year * 12 + extract(month FROM p_start_on)::integer - 1;
    FOR v_index IN 0..(v_period * 2 - 1) LOOP
      v_absolute_month := v_start_month + v_index::numeric * v_interval;
      v_cycle := pg_catalog.floor(v_absolute_month / 4800);
      v_phase := pg_catalog.mod(v_absolute_month, 4800)::integer;
      v_year := 2000 + pg_catalog.floor(v_phase / 12)::integer;
      v_month := pg_catalog.mod(v_phase, 12) + 1;
      IF v_pattern ? 'ordinal' THEN
        v_target := public.repetition_calendar_ordinal_on_internal_p(
          v_year, v_month, (v_pattern->>'ordinal')::integer,
          (v_pattern->>'weekday')::integer
        );
      ELSE
        v_target := public.repetition_calendar_month_day_internal_p(
          v_year, v_month, (v_pattern->>'day_of_month')::integer
        );
      END IF;
      IF v_target IS NOT NULL THEN
        v_serial := v_cycle * 146097 + (v_target - date '2000-01-01');
        IF v_previous_serial IS NOT NULL THEN
          v_gap := v_serial - v_previous_serial;
          IF v_gap > 0 THEN v_minimum := least(coalesce(v_minimum, v_gap), v_gap); END IF;
        END IF;
        v_previous_serial := v_serial;
      END IF;
    END LOOP;
  ELSIF v_frequency = 'yearly' THEN
    v_remainder := pg_catalog.mod(v_interval, 400)::integer;
    v_left := 400;
    v_right := CASE WHEN v_remainder = 0 THEN 400 ELSE v_remainder END;
    WHILE v_right <> 0 LOOP
      v_next := pg_catalog.mod(v_left, v_right);
      v_left := v_right;
      v_right := v_next;
    END LOOP;
    v_gcd := v_left;
    v_period := 400 / v_gcd;
    v_start_year := pg_catalog.mod(
      pg_catalog.mod(extract(year FROM p_start_on)::integer - 2000, 400) + 400,
      400
    );
    FOR v_index IN 0..(v_period * 2 - 1) LOOP
      v_absolute_year := v_start_year + v_index::numeric * v_interval;
      v_cycle := pg_catalog.floor(v_absolute_year / 400);
      v_phase := pg_catalog.mod(v_absolute_year, 400)::integer;
      v_year := 2000 + v_phase;
      IF v_pattern ? 'ordinal' THEN
        v_target := public.repetition_calendar_ordinal_on_internal_p(
          v_year, (v_pattern->>'month')::integer,
          (v_pattern->>'ordinal')::integer, (v_pattern->>'weekday')::integer
        );
      ELSE
        v_target := public.repetition_calendar_month_day_internal_p(
          v_year, (v_pattern->>'month')::integer,
          (v_pattern->>'day_of_month')::integer
        );
      END IF;
      IF v_target IS NOT NULL THEN
        v_serial := v_cycle * 146097 + (v_target - date '2000-01-01');
        IF v_previous_serial IS NOT NULL THEN
          v_gap := v_serial - v_previous_serial;
          IF v_gap > 0 THEN v_minimum := least(coalesce(v_minimum, v_gap), v_gap); END IF;
        END IF;
        v_previous_serial := v_serial;
      END IF;
    END LOOP;
  END IF;

  RETURN least(coalesce(v_minimum, 2147483648::numeric), 2147483648::numeric)::bigint;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_minimum_separation_internal_p(date, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.preview_repetition_with_advance_p(
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date,
  p_occurrence_limit bigint,
  p_pattern jsonb,
  p_advance_days integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_minimum bigint;
  v_result jsonb;
  v_appearance_dates jsonb;
BEGIN
  IF p_advance_days IS NULL OR p_advance_days < 0 THEN
    RAISE EXCEPTION 'La anticipación debe ser un número de días no negativo' USING ERRCODE = '22023';
  END IF;
  v_minimum := public.repetition_minimum_separation_internal_p(p_start_on, v_pattern);
  IF p_advance_days >= v_minimum THEN
    RAISE EXCEPTION 'La anticipación debe ser menor que la separación mínima de % días', v_minimum
      USING ERRCODE = '22023';
  END IF;
  v_result := public.preview_repetition_internal_p(
    p_slug, p_task_id, p_start_on, p_end_on, p_occurrence_limit,
    pg_catalog.statement_timestamp(), v_pattern
  );
  IF v_result->>'status' IS DISTINCT FROM 'available' THEN RETURN v_result; END IF;
  SELECT coalesce(pg_catalog.jsonb_agg(
    ((value::date - p_advance_days)::text) ORDER BY ordinality
  ), '[]'::jsonb) INTO v_appearance_dates
  FROM pg_catalog.jsonb_array_elements_text(v_result->'future_dates')
    WITH ORDINALITY AS date_value(value, ordinality);
  RETURN v_result || pg_catalog.jsonb_build_object(
    'advance_days', p_advance_days,
    'minimum_separation_days', v_minimum,
    'appearance_dates', v_appearance_dates
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_repetition_with_advance_p(
  text, uuid, date, date, bigint, jsonb, integer
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_repetition_with_advance_p(
  text, uuid, date, date, bigint, jsonb, integer
) TO authenticated;

CREATE FUNCTION public.create_repetition_with_advance_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date,
  p_occurrence_limit bigint,
  p_expected_due_on_version bigint,
  p_confirm_start_change boolean,
  p_previous_series_id uuid,
  p_pattern jsonb,
  p_advance_days integer,
  p_appearance_column_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_minimum bigint;
  v_receipt public.daily_repetition_receipts%ROWTYPE;
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
  v_time_zone text;
  v_appearance_on date;
  v_appearance_column_id uuid;
  v_board_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_advance_days IS NULL OR p_advance_days < 0 THEN
    RAISE EXCEPTION 'La anticipación debe ser un número de días no negativo' USING ERRCODE = '22023';
  END IF;
  v_minimum := public.repetition_minimum_separation_internal_p(p_start_on, v_pattern);
  IF p_advance_days >= v_minimum THEN
    RAISE EXCEPTION 'La anticipación debe ser menor que la separación mínima de % días', v_minimum
      USING ERRCODE = '22023';
  END IF;
  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND AND v_receipt.action = 'create' THEN
    IF coalesce(v_receipt.advance_days, 0) <> p_advance_days
      OR (p_appearance_column_id IS NOT NULL
        AND v_receipt.result->>'appearance_column_id' IS DISTINCT FROM p_appearance_column_id::text) THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otra anticipación o columna' USING ERRCODE = '23514';
    END IF;
    RETURN v_receipt.result;
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT column_row.id INTO v_appearance_column_id
  FROM public.columns AS column_row
  JOIN public.tasks AS task ON task.id = p_task_id
  WHERE column_row.id = coalesce(p_appearance_column_id, task.column_id)
    AND column_row.board_id = v_board_id
    AND column_row.generation_id = (
      SELECT board.active_generation_id FROM public.boards AS board WHERE board.id = v_board_id
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La columna elegida ya no pertenece al tablero' USING ERRCODE = '22023';
  END IF;

  v_result := public.create_repetition_p(
    p_operation_id, p_slug, p_task_id, p_start_on, p_end_on,
    p_occurrence_limit, p_expected_due_on_version, p_confirm_start_change,
    p_previous_series_id, v_pattern
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN RETURN v_result; END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid
  FOR UPDATE;
  SELECT board.time_zone INTO v_time_zone
  FROM public.boards AS board WHERE board.id = v_series.board_id;
  v_appearance_on := CASE WHEN v_series.next_due_on IS NULL THEN NULL
    ELSE v_series.next_due_on - p_advance_days END;
  UPDATE public.daily_repetition_series AS series
  SET advance_days = p_advance_days,
      appearance_column_id = v_appearance_column_id
  WHERE series.id = v_series.id;
  UPDATE public.daily_repetition_jobs AS job
  SET available_at = (job.scheduled_on - p_advance_days)::timestamp AT TIME ZONE v_time_zone,
      updated_at = pg_catalog.clock_timestamp()
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.series_revision = v_series.revision
    AND job.state IN ('queued', 'retry_wait');
  v_result := v_result || pg_catalog.jsonb_build_object(
    'advance_days', p_advance_days,
    'appearance_column_id', v_appearance_column_id,
    'appearance_on', v_appearance_on,
    'minimum_separation_days', v_minimum
  );
  UPDATE public.daily_repetition_receipts AS receipt
  SET advance_days = p_advance_days, result = v_result
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_repetition_with_advance_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb, integer, uuid
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_repetition_with_advance_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb, integer, uuid
) TO authenticated;

CREATE OR REPLACE FUNCTION public.advance_daily_repetition_internal_p(
  p_job public.daily_repetition_jobs,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series public.daily_repetition_series%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_column public.columns%ROWTYPE;
  v_series_board_id uuid;
  v_series_generation_id uuid;
  v_pattern jsonb;
  v_today date;
  v_appearance_on date;
  v_through_on date;
  v_final_on date;
  v_target_on date;
  v_next_due_on date;
  v_effective_count bigint;
  v_consumed_count bigint;
  v_new_task_id uuid := pg_catalog.gen_random_uuid();
  v_new_occurrence_id uuid;
  v_position integer;
  v_actor_id uuid;
  v_assignee_id uuid;
  v_creator_id uuid;
  v_previous_sub text;
  v_new_steps jsonb;
  v_finished boolean;
BEGIN
  -- Resolve the board FK without taking a row lock so every worker follows
  -- the board -> series -> job order used by series edits.
  SELECT series.board_id, series.generation_id
  INTO v_series_board_id, v_series_generation_id
  FROM public.daily_repetition_series AS series
  WHERE series.id = p_job.series_id;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'superseded'); END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_series_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'series_unavailable');
  END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = p_job.series_id
  FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'superseded'); END IF;

  SELECT job.* INTO v_job
  FROM public.daily_repetition_jobs AS job
  WHERE job.id = p_job.id
  FOR UPDATE;
  IF NOT FOUND OR v_job.state = 'superseded' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'superseded');
  END IF;
  IF v_job.state IN ('succeeded', 'dead_letter') THEN
    RETURN pg_catalog.jsonb_build_object('status', 'already_processed');
  END IF;
  IF v_job.state IS DISTINCT FROM p_job.state
    OR v_job.series_id IS DISTINCT FROM p_job.series_id
    OR v_job.series_revision IS DISTINCT FROM p_job.series_revision
    OR v_job.scheduled_on IS DISTINCT FROM p_job.scheduled_on
    OR v_job.lease_token IS DISTINCT FROM p_job.lease_token
    OR (v_job.state = 'leased' AND v_job.lease_expires_at <= p_now) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'lease_lost');
  END IF;
  IF v_series.board_id IS DISTINCT FROM v_series_board_id
    OR v_series.generation_id IS DISTINCT FROM v_series_generation_id THEN
    RETURN pg_catalog.jsonb_build_object('status', 'superseded');
  END IF;
  IF v_board.active_generation_id IS DISTINCT FROM v_series.generation_id THEN
    UPDATE public.daily_repetition_series AS series
    SET state = 'stopped', next_due_on = NULL, stopped_at = p_now,
        revision = series.revision + 1, updated_at = p_now
    WHERE series.id = v_series.id;
    RETURN pg_catalog.jsonb_build_object('status', 'series_unavailable');
  END IF;
  IF v_series.state IS DISTINCT FROM 'active'
    OR v_series.revision IS DISTINCT FROM v_job.series_revision
    OR v_series.next_due_on IS DISTINCT FROM v_job.scheduled_on THEN
    RETURN pg_catalog.jsonb_build_object('status', 'superseded');
  END IF;

  v_pattern := v_series.calendar_pattern;
  v_today := public.board_calendar_day(v_board.time_zone, p_now);
  v_appearance_on := v_job.scheduled_on - v_series.advance_days;
  IF v_today < v_appearance_on THEN
    UPDATE public.daily_repetition_jobs AS job
    SET state = 'queued',
        available_at = v_appearance_on::timestamp AT TIME ZONE v_board.time_zone,
        lease_token = NULL, lease_expires_at = NULL, updated_at = p_now
    WHERE job.id = v_job.id;
    RETURN pg_catalog.jsonb_build_object('status', 'not_due');
  END IF;

  IF v_series.occurrence_limit IS NOT NULL THEN
    v_final_on := public.repetition_calendar_occurrence_on_internal_p(
      v_series.start_on, v_series.occurrence_limit, v_pattern
    );
  ELSIF v_series.end_on IS NOT NULL THEN
    v_effective_count := public.repetition_calendar_count_internal_p(
      v_series.start_on, v_series.end_on, v_pattern
    );
    v_final_on := public.repetition_calendar_occurrence_on_internal_p(
      v_series.start_on, greatest(1, v_effective_count), v_pattern
    );
  END IF;

  IF v_final_on IS NOT NULL AND v_series.latest_occurrence_on >= v_final_on THEN
    UPDATE public.daily_repetition_series AS series
    SET state = 'finished', next_due_on = NULL, revision = series.revision + 1,
        updated_at = p_now
    WHERE series.id = v_series.id;
    RETURN pg_catalog.jsonb_build_object('status', 'finished');
  END IF;
  IF v_series.occurrence_limit IS NOT NULL
    AND v_series.consumed_count >= v_series.occurrence_limit THEN
    UPDATE public.daily_repetition_series AS series
    SET state = 'finished', next_due_on = NULL, revision = series.revision + 1,
        updated_at = p_now
    WHERE series.id = v_series.id;
    RETURN pg_catalog.jsonb_build_object('status', 'finished');
  END IF;

  v_through_on := CASE
    WHEN v_today < v_job.scheduled_on THEN v_job.scheduled_on
    WHEN v_final_on IS NOT NULL THEN least(v_today, v_final_on)
    ELSE v_today END;
  v_effective_count := public.repetition_calendar_count_internal_p(
    v_series.start_on, v_through_on, v_pattern
  );
  IF v_effective_count < 1 THEN RETURN pg_catalog.jsonb_build_object('status', 'not_due'); END IF;
  v_target_on := public.repetition_calendar_occurrence_on_internal_p(
    v_series.start_on, v_effective_count, v_pattern
  );
  IF v_target_on < v_series.next_due_on THEN
    RETURN pg_catalog.jsonb_build_object('status', 'not_due');
  END IF;
  v_consumed_count := greatest(v_series.consumed_count, v_effective_count);
  v_next_due_on := public.repetition_calendar_next_on_internal_p(
    v_series.start_on, v_target_on, v_final_on, v_pattern
  );
  v_finished := (v_final_on IS NOT NULL AND v_target_on >= v_final_on)
    OR (v_series.occurrence_limit IS NOT NULL
      AND v_consumed_count >= v_series.occurrence_limit)
    OR v_next_due_on IS NULL;
  IF v_finished THEN v_next_due_on := NULL; END IF;

  IF EXISTS (
    SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.series_id = v_series.id
      AND occurrence.occurrence_on = v_target_on
      AND occurrence.state IN ('current', 'excluded')
  ) THEN
    UPDATE public.daily_repetition_series AS series
    SET state = CASE WHEN v_finished THEN 'finished' ELSE 'active' END,
        latest_occurrence_on = greatest(series.latest_occurrence_on, v_target_on),
        consumed_count = greatest(series.consumed_count, v_consumed_count),
        next_due_on = v_next_due_on,
        revision = series.revision + 1, updated_at = p_now
    WHERE series.id = v_series.id;
    IF NOT v_finished THEN
      SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
      WHERE series.id = v_series.id;
      INSERT INTO public.daily_repetition_jobs(
        job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
      ) VALUES (
        'advance', v_series.id, v_series.revision, v_series.next_due_on,
        pg_catalog.format('advance:%s:%s:%s', v_series.id, v_series.revision, v_series.next_due_on),
        (v_series.next_due_on - v_series.advance_days)::timestamp AT TIME ZONE v_board.time_zone
      ) ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'already_present', 'occurrence_on', v_target_on,
      'consumed_count', v_consumed_count, 'next_due_on', v_next_due_on
    );
  END IF;

  SELECT column_row.* INTO v_column
  FROM public.columns AS column_row
  WHERE column_row.id = v_series.appearance_column_id
    AND column_row.board_id = v_series.board_id
    AND column_row.generation_id = v_series.generation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Series appearance column is unavailable' USING ERRCODE = '23503';
  END IF;
  v_position := coalesce((
    SELECT max(task.position) + 1 FROM public.tasks AS task WHERE task.column_id = v_column.id
  ), 0);

  v_assignee_id := NULLIF(v_series.template_snapshot->>'assignee_id', '')::uuid;
  IF v_assignee_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.board_id = v_series.board_id
      AND membership.user_id = v_assignee_id AND membership.revoked_at IS NULL
      AND public.is_enabled_application_identity_p(v_assignee_id)
  ) THEN v_assignee_id := NULL; END IF;
  IF EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.board_id = v_series.board_id
      AND membership.user_id = v_series.created_by AND membership.revoked_at IS NULL
      AND public.is_enabled_application_identity_p(v_series.created_by)
  ) THEN v_creator_id := v_series.created_by; END IF;

  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', pg_catalog.gen_random_uuid(), 'text', step.value->>'text',
    'is_completed', false,
    'position', coalesce((step.value->>'position')::integer, (step.ordinality - 1)::integer),
    'version', 1
  ) ORDER BY step.ordinality), '[]'::jsonb) INTO v_new_steps
  FROM pg_catalog.jsonb_array_elements(v_series.template_snapshot->'steps')
    WITH ORDINALITY AS step(value, ordinality);

  SELECT membership.user_id INTO v_actor_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_series.board_id AND membership.revoked_at IS NULL
    AND public.is_enabled_application_identity_p(membership.user_id)
  ORDER BY (membership.user_id = v_series.created_by) DESC,
    (membership.user_id = v_board.owner_id) DESC, membership.joined_at
  LIMIT 1;
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'No enabled board member can authorize the daily occurrence'
      USING ERRCODE = '42501';
  END IF;
  v_previous_sub := current_setting('request.jwt.claim.sub', true);
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', v_actor_id::text, true);

  INSERT INTO public.tasks(
    id, column_id, title, description, priority, position, due_on,
    field_versions, assignee_id, is_completed, completed_at,
    completion_version, assignee_version, steps, steps_order_version, checklist_version,
    created_by
  ) VALUES (
    v_new_task_id, v_column.id, v_series.template_snapshot->>'title',
    v_series.template_snapshot->>'description', v_series.template_snapshot->>'priority',
    v_position, v_target_on, '{"title":1,"description":1,"priority":1,"due_on":1}'::jsonb,
    v_assignee_id, false, NULL, 1, 1, v_new_steps, 1, 1, v_creator_id
  );
  PERFORM pg_catalog.set_config('request.jwt.claim.sub', coalesce(v_previous_sub, ''), true);

  UPDATE public.daily_repetition_occurrences AS occurrence
  SET state = 'replaced'
  WHERE occurrence.id = v_series.current_occurrence_id AND occurrence.state = 'current';
  INSERT INTO public.daily_repetition_occurrences(series_id, occurrence_on, task_id, state)
  VALUES (v_series.id, v_target_on, v_new_task_id, 'current')
  RETURNING id INTO v_new_occurrence_id;

  UPDATE public.daily_repetition_series AS series
  SET latest_occurrence_on = v_target_on,
      consumed_count = greatest(series.consumed_count, v_consumed_count),
      current_occurrence_id = v_new_occurrence_id,
      state = CASE WHEN v_finished THEN 'finished' ELSE 'active' END,
      next_due_on = v_next_due_on,
      revision = series.revision + 1,
      updated_at = p_now
  WHERE series.id = v_series.id;

  SELECT series.* INTO v_series FROM public.daily_repetition_series AS series
  WHERE series.id = v_series.id;
  IF v_series.state = 'active' THEN
    INSERT INTO public.daily_repetition_jobs(
      job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
    ) VALUES (
      'advance', v_series.id, v_series.revision, v_series.next_due_on,
      pg_catalog.format('advance:%s:%s:%s', v_series.id, v_series.revision, v_series.next_due_on),
      (v_series.next_due_on - v_series.advance_days)::timestamp AT TIME ZONE v_board.time_zone
    ) ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'series_id', v_series.id,
    'occurrence_on', v_target_on, 'task_id', v_new_task_id,
    'series_state', v_series.state, 'consumed_count', v_series.consumed_count,
    'next_due_on', v_series.next_due_on
  );
END;
$$;
REVOKE ALL ON FUNCTION public.advance_daily_repetition_internal_p(
  public.daily_repetition_jobs, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

-- Advance workers resolve the board first, so the dispatcher must not hold a
-- job-row lock while they wait for the board. The advance function re-locks
-- and validates its job after board and series; purge jobs keep their job-first
-- path because they do not participate in the series lock order.
CREATE OR REPLACE FUNCTION public.process_daily_repetition_job_internal_p(
  p_job_id uuid,
  p_lease_token uuid,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_result jsonb;
  v_failed boolean := false;
  v_error_code text;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_job_id IS NULL OR p_lease_token IS NULL
    OR p_now IS NULL OR NOT pg_catalog.isfinite(p_now) THEN
    RAISE EXCEPTION 'A leased job and valid timestamp are required' USING ERRCODE = '22023';
  END IF;
  SELECT job.* INTO v_job
  FROM public.daily_repetition_jobs AS job
  WHERE job.id = p_job_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'lease_lost');
  END IF;
  IF v_job.state IN ('succeeded', 'superseded') THEN
    RETURN pg_catalog.jsonb_build_object('status', 'already_processed');
  END IF;
  IF v_job.state IS DISTINCT FROM 'leased'
    OR v_job.lease_token IS DISTINCT FROM p_lease_token
    OR v_job.lease_expires_at <= p_now THEN
    RETURN pg_catalog.jsonb_build_object('status', 'lease_lost');
  END IF;

  IF v_job.job_kind = 'purge' THEN
    SELECT job.* INTO v_job
    FROM public.daily_repetition_jobs AS job
    WHERE job.id = p_job_id
    FOR UPDATE;
    IF NOT FOUND OR v_job.state IS DISTINCT FROM 'leased'
      OR v_job.lease_token IS DISTINCT FROM p_lease_token
      OR v_job.lease_expires_at <= p_now THEN
      RETURN pg_catalog.jsonb_build_object('status', 'lease_lost');
    END IF;
  END IF;

  BEGIN
    IF v_job.job_kind = 'advance' THEN
      v_result := public.advance_daily_repetition_internal_p(v_job, p_now);
    ELSE
      v_result := pg_catalog.jsonb_build_object(
        'status', 'confirmed',
        'purged_tasks', public.purge_daily_repetition_tasks_internal_p(1000, p_now)
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error_code = RETURNED_SQLSTATE;
    v_failed := true;
  END;

  IF v_failed THEN
    UPDATE public.daily_repetition_jobs AS job
    SET state = CASE WHEN job.attempt_count >= job.max_attempts
        THEN 'dead_letter' ELSE 'retry_wait' END,
        available_at = CASE WHEN job.attempt_count >= job.max_attempts
          THEN job.available_at
          ELSE p_now + least(interval '1 hour',
            interval '30 seconds' * pg_catalog.power(2::numeric,
              greatest(0, job.attempt_count - 1))::double precision) END,
        lease_token = NULL, lease_expires_at = NULL,
        last_error_code = v_error_code, last_error_at = p_now,
        completed_at = CASE WHEN job.attempt_count >= job.max_attempts THEN p_now ELSE NULL END,
        updated_at = p_now
    WHERE job.id = v_job.id;
    IF v_job.job_kind = 'purge' AND v_job.attempt_count >= v_job.max_attempts THEN
      INSERT INTO public.daily_repetition_jobs(job_kind, dedupe_key, available_at)
      VALUES ('purge', pg_catalog.format('purge:after:%s', v_job.id), p_now + interval '1 hour')
      ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', CASE WHEN v_job.attempt_count >= v_job.max_attempts
        THEN 'dead_letter' ELSE 'retry_wait' END,
      'error_code', v_error_code, 'attempt_count', v_job.attempt_count,
      'available_at', CASE WHEN v_job.attempt_count >= v_job.max_attempts
        THEN NULL ELSE p_now + least(interval '1 hour',
          interval '30 seconds' * pg_catalog.power(2::numeric,
            greatest(0, v_job.attempt_count - 1))::double precision) END
    );
  END IF;

  IF v_result->>'status' IN ('not_due', 'lease_lost', 'already_processed') THEN
    RETURN v_result;
  ELSIF v_result->>'status' = 'superseded' THEN
    UPDATE public.daily_repetition_jobs AS job
    SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
        completed_at = p_now, updated_at = p_now
    WHERE job.id = v_job.id;
    RETURN v_result;
  END IF;

  UPDATE public.daily_repetition_jobs AS job
  SET state = 'succeeded', lease_token = NULL, lease_expires_at = NULL,
      completed_at = p_now, updated_at = p_now
  WHERE job.id = v_job.id;
  IF v_job.job_kind = 'purge' THEN
    INSERT INTO public.daily_repetition_jobs(job_kind, dedupe_key, available_at)
    VALUES ('purge', pg_catalog.format('purge:after:%s', v_job.id), p_now + interval '1 hour')
    ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;
  RETURN coalesce(v_result, pg_catalog.jsonb_build_object('status', 'confirmed'));
END;
$$;
REVOKE ALL ON FUNCTION public.process_daily_repetition_job_internal_p(uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.claim_daily_repetition_jobs_internal_p(
  p_limit integer,
  p_now timestamptz
)
RETURNS TABLE (
  id uuid,
  job_kind text,
  series_id uuid,
  series_revision bigint,
  scheduled_on date,
  lease_token uuid,
  lease_expires_at timestamptz,
  attempt_count integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_candidate record;
  v_board_id uuid;
  v_series public.daily_repetition_series%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_claimed integer := 0;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR p_now IS NULL OR NOT pg_catalog.isfinite(p_now) THEN
    RAISE EXCEPTION 'Choose a valid worker batch and timestamp' USING ERRCODE = '22023';
  END IF;

  FOR v_candidate IN
    SELECT job.id, job.job_kind, job.series_id, job.state,
      job.lease_expires_at, job.attempt_count, job.max_attempts, series.board_id,
      series.id AS candidate_series_id
    FROM public.daily_repetition_jobs AS job
    LEFT JOIN public.daily_repetition_series AS series ON series.id = job.series_id
    WHERE (
        job.state IN ('queued', 'retry_wait') AND job.available_at <= p_now
      ) OR (
        job.state = 'leased' AND job.lease_expires_at <= p_now
      )
    ORDER BY series.board_id NULLS FIRST, series.id NULLS FIRST,
      job.available_at, job.created_at, job.id
  LOOP
    -- Preserve the worker's full expired-lease sweep after the claim batch is
    -- full, without taking locks for additional ready jobs.
    IF v_claimed >= p_limit AND NOT (
      v_candidate.state = 'leased'
      AND v_candidate.lease_expires_at <= p_now
      AND v_candidate.attempt_count >= v_candidate.max_attempts
    ) THEN
      CONTINUE;
    END IF;

    IF v_candidate.job_kind = 'advance' THEN
      SELECT board.id INTO v_board_id
      FROM public.boards AS board
      WHERE board.id = v_candidate.board_id
      FOR UPDATE;
      IF NOT FOUND THEN CONTINUE; END IF;

      SELECT series.* INTO v_series
      FROM public.daily_repetition_series AS series
      WHERE series.id = v_candidate.candidate_series_id
      FOR UPDATE;
      IF NOT FOUND OR v_series.board_id IS DISTINCT FROM v_board_id THEN
        CONTINUE;
      END IF;
    END IF;

    SELECT job.* INTO v_job
    FROM public.daily_repetition_jobs AS job
    WHERE job.id = v_candidate.id
    FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;

    IF v_job.state = 'leased' AND v_job.lease_expires_at <= p_now
      AND v_job.attempt_count >= v_job.max_attempts THEN
      UPDATE public.daily_repetition_jobs AS job
      SET state = 'dead_letter', lease_token = NULL, lease_expires_at = NULL,
          last_error_code = coalesce(job.last_error_code, 'lease_expired'),
          last_error_at = p_now, completed_at = p_now, updated_at = p_now
      WHERE job.id = v_job.id;
      IF v_job.job_kind = 'purge' THEN
        INSERT INTO public.daily_repetition_jobs(job_kind, dedupe_key, available_at)
        VALUES ('purge', pg_catalog.format('purge:after:%s', v_job.id), p_now + interval '1 hour')
        ON CONFLICT (dedupe_key) DO NOTHING;
      END IF;
      CONTINUE;
    END IF;

    IF NOT (
      v_job.state IN ('queued', 'retry_wait') AND v_job.available_at <= p_now
      OR v_job.state = 'leased' AND v_job.lease_expires_at <= p_now
        AND v_job.attempt_count < v_job.max_attempts
    ) THEN
      CONTINUE;
    END IF;

    IF v_claimed >= p_limit THEN CONTINUE; END IF;

    UPDATE public.daily_repetition_jobs AS job
    SET state = 'leased', lease_token = pg_catalog.gen_random_uuid(),
        lease_expires_at = p_now + interval '2 minutes',
        attempt_count = job.attempt_count + 1, updated_at = p_now
    WHERE job.id = v_job.id
    RETURNING job.* INTO v_job;

    id := v_job.id;
    job_kind := v_job.job_kind;
    series_id := v_job.series_id;
    series_revision := v_job.series_revision;
    scheduled_on := v_job.scheduled_on;
    lease_token := v_job.lease_token;
    lease_expires_at := v_job.lease_expires_at;
    attempt_count := v_job.attempt_count;
    RETURN NEXT;
    v_claimed := v_claimed + 1;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_daily_repetition_jobs_internal_p(integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_repetition_p(p_slug text, p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
BEGIN
  v_result := public.get_daily_repetition_p(p_slug, p_task_id);
  IF v_result->>'status' IS DISTINCT FROM 'available' THEN RETURN v_result; END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  RETURN v_result || pg_catalog.jsonb_build_object(
    'rule', v_series.rule, 'pattern', v_series.calendar_pattern,
    'advance_days', v_series.advance_days,
    'appearance_column_id', v_series.appearance_column_id,
    'template_snapshot', v_series.template_snapshot
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_repetition_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_repetition_p(text, uuid) TO authenticated;

CREATE FUNCTION public.repetition_date_matches_pattern_internal_p(
  p_date date,
  p_pattern jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_frequency text := v_pattern->>'frequency';
  v_expected date;
BEGIN
  IF p_date IS NULL OR NOT pg_catalog.isfinite(p_date) THEN RETURN false; END IF;
  IF v_frequency = 'daily' THEN RETURN true; END IF;
  IF v_frequency = 'weekly' THEN
    RETURN EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements_text(v_pattern->'weekdays') AS day(value)
      WHERE value::integer = extract(isodow FROM p_date)::integer
    );
  END IF;
  IF v_frequency = 'monthly' THEN
    v_expected := CASE WHEN v_pattern ? 'ordinal'
      THEN public.repetition_calendar_ordinal_on_internal_p(
        extract(year FROM p_date)::integer, extract(month FROM p_date)::integer,
        (v_pattern->>'ordinal')::integer, (v_pattern->>'weekday')::integer
      )
      ELSE public.repetition_calendar_month_day_internal_p(
        extract(year FROM p_date)::integer, extract(month FROM p_date)::integer,
        (v_pattern->>'day_of_month')::integer
      ) END;
    RETURN v_expected = p_date;
  END IF;
  IF v_frequency = 'yearly'
    AND extract(month FROM p_date)::integer = (v_pattern->>'month')::integer THEN
    v_expected := CASE WHEN v_pattern ? 'ordinal'
      THEN public.repetition_calendar_ordinal_on_internal_p(
        extract(year FROM p_date)::integer, extract(month FROM p_date)::integer,
        (v_pattern->>'ordinal')::integer, (v_pattern->>'weekday')::integer
      )
      ELSE public.repetition_calendar_month_day_internal_p(
        extract(year FROM p_date)::integer, extract(month FROM p_date)::integer,
        (v_pattern->>'day_of_month')::integer
      ) END;
    RETURN v_expected = p_date;
  END IF;
  RETURN false;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_date_matches_pattern_internal_p(date, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.preview_repetition_edit_p(
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_final_mode text,
  p_future_count bigint,
  p_end_on date,
  p_pattern jsonb,
  p_advance_days integer,
  p_appearance_column_id uuid,
  p_template jsonb,
  p_confirm_date_choice boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_board public.boards%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_current public.tasks%ROWTYPE;
  v_today date;
  v_expected_start date;
  v_start_on date;
  v_final_on date;
  v_final_count bigint;
  v_minimum bigint;
  v_template jsonb;
  v_future_dates jsonb;
  v_appearance_dates jsonb;
  v_preserved_exclusions jsonb;
  v_removed_exclusions jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_task_id IS NULL OR p_start_on IS NULL
    OR p_final_mode NOT IN ('count', 'date', 'none')
    OR p_advance_days IS NULL OR p_advance_days < 0
    OR p_appearance_column_id IS NULL OR p_template IS NULL
    OR (p_end_on IS NOT NULL AND NOT pg_catalog.isfinite(p_end_on))
    OR (p_final_mode = 'count' AND (p_future_count IS NULL OR p_future_count < 1
      OR p_future_count > 2147483648 OR p_end_on IS NOT NULL))
    OR (p_final_mode = 'date' AND (p_end_on IS NULL OR p_future_count IS NOT NULL))
    OR (p_final_mode = 'none' AND (p_end_on IS NOT NULL OR p_future_count IS NOT NULL)) THEN
    RAISE EXCEPTION 'Revisa los cambios de repetición antes de continuar' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_typeof(p_template) IS DISTINCT FROM 'object'
    OR pg_catalog.jsonb_typeof(p_template->'title') IS DISTINCT FROM 'string'
    OR pg_catalog.length(pg_catalog.btrim(p_template->>'title')) NOT BETWEEN 1 AND 200
    OR pg_catalog.jsonb_typeof(p_template->'description') NOT IN ('string', 'null')
    OR pg_catalog.length(p_template->>'description') > 2000
    OR p_template->>'priority' NOT IN ('low', 'medium', 'high', 'urgent')
    OR pg_catalog.jsonb_typeof(p_template->'steps') IS DISTINCT FROM 'array'
    OR EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(
        CASE WHEN pg_catalog.jsonb_typeof(p_template->'steps') = 'array'
          THEN p_template->'steps' ELSE '[]'::jsonb END
      ) AS template_step(value)
      WHERE pg_catalog.jsonb_typeof(template_step.value) IS DISTINCT FROM 'object'
        OR pg_catalog.jsonb_typeof(template_step.value->'text') IS DISTINCT FROM 'string'
        OR pg_catalog.length(pg_catalog.btrim(template_step.value->>'text')) = 0
    ) THEN
    RAISE EXCEPTION 'Revisa la plantilla y sus pasos de checklist' USING ERRCODE = '22023';
  END IF;
  IF p_future_count IS NOT NULL AND p_future_count - 1 > 2147483647 THEN
    RAISE EXCEPTION 'La cantidad de próximas repeticiones supera el calendario disponible'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
  WHERE occurrence.task_id = p_task_id
    AND occurrence.id = series.current_occurrence_id
    AND occurrence.state = 'current'
    AND series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id
    AND series.state = 'active';
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT task.* INTO v_current FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.columns AS column_row
    WHERE column_row.id = p_appearance_column_id AND column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id
  ) THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;

  v_today := public.board_calendar_day(v_board.time_zone, pg_catalog.statement_timestamp());
  v_expected_start := public.repetition_calendar_next_on_internal_p(
    v_series.start_on, greatest(v_series.latest_occurrence_on, v_today), NULL, v_pattern
  );
  IF v_expected_start IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'reason', 'no_future_date',
      'series_revision', v_series.revision, 'time_zone', v_board.time_zone
    );
  END IF;
  IF p_start_on <= greatest(v_series.latest_occurrence_on, v_today)
    OR NOT public.repetition_date_matches_pattern_internal_p(p_start_on, v_pattern) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'available', 'requires_date_choice', true,
      'proposed_start_on', v_expected_start, 'selected_start_on', p_start_on,
      'selected_date_compatible', false,
      'series_id', v_series.id, 'series_revision', v_series.revision,
      'time_zone', v_board.time_zone, 'current_task_id', v_current.id,
      'current_due_on', v_current.due_on
    );
  END IF;
  IF p_start_on IS DISTINCT FROM v_expected_start AND NOT p_confirm_date_choice THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'available', 'requires_date_choice', true,
      'proposed_start_on', v_expected_start, 'selected_start_on', p_start_on,
      'selected_date_compatible', true,
      'series_id', v_series.id, 'series_revision', v_series.revision,
      'time_zone', v_board.time_zone, 'current_task_id', v_current.id,
      'current_due_on', v_current.due_on
    );
  END IF;

  v_minimum := public.repetition_minimum_separation_internal_p(p_start_on, v_pattern);
  IF p_advance_days >= v_minimum THEN
    RAISE EXCEPTION 'La anticipación debe ser menor que la separación mínima de % días', v_minimum
      USING ERRCODE = '22023';
  END IF;
  v_template := v_series.template_snapshot || pg_catalog.jsonb_build_object(
    'title', pg_catalog.btrim(p_template->>'title'),
    'description', p_template->'description',
    'priority', p_template->>'priority',
    'assignee_id', p_template->'assignee_id',
    'steps', (
      SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'text', pg_catalog.btrim(template_step.value->>'text'),
        'position', template_step.ordinality - 1
      ) ORDER BY template_step.ordinality), '[]'::jsonb)
      FROM pg_catalog.jsonb_array_elements(p_template->'steps')
        WITH ORDINALITY AS template_step(value, ordinality)
    )
  );
  IF v_template->'assignee_id' IS NOT NULL
    AND v_template->'assignee_id' <> 'null'::jsonb
    AND NOT EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = v_board.id
        AND membership.user_id = (v_template->>'assignee_id')::uuid
        AND membership.revoked_at IS NULL
        AND public.is_enabled_application_identity_p(membership.user_id)
    ) THEN
    RAISE EXCEPTION 'El responsable ya no tiene acceso a este tablero' USING ERRCODE = '22023';
  END IF;

  IF p_final_mode = 'count' THEN
    v_final_count := p_future_count;
    v_final_on := public.repetition_calendar_occurrence_on_internal_p(
      p_start_on, v_final_count, v_pattern
    );
  ELSIF p_final_mode = 'date' THEN
    IF p_end_on < p_start_on THEN
      RAISE EXCEPTION 'La fecha final debe ser igual o posterior a la próxima fecha'
        USING ERRCODE = '22023';
    END IF;
    v_final_count := public.repetition_calendar_count_internal_p(
      p_start_on, p_end_on, v_pattern
    );
    IF v_final_count < 1 THEN
      RAISE EXCEPTION 'La fecha final no incluye ninguna repetición nueva' USING ERRCODE = '22023';
    END IF;
    v_final_on := public.repetition_calendar_occurrence_on_internal_p(
      p_start_on, v_final_count, v_pattern
    );
  ELSE
    v_final_on := NULL;
  END IF;
  v_start_on := p_start_on;
  v_future_dates := public.repetition_calendar_preview_dates_internal_p(
    v_start_on, v_start_on, v_final_on, v_pattern
  );
  SELECT coalesce(pg_catalog.jsonb_agg(
    ((value::date - p_advance_days)::text) ORDER BY ordinality
  ), '[]'::jsonb) INTO v_appearance_dates
  FROM pg_catalog.jsonb_array_elements_text(v_future_dates)
    WITH ORDINALITY AS date_value(value, ordinality);

  SELECT coalesce(pg_catalog.jsonb_agg(occurrence.occurrence_on ORDER BY occurrence.occurrence_on), '[]'::jsonb)
  INTO v_preserved_exclusions
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series.id AND occurrence.state = 'excluded'
    AND occurrence.occurrence_on > v_series.latest_occurrence_on
    AND (v_final_on IS NULL OR occurrence.occurrence_on <= v_final_on)
    AND public.repetition_calendar_count_internal_p(
      v_start_on, occurrence.occurrence_on, v_pattern
    ) > 0
    AND public.repetition_calendar_occurrence_on_internal_p(
      v_start_on,
      public.repetition_calendar_count_internal_p(v_start_on, occurrence.occurrence_on, v_pattern),
      v_pattern
    ) = occurrence.occurrence_on;
  SELECT coalesce(pg_catalog.jsonb_agg(occurrence.occurrence_on ORDER BY occurrence.occurrence_on), '[]'::jsonb)
  INTO v_removed_exclusions
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series.id AND occurrence.state = 'excluded'
    AND occurrence.occurrence_on > v_series.latest_occurrence_on
    AND (v_final_on IS NOT NULL AND occurrence.occurrence_on > v_final_on
      OR public.repetition_calendar_count_internal_p(
        v_start_on, occurrence.occurrence_on, v_pattern
      ) = 0
      OR public.repetition_calendar_occurrence_on_internal_p(
        v_start_on,
        greatest(1, public.repetition_calendar_count_internal_p(
          v_start_on, occurrence.occurrence_on, v_pattern
        )), v_pattern
      ) IS DISTINCT FROM occurrence.occurrence_on);

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available', 'requires_date_choice', false,
    'series_id', v_series.id, 'series_revision', v_series.revision,
    'current_task_id', v_current.id, 'current_due_on', v_current.due_on,
    'current_column_id', v_current.column_id,
    'time_zone', v_board.time_zone, 'today', v_today,
    'start_on', v_start_on, 'final_mode', p_final_mode,
    'future_count', CASE WHEN p_final_mode = 'count' THEN p_future_count ELSE NULL END,
    'end_on', CASE WHEN p_final_mode = 'date' THEN p_end_on ELSE NULL END,
    'final_on', v_final_on, 'future_dates', v_future_dates,
    'appearance_dates', v_appearance_dates,
    'advance_days', p_advance_days, 'minimum_separation_days', v_minimum,
    'pattern', v_pattern, 'appearance_column_id', p_appearance_column_id,
    'template_snapshot', v_template,
    'preserved_exclusion_dates', v_preserved_exclusions,
    'removed_exclusion_dates', v_removed_exclusions
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_repetition_edit_p(
  text, uuid, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_repetition_edit_p(
  text, uuid, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) TO authenticated;

CREATE FUNCTION public.edit_repetition_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_expected_revision bigint,
  p_start_on date,
  p_final_mode text,
  p_future_count bigint,
  p_end_on date,
  p_pattern jsonb,
  p_advance_days integer,
  p_appearance_column_id uuid,
  p_template jsonb,
  p_confirm_date_choice boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_payload_hash bytea;
  v_receipt public.daily_repetition_receipts%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_preview jsonb;
  v_result jsonb;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_new_revision bigint;
  v_occurrence_limit bigint;
  v_end_on date;
  v_start_on date;
  v_time_zone text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RAISE EXCEPTION 'Falta identificar la versión de la serie' USING ERRCODE = '22023';
  END IF;
  v_payload_hash := extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'action', 'edit_repetition', 'slug', p_slug, 'task_id', p_task_id,
    'expected_revision', p_expected_revision, 'start_on', p_start_on,
    'final_mode', p_final_mode, 'future_count', p_future_count, 'end_on', p_end_on,
    'pattern', v_pattern, 'advance_days', p_advance_days,
    'appearance_column_id', p_appearance_column_id, 'template', p_template,
    'confirm_date_choice', p_confirm_date_choice
  )::text, 'UTF8'), 'sha256');
  SELECT board.* INTO v_board FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  PERFORM 1 FROM public.boards AS board WHERE board.id = v_board.id FOR UPDATE;
  SELECT board.* INTO v_board FROM public.boards AS board WHERE board.id = v_board.id;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT receipt.* INTO v_receipt FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'edit'
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otros cambios de repetición'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= pg_catalog.clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN v_receipt.result;
  END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
  WHERE occurrence.task_id = p_task_id
    AND occurrence.id = series.current_occurrence_id
    AND occurrence.state = 'current'
    AND series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id
    AND series.state = 'active'
  FOR UPDATE OF series, occurrence;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  IF v_series.revision IS DISTINCT FROM p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'series_id', v_series.id,
      'series_revision', v_series.revision
    );
  END IF;

  v_preview := public.preview_repetition_edit_p(
    p_slug, p_task_id, p_start_on, p_final_mode, p_future_count, p_end_on,
    v_pattern, p_advance_days, p_appearance_column_id, p_template,
    p_confirm_date_choice
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available' THEN RETURN v_preview; END IF;
  IF coalesce((v_preview->>'requires_date_choice')::boolean, false) THEN
    RETURN v_preview || pg_catalog.jsonb_build_object('status', 'date_choice_required');
  END IF;

  v_start_on := (v_preview->>'start_on')::date;
  v_end_on := NULLIF(v_preview->>'end_on', '')::date;
  v_occurrence_limit := CASE WHEN p_final_mode = 'count' THEN p_future_count ELSE NULL END;
  v_new_revision := v_series.revision + 1;
  SELECT board.time_zone INTO v_time_zone FROM public.boards AS board
  WHERE board.id = v_series.board_id;

  UPDATE public.daily_repetition_occurrences AS occurrence
  SET state = 'retired'
  WHERE occurrence.series_id = v_series.id AND occurrence.state = 'excluded'
    AND occurrence.occurrence_on > v_series.latest_occurrence_on
    AND EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements_text(
        v_preview->'removed_exclusion_dates'
      ) AS removed(value)
      WHERE removed.value::date = occurrence.occurrence_on
    );

  UPDATE public.daily_repetition_jobs AS job
  SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
      completed_at = v_now, updated_at = v_now
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait', 'leased');

  UPDATE public.daily_repetition_series AS series
  SET start_on = v_start_on,
      end_on = v_end_on,
      occurrence_limit = v_occurrence_limit,
      consumed_count = 0,
      next_due_on = v_start_on,
      state = 'active', stopped_at = NULL,
      calendar_pattern = v_pattern,
      rule = v_pattern->>'frequency',
      advance_days = p_advance_days,
      appearance_column_id = p_appearance_column_id,
      template_snapshot = v_preview->'template_snapshot',
      revision = v_new_revision, updated_at = v_now
  WHERE series.id = v_series.id;
  INSERT INTO public.daily_repetition_jobs(
    job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
  ) VALUES (
    'advance', v_series.id, v_new_revision, v_start_on,
    pg_catalog.format('advance:%s:%s:%s', v_series.id, v_new_revision, v_start_on),
    (v_start_on - p_advance_days)::timestamp AT TIME ZONE v_time_zone
  );

  v_result := v_preview || pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'series_revision', v_new_revision, 'next_due_on', v_start_on,
    'occurrence_limit', v_occurrence_limit, 'end_on', v_end_on
  );
  INSERT INTO public.daily_repetition_receipts(
    actor_id, operation_id, action, board_id, task_id, series_id,
    payload_hash, result, advance_days, calendar_pattern
  ) VALUES (
    v_actor_id, p_operation_id, 'edit', v_board.id, p_task_id, v_series.id,
    v_payload_hash, v_result, p_advance_days, v_pattern
  );
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.edit_repetition_p(
  uuid, text, uuid, bigint, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.edit_repetition_p(
  uuid, text, uuid, bigint, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) TO authenticated;

-- Ordinary edits to a single occurrence never rewrite the series template or
-- its chosen appearance column. Restore only reconnects that historical slot.
CREATE OR REPLACE FUNCTION public.sync_daily_repetition_task_deletion_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = 'excluded'
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'current';
    RETURN NEW;
  END IF;
  IF NEW.state = 'deleted' AND OLD.state IS DISTINCT FROM 'deleted' THEN
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = 'excluded'
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'current';
    RETURN NEW;
  END IF;
  IF NEW.state = 'restored' AND OLD.state = 'deleted' THEN
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = CASE WHEN EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS later
      WHERE later.series_id = occurrence.series_id
        AND later.occurrence_on > occurrence.occurrence_on
        AND later.state IN ('current', 'replaced', 'excluded', 'retired', 'purged')
    ) THEN 'replaced' ELSE 'current' END
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'excluded';
    UPDATE public.daily_repetition_series AS series
    SET current_occurrence_id = occurrence.id,
        updated_at = pg_catalog.clock_timestamp()
    FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'current'
      AND NOT EXISTS (
        SELECT 1 FROM public.daily_repetition_occurrences AS later
        WHERE later.series_id = occurrence.series_id
          AND later.occurrence_on > occurrence.occurrence_on
          AND later.state IN ('current', 'replaced', 'excluded', 'retired', 'purged')
      )
      AND series.id = occurrence.series_id;
  ELSIF NEW.state = 'purged' AND OLD.state = 'deleted' THEN
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = 'purged'
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'excluded';
    UPDATE public.daily_repetition_series AS series
    SET current_occurrence_id = NULL, updated_at = pg_catalog.clock_timestamp()
    WHERE series.current_occurrence_id IN (
      SELECT occurrence.id FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'purged'
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_daily_repetition_task_deletion_tg()
  FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
