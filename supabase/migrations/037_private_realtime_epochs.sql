-- Realtime is an invalidation transport. The private board data stays behind
-- the existing authorized read RPCs, while each authorization change rotates
-- the topics that future broadcasts can use.
BEGIN;

ALTER TABLE public.boards
  ADD COLUMN auth_epoch bigint NOT NULL DEFAULT 1,
  ADD CONSTRAINT boards_auth_epoch_positive CHECK (auth_epoch > 0);

CREATE OR REPLACE FUNCTION public.guard_board_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_locked_actor uuid;
  v_recoverable boolean;
  v_service_role boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT access.auth_user_id INTO v_locked_actor
    FROM public.application_access AS access
    WHERE access.auth_user_id = auth.uid()
    FOR SHARE;
    IF NOT FOUND OR NOT public.is_application_user() THEN
      RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
    END IF;
    IF NEW.owner_id IS NOT NULL AND NEW.owner_id <> auth.uid() THEN
      RAISE EXCEPTION 'A board must belong to its creator' USING ERRCODE = '42501';
    END IF;
    NEW.owner_id := auth.uid();
    NEW.name := btrim(NEW.name);
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_service_role := current_setting('request.jwt.claim.role', true) = 'service_role'
      OR current_user = 'service_role';
    IF v_service_role AND EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = OLD.id
        AND recovery.expires_at <= clock_timestamp()
    ) THEN
      RETURN OLD;
    END IF;
    IF NOT public.is_board_owner(OLD.id) THEN
      RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.slug IS DISTINCT FROM OLD.slug THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  -- Internal invalidation updates change only auth_epoch. That field carries
  -- no board authority and must remain rotatable after the former owner is
  -- revoked; every product field continues through the owner guard below.
  IF NEW.auth_epoch IS DISTINCT FROM OLD.auth_epoch
    AND (pg_catalog.to_jsonb(NEW) - 'auth_epoch')
      IS NOT DISTINCT FROM (pg_catalog.to_jsonb(OLD) - 'auth_epoch') THEN
    RETURN NEW;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS recovery
    WHERE recovery.board_id = OLD.id
  ) INTO v_recoverable;
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    IF v_recoverable
      AND public.is_enabled_application_identity_p(NEW.owner_id)
      AND (
        public.is_application_admin()
        OR (
          auth.uid() = NEW.owner_id
          AND EXISTS (
            SELECT 1 FROM public.board_recoverable_deletions AS recovery
            WHERE recovery.board_id = OLD.id
              AND recovery.recovery_owner_id = auth.uid()
          )
        )
      ) THEN
      NULL;
    ELSIF (NOT public.is_board_owner(OLD.id) AND NOT public.is_application_admin())
      OR NOT EXISTS (
        SELECT 1 FROM public.board_memberships AS member
        WHERE member.board_id = OLD.id
          AND member.user_id = NEW.owner_id
          AND member.role = 'collaborator'
          AND member.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(member.user_id)
      ) THEN
      RAISE EXCEPTION 'Choose a current enabled board member as owner'
        USING ERRCODE = '42501';
    END IF;
  ELSIF NOT public.is_board_owner(OLD.id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  NEW.name := btrim(NEW.name);
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.board_realtime_topic(
  p_board_id uuid,
  p_auth_epoch bigint,
  p_channel text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, extensions, pg_temp
AS $$
  SELECT CASE p_channel
    WHEN 'sync' THEN 'board-sync:'
    WHEN 'presence' THEN 'board-presence:'
    ELSE NULL
  END || pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(
        p_board_id::text || ':' || p_auth_epoch::text || ':' || p_channel,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  WHERE p_board_id IS NOT NULL AND p_auth_epoch IS NOT NULL
    AND p_auth_epoch > 0 AND p_channel IN ('sync', 'presence');
$$;
REVOKE ALL ON FUNCTION public.board_realtime_topic(uuid, bigint, text)
  FROM PUBLIC, anon, authenticated;

DROP FUNCTION public.get_board_p(text);
CREATE FUNCTION public.get_board_p(p_slug text)
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  time_zone text,
  role text,
  created_at timestamptz,
  updated_at timestamptz,
  today date,
  auth_epoch bigint,
  sync_topic text,
  presence_topic text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.id, board.slug, board.name, board.time_zone,
    membership.role, board.created_at, board.updated_at,
    public.board_calendar_day(board.time_zone, statement_timestamp()),
    board.auth_epoch,
    public.board_realtime_topic(board.id, board.auth_epoch, 'sync'),
    public.board_realtime_topic(board.id, board.auth_epoch, 'presence')
  FROM public.boards AS board
  JOIN public.board_memberships AS membership ON membership.board_id = board.id
  WHERE board.slug = p_slug AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL AND public.is_board_member(board.id);
$$;
REVOKE ALL ON FUNCTION public.get_board_p(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_board_p(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.can_access_board_topic(p_topic text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT p_topic IS NOT NULL
    AND public.is_application_user()
    AND EXISTS (
      SELECT 1
      FROM public.boards AS board
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
      WHERE membership.user_id = auth.uid()
        AND membership.revoked_at IS NULL
        AND public.is_board_member(board.id)
        AND p_topic IN (
          public.board_realtime_topic(board.id, board.auth_epoch, 'sync'),
          public.board_realtime_topic(board.id, board.auth_epoch, 'presence')
        )
    );
$$;
REVOKE ALL ON FUNCTION public.can_access_board_topic(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_access_board_topic(text) TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_class AS relation
    JOIN pg_catalog.pg_namespace AS schema
      ON schema.oid = relation.relnamespace
    WHERE schema.nspname = 'realtime'
      AND relation.relname = 'messages'
      AND relation.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'Supabase Realtime must provide RLS on realtime.messages';
  END IF;
END;
$$;

DROP POLICY IF EXISTS "openkanban_private_board_read" ON realtime.messages;
DROP POLICY IF EXISTS "openkanban_private_board_send" ON realtime.messages;
CREATE POLICY "openkanban_private_board_read" ON realtime.messages
  FOR SELECT TO authenticated
  USING (
    extension IN ('broadcast', 'presence')
    AND public.can_access_board_topic(realtime.topic())
  );
-- Presence remains client-owned. Broadcast signals can only enter through the
-- database-side realtime.send() primitive below.
CREATE POLICY "openkanban_private_board_presence_send" ON realtime.messages
  FOR INSERT TO authenticated
  WITH CHECK (
    extension = 'presence'
    AND public.can_access_board_topic(realtime.topic())
  );

CREATE FUNCTION public.rotate_board_realtime_epoch(
  p_board_id uuid,
  p_event text DEFAULT 'revalidate'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, realtime, pg_temp
AS $$
DECLARE
  v_auth_epoch bigint;
BEGIN
  IF p_event NOT IN ('revalidate', 'board-deleted') THEN
    RAISE EXCEPTION 'Unsupported Realtime authorization event';
  END IF;

  SELECT board.auth_epoch INTO v_auth_epoch
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  PERFORM realtime.send(
    '{}'::jsonb,
    p_event,
    public.board_realtime_topic(p_board_id, v_auth_epoch, 'sync'),
    true
  );
  UPDATE public.boards AS board
  SET auth_epoch = board.auth_epoch + 1
  WHERE board.id = p_board_id;
END;
$$;
REVOKE ALL ON FUNCTION public.rotate_board_realtime_epoch(uuid, text)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.publish_board_realtime_sync(p_board_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, realtime, pg_temp
AS $$
DECLARE
  v_auth_epoch bigint;
BEGIN
  -- This lock serializes data signals with revocation/epoch rotation. If a
  -- write wins the lock first, its old-topic signal is pre-revocation; if the
  -- revoke wins first, the write can only target the new topic.
  SELECT board.auth_epoch INTO v_auth_epoch
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND OR EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS recovery
    WHERE recovery.board_id = p_board_id
  ) THEN
    RETURN;
  END IF;

  PERFORM realtime.send(
    '{}'::jsonb,
    'sync',
    public.board_realtime_topic(p_board_id, v_auth_epoch, 'sync'),
    true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.publish_board_realtime_sync(uuid)
  FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.rotate_board_realtime_epoch_after_membership_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.board_id ELSE NEW.board_id END;
  PERFORM public.rotate_board_realtime_epoch(v_board_id);
  RETURN NULL;
END;
$$;
CREATE TRIGGER board_membership_rotates_realtime_epoch
  AFTER INSERT OR UPDATE OR DELETE ON public.board_memberships
  FOR EACH ROW
  EXECUTE FUNCTION public.rotate_board_realtime_epoch_after_membership_change();

CREATE FUNCTION public.rotate_board_realtime_epoch_after_owner_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
    PERFORM public.rotate_board_realtime_epoch(NEW.id);
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER board_owner_rotates_realtime_epoch
  AFTER UPDATE OF owner_id ON public.boards
  FOR EACH ROW
  EXECUTE FUNCTION public.rotate_board_realtime_epoch_after_owner_change();

CREATE FUNCTION public.rotate_board_realtime_epoch_after_access_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  IF OLD.state IS NOT DISTINCT FROM NEW.state OR OLD.auth_user_id IS NULL THEN
    RETURN NULL;
  END IF;
  FOR v_board_id IN
    SELECT DISTINCT membership.board_id
    FROM public.board_memberships AS membership
    WHERE membership.user_id = NEW.auth_user_id
      AND membership.revoked_at IS NULL
    ORDER BY membership.board_id
  LOOP
    PERFORM public.rotate_board_realtime_epoch(v_board_id);
  END LOOP;
  RETURN NULL;
END;
$$;
CREATE TRIGGER application_access_rotates_realtime_epoch
  AFTER UPDATE OF state ON public.application_access
  FOR EACH ROW
  EXECUTE FUNCTION public.rotate_board_realtime_epoch_after_access_change();

CREATE FUNCTION public.broadcast_board_delete_and_rotate_epoch()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  PERFORM public.rotate_board_realtime_epoch(NEW.board_id, 'board-deleted');
  RETURN NEW;
END;
$$;
CREATE TRIGGER board_recoverable_deletion_broadcasts
  BEFORE INSERT ON public.board_recoverable_deletions
  FOR EACH ROW
  EXECUTE FUNCTION public.broadcast_board_delete_and_rotate_epoch();

CREATE FUNCTION public.publish_board_table_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  CASE TG_TABLE_NAME
    WHEN 'boards' THEN
      v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
      IF TG_OP = 'UPDATE'
        AND OLD.name IS NOT DISTINCT FROM NEW.name
        AND OLD.time_zone IS NOT DISTINCT FROM NEW.time_zone
        AND OLD.active_generation_id IS NOT DISTINCT FROM NEW.active_generation_id THEN
        RETURN NULL;
      END IF;
    WHEN 'tasks' THEN
      IF TG_OP = 'DELETE' THEN
        SELECT column_row.board_id INTO v_board_id
        FROM public.columns AS column_row WHERE column_row.id = OLD.column_id;
      ELSE
        SELECT column_row.board_id INTO v_board_id
        FROM public.columns AS column_row WHERE column_row.id = NEW.column_id;
      END IF;
    WHEN 'task_comment_mentions' THEN
      IF TG_OP = 'DELETE' THEN
        SELECT comment.board_id INTO v_board_id
        FROM public.task_comments AS comment WHERE comment.id = OLD.comment_id;
      ELSE
        SELECT comment.board_id INTO v_board_id
        FROM public.task_comments AS comment WHERE comment.id = NEW.comment_id;
      END IF;
    ELSE
      v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.board_id ELSE NEW.board_id END;
  END CASE;

  PERFORM public.publish_board_realtime_sync(v_board_id);
  RETURN NULL;
END;
$$;

CREATE TRIGGER boards_publish_realtime_sync
  AFTER UPDATE OR DELETE ON public.boards
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER columns_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.columns
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER tasks_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER task_comments_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.task_comments
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER task_comment_mentions_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.task_comment_mentions
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER board_invitations_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.board_invitations
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER task_deletions_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER column_deletions_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.column_deletions
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();
CREATE TRIGGER task_checklist_deletions_publish_realtime_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.task_checklist_deletions
  FOR EACH ROW EXECUTE FUNCTION public.publish_board_table_change();

-- Maintenance purges used to lock a recovery ledger row before its parent
-- board. Realtime publication shares the board lock with authorization
-- rotation, so take that lock first and let the private ledger row decide who
-- actually purges it. The operation remains idempotent across workers.
CREATE OR REPLACE FUNCTION public.purge_expired_task_internal_p(
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
  v_deletion public.task_deletions%ROWTYPE;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
BEGIN
  SELECT deletion.board_id INTO v_board_id
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = p_id;
  IF NOT FOUND THEN RETURN 'already_terminal'; END IF;

  PERFORM 1 FROM public.boards AS board
  WHERE board.id = v_board_id FOR UPDATE;
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

CREATE OR REPLACE FUNCTION public.purge_expired_tasks_p(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_task_id uuid;
  v_purged integer := 0;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'Choose a purge limit from 1 to 1000' USING ERRCODE = '22023';
  END IF;
  FOR v_task_id IN
    SELECT deletion.task_id
    FROM public.task_deletions AS deletion
    WHERE deletion.state = 'deleted'
      AND deletion.expires_at <= clock_timestamp()
    ORDER BY deletion.expires_at, deletion.task_id
    LIMIT p_limit
  LOOP
    IF public.purge_expired_task_internal_p(v_task_id, NULL) = 'purged' THEN
      v_purged := v_purged + 1;
    END IF;
  END LOOP;
  RETURN v_purged;
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_expired_column_internal_p(
  p_column_id uuid,
  p_now timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_deletion public.column_deletions%ROWTYPE;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
BEGIN
  SELECT deletion.board_id INTO v_board_id
  FROM public.column_deletions AS deletion
  WHERE deletion.column_id = p_column_id;
  IF NOT FOUND THEN RETURN 'already_terminal'; END IF;

  PERFORM 1 FROM public.boards AS board
  WHERE board.id = v_board_id FOR UPDATE;
  SELECT deletion.* INTO v_deletion
  FROM public.column_deletions AS deletion
  WHERE deletion.column_id = p_column_id
  FOR UPDATE;
  IF NOT FOUND OR v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.column_snapshot IS NULL THEN
    RETURN 'already_terminal';
  END IF;
  IF v_now < v_deletion.expires_at THEN RETURN 'too_early'; END IF;
  UPDATE public.column_deletions AS deletion
  SET column_snapshot = NULL, state = 'purged', purged_at = v_now
  WHERE deletion.column_id = p_column_id;
  RETURN 'purged';
END;
$$;

CREATE OR REPLACE FUNCTION public.purge_expired_columns_p(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_column_id uuid;
  v_purged integer := 0;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'Choose a purge limit from 1 to 1000' USING ERRCODE = '22023';
  END IF;
  FOR v_column_id IN
    SELECT deletion.column_id
    FROM public.column_deletions AS deletion
    WHERE deletion.state = 'deleted'
      AND deletion.expires_at <= clock_timestamp()
    ORDER BY deletion.expires_at, deletion.column_id
    LIMIT p_limit
  LOOP
    IF public.purge_expired_column_internal_p(v_column_id, NULL) = 'purged' THEN
      v_purged := v_purged + 1;
    END IF;
  END LOOP;
  RETURN v_purged;
END;
$$;

REVOKE ALL ON FUNCTION public.rotate_board_realtime_epoch_after_membership_change()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rotate_board_realtime_epoch_after_owner_change()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rotate_board_realtime_epoch_after_access_change()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.broadcast_board_delete_and_rotate_epoch()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.publish_board_table_change()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
