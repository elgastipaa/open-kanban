BEGIN;

ALTER FUNCTION public.set_task_labels_p(text, uuid, uuid[])
  RENAME TO set_task_labels_internal_p;
REVOKE ALL ON FUNCTION public.set_task_labels_internal_p(text, uuid, uuid[])
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.set_task_labels_p(
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
  v_expected_ids uuid[];
  v_current_ids uuid[];
  v_current jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_task_id IS NULL
    OR p_expected_label_ids IS NULL OR p_label_ids IS NULL THEN
    RAISE EXCEPTION 'A board, task, current selection and next selection are required'
      USING ERRCODE = '22023';
  END IF;
  IF coalesce(array_ndims(p_expected_label_ids), 1) <> 1
    OR EXISTS (
      SELECT 1 FROM unnest(p_expected_label_ids) AS expected(id) WHERE id IS NULL
    )
    OR (SELECT count(DISTINCT expected.id)
        FROM unnest(p_expected_label_ids) AS expected(id))
      <> cardinality(p_expected_label_ids) THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_expected_set');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
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

  SELECT coalesce(array_agg(expected.id ORDER BY expected.id), ARRAY[]::uuid[])
  INTO v_expected_ids
  FROM unnest(p_expected_label_ids) AS expected(id);
  SELECT coalesce(array_agg(label.id ORDER BY label.id), ARRAY[]::uuid[])
  INTO v_current_ids
  FROM public.board_label_task_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.task_id = p_task_id;
  IF v_current_ids IS DISTINCT FROM v_expected_ids THEN
    v_current := public.get_task_labels_p(p_slug, p_task_id);
    IF v_current->>'status' IS DISTINCT FROM 'available' THEN
      RETURN jsonb_build_object('status', 'unavailable');
    END IF;
    RETURN jsonb_build_object(
      'status', 'conflict', 'reason', 'stale_selection',
      'labels', v_current->'labels'
    );
  END IF;

  RETURN public.set_task_labels_internal_p(p_slug, p_task_id, p_label_ids);
END;
$$;

ALTER FUNCTION public.set_birthday_labels_p(text, uuid, uuid[])
  RENAME TO set_birthday_labels_internal_p;
REVOKE ALL ON FUNCTION public.set_birthday_labels_internal_p(text, uuid, uuid[])
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.set_birthday_labels_p(
  p_slug text,
  p_birthday_id uuid,
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
  v_expected_ids uuid[];
  v_current_ids uuid[];
  v_current jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_birthday_id IS NULL
    OR p_expected_label_ids IS NULL OR p_label_ids IS NULL THEN
    RAISE EXCEPTION 'A board, birthday, current selection and next selection are required'
      USING ERRCODE = '22023';
  END IF;
  IF coalesce(array_ndims(p_expected_label_ids), 1) <> 1
    OR EXISTS (
      SELECT 1 FROM unnest(p_expected_label_ids) AS expected(id) WHERE id IS NULL
    )
    OR (SELECT count(DISTINCT expected.id)
        FROM unnest(p_expected_label_ids) AS expected(id))
      <> cardinality(p_expected_label_ids) THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_expected_set');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
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

  SELECT coalesce(array_agg(expected.id ORDER BY expected.id), ARRAY[]::uuid[])
  INTO v_expected_ids
  FROM unnest(p_expected_label_ids) AS expected(id);
  SELECT coalesce(array_agg(label.id ORDER BY label.id), ARRAY[]::uuid[])
  INTO v_current_ids
  FROM public.board_label_birthday_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.birthday_id = p_birthday_id;
  IF v_current_ids IS DISTINCT FROM v_expected_ids THEN
    v_current := public.get_birthday_labels_p(p_slug, p_birthday_id);
    IF v_current->>'status' IS DISTINCT FROM 'available' THEN
      RETURN jsonb_build_object('status', 'unavailable');
    END IF;
    RETURN jsonb_build_object(
      'status', 'conflict', 'reason', 'stale_selection',
      'labels', v_current->'labels'
    );
  END IF;

  RETURN public.set_birthday_labels_internal_p(
    p_slug, p_birthday_id, p_label_ids
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_task_labels_p(text, uuid, uuid[], uuid[])
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_birthday_labels_p(text, uuid, uuid[], uuid[])
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_task_labels_p(text, uuid, uuid[], uuid[])
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_birthday_labels_p(text, uuid, uuid[], uuid[])
  TO authenticated;

COMMIT;
