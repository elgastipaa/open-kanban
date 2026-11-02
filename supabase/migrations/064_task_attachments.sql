-- Private text attachments use a quota reservation ledger and server-mediated
-- Storage. Object bytes are not readable through the application database.
BEGIN;

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'task-attachments',
  'task-attachments',
  false,
  24000,
  ARRAY['text/plain']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  name = EXCLUDED.name,
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

ALTER TABLE public.task_notifications
  DROP CONSTRAINT IF EXISTS task_notifications_reason_codes_check;
ALTER TABLE public.task_notifications
  ADD CONSTRAINT task_notifications_reason_codes_check CHECK (
    cardinality(reason_codes) > 0
    AND reason_codes <@ ARRAY[
      'assignment', 'mention', 'comment', 'due_date', 'attachment_cleanup'
    ]::text[]
  );

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS schema_name
      ON schema_name.oid = relation.relnamespace
    WHERE schema_name.nspname = 'storage'
      AND relation.relname = 'objects'
      AND relation.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'Supabase Storage object RLS must remain enabled'
      USING ERRCODE = '55000';
  END IF;
END;
$$;

DROP POLICY IF EXISTS openkanban_task_attachments_server_only ON storage.objects;
CREATE POLICY openkanban_task_attachments_server_only
  ON storage.objects AS RESTRICTIVE
  FOR ALL TO anon, authenticated
  USING (bucket_id <> 'task-attachments')
  WITH CHECK (bucket_id <> 'task-attachments');

CREATE TABLE public.task_attachment_quota_ledger (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  limit_bytes bigint NOT NULL DEFAULT 200000000 CHECK (limit_bytes = 200000000),
  active_bytes bigint NOT NULL DEFAULT 0 CHECK (active_bytes >= 0),
  recoverable_bytes bigint NOT NULL DEFAULT 0 CHECK (recoverable_bytes >= 0),
  reserved_bytes bigint NOT NULL DEFAULT 0 CHECK (reserved_bytes >= 0),
  pending_bytes bigint NOT NULL DEFAULT 0 CHECK (pending_bytes >= 0),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);
INSERT INTO public.task_attachment_quota_ledger(singleton) VALUES (true);

CREATE TABLE public.task_attachment_operations (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  action text NOT NULL CHECK (action IN ('upload', 'delete', 'restore', 'admin_cleanup')),
  payload_hash bytea NOT NULL CHECK (pg_catalog.octet_length(payload_hash) = 32),
  attachment_id uuid,
  result_status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (pg_catalog.clock_timestamp() + interval '168 hours'),
  PRIMARY KEY (actor_id, operation_id)
);
CREATE INDEX task_attachment_operations_expiry_idx
  ON public.task_attachment_operations(result_expires_at);

CREATE TABLE public.task_attachments (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  board_id uuid NOT NULL,
  task_id uuid NOT NULL,
  uploaded_by uuid NOT NULL,
  upload_operation_id uuid NOT NULL,
  file_name text NOT NULL CHECK (
    pg_catalog.length(file_name) BETWEEN 1 AND 120
    AND file_name !~ '[[:cntrl:]]'
    AND position('/' in file_name) = 0
    AND position(pg_catalog.chr(92) in file_name) = 0
    AND pg_catalog.lower(file_name) ~ '\.(txt|md)$'
  ),
  size_bytes integer NOT NULL CHECK (size_bytes BETWEEN 1 AND 24000),
  sha256 bytea NOT NULL CHECK (pg_catalog.octet_length(sha256) = 32),
  object_key text NOT NULL UNIQUE,
  state text NOT NULL CHECK (state IN (
    'reserved', 'active', 'recoverable', 'restoring', 'purging',
    'cleanup_pending', 'missing', 'purged'
  )),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  reservation_expires_at timestamptz,
  deleted_at timestamptz,
  deleted_by uuid,
  deletion_cause text CHECK (deletion_cause IN ('author', 'moderation', 'admin_cleanup')),
  expires_at timestamptz,
  purge_lease_id uuid,
  purge_lease_until timestamptz,
  purge_attempts integer NOT NULL DEFAULT 0 CHECK (purge_attempts >= 0),
  CHECK (
    (state = 'reserved' AND reservation_expires_at IS NOT NULL)
    OR (state <> 'reserved' AND reservation_expires_at IS NULL)
  ),
  CHECK (
    (deleted_at IS NULL AND deleted_by IS NULL AND deletion_cause IS NULL AND expires_at IS NULL)
    OR (deleted_at IS NOT NULL AND deletion_cause IS NOT NULL
      AND expires_at = deleted_at + interval '168 hours')
  ),
  CHECK (
    (purge_lease_id IS NULL AND purge_lease_until IS NULL)
    OR (purge_lease_id IS NOT NULL AND purge_lease_until IS NOT NULL)
  ),
  UNIQUE (uploaded_by, upload_operation_id)
);
CREATE INDEX task_attachments_task_state_idx
  ON public.task_attachments(task_id, state, created_at, id);
CREATE INDEX task_attachments_board_state_idx
  ON public.task_attachments(board_id, state, created_at, id);
CREATE INDEX task_attachments_expiry_idx
  ON public.task_attachments(expires_at, id)
  WHERE state IN ('recoverable', 'cleanup_pending', 'missing');

ALTER TABLE public.task_attachment_quota_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_attachment_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_attachments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_attachment_quota_ledger,
  public.task_attachment_operations, public.task_attachments
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.update_task_attachment_quota_ledger()
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

  UPDATE public.task_attachment_quota_ledger AS ledger
  SET active_bytes = ledger.active_bytes - v_old_active + v_new_active,
      recoverable_bytes = ledger.recoverable_bytes - v_old_recoverable + v_new_recoverable,
      reserved_bytes = ledger.reserved_bytes - v_old_reserved + v_new_reserved,
      pending_bytes = ledger.pending_bytes - v_old_pending + v_new_pending,
      updated_at = pg_catalog.clock_timestamp()
  WHERE ledger.singleton;

  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER task_attachments_quota_ledger
  AFTER INSERT OR UPDATE OF state, size_bytes OR DELETE
  ON public.task_attachments
  FOR EACH ROW EXECUTE FUNCTION public.update_task_attachment_quota_ledger();
REVOKE ALL ON FUNCTION public.update_task_attachment_quota_ledger()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.task_attachment_context_for_actor_p(
  p_actor_id uuid,
  p_slug text,
  p_task_id uuid
)
RETURNS TABLE (board_id uuid, owner_id uuid, role text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT board.id, board.owner_id, membership.role
  FROM public.boards AS board
  JOIN public.columns AS column_row
    ON column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  JOIN public.tasks AS task
    ON task.column_id = column_row.id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = p_actor_id
    AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug
    AND task.id = p_task_id
  FOR SHARE OF board, task, membership;
END;
$$;
REVOKE ALL ON FUNCTION public.task_attachment_context_for_actor_p(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.reserve_task_attachment_p(
  p_actor_id uuid,
  p_operation_id uuid,
  p_slug text,
  p_task_id uuid,
  p_file_name text,
  p_size_bytes integer,
  p_sha256 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_context record;
  v_operation public.task_attachment_operations%ROWTYPE;
  v_attachment public.task_attachments%ROWTYPE;
  v_payload_hash bytea;
  v_attachment_id uuid;
  v_used_bytes bigint;
  v_limit_bytes bigint;
  v_task_count integer;
  v_actor_reservations integer;
  v_instance_reservations integer;
  v_recent_uploads integer;
  v_reserved_until timestamptz;
BEGIN
  IF p_actor_id IS NULL OR p_operation_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL
    OR p_file_name IS NULL OR p_size_bytes IS NULL OR p_sha256 IS NULL THEN
    RETURN jsonb_build_object('status', 'rejected');
  END IF;
  IF p_size_bytes < 1 OR p_size_bytes > 24000
    OR pg_catalog.length(p_file_name) NOT BETWEEN 1 AND 120
    OR p_file_name ~ '[[:cntrl:]]'
    OR position('/' in p_file_name) > 0
    OR position(pg_catalog.chr(92) in p_file_name) > 0
    OR pg_catalog.lower(p_file_name) !~ '\.(txt|md)$'
    OR p_sha256 !~ '^[0-9a-f]{64}$' THEN
    RETURN jsonb_build_object('status', 'rejected');
  END IF;
  IF NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_payload_hash := extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'action', 'upload',
    'slug', p_slug,
    'task_id', p_task_id,
    'file_name', p_file_name,
    'size_bytes', p_size_bytes,
    'sha256', p_sha256
  )::text, 'UTF8'), 'sha256');

  INSERT INTO public.task_attachment_operations(
    actor_id, operation_id, action, payload_hash, result_status
  ) VALUES (
    p_actor_id, p_operation_id, 'upload', v_payload_hash, 'processing'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING;
  SELECT operation.* INTO v_operation
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id
    AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF v_operation.action IS DISTINCT FROM 'upload'
    OR v_operation.payload_hash IS DISTINCT FROM v_payload_hash THEN
    RAISE EXCEPTION 'This attachment operation id was already used with different details'
      USING ERRCODE = '23514';
  END IF;
  IF v_operation.result_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND THEN
    UPDATE public.task_attachment_operations AS operation
    SET result_status = 'unavailable'
    WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_operation.attachment_id IS NOT NULL THEN
    SELECT attachment.* INTO v_attachment
    FROM public.task_attachments AS attachment
    WHERE attachment.id = v_operation.attachment_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
    END IF;
    IF v_attachment.state = 'reserved' THEN
      RETURN jsonb_build_object(
        'status', 'reserved',
        'operation_id', p_operation_id,
        'attachment_id', v_attachment.id,
        'reservation_expires_at', v_attachment.reservation_expires_at
      );
    ELSIF v_attachment.state = 'active' THEN
      RETURN jsonb_build_object(
        'status', 'confirmed',
        'operation_id', p_operation_id,
        'attachment_id', v_attachment.id
      );
    END IF;
    RETURN jsonb_build_object('status', 'expired_unknown', 'operation_id', p_operation_id);
  END IF;

  PERFORM 1 FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton FOR UPDATE;

  SELECT count(*)::integer INTO v_actor_reservations
  FROM public.task_attachments AS attachment
  WHERE attachment.uploaded_by = p_actor_id
    AND attachment.state = 'reserved'
    AND attachment.reservation_expires_at > pg_catalog.clock_timestamp();
  IF v_actor_reservations >= 5 THEN
    UPDATE public.task_attachment_operations AS operation
    SET result_status = 'reservation_limit'
    WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'reservation_limit', 'operation_id', p_operation_id);
  END IF;

  SELECT count(*)::integer INTO v_instance_reservations
  FROM public.task_attachments AS attachment
  WHERE attachment.state = 'reserved'
    AND attachment.reservation_expires_at > pg_catalog.clock_timestamp();
  IF v_instance_reservations >= 20 THEN
    UPDATE public.task_attachment_operations AS operation
    SET result_status = 'instance_busy'
    WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'instance_busy', 'operation_id', p_operation_id);
  END IF;

  SELECT count(*)::integer INTO v_recent_uploads
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id
    AND operation.action = 'upload'
    AND operation.created_at > pg_catalog.clock_timestamp() - interval '1 minute';
  IF v_recent_uploads > 30 THEN
    UPDATE public.task_attachment_operations AS operation
    SET result_status = 'rate_limited'
    WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'rate_limited', 'operation_id', p_operation_id);
  END IF;

  SELECT count(*)::integer INTO v_task_count
  FROM public.task_attachments AS attachment
  WHERE attachment.task_id = p_task_id
    AND attachment.state <> 'purged';
  IF v_task_count >= 20 THEN
    UPDATE public.task_attachment_operations AS operation
    SET result_status = 'task_limit'
    WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
    RETURN jsonb_build_object('status', 'task_limit', 'operation_id', p_operation_id);
  END IF;

  SELECT ledger.active_bytes + ledger.recoverable_bytes
      + ledger.reserved_bytes + ledger.pending_bytes,
      ledger.limit_bytes
  INTO v_used_bytes, v_limit_bytes
  FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton;
  IF v_used_bytes + p_size_bytes > v_limit_bytes THEN
    UPDATE public.task_attachment_operations AS operation
    SET result_status = 'quota'
    WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
    RETURN jsonb_build_object(
      'status', 'quota',
      'operation_id', p_operation_id,
      'used_bytes', v_used_bytes,
      'limit_bytes', v_limit_bytes
    );
  END IF;

  v_attachment_id := pg_catalog.gen_random_uuid();
  v_reserved_until := pg_catalog.clock_timestamp() + interval '15 minutes';
  INSERT INTO public.task_attachments(
    id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
    size_bytes, sha256, object_key, state, reservation_expires_at
  ) VALUES (
    v_attachment_id,
    v_context.board_id,
    p_task_id,
    p_actor_id,
    p_operation_id,
    p_file_name,
    p_size_bytes,
    pg_catalog.decode(p_sha256, 'hex'),
    'attachments/' || v_attachment_id::text,
    'reserved',
    v_reserved_until
  );
  UPDATE public.task_attachment_operations AS operation
  SET attachment_id = v_attachment_id,
      result_status = 'reserved'
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;

  RETURN jsonb_build_object(
    'status', 'reserved',
    'operation_id', p_operation_id,
    'attachment_id', v_attachment_id,
    'reservation_expires_at', v_reserved_until
  );
END;
$$;
REVOKE ALL ON FUNCTION public.reserve_task_attachment_p(uuid, uuid, text, uuid, text, integer, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reserve_task_attachment_p(uuid, uuid, text, uuid, text, integer, text)
  TO service_role;

CREATE FUNCTION public.publish_task_attachment_p(
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

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
  FOR UPDATE;
  IF NOT FOUND OR v_attachment.uploaded_by <> p_actor_id
    OR v_attachment.task_id <> p_task_id THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND OR v_context.board_id <> v_attachment.board_id THEN
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
REVOKE ALL ON FUNCTION public.publish_task_attachment_p(uuid, text, uuid, uuid, uuid, integer, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.publish_task_attachment_p(uuid, text, uuid, uuid, uuid, integer, text)
  TO service_role;

CREATE FUNCTION public.list_task_attachments_p(p_slug text, p_task_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_context record;
  v_attachments jsonb;
  v_active_count bigint;
  v_recoverable_count bigint;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_enabled_application_identity_p(v_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(v_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT COALESCE(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'id', attachment.id,
      'file_name', attachment.file_name,
      'size_bytes', attachment.size_bytes,
      'state', attachment.state,
      'created_at', attachment.created_at,
      'deleted_at', attachment.deleted_at,
      'expires_at', attachment.expires_at,
      'can_restore', attachment.state = 'recoverable'
        AND attachment.expires_at > pg_catalog.clock_timestamp()
        AND ((attachment.deletion_cause = 'author'
            AND (attachment.uploaded_by = v_actor_id OR v_context.owner_id = v_actor_id))
          OR (attachment.deletion_cause = 'moderation'
            AND v_context.owner_id = v_actor_id)),
      'can_delete', attachment.state = 'active'
        AND (attachment.uploaded_by = v_actor_id OR v_context.owner_id = v_actor_id)
    ) ORDER BY attachment.created_at, attachment.id
  ), '[]'::jsonb)
  INTO v_attachments
  FROM public.task_attachments AS attachment
  WHERE attachment.board_id = v_context.board_id
    AND attachment.task_id = p_task_id
    AND (attachment.state = 'active'
      OR (attachment.state = 'recoverable'
        AND attachment.expires_at > pg_catalog.clock_timestamp()
        AND (attachment.deletion_cause = 'author'
          OR (attachment.deletion_cause = 'moderation'
            AND v_context.owner_id = v_actor_id))));

  SELECT count(*) FILTER (WHERE attachment.state = 'active'),
    count(*) FILTER (WHERE attachment.state = 'recoverable')
  INTO v_active_count, v_recoverable_count
  FROM public.task_attachments AS attachment
  WHERE attachment.board_id = v_context.board_id
    AND attachment.task_id = p_task_id
    AND attachment.state IN ('active', 'recoverable');

  RETURN jsonb_build_object(
    'status', 'ok',
    'attachments', v_attachments,
    'counts', jsonb_build_object(
      'active', v_active_count,
      'recoverable', v_recoverable_count
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_task_attachments_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_task_attachments_p(text, uuid)
  TO authenticated;

CREATE FUNCTION public.delete_task_attachment_p(
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

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id AND attachment.task_id = p_task_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
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

CREATE FUNCTION public.restore_task_attachment_p(
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

  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id AND attachment.task_id = p_task_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND OR v_context.board_id <> v_attachment.board_id
    OR (v_context.owner_id <> p_actor_id AND v_attachment.uploaded_by <> p_actor_id)
    OR (v_attachment.deletion_cause = 'moderation' AND v_context.owner_id <> p_actor_id)
    OR v_attachment.deletion_cause = 'admin_cleanup' THEN
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

CREATE FUNCTION public.claim_expired_task_attachment_cleanup_p(
  p_lease_id uuid,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  attachment_id uuid,
  object_key text,
  size_bytes integer,
  prior_state text,
  lease_until timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF p_lease_id IS NULL OR p_limit IS NULL OR p_limit < 1 THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT attachment.id, attachment.state AS prior_state
    FROM public.task_attachments AS attachment
    WHERE (attachment.state = 'recoverable' AND attachment.expires_at <= pg_catalog.clock_timestamp())
      OR (attachment.state = 'reserved' AND attachment.reservation_expires_at <= pg_catalog.clock_timestamp())
      OR attachment.state IN ('cleanup_pending', 'missing')
      OR (attachment.state = 'purging' AND attachment.purge_lease_until <= pg_catalog.clock_timestamp())
    ORDER BY COALESCE(attachment.expires_at, attachment.reservation_expires_at, attachment.created_at), attachment.id
    FOR UPDATE SKIP LOCKED
    LIMIT LEAST(p_limit, 100)
  ), claimed AS (
    UPDATE public.task_attachments AS attachment
    SET state = 'purging',
        purge_lease_id = p_lease_id,
        purge_lease_until = pg_catalog.clock_timestamp() + interval '5 minutes',
        purge_attempts = attachment.purge_attempts + 1
    FROM candidates
    WHERE attachment.id = candidates.id
    RETURNING attachment.id, attachment.object_key, attachment.size_bytes,
      attachment.purge_lease_until, candidates.prior_state
  )
  SELECT claimed.id, claimed.object_key, claimed.size_bytes,
    claimed.prior_state, claimed.purge_lease_until
  FROM claimed;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_expired_task_attachment_cleanup_p(uuid, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_expired_task_attachment_cleanup_p(uuid, integer)
  TO service_role;

CREATE FUNCTION public.confirm_task_attachment_purge_p(
  p_attachment_id uuid,
  p_lease_id uuid,
  p_object_absent boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_attachment public.task_attachments%ROWTYPE;
BEGIN
  IF p_attachment_id IS NULL OR p_lease_id IS NULL OR p_object_absent IS NULL THEN
    RETURN jsonb_build_object('status', 'rejected');
  END IF;
  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
    AND attachment.state = 'purging'
    AND attachment.purge_lease_id = p_lease_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  IF p_object_absent THEN
    UPDATE public.task_attachments AS attachment
    SET state = 'purged', purge_lease_id = NULL, purge_lease_until = NULL
    WHERE attachment.id = p_attachment_id;
    RETURN jsonb_build_object('status', 'purged', 'attachment_id', p_attachment_id);
  END IF;

  UPDATE public.task_attachments AS attachment
  SET state = 'cleanup_pending', purge_lease_id = NULL, purge_lease_until = NULL
  WHERE attachment.id = p_attachment_id;
  RETURN jsonb_build_object('status', 'cleanup_pending', 'attachment_id', p_attachment_id);
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_task_attachment_purge_p(uuid, uuid, boolean)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_task_attachment_purge_p(uuid, uuid, boolean)
  TO service_role;

CREATE FUNCTION public.begin_task_attachment_cleanup_p(
  p_attachment_id uuid,
  p_lease_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_attachment public.task_attachments%ROWTYPE;
  v_lease_until timestamptz;
BEGIN
  IF p_attachment_id IS NULL OR p_lease_id IS NULL THEN
    RETURN jsonb_build_object('status', 'rejected');
  END IF;
  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
    AND attachment.state = 'reserved'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  v_lease_until := pg_catalog.clock_timestamp() + interval '5 minutes';
  UPDATE public.task_attachments AS attachment
  SET state = 'purging', purge_lease_id = p_lease_id,
      purge_lease_until = v_lease_until,
      purge_attempts = attachment.purge_attempts + 1
  WHERE attachment.id = p_attachment_id;
  RETURN jsonb_build_object(
    'status', 'claimed',
    'attachment_id', p_attachment_id,
    'object_key', v_attachment.object_key,
    'lease_until', v_lease_until
  );
END;
$$;
REVOKE ALL ON FUNCTION public.begin_task_attachment_cleanup_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.begin_task_attachment_cleanup_p(uuid, uuid)
  TO service_role;

CREATE FUNCTION public.resolve_task_attachment_download_p(
  p_actor_id uuid,
  p_slug text,
  p_task_id uuid,
  p_attachment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_attachment public.task_attachments%ROWTYPE;
  v_context record;
BEGIN
  IF p_actor_id IS NULL OR p_slug IS NULL OR p_task_id IS NULL OR p_attachment_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
    AND attachment.task_id = p_task_id
    AND attachment.state = 'active';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT context.* INTO v_context
  FROM public.task_attachment_context_for_actor_p(p_actor_id, p_slug, p_task_id) AS context;
  IF NOT FOUND OR v_context.board_id <> v_attachment.board_id THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  RETURN jsonb_build_object(
    'status', 'ok',
    'object_key', v_attachment.object_key,
    'file_name', v_attachment.file_name,
    'size_bytes', v_attachment.size_bytes,
    'sha256', pg_catalog.encode(v_attachment.sha256, 'hex')
  );
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_task_attachment_download_p(uuid, text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.resolve_task_attachment_download_p(uuid, text, uuid, uuid)
  TO service_role;

CREATE FUNCTION public.admin_task_attachment_storage_summary_p(p_actor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_ledger public.task_attachment_quota_ledger%ROWTYPE;
  v_active_count bigint;
  v_recoverable_count bigint;
  v_reserved_count bigint;
  v_pending_count bigint;
BEGIN
  IF p_actor_id IS NULL OR NOT public.is_enabled_application_identity_p(p_actor_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = p_actor_id AND access.state = 'active' AND access.is_admin
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT ledger.* INTO v_ledger
  FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton;
  SELECT
    count(*) FILTER (WHERE attachment.state = 'active'),
    count(*) FILTER (WHERE attachment.state = 'recoverable'),
    count(*) FILTER (WHERE attachment.state = 'reserved'),
    count(*) FILTER (WHERE attachment.state IN ('purging', 'cleanup_pending', 'missing'))
  INTO v_active_count, v_recoverable_count, v_reserved_count, v_pending_count
  FROM public.task_attachments AS attachment
  WHERE attachment.state <> 'purged';
  RETURN jsonb_build_object(
    'status', 'ok',
    'limit_bytes', v_ledger.limit_bytes,
    'used_bytes', v_ledger.active_bytes + v_ledger.recoverable_bytes
      + v_ledger.reserved_bytes + v_ledger.pending_bytes,
    'active_bytes', v_ledger.active_bytes,
    'recoverable_bytes', v_ledger.recoverable_bytes,
    'reserved_bytes', v_ledger.reserved_bytes,
    'pending_bytes', v_ledger.pending_bytes,
    'active_count', v_active_count,
    'recoverable_count', v_recoverable_count,
    'reserved_count', v_reserved_count,
    'pending_count', v_pending_count
  );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_task_attachment_storage_summary_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_task_attachment_storage_summary_p(uuid)
  TO service_role;

CREATE FUNCTION public.list_admin_task_attachment_cleanup_p(
  p_actor_id uuid,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_items jsonb;
BEGIN
  IF p_actor_id IS NULL OR NOT public.is_enabled_application_identity_p(p_actor_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = p_actor_id AND access.state = 'active' AND access.is_admin
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT COALESCE(pg_catalog.jsonb_agg(item), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT pg_catalog.jsonb_build_object(
      'attachment_id', attachment.id,
      'board_reference', attachment.board_id,
      'task_reference', attachment.task_id,
      'owner_reference', board.owner_id,
      'uploaded_by_reference', attachment.uploaded_by,
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
    ORDER BY attachment.created_at, attachment.id
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 200)
  ) AS candidates;
  RETURN jsonb_build_object('status', 'ok', 'items', v_items);
END;
$$;
REVOKE ALL ON FUNCTION public.list_admin_task_attachment_cleanup_p(uuid, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_admin_task_attachment_cleanup_p(uuid, integer)
  TO service_role;

CREATE FUNCTION public.admin_delete_task_attachment_p(
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
  v_operation public.task_attachment_operations%ROWTYPE;
  v_payload_hash bytea;
  v_deleted_at timestamptz;
  v_board_id uuid;
  v_generation_id uuid;
  v_task_id uuid;
  v_owner_id uuid;
  v_owner_membership_id uuid;
BEGIN
  IF p_actor_id IS NULL OR p_attachment_id IS NULL OR p_operation_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = p_actor_id AND access.state = 'active' AND access.is_admin
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  v_payload_hash := extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'action', 'admin_cleanup', 'attachment_id', p_attachment_id
  )::text, 'UTF8'), 'sha256');
  INSERT INTO public.task_attachment_operations(
    actor_id, operation_id, action, payload_hash, attachment_id, result_status
  ) VALUES (
    p_actor_id, p_operation_id, 'admin_cleanup', v_payload_hash, p_attachment_id, 'processing'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING;
  SELECT operation.* INTO v_operation
  FROM public.task_attachment_operations AS operation
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF v_operation.action IS DISTINCT FROM 'admin_cleanup'
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
  UPDATE public.task_attachments AS attachment
  SET state = 'recoverable',
      deleted_at = v_deleted_at,
      deleted_by = p_actor_id,
      deletion_cause = 'admin_cleanup',
      expires_at = v_deleted_at + interval '168 hours'
  WHERE attachment.id = p_attachment_id
  RETURNING attachment.board_id, attachment.task_id
  INTO v_board_id, v_task_id;

  SELECT board.active_generation_id, board.owner_id, membership.id
  INTO v_generation_id, v_owner_id, v_owner_membership_id
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = board.owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  JOIN public.tasks AS task ON task.id = v_task_id
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  WHERE board.id = v_board_id
    AND public.is_enabled_application_identity_p(board.owner_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task_id AND deletion.state = 'deleted'
    );
  IF FOUND THEN
    INSERT INTO public.task_notifications(
      board_id, generation_id, task_id, comment_id, source_kind, source_id,
      recipient_user_id, recipient_membership_id, reason_codes, actor_name, occurred_at
    ) VALUES (
      v_board_id, v_generation_id, v_task_id, NULL, 'task_change', p_operation_id,
      v_owner_id, v_owner_membership_id, ARRAY['attachment_cleanup'],
      'Administración', v_deleted_at
    ) ON CONFLICT (source_kind, source_id, recipient_membership_id) DO NOTHING;
  END IF;

  UPDATE public.task_attachment_operations AS operation
  SET result_status = 'confirmed'
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id;
  RETURN jsonb_build_object(
    'status', 'confirmed',
    'attachment_id', p_attachment_id,
    'expires_at', v_deleted_at + interval '168 hours'
  );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_delete_task_attachment_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_delete_task_attachment_p(uuid, uuid, uuid)
  TO service_role;

CREATE FUNCTION public.admin_restore_task_attachment_p(
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
  v_operation public.task_attachment_operations%ROWTYPE;
  v_payload_hash bytea;
BEGIN
  IF p_actor_id IS NULL OR p_attachment_id IS NULL OR p_operation_id IS NULL
    OR NOT public.is_enabled_application_identity_p(p_actor_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.application_access AS access
      WHERE access.auth_user_id = p_actor_id AND access.state = 'active' AND access.is_admin
    ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  WHERE attachment.id = p_attachment_id
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
REVOKE ALL ON FUNCTION public.admin_restore_task_attachment_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_restore_task_attachment_p(uuid, uuid, uuid)
  TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
