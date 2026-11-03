-- Task field edits and movement are separate actions. A movement may change
-- only column_id/position; an edit uses JSON key presence so null can clear
-- description while an omitted key leaves it unchanged.
BEGIN;

DROP FUNCTION IF EXISTS public.update_task_p(text, uuid, text, text, text, uuid, integer);

CREATE OR REPLACE FUNCTION public.edit_task_fields_p(
  p_slug text,
  p_id uuid,
  p_updates jsonb
)
RETURNS public.tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  result public.tasks;
  v_board_id uuid;
BEGIN
  IF p_updates IS NULL OR jsonb_typeof(p_updates) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Task edits must be an object' USING ERRCODE = '23514';
  END IF;

  IF p_updates = '{}'::jsonb OR p_updates - ARRAY['title', 'description', 'priority'] <> '{}'::jsonb THEN
    RAISE EXCEPTION 'Task edit contains no fields or unsupported fields' USING ERRCODE = '23514';
  END IF;

  IF p_updates ? 'title' AND (
    jsonb_typeof(p_updates->'title') IS DISTINCT FROM 'string'
    OR length(btrim(p_updates->>'title')) = 0
    OR length(p_updates->>'title') > 200
  ) THEN
    RAISE EXCEPTION 'Task title is invalid' USING ERRCODE = '23514';
  END IF;

  IF p_updates ? 'description' AND (
    jsonb_typeof(p_updates->'description') NOT IN ('string', 'null')
    OR length(p_updates->>'description') > 2000
  ) THEN
    RAISE EXCEPTION 'Task description is invalid' USING ERRCODE = '23514';
  END IF;

  IF p_updates ? 'priority' AND (
    jsonb_typeof(p_updates->'priority') IS DISTINCT FROM 'string'
    OR p_updates->>'priority' NOT IN ('low', 'medium', 'high', 'urgent')
  ) THEN
    RAISE EXCEPTION 'Task priority is invalid' USING ERRCODE = '23514';
  END IF;

  SELECT id INTO v_board_id FROM public.boards WHERE slug = p_slug;

  UPDATE public.tasks AS t SET
    title = CASE WHEN p_updates ? 'title' THEN p_updates->>'title' ELSE t.title END,
    description = CASE WHEN p_updates ? 'description' THEN p_updates->>'description' ELSE t.description END,
    priority = CASE WHEN p_updates ? 'priority' THEN p_updates->>'priority' ELSE t.priority END
  WHERE t.id = p_id
    AND t.column_id IN (SELECT id FROM public.columns WHERE board_id = v_board_id)
  RETURNING t.* INTO result;

  RETURN result;
END;
$$;

DROP FUNCTION public.update_task_positions_p(text, jsonb);

CREATE FUNCTION public.update_task_positions_p(p_slug text, p_updates jsonb)
RETURNS SETOF public.tasks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  item jsonb;
  v_board_id uuid;
  v_task_id uuid;
  v_target_column_id uuid;
  v_task_ids uuid[] := ARRAY[]::uuid[];
BEGIN
  IF p_updates IS NULL OR jsonb_typeof(p_updates) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Task position updates must be an array' USING ERRCODE = '23514';
  END IF;

  IF jsonb_array_length(p_updates) > 200 THEN
    RAISE EXCEPTION 'Batch size exceeds maximum of 200 items';
  END IF;

  IF jsonb_array_length(p_updates) = 0 THEN
    RETURN;
  END IF;

  SELECT id INTO v_board_id FROM public.boards WHERE slug = p_slug;
  IF v_board_id IS NULL THEN
    RETURN;
  END IF;

  IF (
    SELECT count(*) <> count(DISTINCT value->>'id')
    FROM jsonb_array_elements(p_updates) AS updates(value)
  ) THEN
    RAISE EXCEPTION 'Task position batch contains duplicate IDs' USING ERRCODE = '23514';
  END IF;

  -- Validate every item and reference before the first row is changed.
  FOR item IN SELECT value FROM jsonb_array_elements(p_updates) AS updates(value)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR (item - ARRAY['id', 'column_id', 'position']) <> '{}'::jsonb
      OR NOT (item ? 'id')
      OR NOT (item ? 'position')
      OR jsonb_typeof(item->'id') IS DISTINCT FROM 'string'
      OR jsonb_typeof(item->'position') IS DISTINCT FROM 'number'
      OR (item->>'position') !~ '^[0-9]+$'
      OR ((item ? 'column_id') AND jsonb_typeof(item->'column_id') IS DISTINCT FROM 'string')
    THEN
      RAISE EXCEPTION 'Task position batch contains an invalid item' USING ERRCODE = '23514';
    END IF;

    v_task_id := (item->>'id')::uuid;
    v_task_ids := array_append(v_task_ids, v_task_id);
    IF NOT EXISTS (
      SELECT 1 FROM public.tasks AS t
      JOIN public.columns AS c ON c.id = t.column_id
      WHERE t.id = v_task_id AND c.board_id = v_board_id
    ) THEN
      RAISE EXCEPTION 'Task does not belong to this board' USING ERRCODE = '23514';
    END IF;

    IF item ? 'column_id' THEN
      v_target_column_id := (item->>'column_id')::uuid;
      IF NOT EXISTS (
        SELECT 1 FROM public.columns
        WHERE id = v_target_column_id AND board_id = v_board_id
      ) THEN
        RAISE EXCEPTION 'Destination column does not belong to this board' USING ERRCODE = '23514';
      END IF;
    END IF;
  END LOOP;

  FOR item IN SELECT value FROM jsonb_array_elements(p_updates) AS updates(value)
  LOOP
    v_task_id := (item->>'id')::uuid;
    UPDATE public.tasks AS t SET
      column_id = CASE WHEN item ? 'column_id' THEN (item->>'column_id')::uuid ELSE t.column_id END,
      position = (item->>'position')::integer
    WHERE t.id = v_task_id
      AND t.column_id IN (SELECT id FROM public.columns WHERE board_id = v_board_id);

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Task does not belong to this board' USING ERRCODE = '23514';
    END IF;
  END LOOP;

  RETURN QUERY
    SELECT t.* FROM public.tasks AS t
    WHERE t.id = ANY(v_task_ids)
    ORDER BY array_position(v_task_ids, t.id);
END;
$$;

REVOKE ALL ON FUNCTION public.edit_task_fields_p(text, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.edit_task_fields_p(text, uuid, jsonb) TO anon;
REVOKE ALL ON FUNCTION public.update_task_positions_p(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_task_positions_p(text, jsonb) TO anon;

NOTIFY pgrst, 'reload schema';
COMMIT;
