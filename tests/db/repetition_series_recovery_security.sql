\set ON_ERROR_STOP on

-- Series recovery endpoints disclose and mutate deleted history only for a
-- currently enabled board member. Public execution is limited to the
-- authenticated RPC surface; backing snapshots stay private.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue28-outsider@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '42800000-0000-4000-8000-000000000201',
  'issue28-outsider@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '52800000-0000-4000-8000-000000000201',
  '42800000-0000-4000-8000-000000000201', 'google',
  'issue28-outsider-google-subject',
  '{"email":"issue28-outsider@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '42800000-0000-4000-8000-000000000201',
    google_subject = 'issue28-outsider-google-subject', state = 'active'
WHERE email = 'issue28-outsider@example.test';

DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_series jsonb;
  v_deleted jsonb;
  v_preview jsonb;
  v_restore jsonb;
  v_series_id uuid;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Recovery permissions #28', 'UTC', '42800000-0000-4000-8000-000000000210'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  v_task := public.create_task_p(
    '42800000-0000-4000-8000-000000000211', v_board.id,
    v_column.id, 'Serie privada', 'No debe filtrarse', 'medium'
  );
  IF public.edit_task_fields_p(
    '42800000-0000-4000-8000-000000000212', v_board.slug,
    (v_task->>'task_id')::uuid,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  )->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic recovery task setup failed';
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '42800000-0000-4000-8000-000000000213', v_board.slug,
    (v_task->>'task_id')::uuid, current_date, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  v_series_id := (v_series->>'series_id')::uuid;
  v_deleted := public.delete_repetition_series_p(
    '42800000-0000-4000-8000-000000000214', v_board.slug, v_series_id,
    (v_series->>'series_revision')::bigint, true
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic recovery deletion failed: %', v_deleted;
  END IF;

  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '42800000-0000-4000-8000-000000000201', true
  );
  v_preview := public.preview_delete_repetition_series_p(v_board.slug, v_series_id);
  v_restore := public.restore_repetition_series_p(
    '42800000-0000-4000-8000-000000000215', v_board.slug, v_series_id, NULL
  );
  IF v_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_restore->>'status' IS DISTINCT FROM 'unavailable'
    OR jsonb_array_length(
      public.list_deleted_repetition_series_p(v_board.id)->'series'
    ) <> 0
    OR (SELECT deletion.state FROM public.daily_repetition_series_deletions AS deletion
        WHERE deletion.series_id = v_series_id) IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'A nonmember listed, previewed, or restored another member''s series';
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT has_function_privilege(
      'authenticated', 'public.preview_delete_repetition_series_p(text,uuid)', 'EXECUTE'
    ) OR NOT has_function_privilege(
      'authenticated', 'public.delete_repetition_series_p(uuid,text,uuid,bigint,boolean)', 'EXECUTE'
    ) OR NOT has_function_privilege(
      'authenticated', 'public.list_deleted_repetition_series_p(uuid)', 'EXECUTE'
    ) OR NOT has_function_privilege(
      'authenticated', 'public.restore_repetition_series_p(uuid,text,uuid,uuid)', 'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'Authenticated role is missing a public series recovery RPC';
  END IF;
  IF has_function_privilege(
      'anon', 'public.preview_delete_repetition_series_p(text,uuid)', 'EXECUTE'
    ) OR has_function_privilege(
      'anon', 'public.delete_repetition_series_p(uuid,text,uuid,bigint,boolean)', 'EXECUTE'
    ) OR has_function_privilege(
      'anon', 'public.list_deleted_repetition_series_p(uuid)', 'EXECUTE'
    ) OR has_function_privilege(
      'anon', 'public.restore_repetition_series_p(uuid,text,uuid,uuid)', 'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'Anonymous role can execute a series recovery RPC';
  END IF;
  IF has_table_privilege('authenticated', 'public.daily_repetition_series_deletions', 'SELECT')
    OR has_table_privilege('authenticated', 'public.daily_repetition_series_deletions', 'INSERT')
    OR has_table_privilege('anon', 'public.daily_repetition_series_deletions', 'SELECT') THEN
    RAISE EXCEPTION 'A public role can access private series recovery snapshots';
  END IF;
END;
$$;

COMMIT;
\echo 'PASS: series recovery authorization, membership, and snapshot ACLs.'
