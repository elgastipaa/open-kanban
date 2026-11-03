\set ON_ERROR_STOP on

INSERT INTO public.application_access (email, state, is_admin)
VALUES
  ('issue33-search-owner@example.test', 'pending', false),
  ('issue33-search-outsider@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES
  ('43300000-0000-4000-8000-000000000001',
    'issue33-search-owner@example.test', now(), '{"provider":"google"}'),
  ('43300000-0000-4000-8000-000000000002',
    'issue33-search-outsider@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES
  ('53300000-0000-4000-8000-000000000001',
    '43300000-0000-4000-8000-000000000001', 'google', 'issue33-search-owner',
    '{"email":"issue33-search-owner@example.test","email_verified":true}'),
  ('53300000-0000-4000-8000-000000000002',
    '43300000-0000-4000-8000-000000000002', 'google', 'issue33-search-outsider',
    '{"email":"issue33-search-outsider@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = auth_user.id,
    google_subject = identity.provider_id,
    state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE access.email = auth_user.email
  AND access.email LIKE 'issue33-search-%@example.test';

CREATE TEMP TABLE issue33_search_refs (
  owner_slug text NOT NULL,
  owner_task_id uuid NOT NULL,
  outsider_slug text NOT NULL,
  outsider_task_id uuid NOT NULL
) ON COMMIT PRESERVE ROWS;
GRANT SELECT, INSERT ON issue33_search_refs TO authenticated;

CREATE TEMP TABLE issue33_history_refs (
  board_slug text NOT NULL,
  board_id uuid NOT NULL,
  series_id uuid NOT NULL,
  occurrence_id uuid NOT NULL,
  occurrence_on date NOT NULL,
  task_id uuid NOT NULL,
  comment_id uuid NOT NULL
) ON COMMIT PRESERVE ROWS;
GRANT SELECT, INSERT ON issue33_history_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43300000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_owner_board record;
  v_owner_column record;
  v_owner_task jsonb;
  v_second_task jsonb;
  v_third_task jsonb;
  v_comment jsonb;
  v_taller_comment jsonb;
  v_matching_comment jsonb;
  v_assigned_comment jsonb;
  v_comment_only jsonb;
  v_moderated_comment jsonb;
  v_invitation jsonb;
  v_label jsonb;
  v_second_label jsonb;
  v_label_assignment jsonb;
  v_second_label_assignment jsonb;
  v_assignee_result jsonb;
  v_due_result jsonb;
  v_owner_due_result jsonb;
  v_completion_result jsonb;
  v_next_cursor jsonb;
  v_series jsonb;
  v_history_page jsonb;
  v_index integer;
  v_outsider_board record;
  v_outsider_column record;
  v_outsider_task jsonb;
  v_result jsonb;
BEGIN
  SELECT * INTO v_owner_board
  FROM public.create_board_p(
    'Búsqueda privada A', 'America/Argentina/Buenos_Aires',
    '33300000-0000-4000-8000-000000000001'
  );
  SELECT * INTO v_owner_column FROM public.create_column_p(
    v_owner_board.slug, v_owner_board.id, 'Pendientes A', 0
  );
  v_label := public.create_board_label_p(
    v_owner_board.slug, 'Contexto rojo', 'red'
  );
  v_owner_task := public.create_task_p(
    '33300000-0000-4000-8000-000000000002', v_owner_board.id,
    v_owner_column.id, 'Reunión de Peña', 'Preparar propuesta', 'medium'
  );
  v_second_task := public.create_task_p(
    '33300000-0000-4000-8000-000000000007', v_owner_board.id,
    v_owner_column.id, 'Reunión segunda tarea', 'Recordatorio asignado', 'high'
  );
  v_third_task := public.create_task_p(
    '33300000-0000-4000-8000-000000000008', v_owner_board.id,
    v_owner_column.id, 'Trabajo breve', NULL, 'low'
  );
  v_second_label := public.create_board_label_p(
    v_owner_board.slug, 'Contexto azul', 'blue'
  );
  v_comment := public.create_task_comment_p(
    '33300000-0000-4000-8000-000000000005', v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid, 'Comentario privado de taller'
  );
  v_taller_comment := v_comment;
  v_matching_comment := public.create_task_comment_p(
    '33300000-0000-4000-8000-000000000006', v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid, 'Reunión de Peña con comentarios'
  );
  v_assigned_comment := public.create_task_comment_p(
    '33300000-0000-4000-8000-000000000009', v_owner_board.slug,
    (v_second_task->>'task_id')::uuid, 'Comentario asignado a consulta'
  );
  v_comment_only := public.create_task_comment_p(
    '33300000-0000-4000-8000-000000000010', v_owner_board.slug,
    (v_third_task->>'task_id')::uuid, 'Reunión por comentario'
  );
  v_invitation := public.create_direct_board_invitation_p(
    v_owner_board.slug, 'issue33-search-outsider@example.test'
  );
  IF v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Could not prepare a comment-author membership: %',
      v_invitation;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '43300000-0000-4000-8000-000000000002', true
  );
  v_result := public.accept_direct_board_invitation_p(
    (v_invitation->>'id')::uuid,
    '33300000-0000-4000-8000-000000000015'
  );
  IF v_result->>'status' IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'Could not add a synthetic comment author: %', v_result;
  END IF;
  v_moderated_comment := public.create_task_comment_p(
    '33300000-0000-4000-8000-000000000014', v_owner_board.slug,
    (v_third_task->>'task_id')::uuid, 'Marcador moderado qzxconfidencial'
  );
  IF v_moderated_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create a synthetic collaborator comment: %',
      v_moderated_comment;
  END IF;
  PERFORM pg_catalog.set_config(
    'request.jwt.claim.sub', '43300000-0000-4000-8000-000000000001', true
  );
  v_result := public.delete_task_comment_p(
    '33300000-0000-4000-8000-000000000013', v_owner_board.slug,
    (v_moderated_comment->>'comment_id')::uuid
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->>'deletion_cause' IS DISTINCT FROM 'moderation' THEN
    RAISE EXCEPTION 'Could not prepare a moderated-comment search fixture: %',
      v_result;
  END IF;
  FOR v_index IN 1..25 LOOP
    v_comment := public.create_task_comment_p(
      ('33300000-0000-4000-8000-' ||
        pg_catalog.lpad((100 + v_index)::text, 12, '0'))::uuid,
      v_owner_board.slug,
      (v_owner_task->>'task_id')::uuid,
      pg_catalog.format('Búsqueda privada comentario %s', v_index)
    );
    IF v_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Could not prepare a repetitive comment suggestion fixture: %',
        v_comment;
    END IF;
  END LOOP;
  v_label_assignment := public.set_task_labels_p(
    v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid,
    ARRAY[]::uuid[],
    ARRAY[(v_label->'label'->>'id')::uuid]
  );
  IF v_label_assignment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare a task label filter fixture: %',
      v_label_assignment;
  END IF;
  v_second_label_assignment := public.set_task_labels_p(
    v_owner_board.slug,
    (v_second_task->>'task_id')::uuid,
    ARRAY[]::uuid[],
    ARRAY[(v_second_label->'label'->>'id')::uuid]
  );
  IF v_second_label_assignment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the second label filter fixture: %',
      v_second_label_assignment;
  END IF;
  v_assignee_result := public.set_task_assignee_p(
    '33300000-0000-4000-8000-000000000011', v_owner_board.slug,
    (v_second_task->>'task_id')::uuid,
    '43300000-0000-4000-8000-000000000001', 1
  );
  IF v_assignee_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the assignee filter fixture: %',
      v_assignee_result;
  END IF;
  v_due_result := public.edit_task_fields_p(
    '33300000-0000-4000-8000-000000000012', v_owner_board.slug,
    (v_second_task->>'task_id')::uuid,
    pg_catalog.jsonb_build_object('due_on', public.board_calendar_day(
      'America/Argentina/Buenos_Aires', statement_timestamp()
    )),
    '{"due_on":1}'::jsonb
  );
  IF v_due_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the due filter fixture: %', v_due_result;
  END IF;
  v_owner_due_result := public.edit_task_fields_p(
    '33300000-0000-4000-8000-000000000014', v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid,
    pg_catalog.jsonb_build_object('due_on', public.board_calendar_day(
      'America/Argentina/Buenos_Aires', statement_timestamp()
    ) - 1),
    '{"due_on":1}'::jsonb
  );
  IF v_owner_due_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the overdue task filter fixture: %',
      v_owner_due_result;
  END IF;
  v_completion_result := public.set_task_completion_p(
    '33300000-0000-4000-8000-000000000013', v_owner_board.slug,
    (v_second_task->>'task_id')::uuid, true, 1
  );
  IF v_completion_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the completed filter fixture: %',
      v_completion_result;
  END IF;

  PERFORM set_config('request.jwt.claim.sub',
    '43300000-0000-4000-8000-000000000002', true);
  SELECT * INTO v_outsider_board
  FROM public.create_board_p(
    'Búsqueda privada B', 'America/Argentina/Buenos_Aires',
    '33300000-0000-4000-8000-000000000003'
  );
  SELECT * INTO v_outsider_column FROM public.create_column_p(
    v_outsider_board.slug, v_outsider_board.id, 'Pendientes B', 0
  );
  v_outsider_task := public.create_task_p(
    '33300000-0000-4000-8000-000000000004', v_outsider_board.id,
    v_outsider_column.id, 'Secreto fuera del equipo', 'Texto ajeno', 'high'
  );

  PERFORM set_config('request.jwt.claim.sub',
    '43300000-0000-4000-8000-000000000001', true);
  INSERT INTO issue33_search_refs VALUES (
    v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid,
    v_outsider_board.slug,
    (v_outsider_task->>'task_id')::uuid
  );

  v_result := public.search_unified_p('Reunión de Peña');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'task'
        AND row.value->>'field' = 'title'
        AND row.value->>'title' = 'Reunión de Peña'
        AND row.value->>'board_name' = 'Búsqueda privada A'
        AND row.value->>'task_id' = (v_owner_task->>'task_id')
    ) THEN
    RAISE EXCEPTION 'Authorized exact task search result was missing or incomplete: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('Secreto fuera del equipo');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(v_result->'results') <> 0
    OR v_result::text LIKE '%Secreto fuera del equipo%'
    OR v_result::text LIKE '%' || v_outsider_board.id::text || '%' THEN
    RAISE EXCEPTION 'Search disclosed an inaccessible board/task: %', v_result;
  END IF;

  v_result := public.search_unified_p('reunion');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'task_id' = (v_owner_task->>'task_id')
        AND row.value->>'field' = 'title'
        AND row.value->>'relevance' = 'prefix'
    ) THEN
    RAISE EXCEPTION 'Accentless prefix search did not match the authorized title: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('pena');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'task_id' = (v_owner_task->>'task_id')
        AND row.value->>'field' = 'title'
        AND row.value->>'relevance' = 'word'
    ) THEN
    RAISE EXCEPTION 'The ñ/n equivalence did not match an incomplete word: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('reunion pena');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'task_id' = (v_owner_task->>'task_id')
        AND row.value->>'relevance' = 'word'
    ) THEN
    RAISE EXCEPTION 'Multiple incomplete tokens did not match the task title: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('propuesta');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'task_id' = (v_owner_task->>'task_id')
        AND row.value->>'field' = 'description'
    ) THEN
    RAISE EXCEPTION 'Accentless description search did not report its matched field: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('taller');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'comment'
        AND row.value->>'task_id' = (v_owner_task->>'task_id')
        AND row.value->>'comment_id' = v_taller_comment->>'comment_id'
        AND row.value->>'field' = 'comment'
        AND row.value->>'excerpt' = 'Comentario privado de taller'
    ) THEN
    RAISE EXCEPTION 'Authorized comment search did not return its precise comment and parent: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('qzxconfidencial');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'comment'
        AND row.value->>'comment_id' = v_moderated_comment->>'comment_id'
    ) THEN
    RAISE EXCEPTION 'Moderated comment text appeared in search results: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('privada');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'board'
        AND row.value->>'board_id' = v_owner_board.id::text
        AND row.value->>'board_slug' = v_owner_board.slug
        AND row.value->>'board_name' = 'Búsqueda privada A'
    ) THEN
    RAISE EXCEPTION 'Authorized board suggestion did not return its safe destination: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('contexto');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'label'
        AND row.value->>'label_id' = v_label->'label'->>'id'
        AND row.value->>'board_id' = v_owner_board.id::text
        AND row.value->>'label_name' = 'Contexto rojo'
    ) THEN
    RAISE EXCEPTION 'Authorized label filter suggestion lost its ID/board identity: %',
      v_result;
  END IF;

  v_result := public.search_unified_p(
    'reunion',
    p_label_filters => pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'label_id', v_label->'label'->>'id',
      'board_id', v_owner_board.id
    ))
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'task'
        AND row.value->>'task_id' = (v_owner_task->>'task_id')
    ) THEN
    RAISE EXCEPTION 'A board-scoped label filter did not retain the matching task: %',
      v_result;
  END IF;

  v_result := public.search_unified_p(
    'reunion',
    p_label_filters => pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'label_id', v_label->'label'->>'id',
      'board_id', v_outsider_board.id
    ))
  );
  IF v_result->>'status' IS DISTINCT FROM 'invalid_filter'
    OR pg_catalog.jsonb_array_length(v_result->'results') <> 0 THEN
    RAISE EXCEPTION 'A label ID paired with another board was not blocked: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('reunion', p_mode => 'tasks');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR (
      SELECT count(*)
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'task'
        AND row.value->>'task_id' = (v_owner_task->>'task_id')
    ) <> 1
    OR EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' <> 'task'
    ) THEN
    RAISE EXCEPTION 'The task list did not deduplicate title/comment matches: %',
      v_result;
  END IF;

  v_result := public.search_unified_p(
    'asignado', p_scope => 'my_tasks', p_include_completed => true
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'comment'
        AND row.value->>'task_id' = (v_second_task->>'task_id')
        AND row.value->>'comment_id' = v_assigned_comment->>'comment_id'
    ) THEN
    RAISE EXCEPTION 'My Tasks did not include an assigned task comment: %', v_result;
  END IF;

  v_result := public.search_unified_p('taller', p_scope => 'my_tasks');
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(v_result->'results') <> 0 THEN
    RAISE EXCEPTION 'My Tasks included a comment whose parent was unassigned: %',
      v_result;
  END IF;

  v_result := public.search_unified_p(
    'asignado', p_priority => 'low', p_include_completed => true
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(v_result->'results') <> 0 THEN
    RAISE EXCEPTION 'A parent priority filter did not exclude a comment result: %',
      v_result;
  END IF;

  v_result := public.search_unified_p(
    'asignado', p_due_filter => 'today', p_include_completed => true
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'comment'
        AND row.value->>'task_id' = (v_second_task->>'task_id')
    ) THEN
    RAISE EXCEPTION 'Board-local today filter did not reach the parent comment: %',
      v_result;
  END IF;

  v_result := public.search_unified_p('asignado');
  IF pg_catalog.jsonb_array_length(v_result->'results') <> 0 THEN
    RAISE EXCEPTION 'Completed task comments appeared without explicit inclusion: %',
      v_result;
  END IF;
  v_result := public.search_unified_p('asignado', p_include_completed => true);
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
    WHERE row.value->>'kind' = 'comment'
      AND row.value->>'task_id' = (v_second_task->>'task_id')
  ) THEN
    RAISE EXCEPTION 'Explicit completed inclusion did not restore the parent comment: %',
      v_result;
  END IF;

  v_result := public.search_unified_p(
    'reunion', p_include_completed => true,
    p_label_filters => pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'label_id', v_label->'label'->>'id', 'board_id', v_owner_board.id
      ),
      pg_catalog.jsonb_build_object(
        'label_id', v_second_label->'label'->>'id', 'board_id', v_owner_board.id
      )
    )
  );
  IF (
      SELECT count(DISTINCT row.value->>'task_id')
      FROM pg_catalog.jsonb_array_elements(v_result->'results') AS row(value)
      WHERE row.value->>'kind' = 'task'
    ) <> 2 THEN
    RAISE EXCEPTION 'Selected labels did not combine by OR while preserving task identity: %',
      v_result;
  END IF;

  v_result := public.search_unified_p(
    'reunion', p_mode => 'tasks', p_order => 'due',
    p_include_completed => true, p_limit => 1
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR v_result->>'has_more' IS DISTINCT FROM 'true'
    OR v_result->'next_cursor' IS NULL
    OR NOT (v_result->'next_cursor' ? 'due_on')
    OR v_result->'results'->0->>'task_id' IS DISTINCT FROM (v_owner_task->>'task_id') THEN
    RAISE EXCEPTION 'The first task-list page or its created-order cursor was invalid: %',
      v_result;
  END IF;
  v_next_cursor := v_result->'next_cursor';

  v_result := public.search_unified_p(
    'reunion', p_mode => 'tasks', p_order => 'due',
    p_include_completed => true, p_limit => 1, p_cursor => v_next_cursor
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR v_result->>'has_more' IS DISTINCT FROM 'true'
    OR v_result->'results'->0->>'task_id' IS DISTINCT FROM (v_second_task->>'task_id') THEN
    RAISE EXCEPTION 'The second task-list page did not advance without duplication: %',
      v_result;
  END IF;
  v_next_cursor := v_result->'next_cursor';
  v_result := public.search_unified_p(
    'reunion', p_mode => 'tasks', p_order => 'due',
    p_include_completed => true, p_limit => 1, p_cursor => v_next_cursor
  );
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR v_result->>'has_more' IS DISTINCT FROM 'false'
    OR v_result->'results'->0->>'task_id' IS DISTINCT FROM (v_third_task->>'task_id') THEN
    RAISE EXCEPTION 'Comment-only task did not appear on the final deduplicated page: %',
      v_result;
  END IF;

  v_series := public.create_repetition_with_advance_p(
    '33300000-0000-4000-8000-000000000015', v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid,
    public.board_calendar_day(v_owner_board.time_zone, statement_timestamp()) - 1,
    NULL, 2,
    (v_owner_due_result->'task'->'field_versions'->>'due_on')::bigint,
    false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_owner_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the history search fixture series: %', v_series;
  END IF;
  v_completion_result := public.set_task_completion_p(
    '33300000-0000-4000-8000-000000000018', v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid, true, 1
  );
  IF v_completion_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not mark the history fixture occurrence complete: %',
      v_completion_result;
  END IF;
  v_comment := public.create_task_comment_p(
    '33300000-0000-4000-8000-000000000016', v_owner_board.slug,
    (v_owner_task->>'task_id')::uuid, 'Frase solo historial de reemplazo'
  );
  IF v_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the history search comment: %', v_comment;
  END IF;
  v_history_page := public.get_repetition_history_page_p(
    (v_series->>'series_id')::uuid, NULL, NULL, 20
  );
  IF v_history_page->>'status' IS DISTINCT FROM 'available' THEN
    RAISE EXCEPTION 'History fixture could not read its current slot: %', v_history_page;
  END IF;
  INSERT INTO issue33_history_refs
  SELECT v_owner_board.slug, v_owner_board.id,
    (v_series->>'series_id')::uuid,
    (row.value->>'id')::uuid,
    (row.value->>'occurrence_on')::date,
    (v_owner_task->>'task_id')::uuid,
    (v_comment->>'comment_id')::uuid
  FROM pg_catalog.jsonb_array_elements(v_history_page->'occurrences') AS row(value)
  WHERE row.value->>'task_id' = v_owner_task->>'task_id'
    AND row.value->>'state' = 'current';
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.run_daily_repetition_jobs_p(20);
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',
  '43300000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  refs issue33_history_refs%ROWTYPE;
  v_default jsonb;
  v_history jsonb;
  v_title_default jsonb;
  v_title_history jsonb;
  v_title_completed_no_history jsonb;
  v_title_history_completed jsonb;
  v_task_list_default jsonb;
  v_task_list_history jsonb;
  v_task_list_comment_history jsonb;
  v_current_completed_history_off jsonb;
  v_current_completed_history_on jsonb;
BEGIN
  SELECT * INTO refs FROM issue33_history_refs;
  IF refs.occurrence_id IS NULL THEN
    RAISE EXCEPTION 'History fixture did not capture the initial current occurrence.';
  END IF;

  v_default := public.search_unified_p('historial de reemplazo');
  IF v_default->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(v_default->'results') <> 0 THEN
    RAISE EXCEPTION 'Replaced occurrence comments appeared with history off: %',
      v_default;
  END IF;
  v_history := public.search_unified_p(
    'historial de reemplazo', p_include_history => true
  );
  IF v_history->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(v_history->'results') AS row(value)
      WHERE row.value->>'kind' = 'comment'
        AND row.value->>'comment_id' = refs.comment_id::text
        AND row.value->>'occurrence_id' = refs.occurrence_id::text
        AND row.value->>'series_id' = refs.series_id::text
        AND row.value->>'occurrence_on' = refs.occurrence_on::text
        AND row.value->>'occurrence_state' = 'replaced'
        AND row.value->>'is_historical' = 'true'
        AND row.value->>'is_completed' = 'true'
    ) THEN
    RAISE EXCEPTION 'History search did not return the completed replaced comment: %',
      v_history;
  END IF;

  v_title_default := public.search_unified_p('peña');
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_title_default->'results') AS row(value)
    WHERE row.value->>'task_id' = refs.task_id::text
  ) THEN
    RAISE EXCEPTION 'The replaced task itself was exposed without history: %',
      v_title_default;
  END IF;
  v_title_history := public.search_unified_p('peña', p_include_history => true);
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_title_history->'results') AS row(value)
    WHERE row.value->>'kind' = 'task'
      AND row.value->>'task_id' = refs.task_id::text
      AND row.value->>'occurrence_id' = refs.occurrence_id::text
      AND row.value->>'occurrence_state' = 'replaced'
      AND row.value->>'is_historical' = 'true'
      AND row.value->>'is_completed' = 'true'
  ) THEN
    RAISE EXCEPTION 'History title search did not return the completed replaced occurrence: %',
      v_title_history;
  END IF;
  v_title_completed_no_history := public.search_unified_p(
    'peña', p_include_completed => true
  );
  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(
      v_title_completed_no_history->'results'
    ) AS row(value)
    WHERE row.value->>'task_id' = refs.task_id::text
      AND row.value->>'occurrence_state' = 'replaced'
  ) THEN
    RAISE EXCEPTION 'Completed inclusion enabled historical results without history: %',
      v_title_completed_no_history;
  END IF;
  v_title_history_completed := public.search_unified_p(
    'peña', p_include_history => true, p_include_completed => true
  );
  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_array_elements(
      v_title_history_completed->'results'
    ) AS row(value)
    WHERE row.value->>'task_id' = refs.task_id::text
      AND row.value->>'occurrence_id' = refs.occurrence_id::text
      AND row.value->>'occurrence_state' = 'replaced'
      AND row.value->>'is_historical' = 'true'
      AND row.value->>'is_completed' = 'true'
  ) THEN
    RAISE EXCEPTION 'History and completed enabled did not include the replaced occurrence: %',
      v_title_history_completed;
  END IF;

  v_task_list_default := public.search_unified_p(
    'peña', p_mode => 'tasks'
  );
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_task_list_default->'results') AS row(value)
    WHERE row.value->>'task_id' = refs.task_id::text
  ) THEN
    RAISE EXCEPTION 'The task list exposed replaced history while the option was off: %',
      v_task_list_default;
  END IF;
  v_task_list_history := public.search_unified_p(
    'peña', p_mode => 'tasks', p_include_history => true
  );
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_task_list_history->'results') AS row(value)
    WHERE row.value->>'task_id' = refs.task_id::text
      AND row.value->>'occurrence_id' = refs.occurrence_id::text
      AND row.value->>'occurrence_state' = 'replaced'
      AND row.value->>'is_historical' = 'true'
      AND row.value->>'is_completed' = 'true'
  ) THEN
    RAISE EXCEPTION 'The task list omitted its completed replaced occurrence: %',
      v_task_list_history;
  END IF;

  v_task_list_comment_history := public.search_unified_p(
    'historial de reemplazo', p_mode => 'tasks', p_include_history => true
  );
  IF v_task_list_comment_history->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(
        v_task_list_comment_history->'results'
      ) AS row(value)
      WHERE row.value->>'task_id' = refs.task_id::text
        AND row.value->>'occurrence_id' = refs.occurrence_id::text
        AND row.value->>'occurrence_state' = 'replaced'
        AND row.value->>'is_historical' = 'true'
        AND row.value->>'is_completed' = 'true'
    ) THEN
    RAISE EXCEPTION 'Task list did not include a completed replaced comment match: %',
      v_task_list_comment_history;
  END IF;

  v_current_completed_history_off := public.search_unified_p(
    'asignado', p_include_history => true
  );
  IF v_current_completed_history_off->>'status' IS DISTINCT FROM 'available'
    OR pg_catalog.jsonb_array_length(
      v_current_completed_history_off->'results'
    ) <> 0 THEN
    RAISE EXCEPTION 'History option bypassed completed filtering for a current task: %',
      v_current_completed_history_off;
  END IF;
  v_current_completed_history_on := public.search_unified_p(
    'asignado', p_include_history => true, p_include_completed => true
  );
  IF v_current_completed_history_on->>'status' IS DISTINCT FROM 'available'
    OR NOT EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(
        v_current_completed_history_on->'results'
      ) AS row(value)
      WHERE row.value->>'kind' = 'task'
        AND row.value->>'is_completed' = 'true'
        AND coalesce(row.value->>'is_historical', 'false') = 'false'
    ) THEN
    RAISE EXCEPTION 'Completed filter did not independently restore a current completed task: %',
      v_current_completed_history_on;
  END IF;
END;
$$;
COMMIT;

RESET ROLE;
DO $$
BEGIN
  RAISE NOTICE 'PASS: unified search preserves access, task identity, filters, and explicit history.';
END;
$$;
