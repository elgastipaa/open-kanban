-- Checklist steps are persisted independently from the task's versioned fields.
BEGIN;

ALTER TABLE public.tasks
  ADD COLUMN steps jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN steps_order_version bigint NOT NULL DEFAULT 1,
  ADD COLUMN checklist_version bigint NOT NULL DEFAULT 1,
  ADD CONSTRAINT tasks_steps_are_array
    CHECK (jsonb_typeof(steps) = 'array'),
  ADD CONSTRAINT tasks_steps_order_version_positive
    CHECK (steps_order_version > 0),
  ADD CONSTRAINT tasks_checklist_version_positive
    CHECK (checklist_version > 0);

CREATE TABLE public.task_checklist_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL,
  task_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_status text NOT NULL CHECK (result_status IN (
    'pending', 'confirmed', 'conflict', 'unavailable', 'expired'
  )),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);
ALTER TABLE public.task_checklist_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_checklist_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.task_checklist_deletions (
  step_id uuid PRIMARY KEY,
  task_id uuid NOT NULL,
  board_id uuid NOT NULL,
  deleted_by uuid NOT NULL,
  cause text NOT NULL CHECK (cause = 'user_requested'),
  deleted_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  step_snapshot jsonb,
  state text NOT NULL CHECK (state IN ('deleted', 'restored', 'purged')),
  restored_at timestamptz,
  purged_at timestamptz,
  CONSTRAINT task_checklist_deletions_exact_window CHECK (
    expires_at = deleted_at + interval '168 hours'
  ),
  CONSTRAINT task_checklist_deletions_state_shape CHECK (
    (state = 'deleted' AND step_snapshot IS NOT NULL
      AND restored_at IS NULL AND purged_at IS NULL)
    OR (state = 'restored' AND step_snapshot IS NULL
      AND restored_at IS NOT NULL AND purged_at IS NULL)
    OR (state = 'purged' AND step_snapshot IS NULL
      AND restored_at IS NULL AND purged_at IS NOT NULL)
  )
);
CREATE INDEX task_checklist_deletions_board_expiry_idx
  ON public.task_checklist_deletions (board_id, task_id, expires_at)
  WHERE state = 'deleted';
ALTER TABLE public.task_checklist_deletions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_checklist_deletions
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.purge_task_checklist_after_task_purge_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.state = 'purged' AND OLD.state IS DISTINCT FROM 'purged' THEN
    UPDATE public.task_checklist_deletions AS deletion
    SET step_snapshot = NULL,
        state = 'purged',
        purged_at = NEW.purged_at
    WHERE deletion.task_id = NEW.task_id
      AND deletion.state = 'deleted';
    DELETE FROM public.task_checklist_receipts AS receipt
    WHERE receipt.task_id = NEW.task_id;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER purge_task_checklist_after_task_purge
AFTER UPDATE OF state ON public.task_deletions
FOR EACH ROW EXECUTE FUNCTION public.purge_task_checklist_after_task_purge_tg();
REVOKE ALL ON FUNCTION public.purge_task_checklist_after_task_purge_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.list_deleted_task_checklist_steps_p(p_slug text)
RETURNS TABLE (
  task_id uuid,
  task_title text,
  step_id uuid,
  cause text,
  text text,
  is_completed boolean,
  "position" integer,
  deleted_at timestamptz,
  expires_at timestamptz,
  can_restore boolean,
  eligibility_checked_at timestamptz
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  WITH eligibility_clock AS MATERIALIZED (
    SELECT clock_timestamp() AS checked_at
  )
  SELECT deletion.task_id,
    task.title,
    deletion.step_id,
    deletion.cause,
    deletion.step_snapshot->>'text',
    (deletion.step_snapshot->>'is_completed')::boolean,
    (deletion.step_snapshot->>'position')::integer,
    deletion.deleted_at,
    deletion.expires_at,
    eligibility_clock.checked_at < deletion.expires_at,
    eligibility_clock.checked_at
  FROM public.task_checklist_deletions AS deletion
  JOIN public.tasks AS task ON task.id = deletion.task_id
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  JOIN public.boards AS board ON board.id = deletion.board_id
    AND board.id = column_row.board_id
    AND column_row.generation_id = board.active_generation_id
  CROSS JOIN eligibility_clock
  WHERE board.slug = p_slug
    AND deletion.state = 'deleted'
    AND deletion.step_snapshot IS NOT NULL
    AND auth.uid() IS NOT NULL
    AND public.is_application_user()
    AND public.is_board_member(board.id)
  ORDER BY deletion.deleted_at DESC, deletion.task_id, deletion.step_id;
$$;

CREATE FUNCTION public.restore_task_checklist_step_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_step_id uuid,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_deletion public.task_checklist_deletions%ROWTYPE;
  v_receipt public.task_checklist_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_status text;
  v_now timestamptz;
  v_position integer;
  v_next_steps jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL OR p_step_id IS NULL THEN
    RAISE EXCEPTION 'Checklist recovery requires an operation, task, and step'
      USING ERRCODE = '22023';
  END IF;

  SELECT deletion.board_id INTO v_board_id
  FROM public.task_checklist_deletions AS deletion
  WHERE deletion.step_id = p_step_id
    AND deletion.task_id = p_task_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  PERFORM public.assert_task_capture_access_p(v_board_id);
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id AND board.slug = p_slug;
  IF NOT FOUND OR NOT public.is_board_member(v_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE task.id = p_task_id
    AND column_row.board_id = v_board_id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := public.task_capture_payload_hash(jsonb_build_object(
    'action', 'restore_checklist_step',
    'board_id', v_board_id,
    'task_id', p_task_id,
    'step_id', p_step_id
  ));
  INSERT INTO public.task_checklist_receipts(
    actor_id, operation_id, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, v_board_id, p_task_id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_checklist_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_task_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This checklist operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'operation_id', p_operation_id,
      'task', to_jsonb(v_task)
    );
  END IF;

  SELECT deletion.* INTO v_deletion
  FROM public.task_checklist_deletions AS deletion
  WHERE deletion.step_id = p_step_id
    AND deletion.task_id = p_task_id
    AND deletion.board_id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.step_snapshot IS NULL THEN
    v_status := 'unavailable';
  ELSE
    v_now := coalesce(p_now, clock_timestamp());
    IF v_now >= v_deletion.expires_at THEN
      UPDATE public.task_checklist_deletions AS deletion
      SET step_snapshot = NULL,
          state = 'purged',
          purged_at = v_now
      WHERE deletion.step_id = p_step_id;
      v_status := 'expired';
    ELSIF EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_task.steps) AS step(item)
      WHERE step.item->>'id' = p_step_id::text
    ) THEN
      v_status := 'conflict';
    ELSE
      v_position := least(
        greatest(coalesce((v_deletion.step_snapshot->>'position')::integer, 0), 0),
        jsonb_array_length(v_task.steps)
      );
      SELECT coalesce(jsonb_agg(
        restored.item || jsonb_build_object('position', restored.restore_ordinal - 1)
        ORDER BY restored.restore_ordinal
      ), '[]'::jsonb) INTO v_next_steps
      FROM (
        SELECT step.item,
          step.ordinality + CASE WHEN step.ordinality > v_position THEN 1 ELSE 0 END
            AS restore_ordinal
        FROM jsonb_array_elements(v_task.steps) WITH ORDINALITY AS step(item, ordinality)
        UNION ALL
        SELECT v_deletion.step_snapshot, (v_position + 1)::bigint
      ) AS restored;
      UPDATE public.tasks AS task
      SET steps = v_next_steps,
          steps_order_version = task.steps_order_version + 1,
          checklist_version = task.checklist_version + 1
      WHERE task.id = p_task_id
      RETURNING task.* INTO v_task;
      UPDATE public.task_checklist_deletions AS deletion
      SET step_snapshot = NULL,
          state = 'restored',
          restored_at = v_now
      WHERE deletion.step_id = p_step_id;
      v_status := 'confirmed';
    END IF;
  END IF;

  UPDATE public.task_checklist_receipts AS receipt
  SET result_status = v_status
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;
  RETURN jsonb_build_object(
    'status', v_status,
    'operation_id', p_operation_id,
    'task', to_jsonb(v_task)
  );
END;
$$;

CREATE FUNCTION public.restore_task_checklist_step_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_step_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.restore_task_checklist_step_internal_p(
    p_operation_id, p_slug, p_task_id, p_step_id, NULL
  );
$$;

REVOKE ALL ON FUNCTION public.list_deleted_task_checklist_steps_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_deleted_task_checklist_steps_p(text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.restore_task_checklist_step_p(uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restore_task_checklist_step_p(uuid, text, uuid, uuid)
  TO authenticated;
REVOKE ALL ON FUNCTION public.restore_task_checklist_step_internal_p(
  uuid, text, uuid, uuid, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.mutate_task_checklist_step_p(
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_command jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_receipt public.task_checklist_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_action text;
  v_text text;
  v_step jsonb;
  v_step_id uuid;
  v_step_version bigint;
  v_expected_version bigint;
  v_is_completed boolean;
  v_next_steps jsonb;
  v_step_ids uuid[] := ARRAY[]::uuid[];
  v_step_value jsonb;
  v_current_step_ids uuid[];
  v_requested_step_ids_sorted uuid[];
  v_expected_order_version bigint;
  v_unexpected_key text;
  v_command_field_count integer;
  v_deleted_at timestamptz;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR jsonb_typeof(p_command) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'A checklist command needs an operation, task, and object payload'
      USING ERRCODE = '22023';
  END IF;
  v_action := p_command->>'action';
  IF v_action = 'add' THEN
    v_text := p_command->>'text';
    IF v_text IS NULL OR btrim(v_text) = '' THEN
      RAISE EXCEPTION 'A checklist step needs text' USING ERRCODE = '22023';
    END IF;
  ELSIF v_action IN ('edit', 'delete') THEN
    v_text := p_command->>'text';
    IF (v_action = 'edit' AND (v_text IS NULL OR btrim(v_text) = ''))
      OR jsonb_typeof(p_command->'step_id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(p_command->'expected_version') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'A checklist step edit or delete needs a step and its version'
        USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_step_id := (p_command->>'step_id')::uuid;
      v_expected_version := (p_command->>'expected_version')::bigint;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'A checklist step edit or delete needs a valid step and version'
        USING ERRCODE = '22023';
    END;
    IF v_expected_version < 1 THEN
      RAISE EXCEPTION 'A checklist step edit or delete needs a positive version'
        USING ERRCODE = '22023';
    END IF;
  ELSIF v_action = 'mark' THEN
    IF jsonb_typeof(p_command->'step_id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(p_command->'is_completed') IS DISTINCT FROM 'boolean'
      OR jsonb_typeof(p_command->'expected_version') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'A checklist mark needs a step, desired state, and version'
        USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_step_id := (p_command->>'step_id')::uuid;
      v_expected_version := (p_command->>'expected_version')::bigint;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'A checklist mark needs a valid step and version'
        USING ERRCODE = '22023';
    END;
    v_is_completed := (p_command->>'is_completed')::boolean;
    IF v_expected_version < 1 THEN
      RAISE EXCEPTION 'A checklist mark needs a positive step version'
        USING ERRCODE = '22023';
    END IF;
  ELSIF v_action = 'reorder' THEN
    IF jsonb_typeof(p_command->'step_ids') IS DISTINCT FROM 'array'
      OR jsonb_typeof(p_command->'expected_order_version') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Reordering checklist steps needs their IDs and current order version'
        USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_expected_order_version := (p_command->>'expected_order_version')::bigint;
      FOR v_step_value IN
        SELECT step.value FROM jsonb_array_elements(p_command->'step_ids') AS step(value)
      LOOP
        IF jsonb_typeof(v_step_value) IS DISTINCT FROM 'string' THEN
          RAISE EXCEPTION 'Every checklist step ID must be a UUID'
            USING ERRCODE = '22023';
        END IF;
        v_step_ids := array_append(v_step_ids, (v_step_value #>> '{}')::uuid);
      END LOOP;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Reordering checklist steps needs valid IDs and a version'
        USING ERRCODE = '22023';
    END;
    IF v_expected_order_version < 1 THEN
      RAISE EXCEPTION 'Reordering checklist steps needs a positive order version'
        USING ERRCODE = '22023';
    END IF;
  ELSE
    RAISE EXCEPTION 'Choose a supported checklist action' USING ERRCODE = '22023';
  END IF;

  SELECT key INTO v_unexpected_key
  FROM jsonb_object_keys(p_command) AS command_key(key)
  WHERE NOT (key = ANY(CASE
    WHEN v_action = 'add' THEN ARRAY['action', 'text']
    WHEN v_action = 'edit' THEN ARRAY['action', 'step_id', 'text', 'expected_version']
    WHEN v_action = 'delete' THEN ARRAY['action', 'step_id', 'expected_version']
    WHEN v_action = 'reorder' THEN ARRAY['action', 'step_ids', 'expected_order_version']
    ELSE ARRAY['action', 'step_id', 'is_completed', 'expected_version']
  END))
  LIMIT 1;
  SELECT count(*) INTO v_command_field_count
  FROM jsonb_object_keys(p_command);
  IF v_unexpected_key IS NOT NULL OR v_command_field_count < 2 THEN
    RAISE EXCEPTION 'The checklist step command contains unsupported fields'
      USING ERRCODE = '22023';
  END IF;
  IF (v_action = 'add' AND v_command_field_count <> 2)
    OR (v_action IN ('edit', 'mark') AND v_command_field_count <> 4)
    OR (v_action = 'delete' AND v_command_field_count <> 3)
    OR (v_action = 'reorder' AND v_command_field_count <> 3) THEN
    RAISE EXCEPTION 'The checklist step command contains unsupported fields'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
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
  WHERE task.id = p_task_id
    AND column_row.board_id = v_board_id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE OF task;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := public.task_capture_payload_hash(jsonb_build_object(
    'action', v_action,
    'board_id', v_board_id,
    'task_id', p_task_id,
    'command', p_command
  ));
  INSERT INTO public.task_checklist_receipts(
    actor_id, operation_id, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, v_board_id, p_task_id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_checklist_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_task_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This checklist operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    RETURN jsonb_build_object(
      'status', v_receipt.result_status,
      'operation_id', p_operation_id,
      'task', to_jsonb(v_task)
    );
  END IF;

  IF v_action = 'add' THEN
    v_step := jsonb_build_object(
      'id', gen_random_uuid(),
      'text', v_text,
      'is_completed', false,
      'position', jsonb_array_length(v_task.steps),
      'version', 1
    );
    UPDATE public.tasks AS task
    SET steps = task.steps || jsonb_build_array(v_step),
        steps_order_version = task.steps_order_version + 1,
        checklist_version = task.checklist_version + 1
    WHERE task.id = p_task_id
    RETURNING task.* INTO v_task;
  ELSIF v_action = 'reorder' THEN
    SELECT coalesce(array_agg((step.item->>'id')::uuid ORDER BY step.ordinality), ARRAY[]::uuid[])
    INTO v_current_step_ids
    FROM jsonb_array_elements(v_task.steps) WITH ORDINALITY AS step(item, ordinality);
    SELECT coalesce(array_agg(requested.step_id ORDER BY requested.step_id), ARRAY[]::uuid[])
    INTO v_requested_step_ids_sorted
    FROM (SELECT DISTINCT step_id FROM unnest(v_step_ids) AS requested_ids(step_id)) AS requested;
    IF cardinality(v_step_ids) <> cardinality(v_current_step_ids)
      OR cardinality(v_step_ids) <> cardinality(v_requested_step_ids_sorted)
      OR (
        SELECT coalesce(array_agg(step_id ORDER BY step_id), ARRAY[]::uuid[])
        FROM unnest(v_current_step_ids) AS current_ids(step_id)
      ) IS DISTINCT FROM v_requested_step_ids_sorted THEN
      UPDATE public.task_checklist_receipts AS receipt
      SET result_status = 'conflict'
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object(
        'status', 'conflict',
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;

    IF v_current_step_ids IS DISTINCT FROM v_step_ids
      AND v_task.steps_order_version IS DISTINCT FROM v_expected_order_version THEN
      UPDATE public.task_checklist_receipts AS receipt
      SET result_status = 'conflict'
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object(
        'status', 'conflict',
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;

    IF v_current_step_ids IS DISTINCT FROM v_step_ids THEN
      SELECT coalesce(jsonb_agg(
        step.item || jsonb_build_object('position', requested.ordinality - 1)
        ORDER BY requested.ordinality
      ), '[]'::jsonb) INTO v_next_steps
      FROM unnest(v_step_ids) WITH ORDINALITY AS requested(step_id, ordinality)
      JOIN jsonb_array_elements(v_task.steps) AS step(item)
        ON step.item->>'id' = requested.step_id::text;
      UPDATE public.tasks AS task
      SET steps = v_next_steps,
          steps_order_version = task.steps_order_version + 1,
          checklist_version = task.checklist_version + 1
      WHERE task.id = p_task_id
      RETURNING task.* INTO v_task;
    END IF;
  ELSE
    SELECT step.item INTO v_step
    FROM jsonb_array_elements(v_task.steps) WITH ORDINALITY AS step(item, ordinality)
    WHERE step.item->>'id' = v_step_id::text;
    IF NOT FOUND THEN
      UPDATE public.task_checklist_receipts AS receipt
      SET result_status = 'conflict'
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object(
        'status', 'conflict',
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;

    v_step_version := coalesce((v_step->>'version')::bigint, 1);
    IF v_step_version IS DISTINCT FROM v_expected_version AND (
      v_action = 'delete'
      OR (v_action = 'mark'
        AND (v_step->>'is_completed')::boolean IS DISTINCT FROM v_is_completed)
      OR (v_action = 'edit'
        AND v_step->>'text' IS DISTINCT FROM v_text)
    ) THEN
      UPDATE public.task_checklist_receipts AS receipt
      SET result_status = 'conflict'
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object(
        'status', 'conflict',
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;

    IF (v_action = 'mark'
      AND (v_step->>'is_completed')::boolean IS DISTINCT FROM v_is_completed) THEN
      SELECT coalesce(jsonb_agg(
        CASE WHEN step.item->>'id' = v_step_id::text THEN
          step.item || jsonb_build_object(
            'is_completed', v_is_completed,
            'version', v_step_version + 1
          )
        ELSE step.item END
        ORDER BY step.ordinality
      ), '[]'::jsonb) INTO v_next_steps
      FROM jsonb_array_elements(v_task.steps) WITH ORDINALITY AS step(item, ordinality);

      UPDATE public.tasks AS task
      SET steps = v_next_steps,
          checklist_version = task.checklist_version + 1
      WHERE task.id = p_task_id
      RETURNING task.* INTO v_task;
    ELSIF v_action = 'edit' AND v_step->>'text' IS DISTINCT FROM v_text THEN
      SELECT coalesce(jsonb_agg(
        CASE WHEN step.item->>'id' = v_step_id::text THEN
          step.item || jsonb_build_object(
            'text', v_text,
            'version', v_step_version + 1
          )
        ELSE step.item END
        ORDER BY step.ordinality
      ), '[]'::jsonb) INTO v_next_steps
      FROM jsonb_array_elements(v_task.steps) WITH ORDINALITY AS step(item, ordinality);

      UPDATE public.tasks AS task
      SET steps = v_next_steps,
          checklist_version = task.checklist_version + 1
      WHERE task.id = p_task_id
      RETURNING task.* INTO v_task;
    ELSIF v_action = 'delete' THEN
      v_deleted_at := clock_timestamp();
      INSERT INTO public.task_checklist_deletions(
        step_id, task_id, board_id, deleted_by, cause, deleted_at,
        expires_at, step_snapshot, state
      ) VALUES (
        v_step_id, p_task_id, v_board_id, v_actor_id, 'user_requested',
        v_deleted_at, v_deleted_at + interval '168 hours', v_step, 'deleted'
      ) ON CONFLICT (step_id) DO UPDATE SET
        task_id = EXCLUDED.task_id,
        board_id = EXCLUDED.board_id,
        deleted_by = EXCLUDED.deleted_by,
        cause = EXCLUDED.cause,
        deleted_at = EXCLUDED.deleted_at,
        expires_at = EXCLUDED.expires_at,
        step_snapshot = EXCLUDED.step_snapshot,
        state = 'deleted',
        restored_at = NULL,
        purged_at = NULL
      WHERE public.task_checklist_deletions.state <> 'deleted';
      GET DIAGNOSTICS v_command_field_count = ROW_COUNT;
      IF v_command_field_count <> 1 THEN
        RAISE EXCEPTION 'This checklist step is already deleted'
          USING ERRCODE = '23514';
      END IF;

      SELECT coalesce(jsonb_agg(
        (step.item || jsonb_build_object('position', step.ordinality - 1))
        ORDER BY step.ordinality
      ), '[]'::jsonb) INTO v_next_steps
      FROM jsonb_array_elements(v_task.steps) WITH ORDINALITY AS step(item, ordinality)
      WHERE step.item->>'id' <> v_step_id::text;
      UPDATE public.tasks AS task
      SET steps = v_next_steps,
          steps_order_version = task.steps_order_version + 1,
          checklist_version = task.checklist_version + 1
      WHERE task.id = p_task_id
      RETURNING task.* INTO v_task;
    END IF;
  END IF;

  UPDATE public.task_checklist_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'task', to_jsonb(v_task)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.mutate_task_checklist_step_p(uuid, text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mutate_task_checklist_step_p(uuid, text, uuid, jsonb)
  TO authenticated;

-- Confirmation reviews a checklist revision, not task field versions. Preserve
-- the existing five-argument RPC as a wrapper for requests without a review.
ALTER FUNCTION public.set_task_completion_p(uuid, text, uuid, boolean, bigint)
  RENAME TO set_task_completion_legacy_internal_p;
REVOKE ALL ON FUNCTION public.set_task_completion_legacy_internal_p(
  uuid, text, uuid, boolean, bigint
) FROM PUBLIC, anon, authenticated, service_role;
DROP FUNCTION public.set_task_completion_legacy_internal_p(
  uuid, text, uuid, boolean, bigint
);

CREATE FUNCTION public.set_task_completion_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_is_completed boolean,
  p_expected_version bigint,
  p_confirmed_checklist_version bigint
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
  v_receipt public.task_completion_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_receipt_payload jsonb;
  v_pending_steps_count integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_id IS NULL
    OR p_is_completed IS NULL OR p_expected_version IS NULL
    OR p_expected_version < 1
    OR (p_confirmed_checklist_version IS NOT NULL
      AND (p_confirmed_checklist_version < 1 OR NOT p_is_completed)) THEN
    RAISE EXCEPTION 'Task completion requires a desired state and current version'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

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

  SELECT count(*)::integer INTO v_pending_steps_count
  FROM jsonb_array_elements(v_task.steps) AS step(item)
  WHERE coalesce((step.item->>'is_completed')::boolean, false) = false;

  v_receipt_payload := jsonb_build_object(
    'action', 'set_task_completion',
    'board_id', v_board_id,
    'task_id', p_id,
    'is_completed', p_is_completed,
    'expected_version', p_expected_version
  );
  IF p_confirmed_checklist_version IS NOT NULL THEN
    v_receipt_payload := v_receipt_payload || jsonb_build_object(
      'confirmed_checklist_version', p_confirmed_checklist_version
    );
  END IF;
  v_payload_hash := public.task_capture_payload_hash(v_receipt_payload);

  INSERT INTO public.task_completion_receipts(
    actor_id, operation_id, board_id, task_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, v_board_id, p_id, v_payload_hash, 'pending'
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_completion_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.task_id IS DISTINCT FROM p_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This task completion operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status = 'confirmed' OR v_receipt.result_status = 'conflict' THEN
      IF v_receipt.result_status = 'confirmed'
        AND v_task.is_completed IS DISTINCT FROM p_is_completed THEN
        RETURN jsonb_build_object(
          'status', 'conflict',
          'operation_id', p_operation_id,
          'task', to_jsonb(v_task)
        );
      END IF;
      RETURN jsonb_build_object(
        'status', v_receipt.result_status,
        'operation_id', p_operation_id,
        'task', to_jsonb(v_task)
      );
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
  END IF;

  IF p_is_completed AND NOT v_task.is_completed THEN
    IF p_confirmed_checklist_version IS NOT NULL
      AND p_confirmed_checklist_version IS DISTINCT FROM v_task.checklist_version THEN
      DELETE FROM public.task_completion_receipts AS receipt
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object(
        'status', 'conflict',
        'operation_id', p_operation_id,
        'pending_steps_count', v_pending_steps_count,
        'checklist_version', v_task.checklist_version,
        'task', to_jsonb(v_task)
      );
    END IF;
    IF v_pending_steps_count > 0 AND p_confirmed_checklist_version IS NULL THEN
      DELETE FROM public.task_completion_receipts AS receipt
      WHERE receipt.actor_id = v_actor_id
        AND receipt.operation_id = p_operation_id;
      RETURN jsonb_build_object(
        'status', 'confirmation_required',
        'operation_id', p_operation_id,
        'pending_steps_count', v_pending_steps_count,
        'checklist_version', v_task.checklist_version,
        'task', to_jsonb(v_task)
      );
    END IF;
  END IF;

  IF v_task.is_completed IS DISTINCT FROM p_is_completed
    AND v_task.completion_version <> p_expected_version THEN
    UPDATE public.task_completion_receipts AS receipt
    SET result_status = 'conflict'
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
    RETURN jsonb_build_object(
      'status', 'conflict',
      'operation_id', p_operation_id,
      'task', to_jsonb(v_task)
    );
  END IF;

  IF v_task.is_completed IS DISTINCT FROM p_is_completed THEN
    UPDATE public.tasks AS task SET
      is_completed = p_is_completed,
      completed_at = CASE WHEN p_is_completed THEN clock_timestamp() ELSE NULL END,
      completion_version = task.completion_version + 1
    WHERE task.id = p_id
    RETURNING task.* INTO v_task;
  END IF;

  UPDATE public.task_completion_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'task', to_jsonb(v_task)
  );
END;
$$;

CREATE FUNCTION public.set_task_completion_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_is_completed boolean,
  p_expected_version bigint
)
RETURNS jsonb
LANGUAGE sql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  SELECT public.set_task_completion_p(
    p_operation_id, p_slug, p_id, p_is_completed, p_expected_version, NULL
  );
$$;

REVOKE ALL ON FUNCTION public.set_task_completion_p(uuid, text, uuid, boolean, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_task_completion_p(uuid, text, uuid, boolean, bigint)
  TO authenticated;
REVOKE ALL ON FUNCTION public.set_task_completion_p(
  uuid, text, uuid, boolean, bigint, bigint
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_task_completion_p(
  uuid, text, uuid, boolean, bigint, bigint
) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
