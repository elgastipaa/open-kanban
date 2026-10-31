\set ON_ERROR_STOP on

CREATE TEMP TABLE private_board_refs (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  slug text NOT NULL,
  request_id uuid NOT NULL
);
GRANT SELECT, INSERT ON private_board_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_retry record;
  v_invalid_name_denied boolean := false;
  v_invalid_timezone_denied boolean := false;
  v_payload_conflict_denied boolean := false;
  v_owner_list_count integer;
  v_column_count integer;
  v_resolved_slug text;
  v_owner_id uuid;
  v_full_board json;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Trabajo personal',
    'America/Argentina/Buenos_Aires',
    'aaaaaaaa-0000-4000-8000-000000000001'
  );

  IF v_board.id IS NULL
    OR v_board.name <> 'Trabajo personal'
    OR v_board.role <> 'owner'
    OR v_board.time_zone <> 'America/Argentina/Buenos_Aires'
    OR v_board.slug = '' THEN
    RAISE EXCEPTION 'Board creation did not preserve its name, owner, zone, route, or active generation';
  END IF;
  SELECT owner_id INTO v_owner_id FROM public.boards WHERE id = v_board.id;
  IF v_owner_id <> auth.uid() THEN
    RAISE EXCEPTION 'The created board did not assign its authenticated creator as owner';
  END IF;
  v_full_board := public.get_full_board_p(v_board.slug);
  IF v_full_board->'board'->>'role' <> 'owner'
    OR ((v_full_board->'board')::jsonb ? 'owner_id')
    OR ((v_full_board->'board')::jsonb ? 'active_generation_id') THEN
    RAISE EXCEPTION 'Board metadata exposed internal ownership or generation fields';
  END IF;

  SELECT * INTO v_retry
  FROM public.create_board_p(
    'Trabajo personal',
    'America/Argentina/Buenos_Aires',
    'aaaaaaaa-0000-4000-8000-000000000001'
  );
  IF v_retry.id <> v_board.id OR v_retry.slug <> v_board.slug THEN
    RAISE EXCEPTION 'Retrying one creation intent produced a second board';
  END IF;
  SELECT public.get_board_creation_result_p(
    'aaaaaaaa-0000-4000-8000-000000000001'
  ) INTO v_resolved_slug;
  IF v_resolved_slug <> v_board.slug THEN
    RAISE EXCEPTION 'Creation-result reconciliation did not return the current owner’s result';
  END IF;

  BEGIN
    PERFORM public.create_board_p(
      'Different payload',
      'America/Argentina/Buenos_Aires',
      'aaaaaaaa-0000-4000-8000-000000000001'
    );
  EXCEPTION WHEN check_violation THEN
    v_payload_conflict_denied := true;
  END;
  IF NOT v_payload_conflict_denied THEN
    RAISE EXCEPTION 'One idempotency key accepted conflicting creation details';
  END IF;

  SELECT count(*) INTO v_owner_list_count
  FROM public.list_my_boards()
  WHERE id = v_board.id AND role = 'owner';
  SELECT count(*) INTO v_column_count
  FROM public.columns AS column_row
  WHERE column_row.board_id = v_board.id;
  IF v_owner_list_count <> 1 OR v_column_count <> 0 THEN
    RAISE EXCEPTION 'New board must have one owner membership and active generation, and no columns';
  END IF;

  INSERT INTO pg_temp.private_board_refs(purpose, board_id, slug, request_id)
  VALUES ('owner-board', v_board.id, v_board.slug, 'aaaaaaaa-0000-4000-8000-000000000001');

  BEGIN
    PERFORM public.create_board_p(
      '   ', 'America/Argentina/Buenos_Aires', 'aaaaaaaa-0000-4000-8000-000000000002'
    );
  EXCEPTION WHEN check_violation THEN
    v_invalid_name_denied := true;
  END;
  IF NOT v_invalid_name_denied THEN
    RAISE EXCEPTION 'A whitespace-only board name was accepted';
  END IF;

  BEGIN
    PERFORM public.create_board_p(
      'Invalid zone', 'Not/A_Real_Zone', 'aaaaaaaa-0000-4000-8000-000000000003'
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_invalid_timezone_denied := true;
  END;
  IF NOT v_invalid_timezone_denied THEN
    RAISE EXCEPTION 'An unknown board time zone was accepted';
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_board_id uuid;
  v_owner_count integer;
  v_active_generation_count integer;
BEGIN
  SELECT board_id INTO v_board_id
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  SELECT count(*) INTO v_owner_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board_id
    AND membership.user_id = '40000000-0000-4000-8000-000000000002'
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL;
  SELECT count(*) INTO v_active_generation_count
  FROM public.board_generations AS generation
  WHERE generation.board_id = v_board_id AND generation.status = 'active';
  IF v_owner_count <> 1 OR v_active_generation_count <> 1 THEN
    RAISE EXCEPTION 'New board did not persist one active owner membership and one active generation';
  END IF;
END;
$$;

-- The same request id belongs to a different principal and must not disclose or
-- return the first user's board.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_original_id uuid;
  v_owner_id uuid;
BEGIN
  SELECT board_id INTO v_original_id
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Tablero propio admin',
    'UTC',
    'aaaaaaaa-0000-4000-8000-000000000001'
  );
  SELECT owner_id INTO v_owner_id FROM public.boards WHERE id = v_board.id;
  IF v_board.id = v_original_id OR v_owner_id <> auth.uid() THEN
    RAISE EXCEPTION 'Creation idempotency was not scoped to its authenticated owner';
  END IF;
  INSERT INTO pg_temp.private_board_refs(purpose, board_id, slug, request_id)
  VALUES ('admin-board', v_board.id, v_board.slug, 'aaaaaaaa-0000-4000-8000-000000000001');
END;
$$;
COMMIT;

-- A current collaborator can list and use the board, but cannot rename it.
RESET ROLE;
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, '40000000-0000-4000-8000-000000000001', 'collaborator'
FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_slug text;
  v_board_id uuid;
  v_full_board json;
  v_board_count integer;
  v_denied boolean := false;
BEGIN
  SELECT board_id, slug INTO v_board_id, v_slug
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';

  SELECT count(*) INTO v_board_count FROM public.list_my_boards()
  WHERE id = v_board_id AND role = 'collaborator';
  IF v_board_count <> 1 THEN
    RAISE EXCEPTION 'An active collaborator cannot find the shared board';
  END IF;
  v_full_board := public.get_full_board_p(v_slug);
  IF v_full_board IS NULL
    OR v_full_board->'board'->>'name' <> 'Trabajo personal'
    OR v_full_board->'board'->>'role' <> 'collaborator' THEN
    RAISE EXCEPTION 'An active collaborator cannot read their shared board';
  END IF;

  BEGIN
    PERFORM public.rename_board_p(v_slug, 'Renombre no autorizado');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A collaborator renamed the board';
  END IF;
END;
$$;
COMMIT;

-- The owner may rename; the URL key does not change. The board has no implied
-- first column. Columns are explicitly named and the active order is readable.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_slug text;
  v_name text;
  v_first_column uuid;
  v_second_column uuid;
  v_denied boolean := false;
  v_forged_column_update_denied boolean := false;
  v_cross_board_batch_denied boolean := false;
  v_full_board json;
BEGIN
  SELECT board_id, slug INTO v_board_id, v_slug
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  PERFORM public.rename_board_p(v_slug, 'Trabajo renombrado');
  SELECT name, slug INTO v_name, v_slug
  FROM public.get_board_p(v_slug);
  IF v_name <> 'Trabajo renombrado'
    OR v_slug <> (SELECT slug FROM pg_temp.private_board_refs WHERE purpose = 'owner-board') THEN
    RAISE EXCEPTION 'Renaming changed the stable URL or failed to change the board name';
  END IF;

  BEGIN
    PERFORM public.create_column_p(v_slug, v_board_id, '   ', 0);
  EXCEPTION WHEN check_violation THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A whitespace-only column name was accepted';
  END IF;

  SELECT id INTO v_first_column
  FROM public.create_column_p(v_slug, v_board_id, 'Ideas', 0);
  SELECT id INTO v_second_column
  FROM public.create_column_p(v_slug, v_board_id, 'En marcha', 1);
  PERFORM public.update_column_positions_p(
    v_slug,
    jsonb_build_array(
      jsonb_build_object('id', v_second_column, 'position', 0),
      jsonb_build_object('id', v_first_column, 'position', 1)
    )
  );
  v_full_board := public.get_full_board_p(v_slug);
  IF v_full_board->'columns'->0->>'title' <> 'En marcha'
    OR v_full_board->'columns'->1->>'title' <> 'Ideas' THEN
    RAISE EXCEPTION 'Active board columns did not follow their explicit order';
  END IF;

  BEGIN
    PERFORM public.update_column_positions_p(
      v_slug,
      jsonb_build_array(jsonb_build_object(
        'id', v_second_column,
        'position', 4,
        'title', 'Nombre falsificado'
      ))
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_forged_column_update_denied := true;
  END;
  IF NOT v_forged_column_update_denied
    OR EXISTS (
      SELECT 1 FROM public.columns
      WHERE id = v_second_column AND (title <> 'En marcha' OR position <> 0)
    ) THEN
    RAISE EXCEPTION 'A reorder action modified title or partially changed position';
  END IF;

  BEGIN
    PERFORM public.update_column_positions_p(
      v_slug,
      jsonb_build_array(
        jsonb_build_object('id', v_second_column, 'position', 4),
        jsonb_build_object(
          'id', 'cccccccc-0000-4000-8000-000000000099', 'position', 0
        )
      )
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_cross_board_batch_denied := true;
  END;
  IF NOT v_cross_board_batch_denied
    OR EXISTS (
      SELECT 1 FROM public.columns WHERE id = v_second_column AND position <> 0
    ) THEN
    RAISE EXCEPTION 'An invalid reorder batch changed a valid column before failure';
  END IF;

END;
$$;
COMMIT;

-- The fixture creates a previous generation with recognizable private data.
-- Current board reads must resolve only the generation pointer.
BEGIN;
SET LOCAL session_replication_role = replica;
INSERT INTO public.board_generations(id, board_id, status, created_by)
SELECT 'bbbbbbbb-0000-4000-8000-000000000001', board_id, 'archived', '40000000-0000-4000-8000-000000000002'
FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
INSERT INTO public.columns(id, board_id, generation_id, title, position)
SELECT 'cccccccc-0000-4000-8000-000000000001', board_id, 'bbbbbbbb-0000-4000-8000-000000000001', 'Dato archivado secreto', 0
FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
INSERT INTO public.tasks(id, column_id, title, description, priority, position)
VALUES (
  'dddddddd-0000-4000-8000-000000000001',
  'cccccccc-0000-4000-8000-000000000001',
  'Tarea archivada secreta',
  NULL,
  'medium',
  0
);
UPDATE public.board_generations SET status = 'archived'
WHERE id = (
  SELECT board.active_generation_id FROM public.boards AS board
  JOIN pg_temp.private_board_refs AS ref ON ref.board_id = board.id
  WHERE ref.purpose = 'owner-board'
);
INSERT INTO public.board_generations(id, board_id, status, created_by)
SELECT 'bbbbbbbb-0000-4000-8000-000000000002', board_id, 'active', '40000000-0000-4000-8000-000000000002'
FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
UPDATE public.boards SET active_generation_id = 'bbbbbbbb-0000-4000-8000-000000000002'
WHERE id = (SELECT board_id FROM pg_temp.private_board_refs WHERE purpose = 'owner-board');
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_slug text;
  v_full_board json;
BEGIN
  SELECT board_id, slug INTO v_board_id, v_slug
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  v_full_board := public.get_full_board_p(v_slug);
  IF json_array_length(v_full_board->'columns') <> 0 THEN
    RAISE EXCEPTION 'A read exposed columns from an archived generation';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.get_columns_p(v_board_id)
    WHERE title = 'Dato archivado secreto'
  ) THEN
    RAISE EXCEPTION 'The column reader exposed content from an archived generation';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.get_tasks_by_board_p(v_board_id)
    WHERE title = 'Tarea archivada secreta'
  ) THEN
    RAISE EXCEPTION 'The task reader exposed content from an archived generation';
  END IF;
END;
$$;
COMMIT;

-- Application administrators do not gain board access by role, slug, or ID.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_slug text;
  v_board_id uuid;
  v_count integer;
BEGIN
  SELECT board_id, slug INTO v_board_id, v_slug
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  IF public.get_full_board_p(v_slug) IS NOT NULL
    OR EXISTS (SELECT 1 FROM public.get_board_p(v_slug))
    OR public.can_access_board_topic('board:' || v_board_id::text) THEN
    RAISE EXCEPTION 'An unrelated administrator gained board or realtime access';
  END IF;
  SELECT count(*) INTO v_count FROM public.list_my_boards()
  WHERE id = v_board_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'An unrelated administrator listed a private board';
  END IF;
  SELECT count(*) INTO v_count FROM public.boards WHERE id = v_board_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'RLS exposed an unrelated administrator’s private board';
  END IF;
END;
$$;
COMMIT;

-- An enabled ordinary identity with no current membership has no private-board
-- listing, direct table access, content read, or realtime topic access.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_slug text;
  v_board_id uuid;
  v_count integer;
BEGIN
  SELECT board_id, slug INTO v_board_id, v_slug
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  IF public.get_full_board_p(v_slug) IS NOT NULL
    OR public.can_access_board_topic('board:' || v_board_id::text) THEN
    RAISE EXCEPTION 'An enabled ordinary nonmember gained board or realtime access';
  END IF;
  SELECT count(*) INTO v_count FROM public.list_my_boards();
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'An enabled ordinary nonmember listed another owner’s board';
  END IF;
  SELECT count(*) INTO v_count FROM public.boards;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'RLS exposed an enabled nonmember’s private board';
  END IF;
  SELECT count(*) INTO v_count FROM public.get_columns_p(v_board_id);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'An enabled ordinary nonmember read private columns';
  END IF;
  SELECT count(*) INTO v_count FROM public.get_tasks_by_board_p(v_board_id);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'An enabled ordinary nonmember read private tasks';
  END IF;
  SELECT count(*) INTO v_count FROM public.get_board_p(v_slug);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'An enabled ordinary nonmember fetched private board metadata';
  END IF;
  IF public.get_board_creation_result_p(
    'aaaaaaaa-0000-4000-8000-000000000001'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'An enabled ordinary nonmember resolved another owner’s creation result';
  END IF;
END;
$$;
COMMIT;

-- The role and ownership columns cannot be forged by direct table writes, and
-- an active board cannot acquire a second owner membership.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_denied boolean := false;
BEGIN
  SELECT board_id INTO v_board_id
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  BEGIN
    UPDATE public.boards SET owner_id = '40000000-0000-4000-8000-000000000001'
    WHERE id = v_board_id;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A client forged board ownership through direct DML';
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_board_id uuid;
  v_duplicate_owner_denied boolean := false;
BEGIN
  SELECT board_id INTO v_board_id
  FROM pg_temp.private_board_refs WHERE purpose = 'owner-board';
  BEGIN
    INSERT INTO public.board_memberships(board_id, user_id, role)
    VALUES (v_board_id, '40000000-0000-4000-8000-000000000006', 'owner');
  EXCEPTION WHEN unique_violation THEN
    v_duplicate_owner_denied := true;
  END;
  IF NOT v_duplicate_owner_denied THEN
    RAISE EXCEPTION 'The database accepted a second active board owner';
  END IF;
END;
$$;

\echo 'PASS: private board create, idempotency, membership, ownership, zones, columns, generations, and access isolation'
