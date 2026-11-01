\set ON_ERROR_STOP on

UPDATE auth.identities
SET identity_data = identity_data || jsonb_build_object('name', 'Colaborador habilitado')
WHERE user_id = '40000000-0000-4000-8000-000000000001';
UPDATE auth.identities
SET identity_data = identity_data || jsonb_build_object('name', 'Propietario del tablero')
WHERE user_id = '40000000-0000-4000-8000-000000000002';

CREATE TEMP TABLE issue13_task_fixture (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid
);
GRANT SELECT, INSERT ON issue13_task_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_purposes text[] := ARRAY[
    'due_first', 'due_tie_a', 'due_tie_b', 'no_due',
    'completed_recent', 'completed_old', 'assigned_to_collaborator',
    'assignment_target', 'race_target'
  ];
  v_titles text[] := ARRAY[
    'Vence primero', 'Empate A', 'Empate B', 'Sin fecha',
    'Completada reciente', 'Completada anterior', 'De otra persona',
    'Asignación editable', 'Asignación concurrente'
  ];
  v_index integer;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Issue 13 board A', 'America/Argentina/Buenos_Aires',
    '13000000-0000-4000-8000-000000000001'
  );
  SELECT * INTO v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo de A', 0);
  INSERT INTO pg_temp.issue13_task_fixture(purpose, board_id, slug, column_id)
  VALUES ('board_a', v_board.id, v_board.slug, v_column.id);

  FOR v_index IN 1..array_length(v_purposes, 1) LOOP
    v_task := public.create_task_p(
      ('13000000-0000-4000-8000-' || lpad(v_index::text, 12, '0'))::uuid,
      v_board.id,
      v_column.id,
      v_titles[v_index]
    );
    INSERT INTO pg_temp.issue13_task_fixture(
      purpose, board_id, slug, column_id, task_id
    ) VALUES (
      v_purposes[v_index], v_board.id, v_board.slug, v_column.id,
      (v_task->>'task_id')::uuid
    );
  END LOOP;
END;
$$;
COMMIT;

RESET ROLE;
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, '40000000-0000-4000-8000-000000000001', 'collaborator'
FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a';
-- A member without enabled application access must not be assignable or listed.
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, '40000000-0000-4000-8000-000000000003', 'collaborator'
FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a';

SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', false);
UPDATE public.tasks AS task SET
  assignee_id = '40000000-0000-4000-8000-000000000002',
  due_on = CASE fixture.purpose
    WHEN 'due_first' THEN DATE '2026-11-02'
    WHEN 'due_tie_a' THEN DATE '2026-11-03'
    WHEN 'due_tie_b' THEN DATE '2026-11-03'
    ELSE NULL
  END,
  created_at = CASE fixture.purpose
    WHEN 'due_first' THEN TIMESTAMPTZ '2026-10-03 00:00:00+00'
    WHEN 'due_tie_a' THEN TIMESTAMPTZ '2026-10-01 12:00:00+00'
    WHEN 'due_tie_b' THEN TIMESTAMPTZ '2026-10-01 12:00:00+00'
    WHEN 'no_due' THEN TIMESTAMPTZ '2026-10-04 00:00:00+00'
    WHEN 'completed_recent' THEN TIMESTAMPTZ '2026-10-05 00:00:00+00'
    WHEN 'completed_old' THEN TIMESTAMPTZ '2026-10-06 00:00:00+00'
    WHEN 'assignment_target' THEN TIMESTAMPTZ '2026-10-07 00:00:00+00'
    WHEN 'race_target' THEN TIMESTAMPTZ '2026-10-08 00:00:00+00'
    ELSE TIMESTAMPTZ '2026-10-09 00:00:00+00'
  END,
  is_completed = fixture.purpose IN ('completed_recent', 'completed_old'),
  completed_at = CASE fixture.purpose
    WHEN 'completed_recent' THEN TIMESTAMPTZ '2026-10-31 00:00:00+00'
    WHEN 'completed_old' THEN TIMESTAMPTZ '2026-10-29 00:00:00+00'
    ELSE NULL
  END
FROM pg_temp.issue13_task_fixture AS fixture
WHERE fixture.task_id = task.id
  AND fixture.purpose <> 'assigned_to_collaborator';
UPDATE public.tasks AS task
SET assignee_id = '40000000-0000-4000-8000-000000000001'
FROM pg_temp.issue13_task_fixture AS fixture
WHERE fixture.task_id = task.id
  AND fixture.purpose = 'assigned_to_collaborator';

-- The collaborator owns a second board. Its tasks stay private from board A's
-- owner even though both actors are enabled for the application.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Issue 13 board B', 'Europe/Madrid',
    '13000000-0000-4000-8000-000000000002'
  );
  SELECT * INTO v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo de B', 0);
  v_task := public.create_task_p(
    '13000000-0000-4000-8000-000000000020',
    v_board.id,
    v_column.id,
    'Tarea del tablero B'
  );
  INSERT INTO pg_temp.issue13_task_fixture(
    purpose, board_id, slug, column_id, task_id
  ) VALUES (
    'board_b', v_board.id, v_board.slug, v_column.id, (v_task->>'task_id')::uuid
  );
END;
$$;
COMMIT;
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', false);
UPDATE public.tasks AS task
SET assignee_id = '40000000-0000-4000-8000-000000000001', due_on = DATE '2026-11-01'
FROM pg_temp.issue13_task_fixture AS fixture
WHERE fixture.task_id = task.id AND fixture.purpose = 'board_b';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_due_ids uuid[];
  v_created_ids uuid[];
  v_expected_due_ids uuid[];
  v_expected_created_ids uuid[];
  v_entry jsonb;
  v_assignable_ids uuid[];
  v_assignable_names text[];
  v_assignment jsonb;
  v_conflict jsonb;
  v_edit jsonb;
  v_rejected boolean := false;
  v_payload_collision boolean := false;
BEGIN
  SELECT array_agg((result.entry->'task'->>'id')::uuid ORDER BY result.ordinality)
  INTO v_due_ids
  FROM public.get_my_tasks_p('due') WITH ORDINALITY AS result(entry, ordinality);
  SELECT array_agg((result.entry->'task'->>'id')::uuid ORDER BY result.ordinality)
  INTO v_created_ids
  FROM public.get_my_tasks_p('created') WITH ORDINALITY AS result(entry, ordinality);

  SELECT ARRAY[
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'due_first'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture
      WHERE purpose IN ('due_tie_a', 'due_tie_b') ORDER BY task_id LIMIT 1),
    (SELECT task_id FROM pg_temp.issue13_task_fixture
      WHERE purpose IN ('due_tie_a', 'due_tie_b') ORDER BY task_id OFFSET 1 LIMIT 1),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'no_due'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'race_target'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'completed_recent'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'completed_old')
  ] INTO v_expected_due_ids;
  IF v_due_ids IS DISTINCT FROM v_expected_due_ids THEN
    RAISE EXCEPTION 'Due ordering, null placement, or recent completion order is wrong: %', v_due_ids;
  END IF;

  SELECT ARRAY[
    (SELECT task_id FROM pg_temp.issue13_task_fixture
      WHERE purpose IN ('due_tie_a', 'due_tie_b') ORDER BY task_id LIMIT 1),
    (SELECT task_id FROM pg_temp.issue13_task_fixture
      WHERE purpose IN ('due_tie_a', 'due_tie_b') ORDER BY task_id OFFSET 1 LIMIT 1),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'due_first'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'no_due'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'race_target'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'completed_recent'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'completed_old')
  ] INTO v_expected_created_ids;
  IF v_created_ids IS DISTINCT FROM v_expected_created_ids THEN
    RAISE EXCEPTION 'Creation ordering or completed-recent ordering is wrong: %', v_created_ids;
  END IF;

  SELECT result.entry INTO v_entry
  FROM public.get_my_tasks_p('due') AS result(entry)
  WHERE result.entry->'task'->>'id' = (
    SELECT task_id::text FROM pg_temp.issue13_task_fixture WHERE purpose = 'due_first'
  );
  IF v_entry->'board'->>'slug' IS DISTINCT FROM (
       SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'
     )
    OR v_entry->'board'->>'time_zone' IS DISTINCT FROM 'America/Argentina/Buenos_Aires'
    OR v_entry->'column'->>'title' IS DISTINCT FROM 'Trabajo de A'
    OR v_entry->'task'->>'column_id' IS DISTINCT FROM (
       SELECT column_id::text FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'
     ) THEN
    RAISE EXCEPTION 'My tasks lost its source task, board, column, or board-zone context: %', v_entry;
  END IF;

  SELECT array_agg(member.user_id ORDER BY member.user_id)
  INTO v_assignable_ids
  FROM public.list_assignable_board_members_p(
    (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a')
  ) AS member;
  IF v_assignable_ids IS DISTINCT FROM ARRAY[
    '40000000-0000-4000-8000-000000000001'::uuid,
    '40000000-0000-4000-8000-000000000002'::uuid
  ] THEN
    RAISE EXCEPTION 'Assignable users included a disabled account or omitted a current enabled member: %', v_assignable_ids;
  END IF;
  SELECT array_agg(to_jsonb(member)->>'name' ORDER BY member.user_id)
  INTO v_assignable_names
  FROM public.list_assignable_board_members_p(
    (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a')
  ) AS member;
  IF v_assignable_names IS DISTINCT FROM ARRAY[
    'Colaborador habilitado', 'Propietario del tablero'
  ] THEN
    RAISE EXCEPTION 'Assignable names did not come from the authorized current board members: %',
      v_assignable_names;
  END IF;

  v_assignment := public.set_task_assignee_p(
    '13000000-0000-4000-8000-000000000101',
    (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
    '40000000-0000-4000-8000-000000000001',
    1
  );
  IF v_assignment->>'status' <> 'confirmed'
    OR v_assignment->'task'->>'assignee_id' <> '40000000-0000-4000-8000-000000000001'
    OR v_assignment->'task'->>'assignee_version' <> '2' THEN
    RAISE EXCEPTION 'Current collaborator could not be assigned versionedly: %', v_assignment;
  END IF;
  IF public.set_task_assignee_p(
    '13000000-0000-4000-8000-000000000101',
    (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
    '40000000-0000-4000-8000-000000000001',
    1
  )->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'An assignment retry did not reconcile its receipt';
  END IF;
  BEGIN
    PERFORM public.set_task_assignee_p(
      '13000000-0000-4000-8000-000000000101',
      (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
      (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
      '40000000-0000-4000-8000-000000000002',
      1
    );
  EXCEPTION WHEN check_violation THEN
    v_payload_collision := true;
  END;
  IF NOT v_payload_collision THEN
    RAISE EXCEPTION 'One assignment operation id accepted a different target';
  END IF;

  v_conflict := public.set_task_assignee_p(
    '13000000-0000-4000-8000-000000000102',
    (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
    '40000000-0000-4000-8000-000000000002',
    1
  );
  IF v_conflict->>'status' <> 'conflict'
    OR v_conflict->'task'->>'assignee_id' <> '40000000-0000-4000-8000-000000000001' THEN
    RAISE EXCEPTION 'A stale assignment overwrote a concurrent assignee: %', v_conflict;
  END IF;

  v_edit := public.edit_task_fields_p(
    '13000000-0000-4000-8000-000000000103',
    (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
    '{"title":"Editada por otro miembro"}'::jsonb,
    '{"title":1}'::jsonb
  );
  IF v_edit->>'status' <> 'confirmed'
    OR v_edit->'task'->>'title' <> 'Editada por otro miembro' THEN
    RAISE EXCEPTION 'Assignment incorrectly limited another member from editing: %', v_edit;
  END IF;

  v_assignment := public.set_task_assignee_p(
    '13000000-0000-4000-8000-000000000104',
    (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
    NULL,
    2
  );
  IF v_assignment->>'status' <> 'confirmed'
    OR v_assignment->'task'->>'assignee_id' IS NOT NULL
    OR v_assignment->'task'->>'assignee_version' <> '3' THEN
    RAISE EXCEPTION 'Unassigning did not clear the assignee and advance its version: %', v_assignment;
  END IF;

  BEGIN
    PERFORM public.set_task_assignee_p(
      '13000000-0000-4000-8000-000000000105',
      (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
      (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
      '40000000-0000-4000-8000-000000000003',
      3
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A disabled account with a board membership was assignable';
  END IF;
  v_rejected := false;
  BEGIN
    PERFORM public.set_task_assignee_p(
      '13000000-0000-4000-8000-000000000106',
      (SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a'),
      (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assignment_target'),
      '40000000-0000-4000-8000-000000000005',
      3
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A nonmember of this board was assignable';
  END IF;
END;
$$;
COMMIT;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.board_memberships AS membership
    JOIN pg_temp.issue13_task_fixture AS fixture
      ON fixture.board_id = membership.board_id
    WHERE fixture.purpose = 'board_a'
      AND membership.user_id = '40000000-0000-4000-8000-000000000005'
      AND membership.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'A rejected assignee became a board member';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_tasks uuid[];
  v_board_count integer;
BEGIN
  SELECT array_agg((result.entry->'task'->>'id')::uuid ORDER BY result.ordinality)
  INTO v_tasks
  FROM public.get_my_tasks_p('due') WITH ORDINALITY AS result(entry, ordinality);
  IF v_tasks IS DISTINCT FROM ARRAY[
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_b'),
    (SELECT task_id FROM pg_temp.issue13_task_fixture WHERE purpose = 'assigned_to_collaborator')
  ] THEN
    RAISE EXCEPTION 'Collaborator did not receive only their assigned accessible tasks: %', v_tasks;
  END IF;
  SELECT count(DISTINCT result.entry->'board'->>'slug') INTO v_board_count
  FROM public.get_my_tasks_p('due') AS result(entry);
  IF v_board_count <> 2 THEN
    RAISE EXCEPTION 'My tasks did not aggregate the two authorized source boards';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.get_my_tasks_p('due') AS result(entry)
    WHERE result.entry->'task'->>'id' = (
        SELECT task_id::text FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_b'
      )
      AND result.entry->'board'->>'slug' = (
        SELECT slug FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_b'
      )
      AND result.entry->'column'->>'id' = (
        SELECT column_id::text FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_b'
      )
      AND result.entry->'board'->>'time_zone' = 'Europe/Madrid'
  ) THEN
    RAISE EXCEPTION 'Collaborator task lost its original board, column, or zone';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_slug text;
  v_member_count integer;
BEGIN
  SELECT slug INTO v_slug
  FROM pg_temp.issue13_task_fixture WHERE purpose = 'board_a';
  IF EXISTS (SELECT 1 FROM public.get_my_tasks_p('due')) THEN
    RAISE EXCEPTION 'An application administrator without membership received personal tasks';
  END IF;
  IF public.get_full_board_p(v_slug) IS NOT NULL THEN
    RAISE EXCEPTION 'An application administrator without membership opened a source board';
  END IF;
  SELECT count(*) INTO v_member_count
  FROM public.list_assignable_board_members_p(v_slug);
  IF v_member_count <> 0 THEN
    RAISE EXCEPTION 'An application administrator without membership enumerated board members';
  END IF;
END;
$$;
COMMIT;

CREATE TABLE public.issue13_task_assignment_race_fixture AS
SELECT board.slug AS board_slug, fixture.task_id
FROM pg_temp.issue13_task_fixture AS fixture
JOIN public.boards AS board ON board.id = fixture.board_id
WHERE fixture.purpose = 'race_target';
\echo 'PASS: personal tasks preserve source identity/context, board privacy, ordering, assignment eligibility, receipts, and nonexclusive editing'
