-- Task order is versioned independently from task field edits. Moves carry
-- stable neighbor anchors and an operation receipt so lost responses can be
-- reconciled without applying the move twice.
BEGIN;

ALTER TABLE public.columns
  ADD COLUMN task_order_version bigint NOT NULL DEFAULT 1
    CHECK (task_order_version > 0);

CREATE TABLE public.task_order_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  result_status text NOT NULL CHECK (result_status IN ('pending', 'confirmed', 'conflict')),
  result_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);

ALTER TABLE public.task_order_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_order_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bump_task_order_version_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE public.columns
    SET task_order_version = task_order_version + 1
    WHERE id = NEW.column_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE public.columns
    SET task_order_version = task_order_version + 1
    WHERE id = OLD.column_id;
    RETURN OLD;
  ELSIF OLD.column_id IS DISTINCT FROM NEW.column_id
    OR OLD.position IS DISTINCT FROM NEW.position THEN
    UPDATE public.columns
    SET task_order_version = task_order_version + 1
    WHERE id IN (OLD.column_id, NEW.column_id);
    RETURN NEW;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER tasks_bump_task_order_version
AFTER INSERT OR UPDATE OF column_id, position OR DELETE ON public.tasks
FOR EACH ROW EXECUTE FUNCTION public.bump_task_order_version_p();

REVOKE ALL ON FUNCTION public.bump_task_order_version_p()
  FROM PUBLIC, anon, authenticated, service_role;

DROP FUNCTION public.update_task_positions_p(text, jsonb);

CREATE FUNCTION public.update_task_positions_p(
  p_operation_id uuid,
  p_slug text,
  p_moves jsonb,
  p_expected_order_versions jsonb
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
  v_receipt public.task_order_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_item jsonb;
  v_index integer;
  v_move_count integer;
  v_move_ids uuid[] := ARRAY[]::uuid[];
  v_requested_source_ids uuid[] := ARRAY[]::uuid[];
  v_destination_ids uuid[] := ARRAY[]::uuid[];
  v_before_ids uuid[] := ARRAY[]::uuid[];
  v_after_ids uuid[] := ARRAY[]::uuid[];
  v_gap_slots integer[] := ARRAY[]::integer[];
  v_touched_column_ids uuid[] := ARRAY[]::uuid[];
  v_snapshot_column_ids uuid[] := ARRAY[]::uuid[];
  v_source_column_id uuid;
  v_destination_column_id uuid;
  v_task_id uuid;
  v_before_id uuid;
  v_after_id uuid;
  v_base_ids uuid[];
  v_final_ids uuid[];
  v_base_count integer;
  v_before_position integer;
  v_after_position integer;
  v_gap_slot integer;
  v_column_id uuid;
  v_expected jsonb;
  v_current_order_version bigint;
  v_conflict boolean := false;
  v_column_snapshots jsonb;
  v_result jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL
    OR p_moves IS NULL OR jsonb_typeof(p_moves) IS DISTINCT FROM 'array'
    OR p_expected_order_versions IS NULL
    OR jsonb_typeof(p_expected_order_versions) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Task ordering requires an operation, moves, and expected versions'
      USING ERRCODE = '22023';
  END IF;

  v_move_count := jsonb_array_length(p_moves);
  IF v_move_count = 0 OR v_move_count > 200 THEN
    RAISE EXCEPTION 'Task ordering batches must contain between 1 and 200 moves'
      USING ERRCODE = '22023';
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_moves) AS moves(value)
  LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object'
      OR (v_item - ARRAY['id', 'source_column_id', 'column_id', 'before_task_id', 'after_task_id']) <> '{}'::jsonb
      OR NOT (v_item ?& ARRAY['id', 'source_column_id', 'column_id', 'before_task_id', 'after_task_id'])
      OR jsonb_typeof(v_item->'id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_item->'source_column_id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_item->'column_id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(v_item->'before_task_id') NOT IN ('string', 'null')
      OR jsonb_typeof(v_item->'after_task_id') NOT IN ('string', 'null')
      OR v_item->>'before_task_id' = ''
      OR v_item->>'after_task_id' = '' THEN
      RAISE EXCEPTION 'Task ordering batch contains an invalid move'
        USING ERRCODE = '22023';
    END IF;
    v_task_id := (v_item->>'id')::uuid;
    IF v_task_id = ANY(v_move_ids) THEN
      RAISE EXCEPTION 'Task ordering batch contains duplicate task IDs'
        USING ERRCODE = '23514';
    END IF;
    v_move_ids := array_append(v_move_ids, v_task_id);
    v_requested_source_ids := array_append(v_requested_source_ids, (v_item->>'source_column_id')::uuid);
    v_destination_ids := array_append(v_destination_ids, (v_item->>'column_id')::uuid);
    v_before_ids := array_append(v_before_ids, (v_item->>'before_task_id')::uuid);
    v_after_ids := array_append(v_after_ids, (v_item->>'after_task_id')::uuid);
  END LOOP;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  -- Lock current application and membership access before reading receipts.
  PERFORM public.assert_task_capture_access_p(v_board_id);
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  -- Receipt lookup precedes source-column discovery. After a successful move,
  -- a replay sees the task in its destination but must still return the
  -- original receipt rather than treating that new source as a changed batch.
  v_payload_hash := public.task_capture_payload_hash(jsonb_build_object(
    'action', 'update_task_positions',
    'board_id', v_board_id,
    'moves', p_moves,
    'expected_order_versions', p_expected_order_versions
  ));

  INSERT INTO public.task_order_receipts(
    actor_id, operation_id, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, v_board_id, v_payload_hash, 'pending'
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_order_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.board_id IS DISTINCT FROM v_board_id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'This task ordering operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= clock_timestamp() THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_receipt.result_status = 'confirmed' OR v_receipt.result_status = 'conflict' THEN
      RETURN v_receipt.result_payload;
    END IF;
    RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
  END IF;

  -- Validate the whole batch and collect every source/destination before any
  -- task row changes. The board lock serializes moves, field writes, and access
  -- generation changes for this board.
  FOR v_index IN 1..v_move_count LOOP
    v_task_id := v_move_ids[v_index];
    SELECT task.column_id INTO v_source_column_id
    FROM public.tasks AS task
    JOIN public.columns AS column_row ON column_row.id = task.column_id
    WHERE task.id = v_task_id
      AND column_row.board_id = v_board_id
      AND column_row.generation_id = v_board.active_generation_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Task does not belong to this board'
        USING ERRCODE = '23514';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.columns AS column_row
      WHERE column_row.id = v_requested_source_ids[v_index]
        AND column_row.board_id = v_board_id
        AND column_row.generation_id = v_board.active_generation_id
    ) THEN
      RAISE EXCEPTION 'Source column does not belong to this board'
        USING ERRCODE = '23514';
    END IF;
    IF v_source_column_id IS DISTINCT FROM v_requested_source_ids[v_index] THEN
      v_conflict := true;
    END IF;
    v_destination_column_id := v_destination_ids[v_index];
    IF NOT EXISTS (
      SELECT 1 FROM public.columns AS column_row
      WHERE column_row.id = v_destination_column_id
        AND column_row.board_id = v_board_id
        AND column_row.generation_id = v_board.active_generation_id
    ) THEN
      RAISE EXCEPTION 'Destination column does not belong to this board'
        USING ERRCODE = '23514';
    END IF;
    IF array_position(v_touched_column_ids, v_requested_source_ids[v_index]) IS NULL THEN
      v_touched_column_ids := array_append(v_touched_column_ids, v_requested_source_ids[v_index]);
    END IF;
    IF array_position(v_touched_column_ids, v_destination_column_id) IS NULL THEN
      v_touched_column_ids := array_append(v_touched_column_ids, v_destination_column_id);
    END IF;
    IF array_position(v_snapshot_column_ids, v_source_column_id) IS NULL THEN
      v_snapshot_column_ids := array_append(v_snapshot_column_ids, v_source_column_id);
    END IF;
    IF array_position(v_snapshot_column_ids, v_requested_source_ids[v_index]) IS NULL THEN
      v_snapshot_column_ids := array_append(v_snapshot_column_ids, v_requested_source_ids[v_index]);
    END IF;
    IF array_position(v_snapshot_column_ids, v_destination_column_id) IS NULL THEN
      v_snapshot_column_ids := array_append(v_snapshot_column_ids, v_destination_column_id);
    END IF;
  END LOOP;

  IF (SELECT count(*) FROM jsonb_object_keys(p_expected_order_versions))
    <> cardinality(v_touched_column_ids) THEN
    RAISE EXCEPTION 'Expected order versions must cover exactly the affected columns (received %, expected %)',
      jsonb_object_length(p_expected_order_versions), cardinality(v_touched_column_ids)
      USING ERRCODE = '23514';
  END IF;
  FOREACH v_column_id IN ARRAY v_touched_column_ids LOOP
    v_expected := p_expected_order_versions->v_column_id::text;
    IF v_expected IS NULL OR jsonb_typeof(v_expected) IS DISTINCT FROM 'number'
      OR v_expected::text !~ '^[1-9][0-9]*$' THEN
      RAISE EXCEPTION 'Every affected column requires a positive order version'
        USING ERRCODE = '23514';
    END IF;
  END LOOP;

  FOREACH v_column_id IN ARRAY v_touched_column_ids LOOP
    SELECT column_row.task_order_version INTO v_current_order_version
    FROM public.columns AS column_row
    WHERE column_row.id = v_column_id;
    IF v_current_order_version <> (p_expected_order_versions->>v_column_id::text)::bigint THEN
      v_conflict := true;
    END IF;
  END LOOP;

  IF NOT v_conflict THEN
    -- Anchors are checked against the destination after all tasks in the
    -- request have been removed. Several tasks may target one gap; their input
    -- array order is the deterministic order within that gap.
    FOR v_index IN 1..v_move_count LOOP
      v_column_id := v_destination_ids[v_index];
      SELECT COALESCE(array_agg(task.id ORDER BY task.position, task.id), ARRAY[]::uuid[])
      INTO v_base_ids
      FROM public.tasks AS task
      WHERE task.column_id = v_column_id
        AND NOT (task.id = ANY(v_move_ids));
      v_base_count := cardinality(v_base_ids);
      v_before_id := v_before_ids[v_index];
      v_after_id := v_after_ids[v_index];
      v_before_position := CASE WHEN v_before_id IS NULL THEN NULL ELSE array_position(v_base_ids, v_before_id) END;
      v_after_position := CASE WHEN v_after_id IS NULL THEN NULL ELSE array_position(v_base_ids, v_after_id) END;

      IF v_before_id IS NULL AND v_after_id IS NULL AND v_base_count = 0 THEN
        v_gap_slot := 0;
      ELSIF v_before_id IS NULL AND v_after_position = 1 THEN
        v_gap_slot := 0;
      ELSIF v_after_id IS NULL AND v_before_position = v_base_count THEN
        v_gap_slot := v_base_count;
      ELSIF v_before_position IS NOT NULL
        AND v_after_position = v_before_position + 1 THEN
        v_gap_slot := v_before_position;
      ELSE
        v_conflict := true;
        EXIT;
      END IF;
      v_gap_slots := array_append(v_gap_slots, v_gap_slot);
    END LOOP;
  END IF;

  IF v_conflict THEN
    SELECT COALESCE(jsonb_agg(
      jsonb_build_object(
        'id', column_row.id,
        'task_order_version', column_row.task_order_version,
        'tasks', COALESCE((
          SELECT jsonb_agg(to_jsonb(task) ORDER BY task.position, task.id)
          FROM public.tasks AS task WHERE task.column_id = column_row.id
        ), '[]'::jsonb)
      ) ORDER BY column_row.position, column_row.id
    ), '[]'::jsonb)
    INTO v_column_snapshots
    FROM public.columns AS column_row
    WHERE column_row.id = ANY(v_snapshot_column_ids);
    v_result := jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'columns', v_column_snapshots
    );
    UPDATE public.task_order_receipts AS receipt
    SET result_status = 'conflict', result_payload = v_result
    WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
    RETURN v_result;
  END IF;

  FOREACH v_column_id IN ARRAY v_touched_column_ids LOOP
    SELECT COALESCE(array_agg(task.id ORDER BY task.position, task.id), ARRAY[]::uuid[])
    INTO v_base_ids
    FROM public.tasks AS task
    WHERE task.column_id = v_column_id
      AND NOT (task.id = ANY(v_move_ids));
    v_base_count := cardinality(v_base_ids);
    v_final_ids := ARRAY[]::uuid[];
    FOR v_gap_slot IN 0..v_base_count LOOP
      FOR v_index IN 1..v_move_count LOOP
        IF v_destination_ids[v_index] = v_column_id
          AND v_gap_slots[v_index] = v_gap_slot THEN
          v_final_ids := array_append(v_final_ids, v_move_ids[v_index]);
        END IF;
      END LOOP;
      IF v_gap_slot < v_base_count THEN
        v_final_ids := array_append(v_final_ids, v_base_ids[v_gap_slot + 1]);
      END IF;
    END LOOP;

    IF cardinality(v_final_ids) > 0 THEN
      FOR v_index IN 1..cardinality(v_final_ids) LOOP
        UPDATE public.tasks AS task
        SET column_id = v_column_id, position = v_index - 1
        WHERE task.id = v_final_ids[v_index]
          AND (task.column_id IS DISTINCT FROM v_column_id
            OR task.position IS DISTINCT FROM v_index - 1);
      END LOOP;
    END IF;
  END LOOP;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', column_row.id,
      'task_order_version', column_row.task_order_version,
      'tasks', COALESCE((
        SELECT jsonb_agg(to_jsonb(task) ORDER BY task.position, task.id)
        FROM public.tasks AS task WHERE task.column_id = column_row.id
      ), '[]'::jsonb)
    ) ORDER BY column_row.position, column_row.id
  ), '[]'::jsonb)
  INTO v_column_snapshots
  FROM public.columns AS column_row
  WHERE column_row.id = ANY(v_touched_column_ids);

  v_result := jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'columns', v_column_snapshots
  );
  UPDATE public.task_order_receipts AS receipt
  SET result_status = 'confirmed', result_payload = v_result
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.update_task_positions_p(uuid, text, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_task_positions_p(uuid, text, jsonb, jsonb)
  TO authenticated;

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
      || jsonb_build_object('role', v_role))::json,
    'columns', COALESCE(
      (
        SELECT json_agg(
          json_build_object(
            'id', column_row.id,
            'board_id', column_row.board_id,
            'title', column_row.title,
            'position', column_row.position,
            'is_collapsed', column_row.is_collapsed,
            'task_order_version', column_row.task_order_version,
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

DROP FUNCTION public.get_columns_p(uuid);
CREATE FUNCTION public.get_columns_p(p_board_id uuid)
RETURNS TABLE (
  id uuid,
  board_id uuid,
  title text,
  "position" integer,
  is_collapsed boolean,
  task_order_version bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT column_row.id, column_row.board_id, column_row.title,
    column_row.position, column_row.is_collapsed,
    column_row.task_order_version, column_row.created_at
  FROM public.columns AS column_row
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE board.id = p_board_id
    AND board.active_generation_id = column_row.generation_id
    AND public.is_board_member(board.id)
  ORDER BY column_row.position, column_row.id;
$$;

REVOKE ALL ON FUNCTION public.get_full_board_p(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_full_board_p(text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_columns_p(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_columns_p(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
