BEGIN;

ALTER TABLE public.tasks
  ADD COLUMN is_completed boolean NOT NULL DEFAULT false,
  ADD COLUMN completed_at timestamptz,
  ADD COLUMN completion_version bigint NOT NULL DEFAULT 1,
  ADD CONSTRAINT tasks_completion_version_positive CHECK (completion_version > 0),
  ADD CONSTRAINT tasks_completion_timestamp_matches_state CHECK (
    (is_completed AND completed_at IS NOT NULL)
    OR (NOT is_completed AND completed_at IS NULL)
  );

CREATE INDEX tasks_completed_recent_idx
  ON public.tasks (column_id, completed_at DESC, id)
  WHERE is_completed;

CREATE TABLE public.task_completion_receipts (
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

ALTER TABLE public.task_completion_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_completion_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.set_task_completion_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_is_completed boolean,
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
  v_receipt public.task_completion_receipts%ROWTYPE;
  v_payload_hash bytea;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_id IS NULL
    OR p_is_completed IS NULL OR p_expected_version IS NULL
    OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'Task completion requires a desired state and current version'
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
    'action', 'set_task_completion',
    'board_id', v_board_id,
    'task_id', p_id,
    'is_completed', p_is_completed,
    'expected_version', p_expected_version
  ));

  INSERT INTO public.task_completion_receipts(
    actor_id, operation_id, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, v_board_id, p_id, v_payload_hash, 'pending'
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_completion_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This task completion operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status = 'confirmed' OR v_receipt.result_status = 'conflict' THEN
      IF v_receipt.result_status = 'confirmed'
        AND v_task.is_completed IS DISTINCT FROM p_is_completed THEN
        RETURN jsonb_build_object(
          'status', 'conflict',
          'operation_id', p_operation_id,
          'task', to_jsonb(v_task)
        );
      END IF;
      RETURN jsonb_build_object(
        'status', v_receipt.result_status,
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
  END IF;

  IF v_task.is_completed IS DISTINCT FROM p_is_completed
    AND v_task.completion_version <> p_expected_version THEN
    UPDATE public.task_completion_receipts AS receipt
    SET result_status = 'conflict'
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object(
      'status', 'conflict',
      'operation_id', p_operation_id,
      'task', to_jsonb(v_task)
    );
  END IF;

  IF v_task.is_completed IS DISTINCT FROM p_is_completed THEN
    UPDATE public.tasks AS task SET
      is_completed = p_is_completed,
      completed_at = CASE WHEN p_is_completed THEN clock_timestamp() ELSE NULL END,
      completion_version = task.completion_version + 1
    WHERE task.id = p_id
    RETURNING task.* INTO v_task;
  END IF;

  UPDATE public.task_completion_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'task', to_jsonb(v_task)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_task_completion_p(uuid, text, uuid, boolean, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_task_completion_p(uuid, text, uuid, boolean, bigint)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
