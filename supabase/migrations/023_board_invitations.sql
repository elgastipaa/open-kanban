-- Board invitations are private authorization records. Callers can only use
-- the narrow RPCs below; invitation tokens are stored as SHA-256 digests.
BEGIN;

CREATE TABLE public.board_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  inviter_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  invitation_type text NOT NULL CHECK (invitation_type IN ('direct', 'generic')),
  recipient_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash bytea CHECK (token_hash IS NULL OR octet_length(token_hash) = 32),
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'rejected', 'revoked')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '72 hours'),
  consumed_at timestamptz,
  accepted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT board_invitations_recipient_shape CHECK (
    (invitation_type = 'direct' AND recipient_id IS NOT NULL AND token_hash IS NULL)
    OR (invitation_type = 'generic' AND recipient_id IS NULL AND token_hash IS NOT NULL)
  ),
  CONSTRAINT board_invitations_acceptance_shape CHECK (
    (status = 'accepted') = (consumed_at IS NOT NULL)
    AND (status = 'accepted') = (accepted_by IS NOT NULL)
  ),
  CONSTRAINT board_invitations_expiry_after_creation CHECK (expires_at > created_at)
);
CREATE UNIQUE INDEX board_invitations_one_pending_direct
  ON public.board_invitations(board_id, recipient_id)
  WHERE invitation_type = 'direct' AND status = 'pending';
CREATE UNIQUE INDEX board_invitations_unique_token_hash
  ON public.board_invitations(token_hash)
  WHERE token_hash IS NOT NULL;
CREATE INDEX board_invitations_board_recent
  ON public.board_invitations(board_id, created_at DESC);
CREATE INDEX board_invitations_recipient_pending
  ON public.board_invitations(recipient_id, expires_at)
  WHERE invitation_type = 'direct' AND status = 'pending';

ALTER TABLE public.board_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_invitations
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.assert_board_invitation_actor()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_locked_actor uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;

  SELECT access.auth_user_id INTO v_locked_actor
  FROM public.application_access AS access
  WHERE access.auth_user_id = v_actor_id
    AND access.state = 'active'
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
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
  SELECT EXISTS (
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

CREATE OR REPLACE FUNCTION public.board_invitation_token_hash(p_token text)
RETURNS bytea
LANGUAGE plpgsql
IMMUTABLE
SECURITY DEFINER
SET search_path = pg_catalog, extensions, pg_temp
AS $$
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Invitation is unavailable' USING ERRCODE = '22023';
  END IF;
  RETURN extensions.digest(pg_catalog.convert_to(p_token, 'UTF8'), 'sha256');
END;
$$;

CREATE OR REPLACE FUNCTION public.create_direct_board_invitation_p(
  p_slug text,
  p_email text
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
  v_recipient_id uuid;
  v_email text := pg_catalog.lower(pg_catalog.btrim(p_email));
  v_invitation public.board_invitations%ROWTYPE;
BEGIN
  PERFORM public.assert_board_invitation_actor();
  IF v_email IS NULL OR pg_catalog.length(v_email) > 254
    OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Enter the exact email of an enabled person'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
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

  SELECT access.auth_user_id INTO v_recipient_id
  FROM public.application_access AS access
  WHERE access.email = v_email
    AND access.state = 'active'
    AND access.auth_user_id IS NOT NULL
    AND access.google_subject IS NOT NULL
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The invited person is not available' USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.board_id = v_board.id
      AND membership.user_id = v_recipient_id
      AND membership.revoked_at IS NULL
  ) THEN
    RETURN jsonb_build_object('status', 'already_member');
  END IF;

  SELECT invitation.* INTO v_invitation
  FROM public.board_invitations AS invitation
  WHERE invitation.board_id = v_board.id
    AND invitation.invitation_type = 'direct'
    AND invitation.recipient_id = v_recipient_id
    AND invitation.status = 'pending'
  FOR UPDATE;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', CASE
        WHEN v_invitation.expires_at <= clock_timestamp() THEN 'expired'
        ELSE 'existing'
      END,
      'id', v_invitation.id,
      'expires_at', v_invitation.expires_at
    );
  END IF;

  INSERT INTO public.board_invitations(
    board_id, inviter_id, invitation_type, recipient_id
  ) VALUES (
    v_board.id, v_actor_id, 'direct', v_recipient_id
  ) RETURNING * INTO v_invitation;

  RETURN jsonb_build_object(
    'status', 'created',
    'id', v_invitation.id,
    'expires_at', v_invitation.expires_at
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.create_board_invitation_link_p(p_slug text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
  v_token text := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
  v_invitation public.board_invitations%ROWTYPE;
BEGIN
  PERFORM public.assert_board_invitation_actor();
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

  INSERT INTO public.board_invitations(
    board_id, inviter_id, invitation_type, token_hash
  ) VALUES (
    v_board.id,
    v_actor_id,
    'generic',
    extensions.digest(pg_catalog.convert_to(v_token, 'UTF8'), 'sha256')
  ) RETURNING * INTO v_invitation;

  RETURN jsonb_build_object(
    'status', 'created',
    'id', v_invitation.id,
    'token', v_token,
    'expires_at', v_invitation.expires_at,
    'role', 'collaborator'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_board_invitations_p(p_slug text)
RETURNS TABLE(
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
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
BEGIN
  PERFORM public.assert_board_invitation_actor();
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = auth.uid()
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR v_board.owner_id <> auth.uid() THEN
    RAISE EXCEPTION 'Board owner access is required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT invitation.id,
      invitation.invitation_type,
      access.email,
      invitation.expires_at,
      CASE
        WHEN invitation.status = 'pending'
          AND invitation.expires_at <= clock_timestamp() THEN 'expired'
        ELSE invitation.status
      END
    FROM public.board_invitations AS invitation
    LEFT JOIN public.application_access AS access
      ON access.auth_user_id = invitation.recipient_id
    WHERE invitation.board_id = v_board.id
      AND invitation.status IN ('pending', 'revoked')
    ORDER BY invitation.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_my_pending_board_invitations_p()
RETURNS TABLE(
  id uuid,
  board_name text,
  inviter_email text,
  expires_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN;
  END IF;
  PERFORM public.assert_board_invitation_actor();

  RETURN QUERY
    SELECT invitation.id, board.name, inviter_access.email, invitation.expires_at
    FROM public.board_invitations AS invitation
    JOIN public.boards AS board ON board.id = invitation.board_id
    JOIN public.application_access AS inviter_access
      ON inviter_access.auth_user_id = invitation.inviter_id
      AND inviter_access.state = 'active'
    WHERE invitation.invitation_type = 'direct'
      AND invitation.recipient_id = v_actor_id
      AND invitation.status = 'pending'
      AND invitation.expires_at > clock_timestamp()
      AND public.board_invitation_issuer_is_current_owner(
        invitation.board_id, invitation.inviter_id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.board_memberships AS membership
        WHERE membership.board_id = invitation.board_id
          AND membership.user_id = v_actor_id
          AND membership.revoked_at IS NULL
      )
    ORDER BY invitation.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.preview_board_invitation_p(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_hash bytea;
  v_invitation public.board_invitations%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_inviter_email text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  BEGIN
    v_hash := public.board_invitation_token_hash(p_token);
  EXCEPTION WHEN invalid_parameter_value THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END;

  SELECT invitation.* INTO v_invitation
  FROM public.board_invitations AS invitation
  WHERE invitation.token_hash = v_hash
    AND invitation.invitation_type = 'generic'
    AND invitation.status = 'pending';
  IF NOT FOUND OR v_invitation.expires_at <= clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_invitation.board_id;
  IF NOT FOUND OR NOT public.board_invitation_issuer_is_current_owner(
    v_invitation.board_id, v_invitation.inviter_id
  ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT access.email INTO v_inviter_email
  FROM public.application_access AS access
  WHERE access.auth_user_id = v_invitation.inviter_id
    AND access.state = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  RETURN jsonb_build_object(
    'status', 'available',
    'board_name', v_board.name,
    'inviter', v_inviter_email,
    'role', 'collaborator'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_board_invitation_link_p(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_hash bytea;
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_invitation public.board_invitations%ROWTYPE;
  v_membership_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM public.assert_board_invitation_actor();
  BEGIN
    v_hash := public.board_invitation_token_hash(p_token);
  EXCEPTION WHEN invalid_parameter_value THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END;

  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.token_hash = v_hash
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
  SELECT invitation.* INTO v_invitation
  FROM public.board_invitations AS invitation
  WHERE invitation.token_hash = v_hash
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
  IF FOUND THEN
    RETURN jsonb_build_object('status', 'already_member', 'board_slug', v_board.slug);
  END IF;

  INSERT INTO public.board_memberships(board_id, user_id, role)
  VALUES (v_board.id, v_actor_id, 'collaborator')
  ON CONFLICT (board_id, user_id) WHERE revoked_at IS NULL DO NOTHING
  RETURNING id INTO v_membership_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'already_member', 'board_slug', v_board.slug);
  END IF;

  UPDATE public.board_invitations AS invitation
  SET status = 'accepted',
      consumed_at = clock_timestamp(),
      accepted_by = v_actor_id
  WHERE invitation.id = v_invitation.id;

  RETURN jsonb_build_object('status', 'accepted', 'board_slug', v_board.slug);
END;
$$;

CREATE OR REPLACE FUNCTION public.accept_direct_board_invitation_p(p_invitation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_invitation public.board_invitations%ROWTYPE;
  v_membership_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM public.assert_board_invitation_actor();
  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id
    AND invitation.invitation_type = 'direct'
    AND invitation.recipient_id = v_actor_id
    AND invitation.status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board FROM public.boards AS board
  WHERE board.id = v_board_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
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
  IF FOUND THEN
    RETURN jsonb_build_object('status', 'already_member', 'board_slug', v_board.slug);
  END IF;

  INSERT INTO public.board_memberships(board_id, user_id, role)
  VALUES (v_board.id, v_actor_id, 'collaborator')
  ON CONFLICT (board_id, user_id) WHERE revoked_at IS NULL DO NOTHING
  RETURNING id INTO v_membership_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'already_member', 'board_slug', v_board.slug);
  END IF;

  UPDATE public.board_invitations AS invitation
  SET status = 'accepted',
      consumed_at = clock_timestamp(),
      accepted_by = v_actor_id
  WHERE invitation.id = v_invitation.id;

  RETURN jsonb_build_object('status', 'accepted', 'board_slug', v_board.slug);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_direct_board_invitation_p(p_invitation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN false;
  END IF;
  PERFORM public.assert_board_invitation_actor();
  UPDATE public.board_invitations AS invitation
  SET status = 'rejected'
  WHERE invitation.id = p_invitation_id
    AND invitation.invitation_type = 'direct'
    AND invitation.recipient_id = v_actor_id
    AND invitation.status = 'pending';
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_board_invitation_p(p_invitation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
BEGIN
  PERFORM public.assert_board_invitation_actor();
  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id;
  IF NOT FOUND THEN RETURN false; END IF;

  SELECT board.* INTO v_board FROM public.boards AS board
  WHERE board.id = v_board_id FOR UPDATE;
  IF NOT FOUND THEN RETURN false; END IF;
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

  UPDATE public.board_invitations AS invitation
  SET status = 'revoked'
  WHERE invitation.id = p_invitation_id
    AND invitation.board_id = v_board.id
    AND invitation.status = 'pending';
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.renew_board_invitation_p(p_invitation_id uuid)
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
  v_token text;
  v_hash bytea;
BEGIN
  PERFORM public.assert_board_invitation_actor();
  SELECT invitation.board_id INTO v_board_id
  FROM public.board_invitations AS invitation
  WHERE invitation.id = p_invitation_id
    AND invitation.status = 'pending';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board FROM public.boards AS board
  WHERE board.id = v_board_id FOR UPDATE;
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
    AND invitation.status = 'pending'
  FOR UPDATE;
  IF NOT FOUND OR v_invitation.expires_at > clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'not_expired');
  END IF;

  IF v_invitation.invitation_type = 'generic' THEN
    v_token := pg_catalog.encode(extensions.gen_random_bytes(32), 'hex');
    v_hash := extensions.digest(pg_catalog.convert_to(v_token, 'UTF8'), 'sha256');
    UPDATE public.board_invitations AS invitation
    SET token_hash = v_hash,
        expires_at = clock_timestamp() + interval '72 hours'
    WHERE invitation.id = v_invitation.id
    RETURNING * INTO v_invitation;
    RETURN jsonb_build_object(
      'status', 'renewed',
      'id', v_invitation.id,
      'token', v_token,
      'expires_at', v_invitation.expires_at,
      'role', 'collaborator'
    );
  END IF;

  UPDATE public.board_invitations AS invitation
  SET expires_at = clock_timestamp() + interval '72 hours'
  WHERE invitation.id = v_invitation.id
  RETURNING * INTO v_invitation;
  RETURN jsonb_build_object(
    'status', 'renewed',
    'id', v_invitation.id,
    'expires_at', v_invitation.expires_at
  );
END;
$$;

REVOKE ALL ON FUNCTION public.assert_board_invitation_actor()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.board_invitation_issuer_is_current_owner(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.board_invitation_token_hash(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_direct_board_invitation_p(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_board_invitation_link_p(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_board_invitations_p(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_my_pending_board_invitations_p()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.preview_board_invitation_p(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_board_invitation_link_p(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.accept_direct_board_invitation_p(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reject_direct_board_invitation_p(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.revoke_board_invitation_p(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.renew_board_invitation_p(uuid)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_direct_board_invitation_p(text, text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_board_invitation_link_p(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_board_invitations_p(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_pending_board_invitations_p()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.preview_board_invitation_p(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_board_invitation_link_p(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_direct_board_invitation_p(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_direct_board_invitation_p(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_board_invitation_p(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.renew_board_invitation_p(uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
