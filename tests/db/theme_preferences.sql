\set ON_ERROR_STOP on
\echo 'Issue #22: themes are personal, versioned, and inaccessible without active application access'

INSERT INTO public.user_preferences(user_id, preference_key, value)
VALUES (
  '40000000-0000-4000-8000-000000000002',
  'completed_visibility',
  'false'::jsonb
);

BEGIN;
SET LOCAL ROLE anon;
DO $$
DECLARE
  v_read_denied boolean := false;
  v_write_denied boolean := false;
BEGIN
  BEGIN
    PERFORM 1 FROM public.get_my_theme_preference_p();
  EXCEPTION WHEN insufficient_privilege THEN
    v_read_denied := true;
  END;
  BEGIN
    PERFORM public.set_my_theme_preference_p('dark', 0);
  EXCEPTION WHEN insufficient_privilege THEN
    v_write_denied := true;
  END;
  IF NOT v_read_denied OR NOT v_write_denied THEN
    RAISE EXCEPTION 'An anonymous session could read or change an account theme';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_read_denied boolean := false;
  v_write_denied boolean := false;
BEGIN
  BEGIN
    PERFORM 1 FROM public.get_my_theme_preference_p();
  EXCEPTION WHEN insufficient_privilege THEN
    v_read_denied := true;
  END;
  BEGIN
    PERFORM public.set_my_theme_preference_p('dark', 0);
  EXCEPTION WHEN insufficient_privilege THEN
    v_write_denied := true;
  END;
  IF NOT v_read_denied OR NOT v_write_denied THEN
    RAISE EXCEPTION 'An account without application admission could read or change its theme';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_theme text;
  v_version integer;
  v_result jsonb;
BEGIN
  SELECT theme, version INTO STRICT v_theme, v_version
  FROM public.get_my_theme_preference_p();
  IF v_theme IS DISTINCT FROM 'system' OR v_version IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'A person without a saved theme did not start in System: %, %', v_theme, v_version;
  END IF;

  v_result := public.set_my_theme_preference_p('light', 0);
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR v_result->>'theme' IS DISTINCT FROM 'light'
    OR (v_result->>'version')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'The initial theme change did not save at version 1: %', v_result;
  END IF;

  v_result := public.set_my_theme_preference_p('dark', 1);
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR v_result->>'theme' IS DISTINCT FROM 'dark'
    OR (v_result->>'version')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'The next theme change did not save at version 2: %', v_result;
  END IF;

  v_result := public.set_my_theme_preference_p('light', 1);
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'theme' IS DISTINCT FROM 'dark'
    OR (v_result->>'version')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'A stale device did not receive the saved theme for review: %', v_result;
  END IF;

  v_result := public.set_my_theme_preference_p('light', 3);
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'theme' IS DISTINCT FROM 'dark'
    OR (v_result->>'version')::integer IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'A future-version device overwrote a saved theme: %', v_result;
  END IF;

  SELECT theme, version INTO STRICT v_theme, v_version
  FROM public.get_my_theme_preference_p();
  IF v_theme IS DISTINCT FROM 'dark' OR v_version IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'A stale write silently replaced the saved theme: %, %', v_theme, v_version;
  END IF;

END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.set_my_theme_preference_p('dark', 1);
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'theme' IS DISTINCT FROM 'system'
    OR (v_result->>'version')::integer IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'A nonzero stale write created a preference for the second account: %', v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_other_preference jsonb;
BEGIN
  SELECT preference.value INTO STRICT v_other_preference
  FROM public.user_preferences AS preference
  WHERE preference.user_id = '40000000-0000-4000-8000-000000000002'
    AND preference.preference_key = 'completed_visibility';
  IF v_other_preference IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'Saving a theme changed an independent preference: %', v_other_preference;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_theme text;
  v_version integer;
  v_result jsonb;
BEGIN
  SELECT theme, version INTO STRICT v_theme, v_version
  FROM public.get_my_theme_preference_p();
  IF v_theme IS DISTINCT FROM 'system' OR v_version IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'A second account inherited the first account’s theme: %, %', v_theme, v_version;
  END IF;

  v_result := public.set_my_theme_preference_p('light', 0);
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'The second account could not save its personal theme: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_theme text;
  v_version integer;
BEGIN
  SELECT theme, version INTO STRICT v_theme, v_version
  FROM public.get_my_theme_preference_p();
  IF v_theme IS DISTINCT FROM 'dark' OR v_version IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'Changing another account did not preserve this account’s preference: %, %', v_theme, v_version;
  END IF;
END;
$$;
COMMIT;

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.user_preferences', 'SELECT')
    OR has_table_privilege('authenticated', 'public.user_preferences', 'INSERT')
    OR has_table_privilege('authenticated', 'public.user_preferences', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.user_preferences', 'DELETE')
    OR has_table_privilege('anon', 'public.user_preferences', 'SELECT')
    OR has_function_privilege('anon', 'public.get_my_theme_preference_p()', 'EXECUTE') THEN
    RAISE EXCEPTION 'Clients can bypass the personal preference RPC';
  END IF;
END;
$$;

\echo 'PASS: themes use optimistic per-preference versions and remain isolated by account'
