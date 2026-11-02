BEGIN;

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

CREATE FUNCTION public.search_normalize_internal_p(p_text text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, extensions
AS $$
  SELECT pg_catalog.btrim(pg_catalog.regexp_replace(
    pg_catalog.translate(
      pg_catalog.lower(extensions.unaccent(coalesce(p_text, ''))),
      'ñ', 'n'
    ),
    '[^a-z0-9]+', ' ', 'g'
  ));
$$;

CREATE FUNCTION public.search_match_group_internal_p(
  p_field text,
  p_query text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_field text := public.search_normalize_internal_p(p_field);
  v_query text := public.search_normalize_internal_p(p_query);
BEGIN
  IF v_query = '' OR v_field = '' THEN RETURN NULL; END IF;
  IF v_field = v_query THEN RETURN 'exact'; END IF;
  IF left(v_field, length(v_query)) = v_query THEN RETURN 'prefix'; END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.unnest(pg_catalog.string_to_array(v_query, ' ')) AS query_token(word)
    WHERE query_token.word <> ''
      AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.unnest(pg_catalog.string_to_array(v_field, ' ')) AS field_token(word)
        WHERE left(field_token.word, length(query_token.word)) = query_token.word
      )
  ) THEN
    RETURN 'word';
  END IF;
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.search_normalize_internal_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.search_match_group_internal_p(text, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.search_unified_p(
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
  v_results jsonb;
  v_has_more boolean := false;
  v_next_cursor jsonb;
  v_cursor_due date;
  v_cursor_created timestamptz;
  v_cursor_id uuid;
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
    OR (p_priority IS NOT NULL AND p_priority NOT IN ('low', 'medium', 'high', 'urgent'))
    OR (p_due_filter IS NOT NULL AND p_due_filter NOT IN (
      'today', 'overdue', 'next_7_days', 'no_date'
    ))
    OR (p_order NOT IN ('due', 'created')) THEN
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

  IF p_scope = 'board' AND NOT EXISTS (
    SELECT 1
    FROM public.boards AS board
    WHERE board.id = p_scope_board_id
      AND public.is_board_member(board.id)
  ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'results', '[]'::jsonb,
      'has_more', false, 'next_cursor', NULL
    );
  END IF;
  IF p_filter_board_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.boards AS board
    WHERE board.id = p_filter_board_id
      AND public.is_board_member(board.id)
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
      OR pg_catalog.jsonb_typeof(p_cursor->'created_at') IS DISTINCT FROM 'string'
      OR pg_catalog.jsonb_typeof(p_cursor->'id') IS DISTINCT FROM 'string'
      OR p_cursor->>'id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      OR (p_order = 'due' AND (
        NOT (p_cursor ? 'due_on')
        OR (pg_catalog.jsonb_typeof(p_cursor->'due_on') NOT IN ('string', 'null'))
        OR (p_cursor->>'due_on' IS NOT NULL
          AND p_cursor->>'due_on' !~ '^\d{4}-\d{2}-\d{2}$')
        OR (p_cursor - ARRAY['due_on', 'created_at', 'id']) <> '{}'::jsonb
      ))
      OR (p_order = 'created' AND (
        p_cursor ? 'due_on'
        OR (p_cursor - ARRAY['created_at', 'id']) <> '{}'::jsonb
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
  END IF;

  IF p_mode = 'tasks' THEN
    WITH task_matches AS MATERIALIZED (
      SELECT board.id AS board_id,
        board.slug AS board_slug,
        board.name AS board_name,
        column_row.id AS column_id,
        column_row.title AS column_title,
        task.id AS task_id,
        task.title,
        task.priority,
        task.due_on,
        task.is_completed,
        task.created_at,
        NULL::uuid AS occurrence_id,
        NULL::uuid AS series_id,
        NULL::uuid AS origin_task_id,
        NULL::date AS occurrence_on,
        false AS is_historical,
        field.field_name,
        field.field_text,
        match.relevance,
        CASE match.relevance
          WHEN 'exact' THEN 1
          WHEN 'prefix' THEN 2
          ELSE 3
        END AS relevance_order
      FROM public.tasks AS task
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      JOIN public.boards AS board
        ON board.id = column_row.board_id
        AND board.active_generation_id = column_row.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      CROSS JOIN LATERAL (VALUES
        ('title'::text, task.title),
        ('description'::text, coalesce(task.description, ''))
      ) AS field(field_name, field_text)
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(field.field_text, p_query)
          AS relevance
      ) AS match
      WHERE public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(board.time_zone, statement_timestamp())
            AND task.due_on <= public.board_calendar_day(board.time_zone, statement_timestamp()) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1 FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.task_id = task.id AND occurrence.state = 'replaced'
        )
        AND match.relevance IS NOT NULL
      UNION ALL
      SELECT board.id,
        board.slug,
        board.name,
        column_row.id,
        column_row.title,
        task.id,
        task.title,
        task.priority,
        task.due_on,
        task.is_completed,
        task.created_at,
        occurrence.id,
        series.id,
        series.origin_task_id,
        occurrence.occurrence_on,
        true,
        field.field_name,
        field.field_text,
        match.relevance,
        CASE match.relevance
          WHEN 'exact' THEN 1
          WHEN 'prefix' THEN 2
          ELSE 3
        END
      FROM public.daily_repetition_occurrences AS occurrence
      JOIN public.daily_repetition_series AS series
        ON series.id = occurrence.series_id
      JOIN public.boards AS board
        ON board.id = series.board_id
        AND board.active_generation_id = series.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      JOIN public.tasks AS task ON task.id = occurrence.task_id
      JOIN public.columns AS column_row
        ON column_row.id = task.column_id
        AND column_row.board_id = board.id
        AND column_row.generation_id = board.active_generation_id
      CROSS JOIN LATERAL (VALUES
        ('title'::text, task.title),
        ('description'::text, coalesce(task.description, ''))
      ) AS field(field_name, field_text)
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(field.field_text, p_query)
          AS relevance
      ) AS match
      WHERE p_include_history
        AND occurrence.state = 'replaced'
        AND public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(board.time_zone, statement_timestamp())
            AND task.due_on <= public.board_calendar_day(board.time_zone, statement_timestamp()) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1 FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND match.relevance IS NOT NULL
      UNION ALL
      SELECT board.id,
        board.slug,
        board.name,
        column_row.id,
        column_row.title,
        task.id,
        task.title,
        task.priority,
        task.due_on,
        task.is_completed,
        task.created_at,
        NULL::uuid,
        NULL::uuid,
        NULL::uuid,
        NULL::date,
        false,
        'comment'::text,
        comment_row.content,
        match.relevance,
        CASE match.relevance
          WHEN 'exact' THEN 1
          WHEN 'prefix' THEN 2
          ELSE 3
        END
      FROM public.task_comments AS comment_row
      JOIN public.tasks AS task ON task.id = comment_row.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      JOIN public.boards AS board
        ON board.id = comment_row.board_id
        AND board.id = column_row.board_id
        AND board.active_generation_id = column_row.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(comment_row.content, p_query)
          AS relevance
      ) AS match
      WHERE comment_row.deleted_at IS NULL
        AND public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(board.time_zone, statement_timestamp())
            AND task.due_on <= public.board_calendar_day(board.time_zone, statement_timestamp()) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1 FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.task_id = task.id AND occurrence.state = 'replaced'
        )
        AND match.relevance IS NOT NULL
      UNION ALL
      SELECT board.id,
        board.slug,
        board.name,
        column_row.id,
        column_row.title,
        task.id,
        task.title,
        task.priority,
        task.due_on,
        task.is_completed,
        task.created_at,
        occurrence.id,
        series.id,
        series.origin_task_id,
        occurrence.occurrence_on,
        true,
        'comment'::text,
        comment_row.content,
        match.relevance,
        CASE match.relevance
          WHEN 'exact' THEN 1
          WHEN 'prefix' THEN 2
          ELSE 3
        END
      FROM public.daily_repetition_occurrences AS occurrence
      JOIN public.daily_repetition_series AS series
        ON series.id = occurrence.series_id
      JOIN public.boards AS board
        ON board.id = series.board_id
        AND board.active_generation_id = series.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      JOIN public.tasks AS task ON task.id = occurrence.task_id
      JOIN public.columns AS column_row
        ON column_row.id = task.column_id
        AND column_row.board_id = board.id
        AND column_row.generation_id = board.active_generation_id
      JOIN public.task_comments AS comment_row
        ON comment_row.task_id = task.id
        AND comment_row.board_id = board.id
        AND comment_row.deleted_at IS NULL
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(comment_row.content, p_query)
          AS relevance
      ) AS match
      WHERE p_include_history
        AND occurrence.state = 'replaced'
        AND public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(board.time_zone, statement_timestamp())
            AND task.due_on <= public.board_calendar_day(board.time_zone, statement_timestamp()) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1 FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND match.relevance IS NOT NULL
    ), best_matches AS MATERIALIZED (
      SELECT DISTINCT ON (matched.task_id) matched.*
      FROM task_matches AS matched
      ORDER BY matched.task_id, matched.relevance_order,
        CASE matched.field_name WHEN 'title' THEN 0
          WHEN 'description' THEN 1 ELSE 2 END
    ), page_rows AS MATERIALIZED (
      SELECT * FROM best_matches AS matched
      WHERE p_cursor IS NULL
        OR (p_order = 'created'
          AND (matched.created_at, matched.task_id)
            > (v_cursor_created, v_cursor_id))
        OR (p_order = 'due'
          AND (coalesce(matched.due_on, 'infinity'::date),
            matched.created_at, matched.task_id)
            > (coalesce(v_cursor_due, 'infinity'::date),
              v_cursor_created, v_cursor_id))
      ORDER BY
        CASE WHEN p_order = 'due' THEN coalesce(matched.due_on, 'infinity'::date) END ASC,
        matched.created_at ASC,
        matched.task_id ASC
      LIMIT p_limit + 1
    ), visible_rows AS MATERIALIZED (
      SELECT * FROM page_rows
      ORDER BY
        CASE WHEN p_order = 'due' THEN coalesce(page_rows.due_on, 'infinity'::date) END ASC,
        page_rows.created_at ASC,
        page_rows.task_id ASC
      LIMIT p_limit
    )
    SELECT coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'kind', 'task',
        'field', visible_rows.field_name,
        'relevance', visible_rows.relevance,
        'board_id', visible_rows.board_id,
        'board_slug', visible_rows.board_slug,
        'board_name', visible_rows.board_name,
        'column_id', visible_rows.column_id,
        'column_title', visible_rows.column_title,
        'task_id', visible_rows.task_id,
        'title', visible_rows.title,
        'excerpt', left(visible_rows.field_text, 180),
        'priority', visible_rows.priority,
        'due_on', visible_rows.due_on,
        'is_completed', visible_rows.is_completed,
        'created_at', visible_rows.created_at,
        'is_historical', visible_rows.is_historical,
        'series_id', visible_rows.series_id,
        'origin_task_id', visible_rows.origin_task_id,
        'occurrence_id', visible_rows.occurrence_id,
        'occurrence_on', visible_rows.occurrence_on,
        'occurrence_state', CASE WHEN visible_rows.is_historical
          THEN 'replaced' ELSE NULL END
      )) ORDER BY
        CASE WHEN p_order = 'due' THEN coalesce(visible_rows.due_on, 'infinity'::date) END ASC,
        visible_rows.created_at ASC,
        visible_rows.task_id ASC
    ), '[]'::jsonb),
    (SELECT count(*) > p_limit FROM page_rows),
    CASE WHEN (SELECT count(*) > p_limit FROM page_rows) THEN (
      SELECT pg_catalog.jsonb_build_object(
        'created_at', visible_rows.created_at,
        'id', visible_rows.task_id
      )
      || CASE WHEN p_order = 'due' THEN pg_catalog.jsonb_build_object(
        'due_on', visible_rows.due_on
      ) ELSE '{}'::jsonb END
      FROM visible_rows
      ORDER BY
        CASE WHEN p_order = 'due' THEN coalesce(visible_rows.due_on, 'infinity'::date) END DESC,
        visible_rows.created_at DESC,
        visible_rows.task_id DESC
      LIMIT 1
    ) ELSE NULL END
    INTO v_results, v_has_more, v_next_cursor
    FROM visible_rows;

    RETURN pg_catalog.jsonb_build_object(
      'status', 'available', 'results', v_results,
      'has_more', coalesce(v_has_more, false), 'next_cursor', v_next_cursor
    );
  END IF;

  SELECT coalesce(pg_catalog.jsonb_agg(
    result.item ORDER BY result.relevance_order, result.kind_order,
      result.created_at, result.task_id
  ), '[]'::jsonb)
  INTO v_results
  FROM (
    WITH matched_fields AS MATERIALIZED (
      SELECT board.id AS board_id,
        board.slug AS board_slug,
        board.name AS board_name,
        column_row.id AS column_id,
        column_row.title AS column_title,
        task.id AS task_id,
        task.title,
        task.description,
        task.priority,
        task.due_on,
        task.is_completed,
        task.created_at,
        field.field_name,
        field.field_text,
        match.relevance,
        CASE match.relevance
          WHEN 'exact' THEN 1
          WHEN 'prefix' THEN 2
          ELSE 3
        END AS relevance_order
      FROM public.tasks AS task
      JOIN public.columns AS column_row
        ON column_row.id = task.column_id
      JOIN public.boards AS board
        ON board.id = column_row.board_id
        AND board.active_generation_id = column_row.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      CROSS JOIN LATERAL (VALUES
        ('title'::text, task.title),
        ('description'::text, coalesce(task.description, ''))
      ) AS field(field_name, field_text)
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(field.field_text, p_query) AS relevance
      ) AS match
      WHERE public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(
              board.time_zone, statement_timestamp()
            ))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(
              board.time_zone, statement_timestamp()
            ))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(
              board.time_zone, statement_timestamp()
            )
            AND task.due_on <= public.board_calendar_day(
              board.time_zone, statement_timestamp()
            ) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1
              FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id
            AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.task_id = task.id
            AND occurrence.state = 'replaced'
        )
        AND match.relevance IS NOT NULL
    ), history_task_fields AS MATERIALIZED (
      SELECT board.id AS board_id,
        board.slug AS board_slug,
        board.name AS board_name,
        column_row.id AS column_id,
        column_row.title AS column_title,
        task.id AS task_id,
        task.title,
        task.description,
        task.priority,
        task.due_on,
        task.is_completed,
        task.created_at,
        occurrence.id AS occurrence_id,
        occurrence.occurrence_on,
        series.id AS series_id,
        series.origin_task_id,
        field.field_name,
        field.field_text,
        match.relevance,
        CASE match.relevance
          WHEN 'exact' THEN 1
          WHEN 'prefix' THEN 2
          ELSE 3
        END AS relevance_order
      FROM public.daily_repetition_occurrences AS occurrence
      JOIN public.daily_repetition_series AS series
        ON series.id = occurrence.series_id
      JOIN public.boards AS board
        ON board.id = series.board_id
        AND board.active_generation_id = series.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      JOIN public.tasks AS task ON task.id = occurrence.task_id
      JOIN public.columns AS column_row
        ON column_row.id = task.column_id
        AND column_row.board_id = board.id
        AND column_row.generation_id = board.active_generation_id
      CROSS JOIN LATERAL (VALUES
        ('title'::text, task.title),
        ('description'::text, coalesce(task.description, ''))
      ) AS field(field_name, field_text)
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(field.field_text, p_query)
          AS relevance
      ) AS match
      WHERE p_include_history
        AND occurrence.state = 'replaced'
        AND public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(board.time_zone, statement_timestamp())
            AND task.due_on <= public.board_calendar_day(board.time_zone, statement_timestamp()) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1 FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND match.relevance IS NOT NULL
    ), distinct_history_tasks AS (
      SELECT DISTINCT ON (matched.occurrence_id) matched.*
      FROM history_task_fields AS matched
      ORDER BY matched.occurrence_id, matched.relevance_order,
        CASE WHEN matched.field_name = 'title' THEN 0 ELSE 1 END
    ), distinct_tasks AS (
      SELECT DISTINCT ON (matched.task_id) matched.*
      FROM matched_fields AS matched
      ORDER BY matched.task_id, matched.relevance_order,
        CASE WHEN matched.field_name = 'title' THEN 0 ELSE 1 END
    ), results AS (
      SELECT pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'kind', 'task',
        'field', distinct_tasks.field_name,
        'relevance', distinct_tasks.relevance,
        'board_id', distinct_tasks.board_id,
        'board_slug', distinct_tasks.board_slug,
        'board_name', distinct_tasks.board_name,
        'column_id', distinct_tasks.column_id,
        'column_title', distinct_tasks.column_title,
        'task_id', distinct_tasks.task_id,
        'title', distinct_tasks.title,
        'excerpt', left(distinct_tasks.field_text, 180),
        'priority', distinct_tasks.priority,
        'due_on', distinct_tasks.due_on,
        'is_completed', distinct_tasks.is_completed,
        'created_at', distinct_tasks.created_at
      )) AS item,
      distinct_tasks.created_at,
      distinct_tasks.task_id,
      distinct_tasks.relevance_order,
      0 AS kind_order
      FROM distinct_tasks
      UNION ALL
      SELECT pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'kind', 'task',
        'field', distinct_history_tasks.field_name,
        'relevance', distinct_history_tasks.relevance,
        'board_id', distinct_history_tasks.board_id,
        'board_slug', distinct_history_tasks.board_slug,
        'board_name', distinct_history_tasks.board_name,
        'column_id', distinct_history_tasks.column_id,
        'column_title', distinct_history_tasks.column_title,
        'task_id', distinct_history_tasks.task_id,
        'title', distinct_history_tasks.title,
        'excerpt', left(distinct_history_tasks.field_text, 180),
        'priority', distinct_history_tasks.priority,
        'due_on', distinct_history_tasks.due_on,
        'is_completed', distinct_history_tasks.is_completed,
        'created_at', distinct_history_tasks.created_at,
        'is_historical', true,
        'series_id', distinct_history_tasks.series_id,
        'origin_task_id', distinct_history_tasks.origin_task_id,
        'occurrence_id', distinct_history_tasks.occurrence_id,
        'occurrence_on', distinct_history_tasks.occurrence_on,
        'occurrence_state', 'replaced'
      )) AS item,
      distinct_history_tasks.created_at,
      distinct_history_tasks.task_id,
      distinct_history_tasks.relevance_order,
      0 AS kind_order
      FROM distinct_history_tasks
      UNION ALL
      SELECT pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'kind', 'comment',
        'field', 'comment',
        'relevance', comment_match.relevance,
        'board_id', board.id,
        'board_slug', board.slug,
        'board_name', board.name,
        'column_id', column_row.id,
        'column_title', column_row.title,
        'task_id', task.id,
        'task_title', task.title,
        'comment_id', comment_row.id,
        'author_name', comment_row.author_name,
        'excerpt', left(comment_row.content, 180),
        'priority', task.priority,
        'due_on', task.due_on,
        'is_completed', task.is_completed,
        'created_at', comment_row.created_at
      )) AS item,
      comment_row.created_at,
      task.id AS task_id,
      CASE comment_match.relevance
        WHEN 'exact' THEN 1
        WHEN 'prefix' THEN 2
        ELSE 3
      END AS relevance_order,
      1 AS kind_order
      FROM public.task_comments AS comment_row
      JOIN public.tasks AS task ON task.id = comment_row.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      JOIN public.boards AS board
        ON board.id = comment_row.board_id
        AND board.id = column_row.board_id
        AND board.active_generation_id = column_row.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(comment_row.content, p_query)
          AS relevance
      ) AS comment_match
      WHERE comment_row.deleted_at IS NULL
        AND public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(
              board.time_zone, statement_timestamp()
            ))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(
              board.time_zone, statement_timestamp()
            ))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(
              board.time_zone, statement_timestamp()
            )
            AND task.due_on <= public.board_calendar_day(
              board.time_zone, statement_timestamp()
            ) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1
              FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id
            AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.task_id = task.id
            AND occurrence.state = 'replaced'
        )
        AND comment_match.relevance IS NOT NULL
      UNION ALL
      SELECT pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'kind', 'comment',
        'field', 'comment',
        'relevance', comment_match.relevance,
        'board_id', board.id,
        'board_slug', board.slug,
        'board_name', board.name,
        'column_id', column_row.id,
        'column_title', column_row.title,
        'task_id', task.id,
        'task_title', task.title,
        'comment_id', comment_row.id,
        'author_name', comment_row.author_name,
        'excerpt', left(comment_row.content, 180),
        'priority', task.priority,
        'due_on', task.due_on,
        'is_completed', task.is_completed,
        'created_at', comment_row.created_at,
        'is_historical', true,
        'series_id', series.id,
        'origin_task_id', series.origin_task_id,
        'occurrence_id', occurrence.id,
        'occurrence_on', occurrence.occurrence_on,
        'occurrence_state', 'replaced'
      )) AS item,
      comment_row.created_at,
      task.id AS task_id,
      CASE comment_match.relevance
        WHEN 'exact' THEN 1
        WHEN 'prefix' THEN 2
        ELSE 3
      END AS relevance_order,
      1 AS kind_order
      FROM public.daily_repetition_occurrences AS occurrence
      JOIN public.daily_repetition_series AS series
        ON series.id = occurrence.series_id
      JOIN public.boards AS board
        ON board.id = series.board_id
        AND board.active_generation_id = series.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      JOIN public.tasks AS task ON task.id = occurrence.task_id
      JOIN public.columns AS column_row
        ON column_row.id = task.column_id
        AND column_row.board_id = board.id
        AND column_row.generation_id = board.active_generation_id
      JOIN public.task_comments AS comment_row
        ON comment_row.task_id = task.id
        AND comment_row.board_id = board.id
        AND comment_row.deleted_at IS NULL
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(comment_row.content, p_query)
          AS relevance
      ) AS comment_match
      WHERE p_include_history
        AND occurrence.state = 'replaced'
        AND public.is_board_member(board.id)
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND (p_scope <> 'my_tasks' OR task.assignee_id = v_actor_id)
        AND (p_assignee_id IS NULL OR task.assignee_id = p_assignee_id)
        AND (NOT p_unassigned OR task.assignee_id IS NULL)
        AND (p_include_completed OR NOT task.is_completed)
        AND (p_priority IS NULL OR task.priority = p_priority)
        AND (p_due_filter IS NULL
          OR (p_due_filter = 'today'
            AND task.due_on = public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'overdue'
            AND task.due_on < public.board_calendar_day(board.time_zone, statement_timestamp()))
          OR (p_due_filter = 'next_7_days'
            AND task.due_on > public.board_calendar_day(board.time_zone, statement_timestamp())
            AND task.due_on <= public.board_calendar_day(board.time_zone, statement_timestamp()) + 7)
          OR (p_due_filter = 'no_date' AND task.due_on IS NULL))
        AND (pg_catalog.jsonb_array_length(p_label_filters) = 0 OR EXISTS (
          SELECT 1
          FROM public.board_label_task_assignments AS assignment
          JOIN public.board_labels AS label
            ON label.id = assignment.label_id
            AND label.board_id = assignment.board_id
            AND label.generation_id = assignment.generation_id
            AND label.deleted_at IS NULL
          WHERE assignment.task_id = task.id
            AND assignment.board_id = board.id
            AND assignment.generation_id = column_row.generation_id
            AND EXISTS (
              SELECT 1 FROM pg_catalog.jsonb_array_elements(p_label_filters) AS selected(item)
              WHERE selected.item->>'label_id' = label.id::text
                AND selected.item->>'board_id' = board.id::text
            )
        ))
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
        AND comment_match.relevance IS NOT NULL
      UNION ALL
      SELECT pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'kind', 'board',
        'field', 'name',
        'relevance', board_match.relevance,
        'board_id', board.id,
        'board_slug', board.slug,
        'board_name', board.name,
        'excerpt', left(board.name, 180),
        'created_at', board.created_at
      )) AS item,
      board.created_at,
      board.id AS task_id,
      CASE board_match.relevance
        WHEN 'exact' THEN 1
        WHEN 'prefix' THEN 2
        ELSE 3
      END AS relevance_order,
      2 AS kind_order
      FROM public.boards AS board
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(board.name, p_query)
          AS relevance
      ) AS board_match
      WHERE p_scope = 'all'
        AND p_mode = 'suggestions'
        AND public.is_board_member(board.id)
        AND board_match.relevance IS NOT NULL
      UNION ALL
      SELECT pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'kind', 'label',
        'field', 'name',
        'relevance', label_match.relevance,
        'label_id', label.id,
        'label_name', label.name,
        'label_color', label.color,
        'board_id', board.id,
        'board_slug', board.slug,
        'board_name', board.name,
        'excerpt', left(label.name, 180),
        'created_at', label.created_at
      )) AS item,
      label.created_at,
      label.id AS task_id,
      CASE label_match.relevance
        WHEN 'exact' THEN 1
        WHEN 'prefix' THEN 2
        ELSE 3
      END AS relevance_order,
      3 AS kind_order
      FROM public.board_labels AS label
      JOIN public.boards AS board
        ON board.id = label.board_id
        AND board.active_generation_id = label.generation_id
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
        AND membership.user_id = v_actor_id
        AND membership.revoked_at IS NULL
      CROSS JOIN LATERAL (
        SELECT public.search_match_group_internal_p(label.name, p_query)
          AS relevance
      ) AS label_match
      WHERE p_mode = 'suggestions'
        AND p_scope <> 'my_tasks'
        AND (p_scope <> 'board' OR board.id = p_scope_board_id)
        AND (p_filter_board_id IS NULL OR board.id = p_filter_board_id)
        AND label.deleted_at IS NULL
        AND public.is_board_member(board.id)
        AND label_match.relevance IS NOT NULL
    )
    SELECT ranked.item, ranked.created_at, ranked.task_id,
      ranked.relevance_order, ranked.kind_order
    FROM (
      SELECT results.*,
        pg_catalog.row_number() OVER (
          PARTITION BY results.item->>'kind'
          ORDER BY results.relevance_order, results.created_at, results.task_id
        ) AS group_position
      FROM results
    ) AS ranked
    WHERE ranked.group_position <= greatest(1, (p_limit + 3) / 4)
    ORDER BY ranked.relevance_order, ranked.kind_order,
      ranked.created_at, ranked.task_id
    LIMIT p_limit
  ) AS result;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available',
    'results', v_results,
    'has_more', false,
    'next_cursor', NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.search_unified_p(
  text, text, uuid, uuid, boolean, boolean, text, uuid, boolean,
  text, jsonb, text, text, integer, jsonb
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_unified_p(
  text, text, uuid, uuid, boolean, boolean, text, uuid, boolean,
  text, jsonb, text, text, integer, jsonb
) TO authenticated;

COMMIT;
