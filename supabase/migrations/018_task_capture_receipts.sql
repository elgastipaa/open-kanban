-- Task creation uses an explicit operation receipt so a lost response can be
-- reconciled without creating another task.
BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

ALTER TABLE public.tasks
  ADD COLUMN created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE TABLE public.task_capture_receipts (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);

ALTER TABLE public.task_capture_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_capture_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.task_capture_payload_hash(p_payload jsonb)
RETURNS bytea
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_extension_schema name;
  v_payload_hash bytea;
BEGIN
  SELECT namespace.nspname INTO v_extension_schema
  FROM pg_catalog.pg_extension AS extension
  JOIN pg_catalog.pg_namespace AS namespace
    ON namespace.oid = extension.extnamespace
  WHERE extension.extname = 'pgcrypto';

  IF v_extension_schema IS NULL THEN
    RAISE EXCEPTION 'Task capture fingerprint support is unavailable'
      USING ERRCODE = '55000';
  END IF;

  EXECUTE pg_catalog.format('SELECT %I.digest($1, $2)', v_extension_schema)
    INTO v_payload_hash
    USING pg_catalog.convert_to(p_payload::text, 'UTF8'), 'sha256';
  RETURN v_payload_hash;
END;
$$;

CREATE OR REPLACE FUNCTION public.task_capture_normalize_title(p_title text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_title text;
BEGIN
  IF p_title IS NULL THEN
    RAISE EXCEPTION 'Enter a task title' USING ERRCODE = '22023';
  END IF;

  v_title := pg_catalog.regexp_replace(
    p_title,
    '^[[:space:]]+|[[:space:]]+$',
    '',
    'g'
  );
  IF v_title = '' THEN
    RAISE EXCEPTION 'Enter a task title' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.char_length(v_title) > 200 THEN
    RAISE EXCEPTION 'Task titles must be 200 characters or fewer'
      USING ERRCODE = '22023';
  END IF;
  RETURN v_title;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_task_capture_access_p(p_board_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_locked_actor uuid;
  v_membership_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  -- Shared row locks serialize access checks with application suspension and
  -- membership revocation.
  SELECT access.auth_user_id INTO v_locked_actor
  FROM public.application_access AS access
  WHERE access.auth_user_id = v_actor_id
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = p_board_id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(p_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
END;
$$;

DROP FUNCTION IF EXISTS public.resolve_task_capture_receipt_p(uuid, bytea);

CREATE FUNCTION public.resolve_task_capture_receipt_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_expected_payload_hash bytea
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_receipt public.task_capture_receipts%ROWTYPE;
  v_board_id uuid;
  v_column_id uuid;
  v_task public.tasks%ROWTYPE;
BEGIN
  IF p_operation_id IS NULL OR p_board_id IS NULL THEN
    RAISE EXCEPTION 'A task creation operation and board are required'
      USING ERRCODE = '22023';
  END IF;

  -- Authorize and lock the requested board before looking up the operation id.
  PERFORM public.assert_task_capture_access_p(p_board_id);

  SELECT receipt.* INTO v_receipt
  FROM public.task_capture_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id
    AND receipt.board_id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status', 'not_found',
      'operation_id', p_operation_id
    );
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT column_row.id INTO v_column_id
  FROM public.columns AS column_row
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE column_row.id = v_receipt.column_id
    AND column_row.board_id = p_board_id
    AND column_row.generation_id = board.active_generation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  -- Authorization and membership locks are held before comparing the hash, so
  -- a revoked member cannot distinguish a reused key from an unknown one.
  IF v_receipt.payload_hash IS DISTINCT FROM p_expected_payload_hash THEN
    RAISE EXCEPTION 'This task creation operation was already used with different details'
      USING ERRCODE = '23514';
  END IF;

  IF v_receipt.result_expires_at <= statement_timestamp() THEN
    RETURN jsonb_build_object(
      'status', 'expired_unknown',
      'operation_id', v_receipt.operation_id,
      'board_id', v_receipt.board_id,
      'column_id', v_receipt.column_id,
      'task_id', v_receipt.task_id
    );
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE task.id = v_receipt.task_id
    AND board.id = p_board_id
    AND column_row.generation_id = board.active_generation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', v_receipt.operation_id,
    'board_id', p_board_id,
    'column_id', v_task.column_id,
    'task_id', v_task.id,
    'task', to_jsonb(v_task)
  );
END;
$$;

DROP FUNCTION IF EXISTS public.create_task_p(text, uuid, text, text, text, integer);

CREATE FUNCTION public.create_task_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_column_id uuid,
  p_title text,
  p_description text DEFAULT NULL,
  p_priority text DEFAULT 'medium'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_title text;
  v_description text;
  v_payload_hash bytea;
  v_existing_result jsonb;
  v_board public.boards%ROWTYPE;
  v_locked_actor uuid;
  v_membership_id uuid;
  v_column public.columns%ROWTYPE;
  v_task_id uuid;
  v_position integer;
  v_task public.tasks%ROWTYPE;
  v_receipt public.task_capture_receipts%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'A task creation operation id is required'
      USING ERRCODE = '22023';
  END IF;
  IF p_board_id IS NULL OR p_column_id IS NULL THEN
    RAISE EXCEPTION 'Choose a board and column' USING ERRCODE = '22023';
  END IF;
  PERFORM public.assert_task_capture_access_p(p_board_id);
  v_title := public.task_capture_normalize_title(p_title);
  IF p_description IS NOT NULL AND char_length(p_description) > 2000 THEN
    RAISE EXCEPTION 'Task descriptions must be 2000 characters or fewer'
      USING ERRCODE = '22023';
  END IF;
  IF p_priority IS NULL OR p_priority NOT IN ('low', 'medium', 'high', 'urgent') THEN
    RAISE EXCEPTION 'Choose a valid task priority' USING ERRCODE = '22023';
  END IF;
  v_description := CASE
    WHEN p_description IS NULL OR btrim(p_description) = '' THEN NULL
    ELSE p_description
  END;

  v_payload_hash := public.task_capture_payload_hash(jsonb_build_object(
    'action', 'create_task',
    'board_id', p_board_id,
    'column_id', p_column_id,
    'title', v_title,
    'description', v_description,
    'priority', p_priority
  ));

  v_existing_result := public.resolve_task_capture_receipt_p(
    p_operation_id,
    p_board_id,
    v_payload_hash
  );
  IF v_existing_result->>'status' <> 'not_found' THEN
    RETURN v_existing_result;
  END IF;

  -- Reject nonmembers before taking the board lock; then lock and revalidate
  -- both membership and the active column generation under the same command.
  IF NOT public.is_board_member(p_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = p_board_id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(p_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT column_row.* INTO v_column
  FROM public.columns AS column_row
  WHERE column_row.id = p_column_id
    AND column_row.board_id = p_board_id
    AND column_row.generation_id = v_board.active_generation_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The selected column is unavailable for this board'
      USING ERRCODE = '22023';
  END IF;

  -- Receipt creation precedes the task insert inside one transaction. A
  -- competing operation with this actor/key either owns the receipt or reads
  -- it after its transaction commits; neither path can create a second task.
  v_task_id := gen_random_uuid();
  INSERT INTO public.task_capture_receipts(
    actor_id,
    operation_id,
    board_id,
    column_id,
    task_id,
    payload_hash
  ) VALUES (
    v_actor_id,
    p_operation_id,
    p_board_id,
    p_column_id,
    v_task_id,
    v_payload_hash
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    v_existing_result := public.resolve_task_capture_receipt_p(
      p_operation_id,
      p_board_id,
      v_payload_hash
    );
    IF v_existing_result->>'status' = 'not_found' THEN
      -- The actor-scoped unique key may belong to another board. Keep the
      -- resolver board-scoped for privacy, but report the collision as a
      -- deterministic payload conflict without exposing the other receipt.
      RAISE EXCEPTION 'This task creation operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    RETURN v_existing_result;
  END IF;

  SELECT COALESCE(max(task.position) + 1, 0) INTO v_position
  FROM public.tasks AS task
  WHERE task.column_id = p_column_id;

  INSERT INTO public.tasks(
    id,
    column_id,
    title,
    description,
    priority,
    position,
    created_by
  ) VALUES (
    v_task_id,
    p_column_id,
    v_title,
    v_description,
    p_priority,
    v_position,
    v_actor_id
  )
  RETURNING * INTO v_task;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'board_id', p_board_id,
    'column_id', v_task.column_id,
    'task_id', v_task.id,
    'task', to_jsonb(v_task)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_task_creation_result_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_column_id uuid,
  p_title text,
  p_description text,
  p_priority text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_title text;
  v_description text;
  v_payload_hash bytea;
BEGIN
  IF p_operation_id IS NULL OR p_board_id IS NULL OR p_column_id IS NULL THEN
    RAISE EXCEPTION 'A task creation operation, board, and column are required'
      USING ERRCODE = '22023';
  END IF;
  PERFORM public.assert_task_capture_access_p(p_board_id);
  v_title := public.task_capture_normalize_title(p_title);
  IF p_description IS NOT NULL AND char_length(p_description) > 2000 THEN
    RAISE EXCEPTION 'Task descriptions must be 2000 characters or fewer'
      USING ERRCODE = '22023';
  END IF;
  IF p_priority IS NULL OR p_priority NOT IN ('low', 'medium', 'high', 'urgent') THEN
    RAISE EXCEPTION 'Choose a valid task priority' USING ERRCODE = '22023';
  END IF;

  v_description := CASE
    WHEN p_description IS NULL OR btrim(p_description) = '' THEN NULL
    ELSE p_description
  END;
  v_payload_hash := public.task_capture_payload_hash(jsonb_build_object(
    'action', 'create_task',
    'board_id', p_board_id,
    'column_id', p_column_id,
    'title', v_title,
    'description', v_description,
    'priority', p_priority
  ));

  -- The resolver rechecks and locks access before reading the receipt, so an
  -- access revoke cannot be distinguished from an unknown operation id.
  RETURN public.resolve_task_capture_receipt_p(
    p_operation_id,
    p_board_id,
    v_payload_hash
  );
END;
$$;

REVOKE ALL ON FUNCTION public.task_capture_payload_hash(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.task_capture_normalize_title(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.assert_task_capture_access_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.resolve_task_capture_receipt_p(uuid, uuid, bytea)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_task_p(uuid, uuid, uuid, text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_task_creation_result_p(uuid, uuid, uuid, text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_task_p(uuid, uuid, uuid, text, text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_task_creation_result_p(uuid, uuid, uuid, text, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
