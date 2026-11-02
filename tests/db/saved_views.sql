\set ON_ERROR_STOP on
\echo 'Issue #35: personal saved views preserve a full named definition by context'

INSERT INTO public.application_access (email, state, is_admin)
VALUES
  ('issue35-view-owner@example.test', 'pending', false),
  ('issue35-view-other@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES
  ('43500000-0000-4000-8000-000000000001',
    'issue35-view-owner@example.test', now(), '{"provider":"google"}'),
  ('43500000-0000-4000-8000-000000000002',
    'issue35-view-other@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES
  ('53500000-0000-4000-8000-000000000001',
    '43500000-0000-4000-8000-000000000001', 'google', 'issue35-view-owner',
    '{"email":"issue35-view-owner@example.test","email_verified":true}'),
  ('53500000-0000-4000-8000-000000000002',
    '43500000-0000-4000-8000-000000000002', 'google', 'issue35-view-other',
    '{"email":"issue35-view-other@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = auth_user.id,
    google_subject = identity.provider_id,
    state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE access.email = auth_user.email
  AND access.email LIKE 'issue35-view-%@example.test';

CREATE TEMP TABLE issue35_view_refs (
  ref_name text PRIMARY KEY,
  view_id uuid NOT NULL
);
GRANT SELECT, INSERT ON issue35_view_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43500000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_definition jsonb := jsonb_build_object(
    'query', 'reunión',
    'scope', 'all',
    'boardId', NULL,
    'includeCompleted', true,
    'includeHistory', true,
    'filterBoardId', NULL,
    'dueFilter', 'next_7_days',
    'priority', 'high',
    'assigneeId', NULL,
    'unassigned', true,
    'labels', '[]'::jsonb,
    'order', 'created'
  );
  v_created jsonb;
  v_list jsonb;
  v_my_tasks_definition jsonb := jsonb_build_object(
    'query', '',
    'scope', 'my_tasks',
    'boardId', NULL,
    'includeCompleted', true,
    'includeHistory', false,
    'filterBoardId', NULL,
    'dueFilter', NULL,
    'priority', NULL,
    'assigneeId', NULL,
    'unassigned', false,
    'labels', '[]'::jsonb,
    'order', 'due'
  );
  v_result jsonb;
  v_index integer;
  v_view_id uuid;
  v_updated_definition jsonb;
  v_board record;
  v_board_label jsonb;
  v_reference_definition jsonb;
  v_reference_view_id uuid;
  v_delete_label jsonb;
  v_label_preview jsonb;
  v_restore_label jsonb;
  v_preview jsonb;
  v_restore jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 35 reference board',
    'America/Argentina/Buenos_Aires',
    'a3500000-0000-4000-8000-000000000001'
  );
  v_board_label := public.create_board_label_p(v_board.slug, 'Plan', 'blue');
  IF v_board_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The reference fixture label should be created: %', v_board_label;
  END IF;

  v_created := public.create_my_saved_view_p(
    'search', 'Próxima semana', v_definition
  );
  IF v_created->>'status' IS DISTINCT FROM 'saved'
    OR v_created->'view'->>'name' IS DISTINCT FROM 'Próxima semana'
    OR v_created->'view'->>'context_type' IS DISTINCT FROM 'search'
    OR v_created->'view'->'definition' IS DISTINCT FROM v_definition
    OR (v_created->'view'->>'version')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'A newly saved search view must return its full definition: %', v_created;
  END IF;
  v_view_id := (v_created->'view'->>'id')::uuid;

  v_reference_definition := jsonb_set(
    jsonb_set(v_definition, '{scope}', '"board"'::jsonb),
    '{boardId}', to_jsonb(v_board.id)
  );
  v_reference_definition := jsonb_set(
    v_reference_definition,
    '{labels}',
    jsonb_build_array(jsonb_build_object(
      'boardId', v_board.id,
      'labelId', v_board_label->'label'->>'id'
    ))
  );
  v_result := public.create_my_saved_view_p(
    'search', 'Referencia activa', v_reference_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR (v_result->'view'->>'needs_review')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'A saved view may capture active references it can currently access: %', v_result;
  END IF;
  v_reference_view_id := (v_result->'view'->>'id')::uuid;

  v_updated_definition := jsonb_set(
    jsonb_set(v_definition, '{scope}', '"board"'::jsonb),
    '{boardId}', to_jsonb('a3500000-0000-4000-8000-000000000099'::uuid)
  );
  v_result := public.create_my_saved_view_p(
    'search', 'Referencia no autorizada', v_updated_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'invalid_references'
    OR v_result ? 'view' THEN
    RAISE EXCEPTION 'A new view must not save an inaccessible board reference: %', v_result;
  END IF;
  v_updated_definition := jsonb_set(
    jsonb_set(v_definition, '{scope}', '"board"'::jsonb),
    '{boardId}', to_jsonb(v_board.id)
  );
  v_updated_definition := jsonb_set(
    v_updated_definition,
    '{labels}',
    jsonb_build_array(jsonb_build_object(
      'boardId', v_board.id,
      'labelId', 'a3500000-0000-4000-8000-000000000099'
    ))
  );
  v_result := public.create_my_saved_view_p(
    'search', 'Etiqueta no disponible', v_updated_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'invalid_references'
    OR v_result->'invalid_references'->0->>'field' IS DISTINCT FROM 'labels' THEN
    RAISE EXCEPTION 'A new view must reject an unknown label ID without resolving its name: %', v_result;
  END IF;
  v_updated_definition := jsonb_set(
    v_reference_definition, '{assigneeId}',
    '"a3500000-0000-4000-8000-000000000099"'::jsonb
  );
  v_updated_definition := jsonb_set(v_updated_definition, '{unassigned}', 'false'::jsonb);
  v_result := public.create_my_saved_view_p(
    'search', 'Responsable no disponible', v_updated_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'invalid_references'
    OR v_result->'invalid_references'->0->>'field' IS DISTINCT FROM 'assigneeId' THEN
    RAISE EXCEPTION 'A new view must reject an unavailable member reference: %', v_result;
  END IF;

  v_delete_label := public.delete_board_label_p(
    v_board.slug,
    (v_board_label->'label'->>'id')::uuid,
    (v_board_label->'label'->>'version')::bigint
  );
  IF v_delete_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The owner should be able to remove the reference label: %', v_delete_label;
  END IF;
  v_label_preview := public.preview_restore_board_label_p(
    v_board.slug,
    (v_board_label->'label'->>'id')::uuid,
    'Plan'
  );
  IF v_label_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_label_preview->'can_restore' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'The unchanged label should be restorable for this fixture: %', v_label_preview;
  END IF;
  v_restore_label := public.restore_board_label_p(
    v_board.slug,
    (v_board_label->'label'->>'id')::uuid,
    (v_delete_label->'label'->>'version')::bigint,
    'Plan', ARRAY[]::uuid[], ARRAY[]::uuid[]
  );
  IF v_restore_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The owner should be able to explicitly restore the reference label: %', v_restore_label;
  END IF;
  v_list := public.list_my_saved_views_p('search');
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'active_views') AS saved_view
    WHERE saved_view->>'id' = v_reference_view_id::text
      AND (saved_view->>'needs_review')::boolean
  ) THEN
    RAISE EXCEPTION 'A restored reference must remain blocked until explicit view review: %', v_list;
  END IF;
  v_result := public.delete_my_saved_view_p(v_reference_view_id, 2);
  IF v_result->>'status' IS DISTINCT FROM 'deleted'
    OR (v_result->'view'->>'version')::integer <> 3 THEN
    RAISE EXCEPTION 'A flagged saved view should keep its version when deleted: %', v_result;
  END IF;
  v_preview := public.preview_restore_my_saved_view_p(
    'search', v_reference_view_id, 'Referencia activa', v_reference_definition
  );
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_preview->'can_restore' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'The restored label reference should be explicitly reviewable in recovery: %', v_preview;
  END IF;
  v_restore := public.restore_my_saved_view_p(
    'search', v_reference_view_id, 3, 'Referencia activa', v_reference_definition
  );
  IF v_restore->>'status' IS DISTINCT FROM 'restored'
    OR (v_restore->'view'->>'version')::integer <> 4
    OR (v_restore->'view'->>'needs_review')::boolean THEN
    RAISE EXCEPTION 'Explicit recovery confirmation should clear the review state: %', v_restore;
  END IF;
  v_result := public.update_my_saved_view_p(
    v_reference_view_id, 4, 'Referencia activa', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR (v_result->'view'->>'needs_review')::boolean
    OR (v_result->'view'->>'version')::integer <> 5 THEN
    RAISE EXCEPTION 'An explicit corrected update should clear review atomically: %', v_result;
  END IF;

  v_list := public.list_my_saved_views_p('search');
  IF v_list->>'status' IS DISTINCT FROM 'available'
    OR v_list->>'context_type' IS DISTINCT FROM 'search'
    OR jsonb_array_length(v_list->'active_views') <> 2
    OR v_list->'active_views'->0->'definition' IS DISTINCT FROM v_definition
    OR v_list->'active_views'->0->>'name' IS DISTINCT FROM 'Próxima semana'
    OR jsonb_array_length(v_list->'deleted_views') <> 0 THEN
    RAISE EXCEPTION 'The owner should list the stored active view without changing its definition: %', v_list;
  END IF;

  v_result := public.create_my_saved_view_p(
    'search', '  Reunión  ', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR v_result->'view'->>'name' IS DISTINCT FROM '  Reunión  ' THEN
    RAISE EXCEPTION 'Saved view names preserve entered spelling and spacing: %', v_result;
  END IF;
  v_result := public.create_my_saved_view_p('search', 'reunion', v_definition);
  IF v_result->>'status' IS DISTINCT FROM 'name_conflict' THEN
    RAISE EXCEPTION 'Names collide after accent/case/space normalization: %', v_result;
  END IF;
  v_result := public.create_my_saved_view_p('search', 'Peña', v_definition);
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'The original ñ spelling should be retained: %', v_result;
  END IF;
  v_result := public.create_my_saved_view_p('search', 'Pena', v_definition);
  IF v_result->>'status' IS DISTINCT FROM 'name_conflict' THEN
    RAISE EXCEPTION 'Names collide when ñ is normalized to n: %', v_result;
  END IF;
  v_result := public.create_my_saved_view_p(
    'my_tasks', 'Peña', v_my_tasks_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'The same name is allowed in a different view context: %', v_result;
  END IF;

  v_result := public.create_my_saved_view_p(
    'search', repeat('ñ', 60), v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'A 60-codepoint view name should be accepted: %', v_result;
  END IF;
  BEGIN
    PERFORM public.create_my_saved_view_p(
      'search', repeat('ñ', 61), v_definition
    );
    RAISE EXCEPTION 'A 61-codepoint view name was accepted';
  EXCEPTION WHEN invalid_parameter_value THEN
    NULL;
  END;

  FOR v_index IN 1..44 LOOP
    IF v_index % 2 = 0 THEN
      v_result := public.create_my_saved_view_p(
        'my_tasks', 'Otra vista ' || v_index, v_my_tasks_definition
      );
    ELSE
      v_result := public.create_my_saved_view_p(
        'search', 'Otra vista ' || v_index, v_definition
      );
    END IF;
    IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
      RAISE EXCEPTION 'View number % should fit into the shared 50-view quota: %',
        v_index, v_result;
    END IF;
  END LOOP;
  v_result := public.create_my_saved_view_p(
    'my_tasks', 'Vista 51', v_my_tasks_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'limit_reached' THEN
    RAISE EXCEPTION 'The 51st active view across contexts must be rejected: %', v_result;
  END IF;

  v_updated_definition := jsonb_set(
    v_definition, '{query}', '"planificación"'::jsonb
  );
  v_result := public.update_my_saved_view_p(
    v_view_id, 1, 'Próxima semana', v_updated_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved'
    OR (v_result->'view'->>'version')::integer IS DISTINCT FROM 2
    OR v_result->'view'->'definition' IS DISTINCT FROM v_updated_definition THEN
    RAISE EXCEPTION 'A current view version should update atomically: %', v_result;
  END IF;

  v_result := public.update_my_saved_view_p(
    v_view_id, 1, 'Próxima semana', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR (v_result->'view'->>'version')::integer IS DISTINCT FROM 2
    OR v_result->'view'->'definition' IS DISTINCT FROM v_updated_definition THEN
    RAISE EXCEPTION 'A stale save must return the current view without overwriting it: %', v_result;
  END IF;

  v_result := public.delete_my_saved_view_p(v_view_id, 2);
  IF v_result->>'status' IS DISTINCT FROM 'deleted'
    OR (v_result->'view'->>'version')::integer IS DISTINCT FROM 3
    OR v_result->'view'->>'deleted_at' IS NULL THEN
    RAISE EXCEPTION 'Deleting a view should create a recoverable versioned tombstone: %', v_result;
  END IF;

  v_result := public.update_my_saved_view_p(
    v_view_id, 2, 'Próxima semana', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'A late save must not resurrect a deleted view: %', v_result;
  END IF;

  v_list := public.list_my_saved_views_p('search');
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'active_views') AS active_view
    WHERE active_view->>'id' = v_view_id::text
  ) OR NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_list->'deleted_views') AS deleted_view
    WHERE deleted_view->>'id' = v_view_id::text
      AND deleted_view->'definition' = v_updated_definition
  ) THEN
    RAISE EXCEPTION 'Deleted view should be absent from active list and retained in recovery: %', v_list;
  END IF;

  v_result := public.create_my_saved_view_p(
    'search', 'Próxima semana', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
    RAISE EXCEPTION 'A deleted view name may be reused: %', v_result;
  END IF;
  v_result := public.create_my_saved_view_p(
    'my_tasks', 'Vista 51', v_my_tasks_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'limit_reached' THEN
    RAISE EXCEPTION 'The shared active quota remains 50 after deletion and replacement: %', v_result;
  END IF;

  v_preview := public.preview_restore_my_saved_view_p(
    'search', v_view_id, 'Próxima semana', v_updated_definition
  );
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_preview->'can_restore' IS DISTINCT FROM 'false'::jsonb
    OR NOT (v_preview->'reasons' ? 'name_conflict')
    OR NOT (v_preview->'reasons' ? 'active_limit') THEN
    RAISE EXCEPTION 'Restore preview must report current name and shared quota conflicts: %', v_preview;
  END IF;
  v_restore := public.restore_my_saved_view_p(
    'search', v_view_id, 3, 'Próxima semana', v_updated_definition
  );
  IF v_restore->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'Confirm must reject current restore constraints without mutation: %', v_restore;
  END IF;
  v_restore := public.restore_my_saved_view_p(
    'search', v_view_id, 3, 'Vista recuperada', v_updated_definition
  );
  IF v_restore->>'status' IS DISTINCT FROM 'conflict'
    OR v_restore->>'reason' IS DISTINCT FROM 'active_limit' THEN
    RAISE EXCEPTION 'A renamed restore must still recheck the shared active quota: %', v_restore;
  END IF;

  v_result := public.delete_my_saved_view_p(v_reference_view_id, 5);
  IF v_result->>'status' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'Deleting a second saved view should free one active slot: %', v_result;
  END IF;
  INSERT INTO pg_temp.issue35_view_refs(ref_name, view_id)
  VALUES ('expired', v_reference_view_id);
  v_preview := public.preview_restore_my_saved_view_p(
    'search', v_view_id, 'Vista recuperada', v_updated_definition
  );
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_preview->'can_restore' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'A renamed, valid restore should preview as confirmable: %', v_preview;
  END IF;
  v_restore := public.restore_my_saved_view_p(
    'search', v_view_id, 3, 'Vista recuperada', v_updated_definition
  );
  IF v_restore->>'status' IS DISTINCT FROM 'restored'
    OR v_restore->'view'->>'name' IS DISTINCT FROM 'Vista recuperada'
    OR (v_restore->'view'->>'version')::integer <> 4
    OR v_restore->'view'->'definition' IS DISTINCT FROM v_updated_definition
    OR v_restore->'view'->>'deleted_at' IS NOT NULL THEN
    RAISE EXCEPTION 'Confirmed recovery must restore the same identity and chosen definition: %', v_restore;
  END IF;
  INSERT INTO pg_temp.issue35_view_refs(ref_name, view_id)
  VALUES ('owned', v_view_id);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43500000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_view_id uuid;
  v_list jsonb;
  v_result jsonb;
  v_definition jsonb := jsonb_build_object(
    'query', '', 'scope', 'my_tasks', 'boardId', NULL,
    'includeCompleted', true, 'includeHistory', false,
    'filterBoardId', NULL, 'dueFilter', NULL,
    'priority', NULL, 'assigneeId', NULL, 'unassigned', false,
    'labels', '[]'::jsonb, 'order', 'due'
  );
BEGIN
  SELECT refs.view_id INTO STRICT v_view_id
  FROM pg_temp.issue35_view_refs AS refs WHERE refs.ref_name = 'owned';
  v_list := public.list_my_saved_views_p('search');
  IF v_list->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_list->'active_views') <> 0
    OR jsonb_array_length(v_list->'deleted_views') <> 0 THEN
    RAISE EXCEPTION 'A second account must not list another owner’s saved views: %', v_list;
  END IF;
  v_result := public.preview_restore_my_saved_view_p(
    'search', v_view_id, 'Vista ajena', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' OR v_result ? 'view' THEN
    RAISE EXCEPTION 'A preview must hide a view owned by another account: %', v_result;
  END IF;
  v_result := public.update_my_saved_view_p(
    v_view_id, 4, 'Vista ajena', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' OR v_result ? 'view' THEN
    RAISE EXCEPTION 'An update must hide a view owned by another account: %', v_result;
  END IF;
END;
$$;
COMMIT;

SELECT view_id AS issue35_expired_view_id
FROM pg_temp.issue35_view_refs WHERE ref_name = 'expired' \gset
UPDATE public.user_saved_views
SET deleted_at = clock_timestamp() - interval '7 days'
WHERE id = :'issue35_expired_view_id'::uuid;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43500000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_view_id uuid;
  v_definition jsonb := jsonb_build_object(
    'query', 'reunión', 'scope', 'all', 'boardId', NULL,
    'includeCompleted', true, 'includeHistory', true,
    'filterBoardId', NULL, 'dueFilter', 'next_7_days',
    'priority', 'high', 'assigneeId', NULL, 'unassigned', true,
    'labels', '[]'::jsonb, 'order', 'created'
  );
  v_result jsonb;
BEGIN
  SELECT refs.view_id INTO STRICT v_view_id
  FROM pg_temp.issue35_view_refs AS refs WHERE refs.ref_name = 'expired';
  v_result := public.restore_my_saved_view_p(
    'search', v_view_id, 6, 'Referencia activa', v_definition
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired' THEN
    RAISE EXCEPTION 'A view expires at the exact seven-day boundary: %', v_result;
  END IF;
END;
$$;
COMMIT;

SET ROLE service_role;
DO $$
DECLARE
  v_purged integer;
BEGIN
  v_purged := public.purge_expired_saved_views_p(1);
  IF v_purged <> 1 THEN
    RAISE EXCEPTION 'The service-role purge should physically remove the expired view: %', v_purged;
  END IF;
END;
$$;
RESET ROLE;
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.user_saved_views
    WHERE id = (SELECT view_id FROM pg_temp.issue35_view_refs WHERE ref_name = 'expired')
  ) THEN
    RAISE EXCEPTION 'Expired personal view data was retained after purge';
  END IF;
END;
$$;

\echo 'PASS: an owner saves and lists a complete context-scoped view definition'
