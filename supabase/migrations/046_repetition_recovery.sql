-- Repetition recovery keeps a detached series snapshot for one exact week.
-- The live series and its occurrence slots are removed only after their own
-- currently owned tasks have been tombstoned with a parent-specific cause.
BEGIN;

ALTER TABLE public.daily_repetition_receipts
  DROP CONSTRAINT daily_repetition_receipts_action_check,
  ADD CONSTRAINT daily_repetition_receipts_action_check
    CHECK (action IN ('create', 'stop', 'set_count', 'edit', 'delete', 'restore'));

ALTER TABLE public.task_deletions
  ADD COLUMN parent_series_id uuid;
UPDATE public.task_deletions AS deletion
SET parent_series_id = linked.series_id
FROM (
  SELECT DISTINCT ON (occurrence.task_id)
    occurrence.task_id, occurrence.series_id
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series
    ON series.id = occurrence.series_id
  JOIN public.boards AS board
    ON board.id = series.board_id
    AND board.active_generation_id = series.generation_id
  WHERE occurrence.state IN ('current', 'replaced', 'excluded')
  ORDER BY occurrence.task_id,
    (occurrence.state = 'current') DESC,
    occurrence.occurrence_on DESC, occurrence.id DESC
) AS linked
WHERE deletion.task_id = linked.task_id
  AND deletion.cause = 'user_requested'
  AND deletion.state = 'deleted'
  AND deletion.task_snapshot IS NOT NULL;
ALTER TABLE public.task_deletions
  DROP CONSTRAINT task_deletions_cause_check,
  ADD CONSTRAINT task_deletions_cause_check
    CHECK (cause IN ('user_requested', 'series_requested')),
  ADD CONSTRAINT task_deletions_parent_series_shape CHECK (
    (cause = 'series_requested' AND parent_series_id IS NOT NULL)
    OR cause = 'user_requested'
  );
CREATE INDEX task_deletions_parent_series_idx
  ON public.task_deletions(parent_series_id, state, expires_at)
  WHERE parent_series_id IS NOT NULL;

CREATE TABLE public.daily_repetition_series_deletions (
  series_id uuid PRIMARY KEY,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  deleted_by uuid NOT NULL,
  cause text NOT NULL CHECK (cause = 'user_requested'),
  deleted_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  series_snapshot jsonb,
  occurrences_snapshot jsonb,
  state text NOT NULL CHECK (state IN ('deleted', 'restored', 'purged')),
  restored_at timestamptz,
  purged_at timestamptz,
  CONSTRAINT daily_repetition_series_deletions_window CHECK (
    expires_at = deleted_at + interval '168 hours'
  ),
  CONSTRAINT daily_repetition_series_deletions_state_shape CHECK (
    (state = 'deleted' AND series_snapshot IS NOT NULL
      AND occurrences_snapshot IS NOT NULL
      AND restored_at IS NULL AND purged_at IS NULL)
    OR (state = 'restored' AND series_snapshot IS NULL
      AND occurrences_snapshot IS NULL
      AND restored_at IS NOT NULL AND purged_at IS NULL)
    OR (state = 'purged' AND series_snapshot IS NULL
      AND occurrences_snapshot IS NULL
      AND restored_at IS NULL AND purged_at IS NOT NULL)
  )
);
CREATE INDEX daily_repetition_series_deletions_board_expiry_idx
  ON public.daily_repetition_series_deletions(board_id, expires_at, series_id)
  WHERE state = 'deleted';
ALTER TABLE public.daily_repetition_series_deletions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.daily_repetition_series_deletions
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.guard_series_task_restore_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF OLD.state = 'deleted' AND NEW.state = 'restored'
    AND OLD.parent_series_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_series AS series
      JOIN public.boards AS board ON board.id = series.board_id
      WHERE series.id = OLD.parent_series_id
        AND series.board_id = OLD.board_id
        AND series.generation_id = board.active_generation_id
    ) THEN
    RAISE EXCEPTION 'Primero recupera la serie que contiene esta ocurrencia'
      USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_series_task_restore_tg()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER task_deletions_require_series_parent_restore
  BEFORE UPDATE OF state ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.guard_series_task_restore_tg();

CREATE OR REPLACE FUNCTION public.sync_daily_repetition_task_deletion_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_is_deletion boolean;
BEGIN
  v_is_deletion := TG_OP = 'INSERT';
  IF NOT v_is_deletion THEN
    v_is_deletion := NEW.state = 'deleted' AND OLD.state IS DISTINCT FROM 'deleted';
  END IF;
  IF v_is_deletion THEN
    IF NEW.cause = 'user_requested' THEN
      UPDATE public.task_deletions AS deletion
      SET parent_series_id = (
        SELECT occurrence.series_id
        FROM public.daily_repetition_occurrences AS occurrence
        JOIN public.daily_repetition_series AS series
          ON series.id = occurrence.series_id
        JOIN public.boards AS board
          ON board.id = series.board_id
          AND board.active_generation_id = series.generation_id
        WHERE occurrence.task_id = NEW.task_id
          AND occurrence.state IN ('current', 'replaced')
          AND series.board_id = NEW.board_id
        ORDER BY (occurrence.state = 'current') DESC,
          occurrence.occurrence_on DESC, occurrence.id DESC
        LIMIT 1
      )
      WHERE deletion.task_id = NEW.task_id
        AND deletion.state = 'deleted'
        AND deletion.cause = 'user_requested';
    END IF;
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = 'excluded'
    WHERE occurrence.task_id = NEW.task_id
      AND occurrence.state IN ('current', 'replaced');
    RETURN NEW;
  END IF;
  IF NEW.state = 'restored' AND OLD.state = 'deleted' THEN
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = CASE WHEN EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS later
      WHERE later.series_id = occurrence.series_id
        AND later.occurrence_on > occurrence.occurrence_on
        AND later.state IN ('current', 'replaced', 'excluded', 'retired', 'purged')
    ) THEN 'replaced' ELSE 'current' END
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'excluded';
    UPDATE public.daily_repetition_series AS series
    SET current_occurrence_id = occurrence.id,
        updated_at = pg_catalog.clock_timestamp()
    FROM public.daily_repetition_occurrences AS occurrence
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'current'
      AND NOT EXISTS (
        SELECT 1 FROM public.daily_repetition_occurrences AS later
        WHERE later.series_id = occurrence.series_id
          AND later.occurrence_on > occurrence.occurrence_on
          AND later.state IN ('current', 'replaced', 'excluded', 'retired', 'purged')
      )
      AND series.id = occurrence.series_id;
  ELSIF NEW.state = 'purged' AND OLD.state = 'deleted' THEN
    UPDATE public.daily_repetition_occurrences AS occurrence
    SET state = 'purged'
    WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'excluded';
    UPDATE public.daily_repetition_series AS series
    SET current_occurrence_id = NULL, updated_at = pg_catalog.clock_timestamp()
    WHERE series.current_occurrence_id IN (
      SELECT occurrence.id FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.task_id = NEW.task_id AND occurrence.state = 'purged'
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_daily_repetition_task_deletion_tg()
  FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.list_deleted_tasks_p(text)
  RENAME TO list_deleted_tasks_base_internal_p;
REVOKE ALL ON FUNCTION public.list_deleted_tasks_base_internal_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.list_deleted_tasks_p(p_slug text)
RETURNS TABLE (
  task_id uuid,
  title text,
  original_column_id uuid,
  cause text,
  deleted_at timestamptz,
  expires_at timestamptz,
  can_restore boolean,
  original_column_available boolean,
  eligibility_checked_at timestamptz
)
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT item.task_id, item.title, item.original_column_id, item.cause,
    item.deleted_at, item.expires_at, item.can_restore,
    item.original_column_available, item.eligibility_checked_at
  FROM public.list_deleted_tasks_base_internal_p(p_slug) AS item
  JOIN public.task_deletions AS deletion ON deletion.task_id = item.task_id
  JOIN public.boards AS board
    ON board.id = deletion.board_id AND board.slug = p_slug
  WHERE item.cause <> 'series_requested'
    AND (
      deletion.parent_series_id IS NULL
      OR EXISTS (
        SELECT 1 FROM public.daily_repetition_series AS series
        WHERE series.id = deletion.parent_series_id
          AND series.board_id = board.id
          AND series.generation_id = board.active_generation_id
      )
    );
$$;
REVOKE ALL ON FUNCTION public.list_deleted_tasks_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_deleted_tasks_p(text) TO authenticated;

ALTER FUNCTION public.restore_task_internal_p(uuid, text, uuid, uuid, timestamptz)
  RENAME TO restore_task_base_internal_p;
REVOKE ALL ON FUNCTION public.restore_task_base_internal_p(
  uuid, text, uuid, uuid, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.restore_task_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_target_column_id uuid,
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
  v_deletion public.task_deletions%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_id IS NULL THEN
    RAISE EXCEPTION 'Task recovery requires an operation and task'
      USING ERRCODE = '22023';
  END IF;

  SELECT deletion.board_id INTO v_board_id
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id AND board.slug = p_slug
    AND public.is_board_member(v_board_id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board_id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT deletion.* INTO v_deletion
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id AND deletion.board_id = v_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_deletion.state = 'deleted'
    AND v_deletion.task_snapshot IS NOT NULL
    AND v_deletion.cause = 'user_requested'
    AND v_deletion.parent_series_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_series AS series
      WHERE series.id = v_deletion.parent_series_id
        AND series.board_id = v_board_id
        AND series.generation_id = v_board.active_generation_id
    ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  RETURN public.restore_task_base_internal_p(
    p_operation_id, p_slug, p_id, p_target_column_id, p_now
  );
END;
$$;
REVOKE ALL ON FUNCTION public.restore_task_internal_p(uuid, text, uuid, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.restore_task_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_target_column_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.restore_task_internal_p(
    p_operation_id, p_slug, p_id, p_target_column_id, NULL
  );
$$;
REVOKE ALL ON FUNCTION public.restore_task_p(uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restore_task_p(uuid, text, uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.preview_delete_repetition_series_p(
  p_slug text,
  p_series_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series public.daily_repetition_series%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_occurrence_count integer;
  v_task_count integer;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_series_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = p_series_id AND series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT count(*)::integer INTO v_occurrence_count
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series.id;
  SELECT count(DISTINCT task.id)::integer INTO v_task_count
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.tasks AS task ON task.id = occurrence.task_id
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  WHERE occurrence.series_id = v_series.id
    AND occurrence.state <> 'transferred'
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = task.id
        AND deletion.state IN ('deleted', 'purged')
    );
  RETURN pg_catalog.jsonb_build_object(
    'status', 'available',
    'series_id', v_series.id,
    'board_id', v_board.id,
    'board_slug', v_board.slug,
    'state', v_series.state,
    'revision', v_series.revision,
    'occurrence_count', v_occurrence_count,
    'task_count', v_task_count,
    'title', v_series.template_snapshot->>'title',
    'requires_confirmation', true,
    'retention_hours', 168
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_delete_repetition_series_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_delete_repetition_series_p(text, uuid)
  TO authenticated;

CREATE FUNCTION public.delete_repetition_series_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_series_id uuid,
  p_expected_revision bigint,
  p_confirm_history boolean,
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
  v_series public.daily_repetition_series%ROWTYPE;
  v_receipt public.daily_repetition_receipts%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_payload_hash bytea;
  v_now timestamptz := coalesce(p_deleted_at, pg_catalog.clock_timestamp());
  v_occurrences jsonb;
  v_occurrence_count integer;
  v_task_count integer := 0;
  v_result jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_series_id IS NULL
    OR p_expected_revision IS NULL OR p_expected_revision < 1
    OR p_confirm_history IS NULL THEN
    RAISE EXCEPTION 'Revisa la serie antes de eliminarla' USING ERRCODE = '22023';
  END IF;

  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    v_payload_hash := extensions.digest(pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'delete', 'board_id', v_receipt.board_id,
        'series_id', p_series_id, 'expected_revision', p_expected_revision,
        'confirm_history', p_confirm_history
      )::text, 'UTF8'
    ), 'sha256');
    IF v_receipt.action IS DISTINCT FROM 'delete'
      OR v_receipt.series_id IS DISTINCT FROM p_series_id
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

  SELECT board.* INTO v_board
  FROM public.boards AS board
  JOIN public.daily_repetition_series AS series ON series.board_id = board.id
  WHERE board.slug = p_slug AND series.id = p_series_id;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board.id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  -- Reconcile a repeated request after waiting for another board mutation.
  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'delete'
      OR v_receipt.board_id IS DISTINCT FROM v_board.id
      OR v_receipt.series_id IS DISTINCT FROM p_series_id THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otros datos'
        USING ERRCODE = '23514';
    END IF;
    RETURN v_receipt.result;
  END IF;

  SELECT series.* INTO v_series
  FROM public.daily_repetition_series AS series
  WHERE series.id = p_series_id AND series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_series.revision IS DISTINCT FROM p_expected_revision THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'series_id', p_series_id, 'series_revision', v_series.revision
    );
  END IF;
  IF NOT p_confirm_history THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'confirmation_required', 'operation_id', p_operation_id
    );
  END IF;

  SELECT coalesce(pg_catalog.jsonb_agg(
    pg_catalog.to_jsonb(occurrence)
    ORDER BY occurrence.occurrence_on, occurrence.id
  ), '[]'::jsonb) INTO v_occurrences
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series.id;
  v_occurrence_count := pg_catalog.jsonb_array_length(v_occurrences);

  INSERT INTO public.daily_repetition_series_deletions(
    series_id, board_id, deleted_by, cause, deleted_at, expires_at,
    series_snapshot, occurrences_snapshot, state
  ) VALUES (
    v_series.id, v_board.id, v_actor_id, 'user_requested', v_now,
    v_now + interval '168 hours', pg_catalog.to_jsonb(v_series),
    v_occurrences, 'deleted'
  ) ON CONFLICT (series_id) DO UPDATE SET
    board_id = EXCLUDED.board_id,
    deleted_by = EXCLUDED.deleted_by,
    cause = EXCLUDED.cause,
    deleted_at = EXCLUDED.deleted_at,
    expires_at = EXCLUDED.expires_at,
    series_snapshot = EXCLUDED.series_snapshot,
    occurrences_snapshot = EXCLUDED.occurrences_snapshot,
    state = 'deleted', restored_at = NULL, purged_at = NULL;

  FOR v_task IN
    SELECT task.*
    FROM public.daily_repetition_occurrences AS occurrence
    JOIN public.tasks AS task ON task.id = occurrence.task_id
    JOIN public.columns AS column_row
      ON column_row.id = task.column_id
      AND column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id
    WHERE occurrence.series_id = v_series.id
      AND occurrence.state <> 'transferred'
      AND NOT EXISTS (
        SELECT 1 FROM public.task_deletions AS deletion
        WHERE deletion.task_id = task.id
          AND deletion.state IN ('deleted', 'purged')
      )
    ORDER BY occurrence.occurrence_on, occurrence.id
    FOR UPDATE OF task
  LOOP
    INSERT INTO public.task_deletions(
      task_id, board_id, original_column_id, deleted_by, cause,
      parent_series_id, deleted_at, expires_at, task_snapshot, state
    ) VALUES (
      v_task.id, v_board.id, v_task.column_id, v_actor_id, 'series_requested',
      v_series.id, v_now, v_now + interval '168 hours',
      pg_catalog.to_jsonb(v_task), 'deleted'
    ) ON CONFLICT (task_id) DO UPDATE SET
      board_id = EXCLUDED.board_id,
      original_column_id = EXCLUDED.original_column_id,
      deleted_by = EXCLUDED.deleted_by,
      cause = EXCLUDED.cause,
      parent_series_id = EXCLUDED.parent_series_id,
      deleted_at = EXCLUDED.deleted_at,
      expires_at = EXCLUDED.expires_at,
      task_snapshot = EXCLUDED.task_snapshot,
      state = 'deleted', restored_at = NULL, purged_at = NULL;
    DELETE FROM public.tasks AS task WHERE task.id = v_task.id;
    v_task_count := v_task_count + 1;
  END LOOP;

  DELETE FROM public.daily_repetition_series AS series
  WHERE series.id = v_series.id AND series.board_id = v_board.id;

  v_payload_hash := extensions.digest(pg_catalog.convert_to(
    pg_catalog.jsonb_build_object(
      'action', 'delete', 'board_id', v_board.id,
      'series_id', v_series.id,
      'expected_revision', p_expected_revision,
      'confirm_history', p_confirm_history
    )::text, 'UTF8'
  ), 'sha256');
  v_result := pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'series_id', v_series.id, 'state', v_series.state,
    'deleted_at', v_now, 'expires_at', v_now + interval '168 hours',
    'occurrence_count', v_occurrence_count, 'task_count', v_task_count
  );
  INSERT INTO public.daily_repetition_receipts(
    actor_id, operation_id, action, board_id, task_id, series_id,
    payload_hash, result
  ) VALUES (
    v_actor_id, p_operation_id, 'delete', v_board.id,
    v_series.first_task_id, v_series.id, v_payload_hash, v_result
  );
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_repetition_series_internal_p(
  uuid, text, uuid, bigint, boolean, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.delete_repetition_series_p(
  p_operation_id uuid,
  p_slug text,
  p_series_id uuid,
  p_expected_revision bigint,
  p_confirm_history boolean
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.delete_repetition_series_internal_p(
    p_operation_id, p_slug, p_series_id, p_expected_revision,
    p_confirm_history, NULL
  );
$$;
REVOKE ALL ON FUNCTION public.delete_repetition_series_p(uuid, text, uuid, bigint, boolean)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_repetition_series_p(uuid, text, uuid, bigint, boolean)
  TO authenticated;

CREATE FUNCTION public.list_deleted_repetition_series_p(p_board_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_series jsonb;
  v_checked_at timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'series', '[]'::jsonb);
  END IF;
  SELECT coalesce(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'series_id', deletion.series_id,
      'board_id', board.id,
      'board_slug', board.slug,
      'board_name', board.name,
      'title', deletion.series_snapshot->'template_snapshot'->>'title',
      'state', deletion.series_snapshot->>'state',
      'deleted_at', deletion.deleted_at,
      'expires_at', deletion.expires_at,
      'occurrence_count', pg_catalog.jsonb_array_length(deletion.occurrences_snapshot),
      'can_restore', v_checked_at < deletion.expires_at
        AND board.active_generation_id::text = deletion.series_snapshot->>'generation_id'
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS child
          WHERE child.parent_series_id = deletion.series_id
            AND child.cause = 'series_requested'
            AND child.state = 'deleted'
            AND NOT EXISTS (
              SELECT 1 FROM public.columns AS column_row
              WHERE column_row.id = child.original_column_id
                AND column_row.board_id = board.id
                AND column_row.generation_id = board.active_generation_id
            )
        ),
      'generation_available',
        board.active_generation_id::text = deletion.series_snapshot->>'generation_id',
      'appearance_column_available', EXISTS (
          SELECT 1 FROM public.columns AS column_row
          WHERE column_row.id = (deletion.series_snapshot->>'appearance_column_id')::uuid
            AND column_row.board_id = board.id
            AND column_row.generation_id = board.active_generation_id
        )
      , 'child_columns_available', NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS child
          WHERE child.parent_series_id = deletion.series_id
            AND child.cause = 'series_requested'
            AND child.state = 'deleted'
            AND NOT EXISTS (
              SELECT 1 FROM public.columns AS column_row
              WHERE column_row.id = child.original_column_id
                AND column_row.board_id = board.id
                AND column_row.generation_id = board.active_generation_id
            )
        ),
      'eligibility_checked_at', v_checked_at
    ) ORDER BY deletion.deleted_at DESC, deletion.series_id
  ), '[]'::jsonb) INTO v_series
  FROM public.daily_repetition_series_deletions AS deletion
  JOIN public.boards AS board ON board.id = deletion.board_id
  WHERE deletion.state = 'deleted'
    AND (p_board_id IS NULL OR deletion.board_id = p_board_id)
    AND public.is_board_member(board.id);
  RETURN pg_catalog.jsonb_build_object('status', 'available', 'series', v_series);
END;
$$;
REVOKE ALL ON FUNCTION public.list_deleted_repetition_series_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_deleted_repetition_series_p(uuid)
  TO authenticated;

CREATE FUNCTION public.restore_repetition_series_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_series_id uuid,
  p_target_appearance_column_id uuid,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_deletion public.daily_repetition_series_deletions%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_receipt public.daily_repetition_receipts%ROWTYPE;
  v_column_id uuid;
  v_payload_hash bytea;
  v_now timestamptz := coalesce(p_now, pg_catalog.clock_timestamp());
  v_occurrence_id uuid;
  v_task_deletion public.task_deletions%ROWTYPE;
  v_task_result jsonb;
  v_result jsonb;
  v_status text;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_series_id IS NULL THEN
    RAISE EXCEPTION 'La recuperación requiere una operación y una serie'
      USING ERRCODE = '22023';
  END IF;

  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    v_payload_hash := extensions.digest(pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'restore', 'board_id', v_receipt.board_id,
        'series_id', p_series_id,
        'appearance_column_id', p_target_appearance_column_id
      )::text, 'UTF8'
    ), 'sha256');
    IF v_receipt.action IS DISTINCT FROM 'restore'
      OR v_receipt.series_id IS DISTINCT FROM p_series_id
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

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND (
      EXISTS (
        SELECT 1 FROM public.daily_repetition_series AS series
        WHERE series.id = p_series_id AND series.board_id = board.id
      )
      OR EXISTS (
        SELECT 1 FROM public.daily_repetition_series_deletions AS deletion
        WHERE deletion.series_id = p_series_id AND deletion.board_id = board.id
      )
    )
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board.id AND board.slug = p_slug
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT receipt.* INTO v_receipt
  FROM public.daily_repetition_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id AND receipt.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_receipt.action IS DISTINCT FROM 'restore'
      OR v_receipt.board_id IS DISTINCT FROM v_board.id
      OR v_receipt.series_id IS DISTINCT FROM p_series_id THEN
      RAISE EXCEPTION 'Esta operación ya se usó con otros datos'
        USING ERRCODE = '23514';
    END IF;
    RETURN v_receipt.result;
  END IF;

  SELECT deletion.* INTO v_deletion
  FROM public.daily_repetition_series_deletions AS deletion
  WHERE deletion.series_id = p_series_id AND deletion.board_id = v_board.id
  FOR UPDATE;
  IF NOT FOUND OR v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.series_snapshot IS NULL
    OR v_deletion.occurrences_snapshot IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_now >= v_deletion.expires_at THEN
    RETURN pg_catalog.jsonb_build_object('status', 'expired', 'operation_id', p_operation_id);
  END IF;
  IF v_board.active_generation_id::text
    IS DISTINCT FROM v_deletion.series_snapshot->>'generation_id' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'needs_parent', 'operation_id', p_operation_id);
  END IF;

  v_column_id := coalesce(
    p_target_appearance_column_id,
    (v_deletion.series_snapshot->>'appearance_column_id')::uuid
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.columns AS column_row
    WHERE column_row.id = v_column_id AND column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'needs_destination', 'operation_id', p_operation_id);
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.task_deletions AS child
    WHERE child.parent_series_id = p_series_id
      AND child.cause = 'series_requested' AND child.state = 'deleted'
      AND NOT EXISTS (
        SELECT 1 FROM public.columns AS column_row
        WHERE column_row.id = child.original_column_id
          AND column_row.board_id = v_board.id
          AND column_row.generation_id = v_board.active_generation_id
      )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'needs_parent', 'operation_id', p_operation_id);
  END IF;

  v_series := pg_catalog.jsonb_populate_record(
    NULL::public.daily_repetition_series, v_deletion.series_snapshot
  );
  v_occurrence_id := v_series.current_occurrence_id;
  v_series.current_occurrence_id := NULL;
  v_series.appearance_column_id := v_column_id;
  v_series.revision := v_series.revision + 1;
  v_series.updated_at := v_now;
  INSERT INTO public.daily_repetition_series SELECT v_series.*;
  INSERT INTO public.daily_repetition_occurrences
  SELECT occurrence.*
  FROM pg_catalog.jsonb_populate_recordset(
    NULL::public.daily_repetition_occurrences, v_deletion.occurrences_snapshot
  ) AS occurrence;

  FOR v_task_deletion IN
    SELECT child.*
    FROM public.task_deletions AS child
    WHERE child.parent_series_id = p_series_id
      AND child.cause = 'series_requested'
      AND child.state = 'deleted' AND child.task_snapshot IS NOT NULL
    ORDER BY child.deleted_at, child.task_id
    FOR UPDATE
  LOOP
    v_task_result := public.restore_task_internal_p(
      pg_catalog.gen_random_uuid(), p_slug, v_task_deletion.task_id,
      v_task_deletion.original_column_id, v_now
    );
    IF v_task_result->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'No se pudo recuperar una ocurrencia de la serie'
        USING ERRCODE = '40001';
    END IF;
  END LOOP;

  UPDATE public.daily_repetition_series AS series
  SET current_occurrence_id = (
        SELECT occurrence.id
        FROM public.daily_repetition_occurrences AS occurrence
        WHERE occurrence.series_id = series.id AND occurrence.state = 'current'
          AND EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = occurrence.task_id)
        ORDER BY occurrence.occurrence_on DESC, occurrence.id DESC
        LIMIT 1
      ),
      updated_at = v_now
  WHERE series.id = p_series_id
  RETURNING series.* INTO v_series;

  IF v_series.state = 'active' AND v_series.next_due_on IS NOT NULL THEN
    INSERT INTO public.daily_repetition_jobs(
      job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
    ) VALUES (
      'advance', v_series.id, v_series.revision, v_series.next_due_on,
      pg_catalog.format('advance:%s:%s:%s', v_series.id, v_series.revision, v_series.next_due_on),
      (v_series.next_due_on - v_series.advance_days)::timestamp AT TIME ZONE v_board.time_zone
    ) ON CONFLICT (dedupe_key) DO NOTHING;
  END IF;

  UPDATE public.daily_repetition_series_deletions AS deletion
  SET state = 'restored', series_snapshot = NULL, occurrences_snapshot = NULL,
      restored_at = v_now
  WHERE deletion.series_id = p_series_id;
  v_payload_hash := extensions.digest(pg_catalog.convert_to(
    pg_catalog.jsonb_build_object(
      'action', 'restore', 'board_id', v_board.id,
      'series_id', p_series_id,
      'appearance_column_id', p_target_appearance_column_id
    )::text, 'UTF8'
  ), 'sha256');
  v_result := pg_catalog.jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'series_id', v_series.id, 'state', v_series.state,
    'series_revision', v_series.revision,
    'next_due_on', v_series.next_due_on,
    'appearance_column_id', v_series.appearance_column_id
  );
  INSERT INTO public.daily_repetition_receipts(
    actor_id, operation_id, action, board_id, task_id, series_id,
    payload_hash, result
  ) VALUES (
    v_actor_id, p_operation_id, 'restore', v_board.id,
    v_series.first_task_id, v_series.id, v_payload_hash, v_result
  );
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.restore_repetition_series_internal_p(
  uuid, text, uuid, uuid, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.restore_repetition_series_p(
  p_operation_id uuid,
  p_slug text,
  p_series_id uuid,
  p_target_appearance_column_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.restore_repetition_series_internal_p(
    p_operation_id, p_slug, p_series_id, p_target_appearance_column_id, NULL
  );
$$;
REVOKE ALL ON FUNCTION public.restore_repetition_series_p(uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restore_repetition_series_p(uuid, text, uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.purge_expired_repetition_series_internal_p(
  p_limit integer,
  p_now timestamptz
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_deleted public.daily_repetition_series_deletions%ROWTYPE;
  v_purged integer := 0;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000
    OR p_now IS NULL OR NOT pg_catalog.isfinite(p_now) THEN
    RAISE EXCEPTION 'Elige un lote y un instante de purga válidos'
      USING ERRCODE = '22023';
  END IF;
  FOR v_deleted IN
    SELECT deletion.*
    FROM public.daily_repetition_series_deletions AS deletion
    WHERE deletion.state = 'deleted' AND deletion.expires_at <= p_now
    ORDER BY deletion.expires_at, deletion.series_id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.task_deletions AS child
    SET task_snapshot = NULL, state = 'purged', purged_at = p_now
    WHERE child.parent_series_id = v_deleted.series_id
      AND child.cause = 'series_requested'
      AND child.state = 'deleted' AND child.expires_at <= p_now;
    UPDATE public.daily_repetition_series_deletions AS deletion
    SET series_snapshot = NULL, occurrences_snapshot = NULL,
        state = 'purged', purged_at = p_now
    WHERE deletion.series_id = v_deleted.series_id AND deletion.state = 'deleted';
    v_purged := v_purged + 1;
  END LOOP;
  RETURN v_purged;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_expired_repetition_series_internal_p(integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

-- Purging an individual occurrence follows the same board -> series ->
-- deletion-ledger order as series deletion. The trigger below can update both
-- occurrence and series rows after the ledger changes state, so those parent
-- rows must already be locked in deterministic order.
ALTER FUNCTION public.purge_expired_task_internal_p(uuid, timestamptz)
  RENAME TO purge_expired_task_base_internal_p;
REVOKE ALL ON FUNCTION public.purge_expired_task_base_internal_p(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.purge_expired_task_internal_p(
  p_id uuid,
  p_now timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_parent_series_id uuid;
  v_series_id uuid;
  v_deletion public.task_deletions%ROWTYPE;
  v_now timestamptz := coalesce(p_now, pg_catalog.clock_timestamp());
BEGIN
  SELECT deletion.board_id, deletion.parent_series_id
  INTO v_board_id, v_parent_series_id
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id;
  IF NOT FOUND THEN RETURN 'already_terminal'; END IF;

  PERFORM 1 FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;

  SELECT deletion.parent_series_id INTO v_parent_series_id
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id;
  FOR v_series_id IN
    SELECT series.id
    FROM public.daily_repetition_series AS series
    WHERE series.board_id = v_board_id
      AND (
        series.id = v_parent_series_id
        OR EXISTS (
          SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
          WHERE occurrence.series_id = series.id
            AND occurrence.task_id = p_id
            AND occurrence.state = 'excluded'
        )
      )
    ORDER BY series.id
    FOR UPDATE
  LOOP
    NULL;
  END LOOP;

  SELECT deletion.* INTO v_deletion
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id
  FOR UPDATE;
  IF NOT FOUND OR v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.task_snapshot IS NULL THEN
    RETURN 'already_terminal';
  END IF;
  IF v_now < v_deletion.expires_at THEN RETURN 'too_early'; END IF;
  UPDATE public.task_deletions AS deletion
  SET task_snapshot = NULL,
      state = 'purged',
      purged_at = v_now
  WHERE deletion.task_id = p_id;
  RETURN 'purged';
END;
$$;
REVOKE ALL ON FUNCTION public.purge_expired_task_internal_p(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

ALTER FUNCTION public.purge_daily_repetition_tasks_internal_p(integer, timestamptz)
  RENAME TO purge_daily_repetition_tasks_base_internal_p;
REVOKE ALL ON FUNCTION public.purge_daily_repetition_tasks_base_internal_p(integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.purge_daily_repetition_tasks_internal_p(
  p_limit integer,
  p_now timestamptz
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_task_id uuid;
  v_purged_tasks integer;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000
    OR p_now IS NULL OR NOT pg_catalog.isfinite(p_now) THEN
    RAISE EXCEPTION 'Elige un lote y un instante de purga válidos'
      USING ERRCODE = '22023';
  END IF;

  v_purged_tasks := 0;
  FOR v_task_id IN
    SELECT deletion.task_id
    FROM public.task_deletions AS deletion
    WHERE deletion.state = 'deleted' AND deletion.expires_at <= p_now
    ORDER BY deletion.expires_at, deletion.task_id
    LIMIT p_limit
  LOOP
    IF public.purge_expired_task_internal_p(v_task_id, p_now) = 'purged' THEN
      v_purged_tasks := v_purged_tasks + 1;
    END IF;
  END LOOP;

  PERFORM public.purge_expired_repetition_series_internal_p(p_limit, p_now);
  RETURN v_purged_tasks;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_daily_repetition_tasks_internal_p(integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;

-- Column deletion uses the same selected destination for live tasks and future
-- appearances. Existing task cards stay governed by the task transfer command.
ALTER FUNCTION public.preview_delete_column_p(text, uuid)
  RENAME TO preview_delete_column_base_internal_p;
REVOKE ALL ON FUNCTION public.preview_delete_column_base_internal_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.preview_delete_column_p(p_slug text, p_column_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_result jsonb;
  v_board_id uuid;
  v_series_count integer;
  v_series_token text;
BEGIN
  v_result := public.preview_delete_column_base_internal_p(p_slug, p_column_id);
  IF v_result->>'status' IS DISTINCT FROM 'preview' THEN RETURN v_result; END IF;
  SELECT column_row.board_id INTO v_board_id
  FROM public.columns AS column_row WHERE column_row.id = p_column_id;
  SELECT count(*)::integer INTO v_series_count
  FROM public.daily_repetition_series AS series
  JOIN public.boards AS board ON board.id = series.board_id
  WHERE series.board_id = v_board_id
    AND series.generation_id = board.active_generation_id
    AND series.appearance_column_id = p_column_id
    AND series.state = 'active';
  SELECT encode(extensions.digest(convert_to(coalesce(string_agg(
    series.id::text || ':' || series.revision::text || ':'
      || coalesce(series.next_due_on::text, ''), ',' ORDER BY series.id
  ), ''), 'UTF8'), 'sha256'), 'hex') INTO v_series_token
  FROM public.daily_repetition_series AS series
  JOIN public.boards AS board ON board.id = series.board_id
  WHERE series.board_id = v_board_id
    AND series.generation_id = board.active_generation_id
    AND series.appearance_column_id = p_column_id
    AND series.state = 'active';
  RETURN v_result || pg_catalog.jsonb_build_object(
    'series_count', v_series_count,
    'series_token', v_series_token
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_delete_column_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_delete_column_p(text, uuid)
  TO authenticated;

ALTER FUNCTION public.delete_column_internal_p(uuid, text, uuid, uuid, bigint, timestamptz)
  RENAME TO delete_column_base_internal_p;
REVOKE ALL ON FUNCTION public.delete_column_base_internal_p(
  uuid, text, uuid, uuid, bigint, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.delete_column_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_column_id uuid,
  p_destination_column_id uuid,
  p_expected_task_order_version bigint,
  p_expected_series_token text,
  p_deleted_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_series_count integer;
  v_series_token text;
  v_result jsonb;
  v_series public.daily_repetition_series%ROWTYPE;
  v_now timestamptz := coalesce(p_deleted_at, pg_catalog.clock_timestamp());
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND (
      EXISTS (
        SELECT 1 FROM public.columns AS column_row
        WHERE column_row.board_id = board.id AND column_row.id = p_column_id
      )
      OR EXISTS (
        SELECT 1 FROM public.column_deletions AS deletion
        WHERE deletion.board_id = board.id AND deletion.column_id = p_column_id
      )
    )
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board WHERE board.id = v_board.id FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT count(*)::integer INTO v_series_count
  FROM public.daily_repetition_series AS series
  WHERE series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id
    AND series.appearance_column_id = p_column_id
    AND series.state = 'active';
  SELECT encode(extensions.digest(convert_to(coalesce(string_agg(
    series.id::text || ':' || series.revision::text || ':'
      || coalesce(series.next_due_on::text, ''), ',' ORDER BY series.id
  ), ''), 'UTF8'), 'sha256'), 'hex') INTO v_series_token
  FROM public.daily_repetition_series AS series
  WHERE series.board_id = v_board.id
    AND series.generation_id = v_board.active_generation_id
    AND series.appearance_column_id = p_column_id
    AND series.state = 'active';
  IF v_series_count > 0 AND p_destination_column_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'needs_destination', 'operation_id', p_operation_id);
  END IF;
  IF v_series_count > 0 AND p_expected_series_token IS DISTINCT FROM v_series_token THEN
    RETURN pg_catalog.jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;
  IF v_series_count > 0 AND NOT EXISTS (
    SELECT 1 FROM public.columns AS column_row
    WHERE column_row.id = p_destination_column_id
      AND column_row.board_id = v_board.id
      AND column_row.generation_id = v_board.active_generation_id
      AND column_row.id <> p_column_id
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_result := public.delete_column_base_internal_p(
    p_operation_id, p_slug, p_column_id, p_destination_column_id,
    p_expected_task_order_version, p_deleted_at
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' OR v_series_count = 0 THEN
    RETURN v_result;
  END IF;

  FOR v_series IN
    SELECT series.*
    FROM public.daily_repetition_series AS series
    WHERE series.board_id = v_board.id
      AND series.generation_id = v_board.active_generation_id
      AND series.appearance_column_id = p_column_id
      AND series.state = 'active'
    ORDER BY series.id
    FOR UPDATE
  LOOP
    UPDATE public.daily_repetition_jobs AS job
    SET state = 'superseded', lease_token = NULL, lease_expires_at = NULL,
        completed_at = v_now, updated_at = v_now
    WHERE job.series_id = v_series.id AND job.job_kind = 'advance'
      AND job.state IN ('queued', 'retry_wait', 'leased');
    UPDATE public.daily_repetition_series AS series
    SET appearance_column_id = p_destination_column_id,
        revision = series.revision + 1,
        updated_at = v_now
    WHERE series.id = v_series.id
    RETURNING series.* INTO v_series;
    IF v_series.state = 'active' AND v_series.next_due_on IS NOT NULL THEN
      INSERT INTO public.daily_repetition_jobs(
        job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
      ) VALUES (
        'advance', v_series.id, v_series.revision, v_series.next_due_on,
        pg_catalog.format('advance:%s:%s:%s', v_series.id, v_series.revision, v_series.next_due_on),
        (v_series.next_due_on - v_series.advance_days)::timestamp AT TIME ZONE v_board.time_zone
      ) ON CONFLICT (dedupe_key) DO NOTHING;
    END IF;
  END LOOP;
  RETURN v_result || pg_catalog.jsonb_build_object('moved_series_count', v_series_count);
END;
$$;
REVOKE ALL ON FUNCTION public.delete_column_internal_p(
  uuid, text, uuid, uuid, bigint, text, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.delete_column_p(
  p_operation_id uuid,
  p_slug text,
  p_column_id uuid,
  p_destination_column_id uuid,
  p_expected_task_order_version bigint
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.delete_column_internal_p(
    p_operation_id, p_slug, p_column_id, p_destination_column_id,
    p_expected_task_order_version, NULL, NULL
  );
$$;
REVOKE ALL ON FUNCTION public.delete_column_p(uuid, text, uuid, uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_column_p(uuid, text, uuid, uuid, bigint)
  TO authenticated;
CREATE FUNCTION public.delete_column_p(
  p_operation_id uuid,
  p_slug text,
  p_column_id uuid,
  p_destination_column_id uuid,
  p_expected_task_order_version bigint,
  p_expected_series_token text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.delete_column_internal_p(
    p_operation_id, p_slug, p_column_id, p_destination_column_id,
    p_expected_task_order_version, p_expected_series_token, NULL
  );
$$;
REVOKE ALL ON FUNCTION public.delete_column_p(uuid, text, uuid, uuid, bigint, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_column_p(uuid, text, uuid, uuid, bigint, text)
  TO authenticated;

COMMIT;
