BEGIN;

CREATE TABLE public.user_view_preference_contexts (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  context_type text NOT NULL CHECK (
    context_type IN (
      'board',
      'my_tasks',
      'search_all',
      'search_my_tasks',
      'search_board'
    )
  ),
  board_id uuid REFERENCES public.boards(id) ON DELETE CASCADE,
  CONSTRAINT user_view_preference_contexts_board CHECK (
    (context_type IN ('board', 'search_board')) = (board_id IS NOT NULL)
  ),
  CONSTRAINT user_view_preference_contexts_identity UNIQUE NULLS NOT DISTINCT (
    user_id, context_type, board_id
  )
);

ALTER TABLE public.user_view_preference_contexts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_view_preference_contexts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.user_view_preferences (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  context_type text NOT NULL CHECK (
    context_type IN (
      'board',
      'my_tasks',
      'search_all',
      'search_my_tasks',
      'search_board'
    )
  ),
  board_id uuid REFERENCES public.boards(id) ON DELETE CASCADE,
  preference_key text NOT NULL CHECK (
    preference_key IN (
      'completed_view',
      'filter_board',
      'filter_due',
      'filter_labels',
      'filter_priority',
      'filter_responsibility',
      'include_completed',
      'include_history',
      'labels',
      'order'
    )
  ),
  value jsonb NOT NULL,
  version integer NOT NULL CHECK (version > 0),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT user_view_preferences_context_board CHECK (
    (context_type IN ('board', 'search_board')) = (board_id IS NOT NULL)
  ),
  CONSTRAINT user_view_preferences_context_key CHECK (
    (context_type = 'board' AND preference_key IN ('labels', 'completed_view'))
    OR (context_type = 'my_tasks' AND preference_key IN ('order', 'completed_view'))
    OR (context_type IN ('search_all', 'search_my_tasks', 'search_board')
      AND preference_key IN (
        'filter_board',
        'filter_due',
        'filter_labels',
        'filter_priority',
        'filter_responsibility',
        'include_completed',
        'include_history',
        'order'
      ))
  ),
  CONSTRAINT user_view_preferences_context_identity UNIQUE NULLS NOT DISTINCT (
    user_id,
    context_type,
    board_id,
    preference_key
  )
);

ALTER TABLE public.user_view_preferences ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.user_view_preferences
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.view_preference_keys_internal_p(p_context_type text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT CASE p_context_type
    WHEN 'board' THEN ARRAY['completed_view', 'labels']::text[]
    WHEN 'my_tasks' THEN ARRAY['completed_view', 'order']::text[]
    WHEN 'search_all' THEN ARRAY[
      'filter_board', 'filter_due', 'filter_labels', 'filter_priority',
      'filter_responsibility', 'include_completed', 'include_history', 'order'
    ]::text[]
    WHEN 'search_my_tasks' THEN ARRAY[
      'filter_board', 'filter_due', 'filter_labels', 'filter_priority',
      'include_completed', 'include_history', 'order'
    ]::text[]
    WHEN 'search_board' THEN ARRAY[
      'filter_board', 'filter_due', 'filter_labels', 'filter_priority',
      'filter_responsibility', 'include_completed', 'include_history', 'order'
    ]::text[]
    ELSE NULL
  END;
$$;

CREATE FUNCTION public.view_preference_default_internal_p(
  p_context_type text,
  p_preference_key text
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT CASE
    WHEN p_preference_key = 'labels' THEN '[]'::jsonb
    WHEN p_preference_key = 'completed_view' AND p_context_type = 'board'
      THEN '{"collapsed":[],"hidden":[]}'::jsonb
    WHEN p_preference_key = 'completed_view'
      THEN '{"expanded":true,"visible":true}'::jsonb
    WHEN p_preference_key = 'order' THEN '"due"'::jsonb
    WHEN p_preference_key IN ('filter_board', 'filter_due', 'filter_priority')
      THEN 'null'::jsonb
    WHEN p_preference_key = 'filter_labels' THEN '[]'::jsonb
    WHEN p_preference_key = 'filter_responsibility'
      THEN '{"assignee_id":null,"unassigned":false}'::jsonb
    WHEN p_preference_key IN ('include_completed', 'include_history')
      THEN 'false'::jsonb
    ELSE NULL
  END;
$$;

CREATE FUNCTION public.view_preference_value_valid_internal_p(
  p_context_type text,
  p_preference_key text,
  p_value jsonb
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_count integer;
  v_valid_count integer;
  v_distinct_count integer;
  v_assignee_id text;
BEGIN
  IF p_value IS NULL THEN
    RETURN false;
  END IF;

  IF p_preference_key = 'labels' AND p_context_type = 'board' THEN
    IF jsonb_typeof(p_value) <> 'array'
      OR jsonb_array_length(p_value) > 100 THEN
      RETURN false;
    END IF;
    SELECT count(*),
      count(*) FILTER (
        WHERE jsonb_typeof(label_id) = 'string'
          AND label_id #>> '{}' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      ),
      count(DISTINCT lower(label_id #>> '{}'))
    INTO v_count, v_valid_count, v_distinct_count
    FROM jsonb_array_elements(p_value) AS labels(label_id);
    RETURN v_count = v_valid_count AND v_count = v_distinct_count;
  END IF;

  IF p_preference_key = 'completed_view' AND p_context_type = 'board' THEN
    IF jsonb_typeof(p_value) <> 'object'
      OR (SELECT count(*) FROM jsonb_object_keys(p_value)) <> 2
      OR NOT (p_value ? 'hidden')
      OR NOT (p_value ? 'collapsed')
      OR jsonb_typeof(p_value->'hidden') <> 'array'
      OR jsonb_typeof(p_value->'collapsed') <> 'array'
      OR jsonb_array_length(p_value->'hidden') > 500
      OR jsonb_array_length(p_value->'collapsed') > 500 THEN
      RETURN false;
    END IF;
    SELECT count(*), count(*) FILTER (
      WHERE jsonb_typeof(column_id) = 'string'
        AND column_id #>> '{}' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ), count(DISTINCT lower(column_id #>> '{}'))
    INTO v_count, v_valid_count, v_distinct_count
    FROM jsonb_array_elements(p_value->'hidden') AS columns(column_id);
    IF v_count <> v_valid_count OR v_count <> v_distinct_count THEN
      RETURN false;
    END IF;
    SELECT count(*), count(*) FILTER (
      WHERE jsonb_typeof(column_id) = 'string'
        AND column_id #>> '{}' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ), count(DISTINCT lower(column_id #>> '{}'))
    INTO v_count, v_valid_count, v_distinct_count
    FROM jsonb_array_elements(p_value->'collapsed') AS columns(column_id);
    RETURN v_count = v_valid_count AND v_count = v_distinct_count;
  END IF;

  IF p_preference_key = 'completed_view' AND p_context_type = 'my_tasks' THEN
    RETURN jsonb_typeof(p_value) = 'object'
      AND (SELECT count(*) FROM jsonb_object_keys(p_value)) = 2
      AND p_value ? 'visible'
      AND p_value ? 'expanded'
      AND jsonb_typeof(p_value->'visible') = 'boolean'
      AND jsonb_typeof(p_value->'expanded') = 'boolean';
  END IF;

  IF p_preference_key = 'order' THEN
    RETURN jsonb_typeof(p_value) = 'string'
      AND p_value #>> '{}' IN ('due', 'created');
  END IF;

  IF p_preference_key = 'filter_board' THEN
    RETURN p_value = 'null'::jsonb
      OR (jsonb_typeof(p_value) = 'string'
        AND p_value #>> '{}' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
  END IF;

  IF p_preference_key = 'filter_due' THEN
    RETURN p_value = 'null'::jsonb
      OR (jsonb_typeof(p_value) = 'string'
        AND p_value #>> '{}' IN ('today', 'overdue', 'next_7_days', 'no_date'));
  END IF;

  IF p_preference_key = 'filter_priority' THEN
    RETURN p_value = 'null'::jsonb
      OR (jsonb_typeof(p_value) = 'string'
        AND p_value #>> '{}' IN ('low', 'medium', 'high', 'urgent'));
  END IF;

  IF p_preference_key = 'filter_responsibility' THEN
    IF jsonb_typeof(p_value) <> 'object'
      OR (SELECT count(*) FROM jsonb_object_keys(p_value)) <> 2
      OR NOT (p_value ? 'assignee_id')
      OR NOT (p_value ? 'unassigned')
      OR jsonb_typeof(p_value->'unassigned') <> 'boolean' THEN
      RETURN false;
    END IF;
    v_assignee_id := p_value->>'assignee_id';
    RETURN (p_value->'assignee_id' = 'null'::jsonb
        OR (jsonb_typeof(p_value->'assignee_id') = 'string'
          AND v_assignee_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
      AND NOT ((p_value->>'unassigned')::boolean AND v_assignee_id IS NOT NULL);
  END IF;

  IF p_preference_key = 'filter_labels' THEN
    IF jsonb_typeof(p_value) <> 'array'
      OR jsonb_array_length(p_value) > 100 THEN
      RETURN false;
    END IF;
    SELECT count(*), count(*) FILTER (
      WHERE jsonb_typeof(filter_row) = 'object'
        AND (SELECT count(*) FROM jsonb_object_keys(filter_row)) = 2
        AND jsonb_typeof(filter_row->'board_id') = 'string'
        AND filter_row->>'board_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        AND jsonb_typeof(filter_row->'label_id') = 'string'
        AND filter_row->>'label_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ), count(DISTINCT lower(filter_row->>'board_id') || ':' || lower(filter_row->>'label_id'))
    INTO v_count, v_valid_count, v_distinct_count
    FROM jsonb_array_elements(p_value) AS labels(filter_row);
    RETURN v_count = v_valid_count AND v_count = v_distinct_count;
  END IF;

  IF p_preference_key IN ('include_completed', 'include_history') THEN
    RETURN jsonb_typeof(p_value) = 'boolean';
  END IF;

  RETURN false;
END;
$$;

CREATE FUNCTION public.get_my_view_preferences_p(
  p_context_type text,
  p_board_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_keys text[];
  v_preferences jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;

  v_keys := public.view_preference_keys_internal_p(p_context_type);
  IF v_keys IS NULL
    OR ((p_context_type IN ('board', 'search_board')) <> (p_board_id IS NOT NULL)) THEN
    RAISE EXCEPTION 'A valid preference context is required' USING ERRCODE = '22023';
  END IF;

  IF p_board_id IS NOT NULL AND NOT public.is_board_member(p_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT jsonb_object_agg(
    allowed.preference_key,
    jsonb_build_object(
      'value', coalesce(
        preference.value,
        public.view_preference_default_internal_p(
          p_context_type, allowed.preference_key
        )
      ),
      'version', coalesce(preference.version, 0)
    )
  )
  INTO v_preferences
  FROM unnest(v_keys) AS allowed(preference_key)
  LEFT JOIN public.user_view_preferences AS preference
    ON preference.user_id = v_actor_id
    AND preference.context_type = p_context_type
    AND preference.board_id IS NOT DISTINCT FROM p_board_id
    AND preference.preference_key = allowed.preference_key;

  RETURN jsonb_build_object(
    'status', 'available',
    'context_type', p_context_type,
    'board_id', p_board_id,
    'preferences', coalesce(v_preferences, '{}'::jsonb)
  );
END;
$$;

CREATE FUNCTION public.set_my_view_preference_p(
  p_context_type text,
  p_board_id uuid,
  p_preference_key text,
  p_value jsonb,
  p_expected_version integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_keys text[];
  v_current_value jsonb;
  v_current_version integer;
  v_saved_version integer;
  v_reference_id uuid;
  v_board record;
  v_context_lock uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;

  v_keys := public.view_preference_keys_internal_p(p_context_type);
  IF v_keys IS NULL
    OR ((p_context_type IN ('board', 'search_board')) <> (p_board_id IS NOT NULL))
    OR NOT (p_preference_key = ANY(v_keys))
    OR p_expected_version IS NULL OR p_expected_version < 0
    OR NOT public.view_preference_value_valid_internal_p(
      p_context_type, p_preference_key, p_value
    ) THEN
    RAISE EXCEPTION 'A supported preference and version are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_board_id IS NOT NULL THEN
    SELECT board.id INTO v_board
    FROM public.boards AS board
    JOIN public.board_memberships AS membership
      ON membership.board_id = board.id
    WHERE board.id = p_board_id
      AND membership.user_id = v_actor_id
      AND membership.revoked_at IS NULL
    FOR SHARE OF board, membership;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'unavailable');
    END IF;
  END IF;

  IF p_context_type IN ('search_all', 'search_my_tasks', 'search_board') THEN
    IF p_preference_key = 'filter_board' AND p_value <> 'null'::jsonb THEN
      v_reference_id := (p_value #>> '{}')::uuid;
      IF NOT public.is_board_member(v_reference_id) THEN
        RETURN jsonb_build_object(
          'status', 'invalid_reference',
          'preference_key', p_preference_key
        );
      END IF;
    ELSIF p_preference_key = 'filter_labels' THEN
      IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_value) AS filter_item(item)
        WHERE NOT public.is_board_member((item->>'board_id')::uuid)
          OR (p_context_type = 'search_board'
            AND (item->>'board_id')::uuid <> p_board_id)
      ) THEN
        RETURN jsonb_build_object(
          'status', 'invalid_reference',
          'preference_key', p_preference_key
        );
      END IF;
    ELSIF p_preference_key = 'filter_responsibility'
      AND p_value->'assignee_id' <> 'null'::jsonb THEN
      v_reference_id := (p_value->>'assignee_id')::uuid;
      IF NOT EXISTS (
        SELECT 1
        FROM public.board_memberships AS membership
        WHERE membership.user_id = v_reference_id
          AND membership.revoked_at IS NULL
          AND (p_context_type <> 'search_board'
            OR membership.board_id = p_board_id)
      ) THEN
        RETURN jsonb_build_object(
          'status', 'invalid_reference',
          'preference_key', p_preference_key
        );
      END IF;
    END IF;
  END IF;

  INSERT INTO public.user_view_preference_contexts (
    user_id, context_type, board_id
  ) VALUES (v_actor_id, p_context_type, p_board_id)
  ON CONFLICT (user_id, context_type, board_id) DO NOTHING;

  SELECT context.user_id INTO v_context_lock
  FROM public.user_view_preference_contexts AS context
  WHERE context.user_id = v_actor_id
    AND context.context_type = p_context_type
    AND context.board_id IS NOT DISTINCT FROM p_board_id
  FOR UPDATE;

  IF p_expected_version = 0 THEN
    INSERT INTO public.user_view_preferences (
      user_id,
      context_type,
      board_id,
      preference_key,
      value,
      version,
      updated_at
    ) VALUES (
      v_actor_id,
      p_context_type,
      p_board_id,
      p_preference_key,
      p_value,
      1,
      clock_timestamp()
    )
    ON CONFLICT (user_id, context_type, board_id, preference_key) DO NOTHING
    RETURNING version INTO v_saved_version;
  ELSE
    UPDATE public.user_view_preferences AS current_preference
    SET value = p_value,
        version = current_preference.version + 1,
        updated_at = clock_timestamp()
    WHERE current_preference.user_id = v_actor_id
      AND current_preference.context_type = p_context_type
      AND current_preference.board_id IS NOT DISTINCT FROM p_board_id
      AND current_preference.preference_key = p_preference_key
      AND current_preference.version = p_expected_version
    RETURNING version INTO v_saved_version;
  END IF;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'status', 'saved',
      'preference_key', p_preference_key,
      'value', p_value,
      'version', v_saved_version
    );
  END IF;

  SELECT preference.value, preference.version
  INTO v_current_value, v_current_version
  FROM public.user_view_preferences AS preference
  WHERE preference.user_id = v_actor_id
    AND preference.context_type = p_context_type
    AND preference.board_id IS NOT DISTINCT FROM p_board_id
    AND preference.preference_key = p_preference_key;

  RETURN jsonb_build_object(
    'status', 'conflict',
    'preference_key', p_preference_key,
    'value', coalesce(
      v_current_value,
      public.view_preference_default_internal_p(p_context_type, p_preference_key)
    ),
    'version', coalesce(v_current_version, 0)
  );
END;
$$;

CREATE FUNCTION public.reset_my_view_preferences_p(
  p_context_type text,
  p_board_id uuid,
  p_expected_versions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_keys text[];
  v_key text;
  v_board record;
  v_context_lock uuid;
  v_current_version integer;
  v_matches boolean := true;
  v_preferences jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;

  v_keys := public.view_preference_keys_internal_p(p_context_type);
  IF v_keys IS NULL
    OR ((p_context_type IN ('board', 'search_board')) <> (p_board_id IS NOT NULL))
    OR p_expected_versions IS NULL
    OR jsonb_typeof(p_expected_versions) <> 'object'
    OR (SELECT count(*) FROM jsonb_object_keys(p_expected_versions)) <> cardinality(v_keys)
    OR EXISTS (
      SELECT 1
      FROM jsonb_each(p_expected_versions) AS supplied(preference_key, version)
      WHERE NOT (supplied.preference_key = ANY(v_keys))
        OR jsonb_typeof(supplied.version) <> 'number'
        OR supplied.version #>> '{}' !~ '^(0|[1-9][0-9]*)$'
    )
    OR EXISTS (
      SELECT 1 FROM unnest(v_keys) AS expected(preference_key)
      WHERE NOT (p_expected_versions ? expected.preference_key)
    ) THEN
    RAISE EXCEPTION 'Expected versions for this context are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_board_id IS NOT NULL THEN
    SELECT board.id INTO v_board
    FROM public.boards AS board
    JOIN public.board_memberships AS membership
      ON membership.board_id = board.id
    WHERE board.id = p_board_id
      AND membership.user_id = v_actor_id
      AND membership.revoked_at IS NULL
    FOR SHARE OF board, membership;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'unavailable');
    END IF;
  END IF;

  INSERT INTO public.user_view_preference_contexts (
    user_id, context_type, board_id
  ) VALUES (v_actor_id, p_context_type, p_board_id)
  ON CONFLICT (user_id, context_type, board_id) DO NOTHING;

  SELECT context.user_id INTO v_context_lock
  FROM public.user_view_preference_contexts AS context
  WHERE context.user_id = v_actor_id
    AND context.context_type = p_context_type
    AND context.board_id IS NOT DISTINCT FROM p_board_id
  FOR UPDATE;

  FOREACH v_key IN ARRAY v_keys LOOP
    SELECT preference.version INTO v_current_version
    FROM public.user_view_preferences AS preference
    WHERE preference.user_id = v_actor_id
      AND preference.context_type = p_context_type
      AND preference.board_id IS NOT DISTINCT FROM p_board_id
      AND preference.preference_key = v_key;
    IF coalesce(v_current_version, 0) <>
      (p_expected_versions->>v_key)::integer THEN
      v_matches := false;
    END IF;
    v_current_version := NULL;
  END LOOP;

  IF NOT v_matches THEN
    SELECT jsonb_object_agg(
      allowed.preference_key,
      jsonb_build_object(
        'value', coalesce(
          preference.value,
          public.view_preference_default_internal_p(
            p_context_type, allowed.preference_key
          )
        ),
        'version', coalesce(preference.version, 0)
      )
    ) INTO v_preferences
    FROM unnest(v_keys) AS allowed(preference_key)
    LEFT JOIN public.user_view_preferences AS preference
      ON preference.user_id = v_actor_id
      AND preference.context_type = p_context_type
      AND preference.board_id IS NOT DISTINCT FROM p_board_id
      AND preference.preference_key = allowed.preference_key;
    RETURN jsonb_build_object(
      'status', 'conflict',
      'context_type', p_context_type,
      'board_id', p_board_id,
      'preferences', v_preferences
    );
  END IF;

  FOREACH v_key IN ARRAY v_keys LOOP
    INSERT INTO public.user_view_preferences AS current_preference (
      user_id, context_type, board_id, preference_key, value, version, updated_at
    ) VALUES (
      v_actor_id,
      p_context_type,
      p_board_id,
      v_key,
      public.view_preference_default_internal_p(p_context_type, v_key),
      1,
      clock_timestamp()
    )
    ON CONFLICT (user_id, context_type, board_id, preference_key) DO UPDATE
    SET value = EXCLUDED.value,
        version = current_preference.version + 1,
        updated_at = clock_timestamp();
  END LOOP;

  SELECT jsonb_object_agg(
    preference.preference_key,
    jsonb_build_object('value', preference.value, 'version', preference.version)
  ) INTO v_preferences
  FROM public.user_view_preferences AS preference
  WHERE preference.user_id = v_actor_id
    AND preference.context_type = p_context_type
    AND preference.board_id IS NOT DISTINCT FROM p_board_id;

  RETURN jsonb_build_object(
    'status', 'saved',
    'context_type', p_context_type,
    'board_id', p_board_id,
    'preferences', v_preferences
  );
END;
$$;

REVOKE ALL ON FUNCTION public.view_preference_keys_internal_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.view_preference_default_internal_p(text, text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.view_preference_value_valid_internal_p(text, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_view_preferences_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_my_view_preference_p(text, uuid, text, jsonb, integer)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.reset_my_view_preferences_p(text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_view_preferences_p(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_my_view_preference_p(text, uuid, text, jsonb, integer)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_my_view_preferences_p(text, uuid, jsonb)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
