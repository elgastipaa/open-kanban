BEGIN;

-- Resolve a restored column's receipt after the successful restore removed its
-- recovery ledger row. The board lock and current membership check still gate
-- every replay before any operation result is returned.
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

  -- A successful restore deletes column_deletions. In that case the restored
  -- row identifies the board whose current membership must authorize replay.
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
  SET result_status = v_response->>'status'
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id;
  RETURN v_response;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
