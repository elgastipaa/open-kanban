\set ON_ERROR_STOP on
\echo 'Issue #31: repetition templates own board-scoped labels and inherit active labels atomically'

INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue31@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43100000-0000-4000-8000-000000000002',
  'issue31@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53100000-0000-4000-8000-000000000002',
  '43100000-0000-4000-8000-000000000002', 'google', 'issue31-google-subject',
  '{"email":"issue31@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '43100000-0000-4000-8000-000000000002',
    google_subject = 'issue31-google-subject', state = 'active'
WHERE email = 'issue31@example.test';

INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue31-outsider@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43100000-0000-4000-8000-000000000003',
  'issue31-outsider@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53100000-0000-4000-8000-000000000003',
  '43100000-0000-4000-8000-000000000003', 'google', 'issue31-outsider-subject',
  '{"email":"issue31-outsider@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '43100000-0000-4000-8000-000000000003',
    google_subject = 'issue31-outsider-subject', state = 'active'
WHERE email = 'issue31-outsider@example.test';

CREATE TEMP TABLE issue31_repetition_refs (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  current_task_id uuid NOT NULL,
  series_id uuid NOT NULL,
  label_a uuid NOT NULL,
  label_b uuid NOT NULL,
  other_board_label uuid NOT NULL,
  start_on date NOT NULL,
  PRIMARY KEY (series_id)
);
GRANT SELECT, INSERT ON issue31_repetition_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_other_board record;
  v_other_column record;
  v_task jsonb;
  v_label_a jsonb;
  v_label_b jsonb;
  v_other_label jsonb;
  v_task_labels jsonb;
  v_due_edit jsonb;
  v_created jsonb;
  v_template jsonb;
  v_template_change jsonb;
  v_other_labels uuid[];
  v_pair uuid[];
  v_series_id uuid;
  v_task_id uuid;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Repeticiones #31', 'America/Argentina/Buenos_Aires',
    '31000000-0000-4000-8000-000000000001'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'A organizar', 0
  );
  SELECT * INTO v_other_board
  FROM public.create_board_p(
    'Otro tablero #31', 'America/Argentina/Buenos_Aires',
    '31000000-0000-4000-8000-000000000002'
  );
  SELECT * INTO v_other_column FROM public.create_column_p(
    v_other_board.slug, v_other_board.id, 'A organizar', 0
  );

  v_label_a := public.create_board_label_p(v_board.slug, 'Plantilla A', 'blue');
  v_label_b := public.create_board_label_p(v_board.slug, 'Plantilla B', 'green');
  v_other_label := public.create_board_label_p(v_other_board.slug, 'Etiqueta ajena', 'purple');
  IF v_label_a->>'status' IS DISTINCT FROM 'confirmed'
    OR v_label_b->>'status' IS DISTINCT FROM 'confirmed'
    OR v_other_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic label creation failed: %, %, %',
      v_label_a, v_label_b, v_other_label;
  END IF;

  v_task := public.create_task_p(
    '31000000-0000-4000-8000-000000000010', v_board.id,
    v_column.id, 'Tarea actual', NULL, 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  v_due_edit := public.edit_task_fields_p(
    '31000000-0000-4000-8000-000000000012', v_board.slug, v_task_id,
    pg_catalog.jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_due_edit->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic occurrence date setup failed: %', v_due_edit;
  END IF;

  v_task_labels := public.set_task_labels_p(
    v_board.slug, v_task_id, ARRAY[]::uuid[],
    ARRAY[(v_label_a->'label'->>'id')::uuid, (v_label_b->'label'->>'id')::uuid]
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Initial task label selection failed: %', v_task_labels;
  END IF;
  v_created := public.create_repetition_with_advance_p(
    '31000000-0000-4000-8000-000000000013', v_board.slug, v_task_id,
    current_date, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic repetition creation failed: %', v_created;
  END IF;
  v_series_id := (v_created->>'series_id')::uuid;
  SELECT array_agg(label_id ORDER BY label_id) INTO v_pair
  FROM unnest(ARRAY[
    (v_label_a->'label'->>'id')::uuid,
    (v_label_b->'label'->>'id')::uuid
  ]) AS selected(label_id);

  v_template := public.get_repetition_p(v_board.slug, v_task_id);
  IF v_template->>'status' IS DISTINCT FROM 'available'
    OR v_template->'template_label_ids' IS DISTINCT FROM to_jsonb(v_pair) THEN
    RAISE EXCEPTION 'A new series must seed its independent template labels from the current occurrence: %',
      v_template;
  END IF;

  v_task_labels := public.set_task_labels_p(
    v_board.slug, v_task_id, v_pair,
    ARRAY[(v_label_b->'label'->>'id')::uuid]
  );
  IF v_task_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Current occurrence label edit failed: %', v_task_labels;
  END IF;
  v_template := public.get_repetition_p(v_board.slug, v_task_id);
  IF v_template->'template_label_ids' IS DISTINCT FROM to_jsonb(v_pair) THEN
    RAISE EXCEPTION 'Changing the current occurrence changed the series template: %', v_template;
  END IF;

  v_template_change := public.set_repetition_template_labels_p(
    v_board.slug, v_task_id, v_pair,
    ARRAY[(v_label_a->'label'->>'id')::uuid]
  );
  IF v_template_change->>'status' IS DISTINCT FROM 'confirmed'
    OR v_template_change->'template_label_ids' IS DISTINCT FROM
      jsonb_build_array(v_label_a->'label'->>'id') THEN
    RAISE EXCEPTION 'A member must be able to update only future template labels: %',
      v_template_change;
  END IF;
  v_template := public.get_repetition_p(v_board.slug, v_task_id);
  IF v_template->'template_label_ids' IS DISTINCT FROM
      jsonb_build_array(v_label_a->'label'->>'id')
    OR pg_catalog.jsonb_array_length(
      public.get_task_labels_p(v_board.slug, v_task_id)->'labels'
    ) <> 1 THEN
    RAISE EXCEPTION 'Template label changes rewrote the current occurrence or lost independent selection: %',
      v_template;
  END IF;

  v_other_labels := ARRAY[(v_other_label->'label'->>'id')::uuid];
  v_template_change := public.set_repetition_template_labels_p(
    v_board.slug, v_task_id,
    ARRAY[(v_label_a->'label'->>'id')::uuid], v_other_labels
  );
  v_template := public.get_repetition_p(v_board.slug, v_task_id);
  IF v_template_change->>'status' IS DISTINCT FROM 'conflict'
    OR v_template_change->>'reason' IS DISTINCT FROM 'invalid_selection'
    OR v_template->'template_label_ids' IS DISTINCT FROM
      jsonb_build_array(v_label_a->'label'->>'id') THEN
    RAISE EXCEPTION 'A template selection cannot cross board identity or partially write: %',
      v_template_change;
  END IF;

  INSERT INTO pg_temp.issue31_repetition_refs(
    board_id, board_slug, task_id, current_task_id, series_id, label_a, label_b,
    other_board_label, start_on
  ) VALUES (
    v_board.id, v_board.slug, v_task_id, v_task_id, v_series_id,
    (v_label_a->'label'->>'id')::uuid,
    (v_label_b->'label'->>'id')::uuid,
    (v_other_label->'label'->>'id')::uuid,
    current_date
  );
END;
$$;
COMMIT;

-- The first generated occurrence uses the template value at generation time,
-- not the current occurrence's separately edited labels.
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_result jsonb;
  v_now timestamptz;
  v_task_label_ids uuid[];
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  SELECT job.* INTO STRICT v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_ref.series_id AND job.job_kind = 'advance'
    AND job.state = 'queued' ORDER BY job.created_at LIMIT 1;
  v_now := ((v_ref.start_on + 1)::timestamp + interval '12 hours')
    AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_result := public.advance_daily_repetition_internal_p(v_job, v_now);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The first synthetic generation failed: %', v_result;
  END IF;
  SELECT array_agg(assignment.label_id ORDER BY assignment.label_id)
  INTO v_task_label_ids
  FROM public.board_label_task_assignments AS assignment
  WHERE assignment.task_id = (v_result->>'task_id')::uuid;
  IF v_task_label_ids IS DISTINCT FROM ARRAY[v_ref.label_a]::uuid[] THEN
    RAISE EXCEPTION 'New occurrence did not inherit only the active template set: expected %, actual %',
      ARRAY[v_ref.label_a]::uuid[], v_task_label_ids;
  END IF;
  UPDATE pg_temp.issue31_repetition_refs
  SET current_task_id = (v_result->>'task_id')::uuid
  WHERE series_id = v_ref.series_id;
  IF (SELECT array_agg(assignment.label_id ORDER BY assignment.label_id)
      FROM public.board_label_task_assignments AS assignment
      WHERE assignment.task_id = v_ref.task_id)
    IS DISTINCT FROM ARRAY[v_ref.label_b]::uuid[] THEN
    RAISE EXCEPTION 'Generating an occurrence rewrote the preceding task labels';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_result jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_catalog jsonb;
  v_label jsonb;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  v_result := public.set_repetition_template_labels_p(
    v_ref.board_slug, v_ref.current_task_id, ARRAY[v_ref.label_a]::uuid[],
    ARRAY[v_ref.label_a, v_ref.label_b]::uuid[]
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Template setup for delete/restore failed: %', v_result;
  END IF;

  v_deleted := public.delete_board_label_p(
    v_ref.board_slug, v_ref.label_b,
    (SELECT (item->>'version')::bigint
     FROM jsonb_array_elements(
       public.list_board_labels_p(v_ref.board_slug)->'labels'
     ) AS item
     WHERE item->>'id' = v_ref.label_b::text)
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic label deletion failed: %', v_deleted;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_result jsonb;
  v_now timestamptz;
  v_task_id uuid;
  v_labels uuid[];
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  SELECT job.* INTO STRICT v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_ref.series_id AND job.job_kind = 'advance'
    AND job.state = 'queued' ORDER BY job.created_at DESC LIMIT 1;
  v_now := ((v_ref.start_on + 2)::timestamp + interval '12 hours')
    AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_result := public.advance_daily_repetition_internal_p(v_job, v_now);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Generation while a template label is deleted failed: %', v_result;
  END IF;
  v_task_id := (v_result->>'task_id')::uuid;
  SELECT array_agg(assignment.label_id ORDER BY assignment.label_id)
  INTO v_labels FROM public.board_label_task_assignments AS assignment
  WHERE assignment.task_id = v_task_id;
  IF v_labels IS DISTINCT FROM ARRAY[v_ref.label_a]::uuid[] THEN
    RAISE EXCEPTION 'A deleted template label was inherited: %', v_labels;
  END IF;
  UPDATE pg_temp.issue31_repetition_refs
  SET current_task_id = v_task_id
  WHERE series_id = v_ref.series_id;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_result jsonb;
  v_template jsonb;
  v_task_id uuid;
  v_restored jsonb;
  v_preview jsonb;
  v_trash jsonb;
  v_deleted_label jsonb;
  v_series_selection uuid[];
  v_labels uuid[];
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.task_id);
  SELECT (item->>'task_id')::uuid INTO v_task_id
  FROM jsonb_array_elements(v_template->'occurrences') AS item
  WHERE (item->>'occurrence_on')::date = v_ref.start_on + 2;
  v_trash := public.list_deleted_board_labels_p(v_ref.board_slug);
  SELECT item INTO v_deleted_label
  FROM jsonb_array_elements(v_trash->'labels') AS item
  WHERE item->>'id' = v_ref.label_b::text;
  IF v_template->'template_label_ids' IS DISTINCT FROM
      jsonb_build_array(v_ref.label_a)
    OR v_deleted_label IS NULL THEN
    RAISE EXCEPTION 'A deleted label must be hidden from template selection and available to restore';
  END IF;
  v_preview := public.preview_restore_board_label_with_series_p(
    v_ref.board_slug, v_ref.label_b, v_deleted_label->>'name'
  );
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR jsonb_array_length(v_preview->'associated_series') <> 1
    OR v_preview->'associated_series'->0->>'id' IS DISTINCT FROM v_ref.series_id::text THEN
    RAISE EXCEPTION 'Restore preview must show the affected future template association: %', v_preview;
  END IF;
  v_series_selection := ARRAY[v_ref.series_id]::uuid[];
  v_restored := public.restore_board_label_with_series_p(
    v_ref.board_slug, v_ref.label_b, (v_deleted_label->>'version')::bigint,
    v_deleted_label->>'name',
    ARRAY[v_ref.task_id]::uuid[], ARRAY[]::uuid[], v_series_selection
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic label restoration failed: %', v_restored;
  END IF;
  v_trash := public.get_task_labels_p(v_ref.board_slug, v_task_id);
  SELECT coalesce(array_agg((item->>'id')::uuid ORDER BY item->>'id'), ARRAY[]::uuid[])
  INTO v_labels FROM jsonb_array_elements(v_trash->'labels') AS item;
  IF v_labels IS DISTINCT FROM ARRAY[v_ref.label_a]::uuid[] THEN
    RAISE EXCEPTION 'Restoring a label retroactively changed an occurrence born during its absence: %',
      v_labels;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_result jsonb;
  v_now timestamptz;
  v_labels uuid[];
  v_expected uuid[];
  v_next_ids uuid[];
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  SELECT job.* INTO STRICT v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_ref.series_id AND job.job_kind = 'advance'
    AND job.state = 'queued' ORDER BY job.created_at DESC LIMIT 1;
  v_now := ((v_ref.start_on + 3)::timestamp + interval '12 hours')
    AT TIME ZONE 'America/Argentina/Buenos_Aires';
  v_result := public.advance_daily_repetition_internal_p(v_job, v_now);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Generation after label restoration failed: %', v_result;
  END IF;
  SELECT array_agg(assignment.label_id ORDER BY assignment.label_id)
  INTO v_labels FROM public.board_label_task_assignments AS assignment
  WHERE assignment.task_id = (v_result->>'task_id')::uuid;
  SELECT array_agg(selected.id ORDER BY selected.id)
  INTO v_expected FROM unnest(ARRAY[v_ref.label_a, v_ref.label_b]) AS selected(id);
  IF v_labels IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'A restored template label was not inherited by a later occurrence: %', v_labels;
  END IF;
  UPDATE pg_temp.issue31_repetition_refs
  SET current_task_id = (v_result->>'task_id')::uuid
  WHERE series_id = v_ref.series_id;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_ids uuid[] := ARRAY[]::uuid[];
  v_expected uuid[];
  v_next_ids uuid[];
  v_label jsonb;
  v_result jsonb;
  v_current uuid[];
  v_template jsonb;
  v_deleted jsonb;
  v_preview jsonb;
  v_extra jsonb;
  v_trash jsonb;
  v_deleted_label jsonb;
  v_index_to_omit uuid;
  v_index integer;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  FOR v_index IN 1..11 LOOP
    v_label := public.create_board_label_p(
      v_ref.board_slug, format('Límite plantilla %s', v_index),
      (ARRAY['red', 'orange', 'yellow', 'green', 'teal', 'blue', 'purple', 'pink', 'gray'])[1 + ((v_index - 1) % 9)]
    );
    IF v_label->>'status' IS DISTINCT FROM 'confirmed' THEN
      RAISE EXCEPTION 'Could not create synthetic limit label %: %', v_index, v_label;
    END IF;
    v_ids := array_append(v_ids, (v_label->'label'->>'id')::uuid);
  END LOOP;
  v_result := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  SELECT coalesce(array_agg((item #>> '{}')::uuid ORDER BY item #>> '{}'), ARRAY[]::uuid[])
  INTO v_expected FROM jsonb_array_elements(v_result->'template_label_ids') AS item;
  v_result := public.set_repetition_template_labels_p(
    v_ref.board_slug, v_ref.current_task_id, v_expected, v_ids
  );
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.task_id);
  SELECT coalesce(array_agg((item #>> '{}')::uuid ORDER BY item #>> '{}'), ARRAY[]::uuid[])
  INTO v_current FROM jsonb_array_elements(v_template->'template_label_ids') AS item;
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'reason' IS DISTINCT FROM 'too_many_labels'
    OR v_current IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Template labels must enforce ten atomically without partial changes: result %, before %, after %',
      v_result, v_expected, v_current;
  END IF;

  SELECT array_agg(id ORDER BY id) INTO v_next_ids
  FROM unnest(v_ids[1:10]) AS selected(id);
  v_result := public.set_repetition_template_labels_p(
    v_ref.board_slug, v_ref.current_task_id, v_expected, v_next_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Ten active template labels should be accepted: %', v_result;
  END IF;
  v_index_to_omit := v_next_ids[1];
  v_deleted := public.delete_board_label_p(
    v_ref.board_slug, v_index_to_omit,
    (SELECT (item->>'version')::bigint
     FROM jsonb_array_elements(
       public.list_board_labels_p(v_ref.board_slug)->'labels'
     ) AS item
     WHERE item->>'id' = v_index_to_omit::text)
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Template cap restore fixture could not delete one label: %', v_deleted;
  END IF;

  v_extra := public.create_board_label_p(v_ref.board_slug, 'Plantilla adicional', 'pink');
  IF v_extra->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the replacement active template label: %', v_extra;
  END IF;
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  SELECT coalesce(array_agg((item #>> '{}')::uuid ORDER BY item #>> '{}'), ARRAY[]::uuid[])
  INTO v_expected FROM jsonb_array_elements(v_template->'template_label_ids') AS item;
  v_next_ids := ARRAY(
    SELECT id FROM unnest(v_expected) AS active(id)
    WHERE id <> v_index_to_omit
    UNION ALL SELECT (v_extra->'label'->>'id')::uuid
  );
  SELECT array_agg(id ORDER BY id) INTO v_next_ids
  FROM unnest(v_next_ids) AS selected(id);
  IF cardinality(v_next_ids) <> 10 THEN
    RAISE EXCEPTION 'Synthetic restore-cap fixture expected ten replacement labels: %', v_next_ids;
  END IF;
  v_result := public.set_repetition_template_labels_p(
    v_ref.board_slug, v_ref.current_task_id, v_expected, v_next_ids
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not fill the active template cap before restore: %', v_result;
  END IF;

  v_trash := public.list_deleted_board_labels_p(v_ref.board_slug);
  SELECT item INTO v_deleted_label
  FROM jsonb_array_elements(v_trash->'labels') AS item
  WHERE item->>'id' = v_index_to_omit::text;
  v_preview := public.preview_restore_board_label_with_series_p(
    v_ref.board_slug, v_index_to_omit, v_deleted_label->>'name'
  );
  IF v_preview->'associated_series'->0->>'would_exceed_limit' IS DISTINCT FROM 'true'
    OR (v_preview->'associated_series'->0->>'active_label_count')::integer <> 10 THEN
    RAISE EXCEPTION 'Restore preview must identify the template at its ten-label cap: %', v_preview;
  END IF;
  v_result := public.restore_board_label_p(
    v_ref.board_slug, v_index_to_omit,
    (v_deleted_label->>'version')::bigint, v_deleted_label->>'name',
    ARRAY[]::uuid[], ARRAY[]::uuid[]
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR v_result->>'reason' IS DISTINCT FROM 'too_many_labels' THEN
    RAISE EXCEPTION 'Legacy restore must not silently overflow an active template: %', v_result;
  END IF;
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  SELECT coalesce(array_agg((item #>> '{}')::uuid ORDER BY item #>> '{}'), ARRAY[]::uuid[])
  INTO v_current FROM jsonb_array_elements(v_template->'template_label_ids') AS item;
  IF v_current IS DISTINCT FROM v_next_ids THEN
    RAISE EXCEPTION 'A rejected label restore must not partially edit the template: result %, expected %, actual %',
      v_result, v_next_ids, v_current;
  END IF;

  v_result := public.restore_board_label_with_series_p(
    v_ref.board_slug, v_index_to_omit,
    (v_deleted_label->>'version')::bigint, v_deleted_label->>'name',
    ARRAY[]::uuid[], ARRAY[]::uuid[], ARRAY[]::uuid[]
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT (v_ref.series_id::text = ANY(
      ARRAY(SELECT jsonb_array_elements_text(v_result->'omitted_series_ids'))
    )) THEN
    RAISE EXCEPTION 'Explicitly omitting the over-cap template association should restore atomically: %',
      v_result;
  END IF;
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  SELECT coalesce(array_agg((item #>> '{}')::uuid ORDER BY item #>> '{}'), ARRAY[]::uuid[])
  INTO v_current FROM jsonb_array_elements(v_template->'template_label_ids') AS item;
  IF v_current IS DISTINCT FROM v_next_ids THEN
    RAISE EXCEPTION 'Explicitly omitting one template relation changed unrelated associations: %', v_current;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_status jsonb;
  v_label jsonb;
  v_deleted_label jsonb;
  v_deleted_series jsonb;
  v_restored_series jsonb;
  v_preview jsonb;
  v_restored_label jsonb;
  v_template jsonb;
  v_task_labels jsonb;
  v_set_result jsonb;
  v_edit_result jsonb;
  v_expected uuid[];
  v_label_id uuid;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  v_label := public.create_board_label_p(v_ref.board_slug, 'Recuperación serie #31', 'blue');
  IF v_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the synthetic recovery template label: %', v_label;
  END IF;
  v_label_id := (v_label->'label'->>'id')::uuid;

  v_status := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  SELECT coalesce(array_agg((item #>> '{}')::uuid ORDER BY item #>> '{}'), ARRAY[]::uuid[])
  INTO v_expected FROM jsonb_array_elements(v_status->'template_label_ids') AS item;
  v_set_result := public.set_repetition_template_labels_p(
    v_ref.board_slug, v_ref.current_task_id, v_expected,
    ARRAY[v_ref.label_a, v_label_id]::uuid[]
  );
  IF v_set_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not set the two recovery template labels: %', v_set_result;
  END IF;
  v_status := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  -- Leave a future slot after the recovery inheritance assertion; the original
  -- finite fixture is one occurrence from completion at this point.
  v_edit_result := public.edit_repetition_p(
    '31000000-0000-4000-8000-000000000024', v_ref.board_slug,
    v_ref.current_task_id, (v_status->>'revision')::bigint,
    (v_status->>'next_due_on')::date, 'none', NULL, NULL,
    v_status->'pattern', (v_status->>'advance_days')::integer,
    (v_status->>'appearance_column_id')::uuid,
    v_status->'template_snapshot', false
  );
  IF v_edit_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not leave a future slot for the recovery test: %', v_edit_result;
  END IF;
  v_status := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  v_deleted_label := public.delete_board_label_p(v_ref.board_slug, v_label_id, 1);
  IF v_deleted_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not hide a selected template label before series recovery: %',
      v_deleted_label;
  END IF;

  v_status := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  v_deleted_series := public.delete_repetition_series_p(
    '31000000-0000-4000-8000-000000000020', v_ref.board_slug, v_ref.series_id,
    (v_status->>'revision')::bigint, true
  );
  IF v_deleted_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not delete the synthetic repetition series: %', v_deleted_series;
  END IF;
  v_restored_series := public.restore_repetition_series_p(
    '31000000-0000-4000-8000-000000000021', v_ref.board_slug, v_ref.series_id,
    (v_status->>'appearance_column_id')::uuid
  );
  IF v_restored_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not restore the synthetic repetition series: %', v_restored_series;
  END IF;

  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  IF v_template->>'state' IS DISTINCT FROM 'active'
    OR v_template->'template_label_ids' IS DISTINCT FROM jsonb_build_array(v_ref.label_a) THEN
    RAISE EXCEPTION 'Series restore lost its active template labels or exposed the hidden tag: %',
      v_template;
  END IF;
  v_preview := public.preview_restore_board_label_with_series_p(
    v_ref.board_slug, v_label_id, v_deleted_label->'label'->>'name'
  );
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_preview->'associated_series') AS item
      WHERE item->>'id' = v_ref.series_id::text
    ) THEN
    RAISE EXCEPTION 'A soft-deleted template link must remain available in label restore preview: %',
      v_preview;
  END IF;
  SELECT array_agg(selected.id ORDER BY selected.id)
  INTO v_expected FROM unnest(ARRAY[v_ref.label_a, v_label_id]::uuid[]) AS selected(id);
  v_restored_label := public.restore_board_label_with_series_p(
    v_ref.board_slug, v_label_id,
    (v_deleted_label->'label'->>'version')::bigint,
    v_deleted_label->'label'->>'name',
    ARRAY[]::uuid[], ARRAY[]::uuid[], ARRAY[v_ref.series_id]::uuid[]
  );
  IF v_restored_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not explicitly restore the selected series label: %',
      v_restored_label;
  END IF;
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  IF v_template->'template_label_ids' IS DISTINCT FROM to_jsonb(v_expected) THEN
    RAISE EXCEPTION 'Explicit label restore did not restore the saved series template: %',
      v_template;
  END IF;
  v_task_labels := public.get_task_labels_p(v_ref.board_slug, v_ref.current_task_id);
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_task_labels->'labels') AS item
    WHERE item->>'id' = v_label_id::text
  ) THEN
    RAISE EXCEPTION 'Restoring a template label retroactively changed the current occurrence: %',
      v_task_labels;
  END IF;

END;
$$;
COMMIT;

-- The worker is a service-only path; run it as the disposable database owner,
-- then verify the occurrence relation directly without exposing job rows to a
-- board member RPC.
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_result jsonb;
  v_future_ids uuid[];
  v_expected uuid[];
  v_now timestamptz;
  v_template_label_id uuid;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  SELECT label.id INTO STRICT v_template_label_id
  FROM public.board_labels AS label
  WHERE label.board_id = v_ref.board_id AND label.name = 'Recuperación serie #31';
  SELECT job.* INTO STRICT v_job
  FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_ref.series_id AND job.job_kind = 'advance'
    AND job.state = 'queued'
  ORDER BY job.created_at DESC LIMIT 1;
  v_now := ((v_job.scheduled_on::timestamp + interval '12 hours')
    AT TIME ZONE 'America/Argentina/Buenos_Aires');
  v_result := public.advance_daily_repetition_internal_p(v_job, v_now);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Generation after series/template recovery failed: %', v_result;
  END IF;
  SELECT coalesce(array_agg(assignment.label_id ORDER BY assignment.label_id), ARRAY[]::uuid[])
  INTO v_future_ids
  FROM public.board_label_task_assignments AS assignment
  WHERE assignment.task_id = (v_result->>'task_id')::uuid;
  SELECT array_agg(selected.id ORDER BY selected.id)
  INTO v_expected FROM unnest(ARRAY[v_ref.label_a, v_template_label_id]::uuid[]) AS selected(id);
  IF v_future_ids IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'The next occurrence did not inherit the restored template: expected %, actual %',
      v_expected, v_future_ids;
  END IF;
  UPDATE pg_temp.issue31_repetition_refs
  SET current_task_id = (v_result->>'task_id')::uuid
  WHERE series_id = v_ref.series_id;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_status jsonb;
  v_label jsonb;
  v_selection jsonb;
  v_deleted_label jsonb;
  v_deleted_series jsonb;
  v_expected uuid[];
  v_purged_label_id uuid;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  v_label := public.create_board_label_p(v_ref.board_slug, 'Purgada durante recuperación #31', 'orange');
  IF v_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the synthetic purge label: %', v_label;
  END IF;
  v_purged_label_id := (v_label->'label'->>'id')::uuid;

  v_status := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  SELECT array_agg((item #>> '{}')::uuid ORDER BY item #>> '{}')
  INTO v_expected FROM jsonb_array_elements(v_status->'template_label_ids') AS item;
  v_selection := public.set_repetition_template_labels_p(
    v_ref.board_slug, v_ref.current_task_id, v_expected,
    ARRAY[v_ref.label_a, v_purged_label_id]::uuid[]
  );
  IF v_selection->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not set the template before physical label purge: %', v_selection;
  END IF;
  v_deleted_label := public.delete_board_label_p(v_ref.board_slug, v_purged_label_id, 1);
  IF v_deleted_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not soft-delete the synthetic purge label: %', v_deleted_label;
  END IF;
  v_status := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  v_deleted_series := public.delete_repetition_series_p(
    '31000000-0000-4000-8000-000000000025', v_ref.board_slug, v_ref.series_id,
    (v_status->>'revision')::bigint, true
  );
  IF v_deleted_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not delete series before physical label purge: %', v_deleted_series;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_label_id uuid;
  v_purged integer;
  v_remaining integer;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  SELECT label.id INTO STRICT v_label_id FROM public.board_labels AS label
  WHERE label.board_id = v_ref.board_id
    AND label.name = 'Purgada durante recuperación #31';
  UPDATE public.board_labels AS label
  SET deleted_at = pg_catalog.clock_timestamp() - interval '8 days'
  WHERE label.id = v_label_id;
  v_purged := public.purge_expired_board_labels_p(100);
  SELECT count(*)::integer INTO v_remaining
  FROM public.board_labels AS label WHERE label.id = v_label_id;
  IF v_purged <> 1 OR v_remaining <> 0 THEN
    RAISE EXCEPTION 'The selected synthetic label was not physically purged: %, %',
      v_purged, v_remaining;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_restored jsonb;
  v_template jsonb;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  v_restored := public.restore_repetition_series_p(
    '31000000-0000-4000-8000-000000000026', v_ref.board_slug, v_ref.series_id, NULL
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not recover the series after its template label was purged: %', v_restored;
  END IF;
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  IF v_template->'template_label_ids' IS DISTINCT FROM jsonb_build_array(v_ref.label_a) THEN
    RAISE EXCEPTION 'Restore recreated a template relation for a physically purged label: %',
      v_template;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_job public.daily_repetition_jobs%ROWTYPE;
  v_result jsonb;
  v_now timestamptz;
  v_labels uuid[];
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  SELECT job.* INTO STRICT v_job FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_ref.series_id AND job.job_kind = 'advance'
    AND job.state = 'queued' ORDER BY job.created_at DESC LIMIT 1;
  v_now := ((v_job.scheduled_on::timestamp + interval '12 hours')
    AT TIME ZONE 'America/Argentina/Buenos_Aires');
  v_result := public.advance_daily_repetition_internal_p(v_job, v_now);
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Generation after recovery with a purged template label failed: %', v_result;
  END IF;
  SELECT coalesce(array_agg(assignment.label_id ORDER BY assignment.label_id), ARRAY[]::uuid[])
  INTO v_labels FROM public.board_label_task_assignments AS assignment
  WHERE assignment.task_id = (v_result->>'task_id')::uuid;
  IF v_labels IS DISTINCT FROM ARRAY[v_ref.label_a]::uuid[] THEN
    RAISE EXCEPTION 'The next occurrence inherited a physically purged label: %', v_labels;
  END IF;
  UPDATE pg_temp.issue31_repetition_refs
  SET current_task_id = (v_result->>'task_id')::uuid
  WHERE series_id = v_ref.series_id;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref issue31_repetition_refs%ROWTYPE;
  v_status jsonb;
  v_stopped jsonb;
  v_template jsonb;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue31_repetition_refs;
  v_status := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  v_stopped := public.stop_repetition_series_p(
    '31000000-0000-4000-8000-000000000099', v_ref.board_slug,
    v_ref.series_id, (v_status->>'revision')::bigint
  );
  IF v_stopped->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic series stop failed: %', v_stopped;
  END IF;
  v_template := public.get_repetition_p(v_ref.board_slug, v_ref.current_task_id);
  IF v_template->>'state' IS DISTINCT FROM 'stopped'
    OR v_template ? 'template_snapshot'
    OR v_template ? 'template_label_ids' THEN
    RAISE EXCEPTION 'A terminal series exposed its template as historical content: %',
      v_template;
  END IF;
END;
$$;
COMMIT;
