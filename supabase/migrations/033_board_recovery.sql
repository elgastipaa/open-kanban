BEGIN;

ALTER TABLE public.board_departure_operation_receipts
  DROP CONSTRAINT board_departure_operation_receipts_action_check,
  ADD CONSTRAINT board_departure_operation_receipts_action_check
    CHECK (action IN (
      'leave', 'delete_last_member', 'remove_collaborator', 'delete_board', 'restore_board'
    )),
  DROP CONSTRAINT board_departure_operation_receipts_result_status_check,
  ADD CONSTRAINT board_departure_operation_receipts_result_status_check
    CHECK (result_status IN (
      'pending', 'confirmed', 'conflict', 'recoverable', 'unavailable',
      'owner_required', 'expired'
    ));

ALTER TABLE public.board_recoverable_deletions
  DROP CONSTRAINT board_recoverable_deletions_cause_check,
  ADD CONSTRAINT board_recoverable_deletions_cause_check
    CHECK (cause IN ('owner_confirmed_last_member', 'owner_requested'));

DROP FUNCTION public.delete_board_p(text, uuid);

CREATE OR REPLACE FUNCTION public.is_board_owner(p_board_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT p_board_id IS NOT NULL
    AND public.is_board_member(p_board_id)
    AND EXISTS (
      SELECT 1
      FROM public.boards AS board
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
      WHERE board.id = p_board_id
        AND board.owner_id = auth.uid()
        AND membership.user_id = auth.uid()
        AND membership.role = 'owner'
        AND membership.revoked_at IS NULL
    );
$$;

CREATE OR REPLACE FUNCTION public.guard_board_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_recoverable boolean;
  v_service_role boolean;
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
    v_service_role := current_setting('request.jwt.claim.role', true) = 'service_role'
      OR current_user = 'service_role';
    IF v_service_role AND EXISTS (
      SELECT 1
      FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = OLD.id
        AND recovery.expires_at <= clock_timestamp()
    ) THEN
      RETURN OLD;
    END IF;
    IF NOT public.is_board_owner(OLD.id) THEN
      RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.slug IS DISTINCT FROM OLD.slug THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS recovery
    WHERE recovery.board_id = OLD.id
  ) INTO v_recoverable;

  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    IF v_recoverable AND public.is_application_admin()
      AND public.is_enabled_application_identity_p(NEW.owner_id) THEN
      NULL;
    ELSIF (NOT public.is_board_owner(OLD.id)
      AND NOT public.is_application_admin())
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

CREATE OR REPLACE FUNCTION public.check_board_owner_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_owner_id uuid;
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

  IF EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS recovery
    WHERE recovery.board_id = v_board_id
  ) THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.board_memberships AS membership
    WHERE membership.board_id = v_board_id
      AND membership.user_id = v_owner_id
      AND membership.role = 'owner'
      AND membership.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Every active board must have a current owner membership'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;

CREATE FUNCTION public.delete_board_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_receipt public.board_departure_operation_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_response jsonb;
  v_deleted_at timestamptz;
  v_expires_at timestamptz;
BEGIN
  IF p_operation_id IS NULL OR p_id IS NULL OR p_slug IS NULL THEN
    RAISE EXCEPTION 'A recoverable board deletion requires an operation and board'
      USING ERRCODE = '22023';
  END IF;
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  PERFORM 1
  FROM public.application_access AS access
  WHERE access.auth_user_id = v_actor_id
  ORDER BY access.auth_user_id
  FOR SHARE;
  IF NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  v_payload_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'delete_board',
        'board_id', p_id,
        'slug', p_slug
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  v_response := public.board_departure_operation_result_p(
    v_actor_id, p_operation_id, 'delete_board', p_id, v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_board_member(p_id)
    OR NOT public.is_board_owner(p_id)
    OR v_board.owner_id IS DISTINCT FROM v_actor_id THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  v_response := public.board_departure_operation_result_p(
    v_actor_id, p_operation_id, 'delete_board', p_id, v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;
  IF NOT public.is_board_member(p_id) OR NOT public.is_board_owner(p_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  INSERT INTO public.board_departure_operation_receipts (
    actor_id, operation_id, action, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'delete_board', p_id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_response := public.board_departure_operation_result_p(
      v_actor_id, p_operation_id, 'delete_board', p_id, v_payload_hash
    );
    IF v_response IS NOT NULL THEN
      RETURN v_response;
    END IF;
    RAISE EXCEPTION 'The board deletion result could not be reconciled'
      USING ERRCODE = '40001';
  END IF;

  v_deleted_at := clock_timestamp();
  v_expires_at := v_deleted_at + interval '168 hours';
  INSERT INTO public.board_recoverable_deletions (
    board_id, actor_id, cause, deleted_at, expires_at
  ) VALUES (
    p_id, v_actor_id, 'owner_requested', v_deleted_at, v_expires_at
  );

  UPDATE public.board_invitations AS invitation
  SET status = 'revoked'
  WHERE invitation.board_id = p_id
    AND invitation.status = 'pending';

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

CREATE FUNCTION public.list_my_recoverable_boards_p()
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  owner_id uuid,
  deleted_at timestamptz,
  expires_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.id, board.slug, board.name, board.owner_id,
    recovery.deleted_at, recovery.expires_at
  FROM public.board_recoverable_deletions AS recovery
  JOIN public.boards AS board ON board.id = recovery.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
   AND membership.user_id = auth.uid()
   AND membership.role = 'owner'
   AND membership.revoked_at IS NULL
  WHERE public.is_application_user()
    AND board.owner_id = auth.uid()
    AND recovery.cause = 'owner_requested'
    AND recovery.expires_at > statement_timestamp()
  ORDER BY recovery.deleted_at DESC, board.id;
$$;

CREATE FUNCTION public.admin_list_recoverable_boards_p()
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  owner_id uuid,
  owner_is_valid boolean,
  active_member_count integer,
  cause text,
  deleted_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'Administrator access required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT board.id,
    board.slug,
    board.name,
    board.owner_id,
    public.is_enabled_application_identity_p(board.owner_id)
      AND EXISTS (
        SELECT 1
        FROM public.board_memberships AS owner_membership
        WHERE owner_membership.board_id = board.id
          AND owner_membership.user_id = board.owner_id
          AND owner_membership.role = 'owner'
          AND owner_membership.revoked_at IS NULL
      ) AS owner_is_valid,
    (
      SELECT count(*)::integer
      FROM public.board_memberships AS membership
      WHERE membership.board_id = board.id
        AND membership.revoked_at IS NULL
    ) AS active_member_count,
    recovery.cause,
    recovery.deleted_at,
    recovery.expires_at
  FROM public.board_recoverable_deletions AS recovery
  JOIN public.boards AS board ON board.id = recovery.board_id
  WHERE recovery.expires_at > statement_timestamp()
  ORDER BY recovery.deleted_at DESC, board.id;
END;
$$;

CREATE FUNCTION public.admin_list_recovery_owners_p(p_board_id uuid)
RETURNS TABLE (
  user_id uuid,
  email text,
  is_admin boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_owner_id uuid;
  v_has_enabled_successor boolean;
BEGIN
  IF NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'Administrator access required' USING ERRCODE = '42501';
  END IF;

  SELECT board.owner_id INTO v_owner_id
  FROM public.boards AS board
  JOIN public.board_recoverable_deletions AS recovery
    ON recovery.board_id = board.id
  WHERE board.id = p_board_id
    AND recovery.expires_at > statement_timestamp();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board recovery is unavailable' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.board_memberships AS membership
    WHERE membership.board_id = p_board_id
      AND membership.user_id <> v_owner_id
      AND membership.role = 'collaborator'
      AND membership.revoked_at IS NULL
      AND public.is_enabled_application_identity_p(membership.user_id)
  ) INTO v_has_enabled_successor;

  RETURN QUERY
  SELECT access.auth_user_id, access.email, access.is_admin
  FROM public.application_access AS access
  WHERE access.state = 'active'
    AND access.auth_user_id IS NOT NULL
    AND access.google_subject IS NOT NULL
    AND access.auth_user_id <> v_owner_id
    AND (
      NOT v_has_enabled_successor
      OR EXISTS (
        SELECT 1
        FROM public.board_memberships AS membership
        WHERE membership.board_id = p_board_id
          AND membership.user_id = access.auth_user_id
          AND membership.role = 'collaborator'
          AND membership.revoked_at IS NULL
      )
    )
  ORDER BY pg_catalog.lower(access.email), access.auth_user_id;
END;
$$;

CREATE FUNCTION public.restore_board_internal_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_new_owner_id uuid,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_pre_owner_id uuid;
  v_board public.boards%ROWTYPE;
  v_recovery public.board_recoverable_deletions%ROWTYPE;
  v_receipt public.board_departure_operation_receipts%ROWTYPE;
  v_owner_membership_id uuid;
  v_target_membership_id uuid;
  v_owner_is_valid boolean;
  v_has_enabled_successor boolean;
  v_is_admin boolean;
  v_restored_owner_id uuid;
  v_payload_hash bytea;
  v_response jsonb;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
  v_restored_at timestamptz;
BEGIN
  IF p_operation_id IS NULL OR p_board_id IS NULL THEN
    RAISE EXCEPTION 'Board restoration requires an operation and board'
      USING ERRCODE = '22023';
  END IF;
  v_is_admin := public.is_application_admin();
  IF v_actor_id IS NULL OR (NOT public.is_application_user() AND NOT v_is_admin) THEN
    RAISE EXCEPTION 'Board recovery access is required' USING ERRCODE = '42501';
  END IF;

  SELECT board.owner_id INTO v_pre_owner_id
  FROM public.boards AS board
  WHERE board.id = p_board_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  PERFORM access.auth_user_id
  FROM public.application_access AS access
  WHERE access.auth_user_id = ANY (
    ARRAY[v_actor_id, v_pre_owner_id, p_new_owner_id]::uuid[]
  )
  ORDER BY access.auth_user_id
  FOR SHARE;
  v_is_admin := public.is_application_admin();
  IF v_actor_id IS NULL OR (NOT public.is_application_user() AND NOT v_is_admin) THEN
    RAISE EXCEPTION 'Board recovery access is required' USING ERRCODE = '42501';
  END IF;

  v_payload_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'restore_board',
        'board_id', p_board_id,
        'new_owner_id', p_new_owner_id
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  v_response := public.board_departure_operation_result_p(
    v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_board.owner_id IS DISTINCT FROM v_pre_owner_id THEN
    RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;

  v_response := public.board_departure_operation_result_p(
    v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;

  SELECT recovery.* INTO v_recovery
  FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_recovery.expires_at <= v_now THEN
    RETURN jsonb_build_object('status', 'expired', 'operation_id', p_operation_id);
  END IF;

  SELECT membership.id INTO v_owner_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = p_board_id
    AND membership.user_id = v_board.owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR UPDATE;
  v_owner_is_valid := FOUND
    AND public.is_enabled_application_identity_p(v_board.owner_id);

  IF v_owner_is_valid THEN
    IF v_actor_id IS DISTINCT FROM v_board.owner_id OR p_new_owner_id IS NOT NULL THEN
      RAISE EXCEPTION 'Only the current enabled owner can restore this board'
        USING ERRCODE = '42501';
    END IF;
    v_restored_owner_id := v_board.owner_id;
  ELSE
    IF NOT v_is_admin THEN
      RAISE EXCEPTION 'Administrator access is required to choose a new board owner'
        USING ERRCODE = '42501';
    END IF;
    IF p_new_owner_id IS NULL THEN
      RETURN jsonb_build_object('status', 'owner_required', 'operation_id', p_operation_id);
    END IF;
    IF NOT public.is_enabled_application_identity_p(p_new_owner_id) THEN
      RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM public.board_memberships AS membership
      WHERE membership.board_id = p_board_id
        AND membership.user_id <> v_board.owner_id
        AND membership.role = 'collaborator'
        AND membership.revoked_at IS NULL
        AND public.is_enabled_application_identity_p(membership.user_id)
    ) INTO v_has_enabled_successor;
    IF p_new_owner_id = v_board.owner_id
      OR (v_has_enabled_successor AND NOT EXISTS (
        SELECT 1
        FROM public.board_memberships AS membership
        WHERE membership.board_id = p_board_id
          AND membership.user_id = p_new_owner_id
          AND membership.role = 'collaborator'
          AND membership.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(membership.user_id)
      )) THEN
      RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
    END IF;
    v_restored_owner_id := p_new_owner_id;
  END IF;

  INSERT INTO public.board_departure_operation_receipts (
    actor_id, operation_id, action, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_response := public.board_departure_operation_result_p(
      v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash
    );
    IF v_response IS NOT NULL THEN
      RETURN v_response;
    END IF;
    RAISE EXCEPTION 'The board restoration result could not be reconciled'
      USING ERRCODE = '40001';
  END IF;

  v_restored_at := v_now;
  IF v_restored_owner_id IS DISTINCT FROM v_board.owner_id THEN
    UPDATE public.board_memberships AS membership
    SET revoked_at = v_restored_at
    WHERE membership.board_id = p_board_id
      AND membership.role = 'owner'
      AND membership.revoked_at IS NULL;

    SELECT membership.id INTO v_target_membership_id
    FROM public.board_memberships AS membership
    WHERE membership.board_id = p_board_id
      AND membership.user_id = v_restored_owner_id
      AND membership.revoked_at IS NULL
    FOR UPDATE;
    IF FOUND THEN
      UPDATE public.board_memberships AS membership
      SET role = 'owner'
      WHERE membership.id = v_target_membership_id;
    ELSE
      INSERT INTO public.board_memberships (board_id, user_id, role)
      VALUES (p_board_id, v_restored_owner_id, 'owner');
    END IF;

    UPDATE public.boards AS board
    SET owner_id = v_restored_owner_id,
        updated_at = v_restored_at
    WHERE board.id = p_board_id;
  END IF;

  DELETE FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = p_board_id;

  UPDATE public.board_departure_operation_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'owner_id', v_restored_owner_id,
    'expires_at', v_recovery.expires_at
  );
END;
$$;

CREATE FUNCTION public.restore_board_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_new_owner_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.restore_board_internal_p(
    p_operation_id, p_board_id, p_new_owner_id, NULL
  );
$$;

CREATE FUNCTION public.purge_expired_board_internal_p(
  p_board_id uuid,
  p_now timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_recovery public.board_recoverable_deletions%ROWTYPE;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
BEGIN
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN RETURN 'already_terminal'; END IF;

  SELECT recovery.* INTO v_recovery
  FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN RETURN 'already_terminal'; END IF;
  IF v_now < v_recovery.expires_at THEN RETURN 'too_early'; END IF;

  DELETE FROM public.task_checklist_receipts WHERE board_id = p_board_id;
  DELETE FROM public.task_checklist_deletions WHERE board_id = p_board_id;
  DELETE FROM public.task_comment_receipts WHERE board_id = p_board_id;
  DELETE FROM public.task_recovery_receipts WHERE board_id = p_board_id;
  DELETE FROM public.task_deletions WHERE board_id = p_board_id;
  DELETE FROM public.column_recovery_receipts WHERE board_id = p_board_id;
  DELETE FROM public.column_deletions WHERE board_id = p_board_id;
  DELETE FROM public.task_capture_receipts WHERE board_id = p_board_id;
  DELETE FROM public.task_edit_receipts WHERE board_id = p_board_id;
  DELETE FROM public.task_order_receipts WHERE board_id = p_board_id;
  DELETE FROM public.task_completion_receipts WHERE board_id = p_board_id;
  DELETE FROM public.task_assignee_receipts WHERE board_id = p_board_id;
  DELETE FROM public.board_invitation_operation_receipts WHERE board_id = p_board_id;

  DELETE FROM public.boards WHERE id = p_board_id;
  RETURN 'purged';
END;
$$;

CREATE FUNCTION public.purge_expired_boards_p(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_purged integer := 0;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'Choose a purge limit from 1 to 1000' USING ERRCODE = '22023';
  END IF;

  FOR v_board_id IN
    SELECT board.id
    FROM public.boards AS board
    JOIN public.board_recoverable_deletions AS recovery
      ON recovery.board_id = board.id
    WHERE recovery.expires_at <= clock_timestamp()
    ORDER BY recovery.expires_at, board.id
    LIMIT p_limit
    FOR UPDATE OF board SKIP LOCKED
  LOOP
    IF public.purge_expired_board_internal_p(v_board_id, NULL) = 'purged' THEN
      v_purged := v_purged + 1;
    END IF;
  END LOOP;
  RETURN v_purged;
END;
$$;

CREATE OR REPLACE FUNCTION public.board_invitation_issuer_is_current_owner(
  p_board_id uuid,
  p_inviter_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT NOT EXISTS (
      SELECT 1
      FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = p_board_id
    )
    AND EXISTS (
      SELECT 1
      FROM public.boards AS board
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
      JOIN public.application_access AS access
        ON access.auth_user_id = membership.user_id
      WHERE board.id = p_board_id
        AND board.owner_id = p_inviter_id
        AND membership.user_id = p_inviter_id
        AND membership.role = 'owner'
        AND membership.revoked_at IS NULL
        AND access.state = 'active'
    );
$$;

CREATE OR REPLACE FUNCTION public.get_board_creation_result_p(p_operation_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.slug
  FROM public.board_creation_requests AS request
  JOIN public.boards AS board ON board.id = request.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
  WHERE request.user_id = auth.uid()
    AND request.operation_id = p_operation_id
    AND board.owner_id = auth.uid()
    AND membership.user_id = auth.uid()
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
    AND public.is_application_user()
    AND public.is_board_member(board.id)
  LIMIT 1;
$$;

-- These invitation RPCs predate board recovery and authorize from raw owner rows.
-- Keep those implementations private behind wrappers that enforce the active-board gate.
ALTER FUNCTION public.create_direct_board_invitation_p(text, text)
  RENAME TO create_direct_board_invitation_internal_p;
REVOKE ALL ON FUNCTION public.create_direct_board_invitation_internal_p(text, text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.create_direct_board_invitation_p(p_slug text, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND OR NOT public.is_board_owner(v_board_id) THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.create_direct_board_invitation_internal_p(p_slug, p_email);
END;
$$;
REVOKE ALL ON FUNCTION public.create_direct_board_invitation_p(text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_direct_board_invitation_p(text, text)
  TO authenticated;

ALTER FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  RENAME TO create_board_invitation_link_internal_p;
REVOKE ALL ON FUNCTION public.create_board_invitation_link_internal_p(text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.create_board_invitation_link_p(
  p_slug text,
  p_operation_id uuid,
  p_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND OR NOT public.is_board_owner(v_board_id) THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.create_board_invitation_link_internal_p(
    p_slug, p_operation_id, p_token
  );
END;
$$;
REVOKE ALL ON FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  TO authenticated;

ALTER FUNCTION public.list_board_invitations_p(text)
  RENAME TO list_board_invitations_internal_p;
REVOKE ALL ON FUNCTION public.list_board_invitations_internal_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.list_board_invitations_p(p_slug text)
RETURNS TABLE (
  id uuid,
  invitation_type text,
  recipient_email text,
  expires_at timestamptz,
  invitation_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND OR NOT public.is_board_owner(v_board_id) THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT * FROM public.list_board_invitations_internal_p(p_slug);
END;
$$;
REVOKE ALL ON FUNCTION public.list_board_invitations_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_board_invitations_p(text)
  TO authenticated;

ALTER FUNCTION public.revoke_board_invitation_p(uuid)
  RENAME TO revoke_board_invitation_internal_p;
REVOKE ALL ON FUNCTION public.revoke_board_invitation_internal_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.revoke_board_invitation_p(p_invitation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id;
  IF NOT FOUND THEN RETURN false; END IF;
  IF NOT public.is_board_owner(v_board_id) THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.revoke_board_invitation_internal_p(p_invitation_id);
END;
$$;
REVOKE ALL ON FUNCTION public.revoke_board_invitation_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_board_invitation_p(uuid)
  TO authenticated;

ALTER FUNCTION public.renew_board_invitation_p(uuid, uuid, text)
  RENAME TO renew_board_invitation_internal_p;
REVOKE ALL ON FUNCTION public.renew_board_invitation_internal_p(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.renew_board_invitation_p(
  p_invitation_id uuid,
  p_operation_id uuid,
  p_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF NOT public.is_board_owner(v_board_id) THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.renew_board_invitation_internal_p(
    p_invitation_id, p_operation_id, p_token
  );
END;
$$;
REVOKE ALL ON FUNCTION public.renew_board_invitation_p(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.renew_board_invitation_p(uuid, uuid, text)
  TO authenticated;

REVOKE ALL ON FUNCTION public.delete_board_p(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_board_p(uuid, text, uuid)
  TO authenticated;
REVOKE ALL ON FUNCTION public.list_my_recoverable_boards_p()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_recoverable_boards_p()
  TO authenticated;
REVOKE ALL ON FUNCTION public.admin_list_recoverable_boards_p()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_recoverable_boards_p()
  TO authenticated;
REVOKE ALL ON FUNCTION public.admin_list_recovery_owners_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_recovery_owners_p(uuid)
  TO authenticated;
REVOKE ALL ON FUNCTION public.restore_board_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restore_board_p(uuid, uuid, uuid)
  TO authenticated;
REVOKE ALL ON FUNCTION public.restore_board_internal_p(uuid, uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_board_internal_p(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_boards_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.purge_expired_boards_p(integer)
  TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
