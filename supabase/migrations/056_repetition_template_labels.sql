BEGIN;

ALTER FUNCTION public.restore_board_label_p(text, uuid, bigint, text, uuid[], uuid[])
  RENAME TO restore_board_label_base_internal_p;
REVOKE ALL ON FUNCTION public.restore_board_label_base_internal_p(
  text, uuid, bigint, text, uuid[], uuid[]
) FROM PUBLIC, anon, authenticated, service_role;

ALTER TABLE public.daily_repetition_series
  ADD CONSTRAINT daily_repetition_series_identity_generation_key
    UNIQUE (id, board_id, generation_id);

CREATE TABLE public.board_label_repetition_assignments (
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  label_id uuid NOT NULL,
  series_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (series_id, label_id),
  CONSTRAINT board_label_repetition_assignment_series_fk
    FOREIGN KEY (series_id, board_id, generation_id)
    REFERENCES public.daily_repetition_series(id, board_id, generation_id)
    ON DELETE CASCADE,
  CONSTRAINT board_label_repetition_assignment_label_fk
    FOREIGN KEY (label_id, board_id, generation_id)
    REFERENCES public.board_labels(id, board_id, generation_id)
    ON DELETE CASCADE
);
CREATE INDEX board_label_repetition_assignments_board_generation_idx
  ON public.board_label_repetition_assignments(
    board_id, generation_id, series_id, label_id
  );
ALTER TABLE public.board_label_repetition_assignments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_label_repetition_assignments
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.seed_repetition_template_labels_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  INSERT INTO public.board_label_repetition_assignments(
    board_id, generation_id, label_id, series_id
  )
  SELECT NEW.board_id, NEW.generation_id, assignment.label_id, NEW.id
  FROM public.board_label_task_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.board_id = NEW.board_id
    AND assignment.generation_id = NEW.generation_id
    AND assignment.task_id = NEW.origin_task_id
  ORDER BY assignment.label_id
  ON CONFLICT (series_id, label_id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.seed_repetition_template_labels_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER daily_repetition_series_seed_template_labels
AFTER INSERT ON public.daily_repetition_series
FOR EACH ROW EXECUTE FUNCTION public.seed_repetition_template_labels_p();

-- The board lock acquired by the worker serializes this copy with label
-- deletion and template edits. Only currently active, board-local choices are
-- copied, and the task assignments share the occurrence insert transaction.
CREATE FUNCTION public.copy_repetition_template_labels_to_occurrence_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_series public.daily_repetition_series%ROWTYPE;
  v_template_count integer;
BEGIN
  IF NEW.state IS DISTINCT FROM 'current' THEN RETURN NEW; END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = NEW.series_id;
  IF NOT FOUND OR v_series.current_occurrence_id IS NULL THEN
    -- First slot creation and series recovery reconnect an existing task; only
    -- later worker-created slots inherit template labels.
    RETURN NEW;
  END IF;

  SELECT count(*)::integer INTO v_template_count
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.series_id = v_series.id
    AND assignment.board_id = v_series.board_id
    AND assignment.generation_id = v_series.generation_id;
  IF v_template_count > 10 THEN
    RAISE EXCEPTION 'La plantilla supera el límite de diez etiquetas activas'
      USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.board_label_task_assignments(
    board_id, generation_id, label_id, task_id
  )
  SELECT assignment.board_id, assignment.generation_id,
    assignment.label_id, NEW.task_id
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.series_id = v_series.id
    AND assignment.board_id = v_series.board_id
    AND assignment.generation_id = v_series.generation_id
  ORDER BY assignment.label_id
  ON CONFLICT (task_id, label_id) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.copy_repetition_template_labels_to_occurrence_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER daily_repetition_occurrence_inherit_template_labels
AFTER INSERT ON public.daily_repetition_occurrences
FOR EACH ROW EXECUTE FUNCTION public.copy_repetition_template_labels_to_occurrence_p();

-- Existing series start with the active labels on their current occurrence.
INSERT INTO public.board_label_repetition_assignments(
  board_id, generation_id, label_id, series_id
)
SELECT series.board_id, series.generation_id, assignment.label_id, series.id
FROM public.daily_repetition_series AS series
JOIN public.daily_repetition_occurrences AS occurrence
  ON occurrence.id = series.current_occurrence_id
  AND occurrence.series_id = series.id
JOIN public.board_label_task_assignments AS assignment
  ON assignment.task_id = occurrence.task_id
  AND assignment.board_id = series.board_id
  AND assignment.generation_id = series.generation_id
JOIN public.board_labels AS label
  ON label.id = assignment.label_id
  AND label.board_id = assignment.board_id
  AND label.generation_id = assignment.generation_id
  AND label.deleted_at IS NULL
ON CONFLICT (series_id, label_id) DO NOTHING;

CREATE FUNCTION public.set_repetition_template_labels_p(
  p_slug text,
  p_task_id uuid,
  p_expected_label_ids uuid[],
  p_label_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
  v_series public.daily_repetition_series%ROWTYPE;
  v_expected_ids uuid[];
  v_current_ids uuid[];
  v_requested_count integer;
  v_valid_count integer;
  v_labels jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_task_id IS NULL
    OR p_expected_label_ids IS NULL OR p_label_ids IS NULL THEN
    RAISE EXCEPTION 'A board, current occurrence and complete template selection are required'
      USING ERRCODE = '22023';
  END IF;
  v_requested_count := cardinality(p_label_ids);
  IF v_requested_count > 10 THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'too_many_labels');
  END IF;
  IF coalesce(array_ndims(p_expected_label_ids), 1) <> 1
    OR coalesce(array_ndims(p_label_ids), 1) <> 1
    OR EXISTS (
      SELECT 1 FROM unnest(p_expected_label_ids) AS expected(id) WHERE expected.id IS NULL
    )
    OR EXISTS (
      SELECT 1 FROM unnest(p_label_ids) AS requested(id) WHERE requested.id IS NULL
    )
    OR (SELECT count(DISTINCT expected.id)
        FROM unnest(p_expected_label_ids) AS expected(id))
      <> cardinality(p_expected_label_ids)
    OR (SELECT count(DISTINCT requested.id)
        FROM unnest(p_label_ids) AS requested(id))
      <> v_requested_count THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'unavailable'); END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board.id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series
    ON series.id = occurrence.series_id
    AND series.current_occurrence_id = occurrence.id
  WHERE occurrence.task_id = p_task_id
    AND occurrence.state = 'current'
    AND series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id
    AND series.state = 'active'
  FOR UPDATE OF series;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'unavailable'); END IF;

  SELECT coalesce(array_agg(expected.id ORDER BY expected.id), ARRAY[]::uuid[])
  INTO v_expected_ids
  FROM unnest(p_expected_label_ids) AS expected(id);
  SELECT coalesce(array_agg(assignment.label_id ORDER BY assignment.label_id), ARRAY[]::uuid[])
  INTO v_current_ids
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.series_id = v_series.id;
  IF v_current_ids IS DISTINCT FROM v_expected_ids THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'reason', 'stale_selection',
      'template_label_ids', to_jsonb(v_current_ids)
    );
  END IF;

  SELECT count(*)::integer INTO v_valid_count
  FROM public.board_labels AS label
  JOIN unnest(p_label_ids) AS requested(id) ON requested.id = label.id
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL;
  IF v_valid_count <> v_requested_count THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  DELETE FROM public.board_label_repetition_assignments AS assignment
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.series_id = v_series.id
    AND EXISTS (
      SELECT 1 FROM public.board_labels AS current_label
      WHERE current_label.id = assignment.label_id
        AND current_label.deleted_at IS NULL
    );
  INSERT INTO public.board_label_repetition_assignments(
    board_id, generation_id, label_id, series_id
  )
  SELECT v_board.id, v_board.active_generation_id, requested.id, v_series.id
  FROM unnest(p_label_ids) AS requested(id)
  ORDER BY requested.id;

  SELECT coalesce(jsonb_agg(assignment.label_id ORDER BY assignment.label_id), '[]'::jsonb)
  INTO v_labels
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.series_id = v_series.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed', 'series_id', v_series.id,
    'template_label_ids', v_labels
  );
END;
$$;
REVOKE ALL ON FUNCTION public.set_repetition_template_labels_p(text, uuid, uuid[], uuid[])
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_repetition_template_labels_p(text, uuid, uuid[], uuid[])
  TO authenticated;

CREATE OR REPLACE FUNCTION public.get_repetition_p(p_slug text, p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
  v_template_label_ids jsonb;
BEGIN
  v_result := public.get_daily_repetition_p(p_slug, p_task_id);
  IF v_result->>'status' IS DISTINCT FROM 'available' THEN RETURN v_result; END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  -- Match the existing history redaction contract: terminal or deleted slots
  -- must not turn the active-generation template into recoverable history.
  IF v_series.state IN ('stopped', 'finished') OR EXISTS (
    SELECT 1 FROM public.task_deletions AS deletion
    WHERE deletion.task_id = p_task_id
      AND deletion.state IN ('deleted', 'purged')
  ) THEN
    RETURN v_result || pg_catalog.jsonb_build_object(
      'rule', v_series.rule, 'pattern', v_series.calendar_pattern,
      'advance_days', v_series.advance_days,
      'appearance_column_id', v_series.appearance_column_id
    );
  END IF;
  SELECT coalesce(jsonb_agg(assignment.label_id ORDER BY assignment.label_id), '[]'::jsonb)
  INTO v_template_label_ids
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.series_id = v_series.id
    AND assignment.board_id = v_series.board_id
    AND assignment.generation_id = v_series.generation_id;
  RETURN v_result || pg_catalog.jsonb_build_object(
    'rule', v_series.rule, 'pattern', v_series.calendar_pattern,
    'advance_days', v_series.advance_days,
    'appearance_column_id', v_series.appearance_column_id,
    'template_snapshot', v_series.template_snapshot,
    'template_label_ids', v_template_label_ids
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_repetition_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_repetition_p(text, uuid) TO authenticated;

CREATE FUNCTION public.preview_restore_board_label_with_series_p(
  p_slug text,
  p_label_id uuid,
  p_name text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_preview jsonb;
  v_board public.boards%ROWTYPE;
  v_series jsonb;
BEGIN
  v_preview := public.preview_restore_board_label_p(p_slug, p_label_id, p_name);
  IF v_preview->>'status' IS DISTINCT FROM 'preview' THEN
    RETURN v_preview || pg_catalog.jsonb_build_object('associated_series', '[]'::jsonb);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND board.owner_id = auth.uid()
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'associated_tasks', '[]'::jsonb,
      'associated_birthdays', '[]'::jsonb, 'associated_series', '[]'::jsonb
    );
  END IF;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'id', series.id,
      'title', series.template_snapshot->>'title',
      'state', series.state,
      'active_label_count', counts.active_label_count,
      'would_exceed_limit',
        (series.state = 'active' AND counts.active_label_count >= 10)
    ) ORDER BY series.template_snapshot->>'title', series.id
  ), '[]'::jsonb) INTO v_series
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.daily_repetition_series AS series
    ON series.id = assignment.series_id
    AND series.board_id = assignment.board_id
    AND series.generation_id = assignment.generation_id
  CROSS JOIN LATERAL (
    SELECT count(*)::integer AS active_label_count
    FROM public.board_label_repetition_assignments AS active_assignment
    JOIN public.board_labels AS active_label
      ON active_label.id = active_assignment.label_id
      AND active_label.board_id = active_assignment.board_id
      AND active_label.generation_id = active_assignment.generation_id
      AND active_label.deleted_at IS NULL
    WHERE active_assignment.series_id = series.id
      AND active_assignment.board_id = v_board.id
      AND active_assignment.generation_id = v_board.active_generation_id
  ) AS counts
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.label_id = p_label_id;

  RETURN v_preview || pg_catalog.jsonb_build_object('associated_series', v_series);
END;
$$;

CREATE FUNCTION public.restore_board_label_with_series_p(
  p_slug text,
  p_label_id uuid,
  p_expected_version bigint,
  p_name text,
  p_task_ids uuid[],
  p_birthday_ids uuid[],
  p_series_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
  v_label public.board_labels%ROWTYPE;
  v_preview jsonb;
  v_result jsonb;
  v_available_series_ids uuid[];
  v_requested_series_ids uuid[];
  v_series_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_label_id IS NULL OR p_expected_version IS NULL
    OR p_expected_version < 1 OR p_name IS NULL
    OR p_task_ids IS NULL OR p_birthday_ids IS NULL OR p_series_ids IS NULL THEN
    RAISE EXCEPTION 'A board, label, name and complete association selection are required'
      USING ERRCODE = '22023';
  END IF;
  IF coalesce(array_ndims(p_series_ids), 1) <> 1
    OR EXISTS (SELECT 1 FROM unnest(p_series_ids) AS selected(id) WHERE selected.id IS NULL)
    OR (SELECT count(DISTINCT selected.id)
        FROM unnest(p_series_ids) AS selected(id)) <> cardinality(p_series_ids) THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND board.owner_id = v_actor_id
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'unavailable'); END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board.id AND board.owner_id = v_actor_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT label.* INTO v_label
  FROM public.board_labels AS label
  WHERE label.id = p_label_id
    AND label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('status', 'unavailable'); END IF;
  IF v_label.version IS DISTINCT FROM p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'reason', 'stale_version',
      'label', jsonb_build_object(
        'id', v_label.id, 'name', v_label.name,
        'color', v_label.color, 'version', v_label.version
      )
    );
  END IF;
  IF v_label.deleted_at <= clock_timestamp() - interval '604800 seconds' THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;

  v_preview := public.preview_restore_board_label_p(p_slug, p_label_id, p_name);
  IF v_preview->>'status' IS DISTINCT FROM 'preview' THEN
    RETURN v_preview;
  END IF;
  IF v_preview->>'can_restore' IS DISTINCT FROM 'true' THEN
    RETURN jsonb_build_object(
      'status', 'conflict',
      'reason', CASE
        WHEN v_preview->'reasons' ? 'active_limit' THEN 'active_limit'
        WHEN v_preview->'reasons' ? 'duplicate_name' THEN 'duplicate_name'
        WHEN v_preview->'reasons' ? 'task_recovery_limit'
          OR v_preview->'reasons' ? 'birthday_recovery_limit'
          THEN 'tombstone_association_limit'
        ELSE coalesce(v_preview->'reasons'->>0, 'restore_blocked')
      END,
      'reasons', v_preview->'reasons'
    );
  END IF;

  SELECT coalesce(array_agg(assignment.series_id ORDER BY assignment.series_id), ARRAY[]::uuid[])
  INTO v_available_series_ids
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.daily_repetition_series AS series
    ON series.id = assignment.series_id
    AND series.board_id = assignment.board_id
    AND series.generation_id = assignment.generation_id
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.label_id = v_label.id;
  SELECT coalesce(array_agg(selected.id ORDER BY selected.id), ARRAY[]::uuid[])
  INTO v_requested_series_ids
  FROM unnest(p_series_ids) AS selected(id);
  IF EXISTS (
    SELECT 1 FROM unnest(v_requested_series_ids) AS selected(id)
    WHERE NOT (selected.id = ANY(v_available_series_ids))
  ) THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  FOR v_series_id IN
    SELECT series.id
    FROM public.daily_repetition_series AS series
    WHERE series.id = ANY(v_available_series_ids)
    ORDER BY series.id
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM unnest(v_requested_series_ids) AS selected(id)
    JOIN public.daily_repetition_series AS series ON series.id = selected.id
    WHERE series.state = 'active'
      AND (
        SELECT count(*)
        FROM public.board_label_repetition_assignments AS assignment
        JOIN public.board_labels AS active_label
          ON active_label.id = assignment.label_id
          AND active_label.board_id = assignment.board_id
          AND active_label.generation_id = assignment.generation_id
          AND active_label.deleted_at IS NULL
        WHERE assignment.series_id = series.id
          AND assignment.board_id = v_board.id
          AND assignment.generation_id = v_board.active_generation_id
      ) >= 10
  ) THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'reason', 'too_many_labels',
      'series_ids', to_jsonb(v_requested_series_ids)
    );
  END IF;

  v_result := public.restore_board_label_base_internal_p(
    p_slug, p_label_id, p_expected_version, p_name, p_task_ids, p_birthday_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RETURN v_result;
  END IF;
  DELETE FROM public.board_label_repetition_assignments AS assignment
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.label_id = v_label.id
    AND NOT (assignment.series_id = ANY(v_requested_series_ids));
  RETURN v_result || pg_catalog.jsonb_build_object(
    'restored_series_ids', to_jsonb(v_requested_series_ids),
    'omitted_series_ids', to_jsonb(ARRAY(
      SELECT series_id FROM unnest(v_available_series_ids) AS candidate(series_id)
      WHERE NOT (series_id = ANY(v_requested_series_ids)) ORDER BY series_id
    ))
  );
END;
$$;

-- Keep the existing RPC fail-safe: old clients retain all template links only
-- when that selection still respects the ten-label cap.
CREATE OR REPLACE FUNCTION public.restore_board_label_p(
  p_slug text,
  p_label_id uuid,
  p_expected_version bigint,
  p_name text,
  p_task_ids uuid[],
  p_birthday_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series_ids uuid[];
BEGIN
  SELECT coalesce(array_agg(assignment.series_id ORDER BY assignment.series_id), ARRAY[]::uuid[])
  INTO v_series_ids
  FROM public.board_label_repetition_assignments AS assignment
  JOIN public.daily_repetition_series AS series
    ON series.id = assignment.series_id
    AND series.board_id = assignment.board_id
    AND series.generation_id = assignment.generation_id
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
  WHERE label.id = p_label_id
    AND label.deleted_at IS NOT NULL;
  RETURN public.restore_board_label_with_series_p(
    p_slug, p_label_id, p_expected_version, p_name,
    p_task_ids, p_birthday_ids, v_series_ids
  );
END;
$$;

REVOKE ALL ON FUNCTION public.preview_restore_board_label_with_series_p(text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_board_label_p(
  text, uuid, bigint, text, uuid[], uuid[]
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_board_label_with_series_p(
  text, uuid, bigint, text, uuid[], uuid[], uuid[]
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_restore_board_label_with_series_p(text, uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_board_label_p(
  text, uuid, bigint, text, uuid[], uuid[]
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_board_label_with_series_p(
  text, uuid, bigint, text, uuid[], uuid[], uuid[]
) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
