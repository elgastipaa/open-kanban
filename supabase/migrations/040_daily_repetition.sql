-- Daily series keep the existing task as occurrence one. Future work is
-- represented by dated slots and durable jobs, never by browser timers.
BEGIN;

CREATE TABLE public.daily_repetition_series (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  origin_task_id uuid NOT NULL,
  first_task_id uuid NOT NULL,
  appearance_column_id uuid NOT NULL,
  rule text NOT NULL DEFAULT 'daily' CHECK (rule = 'daily'),
  start_on date NOT NULL CHECK (pg_catalog.isfinite(start_on)),
  end_on date CHECK (end_on IS NULL OR pg_catalog.isfinite(end_on)),
  occurrence_limit bigint CHECK (occurrence_limit IS NULL OR occurrence_limit > 0),
  consumed_count bigint NOT NULL DEFAULT 1 CHECK (consumed_count > 0),
  latest_occurrence_on date NOT NULL CHECK (pg_catalog.isfinite(latest_occurrence_on)),
  current_occurrence_id uuid,
  next_due_on date CHECK (next_due_on IS NULL OR pg_catalog.isfinite(next_due_on)),
  state text NOT NULL CHECK (state IN ('active', 'stopped', 'finished')),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  template_snapshot jsonb NOT NULL CHECK (
    pg_catalog.jsonb_typeof(template_snapshot) = 'object'
    AND pg_catalog.jsonb_typeof(template_snapshot->'title') = 'string'
    AND pg_catalog.length(pg_catalog.btrim(template_snapshot->>'title')) > 0
    AND pg_catalog.length(template_snapshot->>'title') <= 200
    AND pg_catalog.jsonb_typeof(template_snapshot->'description') IN ('string', 'null')
    AND pg_catalog.length(template_snapshot->>'description') <= 2000
    AND template_snapshot->>'priority' IN ('low', 'medium', 'high', 'urgent')
    AND pg_catalog.jsonb_typeof(template_snapshot->'steps') = 'array'
  ),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  stopped_at timestamptz,
  CONSTRAINT daily_repetition_final_shape CHECK (
    end_on IS NULL OR occurrence_limit IS NULL
  ),
  CONSTRAINT daily_repetition_range_shape CHECK (
    end_on IS NULL OR end_on >= start_on
  ),
  CONSTRAINT daily_repetition_state_shape CHECK (
    (state = 'active' AND next_due_on IS NOT NULL AND stopped_at IS NULL)
    OR (state = 'stopped' AND next_due_on IS NULL AND stopped_at IS NOT NULL)
    OR (state = 'finished' AND next_due_on IS NULL AND stopped_at IS NULL)
  )
);
CREATE INDEX daily_repetition_board_state_idx
  ON public.daily_repetition_series(board_id, state, next_due_on);
ALTER TABLE public.daily_repetition_series ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.daily_repetition_series
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.daily_repetition_occurrences (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  series_id uuid NOT NULL REFERENCES public.daily_repetition_series(id) ON DELETE CASCADE,
  occurrence_on date NOT NULL CHECK (pg_catalog.isfinite(occurrence_on)),
  task_id uuid NOT NULL,
  state text NOT NULL CHECK (state IN ('current', 'replaced', 'excluded', 'purged', 'transferred')),
  due_on_override date,
  transferred_to_series_id uuid,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT daily_repetition_one_slot_per_date UNIQUE (series_id, occurrence_on),
  CONSTRAINT daily_repetition_transfer_shape CHECK (
    (state = 'transferred') = (transferred_to_series_id IS NOT NULL)
  )
);
CREATE INDEX daily_repetition_occurrence_task_idx
  ON public.daily_repetition_occurrences(task_id, created_at DESC);
ALTER TABLE public.daily_repetition_occurrences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.daily_repetition_occurrences
  FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE public.daily_repetition_series
  ADD CONSTRAINT daily_repetition_current_occurrence_fk
  FOREIGN KEY (current_occurrence_id)
  REFERENCES public.daily_repetition_occurrences(id) ON DELETE SET NULL;

CREATE TABLE public.daily_repetition_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('create', 'stop', 'set_count')),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  task_id uuid NOT NULL,
  series_id uuid,
  payload_hash bytea NOT NULL CHECK (pg_catalog.octet_length(payload_hash) = 32),
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (pg_catalog.clock_timestamp() + interval '168 hours'),
  PRIMARY KEY (actor_id, operation_id)
);
ALTER TABLE public.daily_repetition_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.daily_repetition_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.daily_repetition_jobs (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  job_kind text NOT NULL CHECK (job_kind IN ('advance', 'purge')),
  series_id uuid REFERENCES public.daily_repetition_series(id) ON DELETE CASCADE,
  series_revision bigint,
  scheduled_on date,
  dedupe_key text NOT NULL UNIQUE,
  state text NOT NULL DEFAULT 'queued'
    CHECK (state IN ('queued', 'retry_wait', 'leased', 'succeeded', 'dead_letter', 'superseded')),
  available_at timestamptz NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  max_attempts integer NOT NULL DEFAULT 8 CHECK (max_attempts BETWEEN 1 AND 20),
  lease_token uuid,
  lease_expires_at timestamptz,
  last_error_code text,
  last_error_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  CONSTRAINT daily_repetition_job_shape CHECK (
    (job_kind = 'advance' AND series_id IS NOT NULL
      AND series_revision IS NOT NULL AND scheduled_on IS NOT NULL)
    OR (job_kind = 'purge' AND series_id IS NULL
      AND series_revision IS NULL AND scheduled_on IS NULL)
  ),
  CONSTRAINT daily_repetition_job_lease_shape CHECK (
    (state = 'leased' AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR (state <> 'leased' AND lease_token IS NULL AND lease_expires_at IS NULL)
  )
);
CREATE INDEX daily_repetition_jobs_claim_idx
  ON public.daily_repetition_jobs(state, available_at, created_at);
ALTER TABLE public.daily_repetition_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.daily_repetition_jobs
  FROM PUBLIC, anon, authenticated, service_role;

-- One durable purge chain starts with the migration. Each completed purge
-- job enqueues its successor in the same transaction as its own completion.
INSERT INTO public.daily_repetition_jobs(job_kind, dedupe_key, available_at)
VALUES ('purge', 'purge:bootstrap', pg_catalog.clock_timestamp());

-- Shared preview calendar for the current daily pattern and the weekly anchor
-- contract required by AC49. The weekly selector is intentionally not exposed
-- by this issue's UI; issue #24 persists and edits weekly rules.
CREATE FUNCTION public.repetition_calendar_preview_dates_internal_p(
  p_start_on date,
  p_preview_from date,
  p_final_on date,
  p_pattern jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_frequency text;
  v_interval bigint;
  v_interval_text text;
  v_weekdays integer[];
  v_anchor date;
  v_steps_from_start bigint;
  v_first_cycle bigint;
  v_future_dates jsonb;
BEGIN
  IF p_start_on IS NULL OR p_preview_from IS NULL
    OR NOT pg_catalog.isfinite(p_start_on)
    OR NOT pg_catalog.isfinite(p_preview_from)
    OR (p_final_on IS NOT NULL AND NOT pg_catalog.isfinite(p_final_on))
    OR (p_final_on IS NOT NULL AND p_final_on < p_start_on)
    OR pg_catalog.jsonb_typeof(p_pattern) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Review the repetition calendar preview'
      USING ERRCODE = '22023';
  END IF;

  v_frequency := p_pattern->>'frequency';
  v_interval_text := p_pattern->>'interval';
  IF v_interval_text IS NULL OR v_interval_text !~ '^[1-9][0-9]*$'
    OR pg_catalog.length(v_interval_text) > 10 THEN
    RAISE EXCEPTION 'Choose a valid repetition interval' USING ERRCODE = '22023';
  END IF;
  v_interval := v_interval_text::bigint;
  IF v_interval > 2147483647 THEN
    RAISE EXCEPTION 'Choose a valid repetition interval' USING ERRCODE = '22023';
  END IF;

  IF v_frequency = 'daily' THEN
    v_steps_from_start := greatest(0, p_preview_from - p_start_on)::bigint;
    v_first_cycle := CASE WHEN v_steps_from_start = 0 THEN 0
      ELSE 1 + (v_steps_from_start - 1) / v_interval END;
    WITH offsets AS (
      SELECT (v_first_cycle + step.step_index)::numeric * v_interval AS day_offset
      FROM pg_catalog.generate_series(0, 4) AS step(step_index)
      WHERE (v_first_cycle + step.step_index)::numeric * v_interval
        <= date '5874897-12-31' - p_start_on
    ), candidates AS (
      SELECT p_start_on + calendar_offset.day_offset::integer AS occurrence_on
      FROM offsets AS calendar_offset
    )
    SELECT coalesce(pg_catalog.jsonb_agg(candidate.occurrence_on ORDER BY candidate.occurrence_on), '[]'::jsonb)
    INTO v_future_dates
    FROM candidates AS candidate
    WHERE candidate.occurrence_on >= p_preview_from
      AND (p_final_on IS NULL OR candidate.occurrence_on <= p_final_on);
    RETURN v_future_dates;
  END IF;

  IF v_frequency <> 'weekly' THEN
    RAISE EXCEPTION 'Choose a valid repetition frequency' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_typeof(p_pattern->'weekdays') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Choose a valid weekly repetition pattern' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_array_length(p_pattern->'weekdays') = 0 OR EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements_text(p_pattern->'weekdays') AS day_value(value)
    WHERE day_value.value !~ '^[1-7]$'
  ) THEN
    RAISE EXCEPTION 'Choose a valid weekly repetition pattern' USING ERRCODE = '22023';
  END IF;
  SELECT pg_catalog.array_agg(day_number ORDER BY day_number) INTO v_weekdays
  FROM (
    SELECT DISTINCT day_value.value::integer AS day_number
    FROM pg_catalog.jsonb_array_elements_text(p_pattern->'weekdays') AS day_value(value)
  ) AS days;

  v_anchor := p_start_on - (extract(isodow FROM p_start_on)::integer - 1);
  v_steps_from_start := greatest(0, (p_preview_from - v_anchor) / 7)::bigint;
  v_first_cycle := CASE WHEN v_steps_from_start = 0 THEN 0
    ELSE 1 + (v_steps_from_start - 1) / v_interval END;
  WITH cycles AS (
    SELECT v_first_cycle + cycle_offset.cycle_index AS cycle
    FROM pg_catalog.generate_series(0, 5) AS cycle_offset(cycle_index)
  ), candidate_offsets AS (
    SELECT (
      (cycles.cycle::numeric * v_interval * 7) + day_value.weekday - 1
    ) AS day_offset
    FROM cycles
    CROSS JOIN pg_catalog.unnest(v_weekdays) AS day_value(weekday)
    WHERE (cycles.cycle::numeric * v_interval * 7) + day_value.weekday - 1
      <= date '5874897-12-31' - v_anchor
  ), candidates AS (
    SELECT v_anchor + candidate_offset.day_offset::integer AS occurrence_on
    FROM candidate_offsets AS candidate_offset
  )
  SELECT coalesce(pg_catalog.jsonb_agg(occurrence_on ORDER BY occurrence_on), '[]'::jsonb)
  INTO v_future_dates
  FROM (
    SELECT DISTINCT candidate.occurrence_on
    FROM candidates AS candidate
    WHERE candidate.occurrence_on >= p_start_on
      AND candidate.occurrence_on >= p_preview_from
      AND (p_final_on IS NULL OR candidate.occurrence_on <= p_final_on)
    ORDER BY candidate.occurrence_on
    LIMIT 5
  ) AS preview;
  RETURN v_future_dates;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_preview_dates_internal_p(
  date, date, date, jsonb
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.preview_daily_repetition_internal_p(
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date,
  p_occurrence_limit bigint,
  p_now timestamptz,
  p_pattern jsonb DEFAULT '{"frequency":"daily","interval":1}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_today date;
  v_final_on date;
  v_preview_from date;
  v_future_dates jsonb;
  v_previous record;
BEGIN
  IF p_task_id IS NULL OR p_slug IS NULL OR p_start_on IS NULL
    OR p_now IS NULL OR NOT pg_catalog.isfinite(p_start_on)
    OR (p_end_on IS NOT NULL AND NOT pg_catalog.isfinite(p_end_on))
    OR (p_occurrence_limit IS NOT NULL AND p_occurrence_limit < 1)
    OR (p_end_on IS NOT NULL AND p_occurrence_limit IS NOT NULL)
    OR (p_end_on IS NOT NULL AND p_end_on < p_start_on) THEN
    RAISE EXCEPTION 'Review the daily repetition dates and final condition'
      USING ERRCODE = '22023';
  END IF;
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  v_today := public.board_calendar_day(v_board.time_zone, p_now);
  IF p_occurrence_limit IS NOT NULL THEN
    IF p_occurrence_limit - 1 > 2147483647 THEN
      RAISE EXCEPTION 'The final date is outside the supported calendar range'
        USING ERRCODE = '22023';
    END IF;
    v_final_on := p_start_on + (p_occurrence_limit - 1)::integer;
  ELSE
    v_final_on := p_end_on;
  END IF;

  v_preview_from := greatest(p_start_on + 1, v_today);
  v_future_dates := public.repetition_calendar_preview_dates_internal_p(
    p_start_on, v_preview_from, v_final_on, p_pattern
  );

  SELECT series.id, series.state, occurrence.state AS occurrence_state
  INTO v_previous
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
  WHERE occurrence.task_id = v_task.id
  ORDER BY occurrence.created_at DESC, occurrence.id DESC
  LIMIT 1;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available',
    'board_id', v_board.id,
    'task_id', v_task.id,
    'current_task_id', v_task.id,
    'time_zone', v_board.time_zone,
    'previewed_at', p_now,
    'today', v_today,
    'existing_due_on', v_task.due_on,
    'existing_due_on_version', (v_task.field_versions->>'due_on')::bigint,
    'proposed_start_on', p_start_on,
    'current', pg_catalog.jsonb_build_object(
      'task_id', v_task.id,
      'due_on', p_start_on,
      'is_existing_task', true
    ),
    'future_dates', v_future_dates,
    'final_on', v_final_on,
    'occurrence_limit', p_occurrence_limit,
    'no_final_date', v_final_on IS NULL,
    'remaining_dates_after_current', CASE
      WHEN p_occurrence_limit IS NOT NULL
        THEN greatest(0, p_occurrence_limit - 1)
      WHEN v_final_on IS NOT NULL THEN greatest(0, v_final_on - p_start_on)
      ELSE NULL END,
    'start_in_past', p_start_on < v_today,
    'requires_start_confirmation', v_task.due_on IS DISTINCT FROM p_start_on,
    'previous_series_id', v_previous.id,
    'previous_series_state', v_previous.state,
    'requires_previous_series_confirmation',
      coalesce(v_previous.occurrence_state = 'current'
        AND v_previous.state IN ('stopped', 'finished'), false)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_daily_repetition_internal_p(
  text, uuid, date, date, bigint, timestamptz, jsonb
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.preview_daily_repetition_p(
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date DEFAULT NULL,
  p_occurrence_limit bigint DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.preview_daily_repetition_internal_p(
    p_slug, p_task_id, p_start_on, p_end_on, p_occurrence_limit,
    pg_catalog.statement_timestamp()
  );
$$;
REVOKE ALL ON FUNCTION public.preview_daily_repetition_p(text, uuid, date, date, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_daily_repetition_p(text, uuid, date, date, bigint)
  TO authenticated;

CREATE FUNCTION public.create_daily_repetition_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_start_on date,
  p_end_on date,
  p_occurrence_limit bigint,
  p_expected_due_on_version bigint,
  p_confirm_start_change boolean,
  p_previous_series_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_series_id uuid;
  v_occurrence_id uuid;
  v_previous record;
  v_receipt public.daily_repetition_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_next_due_on date;
  v_final_on date;
  v_series_state text;
  v_result jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR p_start_on IS NULL OR NOT pg_catalog.isfinite(p_start_on)
    OR p_expected_due_on_version IS NULL OR p_expected_due_on_version < 1
    OR p_confirm_start_change IS NULL
    OR (p_end_on IS NOT NULL AND NOT pg_catalog.isfinite(p_end_on))
    OR (p_occurrence_limit IS NOT NULL AND p_occurrence_limit < 1)
    OR (p_end_on IS NOT NULL AND p_occurrence_limit IS NOT NULL)
    OR (p_end_on IS NOT NULL AND p_end_on < p_start_on) THEN
    RAISE EXCEPTION 'Review the daily repetition details before saving'
      USING ERRCODE = '22023';
  END IF;
  IF p_occurrence_limit IS NOT NULL AND p_occurrence_limit - 1 > 2147483647 THEN
    RAISE EXCEPTION 'The final date is outside the supported calendar range'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM 1 FROM public.boards AS board WHERE board.id = v_board.id FOR UPDATE;
  SELECT board.* INTO v_board FROM public.boards AS board WHERE board.id = v_board.id;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  v_payload_hash := extensions.digest(
    pg_catalog.convert_to(pg_catalog.jsonb_build_object(
      'action', 'create_daily_repetition', 'board_id', v_board.id,
      'task_id', p_task_id, 'start_on', p_start_on,
      'end_on', p_end_on, 'occurrence_limit', p_occurrence_limit,
      'expected_due_on_version', p_expected_due_on_version,
      'confirm_start_change', p_confirm_start_change,
      'previous_series_id', p_previous_series_id
    )::text, 'UTF8'), 'sha256'
  );
  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'create'
      OR v_receipt.board_id IS DISTINCT FROM v_board.id
      OR v_receipt.task_id IS DISTINCT FROM p_task_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This repetition operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= pg_catalog.clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN v_receipt.result;
  END IF;

  IF (v_task.field_versions->>'due_on')::bigint <> p_expected_due_on_version THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'task', pg_catalog.to_jsonb(v_task),
      'current_due_on_version', (v_task.field_versions->>'due_on')::bigint
    );
  END IF;

  SELECT series.id, series.state, occurrence.id AS occurrence_id,
    occurrence.state AS occurrence_state
  INTO v_previous
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
  WHERE occurrence.task_id = v_task.id
  ORDER BY occurrence.created_at DESC, occurrence.id DESC
  LIMIT 1
  FOR UPDATE OF series, occurrence;
  IF FOUND AND v_previous.state = 'active'
    AND v_previous.occurrence_state = 'current' THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'reason', 'already_repeating'
    );
  END IF;
  IF FOUND AND v_previous.occurrence_state = 'current'
    AND v_previous.state IN ('stopped', 'finished') THEN
    IF p_previous_series_id IS DISTINCT FROM v_previous.id THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'confirmation_required', 'operation_id', p_operation_id,
        'confirmation', 'new_series_from_stopped',
        'previous_series_id', v_previous.id,
        'previous_series_state', v_previous.state
      );
    END IF;
  ELSIF p_previous_series_id IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'reason', 'previous_series_changed'
    );
  END IF;
  IF v_task.due_on IS DISTINCT FROM p_start_on AND NOT p_confirm_start_change THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmation_required', 'operation_id', p_operation_id,
      'confirmation', 'change_current_due_date',
      'existing_due_on', v_task.due_on,
      'proposed_start_on', p_start_on,
      'task_id', v_task.id
    );
  END IF;

  v_final_on := CASE
    WHEN p_occurrence_limit IS NOT NULL
      THEN p_start_on + (p_occurrence_limit - 1)::integer
    ELSE p_end_on
  END;
  v_next_due_on := p_start_on + 1;
  IF (p_occurrence_limit = 1) OR v_final_on = p_start_on THEN
    v_series_state := 'finished';
    v_next_due_on := NULL;
  ELSE
    v_series_state := 'active';
  END IF;

  IF v_task.due_on IS DISTINCT FROM p_start_on THEN
    UPDATE public.tasks AS task
    SET due_on = p_start_on,
        field_versions = pg_catalog.jsonb_set(
          task.field_versions, '{due_on}',
          pg_catalog.to_jsonb((task.field_versions->>'due_on')::bigint + 1)
        )
    WHERE task.id = v_task.id
    RETURNING task.* INTO v_task;
  END IF;

  INSERT INTO public.daily_repetition_series(
    board_id, generation_id, created_by, origin_task_id, first_task_id,
    appearance_column_id, start_on, end_on, occurrence_limit,
    consumed_count, latest_occurrence_on, next_due_on, state, template_snapshot
  ) VALUES (
    v_board.id, v_board.active_generation_id, v_actor_id, v_task.id, v_task.id,
    v_task.column_id, p_start_on, p_end_on, p_occurrence_limit,
    1, p_start_on, v_next_due_on, v_series_state,
    pg_catalog.jsonb_build_object(
      'title', v_task.title, 'description', v_task.description,
      'priority', v_task.priority, 'assignee_id', v_task.assignee_id,
      'steps', v_task.steps
    )
  ) RETURNING id INTO v_series_id;

  IF FOUND AND v_previous.occurrence_id IS NOT NULL
    AND v_previous.occurrence_state = 'current' THEN
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = 'transferred', transferred_to_series_id = v_series_id
    WHERE occurrence.id = v_previous.occurrence_id;
  END IF;

  INSERT INTO public.daily_repetition_occurrences(
    series_id, occurrence_on, task_id, state
  ) VALUES (v_series_id, p_start_on, v_task.id, 'current')
  RETURNING id INTO v_occurrence_id;
  UPDATE public.daily_repetition_series AS series
  SET current_occurrence_id = v_occurrence_id,
      updated_at = pg_catalog.clock_timestamp()
  WHERE series.id = v_series_id;

  IF v_series_state = 'active' THEN
    INSERT INTO public.daily_repetition_jobs(
      job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
    ) VALUES (
      'advance', v_series_id, 1, v_next_due_on,
      pg_catalog.format('advance:%s:1:%s', v_series_id, v_next_due_on),
      v_next_due_on::timestamp AT TIME ZONE v_board.time_zone
    );
  END IF;

  v_result := pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'series_id', v_series_id, 'series_revision', 1,
    'task_id', v_task.id, 'due_on', v_task.due_on,
    'state', v_series_state, 'next_due_on', v_next_due_on,
    'consumed_count', 1, 'occurrence_limit', p_occurrence_limit,
    'end_on', p_end_on, 'task', pg_catalog.to_jsonb(v_task)
  );
  INSERT INTO public.daily_repetition_receipts(
    actor_id, operation_id, action, board_id, task_id, series_id,
    payload_hash, result
  ) VALUES (
    v_actor_id, p_operation_id, 'create', v_board.id, v_task.id, v_series_id,
    v_payload_hash, v_result
  );
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_daily_repetition_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_daily_repetition_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid
) TO authenticated;

CREATE FUNCTION public.claim_daily_repetition_jobs_internal_p(
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
  v_expired record;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR p_now IS NULL OR NOT pg_catalog.isfinite(p_now) THEN
    RAISE EXCEPTION 'Choose a valid worker batch and timestamp' USING ERRCODE = '22023';
  END IF;

  FOR v_expired IN
    UPDATE public.daily_repetition_jobs AS job
    SET state = 'dead_letter',
        lease_token = NULL,
        lease_expires_at = NULL,
        last_error_code = coalesce(job.last_error_code, 'lease_expired'),
        last_error_at = p_now,
        completed_at = p_now,
        updated_at = p_now
    WHERE job.state = 'leased'
      AND job.lease_expires_at <= p_now
      AND job.attempt_count >= job.max_attempts
    RETURNING job.id, job.job_kind
  LOOP
    IF v_expired.job_kind = 'purge' THEN
      INSERT INTO public.daily_repetition_jobs(job_kind, dedupe_key, available_at)
      VALUES ('purge', pg_catalog.format('purge:after:%s', v_expired.id), p_now + interval '1 hour')
      ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
  END LOOP;

  RETURN QUERY
  WITH candidates AS MATERIALIZED (
    SELECT job.id
    FROM public.daily_repetition_jobs AS job
    WHERE (
        job.state IN ('queued', 'retry_wait') AND job.available_at <= p_now
      ) OR (
        job.state = 'leased' AND job.lease_expires_at <= p_now
          AND job.attempt_count < job.max_attempts
      )
    ORDER BY job.available_at, job.created_at, job.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  ), leased AS (
    UPDATE public.daily_repetition_jobs AS job
    SET state = 'leased',
        lease_token = pg_catalog.gen_random_uuid(),
        lease_expires_at = p_now + interval '2 minutes',
        attempt_count = job.attempt_count + 1,
        updated_at = p_now
    FROM candidates
    WHERE job.id = candidates.id
    RETURNING job.*
  )
  SELECT leased.id, leased.job_kind, leased.series_id, leased.series_revision,
    leased.scheduled_on, leased.lease_token, leased.lease_expires_at,
    leased.attempt_count
  FROM leased
  ORDER BY leased.available_at, leased.created_at, leased.id;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_daily_repetition_jobs_internal_p(integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.advance_daily_repetition_internal_p(
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
  v_today date;
  v_final_on date;
  v_target_on date;
  v_gap bigint;
  v_new_task_id uuid := pg_catalog.gen_random_uuid();
  v_new_occurrence_id uuid;
  v_position integer;
  v_actor_id uuid;
  v_assignee_id uuid;
  v_creator_id uuid;
  v_previous_sub text;
  v_new_steps jsonb;
  v_result jsonb;
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

  v_today := public.board_calendar_day(v_board.time_zone, p_now);
  IF v_today < p_job.scheduled_on THEN
    UPDATE public.daily_repetition_jobs AS job
    SET state = 'queued', available_at = p_job.scheduled_on::timestamp AT TIME ZONE v_board.time_zone,
        lease_token = NULL, lease_expires_at = NULL, updated_at = p_now
    WHERE job.id = p_job.id;
    RETURN pg_catalog.jsonb_build_object('status', 'not_due');
  END IF;

  v_final_on := CASE
    WHEN v_series.occurrence_limit IS NOT NULL
      THEN v_series.start_on + (v_series.occurrence_limit - 1)::integer
    ELSE v_series.end_on
  END;
  IF v_final_on IS NOT NULL AND v_today > v_final_on THEN
    v_target_on := v_final_on;
  ELSE
    v_target_on := v_today;
  END IF;
  v_target_on := greatest(v_target_on, v_series.next_due_on);

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
  IF v_series.end_on IS NOT NULL AND v_target_on > v_series.end_on THEN
    UPDATE public.daily_repetition_series AS series
    SET state = 'finished', next_due_on = NULL, revision = series.revision + 1,
        updated_at = p_now
    WHERE series.id = v_series.id;
    RETURN pg_catalog.jsonb_build_object('status', 'finished');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.series_id = v_series.id AND occurrence.occurrence_on = v_target_on
  ) THEN
    UPDATE public.daily_repetition_series AS series
    SET state = CASE WHEN v_final_on IS NOT NULL AND v_target_on >= v_final_on
        THEN 'finished' ELSE 'active' END,
        latest_occurrence_on = greatest(series.latest_occurrence_on, v_target_on),
        consumed_count = CASE WHEN series.occurrence_limit IS NULL
          THEN series.consumed_count + greatest(1, v_target_on - series.latest_occurrence_on)
          ELSE least(series.occurrence_limit,
            series.consumed_count + greatest(1, v_target_on - series.latest_occurrence_on)) END,
        next_due_on = CASE WHEN v_final_on IS NOT NULL AND v_target_on >= v_final_on
          THEN NULL ELSE v_target_on + 1 END,
        revision = series.revision + 1, updated_at = p_now
    WHERE series.id = v_series.id;
    RETURN pg_catalog.jsonb_build_object('status', 'already_present');
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

  v_gap := greatest(1, v_target_on - v_series.latest_occurrence_on);
  UPDATE public.daily_repetition_series AS series
  SET latest_occurrence_on = v_target_on,
      consumed_count = CASE WHEN series.occurrence_limit IS NULL
        THEN series.consumed_count + v_gap
        ELSE least(series.occurrence_limit, series.consumed_count + v_gap) END,
      current_occurrence_id = v_new_occurrence_id,
      state = CASE WHEN v_final_on IS NOT NULL AND v_target_on >= v_final_on
          OR (series.occurrence_limit IS NOT NULL
            AND series.consumed_count + v_gap >= series.occurrence_limit)
        THEN 'finished' ELSE 'active' END,
      next_due_on = CASE WHEN v_final_on IS NOT NULL AND v_target_on >= v_final_on
          OR (series.occurrence_limit IS NOT NULL
            AND series.consumed_count + v_gap >= series.occurrence_limit)
        THEN NULL ELSE v_target_on + 1 END,
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
REVOKE ALL ON FUNCTION public.advance_daily_repetition_internal_p(
  public.daily_repetition_jobs, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.purge_daily_repetition_tasks_internal_p(
  p_limit integer,
  p_now timestamptz
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_task_id uuid;
  v_purged integer := 0;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000
    OR p_now IS NULL OR NOT pg_catalog.isfinite(p_now) THEN
    RAISE EXCEPTION 'Choose a valid purge batch and timestamp' USING ERRCODE = '22023';
  END IF;
  FOR v_task_id IN
    SELECT deletion.task_id
    FROM public.task_deletions AS deletion
    WHERE deletion.state = 'deleted' AND deletion.expires_at <= p_now
    ORDER BY deletion.expires_at, deletion.task_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    IF public.purge_expired_task_internal_p(v_task_id, p_now) = 'purged' THEN
      v_purged := v_purged + 1;
    END IF;
  END LOOP;
  RETURN v_purged;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_daily_repetition_tasks_internal_p(integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.process_daily_repetition_job_internal_p(
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
  WHERE job.id = p_job_id
  FOR UPDATE;
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

  IF v_result->>'status' = 'not_due' THEN
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

CREATE FUNCTION public.run_daily_repetition_jobs_p(p_limit integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_job record;
  v_processed integer := 0;
  v_confirmed integer := 0;
  v_failed integer := 0;
  v_result jsonb;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 THEN
    RAISE EXCEPTION 'Choose a worker batch from 1 to 100' USING ERRCODE = '22023';
  END IF;
  FOR v_job IN
    SELECT * FROM public.claim_daily_repetition_jobs_internal_p(p_limit, v_now)
  LOOP
    v_result := public.process_daily_repetition_job_internal_p(v_job.id, v_job.lease_token, v_now);
    v_processed := v_processed + 1;
    IF v_result->>'status' IN ('confirmed', 'finished', 'already_present', 'superseded') THEN
      v_confirmed := v_confirmed + 1;
    ELSIF v_result->>'status' IN ('retry_wait', 'dead_letter') THEN
      v_failed := v_failed + 1;
    END IF;
  END LOOP;
  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'claimed', v_processed,
    'completed', v_confirmed, 'failed', v_failed
  );
END;
$$;
REVOKE ALL ON FUNCTION public.run_daily_repetition_jobs_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.run_daily_repetition_jobs_p(integer) TO service_role;

CREATE FUNCTION public.get_daily_repetition_p(p_slug text, p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series public.daily_repetition_series%ROWTYPE;
  v_board_id uuid;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_task_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.id INTO v_board_id FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
  WHERE occurrence.task_id = p_task_id AND series.board_id = v_board_id
  ORDER BY occurrence.created_at DESC, occurrence.id DESC
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'not_repeating');
  END IF;
  SELECT pg_catalog.jsonb_build_object(
    'status', 'available', 'series_id', v_series.id, 'state', v_series.state,
    'start_on', v_series.start_on, 'end_on', v_series.end_on,
    'occurrence_limit', v_series.occurrence_limit,
    'consumed_count', v_series.consumed_count,
    'latest_occurrence_on', v_series.latest_occurrence_on,
    'next_due_on', v_series.next_due_on, 'revision', v_series.revision,
    'occurrences', coalesce((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'occurrence_on', occurrence.occurrence_on, 'task_id', occurrence.task_id,
        'state', occurrence.state, 'due_on_override', occurrence.due_on_override
      ) ORDER BY occurrence.occurrence_on)
      FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = v_series.id
    ), '[]'::jsonb),
    'diagnostic', (
      SELECT pg_catalog.jsonb_build_object(
        'status', job.state, 'attempt_count', job.attempt_count,
        'last_error_code', job.last_error_code, 'last_error_at', job.last_error_at
      )
      FROM public.daily_repetition_jobs AS job
      WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
      ORDER BY job.created_at DESC, job.id DESC LIMIT 1
    )
  ) INTO v_result;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_daily_repetition_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_daily_repetition_p(text, uuid) TO authenticated;

CREATE FUNCTION public.guard_daily_occurrence_due_on_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_occurrence public.daily_repetition_occurrences%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
BEGIN
  IF TG_OP <> 'UPDATE' OR NEW.due_on IS NOT DISTINCT FROM OLD.due_on THEN
    RETURN NEW;
  END IF;
  SELECT occurrence.* INTO v_occurrence
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.task_id = OLD.id AND occurrence.state = 'current'
  ORDER BY occurrence.created_at DESC, occurrence.id DESC LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = v_occurrence.series_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NEW; END IF;
  IF v_series.state = 'active' AND v_series.next_due_on IS NOT NULL
    AND NEW.due_on IS NOT NULL AND NEW.due_on >= v_series.next_due_on THEN
    RAISE EXCEPTION 'La fecha excepcional debe ser anterior a la próxima repetición (%).',
      v_series.next_due_on
      USING ERRCODE = 'P2301', DETAIL = v_series.next_due_on::text;
  END IF;
  UPDATE public.daily_repetition_occurrences AS occurrence
  SET due_on_override = NEW.due_on
  WHERE occurrence.id = v_occurrence.id;
  RETURN NEW;
END;
$$;
CREATE TRIGGER tasks_guard_daily_occurrence_due_on
  BEFORE UPDATE OF due_on ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.guard_daily_occurrence_due_on_tg();
REVOKE ALL ON FUNCTION public.guard_daily_occurrence_due_on_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.sync_daily_repetition_template_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series public.daily_repetition_series%ROWTYPE;
BEGIN
  IF NEW.title IS NOT DISTINCT FROM OLD.title
    AND NEW.description IS NOT DISTINCT FROM OLD.description
    AND NEW.priority IS NOT DISTINCT FROM OLD.priority
    AND NEW.assignee_id IS NOT DISTINCT FROM OLD.assignee_id
    AND NEW.steps IS NOT DISTINCT FROM OLD.steps
    AND NEW.column_id IS NOT DISTINCT FROM OLD.column_id THEN
    RETURN NEW;
  END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
  WHERE occurrence.task_id = NEW.id AND occurrence.state = 'current'
    AND series.state = 'active'
  ORDER BY occurrence.created_at DESC, occurrence.id DESC LIMIT 1
  FOR UPDATE OF series;
  IF NOT FOUND THEN RETURN NEW; END IF;

  UPDATE public.daily_repetition_jobs AS job
  SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
      completed_at = pg_catalog.clock_timestamp(), updated_at = pg_catalog.clock_timestamp()
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait', 'leased');
  UPDATE public.daily_repetition_series AS series
  SET template_snapshot = pg_catalog.jsonb_build_object(
        'title', NEW.title, 'description', NEW.description,
        'priority', NEW.priority, 'assignee_id', NEW.assignee_id, 'steps', NEW.steps
      ),
      appearance_column_id = NEW.column_id,
      revision = series.revision + 1,
      updated_at = pg_catalog.clock_timestamp()
  WHERE series.id = v_series.id;
  INSERT INTO public.daily_repetition_jobs(
    job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
  )
  SELECT 'advance', series.id, series.revision, series.next_due_on,
    pg_catalog.format('advance:%s:%s:%s', series.id, series.revision, series.next_due_on),
    series.next_due_on::timestamp AT TIME ZONE board.time_zone
  FROM public.daily_repetition_series AS series
  JOIN public.boards AS board ON board.id = series.board_id
  WHERE series.id = v_series.id AND series.state = 'active'
  ON CONFLICT (dedupe_key) DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER tasks_sync_daily_repetition_template
  AFTER UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.sync_daily_repetition_template_tg();
REVOKE ALL ON FUNCTION public.sync_daily_repetition_template_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.sync_daily_repetition_task_deletion_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_occurrence public.daily_repetition_occurrences%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_task public.tasks%ROWTYPE;
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
      )
      AND series.id = occurrence.series_id;
    SELECT occurrence.* INTO v_occurrence
    FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'current'
    ORDER BY occurrence.created_at DESC, occurrence.id DESC LIMIT 1;
    IF FOUND THEN
      SELECT task.* INTO v_task
      FROM public.tasks AS task WHERE task.id = NEW.task_id;
      SELECT series.* INTO v_series
      FROM public.daily_repetition_series AS series
      WHERE series.id = v_occurrence.series_id AND series.state = 'active'
      FOR UPDATE;
      IF FOUND THEN
        UPDATE public.daily_repetition_jobs AS job
        SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
            completed_at = pg_catalog.clock_timestamp(), updated_at = pg_catalog.clock_timestamp()
        WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
          AND job.state IN ('queued', 'retry_wait', 'leased');
        UPDATE public.daily_repetition_series AS series
        SET template_snapshot = pg_catalog.jsonb_build_object(
              'title', v_task.title, 'description', v_task.description,
              'priority', v_task.priority, 'assignee_id', v_task.assignee_id,
              'steps', v_task.steps
            ),
            appearance_column_id = v_task.column_id,
            revision = series.revision + 1,
            updated_at = pg_catalog.clock_timestamp()
        WHERE series.id = v_series.id
        RETURNING series.* INTO v_series;
        INSERT INTO public.daily_repetition_jobs(
          job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
        )
        SELECT 'advance', series.id, series.revision, series.next_due_on,
          pg_catalog.format('advance:%s:%s:%s', series.id, series.revision, series.next_due_on),
          series.next_due_on::timestamp AT TIME ZONE board.time_zone
        FROM public.daily_repetition_series AS series
        JOIN public.boards AS board ON board.id = series.board_id
        WHERE series.id = v_series.id AND series.state = 'active'
          AND series.next_due_on IS NOT NULL
        ON CONFLICT (dedupe_key) DO NOTHING;
      END IF;
    END IF;
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
CREATE TRIGGER task_deletions_sync_daily_repetition_insert
  AFTER INSERT ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.sync_daily_repetition_task_deletion_tg();
CREATE TRIGGER task_deletions_sync_daily_repetition_update
  AFTER UPDATE OF state ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.sync_daily_repetition_task_deletion_tg();
REVOKE ALL ON FUNCTION public.sync_daily_repetition_task_deletion_tg()
  FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
