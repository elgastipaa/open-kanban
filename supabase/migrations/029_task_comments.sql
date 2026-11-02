-- Task conversations are separate from task fields and use durable receipts
-- so a lost response can be reconciled without creating another comment.
BEGIN;

CREATE TABLE public.task_comments (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  author_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  author_name text NOT NULL,
  content text NOT NULL CHECK (pg_catalog.btrim(content) <> ''),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  edited_at timestamptz,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  deleted_at timestamptz,
  deleted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  deletion_cause text CHECK (deletion_cause IN ('author', 'moderation')),
  CONSTRAINT task_comments_deletion_shape CHECK (
    (deleted_at IS NULL AND deleted_by IS NULL AND deletion_cause IS NULL)
    OR (deleted_at IS NOT NULL AND deletion_cause IS NOT NULL)
  )
);
CREATE INDEX task_comments_task_chronological_idx
  ON public.task_comments(task_id, created_at, id);

CREATE TABLE public.task_comment_mentions (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  comment_id uuid NOT NULL REFERENCES public.task_comments(id) ON DELETE CASCADE,
  membership_id uuid REFERENCES public.board_memberships(id) ON DELETE SET NULL,
  start_char integer NOT NULL CHECK (start_char >= 0),
  length_chars integer NOT NULL CHECK (length_chars > 0),
  display_text text NOT NULL CHECK (display_text <> ''),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT task_comment_mentions_comment_position_unique
    UNIQUE (comment_id, start_char)
);
CREATE INDEX task_comment_mentions_membership_idx
  ON public.task_comment_mentions(membership_id)
  WHERE membership_id IS NOT NULL;

CREATE TABLE public.task_comment_receipts (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  action text NOT NULL DEFAULT 'create'
    CHECK (action IN ('create', 'edit', 'delete', 'restore')),
  board_id uuid NOT NULL,
  task_id uuid NOT NULL,
  comment_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_version bigint NOT NULL DEFAULT 1 CHECK (result_version > 0),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);
CREATE INDEX task_comment_receipts_expiry_idx
  ON public.task_comment_receipts(result_expires_at);

ALTER TABLE public.task_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_comment_mentions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_comment_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_comments, public.task_comment_mentions,
  public.task_comment_receipts FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.freeze_task_comment_mentions_on_membership_exit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL THEN
    UPDATE public.task_comment_mentions AS mention
    SET membership_id = NULL
    WHERE mention.membership_id = OLD.id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.task_comment_mentions AS mention
    SET membership_id = NULL
    WHERE mention.membership_id = OLD.id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER board_membership_freezes_task_comment_mentions
  AFTER UPDATE OF revoked_at OR DELETE ON public.board_memberships
  FOR EACH ROW EXECUTE FUNCTION public.freeze_task_comment_mentions_on_membership_exit();
REVOKE ALL ON FUNCTION public.freeze_task_comment_mentions_on_membership_exit()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.task_comment_context_p(p_slug text, p_task_id uuid)
RETURNS TABLE (
  context_board_id uuid,
  context_owner_id uuid,
  context_generation_id uuid,
  context_membership_id uuid,
  context_role text,
  context_member_name text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    board.id,
    board.owner_id,
    board.active_generation_id,
    membership.id,
    membership.role,
    member.name
  FROM public.boards AS board
  JOIN public.columns AS column_row
    ON column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  JOIN public.tasks AS task
    ON task.column_id = column_row.id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL
  JOIN public.list_assignable_board_members_p(board.slug) AS member
    ON member.user_id = auth.uid()
  WHERE board.slug = p_slug
    AND task.id = p_task_id
  FOR SHARE OF board, task, membership;
END;
$$;
REVOKE ALL ON FUNCTION public.task_comment_context_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.store_task_comment_mentions_p(
  p_board_id uuid,
  p_slug text,
  p_comment_id uuid,
  p_content text,
  p_mentions jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_item record;
  v_user_id uuid;
  v_start integer;
  v_length integer;
  v_membership_id uuid;
  v_member_name text;
  v_display_text text;
  v_previous jsonb := '[]'::jsonb;
BEGIN
  IF pg_catalog.jsonb_typeof(p_mentions) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Review the member mentions before sending the comment'
      USING ERRCODE = '22023';
  END IF;

  FOR v_item IN
    SELECT entries.value AS item, entries.ordinality
    FROM pg_catalog.jsonb_array_elements(p_mentions) WITH ORDINALITY AS entries(value, ordinality)
  LOOP
    IF pg_catalog.jsonb_typeof(v_item.item) IS DISTINCT FROM 'object'
      OR (SELECT count(*) FROM pg_catalog.jsonb_object_keys(v_item.item)) <> 3
      OR NOT (v_item.item ? 'user_id')
      OR NOT (v_item.item ? 'start_char')
      OR NOT (v_item.item ? 'length_chars')
      OR pg_catalog.jsonb_typeof(v_item.item->'user_id') IS DISTINCT FROM 'string'
      OR pg_catalog.jsonb_typeof(v_item.item->'start_char') IS DISTINCT FROM 'number'
      OR pg_catalog.jsonb_typeof(v_item.item->'length_chars') IS DISTINCT FROM 'number'
      OR v_item.item->>'start_char' !~ '^(0|[1-9][0-9]*)$'
      OR v_item.item->>'length_chars' !~ '^[1-9][0-9]*$' THEN
      RAISE EXCEPTION 'Review the member mentions before sending the comment'
        USING ERRCODE = '22023';
    END IF;

    BEGIN
      v_user_id := (v_item.item->>'user_id')::uuid;
      v_start := (v_item.item->>'start_char')::integer;
      v_length := (v_item.item->>'length_chars')::integer;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
      RAISE EXCEPTION 'Review the member mentions before sending the comment'
        USING ERRCODE = '22023';
    END;

    IF v_start + v_length > pg_catalog.char_length(p_content)
      OR EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_array_elements(v_previous) AS previous(value)
        WHERE v_start < (previous.value->>'start_char')::integer
            + (previous.value->>'length_chars')::integer
          AND (previous.value->>'start_char')::integer < v_start + v_length
      ) THEN
      RAISE EXCEPTION 'Review the member mentions before sending the comment'
        USING ERRCODE = '22023';
    END IF;

    SELECT membership.id, member.name
    INTO v_membership_id, v_member_name
    FROM public.board_memberships AS membership
    JOIN public.list_assignable_board_members_p(p_slug) AS member
      ON member.user_id = membership.user_id
    WHERE membership.board_id = p_board_id
      AND membership.user_id = v_user_id
      AND membership.revoked_at IS NULL;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Review the member mentions before sending the comment'
        USING ERRCODE = '22023';
    END IF;

    v_display_text := pg_catalog.substring(p_content, v_start + 1, v_length);
    IF v_display_text IS DISTINCT FROM '@' || v_member_name THEN
      RAISE EXCEPTION 'Review the member mentions before sending the comment'
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.task_comment_mentions (
      comment_id, membership_id, start_char, length_chars, display_text
    ) VALUES (
      p_comment_id, v_membership_id, v_start, v_length, v_display_text
    );
    v_previous := v_previous || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('start_char', v_start, 'length_chars', v_length)
    );
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.store_task_comment_mentions_p(uuid, text, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.create_task_comment_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_content text,
  p_mentions jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_context record;
  v_hash bytea;
  v_receipt public.task_comment_receipts%ROWTYPE;
  v_comment_id uuid;
  v_content text := p_content;
  v_mentions jsonb := coalesce(p_mentions, '[]'::jsonb);
BEGIN
  IF p_operation_id IS NULL OR p_task_id IS NULL OR p_slug IS NULL
    OR pg_catalog.btrim(coalesce(v_content, '')) = ''
    OR pg_catalog.jsonb_typeof(v_mentions) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Review the comment before sending it' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_context
  FROM public.task_comment_context_p(p_slug, p_task_id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;

  v_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'create',
        'slug', p_slug,
        'task_id', p_task_id,
        'content', v_content,
        'mentions', v_mentions
      )::text,
      'UTF8'
    ),
    'sha256'
  );

  SELECT receipt.* INTO v_receipt
  FROM public.task_comment_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'create'
      OR v_receipt.payload_hash IS DISTINCT FROM v_hash
      OR v_receipt.board_id IS DISTINCT FROM v_context.context_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_task_id THEN
      RAISE EXCEPTION 'This comment operation was already used for different content'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmed',
      'operation_id', p_operation_id,
      'comment_id', v_receipt.comment_id
    );
  END IF;

  v_comment_id := pg_catalog.gen_random_uuid();
  INSERT INTO public.task_comment_receipts (
    actor_id, operation_id, action, board_id, task_id, comment_id,
    payload_hash, result_version
  ) VALUES (
    v_actor_id,
    p_operation_id,
    'create',
    v_context.context_board_id,
    p_task_id,
    v_comment_id,
    v_hash,
    1
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_comment_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The comment result could not be reconciled; review the conversation'
        USING ERRCODE = '40001';
    END IF;
    IF v_receipt.action IS DISTINCT FROM 'create'
      OR v_receipt.payload_hash IS DISTINCT FROM v_hash
      OR v_receipt.board_id IS DISTINCT FROM v_context.context_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_task_id THEN
      RAISE EXCEPTION 'This comment operation was already used for different content'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmed',
      'operation_id', p_operation_id,
      'comment_id', v_receipt.comment_id
    );
  END IF;

  INSERT INTO public.task_comments (
    id, board_id, task_id, author_id, author_name, content
  ) VALUES (
    v_comment_id,
    v_context.context_board_id,
    p_task_id,
    v_actor_id,
    v_context.context_member_name,
    v_content
  );

  PERFORM public.store_task_comment_mentions_p(
    v_context.context_board_id,
    p_slug,
    v_comment_id,
    v_content,
    v_mentions
  );

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'comment_id', v_comment_id
  );
END;
$$;

CREATE FUNCTION public.edit_task_comment_p(
  p_operation_id uuid,
  p_slug text,
  p_comment_id uuid,
  p_expected_version bigint,
  p_content text,
  p_mentions jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_task_id uuid;
  v_context record;
  v_comment public.task_comments%ROWTYPE;
  v_receipt public.task_comment_receipts%ROWTYPE;
  v_content text := p_content;
  v_mentions jsonb := coalesce(p_mentions, '[]'::jsonb);
  v_hash bytea;
BEGIN
  IF p_operation_id IS NULL OR p_comment_id IS NULL OR p_slug IS NULL
    OR p_expected_version IS NULL OR p_expected_version < 1
    OR pg_catalog.btrim(coalesce(v_content, '')) = ''
    OR pg_catalog.jsonb_typeof(v_mentions) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Review the comment before saving it' USING ERRCODE = '22023';
  END IF;
  SELECT comment_row.task_id INTO v_task_id
  FROM public.task_comments AS comment_row
  JOIN public.boards AS board ON board.id = comment_row.board_id
  WHERE board.slug = p_slug AND comment_row.id = p_comment_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT * INTO v_context FROM public.task_comment_context_p(p_slug, v_task_id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT comment_row.* INTO v_comment
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = p_comment_id
    AND comment_row.board_id = v_context.context_board_id
    AND comment_row.task_id = v_task_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  v_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'edit',
        'slug', p_slug,
        'comment_id', p_comment_id,
        'expected_version', p_expected_version,
        'content', v_content,
        'mentions', v_mentions
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  SELECT receipt.* INTO v_receipt
  FROM public.task_comment_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'edit'
      OR v_receipt.comment_id IS DISTINCT FROM p_comment_id
      OR v_receipt.board_id IS DISTINCT FROM v_context.context_board_id
      OR v_receipt.task_id IS DISTINCT FROM v_task_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'This comment operation was already used for different content'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmed',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id,
      'version', v_receipt.result_version
    );
  END IF;

  IF v_comment.deleted_at IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id,
      'version', v_comment.version
    );
  END IF;
  IF v_comment.author_id IS DISTINCT FROM v_actor_id THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'forbidden',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id
    );
  END IF;

  IF v_comment.version IS DISTINCT FROM p_expected_version THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id,
      'version', v_comment.version
    );
  END IF;

  INSERT INTO public.task_comment_receipts (
    actor_id, operation_id, action, board_id, task_id, comment_id,
    payload_hash, result_version
  ) VALUES (
    v_actor_id,
    p_operation_id,
    'edit',
    v_context.context_board_id,
    v_task_id,
    p_comment_id,
    v_hash,
    v_comment.version + 1
  );
  UPDATE public.task_comments AS comment_row
  SET content = v_content,
      edited_at = clock_timestamp(),
      version = comment_row.version + 1
  WHERE comment_row.id = p_comment_id
  RETURNING comment_row.* INTO v_comment;

  DELETE FROM public.task_comment_mentions AS mention
  WHERE mention.comment_id = p_comment_id;
  PERFORM public.store_task_comment_mentions_p(
    v_context.context_board_id,
    p_slug,
    p_comment_id,
    v_content,
    v_mentions
  );

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'comment_id', p_comment_id,
    'version', v_comment.version
  );
END;
$$;

CREATE FUNCTION public.delete_task_comment_p(
  p_operation_id uuid,
  p_slug text,
  p_comment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_task_id uuid;
  v_context record;
  v_comment public.task_comments%ROWTYPE;
  v_receipt public.task_comment_receipts%ROWTYPE;
  v_cause text;
  v_hash bytea;
BEGIN
  IF p_operation_id IS NULL OR p_comment_id IS NULL OR p_slug IS NULL THEN
    RAISE EXCEPTION 'Review the comment before deleting it' USING ERRCODE = '22023';
  END IF;
  SELECT comment_row.task_id INTO v_task_id
  FROM public.task_comments AS comment_row
  JOIN public.boards AS board ON board.id = comment_row.board_id
  WHERE board.slug = p_slug AND comment_row.id = p_comment_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT * INTO v_context FROM public.task_comment_context_p(p_slug, v_task_id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT comment_row.* INTO v_comment
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = p_comment_id
    AND comment_row.board_id = v_context.context_board_id
    AND comment_row.task_id = v_task_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_comment.author_id = v_actor_id THEN
    v_cause := 'author';
  ELSIF v_context.context_role = 'owner' THEN
    v_cause := 'moderation';
  ELSE
    RETURN pg_catalog.jsonb_build_object(
      'status', 'forbidden',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id
    );
  END IF;

  v_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'delete', 'slug', p_slug, 'comment_id', p_comment_id
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  SELECT receipt.* INTO v_receipt
  FROM public.task_comment_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'delete'
      OR v_receipt.comment_id IS DISTINCT FROM p_comment_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'This comment operation was already used for a different action'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmed',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id,
      'deletion_cause', v_cause,
      'version', v_receipt.result_version
    );
  END IF;

  IF v_comment.deleted_at IS NOT NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id, 'comment_id', p_comment_id
    );
  END IF;

  INSERT INTO public.task_comment_receipts (
    actor_id, operation_id, action, board_id, task_id, comment_id,
    payload_hash, result_version
  ) VALUES (
    v_actor_id,
    p_operation_id,
    'delete',
    v_context.context_board_id,
    v_task_id,
    p_comment_id,
    v_hash,
    v_comment.version + 1
  );
  UPDATE public.task_comments AS comment_row
  SET deleted_at = clock_timestamp(),
      deleted_by = v_actor_id,
      deletion_cause = v_cause,
      version = comment_row.version + 1
  WHERE comment_row.id = p_comment_id
  RETURNING comment_row.* INTO v_comment;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'comment_id', p_comment_id,
    'deletion_cause', v_cause,
    'deleted_at', v_comment.deleted_at,
    'version', v_comment.version
  );
END;
$$;

CREATE FUNCTION public.get_task_comments_p(
  p_slug text,
  p_task_id uuid,
  p_limit integer DEFAULT 30,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL,
  p_anchor_comment_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_context record;
  v_comments jsonb;
  v_count integer;
  v_oldest_created_at timestamptz;
  v_oldest_id uuid;
  v_anchor_created_at timestamptz;
  v_anchor_id uuid;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR ((p_before_created_at IS NULL) <> (p_before_id IS NULL))
    OR (p_anchor_comment_id IS NOT NULL AND p_before_created_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Review the conversation page before loading it'
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_context
  FROM public.task_comment_context_p(p_slug, p_task_id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  IF p_anchor_comment_id IS NOT NULL THEN
    SELECT comment_row.created_at, comment_row.id
    INTO v_anchor_created_at, v_anchor_id
    FROM public.task_comments AS comment_row
    WHERE comment_row.board_id = v_context.context_board_id
      AND comment_row.task_id = p_task_id
      AND comment_row.id = p_anchor_comment_id;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
    END IF;
  END IF;

  WITH page_rows AS (
    SELECT comment_row.*
    FROM public.task_comments AS comment_row
    WHERE comment_row.board_id = v_context.context_board_id
      AND comment_row.task_id = p_task_id
      AND (
        (p_anchor_comment_id IS NOT NULL
          AND (comment_row.created_at, comment_row.id)
            <= (v_anchor_created_at, v_anchor_id))
        OR (p_anchor_comment_id IS NULL AND
          (p_before_created_at IS NULL OR
            (comment_row.created_at, comment_row.id) < (p_before_created_at, p_before_id)))
      )
    ORDER BY comment_row.created_at DESC, comment_row.id DESC
    LIMIT p_limit + 1
  ), visible_rows AS (
    SELECT * FROM page_rows
    ORDER BY created_at DESC, id DESC
    LIMIT p_limit
  )
  SELECT
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
          'id', visible_rows.id,
          'author_id', visible_rows.author_id,
          'author_name', visible_rows.author_name,
          'created_at', visible_rows.created_at,
          'edited_at', visible_rows.edited_at,
          'version', CASE WHEN visible_rows.deleted_at IS NULL
            THEN visible_rows.version ELSE NULL END,
          'deleted', visible_rows.deleted_at IS NOT NULL,
          'content', CASE WHEN visible_rows.deleted_at IS NULL
            THEN visible_rows.content ELSE NULL END,
          'can_restore', CASE WHEN visible_rows.deleted_at IS NOT NULL THEN
            public.task_comment_restore_window_open_p(
              visible_rows.deleted_at, clock_timestamp()
            ) AND (
              (visible_rows.deletion_cause = 'author'
                AND (visible_rows.author_id = auth.uid()
                  OR v_context.context_role = 'owner'))
              OR (visible_rows.deletion_cause = 'moderation'
                AND v_context.context_role = 'owner')
            )
            ELSE NULL END,
          'expires_at', CASE WHEN visible_rows.deleted_at IS NOT NULL
            THEN visible_rows.deleted_at + interval '168 hours' ELSE NULL END,
          'mentions', CASE WHEN visible_rows.deleted_at IS NULL THEN
            coalesce((
              SELECT pg_catalog.jsonb_agg(
                pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
                  'start_char', mention.start_char,
                  'length_chars', mention.length_chars,
                  'text', mention.display_text,
                  'user_id', membership.user_id
                )) ORDER BY mention.start_char
              )
              FROM public.task_comment_mentions AS mention
              LEFT JOIN public.board_memberships AS membership
                ON membership.id = mention.membership_id
                AND membership.revoked_at IS NULL
              WHERE mention.comment_id = visible_rows.id
            ), '[]'::jsonb)
            ELSE '[]'::jsonb END
        )) ORDER BY visible_rows.created_at, visible_rows.id
      ),
      '[]'::jsonb
    ),
    (SELECT count(*)::integer FROM page_rows),
    (SELECT visible.created_at FROM visible_rows AS visible
      ORDER BY visible.created_at, visible.id LIMIT 1),
    (SELECT visible.id FROM visible_rows AS visible
      ORDER BY visible.created_at, visible.id LIMIT 1)
  INTO v_comments, v_count, v_oldest_created_at, v_oldest_id
  FROM visible_rows;

  RETURN pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'status', 'available',
    'comments', v_comments,
    'has_more', v_count > p_limit,
    'next_cursor', CASE WHEN v_count > p_limit THEN
      pg_catalog.jsonb_build_object(
        'created_at', v_oldest_created_at,
        'id', v_oldest_id
      )
      ELSE NULL END
    , 'anchor_id', CASE WHEN p_anchor_comment_id IS NOT NULL
      THEN p_anchor_comment_id ELSE NULL END
    , 'anchor_index', CASE WHEN p_anchor_comment_id IS NOT NULL
      THEN pg_catalog.jsonb_array_length(v_comments) - 1 ELSE NULL END
  ));
END;
$$;

CREATE FUNCTION public.restore_task_comment_p(
  p_operation_id uuid,
  p_slug text,
  p_comment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_task_id uuid;
  v_context record;
  v_comment public.task_comments%ROWTYPE;
  v_receipt public.task_comment_receipts%ROWTYPE;
  v_hash bytea;
BEGIN
  IF p_operation_id IS NULL OR p_comment_id IS NULL OR p_slug IS NULL THEN
    RAISE EXCEPTION 'Review the comment before restoring it' USING ERRCODE = '22023';
  END IF;
  SELECT comment_row.task_id INTO v_task_id
  FROM public.task_comments AS comment_row
  JOIN public.boards AS board ON board.id = comment_row.board_id
  WHERE board.slug = p_slug AND comment_row.id = p_comment_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT * INTO v_context FROM public.task_comment_context_p(p_slug, v_task_id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT comment_row.* INTO v_comment
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = p_comment_id
    AND comment_row.board_id = v_context.context_board_id
    AND comment_row.task_id = v_task_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  v_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'restore', 'slug', p_slug, 'comment_id', p_comment_id
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  SELECT receipt.* INTO v_receipt
  FROM public.task_comment_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'restore'
      OR v_receipt.comment_id IS DISTINCT FROM p_comment_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_hash THEN
      RAISE EXCEPTION 'This comment operation was already used for a different action'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmed',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id,
      'version', v_receipt.result_version
    );
  END IF;

  IF v_comment.deleted_at IS NULL OR v_comment.deletion_cause IS NULL THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id, 'comment_id', p_comment_id
    );
  END IF;
  IF NOT public.task_comment_restore_window_open_p(
    v_comment.deleted_at,
    clock_timestamp()
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'expired', 'operation_id', p_operation_id, 'comment_id', p_comment_id
    );
  END IF;
  IF v_comment.deletion_cause = 'moderation'
    AND v_context.context_role <> 'owner' THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'forbidden',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id
    );
  END IF;
  IF v_comment.deletion_cause = 'author'
    AND v_comment.author_id <> v_actor_id
    AND v_context.context_role <> 'owner' THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'forbidden',
      'operation_id', p_operation_id,
      'comment_id', p_comment_id
    );
  END IF;

  INSERT INTO public.task_comment_receipts (
    actor_id, operation_id, action, board_id, task_id, comment_id,
    payload_hash, result_version
  ) VALUES (
    v_actor_id,
    p_operation_id,
    'restore',
    v_context.context_board_id,
    v_task_id,
    p_comment_id,
    v_hash,
    v_comment.version + 1
  );
  UPDATE public.task_comments AS comment_row
  SET deleted_at = NULL,
      deleted_by = NULL,
      deletion_cause = NULL,
      version = comment_row.version + 1
  WHERE comment_row.id = p_comment_id
  RETURNING comment_row.* INTO v_comment;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'comment_id', p_comment_id,
    'version', v_comment.version
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_task_comment_p(uuid, text, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_task_comment_p(uuid, text, uuid, text, jsonb)
  TO authenticated;
REVOKE ALL ON FUNCTION public.get_task_comments_p(text, uuid, integer, timestamptz, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_task_comments_p(text, uuid, integer, timestamptz, uuid, uuid)
  TO authenticated;
REVOKE ALL ON FUNCTION public.edit_task_comment_p(uuid, text, uuid, bigint, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.edit_task_comment_p(uuid, text, uuid, bigint, text, jsonb)
  TO authenticated;
REVOKE ALL ON FUNCTION public.delete_task_comment_p(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_task_comment_p(uuid, text, uuid)
  TO authenticated;

CREATE FUNCTION public.task_comment_restore_window_open_p(
  p_deleted_at timestamptz,
  p_now timestamptz
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog
AS $$
  SELECT p_deleted_at + interval '168 hours' > p_now;
$$;
REVOKE ALL ON FUNCTION public.task_comment_restore_window_open_p(timestamptz, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.restore_task_comment_p(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restore_task_comment_p(uuid, text, uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
