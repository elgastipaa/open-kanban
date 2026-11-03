BEGIN;

-- A task search cursor is valid only for the accessible board content revision
-- that produced it. The existing search implementation remains the single
-- source of matching, authorization, ordering, and keyset pagination behavior.
CREATE FUNCTION public.search_unified_page_p(
  p_query text,
  p_scope text DEFAULT 'all',
  p_scope_board_id uuid DEFAULT NULL,
  p_filter_board_id uuid DEFAULT NULL,
  p_include_completed boolean DEFAULT false,
  p_include_history boolean DEFAULT false,
  p_priority text DEFAULT NULL,
  p_assignee_id uuid DEFAULT NULL,
  p_unassigned boolean DEFAULT false,
  p_due_filter text DEFAULT NULL,
  p_label_filters jsonb DEFAULT '[]'::jsonb,
  p_order text DEFAULT 'due',
  p_mode text DEFAULT 'suggestions',
  p_limit integer DEFAULT 20,
  p_cursor jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_content_revision text;
  v_revision text;
  v_base_cursor jsonb := p_cursor;
  v_result jsonb;
  v_cursor_created timestamptz;
  v_cursor_id uuid;
  v_cursor_due date;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'results', '[]'::jsonb,
      'has_more', false, 'next_cursor', NULL
    );
  END IF;
  IF p_query IS NULL OR pg_catalog.length(pg_catalog.btrim(p_query)) > 200
    OR p_scope NOT IN ('all', 'board', 'my_tasks')
    OR (p_scope = 'board' AND p_scope_board_id IS NULL)
    OR (p_scope <> 'board' AND p_scope_board_id IS NOT NULL)
    OR p_mode NOT IN ('suggestions', 'tasks')
    OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR p_order NOT IN ('due', 'created')
    OR (p_priority IS NOT NULL AND p_priority NOT IN ('low', 'medium', 'high', 'urgent'))
    OR (p_due_filter IS NOT NULL AND p_due_filter NOT IN (
      'today', 'overdue', 'next_7_days', 'no_date'
    )) THEN
    RAISE EXCEPTION 'Revisa los filtros de búsqueda' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_typeof(p_label_filters) IS DISTINCT FROM 'array'
    OR pg_catalog.jsonb_array_length(p_label_filters) > 100
    OR EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
      WHERE pg_catalog.jsonb_typeof(selected.item) IS DISTINCT FROM 'object'
        OR NOT (selected.item ?& ARRAY['board_id', 'label_id'])
        OR selected.item - ARRAY['board_id', 'label_id'] <> '{}'::jsonb
        OR pg_catalog.jsonb_typeof(selected.item->'board_id') IS DISTINCT FROM 'string'
        OR pg_catalog.jsonb_typeof(selected.item->'label_id') IS DISTINCT FROM 'string'
        OR selected.item->>'board_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        OR selected.item->>'label_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ) THEN
    RAISE EXCEPTION 'Revisa las etiquetas elegidas para la búsqueda'
      USING ERRCODE = '22023';
  END IF;

  -- Access and filter checks run before cursor comparison so a stale cursor
  -- cannot turn removed access into a successful page response.
  IF p_scope = 'board' AND NOT EXISTS (
    SELECT 1 FROM public.boards AS board
    WHERE board.id = p_scope_board_id AND public.is_board_member(board.id)
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'results', '[]'::jsonb,
      'has_more', false, 'next_cursor', NULL
    );
  END IF;
  IF p_filter_board_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.boards AS board
    WHERE board.id = p_filter_board_id AND public.is_board_member(board.id)
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'results', '[]'::jsonb,
      'has_more', false, 'next_cursor', NULL
    );
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.board_labels AS label
      JOIN public.boards AS board
        ON board.id = label.board_id
        AND board.active_generation_id = label.generation_id
      WHERE label.id::text = selected.item->>'label_id'
        AND board.id::text = selected.item->>'board_id'
        AND label.deleted_at IS NULL
        AND public.is_board_member(board.id)
    )
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'invalid_filter', 'results', '[]'::jsonb,
      'has_more', false, 'next_cursor', NULL
    );
  END IF;

  IF p_cursor IS NOT NULL THEN
    IF p_mode <> 'tasks'
      OR pg_catalog.jsonb_typeof(p_cursor) IS DISTINCT FROM 'object'
      OR NOT (p_cursor ?& ARRAY['created_at', 'id'])
      OR (p_cursor ? 'revision' AND (
        pg_catalog.jsonb_typeof(p_cursor->'revision') IS DISTINCT FROM 'string'
        OR p_cursor->>'revision' !~ '^[0-9a-f]{32}$'
      ))
      OR pg_catalog.jsonb_typeof(p_cursor->'created_at') IS DISTINCT FROM 'string'
      OR pg_catalog.jsonb_typeof(p_cursor->'id') IS DISTINCT FROM 'string'
      OR p_cursor->>'id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR (p_order = 'due' AND (
        NOT (p_cursor ? 'due_on')
        OR (pg_catalog.jsonb_typeof(p_cursor->'due_on') NOT IN ('string', 'null'))
        OR (p_cursor->>'due_on' IS NOT NULL
          AND p_cursor->>'due_on' !~ '^\d{4}-\d{2}-\d{2}$')
        OR (p_cursor - ARRAY['due_on', 'created_at', 'id', 'revision']) <> '{}'::jsonb
      ))
      OR (p_order = 'created' AND (
        p_cursor ? 'due_on'
        OR (p_cursor - ARRAY['created_at', 'id', 'revision']) <> '{}'::jsonb
      )) THEN
      RAISE EXCEPTION 'Revisa la página de búsqueda antes de continuar'
        USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_cursor_created := (p_cursor->>'created_at')::timestamptz;
      v_cursor_id := (p_cursor->>'id')::uuid;
      IF p_order = 'due' AND p_cursor->>'due_on' IS NOT NULL THEN
        v_cursor_due := (p_cursor->>'due_on')::date;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Revisa la página de búsqueda antes de continuar'
        USING ERRCODE = '22023';
    END;
    IF NOT (p_cursor ? 'revision') THEN
      -- Older open clients can only restart from a page-one request. Returning
      -- no rows keeps a pre-revision cursor from silently mixing snapshots.
      RETURN pg_catalog.jsonb_build_object(
        'status', 'stale_page', 'results', '[]'::jsonb,
        'has_more', false, 'next_cursor', NULL
      );
    END IF;
    v_base_cursor := p_cursor - 'revision';
  END IF;

  SELECT coalesce(pg_catalog.string_agg(
    revision.board_id::text || ':' || revision.revision::text || CASE
      WHEN p_due_filter IN ('today', 'overdue', 'next_7_days') THEN
        ':' || public.board_calendar_day(board.time_zone, statement_timestamp())::text
      ELSE ''
    END,
    ',' ORDER BY revision.board_id
  ), '')
  INTO v_content_revision
  FROM public.board_content_revisions AS revision
  JOIN public.boards AS board ON board.id = revision.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  WHERE (p_scope <> 'board' OR board.id = p_scope_board_id)
    AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id);
  v_revision := pg_catalog.md5(pg_catalog.jsonb_build_array(
    v_actor_id,
    p_query,
    p_scope,
    p_scope_board_id,
    p_filter_board_id,
    p_include_completed,
    p_include_history,
    p_priority,
    p_assignee_id,
    p_unassigned,
    p_due_filter,
    p_label_filters,
    p_order,
    p_mode,
    v_content_revision
  )::text);

  IF p_cursor IS NOT NULL AND p_cursor->>'revision' IS DISTINCT FROM v_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'stale_page', 'results', '[]'::jsonb,
      'has_more', false, 'next_cursor', NULL
    );
  END IF;

  v_result := public.search_unified_p(
    p_query, p_scope, p_scope_board_id, p_filter_board_id,
    p_include_completed, p_include_history, p_priority, p_assignee_id,
    p_unassigned, p_due_filter, p_label_filters, p_order, p_mode,
    p_limit, v_base_cursor
  );
  IF p_mode = 'tasks' AND v_result->>'status' = 'available'
    AND (v_result->>'has_more')::boolean
    AND v_result->'next_cursor' IS NOT NULL THEN
    v_result := pg_catalog.jsonb_set(
      v_result,
      '{next_cursor}',
      (v_result->'next_cursor') || pg_catalog.jsonb_build_object('revision', v_revision),
      true
    );
  END IF;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.search_unified_page_p(
  text, text, uuid, uuid, boolean, boolean, text, uuid, boolean, text,
  jsonb, text, text, integer, jsonb
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_unified_page_p(
  text, text, uuid, uuid, boolean, boolean, text, uuid, boolean, text,
  jsonb, text, text, integer, jsonb
) TO authenticated;

COMMIT;
