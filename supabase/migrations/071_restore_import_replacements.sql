-- Retained import generations include the board header that was replaced.
BEGIN;

-- A generation can be activated more than once. Keep notifications scoped to
-- the activation that produced them so restoring content never revives an old
-- inbox entry or its unread state.
ALTER TABLE public.task_notifications
  ADD COLUMN generation_notification_epoch uuid;

CREATE TABLE public.board_generation_notification_epochs (
  board_id uuid PRIMARY KEY REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  notification_epoch uuid NOT NULL
);
ALTER TABLE public.board_generation_notification_epochs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_generation_notification_epochs
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.task_notification_matches_active_generation_epoch_p(
  p_board_id uuid,
  p_generation_id uuid,
  p_notification_epoch uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.boards AS board
    WHERE board.id = p_board_id
      AND board.active_generation_id = p_generation_id
      AND (
        NOT EXISTS (
          SELECT 1 FROM public.board_generation_notification_epochs AS epoch
          WHERE epoch.board_id = board.id
        )
        OR EXISTS (
          SELECT 1 FROM public.board_generation_notification_epochs AS epoch
          WHERE epoch.board_id = board.id
            AND epoch.generation_id = board.active_generation_id
            AND epoch.notification_epoch = p_notification_epoch
        )
      )
  );
$$;
REVOKE ALL ON FUNCTION public.task_notification_matches_active_generation_epoch_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.advance_board_notification_epoch_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF OLD.active_generation_id IS DISTINCT FROM NEW.active_generation_id THEN
    INSERT INTO public.board_generation_notification_epochs(
      board_id, generation_id, notification_epoch
    ) VALUES (
      NEW.id, NEW.active_generation_id, pg_catalog.gen_random_uuid()
    )
    ON CONFLICT (board_id) DO UPDATE
    SET generation_id = EXCLUDED.generation_id,
        notification_epoch = EXCLUDED.notification_epoch;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER boards_advance_task_notification_epoch
  BEFORE UPDATE OF active_generation_id ON public.boards
  FOR EACH ROW EXECUTE FUNCTION public.advance_board_notification_epoch_tg();
REVOKE ALL ON FUNCTION public.advance_board_notification_epoch_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.stamp_task_notification_epoch_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  SELECT epoch.notification_epoch
  INTO NEW.generation_notification_epoch
  FROM public.boards AS board
  LEFT JOIN public.board_generation_notification_epochs AS epoch
    ON epoch.board_id = board.id
    AND epoch.generation_id = board.active_generation_id
  WHERE board.id = NEW.board_id
    AND board.active_generation_id = NEW.generation_id;
  RETURN NEW;
END;
$$;
CREATE TRIGGER task_notifications_stamp_generation_epoch
  BEFORE INSERT ON public.task_notifications
  FOR EACH ROW EXECUTE FUNCTION public.stamp_task_notification_epoch_tg();
REVOKE ALL ON FUNCTION public.stamp_task_notification_epoch_tg()
  FROM PUBLIC, anon, authenticated, service_role;

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

-- Keep notifications scoped to one logical activation of a generation.
CREATE OR REPLACE FUNCTION public.process_task_notification_jobs_internal_p(
  p_limit integer,
  p_now timestamptz,
  p_recipient_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_notice public.task_notifications%ROWTYPE;
  v_processed integer := 0;
  v_skipped integer := 0;
  v_retry integer := 0;
  v_sqlstate text;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500
    OR p_now IS NULL THEN
    RAISE EXCEPTION 'Elige un lote de novedades válido' USING ERRCODE = '22023';
  END IF;

  FOR v_notice IN
    SELECT notice.*
    FROM public.task_notifications AS notice
    WHERE notice.state IN ('pending', 'retry_wait')
      AND notice.available_at <= p_now
      AND notice.occurred_at > p_now - interval '90 days'
      AND (p_recipient_user_id IS NULL
        OR notice.recipient_user_id = p_recipient_user_id)
    ORDER BY notice.available_at, notice.occurred_at, notice.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM public.board_memberships AS membership
        JOIN public.boards AS board
          ON board.id = membership.board_id
          AND board.active_generation_id = v_notice.generation_id
            AND public.task_notification_matches_active_generation_epoch_p(
              v_notice.board_id, v_notice.generation_id,
              v_notice.generation_notification_epoch
            )
        WHERE membership.id = v_notice.recipient_membership_id
          AND membership.board_id = v_notice.board_id
          AND membership.user_id = v_notice.recipient_user_id
          AND membership.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(membership.user_id)
          AND NOT EXISTS (
            SELECT 1 FROM public.board_recoverable_deletions AS deletion
            WHERE deletion.board_id = board.id
          )
      ) THEN
        UPDATE public.task_notifications AS notice
        SET state = 'delivered',
            delivered_at = coalesce(notice.delivered_at, p_now),
            attempt_count = notice.attempt_count + 1,
            last_error_code = NULL
        WHERE notice.id = v_notice.id;
        v_processed := v_processed + 1;
      ELSE
        UPDATE public.task_notifications AS notice
        SET state = 'skipped',
            delivered_at = NULL,
            attempt_count = notice.attempt_count + 1,
            last_error_code = NULL
        WHERE notice.id = v_notice.id;
        v_skipped := v_skipped + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      UPDATE public.task_notifications AS notice
      SET state = 'retry_wait',
          attempt_count = notice.attempt_count + 1,
          available_at = p_now + pg_catalog.make_interval(secs =>
            LEAST(3600::numeric, 30 * pg_catalog.power(2::numeric,
              LEAST(notice.attempt_count, 7)))::double precision
          ),
          last_error_code = v_sqlstate
      WHERE notice.id = v_notice.id;
      v_retry := v_retry + 1;
    END;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'processed', 'delivered', v_processed,
    'skipped', v_skipped, 'retry_wait', v_retry
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_my_task_notifications_p(
  p_filter text DEFAULT 'all',
  p_limit integer DEFAULT 30,
  p_before_occurred_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_items jsonb;
  v_count integer;
  v_has_more boolean;
  v_unread_count integer;
  v_next_cursor jsonb := NULL;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF p_filter IS NULL OR p_filter NOT IN ('all', 'unread')
    OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR ((p_before_occurred_at IS NULL) <> (p_before_id IS NULL)) THEN
    RAISE EXCEPTION 'Elige una página de novedades válida' USING ERRCODE = '22023';
  END IF;

  -- A separate, repeatable pass drains this caller's durable queue. A failed
  -- transaction leaves work pending for this request or the service worker.
  PERFORM public.process_task_notification_jobs_internal_p(
    100, pg_catalog.clock_timestamp(), auth.uid()
  );

  SELECT count(*)::integer INTO v_unread_count
  FROM public.task_notifications AS notice
  JOIN public.board_memberships AS recipient
    ON recipient.id = notice.recipient_membership_id
    AND recipient.board_id = notice.board_id
    AND recipient.user_id = auth.uid()
    AND recipient.revoked_at IS NULL
  JOIN public.boards AS board
    ON board.id = notice.board_id
    AND board.active_generation_id = notice.generation_id
      AND public.task_notification_matches_active_generation_epoch_p(
        notice.board_id, notice.generation_id,
        notice.generation_notification_epoch
      )
  WHERE notice.recipient_user_id = auth.uid()
    AND notice.state = 'delivered' AND notice.read_at IS NULL
    AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND public.is_enabled_application_identity_p(auth.uid())
    AND public.is_board_member(board.id);

  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', page.id,
    'occurred_at', page.occurred_at,
    'actor_name', page.actor_name,
    'reason_codes', page.reason_codes,
    'task_title', CASE WHEN page.target_available THEN page.task_title ELSE NULL END,
    'unavailable', NOT page.target_available,
    'read_at', page.read_at
  ) ORDER BY page.occurred_at DESC, page.id DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT notice.id, notice.occurred_at, notice.actor_name,
      notice.reason_codes, notice.read_at,
      task.title AS task_title,
      task.id IS NOT NULL AND column_row.id IS NOT NULL
        AND (notice.comment_id IS NULL OR comment_row.id IS NOT NULL)
        AS target_available
    FROM public.task_notifications AS notice
    JOIN public.board_memberships AS recipient
      ON recipient.id = notice.recipient_membership_id
      AND recipient.board_id = notice.board_id
      AND recipient.user_id = auth.uid()
      AND recipient.revoked_at IS NULL
    JOIN public.boards AS board
      ON board.id = notice.board_id
      AND board.active_generation_id = notice.generation_id
        AND public.task_notification_matches_active_generation_epoch_p(
          notice.board_id, notice.generation_id,
          notice.generation_notification_epoch
        )
    LEFT JOIN public.tasks AS task
      ON task.id = notice.task_id
    LEFT JOIN public.columns AS column_row
      ON column_row.id = task.column_id
      AND column_row.board_id = board.id
      AND column_row.generation_id = board.active_generation_id
    LEFT JOIN public.task_comments AS comment_row
      ON comment_row.id = notice.comment_id
      AND comment_row.task_id = notice.task_id
      AND comment_row.deleted_at IS NULL
    WHERE notice.recipient_user_id = auth.uid()
      AND notice.state = 'delivered'
      AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
      AND (p_filter = 'all' OR notice.read_at IS NULL)
      AND (p_before_occurred_at IS NULL
        OR (notice.occurred_at, notice.id) < (p_before_occurred_at, p_before_id))
      AND NOT EXISTS (
        SELECT 1 FROM public.board_recoverable_deletions AS deletion
        WHERE deletion.board_id = board.id
      )
      AND public.is_enabled_application_identity_p(auth.uid())
      AND public.is_board_member(board.id)
    ORDER BY notice.occurred_at DESC, notice.id DESC
    LIMIT p_limit + 1
  ) AS page;

  v_count := pg_catalog.jsonb_array_length(v_items);
  v_has_more := v_count > p_limit;
  IF v_has_more THEN
    v_items := v_items - p_limit;
    v_next_cursor := pg_catalog.jsonb_build_object(
      'occurred_at', v_items->(p_limit - 1)->>'occurred_at',
      'id', v_items->(p_limit - 1)->>'id'
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available', 'items', v_items,
    'unread_count', coalesce(v_unread_count, 0),
    'has_more', v_has_more, 'next_cursor', v_next_cursor,
    'retention_days', 90
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_task_notification_target_p(p_notification_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_target record;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_notification_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.slug, task.id AS task_id, notice.comment_id,
    comment_row.id AS visible_comment_id
  INTO v_target
  FROM public.task_notifications AS notice
  JOIN public.board_memberships AS recipient
    ON recipient.id = notice.recipient_membership_id
    AND recipient.board_id = notice.board_id
    AND recipient.user_id = auth.uid()
    AND recipient.revoked_at IS NULL
  JOIN public.boards AS board
    ON board.id = notice.board_id
    AND board.active_generation_id = notice.generation_id
      AND public.task_notification_matches_active_generation_epoch_p(
        notice.board_id, notice.generation_id,
        notice.generation_notification_epoch
      )
  JOIN public.columns AS column_row
    ON column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  JOIN public.tasks AS task
    ON task.id = notice.task_id AND task.column_id = column_row.id
  LEFT JOIN public.task_comments AS comment_row
    ON comment_row.id = notice.comment_id
    AND comment_row.task_id = notice.task_id
    AND comment_row.deleted_at IS NULL
  WHERE notice.id = p_notification_id
    AND notice.recipient_user_id = auth.uid()
    AND notice.state = 'delivered'
    AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
    AND (notice.comment_id IS NULL OR comment_row.id IS NOT NULL)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = notice.task_id AND deletion.state IN ('deleted', 'purged')
    )
    AND public.is_enabled_application_identity_p(auth.uid())
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available', 'slug', v_target.slug,
    'task_id', v_target.task_id, 'comment_id', v_target.comment_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_my_task_notification_read_p(p_notification_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_notification_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT notice.board_id INTO v_board_id
  FROM public.task_notifications AS notice
  JOIN public.board_memberships AS recipient
    ON recipient.id = notice.recipient_membership_id
    AND recipient.board_id = notice.board_id
    AND recipient.user_id = auth.uid()
    AND recipient.revoked_at IS NULL
  JOIN public.boards AS board
    ON board.id = notice.board_id
    AND board.active_generation_id = notice.generation_id
      AND public.task_notification_matches_active_generation_epoch_p(
        notice.board_id, notice.generation_id,
        notice.generation_notification_epoch
      )
  WHERE notice.id = p_notification_id
    AND notice.recipient_user_id = auth.uid()
    AND notice.state = 'delivered'
    AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND public.is_enabled_application_identity_p(auth.uid())
    AND public.is_board_member(board.id)
  FOR UPDATE OF notice, recipient, board;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  UPDATE public.task_notifications AS notice
  SET read_at = coalesce(notice.read_at, pg_catalog.clock_timestamp())
  WHERE notice.id = p_notification_id;

  RETURN pg_catalog.jsonb_build_object('status', 'confirmed');
END;
$$;

CREATE OR REPLACE FUNCTION public.mark_my_task_notifications_batch_p(
  p_operation_id uuid,
  p_notification_ids uuid[],
  p_retry_failed boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_notification_ids uuid[];
  v_payload_hash bytea;
  v_receipt public.task_notification_batch_receipts%ROWTYPE;
  v_is_new boolean;
  v_notification_id uuid;
  v_previous jsonb;
  v_result text;
  v_read_at timestamptz;
  v_items jsonb := '[]'::jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR NOT public.is_enabled_application_identity_p(v_actor_id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF p_operation_id IS NULL OR p_notification_ids IS NULL
    OR cardinality(p_notification_ids) < 1 OR cardinality(p_notification_ids) > 100
    OR array_position(p_notification_ids, NULL) IS NOT NULL
    OR p_retry_failed IS NULL
    OR EXISTS (
      SELECT requested.notification_id
      FROM pg_catalog.unnest(p_notification_ids) AS requested(notification_id)
      GROUP BY requested.notification_id HAVING count(*) > 1
    ) THEN
    RAISE EXCEPTION 'Elige un lote de novedades válido' USING ERRCODE = '22023';
  END IF;

  SELECT pg_catalog.array_agg(requested.notification_id ORDER BY requested.notification_id)
  INTO v_notification_ids
  FROM pg_catalog.unnest(p_notification_ids) AS requested(notification_id);
  v_payload_hash := public.task_capture_payload_hash(pg_catalog.jsonb_build_object(
    'action', 'mark_task_notifications_read',
    'notification_ids', pg_catalog.to_jsonb(v_notification_ids)
  ));

  INSERT INTO public.task_notification_batch_receipts(
    actor_id, operation_id, payload_hash, notification_ids
  ) VALUES (
    v_actor_id, p_operation_id, v_payload_hash, v_notification_ids
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  v_is_new := FOUND;

  IF v_is_new AND p_retry_failed THEN
    DELETE FROM public.task_notification_batch_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'not_found', 'operation_id', p_operation_id
    );
  END IF;

  IF NOT v_is_new THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_notification_batch_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'processing', 'operation_id', p_operation_id
      );
    END IF;
    IF v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'Esta operación de novedades ya se usó con otros elementos'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= pg_catalog.clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'processing', 'operation_id', p_operation_id
      );
    END IF;
    IF NOT p_retry_failed OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_receipt.item_results) AS item
      WHERE item->>'result' = 'failed'
    ) THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'confirmed',
        'operation_id', p_operation_id,
        'items', v_receipt.item_results
      );
    END IF;
  END IF;

  FOREACH v_notification_id IN ARRAY v_notification_ids LOOP
    IF NOT v_is_new THEN
      SELECT item INTO v_previous
      FROM pg_catalog.jsonb_array_elements(v_receipt.item_results) AS item
      WHERE item->>'id' = v_notification_id::text;
      IF v_previous->>'result' IS DISTINCT FROM 'failed' THEN
        v_items := v_items || pg_catalog.jsonb_build_array(v_previous);
        CONTINUE;
      END IF;
    END IF;

    v_result := 'unavailable';
    BEGIN
      SELECT notice.read_at INTO v_read_at
      FROM public.task_notifications AS notice
      JOIN public.board_memberships AS recipient
        ON recipient.id = notice.recipient_membership_id
        AND recipient.board_id = notice.board_id
        AND recipient.user_id = v_actor_id
        AND recipient.revoked_at IS NULL
      JOIN public.boards AS board
        ON board.id = notice.board_id
        AND board.active_generation_id = notice.generation_id
          AND public.task_notification_matches_active_generation_epoch_p(
            notice.board_id, notice.generation_id,
            notice.generation_notification_epoch
          )
      WHERE notice.id = v_notification_id
        AND notice.recipient_user_id = v_actor_id
        AND notice.state = 'delivered'
        AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
        AND NOT EXISTS (
          SELECT 1 FROM public.board_recoverable_deletions AS deletion
          WHERE deletion.board_id = board.id
        )
        AND public.is_enabled_application_identity_p(v_actor_id)
        AND public.is_board_member(board.id)
      FOR UPDATE OF notice, recipient, board;

      IF FOUND THEN
        IF v_read_at IS NOT NULL THEN
          v_result := 'already_read';
        ELSE
          UPDATE public.task_notifications AS notice
          SET read_at = pg_catalog.clock_timestamp()
          WHERE notice.id = v_notification_id AND notice.read_at IS NULL;
          IF FOUND THEN
            v_result := 'marked';
          ELSE
            v_result := 'already_read';
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- A single row failure must not roll back successful results for the
      -- rest of the frozen batch. Keep the database error private.
      v_result := 'failed';
    END;

    v_items := v_items || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('id', v_notification_id, 'result', v_result)
    );
  END LOOP;

  UPDATE public.task_notification_batch_receipts AS receipt
  SET item_results = v_items, result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.process_task_notification_jobs_internal_p(integer, timestamptz, uuid) FROM PUBLIC, anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.list_my_task_notifications_p(text, integer, timestamptz, uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_task_notifications_p(text, integer, timestamptz, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.get_my_task_notification_target_p(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_task_notification_target_p(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.mark_my_task_notification_read_p(uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_my_task_notification_read_p(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.mark_my_task_notifications_batch_p(uuid, uuid[], boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_my_task_notifications_batch_p(uuid, uuid[], boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
