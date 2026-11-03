BEGIN;

ALTER TABLE public.board_departure_operation_receipts
  DROP CONSTRAINT board_departure_operation_receipts_action_check,
  ADD CONSTRAINT board_departure_operation_receipts_action_check
    CHECK (action IN ('leave', 'delete_last_member', 'remove_collaborator'));

CREATE FUNCTION public.list_board_members_p(p_slug text)
RETURNS TABLE (
  membership_id uuid,
  user_id uuid,
  name text,
  role text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT
    membership.id,
    membership.user_id,
    coalesce(nullif(btrim(identity.identity_data->>'name'), ''), auth_user.email),
    membership.role
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.revoked_at IS NULL
  JOIN auth.users AS auth_user ON auth_user.id = membership.user_id
  JOIN public.application_access AS access
    ON access.auth_user_id = membership.user_id
    AND access.email = lower(auth_user.email)
  JOIN auth.identities AS identity
    ON identity.user_id = auth_user.id
    AND identity.provider = 'google'
    AND identity.provider_id = access.google_subject
    AND lower(identity.identity_data->>'email') = lower(auth_user.email)
    AND coalesce((identity.identity_data->>'email_verified')::boolean, false)
  WHERE board.slug = p_slug
    AND public.is_application_user()
    AND public.is_board_member(board.id)
  ORDER BY (membership.role = 'owner') DESC, lower(auth_user.email), membership.user_id;
$$;
REVOKE ALL ON FUNCTION public.list_board_members_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_board_members_p(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.prepare_board_member_departure_p(
  p_board_id uuid,
  p_member_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_board_id IS NULL OR p_member_id IS NULL
    OR NOT public.is_application_user()
    OR NOT (
      (
        p_member_id = auth.uid()
        AND public.is_board_member(p_board_id)
      )
      OR (
        public.is_board_owner(p_board_id)
        AND EXISTS (
          SELECT 1
          FROM public.board_memberships AS membership
          WHERE membership.board_id = p_board_id
            AND membership.user_id = p_member_id
            AND membership.role = 'collaborator'
            AND membership.revoked_at IS NULL
        )
      )
    ) THEN
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

CREATE FUNCTION public.remove_board_collaborator_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_membership_id uuid
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
  v_target_membership public.board_memberships%ROWTYPE;
  v_receipt public.board_departure_operation_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_response jsonb;
BEGIN
  IF p_operation_id IS NULL OR p_board_id IS NULL OR p_membership_id IS NULL THEN
    RAISE EXCEPTION 'A collaborator removal requires an operation and member episode'
      USING ERRCODE = '22023';
  END IF;
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  v_payload_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'remove_collaborator',
        'board_id', p_board_id,
        'membership_id', p_membership_id
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  v_response := public.board_departure_operation_result_p(
    v_actor_id,
    p_operation_id,
    'remove_collaborator',
    p_board_id,
    v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;
  IF NOT public.is_board_owner(p_board_id) THEN
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
    'remove_collaborator',
    p_board_id,
    v_payload_hash
  );
  IF v_response IS NOT NULL THEN
    RETURN v_response;
  END IF;
  IF NOT public.is_board_owner(p_board_id) THEN
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
    v_actor_id, p_operation_id, 'remove_collaborator', p_board_id,
    v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_response := public.board_departure_operation_result_p(
      v_actor_id,
      p_operation_id,
      'remove_collaborator',
      p_board_id,
      v_payload_hash
    );
    IF v_response IS NOT NULL THEN
      RETURN v_response;
    END IF;
    RAISE EXCEPTION 'The collaborator removal result could not be reconciled'
      USING ERRCODE = '40001';
  END IF;

  SELECT membership.* INTO v_target_membership
  FROM public.board_memberships AS membership
  WHERE membership.id = p_membership_id
    AND membership.board_id = p_board_id
  FOR UPDATE;
  IF NOT FOUND
    OR v_target_membership.revoked_at IS NOT NULL
    OR v_target_membership.role <> 'collaborator' THEN
    UPDATE public.board_departure_operation_receipts AS receipt
    SET result_status = 'conflict'
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;

  PERFORM public.prepare_board_member_departure_p(
    p_board_id,
    v_target_membership.user_id
  );

  UPDATE public.board_memberships AS membership
  SET revoked_at = clock_timestamp()
  WHERE membership.id = v_target_membership.id
    AND membership.revoked_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The collaborator membership changed during removal'
      USING ERRCODE = '40001';
  END IF;

  UPDATE public.board_departure_operation_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object('status', 'confirmed', 'operation_id', p_operation_id);
END;
$$;
REVOKE ALL ON FUNCTION public.remove_board_collaborator_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.remove_board_collaborator_p(uuid, uuid, uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
