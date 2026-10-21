-- Keep the anonymous URL-based product while closing obsolete RPC bypasses.
-- Apply after 001–011. No table/data removal; no CASCADE.
BEGIN;

DROP FUNCTION IF EXISTS public.delete_board_p(uuid);
DROP FUNCTION IF EXISTS public.delete_column_p(uuid);
DROP FUNCTION IF EXISTS public.delete_task_p(uuid);
DROP FUNCTION IF EXISTS public.create_column_p(uuid, text, integer);
DROP FUNCTION IF EXISTS public.create_task_p(uuid, text, text, text, integer);
DROP FUNCTION IF EXISTS public.update_column_p(uuid, text, integer, boolean);
DROP FUNCTION IF EXISTS public.update_task_p(uuid, text, text, text, uuid, integer);
DROP FUNCTION IF EXISTS public.update_column_positions_p(jsonb);
DROP FUNCTION IF EXISTS public.update_task_positions_p(jsonb);

CREATE OR REPLACE FUNCTION public.update_task_p(
  p_slug text,
  p_id uuid,
  p_title text DEFAULT NULL,
  p_description text DEFAULT NULL,
  p_priority text DEFAULT NULL,
  p_column_id uuid DEFAULT NULL,
  p_position integer DEFAULT NULL
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
  SELECT id INTO v_board_id FROM public.boards WHERE slug = p_slug;
  IF p_column_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.columns WHERE id = p_column_id AND board_id = v_board_id
  ) THEN
    RAISE EXCEPTION 'Destination column does not belong to this board' USING ERRCODE = '23514';
  END IF;

  UPDATE public.tasks AS t SET
    title = COALESCE(p_title, t.title),
    description = COALESCE(p_description, t.description),
    priority = COALESCE(p_priority, t.priority),
    column_id = COALESCE(p_column_id, t.column_id),
    position = COALESCE(p_position, t.position)
  WHERE t.id = p_id
    AND t.column_id IN (SELECT id FROM public.columns WHERE board_id = v_board_id)
  RETURNING t.* INTO result;
  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_task_positions_p(p_slug text, p_updates jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  item jsonb;
  v_board_id uuid;
BEGIN
  IF jsonb_array_length(p_updates) > 200 THEN
    RAISE EXCEPTION 'Batch size exceeds maximum of 200 items';
  END IF;
  SELECT id INTO v_board_id FROM public.boards WHERE slug = p_slug;
  IF v_board_id IS NULL THEN RETURN; END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_updates)
  LOOP
    IF item->>'column_id' IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.columns
      WHERE id = (item->>'column_id')::uuid AND board_id = v_board_id
    ) THEN
      RAISE EXCEPTION 'Destination column does not belong to this board' USING ERRCODE = '23514';
    END IF;

    UPDATE public.tasks AS t SET
      column_id = COALESCE((item->>'column_id')::uuid, t.column_id),
      position = (item->>'position')::integer,
      title = COALESCE(item->>'title', t.title),
      description = COALESCE(item->>'description', t.description),
      priority = COALESCE(item->>'priority', t.priority)
    WHERE t.id = (item->>'id')::uuid
      AND t.column_id IN (SELECT id FROM public.columns WHERE board_id = v_board_id);
  END LOOP;
END;
$$;

-- Public roles cannot create objects that shadow names used by RPC functions.
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO anon;

-- Scope privilege changes to OpenKanban's API, not every function in public.
DO $$
DECLARE
  signature text;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'public.get_board_p(text)',
    'public.get_full_board_p(text)',
    'public.create_board_p(text)',
    'public.delete_board_p(text, uuid)',
    'public.get_columns_p(uuid)',
    'public.create_column_p(text, uuid, text, integer)',
    'public.update_column_p(text, uuid, text, integer, boolean)',
    'public.delete_column_p(text, uuid)',
    'public.update_column_positions_p(text, jsonb)',
    'public.batch_toggle_columns_collapse_p(text, boolean)',
    'public.get_tasks_by_board_p(uuid)',
    'public.create_task_p(text, uuid, text, text, text, integer)',
    'public.update_task_p(text, uuid, text, text, text, uuid, integer)',
    'public.delete_task_p(text, uuid)',
    'public.update_task_positions_p(text, jsonb)'
  ] LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = pg_catalog, public, pg_temp', signature);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', signature);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', signature);
  END LOOP;
END;
$$;

COMMIT;
