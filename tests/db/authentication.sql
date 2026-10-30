\set ON_ERROR_STOP on
\echo 'Testing explicit Google identity mapping, owner isolation, and revocation'
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('40000000-0000-4000-8000-000000000001', 'bootstrap-admin@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000002', 'enabled-user@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000003', 'denied-user@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000004', 'email-only@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data, created_at) VALUES
  ('50000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000001', 'google', 'google-subject-admin', '{"email":"bootstrap-admin@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000002', '40000000-0000-4000-8000-000000000002', 'google', 'google-subject-enabled', '{"email":"enabled-user@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000003', '40000000-0000-4000-8000-000000000003', 'google', 'google-subject-denied', '{"email":"denied-user@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000004', '40000000-0000-4000-8000-000000000004', 'email', 'email-only@example.test', '{"email":"email-only@example.test","email_verified":true}', now());

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_access jsonb;
  v_board_id uuid;
  v_column_id uuid;
  v_pending_removed boolean;
  v_admin_count integer := 0;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' OR v_access->>'is_admin' <> 'true' THEN
    RAISE EXCEPTION 'Explicit bootstrap fixture did not admit its administrator: %', v_access;
  END IF;
  IF NOT public.is_application_user() OR NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'Bootstrap administrator lacks the expected application identity';
  END IF;

  SELECT id INTO v_board_id FROM public.create_board_p('admin-private-board');
  PERFORM set_config('test.admin_board_id', v_board_id::text, false);
  SELECT id INTO v_column_id FROM public.create_column_p('admin-private-board', v_board_id, 'Admin private', 0);
  PERFORM public.create_task_p('admin-private-board', v_column_id, 'Admin-owned content');
  SELECT count(*) INTO v_admin_count FROM public.list_my_boards();
  IF v_admin_count <> 1 THEN
    RAISE EXCEPTION 'Owner dashboard did not list exactly its administrator board';
  END IF;

  PERFORM public.admin_enable_access('another-user@example.test');
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_list_access()
    WHERE email = 'another-user@example.test' AND state = 'pending' AND NOT is_admin AND NOT linked
  ) THEN
    RAISE EXCEPTION 'Administrator did not create an explicit pending authorization';
  END IF;
  v_pending_removed := public.admin_remove_pending_access('another-user@example.test');
  IF NOT v_pending_removed THEN
    RAISE EXCEPTION 'Administrator could not withdraw pending authorization';
  END IF;

  BEGIN
    PERFORM public.admin_suspend_access('bootstrap-admin@example.test');
  EXCEPTION WHEN check_violation THEN
    v_admin_count := 1;
  END;
  IF v_admin_count <> 1 OR NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'The final administrator could be suspended';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: an explicit fixture, not the first visitor, bootstraps admin'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_access jsonb;
  v_board_id uuid;
  v_delete_board_id uuid;
  v_column_id uuid;
  v_delete_column_id uuid;
  v_row_count integer;
  v_channel_count integer;
  v_denied boolean := false;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' OR v_access->>'is_admin' <> 'false' THEN
    RAISE EXCEPTION 'Explicitly enabled Google identity was not linked: %', v_access;
  END IF;
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' THEN
    RAISE EXCEPTION 'A repeated session check lost the stable identity link';
  END IF;

  SELECT id INTO v_board_id FROM public.create_board_p('enabled-private-board');
  SELECT id INTO v_column_id FROM public.create_column_p('enabled-private-board', v_board_id, 'Enabled private', 0);
  PERFORM public.create_task_p('enabled-private-board', v_column_id, 'Enabled content');
  IF public.get_full_board_p('enabled-private-board')->'columns'->0->'tasks'->0->>'title'
    IS DISTINCT FROM 'Enabled content' THEN
    RAISE EXCEPTION 'Enabled identity cannot read its own board';
  END IF;
  IF public.get_full_board_p('admin-private-board') IS NOT NULL THEN
    RAISE EXCEPTION 'A valid but unrelated identity can read the admin board by slug';
  END IF;
  SELECT count(*) INTO v_row_count FROM public.boards;
  IF v_row_count <> 1 THEN
    RAISE EXCEPTION 'Direct RLS query returned another user’s board';
  END IF;
  SELECT count(*) INTO v_row_count FROM public.list_my_boards();
  IF v_row_count <> 1 THEN
    RAISE EXCEPTION 'Owner dashboard did not list exactly its enabled user’s boards';
  END IF;

  PERFORM set_config('request.jwt.claim.topic', 'board:' || current_setting('test.admin_board_id'), true);
  BEGIN
    INSERT INTO realtime.messages(extension, topic, payload)
    VALUES ('broadcast', 'board:' || current_setting('test.admin_board_id'), '{}'::jsonb);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'An enabled user joined another owner’s private channel';
  END IF;

  PERFORM set_config('request.jwt.claim.topic', 'board:' || v_board_id::text, true);
  INSERT INTO realtime.messages(extension, topic, payload)
  VALUES ('broadcast', 'board:' || v_board_id::text, '{}'::jsonb);
  SELECT count(*) INTO v_channel_count FROM realtime.messages
  WHERE topic = 'board:' || v_board_id::text;
  IF v_channel_count <> 1 THEN
    RAISE EXCEPTION 'The allowed private topic did not retain its message';
  END IF;

  SELECT id INTO v_delete_board_id FROM public.create_board_p('enabled-delete-board');
  SELECT id INTO v_delete_column_id FROM public.create_column_p('enabled-delete-board', v_delete_board_id, 'To delete', 0);
  PERFORM public.create_task_p('enabled-delete-board', v_delete_column_id, 'Cascade fixture');
  PERFORM public.delete_board_p('enabled-delete-board', v_delete_board_id);
  IF EXISTS (SELECT 1 FROM public.boards WHERE slug = 'enabled-delete-board') THEN
    RAISE EXCEPTION 'An owner could not delete a board and its children';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: enabled Google identity is linked to its stable Auth account and owns private data'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
BEGIN
  IF public.get_full_board_p('enabled-private-board') IS NOT NULL THEN
    RAISE EXCEPTION 'Application administrator can read another user’s private board';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: global administration does not grant board membership or content access'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_access jsonb;
  v_row_count integer;
  v_denied boolean := false;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'not_enabled' THEN
    RAISE EXCEPTION 'Google identity without explicit authorization was admitted: %', v_access;
  END IF;
  IF public.is_application_user() THEN
    RAISE EXCEPTION 'Non-enabled Auth user passed the application admission check';
  END IF;
  SELECT count(*) INTO v_row_count FROM public.boards;
  IF v_row_count <> 0 OR public.get_full_board_p('enabled-private-board') IS NOT NULL THEN
    RAISE EXCEPTION 'Non-enabled Auth user read product data';
  END IF;
  SELECT count(*) INTO v_row_count FROM public.list_my_boards();
  IF v_row_count <> 0 THEN
    RAISE EXCEPTION 'Non-enabled Auth user listed private boards';
  END IF;
  BEGIN
    PERFORM public.create_board_p('denied-created-board');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Non-enabled Auth user created a board';
  END IF;
  BEGIN
    PERFORM public.admin_enable_access('attacker-created@example.test');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A non-admin Auth user passed an application administration RPC';
  END IF;
END;
$$;
COMMIT;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.application_access WHERE email = 'attacker-created@example.test') THEN
    RAISE EXCEPTION 'A non-admin Auth user granted application access';
  END IF;
END;
$$;
\echo 'PASS: a valid Auth token without application authorization stays restricted'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'google_required' THEN
    RAISE EXCEPTION 'An identity without a Google provider was admitted: %', v_access;
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: a non-Google identity is not treated as Google sign-in'

UPDATE auth.identities
SET provider_id = 'changed-google-subject'
WHERE user_id = '40000000-0000-4000-8000-000000000002' AND provider = 'google';
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'not_enabled' OR public.is_application_user() THEN
    RAISE EXCEPTION 'A changed Google subject inherited an existing authorization';
  END IF;
END;
$$;
COMMIT;
UPDATE auth.identities
SET provider_id = 'google-subject-enabled'
WHERE user_id = '40000000-0000-4000-8000-000000000002' AND provider = 'google';
\echo 'PASS: an authorization remains bound to its original Google subject'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_suspended boolean;
BEGIN
  v_suspended := public.admin_suspend_access('enabled-user@example.test');
  IF NOT v_suspended THEN
    RAISE EXCEPTION 'Administrator did not suspend the enabled user';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_access jsonb;
  v_row_count integer;
  v_denied boolean := false;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'suspended' OR public.is_application_user() THEN
    RAISE EXCEPTION 'A previously issued Auth identity bypassed current suspension: %', v_access;
  END IF;
  SELECT count(*) INTO v_row_count FROM public.boards;
  IF v_row_count <> 0 OR public.get_full_board_p('enabled-private-board') IS NOT NULL THEN
    RAISE EXCEPTION 'Suspended Auth identity can still read product data';
  END IF;
  BEGIN
    PERFORM public.create_board_p('suspended-created-board');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Suspended Auth identity can still create a board';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: a valid token cannot bypass current suspension'
