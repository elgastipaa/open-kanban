BEGIN;

CREATE FUNCTION public.update_board_label_p(
  p_slug text,
  p_label_id uuid,
  p_expected_version bigint,
  p_name text,
  p_color text
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
  v_membership_id uuid;
  v_label public.board_labels%ROWTYPE;
  v_collision public.board_labels%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_label_id IS NULL OR p_expected_version IS NULL
    OR p_expected_version < 1 OR p_name IS NULL
    OR btrim(p_name) = '' OR char_length(p_name) > 40
    OR p_color IS NULL
    OR p_color NOT IN ('red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'pink', 'gray') THEN
    RAISE EXCEPTION 'A label requires a name of up to 40 characters and a valid palette color'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
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

  SELECT label.* INTO v_label
  FROM public.board_labels AS label
  WHERE label.id = p_label_id
    AND label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  IF v_label.version <> p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict',
      'reason', 'stale_version',
      'label', jsonb_build_object(
        'id', v_label.id,
        'board_id', v_label.board_id,
        'name', v_label.name,
        'color', v_label.color,
        'version', v_label.version
      )
    );
  END IF;

  SELECT label.* INTO v_collision
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL
    AND label.id <> v_label.id
    AND btrim(label.name) COLLATE public.board_label_name_ci_ai
      = btrim(p_name) COLLATE public.board_label_name_ci_ai;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'conflict',
      'reason', 'duplicate_name',
      'label', jsonb_build_object(
        'id', v_collision.id,
        'board_id', v_collision.board_id,
        'name', v_collision.name,
        'color', v_collision.color,
        'version', v_collision.version
      )
    );
  END IF;

  IF v_label.name IS DISTINCT FROM p_name OR v_label.color IS DISTINCT FROM p_color THEN
    UPDATE public.board_labels AS label
    SET name = p_name,
        color = p_color,
        updated_at = clock_timestamp(),
        version = label.version + 1
    WHERE label.id = v_label.id
    RETURNING * INTO v_label;
  END IF;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'label', jsonb_build_object(
      'id', v_label.id,
      'board_id', v_label.board_id,
      'name', v_label.name,
      'color', v_label.color,
      'created_at', v_label.created_at,
      'updated_at', v_label.updated_at,
      'version', v_label.version
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.update_board_label_p(text, uuid, bigint, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_board_label_p(text, uuid, bigint, text, text)
  TO authenticated;

COMMIT;
