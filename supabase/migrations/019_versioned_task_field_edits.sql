BEGIN;

ALTER TABLE public.tasks
  ADD COLUMN field_versions jsonb NOT NULL
    DEFAULT '{"title":1,"description":1,"priority":1}'::jsonb,
  ADD CONSTRAINT tasks_field_versions_shape CHECK (
    jsonb_typeof(field_versions) = 'object'
    AND field_versions ?& ARRAY['title', 'description', 'priority']
    AND field_versions - ARRAY['title', 'description', 'priority'] = '{}'::jsonb
    AND jsonb_typeof(field_versions->'title') = 'number'
    AND jsonb_typeof(field_versions->'description') = 'number'
    AND jsonb_typeof(field_versions->'priority') = 'number'
    AND field_versions->>'title' ~ '^[1-9][0-9]*$'
    AND field_versions->>'description' ~ '^[1-9][0-9]*$'
    AND field_versions->>'priority' ~ '^[1-9][0-9]*$'
  );

CREATE TABLE public.task_edit_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  task_id uuid NOT NULL REFERENCES public.tasks(id) ON DELETE CASCADE,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_status text NOT NULL CHECK (result_status IN ('pending', 'confirmed', 'conflict')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);

ALTER TABLE public.task_edit_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_edit_receipts
  FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.edit_task_fields_p(text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
DROP FUNCTION IF EXISTS public.edit_task_fields_p(text, uuid, jsonb);

CREATE FUNCTION public.edit_task_fields_p(
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
    OR p_updates - ARRAY['title', 'description', 'priority'] <> '{}'::jsonb THEN
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

  IF v_field_versions IS DISTINCT FROM v_task.field_versions THEN
    UPDATE public.tasks AS task SET
      title = CASE WHEN p_updates ? 'title' THEN p_updates->>'title' ELSE task.title END,
      description = CASE WHEN p_updates ? 'description' THEN p_updates->>'description' ELSE task.description END,
      priority = CASE WHEN p_updates ? 'priority' THEN p_updates->>'priority' ELSE task.priority END,
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

REVOKE ALL ON FUNCTION public.edit_task_fields_p(uuid, text, uuid, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edit_task_fields_p(uuid, text, uuid, jsonb, jsonb)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
