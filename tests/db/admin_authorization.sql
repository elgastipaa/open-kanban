\set ON_ERROR_STOP on
\echo 'Testing active non-admin denial for every global-access RPC'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_denied boolean;
BEGIN
  IF public.is_application_admin() THEN
    RAISE EXCEPTION 'A regular enabled user unexpectedly has application administration';
  END IF;

  v_denied := false;
  BEGIN
    PERFORM * FROM public.admin_list_access();
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A regular enabled user read the global access list';
  END IF;

  v_denied := false;
  BEGIN
    PERFORM public.admin_enable_access('unauthorized-new@example.test');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A regular enabled user granted global access';
  END IF;

  v_denied := false;
  BEGIN
    PERFORM public.admin_remove_pending_access('pending-target@example.test');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A regular enabled user withdrew pending global access';
  END IF;

  v_denied := false;
  BEGIN
    PERFORM public.admin_suspend_access('revocation-user@example.test');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A regular enabled user suspended another application account';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'unauthorized-new@example.test'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'pending-target@example.test'
      AND access.state = 'pending' AND NOT access.linked
  ) OR NOT EXISTS (
    SELECT 1 FROM public.admin_list_access() AS access
    WHERE access.email = 'revocation-user@example.test'
      AND access.state = 'active' AND access.linked
  ) THEN
    RAISE EXCEPTION 'A regular enabled user changed application access state';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: an active non-admin cannot list, enable, remove, or suspend global access'
