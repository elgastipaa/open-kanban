BEGIN;

CREATE COLLATION public.board_label_name_ci_ai (
  provider = icu,
  locale = 'und-u-ks-level1',
  deterministic = false
);

CREATE TABLE public.board_labels (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  name text NOT NULL CHECK (
    btrim(name) <> '' AND char_length(name) <= 40
  ),
  color text NOT NULL CHECK (
    color IN ('red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'pink', 'gray')
  ),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  deleted_at timestamptz,
  deleted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT board_labels_generation_fk FOREIGN KEY (board_id, generation_id)
    REFERENCES public.board_generations(board_id, id) ON DELETE CASCADE,
  CONSTRAINT board_labels_deletion_shape CHECK (
    (deleted_at IS NULL AND deleted_by IS NULL)
    OR (deleted_at IS NOT NULL)
  )
);
CREATE UNIQUE INDEX board_labels_active_name_uidx
  ON public.board_labels (
    board_id,
    (btrim(name) COLLATE public.board_label_name_ci_ai)
  )
  WHERE deleted_at IS NULL;
CREATE INDEX board_labels_generation_active_idx
  ON public.board_labels(board_id, generation_id, created_at, id)
  WHERE deleted_at IS NULL;
ALTER TABLE public.board_labels ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_labels
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.list_board_labels_p(p_slug text)
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
        'created_at', label.created_at,
        'updated_at', label.updated_at,
        'version', label.version
      ) ORDER BY label.created_at, label.id
    ),
    '[]'::jsonb
  ) INTO v_labels
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL;

  RETURN jsonb_build_object('status', 'available', 'labels', v_labels);
END;
$$;

CREATE FUNCTION public.create_board_label_p(
  p_slug text,
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
  v_existing public.board_labels%ROWTYPE;
  v_label public.board_labels%ROWTYPE;
  v_active_count integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_slug IS NULL OR p_name IS NULL OR p_color IS NULL
    OR btrim(p_name) = '' OR char_length(p_name) > 40
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

  SELECT label.* INTO v_existing
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL
    AND btrim(label.name) COLLATE public.board_label_name_ci_ai
      = btrim(p_name) COLLATE public.board_label_name_ci_ai;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'conflict',
      'reason', 'duplicate_name',
      'label', jsonb_build_object(
        'id', v_existing.id,
        'board_id', v_existing.board_id,
        'name', v_existing.name,
        'color', v_existing.color,
        'version', v_existing.version
      )
    );
  END IF;

  SELECT count(*)::integer INTO v_active_count
  FROM public.board_labels AS label
  WHERE label.board_id = v_board.id
    AND label.generation_id = v_board.active_generation_id
    AND label.deleted_at IS NULL;
  IF v_active_count >= 100 THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'active_limit');
  END IF;

  INSERT INTO public.board_labels (
    board_id, generation_id, name, color, created_by
  ) VALUES (
    v_board.id, v_board.active_generation_id, p_name, p_color, v_actor_id
  ) RETURNING * INTO v_label;

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

REVOKE ALL ON FUNCTION public.list_board_labels_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_board_label_p(text, text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_board_labels_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_board_label_p(text, text, text) TO authenticated;

COMMIT;
