-- Keep task responsibility separate from edit permissions and task field edits.
BEGIN;

ALTER TABLE public.tasks
  ADD COLUMN assignee_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN assignee_version bigint NOT NULL DEFAULT 1,
  ADD CONSTRAINT tasks_assignee_version_positive CHECK (assignee_version > 0);

CREATE INDEX tasks_assignee_current_idx
  ON public.tasks (assignee_id, column_id, is_completed, due_on, created_at, id)
  WHERE assignee_id IS NOT NULL;

CREATE TABLE public.task_assignee_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_status text NOT NULL CHECK (result_status IN ('pending', 'confirmed', 'conflict')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);
ALTER TABLE public.task_assignee_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_assignee_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.is_enabled_application_identity_p(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT p_user_id IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.application_access AS access
    JOIN auth.users AS auth_user ON auth_user.id = access.auth_user_id
    JOIN auth.identities AS identity ON identity.user_id = auth_user.id
    WHERE access.auth_user_id = p_user_id
      AND access.state = 'active'
      AND access.email = lower(auth_user.email)
      AND identity.provider = 'google'
      AND identity.provider_id = access.google_subject
      AND lower(identity.identity_data->>'email') = lower(auth_user.email)
      AND coalesce((identity.identity_data->>'email_verified')::boolean, false)
  );
$$;

CREATE FUNCTION public.get_my_tasks_p(p_order text DEFAULT 'due')
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_order IS NULL OR p_order NOT IN ('due', 'created') THEN
    RAISE EXCEPTION 'Choose a supported task order' USING ERRCODE = '22023';
  END IF;
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT jsonb_build_object(
    'task', to_jsonb(task),
    'board', jsonb_build_object(
      'id', board.id,
      'slug', board.slug,
      'name', board.name,
      'time_zone', board.time_zone,
      'today', public.board_calendar_day(board.time_zone, statement_timestamp())
    ),
    'column', jsonb_build_object(
      'id', column_row.id,
      'title', column_row.title,
      'position', column_row.position
    )
  )
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  JOIN public.boards AS board ON board.id = column_row.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL
  WHERE task.assignee_id = auth.uid()
    AND column_row.generation_id = board.active_generation_id
    AND public.is_board_member(board.id)
  ORDER BY
    task.is_completed,
    CASE WHEN task.is_completed THEN task.completed_at END DESC NULLS LAST,
    CASE WHEN NOT task.is_completed AND p_order = 'due' THEN task.due_on END ASC NULLS LAST,
    task.created_at ASC,
    task.id ASC;
END;
$$;

CREATE FUNCTION public.list_assignable_board_members_p(p_slug text)
RETURNS TABLE(user_id uuid, email text, role text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT membership.user_id, auth_user.email, membership.role
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.revoked_at IS NULL
  JOIN auth.users AS auth_user ON auth_user.id = membership.user_id
  WHERE board.slug = p_slug
    AND public.is_application_user()
    AND public.is_board_member(board.id)
    AND public.is_enabled_application_identity_p(membership.user_id)
  ORDER BY lower(auth_user.email), membership.user_id;
$$;

CREATE FUNCTION public.set_task_assignee_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_assignee_id uuid,
  p_expected_version bigint
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
  v_task public.tasks%ROWTYPE;
  v_receipt public.task_assignee_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_target_membership_id uuid;
  v_target_access_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_id IS NULL
    OR p_expected_version IS NULL OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'Task responsibility requires a task and current version'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  PERFORM public.assert_task_capture_access_p(v_board_id);
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_id
    AND column_row.board_id = v_board_id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := public.task_capture_payload_hash(jsonb_build_object(
    'action', 'set_task_assignee',
    'board_id', v_board_id,
    'task_id', p_id,
    'assignee_id', p_assignee_id,
    'expected_version', p_expected_version
  ));

  INSERT INTO public.task_assignee_receipts(
    actor_id, operation_id, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, v_board_id, p_id, v_payload_hash, 'pending'
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_assignee_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This responsibility operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status IN ('confirmed', 'conflict') THEN
      RETURN jsonb_build_object(
        'status', v_receipt.result_status,
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;
    RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
  END IF;

  IF p_assignee_id IS NOT NULL THEN
    SELECT membership.id INTO v_target_membership_id
    FROM public.board_memberships AS membership
    WHERE membership.board_id = v_board_id
      AND membership.user_id = p_assignee_id
      AND membership.revoked_at IS NULL
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Choose a current member of this board' USING ERRCODE = '22023';
    END IF;

    SELECT access.auth_user_id INTO v_target_access_id
    FROM public.application_access AS access
    JOIN auth.users AS auth_user ON auth_user.id = access.auth_user_id
    JOIN auth.identities AS identity ON identity.user_id = auth_user.id
    WHERE access.auth_user_id = p_assignee_id
      AND access.state = 'active'
      AND access.email = lower(auth_user.email)
      AND identity.provider = 'google'
      AND identity.provider_id = access.google_subject
      AND lower(identity.identity_data->>'email') = lower(auth_user.email)
      AND coalesce((identity.identity_data->>'email_verified')::boolean, false)
    FOR SHARE OF access;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Choose a current member of this board' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_task.assignee_id IS DISTINCT FROM p_assignee_id
    AND v_task.assignee_version <> p_expected_version THEN
    UPDATE public.task_assignee_receipts AS receipt
    SET result_status = 'conflict'
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object(
      'status', 'conflict',
      'operation_id', p_operation_id,
      'task', to_jsonb(v_task)
    );
  END IF;

  IF v_task.assignee_id IS DISTINCT FROM p_assignee_id THEN
    UPDATE public.tasks AS task SET
      assignee_id = p_assignee_id,
      assignee_version = task.assignee_version + 1
    WHERE task.id = p_id
    RETURNING task.* INTO v_task;
  END IF;

  UPDATE public.task_assignee_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'task', to_jsonb(v_task)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.is_enabled_application_identity_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_tasks_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_assignable_board_members_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_task_assignee_p(uuid, text, uuid, uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_tasks_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_assignable_board_members_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_task_assignee_p(uuid, text, uuid, uuid, bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
