-- Prepare v1 imports in an invisible generation, then publish one pointer swap.
BEGIN;

CREATE TABLE public.board_content_revisions (
  board_id uuid PRIMARY KEY REFERENCES public.boards(id) ON DELETE CASCADE,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp()
);
INSERT INTO public.board_content_revisions(board_id)
SELECT board.id FROM public.boards AS board;
ALTER TABLE public.board_content_revisions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_content_revisions
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_import_stage_contexts (
  transaction_id bigint NOT NULL,
  actor_id uuid NOT NULL,
  board_id uuid NOT NULL,
  generation_id uuid NOT NULL,
  PRIMARY KEY (transaction_id, generation_id)
);
ALTER TABLE public.board_import_stage_contexts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_import_stage_contexts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_import_cleanup_contexts (
  transaction_id bigint NOT NULL,
  board_id uuid NOT NULL,
  generation_id uuid NOT NULL,
  PRIMARY KEY (transaction_id, generation_id)
);
ALTER TABLE public.board_import_cleanup_contexts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_import_cleanup_contexts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_generation_retention (
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  replacement_generation_id uuid NOT NULL,
  retained_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (board_id, generation_id),
  CHECK (expires_at = retained_at + interval '168 hours'),
  FOREIGN KEY (board_id, generation_id)
    REFERENCES public.board_generations(board_id, id) ON DELETE CASCADE
);
CREATE INDEX board_generation_retention_expiry_idx
  ON public.board_generation_retention(expires_at, board_id, generation_id);
ALTER TABLE public.board_generation_retention ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_generation_retention
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_import_operations (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid,
  base_generation_id uuid NOT NULL,
  expected_content_revision bigint NOT NULL CHECK (expected_content_revision > 0),
  source_sha256 text NOT NULL CHECK (source_sha256 ~ '^[0-9a-f]{64}$'),
  staged_content_hash bytea,
  status text NOT NULL CHECK (status IN (
    'staging', 'prepared', 'confirmed', 'conflict', 'expired', 'cancelled'
  )),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  expires_at timestamptz NOT NULL,
  confirmed_at timestamptz,
  result jsonb,
  PRIMARY KEY (actor_id, operation_id),
  CHECK (expires_at > created_at),
  CHECK ((status IN ('prepared', 'confirmed') AND staged_content_hash IS NOT NULL)
    OR status NOT IN ('prepared', 'confirmed')),
  CHECK ((status = 'confirmed') = (confirmed_at IS NOT NULL))
);
CREATE INDEX board_import_operations_expiry_idx
  ON public.board_import_operations(expires_at, board_id)
  WHERE status IN ('staging', 'prepared');
CREATE INDEX board_import_operations_confirmed_retention_idx
  ON public.board_import_operations(confirmed_at, actor_id, operation_id)
  WHERE status = 'confirmed';
CREATE INDEX board_import_operations_terminal_retention_idx
  ON public.board_import_operations(expires_at, actor_id, operation_id)
  WHERE status IN ('conflict', 'expired', 'cancelled');
ALTER TABLE public.board_import_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_import_operations
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.seed_board_content_revision_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  INSERT INTO public.board_content_revisions(board_id)
  VALUES (NEW.id)
  ON CONFLICT (board_id) DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER boards_seed_content_revision
  AFTER INSERT ON public.boards
  FOR EACH ROW EXECUTE FUNCTION public.seed_board_content_revision_tg();
REVOKE ALL ON FUNCTION public.seed_board_content_revision_tg()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.bump_board_content_revision_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_row jsonb;
  v_board_id uuid;
  v_generation_id uuid;
  v_parent_id uuid;
BEGIN
  v_row := CASE WHEN TG_OP = 'DELETE' THEN pg_catalog.to_jsonb(OLD)
    ELSE pg_catalog.to_jsonb(NEW) END;
  CASE TG_ARGV[0]
    WHEN 'board' THEN
      v_board_id := (v_row->>'id')::uuid;
      UPDATE public.board_content_revisions
      SET revision = revision + 1, updated_at = pg_catalog.clock_timestamp()
      WHERE board_id = v_board_id;
      RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
    WHEN 'generation' THEN
      v_board_id := (v_row->>'board_id')::uuid;
      v_generation_id := (v_row->>'generation_id')::uuid;
    WHEN 'task' THEN
      v_parent_id := (v_row->>'column_id')::uuid;
      SELECT column_row.board_id, column_row.generation_id
      INTO v_board_id, v_generation_id
      FROM public.columns AS column_row WHERE column_row.id = v_parent_id;
    WHEN 'task_reference' THEN
      v_parent_id := (v_row->>'task_id')::uuid;
      SELECT column_row.board_id, column_row.generation_id
      INTO v_board_id, v_generation_id
      FROM public.tasks AS task
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE task.id = v_parent_id;
    WHEN 'column_reference' THEN
      v_parent_id := (v_row->>'column_id')::uuid;
      SELECT column_row.board_id, column_row.generation_id
      INTO v_board_id, v_generation_id
      FROM public.columns AS column_row WHERE column_row.id = v_parent_id;
    WHEN 'comment_reference' THEN
      v_parent_id := (v_row->>'comment_id')::uuid;
      SELECT column_row.board_id, column_row.generation_id
      INTO v_board_id, v_generation_id
      FROM public.task_comments AS comment_row
      JOIN public.tasks AS task ON task.id = comment_row.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE comment_row.id = v_parent_id;
    WHEN 'series_reference' THEN
      v_parent_id := (v_row->>'series_id')::uuid;
      SELECT series.board_id, series.generation_id
      INTO v_board_id, v_generation_id
      FROM public.daily_repetition_series AS series
      WHERE series.id = v_parent_id;
    ELSE
      RAISE EXCEPTION 'Unknown board content revision trigger source';
  END CASE;

  IF v_board_id IS NOT NULL AND v_generation_id IS NOT NULL THEN
    UPDATE public.board_content_revisions AS revision
    SET revision = revision.revision + 1,
        updated_at = pg_catalog.clock_timestamp()
    FROM public.boards AS board
    WHERE revision.board_id = v_board_id
      AND board.id = v_board_id
      AND board.active_generation_id = v_generation_id;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;
CREATE TRIGGER boards_bump_content_revision
  AFTER UPDATE OF name, time_zone, active_generation_id ON public.boards
  FOR EACH ROW WHEN (
    OLD.name IS DISTINCT FROM NEW.name
    OR OLD.time_zone IS DISTINCT FROM NEW.time_zone
    OR OLD.active_generation_id IS DISTINCT FROM NEW.active_generation_id
  ) EXECUTE FUNCTION public.bump_board_content_revision_tg('board');
CREATE TRIGGER columns_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.columns
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER tasks_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('task');
CREATE TRIGGER comments_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.task_comments
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('task_reference');
CREATE TRIGGER comment_mentions_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.task_comment_mentions
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('comment_reference');
CREATE TRIGGER labels_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.board_labels
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER task_label_assignments_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.board_label_task_assignments
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER birthday_label_assignments_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.board_label_birthday_assignments
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER repetition_label_assignments_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.board_label_repetition_assignments
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER birthdays_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.board_birthdays
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER birthday_deletions_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.birthday_deletions
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER repetitions_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.daily_repetition_series
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('generation');
CREATE TRIGGER repetition_occurrences_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.daily_repetition_occurrences
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('series_reference');
CREATE TRIGGER repetition_deletions_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.daily_repetition_series_deletions
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('series_reference');
CREATE TRIGGER column_deletions_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.column_deletions
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('column_reference');
CREATE TRIGGER task_deletions_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('task_reference');
CREATE TRIGGER checklist_deletions_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.task_checklist_deletions
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('task_reference');
CREATE TRIGGER task_activity_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.task_activity_events
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('task_reference');
CREATE TRIGGER task_attachments_bump_content_revision
  AFTER INSERT OR UPDATE OR DELETE ON public.task_attachments
  FOR EACH ROW EXECUTE FUNCTION public.bump_board_content_revision_tg('task_reference');
REVOKE ALL ON FUNCTION public.bump_board_content_revision_tg()
  FROM PUBLIC, anon, authenticated, service_role;

-- Revisions are incremented for every active content mutation. The counter is
-- kept outside boards so system jobs do not need to impersonate a board owner.
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
  v_stage_actor_id uuid;
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

  IF TG_OP = 'DELETE' AND EXISTS (
    SELECT 1 FROM public.board_import_cleanup_contexts AS context
    WHERE context.transaction_id = pg_catalog.txid_current()
  ) THEN
    RETURN OLD;
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
    IF TG_OP = 'DELETE' AND EXISTS (
      SELECT 1 FROM public.board_import_cleanup_contexts AS context
      WHERE context.transaction_id = pg_catalog.txid_current()
        AND context.board_id = v_old_board_id
        AND context.generation_id = v_old_generation_id
    ) THEN
      RETURN OLD;
    END IF;
    IF v_active_generation_id IS DISTINCT FROM v_old_generation_id
      AND NOT (
        TG_OP = 'UPDATE'
        AND TG_TABLE_NAME = 'columns'
        AND (pg_catalog.to_jsonb(NEW)->>'task_order_version')::bigint
          = (pg_catalog.to_jsonb(OLD)->>'task_order_version')::bigint + 1
        AND (pg_catalog.to_jsonb(NEW) - 'task_order_version')
          IS NOT DISTINCT FROM
          (pg_catalog.to_jsonb(OLD) - 'task_order_version')
        AND EXISTS (
          SELECT 1 FROM public.board_import_stage_contexts AS context
          JOIN public.board_generations AS generation
            ON generation.board_id = context.board_id
            AND generation.id = context.generation_id
            AND generation.status = 'preparing'
          WHERE context.transaction_id = pg_catalog.txid_current()
            AND context.actor_id = auth.uid()
            AND context.board_id = v_old_board_id
            AND context.generation_id = v_old_generation_id
        )
        AND public.is_application_user()
        AND public.is_board_owner(v_old_board_id)
      ) THEN
      RAISE EXCEPTION 'Archived board content cannot be changed' USING ERRCODE = '42501';
    END IF;
  END IF;
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
      SELECT context.actor_id INTO v_stage_actor_id
      FROM public.board_import_stage_contexts AS context
      JOIN public.board_generations AS generation
        ON generation.board_id = context.board_id
        AND generation.id = context.generation_id
        AND generation.status = 'preparing'
      WHERE context.transaction_id = pg_catalog.txid_current()
        AND context.actor_id = auth.uid()
        AND context.board_id = v_new_board_id
        AND context.generation_id = v_new_generation_id;
      IF NOT FOUND
        OR NOT (
          TG_OP = 'INSERT'
          OR (TG_OP = 'UPDATE'
            AND TG_TABLE_NAME = 'columns'
            AND (pg_catalog.to_jsonb(NEW)->>'task_order_version')::bigint
              = (pg_catalog.to_jsonb(OLD)->>'task_order_version')::bigint + 1
            AND (pg_catalog.to_jsonb(NEW) - 'task_order_version')
              IS NOT DISTINCT FROM
              (pg_catalog.to_jsonb(OLD) - 'task_order_version'))
        )
        OR NOT public.is_application_user()
        OR NOT public.is_board_owner(v_new_board_id) THEN
        RAISE EXCEPTION 'Archived board content cannot be changed' USING ERRCODE = '42501';
      END IF;
      RETURN NEW;
    END IF;
  END IF;
  IF TG_TABLE_NAME = 'tasks' AND TG_OP = 'UPDATE' THEN
    IF OLD.assignee_id IS NOT NULL
      AND NEW.assignee_id IS NULL
      AND NEW.assignee_version = OLD.assignee_version + 1
      AND (pg_catalog.to_jsonb(NEW) - 'assignee_id' - 'assignee_version')
        IS NOT DISTINCT FROM
        (pg_catalog.to_jsonb(OLD) - 'assignee_id' - 'assignee_version')
      AND public.is_application_admin()
      AND EXISTS (
        SELECT 1 FROM public.account_suspension_write_contexts AS context
        WHERE context.transaction_id = pg_catalog.txid_current()
          AND context.actor_id = auth.uid()
          AND context.target_id = OLD.assignee_id
          AND v_old_board_id = ANY(context.board_ids)
      ) THEN
      RETURN NEW;
    END IF;
  END IF;
  IF NOT public.is_application_user()
    OR (TG_OP <> 'INSERT' AND NOT public.is_board_member(v_old_board_id))
    OR (TG_OP <> 'DELETE' AND NOT public.is_board_member(v_new_board_id)) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.guard_board_child_owner()
  FROM PUBLIC, anon, authenticated, service_role;

-- Staged and archived rows are invisible to the live board. Do not publish a
-- sync invalidation for each row written while preparing an import generation.
CREATE OR REPLACE FUNCTION public.publish_board_table_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_generation_id uuid;
  v_row jsonb;
  v_column_id uuid;
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
    WHEN 'columns' THEN
      v_row := CASE WHEN TG_OP = 'DELETE'
        THEN pg_catalog.to_jsonb(OLD) ELSE pg_catalog.to_jsonb(NEW) END;
      v_board_id := (v_row->>'board_id')::uuid;
      v_generation_id := (v_row->>'generation_id')::uuid;
    WHEN 'tasks' THEN
      v_row := CASE WHEN TG_OP = 'DELETE'
        THEN pg_catalog.to_jsonb(OLD) ELSE pg_catalog.to_jsonb(NEW) END;
      v_column_id := (v_row->>'column_id')::uuid;
      SELECT column_row.board_id, column_row.generation_id
        INTO v_board_id, v_generation_id
      FROM public.columns AS column_row WHERE column_row.id = v_column_id;
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

  IF v_generation_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.boards AS board
    WHERE board.id = v_board_id
      AND board.active_generation_id = v_generation_id
  ) THEN
    RETURN NULL;
  END IF;
  PERFORM public.publish_board_realtime_sync(v_board_id);
  RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.publish_board_table_change()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.cleanup_board_import_generation_p(
  p_board_id uuid,
  p_generation_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_deleted boolean;
BEGIN
  IF p_board_id IS NULL OR p_generation_id IS NULL THEN
    RETURN false;
  END IF;
  INSERT INTO public.board_import_cleanup_contexts(
    transaction_id, board_id, generation_id
  ) VALUES (pg_catalog.txid_current(), p_board_id, p_generation_id)
  ON CONFLICT DO NOTHING;
  DELETE FROM public.board_generations AS generation
  WHERE generation.board_id = p_board_id
    AND generation.id = p_generation_id
    AND generation.status IN ('preparing', 'archived')
    AND NOT EXISTS (
      SELECT 1 FROM public.boards AS board
      WHERE board.id = generation.board_id
        AND board.active_generation_id = generation.id
    );
  v_deleted := FOUND;
  DELETE FROM public.board_import_cleanup_contexts AS context
  WHERE context.transaction_id = pg_catalog.txid_current()
    AND context.board_id = p_board_id
    AND context.generation_id = p_generation_id;
  RETURN v_deleted;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_board_import_generation_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_import_generation_hash_p(
  p_board_id uuid,
  p_generation_id uuid
)
RETURNS bytea
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
  SELECT extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'columns', COALESCE((
          SELECT pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'id', column_row.id,
              'title', column_row.title,
              'position', column_row.position,
              'tasks', COALESCE((
                SELECT pg_catalog.jsonb_agg(
                  pg_catalog.jsonb_build_object(
                    'id', task.id,
                    'title', task.title,
                    'description', task.description,
                    'priority', task.priority,
                    'position', task.position
                  ) ORDER BY task.position, task.id
                )
                FROM public.tasks AS task
                WHERE task.column_id = column_row.id
              ), '[]'::jsonb)
            ) ORDER BY column_row.position, column_row.id
          )
          FROM public.columns AS column_row
          WHERE column_row.board_id = p_board_id
            AND column_row.generation_id = p_generation_id
        ), '[]'::jsonb)
      )::text,
      'UTF8'
    ),
    'sha256'
  );
$$;
REVOKE ALL ON FUNCTION public.board_import_generation_hash_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_import_generation_summary_p(
  p_board_id uuid,
  p_generation_id uuid
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'columns', (
      SELECT count(*) FROM public.columns AS column_row
      WHERE column_row.board_id = p_board_id
        AND column_row.generation_id = p_generation_id
        AND NOT EXISTS (
          SELECT 1 FROM public.column_deletions AS deletion
          WHERE deletion.column_id = column_row.id AND deletion.state = 'deleted'
        )
    ),
    'tasks', (
      SELECT count(*)
      FROM public.tasks AS task
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.board_id = p_board_id
        AND column_row.generation_id = p_generation_id
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.state = 'deleted'
        )
    ),
    'comments', (
      SELECT count(*)
      FROM public.task_comments AS comment_row
      JOIN public.tasks AS task ON task.id = comment_row.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.board_id = p_board_id
        AND column_row.generation_id = p_generation_id
        AND comment_row.deleted_at IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM public.task_deletions AS deletion
          WHERE deletion.task_id = task.id AND deletion.state = 'deleted'
        )
    ),
    'labels', (
      SELECT count(*) FROM public.board_labels AS label
      WHERE label.board_id = p_board_id AND label.generation_id = p_generation_id
        AND label.deleted_at IS NULL
    ),
    'birthdays', (
      SELECT count(*) FROM public.board_birthdays AS birthday
      WHERE birthday.board_id = p_board_id AND birthday.generation_id = p_generation_id
        AND NOT EXISTS (
          SELECT 1 FROM public.birthday_deletions AS deletion
          WHERE deletion.birthday_id = birthday.id AND deletion.state = 'deleted'
        )
    ),
    'series', (
      SELECT count(*) FROM public.daily_repetition_series AS series
      WHERE series.board_id = p_board_id AND series.generation_id = p_generation_id
        AND NOT EXISTS (
          SELECT 1 FROM public.daily_repetition_series_deletions AS deletion
          WHERE deletion.series_id = series.id AND deletion.state = 'deleted'
        )
    ),
    'attachments', (
      SELECT count(*)
      FROM public.task_attachments AS attachment
      JOIN public.tasks AS task ON task.id = attachment.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.board_id = p_board_id
        AND column_row.generation_id = p_generation_id
        AND attachment.state <> 'purged'
    ),
    'attachment_bytes', (
      SELECT COALESCE(sum(attachment.size_bytes), 0)
      FROM public.task_attachments AS attachment
      JOIN public.tasks AS task ON task.id = attachment.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.board_id = p_board_id
        AND column_row.generation_id = p_generation_id
        AND attachment.state <> 'purged'
    )
  );
$$;
REVOKE ALL ON FUNCTION public.board_import_generation_summary_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_import_capacity_snapshot_p()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'limit_bytes', ledger.limit_bytes,
    'used_bytes', ledger.active_bytes + ledger.recoverable_bytes
      + ledger.reserved_bytes + ledger.pending_bytes,
    'available_bytes', GREATEST(
      ledger.limit_bytes - ledger.active_bytes - ledger.recoverable_bytes
        - ledger.reserved_bytes - ledger.pending_bytes,
      0::bigint
    ),
    'can_replace', ledger.active_bytes + ledger.recoverable_bytes
      + ledger.reserved_bytes + ledger.pending_bytes <= ledger.limit_bytes
  )
  FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton;
$$;
REVOKE ALL ON FUNCTION public.board_import_capacity_snapshot_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_import_preview_result_p(
  p_operation public.board_import_operations,
  p_revision bigint
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'status', p_operation.status,
    'operation_id', p_operation.operation_id,
    'content_revision', p_revision,
    'source_sha256', p_operation.source_sha256,
    'expires_at', p_operation.expires_at,
    'current', public.board_import_generation_summary_p(
      p_operation.board_id, p_operation.base_generation_id
    ),
    'imported', public.board_import_generation_summary_p(
      p_operation.board_id, p_operation.generation_id
    ),
    'capacity', public.board_import_capacity_snapshot_p(),
    'retains_current_members', true,
    'source_version', 1
  );
$$;
REVOKE ALL ON FUNCTION public.board_import_preview_result_p(
  public.board_import_operations, bigint
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_import_document_valid_p(p_document jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_column jsonb;
  v_task jsonb;
BEGIN
  IF p_document IS NULL
    OR pg_catalog.jsonb_typeof(p_document) IS DISTINCT FROM 'object' THEN
    RETURN false;
  END IF;
  IF pg_catalog.octet_length(pg_catalog.convert_to(p_document::text, 'UTF8')) > 2097152
    OR NOT (p_document ? 'columns')
    OR p_document - ARRAY['columns'] <> '{}'::jsonb THEN
    RETURN false;
  END IF;
  IF pg_catalog.jsonb_typeof(p_document->'columns') IS DISTINCT FROM 'array' THEN
    RETURN false;
  END IF;
  IF pg_catalog.jsonb_array_length(p_document->'columns') > 50 THEN
    RETURN false;
  END IF;
  FOR v_column IN SELECT value FROM pg_catalog.jsonb_array_elements(p_document->'columns') AS value
  LOOP
    IF pg_catalog.jsonb_typeof(v_column) IS DISTINCT FROM 'object'
      OR NOT (v_column ?& ARRAY['title', 'position', 'tasks'])
      OR v_column - ARRAY['title', 'position', 'tasks'] <> '{}'::jsonb THEN
      RETURN false;
    END IF;
    IF pg_catalog.jsonb_typeof(v_column->'title') IS DISTINCT FROM 'string'
      OR v_column->>'title' <> pg_catalog.btrim(v_column->>'title')
      OR pg_catalog.length(v_column->>'title') NOT BETWEEN 1 AND 100
      OR pg_catalog.jsonb_typeof(v_column->'position') IS DISTINCT FROM 'number'
      OR (v_column->>'position')::numeric NOT BETWEEN 0 AND 2147483647
      OR trunc((v_column->>'position')::numeric) <> (v_column->>'position')::numeric THEN
      RETURN false;
    END IF;
    IF pg_catalog.jsonb_typeof(v_column->'tasks') IS DISTINCT FROM 'array' THEN
      RETURN false;
    END IF;
    IF pg_catalog.jsonb_array_length(v_column->'tasks') > 500 THEN
      RETURN false;
    END IF;
    FOR v_task IN SELECT value FROM pg_catalog.jsonb_array_elements(v_column->'tasks') AS value
    LOOP
      IF pg_catalog.jsonb_typeof(v_task) IS DISTINCT FROM 'object'
        OR NOT (v_task ?& ARRAY['title', 'description', 'priority', 'position'])
        OR v_task - ARRAY['title', 'description', 'priority', 'position'] <> '{}'::jsonb THEN
        RETURN false;
      END IF;
      IF pg_catalog.jsonb_typeof(v_task->'title') IS DISTINCT FROM 'string'
        OR v_task->>'title' <> pg_catalog.btrim(v_task->>'title')
        OR pg_catalog.length(v_task->>'title') NOT BETWEEN 1 AND 200
        OR pg_catalog.jsonb_typeof(v_task->'description') NOT IN ('string', 'null')
        OR (pg_catalog.jsonb_typeof(v_task->'description') = 'string'
          AND pg_catalog.length(v_task->>'description') > 2000)
        OR pg_catalog.jsonb_typeof(v_task->'priority') IS DISTINCT FROM 'string'
        OR v_task->>'priority' NOT IN ('low', 'medium', 'high', 'urgent')
        OR pg_catalog.jsonb_typeof(v_task->'position') IS DISTINCT FROM 'number'
        OR (v_task->>'position')::numeric NOT BETWEEN 0 AND 2147483647
        OR trunc((v_task->>'position')::numeric) <> (v_task->>'position')::numeric THEN
        RETURN false;
      END IF;
    END LOOP;
  END LOOP;
  RETURN true;
EXCEPTION WHEN data_exception THEN
  RETURN false;
END;
$$;
REVOKE ALL ON FUNCTION public.board_import_document_valid_p(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.prepare_board_import_p(
  p_slug text,
  p_operation_id uuid,
  p_source_sha256 text,
  p_document jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_operation public.board_import_operations%ROWTYPE;
  v_generation_id uuid := pg_catalog.gen_random_uuid();
  v_revision bigint;
  v_column jsonb;
  v_task jsonb;
  v_column_id uuid;
  v_hash bytea;
  v_result jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_slug = '' OR p_operation_id IS NULL
    OR p_source_sha256 IS NULL OR p_source_sha256 !~ '^[0-9a-f]{64}$'
    OR NOT public.board_import_document_valid_p(p_document) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
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
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND OR v_board.owner_id IS DISTINCT FROM v_actor_id
    OR NOT public.is_board_owner(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_board.id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_operation.board_id <> v_board.id
      OR v_operation.source_sha256 <> p_source_sha256 THEN
      RETURN pg_catalog.jsonb_build_object('status', 'conflict');
    END IF;
    IF v_operation.status = 'confirmed' THEN
      RETURN COALESCE(v_operation.result,
        pg_catalog.jsonb_build_object('status', 'confirmed', 'operation_id', p_operation_id));
    END IF;
    IF v_operation.status <> 'prepared'
      OR v_operation.expected_content_revision <> v_revision
      OR v_operation.expires_at <= pg_catalog.clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object('status', 'conflict');
    END IF;
    RETURN public.board_import_preview_result_p(v_operation, v_revision);
  END IF;

  INSERT INTO public.board_generations(id, board_id, status, created_by)
  VALUES (v_generation_id, v_board.id, 'preparing', v_actor_id);
  INSERT INTO public.board_import_operations(
    actor_id, operation_id, board_id, generation_id, base_generation_id,
    expected_content_revision, source_sha256, status, expires_at
  ) VALUES (
    v_actor_id, p_operation_id, v_board.id, v_generation_id,
    v_board.active_generation_id, v_revision, p_source_sha256, 'staging',
    pg_catalog.clock_timestamp() + interval '1 hour'
  ) RETURNING * INTO v_operation;
  INSERT INTO public.board_import_stage_contexts(
    transaction_id, actor_id, board_id, generation_id
  ) VALUES (pg_catalog.txid_current(), v_actor_id, v_board.id, v_generation_id);

  FOR v_column IN
    SELECT value FROM pg_catalog.jsonb_array_elements(p_document->'columns') AS value
  LOOP
    INSERT INTO public.columns(board_id, generation_id, title, position)
    VALUES (
      v_board.id, v_generation_id, v_column->>'title',
      (v_column->>'position')::integer
    ) RETURNING id INTO v_column_id;
    FOR v_task IN
      SELECT value FROM pg_catalog.jsonb_array_elements(v_column->'tasks') AS value
    LOOP
      INSERT INTO public.tasks(
        id, column_id, title, description, priority, position,
        created_by, assignee_id, due_on, is_completed, completed_at, steps
      ) VALUES (
        pg_catalog.gen_random_uuid(), v_column_id, v_task->>'title',
        NULLIF(v_task->'description', 'null'::jsonb)#>>'{}',
        v_task->>'priority', (v_task->>'position')::integer,
        NULL, NULL, NULL, false, NULL, '[]'::jsonb
      );
    END LOOP;
  END LOOP;
  DELETE FROM public.board_import_stage_contexts AS context
  WHERE context.transaction_id = pg_catalog.txid_current()
    AND context.generation_id = v_generation_id;

  v_hash := public.board_import_generation_hash_p(v_board.id, v_generation_id);
  UPDATE public.board_import_operations AS operation
  SET staged_content_hash = v_hash, status = 'prepared'
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
  RETURNING * INTO v_operation;
  v_result := public.board_import_preview_result_p(v_operation, v_revision);
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.prepare_board_import_p(text, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prepare_board_import_p(text, uuid, text, jsonb)
  TO authenticated;

CREATE FUNCTION public.confirm_board_import_p(
  p_slug text,
  p_operation_id uuid,
  p_expected_content_revision bigint,
  p_source_sha256 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_operation public.board_import_operations%ROWTYPE;
  v_revision bigint;
  v_ledger public.task_attachment_quota_ledger%ROWTYPE;
  v_used_bytes bigint;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_retained_until timestamptz;
  v_result jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_operation_id IS NULL
    OR p_expected_content_revision IS NULL OR p_source_sha256 IS NULL THEN
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
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND OR v_board.owner_id IS DISTINCT FROM v_actor_id
    OR NOT public.is_board_owner(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_board.id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id
    AND operation.operation_id = p_operation_id
    AND operation.board_id = v_board.id
  FOR UPDATE;
  IF NOT FOUND OR v_operation.source_sha256 <> p_source_sha256 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_operation.status = 'confirmed' THEN
    RETURN COALESCE(v_operation.result,
      pg_catalog.jsonb_build_object('status', 'confirmed', 'operation_id', p_operation_id));
  END IF;
  IF v_operation.status = 'conflict' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'conflict');
  END IF;
  IF v_operation.status = 'cancelled' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'cancelled');
  END IF;
  IF v_operation.status = 'expired' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  IF v_operation.status <> 'prepared' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_operation.expires_at <= v_now THEN
    UPDATE public.board_import_operations AS operation
    SET status = 'expired'
    WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;
    PERFORM public.cleanup_board_import_generation_p(v_board.id, v_operation.generation_id);
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  IF p_expected_content_revision <> v_operation.expected_content_revision
    OR v_revision <> v_operation.expected_content_revision
    OR v_board.active_generation_id <> v_operation.base_generation_id THEN
    UPDATE public.board_import_operations AS operation
    SET status = 'conflict'
    WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;
    PERFORM public.cleanup_board_import_generation_p(v_board.id, v_operation.generation_id);
    RETURN pg_catalog.jsonb_build_object(
      'status', 'conflict', 'content_revision', v_revision
    );
  END IF;
  IF v_operation.generation_id IS NULL
    OR public.board_import_generation_hash_p(v_board.id, v_operation.generation_id)
      IS DISTINCT FROM v_operation.staged_content_hash THEN
    UPDATE public.board_import_operations AS operation
    SET status = 'conflict'
    WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;
    PERFORM public.cleanup_board_import_generation_p(v_board.id, v_operation.generation_id);
    RETURN pg_catalog.jsonb_build_object('status', 'conflict');
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

  v_retained_until := v_now + interval '168 hours';
  INSERT INTO public.board_generation_retention(
    board_id, generation_id, replacement_generation_id,
    retained_at, expires_at
  ) VALUES (
    v_board.id, v_board.active_generation_id, v_operation.generation_id,
    v_now, v_retained_until
  );
  UPDATE public.board_generations
  SET status = 'archived'
  WHERE board_id = v_board.id AND id = v_board.active_generation_id
    AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The current board generation could not be retained'
      USING ERRCODE = '40001';
  END IF;
  UPDATE public.board_generations
  SET status = 'active'
  WHERE board_id = v_board.id AND id = v_operation.generation_id
    AND status = 'preparing';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The prepared board generation is unavailable'
      USING ERRCODE = '40001';
  END IF;
  UPDATE public.boards AS board
  SET active_generation_id = v_operation.generation_id
  WHERE board.id = v_board.id
    AND board.active_generation_id = v_operation.base_generation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The board changed during import publication'
      USING ERRCODE = '40001';
  END IF;

  v_result := pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'content_revision', v_revision + 1,
    'retained_until', v_retained_until
  );
  UPDATE public.board_import_operations AS operation
  SET status = 'confirmed', confirmed_at = v_now, result = v_result
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_board_import_p(text, uuid, bigint, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_board_import_p(text, uuid, bigint, text)
  TO authenticated;

CREATE FUNCTION public.cleanup_expired_board_import_operations_p(p_limit integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_operation public.board_import_operations%ROWTYPE;
  v_cleaned integer := 0;
  v_deleted integer := 0;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF p_limit IS NULL OR p_limit < 1 THEN RETURN 0; END IF;
  FOR v_board_id IN
    SELECT board.id
    FROM public.boards AS board
    WHERE EXISTS (
      SELECT 1 FROM public.board_import_operations AS operation
      JOIN public.board_generations AS generation
        ON generation.board_id = operation.board_id
        AND generation.id = operation.generation_id
        AND generation.status = 'preparing'
      WHERE operation.board_id = board.id
        AND (
          (operation.status IN ('staging', 'prepared')
            AND operation.expires_at <= v_now)
          OR operation.status IN ('conflict', 'expired', 'cancelled')
        )
    )
    ORDER BY board.id
    LIMIT LEAST(p_limit, 100)
  LOOP
    PERFORM 1 FROM public.boards AS board
    WHERE board.id = v_board_id FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    FOR v_operation IN
      SELECT operation.*
      FROM public.board_import_operations AS operation
      JOIN public.board_generations AS generation
        ON generation.board_id = operation.board_id
        AND generation.id = operation.generation_id
        AND generation.status = 'preparing'
      WHERE operation.board_id = v_board_id
        AND (
          (operation.status IN ('staging', 'prepared')
            AND operation.expires_at <= v_now)
          OR operation.status IN ('conflict', 'expired', 'cancelled')
        )
      FOR UPDATE OF operation SKIP LOCKED
    LOOP
      IF v_operation.status IN ('staging', 'prepared') THEN
        UPDATE public.board_import_operations AS operation
        SET status = 'expired'
        WHERE operation.actor_id = v_operation.actor_id
          AND operation.operation_id = v_operation.operation_id;
      END IF;
      PERFORM public.cleanup_board_import_generation_p(
        v_operation.board_id, v_operation.generation_id
      );
      v_cleaned := v_cleaned + 1;
    END LOOP;
  END LOOP;

  -- Receipts reconcile uncertain commits for seven days, then their actor,
  -- board, hash, and result metadata can be discarded in bounded batches.
  WITH stale AS (
    SELECT operation.actor_id, operation.operation_id
    FROM public.board_import_operations AS operation
    WHERE (operation.status = 'confirmed'
        AND operation.confirmed_at <= v_now - interval '168 hours')
      OR (operation.status IN ('conflict', 'expired', 'cancelled')
        AND operation.expires_at <= v_now - interval '168 hours')
    ORDER BY COALESCE(operation.confirmed_at, operation.expires_at),
      operation.actor_id, operation.operation_id
    LIMIT LEAST(p_limit, 100)
    FOR UPDATE OF operation SKIP LOCKED
  )
  DELETE FROM public.board_import_operations AS operation
  USING stale
  WHERE operation.actor_id = stale.actor_id
    AND operation.operation_id = stale.operation_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  v_cleaned := v_cleaned + v_deleted;
  RETURN v_cleaned;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_expired_board_import_operations_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_board_import_operations_p(integer)
  TO service_role;

CREATE FUNCTION public.cleanup_expired_board_generation_retention_p(p_limit integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_retention public.board_generation_retention%ROWTYPE;
  v_owner_id uuid;
  v_cleaned integer := 0;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 THEN RETURN 0; END IF;
  FOR v_board_id IN
    SELECT board.id
    FROM public.boards AS board
    WHERE EXISTS (
      SELECT 1 FROM public.board_generation_retention AS retention
      JOIN public.board_generations AS generation
        ON generation.board_id = retention.board_id
        AND generation.id = retention.generation_id
        AND generation.status = 'archived'
      WHERE retention.board_id = board.id
        AND retention.expires_at <= pg_catalog.clock_timestamp()
    )
    ORDER BY board.id
    LIMIT LEAST(p_limit, 100)
  LOOP
    PERFORM 1 FROM public.boards AS board
    WHERE board.id = v_board_id FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN CONTINUE; END IF;
    SELECT board.owner_id INTO v_owner_id
    FROM public.boards AS board WHERE board.id = v_board_id;
    FOR v_retention IN
      SELECT retention.*
      FROM public.board_generation_retention AS retention
      JOIN public.board_generations AS generation
        ON generation.board_id = retention.board_id
        AND generation.id = retention.generation_id
        AND generation.status = 'archived'
      WHERE retention.board_id = v_board_id
        AND retention.expires_at <= pg_catalog.clock_timestamp()
      ORDER BY retention.expires_at, retention.generation_id
      FOR UPDATE OF retention SKIP LOCKED
    LOOP
      UPDATE public.task_attachments AS attachment
      SET state = 'cleanup_pending',
          deleted_at = v_retention.retained_at,
          deleted_by = v_owner_id,
          deletion_cause = 'admin_cleanup',
          expires_at = v_retention.expires_at
      FROM public.tasks AS task
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE attachment.task_id = task.id
        AND attachment.board_id = v_board_id
        AND column_row.board_id = v_board_id
        AND column_row.generation_id = v_retention.generation_id
        AND attachment.state IN ('active', 'recoverable');
      IF NOT EXISTS (
        SELECT 1
        FROM public.task_attachments AS attachment
        JOIN public.tasks AS task ON task.id = attachment.task_id
        JOIN public.columns AS column_row ON column_row.id = task.column_id
        WHERE attachment.board_id = v_board_id
          AND column_row.board_id = v_board_id
          AND column_row.generation_id = v_retention.generation_id
          AND attachment.state <> 'purged'
      ) THEN
        PERFORM public.cleanup_board_import_generation_p(
          v_board_id, v_retention.generation_id
        );
      END IF;
      v_cleaned := v_cleaned + 1;
    END LOOP;
  END LOOP;
  RETURN v_cleaned;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_expired_board_generation_retention_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_board_generation_retention_p(integer)
  TO service_role;

COMMIT;
