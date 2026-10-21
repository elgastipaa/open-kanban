\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE anon;

-- Exercise the same RPC boundary as an anonymous Supabase caller.
DO $$
DECLARE
  statement text;
  denied boolean;
BEGIN
  FOREACH statement IN ARRAY ARRAY[
    'SELECT public.delete_board_p(''00000000-0000-0000-0000-000000000001''::uuid)',
    'SELECT public.delete_column_p(''00000000-0000-0000-0000-000000000001''::uuid)',
    'SELECT public.delete_task_p(''00000000-0000-0000-0000-000000000001''::uuid)',
    'SELECT public.create_column_p(''00000000-0000-0000-0000-000000000001''::uuid, ''Test'', 0)',
    'SELECT public.create_task_p(''00000000-0000-0000-0000-000000000001''::uuid, ''Test'')',
    'SELECT public.update_column_p(''00000000-0000-0000-0000-000000000001''::uuid)',
    'SELECT public.update_task_p(''00000000-0000-0000-0000-000000000001''::uuid)',
    'SELECT public.update_column_positions_p(''[]''::jsonb)',
    'SELECT public.update_task_positions_p(''[]''::jsonb)'
  ] LOOP
    denied := false;
    BEGIN
      EXECUTE statement;
    EXCEPTION WHEN undefined_function OR insufficient_privilege THEN
      denied := true;
    END;
    IF NOT denied THEN
      RAISE EXCEPTION 'Legacy mutation is callable without a slug: %', statement;
    END IF;
  END LOOP;
END;
$$;
\echo 'PASS: legacy mutations cannot bypass slug checks'

DO $$
DECLARE
  source_board public.boards;
  other_board public.boards;
  source_column public.columns;
  other_column public.columns;
  task public.tasks;
  denied boolean := false;
BEGIN
  source_board := public.create_board_p('test-source');
  other_board := public.create_board_p('test-other');
  source_column := public.create_column_p('test-source', source_board.id, 'To Do', 0);
  other_column := public.create_column_p('test-other', other_board.id, 'Private', 0);
  task := public.create_task_p('test-source', source_column.id, 'Fictional task');
  BEGIN
    PERFORM public.update_task_p('test-source', task.id, p_column_id => other_column.id);
  EXCEPTION WHEN check_violation THEN
    denied := true;
  END;
  IF NOT denied THEN
    RAISE EXCEPTION 'Task can be moved into another board';
  END IF;
  IF public.get_full_board_p('test-source')->'columns'->0->'tasks'->0->>'title' IS DISTINCT FROM 'Fictional task' THEN
    RAISE EXCEPTION 'Rejected move changed the source board';
  END IF;
END;
$$;
\echo 'PASS: individual moves cannot cross boards'

DO $$
DECLARE
  source_column public.columns;
  other_column public.columns;
  first_task public.tasks;
  second_task public.tasks;
  denied boolean := false;
BEGIN
  SELECT * INTO source_column FROM public.get_columns_p((SELECT id FROM public.get_board_p('test-source'))) LIMIT 1;
  SELECT * INTO other_column FROM public.get_columns_p((SELECT id FROM public.get_board_p('test-other'))) LIMIT 1;
  SELECT * INTO first_task FROM public.get_tasks_by_board_p((SELECT id FROM public.get_board_p('test-source'))) LIMIT 1;
  second_task := public.create_task_p('test-source', source_column.id, 'Second task', p_position => 1);
  BEGIN
    PERFORM public.update_task_positions_p('test-source', jsonb_build_array(
      jsonb_build_object('id', first_task.id, 'position', 1),
      jsonb_build_object('id', second_task.id, 'position', 0, 'column_id', other_column.id)
    ));
  EXCEPTION WHEN check_violation THEN
    denied := true;
  END;
  IF NOT denied THEN
    RAISE EXCEPTION 'Batch can move a task into another board';
  END IF;
  IF public.get_full_board_p('test-source')->'columns'->0->'tasks'->0->>'title' IS DISTINCT FROM 'Fictional task' THEN
    RAISE EXCEPTION 'Rejected batch partially changed the source board';
  END IF;
END;
$$;
\echo 'PASS: cross-board batches are rejected atomically'

DO $$
DECLARE
  board_id uuid;
  source_column public.columns;
  destination public.columns;
  task public.tasks;
  data json;
  denied boolean := false;
BEGIN
  SELECT id INTO board_id FROM public.get_board_p('test-source');
  SELECT * INTO source_column FROM public.get_columns_p(board_id) LIMIT 1;
  destination := public.create_column_p('test-source', board_id, 'Doing', 1);
  SELECT * INTO task FROM public.get_tasks_by_board_p(board_id) WHERE title = 'Fictional task';
  PERFORM public.update_task_p('test-source', task.id,
    p_title => 'Edited task', p_description => 'Fictional details',
    p_priority => 'urgent', p_column_id => destination.id, p_position => 0);
  data := public.get_full_board_p('test-source');
  IF data->'columns'->1->'tasks'->0->>'title' IS DISTINCT FROM 'Edited task'
    OR data->'columns'->1->'tasks'->0->>'priority' IS DISTINCT FROM 'urgent'
    OR data->'columns'->1->'tasks'->0->>'description' IS DISTINCT FROM 'Fictional details' THEN
    RAISE EXCEPTION 'Same-board task edit/move did not persist';
  END IF;
  PERFORM public.update_task_positions_p('test-source', jsonb_build_array(
    jsonb_build_object('id', task.id, 'column_id', source_column.id, 'position', 0)
  ));
  PERFORM public.update_column_p('test-source', destination.id, p_title => 'Done');
  PERFORM public.batch_toggle_columns_collapse_p('test-source', true);
  IF public.get_full_board_p('test-source')->'columns'->1->>'title' IS DISTINCT FROM 'Done'
    OR public.get_full_board_p('test-source')->'columns'->1->>'is_collapsed' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Column edit/collapse did not persist';
  END IF;
  PERFORM public.update_column_positions_p('test-source', jsonb_build_array(
    jsonb_build_object('id', destination.id, 'position', 0),
    jsonb_build_object('id', source_column.id, 'position', 1)
  ));
  IF public.get_full_board_p('test-source')->'columns'->0->>'title' IS DISTINCT FROM 'Done' THEN
    RAISE EXCEPTION 'Column reordering did not persist';
  END IF;

  -- The caller knows one slug but cannot use it to mutate another board's task.
  PERFORM public.update_task_p('test-other', task.id, p_title => 'Corrupted');
  PERFORM public.delete_task_p('test-other', task.id);
  SELECT * INTO task FROM public.get_tasks_by_board_p(board_id) WHERE title = 'Edited task';
  IF task.id IS NULL THEN RAISE EXCEPTION 'Wrong slug changed or deleted a task'; END IF;

  IF (SELECT count(*) FROM public.boards) <> 0
    OR (SELECT count(*) FROM public.columns) <> 0
    OR (SELECT count(*) FROM public.tasks) <> 0 THEN
    RAISE EXCEPTION 'Direct table reads bypass RLS';
  END IF;
  BEGIN
    INSERT INTO public.boards(slug) VALUES ('direct-insert');
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Direct table insert bypasses RLS'; END IF;

  PERFORM public.delete_column_p('test-source', source_column.id);
  IF EXISTS (SELECT 1 FROM public.get_tasks_by_board_p(board_id)) THEN
    RAISE EXCEPTION 'Deleting a column did not cascade to its tasks';
  END IF;
  PERFORM public.delete_board_p('test-source', board_id);
  IF public.get_full_board_p('test-source') IS NOT NULL THEN
    RAISE EXCEPTION 'Deleted board is still readable';
  END IF;
  IF public.get_full_board_p('test-other')->'columns'->0->>'title' IS DISTINCT FROM 'Private' THEN
    RAISE EXCEPTION 'Deletion affected another board';
  END IF;
END;
$$;
\echo 'PASS: original CRUD, ordering, collapse, RLS and cascades'

-- A caller-controlled temporary relation must not shadow the real board table.
SET LOCAL search_path = pg_temp, public;
CREATE TEMP TABLE boards (id uuid, slug text, created_at timestamptz, updated_at timestamptz);
INSERT INTO boards VALUES (gen_random_uuid(), 'shadow', now(), now());
DO $$
BEGIN
  IF public.get_full_board_p('shadow') IS NOT NULL THEN
    RAISE EXCEPTION 'Caller search_path shadows the board table';
  END IF;
END;
$$;
\echo 'PASS: caller search_path cannot shadow RPC data'

RESET ROLE;
SET LOCAL ROLE authenticated;
DO $$
DECLARE
  denied boolean := false;
BEGIN
  BEGIN
    PERFORM public.get_full_board_p('test-other');
  EXCEPTION WHEN insufficient_privilege THEN
    denied := true;
  END;
  IF NOT denied THEN RAISE EXCEPTION 'Unexpected role can execute anonymous RPCs'; END IF;
END;
$$;
\echo 'PASS: no implicit RPC grant to authenticated role (Auth not enabled)'

ROLLBACK;
