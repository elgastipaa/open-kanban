\set ON_ERROR_STOP on
\echo 'Preparing authenticated actors for concurrent task-field edits'

CREATE TABLE public.issue8_task_field_fixture (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL
);
GRANT SELECT, INSERT ON public.issue8_task_field_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Issue 8 concurrent field edits',
    'UTC',
    'a8888888-0000-4000-8000-000000000001'
  );

  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Edición', 0);

  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000002',
    v_board.id,
    v_column_id,
    'Título inicial'
  )->'task';
  INSERT INTO public.issue8_task_field_fixture
    (purpose, board_id, board_slug, column_id, task_id)
  VALUES ('same-field', v_board.id, v_board.slug, v_column_id, (v_task->>'id')::uuid);

  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000003',
    v_board.id,
    v_column_id,
    'Campos distintos'
  )->'task';
  INSERT INTO public.issue8_task_field_fixture
    (purpose, board_id, board_slug, column_id, task_id)
  VALUES ('different-fields', v_board.id, v_board.slug, v_column_id, (v_task->>'id')::uuid);
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '40000000-0000-4000-8000-000000000005', 'collaborator'
FROM public.issue8_task_field_fixture AS fixture
WHERE fixture.purpose = 'same-field';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
BEGIN
  IF NOT public.is_application_user() OR NOT EXISTS (
    SELECT 1 FROM public.issue8_task_field_fixture AS fixture
    WHERE public.is_board_member(fixture.board_id)
  ) THEN
    RAISE EXCEPTION 'The second synthetic actor is not an authorized board collaborator';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: two enabled synthetic actors share one isolated task board'
