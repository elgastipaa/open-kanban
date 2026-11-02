-- Private boards have explicit membership and one visible content generation.
BEGIN;

ALTER TABLE public.boards
  ADD COLUMN name text,
  ADD COLUMN time_zone text NOT NULL DEFAULT 'UTC',
  ADD COLUMN active_generation_id uuid;

-- Existing rows are being backfilled by the migration owner, outside the
-- authenticated application path that protects runtime writes.
ALTER TABLE public.boards DISABLE TRIGGER boards_require_owner;
ALTER TABLE public.columns DISABLE TRIGGER columns_require_board_owner;

UPDATE public.boards
SET name = slug
WHERE name IS NULL;

ALTER TABLE public.boards
  ALTER COLUMN name SET NOT NULL,
  ADD CONSTRAINT boards_name_nonempty CHECK (
    name <> '' AND name = btrim(name) AND char_length(name) <= 100
  );

CREATE TABLE public.board_generations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  status text NOT NULL CHECK (status IN ('preparing', 'active', 'archived')),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (board_id, id)
);
CREATE UNIQUE INDEX board_generations_one_active_per_board
  ON public.board_generations(board_id) WHERE status = 'active';

WITH initial_generations AS (
  SELECT board.id AS board_id, gen_random_uuid() AS generation_id, board.owner_id
  FROM public.boards AS board
)
INSERT INTO public.board_generations(id, board_id, status, created_by)
SELECT generation_id, board_id, 'active', owner_id
FROM initial_generations;

UPDATE public.boards AS board
SET active_generation_id = generation.id
FROM public.board_generations AS generation
WHERE generation.board_id = board.id AND generation.status = 'active';

ALTER TABLE public.boards
  ALTER COLUMN active_generation_id SET NOT NULL,
  ADD CONSTRAINT boards_active_generation_fk
    FOREIGN KEY (id, active_generation_id)
    REFERENCES public.board_generations(board_id, id)
    DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE public.columns ADD COLUMN generation_id uuid;
UPDATE public.columns AS column_row
SET generation_id = board.active_generation_id
FROM public.boards AS board
WHERE board.id = column_row.board_id;
ALTER TABLE public.columns
  ALTER COLUMN generation_id SET NOT NULL,
  ADD CONSTRAINT columns_generation_fk
    FOREIGN KEY (board_id, generation_id)
    REFERENCES public.board_generations(board_id, id)
    ON DELETE CASCADE;
CREATE INDEX idx_columns_active_generation_position
  ON public.columns(board_id, generation_id, position);
ALTER TABLE public.columns
  ADD CONSTRAINT columns_title_nonempty CHECK (
    btrim(title) <> '' AND char_length(btrim(title)) <= 100
  ) NOT VALID,
  ADD CONSTRAINT columns_position_nonnegative CHECK (position >= 0) NOT VALID;

ALTER TABLE public.boards ENABLE TRIGGER boards_require_owner;
ALTER TABLE public.columns ENABLE TRIGGER columns_require_board_owner;

CREATE TABLE public.board_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  role text NOT NULL CHECK (role IN ('owner', 'collaborator')),
  joined_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  CHECK (revoked_at IS NULL OR revoked_at >= joined_at)
);
CREATE UNIQUE INDEX board_memberships_one_current_episode
  ON public.board_memberships(board_id, user_id) WHERE revoked_at IS NULL;
CREATE UNIQUE INDEX board_memberships_one_current_owner
  ON public.board_memberships(board_id) WHERE role = 'owner' AND revoked_at IS NULL;
CREATE INDEX board_memberships_user_current
  ON public.board_memberships(user_id, board_id) WHERE revoked_at IS NULL;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board.id, board.owner_id, 'owner'
FROM public.boards AS board
WHERE board.owner_id IS NOT NULL;

CREATE TABLE public.board_creation_requests (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL UNIQUE,
  requested_name text NOT NULL,
  requested_time_zone text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, operation_id)
);

ALTER TABLE public.board_generations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_creation_requests ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_board_member(p_board_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT p_board_id IS NOT NULL
    AND public.is_application_user()
    AND EXISTS (
      SELECT 1 FROM public.board_memberships AS membership
      WHERE membership.board_id = p_board_id
        AND membership.user_id = auth.uid()
        AND membership.revoked_at IS NULL
    );
$$;

CREATE OR REPLACE FUNCTION public.is_board_owner(p_board_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT p_board_id IS NOT NULL
    AND public.is_application_user()
    AND EXISTS (
      SELECT 1 FROM public.boards AS board
      JOIN public.board_memberships AS membership
        ON membership.board_id = board.id
      WHERE board.id = p_board_id
        AND board.owner_id = auth.uid()
        AND membership.user_id = auth.uid()
        AND membership.role = 'owner'
        AND membership.revoked_at IS NULL
    );
$$;

CREATE OR REPLACE FUNCTION public.check_board_owner_membership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_owner_id uuid;
  v_active_owner_count integer;
BEGIN
  IF TG_TABLE_NAME = 'boards' THEN
    v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
  ELSE
    v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.board_id ELSE NEW.board_id END;
  END IF;

  SELECT board.owner_id INTO v_owner_id
  FROM public.boards AS board WHERE board.id = v_board_id;
  IF NOT FOUND OR v_owner_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT count(*) INTO v_active_owner_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board_id
    AND membership.user_id = v_owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL;
  IF v_active_owner_count <> 1 THEN
    RAISE EXCEPTION 'Every owned board must have exactly one active owner membership'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER boards_owner_membership_valid
  AFTER INSERT OR UPDATE ON public.boards
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.check_board_owner_membership();
CREATE CONSTRAINT TRIGGER board_membership_owner_valid
  AFTER INSERT OR UPDATE OR DELETE ON public.board_memberships
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.check_board_owner_membership();

CREATE OR REPLACE FUNCTION public.check_active_board_generation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_active_generation_id uuid;
  v_active_count integer;
  v_pointer_status text;
BEGIN
  IF TG_TABLE_NAME = 'boards' THEN
    v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END;
  ELSE
    v_board_id := CASE WHEN TG_OP = 'DELETE' THEN OLD.board_id ELSE NEW.board_id END;
  END IF;

  SELECT board.active_generation_id INTO v_active_generation_id
  FROM public.boards AS board WHERE board.id = v_board_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT count(*) INTO v_active_count
  FROM public.board_generations AS generation
  WHERE generation.board_id = v_board_id AND generation.status = 'active';
  SELECT generation.status INTO v_pointer_status
  FROM public.board_generations AS generation
  WHERE generation.board_id = v_board_id
    AND generation.id = v_active_generation_id;
  IF v_active_count <> 1 OR v_pointer_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'Every board must point to its only active content generation'
      USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER boards_active_generation_valid
  AFTER INSERT OR UPDATE ON public.boards
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.check_active_board_generation();
CREATE CONSTRAINT TRIGGER board_generation_active_pointer_valid
  AFTER INSERT OR UPDATE OR DELETE ON public.board_generations
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.check_active_board_generation();

CREATE OR REPLACE FUNCTION public.validate_board_time_zone()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_timezone_names AS zone
    WHERE zone.name = NEW.time_zone
  ) THEN
    RAISE EXCEPTION 'Choose a valid time zone' USING ERRCODE = '22023';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER boards_validate_time_zone
  BEFORE INSERT OR UPDATE OF time_zone ON public.boards
  FOR EACH ROW EXECUTE FUNCTION public.validate_board_time_zone();

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
    NEW.name := btrim(NEW.name);
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    IF NOT public.is_board_owner(OLD.id) THEN
      RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NOT public.is_board_owner(OLD.id)
    OR NEW.id IS DISTINCT FROM OLD.id
    OR NEW.slug IS DISTINCT FROM OLD.slug
    OR NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  NEW.name := btrim(NEW.name);
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
  v_old_generation_id uuid;
  v_new_generation_id uuid;
  v_active_generation_id uuid;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    IF TG_TABLE_NAME = 'columns' THEN
      v_old_board_id := OLD.board_id;
      v_old_generation_id := OLD.generation_id;
    ELSE
      SELECT column_row.board_id, column_row.generation_id
        INTO v_old_board_id, v_old_generation_id
      FROM public.columns AS column_row WHERE column_row.id = OLD.column_id;
    END IF;
  END IF;

  IF TG_OP <> 'DELETE' THEN
    IF TG_TABLE_NAME = 'columns' THEN
      v_new_board_id := NEW.board_id;
      v_new_generation_id := NEW.generation_id;
    ELSE
      SELECT column_row.board_id, column_row.generation_id
        INTO v_new_board_id, v_new_generation_id
      FROM public.columns AS column_row WHERE column_row.id = NEW.column_id;
    END IF;
  END IF;

  IF TG_OP = 'UPDATE' AND v_old_board_id IS DISTINCT FROM v_new_board_id THEN
    RAISE EXCEPTION 'Content cannot move between boards' USING ERRCODE = '42501';
  END IF;

  IF TG_OP <> 'INSERT' AND v_old_board_id IS NOT NULL THEN
    SELECT board.active_generation_id INTO v_active_generation_id
    FROM public.boards AS board WHERE board.id = v_old_board_id;
    IF NOT FOUND AND TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
      RETURN OLD;
    END IF;
    IF v_active_generation_id IS DISTINCT FROM v_old_generation_id THEN
      RAISE EXCEPTION 'Archived board content cannot be changed' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Parent deletion cascades can remove membership before the child trigger
  -- fires. The parent trigger already authorized the cascade; direct child
  -- deletes execute at trigger depth one and still require current membership.
  IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1
    AND NOT public.is_board_member(v_old_board_id) THEN
    RETURN OLD;
  END IF;

  IF TG_OP <> 'DELETE' THEN
    SELECT board.active_generation_id INTO v_active_generation_id
    FROM public.boards AS board WHERE board.id = v_new_board_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
    END IF;
    IF TG_TABLE_NAME = 'columns' AND v_new_generation_id IS NULL THEN
      NEW.generation_id := v_active_generation_id;
      v_new_generation_id := v_active_generation_id;
    END IF;
    IF v_new_generation_id IS DISTINCT FROM v_active_generation_id THEN
      RAISE EXCEPTION 'Archived board content cannot be changed' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF NOT public.is_application_user()
    OR (TG_OP <> 'INSERT' AND NOT public.is_board_member(v_old_board_id))
    OR (TG_OP <> 'DELETE' AND NOT public.is_board_member(v_new_board_id)) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP POLICY IF EXISTS "boards_select_enabled_owner" ON public.boards;
DROP POLICY IF EXISTS "columns_select_enabled_owner" ON public.columns;
DROP POLICY IF EXISTS "tasks_select_enabled_owner" ON public.tasks;
CREATE POLICY boards_select_current_member ON public.boards
  FOR SELECT TO authenticated USING (public.is_board_member(id));
CREATE POLICY columns_select_current_member_active_generation ON public.columns
  FOR SELECT TO authenticated USING (
    public.is_board_member(board_id)
    AND EXISTS (
      SELECT 1 FROM public.boards AS board
      WHERE board.id = columns.board_id
        AND board.active_generation_id = columns.generation_id
    )
  );
CREATE POLICY tasks_select_current_member_active_generation ON public.tasks
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.columns AS column_row
      JOIN public.boards AS board ON board.id = column_row.board_id
      WHERE column_row.id = tasks.column_id
        AND public.is_board_member(board.id)
        AND board.active_generation_id = column_row.generation_id
    )
  );

DROP FUNCTION public.list_my_boards();
CREATE FUNCTION public.list_my_boards()
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  time_zone text,
  role text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.id, board.slug, board.name, board.time_zone,
    membership.role, board.created_at, board.updated_at
  FROM public.boards AS board
  JOIN public.board_memberships AS membership ON membership.board_id = board.id
  WHERE membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL
    AND public.is_application_user()
  ORDER BY board.updated_at DESC, board.id;
$$;

DROP FUNCTION public.get_board_p(text);
CREATE FUNCTION public.get_board_p(p_slug text)
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  time_zone text,
  role text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.id, board.slug, board.name, board.time_zone,
    membership.role, board.created_at, board.updated_at
  FROM public.boards AS board
  JOIN public.board_memberships AS membership ON membership.board_id = board.id
  WHERE board.slug = p_slug AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL AND public.is_board_member(board.id);
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
  v_role text;
BEGIN
  SELECT * INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  SELECT membership.role INTO v_role
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL;

  RETURN json_build_object(
    'board', ((to_jsonb(v_board) - 'active_generation_id' - 'owner_id')
      || jsonb_build_object('role', v_role))::json,
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
          AND column_row.generation_id = v_board.active_generation_id
      ),
      '[]'::json
    )
  );
END;
$$;

DROP FUNCTION public.get_columns_p(uuid);
CREATE FUNCTION public.get_columns_p(p_board_id uuid)
RETURNS TABLE (
  id uuid,
  board_id uuid,
  title text,
  "position" integer,
  is_collapsed boolean,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT column_row.id, column_row.board_id, column_row.title,
    column_row.position, column_row.is_collapsed, column_row.created_at
  FROM public.columns AS column_row
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE board.id = p_board_id
    AND board.active_generation_id = column_row.generation_id
    AND public.is_board_member(board.id)
  ORDER BY column_row.position, column_row.id;
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
    AND board.active_generation_id = column_row.generation_id
    AND public.is_board_member(board.id)
  ORDER BY task_row.position, task_row.id;
$$;

CREATE OR REPLACE FUNCTION public.update_column_positions_p(
  p_slug text,
  p_updates jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_update_count integer;
  v_unique_count integer;
  v_target_count integer;
BEGIN
  IF p_updates IS NULL OR jsonb_typeof(p_updates) <> 'array' THEN
    RAISE EXCEPTION 'Column positions must be an array' USING ERRCODE = '22023';
  END IF;

  v_update_count := jsonb_array_length(p_updates);
  IF v_update_count > 200 THEN
    RAISE EXCEPTION 'Batch size exceeds maximum of 200 items';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF v_board_id IS NULL THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF v_update_count = 0 THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_updates) AS item(value)
    WHERE jsonb_typeof(item.value) <> 'object'
      OR item.value - ARRAY['id', 'position'] <> '{}'::jsonb
      OR NOT (item.value ? 'id')
      OR NOT (item.value ? 'position')
      OR jsonb_typeof(item.value->'id') <> 'string'
      OR jsonb_typeof(item.value->'position') <> 'number'
  ) THEN
    RAISE EXCEPTION 'Only column id and position can be changed in a reorder'
      USING ERRCODE = '22023';
  END IF;

  SELECT count(DISTINCT (item.value->>'id')::uuid) INTO v_unique_count
  FROM jsonb_array_elements(p_updates) AS item(value);
  IF v_unique_count <> v_update_count THEN
    RAISE EXCEPTION 'A column may appear only once in a reorder' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_target_count
  FROM jsonb_array_elements(p_updates) AS item(value)
  JOIN public.columns AS column_row
    ON column_row.id = (item.value->>'id')::uuid
   AND column_row.board_id = v_board_id
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE column_row.generation_id = board.active_generation_id
    AND (item.value->>'position')::integer >= 0;
  IF v_target_count <> v_update_count THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  UPDATE public.columns AS column_row
  SET position = (item.value->>'position')::integer
  FROM jsonb_array_elements(p_updates) AS item(value)
  WHERE column_row.id = (item.value->>'id')::uuid
    AND column_row.board_id = v_board_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.can_access_board_topic(p_topic text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  IF p_topic IS NULL OR p_topic !~ '^board(-sync)?:[0-9a-fA-F-]{36}$' THEN
    RETURN false;
  END IF;
  BEGIN
    v_board_id := split_part(p_topic, ':', 2)::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;
  RETURN public.is_board_member(v_board_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_board_creation_result_p(p_operation_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.slug
  FROM public.board_creation_requests AS request
  JOIN public.boards AS board ON board.id = request.board_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
  WHERE request.user_id = auth.uid()
    AND request.operation_id = p_operation_id
    AND board.owner_id = auth.uid()
    AND membership.user_id = auth.uid()
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
    AND public.is_application_user()
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.create_board_p(
  p_name text,
  p_time_zone text,
  p_operation_id uuid
)
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  time_zone text,
  role text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_board_id uuid := gen_random_uuid();
  v_generation_id uuid := gen_random_uuid();
  v_existing_request public.board_creation_requests%ROWTYPE;
BEGIN
  IF NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL THEN
    RAISE EXCEPTION 'A creation operation id is required' USING ERRCODE = '22023';
  END IF;
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Enter a board name' USING ERRCODE = '23514';
  END IF;
  IF char_length(btrim(p_name)) > 100 THEN
    RAISE EXCEPTION 'Board names must be 100 characters or fewer' USING ERRCODE = '23514';
  END IF;
  IF p_time_zone IS NULL OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_timezone_names AS zone WHERE zone.name = p_time_zone
  ) THEN
    RAISE EXCEPTION 'Choose a valid time zone' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.board_creation_requests(
    user_id, operation_id, board_id, requested_name, requested_time_zone
  ) VALUES (
    v_user_id, p_operation_id, v_board_id, btrim(p_name), p_time_zone
  ) ON CONFLICT (user_id, operation_id) DO NOTHING;

  IF NOT FOUND THEN
    SELECT * INTO v_existing_request
    FROM public.board_creation_requests AS request
    WHERE request.user_id = v_user_id AND request.operation_id = p_operation_id
    FOR UPDATE;
    IF v_existing_request.requested_name IS DISTINCT FROM btrim(p_name)
      OR v_existing_request.requested_time_zone IS DISTINCT FROM p_time_zone THEN
      RAISE EXCEPTION 'This creation operation was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    RETURN QUERY
    SELECT board.id, board.slug, board.name, board.time_zone,
      membership.role, board.created_at, board.updated_at
    FROM public.boards AS board
    JOIN public.board_memberships AS membership ON membership.board_id = board.id
    WHERE board.id = v_existing_request.board_id
      AND board.owner_id = v_user_id
      AND membership.user_id = v_user_id
      AND membership.revoked_at IS NULL
      AND public.is_board_member(board.id);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The result of this creation is no longer available'
        USING ERRCODE = '42501';
    END IF;
    RETURN;
  END IF;

  INSERT INTO public.boards(id, slug, name, time_zone, owner_id, active_generation_id)
  VALUES (
    v_board_id,
    'board-' || v_board_id::text,
    btrim(p_name),
    p_time_zone,
    v_user_id,
    v_generation_id
  );
  INSERT INTO public.board_generations(id, board_id, status, created_by)
  VALUES (v_generation_id, v_board_id, 'active', v_user_id);
  INSERT INTO public.board_memberships(board_id, user_id, role)
  VALUES (v_board_id, v_user_id, 'owner');

  RETURN QUERY
  SELECT board.id, board.slug, board.name, board.time_zone,
    membership.role, board.created_at, board.updated_at
  FROM public.boards AS board
  JOIN public.board_memberships AS membership ON membership.board_id = board.id
  WHERE board.id = v_board_id AND membership.user_id = v_user_id
    AND membership.revoked_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.rename_board_p(p_slug text, p_name text)
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  time_zone text,
  role text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  IF p_name IS NULL OR btrim(p_name) = '' THEN
    RAISE EXCEPTION 'Enter a board name' USING ERRCODE = '23514';
  END IF;
  IF char_length(btrim(p_name)) > 100 THEN
    RAISE EXCEPTION 'Board names must be 100 characters or fewer' USING ERRCODE = '23514';
  END IF;
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug AND board.owner_id = auth.uid();
  IF v_board_id IS NULL OR NOT public.is_board_owner(v_board_id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  UPDATE public.boards AS board SET name = btrim(p_name)
  WHERE board.id = v_board_id;
  RETURN QUERY
  SELECT board.id, board.slug, board.name, board.time_zone,
    membership.role, board.created_at, board.updated_at
  FROM public.boards AS board
  JOIN public.board_memberships AS membership ON membership.board_id = board.id
  WHERE board.id = v_board_id AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL;
END;
$$;

-- The old slug-creation function cannot bypass explicit naming/idempotency.
REVOKE ALL ON FUNCTION public.create_board_p(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_board_p(text, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_board_creation_result_p(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rename_board_p(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_board_member(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_board_owner(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_board_p(text, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_board_creation_result_p(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rename_board_p(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_board_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_board_owner(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_boards() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_board_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_full_board_p(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_columns_p(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_tasks_by_board_p(uuid) TO authenticated;

REVOKE ALL ON TABLE public.board_generations, public.board_memberships,
  public.board_creation_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.boards, public.columns, public.tasks TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
