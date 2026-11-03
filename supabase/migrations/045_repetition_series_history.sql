-- Series and their occurrence history are queried independently from the
-- board's visible task rows. Every request rechecks current membership.
BEGIN;

-- Once a series cannot generate more occurrences, its template is no longer
-- operational. Keep only a non-content marker so terminal history cannot
-- become a second copy of the task text.
CREATE FUNCTION public.redact_terminal_repetition_template_tg()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.state IN ('stopped', 'finished') THEN
    NEW.template_snapshot := pg_catalog.jsonb_build_object(
      'title', 'Plantilla retirada',
      'description', NULL,
      'priority', 'medium',
      'assignee_id', NULL,
      'steps', '[]'::jsonb,
      'redacted', true
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.redact_terminal_repetition_template_tg()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER daily_repetition_series_redact_terminal_template
  BEFORE INSERT OR UPDATE OF state, template_snapshot ON public.daily_repetition_series
  FOR EACH ROW EXECUTE FUNCTION public.redact_terminal_repetition_template_tg();

UPDATE public.daily_repetition_series AS series
SET template_snapshot = pg_catalog.jsonb_build_object(
  'title', 'Plantilla retirada',
  'description', NULL,
  'priority', 'medium',
  'assignee_id', NULL,
  'steps', '[]'::jsonb,
  'redacted', true
)
WHERE series.state IN ('stopped', 'finished')
  AND series.template_snapshot->>'redacted' IS DISTINCT FROM 'true';

CREATE FUNCTION public.list_repetition_series_p(
  p_board_id uuid DEFAULT NULL,
  p_before_created_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_state text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series jsonb;
  v_has_more boolean;
  v_cursor jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'series', '[]'::jsonb, 'has_more', false
    );
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR ((p_before_created_at IS NULL) <> (p_before_id IS NULL))
    OR (p_state IS NOT NULL AND p_state NOT IN ('active', 'stopped', 'finished')) THEN
    RAISE EXCEPTION 'Revisa la página de series antes de cargarla'
      USING ERRCODE = '22023';
  END IF;

  WITH eligible AS MATERIALIZED (
    SELECT series.id, series.board_id, series.generation_id,
      series.rule, series.calendar_pattern, series.start_on, series.end_on,
      series.occurrence_limit, series.consumed_count,
      series.latest_occurrence_on, series.current_occurrence_id,
      series.next_due_on, series.state, series.revision,
      series.advance_days, series.appearance_column_id, series.created_at,
      board.slug AS board_slug, board.name AS board_name,
      board.time_zone AS board_time_zone,
      visible_current_task.id AS current_task_id,
      visible_current_task.title AS current_task_title
    FROM public.daily_repetition_series AS series
    JOIN public.boards AS board
      ON board.id = series.board_id
      AND board.active_generation_id = series.generation_id
    LEFT JOIN public.daily_repetition_occurrences AS current_occurrence
      ON current_occurrence.id = series.current_occurrence_id
      AND current_occurrence.series_id = series.id
      AND current_occurrence.state = 'current'
    LEFT JOIN LATERAL (
      SELECT task.id, task.title
      FROM public.tasks AS task
      JOIN public.columns AS column_row
        ON column_row.id = task.column_id
        AND column_row.board_id = board.id
        AND column_row.generation_id = board.active_generation_id
      WHERE task.id = current_occurrence.task_id
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id
            AND deletion.board_id = board.id
            AND deletion.state IN ('deleted', 'purged')
        )
    ) AS visible_current_task ON true
    WHERE public.is_board_member(board.id)
      AND (p_board_id IS NULL OR series.board_id = p_board_id)
      AND (p_state IS NULL OR series.state = p_state)
      AND (p_before_created_at IS NULL
        OR (series.created_at, series.id) < (p_before_created_at, p_before_id))
  ), page_rows AS (
    SELECT * FROM eligible
    ORDER BY created_at DESC, id DESC
    LIMIT p_limit + 1
  ), visible_rows AS (
    SELECT * FROM page_rows
    ORDER BY created_at DESC, id DESC
    LIMIT p_limit
  )
  SELECT
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', visible_rows.id,
        'board_id', visible_rows.board_id,
        'board_slug', visible_rows.board_slug,
        'board_name', visible_rows.board_name,
        'board_time_zone', visible_rows.board_time_zone,
        'state', visible_rows.state,
        'rule', visible_rows.rule,
        'pattern', visible_rows.calendar_pattern,
        'start_on', visible_rows.start_on,
        'end_on', visible_rows.end_on,
        'occurrence_limit', visible_rows.occurrence_limit,
        'consumed_count', visible_rows.consumed_count,
        'latest_occurrence_on', visible_rows.latest_occurrence_on,
        'next_due_on', visible_rows.next_due_on,
        'next_appearance_on', CASE
          WHEN visible_rows.next_due_on IS NULL THEN NULL
          ELSE visible_rows.next_due_on - visible_rows.advance_days
        END,
        'revision', visible_rows.revision,
        'advance_days', visible_rows.advance_days,
        'appearance_column_id', visible_rows.appearance_column_id,
        'current_task_id', visible_rows.current_task_id,
        'current_task_title', visible_rows.current_task_title,
        'created_at', visible_rows.created_at
      ) ORDER BY visible_rows.created_at DESC, visible_rows.id DESC
    ), '[]'::jsonb),
    (SELECT count(*) > p_limit FROM page_rows),
    CASE WHEN (SELECT count(*) > p_limit FROM page_rows) THEN (
      SELECT pg_catalog.jsonb_build_object(
        'created_at', visible_rows.created_at,
        'id', visible_rows.id
      )
      FROM visible_rows
      ORDER BY visible_rows.created_at ASC, visible_rows.id ASC
      LIMIT 1
    ) ELSE NULL END
  INTO v_series, v_has_more, v_cursor
  FROM visible_rows;

  RETURN pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'status', 'available',
    'series', coalesce(v_series, '[]'::jsonb),
    'has_more', coalesce(v_has_more, false),
    'next_cursor', v_cursor
  ));
END;
$$;
REVOKE ALL ON FUNCTION public.list_repetition_series_p(
  uuid, timestamptz, uuid, integer, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_repetition_series_p(
  uuid, timestamptz, uuid, integer, text
) TO authenticated;

CREATE FUNCTION public.get_repetition_history_page_p(
  p_series_id uuid,
  p_before_on date DEFAULT NULL,
  p_before_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series public.daily_repetition_series%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_history jsonb;
  v_has_more boolean;
  v_cursor jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_series_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR ((p_before_on IS NULL) <> (p_before_id IS NULL)) THEN
    RAISE EXCEPTION 'Revisa la página del historial antes de cargarla'
      USING ERRCODE = '22023';
  END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  JOIN public.boards AS board
    ON board.id = series.board_id
    AND board.active_generation_id = series.generation_id
  WHERE series.id = p_series_id AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_series.board_id
    AND board.active_generation_id = v_series.generation_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  WITH page_rows AS MATERIALIZED (
    SELECT occurrence.id, occurrence.occurrence_on, occurrence.task_id,
      occurrence.state, occurrence.due_on_override,
      visible_task.id AS visible_task_id,
      visible_task.title, visible_task.description, visible_task.priority,
      visible_task.is_completed, visible_task.due_on,
      visible_task.created_by,
      (SELECT count(*)::integer
        FROM public.task_comments AS comment_row
        WHERE comment_row.task_id = visible_task.id
          AND comment_row.board_id = v_board.id
          AND comment_row.deleted_at IS NULL) AS comment_count,
      (SELECT comment_row.id
        FROM public.task_comments AS comment_row
        WHERE comment_row.task_id = visible_task.id
          AND comment_row.board_id = v_board.id
          AND comment_row.deleted_at IS NULL
        ORDER BY comment_row.created_at DESC, comment_row.id DESC
        LIMIT 1) AS latest_comment_id
    FROM public.daily_repetition_occurrences AS occurrence
    LEFT JOIN LATERAL (
      SELECT task.id, task.title, task.description, task.priority,
        task.is_completed, task.due_on, task.created_by
      FROM public.tasks AS task
      JOIN public.columns AS column_row
        ON column_row.id = task.column_id
        AND column_row.board_id = v_board.id
        AND column_row.generation_id = v_board.active_generation_id
      WHERE task.id = occurrence.task_id
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id
            AND deletion.board_id = v_board.id
            AND deletion.state IN ('deleted', 'purged')
        )
    ) AS visible_task ON true
    WHERE occurrence.series_id = v_series.id
      AND (p_before_on IS NULL
        OR (occurrence.occurrence_on, occurrence.id) < (p_before_on, p_before_id))
    ORDER BY occurrence.occurrence_on DESC, occurrence.id DESC
    LIMIT p_limit + 1
  ), visible_rows AS (
    SELECT * FROM page_rows
    ORDER BY occurrence_on DESC, id DESC
    LIMIT p_limit
  )
  SELECT
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'id', visible_rows.id,
        'occurrence_on', visible_rows.occurrence_on,
        'task_id', visible_rows.visible_task_id,
        'state', visible_rows.state,
        'due_on_override', visible_rows.due_on_override,
        'title', visible_rows.title,
        'description', visible_rows.description,
        'priority', visible_rows.priority,
        'is_completed', visible_rows.is_completed,
        'due_on', visible_rows.due_on,
        'created_by', visible_rows.created_by,
        'comment_count', visible_rows.comment_count,
        'latest_comment_id', visible_rows.latest_comment_id,
        'content_available', visible_rows.visible_task_id IS NOT NULL
      )) ORDER BY visible_rows.occurrence_on DESC, visible_rows.id DESC
    ), '[]'::jsonb),
    (SELECT count(*) > p_limit FROM page_rows),
    CASE WHEN (SELECT count(*) > p_limit FROM page_rows) THEN (
      SELECT pg_catalog.jsonb_build_object(
        'occurrence_on', visible_rows.occurrence_on,
        'id', visible_rows.id
      )
      FROM visible_rows
      ORDER BY visible_rows.occurrence_on ASC, visible_rows.id ASC
      LIMIT 1
    ) ELSE NULL END
  INTO v_history, v_has_more, v_cursor
  FROM visible_rows;

  RETURN pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'status', 'available',
    'series', pg_catalog.jsonb_build_object(
      'id', v_series.id,
      'board_id', v_board.id,
      'board_slug', v_board.slug,
      'board_name', v_board.name,
      'board_time_zone', v_board.time_zone,
      'state', v_series.state,
      'rule', v_series.rule,
      'pattern', v_series.calendar_pattern,
      'start_on', v_series.start_on,
      'end_on', v_series.end_on,
      'occurrence_limit', v_series.occurrence_limit,
      'consumed_count', v_series.consumed_count,
      'latest_occurrence_on', v_series.latest_occurrence_on,
      'next_due_on', v_series.next_due_on,
      'revision', v_series.revision,
      'advance_days', v_series.advance_days,
      'appearance_column_id', v_series.appearance_column_id
    ),
    'occurrences', coalesce(v_history, '[]'::jsonb),
    'has_more', coalesce(v_has_more, false),
    'next_cursor', v_cursor
  ));
END;
$$;
REVOKE ALL ON FUNCTION public.get_repetition_history_page_p(
  uuid, date, uuid, integer
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_repetition_history_page_p(
  uuid, date, uuid, integer
) TO authenticated;

CREATE FUNCTION public.get_repetition_history_occurrence_p(
  p_series_id uuid,
  p_occurrence_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series public.daily_repetition_series%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_occurrence public.daily_repetition_occurrences%ROWTYPE;
  v_task_id uuid;
  v_task jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_series_id IS NULL OR p_occurrence_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  JOIN public.boards AS board
    ON board.id = series.board_id
    AND board.active_generation_id = series.generation_id
  WHERE series.id = p_series_id AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_series.board_id
    AND board.active_generation_id = v_series.generation_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT occurrence.* INTO v_occurrence
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.id = p_occurrence_id
    AND occurrence.series_id = v_series.id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT task.id,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'id', task.id,
      'title', task.title,
      'description', task.description,
      'priority', task.priority,
      'is_completed', task.is_completed,
      'due_on', task.due_on,
      'created_by', task.created_by,
      'comment_count', (
        SELECT count(*)::integer FROM public.task_comments AS comment_row
        WHERE comment_row.task_id = task.id
          AND comment_row.board_id = v_board.id
          AND comment_row.deleted_at IS NULL
      ),
      'latest_comment_id', (
        SELECT comment_row.id FROM public.task_comments AS comment_row
        WHERE comment_row.task_id = task.id
          AND comment_row.board_id = v_board.id
          AND comment_row.deleted_at IS NULL
        ORDER BY comment_row.created_at DESC, comment_row.id DESC
        LIMIT 1
      )
    )) INTO v_task_id, v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  WHERE task.id = v_occurrence.task_id
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = task.id
        AND deletion.board_id = v_board.id
        AND deletion.state IN ('deleted', 'purged')
    );

  RETURN pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
    'status', 'available',
    'board_slug', v_board.slug,
    'occurrence', pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'id', v_occurrence.id,
      'occurrence_on', v_occurrence.occurrence_on,
      'state', v_occurrence.state,
      'due_on_override', v_occurrence.due_on_override,
      'task_id', v_task_id,
      'task', v_task,
      'content_available', v_task_id IS NOT NULL,
      'latest_comment_id', v_task->'latest_comment_id',
      'comment_count', v_task->'comment_count'
    )),
    'series', pg_catalog.jsonb_build_object(
      'id', v_series.id,
      'board_id', v_board.id,
      'board_slug', v_board.slug,
      'board_name', v_board.name,
      'state', v_series.state,
      'revision', v_series.revision
    )
  ));
END;
$$;
REVOKE ALL ON FUNCTION public.get_repetition_history_occurrence_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_repetition_history_occurrence_p(uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.stop_repetition_series_p(
  p_operation_id uuid,
  p_slug text,
  p_series_id uuid,
  p_expected_revision bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_receipt public.daily_repetition_receipts%ROWTYPE;
  v_current_task_id uuid;
  v_payload_hash bytea;
  v_result jsonb;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_series_id IS NULL
    OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RAISE EXCEPTION 'Revisa la serie antes de detenerla' USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id)
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = p_series_id
    AND series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;

  v_payload_hash := extensions.digest(pg_catalog.convert_to(
    pg_catalog.jsonb_build_object(
      'action', 'stop', 'board_id', v_board.id,
      'series_id', v_series.id,
      'expected_revision', p_expected_revision
    )::text, 'UTF8'
  ), 'sha256');
  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'stop'
      OR v_receipt.board_id IS DISTINCT FROM v_board.id
      OR v_receipt.series_id IS DISTINCT FROM v_series.id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otros datos'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= v_now THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN v_receipt.result;
  END IF;

  IF v_series.revision IS DISTINCT FROM p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'series_id', v_series.id, 'series_revision', v_series.revision,
      'state', v_series.state
    );
  END IF;
  IF v_series.state IS DISTINCT FROM 'active' THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', CASE WHEN v_series.state = 'stopped'
        THEN 'already_stopped' ELSE 'finished' END,
      'operation_id', p_operation_id,
      'series_id', v_series.id, 'series_revision', v_series.revision,
      'state', v_series.state
    );
  END IF;

  SELECT occurrence.task_id INTO v_current_task_id
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.id = v_series.current_occurrence_id
    AND occurrence.series_id = v_series.id
    AND occurrence.state = 'current';

  UPDATE public.daily_repetition_jobs AS job
  SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
      completed_at = v_now, updated_at = v_now
  WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait', 'leased');

  UPDATE public.daily_repetition_series AS series
  SET state = 'stopped', next_due_on = NULL, stopped_at = v_now,
      revision = series.revision + 1, updated_at = v_now
  WHERE series.id = v_series.id
  RETURNING series.* INTO v_series;

  v_result := pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'series_id', v_series.id, 'series_revision', v_series.revision,
    'state', v_series.state, 'next_due_on', v_series.next_due_on,
    'current_occurrence_id', v_series.current_occurrence_id,
    'current_task_id', v_current_task_id,
    'consumed_count', v_series.consumed_count,
    'occurrence_limit', v_series.occurrence_limit,
    'end_on', v_series.end_on
  );
  INSERT INTO public.daily_repetition_receipts(
    actor_id, operation_id, action, board_id, task_id, series_id,
    payload_hash, result
  ) VALUES (
    v_actor_id, p_operation_id, 'stop', v_board.id,
    coalesce(v_current_task_id, v_series.first_task_id), v_series.id,
    v_payload_hash, v_result
  );
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.stop_repetition_series_p(uuid, text, uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.stop_repetition_series_p(uuid, text, uuid, bigint)
  TO authenticated;

CREATE TABLE public.task_copy_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  source_task_id uuid NOT NULL,
  copied_task_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (pg_catalog.octet_length(payload_hash) = 32),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (pg_catalog.clock_timestamp() + interval '168 hours'),
  PRIMARY KEY (actor_id, operation_id)
);
ALTER TABLE public.task_copy_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_copy_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.historical_task_copy_preview_internal_p(
  p_board_id uuid,
  p_generation_id uuid,
  p_task_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_steps jsonb;
  v_copy_steps jsonb;
  v_source_hash bytea;
BEGIN
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
    AND board.active_generation_id = p_generation_id;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  WHERE task.id = p_task_id
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = task.id
        AND deletion.board_id = v_board.id
        AND deletion.state IN ('deleted', 'purged')
    );
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  IF NOT v_task.is_completed AND NOT EXISTS (
    SELECT 1
    FROM public.daily_repetition_occurrences AS occurrence
    JOIN public.daily_repetition_series AS series
      ON series.id = occurrence.series_id
      AND series.board_id = v_board.id
      AND series.generation_id = v_board.active_generation_id
    WHERE occurrence.task_id = v_task.id
      AND occurrence.state IN ('replaced', 'excluded', 'transferred', 'retired')
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'text', step.value->>'text',
      'position', coalesce((step.value->>'position')::integer,
        (step.ordinality - 1)::integer),
      'is_completed', false
    ) ORDER BY step.ordinality), '[]'::jsonb),
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'text', step.value->>'text',
      'position', coalesce((step.value->>'position')::integer,
        (step.ordinality - 1)::integer)
    ) ORDER BY step.ordinality), '[]'::jsonb)
  INTO v_copy_steps, v_steps
  FROM pg_catalog.jsonb_array_elements(v_task.steps)
    WITH ORDINALITY AS step(value, ordinality);
  v_copy_steps := coalesce(v_copy_steps, '[]'::jsonb);
  v_steps := coalesce(v_steps, '[]'::jsonb);
  v_source_hash := extensions.digest(pg_catalog.convert_to(
    pg_catalog.jsonb_build_object(
      'title', v_task.title,
      'description', v_task.description,
      'priority', v_task.priority,
      'steps', v_steps
    )::text, 'UTF8'
  ), 'sha256');
  RETURN pg_catalog.jsonb_build_object(
    'status', 'available',
    'board_id', v_board.id,
    'source_task_id', v_task.id,
    'source_column_id', v_task.column_id,
    'target_column_id', v_task.column_id,
    'title', v_task.title,
    'description', v_task.description,
    'priority', v_task.priority,
    'steps', v_copy_steps,
    'step_count', pg_catalog.jsonb_array_length(v_copy_steps),
    'source_hash', pg_catalog.encode(v_source_hash, 'hex')
  );
END;
$$;
REVOKE ALL ON FUNCTION public.historical_task_copy_preview_internal_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.preview_historical_task_copy_p(
  p_slug text,
  p_task_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_task_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  RETURN public.historical_task_copy_preview_internal_p(
    v_board.id, v_board.active_generation_id, p_task_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_historical_task_copy_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_historical_task_copy_p(text, uuid)
  TO authenticated;

CREATE FUNCTION public.copy_historical_task_p(
  p_operation_id uuid,
  p_slug text,
  p_source_task_id uuid,
  p_target_column_id uuid,
  p_title text,
  p_expected_source_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_source public.tasks%ROWTYPE;
  v_receipt public.task_copy_receipts%ROWTYPE;
  v_column_id uuid;
  v_create_operation_id uuid := pg_catalog.gen_random_uuid();
  v_copy_preview jsonb;
  v_create_result jsonb;
  v_new_task public.tasks%ROWTYPE;
  v_payload_hash bytea;
  v_result jsonb;
  v_title text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_source_task_id IS NULL
    OR p_target_column_id IS NULL OR p_expected_source_hash IS NULL
    OR p_expected_source_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Revisa la copia antes de confirmarla' USING ERRCODE = '22023';
  END IF;
  v_title := public.task_capture_normalize_title(p_title);

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id)
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;
  v_payload_hash := extensions.digest(pg_catalog.convert_to(
    pg_catalog.jsonb_build_object(
      'action', 'copy_historical_task',
      'board_id', v_board.id,
      'source_task_id', p_source_task_id,
      'target_column_id', p_target_column_id,
      'title', v_title,
      'expected_source_hash', p_expected_source_hash
    )::text, 'UTF8'
  ), 'sha256');
  SELECT receipt.* INTO v_receipt
  FROM public.task_copy_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.board_id IS DISTINCT FROM v_board.id
      OR v_receipt.source_task_id IS DISTINCT FROM p_source_task_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otra copia'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= pg_catalog.clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    SELECT task.* INTO v_new_task
    FROM public.tasks AS task
    JOIN public.columns AS column_row
      ON column_row.id = task.column_id
      AND column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id
    WHERE task.id = v_receipt.copied_task_id
      AND NOT EXISTS (
        SELECT 1 FROM public.task_deletions AS deletion
        WHERE deletion.task_id = task.id AND deletion.board_id = v_board.id
          AND deletion.state IN ('deleted', 'purged')
      );
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmed', 'operation_id', p_operation_id,
      'task_id', v_new_task.id, 'task', pg_catalog.to_jsonb(v_new_task)
    );
  END IF;

  SELECT task.* INTO v_source
  FROM public.tasks AS task
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  WHERE task.id = p_source_task_id
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = task.id AND deletion.board_id = v_board.id
        AND deletion.state IN ('deleted', 'purged')
    )
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;
  SELECT column_row.id INTO v_column_id
  FROM public.columns AS column_row
  WHERE column_row.id = p_target_column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;

  v_copy_preview := public.historical_task_copy_preview_internal_p(
    v_board.id, v_board.active_generation_id, p_source_task_id
  );
  IF v_copy_preview->>'status' IS DISTINCT FROM 'available' THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;
  IF v_copy_preview->>'source_hash' IS DISTINCT FROM p_expected_source_hash THEN
    RETURN v_copy_preview || pg_catalog.jsonb_build_object(
      'status', 'source_changed', 'operation_id', p_operation_id,
      'title', v_title, 'target_column_id', v_column_id
    );
  END IF;

  v_create_result := public.create_task_p(
    v_create_operation_id, v_board.id, v_column_id, v_title,
    v_source.description, v_source.priority
  );
  IF v_create_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'No se pudo crear la tarea copiada' USING ERRCODE = '40001';
  END IF;
  UPDATE public.tasks AS task
  SET steps = coalesce((
    SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', pg_catalog.gen_random_uuid(),
      'text', step.value->>'text',
      'is_completed', false,
      'position', coalesce((step.value->>'position')::integer,
        (step.ordinality - 1)::integer),
      'version', 1
    ) ORDER BY step.ordinality)
    FROM pg_catalog.jsonb_array_elements(v_source.steps)
      WITH ORDINALITY AS step(value, ordinality)
  ), '[]'::jsonb)
  WHERE task.id = (v_create_result->>'task_id')::uuid
  RETURNING task.* INTO v_new_task;
  DELETE FROM public.task_capture_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = v_create_operation_id;

  INSERT INTO public.task_copy_receipts(
    actor_id, operation_id, board_id, source_task_id, copied_task_id, payload_hash
  ) VALUES (
    v_actor_id, p_operation_id, v_board.id, p_source_task_id,
    v_new_task.id, v_payload_hash
  );
  v_result := pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'task_id', v_new_task.id, 'task', pg_catalog.to_jsonb(v_new_task)
  );
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.copy_historical_task_p(
  uuid, text, uuid, uuid, text, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.copy_historical_task_p(
  uuid, text, uuid, uuid, text, text
) TO authenticated;

-- The legacy task lookup can still find a slot after its task was deleted.
-- Do not make the recurrence template a second recovery snapshot in that case.
CREATE OR REPLACE FUNCTION public.get_repetition_p(
  p_slug text,
  p_task_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
BEGIN
  v_result := public.get_daily_repetition_p(p_slug, p_task_id);
  IF v_result->>'status' IS DISTINCT FROM 'available' THEN
    RETURN v_result;
  END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = (v_result->>'series_id')::uuid;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  IF v_series.state IN ('stopped', 'finished') OR EXISTS (
    SELECT 1 FROM public.task_deletions AS deletion
    WHERE deletion.task_id = p_task_id
      AND deletion.state IN ('deleted', 'purged')
  ) THEN
    RETURN v_result || pg_catalog.jsonb_build_object(
      'rule', v_series.rule, 'pattern', v_series.calendar_pattern,
      'advance_days', v_series.advance_days,
      'appearance_column_id', v_series.appearance_column_id
    );
  END IF;

  RETURN v_result || pg_catalog.jsonb_build_object(
    'rule', v_series.rule, 'pattern', v_series.calendar_pattern,
    'advance_days', v_series.advance_days,
    'appearance_column_id', v_series.appearance_column_id,
    'template_snapshot', v_series.template_snapshot
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_repetition_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_repetition_p(text, uuid)
  TO authenticated;

CREATE FUNCTION public.guard_replaced_repetition_completion_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF NEW.is_completed IS NOT DISTINCT FROM OLD.is_completed THEN
    RETURN NEW;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.task_id = OLD.id
  ) AND NOT EXISTS (
    SELECT 1
    FROM public.daily_repetition_occurrences AS occurrence
    JOIN public.daily_repetition_series AS series
      ON series.id = occurrence.series_id
      AND series.board_id = (
        SELECT column_row.board_id
        FROM public.columns AS column_row
        WHERE column_row.id = OLD.column_id
      )
    JOIN public.boards AS board
      ON board.id = series.board_id
      AND board.active_generation_id = series.generation_id
    WHERE occurrence.task_id = OLD.id
      AND occurrence.state = 'current'
      AND series.current_occurrence_id = occurrence.id
  ) THEN
    RAISE EXCEPTION 'Esta ocurrencia pertenece al historial y no se puede modificar'
      USING ERRCODE = 'P2302';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER tasks_guard_replaced_repetition_completion
  BEFORE UPDATE OF is_completed ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.guard_replaced_repetition_completion_tg();
REVOKE ALL ON FUNCTION public.guard_replaced_repetition_completion_tg()
  FROM PUBLIC, anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
