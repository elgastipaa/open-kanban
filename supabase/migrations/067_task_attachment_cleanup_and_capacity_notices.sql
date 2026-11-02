BEGIN;

CREATE TABLE public.task_attachment_capacity_notice_states (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  threshold_bytes bigint NOT NULL CHECK (threshold_bytes IN (160000000, 200000000)),
  last_notified_at timestamptz,
  read_at timestamptz,
  armed boolean NOT NULL DEFAULT true,
  PRIMARY KEY (user_id, threshold_bytes),
  CHECK (read_at IS NULL OR (last_notified_at IS NOT NULL AND read_at >= last_notified_at))
);
ALTER TABLE public.task_attachment_capacity_notice_states ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_attachment_capacity_notice_states
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.record_task_attachment_capacity_transition_p(
  p_previous_bytes bigint,
  p_current_bytes bigint,
  p_now timestamptz DEFAULT pg_catalog.clock_timestamp()
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_threshold bigint;
BEGIN
  IF p_previous_bytes IS NULL OR p_current_bytes IS NULL OR p_now IS NULL
    OR p_previous_bytes < 0 OR p_current_bytes < 0 THEN
    RETURN;
  END IF;

  FOREACH v_threshold IN ARRAY ARRAY[160000000::bigint, 200000000::bigint] LOOP
    IF p_previous_bytes >= v_threshold AND p_current_bytes < v_threshold THEN
      UPDATE public.task_attachment_capacity_notice_states AS state
      SET armed = true
      WHERE state.threshold_bytes = v_threshold;
    ELSIF p_previous_bytes < v_threshold AND p_current_bytes >= v_threshold THEN
      INSERT INTO public.task_attachment_capacity_notice_states(
        user_id, threshold_bytes, last_notified_at, read_at, armed
      )
      SELECT recipient.user_id,
        v_threshold,
        CASE
          WHEN state.user_id IS NULL
            OR (state.armed AND (
              state.last_notified_at IS NULL
              OR state.last_notified_at <= p_now - interval '24 hours'
            )) THEN p_now
          ELSE state.last_notified_at
        END,
        CASE
          WHEN state.user_id IS NULL
            OR (state.armed AND (
              state.last_notified_at IS NULL
              OR state.last_notified_at <= p_now - interval '24 hours'
            )) THEN NULL
          ELSE state.read_at
        END,
        false
      FROM (
        SELECT access.auth_user_id AS user_id
        FROM public.application_access AS access
        WHERE access.state = 'active'
          AND access.is_admin
          AND public.is_enabled_application_identity_p(access.auth_user_id)
        UNION
        SELECT board.owner_id AS user_id
        FROM public.boards AS board
        JOIN public.board_memberships AS membership
          ON membership.board_id = board.id
          AND membership.user_id = board.owner_id
          AND membership.role = 'owner'
          AND membership.revoked_at IS NULL
        WHERE public.is_enabled_application_identity_p(board.owner_id)
          AND EXISTS (
            SELECT 1
            FROM public.task_attachments AS attachment
            WHERE attachment.board_id = board.id
              AND attachment.state <> 'purged'
          )
      ) AS recipient
      LEFT JOIN public.task_attachment_capacity_notice_states AS state
        ON state.user_id = recipient.user_id
        AND state.threshold_bytes = v_threshold
      ON CONFLICT (user_id, threshold_bytes) DO UPDATE
      SET last_notified_at = CASE
            WHEN public.task_attachment_capacity_notice_states.armed
              AND (
                public.task_attachment_capacity_notice_states.last_notified_at IS NULL
                OR public.task_attachment_capacity_notice_states.last_notified_at
                  <= p_now - interval '24 hours'
              ) THEN p_now
            ELSE public.task_attachment_capacity_notice_states.last_notified_at
          END,
          read_at = CASE
            WHEN public.task_attachment_capacity_notice_states.armed
              AND (
                public.task_attachment_capacity_notice_states.last_notified_at IS NULL
                OR public.task_attachment_capacity_notice_states.last_notified_at
                  <= p_now - interval '24 hours'
              ) THEN NULL
            ELSE public.task_attachment_capacity_notice_states.read_at
          END,
          armed = false;
    END IF;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.record_task_attachment_capacity_transition_p(
  bigint, bigint, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.update_task_attachment_quota_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_old_active bigint := 0;
  v_old_recoverable bigint := 0;
  v_old_reserved bigint := 0;
  v_old_pending bigint := 0;
  v_new_active bigint := 0;
  v_new_recoverable bigint := 0;
  v_new_reserved bigint := 0;
  v_new_pending bigint := 0;
  v_previous_bytes bigint;
  v_current_bytes bigint;
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    v_old_active := CASE WHEN OLD.state = 'active' THEN OLD.size_bytes ELSE 0 END;
    v_old_recoverable := CASE WHEN OLD.state IN ('recoverable', 'restoring') THEN OLD.size_bytes ELSE 0 END;
    v_old_reserved := CASE WHEN OLD.state = 'reserved' THEN OLD.size_bytes ELSE 0 END;
    v_old_pending := CASE WHEN OLD.state IN ('purging', 'cleanup_pending', 'missing') THEN OLD.size_bytes ELSE 0 END;
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    v_new_active := CASE WHEN NEW.state = 'active' THEN NEW.size_bytes ELSE 0 END;
    v_new_recoverable := CASE WHEN NEW.state IN ('recoverable', 'restoring') THEN NEW.size_bytes ELSE 0 END;
    v_new_reserved := CASE WHEN NEW.state = 'reserved' THEN NEW.size_bytes ELSE 0 END;
    v_new_pending := CASE WHEN NEW.state IN ('purging', 'cleanup_pending', 'missing') THEN NEW.size_bytes ELSE 0 END;
  END IF;

  SELECT ledger.active_bytes + ledger.recoverable_bytes
      + ledger.reserved_bytes + ledger.pending_bytes
  INTO v_previous_bytes
  FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton
  FOR UPDATE;

  UPDATE public.task_attachment_quota_ledger AS ledger
  SET active_bytes = ledger.active_bytes - v_old_active + v_new_active,
      recoverable_bytes = ledger.recoverable_bytes - v_old_recoverable + v_new_recoverable,
      reserved_bytes = ledger.reserved_bytes - v_old_reserved + v_new_reserved,
      pending_bytes = ledger.pending_bytes - v_old_pending + v_new_pending,
      updated_at = pg_catalog.clock_timestamp()
  WHERE ledger.singleton
  RETURNING ledger.active_bytes + ledger.recoverable_bytes
      + ledger.reserved_bytes + ledger.pending_bytes
  INTO v_current_bytes;

  PERFORM public.record_task_attachment_capacity_transition_p(
    v_previous_bytes, v_current_bytes, pg_catalog.clock_timestamp()
  );

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.list_board_task_attachment_storage_p(
  p_actor_id uuid,
  p_slug text,
  p_limit integer DEFAULT 100,
  p_cursor_created_at timestamptz DEFAULT NULL,
  p_cursor_attachment_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_page_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 100);
  v_items jsonb;
  v_has_more boolean;
  v_next_cursor jsonb;
  v_board_active_bytes bigint;
  v_board_recoverable_bytes bigint;
  v_board_reserved_bytes bigint;
  v_board_pending_bytes bigint;
  v_board_active_count bigint;
  v_board_recoverable_count bigint;
  v_global public.task_attachment_quota_ledger%ROWTYPE;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL
    OR ((p_cursor_created_at IS NULL) <> (p_cursor_attachment_id IS NULL))
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = p_actor_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug
    AND board.owner_id = p_actor_id
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR SHARE OF board, membership;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT
    COALESCE(sum(attachment.size_bytes) FILTER (WHERE attachment.state = 'active'), 0),
    COALESCE(sum(attachment.size_bytes) FILTER (WHERE attachment.state IN ('recoverable', 'restoring')), 0),
    COALESCE(sum(attachment.size_bytes) FILTER (WHERE attachment.state = 'reserved'), 0),
    COALESCE(sum(attachment.size_bytes) FILTER (WHERE attachment.state IN ('purging', 'cleanup_pending', 'missing')), 0),
    count(*) FILTER (WHERE attachment.state = 'active'),
    count(*) FILTER (WHERE attachment.state IN ('recoverable', 'restoring'))
  INTO v_board_active_bytes, v_board_recoverable_bytes,
    v_board_reserved_bytes, v_board_pending_bytes,
    v_board_active_count, v_board_recoverable_count
  FROM public.task_attachments AS attachment
  WHERE attachment.board_id = v_board_id
    AND attachment.state <> 'purged';

  SELECT ledger.* INTO v_global
  FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton;

  WITH candidates AS (
    SELECT attachment.id, attachment.task_id, task.title, task.is_completed,
      attachment.file_name, attachment.size_bytes, attachment.state,
      attachment.created_at, attachment.deleted_at, attachment.deletion_cause,
      attachment.expires_at
    FROM public.task_attachments AS attachment
    JOIN public.tasks AS task ON task.id = attachment.task_id
    JOIN public.columns AS column_row
      ON column_row.id = task.column_id
      AND column_row.board_id = v_board_id
      AND column_row.generation_id = (
        SELECT board.active_generation_id FROM public.boards AS board
        WHERE board.id = v_board_id
      )
    WHERE attachment.board_id = v_board_id
      AND attachment.state IN ('active', 'recoverable')
      AND (p_cursor_created_at IS NULL
        OR (attachment.created_at, attachment.id) > (p_cursor_created_at, p_cursor_attachment_id))
    ORDER BY attachment.created_at, attachment.id
    LIMIT v_page_limit + 1
  ),
  numbered AS (
    SELECT candidates.*,
      pg_catalog.row_number() OVER (ORDER BY candidates.created_at, candidates.id) AS ordinal
    FROM candidates
  )
  SELECT
    COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'attachment_id', numbered.id,
      'task_id', numbered.task_id,
      'task_title', numbered.title,
      'task_completed', numbered.is_completed,
      'file_name', numbered.file_name,
      'size_bytes', numbered.size_bytes,
      'state', numbered.state,
      'created_at', numbered.created_at,
      'deleted_at', numbered.deleted_at,
      'deletion_cause', numbered.deletion_cause,
      'expires_at', numbered.expires_at
    ) ORDER BY numbered.ordinal) FILTER (WHERE numbered.ordinal <= v_page_limit), '[]'::jsonb),
    count(*) > v_page_limit
  INTO v_items, v_has_more
  FROM numbered;

  IF v_has_more AND jsonb_array_length(v_items) > 0 THEN
    v_next_cursor := jsonb_build_object(
      'created_at', v_items->(jsonb_array_length(v_items) - 1)->>'created_at',
      'attachment_id', v_items->(jsonb_array_length(v_items) - 1)->>'attachment_id'
    );
  ELSE
    v_next_cursor := NULL;
  END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'board_usage', jsonb_build_object(
      'active_bytes', v_board_active_bytes,
      'recoverable_bytes', v_board_recoverable_bytes,
      'reserved_bytes', v_board_reserved_bytes,
      'pending_bytes', v_board_pending_bytes,
      'active_count', v_board_active_count,
      'recoverable_count', v_board_recoverable_count
    ),
    'global_capacity', jsonb_build_object(
      'limit_bytes', v_global.limit_bytes,
      'used_bytes', v_global.active_bytes + v_global.recoverable_bytes
        + v_global.reserved_bytes + v_global.pending_bytes,
      'warning_threshold_bytes', 160000000
    ),
    'items', v_items,
    'has_more', v_has_more,
    'next_cursor', v_next_cursor
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_board_task_attachment_storage_p(
  uuid, text, integer, timestamptz, uuid
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_board_task_attachment_storage_p(
  uuid, text, integer, timestamptz, uuid
) TO service_role;

CREATE FUNCTION public.preview_completed_task_attachment_cleanup_p(
  p_actor_id uuid,
  p_slug text,
  p_attachment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_context record;
  v_task public.tasks%ROWTYPE;
  v_attachment public.task_attachments%ROWTYPE;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_attachment_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(
    p_actor_id,
    p_slug,
    (SELECT attachment.task_id FROM public.task_attachments AS attachment
      WHERE attachment.id = p_attachment_id)
  ) AS context;
  IF NOT FOUND OR v_context.role <> 'owner' OR v_context.owner_id <> p_actor_id THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_context.board_id
  JOIN public.boards AS board
    ON board.id = column_row.board_id
    AND column_row.generation_id = board.active_generation_id
  WHERE task.id = (SELECT attachment.task_id FROM public.task_attachments AS attachment
    WHERE attachment.id = p_attachment_id)
  FOR SHARE OF task;
  IF NOT FOUND OR NOT v_task.is_completed
    OR EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task.id AND deletion.state IN ('deleted', 'purged')
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
    AND attachment.task_id = v_task.id
    AND attachment.board_id = v_context.board_id
    AND attachment.state = 'active'
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  RETURN jsonb_build_object(
    'status', 'preview',
    'item', jsonb_build_object(
      'attachment_id', v_attachment.id,
      'task_id', v_task.id,
      'task_title', v_task.title,
      'file_name', v_attachment.file_name,
      'size_bytes', v_attachment.size_bytes,
      'created_at', v_attachment.created_at
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.preview_completed_task_attachment_cleanup_p(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_completed_task_attachment_cleanup_p(uuid, text, uuid)
  TO service_role;

CREATE FUNCTION public.cleanup_completed_task_attachment_p(
  p_actor_id uuid,
  p_slug text,
  p_attachment_id uuid,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_context record;
  v_task public.tasks%ROWTYPE;
  v_attachment public.task_attachments%ROWTYPE;
  v_operation public.task_attachment_operations%ROWTYPE;
  v_result jsonb;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_attachment_id IS NULL
    OR p_operation_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(
    p_actor_id,
    p_slug,
    (SELECT attachment.task_id FROM public.task_attachments AS attachment
      WHERE attachment.id = p_attachment_id)
  ) AS context;
  IF NOT FOUND OR v_context.role <> 'owner' OR v_context.owner_id <> p_actor_id THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT operation.* INTO v_operation
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id
    AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    v_result := public.delete_task_attachment_p(
      p_actor_id,
      p_slug,
      (SELECT attachment.task_id FROM public.task_attachments AS attachment
        WHERE attachment.id = p_attachment_id),
      p_attachment_id,
      p_operation_id
    );
    IF v_result->>'status' = 'confirmed' THEN
      RETURN v_result || jsonb_build_object(
        'expires_at', (SELECT attachment.expires_at
          FROM public.task_attachments AS attachment
          WHERE attachment.id = p_attachment_id)
      );
    END IF;
    RETURN v_result;
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_context.board_id
  JOIN public.boards AS board
    ON board.id = column_row.board_id
    AND column_row.generation_id = board.active_generation_id
  WHERE task.id = (SELECT attachment.task_id FROM public.task_attachments AS attachment
    WHERE attachment.id = p_attachment_id)
  FOR UPDATE OF task;

  -- Recheck after acquiring the task lock so concurrent retries see the
  -- receipt committed by an earlier request before inspecting current state.
  SELECT operation.* INTO v_operation
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id
    AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    v_result := public.delete_task_attachment_p(
      p_actor_id,
      p_slug,
      (SELECT attachment.task_id FROM public.task_attachments AS attachment
        WHERE attachment.id = p_attachment_id),
      p_attachment_id,
      p_operation_id
    );
    IF v_result->>'status' = 'confirmed' THEN
      RETURN v_result || jsonb_build_object(
        'expires_at', (SELECT attachment.expires_at
          FROM public.task_attachments AS attachment
          WHERE attachment.id = p_attachment_id)
      );
    END IF;
    RETURN v_result;
  END IF;

  IF v_task.id IS NULL OR NOT v_task.is_completed
    OR EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task.id AND deletion.state IN ('deleted', 'purged')
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
    AND attachment.task_id = v_task.id
    AND attachment.board_id = v_context.board_id
  FOR UPDATE;
  IF NOT FOUND OR v_attachment.state <> 'active' THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_result := public.delete_task_attachment_p(
    p_actor_id, p_slug, v_task.id, p_attachment_id, p_operation_id
  );
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_completed_task_attachment_p(uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_completed_task_attachment_p(uuid, text, uuid, uuid)
  TO service_role;

CREATE FUNCTION public.list_my_task_attachment_capacity_notices_p(p_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF p_actor_id IS NULL OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'threshold_bytes', state.threshold_bytes,
    'last_notified_at', state.last_notified_at
  ) ORDER BY state.threshold_bytes), '[]'::jsonb)
  INTO v_items
  FROM public.task_attachment_capacity_notice_states AS state
  WHERE state.user_id = p_actor_id
    AND state.last_notified_at IS NOT NULL
    AND state.read_at IS NULL;
  RETURN jsonb_build_object('status', 'ok', 'items', v_items);
END;
$$;
REVOKE ALL ON FUNCTION public.list_my_task_attachment_capacity_notices_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_task_attachment_capacity_notices_p(uuid)
  TO service_role;

CREATE FUNCTION public.mark_my_task_attachment_capacity_notice_read_p(
  p_actor_id uuid,
  p_threshold_bytes bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_actor_id IS NULL OR p_threshold_bytes NOT IN (160000000, 200000000)
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  UPDATE public.task_attachment_capacity_notice_states AS state
  SET read_at = pg_catalog.clock_timestamp()
  WHERE state.user_id = p_actor_id
    AND state.threshold_bytes = p_threshold_bytes
    AND state.last_notified_at IS NOT NULL
    AND state.read_at IS NULL;
  RETURN jsonb_build_object('status', 'confirmed');
END;
$$;
REVOKE ALL ON FUNCTION public.mark_my_task_attachment_capacity_notice_read_p(uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_my_task_attachment_capacity_notice_read_p(uuid, bigint)
  TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
