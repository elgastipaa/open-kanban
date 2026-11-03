\set ON_ERROR_STOP on
\echo 'Issue #5 smoke test for an isolated Supabase local project; all Auth identities are synthetic.'

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('60000000-0000-4000-8000-000000000001', 'local-admin@example.test', now(), '{"provider":"google"}'),
  ('60000000-0000-4000-8000-000000000002', 'local-owner@example.test', now(), '{"provider":"google"}'),
  ('60000000-0000-4000-8000-000000000003', 'local-revocation@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (user_id, provider, provider_id, identity_data, last_sign_in_at) VALUES
  ('60000000-0000-4000-8000-000000000001', 'google', 'local-google-subject-admin', '{"email":"local-admin@example.test","email_verified":true}', now()),
  ('60000000-0000-4000-8000-000000000002', 'google', 'local-google-subject-owner', '{"email":"local-owner@example.test","email_verified":true}', now()),
  ('60000000-0000-4000-8000-000000000003', 'google', 'local-google-subject-revocation', '{"email":"local-revocation@example.test","email_verified":true}', now());
INSERT INTO public.application_access(email, state, is_admin) VALUES
  ('local-admin@example.test', 'pending', true);

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' OR v_access->>'is_admin' <> 'true' THEN
    RAISE EXCEPTION 'The explicit synthetic bootstrap identity did not become an admin';
  END IF;
  PERFORM public.admin_enable_access('local-owner@example.test');
  PERFORM public.admin_enable_access('local-revocation@example.test');
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' THEN
    RAISE EXCEPTION 'The synthetic board owner was not admitted';
  END IF;
  PERFORM public.create_board_p('issue5-local-owner-board');
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' THEN
    RAISE EXCEPTION 'The synthetic no-board identity was not admitted';
  END IF;
END;
$$;
COMMIT;

UPDATE auth.users
SET email = 'local-revocation-updated@example.test'
WHERE id = '60000000-0000-4000-8000-000000000003';
UPDATE auth.identities
SET identity_data = jsonb_set(identity_data, '{email}', '"local-revocation-updated@example.test"'::jsonb)
WHERE user_id = '60000000-0000-4000-8000-000000000003' AND provider = 'google';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'active' THEN
    RAISE EXCEPTION 'A changed Google email replaced the stable linked identity';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_owner_blocked boolean := false;
  v_final_admin_blocked boolean := false;
  v_suspended boolean;
BEGIN
  IF public.get_full_board_p('issue5-local-owner-board') IS NOT NULL THEN
    RAISE EXCEPTION 'Global administration obtained another person’s board content';
  END IF;

  BEGIN
    PERFORM public.admin_suspend_access('local-owner@example.test');
  EXCEPTION WHEN SQLSTATE '55000' THEN
    v_owner_blocked := true;
  END;
  IF NOT v_owner_blocked OR NOT EXISTS (
    SELECT 1 FROM public.admin_list_access()
    WHERE email = 'local-owner@example.test' AND state = 'active'
  ) THEN
    RAISE EXCEPTION 'Suspension was not blocked for an account that owns a board';
  END IF;

  v_suspended := public.admin_suspend_access('local-revocation@example.test');
  IF NOT v_suspended THEN
    RAISE EXCEPTION 'Administrator could not suspend the synthetic no-board identity';
  END IF;

  BEGIN
    PERFORM public.admin_suspend_access('local-admin@example.test');
  EXCEPTION WHEN check_violation THEN
    v_final_admin_blocked := true;
  END;
  IF NOT v_final_admin_blocked THEN
    RAISE EXCEPTION 'The only active administrator could be suspended';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_access jsonb;
  v_denied boolean := false;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' <> 'suspended' OR public.is_application_user() THEN
    RAISE EXCEPTION 'An old synthetic Auth claim bypassed current suspension';
  END IF;
  BEGIN
    PERFORM public.create_board_p('issue5-local-forbidden-board');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A suspended identity wrote with its old Auth claim';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000001', true);
DO $$
BEGIN
  PERFORM public.admin_enable_access('local-revocation@example.test');
  IF NOT EXISTS (
    SELECT 1 FROM public.admin_list_access()
    WHERE email = 'local-revocation@example.test' AND state = 'active' AND linked
  ) OR EXISTS (
    SELECT 1 FROM public.admin_list_access()
    WHERE email = 'local-revocation-updated@example.test'
  ) THEN
    RAISE EXCEPTION 'Rehabilitation changed or duplicated the linked identity';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '60000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_access jsonb;
  v_board_count integer;
BEGIN
  v_access := public.resolve_application_access();
  SELECT count(*) INTO v_board_count FROM public.list_my_boards();
  IF v_access->>'status' <> 'active' OR v_board_count <> 0 THEN
    RAISE EXCEPTION 'Rehabilitation did not restore just the application access';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: isolated Supabase Auth identity linking, ownership deferral, revocation, unique-admin guard, and rehabilitation.'
