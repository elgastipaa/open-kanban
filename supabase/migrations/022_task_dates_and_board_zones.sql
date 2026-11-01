BEGIN;

-- DATE deadlines are interpreted in the board's IANA zone. Keep this helper
-- parameterized so integration tests can supply a controlled instant.
CREATE OR REPLACE FUNCTION public.board_calendar_day(
  p_time_zone text,
  p_at timestamptz
)
RETURNS date
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT (p_at AT TIME ZONE p_time_zone)::date;
$$;

ALTER TABLE public.tasks
  ADD COLUMN due_on date;

ALTER TABLE public.tasks
  ALTER COLUMN field_versions SET DEFAULT
    '{"title":1,"description":1,"priority":1,"due_on":1}'::jsonb,
  DROP CONSTRAINT tasks_field_versions_shape;

ALTER TABLE public.tasks DISABLE TRIGGER tasks_require_board_owner;

UPDATE public.tasks
SET field_versions = field_versions || '{"due_on":1}'::jsonb;

ALTER TABLE public.tasks ENABLE TRIGGER tasks_require_board_owner;

ALTER TABLE public.tasks
  ADD CONSTRAINT tasks_field_versions_shape CHECK (
    jsonb_typeof(field_versions) = 'object'
    AND field_versions ?& ARRAY['title', 'description', 'priority', 'due_on']
    AND field_versions - ARRAY['title', 'description', 'priority', 'due_on'] = '{}'::jsonb
    AND jsonb_typeof(field_versions->'title') = 'number'
    AND jsonb_typeof(field_versions->'description') = 'number'
    AND jsonb_typeof(field_versions->'priority') = 'number'
    AND jsonb_typeof(field_versions->'due_on') = 'number'
    AND field_versions->>'title' ~ '^[1-9][0-9]*$'
    AND field_versions->>'description' ~ '^[1-9][0-9]*$'
    AND field_versions->>'priority' ~ '^[1-9][0-9]*$'
    AND field_versions->>'due_on' ~ '^[1-9][0-9]*$'
  );

CREATE OR REPLACE FUNCTION public.edit_task_fields_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_updates jsonb,
  p_expected_versions jsonb
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
  v_task public.tasks%ROWTYPE;
  v_receipt public.task_edit_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_conflicts jsonb := '{}'::jsonb;
  v_field_versions jsonb;
  v_task_edit jsonb;
  v_status text;
  v_due_on date;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_id IS NULL THEN
    RAISE EXCEPTION 'A task edit operation, board, and task are required'
      USING ERRCODE = '22023';
  END IF;
  IF p_updates IS NULL OR jsonb_typeof(p_updates) IS DISTINCT FROM 'object'
    OR p_expected_versions IS NULL
    OR jsonb_typeof(p_expected_versions) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Task edits require fields and their expected versions'
      USING ERRCODE = '22023';
  END IF;
  IF p_updates = '{}'::jsonb
    OR p_updates - ARRAY['title', 'description', 'priority', 'due_on'] <> '{}'::jsonb THEN
    RAISE EXCEPTION 'Task edit contains no fields or unsupported fields'
      USING ERRCODE = '23514';
  END IF;
  IF EXISTS (
      SELECT 1
      FROM jsonb_object_keys(p_updates) AS update_field(field_name)
      WHERE NOT (p_expected_versions ? update_field.field_name)
    )
    OR EXISTS (
      SELECT 1
      FROM jsonb_each(p_expected_versions) AS expected(field_name, version_value)
      WHERE NOT (p_updates ? expected.field_name)
        OR jsonb_typeof(expected.version_value) IS DISTINCT FROM 'number'
        OR expected.version_value::text !~ '^[1-9][0-9]*$'
    ) THEN
    RAISE EXCEPTION 'Each edited field requires one positive expected version'
      USING ERRCODE = '23514';
  END IF;

  IF p_updates ? 'title' AND (
    jsonb_typeof(p_updates->'title') IS DISTINCT FROM 'string'
    OR length(btrim(p_updates->>'title')) = 0
    OR length(p_updates->>'title') > 200
  ) THEN
    RAISE EXCEPTION 'Task title is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_updates ? 'description' AND (
    jsonb_typeof(p_updates->'description') NOT IN ('string', 'null')
    OR length(p_updates->>'description') > 2000
  ) THEN
    RAISE EXCEPTION 'Task description is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_updates ? 'priority' AND (
    jsonb_typeof(p_updates->'priority') IS DISTINCT FROM 'string'
    OR p_updates->>'priority' NOT IN ('low', 'medium', 'high', 'urgent')
  ) THEN
    RAISE EXCEPTION 'Task priority is invalid' USING ERRCODE = '22023';
  END IF;
  IF p_updates ? 'due_on' AND
    jsonb_typeof(p_updates->'due_on') NOT IN ('string', 'null') THEN
    RAISE EXCEPTION 'Task deadline must be a calendar date or null'
      USING ERRCODE = '22023';
  END IF;
  IF p_updates ? 'due_on' AND jsonb_typeof(p_updates->'due_on') = 'string' THEN
    IF p_updates->>'due_on' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
      RAISE EXCEPTION 'Task deadline must use YYYY-MM-DD' USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_due_on := (p_updates->>'due_on')::date;
      IF NOT isfinite(v_due_on)
        OR to_char(v_due_on, 'YYYY-MM-DD') <> p_updates->>'due_on' THEN
        RAISE EXCEPTION 'Task deadline must use YYYY-MM-DD';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Task deadline is invalid' USING ERRCODE = '22023';
    END;
  END IF;
  IF p_updates ? 'due_on' AND jsonb_typeof(p_updates->'due_on') = 'null' THEN
    v_due_on := NULL;
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  -- Lock current authorization before the board, then revalidate under the
  -- same short transaction that checks versions and writes the fields.
  PERFORM public.assert_task_capture_access_p(v_board_id);
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_id
    AND column_row.board_id = v_board_id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := public.task_capture_payload_hash(jsonb_build_object(
    'action', 'edit_task_fields',
    'board_id', v_board_id,
    'task_id', p_id,
    'updates', p_updates,
    'expected_versions', p_expected_versions
  ));

  INSERT INTO public.task_edit_receipts(
    actor_id, operation_id, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, v_board_id, p_id, v_payload_hash, 'pending'
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_edit_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This task edit operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status = 'confirmed' THEN
      RETURN jsonb_build_object(
        'status', 'confirmed',
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
  END IF;

  v_field_versions := v_task.field_versions;

  IF p_updates ? 'title'
    AND (p_expected_versions->>'title')::bigint <> (v_field_versions->>'title')::bigint THEN
    v_conflicts := v_conflicts || jsonb_build_object(
      'title', jsonb_build_object(
        'current', v_task.title,
        'draft', p_updates->'title',
        'current_version', (v_field_versions->>'title')::bigint
      )
    );
  END IF;
  IF p_updates ? 'description'
    AND (p_expected_versions->>'description')::bigint <> (v_field_versions->>'description')::bigint THEN
    v_conflicts := v_conflicts || jsonb_build_object(
      'description', jsonb_build_object(
        'current', v_task.description,
        'draft', p_updates->'description',
        'current_version', (v_field_versions->>'description')::bigint
      )
    );
  END IF;
  IF p_updates ? 'priority'
    AND (p_expected_versions->>'priority')::bigint <> (v_field_versions->>'priority')::bigint THEN
    v_conflicts := v_conflicts || jsonb_build_object(
      'priority', jsonb_build_object(
        'current', v_task.priority,
        'draft', p_updates->'priority',
        'current_version', (v_field_versions->>'priority')::bigint
      )
    );
  END IF;
  IF p_updates ? 'due_on'
    AND (p_expected_versions->>'due_on')::bigint <> (v_field_versions->>'due_on')::bigint THEN
    v_conflicts := v_conflicts || jsonb_build_object(
      'due_on', jsonb_build_object(
        'current', v_task.due_on,
        'draft', p_updates->'due_on',
        'current_version', (v_field_versions->>'due_on')::bigint
      )
    );
  END IF;

  IF v_conflicts <> '{}'::jsonb THEN
    UPDATE public.task_edit_receipts AS receipt
    SET result_status = 'conflict'
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object(
      'status', 'conflict',
      'operation_id', p_operation_id,
      'task', to_jsonb(v_task),
      'conflicts', v_conflicts
    );
  END IF;

  IF p_updates ? 'title' AND v_task.title IS DISTINCT FROM p_updates->>'title' THEN
    v_field_versions := jsonb_set(
      v_field_versions,
      '{title}',
      to_jsonb((v_field_versions->>'title')::bigint + 1)
    );
  END IF;
  IF p_updates ? 'description'
    AND v_task.description IS DISTINCT FROM p_updates->>'description' THEN
    v_field_versions := jsonb_set(
      v_field_versions,
      '{description}',
      to_jsonb((v_field_versions->>'description')::bigint + 1)
    );
  END IF;
  IF p_updates ? 'priority' AND v_task.priority IS DISTINCT FROM p_updates->>'priority' THEN
    v_field_versions := jsonb_set(
      v_field_versions,
      '{priority}',
      to_jsonb((v_field_versions->>'priority')::bigint + 1)
    );
  END IF;
  IF p_updates ? 'due_on' AND v_task.due_on IS DISTINCT FROM v_due_on THEN
    v_field_versions := jsonb_set(
      v_field_versions,
      '{due_on}',
      to_jsonb((v_field_versions->>'due_on')::bigint + 1)
    );
  END IF;

  IF v_field_versions IS DISTINCT FROM v_task.field_versions THEN
    UPDATE public.tasks AS task SET
      title = CASE WHEN p_updates ? 'title' THEN p_updates->>'title' ELSE task.title END,
      description = CASE WHEN p_updates ? 'description' THEN p_updates->>'description' ELSE task.description END,
      priority = CASE WHEN p_updates ? 'priority' THEN p_updates->>'priority' ELSE task.priority END,
      due_on = CASE WHEN p_updates ? 'due_on' THEN v_due_on ELSE task.due_on END,
      field_versions = v_field_versions
    WHERE task.id = p_id
    RETURNING task.* INTO v_task;
  END IF;

  UPDATE public.task_edit_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'task', to_jsonb(v_task)
  );
END;
$$;

DROP FUNCTION public.get_board_p(text);
CREATE FUNCTION public.get_board_p(p_slug text)
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  time_zone text,
  role text,
  created_at timestamptz,
  updated_at timestamptz,
  today date
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.id, board.slug, board.name, board.time_zone,
    membership.role, board.created_at, board.updated_at,
    public.board_calendar_day(board.time_zone, statement_timestamp())
  FROM public.boards AS board
  JOIN public.board_memberships AS membership ON membership.board_id = board.id
  WHERE board.slug = p_slug AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL AND public.is_board_member(board.id);
$$;

CREATE OR REPLACE FUNCTION public.get_full_board_p(p_slug text)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_role text;
BEGIN
  SELECT * INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT membership.role INTO v_role
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL;

  RETURN json_build_object(
    'board', ((to_jsonb(v_board) - 'active_generation_id' - 'owner_id')
      || jsonb_build_object(
        'role', v_role,
        'today', public.board_calendar_day(v_board.time_zone, statement_timestamp())
      ))::json,
    'columns', COALESCE(
      (
        SELECT json_agg(
          json_build_object(
            'id', column_row.id,
            'board_id', column_row.board_id,
            'title', column_row.title,
            'position', column_row.position,
            'is_collapsed', column_row.is_collapsed,
            'created_at', column_row.created_at,
            'tasks', COALESCE(
              (
                SELECT json_agg(row_to_json(task_row) ORDER BY task_row.position)
                FROM public.tasks AS task_row
                WHERE task_row.column_id = column_row.id
              ),
              '[]'::json
            )
          ) ORDER BY column_row.position
        )
        FROM public.columns AS column_row
        WHERE column_row.board_id = v_board.id
          AND column_row.generation_id = v_board.active_generation_id
      ),
      '[]'::json
    )
  );
END;
$$;

CREATE FUNCTION public.preview_board_time_zone_p(
  p_slug text,
  p_time_zone text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_now timestamptz := statement_timestamp();
  v_today_before date;
  v_today_after date;
  v_due_today_before integer;
  v_overdue_before integer;
  v_due_today_after integer;
  v_overdue_after integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_time_zone IS NULL OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_timezone_names AS zone WHERE zone.name = p_time_zone
  ) THEN
    RAISE EXCEPTION 'Choose a valid time zone' USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND OR v_board.owner_id IS DISTINCT FROM auth.uid()
    OR NOT public.is_board_owner(v_board.id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  v_today_before := public.board_calendar_day(v_board.time_zone, v_now);
  v_today_after := public.board_calendar_day(p_time_zone, v_now);

  SELECT
    count(*) FILTER (WHERE task.due_on = v_today_before),
    count(*) FILTER (WHERE task.due_on < v_today_before),
    count(*) FILTER (WHERE task.due_on = v_today_after),
    count(*) FILTER (WHERE task.due_on < v_today_after)
  INTO v_due_today_before, v_overdue_before, v_due_today_after, v_overdue_after
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
    AND NOT task.is_completed
    AND task.due_on IS NOT NULL;

  RETURN jsonb_build_object(
    'time_zone', v_board.time_zone,
    'preview_time_zone', p_time_zone,
    'today_before', v_today_before,
    'today_after', v_today_after,
    'due_today_before', v_due_today_before,
    'overdue_before', v_overdue_before,
    'due_today_after', v_due_today_after,
    'overdue_after', v_overdue_after,
    'due_dates_unchanged', true
  );
END;
$$;

CREATE FUNCTION public.update_board_time_zone_p(
  p_slug text,
  p_expected_time_zone text,
  p_time_zone text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_role text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_time_zone IS NULL OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_timezone_names AS zone WHERE zone.name = p_time_zone
  ) THEN
    RAISE EXCEPTION 'Choose a valid time zone' USING ERRCODE = '22023';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR v_board.owner_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT membership.role INTO v_role
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = auth.uid()
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR UPDATE;
  IF v_role IS DISTINCT FROM 'owner' OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF v_board.time_zone IS DISTINCT FROM p_expected_time_zone THEN
    RAISE EXCEPTION 'The board time zone changed after the preview'
      USING ERRCODE = '23514';
  END IF;

  UPDATE public.boards AS board
  SET time_zone = p_time_zone
  WHERE board.id = v_board.id
  RETURNING board.* INTO v_board;

  RETURN (to_jsonb(v_board) - 'owner_id' - 'active_generation_id')
    || jsonb_build_object(
      'role', 'owner',
      'today', public.board_calendar_day(v_board.time_zone, statement_timestamp())
    );
END;
$$;

REVOKE ALL ON FUNCTION public.edit_task_fields_p(uuid, text, uuid, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edit_task_fields_p(uuid, text, uuid, jsonb, jsonb)
  TO authenticated;
REVOKE ALL ON FUNCTION public.board_calendar_day(text, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.board_calendar_day(text, timestamptz)
  TO authenticated;
REVOKE ALL ON FUNCTION public.preview_board_time_zone_p(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.preview_board_time_zone_p(text, text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.update_board_time_zone_p(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_board_time_zone_p(text, text, text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.get_board_p(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_board_p(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
