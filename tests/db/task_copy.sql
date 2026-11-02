\set ON_ERROR_STOP on

INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue32@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43200000-0000-4000-8000-000000000002',
  'issue32@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53200000-0000-4000-8000-000000000002',
  '43200000-0000-4000-8000-000000000002', 'google', 'issue32-google-subject',
  '{"email":"issue32@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '43200000-0000-4000-8000-000000000002',
    google_subject = 'issue32-google-subject', state = 'active'
WHERE email = 'issue32@example.test';
INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue32-outsider@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43200000-0000-4000-8000-000000000003',
  'issue32-outsider@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53200000-0000-4000-8000-000000000003',
  '43200000-0000-4000-8000-000000000003', 'google', 'issue32-outsider-subject',
  '{"email":"issue32-outsider@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '43200000-0000-4000-8000-000000000003',
    google_subject = 'issue32-outsider-subject', state = 'active'
WHERE email = 'issue32-outsider@example.test';
INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue32-collaborator@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43200000-0000-4000-8000-000000000004',
  'issue32-collaborator@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53200000-0000-4000-8000-000000000004',
  '43200000-0000-4000-8000-000000000004', 'google', 'issue32-collaborator-subject',
  '{"email":"issue32-collaborator@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '43200000-0000-4000-8000-000000000004',
    google_subject = 'issue32-collaborator-subject', state = 'active'
WHERE email = 'issue32-collaborator@example.test';

CREATE TEMP TABLE issue32_copy_access_refs (
  board_slug text NOT NULL,
  source_task_id uuid NOT NULL,
  target_column_id uuid NOT NULL,
  source_hash text NOT NULL
) ON COMMIT PRESERVE ROWS;
GRANT SELECT, INSERT ON issue32_copy_access_refs TO authenticated;

-- A current pending task is a valid E04 source; preview is read-only.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43200000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_created jsonb;
  v_label jsonb;
  v_second_label jsonb;
  v_more_label jsonb;
  v_deleted_label jsonb;
  v_set_labels jsonb;
  v_delete_label jsonb;
  v_comment jsonb;
  v_occurrence_label jsonb;
  v_template_label jsonb;
  v_assignee_result jsonb;
  v_step jsonb;
  v_source_edit jsonb;
  v_target_task jsonb;
  v_occurrence_task jsonb;
  v_occurrence_series jsonb;
  v_occurrence_status jsonb;
  v_template_change jsonb;
  v_occurrence_preview_before jsonb;
  v_occurrence_preview_after jsonb;
  v_occurrence_copy jsonb;
  v_occurrence_copy_labels jsonb;
  v_occurrence_source_labels jsonb;
  v_other_board record;
  v_other_column record;
  v_other_task jsonb;
  v_trash_task jsonb;
  v_trash_result jsonb;
  v_birthday jsonb;
  v_denied_preview jsonb;
  v_denied_copy jsonb;
  v_expected_template_ids uuid[];
  v_label_id uuid;
  v_second_label_id uuid;
  v_deleted_label_id uuid;
  v_occurrence_label_id uuid;
  v_template_label_id uuid;
  v_more_label_ids uuid[] := ARRAY[]::uuid[];
  v_copy_label_ids uuid[];
  v_index integer;
  v_other_task_id uuid;
  v_trash_task_id uuid;
  v_birthday_id uuid;
  v_preview jsonb;
  v_changed jsonb;
  v_copy jsonb;
  v_replay jsonb;
  v_copy_labels jsonb;
  v_source_labels jsonb;
  v_copy_repetition jsonb;
  v_copy_comments jsonb;
  v_source record;
  v_destination record;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Issue #32 pending copy', 'America/Argentina/Buenos_Aires',
    '32000000-0000-4000-8000-000000000010'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Pendientes', 0
  );
  SELECT * INTO v_destination FROM public.create_column_p(
    v_board.slug, v_board.id, 'Destino', 1
  );
  v_target_task := public.create_task_p(
    '32000000-0000-4000-8000-000000000012', v_board.id,
    v_destination.id, 'Primera en destino', NULL, 'medium'
  );
  v_created := public.create_task_p(
    '32000000-0000-4000-8000-000000000011', v_board.id,
    v_column.id, 'Fuente pendiente', 'Descripción fuente', 'high'
  );
  v_step := public.mutate_task_checklist_step_p(
    '32000000-0000-4000-8000-000000000013', v_board.slug,
    (v_created->'task'->>'id')::uuid,
    '{"action":"add","text":"Paso sin marcar"}'::jsonb
  );
  v_source_edit := public.edit_task_fields_p(
    '32000000-0000-4000-8000-000000000014', v_board.slug,
    (v_created->'task'->>'id')::uuid,
    pg_catalog.jsonb_build_object('due_on', (current_date - 1)::text),
    '{"due_on":1}'::jsonb
  );
  v_assignee_result := public.set_task_assignee_p(
    '32000000-0000-4000-8000-000000000040', v_board.slug,
    (v_created->'task'->>'id')::uuid,
    '43200000-0000-4000-8000-000000000002',
    (v_created->'task'->>'assignee_version')::bigint
  );
  IF v_assignee_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic source assignment setup failed: %', v_assignee_result;
  END IF;
  v_label := public.create_board_label_p(v_board.slug, 'Inicio', 'blue');
  v_deleted_label := public.create_board_label_p(
    v_board.slug, 'Ya retirada', 'gray'
  );
  IF v_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic source label creation failed: %', v_label;
  END IF;
  v_label_id := (v_label->'label'->>'id')::uuid;
  v_deleted_label_id := (v_deleted_label->'label'->>'id')::uuid;
  v_set_labels := public.set_task_labels_p(
    v_board.slug, (v_created->'task'->>'id')::uuid,
    ARRAY[]::uuid[], ARRAY[v_label_id, v_deleted_label_id]::uuid[]
  );
  IF v_set_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic source label assignment failed: %', v_set_labels;
  END IF;
  v_delete_label := public.delete_board_label_p(
    v_board.slug, v_deleted_label_id, 1
  );
  IF v_delete_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic source label deletion failed: %', v_delete_label;
  END IF;
  v_preview := public.preview_task_copy_p(
    v_board.slug, (v_created->'task'->>'id')::uuid
  );
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'title' IS DISTINCT FROM 'Fuente pendiente'
    OR v_preview->>'description' IS DISTINCT FROM 'Descripción fuente'
    OR v_preview->>'priority' IS DISTINCT FROM 'high'
    OR v_preview->'labels' IS NULL
    OR jsonb_array_length(v_preview->'labels') <> 1
    OR v_preview->'labels'->0->>'id' IS DISTINCT FROM v_label_id::text
    OR v_preview->>'source_hash' IS NULL THEN
    RAISE EXCEPTION 'A current pending task must have a same-board copy preview: %',
      v_preview;
  END IF;
  v_second_label := public.create_board_label_p(v_board.slug, 'Seguimiento', 'teal');
  IF v_second_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic second active label creation failed: %', v_second_label;
  END IF;
  v_second_label_id := (v_second_label->'label'->>'id')::uuid;
  FOR v_index IN 1..8 LOOP
    v_more_label := public.create_board_label_p(
      v_board.slug, 'Etiqueta extra ' || v_index, 'blue'
    );
    IF v_more_label->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Synthetic maximum-count label creation failed: %', v_more_label;
    END IF;
    v_more_label_ids := pg_catalog.array_append(
      v_more_label_ids, (v_more_label->'label'->>'id')::uuid
    );
  END LOOP;
  v_copy_label_ids := ARRAY[v_label_id, v_second_label_id]::uuid[] || v_more_label_ids;
  v_set_labels := public.set_task_labels_p(
    v_board.slug, (v_created->'task'->>'id')::uuid,
    ARRAY[v_label_id]::uuid[], v_copy_label_ids
  );
  IF v_set_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic source label change failed: %', v_set_labels;
  END IF;
  v_changed := public.copy_task_p(
    '32000000-0000-4000-8000-000000000015', v_board.slug,
    (v_created->'task'->>'id')::uuid, v_destination.id,
    'Título elegido', v_preview->>'source_hash'
  );
  IF v_changed->>'status' IS DISTINCT FROM 'source_changed'
    OR v_changed->>'title' IS DISTINCT FROM 'Título elegido'
    OR (v_changed->>'target_column_id')::uuid IS DISTINCT FROM v_destination.id
    OR jsonb_array_length(v_changed->'labels') <> 10
    OR EXISTS (SELECT 1 FROM public.tasks WHERE title = 'Título elegido') THEN
    RAISE EXCEPTION 'Active label changes must refresh the preview without creating a copy: %',
      v_changed;
  END IF;
  v_comment := public.create_task_comment_p(
    '32000000-0000-4000-8000-000000000016', v_board.slug,
    (v_created->'task'->>'id')::uuid, 'Comentario posterior no copiable', '[]'::jsonb
  );
  IF v_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic post-preview comment creation failed: %', v_comment;
  END IF;
  v_copy := public.copy_task_p(
    '32000000-0000-4000-8000-000000000015', v_board.slug,
    (v_created->'task'->>'id')::uuid, v_destination.id,
    'Título elegido', v_changed->>'source_hash'
  );
  v_copy_labels := public.get_task_labels_p(
    v_board.slug, (v_copy->'task'->>'id')::uuid
  );
  v_copy_repetition := public.get_repetition_p(
    v_board.slug, (v_copy->'task'->>'id')::uuid
  );
  v_copy_comments := public.get_task_comments_p(
    v_board.slug, (v_copy->'task'->>'id')::uuid, 20, NULL, NULL, NULL
  );
  IF v_copy->>'status' IS DISTINCT FROM 'confirmed'
    OR v_copy->'task'->>'title' IS DISTINCT FROM 'Título elegido'
    OR v_copy->'task'->>'description' IS DISTINCT FROM 'Descripción fuente'
    OR v_copy->'task'->>'priority' IS DISTINCT FROM 'high'
    OR v_copy->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_copy->'task'->>'due_on' IS NOT NULL
    OR v_copy->'task'->>'assignee_id' IS NOT NULL
    OR (v_copy->'task'->>'column_id')::uuid IS DISTINCT FROM v_destination.id
    OR (v_copy->'task'->>'position')::integer
      <= (v_target_task->'task'->>'position')::integer
    OR jsonb_array_length(v_copy->'task'->'steps') <> 1
    OR v_copy->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Paso sin marcar'
    OR v_copy->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'false'
    OR v_copy->'task'->'steps'->0->>'id'
      IS NOT DISTINCT FROM v_step->'task'->'steps'->0->>'id'
    OR v_copy_labels->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_copy_labels->'labels') <> 10
    OR EXISTS (
      SELECT 1 FROM unnest(v_copy_label_ids) AS expected(label_id)
      WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_copy_labels->'labels') AS label(item)
        WHERE label.item->>'id' = expected.label_id::text
      )
    )
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_copy_labels->'labels') AS label(item)
      WHERE label.item->>'id' = v_label_id::text
    )
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_copy_labels->'labels') AS label(item)
      WHERE label.item->>'id' = v_second_label_id::text
    )
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_copy_labels->'labels') AS label(item)
      WHERE label.item->>'id' = v_deleted_label_id::text
    )
    OR v_copy_repetition->>'status' IS DISTINCT FROM 'not_repeating'
    OR v_copy_comments->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_copy_comments->'comments') <> 0 THEN
    RAISE EXCEPTION 'E04 copy must create a pending same-board identity with only allowed fields: % / % / % / %',
      v_copy, v_copy_labels, v_copy_repetition, v_copy_comments;
  END IF;
  v_replay := public.copy_task_p(
    '32000000-0000-4000-8000-000000000015', v_board.slug,
    (v_created->'task'->>'id')::uuid, v_destination.id,
    'Título elegido', v_changed->>'source_hash'
  );
  IF v_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replay->'task'->>'id' IS DISTINCT FROM v_copy->'task'->>'id' THEN
    RAISE EXCEPTION 'Retrying the same copy operation must not create a duplicate: % / %',
      v_copy, v_replay;
  END IF;
  SELECT task.* INTO v_source
  FROM public.tasks AS task
  WHERE task.id = (v_created->'task'->>'id')::uuid;
  v_source_labels := public.get_task_labels_p(v_board.slug, v_source.id);
  IF v_source.title IS DISTINCT FROM 'Fuente pendiente'
    OR v_source.description IS DISTINCT FROM 'Descripción fuente'
    OR v_source.due_on IS DISTINCT FROM current_date - 1
    OR v_source.assignee_id IS DISTINCT FROM
      '43200000-0000-4000-8000-000000000002'::uuid
    OR v_source.is_completed
    OR jsonb_array_length(v_source_labels->'labels') <> 10
    OR EXISTS (
      SELECT 1 FROM unnest(v_copy_label_ids) AS expected(label_id)
      WHERE NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_source_labels->'labels') AS label(item)
        WHERE label.item->>'id' = expected.label_id::text
      )
    )
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_source_labels->'labels') AS label(item)
      WHERE label.item->>'id' = v_label_id::text
    )
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_source_labels->'labels') AS label(item)
      WHERE label.item->>'id' = v_second_label_id::text
    ) THEN
    RAISE EXCEPTION 'Copy must preserve the source and its active labels: % / %',
      v_source, v_source_labels;
  END IF;

  -- A task copy never crosses its source board, including the destination.
  SELECT * INTO v_other_board FROM public.create_board_p(
    'Issue #32 other board', 'America/Argentina/Buenos_Aires',
    '32000000-0000-4000-8000-000000000030'
  );
  SELECT * INTO v_other_column FROM public.create_column_p(
    v_other_board.slug, v_other_board.id, 'Otra columna', 0
  );
  v_other_task := public.create_task_p(
    '32000000-0000-4000-8000-000000000031', v_other_board.id,
    v_other_column.id, 'Origen de otro tablero', NULL, 'medium'
  );
  v_other_task_id := (v_other_task->'task'->>'id')::uuid;
  v_denied_preview := public.preview_task_copy_p(v_other_board.slug, v_source.id);
  IF v_denied_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_denied_preview::text LIKE '%' || v_source.id::text || '%'
    OR v_denied_preview::text LIKE '%Fuente pendiente%' THEN
    RAISE EXCEPTION 'A source task from another board must stay unavailable: %',
      v_denied_preview;
  END IF;
  v_denied_preview := public.preview_task_copy_p(v_board.slug, v_other_task_id);
  IF v_denied_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_denied_preview::text LIKE '%' || v_other_task_id::text || '%' THEN
    RAISE EXCEPTION 'A foreign task ID must not disclose content through preview: %',
      v_denied_preview;
  END IF;
  v_denied_copy := public.copy_task_p(
    '32000000-0000-4000-8000-000000000032', v_board.slug,
    v_source.id, v_other_column.id, 'No cruzar tableros', v_changed->>'source_hash'
  );
  IF v_denied_copy->>'status' IS DISTINCT FROM 'unavailable'
    OR EXISTS (SELECT 1 FROM public.tasks WHERE title = 'No cruzar tableros') THEN
    RAISE EXCEPTION 'A copy destination from another board must be rejected atomically: %',
      v_denied_copy;
  END IF;

  -- A birthday ID is not a task source and receives only the generic response.
  v_birthday := public.create_birthday_p(
    '32000000-0000-4000-8000-000000000033', v_board.slug,
    'Cumpleaños sin copia', 3, 14, NULL
  );
  IF v_birthday->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic birthday setup failed: %', v_birthday;
  END IF;
  v_birthday_id := (v_birthday->'birthday'->>'id')::uuid;
  v_denied_preview := public.preview_task_copy_p(v_board.slug, v_birthday_id);
  v_denied_copy := public.copy_task_p(
    '32000000-0000-4000-8000-000000000034', v_board.slug,
    v_birthday_id, v_column.id, 'No copiar cumpleaños', v_changed->>'source_hash'
  );
  IF v_denied_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_denied_copy->>'status' IS DISTINCT FROM 'unavailable'
    OR EXISTS (SELECT 1 FROM public.tasks WHERE title = 'No copiar cumpleaños') THEN
    RAISE EXCEPTION 'Birthday entities must not be offered or copied as tasks: % / %',
      v_denied_preview, v_denied_copy;
  END IF;

  -- Deleted sources remain unavailable until their own recovery flow restores them.
  v_trash_task := public.create_task_p(
    '32000000-0000-4000-8000-000000000035', v_board.id,
    v_column.id, 'Fuente en papelera', NULL, 'medium'
  );
  v_trash_task_id := (v_trash_task->'task'->>'id')::uuid;
  v_trash_result := public.delete_task_p(
    '32000000-0000-4000-8000-000000000036', v_board.slug,
    v_trash_task_id, 'user_requested'
  );
  v_denied_preview := public.preview_task_copy_p(v_board.slug, v_trash_task_id);
  v_denied_copy := public.copy_task_p(
    '32000000-0000-4000-8000-000000000037', v_board.slug,
    v_trash_task_id, v_column.id, 'No copiar papelera', v_changed->>'source_hash'
  );
  IF v_trash_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_denied_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_denied_copy->>'status' IS DISTINCT FROM 'unavailable'
    OR EXISTS (SELECT 1 FROM public.tasks WHERE title = 'No copiar papelera') THEN
    RAISE EXCEPTION 'A deleted task must remain unavailable to copy: % / % / %',
      v_trash_result, v_denied_preview, v_denied_copy;
  END IF;

  -- A user outside the board receives no source identifiers or private fields.
  PERFORM set_config(
    'request.jwt.claim.sub', '43200000-0000-4000-8000-000000000003', true
  );
  v_denied_preview := public.preview_task_copy_p(v_board.slug, v_source.id);
  v_denied_copy := public.copy_task_p(
    '32000000-0000-4000-8000-000000000038', v_board.slug,
    v_source.id, v_destination.id, 'No crear sin acceso', v_changed->>'source_hash'
  );
  IF v_denied_preview->>'status' IS DISTINCT FROM 'unavailable'
    OR v_denied_preview::text LIKE '%' || v_source.id::text || '%'
    OR v_denied_preview::text LIKE '%Fuente pendiente%'
    OR v_denied_copy->>'status' IS DISTINCT FROM 'unavailable'
    OR EXISTS (SELECT 1 FROM public.tasks WHERE title = 'No crear sin acceso') THEN
    RAISE EXCEPTION 'A nonmember must receive a generic denial with no copy: % / %',
      v_denied_preview, v_denied_copy;
  END IF;
  PERFORM set_config(
    'request.jwt.claim.sub', '43200000-0000-4000-8000-000000000002', true
  );

  -- The occurrence owns its label selection. Changing the template cannot
  -- change the labels shown or copied from this current occurrence.
  v_occurrence_task := public.create_task_p(
    '32000000-0000-4000-8000-000000000017', v_board.id,
    v_column.id, 'Ocurrencia de origen', NULL, 'medium'
  );
  v_source_edit := public.edit_task_fields_p(
    '32000000-0000-4000-8000-000000000018', v_board.slug,
    (v_occurrence_task->'task'->>'id')::uuid,
    pg_catalog.jsonb_build_object('due_on', (current_date - 1)::text),
    '{"due_on":1}'::jsonb
  );
  v_occurrence_label := public.create_board_label_p(
    v_board.slug, 'Solo ocurrencia', 'purple'
  );
  v_template_label := public.create_board_label_p(
    v_board.slug, 'Solo futuras', 'orange'
  );
  v_occurrence_label_id := (v_occurrence_label->'label'->>'id')::uuid;
  v_template_label_id := (v_template_label->'label'->>'id')::uuid;
  v_set_labels := public.set_task_labels_p(
    v_board.slug, (v_occurrence_task->'task'->>'id')::uuid,
    ARRAY[]::uuid[], ARRAY[v_occurrence_label_id]::uuid[]
  );
  v_occurrence_series := public.create_repetition_with_advance_p(
    '32000000-0000-4000-8000-000000000019', v_board.slug,
    (v_occurrence_task->'task'->>'id')::uuid, current_date - 1, NULL,
    2, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_occurrence_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic copy occurrence series setup failed: %',
      v_occurrence_series;
  END IF;
  v_occurrence_status := public.get_repetition_p(
    v_board.slug, (v_occurrence_task->'task'->>'id')::uuid
  );
  SELECT coalesce(pg_catalog.array_agg(item.value::uuid ORDER BY item.value::uuid),
    ARRAY[]::uuid[])
  INTO v_expected_template_ids
  FROM pg_catalog.jsonb_array_elements_text(
    v_occurrence_status->'template_label_ids'
  ) AS item(value);
  v_occurrence_preview_before := public.preview_task_copy_p(
    v_board.slug, (v_occurrence_task->'task'->>'id')::uuid
  );
  v_template_change := public.set_repetition_template_labels_p(
    v_board.slug, (v_occurrence_task->'task'->>'id')::uuid,
    v_expected_template_ids, ARRAY[v_template_label_id]::uuid[]
  );
  v_occurrence_preview_after := public.preview_task_copy_p(
    v_board.slug, (v_occurrence_task->'task'->>'id')::uuid
  );
  v_occurrence_source_labels := public.get_task_labels_p(
    v_board.slug, (v_occurrence_task->'task'->>'id')::uuid
  );
  v_occurrence_copy := public.copy_task_p(
    '32000000-0000-4000-8000-000000000020', v_board.slug,
    (v_occurrence_task->'task'->>'id')::uuid, v_destination.id,
    'Copia puntual de ocurrencia', v_occurrence_preview_after->>'source_hash'
  );
  v_occurrence_copy_labels := public.get_task_labels_p(
    v_board.slug, (v_occurrence_copy->'task'->>'id')::uuid
  );
  IF v_occurrence_status->>'status' IS DISTINCT FROM 'available'
    OR v_template_change->>'status' IS DISTINCT FROM 'confirmed'
    OR v_occurrence_preview_before->'labels'->0->>'id'
      IS DISTINCT FROM v_occurrence_label_id::text
    OR v_occurrence_preview_after->>'source_hash'
      IS DISTINCT FROM v_occurrence_preview_before->>'source_hash'
    OR jsonb_array_length(v_occurrence_preview_after->'labels') <> 1
    OR v_occurrence_preview_after->'labels'->0->>'id'
      IS DISTINCT FROM v_occurrence_label_id::text
    OR jsonb_array_length(v_occurrence_source_labels->'labels') <> 1
    OR v_occurrence_source_labels->'labels'->0->>'id'
      IS DISTINCT FROM v_occurrence_label_id::text
    OR v_occurrence_copy->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_occurrence_copy->'task'->>'is_completed')::boolean
    OR jsonb_array_length(v_occurrence_copy_labels->'labels') <> 1
    OR v_occurrence_copy_labels->'labels'->0->>'id'
      IS DISTINCT FROM v_occurrence_label_id::text THEN
    RAISE EXCEPTION 'Occurrence copy must use actual task labels, not the series template: % / % / % / % / %',
      v_occurrence_preview_before, v_occurrence_preview_after,
      v_occurrence_source_labels, v_occurrence_copy, v_occurrence_copy_labels;
  END IF;
END;
$$;
COMMIT;

-- A collaborator can preview, but confirmation revalidates membership after
-- the preview so a revoked collaborator cannot create a task from stale data.
INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT board.id, '43200000-0000-4000-8000-000000000004', 'collaborator'
FROM public.boards AS board
WHERE board.name = 'Issue #32 pending copy';
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43200000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_board_slug text;
  v_source_id uuid;
  v_target_id uuid;
  v_preview jsonb;
BEGIN
  SELECT board.slug, task.id, target.id
  INTO STRICT v_board_slug, v_source_id, v_target_id
  FROM public.boards AS board
  JOIN public.tasks AS task ON task.title = 'Fuente pendiente'
  JOIN public.columns AS source_column ON source_column.id = task.column_id
    AND source_column.board_id = board.id
  JOIN public.columns AS target ON target.board_id = board.id
    AND target.title = 'Destino'
  WHERE board.name = 'Issue #32 pending copy';
  v_preview := public.preview_task_copy_p(v_board_slug, v_source_id);
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'source_hash' IS NULL THEN
    RAISE EXCEPTION 'An authorized collaborator could not preview the task: %',
      v_preview;
  END IF;
  INSERT INTO issue32_copy_access_refs (
    board_slug, source_task_id, target_column_id, source_hash
  ) VALUES (v_board_slug, v_source_id, v_target_id, v_preview->>'source_hash');
END;
$$;
COMMIT;
DELETE FROM public.board_memberships AS membership
USING public.boards AS board
WHERE membership.board_id = board.id
  AND board.name = 'Issue #32 pending copy'
  AND membership.user_id = '43200000-0000-4000-8000-000000000004';
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43200000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  refs issue32_copy_access_refs%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT refs FROM issue32_copy_access_refs;
  v_result := public.copy_task_p(
    '32000000-0000-4000-8000-000000000039', refs.board_slug,
    refs.source_task_id, refs.target_column_id,
    'No crear tras revocación', refs.source_hash
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR EXISTS (SELECT 1 FROM public.tasks WHERE title = 'No crear tras revocación') THEN
    RAISE EXCEPTION 'A source access loss after preview must block the copy: %',
      v_result;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: current pending tasks have an authorized E04 copy preview.'
