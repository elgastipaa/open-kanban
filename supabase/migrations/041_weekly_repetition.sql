-- Persisted weekly recurrence builds on the same date-only calendar used by
-- daily preview and the durable repetition worker.
BEGIN;

ALTER TABLE public.daily_repetition_series
  DROP CONSTRAINT IF EXISTS daily_repetition_series_rule_check;
ALTER TABLE public.daily_repetition_series
  ADD COLUMN calendar_pattern jsonb NOT NULL
    DEFAULT '{"frequency":"daily","interval":1}'::jsonb;
ALTER TABLE public.daily_repetition_series
  ADD CONSTRAINT daily_repetition_series_rule_check
  CHECK (rule IN ('daily', 'weekly'));
ALTER TABLE public.daily_repetition_receipts
  ADD COLUMN calendar_pattern jsonb;

CREATE FUNCTION public.normalize_repetition_pattern_internal_p(p_pattern jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_frequency text;
  v_interval_text text;
  v_interval bigint;
  v_expected_keys integer;
  v_weekdays integer[];
BEGIN
  IF pg_catalog.jsonb_typeof(p_pattern) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Elige una regla de repetición válida' USING ERRCODE = '22023';
  END IF;
  v_frequency := p_pattern->>'frequency';
  v_interval_text := p_pattern->>'interval';
  IF v_frequency NOT IN ('daily', 'weekly')
    OR v_interval_text IS NULL
    OR v_interval_text !~ '^[1-9][0-9]*$'
    OR pg_catalog.length(v_interval_text) > 10 THEN
    RAISE EXCEPTION 'Elige un intervalo de repetición positivo' USING ERRCODE = '22023';
  END IF;
  v_interval := v_interval_text::bigint;
  IF v_interval > 2147483647 THEN
    RAISE EXCEPTION 'El intervalo supera el calendario admitido' USING ERRCODE = '22023';
  END IF;

  v_expected_keys := CASE WHEN v_frequency = 'weekly' THEN 3 ELSE 2 END;
  IF (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(p_pattern))
    <> v_expected_keys THEN
    RAISE EXCEPTION 'Revisa la frecuencia y los días elegidos' USING ERRCODE = '22023';
  END IF;

  IF v_frequency = 'daily' THEN
    RETURN pg_catalog.jsonb_build_object(
      'frequency', 'daily', 'interval', v_interval
    );
  END IF;

  IF pg_catalog.jsonb_typeof(p_pattern->'weekdays') IS DISTINCT FROM 'array'
    OR pg_catalog.jsonb_array_length(p_pattern->'weekdays') = 0
    OR EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements_text(p_pattern->'weekdays') AS day_value(value)
      WHERE day_value.value IS NULL OR day_value.value !~ '^[1-7]$'
    ) THEN
    RAISE EXCEPTION 'Elige uno o varios días de lunes a domingo' USING ERRCODE = '22023';
  END IF;

  SELECT pg_catalog.array_agg(day_number ORDER BY day_number)
  INTO v_weekdays
  FROM (
    SELECT DISTINCT day_value.value::integer AS day_number
    FROM pg_catalog.jsonb_array_elements_text(p_pattern->'weekdays') AS day_value(value)
  ) AS selected_days;

  RETURN pg_catalog.jsonb_build_object(
    'frequency', 'weekly', 'interval', v_interval,
    'weekdays', pg_catalog.to_jsonb(v_weekdays)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.normalize_repetition_pattern_internal_p(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
ALTER TABLE public.daily_repetition_series
  ADD CONSTRAINT daily_repetition_series_calendar_pattern_check
  CHECK (
    calendar_pattern = public.normalize_repetition_pattern_internal_p(calendar_pattern)
    AND rule = calendar_pattern->>'frequency'
  );
ALTER TABLE public.daily_repetition_receipts
  ADD CONSTRAINT daily_repetition_receipts_calendar_pattern_check
  CHECK (
    calendar_pattern IS NULL
    OR calendar_pattern = public.normalize_repetition_pattern_internal_p(calendar_pattern)
  );

CREATE FUNCTION public.repetition_calendar_occurrence_on_internal_p(
  p_start_on date,
  p_occurrence_number bigint,
  p_pattern jsonb
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_interval bigint;
  v_weekdays integer[];
  v_start_weekday integer;
  v_first_week_count bigint;
  v_remaining numeric;
  v_cycle numeric;
  v_day_index integer;
  v_anchor date;
  v_offset numeric;
  v_max_offset numeric;
BEGIN
  IF p_start_on IS NULL OR p_occurrence_number IS NULL
    OR p_occurrence_number < 1 OR NOT pg_catalog.isfinite(p_start_on) THEN
    RAISE EXCEPTION 'Revisa la fecha inicial y la cantidad de ocurrencias' USING ERRCODE = '22023';
  END IF;
  IF p_occurrence_number = 1 THEN
    RETURN p_start_on;
  END IF;

  v_interval := (v_pattern->>'interval')::bigint;
  IF v_pattern->>'frequency' = 'daily' THEN
    v_offset := (p_occurrence_number - 1)::numeric * v_interval;
    v_max_offset := date '5874897-12-31' - p_start_on;
  ELSE
    SELECT pg_catalog.array_agg(day_value.value::integer ORDER BY day_value.value::integer)
    INTO v_weekdays
    FROM pg_catalog.jsonb_array_elements_text(v_pattern->'weekdays') AS day_value(value);
    v_start_weekday := extract(isodow FROM p_start_on)::integer;
    SELECT pg_catalog.count(*) INTO v_first_week_count
    FROM pg_catalog.unnest(v_weekdays) AS selected_day(value)
    WHERE selected_day.value > v_start_weekday;
    v_remaining := (p_occurrence_number - 1)::numeric;
    v_anchor := p_start_on - (v_start_weekday - 1);
    IF v_remaining <= v_first_week_count THEN
      SELECT selected_day.value - 1 INTO v_offset
      FROM pg_catalog.unnest(v_weekdays) AS selected_day(value)
      WHERE selected_day.value > v_start_weekday
      ORDER BY selected_day.value
      OFFSET (v_remaining - 1)::integer LIMIT 1;
    ELSE
      v_remaining := v_remaining - v_first_week_count;
      v_cycle := 1 + pg_catalog.floor((v_remaining - 1) / pg_catalog.array_length(v_weekdays, 1));
      v_day_index := pg_catalog.mod(v_remaining - 1, pg_catalog.array_length(v_weekdays, 1))::integer + 1;
      v_offset := v_cycle * v_interval * 7 + v_weekdays[v_day_index] - 1;
    END IF;
    v_max_offset := date '5874897-12-31' - v_anchor;
  END IF;

  IF v_offset IS NULL OR v_offset > v_max_offset
    OR (v_pattern->>'frequency' = 'daily' AND v_offset > 2147483647) THEN
    RAISE EXCEPTION 'La fecha final supera el calendario admitido' USING ERRCODE = '22023';
  END IF;
  IF v_pattern->>'frequency' = 'daily' THEN
    RETURN p_start_on + v_offset::integer;
  END IF;
  IF v_offset > 2147483647 THEN
    RAISE EXCEPTION 'La fecha final supera el calendario admitido' USING ERRCODE = '22023';
  END IF;
  RETURN v_anchor + v_offset::integer;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_occurrence_on_internal_p(date, bigint, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.repetition_calendar_count_internal_p(
  p_start_on date,
  p_through_on date,
  p_pattern jsonb
)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_interval bigint;
  v_weekdays integer[];
  v_start_weekday integer;
  v_through_weekday integer;
  v_anchor date;
  v_weeks_since bigint;
  v_cycle bigint;
  v_last_full_cycle bigint;
  v_weekday_count bigint;
  v_first_week_count bigint;
  v_current_week_count bigint;
  v_count bigint;
BEGIN
  IF p_start_on IS NULL OR p_through_on IS NULL
    OR NOT pg_catalog.isfinite(p_start_on) OR NOT pg_catalog.isfinite(p_through_on) THEN
    RAISE EXCEPTION 'Revisa el intervalo de fechas de la serie' USING ERRCODE = '22023';
  END IF;
  IF p_through_on < p_start_on THEN RETURN 0; END IF;

  v_interval := (v_pattern->>'interval')::bigint;
  IF v_pattern->>'frequency' = 'daily' THEN
    RETURN ((p_through_on - p_start_on) / v_interval) + 1;
  END IF;

  SELECT pg_catalog.array_agg(day_value.value::integer ORDER BY day_value.value::integer)
  INTO v_weekdays
  FROM pg_catalog.jsonb_array_elements_text(v_pattern->'weekdays') AS day_value(value);
  v_weekday_count := pg_catalog.array_length(v_weekdays, 1);
  v_start_weekday := extract(isodow FROM p_start_on)::integer;
  v_through_weekday := extract(isodow FROM p_through_on)::integer;
  v_anchor := p_start_on - (v_start_weekday - 1);
  v_weeks_since := (p_through_on - v_anchor) / 7;
  v_cycle := v_weeks_since / v_interval;
  SELECT pg_catalog.count(*) INTO v_first_week_count
  FROM pg_catalog.unnest(v_weekdays) AS selected_day(value)
  WHERE selected_day.value > v_start_weekday;

  IF v_weeks_since = 0 THEN
    SELECT pg_catalog.count(*) INTO v_current_week_count
    FROM pg_catalog.unnest(v_weekdays) AS selected_day(value)
    WHERE selected_day.value > v_start_weekday
      AND selected_day.value <= v_through_weekday;
    RETURN 1 + v_current_week_count;
  END IF;

  v_count := v_first_week_count;
  IF pg_catalog.mod(v_weeks_since, v_interval) = 0 THEN
    v_last_full_cycle := greatest(0, v_cycle - 1);
    SELECT pg_catalog.count(*) INTO v_current_week_count
    FROM pg_catalog.unnest(v_weekdays) AS selected_day(value)
    WHERE selected_day.value <= v_through_weekday;
  ELSE
    v_last_full_cycle := v_cycle;
    v_current_week_count := 0;
  END IF;
  v_count := v_count + (v_last_full_cycle * v_weekday_count) + v_current_week_count;
  RETURN 1 + v_count;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_count_internal_p(date, date, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.repetition_calendar_next_on_internal_p(
  p_start_on date,
  p_after_on date,
  p_final_on date,
  p_pattern jsonb
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_dates jsonb;
BEGIN
  IF p_start_on IS NULL OR p_after_on IS NULL
    OR NOT pg_catalog.isfinite(p_start_on) OR NOT pg_catalog.isfinite(p_after_on)
    OR (p_final_on IS NOT NULL AND NOT pg_catalog.isfinite(p_final_on)) THEN
    RAISE EXCEPTION 'Revisa las fechas del calendario de repetición' USING ERRCODE = '22023';
  END IF;
  IF p_after_on >= date '5874897-12-31'
    OR (p_final_on IS NOT NULL AND p_after_on >= p_final_on) THEN
    RETURN NULL;
  END IF;
  v_dates := public.repetition_calendar_preview_dates_internal_p(
    p_start_on, p_after_on + 1, p_final_on, p_pattern
  );
  RETURN NULLIF(v_dates->>0, '')::date;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_next_on_internal_p(date, date, date, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.preview_repetition_internal_p(
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date,
  p_occurrence_limit bigint,
  p_now timestamptz,
  p_pattern jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_final_on date;
  v_result jsonb;
  v_remaining bigint;
BEGIN
  IF p_start_on IS NULL OR p_now IS NULL OR NOT pg_catalog.isfinite(p_start_on)
    OR NOT pg_catalog.isfinite(p_now)
    OR (p_end_on IS NOT NULL AND NOT pg_catalog.isfinite(p_end_on))
    OR (p_occurrence_limit IS NOT NULL AND p_occurrence_limit < 1)
    OR (p_occurrence_limit IS NOT NULL AND p_occurrence_limit - 1 > 2147483647)
    OR (p_end_on IS NOT NULL AND p_occurrence_limit IS NOT NULL)
    OR (p_end_on IS NOT NULL AND p_end_on < p_start_on) THEN
    RAISE EXCEPTION 'Revisa las fechas y el final de la repetición' USING ERRCODE = '22023';
  END IF;

  IF p_occurrence_limit IS NOT NULL THEN
    v_final_on := public.repetition_calendar_occurrence_on_internal_p(
      p_start_on, p_occurrence_limit, v_pattern
    );
    v_remaining := p_occurrence_limit - 1;
  ELSE
    v_final_on := p_end_on;
    v_remaining := CASE WHEN p_end_on IS NULL THEN NULL
      ELSE greatest(0,
        public.repetition_calendar_count_internal_p(p_start_on, p_end_on, v_pattern) - 1)
      END;
  END IF;

  v_result := public.preview_daily_repetition_internal_p(
    p_slug, p_task_id, p_start_on, v_final_on, NULL, p_now, v_pattern
  );
  IF v_result->>'status' <> 'available' THEN RETURN v_result; END IF;
  RETURN v_result || pg_catalog.jsonb_build_object(
    'pattern', v_pattern,
    'final_on', v_final_on,
    'occurrence_limit', p_occurrence_limit,
    'no_final_date', v_final_on IS NULL,
    'remaining_dates_after_current', v_remaining
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_repetition_internal_p(
  text, uuid, date, date, bigint, timestamptz, jsonb
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.preview_repetition_p(
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date DEFAULT NULL,
  p_occurrence_limit bigint DEFAULT NULL,
  p_pattern jsonb DEFAULT '{"frequency":"daily","interval":1}'::jsonb
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.preview_repetition_internal_p(
    p_slug, p_task_id, p_start_on, p_end_on, p_occurrence_limit,
    pg_catalog.statement_timestamp(), p_pattern
  );
$$;
REVOKE ALL ON FUNCTION public.preview_repetition_p(text, uuid, date, date, bigint, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_repetition_p(text, uuid, date, date, bigint, jsonb)
  TO authenticated;

CREATE FUNCTION public.get_repetition_p(p_slug text, p_task_id uuid)
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
  IF v_result->>'status' IS DISTINCT FROM 'available' THEN
    RETURN v_result;
  END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  RETURN v_result || pg_catalog.jsonb_build_object(
    'rule', v_series.rule, 'pattern', v_series.calendar_pattern
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_repetition_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_repetition_p(text, uuid) TO authenticated;

CREATE FUNCTION public.create_repetition_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date,
  p_occurrence_limit bigint,
  p_expected_due_on_version bigint,
  p_confirm_start_change boolean,
  p_previous_series_id uuid,
  p_pattern jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_default_pattern constant jsonb := '{"frequency":"daily","interval":1}'::jsonb;
  v_receipt public.daily_repetition_receipts%ROWTYPE;
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_final_on date;
  v_next_due_on date;
  v_occurrence_count bigint;
  v_series_state text;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;

  IF p_operation_id IS NOT NULL THEN
    SELECT receipt.* INTO v_receipt
    FROM public.daily_repetition_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF FOUND AND coalesce(v_receipt.calendar_pattern, v_default_pattern)
      IS DISTINCT FROM v_pattern THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otra regla de repetición'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  -- The established conversion path keeps its permissions, date confirmation,
  -- version checks, task identity and receipt semantics. This wrapper replaces
  -- its provisional daily next date with the selected canonical pattern before
  -- the transaction becomes visible to the durable worker.
  v_result := public.create_daily_repetition_p(
    p_operation_id, p_slug, p_task_id, p_start_on, p_end_on,
    p_occurrence_limit, p_expected_due_on_version, p_confirm_start_change,
    p_previous_series_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RETURN v_result;
  END IF;

  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se pudo confirmar el resultado de la serie'
      USING ERRCODE = '40001';
  END IF;
  IF v_receipt.calendar_pattern IS NOT NULL
    AND v_receipt.calendar_pattern IS DISTINCT FROM v_pattern THEN
    RAISE EXCEPTION 'Esta operación ya se usó con otra regla de repetición'
      USING ERRCODE = '23514';
  END IF;
  IF v_receipt.calendar_pattern IS NOT NULL THEN
    RETURN v_receipt.result;
  END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = v_receipt.series_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La serie dejó de estar disponible'
      USING ERRCODE = '40001';
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_series.board_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'El tablero dejó de estar disponible'
      USING ERRCODE = '40001';
  END IF;

  IF p_occurrence_limit IS NOT NULL THEN
    v_occurrence_count := p_occurrence_limit;
    v_final_on := public.repetition_calendar_occurrence_on_internal_p(
      p_start_on, p_occurrence_limit, v_pattern
    );
  ELSIF p_end_on IS NOT NULL THEN
    v_occurrence_count := public.repetition_calendar_count_internal_p(
      p_start_on, p_end_on, v_pattern
    );
    v_final_on := public.repetition_calendar_occurrence_on_internal_p(
      p_start_on, v_occurrence_count, v_pattern
    );
  ELSE
    v_occurrence_count := NULL;
    v_final_on := NULL;
  END IF;

  v_next_due_on := public.repetition_calendar_next_on_internal_p(
    p_start_on, p_start_on, v_final_on, v_pattern
  );
  v_series_state := CASE WHEN v_next_due_on IS NULL THEN 'finished' ELSE 'active' END;

  UPDATE public.daily_repetition_jobs AS job
  SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
      completed_at = coalesce(job.completed_at, v_now), updated_at = v_now
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait', 'leased');

  UPDATE public.daily_repetition_series AS series
  SET rule = v_pattern->>'frequency', calendar_pattern = v_pattern,
      occurrence_limit = p_occurrence_limit, end_on = p_end_on,
      next_due_on = v_next_due_on, state = v_series_state,
      stopped_at = NULL, revision = series.revision + 1, updated_at = v_now
  WHERE series.id = v_series.id
  RETURNING series.* INTO v_series;

  IF v_series.state = 'active' THEN
    INSERT INTO public.daily_repetition_jobs(
      job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
    ) VALUES (
      'advance', v_series.id, v_series.revision, v_next_due_on,
      pg_catalog.format('advance:%s:%s:%s', v_series.id, v_series.revision, v_next_due_on),
      v_next_due_on::timestamp AT TIME ZONE v_board.time_zone
    );
  END IF;

  v_result := v_receipt.result || pg_catalog.jsonb_build_object(
    'state', v_series.state,
    'series_state', v_series.state,
    'series_revision', v_series.revision,
    'next_due_on', v_series.next_due_on,
    'consumed_count', v_series.consumed_count,
    'occurrence_limit', v_series.occurrence_limit,
    'end_on', v_series.end_on,
    'pattern', v_series.calendar_pattern
  );
  UPDATE public.daily_repetition_receipts AS receipt
  SET calendar_pattern = v_pattern, result = v_result
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_repetition_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_repetition_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb
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
  v_board public.boards%ROWTYPE;
  v_column public.columns%ROWTYPE;
  v_pattern jsonb;
  v_today date;
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
  v_result jsonb;
  v_finished boolean;
BEGIN
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = p_job.series_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'superseded');
  END IF;
  IF v_series.state IS DISTINCT FROM 'active'
    OR v_series.revision IS DISTINCT FROM p_job.series_revision
    OR v_series.next_due_on IS DISTINCT FROM p_job.scheduled_on THEN
    RETURN pg_catalog.jsonb_build_object('status', 'superseded');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_series.board_id
    AND board.active_generation_id = v_series.generation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    UPDATE public.daily_repetition_series AS series
    SET state = 'stopped', next_due_on = NULL, stopped_at = p_now,
        revision = series.revision + 1, updated_at = p_now
    WHERE series.id = v_series.id;
    RETURN pg_catalog.jsonb_build_object('status', 'series_unavailable');
  END IF;

  v_pattern := v_series.calendar_pattern;
  v_today := public.board_calendar_day(v_board.time_zone, p_now);
  IF v_today < p_job.scheduled_on THEN
    UPDATE public.daily_repetition_jobs AS job
    SET state = 'queued',
        available_at = p_job.scheduled_on::timestamp AT TIME ZONE v_board.time_zone,
        lease_token = NULL, lease_expires_at = NULL, updated_at = p_now
    WHERE job.id = p_job.id;
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

  v_through_on := CASE WHEN v_final_on IS NOT NULL
    THEN least(v_today, v_final_on) ELSE v_today END;
  v_effective_count := public.repetition_calendar_count_internal_p(
    v_series.start_on, v_through_on, v_pattern
  );
  IF v_effective_count < 1 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'not_due');
  END IF;
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
    WHERE occurrence.series_id = v_series.id AND occurrence.occurrence_on = v_target_on
  ) THEN
    UPDATE public.daily_repetition_series AS series
    SET state = CASE WHEN v_finished THEN 'finished' ELSE 'active' END,
        latest_occurrence_on = greatest(series.latest_occurrence_on, v_target_on),
        consumed_count = greatest(series.consumed_count, v_consumed_count),
        next_due_on = v_next_due_on,
        revision = series.revision + 1, updated_at = p_now
    WHERE series.id = v_series.id;
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
    SELECT 1
    FROM public.board_memberships AS membership
    WHERE membership.board_id = v_series.board_id
      AND membership.user_id = v_assignee_id
      AND membership.revoked_at IS NULL
      AND public.is_enabled_application_identity_p(v_assignee_id)
  ) THEN
    v_assignee_id := NULL;
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.board_memberships AS membership
    WHERE membership.board_id = v_series.board_id
      AND membership.user_id = v_series.created_by
      AND membership.revoked_at IS NULL
      AND public.is_enabled_application_identity_p(v_series.created_by)
  ) THEN
    v_creator_id := v_series.created_by;
  END IF;

  SELECT coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'id', pg_catalog.gen_random_uuid(),
      'text', step.value->>'text',
      'is_completed', false,
      'position', coalesce((step.value->>'position')::integer, (step.ordinality - 1)::integer),
      'version', 1
    ) ORDER BY step.ordinality
  ), '[]'::jsonb) INTO v_new_steps
  FROM pg_catalog.jsonb_array_elements(v_series.template_snapshot->'steps')
    WITH ORDINALITY AS step(value, ordinality);

  -- The task guard uses a current member only as an authorization context.
  -- It does not change the series creator reference or copy conversation data.
  SELECT membership.user_id INTO v_actor_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_series.board_id
    AND membership.revoked_at IS NULL
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
  WHERE occurrence.id = v_series.current_occurrence_id
    AND occurrence.state = 'current';
  INSERT INTO public.daily_repetition_occurrences(
    series_id, occurrence_on, task_id, state
  ) VALUES (v_series.id, v_target_on, v_new_task_id, 'current')
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

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series WHERE series.id = v_series.id;
  IF v_series.state = 'active' THEN
    INSERT INTO public.daily_repetition_jobs(
      job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
    ) VALUES (
      'advance', v_series.id, v_series.revision, v_series.next_due_on,
      pg_catalog.format('advance:%s:%s:%s', v_series.id, v_series.revision, v_series.next_due_on),
      v_series.next_due_on::timestamp AT TIME ZONE v_board.time_zone
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

NOTIFY pgrst, 'reload schema';
COMMIT;
