BEGIN;

CREATE TABLE public.board_departure_operation_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('leave', 'delete_last_member')),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_status text NOT NULL CHECK (
    result_status IN ('pending', 'confirmed', 'conflict', 'recoverable')
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (clock_timestamp() + interval '168 hours'),
  PRIMARY KEY (actor_id, operation_id)
);
CREATE INDEX board_departure_operation_receipts_expiry_idx
  ON public.board_departure_operation_receipts(result_expires_at);

ALTER TABLE public.board_departure_operation_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_departure_operation_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_recoverable_deletions (
  board_id uuid PRIMARY KEY REFERENCES public.boards(id) ON DELETE CASCADE,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  cause text NOT NULL CHECK (cause = 'owner_confirmed_last_member'),
  deleted_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  CONSTRAINT board_recoverable_deletions_window CHECK (
    expires_at = deleted_at + interval '168 hours'
  )
);
CREATE INDEX board_recoverable_deletions_expiry_idx
  ON public.board_recoverable_deletions(expires_at);
ALTER TABLE public.board_recoverable_deletions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_recoverable_deletions
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.is_board_member(p_board_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT p_board_id IS NOT NULL
    AND public.is_application_user()
    AND NOT EXISTS (
      SELECT 1
      FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = p_board_id
    )
    AND EXISTS (
      SELECT 1
      FROM public.board_memberships AS membership
      WHERE membership.board_id = p_board_id
        AND membership.user_id = auth.uid()
        AND membership.revoked_at IS NULL
    );
$$;

CREATE OR REPLACE FUNCTION public.check_board_owner_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_owner_id uuid;
  v_active_owner_count integer;
  v_recovery_exists boolean;
  v_active_member_count integer;
BEGIN
  IF TG_TABLE_NAME = 'boards' THEN
    v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
  ELSE
    v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.board_id ELSE NEW.board_id END;
  END IF;

  SELECT board.owner_id INTO v_owner_id
  FROM public.boards AS board
  WHERE board.id = v_board_id;
  IF NOT FOUND OR v_owner_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.board_recoverable_deletions AS recovery
    WHERE recovery.board_id = v_board_id
  ) INTO v_recovery_exists;
  IF v_recovery_exists THEN
    SELECT count(*) INTO v_active_member_count
    FROM public.board_memberships AS membership
    WHERE membership.board_id = v_board_id
      AND membership.revoked_at IS NULL;
    IF v_active_member_count <> 0 THEN
      RAISE EXCEPTION 'A recoverable board cannot retain active memberships'
        USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
  END IF;

  SELECT count(*) INTO v_active_owner_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board_id
    AND membership.user_id = v_owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL;
  IF v_active_owner_count <> 1 THEN
    RAISE EXCEPTION 'Every owned board must have exactly one active owner membership'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_my_boards()
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  time_zone text,
  role text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.id, board.slug, board.name, board.time_zone,
    membership.role, board.created_at, board.updated_at
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
  WHERE membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL
    AND public.is_application_user()
    AND public.is_board_member(board.id)
  ORDER BY board.updated_at DESC, board.id;
$$;

CREATE FUNCTION public.board_departure_operation_result_p(
  p_actor_id uuid,
  p_operation_id uuid,
  p_action text,
  p_board_id uuid,
  p_payload_hash bytea
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_receipt public.board_departure_operation_receipts%ROWTYPE;
BEGIN
  SELECT receipt.* INTO v_receipt
  FROM public.board_departure_operation_receipts AS receipt
  WHERE receipt.actor_id = p_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_receipt.action IS DISTINCT FROM p_action
    OR v_receipt.board_id IS DISTINCT FROM p_board_id
    OR v_receipt.payload_hash IS DISTINCT FROM p_payload_hash THEN
    RAISE EXCEPTION 'Board departure operation key was already used'
      USING ERRCODE = '23514';
  END IF;
  IF v_receipt.result_expires_at <= clock_timestamp() THEN
    RETURN jsonb_build_object(
      'status', 'expired_unknown',
      'operation_id', p_operation_id
    );
  END IF;
  IF v_receipt.result_status = 'pending' THEN
    RETURN jsonb_build_object(
      'status', 'retryable',
      'operation_id', p_operation_id
    );
  END IF;
  IF v_receipt.result_status = 'recoverable' THEN
    RETURN jsonb_build_object(
      'status', 'recoverable',
      'operation_id', p_operation_id,
      'expires_at', v_receipt.result_expires_at
    );
  END IF;
  RETURN jsonb_build_object(
    'status', v_receipt.result_status,
    'operation_id', p_operation_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.board_departure_operation_result_p(
  uuid, uuid, text, uuid, bytea
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.prepare_board_member_departure_p(
  p_board_id uuid,
  p_member_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_board_id IS NULL OR p_member_id IS DISTINCT FROM auth.uid()
    OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.board_invitations AS invitation
  SET status = 'revoked'
  WHERE invitation.board_id = p_board_id
    AND invitation.inviter_id = p_member_id
    AND invitation.status = 'pending';

  UPDATE public.tasks AS task
  SET assignee_id = NULL,
      assignee_version = task.assignee_version + 1
  FROM public.columns AS column_row
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE task.column_id = column_row.id
    AND column_row.board_id = p_board_id
    AND column_row.generation_id = board.active_generation_id
    AND task.assignee_id = p_member_id
    AND NOT task.is_completed;
END;
$$;
REVOKE ALL ON FUNCTION public.prepare_board_member_departure_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.guard_board_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT public.is_application_user() THEN
      RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
    END IF;
    IF NEW.owner_id IS NOT NULL AND NEW.owner_id <> auth.uid() THEN
      RAISE EXCEPTION 'A board must belong to its creator' USING ERRCODE = '42501';
    END IF;
    NEW.owner_id := auth.uid();
    NEW.name := btrim(NEW.name);
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF NOT public.is_board_owner(OLD.id) THEN
      RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.slug IS DISTINCT FROM OLD.slug THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    IF (NOT public.is_board_owner(OLD.id) AND NOT public.is_application_admin())
      OR NOT EXISTS (
        SELECT 1
        FROM public.board_memberships AS membership
        WHERE membership.board_id = OLD.id
          AND membership.user_id = NEW.owner_id
          AND membership.role = 'collaborator'
          AND membership.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(membership.user_id)
      ) THEN
      RAISE EXCEPTION 'Choose a current enabled board member as owner'
        USING ERRCODE = '42501';
    END IF;
  ELSIF NOT public.is_board_owner(OLD.id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  NEW.name := btrim(NEW.name);
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.leave_board_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_successor_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_actor_membership public.board_memberships%ROWTYPE;
  v_successor public.board_memberships%ROWTYPE;
  v_receipt public.board_departure_operation_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_response jsonb;
BEGIN
  IF p_operation_id IS NULL OR p_board_id IS NULL THEN
    RAISE EXCEPTION 'A board departure requires an operation and board'
      USING ERRCODE = '22023';
  END IF;

  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  v_payload_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'leave',
        'board_id', p_board_id,
        'successor_user_id', p_successor_user_id
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  v_response := public.board_departure_operation_result_p(
    v_actor_id,
    p_operation_id,
    'leave',
    p_board_id,
    v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;
  IF NOT public.is_board_member(p_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  -- Another request with this actor and operation id may have committed while
  -- this call waited for the board lock. Reconcile it before membership checks.
  v_response := public.board_departure_operation_result_p(
    v_actor_id,
    p_operation_id,
    'leave',
    p_board_id,
    v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;
  IF NOT public.is_board_member(p_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT membership.* INTO v_actor_membership
  FROM public.board_memberships AS membership
  WHERE membership.board_id = p_board_id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  IF v_board.owner_id = v_actor_id AND v_actor_membership.role = 'owner' THEN
    INSERT INTO public.board_departure_operation_receipts (
      actor_id, operation_id, action, board_id, payload_hash, result_status
    ) VALUES (
      v_actor_id, p_operation_id, 'leave', p_board_id, v_payload_hash, 'pending'
    ) ON CONFLICT (actor_id, operation_id) DO NOTHING
    RETURNING * INTO v_receipt;
    IF NOT FOUND THEN
      v_response := public.board_departure_operation_result_p(
        v_actor_id, p_operation_id, 'leave', p_board_id, v_payload_hash
      );
      IF v_response IS NOT NULL THEN
        RETURN v_response;
      END IF;
      RAISE EXCEPTION 'The board departure result could not be reconciled'
        USING ERRCODE = '40001';
    END IF;

    IF p_successor_user_id IS NULL OR p_successor_user_id = v_actor_id THEN
      UPDATE public.board_departure_operation_receipts AS receipt
      SET result_status = 'conflict'
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
    END IF;

    SELECT membership.* INTO v_successor
    FROM public.board_memberships AS membership
    WHERE membership.board_id = p_board_id
      AND membership.user_id = p_successor_user_id
      AND membership.role = 'collaborator'
      AND membership.revoked_at IS NULL
    FOR UPDATE;
    IF NOT FOUND OR NOT public.is_enabled_application_identity_p(p_successor_user_id) THEN
      UPDATE public.board_departure_operation_receipts AS receipt
      SET result_status = 'conflict'
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
    END IF;

    UPDATE public.boards AS board
    SET owner_id = p_successor_user_id
    WHERE board.id = p_board_id;
    PERFORM public.prepare_board_member_departure_p(p_board_id, v_actor_id);
    UPDATE public.board_memberships AS membership
    SET revoked_at = clock_timestamp()
    WHERE membership.id = v_actor_membership.id;
    UPDATE public.board_memberships AS membership
    SET role = 'owner'
    WHERE membership.id = v_successor.id;

    UPDATE public.board_departure_operation_receipts AS receipt
    SET result_status = 'confirmed'
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id;

    RETURN jsonb_build_object('status', 'confirmed', 'operation_id', p_operation_id);
  END IF;

  IF v_board.owner_id IS DISTINCT FROM v_actor_id
    AND v_actor_membership.role = 'collaborator' THEN
    IF p_successor_user_id IS NOT NULL THEN
      RAISE EXCEPTION 'Only a board owner chooses a successor'
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.board_departure_operation_receipts (
      actor_id, operation_id, action, board_id, payload_hash, result_status
    ) VALUES (
      v_actor_id, p_operation_id, 'leave', p_board_id, v_payload_hash, 'pending'
    ) ON CONFLICT (actor_id, operation_id) DO NOTHING
    RETURNING * INTO v_receipt;
    IF NOT FOUND THEN
      v_response := public.board_departure_operation_result_p(
        v_actor_id, p_operation_id, 'leave', p_board_id, v_payload_hash
      );
      IF v_response IS NOT NULL THEN
        RETURN v_response;
      END IF;
      RAISE EXCEPTION 'The board departure result could not be reconciled'
        USING ERRCODE = '40001';
    END IF;

    PERFORM public.prepare_board_member_departure_p(p_board_id, v_actor_id);

    UPDATE public.board_memberships AS membership
    SET revoked_at = clock_timestamp()
    WHERE membership.id = v_actor_membership.id;

    UPDATE public.board_departure_operation_receipts AS receipt
    SET result_status = 'confirmed'
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id;

    RETURN jsonb_build_object('status', 'confirmed', 'operation_id', p_operation_id);
  END IF;

  RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
END;
$$;
REVOKE ALL ON FUNCTION public.leave_board_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.leave_board_p(uuid, uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.delete_last_member_board_p(
  p_operation_id uuid,
  p_board_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_owner_membership public.board_memberships%ROWTYPE;
  v_receipt public.board_departure_operation_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_response jsonb;
  v_other_active_members integer;
  v_deleted_at timestamptz;
  v_expires_at timestamptz;
BEGIN
  IF p_operation_id IS NULL OR p_board_id IS NULL THEN
    RAISE EXCEPTION 'A recoverable board deletion requires an operation and board'
      USING ERRCODE = '22023';
  END IF;
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  v_payload_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'delete_last_member',
        'board_id', p_board_id
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  v_response := public.board_departure_operation_result_p(
    v_actor_id,
    p_operation_id,
    'delete_last_member',
    p_board_id,
    v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;
  IF NOT public.is_board_member(p_board_id) THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_response := public.board_departure_operation_result_p(
    v_actor_id,
    p_operation_id,
    'delete_last_member',
    p_board_id,
    v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;
  IF NOT public.is_board_member(p_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT membership.* INTO v_owner_membership
  FROM public.board_memberships AS membership
  WHERE membership.board_id = p_board_id
    AND membership.user_id = v_actor_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND OR v_board.owner_id IS DISTINCT FROM v_actor_id THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.board_departure_operation_receipts (
    actor_id, operation_id, action, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'delete_last_member', p_board_id,
    v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_response := public.board_departure_operation_result_p(
      v_actor_id,
      p_operation_id,
      'delete_last_member',
      p_board_id,
      v_payload_hash
    );
    IF v_response IS NOT NULL THEN
      RETURN v_response;
    END IF;
    RAISE EXCEPTION 'The recoverable deletion result could not be reconciled'
      USING ERRCODE = '40001';
  END IF;

  SELECT count(*) INTO v_other_active_members
  FROM public.board_memberships AS membership
  WHERE membership.board_id = p_board_id
    AND membership.revoked_at IS NULL
    AND membership.user_id <> v_actor_id;
  IF v_other_active_members <> 0 THEN
    UPDATE public.board_departure_operation_receipts AS receipt
    SET result_status = 'conflict'
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;

  PERFORM public.prepare_board_member_departure_p(p_board_id, v_actor_id);

  v_deleted_at := clock_timestamp();
  v_expires_at := v_deleted_at + interval '168 hours';
  INSERT INTO public.board_recoverable_deletions (
    board_id, actor_id, cause, deleted_at, expires_at
  ) VALUES (
    p_board_id,
    v_actor_id,
    'owner_confirmed_last_member',
    v_deleted_at,
    v_expires_at
  );

  UPDATE public.board_invitations AS invitation
  SET status = 'revoked'
  WHERE invitation.board_id = p_board_id
    AND invitation.status = 'pending';

  UPDATE public.board_memberships AS membership
  SET revoked_at = v_deleted_at
  WHERE membership.id = v_owner_membership.id;

  UPDATE public.board_departure_operation_receipts AS receipt
  SET result_status = 'recoverable',
      result_expires_at = v_expires_at
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'recoverable',
    'operation_id', p_operation_id,
    'expires_at', v_expires_at
  );
END;
$$;
REVOKE ALL ON FUNCTION public.delete_last_member_board_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_last_member_board_p(uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.has_other_current_board_members_p(p_board_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_board_id IS NULL OR NOT public.is_application_user()
    OR NOT public.is_board_owner(p_board_id) THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  RETURN EXISTS (
    SELECT 1
    FROM public.board_memberships AS membership
    WHERE membership.board_id = p_board_id
      AND membership.revoked_at IS NULL
      AND membership.user_id <> auth.uid()
  );
END;
$$;
REVOKE ALL ON FUNCTION public.has_other_current_board_members_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.has_other_current_board_members_p(uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
