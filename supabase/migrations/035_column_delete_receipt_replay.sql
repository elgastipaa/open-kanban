BEGIN;

ALTER TABLE public.column_recovery_receipts
  ADD COLUMN result_payload jsonb;

CREATE OR REPLACE FUNCTION public.column_recovery_result_p(
  p_actor_id uuid,
  p_operation_id uuid,
  p_command text,
  p_board_id uuid,
  p_column_id uuid,
  p_destination_column_id uuid,
  p_expected_task_order_version bigint,
  p_payload_hash bytea
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_receipt public.column_recovery_receipts%ROWTYPE;
BEGIN
  SELECT receipt.* INTO v_receipt
  FROM public.column_recovery_receipts AS receipt
  WHERE receipt.actor_id = p_actor_id
    AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_receipt.command IS DISTINCT FROM p_command
    OR v_receipt.board_id IS DISTINCT FROM p_board_id
    OR v_receipt.column_id IS DISTINCT FROM p_column_id
    OR v_receipt.destination_column_id IS DISTINCT FROM p_destination_column_id
    OR v_receipt.expected_task_order_version IS DISTINCT FROM p_expected_task_order_version
    OR v_receipt.payload_hash IS DISTINCT FROM p_payload_hash THEN
    RAISE EXCEPTION 'Column recovery operation key was already used'
      USING ERRCODE = '23514';
  END IF;
  IF v_receipt.result_expires_at <= clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
  END IF;
  IF v_receipt.result_status = 'pending' THEN
    RETURN jsonb_build_object('status', 'retryable', 'operation_id', p_operation_id);
  END IF;
  RETURN coalesce(
    v_receipt.result_payload,
    jsonb_build_object('status', v_receipt.result_status, 'operation_id', p_operation_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_column_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_column_id uuid,
  p_destination_column_id uuid,
  p_expected_task_order_version bigint,
  p_deleted_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_column public.columns%ROWTYPE;
  v_destination public.columns%ROWTYPE;
  v_deletion public.column_deletions%ROWTYPE;
  v_payload_hash bytea;
  v_response jsonb;
  v_task_count integer;
  v_destination_position integer;
  v_deleted_at timestamptz;
  v_receipt public.column_recovery_receipts%ROWTYPE;
  v_has_deletion boolean;
  v_has_column boolean;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_column_id IS NULL
    OR p_expected_task_order_version IS NULL THEN
    RAISE EXCEPTION 'Column deletion requires a preview and operation id'
      USING ERRCODE = '22023';
  END IF;

  -- A committed deletion removes the source row but retains the board id in
  -- the recovery ledger. After a later restore, the active column locates it.
  SELECT deletion.board_id INTO v_board.id
  FROM public.column_deletions AS deletion
  WHERE deletion.column_id = p_column_id;
  IF NOT FOUND THEN
    SELECT board.id INTO v_board.id
    FROM public.boards AS board
    JOIN public.columns AS column_row ON column_row.board_id = board.id
    WHERE board.slug = p_slug AND column_row.id = p_column_id;
  END IF;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board.id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT deletion.* INTO v_deletion
  FROM public.column_deletions AS deletion
  WHERE deletion.column_id = p_column_id AND deletion.board_id = v_board.id
  FOR UPDATE;
  v_has_deletion := FOUND;

  SELECT column_row.* INTO v_column
  FROM public.columns AS column_row
  WHERE column_row.id = p_column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  FOR UPDATE;
  v_has_column := FOUND;
  IF NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := extensions.digest(convert_to(jsonb_build_object(
    'command', 'delete',
    'board_id', v_board.id,
    'column_id', p_column_id,
    'destination_column_id', p_destination_column_id,
    'expected_task_order_version', p_expected_task_order_version
  )::text, 'UTF8'), 'sha256');
  v_response := public.column_recovery_result_p(
    v_actor_id, p_operation_id, 'delete', v_board.id, p_column_id,
    p_destination_column_id, p_expected_task_order_version, v_payload_hash
  );
  IF v_response IS NOT NULL THEN RETURN v_response; END IF;
  IF NOT v_has_column OR v_has_deletion THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  INSERT INTO public.column_recovery_receipts(
    actor_id, operation_id, command, board_id, column_id,
    destination_column_id, expected_task_order_version, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'delete', v_board.id, p_column_id,
    p_destination_column_id, p_expected_task_order_version, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_response := public.column_recovery_result_p(
      v_actor_id, p_operation_id, 'delete', v_board.id, p_column_id,
      p_destination_column_id, p_expected_task_order_version, v_payload_hash
    );
    IF v_response IS NOT NULL THEN RETURN v_response; END IF;
    RAISE EXCEPTION 'Column deletion result could not be reconciled'
      USING ERRCODE = '40001';
  END IF;

  SELECT count(*)::integer INTO v_task_count
  FROM public.tasks AS task
  WHERE task.column_id = v_column.id;
  IF v_column.task_order_version IS DISTINCT FROM p_expected_task_order_version
    OR (SELECT count(*) FROM public.columns AS candidate
        WHERE candidate.board_id = v_board.id
          AND candidate.generation_id = v_board.active_generation_id) <= 1 THEN
    v_response := jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  ELSIF v_task_count > 0 AND p_destination_column_id IS NULL THEN
    v_response := jsonb_build_object('status', 'needs_destination', 'operation_id', p_operation_id);
  ELSE
    IF p_destination_column_id IS NOT NULL THEN
      SELECT candidate.* INTO v_destination
      FROM public.columns AS candidate
      WHERE candidate.id = p_destination_column_id
        AND candidate.board_id = v_board.id
        AND candidate.generation_id = v_board.active_generation_id
        AND candidate.id <> v_column.id
      FOR UPDATE;
      IF NOT FOUND THEN
        v_response := jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
      END IF;
    END IF;
    IF v_response IS NULL THEN
      IF v_task_count > 0 THEN
        SELECT coalesce(max(task.position) + 1, 0)::integer INTO v_destination_position
        FROM public.tasks AS task
        WHERE task.column_id = v_destination.id;
        WITH moving AS (
          SELECT task.id,
            row_number() OVER (ORDER BY task.position, task.created_at, task.id) - 1 AS offset
          FROM public.tasks AS task
          WHERE task.column_id = v_column.id
        )
        UPDATE public.tasks AS task
        SET column_id = v_destination.id,
            position = v_destination_position + moving.offset
        FROM moving
        WHERE task.id = moving.id;
      END IF;
      v_deleted_at := coalesce(p_deleted_at, clock_timestamp());
      INSERT INTO public.column_deletions(
        column_id, board_id, deleted_by, cause, deleted_at, expires_at,
        column_snapshot, destination_column_id, moved_task_count, state
      ) VALUES (
        v_column.id, v_board.id, v_actor_id, 'user_requested', v_deleted_at,
        v_deleted_at + interval '168 hours', to_jsonb(v_column),
        p_destination_column_id, v_task_count, 'deleted'
      );
      DELETE FROM public.columns AS column_row
      WHERE column_row.id = v_column.id
        AND column_row.board_id = v_board.id
        AND column_row.generation_id = v_board.active_generation_id;
      WITH ordered AS (
        SELECT candidate.id,
          row_number() OVER (ORDER BY candidate.position, candidate.id) - 1 AS next_position
        FROM public.columns AS candidate
        WHERE candidate.board_id = v_board.id
          AND candidate.generation_id = v_board.active_generation_id
      )
      UPDATE public.columns AS candidate
      SET position = ordered.next_position
      FROM ordered
      WHERE candidate.id = ordered.id;
      v_response := jsonb_build_object(
        'status', 'confirmed', 'operation_id', p_operation_id,
        'column_id', p_column_id, 'deletion_id', p_column_id,
        'moved_task_count', v_task_count, 'expires_at', v_deleted_at + interval '168 hours'
      );
    END IF;
  END IF;
  UPDATE public.column_recovery_receipts AS receipt
  SET result_status = v_response->>'status', result_payload = v_response
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN v_response;
END;
$$;

CREATE OR REPLACE FUNCTION public.restore_column_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_column_id uuid,
  p_restored_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_deletion public.column_deletions%ROWTYPE;
  v_column public.columns%ROWTYPE;
  v_payload_hash bytea;
  v_response jsonb;
  v_receipt public.column_recovery_receipts%ROWTYPE;
  v_now timestamptz;
  v_position integer;
  v_column_count integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_column_id IS NULL THEN
    RAISE EXCEPTION 'Column recovery requires an operation and column'
      USING ERRCODE = '22023';
  END IF;
  SELECT deletion.board_id INTO v_board.id
  FROM public.column_deletions AS deletion
  WHERE deletion.column_id = p_column_id;
  IF NOT FOUND THEN
    SELECT board.id INTO v_board.id
    FROM public.boards AS board
    JOIN public.columns AS column_row ON column_row.board_id = board.id
    WHERE board.slug = p_slug AND column_row.id = p_column_id;
  END IF;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board.id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT deletion.* INTO v_deletion
  FROM public.column_deletions AS deletion
  WHERE deletion.column_id = p_column_id AND deletion.board_id = v_board.id
  FOR UPDATE;
  v_payload_hash := extensions.digest(convert_to(jsonb_build_object(
    'command', 'restore', 'board_id', v_board.id, 'column_id', p_column_id
  )::text, 'UTF8'), 'sha256');
  v_response := public.column_recovery_result_p(
    v_actor_id, p_operation_id, 'restore', v_board.id, p_column_id,
    NULL, NULL, v_payload_hash
  );
  IF v_response IS NOT NULL THEN RETURN v_response; END IF;
  IF NOT FOUND OR v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.column_snapshot IS NULL THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  INSERT INTO public.column_recovery_receipts(
    actor_id, operation_id, command, board_id, column_id,
    destination_column_id, expected_task_order_version, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'restore', v_board.id, p_column_id,
    NULL, NULL, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_response := public.column_recovery_result_p(
      v_actor_id, p_operation_id, 'restore', v_board.id, p_column_id,
      NULL, NULL, v_payload_hash
    );
    IF v_response IS NOT NULL THEN RETURN v_response; END IF;
    RAISE EXCEPTION 'Column recovery result could not be reconciled'
      USING ERRCODE = '40001';
  END IF;
  v_now := coalesce(p_restored_at, clock_timestamp());
  IF v_now >= v_deletion.expires_at THEN
    v_response := jsonb_build_object('status', 'expired', 'operation_id', p_operation_id);
  ELSIF (v_deletion.column_snapshot->>'generation_id')::uuid
      IS DISTINCT FROM v_board.active_generation_id THEN
    v_response := jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  ELSIF EXISTS (
    SELECT 1 FROM public.columns AS column_row WHERE column_row.id = p_column_id
  ) THEN
    v_response := jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  ELSE
    SELECT count(*)::integer INTO v_column_count
    FROM public.columns AS column_row
    WHERE column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id;
    v_position := least(
      greatest((v_deletion.column_snapshot->>'position')::integer, 0),
      v_column_count
    );
    UPDATE public.columns AS column_row
    SET position = column_row.position + 1
    WHERE column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id
      AND column_row.position >= v_position;
    v_column := jsonb_populate_record(NULL::public.columns, v_deletion.column_snapshot);
    v_column.position := v_position;
    INSERT INTO public.columns SELECT v_column.*;
    DELETE FROM public.column_deletions AS deletion
    WHERE deletion.column_id = p_column_id AND deletion.board_id = v_board.id;
    v_response := jsonb_build_object(
      'status', 'confirmed', 'operation_id', p_operation_id,
      'column_id', p_column_id, 'moved_task_count', v_deletion.moved_task_count
    );
  END IF;
  UPDATE public.column_recovery_receipts AS receipt
  SET result_status = v_response->>'status', result_payload = v_response
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN v_response;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
