-- Retained import generations include the board header that was replaced.
BEGIN;

ALTER TABLE public.board_generation_retention
  ADD COLUMN retained_board_name text,
  ADD COLUMN retained_time_zone text,
  ADD CONSTRAINT board_generation_retention_header_shape CHECK (
    (retained_board_name IS NULL AND retained_time_zone IS NULL)
    OR (retained_board_name IS NOT NULL
      AND pg_catalog.btrim(retained_board_name) <> ''
      AND pg_catalog.char_length(retained_board_name) <= 100
      AND retained_time_zone IS NOT NULL
      AND pg_catalog.btrim(retained_time_zone) <> '')
  );

CREATE FUNCTION public.capture_board_generation_retention_header_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_name text;
  v_time_zone text;
BEGIN
  IF NEW.retained_board_name IS NULL AND NEW.retained_time_zone IS NULL THEN
    SELECT board.name, board.time_zone
    INTO v_board_name, v_time_zone
    FROM public.boards AS board
    WHERE board.id = NEW.board_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The retained import board is unavailable'
        USING ERRCODE = '23503';
    END IF;
    NEW.retained_board_name := v_board_name;
    NEW.retained_time_zone := v_time_zone;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER board_generation_retention_capture_header
  BEFORE INSERT ON public.board_generation_retention
  FOR EACH ROW EXECUTE FUNCTION public.capture_board_generation_retention_header_tg();
REVOKE ALL ON FUNCTION public.capture_board_generation_retention_header_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_import_restore_operations (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  base_generation_id uuid NOT NULL,
  expected_content_revision bigint NOT NULL CHECK (expected_content_revision > 0),
  status text NOT NULL CHECK (status IN (
    'prepared', 'confirmed', 'conflict', 'expired', 'metadata_unavailable'
  )),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  expires_at timestamptz NOT NULL,
  confirmed_at timestamptz,
  result jsonb,
  PRIMARY KEY (actor_id, operation_id),
  CHECK (expires_at > created_at),
  CHECK ((status = 'confirmed') = (confirmed_at IS NOT NULL))
);
CREATE INDEX board_import_restore_operations_expiry_idx
  ON public.board_import_restore_operations(expires_at, board_id)
  WHERE status = 'prepared';
ALTER TABLE public.board_import_restore_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_import_restore_operations
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.list_board_import_recoveries_p(p_slug text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_revision bigint;
  v_recoveries jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_slug = '' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM 1 FROM public.application_access AS access
  WHERE access.auth_user_id = v_actor_id AND access.state = 'active'
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug
    AND board.owner_id = v_actor_id
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR SHARE OF board, membership;
  IF NOT FOUND OR NOT public.is_board_owner(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_board.id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT COALESCE(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'generation_id', retention.generation_id,
      'retained_at', retention.retained_at,
      'expires_at', retention.expires_at,
      'board', CASE WHEN retention.retained_board_name IS NULL THEN NULL
        ELSE pg_catalog.jsonb_build_object(
          'name', retention.retained_board_name,
          'time_zone', retention.retained_time_zone
        ) END,
      'content', public.board_import_generation_summary_p(
        retention.board_id, retention.generation_id
      ),
      'restorable', retention.retained_board_name IS NOT NULL
        AND retention.retained_time_zone IS NOT NULL,
      'reason', CASE WHEN retention.retained_board_name IS NULL
        THEN 'metadata_unavailable' ELSE NULL END
    ) ORDER BY retention.retained_at DESC, retention.generation_id
  ), '[]'::jsonb)
  INTO v_recoveries
  FROM public.board_generation_retention AS retention
  JOIN public.board_generations AS generation
    ON generation.board_id = retention.board_id
    AND generation.id = retention.generation_id
    AND generation.status = 'archived'
  WHERE retention.board_id = v_board.id
    AND retention.expires_at > pg_catalog.clock_timestamp();

  RETURN pg_catalog.jsonb_build_object(
    'status', 'ok',
    'current_generation_id', v_board.active_generation_id,
    'content_revision', v_revision,
    'current_board', pg_catalog.jsonb_build_object(
      'name', v_board.name,
      'time_zone', v_board.time_zone
    ),
    'current', public.board_import_generation_summary_p(
      v_board.id, v_board.active_generation_id
    ),
    'capacity', public.board_import_capacity_snapshot_p(),
    'recoveries', v_recoveries
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_board_import_recoveries_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_board_import_recoveries_p(text)
  TO authenticated;

CREATE FUNCTION public.prepare_board_import_restore_p(
  p_slug text,
  p_generation_id uuid,
  p_operation_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_revision bigint;
  v_operation public.board_import_restore_operations%ROWTYPE;
  v_retention public.board_generation_retention%ROWTYPE;
  v_capacity jsonb;
  v_now timestamptz;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_slug = '' OR p_generation_id IS NULL
    OR p_operation_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM 1 FROM public.application_access AS access
  WHERE access.auth_user_id = v_actor_id AND access.state = 'active'
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug AND board.owner_id = v_actor_id
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND OR NOT public.is_board_owner(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_board.id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT operation.* INTO v_operation
  FROM public.board_import_restore_operations AS operation
  WHERE operation.actor_id = v_actor_id
    AND operation.operation_id = p_operation_id
  FOR UPDATE;
  v_now := pg_catalog.clock_timestamp();
  IF FOUND THEN
    IF v_operation.board_id <> v_board.id
      OR v_operation.generation_id <> p_generation_id THEN
      RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
    END IF;
    IF v_operation.status = 'confirmed' THEN
      RETURN COALESCE(v_operation.result,
        pg_catalog.jsonb_build_object(
          'status', 'confirmed', 'operation_id', p_operation_id
        ));
    END IF;
    IF v_operation.status = 'conflict' THEN
      RETURN pg_catalog.jsonb_build_object('status', 'conflict');
    END IF;
    IF v_operation.status = 'metadata_unavailable' THEN
      RETURN pg_catalog.jsonb_build_object('status', 'metadata_unavailable');
    END IF;
    IF v_operation.status = 'expired' OR v_operation.expires_at <= v_now THEN
      UPDATE public.board_import_restore_operations AS operation
      SET status = 'expired'
      WHERE operation.actor_id = v_actor_id
        AND operation.operation_id = p_operation_id;
      RETURN pg_catalog.jsonb_build_object('status', 'expired');
    END IF;
    IF v_operation.base_generation_id IS DISTINCT FROM v_board.active_generation_id
      OR v_operation.expected_content_revision IS DISTINCT FROM v_revision THEN
      UPDATE public.board_import_restore_operations AS operation
      SET status = 'conflict'
      WHERE operation.actor_id = v_actor_id
        AND operation.operation_id = p_operation_id;
      RETURN pg_catalog.jsonb_build_object(
        'status', 'conflict', 'content_revision', v_revision,
        'current_generation_id', v_board.active_generation_id
      );
    END IF;
  ELSE
    INSERT INTO public.board_import_restore_operations(
      actor_id, operation_id, board_id, generation_id, base_generation_id,
      expected_content_revision, status, expires_at
    ) VALUES (
      v_actor_id, p_operation_id, v_board.id, p_generation_id,
      v_board.active_generation_id, v_revision, 'prepared',
      v_now + interval '1 hour'
    ) RETURNING * INTO v_operation;
  END IF;

  SELECT retention.* INTO v_retention
  FROM public.board_generation_retention AS retention
  JOIN public.board_generations AS generation
    ON generation.board_id = retention.board_id
    AND generation.id = retention.generation_id
    AND generation.status = 'archived'
  WHERE retention.board_id = v_board.id
    AND retention.generation_id = p_generation_id
  FOR UPDATE OF retention;
  v_now := pg_catalog.clock_timestamp();
  IF NOT FOUND THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'expired'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id
      AND operation.status = 'prepared';
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  IF v_retention.expires_at <= v_now THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'expired'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id
      AND operation.status = 'prepared';
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  IF v_retention.retained_board_name IS NULL
    OR v_retention.retained_time_zone IS NULL THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'metadata_unavailable'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id
      AND operation.status = 'prepared';
    RETURN pg_catalog.jsonb_build_object('status', 'metadata_unavailable');
  END IF;
  v_capacity := public.board_import_capacity_snapshot_p();
  RETURN pg_catalog.jsonb_build_object(
    'status', 'ready',
    'operation_id', p_operation_id,
    'restored_generation_id', v_retention.generation_id,
    'replaced_generation_id', v_board.active_generation_id,
    'retained_at', v_retention.retained_at,
    'expires_at', v_retention.expires_at,
    'preview_expires_at', v_operation.expires_at,
    'content_revision', v_revision,
    'restored_board', pg_catalog.jsonb_build_object(
      'name', v_retention.retained_board_name,
      'time_zone', v_retention.retained_time_zone
    ),
    'current_board', pg_catalog.jsonb_build_object(
      'name', v_board.name,
      'time_zone', v_board.time_zone
    ),
    'restored', public.board_import_generation_summary_p(
      v_board.id, v_retention.generation_id
    ),
    'current', public.board_import_generation_summary_p(
      v_board.id, v_board.active_generation_id
    ),
    'capacity', v_capacity || pg_catalog.jsonb_build_object(
      'can_restore', v_capacity->>'can_replace' = 'true'
    )
  );
END;
$$;
REVOKE ALL ON FUNCTION public.prepare_board_import_restore_p(text, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prepare_board_import_restore_p(text, uuid, uuid)
  TO authenticated;

CREATE FUNCTION public.confirm_board_import_restore_p(
  p_slug text,
  p_generation_id uuid,
  p_operation_id uuid,
  p_expected_content_revision bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_revision bigint;
  v_operation public.board_import_restore_operations%ROWTYPE;
  v_retention public.board_generation_retention%ROWTYPE;
  v_ledger public.task_attachment_quota_ledger%ROWTYPE;
  v_used_bytes bigint;
  v_now timestamptz;
  v_retained_until timestamptz;
  v_result jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_slug = '' OR p_generation_id IS NULL
    OR p_operation_id IS NULL OR p_expected_content_revision IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM 1 FROM public.application_access AS access
  WHERE access.auth_user_id = v_actor_id AND access.state = 'active'
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug AND board.owner_id = v_actor_id
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND OR NOT public.is_board_owner(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_board.id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_restore_operations AS operation
  WHERE operation.actor_id = v_actor_id
    AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF NOT FOUND OR v_operation.board_id <> v_board.id
    OR v_operation.generation_id <> p_generation_id
    OR v_operation.expected_content_revision <> p_expected_content_revision THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_operation.status = 'confirmed' THEN
    RETURN COALESCE(v_operation.result,
      pg_catalog.jsonb_build_object(
        'status', 'confirmed', 'operation_id', p_operation_id,
        'restored_generation_id', p_generation_id
      ));
  END IF;
  IF v_operation.status = 'metadata_unavailable' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'metadata_unavailable');
  END IF;
  IF v_operation.status = 'conflict' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'conflict');
  END IF;
  IF v_operation.status = 'expired' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  IF v_operation.status <> 'prepared' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  v_now := pg_catalog.clock_timestamp();
  IF v_operation.expires_at <= v_now THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'expired'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  IF v_operation.base_generation_id IS DISTINCT FROM v_board.active_generation_id
    OR v_operation.expected_content_revision IS DISTINCT FROM v_revision THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'conflict'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'content_revision', v_revision,
      'current_generation_id', v_board.active_generation_id
    );
  END IF;

  SELECT retention.* INTO v_retention
  FROM public.board_generation_retention AS retention
  JOIN public.board_generations AS generation
    ON generation.board_id = retention.board_id
    AND generation.id = retention.generation_id
    AND generation.status = 'archived'
  WHERE retention.board_id = v_board.id
    AND retention.generation_id = p_generation_id
  FOR UPDATE OF retention;
  v_now := pg_catalog.clock_timestamp();
  IF NOT FOUND OR v_retention.expires_at <= v_now THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'expired'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  IF v_retention.retained_board_name IS NULL
    OR v_retention.retained_time_zone IS NULL THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'metadata_unavailable'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object('status', 'metadata_unavailable');
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.task_attachments AS attachment
    JOIN public.tasks AS task ON task.id = attachment.task_id
    JOIN public.columns AS column_row ON column_row.id = task.column_id
    WHERE attachment.board_id = v_board.id
      AND column_row.board_id = v_board.id
      AND column_row.generation_id = p_generation_id
      AND attachment.state NOT IN ('active', 'recoverable')
  ) THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'expired'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;

  SELECT ledger.* INTO v_ledger
  FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'capacity');
  END IF;
  v_used_bytes := v_ledger.active_bytes + v_ledger.recoverable_bytes
    + v_ledger.reserved_bytes + v_ledger.pending_bytes;
  IF v_used_bytes > v_ledger.limit_bytes THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'capacity', 'capacity', public.board_import_capacity_snapshot_p()
    );
  END IF;

  v_now := pg_catalog.clock_timestamp();
  IF v_operation.expires_at <= v_now OR v_retention.expires_at <= v_now THEN
    UPDATE public.board_import_restore_operations AS operation
    SET status = 'expired'
    WHERE operation.actor_id = v_actor_id
      AND operation.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;

  v_retained_until := v_now + interval '168 hours';
  INSERT INTO public.board_generation_retention(
    board_id, generation_id, replacement_generation_id,
    retained_at, expires_at
  ) VALUES (
    v_board.id, v_board.active_generation_id, p_generation_id,
    v_now, v_retained_until
  );
  UPDATE public.board_generations AS generation
  SET status = 'archived'
  WHERE generation.board_id = v_board.id
    AND generation.id = v_operation.base_generation_id
    AND generation.status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The replaced board generation could not be retained'
      USING ERRCODE = '40001';
  END IF;
  UPDATE public.board_generations AS generation
  SET status = 'active'
  WHERE generation.board_id = v_board.id
    AND generation.id = p_generation_id
    AND generation.status = 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The retained board generation could not be reactivated'
      USING ERRCODE = '40001';
  END IF;
  UPDATE public.boards AS board
  SET active_generation_id = p_generation_id,
      name = v_retention.retained_board_name,
      time_zone = v_retention.retained_time_zone
  WHERE board.id = v_board.id
    AND board.active_generation_id = v_operation.base_generation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The board changed during restore publication'
      USING ERRCODE = '40001';
  END IF;
  DELETE FROM public.board_generation_retention AS retention
  WHERE retention.board_id = v_board.id
    AND retention.generation_id = p_generation_id;

  v_result := pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'restored_generation_id', p_generation_id,
    'replaced_generation_id', v_operation.base_generation_id,
    'content_revision', v_revision + 1,
    'retained_until', v_retained_until
  );
  UPDATE public.board_import_restore_operations AS operation
  SET status = 'confirmed', confirmed_at = v_now, result = v_result
  WHERE operation.actor_id = v_actor_id
    AND operation.operation_id = p_operation_id;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_board_import_restore_p(text, uuid, uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_board_import_restore_p(text, uuid, uuid, bigint)
  TO authenticated;

CREATE FUNCTION public.cleanup_expired_board_import_restore_operations_p(
  p_limit integer DEFAULT 50
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_operation public.board_import_restore_operations%ROWTYPE;
  v_now timestamptz;
  v_cleaned integer := 0;
  v_deleted integer := 0;
  v_limit integer;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 THEN RETURN 0; END IF;
  v_limit := LEAST(p_limit, 100);
  FOR v_board_id IN
    SELECT board.id
    FROM public.boards AS board
    WHERE EXISTS (
      SELECT 1 FROM public.board_import_restore_operations AS operation
      WHERE operation.board_id = board.id
        AND ((operation.status = 'prepared'
            AND operation.expires_at <= pg_catalog.clock_timestamp())
          OR (operation.status = 'confirmed'
            AND operation.confirmed_at <= pg_catalog.clock_timestamp() - interval '168 hours')
          OR (operation.status IN ('conflict', 'expired', 'metadata_unavailable')
            AND operation.expires_at <= pg_catalog.clock_timestamp() - interval '168 hours'))
    )
    ORDER BY board.id
    LIMIT v_limit
  LOOP
    EXIT WHEN v_cleaned >= v_limit;
    PERFORM 1 FROM public.boards AS board
    WHERE board.id = v_board_id FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    v_now := pg_catalog.clock_timestamp();
    FOR v_operation IN
      SELECT operation.*
      FROM public.board_import_restore_operations AS operation
      WHERE operation.board_id = v_board_id
        AND operation.status = 'prepared'
        AND operation.expires_at <= v_now
      ORDER BY operation.expires_at, operation.operation_id
      LIMIT v_limit - v_cleaned
      FOR UPDATE OF operation SKIP LOCKED
    LOOP
      UPDATE public.board_import_restore_operations AS operation
      SET status = 'expired'
      WHERE operation.actor_id = v_operation.actor_id
        AND operation.operation_id = v_operation.operation_id;
      v_cleaned := v_cleaned + 1;
    END LOOP;

    WITH stale AS (
      SELECT operation.actor_id, operation.operation_id
      FROM public.board_import_restore_operations AS operation
      WHERE operation.board_id = v_board_id
        AND ((operation.status = 'confirmed'
            AND operation.confirmed_at <= v_now - interval '168 hours')
          OR (operation.status IN ('conflict', 'expired', 'metadata_unavailable')
            AND operation.expires_at <= v_now - interval '168 hours'))
      ORDER BY COALESCE(operation.confirmed_at, operation.expires_at),
        operation.actor_id, operation.operation_id
      LIMIT LEAST(v_limit - v_cleaned, 100)
      FOR UPDATE OF operation SKIP LOCKED
    )
    DELETE FROM public.board_import_restore_operations AS operation
    USING stale
    WHERE operation.actor_id = stale.actor_id
      AND operation.operation_id = stale.operation_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_cleaned := v_cleaned + v_deleted;
  END LOOP;
  RETURN v_cleaned;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_expired_board_import_restore_operations_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_board_import_restore_operations_p(integer)
  TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
