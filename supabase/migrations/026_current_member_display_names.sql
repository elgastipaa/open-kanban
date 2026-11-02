-- Return display names only from the verified, enabled identities of the
-- current members of a board the caller can access.
BEGIN;

DROP FUNCTION public.list_assignable_board_members_p(text);

CREATE FUNCTION public.list_assignable_board_members_p(p_slug text)
RETURNS TABLE(user_id uuid, name text, email text, role text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT
    membership.user_id,
    coalesce(nullif(btrim(identity.identity_data->>'name'), ''), auth_user.email) AS name,
    auth_user.email,
    membership.role
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.revoked_at IS NULL
  JOIN auth.users AS auth_user ON auth_user.id = membership.user_id
  JOIN public.application_access AS access
    ON access.auth_user_id = membership.user_id
    AND access.state = 'active'
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
    AND public.is_enabled_application_identity_p(membership.user_id)
  ORDER BY lower(auth_user.email), membership.user_id;
$$;

REVOKE ALL ON FUNCTION public.list_assignable_board_members_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_assignable_board_members_p(text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
