\set ON_ERROR_STOP on
\echo 'Issue #34: view preferences are private, context-scoped, and versioned per setting'

INSERT INTO public.application_access (email, state, is_admin)
VALUES
  ('issue34-preferences-a@example.test', 'pending', false),
  ('issue34-preferences-b@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES
  ('43400000-0000-4000-8000-000000000001',
    'issue34-preferences-a@example.test', now(), '{"provider":"google"}'),
  ('43400000-0000-4000-8000-000000000002',
    'issue34-preferences-b@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES
  ('53400000-0000-4000-8000-000000000001',
    '43400000-0000-4000-8000-000000000001', 'google', 'issue34-preferences-a',
    '{"email":"issue34-preferences-a@example.test","email_verified":true}'),
  ('53400000-0000-4000-8000-000000000002',
    '43400000-0000-4000-8000-000000000002', 'google', 'issue34-preferences-b',
    '{"email":"issue34-preferences-b@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = auth_user.id,
    google_subject = identity.provider_id,
    state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE access.email = auth_user.email
  AND access.email LIKE 'issue34-preferences-%@example.test';

CREATE TEMP TABLE issue34_preference_board (board_id uuid NOT NULL);
GRANT SELECT, INSERT ON issue34_preference_board TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_snapshot jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 34 preference board',
    'America/Argentina/Buenos_Aires',
    'a3400000-0000-4000-8000-000000000001'
  );
  INSERT INTO pg_temp.issue34_preference_board(board_id) VALUES (v_board.id);

  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  IF v_snapshot->>'status' IS DISTINCT FROM 'available'
    OR v_snapshot->'preferences'->'order'->'value' IS DISTINCT FROM '"due"'::jsonb
    OR (v_snapshot->'preferences'->'order'->>'version')::integer IS DISTINCT FROM 0
    OR v_snapshot->'preferences'->'include_history'->'value' IS DISTINCT FROM 'false'::jsonb THEN
    RAISE EXCEPTION 'A new account/context should return defaults at version zero: %', v_snapshot;
  END IF;

  v_result := public.set_my_view_preference_p(
    'search_all', NULL, 'order', '"created"'::jsonb, 0
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR v_result->'value' IS DISTINCT FROM '"created"'::jsonb
    OR (v_result->>'version')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'The first context preference did not save at version 1: %', v_result;
  END IF;

  v_result := public.set_my_view_preference_p(
    'search_all', NULL, 'filter_due', '"today"'::jsonb, 0
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'A separate preference conflicted with the order setting: %', v_result;
  END IF;

  v_result := public.set_my_view_preference_p(
    'search_all', NULL, 'order', '"due"'::jsonb, 0
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->'value' IS DISTINCT FROM '"created"'::jsonb
    OR (v_result->>'version')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'A stale write must preserve and return the saved setting: %', v_result;
  END IF;

  v_result := public.set_my_view_preference_p(
    'board', v_board.id, 'labels', '[]'::jsonb, 0
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'An owner could not save preferences for the active board: %', v_result;
  END IF;

  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  v_result := public.reset_my_view_preferences_p(
    'search_all', NULL,
    (SELECT jsonb_object_agg(key, value->'version')
     FROM jsonb_each(v_snapshot->'preferences'))
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR v_result->'preferences'->'order'->'value' IS DISTINCT FROM '"due"'::jsonb
    OR v_result->'preferences'->'filter_due'->'value' IS DISTINCT FROM 'null'::jsonb
    OR (v_result->'preferences'->'order'->>'version')::integer <> 2
    OR (v_result->'preferences'->'filter_due'->>'version')::integer <> 2 THEN
    RAISE EXCEPTION 'Reset should atomically restore only this context defaults: %', v_result;
  END IF;

  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  v_result := public.set_my_view_preference_p(
    'search_all', NULL, 'order', '"created"'::jsonb,
    (v_snapshot->'preferences'->'order'->>'version')::integer
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'The post-reset setting could not be updated: %', v_result;
  END IF;
  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  v_result := public.reset_my_view_preferences_p(
    'search_all', NULL,
    (SELECT jsonb_object_agg(key, value->'version')
     FROM jsonb_each(v_snapshot->'preferences'))
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'A fresh reset version set should succeed: %', v_result;
  END IF;
  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  v_result := public.set_my_view_preference_p(
    'search_all', NULL, 'order', '"created"'::jsonb,
    (v_snapshot->'preferences'->'order'->>'version')::integer
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'Could not prepare a concurrent reset conflict: %', v_result;
  END IF;
  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  v_result := public.reset_my_view_preferences_p(
    'search_all', NULL,
    jsonb_set(
      (SELECT jsonb_object_agg(key, value->'version')
       FROM jsonb_each(v_snapshot->'preferences')),
      '{order}', to_jsonb((v_snapshot->'preferences'->'order'->>'version')::integer - 1)
    )
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->'preferences'->'order'->'value' IS DISTINCT FROM '"created"'::jsonb THEN
    RAISE EXCEPTION 'Stale reset should return current state without changing it: %', v_result;
  END IF;
  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  IF v_snapshot->'preferences'->'order'->'value' IS DISTINCT FROM '"created"'::jsonb THEN
    RAISE EXCEPTION 'Stale reset changed data before explicit review: %', v_snapshot;
  END IF;
  v_result := public.set_my_view_preference_p(
    'search_all', NULL, 'filter_due', '"today"'::jsonb, 0
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->'value' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'Reset should preserve setting versions and reject stale client writes: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43400000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_snapshot jsonb;
  v_result jsonb;
  v_rejected boolean := false;
BEGIN
  SELECT board_id INTO STRICT v_board_id FROM pg_temp.issue34_preference_board;

  v_snapshot := public.get_my_view_preferences_p('search_all', NULL);
  IF v_snapshot->>'status' IS DISTINCT FROM 'available'
    OR v_snapshot->'preferences'->'order'->'value' IS DISTINCT FROM '"due"'::jsonb
    OR (v_snapshot->'preferences'->'order'->>'version')::integer IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'A second account inherited another account’s preferences: %', v_snapshot;
  END IF;

  v_snapshot := public.get_my_view_preferences_p('board', v_board_id);
  IF v_snapshot->>'status' IS DISTINCT FROM 'unavailable'
    OR v_snapshot ? 'preferences' THEN
    RAISE EXCEPTION 'A non-member learned board preference state: %', v_snapshot;
  END IF;

  v_result := public.set_my_view_preference_p(
    'board', v_board_id, 'labels', '[]'::jsonb, 0
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR v_result ? 'value' THEN
    RAISE EXCEPTION 'A non-member changed or learned a board preference: %', v_result;
  END IF;

  v_result := public.reset_my_view_preferences_p(
    'board', v_board_id,
    jsonb_build_object('labels', 1, 'completed_view', 0)
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR v_result ? 'preferences' THEN
    RAISE EXCEPTION 'A non-member reset or learned board preference state: %', v_result;
  END IF;

  BEGIN
    PERFORM public.set_my_view_preference_p(
      'search_all', NULL, 'unknown_setting', '"private"'::jsonb, 0
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'An unrecognized context preference was accepted';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board_id uuid;
  v_snapshot jsonb;
BEGIN
  SELECT board_id INTO STRICT v_board_id FROM pg_temp.issue34_preference_board;
  v_snapshot := public.get_my_view_preferences_p('board', v_board_id);
  IF v_snapshot->'preferences'->'labels'->'value' IS DISTINCT FROM '[]'::jsonb
    OR (v_snapshot->'preferences'->'labels'->>'version')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'A non-member reset changed the owner board preference: %', v_snapshot;
  END IF;
END;
$$;
COMMIT;

DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.user_view_preferences', 'SELECT')
    OR has_table_privilege('authenticated', 'public.user_view_preferences', 'INSERT')
    OR has_table_privilege('authenticated', 'public.user_view_preferences', 'UPDATE')
    OR has_table_privilege('authenticated', 'public.user_view_preferences', 'DELETE')
    OR has_function_privilege('anon',
      'public.get_my_view_preferences_p(text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Clients can bypass the private context preference RPC';
  END IF;
END;
$$;

\echo 'PASS: view preferences are actor/context-scoped, CAS-versioned, and board-authorized'
