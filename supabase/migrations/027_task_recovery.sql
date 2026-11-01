-- Retain task content in a private tombstone for exactly seven 24-hour periods.
-- The deletion ledger has no foreign keys to its former parents so those
-- metadata and deadlines survive a later column or board cascade.
BEGIN;

CREATE TABLE public.task_deletions (
  task_id uuid PRIMARY KEY,
  board_id uuid NOT NULL,
  original_column_id uuid NOT NULL,
  deleted_by uuid NOT NULL,
  cause text NOT NULL CHECK (cause = 'user_requested'),
  deleted_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  task_snapshot jsonb,
  state text NOT NULL CHECK (state IN ('deleted', 'restored', 'purged')),
  restored_at timestamptz,
  purged_at timestamptz,
  CONSTRAINT task_deletions_exact_window CHECK (
    expires_at = deleted_at + interval '7 days'
  ),
  CONSTRAINT task_deletions_state_shape CHECK (
    (state = 'deleted' AND task_snapshot IS NOT NULL
      AND restored_at IS NULL AND purged_at IS NULL)
    OR (state = 'restored' AND task_snapshot IS NULL
      AND restored_at IS NOT NULL AND purged_at IS NULL)
    OR (state = 'purged' AND task_snapshot IS NULL
      AND restored_at IS NULL AND purged_at IS NOT NULL)
  )
);
CREATE INDEX task_deletions_board_expiry_idx
  ON public.task_deletions (board_id, expires_at, task_id)
  WHERE state = 'deleted';
ALTER TABLE public.task_deletions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_deletions
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.task_recovery_receipts (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  command text NOT NULL CHECK (command IN ('delete', 'restore')),
  board_id uuid NOT NULL,
  task_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_status text NOT NULL CHECK (result_status IN (
    'pending', 'confirmed', 'conflict', 'unavailable', 'expired', 'needs_destination'
  )),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);
ALTER TABLE public.task_recovery_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_recovery_receipts
  FROM PUBLIC, anon, authenticated, service_role;

DROP FUNCTION public.delete_task_p(text, uuid);

CREATE FUNCTION public.delete_task_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_cause text DEFAULT 'user_requested'
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
  v_membership_id uuid;
  v_receipt public.task_recovery_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_deleted_at timestamptz;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_id IS NULL
    OR p_cause IS DISTINCT FROM 'user_requested' THEN
    RAISE EXCEPTION 'Task deletion requires an operation, task, and supported cause'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board.id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := extensions.digest(convert_to(jsonb_build_object(
    'command', 'delete',
    'board_id', v_board.id,
    'task_id', p_id,
    'cause', p_cause
  )::text, 'UTF8'), 'sha256');

  INSERT INTO public.task_recovery_receipts(
    actor_id, operation_id, command, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'delete', v_board.id, p_id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_recovery_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.command IS DISTINCT FROM 'delete'
      OR v_receipt.board_id IS DISTINCT FROM v_board.id
      OR v_receipt.task_id IS DISTINCT FROM p_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This task operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status <> 'pending' THEN
      RETURN jsonb_build_object(
        'status', v_receipt.result_status,
        'operation_id', p_operation_id
      );
    END IF;
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    UPDATE public.task_recovery_receipts AS receipt
    SET result_status = 'unavailable'
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_deleted_at := clock_timestamp();
  INSERT INTO public.task_deletions(
    task_id, board_id, original_column_id, deleted_by, cause,
    deleted_at, expires_at, task_snapshot, state
  ) VALUES (
    v_task.id, v_board.id, v_task.column_id, v_actor_id, p_cause,
    v_deleted_at, v_deleted_at + interval '7 days', to_jsonb(v_task), 'deleted'
  )
  ON CONFLICT (task_id) DO UPDATE SET
    board_id = EXCLUDED.board_id,
    original_column_id = EXCLUDED.original_column_id,
    deleted_by = EXCLUDED.deleted_by,
    cause = EXCLUDED.cause,
    deleted_at = EXCLUDED.deleted_at,
    expires_at = EXCLUDED.expires_at,
    task_snapshot = EXCLUDED.task_snapshot,
    state = 'deleted',
    restored_at = NULL,
    purged_at = NULL;

  DELETE FROM public.tasks WHERE id = v_task.id;
  UPDATE public.task_recovery_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN jsonb_build_object('status', 'confirmed', 'operation_id', p_operation_id);
END;
$$;

CREATE FUNCTION public.list_deleted_tasks_p(p_slug text)
RETURNS TABLE (
  task_id uuid,
  title text,
  original_column_id uuid,
  cause text,
  deleted_at timestamptz,
  expires_at timestamptz,
  can_restore boolean,
  original_column_available boolean
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT deletion.task_id,
    deletion.task_snapshot->>'title',
    deletion.original_column_id,
    deletion.cause,
    deletion.deleted_at,
    deletion.expires_at,
    clock_timestamp() < deletion.expires_at,
    EXISTS (
      SELECT 1 FROM public.columns AS column_row
      WHERE column_row.id = deletion.original_column_id
        AND column_row.board_id = board.id
        AND column_row.generation_id = board.active_generation_id
    )
  FROM public.task_deletions AS deletion
  JOIN public.boards AS board ON board.id = deletion.board_id
  WHERE board.slug = p_slug
    AND deletion.state = 'deleted'
    AND deletion.task_snapshot IS NOT NULL
    AND auth.uid() IS NOT NULL
    AND public.is_application_user()
    AND public.is_board_member(board.id)
  ORDER BY deletion.deleted_at DESC, deletion.task_id;
$$;

CREATE FUNCTION public.restore_task_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_target_column_id uuid,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_deletion public.task_deletions%ROWTYPE;
  v_column public.columns%ROWTYPE;
  v_receipt public.task_recovery_receipts%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_membership_id uuid;
  v_payload_hash bytea;
  v_now timestamptz;
  v_column_id uuid;
  v_position integer;
  v_assignee_id uuid;
  v_status text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_id IS NULL THEN
    RAISE EXCEPTION 'Task recovery requires an operation and task'
      USING ERRCODE = '22023';
  END IF;

  -- Read only the non-sensitive board key first so all task mutations lock in
  -- board -> deletion -> task order. Parent deletion cannot reset this ledger.
  SELECT deletion.board_id INTO v_board_id
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id AND board.slug = p_slug;
  IF NOT FOUND OR NOT public.is_board_member(v_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board_id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := extensions.digest(convert_to(jsonb_build_object(
    'command', 'restore',
    'board_id', v_board_id,
    'task_id', p_id,
    'target_column_id', p_target_column_id
  )::text, 'UTF8'), 'sha256');

  INSERT INTO public.task_recovery_receipts(
    actor_id, operation_id, command, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'restore', v_board_id, p_id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_recovery_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.command IS DISTINCT FROM 'restore'
      OR v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This task operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status <> 'pending' THEN
      RETURN jsonb_build_object(
        'status', v_receipt.result_status,
        'operation_id', p_operation_id
      );
    END IF;
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT deletion.* INTO v_deletion
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id AND deletion.board_id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.task_snapshot IS NULL THEN
    v_status := 'unavailable';
  ELSE
    v_now := coalesce(p_now, clock_timestamp());
    IF v_now >= v_deletion.expires_at THEN
      v_status := 'expired';
    ELSE
      v_column_id := coalesce(p_target_column_id, v_deletion.original_column_id);
      SELECT column_row.* INTO v_column
      FROM public.columns AS column_row
      WHERE column_row.id = v_column_id
        AND column_row.board_id = v_board_id
        AND column_row.generation_id = v_board.active_generation_id
      FOR UPDATE;
      IF NOT FOUND THEN
        v_status := CASE
          WHEN p_target_column_id IS NULL THEN 'needs_destination'
          ELSE 'unavailable'
        END;
      ELSIF EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = p_id) THEN
        v_status := 'unavailable';
      ELSE
        v_position := coalesce((
          SELECT max(task.position) + 1
          FROM public.tasks AS task
          WHERE task.column_id = v_column.id
        ), 0);
        v_task := jsonb_populate_record(NULL::public.tasks, v_deletion.task_snapshot);
        v_assignee_id := v_task.assignee_id;
        IF v_assignee_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM public.board_memberships AS assignment_membership
          WHERE assignment_membership.board_id = v_board_id
            AND assignment_membership.user_id = v_assignee_id
            AND assignment_membership.revoked_at IS NULL
            AND public.is_enabled_application_identity_p(v_assignee_id)
        ) THEN
          v_assignee_id := NULL;
        END IF;
        v_task.column_id := v_column.id;
        v_task.position := v_position;
        v_task.assignee_id := v_assignee_id;
        IF v_task.assignee_id IS DISTINCT FROM (v_deletion.task_snapshot->>'assignee_id')::uuid THEN
          v_task.assignee_version := v_task.assignee_version + 1;
        END IF;
        v_task.updated_at := v_now;
        INSERT INTO public.tasks SELECT v_task.*;
        UPDATE public.task_deletions AS deletion
        SET task_snapshot = NULL,
            state = 'restored',
            restored_at = v_now
        WHERE deletion.task_id = p_id;
        v_status := 'confirmed';
      END IF;
    END IF;
  END IF;

  UPDATE public.task_recovery_receipts AS receipt
  SET result_status = v_status
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN jsonb_build_object('status', v_status, 'operation_id', p_operation_id);
END;
$$;

CREATE FUNCTION public.restore_task_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_target_column_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.restore_task_internal_p(
    p_operation_id, p_slug, p_id, p_target_column_id, NULL
  );
$$;

CREATE FUNCTION public.purge_expired_task_internal_p(
  p_id uuid,
  p_now timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_deletion public.task_deletions%ROWTYPE;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
BEGIN
  SELECT deletion.* INTO v_deletion
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id
  FOR UPDATE;
  IF NOT FOUND OR v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.task_snapshot IS NULL THEN
    RETURN 'already_terminal';
  END IF;
  IF v_now < v_deletion.expires_at THEN
    RETURN 'too_early';
  END IF;
  UPDATE public.task_deletions AS deletion
  SET task_snapshot = NULL,
      state = 'purged',
      purged_at = v_now
  WHERE deletion.task_id = p_id;
  RETURN 'purged';
END;
$$;

-- This service-role entry point is only a callable hook for the future durable
-- worker. The worker itself belongs to issue #23 and is intentionally absent.
CREATE FUNCTION public.purge_expired_tasks_p(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_task_id uuid;
  v_purged integer := 0;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'Choose a purge limit from 1 to 1000' USING ERRCODE = '22023';
  END IF;
  FOR v_task_id IN
    SELECT deletion.task_id
    FROM public.task_deletions AS deletion
    WHERE deletion.state = 'deleted'
      AND deletion.expires_at <= clock_timestamp()
    ORDER BY deletion.expires_at, deletion.task_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    IF public.purge_expired_task_internal_p(v_task_id, NULL) = 'purged' THEN
      v_purged := v_purged + 1;
    END IF;
  END LOOP;
  RETURN v_purged;
END;
$$;

REVOKE ALL ON FUNCTION public.delete_task_p(uuid, text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_task_p(uuid, text, uuid, text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.list_deleted_tasks_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_deleted_tasks_p(text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.restore_task_internal_p(uuid, text, uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_task_p(uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restore_task_p(uuid, text, uuid, uuid)
  TO authenticated;
REVOKE ALL ON FUNCTION public.purge_expired_task_internal_p(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_tasks_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.purge_expired_tasks_p(integer)
  TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
