-- Minimal, immutable task activity for the E05 fields and recovery lifecycle.
BEGIN;

CREATE TABLE public.task_activity_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  task_id uuid NOT NULL,
  category text NOT NULL CHECK (category IN (
    'assignee', 'due_date', 'column', 'completion', 'recovery'
  )),
  actor_type text NOT NULL CHECK (actor_type IN ('user', 'system', 'imported')),
  actor_name text,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  before_value jsonb,
  after_value jsonb,
  CONSTRAINT task_activity_actor_snapshot_shape CHECK (
    (actor_type = 'system' AND actor_name IS NULL)
    OR (actor_type IN ('user', 'imported')
      AND actor_name IS NOT NULL AND btrim(actor_name) <> '')
  ),
  CONSTRAINT task_activity_value_shape CHECK (
    (category = 'recovery' AND before_value IS NULL AND after_value IS NULL)
    OR (category <> 'recovery' AND before_value IS NOT NULL AND after_value IS NOT NULL)
  )
);
CREATE INDEX task_activity_recent_by_task_idx
  ON public.task_activity_events(task_id, occurred_at DESC, id DESC);
CREATE INDEX task_activity_expiry_idx
  ON public.task_activity_events(occurred_at, id);

ALTER TABLE public.task_activity_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_activity_events
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.capture_task_activity_update_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_board_slug text;
  v_actor_name text;
  v_before_assignee text;
  v_after_assignee text;
  v_before_column text;
  v_after_column text;
  v_actor_type text;
BEGIN
  IF OLD.assignee_id IS NOT DISTINCT FROM NEW.assignee_id
    AND OLD.due_on IS NOT DISTINCT FROM NEW.due_on
    AND OLD.column_id IS NOT DISTINCT FROM NEW.column_id
    AND OLD.is_completed IS NOT DISTINCT FROM NEW.is_completed THEN
    RETURN NEW;
  END IF;

  SELECT board.id, board.slug INTO v_board_id, v_board_slug
  FROM public.boards AS board
  JOIN public.columns AS old_column
    ON old_column.board_id = board.id
    AND old_column.id = OLD.column_id
    AND old_column.generation_id = board.active_generation_id
  JOIN public.columns AS new_column
    ON new_column.board_id = board.id
    AND new_column.id = NEW.column_id
    AND new_column.generation_id = board.active_generation_id
  WHERE NOT EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS deletion
    WHERE deletion.board_id = board.id
  );
  IF NOT FOUND THEN RETURN NEW; END IF;

  v_actor_type := CASE WHEN auth.uid() IS NULL THEN 'system' ELSE 'user' END;
  IF v_actor_type = 'user' THEN
    SELECT member.name INTO v_actor_name
    FROM public.list_assignable_board_members_p(v_board_slug) AS member
    WHERE member.user_id = auth.uid();
    v_actor_name := coalesce(v_actor_name, 'Miembro del tablero');
  END IF;

  IF OLD.assignee_id IS DISTINCT FROM NEW.assignee_id THEN
    IF OLD.assignee_id IS NOT NULL THEN
      SELECT member.name INTO v_before_assignee
      FROM public.list_assignable_board_members_p(v_board_slug) AS member
      WHERE member.user_id = OLD.assignee_id;
    END IF;
    IF NEW.assignee_id IS NOT NULL THEN
      SELECT member.name INTO v_after_assignee
      FROM public.list_assignable_board_members_p(v_board_slug) AS member
      WHERE member.user_id = NEW.assignee_id;
    END IF;
    INSERT INTO public.task_activity_events(
      board_id, task_id, category, actor_type, actor_name,
      before_value, after_value
    ) VALUES (
      v_board_id, NEW.id, 'assignee', v_actor_type, v_actor_name,
      to_jsonb(coalesce(
        v_before_assignee,
        CASE WHEN OLD.assignee_id IS NULL THEN 'Sin responsable' ELSE 'Miembro anterior' END
      )),
      to_jsonb(coalesce(
        v_after_assignee,
        CASE WHEN NEW.assignee_id IS NULL THEN 'Sin responsable' ELSE 'Miembro no disponible' END
      ))
    );
  END IF;

  IF OLD.due_on IS DISTINCT FROM NEW.due_on THEN
    INSERT INTO public.task_activity_events(
      board_id, task_id, category, actor_type, actor_name,
      before_value, after_value
    ) VALUES (
      v_board_id, NEW.id, 'due_date', v_actor_type, v_actor_name,
      coalesce(to_jsonb(OLD.due_on), 'null'::jsonb),
      coalesce(to_jsonb(NEW.due_on), 'null'::jsonb)
    );
  END IF;

  IF OLD.column_id IS DISTINCT FROM NEW.column_id THEN
    SELECT column_row.title INTO v_before_column
    FROM public.columns AS column_row WHERE column_row.id = OLD.column_id;
    SELECT column_row.title INTO v_after_column
    FROM public.columns AS column_row WHERE column_row.id = NEW.column_id;
    INSERT INTO public.task_activity_events(
      board_id, task_id, category, actor_type, actor_name,
      before_value, after_value
    ) VALUES (
      v_board_id, NEW.id, 'column', v_actor_type, v_actor_name,
      to_jsonb(coalesce(v_before_column, 'Columna no disponible')),
      to_jsonb(coalesce(v_after_column, 'Columna no disponible'))
    );
  END IF;

  IF OLD.is_completed IS DISTINCT FROM NEW.is_completed THEN
    INSERT INTO public.task_activity_events(
      board_id, task_id, category, actor_type, actor_name,
      before_value, after_value
    ) VALUES (
      v_board_id, NEW.id, 'completion', v_actor_type, v_actor_name,
      to_jsonb(OLD.is_completed), to_jsonb(NEW.is_completed)
    );
  END IF;

  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_task_activity_update_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER tasks_capture_e05_activity
  AFTER UPDATE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.capture_task_activity_update_tg();

CREATE FUNCTION public.capture_task_activity_recovery_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_slug text;
  v_actor_name text;
  v_actor_type text;
BEGIN
  IF TG_OP = 'DELETE' THEN
    DELETE FROM public.task_activity_events AS event
    WHERE event.task_id = OLD.task_id;
    RETURN OLD;
  END IF;

  IF OLD.state = 'deleted' AND NEW.state = 'purged' THEN
    DELETE FROM public.task_activity_events AS event
    WHERE event.task_id = NEW.task_id;
    RETURN NEW;
  END IF;

  IF OLD.state IS DISTINCT FROM 'deleted' OR NEW.state IS DISTINCT FROM 'restored'
    OR NOT EXISTS (
      SELECT 1
      FROM public.tasks AS task
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      JOIN public.boards AS board
        ON board.id = column_row.board_id
        AND board.active_generation_id = column_row.generation_id
      WHERE task.id = NEW.task_id
        AND board.id = NEW.board_id
        AND NOT EXISTS (
          SELECT 1 FROM public.board_recoverable_deletions AS board_deletion
          WHERE board_deletion.board_id = board.id
        )
    ) THEN
    RETURN NEW;
  END IF;

  SELECT board.slug INTO v_board_slug
  FROM public.boards AS board
  WHERE board.id = NEW.board_id;
  v_actor_type := CASE WHEN auth.uid() IS NULL THEN 'system' ELSE 'user' END;
  IF v_actor_type = 'user' THEN
    SELECT member.name INTO v_actor_name
    FROM public.list_assignable_board_members_p(v_board_slug) AS member
    WHERE member.user_id = auth.uid();
    v_actor_name := coalesce(v_actor_name, 'Miembro del tablero');
  END IF;

  INSERT INTO public.task_activity_events(
    board_id, task_id, category, actor_type, actor_name, occurred_at
  ) VALUES (
    NEW.board_id, NEW.task_id, 'recovery', v_actor_type, v_actor_name,
    coalesce(NEW.restored_at, clock_timestamp())
  );
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_task_activity_recovery_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER task_deletions_capture_activity_recovery
  AFTER UPDATE OF state ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.capture_task_activity_recovery_tg();
CREATE TRIGGER task_deletions_purge_activity
  AFTER DELETE ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.capture_task_activity_recovery_tg();

CREATE FUNCTION public.get_task_activity_p(
  p_slug text,
  p_task_id uuid,
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
  v_board_id uuid;
  v_events jsonb;
  v_event_count integer;
  v_has_more boolean;
  v_next_cursor jsonb := NULL;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_task_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR ((p_before_occurred_at IS NULL) <> (p_before_id IS NULL)) THEN
    RAISE EXCEPTION 'Elige una página de actividad válida' USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.columns AS column_row
    ON column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  JOIN public.tasks AS task ON task.column_id = column_row.id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = auth.uid()
    AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug
    AND task.id = p_task_id
    AND public.is_board_member(board.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = task.id
        AND deletion.state IN ('deleted', 'purged')
    )
  FOR SHARE OF board, task, membership;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board_id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT coalesce(jsonb_agg(pg_catalog.jsonb_build_object(
    'id', page.id,
    'category', page.category,
    'actor_type', page.actor_type,
    'actor_name', page.actor_name,
    'occurred_at', page.occurred_at,
    'before_value', page.before_value,
    'after_value', page.after_value
  ) ORDER BY page.occurred_at DESC, page.id DESC), '[]'::jsonb)
  INTO v_events
  FROM (
    SELECT event.*
    FROM public.task_activity_events AS event
    WHERE event.board_id = v_board_id
      AND event.task_id = p_task_id
      AND event.occurred_at > clock_timestamp() - interval '180 days'
      AND (p_before_occurred_at IS NULL
        OR (event.occurred_at, event.id) < (p_before_occurred_at, p_before_id))
    ORDER BY event.occurred_at DESC, event.id DESC
    LIMIT p_limit + 1
  ) AS page;

  v_event_count := jsonb_array_length(v_events);
  v_has_more := v_event_count > p_limit;
  IF v_has_more THEN
    v_events := v_events - p_limit;
    v_next_cursor := pg_catalog.jsonb_build_object(
      'occurred_at', v_events->(p_limit - 1)->>'occurred_at',
      'id', v_events->(p_limit - 1)->>'id'
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available',
    'events', v_events,
    'has_more', v_has_more,
    'next_cursor', v_next_cursor,
    'retention_days', 180
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_task_activity_p(text, uuid, integer, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_task_activity_p(text, uuid, integer, timestamptz, uuid)
  TO authenticated;

CREATE FUNCTION public.purge_expired_task_activity_p(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_purged integer;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 5000 THEN
    RAISE EXCEPTION 'Elige un lote de purga válido' USING ERRCODE = '22023';
  END IF;

  WITH expired AS (
    SELECT event.id
    FROM public.task_activity_events AS event
    WHERE event.occurred_at <= clock_timestamp() - interval '180 days'
    ORDER BY event.occurred_at, event.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.task_activity_events AS event
  USING expired
  WHERE event.id = expired.id;
  GET DIAGNOSTICS v_purged = ROW_COUNT;
  RETURN v_purged;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_expired_task_activity_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.purge_expired_task_activity_p(integer)
  TO service_role;

NOTIFY pgrst, 'reload schema';
COMMIT;
