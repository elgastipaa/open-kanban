-- Keep an advanced next occurrence strictly after the deadline of the current
-- task. The public wrappers add actionable preview/result data and validate the
-- final condition while holding the same board/task locks as the write path.

ALTER FUNCTION public.preview_repetition_with_advance_p(
  text, uuid, date, date, bigint, jsonb, integer
) RENAME TO preview_repetition_with_advance_base_internal_p;
REVOKE ALL ON FUNCTION public.preview_repetition_with_advance_base_internal_p(
  text, uuid, date, date, bigint, jsonb, integer
) FROM PUBLIC, anon, authenticated, service_role;

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
  v_result jsonb;
  v_first_due_on date;
  v_first_appearance_on date;
  v_current_due_on date;
BEGIN
  v_result := public.preview_repetition_with_advance_base_internal_p(
    p_slug, p_task_id, p_start_on, p_end_on, p_occurrence_limit,
    p_pattern, p_advance_days
  );
  IF v_result->>'status' IS DISTINCT FROM 'available' THEN
    RETURN v_result;
  END IF;
  v_first_due_on := public.repetition_calendar_next_on_internal_p(
    p_start_on, p_start_on, NULLIF(v_result->>'final_on', '')::date,
    v_result->'pattern'
  );
  v_first_appearance_on := CASE WHEN v_first_due_on IS NULL THEN NULL
    ELSE v_first_due_on - p_advance_days END;
  v_current_due_on := NULLIF(v_result->'current'->>'due_on', '')::date;
  RETURN v_result || pg_catalog.jsonb_build_object(
    'first_future_due_on', v_first_due_on,
    'first_appearance_on', v_first_appearance_on,
    'current_due_on', v_current_due_on,
    'appearance_compatible', v_first_appearance_on IS NULL
      OR (v_current_due_on IS NOT NULL AND v_first_appearance_on > v_current_due_on)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_repetition_with_advance_p(
  text, uuid, date, date, bigint, jsonb, integer
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_repetition_with_advance_p(
  text, uuid, date, date, bigint, jsonb, integer
) TO authenticated;

ALTER FUNCTION public.create_repetition_with_advance_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb, integer, uuid
) RENAME TO create_repetition_with_advance_base_internal_p;
REVOKE ALL ON FUNCTION public.create_repetition_with_advance_base_internal_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb, integer, uuid
) FROM PUBLIC, anon, authenticated, service_role;

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
  v_preview jsonb;
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
  v_task public.tasks%ROWTYPE;
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
  IF FOUND THEN
    IF v_receipt.action = 'create' AND (
      coalesce(v_receipt.advance_days, 0) <> p_advance_days
      OR (p_appearance_column_id IS NOT NULL
        AND v_receipt.result->>'appearance_column_id' IS DISTINCT FROM p_appearance_column_id::text)
    ) THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otra anticipación o columna' USING ERRCODE = '23514';
    END IF;
    RETURN public.create_repetition_with_advance_base_internal_p(
      p_operation_id, p_slug, p_task_id, p_start_on, p_end_on,
      p_occurrence_limit, p_expected_due_on_version, p_confirm_start_change,
      p_previous_series_id, v_pattern, p_advance_days, p_appearance_column_id
    );
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  PERFORM 1 FROM public.boards AS board WHERE board.id = v_board_id FOR UPDATE;
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug AND board.id = v_board_id
    AND public.is_application_user() AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;

  -- A concurrent retry may have written the receipt while this call waited on
  -- the board. Preserve the established idempotent replay before previewing.
  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action = 'create' AND (
      coalesce(v_receipt.advance_days, 0) <> p_advance_days
      OR (p_appearance_column_id IS NOT NULL
        AND v_receipt.result->>'appearance_column_id' IS DISTINCT FROM p_appearance_column_id::text)
    ) THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otra anticipación o columna' USING ERRCODE = '23514';
    END IF;
    RETURN public.create_repetition_with_advance_base_internal_p(
      p_operation_id, p_slug, p_task_id, p_start_on, p_end_on,
      p_occurrence_limit, p_expected_due_on_version, p_confirm_start_change,
      p_previous_series_id, v_pattern, p_advance_days, p_appearance_column_id
    );
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id AND column_row.board_id = v_board_id
    AND column_row.generation_id = (
      SELECT board.active_generation_id FROM public.boards AS board WHERE board.id = v_board_id
    )
  FOR UPDATE OF task;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;

  SELECT column_row.id INTO v_appearance_column_id
  FROM public.columns AS column_row
  WHERE column_row.id = coalesce(p_appearance_column_id, v_task.column_id)
    AND column_row.board_id = v_board_id
    AND column_row.generation_id = (
      SELECT board.active_generation_id FROM public.boards AS board WHERE board.id = v_board_id
    );
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La columna elegida ya no pertenece al tablero' USING ERRCODE = '22023';
  END IF;

  v_preview := public.preview_repetition_with_advance_p(
    p_slug, p_task_id, p_start_on, p_end_on, p_occurrence_limit,
    v_pattern, p_advance_days
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available' THEN RETURN v_preview; END IF;
  IF v_preview->>'appearance_compatible' IS DISTINCT FROM 'true' THEN
    RETURN v_preview || pg_catalog.jsonb_build_object(
      'status', 'appearance_conflict',
      'appearance_conflict_message',
        'La primera aparición debe ser posterior al vencimiento de la tarea actual. Elige una fecha futura posterior o reduce la anticipación.'
    );
  END IF;

  v_result := public.create_repetition_with_advance_base_internal_p(
    p_operation_id, p_slug, p_task_id, p_start_on, p_end_on,
    p_occurrence_limit, p_expected_due_on_version, p_confirm_start_change,
    p_previous_series_id, v_pattern, p_advance_days, v_appearance_column_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN RETURN v_result; END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid
  FOR UPDATE;
  SELECT task.* INTO v_task FROM public.tasks AS task
  WHERE task.id = p_task_id FOR UPDATE;
  v_appearance_on := CASE WHEN v_series.next_due_on IS NULL THEN NULL
    ELSE v_series.next_due_on - p_advance_days END;
  IF v_appearance_on IS NOT NULL
    AND (v_task.due_on IS NULL OR v_appearance_on <= v_task.due_on) THEN
    RAISE EXCEPTION 'La primera aparición debe ser posterior a la fecha límite actual (%)', v_task.due_on
      USING ERRCODE = '22023';
  END IF;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_repetition_with_advance_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb, integer, uuid
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_repetition_with_advance_p(
  uuid, text, uuid, date, date, bigint, bigint, boolean, uuid, jsonb, integer, uuid
) TO authenticated;

ALTER FUNCTION public.preview_repetition_edit_p(
  text, uuid, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) RENAME TO preview_repetition_edit_base_internal_p;
REVOKE ALL ON FUNCTION public.preview_repetition_edit_base_internal_p(
  text, uuid, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) FROM PUBLIC, anon, authenticated, service_role;

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
  v_result jsonb;
  v_first_appearance_on date;
  v_current_due_on date;
  v_appearance_compatible boolean;
BEGIN
  v_result := public.preview_repetition_edit_base_internal_p(
    p_slug, p_task_id, p_start_on, p_final_mode, p_future_count,
    p_end_on, p_pattern, p_advance_days, p_appearance_column_id,
    p_template, p_confirm_date_choice
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR coalesce((v_result->>'requires_date_choice')::boolean, false) THEN
    RETURN v_result;
  END IF;
  v_first_appearance_on := NULLIF(v_result->'appearance_dates'->>0, '')::date;
  v_current_due_on := NULLIF(v_result->>'current_due_on', '')::date;
  v_appearance_compatible := v_first_appearance_on IS NULL
    OR (v_current_due_on IS NOT NULL AND v_first_appearance_on > v_current_due_on);
  RETURN v_result || pg_catalog.jsonb_build_object(
    'first_appearance_on', v_first_appearance_on,
    'appearance_compatible', v_appearance_compatible,
    'appearance_conflict_message', CASE WHEN v_appearance_compatible THEN NULL
      ELSE 'La primera aparición debe ser posterior al vencimiento de la tarea actual. Elige una fecha futura posterior o reduce la anticipación.'
      END
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_repetition_edit_p(
  text, uuid, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_repetition_edit_p(
  text, uuid, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) TO authenticated;

ALTER FUNCTION public.edit_repetition_p(
  uuid, text, uuid, bigint, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) RENAME TO edit_repetition_base_internal_p;
REVOKE ALL ON FUNCTION public.edit_repetition_base_internal_p(
  uuid, text, uuid, bigint, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) FROM PUBLIC, anon, authenticated, service_role;

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
  v_board public.boards%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_preview jsonb;
  v_current public.tasks%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RETURN public.edit_repetition_base_internal_p(
      p_operation_id, p_slug, p_task_id, p_expected_revision, p_start_on,
      p_final_mode, p_future_count, p_end_on, p_pattern, p_advance_days,
      p_appearance_column_id, p_template, p_confirm_date_choice
    );
  END IF;

  SELECT board.* INTO v_board FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  PERFORM 1 FROM public.boards AS board WHERE board.id = v_board.id FOR UPDATE;
  SELECT board.* INTO v_board FROM public.boards AS board
  WHERE board.id = v_board.id AND public.is_application_user()
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;

  -- Keep retries on the existing receipt path before rechecking current state.
  IF EXISTS (
    SELECT 1 FROM public.daily_repetition_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  ) THEN
    RETURN public.edit_repetition_base_internal_p(
      p_operation_id, p_slug, p_task_id, p_expected_revision, p_start_on,
      p_final_mode, p_future_count, p_end_on, p_pattern, p_advance_days,
      p_appearance_column_id, p_template, p_confirm_date_choice
    );
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

  SELECT task.* INTO v_current
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;

  v_preview := public.preview_repetition_edit_p(
    p_slug, p_task_id, p_start_on, p_final_mode, p_future_count, p_end_on,
    p_pattern, p_advance_days, p_appearance_column_id, p_template,
    p_confirm_date_choice
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available' THEN RETURN v_preview; END IF;
  IF coalesce((v_preview->>'requires_date_choice')::boolean, false) THEN
    RETURN v_preview || pg_catalog.jsonb_build_object('status', 'date_choice_required');
  END IF;
  IF v_preview->>'appearance_compatible' IS DISTINCT FROM 'true' THEN
    RETURN v_preview || pg_catalog.jsonb_build_object('status', 'appearance_conflict');
  END IF;

  RETURN public.edit_repetition_base_internal_p(
    p_operation_id, p_slug, p_task_id, p_expected_revision, p_start_on,
    p_final_mode, p_future_count, p_end_on, p_pattern, p_advance_days,
    p_appearance_column_id, p_template, p_confirm_date_choice
  );
END;
$$;
REVOKE ALL ON FUNCTION public.edit_repetition_p(
  uuid, text, uuid, bigint, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.edit_repetition_p(
  uuid, text, uuid, bigint, date, text, bigint, date, jsonb, integer, uuid, jsonb, boolean
) TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_daily_occurrence_due_on_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_occurrence public.daily_repetition_occurrences%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_next_appearance_on date;
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
  IF v_series.state IS DISTINCT FROM 'active' THEN
    RETURN NEW;
  END IF;
  v_next_appearance_on := v_series.next_due_on - v_series.advance_days;
  IF v_next_appearance_on IS NOT NULL
    AND NEW.due_on IS NOT NULL AND NEW.due_on >= v_next_appearance_on THEN
    RAISE EXCEPTION 'La fecha excepcional debe ser anterior a la próxima aparición (%).',
      v_next_appearance_on
      USING ERRCODE = 'P2301', DETAIL = v_next_appearance_on::text;
  END IF;
  UPDATE public.daily_repetition_occurrences AS occurrence
  SET due_on_override = NEW.due_on
  WHERE occurrence.id = v_occurrence.id;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_daily_occurrence_due_on_tg()
  FROM PUBLIC, anon, authenticated, service_role;

