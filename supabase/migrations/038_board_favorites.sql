BEGIN;

CREATE TABLE public.board_favorites (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, board_id)
);
ALTER TABLE public.board_favorites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_favorites FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.list_my_board_favorites_p()
RETURNS TABLE (board_id uuid)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT favorite.board_id
  FROM public.board_favorites AS favorite
  WHERE favorite.user_id = auth.uid()
    AND public.is_board_member(favorite.board_id);
END;
$$;
REVOKE ALL ON FUNCTION public.list_my_board_favorites_p()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_board_favorites_p() TO authenticated;

CREATE FUNCTION public.set_board_favorite_p(
  p_board_id uuid,
  p_is_favorite boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF p_board_id IS NULL OR p_is_favorite IS NULL THEN
    RAISE EXCEPTION 'A board and requested favorite state are required'
      USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
  WHERE board.id = p_board_id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
    AND public.is_board_member(board.id)
  FOR SHARE OF board, membership;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  IF p_is_favorite THEN
    INSERT INTO public.board_favorites(user_id, board_id)
    VALUES (v_actor_id, p_board_id)
    ON CONFLICT (user_id, board_id) DO NOTHING;
  ELSE
    DELETE FROM public.board_favorites AS favorite
    WHERE favorite.user_id = v_actor_id
      AND favorite.board_id = p_board_id;
  END IF;

  RETURN p_is_favorite;
END;
$$;
REVOKE ALL ON FUNCTION public.set_board_favorite_p(uuid, boolean)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_board_favorite_p(uuid, boolean)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
