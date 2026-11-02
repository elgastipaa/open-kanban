BEGIN;

-- Admin attachment recovery is authorized against the live board and task,
-- not only the attachment ledger. Follow account-access -> board -> task ->
-- attachment lock order, matching board recovery and task deletion paths.
CREATE OR REPLACE FUNCTION public.admin_restore_task_attachment_p(
  p_actor_id uuid,
  p_attachment_id uuid,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_attachment public.task_attachments%ROWTYPE;
  v_scope record;
  v_board public.boards%ROWTYPE;
  v_owner_id uuid;
  v_task_id uuid;
  v_operation public.task_attachment_operations%ROWTYPE;
  v_payload_hash bytea;
BEGIN
  IF p_actor_id IS NULL OR p_attachment_id IS NULL OR p_operation_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = p_actor_id
        AND access.state = 'active' AND access.is_admin
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT attachment.board_id, attachment.task_id
  INTO v_scope
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.owner_id INTO v_owner_id
  FROM public.boards AS board
  WHERE board.id = v_scope.board_id;
  IF NOT FOUND OR v_owner_id IS NULL THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM public.lock_application_access_rows_p(
    ARRAY[p_actor_id, v_owner_id]::uuid[], NULL
  );
  IF NOT public.is_enabled_application_identity_p(p_actor_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = p_actor_id
        AND access.state = 'active' AND access.is_admin
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_scope.board_id
  FOR UPDATE;
  IF NOT FOUND OR v_board.owner_id IS DISTINCT FROM v_owner_id
    OR v_board.active_generation_id IS NULL
    OR EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = v_board.id
    )
    OR NOT public.is_enabled_application_identity_p(v_owner_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = v_board.id
        AND membership.user_id = v_owner_id
        AND membership.role = 'owner'
        AND membership.revoked_at IS NULL
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM 1
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT task.id INTO v_task_id
  FROM public.tasks AS task
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  WHERE task.id = v_scope.task_id
  FOR UPDATE OF task;
  IF NOT FOUND OR EXISTS (
    SELECT 1 FROM public.task_deletions AS deletion
    WHERE deletion.task_id = v_scope.task_id
      AND deletion.state IN ('deleted', 'purged')
  ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
    AND attachment.board_id = v_board.id
    AND attachment.task_id = v_task_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_payload_hash := extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'action', 'restore_admin_cleanup', 'attachment_id', p_attachment_id
  )::text, 'UTF8'), 'sha256');
  INSERT INTO public.task_attachment_operations(
    actor_id, operation_id, action, payload_hash, attachment_id, result_status
  ) VALUES (
    p_actor_id, p_operation_id, 'restore', v_payload_hash, p_attachment_id, 'processing'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING;
  SELECT operation.* INTO v_operation
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF v_operation.action IS DISTINCT FROM 'restore'
    OR v_operation.payload_hash IS DISTINCT FROM v_payload_hash
    OR v_operation.attachment_id IS DISTINCT FROM p_attachment_id THEN
    RAISE EXCEPTION 'This attachment operation id was already used with different details'
      USING ERRCODE = '23514';
  END IF;
  IF v_operation.result_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
  END IF;
  IF v_operation.result_status = 'confirmed' THEN
    RETURN jsonb_build_object('status', 'confirmed', 'attachment_id', p_attachment_id);
  END IF;
  IF v_attachment.state <> 'recoverable'
    OR v_attachment.deletion_cause <> 'admin_cleanup'
    OR v_attachment.expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  UPDATE public.task_attachments AS attachment
  SET state = 'active', deleted_at = NULL, deleted_by = NULL,
      deletion_cause = NULL, expires_at = NULL
  WHERE attachment.id = p_attachment_id;
  UPDATE public.task_attachment_operations AS operation
  SET result_status = 'confirmed'
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
  RETURN jsonb_build_object('status', 'confirmed', 'attachment_id', p_attachment_id);
END;
$$;

DROP FUNCTION public.list_admin_task_attachment_cleanup_p(uuid, integer);
CREATE FUNCTION public.list_admin_task_attachment_cleanup_p(
  p_actor_id uuid,
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
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200);
  v_items jsonb;
  v_candidate_count integer;
  v_has_more boolean;
  v_next_cursor jsonb;
BEGIN
  IF p_actor_id IS NULL OR NOT public.is_enabled_application_identity_p(p_actor_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = p_actor_id AND access.state = 'active' AND access.is_admin
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF (p_cursor_created_at IS NULL) <> (p_cursor_attachment_id IS NULL) THEN
    RETURN jsonb_build_object('status', 'invalid_cursor');
  END IF;

  WITH candidates AS MATERIALIZED (
    SELECT attachment.created_at, attachment.id,
      pg_catalog.jsonb_build_object(
        'attachment_id', attachment.id,
        'board_reference', attachment.board_id,
        'task_reference', attachment.task_id,
        'owner_reference', board.owner_id,
        'size_bytes', attachment.size_bytes,
        'created_at', attachment.created_at,
        'state', attachment.state,
        'deletion_cause', attachment.deletion_cause,
        'task_state', CASE
          WHEN task.id IS NULL THEN 'missing'
          WHEN board_deletion.board_id IS NOT NULL THEN 'board_recoverable'
          WHEN task_deletion.state = 'deleted' THEN 'recoverable'
          WHEN task_deletion.state = 'purged' THEN 'purged'
          ELSE 'active'
        END,
        'expires_at', attachment.expires_at
      ) AS item
    FROM public.task_attachments AS attachment
    LEFT JOIN public.boards AS board ON board.id = attachment.board_id
    LEFT JOIN public.tasks AS task ON task.id = attachment.task_id
    LEFT JOIN public.task_deletions AS task_deletion
      ON task_deletion.task_id = attachment.task_id
    LEFT JOIN public.board_recoverable_deletions AS board_deletion
      ON board_deletion.board_id = attachment.board_id
    WHERE attachment.state IN ('active', 'recoverable')
      AND (p_cursor_created_at IS NULL
        OR (attachment.created_at, attachment.id)
          > (p_cursor_created_at, p_cursor_attachment_id))
    ORDER BY attachment.created_at, attachment.id
    LIMIT v_limit + 1
  ), numbered AS (
    SELECT candidate.*,
      pg_catalog.row_number() OVER (ORDER BY candidate.created_at, candidate.id) AS ordinal
    FROM candidates AS candidate
  )
  SELECT COALESCE(
      pg_catalog.jsonb_agg(numbered.item ORDER BY numbered.created_at, numbered.id)
        FILTER (WHERE numbered.ordinal <= v_limit),
      '[]'::jsonb
    ),
    count(*)::integer
  INTO v_items, v_candidate_count
  FROM numbered;

  v_has_more := v_candidate_count > v_limit;
  IF v_has_more THEN
    v_next_cursor := pg_catalog.jsonb_build_object(
      'created_at', v_items->(v_limit - 1)->>'created_at',
      'attachment_id', v_items->(v_limit - 1)->>'attachment_id'
    );
  END IF;
  RETURN pg_catalog.jsonb_build_object(
    'status', 'ok',
    'items', v_items,
    'has_more', v_has_more,
    'next_cursor', v_next_cursor
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_admin_task_attachment_cleanup_p(
  uuid, integer, timestamptz, uuid
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_admin_task_attachment_cleanup_p(
  uuid, integer, timestamptz, uuid
) TO service_role;

ALTER TABLE public.task_attachments
  DROP CONSTRAINT task_attachments_deletion_cause_check,
  ADD CONSTRAINT task_attachments_deletion_cause_check CHECK (
    deletion_cause IN ('author', 'moderation', 'admin_cleanup', 'parent_delete')
  );

CREATE FUNCTION public.sync_task_attachment_task_deletion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.state = 'deleted' AND (
    TG_OP = 'INSERT'
    OR OLD.state IS DISTINCT FROM 'deleted'
    OR OLD.deleted_at IS DISTINCT FROM NEW.deleted_at
    OR OLD.expires_at IS DISTINCT FROM NEW.expires_at
  ) THEN
    UPDATE public.task_attachments AS attachment
    SET state = 'recoverable',
        deleted_at = NEW.deleted_at,
        deleted_by = NEW.deleted_by,
        deletion_cause = 'parent_delete',
        expires_at = NEW.expires_at
    WHERE attachment.board_id = NEW.board_id
      AND attachment.task_id = NEW.task_id
      AND attachment.state = 'active';
  ELSIF TG_OP = 'UPDATE' AND OLD.state = 'deleted'
    AND NEW.state = 'restored' AND NEW.restored_at IS NOT NULL THEN
    UPDATE public.task_attachments AS attachment
    SET state = 'active',
        deleted_at = NULL,
        deleted_by = NULL,
        deletion_cause = NULL,
        expires_at = NULL
    WHERE attachment.board_id = NEW.board_id
      AND attachment.task_id = NEW.task_id
      AND attachment.state = 'recoverable'
      AND attachment.deletion_cause = 'parent_delete'
      AND attachment.expires_at > NEW.restored_at;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.sync_task_attachment_task_deletion()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER task_deletions_sync_task_attachments_insert
AFTER INSERT ON public.task_deletions
FOR EACH ROW EXECUTE FUNCTION public.sync_task_attachment_task_deletion();
CREATE TRIGGER task_deletions_sync_task_attachments_update
AFTER UPDATE OF state, deleted_at, expires_at ON public.task_deletions
FOR EACH ROW EXECUTE FUNCTION public.sync_task_attachment_task_deletion();

-- Task deletion locks board and task before cascading to attachments. Keep
-- every member operation on the same board -> task -> attachment order.
CREATE OR REPLACE FUNCTION public.publish_task_attachment_p(
  p_actor_id uuid,
  p_slug text,
  p_task_id uuid,
  p_attachment_id uuid,
  p_operation_id uuid,
  p_verified_size_bytes integer,
  p_verified_sha256 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_attachment public.task_attachments%ROWTYPE;
  v_context record;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR p_attachment_id IS NULL OR p_operation_id IS NULL
    OR p_verified_size_bytes IS NULL OR p_verified_sha256 IS NULL THEN
    RETURN jsonb_build_object('status', 'rejected');
  END IF;
  IF NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
  FOR UPDATE;
  IF NOT FOUND OR v_attachment.uploaded_by <> p_actor_id
    OR v_attachment.task_id <> p_task_id
    OR v_context.board_id <> v_attachment.board_id THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_attachment.upload_operation_id <> p_operation_id
    OR v_attachment.size_bytes <> p_verified_size_bytes
    OR v_attachment.sha256 <> pg_catalog.decode(p_verified_sha256, 'hex') THEN
    RETURN jsonb_build_object('status', 'object_mismatch');
  END IF;
  IF v_attachment.state = 'active' THEN
    RETURN jsonb_build_object('status', 'confirmed', 'attachment_id', v_attachment.id);
  END IF;
  IF v_attachment.state <> 'reserved'
    OR v_attachment.reservation_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
  END IF;

  PERFORM 1
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id
    AND operation.operation_id = p_operation_id
    AND operation.action = 'upload'
    AND operation.attachment_id = p_attachment_id
    AND operation.result_status = 'reserved'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  UPDATE public.task_attachments AS attachment
  SET state = 'active', reservation_expires_at = NULL
  WHERE attachment.id = p_attachment_id;
  UPDATE public.task_attachment_operations AS operation
  SET result_status = 'confirmed'
  WHERE operation.actor_id = p_actor_id
    AND operation.operation_id = p_operation_id;
  RETURN jsonb_build_object('status', 'confirmed', 'attachment_id', p_attachment_id);
END;
$$;
REVOKE ALL ON FUNCTION public.publish_task_attachment_p(
  uuid, text, uuid, uuid, uuid, integer, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_task_attachment_p(
  uuid, text, uuid, uuid, uuid, integer, text
) TO service_role;

CREATE OR REPLACE FUNCTION public.delete_task_attachment_p(
  p_actor_id uuid,
  p_slug text,
  p_task_id uuid,
  p_attachment_id uuid,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_attachment public.task_attachments%ROWTYPE;
  v_operation public.task_attachment_operations%ROWTYPE;
  v_context record;
  v_payload_hash bytea;
  v_deleted_at timestamptz;
  v_cause text;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR p_attachment_id IS NULL OR p_operation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'rejected');
  END IF;
  IF NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id AND attachment.task_id = p_task_id
  FOR UPDATE;
  IF NOT FOUND OR v_context.board_id <> v_attachment.board_id
    OR (v_attachment.uploaded_by <> p_actor_id AND v_context.owner_id <> p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_payload_hash := extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'action', 'delete', 'attachment_id', p_attachment_id
  )::text, 'UTF8'), 'sha256');
  INSERT INTO public.task_attachment_operations(
    actor_id, operation_id, action, payload_hash, attachment_id, result_status
  ) VALUES (
    p_actor_id, p_operation_id, 'delete', v_payload_hash, p_attachment_id, 'processing'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING;
  SELECT operation.* INTO v_operation
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF v_operation.action IS DISTINCT FROM 'delete'
    OR v_operation.payload_hash IS DISTINCT FROM v_payload_hash
    OR v_operation.attachment_id IS DISTINCT FROM p_attachment_id THEN
    RAISE EXCEPTION 'This attachment operation id was already used with different details'
      USING ERRCODE = '23514';
  END IF;
  IF v_operation.result_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
  END IF;
  IF v_operation.result_status = 'confirmed' THEN
    RETURN jsonb_build_object('status', 'confirmed', 'attachment_id', p_attachment_id);
  END IF;
  IF v_attachment.state <> 'active' THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_deleted_at := pg_catalog.clock_timestamp();
  v_cause := CASE WHEN v_attachment.uploaded_by = p_actor_id THEN 'author' ELSE 'moderation' END;
  UPDATE public.task_attachments AS attachment
  SET state = 'recoverable',
      deleted_at = v_deleted_at,
      deleted_by = p_actor_id,
      deletion_cause = v_cause,
      expires_at = v_deleted_at + interval '168 hours'
  WHERE attachment.id = p_attachment_id;
  UPDATE public.task_attachment_operations AS operation
  SET result_status = 'confirmed'
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'attachment_id', p_attachment_id,
    'deleted_at', v_deleted_at,
    'expires_at', v_deleted_at + interval '168 hours',
    'cause', v_cause
  );
END;
$$;
REVOKE ALL ON FUNCTION public.delete_task_attachment_p(uuid, text, uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_task_attachment_p(uuid, text, uuid, uuid, uuid)
  TO service_role;

CREATE OR REPLACE FUNCTION public.restore_task_attachment_p(
  p_actor_id uuid,
  p_slug text,
  p_task_id uuid,
  p_attachment_id uuid,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_attachment public.task_attachments%ROWTYPE;
  v_operation public.task_attachment_operations%ROWTYPE;
  v_context record;
  v_payload_hash bytea;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR p_attachment_id IS NULL OR p_operation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'rejected');
  END IF;
  IF NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id AND attachment.task_id = p_task_id
  FOR UPDATE;
  IF NOT FOUND OR v_context.board_id <> v_attachment.board_id
    OR (v_context.owner_id <> p_actor_id AND v_attachment.uploaded_by <> p_actor_id)
    OR (v_attachment.deletion_cause = 'moderation' AND v_context.owner_id <> p_actor_id)
    OR v_attachment.deletion_cause IN ('admin_cleanup', 'parent_delete') THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_payload_hash := extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'action', 'restore', 'attachment_id', p_attachment_id
  )::text, 'UTF8'), 'sha256');
  INSERT INTO public.task_attachment_operations(
    actor_id, operation_id, action, payload_hash, attachment_id, result_status
  ) VALUES (
    p_actor_id, p_operation_id, 'restore', v_payload_hash, p_attachment_id, 'processing'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING;
  SELECT operation.* INTO v_operation
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF v_operation.action IS DISTINCT FROM 'restore'
    OR v_operation.payload_hash IS DISTINCT FROM v_payload_hash
    OR v_operation.attachment_id IS DISTINCT FROM p_attachment_id THEN
    RAISE EXCEPTION 'This attachment operation id was already used with different details'
      USING ERRCODE = '23514';
  END IF;
  IF v_operation.result_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
  END IF;
  IF v_operation.result_status = 'confirmed' THEN
    RETURN jsonb_build_object('status', 'confirmed', 'attachment_id', p_attachment_id);
  END IF;
  IF v_attachment.state <> 'recoverable'
    OR v_attachment.expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  UPDATE public.task_attachments AS attachment
  SET state = 'active', deleted_at = NULL, deleted_by = NULL,
      deletion_cause = NULL, expires_at = NULL
  WHERE attachment.id = p_attachment_id;
  UPDATE public.task_attachment_operations AS operation
  SET result_status = 'confirmed'
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
  RETURN jsonb_build_object('status', 'confirmed', 'attachment_id', p_attachment_id);
END;
$$;
REVOKE ALL ON FUNCTION public.restore_task_attachment_p(uuid, text, uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.restore_task_attachment_p(uuid, text, uuid, uuid, uuid)
  TO service_role;

COMMIT;
