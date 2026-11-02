BEGIN;

-- Keep only the label identities beside the existing seven-day task tombstone.
-- The assignment rows themselves still cascade with the deleted task.
ALTER TABLE public.task_deletions
  ADD COLUMN label_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];

CREATE FUNCTION public.capture_task_recovery_label_ids_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  UPDATE public.task_deletions AS deletion
  SET label_ids = coalesce((
    SELECT array_agg(assignment.label_id ORDER BY assignment.label_id)
    FROM public.board_label_task_assignments AS assignment
    WHERE assignment.task_id = OLD.id
  ), ARRAY[]::uuid[])
  WHERE deletion.task_id = OLD.id
    AND deletion.state = 'deleted'
    AND deletion.task_snapshot IS NOT NULL;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_task_recovery_label_ids_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER tasks_capture_recovery_label_ids
BEFORE DELETE ON public.tasks
FOR EACH ROW EXECUTE FUNCTION public.capture_task_recovery_label_ids_p();

-- Purge locks the label row while deleting it. Recovery already owns the board
-- and tombstone locks; take compatible label locks in ID order before the
-- assignment insert so a concurrent purge either waits or is revalidated away.
CREATE FUNCTION public.lock_existing_board_label_ids_for_recovery_p(
  p_board_id uuid,
  p_generation_id uuid,
  p_label_ids uuid[]
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_label_id uuid;
BEGIN
  FOR v_label_id IN
    SELECT label.id
    FROM public.board_labels AS label
    WHERE label.board_id = p_board_id
      AND label.generation_id = p_generation_id
      AND label.id = ANY(p_label_ids)
    ORDER BY label.id
    FOR KEY SHARE OF label
  LOOP
    NULL;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_existing_board_label_ids_for_recovery_p(uuid, uuid, uuid[])
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.restore_task_label_ids_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_deletion public.task_deletions%ROWTYPE;
  v_board_id uuid;
  v_generation_id uuid;
BEGIN
  SELECT deletion.* INTO v_deletion
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = NEW.id
    AND deletion.state = 'deleted'
    AND deletion.task_snapshot IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND OR cardinality(v_deletion.label_ids) = 0 THEN
    RETURN NEW;
  END IF;

  SELECT column_row.board_id, column_row.generation_id
  INTO v_board_id, v_generation_id
  FROM public.columns AS column_row
  WHERE column_row.id = NEW.column_id;
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  PERFORM public.lock_existing_board_label_ids_for_recovery_p(
    v_board_id, v_generation_id, v_deletion.label_ids
  );

  INSERT INTO public.board_label_task_assignments (
    board_id, generation_id, label_id, task_id
  )
  SELECT v_board_id, v_generation_id, label.id, NEW.id
  FROM unnest(v_deletion.label_ids) AS selected(label_id)
  JOIN public.board_labels AS label
    ON label.id = selected.label_id
    AND label.board_id = v_board_id
    AND label.generation_id = v_generation_id
  ON CONFLICT (task_id, label_id) DO NOTHING;

  UPDATE public.task_deletions AS deletion
  SET label_ids = ARRAY[]::uuid[]
  WHERE deletion.task_id = NEW.id
    AND deletion.state = 'deleted';
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.restore_task_label_ids_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER tasks_restore_recovery_label_ids
AFTER INSERT ON public.tasks
FOR EACH ROW EXECUTE FUNCTION public.restore_task_label_ids_p();

CREATE FUNCTION public.clear_terminal_task_recovery_label_ids_p()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NEW.state <> 'deleted' THEN
    NEW.label_ids := ARRAY[]::uuid[];
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.clear_terminal_task_recovery_label_ids_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER task_deletions_clear_terminal_label_ids
BEFORE UPDATE OF state ON public.task_deletions
FOR EACH ROW EXECUTE FUNCTION public.clear_terminal_task_recovery_label_ids_p();

ALTER TABLE public.birthday_deletions
  ADD COLUMN label_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[];

CREATE FUNCTION public.board_label_tombstone_capacity_reasons_p(
  p_board_id uuid,
  p_generation_id uuid,
  p_label_id uuid
)
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT coalesce(array_agg(reason ORDER BY reason), ARRAY[]::text[])
  FROM (
    SELECT 'task_recovery_limit'::text AS reason
    WHERE EXISTS (
      SELECT 1
      FROM public.task_deletions AS deletion
      WHERE deletion.board_id = p_board_id
        AND deletion.state = 'deleted'
        AND deletion.task_snapshot IS NOT NULL
        AND deletion.expires_at > clock_timestamp()
        AND p_label_id = ANY(deletion.label_ids)
        AND (
          SELECT count(DISTINCT active_candidate.label_id)
          FROM unnest(deletion.label_ids) AS active_candidate(label_id)
          JOIN public.board_labels AS active_label
            ON active_label.id = active_candidate.label_id
            AND active_label.board_id = p_board_id
            AND active_label.generation_id = p_generation_id
            AND active_label.deleted_at IS NULL
          WHERE active_candidate.label_id <> p_label_id
        ) >= 10
    )
    UNION ALL
    SELECT 'birthday_recovery_limit'::text AS reason
    WHERE EXISTS (
      SELECT 1
      FROM public.birthday_deletions AS deletion
      WHERE deletion.board_id = p_board_id
        AND deletion.generation_id = p_generation_id
        AND deletion.state = 'deleted'
        AND deletion.birthday_snapshot IS NOT NULL
        AND deletion.expires_at > clock_timestamp()
        AND p_label_id = ANY(deletion.label_ids)
        AND (
          SELECT count(DISTINCT active_candidate.label_id)
          FROM unnest(deletion.label_ids) AS active_candidate(label_id)
          JOIN public.board_labels AS active_label
            ON active_label.id = active_candidate.label_id
            AND active_label.board_id = p_board_id
            AND active_label.generation_id = p_generation_id
            AND active_label.deleted_at IS NULL
          WHERE active_candidate.label_id <> p_label_id
        ) >= 10
    )
  ) AS reasons;
$$;
REVOKE ALL ON FUNCTION public.board_label_tombstone_capacity_reasons_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.capture_birthday_recovery_label_ids_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  UPDATE public.birthday_deletions AS deletion
  SET label_ids = coalesce((
    SELECT array_agg(assignment.label_id ORDER BY assignment.label_id)
    FROM public.board_label_birthday_assignments AS assignment
    WHERE assignment.birthday_id = OLD.id
  ), ARRAY[]::uuid[])
  WHERE deletion.birthday_id = OLD.id
    AND deletion.state = 'deleted'
    AND deletion.birthday_snapshot IS NOT NULL;
  RETURN OLD;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_birthday_recovery_label_ids_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER birthdays_capture_recovery_label_ids
BEFORE DELETE ON public.board_birthdays
FOR EACH ROW EXECUTE FUNCTION public.capture_birthday_recovery_label_ids_p();

CREATE FUNCTION public.restore_birthday_label_ids_p()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_deletion public.birthday_deletions%ROWTYPE;
BEGIN
  SELECT deletion.* INTO v_deletion
  FROM public.birthday_deletions AS deletion
  WHERE deletion.birthday_id = NEW.id
    AND deletion.state = 'deleted'
    AND deletion.birthday_snapshot IS NOT NULL
  FOR UPDATE;
  IF NOT FOUND OR cardinality(v_deletion.label_ids) = 0 THEN
    RETURN NEW;
  END IF;

  PERFORM public.lock_existing_board_label_ids_for_recovery_p(
    NEW.board_id, NEW.generation_id, v_deletion.label_ids
  );

  INSERT INTO public.board_label_birthday_assignments (
    board_id, generation_id, label_id, birthday_id
  )
  SELECT NEW.board_id, NEW.generation_id, label.id, NEW.id
  FROM unnest(v_deletion.label_ids) AS selected(label_id)
  JOIN public.board_labels AS label
    ON label.id = selected.label_id
    AND label.board_id = NEW.board_id
    AND label.generation_id = NEW.generation_id
  ON CONFLICT (birthday_id, label_id) DO NOTHING;

  UPDATE public.birthday_deletions AS deletion
  SET label_ids = ARRAY[]::uuid[]
  WHERE deletion.birthday_id = NEW.id
    AND deletion.state = 'deleted';
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.restore_birthday_label_ids_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER birthdays_restore_recovery_label_ids
AFTER INSERT ON public.board_birthdays
FOR EACH ROW EXECUTE FUNCTION public.restore_birthday_label_ids_p();

CREATE FUNCTION public.clear_terminal_birthday_recovery_label_ids_p()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
  IF NEW.state <> 'deleted' THEN
    NEW.label_ids := ARRAY[]::uuid[];
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.clear_terminal_birthday_recovery_label_ids_p()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER birthday_deletions_clear_terminal_label_ids
BEFORE UPDATE OF state ON public.birthday_deletions
FOR EACH ROW EXECUTE FUNCTION public.clear_terminal_birthday_recovery_label_ids_p();

COMMIT;
