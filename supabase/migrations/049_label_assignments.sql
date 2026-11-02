BEGIN;

ALTER TABLE public.board_labels
  ADD CONSTRAINT board_labels_identity_generation_key
    UNIQUE (id, board_id, generation_id);

CREATE TABLE public.board_label_task_assignments (
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  label_id uuid NOT NULL,
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (task_id, label_id),
  CONSTRAINT board_label_task_assignment_label_fk
    FOREIGN KEY (label_id, board_id, generation_id)
    REFERENCES public.board_labels(id, board_id, generation_id) ON DELETE CASCADE
);
CREATE INDEX board_label_task_assignments_board_generation_idx
  ON public.board_label_task_assignments(board_id, generation_id, task_id, label_id);
ALTER TABLE public.board_label_task_assignments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_label_task_assignments
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_label_birthday_assignments (
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  label_id uuid NOT NULL,
  birthday_id uuid NOT NULL REFERENCES public.board_birthdays(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (birthday_id, label_id),
  CONSTRAINT board_label_birthday_assignment_label_fk
    FOREIGN KEY (label_id, board_id, generation_id)
    REFERENCES public.board_labels(id, board_id, generation_id) ON DELETE CASCADE
);
CREATE INDEX board_label_birthday_assignments_board_generation_idx
  ON public.board_label_birthday_assignments(board_id, generation_id, birthday_id, label_id);
ALTER TABLE public.board_label_birthday_assignments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_label_birthday_assignments
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.get_task_labels_p(p_slug text, p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_task_id uuid;
  v_labels jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT task.id INTO v_task_id
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', label.id,
        'board_id', label.board_id,
        'name', label.name,
        'color', label.color,
        'version', label.version
      ) ORDER BY label.created_at, label.id
    ),
    '[]'::jsonb
  ) INTO v_labels
  FROM public.board_label_task_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.task_id = v_task_id
    AND label.deleted_at IS NULL;

  RETURN jsonb_build_object('status', 'available', 'labels', v_labels);
END;
$$;

CREATE FUNCTION public.get_birthday_labels_p(p_slug text, p_birthday_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_birthday_id uuid;
  v_labels jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT birthday.id INTO v_birthday_id
  FROM public.board_birthdays AS birthday
  WHERE birthday.id = p_birthday_id
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', label.id,
        'board_id', label.board_id,
        'name', label.name,
        'color', label.color,
        'version', label.version
      ) ORDER BY label.created_at, label.id
    ),
    '[]'::jsonb
  ) INTO v_labels
  FROM public.board_label_birthday_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.birthday_id = v_birthday_id
    AND label.deleted_at IS NULL;

  RETURN jsonb_build_object('status', 'available', 'labels', v_labels);
END;
$$;

CREATE FUNCTION public.set_task_labels_p(
  p_slug text,
  p_task_id uuid,
  p_label_ids uuid[]
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
  v_task public.tasks%ROWTYPE;
  v_valid_count integer;
  v_requested_count integer;
  v_labels jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_task_id IS NULL OR p_label_ids IS NULL THEN
    RAISE EXCEPTION 'A board, task, and complete label selection are required'
      USING ERRCODE = '22023';
  END IF;
  v_requested_count := cardinality(p_label_ids);
  IF v_requested_count > 10 THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'too_many_labels');
  END IF;
  IF coalesce(array_ndims(p_label_ids), 1) <> 1
    OR EXISTS (SELECT 1 FROM unnest(p_label_ids) AS requested(id) WHERE id IS NULL)
    OR (SELECT count(DISTINCT requested.id) FROM unnest(p_label_ids) AS requested(id))
      <> v_requested_count THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
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

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
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

  DELETE FROM public.board_label_task_assignments AS assignment
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.task_id = v_task.id
    AND EXISTS (
      SELECT 1 FROM public.board_labels AS current_label
      WHERE current_label.id = assignment.label_id
        AND current_label.deleted_at IS NULL
    );
  INSERT INTO public.board_label_task_assignments (
    board_id, generation_id, label_id, task_id
  )
  SELECT v_board.id, v_board.active_generation_id, requested.id, v_task.id
  FROM unnest(p_label_ids) AS requested(id);

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', label.id,
        'board_id', label.board_id,
        'name', label.name,
        'color', label.color,
        'version', label.version
      ) ORDER BY label.created_at, label.id
    ),
    '[]'::jsonb
  ) INTO v_labels
  FROM public.board_label_task_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.task_id = v_task.id
    AND label.deleted_at IS NULL;

  RETURN jsonb_build_object(
    'status', 'confirmed', 'task_id', v_task.id, 'labels', v_labels
  );
END;
$$;

CREATE FUNCTION public.set_birthday_labels_p(
  p_slug text,
  p_birthday_id uuid,
  p_label_ids uuid[]
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
  v_birthday public.board_birthdays%ROWTYPE;
  v_valid_count integer;
  v_requested_count integer;
  v_labels jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_birthday_id IS NULL OR p_label_ids IS NULL THEN
    RAISE EXCEPTION 'A board, birthday, and complete label selection are required'
      USING ERRCODE = '22023';
  END IF;
  v_requested_count := cardinality(p_label_ids);
  IF v_requested_count > 10 THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'too_many_labels');
  END IF;
  IF coalesce(array_ndims(p_label_ids), 1) <> 1
    OR EXISTS (SELECT 1 FROM unnest(p_label_ids) AS requested(id) WHERE id IS NULL)
    OR (SELECT count(DISTINCT requested.id) FROM unnest(p_label_ids) AS requested(id))
      <> v_requested_count THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'invalid_selection');
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
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

  SELECT birthday.* INTO v_birthday
  FROM public.board_birthdays AS birthday
  WHERE birthday.id = p_birthday_id
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
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

  DELETE FROM public.board_label_birthday_assignments AS assignment
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.birthday_id = v_birthday.id
    AND EXISTS (
      SELECT 1 FROM public.board_labels AS current_label
      WHERE current_label.id = assignment.label_id
        AND current_label.deleted_at IS NULL
    );
  INSERT INTO public.board_label_birthday_assignments (
    board_id, generation_id, label_id, birthday_id
  )
  SELECT v_board.id, v_board.active_generation_id, requested.id, v_birthday.id
  FROM unnest(p_label_ids) AS requested(id);

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', label.id,
        'board_id', label.board_id,
        'name', label.name,
        'color', label.color,
        'version', label.version
      ) ORDER BY label.created_at, label.id
    ),
    '[]'::jsonb
  ) INTO v_labels
  FROM public.board_label_birthday_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.birthday_id = v_birthday.id
    AND label.deleted_at IS NULL;

  RETURN jsonb_build_object(
    'status', 'confirmed', 'birthday_id', v_birthday.id, 'labels', v_labels
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_task_labels_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_birthday_labels_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_task_labels_p(text, uuid, uuid[])
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_birthday_labels_p(text, uuid, uuid[])
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_task_labels_p(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_birthday_labels_p(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_task_labels_p(text, uuid, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_birthday_labels_p(text, uuid, uuid[]) TO authenticated;

COMMIT;
