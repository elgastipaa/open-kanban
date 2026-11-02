\set ON_ERROR_STOP on
\echo 'Testing safe v1 import preparation, revalidation, quota, publication, and recovery'

INSERT INTO public.application_access (email, state, is_admin) VALUES
  ('issue43-owner@example.test', 'pending', false),
  ('issue43-collaborator@example.test', 'pending', false),
  ('issue43-outsider@example.test', 'pending', true);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('a4300000-0000-4000-8000-000000000001', 'issue43-owner@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('a4300000-0000-4000-8000-000000000002', 'issue43-collaborator@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('a4300000-0000-4000-8000-000000000003', 'issue43-outsider@example.test', clock_timestamp(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('a4310000-0000-4000-8000-000000000001', 'a4300000-0000-4000-8000-000000000001', 'google', 'issue43-owner', '{"email":"issue43-owner@example.test","email_verified":true}'),
  ('a4310000-0000-4000-8000-000000000002', 'a4300000-0000-4000-8000-000000000002', 'google', 'issue43-collaborator', '{"email":"issue43-collaborator@example.test","email_verified":true}'),
  ('a4310000-0000-4000-8000-000000000003', 'a4300000-0000-4000-8000-000000000003', 'google', 'issue43-outsider', '{"email":"issue43-outsider@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = auth_user.id, google_subject = identity.provider_id, state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE access.email = auth_user.email AND identity.provider = 'google';

CREATE TABLE public.issue43_import_fixture (
  board_id uuid NOT NULL,
  slug text NOT NULL,
  owner_id uuid NOT NULL,
  collaborator_id uuid NOT NULL,
  old_generation_id uuid NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  attachment_id uuid NOT NULL
);
CREATE TABLE public.issue43_import_results (name text PRIMARY KEY, result jsonb NOT NULL);
GRANT SELECT, INSERT, UPDATE ON public.issue43_import_fixture, public.issue43_import_results
  TO authenticated, service_role;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task_result jsonb;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Issue 43 destino sintético', 'America/Argentina/Buenos_Aires',
    'a4320000-0000-4000-8000-000000000001'
  );
  SELECT id INTO v_column_id FROM public.create_column_p(
    v_board.slug, v_board.id, 'Columna original', 0
  );
  v_task_result := public.create_task_p(
    'a4330000-0000-4000-8000-000000000001', v_board.id, v_column_id, 'Tarea original'
  );
  INSERT INTO public.issue43_import_fixture(
    board_id, slug, owner_id, collaborator_id, old_generation_id,
    column_id, task_id, attachment_id
  ) VALUES (
    v_board.id, v_board.slug, auth.uid(), 'a4300000-0000-4000-8000-000000000002',
    (SELECT active_generation_id FROM public.boards WHERE id = v_board.id),
    v_column_id, (v_task_result->'task'->>'id')::uuid,
    'a4340000-0000-4000-8000-000000000001'
  );
END;
$$;
COMMIT;
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, collaborator_id, 'collaborator' FROM public.issue43_import_fixture;
INSERT INTO public.task_attachments(
  id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
  size_bytes, sha256, object_key, state
)
SELECT attachment_id, board_id, task_id, owner_id,
  'a4350000-0000-4000-8000-000000000001', 'informe.txt', 12,
  extensions.digest(convert_to('dato local', 'UTF8'), 'sha256'),
  'attachments/issue43-synthetic-object', 'active'
FROM public.issue43_import_fixture;

CREATE FUNCTION public.issue43_fail_pointer_swap_tg()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.active_generation_id IS DISTINCT FROM OLD.active_generation_id THEN
    RAISE EXCEPTION 'synthetic publication failure' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;
CREATE FUNCTION public.issue43_hold_board_lock_p(p_slug text, p_seconds integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF p_slug IS NULL OR p_seconds NOT BETWEEN 1 AND 10
    OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'The synthetic board lock request is invalid'
      USING ERRCODE = '42501';
  END IF;
  PERFORM 1 FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  PERFORM pg_catalog.pg_sleep(p_seconds);
END;
$$;
REVOKE ALL ON FUNCTION public.issue43_hold_board_lock_p(text, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.issue43_hold_board_lock_p(text, integer)
  TO authenticated;

-- A prepared v1 replacement stays invisible; only the authenticated owner may prepare it.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'stale', public.prepare_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000001', repeat('a', 64),
  '{"columns":[{"title":"Importada","position":0,"tasks":[{"title":"Nueva","description":"Descripción sintética","priority":"high","position":0}]}]}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
INSERT INTO public.issue43_import_results(name, result)
SELECT 'invalid_missing_field', public.prepare_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000006', repeat('f', 64),
  '{"columns":[{"title":"Inválida","position":0,"tasks":[{"title":"Sin descripción","priority":"medium","position":0}]}]}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
INSERT INTO public.issue43_import_results(name, result)
SELECT 'invalid_identity', public.prepare_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000007', repeat('f', 64),
  '{"columns":[],"owner_id":"a4300000-0000-4000-8000-000000000001"}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
SELECT result FROM public.issue43_import_results WHERE name = 'stale';
INSERT INTO public.issue43_import_results(name, result)
SELECT 'visible', jsonb_build_object(
  'task_count', (SELECT count(*) FROM public.get_tasks_by_board_p(fixture.board_id))
) FROM public.issue43_import_fixture AS fixture;
COMMIT;
DO $$
DECLARE
  v_fixture public.issue43_import_fixture%ROWTYPE;
  v_preview jsonb;
  v_generation_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture FROM public.issue43_import_fixture;
  SELECT result INTO STRICT v_preview FROM public.issue43_import_results WHERE name = 'stale';
  SELECT generation_id INTO STRICT v_generation_id FROM public.board_import_operations
  WHERE actor_id = v_fixture.owner_id AND operation_id = 'a4360000-0000-4000-8000-000000000001';
  IF v_preview->>'status' <> 'prepared'
    OR v_preview->'current'->>'tasks' <> '1'
    OR v_preview->'imported'->>'tasks' <> '1'
    OR v_preview->'current'->>'attachment_bytes' <> '12'
    OR v_preview->'imported'->>'attachment_bytes' <> '0'
    OR v_preview->'capacity'->>'used_bytes' <> '12'
    OR (SELECT active_generation_id FROM public.boards WHERE id = v_fixture.board_id) <> v_fixture.old_generation_id
    OR (SELECT status FROM public.board_generations WHERE id = v_generation_id) <> 'preparing'
    OR (SELECT result->>'task_count' FROM public.issue43_import_results WHERE name = 'visible') <> '1'
    OR (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'invalid_missing_field') <> 'invalid'
    OR (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'invalid_identity') <> 'invalid'
    OR EXISTS (SELECT 1 FROM public.board_import_operations
      WHERE operation_id IN ('a4360000-0000-4000-8000-000000000006', 'a4360000-0000-4000-8000-000000000007')) THEN
    RAISE EXCEPTION 'Preview did not preserve the visible destination while reporting staged content: %', v_preview;
  END IF;
END;
$$;

-- A concurrent content revision invalidates that preview; collaborators cannot prepare replacements.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'revision', jsonb_build_object('value', result->>'content_revision')
FROM public.issue43_import_results WHERE name = 'stale';
SELECT public.edit_task_fields_p(
  'a4370000-0000-4000-8000-000000000001', fixture.slug, fixture.task_id,
  '{"title":"Editada durante la vista previa"}'::jsonb, '{"title":1}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000002', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'collaborator', public.prepare_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000002', repeat('b', 64), '{"columns":[]}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'stale_confirm', public.confirm_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000001',
  (SELECT (result->>'value')::bigint FROM public.issue43_import_results WHERE name = 'revision'), repeat('a', 64)
) FROM public.issue43_import_fixture AS fixture;
COMMIT;
DO $$
DECLARE fixture public.issue43_import_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  IF (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'collaborator') <> 'unavailable'
    OR (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'stale_confirm') <> 'conflict'
    OR (SELECT status FROM public.board_import_operations WHERE operation_id = 'a4360000-0000-4000-8000-000000000001') <> 'conflict'
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id) <> fixture.old_generation_id THEN
    RAISE EXCEPTION 'Owner/version revalidation did not reject stale or unauthorized import';
  END IF;
END;
$$;

-- Capacity failures leave the prepared operation retryable.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'publish', public.prepare_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000003', repeat('c', 64),
  '{"columns":[{"title":"Importada","position":0,"tasks":[{"title":"Nueva","description":null,"priority":"medium","position":0}]}]}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
COMMIT;
CREATE FUNCTION public.issue43_try_mutate_prepared_generation_p(p_operation_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  UPDATE public.tasks AS task
  SET title = 'Mutación no autorizada'
  FROM public.columns AS column_row
  WHERE column_row.id = task.column_id
    AND column_row.generation_id = (
      SELECT operation.generation_id FROM public.board_import_operations AS operation
      WHERE operation.actor_id = auth.uid() AND operation.operation_id = p_operation_id
    );
  RETURN 'updated';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'rejected';
END;
$$;
REVOKE ALL ON FUNCTION public.issue43_try_mutate_prepared_generation_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.issue43_try_mutate_prepared_generation_p(uuid)
  TO authenticated;
CREATE FUNCTION public.issue43_try_bump_prepared_column_order_p(p_operation_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  UPDATE public.columns AS column_row
  SET task_order_version = column_row.task_order_version + 1
  WHERE column_row.generation_id = (
    SELECT operation.generation_id FROM public.board_import_operations AS operation
    WHERE operation.actor_id = auth.uid() AND operation.operation_id = p_operation_id
  );
  RETURN 'updated';
EXCEPTION WHEN insufficient_privilege THEN
  RETURN 'rejected';
END;
$$;
REVOKE ALL ON FUNCTION public.issue43_try_bump_prepared_column_order_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.issue43_try_bump_prepared_column_order_p(uuid)
  TO authenticated;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'stage_guard', jsonb_build_object(
  'status', public.issue43_try_mutate_prepared_generation_p('a4360000-0000-4000-8000-000000000003')
);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'stage_order_guard', jsonb_build_object(
  'status', public.issue43_try_bump_prepared_column_order_p('a4360000-0000-4000-8000-000000000003')
);
COMMIT;
UPDATE public.task_attachment_quota_ledger SET active_bytes = limit_bytes + 1 WHERE singleton;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'capacity', public.confirm_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000003',
  (SELECT (result->>'content_revision')::bigint FROM public.issue43_import_results WHERE name = 'publish'), repeat('c', 64)
) FROM public.issue43_import_fixture AS fixture;
COMMIT;
UPDATE public.task_attachment_quota_ledger AS ledger
SET active_bytes = (SELECT COALESCE(sum(size_bytes), 0) FROM public.task_attachments WHERE state = 'active'),
    recoverable_bytes = 0, reserved_bytes = 0, pending_bytes = 0
WHERE singleton;
DO $$
DECLARE fixture public.issue43_import_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  IF (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'capacity') <> 'capacity'
    OR (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'stage_guard') <> 'rejected'
    OR (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'stage_order_guard') <> 'rejected'
    OR has_table_privilege('authenticated', 'public.board_import_stage_contexts', 'INSERT')
    OR has_table_privilege('service_role', 'public.board_import_stage_contexts', 'INSERT')
    OR (SELECT status FROM public.board_import_operations WHERE operation_id = 'a4360000-0000-4000-8000-000000000003') <> 'prepared'
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id) <> fixture.old_generation_id THEN
    RAISE EXCEPTION 'Quota rejection changed publication state';
  END IF;
END;
$$;

-- A failure at the final pointer swap rolls back generation states and retention together.
CREATE TRIGGER issue43_reject_pointer_swap
BEFORE UPDATE OF active_generation_id ON public.boards
FOR EACH ROW EXECUTE FUNCTION public.issue43_fail_pointer_swap_tg();
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
DO $$
DECLARE failed boolean := false;
BEGIN
  BEGIN
    PERFORM public.confirm_board_import_p(
      (SELECT slug FROM public.issue43_import_fixture), 'a4360000-0000-4000-8000-000000000003',
      (SELECT (result->>'content_revision')::bigint FROM public.issue43_import_results WHERE name = 'publish'), repeat('c', 64)
    );
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failed := true;
  END;
  IF NOT failed THEN RAISE EXCEPTION 'Synthetic publication fault was not reached'; END IF;
END;
$$;
COMMIT;
DROP TRIGGER issue43_reject_pointer_swap ON public.boards;
DO $$
DECLARE
  fixture public.issue43_import_fixture%ROWTYPE;
  operation public.board_import_operations%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  SELECT * INTO STRICT operation FROM public.board_import_operations
  WHERE actor_id = fixture.owner_id AND operation_id = 'a4360000-0000-4000-8000-000000000003';
  IF (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id) <> fixture.old_generation_id
    OR (SELECT status FROM public.board_generations WHERE id = operation.base_generation_id) <> 'active'
    OR (SELECT status FROM public.board_generations WHERE id = operation.generation_id) <> 'preparing'
    OR EXISTS (SELECT 1 FROM public.board_generation_retention WHERE board_id = fixture.board_id) THEN
    RAISE EXCEPTION 'Publication failure left partial generation state';
  END IF;
END;
$$;

-- A lost response after commit is replayed from the same durable receipt.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'confirmed', public.confirm_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000003',
  (SELECT (result->>'content_revision')::bigint FROM public.issue43_import_results WHERE name = 'publish'), repeat('c', 64)
) FROM public.issue43_import_fixture AS fixture;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'retry', public.confirm_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000003',
  (SELECT (result->>'content_revision')::bigint FROM public.issue43_import_results WHERE name = 'publish'), repeat('c', 64)
) FROM public.issue43_import_fixture AS fixture;
INSERT INTO public.issue43_import_results(name, result)
SELECT 'recoveries', public.list_board_import_recoveries_p(fixture.slug)
FROM public.issue43_import_fixture AS fixture;
COMMIT;
DO $$
DECLARE
  fixture public.issue43_import_fixture%ROWTYPE;
  result jsonb;
  imported_task public.tasks%ROWTYPE;
  retained public.board_generation_retention%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  SELECT issue43_import_results.result INTO STRICT result FROM public.issue43_import_results WHERE name = 'confirmed';
  SELECT * INTO STRICT retained FROM public.board_generation_retention
  WHERE board_id = fixture.board_id AND generation_id = fixture.old_generation_id;
  SELECT task.* INTO STRICT imported_task FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE column_row.board_id = fixture.board_id
    AND column_row.generation_id = (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id);
  IF result->>'status' <> 'confirmed'
    OR (SELECT issue43_import_results.result FROM public.issue43_import_results WHERE name = 'retry') <> result
    OR retained.expires_at <> retained.retained_at + interval '168 hours'
    OR retained.replacement_generation_id <> (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
    OR imported_task.title <> 'Nueva' OR imported_task.created_by IS NOT NULL
    OR imported_task.assignee_id IS NOT NULL OR imported_task.due_on IS NOT NULL
    OR imported_task.is_completed OR imported_task.steps <> '[]'::jsonb
    OR (SELECT owner_id FROM public.boards WHERE id = fixture.board_id) <> fixture.owner_id
    OR (SELECT count(*) FROM public.board_memberships WHERE board_id = fixture.board_id AND revoked_at IS NULL) <> 2
    OR (SELECT active_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 12
    OR NOT EXISTS (SELECT 1 FROM public.task_attachments WHERE id = fixture.attachment_id AND state = 'active')
    OR jsonb_array_length((SELECT issue43_import_results.result->'items'
      FROM public.issue43_import_results WHERE name = 'recoveries')) <> 1 THEN
    RAISE EXCEPTION 'Replacement, receipt, retention, defaults, or membership invariant failed';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'restore_preview', public.prepare_board_import_restore_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000004', fixture.old_generation_id
) FROM public.issue43_import_fixture AS fixture;
INSERT INTO public.issue43_import_results(name, result)
SELECT 'restore_confirmed', public.confirm_board_import_restore_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000004',
  (SELECT (result->>'content_revision')::bigint FROM public.issue43_import_results WHERE name = 'restore_preview')
) FROM public.issue43_import_fixture AS fixture;
COMMIT;
DO $$
DECLARE fixture public.issue43_import_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  IF (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'restore_preview') <> 'prepared'
    OR (SELECT result->>'status' FROM public.issue43_import_results WHERE name = 'restore_confirmed') <> 'confirmed'
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id) <> fixture.old_generation_id
    OR (SELECT owner_id FROM public.boards WHERE id = fixture.board_id) <> fixture.owner_id
    OR (SELECT count(*) FROM public.board_memberships WHERE board_id = fixture.board_id AND revoked_at IS NULL) <> 2 THEN
    RAISE EXCEPTION 'Previous-generation restore changed board identity or membership';
  END IF;
END;
$$;

DROP FUNCTION public.issue43_fail_pointer_swap_tg();
DROP FUNCTION public.issue43_try_mutate_prepared_generation_p(uuid);
DROP FUNCTION public.issue43_try_bump_prepared_column_order_p(uuid);
\echo 'PASS: staged v1 import revalidates owner, revisions, and quota; publication is atomic and retryable; previous generation restores within seven days.'
