BEGIN;

CREATE FUNCTION public.saved_view_name_key_internal_p(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, extensions
AS $$
  SELECT pg_catalog.lower(
    pg_catalog.regexp_replace(
      extensions.unaccent(pg_catalog.btrim(p_name)),
      '[[:space:]]+', ' ', 'g'
    )
  );
$$;

CREATE FUNCTION public.saved_view_context_valid_internal_p(p_context_type text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT p_context_type IN ('search', 'my_tasks');
$$;

CREATE FUNCTION public.saved_view_definition_valid_internal_p(
  p_context_type text,
  p_definition jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_label jsonb;
  v_seen_labels text[] := ARRAY[]::text[];
  v_pair text;
BEGIN
  IF NOT public.saved_view_context_valid_internal_p(p_context_type)
    OR jsonb_typeof(p_definition) IS DISTINCT FROM 'object' THEN
    RETURN false;
  END IF;

  IF (SELECT count(*) FROM jsonb_object_keys(p_definition)) <> 12
    OR NOT (p_definition ?& ARRAY[
      'query', 'scope', 'boardId', 'includeCompleted', 'includeHistory',
      'filterBoardId', 'dueFilter', 'priority', 'assigneeId', 'unassigned',
      'labels', 'order'
    ]) THEN
    RETURN false;
  END IF;

  IF jsonb_typeof(p_definition->'query') IS DISTINCT FROM 'string'
    OR char_length(p_definition->>'query') > 200
    OR jsonb_typeof(p_definition->'scope') IS DISTINCT FROM 'string'
    OR jsonb_typeof(p_definition->'includeCompleted') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_definition->'includeHistory') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_definition->'unassigned') IS DISTINCT FROM 'boolean'
    OR jsonb_typeof(p_definition->'labels') IS DISTINCT FROM 'array'
    OR jsonb_typeof(p_definition->'order') IS DISTINCT FROM 'string'
    OR p_definition->>'order' NOT IN ('due', 'created') THEN
    RETURN false;
  END IF;
  IF jsonb_array_length(p_definition->'labels') > 100 THEN
    RETURN false;
  END IF;

  IF p_context_type = 'search' THEN
    IF p_definition->>'scope' NOT IN ('all', 'board', 'my_tasks') THEN
      RETURN false;
    END IF;
  ELSIF p_definition->>'scope' <> 'my_tasks'
    OR p_definition->>'query' <> ''
    OR (p_definition->>'includeHistory')::boolean
    OR p_definition->'filterBoardId' IS DISTINCT FROM 'null'::jsonb
    OR p_definition->'dueFilter' IS DISTINCT FROM 'null'::jsonb
    OR p_definition->'priority' IS DISTINCT FROM 'null'::jsonb
    OR p_definition->'assigneeId' IS DISTINCT FROM 'null'::jsonb
    OR (p_definition->>'unassigned')::boolean
    OR jsonb_array_length(p_definition->'labels') <> 0 THEN
    RETURN false;
  END IF;

  IF p_definition->>'scope' = 'board' THEN
    IF jsonb_typeof(p_definition->'boardId') IS DISTINCT FROM 'string'
      OR p_definition->>'boardId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RETURN false;
    END IF;
  ELSIF p_definition->'boardId' <> 'null'::jsonb THEN
    RETURN false;
  END IF;

  IF p_definition->'filterBoardId' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_definition->'filterBoardId') IS DISTINCT FROM 'string'
      OR p_definition->>'filterBoardId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RETURN false;
    END IF;
  END IF;
  IF p_definition->'dueFilter' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_definition->'dueFilter') IS DISTINCT FROM 'string'
      OR p_definition->>'dueFilter' NOT IN ('today', 'overdue', 'next_7_days', 'no_date') THEN
      RETURN false;
    END IF;
  END IF;
  IF p_definition->'priority' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_definition->'priority') IS DISTINCT FROM 'string'
      OR p_definition->>'priority' NOT IN ('low', 'medium', 'high', 'urgent') THEN
      RETURN false;
    END IF;
  END IF;
  IF p_definition->'assigneeId' IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_definition->'assigneeId') IS DISTINCT FROM 'string'
      OR p_definition->>'assigneeId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RETURN false;
    END IF;
  END IF;
  IF (p_definition->>'unassigned')::boolean
    AND p_definition->'assigneeId' <> 'null'::jsonb THEN
    RETURN false;
  END IF;

  FOR v_label IN SELECT jsonb_array_elements(p_definition->'labels') LOOP
    IF jsonb_typeof(v_label) IS DISTINCT FROM 'object' THEN
      RETURN false;
    END IF;
    IF (SELECT count(*) FROM jsonb_object_keys(v_label)) <> 2
      OR NOT (v_label ?& ARRAY['boardId', 'labelId'])
      OR jsonb_typeof(v_label->'boardId') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_label->'labelId') IS DISTINCT FROM 'string'
      OR v_label->>'boardId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR v_label->>'labelId' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RETURN false;
    END IF;
    v_pair := pg_catalog.lower(v_label->>'boardId') || ':' || pg_catalog.lower(v_label->>'labelId');
    IF v_pair = ANY(v_seen_labels) THEN
      RETURN false;
    END IF;
    v_seen_labels := array_append(v_seen_labels, v_pair);
  END LOOP;

  RETURN true;
END;
$$;

CREATE FUNCTION public.saved_view_invalid_references_internal_p(
  p_actor_id uuid,
  p_definition jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_invalid jsonb := '[]'::jsonb;
  v_label jsonb;
  v_scope_board_id uuid;
  v_filter_board_id uuid;
  v_assignee_id uuid;
  v_has_accessible_assignee_board boolean;
BEGIN
  IF p_definition->>'scope' = 'board' THEN
    v_scope_board_id := (p_definition->>'boardId')::uuid;
    IF NOT EXISTS (
      SELECT 1 FROM public.boards AS board
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
       AND membership.user_id = p_actor_id
       AND membership.revoked_at IS NULL
      WHERE board.id = v_scope_board_id
    ) THEN
      v_invalid := v_invalid || jsonb_build_array(
        jsonb_build_object('field', 'boardId')
      );
    END IF;
  END IF;

  IF p_definition->'filterBoardId' IS DISTINCT FROM 'null'::jsonb THEN
    v_filter_board_id := (p_definition->>'filterBoardId')::uuid;
    IF NOT EXISTS (
      SELECT 1 FROM public.boards AS board
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
       AND membership.user_id = p_actor_id
       AND membership.revoked_at IS NULL
      WHERE board.id = v_filter_board_id
    ) THEN
      v_invalid := v_invalid || jsonb_build_array(
        jsonb_build_object('field', 'filterBoardId')
      );
    END IF;
  END IF;

  FOR v_label IN SELECT jsonb_array_elements(p_definition->'labels') LOOP
    IF NOT EXISTS (
      SELECT 1
      FROM public.board_labels AS label
      JOIN public.boards AS board
        ON board.id = label.board_id
       AND board.active_generation_id = label.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
       AND membership.user_id = p_actor_id
       AND membership.revoked_at IS NULL
      WHERE board.id = (v_label->>'boardId')::uuid
        AND label.id = (v_label->>'labelId')::uuid
        AND label.deleted_at IS NULL
    ) THEN
      v_invalid := v_invalid || jsonb_build_array(
        jsonb_build_object('field', 'labels')
      );
    END IF;
  END LOOP;

  IF p_definition->'assigneeId' IS DISTINCT FROM 'null'::jsonb THEN
    v_assignee_id := (p_definition->>'assigneeId')::uuid;
    IF v_scope_board_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = v_scope_board_id
        AND membership.user_id = v_assignee_id
        AND membership.revoked_at IS NULL
    ) THEN
      v_invalid := v_invalid || jsonb_build_array(
        jsonb_build_object('field', 'assigneeId')
      );
    END IF;
    IF v_filter_board_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = v_filter_board_id
        AND membership.user_id = v_assignee_id
        AND membership.revoked_at IS NULL
    ) THEN
      v_invalid := v_invalid || jsonb_build_array(
        jsonb_build_object('field', 'assigneeId')
      );
    END IF;
    IF v_scope_board_id IS NULL AND v_filter_board_id IS NULL
      AND NOT EXISTS (
        SELECT 1
        FROM public.boards AS board
        JOIN public.board_memberships AS actor_membership
          ON actor_membership.board_id = board.id
         AND actor_membership.user_id = p_actor_id
         AND actor_membership.revoked_at IS NULL
        JOIN public.board_memberships AS assignee_membership
          ON assignee_membership.board_id = board.id
         AND assignee_membership.user_id = v_assignee_id
         AND assignee_membership.revoked_at IS NULL
      ) THEN
      v_invalid := v_invalid || jsonb_build_array(
        jsonb_build_object('field', 'assigneeId')
      );
    END IF;
  END IF;

  RETURN v_invalid;
END;
$$;

CREATE TABLE public.user_saved_view_actor_locks (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE
);
ALTER TABLE public.user_saved_view_actor_locks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_saved_view_actor_locks
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.user_saved_views (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  context_type text NOT NULL CHECK (context_type IN ('search', 'my_tasks')),
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 60),
  name_key text NOT NULL,
  definition jsonb NOT NULL,
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  needs_review boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  deleted_at timestamptz,
  CHECK (btrim(name) <> ''),
  CHECK (name_key = public.saved_view_name_key_internal_p(name)),
  CHECK (public.saved_view_definition_valid_internal_p(context_type, definition))
);
CREATE UNIQUE INDEX user_saved_views_active_name_unique
  ON public.user_saved_views(user_id, context_type, name_key)
  WHERE deleted_at IS NULL;
CREATE INDEX user_saved_views_deleted_window
  ON public.user_saved_views(user_id, context_type, deleted_at)
  WHERE deleted_at IS NOT NULL;
ALTER TABLE public.user_saved_views ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_saved_views
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.mark_saved_views_needing_review_internal_p(
  p_board_id uuid,
  p_label_id uuid DEFAULT NULL,
  p_user_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  UPDATE public.user_saved_views AS saved_view
  SET needs_review = true,
      version = saved_view.version + 1,
      updated_at = clock_timestamp()
  WHERE NOT saved_view.needs_review
    AND (
      (p_label_id IS NOT NULL AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements(saved_view.definition->'labels') AS selected(item)
        WHERE selected.item->>'boardId' = p_board_id::text
          AND selected.item->>'labelId' = p_label_id::text
      ))
      OR (p_label_id IS NULL AND (
        saved_view.definition->>'boardId' = p_board_id::text
        OR saved_view.definition->>'filterBoardId' = p_board_id::text
        OR EXISTS (
          SELECT 1
          FROM jsonb_array_elements(saved_view.definition->'labels') AS selected(item)
          WHERE selected.item->>'boardId' = p_board_id::text
        )
        OR (p_user_id IS NOT NULL
          AND saved_view.definition->>'assigneeId' = p_user_id::text)
      ))
    );
$$;

CREATE FUNCTION public.saved_view_reference_transition_internal_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_old jsonb := to_jsonb(OLD);
  v_board_id uuid;
  v_label_id uuid;
  v_user_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'board_labels' THEN
    v_board_id := (v_old->>'board_id')::uuid;
    v_label_id := (v_old->>'id')::uuid;
  ELSIF TG_TABLE_NAME = 'board_memberships' THEN
    v_board_id := (v_old->>'board_id')::uuid;
    v_user_id := (v_old->>'user_id')::uuid;
  ELSE
    v_board_id := (v_old->>'id')::uuid;
  END IF;

  PERFORM public.mark_saved_views_needing_review_internal_p(
    v_board_id, v_label_id, v_user_id
  );
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER board_labels_saved_view_reference_transition
AFTER UPDATE OF deleted_at, generation_id ON public.board_labels
FOR EACH ROW
WHEN (OLD.deleted_at IS DISTINCT FROM NEW.deleted_at
  OR OLD.generation_id IS DISTINCT FROM NEW.generation_id)
EXECUTE FUNCTION public.saved_view_reference_transition_internal_p();

CREATE TRIGGER board_labels_saved_view_reference_delete
AFTER DELETE ON public.board_labels
FOR EACH ROW
EXECUTE FUNCTION public.saved_view_reference_transition_internal_p();

CREATE TRIGGER board_memberships_saved_view_reference_transition
AFTER UPDATE OF revoked_at ON public.board_memberships
FOR EACH ROW
WHEN (OLD.revoked_at IS DISTINCT FROM NEW.revoked_at)
EXECUTE FUNCTION public.saved_view_reference_transition_internal_p();

CREATE TRIGGER board_memberships_saved_view_reference_delete
AFTER DELETE ON public.board_memberships
FOR EACH ROW
EXECUTE FUNCTION public.saved_view_reference_transition_internal_p();

CREATE TRIGGER boards_saved_view_reference_transition
AFTER UPDATE OF active_generation_id ON public.boards
FOR EACH ROW
WHEN (OLD.active_generation_id IS DISTINCT FROM NEW.active_generation_id)
EXECUTE FUNCTION public.saved_view_reference_transition_internal_p();

CREATE TRIGGER boards_saved_view_reference_delete
AFTER DELETE ON public.boards
FOR EACH ROW
EXECUTE FUNCTION public.saved_view_reference_transition_internal_p();

CREATE FUNCTION public.saved_view_json_internal_p(p_view public.user_saved_views)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT jsonb_build_object(
    'id', p_view.id,
    'context_type', p_view.context_type,
    'name', p_view.name,
    'definition', p_view.definition,
    'version', p_view.version,
    'needs_review', p_view.needs_review,
    'created_at', p_view.created_at,
    'updated_at', p_view.updated_at,
    'deleted_at', p_view.deleted_at
  );
$$;

CREATE FUNCTION public.create_my_saved_view_p(
  p_context_type text,
  p_name text,
  p_definition jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_name_key text;
  v_view public.user_saved_views;
  v_active_count integer;
  v_invalid_references jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.saved_view_context_valid_internal_p(p_context_type)
    OR p_name IS NULL
    OR char_length(p_name) NOT BETWEEN 1 AND 60
    OR btrim(p_name) = ''
    OR NOT public.saved_view_definition_valid_internal_p(p_context_type, p_definition) THEN
    RAISE EXCEPTION 'A valid saved view is required' USING ERRCODE = '22023';
  END IF;

  v_invalid_references := public.saved_view_invalid_references_internal_p(
    v_actor_id, p_definition
  );
  IF jsonb_array_length(v_invalid_references) > 0 THEN
    RETURN jsonb_build_object(
      'status', 'invalid_references',
      'invalid_references', v_invalid_references
    );
  END IF;

  v_name_key := public.saved_view_name_key_internal_p(p_name);
  INSERT INTO public.user_saved_view_actor_locks(user_id)
  VALUES (v_actor_id) ON CONFLICT (user_id) DO NOTHING;
  PERFORM 1 FROM public.user_saved_view_actor_locks AS actor_lock
  WHERE actor_lock.user_id = v_actor_id FOR UPDATE;

  SELECT count(*)::integer INTO v_active_count
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.user_id = v_actor_id AND saved_view.deleted_at IS NULL;
  IF v_active_count >= 50 THEN
    RETURN jsonb_build_object('status', 'limit_reached');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.user_saved_views AS saved_view
    WHERE saved_view.user_id = v_actor_id
      AND saved_view.context_type = p_context_type
      AND saved_view.deleted_at IS NULL
      AND saved_view.name_key = v_name_key
  ) THEN
    RETURN jsonb_build_object('status', 'name_conflict');
  END IF;

  INSERT INTO public.user_saved_views(
    user_id, context_type, name, name_key, definition
  ) VALUES (
    v_actor_id, p_context_type, p_name, v_name_key, p_definition
  ) RETURNING * INTO v_view;

  RETURN jsonb_build_object(
    'status', 'saved', 'view', public.saved_view_json_internal_p(v_view)
  );
END;
$$;

CREATE FUNCTION public.list_my_saved_views_p(p_context_type text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_active jsonb;
  v_deleted jsonb;
  v_view public.user_saved_views;
  v_invalid_references jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF NOT public.saved_view_context_valid_internal_p(p_context_type) THEN
    RAISE EXCEPTION 'A valid saved view context is required'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.user_saved_view_actor_locks(user_id)
  VALUES (v_actor_id) ON CONFLICT (user_id) DO NOTHING;
  PERFORM 1 FROM public.user_saved_view_actor_locks AS actor_lock
  WHERE actor_lock.user_id = v_actor_id FOR UPDATE;

  DELETE FROM public.user_saved_views AS saved_view
  WHERE saved_view.user_id = v_actor_id
    AND saved_view.deleted_at <= clock_timestamp() - interval '7 days';

  FOR v_view IN
    SELECT saved_view.*
    FROM public.user_saved_views AS saved_view
    WHERE saved_view.user_id = v_actor_id
      AND saved_view.context_type = p_context_type
      AND saved_view.deleted_at IS NULL
    FOR UPDATE
  LOOP
    v_invalid_references := public.saved_view_invalid_references_internal_p(
      v_actor_id, v_view.definition
    );
    IF jsonb_array_length(v_invalid_references) > 0
      AND NOT v_view.needs_review THEN
      UPDATE public.user_saved_views AS saved_view
      SET needs_review = true,
          version = saved_view.version + 1,
          updated_at = clock_timestamp()
      WHERE saved_view.id = v_view.id;
    END IF;
  END LOOP;

  SELECT coalesce(jsonb_agg(jsonb_set(
      public.saved_view_json_internal_p(saved_view),
      '{invalid_references}',
      public.saved_view_invalid_references_internal_p(
        v_actor_id, saved_view.definition
      )
    )
      ORDER BY saved_view.created_at, saved_view.id), '[]'::jsonb)
  INTO v_active
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.user_id = v_actor_id
    AND saved_view.context_type = p_context_type
    AND saved_view.deleted_at IS NULL;

  SELECT coalesce(jsonb_agg(jsonb_set(
      public.saved_view_json_internal_p(saved_view),
      '{invalid_references}',
      public.saved_view_invalid_references_internal_p(
        v_actor_id, saved_view.definition
      )
    )
      ORDER BY saved_view.deleted_at DESC, saved_view.id), '[]'::jsonb)
  INTO v_deleted
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.user_id = v_actor_id
    AND saved_view.context_type = p_context_type
    AND saved_view.deleted_at > clock_timestamp() - interval '7 days';

  RETURN jsonb_build_object(
    'status', 'available',
    'context_type', p_context_type,
    'active_views', v_active,
    'deleted_views', v_deleted
  );
END;
$$;

CREATE FUNCTION public.update_my_saved_view_p(
  p_view_id uuid,
  p_expected_version bigint,
  p_name text,
  p_definition jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_view public.user_saved_views;
  v_name_key text;
  v_invalid_references jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF p_view_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1
    OR p_name IS NULL OR char_length(p_name) NOT BETWEEN 1 AND 60
    OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'A valid saved view update is required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.user_saved_view_actor_locks(user_id)
  VALUES (v_actor_id) ON CONFLICT (user_id) DO NOTHING;
  PERFORM 1 FROM public.user_saved_view_actor_locks AS actor_lock
  WHERE actor_lock.user_id = v_actor_id FOR UPDATE;

  SELECT * INTO v_view
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.id = p_view_id AND saved_view.user_id = v_actor_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_view.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'deleted', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;
  IF v_view.version <> p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;
  IF NOT public.saved_view_definition_valid_internal_p(
      v_view.context_type, p_definition
    ) THEN
    RAISE EXCEPTION 'A valid saved view definition is required'
      USING ERRCODE = '22023';
  END IF;
  v_invalid_references := public.saved_view_invalid_references_internal_p(
    v_actor_id, p_definition
  );
  IF jsonb_array_length(v_invalid_references) > 0 THEN
    RETURN jsonb_build_object(
      'status', 'invalid_references',
      'invalid_references', v_invalid_references,
      'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;

  v_name_key := public.saved_view_name_key_internal_p(p_name);
  IF EXISTS (
    SELECT 1 FROM public.user_saved_views AS saved_view
    WHERE saved_view.user_id = v_actor_id
      AND saved_view.context_type = v_view.context_type
      AND saved_view.deleted_at IS NULL
      AND saved_view.id <> p_view_id
      AND saved_view.name_key = v_name_key
  ) THEN
    RETURN jsonb_build_object('status', 'name_conflict');
  END IF;

  UPDATE public.user_saved_views AS saved_view
  SET name = p_name,
      name_key = v_name_key,
      definition = p_definition,
      version = saved_view.version + 1,
      needs_review = false,
      updated_at = clock_timestamp()
  WHERE saved_view.id = p_view_id
  RETURNING * INTO v_view;
  RETURN jsonb_build_object(
    'status', 'saved', 'view', public.saved_view_json_internal_p(v_view)
  );
END;
$$;

CREATE FUNCTION public.delete_my_saved_view_p(
  p_view_id uuid,
  p_expected_version bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_view public.user_saved_views;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF p_view_id IS NULL OR p_expected_version IS NULL OR p_expected_version < 1 THEN
    RAISE EXCEPTION 'A saved view and version are required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.user_saved_view_actor_locks(user_id)
  VALUES (v_actor_id) ON CONFLICT (user_id) DO NOTHING;
  PERFORM 1 FROM public.user_saved_view_actor_locks AS actor_lock
  WHERE actor_lock.user_id = v_actor_id FOR UPDATE;

  SELECT * INTO v_view
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.id = p_view_id AND saved_view.user_id = v_actor_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_view.deleted_at IS NOT NULL THEN
    RETURN jsonb_build_object(
      'status', 'deleted', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;
  IF v_view.version <> p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;

  UPDATE public.user_saved_views AS saved_view
  SET deleted_at = clock_timestamp(),
      version = saved_view.version + 1,
      updated_at = clock_timestamp()
  WHERE saved_view.id = p_view_id
  RETURNING * INTO v_view;
  RETURN jsonb_build_object(
    'status', 'deleted', 'view', public.saved_view_json_internal_p(v_view)
  );
END;
$$;

CREATE FUNCTION public.preview_restore_my_saved_view_p(
  p_context_type text,
  p_view_id uuid,
  p_name text,
  p_definition jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_view public.user_saved_views;
  v_name_key text;
  v_active_count integer;
  v_reasons text[] := ARRAY[]::text[];
  v_invalid_references jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF NOT public.saved_view_context_valid_internal_p(p_context_type)
    OR p_view_id IS NULL
    OR p_name IS NULL
    OR char_length(p_name) NOT BETWEEN 1 AND 60
    OR btrim(p_name) = ''
    OR NOT public.saved_view_definition_valid_internal_p(p_context_type, p_definition) THEN
    RAISE EXCEPTION 'A valid saved view recovery proposal is required'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.user_saved_view_actor_locks(user_id)
  VALUES (v_actor_id) ON CONFLICT (user_id) DO NOTHING;
  PERFORM 1 FROM public.user_saved_view_actor_locks AS actor_lock
  WHERE actor_lock.user_id = v_actor_id FOR UPDATE;

  SELECT * INTO v_view
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.id = p_view_id
    AND saved_view.user_id = v_actor_id
    AND saved_view.context_type = p_context_type
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_view.deleted_at IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'active', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;
  IF v_view.deleted_at <= clock_timestamp() - interval '7 days' THEN
    RETURN jsonb_build_object(
      'status', 'expired', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;

  v_name_key := public.saved_view_name_key_internal_p(p_name);
  SELECT count(*)::integer INTO v_active_count
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.user_id = v_actor_id AND saved_view.deleted_at IS NULL;
  IF v_active_count >= 50 THEN
    v_reasons := array_append(v_reasons, 'active_limit');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.user_saved_views AS saved_view
    WHERE saved_view.user_id = v_actor_id
      AND saved_view.context_type = p_context_type
      AND saved_view.deleted_at IS NULL
      AND saved_view.name_key = v_name_key
  ) THEN
    v_reasons := array_append(v_reasons, 'name_conflict');
  END IF;
  v_invalid_references := public.saved_view_invalid_references_internal_p(
    v_actor_id, p_definition
  );
  IF jsonb_array_length(v_invalid_references) > 0 THEN
    v_reasons := array_append(v_reasons, 'invalid_references');
  END IF;

  RETURN jsonb_build_object(
    'status', 'preview',
    'can_restore', cardinality(v_reasons) = 0,
    'reasons', to_jsonb(v_reasons),
    'invalid_references', v_invalid_references,
    'view', public.saved_view_json_internal_p(v_view),
    'proposed_name', p_name,
    'proposed_definition', p_definition,
    'active_count', v_active_count
  );
END;
$$;

CREATE FUNCTION public.restore_my_saved_view_p(
  p_context_type text,
  p_view_id uuid,
  p_expected_version bigint,
  p_name text,
  p_definition jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_view public.user_saved_views;
  v_name_key text;
  v_active_count integer;
  v_invalid_references jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF NOT public.saved_view_context_valid_internal_p(p_context_type)
    OR p_view_id IS NULL
    OR p_expected_version IS NULL
    OR p_expected_version < 1
    OR p_name IS NULL
    OR char_length(p_name) NOT BETWEEN 1 AND 60
    OR btrim(p_name) = ''
    OR NOT public.saved_view_definition_valid_internal_p(p_context_type, p_definition) THEN
    RAISE EXCEPTION 'A valid saved view recovery confirmation is required'
      USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.user_saved_view_actor_locks(user_id)
  VALUES (v_actor_id) ON CONFLICT (user_id) DO NOTHING;
  PERFORM 1 FROM public.user_saved_view_actor_locks AS actor_lock
  WHERE actor_lock.user_id = v_actor_id FOR UPDATE;

  SELECT * INTO v_view
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.id = p_view_id
    AND saved_view.user_id = v_actor_id
    AND saved_view.context_type = p_context_type
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_view.deleted_at IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'active', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;
  IF v_view.deleted_at <= clock_timestamp() - interval '7 days' THEN
    RETURN jsonb_build_object(
      'status', 'expired', 'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;
  IF v_view.version <> p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict',
      'reason', 'stale_version',
      'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;

  v_invalid_references := public.saved_view_invalid_references_internal_p(
    v_actor_id, p_definition
  );
  IF jsonb_array_length(v_invalid_references) > 0 THEN
    RETURN jsonb_build_object(
      'status', 'invalid_references',
      'invalid_references', v_invalid_references,
      'view', public.saved_view_json_internal_p(v_view)
    );
  END IF;

  SELECT count(*)::integer INTO v_active_count
  FROM public.user_saved_views AS saved_view
  WHERE saved_view.user_id = v_actor_id AND saved_view.deleted_at IS NULL;
  IF v_active_count >= 50 THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'active_limit');
  END IF;

  v_name_key := public.saved_view_name_key_internal_p(p_name);
  IF EXISTS (
    SELECT 1 FROM public.user_saved_views AS saved_view
    WHERE saved_view.user_id = v_actor_id
      AND saved_view.context_type = p_context_type
      AND saved_view.deleted_at IS NULL
      AND saved_view.name_key = v_name_key
  ) THEN
    RETURN jsonb_build_object('status', 'conflict', 'reason', 'name_conflict');
  END IF;

  UPDATE public.user_saved_views AS saved_view
  SET name = p_name,
      name_key = v_name_key,
      definition = p_definition,
      needs_review = false,
      deleted_at = NULL,
      version = saved_view.version + 1,
      updated_at = clock_timestamp()
  WHERE saved_view.id = p_view_id
  RETURNING * INTO v_view;
  RETURN jsonb_build_object(
    'status', 'restored', 'view', public.saved_view_json_internal_p(v_view)
  );
END;
$$;

CREATE FUNCTION public.purge_expired_saved_views_p(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_purged integer;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'Purge limit must be between 1 and 1000'
      USING ERRCODE = '22023';
  END IF;

  WITH expired AS (
    SELECT saved_view.id
    FROM public.user_saved_views AS saved_view
    WHERE saved_view.deleted_at <= clock_timestamp() - interval '7 days'
    ORDER BY saved_view.deleted_at, saved_view.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.user_saved_views AS saved_view
  USING expired
  WHERE saved_view.id = expired.id;
  GET DIAGNOSTICS v_purged = ROW_COUNT;
  RETURN v_purged;
END;
$$;

REVOKE ALL ON FUNCTION public.saved_view_name_key_internal_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.saved_view_context_valid_internal_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.saved_view_definition_valid_internal_p(text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.saved_view_invalid_references_internal_p(uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.saved_view_json_internal_p(public.user_saved_views)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.mark_saved_views_needing_review_internal_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.saved_view_reference_transition_internal_p()
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_my_saved_view_p(text, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_my_saved_views_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_my_saved_view_p(uuid, bigint, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_my_saved_view_p(uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.preview_restore_my_saved_view_p(text, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_my_saved_view_p(text, uuid, bigint, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_saved_views_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_my_saved_view_p(text, text, jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_saved_views_p(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_my_saved_view_p(uuid, bigint, text, jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_my_saved_view_p(uuid, bigint)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.preview_restore_my_saved_view_p(text, uuid, text, jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_my_saved_view_p(text, uuid, bigint, text, jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.purge_expired_saved_views_p(integer)
  TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
