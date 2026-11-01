\set ON_ERROR_STOP on
\echo 'Testing explicit Google identity mapping, owner isolation, and revocation'
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('40000000-0000-4000-8000-000000000001', 'bootstrap-admin@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000002', 'enabled-user@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000003', 'denied-user@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000004', 'email-only@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000005', 'revocation-user@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000006', 'second-admin@example.test', now(), '{"provider":"google"}'),
  ('40000000-0000-4000-8000-000000000007', 'unverified-user@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data, created_at) VALUES
  ('50000000-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000001', 'google', 'google-subject-admin', '{"email":"bootstrap-admin@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000002', '40000000-0000-4000-8000-000000000002', 'google', 'google-subject-enabled', '{"email":"enabled-user@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000003', '40000000-0000-4000-8000-000000000003', 'google', 'google-subject-denied', '{"email":"denied-user@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000004', '40000000-0000-4000-8000-000000000004', 'email', 'email-only@example.test', '{"email":"email-only@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000005', '40000000-0000-4000-8000-000000000005', 'google', 'google-subject-revocation', '{"email":"revocation-user@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000006', '40000000-0000-4000-8000-000000000006', 'google', 'google-subject-second-admin', '{"email":"second-admin@example.test","email_verified":true}', now()),
  ('50000000-0000-4000-8000-000000000007', '40000000-0000-4000-8000-000000000007', 'google', 'google-subject-unverified', '{"email":"unverified-user@example.test","email_verified":false}', now());

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_access jsonb;
  v_board_id uuid;
  v_board_slug text;
  v_column_id uuid;
  v_pending_removed boolean;
  v_admin_count integer := 0;
  v_invalid_email_message text;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' OR v_access->>'is_admin' <> 'true' THEN
    RAISE EXCEPTION 'Explicit bootstrap fixture did not admit its administrator: %', v_access;
  END IF;
  IF NOT public.is_application_user() OR NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'Bootstrap administrator lacks the expected application identity';
  END IF;

  SELECT id, slug INTO v_board_id, v_board_slug
  FROM public.create_board_p(
    'Admin private board', 'UTC', 'bbbbbbbb-0000-4000-8000-000000000001'
  );
  PERFORM set_config('test.admin_board_id', v_board_id::text, false);
  PERFORM set_config('test.admin_board_slug', v_board_slug, false);
  SELECT id INTO v_column_id FROM public.create_column_p(v_board_slug, v_board_id, 'Admin private', 0);
  PERFORM public.create_task_p(
    'f7000000-0000-4000-8000-000000000001',
    v_board_id,
    v_column_id,
    'Admin-owned content'
  );
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

  PERFORM public.admin_enable_access('pending-target@example.test');
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_list_access()
    WHERE email = 'pending-target@example.test' AND state = 'pending' AND NOT linked
  ) THEN
    RAISE EXCEPTION 'Administrator could not leave a pending authorization for later management';
  END IF;

  BEGIN
    PERFORM public.admin_enable_access('invalid-address');
    RAISE EXCEPTION 'Invalid email address was accepted';
  EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS v_invalid_email_message = MESSAGE_TEXT;
  END;
  IF v_invalid_email_message IS DISTINCT FROM 'Enter a valid Google email address' THEN
    RAISE EXCEPTION 'Invalid email address did not return its expected validation error: %',
      v_invalid_email_message;
  END IF;

  PERFORM public.admin_enable_access('peña@example.test');
  PERFORM public.admin_enable_access('pena@example.test');
  PERFORM public.admin_enable_access('anita.café@example.test');
  PERFORM public.admin_enable_access('anita.cafe@example.test');
  IF (
    SELECT count(*) FROM public.admin_list_access() AS access
    WHERE access.email IN (
      'peña@example.test',
      'pena@example.test',
      'anita.café@example.test',
      'anita.cafe@example.test'
    )
  ) <> 4 THEN
    RAISE EXCEPTION 'Email admission incorrectly normalized accents or ñ';
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
  v_board_slug text;
  v_delete_board_id uuid;
  v_delete_board_slug text;
  v_column_id uuid;
  v_delete_column_id uuid;
  v_sync_topic text;
  v_presence_topic text;
  v_row_count integer;
  v_channel_count integer;
  v_delete_result jsonb;
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

  SELECT id, slug INTO v_board_id, v_board_slug
  FROM public.create_board_p(
    'Enabled private board', 'UTC', 'bbbbbbbb-0000-4000-8000-000000000002'
  );
  PERFORM set_config('test.enabled_board_slug', v_board_slug, false);
  SELECT id INTO v_column_id FROM public.create_column_p(v_board_slug, v_board_id, 'Enabled private', 0);
  PERFORM public.create_task_p(
    'f7000000-0000-4000-8000-000000000002',
    v_board_id,
    v_column_id,
    'Enabled content'
  );
  IF public.get_full_board_p(v_board_slug)->'columns'->0->'tasks'->0->>'title'
    IS DISTINCT FROM 'Enabled content' THEN
    RAISE EXCEPTION 'Enabled identity cannot read its own board';
  END IF;
  IF public.get_full_board_p(current_setting('test.admin_board_slug')) IS NOT NULL THEN
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

  SELECT authorized.sync_topic, authorized.presence_topic
  INTO v_sync_topic, v_presence_topic
  FROM public.get_board_p(v_board_slug) AS authorized;
  IF v_sync_topic IS NULL OR v_presence_topic IS NULL
    OR NOT public.can_access_board_topic(v_sync_topic) THEN
    RAISE EXCEPTION 'Authorized board context did not provide current private topics';
  END IF;
  PERFORM set_config('request.jwt.claim.topic', v_presence_topic, true);
  INSERT INTO realtime.messages(extension, topic, payload)
  VALUES ('presence', v_presence_topic, '{}'::jsonb);
  SELECT count(*) INTO v_channel_count FROM realtime.messages
  WHERE topic = v_presence_topic AND extension = 'presence';
  IF v_channel_count <> 1 THEN
    RAISE EXCEPTION 'The current private presence topic did not retain its message';
  END IF;
  v_denied := false;
  BEGIN
    INSERT INTO realtime.messages(extension, topic, payload)
    VALUES ('broadcast', v_sync_topic, '{}'::jsonb);
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'An authenticated board client published a server-owned broadcast';
  END IF;

  SELECT id, slug INTO v_delete_board_id, v_delete_board_slug
  FROM public.create_board_p(
    'Enabled delete board', 'UTC', 'bbbbbbbb-0000-4000-8000-000000000003'
  );
  SELECT id INTO v_delete_column_id FROM public.create_column_p(v_delete_board_slug, v_delete_board_id, 'To delete', 0);
  PERFORM public.create_task_p(
    'f7000000-0000-4000-8000-000000000003',
    v_delete_board_id,
    v_delete_column_id,
    'Cascade fixture'
  );
  v_delete_result := public.delete_board_p(
    'f7000000-0000-4000-8000-000000000004',
    v_delete_board_slug,
    v_delete_board_id
  );
  IF v_delete_result->>'status' IS DISTINCT FROM 'recoverable'
    OR public.get_full_board_p(v_delete_board_slug) IS NOT NULL
    OR NOT EXISTS (
      SELECT 1 FROM public.list_my_recoverable_boards_p() AS recovery
      WHERE recovery.id = v_delete_board_id
    ) THEN
    RAISE EXCEPTION 'An owner could not hide a board for recovery: %', v_delete_result;
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
  IF public.get_full_board_p(current_setting('test.enabled_board_slug')) IS NOT NULL THEN
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
  IF v_row_count <> 0 OR public.get_full_board_p(current_setting('test.enabled_board_slug')) IS NOT NULL THEN
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

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000007', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'google_required' OR public.is_application_user() THEN
    RAISE EXCEPTION 'An unverified Google email was eligible for a pending authorization: %', v_access;
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: a pending authorization requires a verified Google identity'

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
  v_blocked boolean := false;
BEGIN
  BEGIN
    PERFORM public.admin_suspend_access('enabled-user@example.test');
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_blocked := true;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'Administrator suspended a user who still owns a board';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'enabled-user@example.test' AND access.state = 'active'
  ) THEN
    RAISE EXCEPTION 'A blocked suspension changed the owner’s application state';
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
  v_board_count integer;
BEGIN
  v_access := public.resolve_application_access();
  SELECT count(*) INTO v_board_count FROM public.list_my_boards();
  IF v_access->>'status' <> 'active' OR v_board_count <> 1 THEN
    RAISE EXCEPTION 'A blocked suspension did not preserve the owner’s active access';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' OR v_access->>'is_admin' <> 'false' THEN
    RAISE EXCEPTION 'A no-board identity was not linked for revocation testing: %', v_access;
  END IF;
END;
$$;
COMMIT;

UPDATE auth.users
SET email = 'revocation-user-updated@example.test'
WHERE id = '40000000-0000-4000-8000-000000000005';
UPDATE auth.identities
SET identity_data = jsonb_set(
  identity_data,
  '{email}',
  '"revocation-user-updated@example.test"'::jsonb
)
WHERE user_id = '40000000-0000-4000-8000-000000000005'
  AND provider = 'google';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' THEN
    RAISE EXCEPTION 'A changed Google email broke its stable linked identity: %', v_access;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'revocation-user@example.test'
      AND access.state = 'active' AND access.linked
  ) OR EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'revocation-user-updated@example.test'
  ) THEN
    RAISE EXCEPTION 'A changed email created or moved an application identity';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_suspended boolean;
BEGIN
  v_suspended := public.admin_suspend_access('revocation-user@example.test');
  IF NOT v_suspended THEN
    RAISE EXCEPTION 'Administrator did not suspend the no-board user';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
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
  IF v_row_count <> 0 OR public.get_full_board_p(current_setting('test.enabled_board_slug')) IS NOT NULL THEN
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

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
BEGIN
  PERFORM public.admin_enable_access('revocation-user@example.test');
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'revocation-user@example.test'
      AND access.state = 'active' AND access.linked
  ) THEN
    RAISE EXCEPTION 'Rehabilitation did not preserve the linked authorization';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'revocation-user-updated@example.test'
  ) THEN
    RAISE EXCEPTION 'Rehabilitation created an authorization under the changed email';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_access jsonb;
  v_board_count integer;
BEGIN
  v_access := public.resolve_application_access();
  SELECT count(*) INTO v_board_count FROM public.list_my_boards();
  IF v_access->>'status' <> 'active' OR v_board_count <> 0 THEN
    RAISE EXCEPTION 'Rehabilitation did not restore the same access without recreating boards';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' OR v_access->>'is_admin' <> 'true' THEN
    RAISE EXCEPTION 'Second administrator fixture was not linked for concurrency testing';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: stable Google subject, unchanged access row, and an isolated second administrator fixture'
