BEGIN;

CREATE FUNCTION public.preview_restore_board_label_p(
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
  v_board public.boards%ROWTYPE;
  v_label public.board_labels%ROWTYPE;
  v_reasons jsonb := '[]'::jsonb;
  v_active_count integer;
  v_duplicate_id uuid;
  v_tasks jsonb;
  v_birthdays jsonb;
  v_can_restore boolean := true;
  v_tombstone_reasons text[];
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object(
      'status', 'unavailable', 'associated_tasks', '[]'::jsonb,
      'associated_birthdays', '[]'::jsonb
    );
  END IF;
  IF p_slug IS NULL OR p_label_id IS NULL OR p_name IS NULL
    OR btrim(p_name) = '' OR char_length(p_name) > 40 THEN
    RAISE EXCEPTION 'A restored label requires a name of up to 40 characters'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND board.owner_id = auth.uid()
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status', 'unavailable', 'associated_tasks', '[]'::jsonb,
      'associated_birthdays', '[]'::jsonb
    );
  END IF;

  SELECT label.* INTO v_label
  FROM public.board_labels AS label
  WHERE label.id = p_label_id
    AND label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NOT NULL;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status', 'unavailable', 'associated_tasks', '[]'::jsonb,
      'associated_birthdays', '[]'::jsonb
    );
  END IF;
  IF v_label.deleted_at <= clock_timestamp() - interval '604800 seconds' THEN
    RETURN jsonb_build_object(
      'status', 'expired', 'associated_tasks', '[]'::jsonb,
      'associated_birthdays', '[]'::jsonb
    );
  END IF;

  SELECT count(*)::integer INTO v_active_count
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL;
  IF v_active_count >= 100 THEN
    v_reasons := v_reasons || jsonb_build_array('active_limit');
  END IF;

  SELECT label.id INTO v_duplicate_id
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL
    AND label.id <> v_label.id
    AND btrim(label.name) COLLATE public.board_label_name_ci_ai
      = btrim(p_name) COLLATE public.board_label_name_ci_ai
  LIMIT 1;
  IF FOUND THEN
    v_reasons := v_reasons || jsonb_build_array('duplicate_name');
  END IF;

  v_tombstone_reasons := public.board_label_tombstone_capacity_reasons_p(
    v_board.id, v_board.active_generation_id, v_label.id
  );
  v_reasons := v_reasons || to_jsonb(v_tombstone_reasons);

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', task.id,
        'title', task.title,
        'active_label_count', counts.active_label_count,
        'would_exceed_limit', counts.active_label_count >= 10
      ) ORDER BY task.title, task.id
    ),
    '[]'::jsonb
  ) INTO v_tasks
  FROM public.board_label_task_assignments AS assignment
  JOIN public.tasks AS task ON task.id = assignment.task_id
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  CROSS JOIN LATERAL (
    SELECT count(*)::integer AS active_label_count
    FROM public.board_label_task_assignments AS active_assignment
    JOIN public.board_labels AS active_label
      ON active_label.id = active_assignment.label_id
      AND active_label.board_id = active_assignment.board_id
      AND active_label.generation_id = active_assignment.generation_id
      AND active_label.deleted_at IS NULL
    WHERE active_assignment.task_id = task.id
      AND active_assignment.board_id = v_board.id
      AND active_assignment.generation_id = v_board.active_generation_id
  ) AS counts
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', birthday.id,
        'name', birthday.name,
        'active_label_count', counts.active_label_count,
        'would_exceed_limit', counts.active_label_count >= 10
      ) ORDER BY birthday.name, birthday.id
    ),
    '[]'::jsonb
  ) INTO v_birthdays
  FROM public.board_label_birthday_assignments AS assignment
  JOIN public.board_birthdays AS birthday ON birthday.id = assignment.birthday_id
  CROSS JOIN LATERAL (
    SELECT count(*)::integer AS active_label_count
    FROM public.board_label_birthday_assignments AS active_assignment
    JOIN public.board_labels AS active_label
      ON active_label.id = active_assignment.label_id
      AND active_label.board_id = active_assignment.board_id
      AND active_label.generation_id = active_assignment.generation_id
      AND active_label.deleted_at IS NULL
    WHERE active_assignment.birthday_id = birthday.id
      AND active_assignment.board_id = v_board.id
      AND active_assignment.generation_id = v_board.active_generation_id
  ) AS counts
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id;

  v_can_restore := jsonb_array_length(v_reasons) = 0;
  RETURN jsonb_build_object(
    'status', 'preview',
    'can_restore', v_can_restore,
    'reasons', v_reasons,
    'label', jsonb_build_object(
      'id', v_label.id,
      'board_id', v_label.board_id,
      'name', v_label.name,
      'proposed_name', p_name,
      'color', v_label.color,
      'deleted_at', v_label.deleted_at,
      'expires_at', v_label.deleted_at + interval '604800 seconds',
      'version', v_label.version
    ),
    'associated_tasks', v_tasks,
    'associated_birthdays', v_birthdays
  );
END;
$$;

CREATE FUNCTION public.restore_board_label_p(
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
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
  v_label public.board_labels%ROWTYPE;
  v_duplicate_id uuid;
  v_active_count integer;
  v_requested_tasks integer;
  v_requested_birthdays integer;
  v_valid_tasks integer;
  v_valid_birthdays integer;
  v_tombstone_reasons text[];
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_label_id IS NULL OR p_expected_version IS NULL
    OR p_expected_version < 1 OR p_name IS NULL OR btrim(p_name) = ''
    OR char_length(p_name) > 40 OR p_task_ids IS NULL OR p_birthday_ids IS NULL THEN
    RAISE EXCEPTION 'A board, label, name and complete association selection are required'
      USING ERRCODE = '22023';
  END IF;
  v_requested_tasks := cardinality(p_task_ids);
  v_requested_birthdays := cardinality(p_birthday_ids);
  IF coalesce(array_ndims(p_task_ids), 1) <> 1
    OR coalesce(array_ndims(p_birthday_ids), 1) <> 1
    OR EXISTS (SELECT 1 FROM unnest(p_task_ids) AS selected(id) WHERE id IS NULL)
    OR EXISTS (SELECT 1 FROM unnest(p_birthday_ids) AS selected(id) WHERE id IS NULL)
    OR (SELECT count(DISTINCT selected.id) FROM unnest(p_task_ids) AS selected(id))
      <> v_requested_tasks
    OR (SELECT count(DISTINCT selected.id) FROM unnest(p_birthday_ids) AS selected(id))
      <> v_requested_birthdays THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND board.owner_id = v_actor_id
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
    AND board.owner_id = v_actor_id
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
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_label.deleted_at <= clock_timestamp() - interval '604800 seconds' THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;
  IF v_label.version <> p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'reason', 'stale_version',
      'label', jsonb_build_object(
        'id', v_label.id, 'name', v_label.name,
        'color', v_label.color, 'version', v_label.version
      )
    );
  END IF;

  SELECT count(*)::integer INTO v_active_count
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL;
  IF v_active_count >= 100 THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'active_limit');
  END IF;

  SELECT label.id INTO v_duplicate_id
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL
    AND label.id <> v_label.id
    AND btrim(label.name) COLLATE public.board_label_name_ci_ai
      = btrim(p_name) COLLATE public.board_label_name_ci_ai
  LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'duplicate_name');
  END IF;

  v_tombstone_reasons := public.board_label_tombstone_capacity_reasons_p(
    v_board.id, v_board.active_generation_id, v_label.id
  );
  IF cardinality(v_tombstone_reasons) > 0 THEN
    RETURN jsonb_build_object(
      'status', 'conflict',
      'reason', 'tombstone_association_limit',
      'reasons', to_jsonb(v_tombstone_reasons)
    );
  END IF;

  PERFORM task.id
  FROM public.board_label_task_assignments AS assignment
  JOIN public.tasks AS task ON task.id = assignment.task_id
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND task.id = ANY(p_task_ids)
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  ORDER BY task.id
  FOR UPDATE OF task;

  PERFORM birthday.id
  FROM public.board_label_birthday_assignments AS assignment
  JOIN public.board_birthdays AS birthday ON birthday.id = assignment.birthday_id
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND birthday.id = ANY(p_birthday_ids)
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id
  ORDER BY birthday.id
  FOR UPDATE OF birthday;

  SELECT count(*)::integer INTO v_valid_tasks
  FROM public.board_label_task_assignments AS assignment
  JOIN public.tasks AS task ON task.id = assignment.task_id
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND task.id = ANY(p_task_ids)
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id;
  SELECT count(*)::integer INTO v_valid_birthdays
  FROM public.board_label_birthday_assignments AS assignment
  JOIN public.board_birthdays AS birthday ON birthday.id = assignment.birthday_id
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND birthday.id = ANY(p_birthday_ids)
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id;
  IF v_valid_tasks <> v_requested_tasks OR v_valid_birthdays <> v_requested_birthdays THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM unnest(p_task_ids) AS selected(id)
    WHERE (
      SELECT count(*)
      FROM public.board_label_task_assignments AS assignment
      JOIN public.board_labels AS active_label
        ON active_label.id = assignment.label_id
        AND active_label.deleted_at IS NULL
      WHERE assignment.board_id = v_board.id
        AND assignment.generation_id = v_board.active_generation_id
        AND assignment.task_id = selected.id
    ) >= 10
  ) OR EXISTS (
    SELECT 1
    FROM unnest(p_birthday_ids) AS selected(id)
    WHERE (
      SELECT count(*)
      FROM public.board_label_birthday_assignments AS assignment
      JOIN public.board_labels AS active_label
        ON active_label.id = assignment.label_id
        AND active_label.deleted_at IS NULL
      WHERE assignment.board_id = v_board.id
        AND assignment.generation_id = v_board.active_generation_id
        AND assignment.birthday_id = selected.id
    ) >= 10
  ) THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'too_many_labels');
  END IF;

  UPDATE public.board_labels AS label
  SET name = p_name,
      deleted_at = NULL,
      deleted_by = NULL,
      updated_at = clock_timestamp(),
      version = label.version + 1
  WHERE label.id = v_label.id
  RETURNING * INTO v_label;

  DELETE FROM public.board_label_task_assignments AS assignment
  USING public.tasks AS task, public.columns AS column_row
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.task_id = task.id
    AND task.column_id = column_row.id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
    AND NOT (task.id = ANY(p_task_ids));

  DELETE FROM public.board_label_birthday_assignments AS assignment
  USING public.board_birthdays AS birthday
  WHERE assignment.label_id = v_label.id
    AND assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.birthday_id = birthday.id
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id
    AND NOT (birthday.id = ANY(p_birthday_ids));

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'label', jsonb_build_object(
      'id', v_label.id,
      'board_id', v_label.board_id,
      'name', v_label.name,
      'color', v_label.color,
      'updated_at', v_label.updated_at,
      'version', v_label.version
    ),
    'restored_task_ids', to_jsonb(p_task_ids),
    'restored_birthday_ids', to_jsonb(p_birthday_ids)
  );
END;
$$;

CREATE FUNCTION public.purge_expired_board_labels_p(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_purged integer;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'Purge limit must be between 1 and 1000'
      USING ERRCODE = '22023';
  END IF;

  WITH expired AS (
    SELECT label.id
    FROM public.board_labels AS label
    WHERE label.deleted_at <= clock_timestamp() - interval '604800 seconds'
    ORDER BY label.deleted_at, label.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.board_labels AS label
  USING expired
  WHERE label.id = expired.id;
  GET DIAGNOSTICS v_purged = ROW_COUNT;
  RETURN v_purged;
END;
$$;

REVOKE ALL ON FUNCTION public.preview_restore_board_label_p(text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_board_label_p(text, uuid, bigint, text, uuid[], uuid[])
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_board_labels_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_restore_board_label_p(text, uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_board_label_p(text, uuid, bigint, text, uuid[], uuid[])
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.purge_expired_board_labels_p(integer)
  TO service_role;

COMMIT;
