-- Closed Google sign-in and application admission.
-- This migration is additive: legacy anonymous data remains present but ownerless
-- rows become private and inaccessible until an explicit ownership migration.
BEGIN;

ALTER TABLE public.boards
  ADD COLUMN owner_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT;
CREATE INDEX idx_boards_owner_id ON public.boards(owner_id) WHERE owner_id IS NOT NULL;

CREATE TABLE public.application_access (
  email text PRIMARY KEY,
  auth_user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
  google_subject text UNIQUE,
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'active', 'suspended')),
  is_admin boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT application_access_email_normalized CHECK (
    email = lower(btrim(email))
    AND length(email) BETWEEN 3 AND 254
    AND email ~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
  ),
  CONSTRAINT application_access_identity_pair CHECK (
    (auth_user_id IS NULL) = (google_subject IS NULL)
  ),
  CONSTRAINT application_access_active_identity CHECK (
    state <> 'active' OR auth_user_id IS NOT NULL
  ),
  CONSTRAINT application_access_pending_identity CHECK (
    state <> 'pending' OR auth_user_id IS NULL
  )
);
ALTER TABLE public.application_access ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.application_access FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.application_access TO service_role;

CREATE OR REPLACE FUNCTION public.current_google_identity()
RETURNS TABLE(email text, google_subject text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, auth, public, pg_temp
AS $$
  SELECT
    lower(identity.identity_data ->> 'email'),
    identity.provider_id
  FROM auth.users AS auth_user
  JOIN auth.identities AS identity ON identity.user_id = auth_user.id
  WHERE auth_user.id = auth.uid()
    AND auth_user.email_confirmed_at IS NOT NULL
    AND identity.provider = 'google'
    AND identity.provider_id <> ''
    AND lower(identity.identity_data ->> 'email') = lower(auth_user.email)
    AND coalesce((identity.identity_data ->> 'email_verified')::boolean, false)
  ORDER BY identity.last_sign_in_at DESC NULLS LAST, identity.created_at DESC
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_application_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, auth, public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.application_access AS access
    JOIN public.current_google_identity() AS identity
      ON identity.google_subject = access.google_subject
    WHERE access.auth_user_id = auth.uid()
      AND access.state = 'active'
  );
$$;

CREATE OR REPLACE FUNCTION public.is_application_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, auth, public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.application_access AS access
    JOIN public.current_google_identity() AS identity
      ON identity.google_subject = access.google_subject
    WHERE access.auth_user_id = auth.uid()
      AND access.state = 'active'
      AND access.is_admin
  );
$$;

CREATE OR REPLACE FUNCTION public.resolve_application_access()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, auth, public, pg_temp
AS $$
DECLARE
  v_identity record;
  v_access public.application_access%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN jsonb_build_object('status', 'signed_out', 'is_admin', false);
  END IF;

  SELECT * INTO v_identity FROM public.current_google_identity();
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'google_required', 'is_admin', false);
  END IF;

  SELECT * INTO v_access
  FROM public.application_access AS access
  WHERE access.auth_user_id = auth.uid()
  FOR UPDATE;

  IF FOUND THEN
    IF v_access.google_subject <> v_identity.google_subject THEN
      RETURN jsonb_build_object('status', 'not_enabled', 'is_admin', false);
    END IF;
    IF v_access.state = 'suspended' THEN
      RETURN jsonb_build_object('status', 'suspended', 'is_admin', false);
    END IF;
    IF v_access.state = 'active' THEN
      RETURN jsonb_build_object('status', 'active', 'is_admin', v_access.is_admin);
    END IF;
    RETURN jsonb_build_object('status', 'not_enabled', 'is_admin', false);
  END IF;

  SELECT * INTO v_access
  FROM public.application_access AS access
  WHERE access.email = v_identity.email
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_enabled', 'is_admin', false);
  END IF;
  IF v_access.state = 'suspended' THEN
    RETURN jsonb_build_object('status', 'suspended', 'is_admin', false);
  END IF;
  IF v_access.state <> 'pending'
    OR (v_access.auth_user_id IS NOT NULL AND v_access.auth_user_id <> auth.uid())
    OR (v_access.google_subject IS NOT NULL AND v_access.google_subject <> v_identity.google_subject) THEN
    RETURN jsonb_build_object('status', 'not_enabled', 'is_admin', false);
  END IF;

  UPDATE public.application_access AS access
  SET auth_user_id = auth.uid(),
      google_subject = v_identity.google_subject,
      state = 'active',
      updated_at = now()
  WHERE access.email = v_identity.email
    AND access.state = 'pending'
    AND access.auth_user_id IS NULL
  RETURNING * INTO v_access;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_enabled', 'is_admin', false);
  END IF;

  RETURN jsonb_build_object('status', 'active', 'is_admin', v_access.is_admin);
END;
$$;

CREATE OR REPLACE FUNCTION public.require_application_admin()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'Administrator access required' USING ERRCODE = '42501';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_access()
RETURNS TABLE(email text, state text, is_admin boolean, linked boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  PERFORM public.require_application_admin();
  RETURN QUERY
    SELECT access.email, access.state, access.is_admin, access.auth_user_id IS NOT NULL
    FROM public.application_access AS access
    ORDER BY access.email;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_enable_access(p_email text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_email text := lower(btrim(p_email));
BEGIN
  PERFORM public.require_application_admin();
  IF v_email IS NULL OR length(v_email) > 254
    OR v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Enter a valid Google email address' USING ERRCODE = '23514';
  END IF;

  INSERT INTO public.application_access(email, state)
  VALUES (v_email, 'pending')
  ON CONFLICT (email) DO UPDATE SET
    state = CASE
      WHEN public.application_access.state = 'suspended'
        AND public.application_access.auth_user_id IS NOT NULL THEN 'active'
      WHEN public.application_access.state = 'suspended' THEN 'pending'
      ELSE public.application_access.state
    END,
    updated_at = now();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_remove_pending_access(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_removed boolean;
BEGIN
  PERFORM public.require_application_admin();
  DELETE FROM public.application_access AS access
  WHERE access.email = lower(btrim(p_email))
    AND access.state = 'pending'
    AND access.auth_user_id IS NULL;
  v_removed := FOUND;
  RETURN v_removed;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_suspend_access(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_access public.application_access%ROWTYPE;
BEGIN
  PERFORM public.require_application_admin();
  LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO v_access
  FROM public.application_access AS access
  WHERE access.email = lower(btrim(p_email))
    AND access.auth_user_id IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF v_access.is_admin AND (
    SELECT count(*) FROM public.application_access AS active_admin
    WHERE active_admin.is_admin AND active_admin.state = 'active'
  ) <= 1 THEN
    RAISE EXCEPTION 'At least one active administrator must remain' USING ERRCODE = '23514';
  END IF;

  UPDATE public.application_access AS access
  SET state = 'suspended', updated_at = now()
  WHERE access.email = v_access.email;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_my_boards()
RETURNS SETOF public.boards
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.*
  FROM public.boards AS board
  WHERE board.owner_id = auth.uid()
    AND public.is_application_user()
  ORDER BY board.updated_at DESC, board.id;
$$;

CREATE OR REPLACE FUNCTION public.guard_board_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT public.is_application_user() THEN
      RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
    END IF;
    IF NEW.owner_id IS NOT NULL AND NEW.owner_id <> auth.uid() THEN
      RAISE EXCEPTION 'A board must belong to its creator' USING ERRCODE = '42501';
    END IF;
    NEW.owner_id := auth.uid();
    RETURN NEW;
  END IF;

  IF NOT public.is_application_user()
    OR OLD.owner_id IS DISTINCT FROM auth.uid()
    OR (TG_OP = 'UPDATE' AND NEW.owner_id IS DISTINCT FROM OLD.owner_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_board_child_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_old_board_id uuid;
  v_new_board_id uuid;
  v_old_owner_id uuid;
  v_new_owner_id uuid;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    IF TG_TABLE_NAME = 'columns' THEN
      v_old_board_id := OLD.board_id;
    ELSE
      SELECT column_row.board_id INTO v_old_board_id
      FROM public.columns AS column_row WHERE column_row.id = OLD.column_id;
    END IF;
  END IF;

  IF TG_OP <> 'DELETE' THEN
    IF TG_TABLE_NAME = 'columns' THEN
      v_new_board_id := NEW.board_id;
    ELSE
      SELECT column_row.board_id INTO v_new_board_id
      FROM public.columns AS column_row WHERE column_row.id = NEW.column_id;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' AND v_old_board_id IS DISTINCT FROM v_new_board_id THEN
    RAISE EXCEPTION 'Content cannot move between boards' USING ERRCODE = '42501';
  END IF;

  IF TG_OP <> 'INSERT' THEN
    SELECT board.owner_id INTO v_old_owner_id
    FROM public.boards AS board WHERE board.id = v_old_board_id;
    IF NOT FOUND AND TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
      RETURN OLD;
    END IF;
  END IF;

  IF TG_OP <> 'DELETE' THEN
    SELECT board.owner_id INTO v_new_owner_id
    FROM public.boards AS board WHERE board.id = v_new_board_id;
  END IF;

  IF NOT public.is_application_user()
    OR (TG_OP <> 'INSERT' AND v_old_owner_id IS DISTINCT FROM auth.uid())
    OR (TG_OP <> 'DELETE' AND v_new_owner_id IS DISTINCT FROM auth.uid()) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS boards_require_owner ON public.boards;
CREATE TRIGGER boards_require_owner
  BEFORE INSERT OR UPDATE OR DELETE ON public.boards
  FOR EACH ROW EXECUTE FUNCTION public.guard_board_owner();

DROP TRIGGER IF EXISTS columns_require_board_owner ON public.columns;
CREATE TRIGGER columns_require_board_owner
  BEFORE INSERT OR UPDATE OR DELETE ON public.columns
  FOR EACH ROW EXECUTE FUNCTION public.guard_board_child_owner();

DROP TRIGGER IF EXISTS tasks_require_board_owner ON public.tasks;
CREATE TRIGGER tasks_require_board_owner
  BEFORE INSERT OR UPDATE OR DELETE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.guard_board_child_owner();

DROP POLICY IF EXISTS "boards_select" ON public.boards;
DROP POLICY IF EXISTS "columns_select" ON public.columns;
DROP POLICY IF EXISTS "tasks_select" ON public.tasks;
CREATE POLICY "boards_select_enabled_owner" ON public.boards
  FOR SELECT TO authenticated
  USING (owner_id = (SELECT auth.uid()) AND public.is_application_user());
CREATE POLICY "columns_select_enabled_owner" ON public.columns
  FOR SELECT TO authenticated
  USING (
    public.is_application_user()
    AND EXISTS (
      SELECT 1 FROM public.boards AS board
      WHERE board.id = columns.board_id AND board.owner_id = (SELECT auth.uid())
    )
  );
CREATE POLICY "tasks_select_enabled_owner" ON public.tasks
  FOR SELECT TO authenticated
  USING (
    public.is_application_user()
    AND EXISTS (
      SELECT 1 FROM public.columns AS column_row
      JOIN public.boards AS board ON board.id = column_row.board_id
      WHERE column_row.id = tasks.column_id AND board.owner_id = (SELECT auth.uid())
    )
  );

CREATE OR REPLACE FUNCTION public.get_board_p(p_slug text)
RETURNS SETOF public.boards
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.* FROM public.boards AS board
  WHERE board.slug = p_slug
    AND board.owner_id = auth.uid()
    AND public.is_application_user();
$$;

CREATE OR REPLACE FUNCTION public.get_full_board_p(p_slug text)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
BEGIN
  IF NOT public.is_application_user() THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND board.owner_id = auth.uid();
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN json_build_object(
    'board', row_to_json(v_board),
    'columns', COALESCE(
      (
        SELECT json_agg(
          json_build_object(
            'id', column_row.id,
            'board_id', column_row.board_id,
            'title', column_row.title,
            'position', column_row.position,
            'is_collapsed', column_row.is_collapsed,
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
      ),
      '[]'::json
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_columns_p(p_board_id uuid)
RETURNS SETOF public.columns
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT column_row.*
  FROM public.columns AS column_row
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE board.id = p_board_id
    AND board.owner_id = auth.uid()
    AND public.is_application_user()
  ORDER BY column_row.position;
$$;

CREATE OR REPLACE FUNCTION public.get_tasks_by_board_p(p_board_id uuid)
RETURNS SETOF public.tasks
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT task_row.*
  FROM public.tasks AS task_row
  JOIN public.columns AS column_row ON column_row.id = task_row.column_id
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE board.id = p_board_id
    AND board.owner_id = auth.uid()
    AND public.is_application_user()
  ORDER BY task_row.position;
$$;

CREATE OR REPLACE FUNCTION public.can_access_board_topic(p_topic text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.is_application_user()
    AND p_topic ~ '^board(-sync)?:[0-9a-fA-F-]{36}$'
    AND EXISTS (
      SELECT 1 FROM public.boards AS board
      WHERE board.id = split_part(p_topic, ':', 2)::uuid
        AND board.owner_id = auth.uid()
    );
$$;

ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "openkanban_private_board_read" ON realtime.messages;
DROP POLICY IF EXISTS "openkanban_private_board_send" ON realtime.messages;
CREATE POLICY "openkanban_private_board_read" ON realtime.messages
  FOR SELECT TO authenticated
  USING (
    extension IN ('broadcast', 'presence')
    AND public.can_access_board_topic(realtime.topic())
  );
CREATE POLICY "openkanban_private_board_send" ON realtime.messages
  FOR INSERT TO authenticated
  WITH CHECK (
    extension IN ('broadcast', 'presence')
    AND public.can_access_board_topic(realtime.topic())
  );

REVOKE ALL ON SCHEMA public FROM PUBLIC, anon;
GRANT USAGE ON SCHEMA public TO authenticated, service_role;
REVOKE ALL ON TABLE public.boards, public.columns, public.tasks FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.boards, public.columns, public.tasks TO authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.is_application_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_application_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_application_access() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_access() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_enable_access(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_pending_access(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_suspend_access(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_boards() TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_access_board_topic(text) TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_board_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_full_board_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_board_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_board_p(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_columns_p(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_column_p(text, uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_column_p(text, uuid, text, integer, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_column_p(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_column_positions_p(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.batch_toggle_columns_collapse_p(text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_tasks_by_board_p(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_task_p(text, uuid, text, text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.edit_task_fields_p(text, uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_task_positions_p(text, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_task_p(text, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
