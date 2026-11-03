BEGIN;

ALTER TABLE public.daily_repetition_series
  DROP CONSTRAINT IF EXISTS daily_repetition_series_rule_check;
ALTER TABLE public.daily_repetition_series
  ADD CONSTRAINT daily_repetition_series_rule_check
  CHECK (rule IN ('daily', 'weekly', 'monthly', 'yearly'));

CREATE OR REPLACE FUNCTION public.normalize_repetition_pattern_internal_p(p_pattern jsonb)
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
  v_day_text text;
  v_day integer;
  v_ordinal_text text;
  v_weekday_text text;
  v_ordinal integer;
  v_weekday integer;
  v_month_text text;
  v_month integer;
BEGIN
  IF pg_catalog.jsonb_typeof(p_pattern) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Elige una regla de repetición válida' USING ERRCODE = '22023';
  END IF;
  v_frequency := p_pattern->>'frequency';
  v_interval_text := p_pattern->>'interval';
  IF v_frequency NOT IN ('daily', 'weekly', 'monthly', 'yearly')
    OR v_interval_text IS NULL
    OR v_interval_text !~ '^[1-9][0-9]*$'
    OR pg_catalog.length(v_interval_text) > 19 THEN
    RAISE EXCEPTION 'Elige un intervalo de repetición positivo' USING ERRCODE = '22023';
  END IF;
  v_interval := v_interval_text::bigint;
  IF v_frequency IN ('daily', 'weekly') AND v_interval > 2147483647 THEN
    RAISE EXCEPTION 'El intervalo supera el calendario admitido' USING ERRCODE = '22023';
  END IF;
  IF v_frequency = 'daily' AND v_interval <> 1 THEN
    RAISE EXCEPTION 'La repetición diaria mantiene un intervalo de un día' USING ERRCODE = '22023';
  END IF;

  IF v_frequency = 'monthly' THEN
    IF p_pattern ? 'day_of_month' THEN
      v_expected_keys := 3;
    ELSIF p_pattern ? 'ordinal' AND p_pattern ? 'weekday' THEN
      v_expected_keys := 4;
    ELSE
      RAISE EXCEPTION 'Elige un día o un ordinal semanal del mes' USING ERRCODE = '22023';
    END IF;
  ELSIF v_frequency = 'yearly' THEN
    IF p_pattern ? 'day_of_month' AND p_pattern ? 'month' THEN
      v_expected_keys := 4;
    ELSIF p_pattern ? 'ordinal' AND p_pattern ? 'weekday' AND p_pattern ? 'month' THEN
      v_expected_keys := 5;
    ELSE
      RAISE EXCEPTION 'Elige una fecha o un ordinal semanal del año' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_expected_keys := CASE WHEN v_frequency = 'weekly' THEN 3 ELSE 2 END;
  END IF;
  IF (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(p_pattern))
    <> v_expected_keys THEN
    RAISE EXCEPTION 'Revisa la frecuencia y el patrón elegidos' USING ERRCODE = '22023';
  END IF;

  IF v_frequency = 'daily' THEN
    RETURN pg_catalog.jsonb_build_object(
      'frequency', 'daily', 'interval', v_interval
    );
  END IF;

  IF v_frequency = 'weekly' THEN
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
  END IF;

  IF v_frequency = 'yearly' THEN
    v_month_text := p_pattern->>'month';
    IF pg_catalog.jsonb_typeof(p_pattern->'month') IS DISTINCT FROM 'number'
      OR v_month_text IS NULL OR v_month_text !~ '^([1-9]|1[0-2])$' THEN
      RAISE EXCEPTION 'Elige un mes entre enero y diciembre' USING ERRCODE = '22023';
    END IF;
    v_month := v_month_text::integer;
    IF p_pattern ? 'day_of_month' THEN
      v_day_text := p_pattern->>'day_of_month';
      IF pg_catalog.jsonb_typeof(p_pattern->'day_of_month') IS DISTINCT FROM 'number'
        OR v_day_text IS NULL OR v_day_text !~ '^(-1|[1-9]|[12][0-9]|3[01])$' THEN
        RAISE EXCEPTION 'Elige un día del mes entre 1 y 31 o el último día' USING ERRCODE = '22023';
      END IF;
      RETURN pg_catalog.jsonb_build_object(
        'frequency', 'yearly', 'interval', v_interval_text, 'month', v_month,
        'day_of_month', v_day_text::integer
      );
    END IF;
    v_ordinal_text := p_pattern->>'ordinal';
    v_weekday_text := p_pattern->>'weekday';
    IF pg_catalog.jsonb_typeof(p_pattern->'ordinal') IS DISTINCT FROM 'number'
      OR pg_catalog.jsonb_typeof(p_pattern->'weekday') IS DISTINCT FROM 'number'
      OR v_ordinal_text IS NULL OR v_ordinal_text !~ '^(-1|[1-5])$'
      OR v_weekday_text IS NULL OR v_weekday_text !~ '^[1-7]$' THEN
      RAISE EXCEPTION 'Elige un ordinal y un día de la semana válidos' USING ERRCODE = '22023';
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'frequency', 'yearly', 'interval', v_interval_text, 'month', v_month,
      'ordinal', v_ordinal_text::integer, 'weekday', v_weekday_text::integer
    );
  END IF;

  IF NOT (p_pattern ? 'day_of_month') THEN
    v_ordinal_text := p_pattern->>'ordinal';
    v_weekday_text := p_pattern->>'weekday';
    IF pg_catalog.jsonb_typeof(p_pattern->'ordinal') IS DISTINCT FROM 'number'
      OR pg_catalog.jsonb_typeof(p_pattern->'weekday') IS DISTINCT FROM 'number'
      OR v_ordinal_text IS NULL OR v_ordinal_text !~ '^(-1|[1-5])$'
      OR v_weekday_text IS NULL OR v_weekday_text !~ '^[1-7]$' THEN
      RAISE EXCEPTION 'Elige un ordinal y un día de la semana válidos' USING ERRCODE = '22023';
    END IF;
    v_ordinal := v_ordinal_text::integer;
    v_weekday := v_weekday_text::integer;
    RETURN pg_catalog.jsonb_build_object(
      'frequency', 'monthly', 'interval', v_interval_text,
      'ordinal', v_ordinal, 'weekday', v_weekday
    );
  END IF;

  v_day_text := p_pattern->>'day_of_month';
  IF pg_catalog.jsonb_typeof(p_pattern->'day_of_month') IS DISTINCT FROM 'number'
    OR v_day_text IS NULL OR v_day_text !~ '^(-1|[1-9]|[12][0-9]|3[01])$' THEN
    RAISE EXCEPTION 'Elige un día del mes entre 1 y 31 o el último día' USING ERRCODE = '22023';
  END IF;
  v_day := v_day_text::integer;
  RETURN pg_catalog.jsonb_build_object(
    'frequency', 'monthly', 'interval', v_interval_text, 'day_of_month', v_day
  );
END;
$$;
REVOKE ALL ON FUNCTION public.normalize_repetition_pattern_internal_p(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.repetition_calendar_month_day_internal_p(
  p_year integer,
  p_month integer,
  p_day integer
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_last_day integer;
BEGIN
  IF p_year < 1 OR p_year > 5874897 OR p_month < 1 OR p_month > 12
    OR (p_day <> -1 AND (p_day < 1 OR p_day > 31)) THEN
    RETURN NULL;
  END IF;
  v_last_day := CASE
    WHEN p_month = 2 THEN CASE
      WHEN pg_catalog.mod(p_year, 4) = 0
        AND (pg_catalog.mod(p_year, 100) <> 0 OR pg_catalog.mod(p_year, 400) = 0)
        THEN 29
      ELSE 28
    END
    WHEN p_month IN (4, 6, 9, 11) THEN 30
    ELSE 31
  END;
  RETURN pg_catalog.make_date(
    p_year, p_month, CASE WHEN p_day = -1 THEN v_last_day ELSE least(p_day, v_last_day) END
  );
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_month_day_internal_p(integer, integer, integer)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.repetition_calendar_ordinal_on_internal_p(
  p_year integer,
  p_month integer,
  p_ordinal integer,
  p_weekday integer
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_first date;
  v_last date;
  v_day_offset integer;
  v_candidate date;
BEGIN
  IF p_ordinal NOT IN (1, 2, 3, 4, 5, -1)
    OR p_weekday < 1 OR p_weekday > 7 THEN
    RETURN NULL;
  END IF;
  v_first := pg_catalog.make_date(p_year, p_month, 1);
  v_last := public.repetition_calendar_month_day_internal_p(p_year, p_month, 31);
  IF p_ordinal = -1 THEN
    RETURN v_last - pg_catalog.mod(
      extract(isodow FROM v_last)::integer - p_weekday + 7, 7
    );
  END IF;
  v_day_offset := pg_catalog.mod(
    p_weekday - extract(isodow FROM v_first)::integer + 7, 7
  );
  v_candidate := v_first + v_day_offset + (p_ordinal - 1) * 7;
  RETURN CASE WHEN v_candidate <= v_last THEN v_candidate ELSE NULL END;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_ordinal_on_internal_p(integer, integer, integer, integer)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.repetition_calendar_ordinal_cycle_internal_p(
  p_start_on date,
  p_pattern jsonb
)
RETURNS TABLE(cycle_length integer, occurrence_steps integer[])
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_period integer;
  v_interval_mod integer;
  v_gcd_left integer;
  v_gcd_right integer;
  v_remainder integer;
  v_cycle_length integer;
  v_step integer;
  v_start_serial integer;
  v_calendar_serial integer;
  v_year integer;
  v_month integer;
  v_valid_steps integer[] := ARRAY[]::integer[];
BEGIN
  IF v_pattern->>'frequency' NOT IN ('monthly', 'yearly')
    OR NOT (v_pattern ? 'ordinal')
    OR p_start_on IS NULL OR NOT pg_catalog.isfinite(p_start_on) THEN
    RAISE EXCEPTION 'Revisa el ancla del ordinal semanal' USING ERRCODE = '22023';
  END IF;
  IF extract(year FROM p_start_on) < 1 THEN
    RAISE EXCEPTION 'La fecha inicial debe pertenecer a un año del calendario' USING ERRCODE = '22023';
  END IF;

  IF v_pattern->>'frequency' = 'monthly' THEN
    v_period := 4800;
    v_start_serial := pg_catalog.mod(
      ((extract(year FROM p_start_on)::integer - 1) * 12)
        + extract(month FROM p_start_on)::integer - 1,
      v_period
    );
  ELSE
    v_period := 400;
    v_start_serial := pg_catalog.mod(extract(year FROM p_start_on)::integer - 1, v_period);
  END IF;
  v_interval_mod := pg_catalog.mod((v_pattern->>'interval')::bigint, v_period)::integer;
  v_gcd_left := v_period;
  v_gcd_right := v_interval_mod;
  WHILE v_gcd_right > 0 LOOP
    v_remainder := pg_catalog.mod(v_gcd_left, v_gcd_right);
    v_gcd_left := v_gcd_right;
    v_gcd_right := v_remainder;
  END LOOP;
  v_cycle_length := v_period / v_gcd_left;

  FOR v_step IN 1..v_cycle_length LOOP
    v_calendar_serial := pg_catalog.mod(
      v_start_serial + v_step * v_interval_mod, v_period
    );
    IF v_pattern->>'frequency' = 'monthly' THEN
      v_year := v_calendar_serial / 12 + 1;
      v_month := pg_catalog.mod(v_calendar_serial, 12) + 1;
    ELSE
      v_year := v_calendar_serial + 1;
      v_month := (v_pattern->>'month')::integer;
    END IF;
    IF public.repetition_calendar_ordinal_on_internal_p(
      v_year, v_month, (v_pattern->>'ordinal')::integer,
      (v_pattern->>'weekday')::integer
    ) IS NOT NULL THEN
      v_valid_steps := pg_catalog.array_append(v_valid_steps, v_step);
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_cycle_length, v_valid_steps;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_ordinal_cycle_internal_p(date, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.repetition_calendar_month_occurrence_internal_p(
  p_start_on date,
  p_steps numeric,
  p_pattern jsonb
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_start_year numeric;
  v_month_index numeric;
  v_year_index numeric;
  v_year integer;
  v_month integer;
  v_day integer;
BEGIN
  IF v_pattern->>'frequency' <> 'monthly' OR p_start_on IS NULL
    OR p_steps IS NULL OR p_steps < 0 OR NOT pg_catalog.isfinite(p_start_on) THEN
    RAISE EXCEPTION 'Revisa la fecha inicial y la cantidad de ocurrencias' USING ERRCODE = '22023';
  END IF;
  v_start_year := extract(year FROM p_start_on);
  IF v_start_year < 1 THEN
    RAISE EXCEPTION 'La fecha inicial debe pertenecer a un año del calendario' USING ERRCODE = '22023';
  END IF;
  v_month_index := ((v_start_year - 1) * 12)
    + extract(month FROM p_start_on) - 1
    + p_steps * (v_pattern->>'interval')::numeric;
  IF v_month_index > ((5874897 - 1) * 12 + 11) THEN
    RETURN NULL;
  END IF;
  v_year_index := pg_catalog.floor(v_month_index / 12);
  v_year := (v_year_index + 1)::integer;
  v_month := (pg_catalog.mod(v_month_index, 12) + 1)::integer;
  IF v_pattern ? 'ordinal' THEN
    RETURN public.repetition_calendar_ordinal_on_internal_p(
      v_year, v_month, (v_pattern->>'ordinal')::integer,
      (v_pattern->>'weekday')::integer
    );
  END IF;
  v_day := (v_pattern->>'day_of_month')::integer;
  RETURN public.repetition_calendar_month_day_internal_p(
    v_year, v_month, v_day
  );
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_month_occurrence_internal_p(date, numeric, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.repetition_calendar_year_occurrence_internal_p(
  p_start_on date,
  p_steps numeric,
  p_pattern jsonb
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_start_year numeric;
  v_year numeric;
BEGIN
  IF v_pattern->>'frequency' <> 'yearly' OR p_start_on IS NULL
    OR p_steps IS NULL OR p_steps < 0 OR NOT pg_catalog.isfinite(p_start_on) THEN
    RAISE EXCEPTION 'Revisa la fecha inicial y la cantidad de ocurrencias' USING ERRCODE = '22023';
  END IF;
  v_start_year := extract(year FROM p_start_on);
  IF v_start_year < 1 THEN
    RAISE EXCEPTION 'La fecha inicial debe pertenecer a un año del calendario' USING ERRCODE = '22023';
  END IF;
  v_year := v_start_year + p_steps * (v_pattern->>'interval')::numeric;
  IF v_year > 5874897 THEN RETURN NULL; END IF;
  IF v_pattern ? 'ordinal' THEN
    RETURN public.repetition_calendar_ordinal_on_internal_p(
      v_year::integer, (v_pattern->>'month')::integer,
      (v_pattern->>'ordinal')::integer, (v_pattern->>'weekday')::integer
    );
  END IF;
  RETURN public.repetition_calendar_month_day_internal_p(
    v_year::integer, (v_pattern->>'month')::integer,
    (v_pattern->>'day_of_month')::integer
  );
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_year_occurrence_internal_p(date, numeric, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.repetition_calendar_occurrence_on_internal_p(date, bigint, jsonb)
  RENAME TO repetition_calendar_occurrence_daily_weekly_internal_p;
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
  v_cycle_length integer;
  v_occurrence_steps integer[];
  v_valid_count integer;
  v_needed numeric;
  v_cycle_number numeric;
  v_step_position integer;
  v_steps numeric;
  v_initial_candidate date;
  v_frequency text;
BEGIN
  IF p_start_on IS NULL OR p_occurrence_number IS NULL
    OR p_occurrence_number < 1 OR NOT pg_catalog.isfinite(p_start_on) THEN
    RAISE EXCEPTION 'Revisa la fecha inicial y la cantidad de ocurrencias' USING ERRCODE = '22023';
  END IF;
  IF p_occurrence_number = 1 THEN
    RETURN p_start_on;
  END IF;
  v_frequency := v_pattern->>'frequency';
  IF v_frequency IN ('monthly', 'yearly') THEN
    v_initial_candidate := CASE WHEN v_frequency = 'monthly'
      THEN public.repetition_calendar_month_occurrence_internal_p(p_start_on, 0, v_pattern)
      ELSE public.repetition_calendar_year_occurrence_internal_p(p_start_on, 0, v_pattern)
    END;
    IF v_initial_candidate > p_start_on THEN
      IF p_occurrence_number = 2 THEN RETURN v_initial_candidate; END IF;
      v_needed := p_occurrence_number - 2;
    ELSE
      v_needed := p_occurrence_number - 1;
    END IF;
    IF v_pattern ? 'ordinal' THEN
      SELECT calendar.cycle_length, calendar.occurrence_steps
      INTO v_cycle_length, v_occurrence_steps
      FROM public.repetition_calendar_ordinal_cycle_internal_p(p_start_on, v_pattern) AS calendar;
      v_valid_count := coalesce(pg_catalog.array_length(v_occurrence_steps, 1), 0);
      IF v_valid_count = 0 THEN RETURN NULL; END IF;
      IF v_needed = 0 THEN RETURN v_initial_candidate; END IF;
      v_cycle_number := pg_catalog.floor((v_needed - 1) / v_valid_count);
      v_step_position := pg_catalog.mod(v_needed - 1, v_valid_count)::integer + 1;
      v_steps := v_cycle_number * v_cycle_length + v_occurrence_steps[v_step_position];
    ELSE
      v_steps := v_needed;
    END IF;
    RETURN CASE WHEN v_frequency = 'monthly'
      THEN public.repetition_calendar_month_occurrence_internal_p(p_start_on, v_steps, v_pattern)
      ELSE public.repetition_calendar_year_occurrence_internal_p(p_start_on, v_steps, v_pattern)
    END;
  END IF;
  RETURN public.repetition_calendar_occurrence_daily_weekly_internal_p(
    p_start_on, p_occurrence_number, v_pattern
  );
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_occurrence_on_internal_p(date, bigint, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.repetition_calendar_count_internal_p(date, date, jsonb)
  RENAME TO repetition_calendar_count_daily_weekly_internal_p;
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
  v_period_delta numeric;
  v_steps numeric;
  v_cycle_length integer;
  v_occurrence_steps integer[];
  v_valid_count integer;
  v_full_cycles numeric;
  v_remainder integer;
  v_tail_count bigint;
  v_future_count numeric;
  v_count bigint;
  v_last_occurrence date;
  v_initial_candidate date;
  v_frequency text;
BEGIN
  IF p_start_on IS NULL OR p_through_on IS NULL
    OR NOT pg_catalog.isfinite(p_start_on) OR NOT pg_catalog.isfinite(p_through_on) THEN
    RAISE EXCEPTION 'Revisa el intervalo de fechas de la serie' USING ERRCODE = '22023';
  END IF;
  IF p_through_on < p_start_on THEN RETURN 0; END IF;
  v_frequency := v_pattern->>'frequency';
  IF v_frequency IN ('daily', 'weekly') THEN
    RETURN public.repetition_calendar_count_daily_weekly_internal_p(
      p_start_on, p_through_on, v_pattern
    );
  END IF;

  v_period_delta := CASE WHEN v_frequency = 'monthly'
    THEN (extract(year FROM p_through_on) - extract(year FROM p_start_on)) * 12
      + extract(month FROM p_through_on) - extract(month FROM p_start_on)
    ELSE extract(year FROM p_through_on) - extract(year FROM p_start_on)
  END;
  v_steps := pg_catalog.floor(v_period_delta / (v_pattern->>'interval')::numeric);
  IF v_pattern ? 'ordinal' THEN
    SELECT calendar.cycle_length, calendar.occurrence_steps
    INTO v_cycle_length, v_occurrence_steps
    FROM public.repetition_calendar_ordinal_cycle_internal_p(p_start_on, v_pattern) AS calendar;
    v_valid_count := coalesce(pg_catalog.array_length(v_occurrence_steps, 1), 0);
    IF v_valid_count = 0 THEN
      v_future_count := 0;
    ELSE
      v_full_cycles := pg_catalog.floor(v_steps / v_cycle_length);
      v_remainder := pg_catalog.mod(v_steps, v_cycle_length)::integer;
      SELECT pg_catalog.count(*) INTO v_tail_count
      FROM pg_catalog.unnest(v_occurrence_steps) AS step(value)
      WHERE step.value <= v_remainder;
      v_future_count := v_full_cycles * v_valid_count + v_tail_count;
    END IF;
  ELSE
    v_future_count := v_steps;
  END IF;
  v_initial_candidate := CASE WHEN v_frequency = 'monthly'
    THEN public.repetition_calendar_month_occurrence_internal_p(p_start_on, 0, v_pattern)
    ELSE public.repetition_calendar_year_occurrence_internal_p(p_start_on, 0, v_pattern)
  END;
  IF v_initial_candidate > p_start_on AND v_initial_candidate <= p_through_on THEN
    v_future_count := v_future_count + 1;
  END IF;
  v_count := (1 + v_future_count)::bigint;
  IF v_future_count > 0 THEN
    v_last_occurrence := public.repetition_calendar_occurrence_on_internal_p(
      p_start_on, v_count, v_pattern
    );
    IF v_last_occurrence IS NULL OR v_last_occurrence > p_through_on THEN
      v_count := v_count - 1;
    END IF;
  END IF;
  RETURN greatest(0, v_count);
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_count_internal_p(date, date, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.repetition_calendar_preview_dates_internal_p(date, date, date, jsonb)
  RENAME TO repetition_calendar_preview_daily_weekly_internal_p;
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
  v_pattern jsonb := public.normalize_repetition_pattern_internal_p(p_pattern);
  v_before_count bigint;
  v_through_count bigint;
  v_dates jsonb;
BEGIN
  IF p_start_on IS NULL OR p_preview_from IS NULL
    OR NOT pg_catalog.isfinite(p_start_on) OR NOT pg_catalog.isfinite(p_preview_from)
    OR (p_final_on IS NOT NULL AND NOT pg_catalog.isfinite(p_final_on))
    OR (p_final_on IS NOT NULL AND p_final_on < p_start_on) THEN
    RAISE EXCEPTION 'Revisa la vista previa del calendario' USING ERRCODE = '22023';
  END IF;
  IF v_pattern->>'frequency' IN ('daily', 'weekly') THEN
    RETURN public.repetition_calendar_preview_daily_weekly_internal_p(
      p_start_on, p_preview_from, p_final_on, v_pattern
    );
  END IF;

  v_before_count := CASE WHEN p_preview_from <= p_start_on THEN 0 ELSE
    public.repetition_calendar_count_internal_p(
      p_start_on, p_preview_from - 1, v_pattern
    ) END;
  v_through_count := public.repetition_calendar_count_internal_p(
    p_start_on, coalesce(p_final_on, date '5874897-12-31'), v_pattern
  );
  IF v_before_count >= v_through_count THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT coalesce(
    pg_catalog.jsonb_agg(candidate.occurrence_on ORDER BY candidate.occurrence_on),
    '[]'::jsonb
  )
  INTO v_dates
  FROM (
    SELECT public.repetition_calendar_occurrence_on_internal_p(
      p_start_on, occurrence_number.value, v_pattern
    ) AS occurrence_on
    FROM pg_catalog.generate_series(
      v_before_count + 1, least(v_through_count, v_before_count + 5)
    ) AS occurrence_number(value)
  ) AS candidate
  WHERE candidate.occurrence_on IS NOT NULL
    AND candidate.occurrence_on >= p_preview_from
    AND (p_final_on IS NULL OR candidate.occurrence_on <= p_final_on);
  RETURN v_dates;
END;
$$;
REVOKE ALL ON FUNCTION public.repetition_calendar_preview_dates_internal_p(date, date, date, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
