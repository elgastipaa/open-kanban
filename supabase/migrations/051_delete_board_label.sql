BEGIN;

CREATE FUNCTION public.list_deleted_board_labels_p(p_slug text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_labels jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND board.owner_id = auth.uid()
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'labels', '[]'::jsonb);
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', label.id,
        'board_id', label.board_id,
        'name', label.name,
        'color', label.color,
        'deleted_at', label.deleted_at,
        'expires_at', label.deleted_at + interval '604800 seconds',
        'version', label.version
      ) ORDER BY label.deleted_at DESC, label.id
    ),
    '[]'::jsonb
  ) INTO v_labels
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at > clock_timestamp() - interval '604800 seconds';

  RETURN jsonb_build_object('status', 'available', 'labels', v_labels);
END;
$$;

CREATE FUNCTION public.delete_board_label_p(
  p_slug text,
  p_label_id uuid,
  p_expected_version bigint
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
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_label_id IS NULL OR p_expected_version IS NULL
    OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'A board, label, and expected version are required'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND board.owner_id = v_actor_id
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
    AND board.owner_id = v_actor_id
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

  UPDATE public.board_labels AS label
  SET deleted_at = clock_timestamp(),
      deleted_by = v_actor_id,
      updated_at = clock_timestamp(),
      version = label.version + 1
  WHERE label.id = v_label.id
  RETURNING * INTO v_label;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'label', jsonb_build_object(
      'id', v_label.id,
      'board_id', v_label.board_id,
      'name', v_label.name,
      'color', v_label.color,
      'deleted_at', v_label.deleted_at,
      'expires_at', v_label.deleted_at + interval '604800 seconds',
      'version', v_label.version
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.list_deleted_board_labels_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_board_label_p(text, uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_deleted_board_labels_p(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_board_label_p(text, uuid, bigint)
  TO authenticated;

COMMIT;
