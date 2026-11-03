-- Invitation commands reconcile a lost response by actor, operation id, and
-- payload. Bearer tokens stay client-held; receipts persist only their hashes.
BEGIN;

CREATE TABLE public.board_invitation_operation_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  command text NOT NULL CHECK (
    command IN ('create_link', 'renew', 'accept_link', 'accept_direct')
  ),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  invitation_id uuid REFERENCES public.board_invitations(id) ON DELETE CASCADE,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_status text NOT NULL CHECK (
    result_status IN (
      'pending', 'created', 'renewed', 'not_expired', 'accepted', 'already_member'
    )
  ),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id),
  CONSTRAINT board_invitation_receipt_invitation_shape CHECK (
    (result_status = 'pending' AND invitation_id IS NULL)
    OR (result_status <> 'pending' AND invitation_id IS NOT NULL)
  )
);

ALTER TABLE public.board_invitation_operation_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_invitation_operation_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.board_invitation_operation_hash_p(p_payload jsonb)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, extensions, pg_temp
AS $$
  SELECT extensions.digest(
    pg_catalog.convert_to(p_payload::text, 'UTF8'),
    'sha256'
  );
$$;

CREATE OR REPLACE FUNCTION public.lock_board_invitation_operation_p(
  p_actor_id uuid,
  p_operation_id uuid,
  p_command text,
  p_board_id uuid,
  p_payload_hash bytea
)
RETURNS public.board_invitation_operation_receipts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_receipt public.board_invitation_operation_receipts%ROWTYPE;
BEGIN
  SELECT receipt.* INTO v_receipt
  FROM public.board_invitation_operation_receipts AS receipt
  WHERE receipt.actor_id = p_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF v_receipt.command IS DISTINCT FROM p_command
    OR (p_board_id IS NOT NULL AND v_receipt.board_id IS DISTINCT FROM p_board_id)
    OR v_receipt.payload_hash IS DISTINCT FROM p_payload_hash THEN
    RAISE EXCEPTION 'Invitation operation key was already used'
      USING ERRCODE = '23514';
  END IF;
  RETURN v_receipt;
END;
$$;

REVOKE ALL ON FUNCTION public.create_board_invitation_link_p(text)
  FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.create_board_invitation_link_p(text);
REVOKE ALL ON FUNCTION public.accept_board_invitation_link_p(text)
  FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.accept_board_invitation_link_p(text);
REVOKE ALL ON FUNCTION public.accept_direct_board_invitation_p(uuid)
  FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.accept_direct_board_invitation_p(uuid);
REVOKE ALL ON FUNCTION public.renew_board_invitation_p(uuid)
  FROM PUBLIC, anon, authenticated;
DROP FUNCTION public.renew_board_invitation_p(uuid);

CREATE FUNCTION public.create_board_invitation_link_p(
  p_slug text,
  p_operation_id uuid,
  p_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
  v_token_hash bytea;
  v_payload_hash bytea;
  v_receipt public.board_invitation_operation_receipts%ROWTYPE;
  v_invitation public.board_invitations%ROWTYPE;
BEGIN
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'An invitation operation id is required'
      USING ERRCODE = '22023';
  END IF;
  PERFORM public.assert_board_invitation_actor();
  v_token_hash := public.board_invitation_token_hash(p_token);

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR v_board.owner_id <> v_actor_id THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  v_payload_hash := public.board_invitation_operation_hash_p(jsonb_build_object(
    'command', 'create_link',
    'board_id', v_board.id,
    'token_hash', pg_catalog.encode(v_token_hash, 'hex')
  ));
  v_receipt := public.lock_board_invitation_operation_p(
    v_actor_id, p_operation_id, 'create_link', v_board.id, v_payload_hash
  );
  IF v_receipt.actor_id IS NOT NULL THEN
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable');
    END IF;
    SELECT invitation.* INTO v_invitation
    FROM public.board_invitations AS invitation
    WHERE invitation.id = v_receipt.invitation_id
      AND invitation.board_id = v_board.id
      AND invitation.invitation_type = 'generic'
    FOR SHARE;
    IF NOT FOUND
      OR v_invitation.status <> 'pending'
      OR v_invitation.expires_at <= clock_timestamp()
      OR v_invitation.token_hash IS DISTINCT FROM v_token_hash
      OR NOT public.board_invitation_issuer_is_current_owner(
        v_board.id, v_invitation.inviter_id
      ) THEN
      RETURN jsonb_build_object('status', 'unavailable');
    END IF;
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'id', v_invitation.id,
      'token', p_token,
      'expires_at', v_invitation.expires_at,
      'role', 'collaborator'
    );
  END IF;

  INSERT INTO public.board_invitation_operation_receipts(
    actor_id, operation_id, command, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'create_link', v_board.id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_receipt := public.lock_board_invitation_operation_p(
      v_actor_id, p_operation_id, 'create_link', v_board.id, v_payload_hash
    );
    IF v_receipt.actor_id IS NULL THEN
      RETURN jsonb_build_object('status', 'retryable');
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    SELECT invitation.* INTO v_invitation
    FROM public.board_invitations AS invitation
    WHERE invitation.id = v_receipt.invitation_id
      AND invitation.board_id = v_board.id
      AND invitation.invitation_type = 'generic'
    FOR SHARE;
    IF NOT FOUND
      OR v_invitation.status <> 'pending'
      OR v_invitation.expires_at <= clock_timestamp()
      OR v_invitation.token_hash IS DISTINCT FROM v_token_hash
      OR NOT public.board_invitation_issuer_is_current_owner(
        v_board.id, v_invitation.inviter_id
      ) THEN
      RETURN jsonb_build_object('status', 'unavailable');
    END IF;
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'id', v_invitation.id,
      'token', p_token,
      'expires_at', v_invitation.expires_at,
      'role', 'collaborator'
    );
  END IF;

  INSERT INTO public.board_invitations(
    board_id, inviter_id, invitation_type, token_hash
  ) VALUES (
    v_board.id, v_actor_id, 'generic', v_token_hash
  ) RETURNING * INTO v_invitation;
  UPDATE public.board_invitation_operation_receipts AS receipt
  SET invitation_id = v_invitation.id,
      result_status = 'created'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'created',
    'id', v_invitation.id,
    'token', p_token,
    'expires_at', v_invitation.expires_at,
    'role', 'collaborator'
  );
END;
$$;

CREATE FUNCTION public.accept_board_invitation_link_p(
  p_token text,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_token_hash bytea;
  v_payload_hash bytea;
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_invitation public.board_invitations%ROWTYPE;
  v_membership_id uuid;
  v_receipt public.board_invitation_operation_receipts%ROWTYPE;
  v_result_status text;
BEGIN
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'An invitation operation id is required'
      USING ERRCODE = '22023';
  END IF;
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM public.assert_board_invitation_actor();
  BEGIN
    v_token_hash := public.board_invitation_token_hash(p_token);
  EXCEPTION WHEN invalid_parameter_value THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END;
  v_payload_hash := public.board_invitation_operation_hash_p(jsonb_build_object(
    'command', 'accept_link',
    'token_hash', pg_catalog.encode(v_token_hash, 'hex')
  ));

  v_receipt := public.lock_board_invitation_operation_p(
    v_actor_id, p_operation_id, 'accept_link', NULL, v_payload_hash
  );
  IF v_receipt.actor_id IS NOT NULL THEN
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    SELECT board.* INTO v_board
    FROM public.boards AS board
    WHERE board.id = v_receipt.board_id
    FOR UPDATE;
    IF NOT FOUND THEN
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
    IF v_receipt.result_status NOT IN ('accepted', 'already_member') THEN
      RETURN jsonb_build_object('status', 'retryable');
    END IF;
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'board_slug', v_board.slug
    );
  END IF;

  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.token_hash = v_token_hash
    AND invitation.invitation_type = 'generic';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_receipt := public.lock_board_invitation_operation_p(
    v_actor_id, p_operation_id, 'accept_link', v_board.id, v_payload_hash
  );
  IF v_receipt.actor_id IS NOT NULL THEN
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
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
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'board_slug', v_board.slug
    );
  END IF;

  SELECT invitation.* INTO v_invitation
  FROM public.board_invitations AS invitation
  WHERE invitation.token_hash = v_token_hash
    AND invitation.invitation_type = 'generic'
    AND invitation.board_id = v_board.id
  FOR UPDATE;
  IF NOT FOUND
    OR v_invitation.status <> 'pending'
    OR v_invitation.expires_at <= clock_timestamp()
    OR NOT public.board_invitation_issuer_is_current_owner(
      v_board.id, v_invitation.inviter_id
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR UPDATE;
  v_result_status := CASE WHEN FOUND THEN 'already_member' ELSE 'accepted' END;

  INSERT INTO public.board_invitation_operation_receipts(
    actor_id, operation_id, command, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'accept_link', v_board.id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_receipt := public.lock_board_invitation_operation_p(
      v_actor_id, p_operation_id, 'accept_link', v_board.id, v_payload_hash
    );
    IF v_receipt.actor_id IS NULL THEN
      RETURN jsonb_build_object('status', 'retryable');
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
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'board_slug', v_board.slug
    );
  END IF;

  IF v_result_status = 'accepted' THEN
    INSERT INTO public.board_memberships(board_id, user_id, role)
    VALUES (v_board.id, v_actor_id, 'collaborator')
    ON CONFLICT (board_id, user_id) WHERE revoked_at IS NULL DO NOTHING
    RETURNING id INTO v_membership_id;
    IF NOT FOUND THEN
      v_result_status := 'already_member';
    ELSE
      UPDATE public.board_invitations AS invitation
      SET status = 'accepted',
          consumed_at = clock_timestamp(),
          accepted_by = v_actor_id
      WHERE invitation.id = v_invitation.id;
    END IF;
  END IF;

  UPDATE public.board_invitation_operation_receipts AS receipt
  SET invitation_id = v_invitation.id,
      result_status = v_result_status
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', v_result_status,
    'board_slug', v_board.slug
  );
END;
$$;

CREATE FUNCTION public.accept_direct_board_invitation_p(
  p_invitation_id uuid,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_payload_hash bytea;
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_invitation public.board_invitations%ROWTYPE;
  v_membership_id uuid;
  v_receipt public.board_invitation_operation_receipts%ROWTYPE;
  v_result_status text;
BEGIN
  IF p_operation_id IS NULL OR p_invitation_id IS NULL THEN
    RAISE EXCEPTION 'An invitation and operation id are required'
      USING ERRCODE = '22023';
  END IF;
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM public.assert_board_invitation_actor();
  v_payload_hash := public.board_invitation_operation_hash_p(jsonb_build_object(
    'command', 'accept_direct',
    'invitation_id', p_invitation_id
  ));

  v_receipt := public.lock_board_invitation_operation_p(
    v_actor_id, p_operation_id, 'accept_direct', NULL, v_payload_hash
  );
  IF v_receipt.actor_id IS NOT NULL THEN
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    SELECT board.* INTO v_board
    FROM public.boards AS board
    WHERE board.id = v_receipt.board_id
    FOR UPDATE;
    IF NOT FOUND THEN
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
    IF v_receipt.result_status NOT IN ('accepted', 'already_member') THEN
      RETURN jsonb_build_object('status', 'retryable');
    END IF;
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'board_slug', v_board.slug
    );
  END IF;

  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id
    AND invitation.invitation_type = 'direct'
    AND invitation.recipient_id = v_actor_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_receipt := public.lock_board_invitation_operation_p(
    v_actor_id, p_operation_id, 'accept_direct', v_board.id, v_payload_hash
  );
  IF v_receipt.actor_id IS NOT NULL THEN
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
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
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'board_slug', v_board.slug
    );
  END IF;

  SELECT invitation.* INTO v_invitation
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id
    AND invitation.invitation_type = 'direct'
    AND invitation.recipient_id = v_actor_id
    AND invitation.board_id = v_board.id
  FOR UPDATE;
  IF NOT FOUND
    OR v_invitation.status <> 'pending'
    OR v_invitation.expires_at <= clock_timestamp()
    OR NOT public.board_invitation_issuer_is_current_owner(
      v_board.id, v_invitation.inviter_id
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR UPDATE;
  v_result_status := CASE WHEN FOUND THEN 'already_member' ELSE 'accepted' END;

  INSERT INTO public.board_invitation_operation_receipts(
    actor_id, operation_id, command, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'accept_direct', v_board.id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_receipt := public.lock_board_invitation_operation_p(
      v_actor_id, p_operation_id, 'accept_direct', v_board.id, v_payload_hash
    );
    IF v_receipt.actor_id IS NULL THEN
      RETURN jsonb_build_object('status', 'retryable');
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
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'board_slug', v_board.slug
    );
  END IF;

  IF v_result_status = 'accepted' THEN
    INSERT INTO public.board_memberships(board_id, user_id, role)
    VALUES (v_board.id, v_actor_id, 'collaborator')
    ON CONFLICT (board_id, user_id) WHERE revoked_at IS NULL DO NOTHING
    RETURNING id INTO v_membership_id;
    IF NOT FOUND THEN
      v_result_status := 'already_member';
    ELSE
      UPDATE public.board_invitations AS invitation
      SET status = 'accepted',
          consumed_at = clock_timestamp(),
          accepted_by = v_actor_id
      WHERE invitation.id = v_invitation.id;
    END IF;
  END IF;

  UPDATE public.board_invitation_operation_receipts AS receipt
  SET invitation_id = v_invitation.id,
      result_status = v_result_status
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', v_result_status,
    'board_slug', v_board.slug
  );
END;
$$;

CREATE FUNCTION public.renew_board_invitation_p(
  p_invitation_id uuid,
  p_operation_id uuid,
  p_token text
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
  v_invitation public.board_invitations%ROWTYPE;
  v_membership_id uuid;
  v_token_hash bytea;
  v_token_payload_hash text;
  v_payload_hash bytea;
  v_receipt public.board_invitation_operation_receipts%ROWTYPE;
BEGIN
  IF p_operation_id IS NULL OR p_invitation_id IS NULL THEN
    RAISE EXCEPTION 'An invitation and operation id are required'
      USING ERRCODE = '22023';
  END IF;
  PERFORM public.assert_board_invitation_actor();
  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR v_board.owner_id <> v_actor_id THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  SELECT invitation.* INTO v_invitation
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id
    AND invitation.board_id = v_board.id
  FOR UPDATE;
  IF NOT FOUND OR v_invitation.status <> 'pending'
    OR NOT public.board_invitation_issuer_is_current_owner(
      v_board.id, v_invitation.inviter_id
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  IF v_invitation.invitation_type = 'generic' THEN
    v_token_hash := public.board_invitation_token_hash(p_token);
    v_token_payload_hash := pg_catalog.encode(v_token_hash, 'hex');
  ELSE
    IF p_token IS NOT NULL THEN
      RAISE EXCEPTION 'Direct invitation renewal does not accept a token'
        USING ERRCODE = '22023';
    END IF;
    v_token_hash := NULL;
    v_token_payload_hash := NULL;
  END IF;
  v_payload_hash := public.board_invitation_operation_hash_p(jsonb_build_object(
    'command', 'renew',
    'board_id', v_board.id,
    'invitation_id', v_invitation.id,
    'token_hash', v_token_payload_hash
  ));

  v_receipt := public.lock_board_invitation_operation_p(
    v_actor_id, p_operation_id, 'renew', v_board.id, v_payload_hash
  );
  IF v_receipt.actor_id IS NOT NULL THEN
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    IF v_receipt.result_status = 'not_expired' THEN
      RETURN jsonb_build_object('status', 'not_expired');
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable');
    END IF;
    IF v_invitation.expires_at <= clock_timestamp()
      OR (v_invitation.invitation_type = 'generic'
        AND v_invitation.token_hash IS DISTINCT FROM v_token_hash) THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    IF v_receipt.result_status <> 'renewed' THEN
      RETURN jsonb_build_object('status', 'unavailable');
    END IF;
    IF v_invitation.invitation_type = 'generic' THEN
      RETURN jsonb_build_object(
        'status', 'renewed',
        'id', v_invitation.id,
        'token', p_token,
        'expires_at', v_invitation.expires_at,
        'role', 'collaborator'
      );
    END IF;
    RETURN jsonb_build_object(
      'status', 'renewed',
      'id', v_invitation.id,
      'expires_at', v_invitation.expires_at
    );
  END IF;

  INSERT INTO public.board_invitation_operation_receipts(
    actor_id, operation_id, command, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'renew', v_board.id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_receipt := public.lock_board_invitation_operation_p(
      v_actor_id, p_operation_id, 'renew', v_board.id, v_payload_hash
    );
    IF v_receipt.actor_id IS NULL THEN
      RETURN jsonb_build_object('status', 'retryable');
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    IF v_receipt.result_status = 'not_expired' THEN
      RETURN jsonb_build_object('status', 'not_expired');
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable');
    END IF;
    IF v_invitation.expires_at <= clock_timestamp()
      OR (v_invitation.invitation_type = 'generic'
        AND v_invitation.token_hash IS DISTINCT FROM v_token_hash) THEN
      RETURN jsonb_build_object('status', 'expired_unknown');
    END IF;
    IF v_invitation.invitation_type = 'generic' THEN
      RETURN jsonb_build_object(
        'status', 'renewed',
        'id', v_invitation.id,
        'token', p_token,
        'expires_at', v_invitation.expires_at,
        'role', 'collaborator'
      );
    END IF;
    RETURN jsonb_build_object(
      'status', 'renewed',
      'id', v_invitation.id,
      'expires_at', v_invitation.expires_at
    );
  END IF;

  IF v_invitation.expires_at > clock_timestamp() THEN
    UPDATE public.board_invitation_operation_receipts AS receipt
    SET invitation_id = v_invitation.id,
        result_status = 'not_expired'
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'not_expired');
  END IF;

  IF v_invitation.invitation_type = 'generic' THEN
    UPDATE public.board_invitations AS invitation
    SET token_hash = v_token_hash,
        expires_at = clock_timestamp() + interval '72 hours'
    WHERE invitation.id = v_invitation.id
    RETURNING * INTO v_invitation;
  ELSE
    UPDATE public.board_invitations AS invitation
    SET expires_at = clock_timestamp() + interval '72 hours'
    WHERE invitation.id = v_invitation.id
    RETURNING * INTO v_invitation;
  END IF;

  UPDATE public.board_invitation_operation_receipts AS receipt
  SET invitation_id = v_invitation.id,
      result_status = 'renewed'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  IF v_invitation.invitation_type = 'generic' THEN
    RETURN jsonb_build_object(
      'status', 'renewed',
      'id', v_invitation.id,
      'token', p_token,
      'expires_at', v_invitation.expires_at,
      'role', 'collaborator'
    );
  END IF;
  RETURN jsonb_build_object(
    'status', 'renewed',
    'id', v_invitation.id,
    'expires_at', v_invitation.expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.board_invitation_operation_hash_p(jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.lock_board_invitation_operation_p(uuid, uuid, text, uuid, bytea)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_board_invitation_link_p(text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_direct_board_invitation_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.renew_board_invitation_p(uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_board_invitation_link_p(text, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_direct_board_invitation_p(uuid, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.renew_board_invitation_p(uuid, uuid, text)
  TO authenticated;

COMMIT;
