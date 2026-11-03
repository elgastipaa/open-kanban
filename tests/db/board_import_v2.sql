\set ON_ERROR_STOP on
\echo 'Testing v2 import staging, invisible generation, finalization, and atomic publication'

INSERT INTO public.application_access (email, state, is_admin) VALUES
  ('issue44-owner@example.test', 'pending', false),
  ('issue44-collaborator@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('a4400000-0000-4000-8000-000000000001', 'issue44-owner@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('a4400000-0000-4000-8000-000000000002', 'issue44-collaborator@example.test', clock_timestamp(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('a4410000-0000-4000-8000-000000000001', 'a4400000-0000-4000-8000-000000000001', 'google', 'issue44-owner', '{"email":"issue44-owner@example.test","email_verified":true}'),
  ('a4410000-0000-4000-8000-000000000002', 'a4400000-0000-4000-8000-000000000002', 'google', 'issue44-collaborator', '{"email":"issue44-collaborator@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = auth_user.id, google_subject = identity.provider_id, state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE access.email = auth_user.email AND identity.provider = 'google';

CREATE TABLE public.issue44_import_fixture (
  board_id uuid NOT NULL,
  slug text NOT NULL,
  owner_id uuid NOT NULL,
  collaborator_id uuid NOT NULL,
  old_generation_id uuid NOT NULL,
  published_generation_id uuid,
  old_task_id uuid NOT NULL,
  old_attachment_id uuid NOT NULL,
  new_attachment_id uuid,
  cancel_attachment_id uuid,
  content_revision bigint,
  source_manifest jsonb,
  board_record jsonb,
  column_records jsonb,
  task_records jsonb,
  attachment_records jsonb
);
GRANT SELECT, INSERT, UPDATE ON public.issue44_import_fixture TO authenticated, service_role;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task_result jsonb;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Destino previo', 'UTC', 'a4420000-0000-4000-8000-000000000001'
  );
  SELECT id INTO v_column_id FROM public.create_column_p(
    v_board.slug, v_board.id, 'Columna previa', 0
  );
  v_task_result := public.create_task_p(
    'a4430000-0000-4000-8000-000000000001', v_board.id, v_column_id, 'Tarea previa'
  );
  INSERT INTO public.issue44_import_fixture(
    board_id, slug, owner_id, collaborator_id, old_generation_id, old_task_id,
    old_attachment_id
  ) VALUES (
    v_board.id, v_board.slug, auth.uid(), 'a4400000-0000-4000-8000-000000000002',
    (SELECT active_generation_id FROM public.boards WHERE id = v_board.id),
    (v_task_result->'task'->>'id')::uuid,
    'a4450000-0000-4000-8000-000000000001'
  );
END;
$$;
COMMIT;
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, collaborator_id, 'collaborator' FROM public.issue44_import_fixture;
INSERT INTO public.task_attachments(
  id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
  size_bytes, sha256, object_key, state
)
SELECT old_attachment_id, board_id, old_task_id, owner_id,
  'a4460000-0000-4000-8000-000000000001', 'previo.txt', 5,
  extensions.digest(convert_to('prior', 'UTF8'), 'sha256'),
  'attachments/issue44-synthetic-prior', 'active'
FROM public.issue44_import_fixture;
INSERT INTO public.board_labels(
  id, board_id, generation_id, name, color, created_by
)
SELECT 'a4470000-0000-4000-8000-000000000001', board_id,
  old_generation_id, 'operación', 'red', owner_id
FROM public.issue44_import_fixture;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture public.issue44_import_fixture%ROWTYPE;
  v_manifest jsonb;
  v_files jsonb;
  v_board jsonb;
  v_columns jsonb;
  v_tasks jsonb;
  v_comments jsonb;
  v_labels jsonb;
  v_task_labels jsonb;
  v_birthdays jsonb;
  v_birthday_labels jsonb;
  v_repetitions jsonb;
  v_repetition_labels jsonb;
  v_occurrences jsonb;
  v_activity jsonb;
  v_attachments jsonb;
  v_result jsonb;
  v_operation uuid := 'a4440000-0000-4000-8000-000000000001';
  v_digest text := repeat('a', 64);
  v_attachment_sha text := '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
  v_recent_at timestamptz := pg_catalog.clock_timestamp() - interval '30 days';
  v_revision bigint;
BEGIN
  SELECT * INTO STRICT v_fixture FROM public.issue44_import_fixture;
  SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'path', file.path, 'content_type', file.content_type,
    'size_bytes', CASE WHEN file.path LIKE 'objects/%' THEN 4 ELSE 0 END,
    'sha256', CASE WHEN file.path LIKE 'objects/%' THEN v_attachment_sha ELSE v_digest END,
    'records', file.records
  ) ORDER BY file.ordinal)
  INTO v_files
  FROM (VALUES
    (1,'data/board.json','application/json',1),
    (2,'data/columns.ndjson','application/x-ndjson',1),
    (3,'data/tasks.ndjson','application/x-ndjson',2),
    (4,'data/comments.ndjson','application/x-ndjson',1),
    (5,'data/labels.ndjson','application/x-ndjson',1),
    (6,'data/task-labels.ndjson','application/x-ndjson',1),
    (7,'data/birthdays.ndjson','application/x-ndjson',1),
    (8,'data/birthday-labels.ndjson','application/x-ndjson',1),
    (9,'data/repetitions.ndjson','application/x-ndjson',2),
    (10,'data/repetition-labels.ndjson','application/x-ndjson',1),
    (11,'data/repetition-occurrences.ndjson','application/x-ndjson',3),
    (12,'data/activity.ndjson','application/x-ndjson',1),
    (13,'data/attachments.ndjson','application/x-ndjson',1),
    (14,'objects/attachment_' || repeat('e', 64) || '.txt','text/plain; charset=utf-8',NULL)
  ) AS file(ordinal, path, content_type, records);
  v_manifest := pg_catalog.jsonb_build_object(
    'format', 'openkanban-board', 'version', 2,
    'exported_at', pg_catalog.clock_timestamp()::text, 'schema_version', 1,
    'calendar', pg_catalog.jsonb_build_object('time_zone', 'America/Argentina/Buenos_Aires'),
    'normalization_version', 1,
    'identifiers', pg_catalog.jsonb_build_object('scope', 'package', 'grant_access', false),
    'compression', 'store', 'integrity', 'sha256', 'files', v_files
  );
  IF public.prepare_board_import_v2_p(
      v_fixture.slug, 'a4440000-0000-4000-8000-000000000010', v_digest,
      v_manifest || pg_catalog.jsonb_build_object('extra', true)
    )->>'status' <> 'invalid' THEN
    RAISE EXCEPTION 'v2 prepare accepted an unknown manifest key';
  END IF;
  IF public.prepare_board_import_v2_p(
      v_fixture.slug, 'a4440000-0000-4000-8000-000000000011', v_digest,
      pg_catalog.jsonb_set(
        v_manifest, '{exported_at}', to_jsonb(pg_catalog.repeat('x', 8000000))
      )
    )->>'status' <> 'invalid' THEN
    RAISE EXCEPTION 'v2 prepare accepted a manifest over its byte limit';
  END IF;
  IF public.prepare_board_import_v2_p(
      v_fixture.slug, 'a4440000-0000-4000-8000-000000000012', v_digest,
      pg_catalog.jsonb_set(
        pg_catalog.jsonb_set(v_manifest, '{files,0,size_bytes}', '110000000'::jsonb),
        '{files,1,size_bytes}', '110000000'::jsonb
      )
    )->>'status' <> 'invalid' THEN
    RAISE EXCEPTION 'v2 prepare accepted a declared file total over its byte limit';
  END IF;
  IF public.prepare_board_import_v2_p(
      v_fixture.slug, 'a4440000-0000-4000-8000-000000000013', v_digest,
      pg_catalog.jsonb_set(
        v_manifest, '{files,0,path}', to_jsonb('../board.json'::text)
      )
    )->>'status' <> 'invalid' THEN
    RAISE EXCEPTION 'v2 prepare accepted an unsafe manifest path';
  END IF;
  v_board := pg_catalog.jsonb_build_object(
    'id', 'board_' || repeat('1', 64), 'name', 'Respaldo completo',
    'time_zone', 'America/Argentina/Buenos_Aires',
    'created_at', '2025-01-01T00:00:00Z', 'updated_at', '2025-01-02T00:00:00Z'
  );
  v_columns := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'column_' || repeat('2', 64), 'title', 'Columna importada',
    'position', 0, 'created_at', '2025-01-01T00:00:00Z'
  ));
  v_tasks := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'task_' || repeat('3', 64), 'column_id', 'column_' || repeat('2', 64),
    'title', 'Tarea importada', 'description', 'Con una mención @anterior',
    'priority', 'high', 'position', 0, 'due_on', '2025-02-03',
    'is_completed', false, 'completed_at', NULL, 'steps', '[]'::jsonb,
    'created_at', '2025-01-01T00:00:00Z', 'updated_at', '2025-01-02T00:00:00Z',
    'assignee_ref', 'member_' || repeat('9', 64)
  ), pg_catalog.jsonb_build_object(
    'id', 'task_' || repeat('4', 64), 'column_id', 'column_' || repeat('2', 64),
    'title', 'Tarea de serie B', 'description', NULL,
    'priority', 'medium', 'position', 1, 'due_on', NULL,
    'is_completed', false, 'completed_at', NULL, 'steps', '[]'::jsonb,
    'created_at', '2025-01-01T00:00:00Z', 'updated_at', '2025-01-02T00:00:00Z',
    'assignee_ref', 'member_' || repeat('f', 64)
  ));
  v_comments := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'comment_' || repeat('5', 64), 'task_id', 'task_' || repeat('3', 64),
    'author_name', 'Ana importada', 'content', 'Mención @persona permanece como texto',
    'created_at', (v_recent_at - interval '1 day')::text, 'edited_at', NULL, 'version', 1
  ));
  v_labels := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'label_' || repeat('6', 64), 'name', 'Operación', 'color', 'blue',
    'created_at', '2025-01-01T00:00:00Z', 'updated_at', '2025-01-02T00:00:00Z'
  ));
  v_task_labels := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'task_id', 'task_' || repeat('3', 64), 'label_id', 'label_' || repeat('6', 64)
  ));
  v_birthdays := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'birthday_' || repeat('7', 64), 'name', 'Cumple sintético',
    'birth_month', 2, 'birth_day', 28, 'advance_days', 3,
    'created_at', '2025-01-01T00:00:00Z', 'updated_at', '2025-01-02T00:00:00Z'
  ));
  v_birthday_labels := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'birthday_id', 'birthday_' || repeat('7', 64), 'label_id', 'label_' || repeat('6', 64)
  ));
  v_repetitions := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'id', 'repetition_' || repeat('8', 64),
      'origin_task_id', 'task_' || repeat('3', 64), 'first_task_id', 'task_' || repeat('3', 64),
      'appearance_column_id', 'column_' || repeat('2', 64), 'rule', 'daily',
      'start_on', '2025-01-01', 'end_on', NULL, 'occurrence_limit', NULL,
      'consumed_count', 2, 'latest_occurrence_on', '2025-01-02',
      'current_occurrence_id', NULL, 'next_due_on', NULL, 'state', 'stopped',
      'calendar_pattern', pg_catalog.jsonb_build_object('frequency','daily','interval',1),
      'advance_days', 2,
      'template_snapshot', pg_catalog.jsonb_build_object(
        'title','Serie A','description',NULL,'priority','medium',
        'assignee_ref','member_' || repeat('9',64),'steps','[]'::jsonb,'redacted',false
      ),
      'created_at','2025-01-01T00:00:00Z','updated_at','2025-01-02T00:00:00Z',
      'stopped_at','2025-01-02T12:00:00Z'
    ),
    pg_catalog.jsonb_build_object(
      'id', 'repetition_' || repeat('9', 64),
      'origin_task_id', 'task_' || repeat('4', 64), 'first_task_id', 'task_' || repeat('4', 64),
      'appearance_column_id', 'column_' || repeat('2', 64), 'rule', 'daily',
      'start_on', '2025-01-01', 'end_on', NULL, 'occurrence_limit', NULL,
      'consumed_count', 1, 'latest_occurrence_on', '2025-01-01',
      'current_occurrence_id', 'occurrence_' || repeat('b',64),
      'next_due_on', '2025-01-02', 'state', 'active',
      'calendar_pattern', pg_catalog.jsonb_build_object('frequency','daily','interval',1),
      'advance_days', 0,
      'template_snapshot', pg_catalog.jsonb_build_object(
        'title','Serie B','description',NULL,'priority','high',
        'assignee_ref','member_' || repeat('f',64),'steps','[]'::jsonb,'redacted',false
      ),
      'created_at','2025-01-01T00:00:00Z','updated_at','2025-01-02T00:00:00Z',
      'stopped_at',NULL
    )
  );
  v_repetition_labels := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'series_id', 'repetition_' || repeat('9', 64), 'label_id', 'label_' || repeat('6', 64)
  ));
  v_occurrences := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'id','occurrence_' || repeat('a',64),'series_id','repetition_' || repeat('8',64),
      'occurrence_on','2025-01-01','task_id','task_' || repeat('3',64),'state','transferred',
      'due_on_override',NULL,'transferred_to_series_id','repetition_' || repeat('9',64),
      'created_at','2025-01-01T00:00:00Z'
    ),
    pg_catalog.jsonb_build_object(
      'id','occurrence_' || repeat('b',64),'series_id','repetition_' || repeat('9',64),
      'occurrence_on','2025-01-01','task_id','task_' || repeat('4',64),'state','current',
      'due_on_override',NULL,'transferred_to_series_id',NULL,'created_at','2025-01-01T00:00:00Z'
    ),
    pg_catalog.jsonb_build_object(
      'id','occurrence_' || repeat('c',64),'series_id','repetition_' || repeat('8',64),
      'occurrence_on','2025-01-02','task_id','task_' || repeat('3',64),'state','excluded',
      'due_on_override','2025-01-04','transferred_to_series_id',NULL,'created_at','2025-01-02T00:00:00Z'
    )
  );
  v_activity := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id','activity_' || repeat('d',64),'task_id','task_' || repeat('3',64),
    'actor_type','user','category','due_date','actor_name','Ana importada',
    'occurred_at',v_recent_at::text,'before_value','2025-02-02','after_value','2025-02-03'
  ));
  v_attachments := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id','attachment_' || repeat('e',64),'task_id','task_' || repeat('3',64),
    'file_name','nota.txt','size_bytes',4,'sha256',v_attachment_sha,
    'created_at','2025-01-02T00:00:00Z'
  ));
  UPDATE public.issue44_import_fixture
  SET source_manifest = v_manifest,
      board_record = v_board,
      column_records = v_columns,
      task_records = v_tasks,
      attachment_records = v_attachments;

  v_result := public.prepare_board_import_v2_p(v_fixture.slug, v_operation, v_digest, v_manifest);
  IF v_result->>'status' <> 'staging' THEN
    RAISE EXCEPTION 'v2 prepare did not start staging: %', v_result;
  END IF;
  IF public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'board', 0, jsonb_build_array(v_board))->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'columns', 0, v_columns)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'tasks', 0, v_tasks)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'comments', 0, v_comments)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'labels', 0, v_labels)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'task_labels', 0, v_task_labels)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'birthdays', 0, v_birthdays)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'birthday_labels', 0, v_birthday_labels)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'repetitions', 0, v_repetitions)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'repetition_labels', 0, v_repetition_labels)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'repetition_occurrences', 0, v_occurrences)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'activity', 0, v_activity)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'attachments', 0, v_attachments)->>'status' <> 'staging' THEN
    RAISE EXCEPTION 'v2 entity batches did not stage';
  END IF;
  IF public.stage_board_import_v2_batch_p(v_fixture.slug, v_operation, 'tasks', 0, v_tasks)->>'status' <> 'staging' THEN
    RAISE EXCEPTION 'an identical stage retry was not idempotent';
  END IF;
  IF (SELECT count(*) FROM public.get_tasks_by_board_p(v_fixture.board_id)) <> 1
    OR (SELECT active_generation_id FROM public.boards WHERE id = v_fixture.board_id) <> v_fixture.old_generation_id THEN
    RAISE EXCEPTION 'staged content became visible before pointer swap';
  END IF;
  v_result := public.reserve_board_import_v2_p(v_fixture.slug, v_operation);
  IF v_result->>'status' <> 'reserved' OR jsonb_array_length(v_result->'targets') <> 1
    OR (v_result->'targets'->0->>'object_key') <> 'attachments/' || (v_result->'targets'->0->>'attachment_id') THEN
    RAISE EXCEPTION 'v2 content was not materialized as an invisible generation: %', v_result;
  END IF;
  UPDATE public.issue44_import_fixture
  SET new_attachment_id = (v_result->'targets'->0->>'attachment_id')::uuid;
  IF public.reserve_board_import_v2_p(v_fixture.slug, v_operation)->>'status' <> 'reserved' THEN
    RAISE EXCEPTION 'v2 reservation retry was not idempotent';
  END IF;
END;
$$;
COMMIT;

CREATE FUNCTION public.issue44_try_unsafe_update(p_operation_id uuid, p_source_ref text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_task_id uuid;
BEGIN
  SELECT reference.destination_id INTO STRICT v_task_id
  FROM public.board_import_v2_refs AS reference
  WHERE reference.operation_id = p_operation_id
    AND reference.source_ref = p_source_ref
    AND reference.ref_kind = 'task';
  UPDATE public.tasks
  SET assignee_version = assignee_version + 1
  WHERE id = v_task_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.issue44_try_unsafe_update(uuid, text) TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.issue44_try_unsafe_update(
      'a4440000-0000-4000-8000-000000000001', 'task_' || repeat('3', 64)
    );
    RAISE EXCEPTION 'direct task update changed a preparing v2 generation';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END;
$$;
COMMIT;

UPDATE public.application_access
SET state = 'suspended'
WHERE auth_user_id = 'a4400000-0000-4000-8000-000000000001';
BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  result := public.mark_board_import_v2_object_uploaded_p(
    'a4400000-0000-4000-8000-000000000003',
    'a4440000-0000-4000-8000-000000000001', fixture.new_attachment_id, 4,
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
  );
  IF result->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'a forged actor was allowed to acknowledge a Storage upload: %', result;
  END IF;
  result := public.mark_board_import_v2_object_uploaded_p(
    fixture.collaborator_id, 'a4440000-0000-4000-8000-000000000001',
    fixture.new_attachment_id, 4,
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
  );
  IF result->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'a non-owner collaborator was allowed to acknowledge a Storage upload: %', result;
  END IF;
  result := public.mark_board_import_v2_object_uploaded_p(
    fixture.owner_id, 'a4440000-0000-4000-8000-000000000001',
    fixture.new_attachment_id, 4,
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
  );
  IF result->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'a disabled owner was allowed to acknowledge a Storage upload: %', result;
  END IF;
END;
$$;
COMMIT;
UPDATE public.application_access
SET state = 'active'
WHERE auth_user_id = 'a4400000-0000-4000-8000-000000000001';

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  result := public.mark_board_import_v2_object_uploaded_p(
    fixture.owner_id, 'a4440000-0000-4000-8000-000000000001',
    fixture.new_attachment_id, 4,
    '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'
  );
  IF result->>'status' <> 'uploaded' THEN
    RAISE EXCEPTION 'service-role Storage upload acknowledgement was rejected: %', result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture public.issue44_import_fixture%ROWTYPE;
  v_result jsonb;
  v_decisions jsonb := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'source_ref', 'member_' || repeat('9', 64),
      'target_user_id', 'a4400000-0000-4000-8000-000000000002'
    ),
    pg_catalog.jsonb_build_object(
      'source_ref', 'member_' || repeat('f', 64),
      'target_user_id', NULL
    )
  );
  v_label_decisions jsonb := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'source_ref', 'label_' || repeat('6', 64), 'name', 'Operación importada'
    )
  );
  v_label_decisions_after jsonb := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'source_ref', 'label_' || repeat('6', 64), 'name', 'Operación reimportada'
    )
  );
  v_operation uuid := 'a4440000-0000-4000-8000-000000000001';
  v_digest text := repeat('a', 64);
  v_revision bigint;
BEGIN
  SELECT * INTO STRICT v_fixture FROM public.issue44_import_fixture;
  v_result := public.finalize_board_import_v2_p(v_fixture.slug, v_operation);
  IF v_result->>'status' <> 'label_conflict'
    OR jsonb_array_length(v_result->'label_conflicts') <> 1
    OR jsonb_array_length(v_result->'member_refs') <> 2
    OR jsonb_array_length(v_result->'members') <> 2
    OR v_result->'imported'->>'labels' <> '1' THEN
    RAISE EXCEPTION 'label collision did not hold publication with member decisions visible: %', v_result;
  END IF;
  v_result := public.set_board_import_v2_label_resolutions_p(
    v_fixture.slug, v_operation, v_label_decisions,
    pg_catalog.jsonb_set(
      v_decisions, '{0,target_user_id}',
      to_jsonb('a4400000-0000-4000-8000-000000000003'::text)
    )
  );
  IF v_result->>'status' <> 'member_conflict' THEN
    RAISE EXCEPTION 'a non-member was accepted as a destination assignee: %', v_result;
  END IF;
  v_result := public.set_board_import_v2_label_resolutions_p(
    v_fixture.slug, v_operation,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'source_ref', 'label_' || repeat('6', 64), 'name', 'operación'
    )),
    v_decisions
  );
  IF v_result->>'status' <> 'label_conflict'
    OR jsonb_array_length(v_result->'label_conflicts') <> 1 THEN
    RAISE EXCEPTION 'a normalized duplicate label name was silently accepted: %', v_result;
  END IF;
  v_result := public.set_board_import_v2_label_resolutions_p(
    v_fixture.slug, v_operation, v_label_decisions, v_decisions
  );
  IF v_result->>'status' <> 'saved' THEN
    RAISE EXCEPTION 'explicit member and label decisions were not saved: %', v_result;
  END IF;
  v_result := public.set_board_import_v2_label_resolutions_p(
    v_fixture.slug, v_operation, v_label_decisions, v_decisions
  );
  IF v_result->>'status' <> 'saved' THEN
    RAISE EXCEPTION 'retry of saved member and label decisions was not idempotent: %', v_result;
  END IF;
  v_result := public.finalize_board_import_v2_p(v_fixture.slug, v_operation);
  IF v_result->>'status' <> 'prepared' OR v_result->>'source_version' <> '2'
    OR v_result->>'time_zone' <> 'America/Argentina/Buenos_Aires'
    OR v_result->'imported'->>'tasks' <> '2'
    OR v_result->'imported'->>'comments' <> '1'
    OR v_result->'imported'->>'labels' <> '1'
    OR v_result->'imported'->>'birthdays' <> '1'
    OR v_result->'imported'->>'series' <> '2'
    OR v_result->'imported'->>'attachments' <> '1'
    OR v_result->'capacity'->>'used_bytes' <> '9'
    OR v_result->'member_mappings'->0->>'target_user_id' <> 'a4400000-0000-4000-8000-000000000002'
    OR (SELECT active_generation_id FROM public.boards WHERE id = v_fixture.board_id) <> v_fixture.old_generation_id THEN
    RAISE EXCEPTION 'v2 preview changed visible content, lost package data or miscounted quota: %', v_result;
  END IF;
  v_revision := (v_result->>'content_revision')::bigint;
  UPDATE public.issue44_import_fixture
  SET content_revision = v_revision;
  IF public.confirm_board_import_v2_p(
    v_fixture.slug, v_operation, v_revision, v_digest, '[]'::jsonb
  )->>'status' <> 'member_mapping_required'
    OR (SELECT active_generation_id FROM public.boards WHERE id = v_fixture.board_id)
      <> v_fixture.old_generation_id THEN
    RAISE EXCEPTION 'v2 publication accepted a missing assignment decision or changed the pointer';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  result jsonb;
  v_revision bigint;
  decisions jsonb := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'source_ref', 'member_' || repeat('9', 64),
      'target_user_id', 'a4400000-0000-4000-8000-000000000002'
    ),
    pg_catalog.jsonb_build_object(
      'source_ref', 'member_' || repeat('f', 64), 'target_user_id', NULL
    )
  );
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  v_revision := fixture.content_revision;
  result := public.finalize_board_import_v2_p(
    fixture.slug, 'a4440000-0000-4000-8000-000000000001'
  );
  IF result->>'status' <> 'prepared' THEN
    RAISE EXCEPTION 'a current prepared preview could not be refreshed: %', result;
  END IF;
  v_revision := (result->>'content_revision')::bigint;
  UPDATE public.issue44_import_fixture
  SET content_revision = v_revision;
  result := public.confirm_board_import_v2_p(
    fixture.slug, 'a4440000-0000-4000-8000-000000000001', v_revision,
    repeat('a', 64), decisions
  );
  IF result->>'status' <> 'confirmed'
    OR (SELECT name FROM public.boards WHERE id = fixture.board_id) <> 'Respaldo completo'
    OR (SELECT time_zone FROM public.boards WHERE id = fixture.board_id) <> 'America/Argentina/Buenos_Aires'
    OR (SELECT count(*) FROM public.get_tasks_by_board_p(fixture.board_id)) <> 2
    OR (SELECT count(*) FROM public.get_tasks_by_board_p(fixture.board_id) WHERE title IN ('Tarea importada', 'Tarea de serie B')) <> 2
    OR (SELECT count(*) FROM public.list_board_members_p(fixture.slug)) <> 2
    OR (SELECT owner_id FROM public.boards WHERE id = fixture.board_id) <> fixture.owner_id THEN
    RAISE EXCEPTION 'v2 confirmation did not atomically publish package content and metadata: %', result;
  END IF;
  UPDATE public.issue44_import_fixture
  SET published_generation_id = (
    SELECT board.active_generation_id FROM public.boards AS board WHERE board.id = fixture.board_id
  );
  IF public.confirm_board_import_v2_p(
    fixture.slug, 'a4440000-0000-4000-8000-000000000001', v_revision,
    repeat('a', 64), decisions
  )->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'v2 confirmation retry was not idempotent';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  operation_id uuid := 'a4440000-0000-4000-8000-000000000003';
  source_sha text := repeat('b', 64);
  empty_sha text := 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  files jsonb;
  manifest jsonb;
  board_record jsonb := pg_catalog.jsonb_build_object(
    'id', 'board_' || repeat('a', 64), 'name', 'Edición posterior',
    'time_zone', 'UTC', 'created_at', '2025-01-01T00:00:00Z',
    'updated_at', '2025-01-02T00:00:00Z'
  );
  column_records jsonb := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'column_' || repeat('c', 64), 'title', 'Columna de control',
    'position', 0, 'created_at', '2025-01-01T00:00:00Z'
  ));
  result jsonb;
  labels jsonb;
  label_id uuid;
  label_version bigint;
  revision bigint;
  active_generation uuid;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  SELECT board.active_generation_id INTO active_generation
  FROM public.boards AS board WHERE board.id = fixture.board_id;
  files := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object('path','data/board.json','size_bytes',1,'sha256',source_sha,'content_type','application/json','records',1),
    pg_catalog.jsonb_build_object('path','data/columns.ndjson','size_bytes',1,'sha256',source_sha,'content_type','application/x-ndjson','records',1),
    pg_catalog.jsonb_build_object('path','data/tasks.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/comments.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/labels.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/task-labels.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/birthdays.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/birthday-labels.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/repetitions.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/repetition-labels.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/repetition-occurrences.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/activity.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0),
    pg_catalog.jsonb_build_object('path','data/attachments.ndjson','size_bytes',0,'sha256',empty_sha,'content_type','application/x-ndjson','records',0)
  );
  manifest := pg_catalog.jsonb_build_object(
    'format','openkanban-board','version',2,'exported_at','2025-01-02T00:00:00Z',
    'schema_version',1,'normalization_version',1,'compression','store','integrity','sha256',
    'calendar',pg_catalog.jsonb_build_object('time_zone','UTC'),
    'identifiers',pg_catalog.jsonb_build_object('scope','package','grant_access',false),
    'files',files
  );
  result := public.prepare_board_import_v2_p(fixture.slug, operation_id, source_sha, manifest);
  IF result->>'status' <> 'staging' THEN
    RAISE EXCEPTION 'second synthetic import did not stage for stale-preview check: %', result;
  END IF;
  IF public.stage_board_import_v2_batch_p(fixture.slug, operation_id, 'board', 0,
      pg_catalog.jsonb_build_array(board_record))->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation_id, 'columns', 0,
      column_records)->>'status' <> 'staging' THEN
    RAISE EXCEPTION 'second synthetic import records did not stage';
  END IF;
  result := public.reserve_board_import_v2_p(fixture.slug, operation_id);
  IF result->>'status' <> 'reserved' OR pg_catalog.jsonb_array_length(result->'targets') <> 0 THEN
    RAISE EXCEPTION 'empty-object control import did not reserve cleanly: %', result;
  END IF;
  result := public.finalize_board_import_v2_p(fixture.slug, operation_id);
  IF result->>'status' <> 'prepared' THEN
    RAISE EXCEPTION 'second synthetic import did not prepare for stale-preview check: %', result;
  END IF;
  revision := (result->>'content_revision')::bigint;
  labels := public.list_board_labels_p(fixture.slug)->'labels';
  label_id := (labels->0->>'id')::uuid;
  label_version := (labels->0->>'version')::bigint;
  result := public.update_board_label_p(
    fixture.slug, label_id, label_version, 'Operación reimportada', 'red'
  );
  IF result->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'synthetic active-board edit failed after second preview: %', result;
  END IF;
  result := public.confirm_board_import_v2_p(
    fixture.slug, operation_id, revision, source_sha, '[]'::jsonb
  );
  IF result->>'status' <> 'conflict'
    OR (SELECT board.active_generation_id FROM public.boards AS board WHERE board.id = fixture.board_id)
      <> active_generation THEN
    RAISE EXCEPTION 'confirmation did not reject a stale preview after a real edit: %', result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  operation_id uuid := 'a4440000-0000-4000-8000-000000000004';
  source_sha text := repeat('c', 64);
  empty_sha text := 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
  manifest jsonb;
  files jsonb;
  board_record jsonb := pg_catalog.jsonb_build_object(
    'id', 'board_' || repeat('d', 64), 'name', 'Revalidación de miembros',
    'time_zone', 'UTC', 'created_at', '2025-01-01T00:00:00Z',
    'updated_at', '2025-01-02T00:00:00Z'
  );
  column_records jsonb := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'column_' || repeat('e', 64), 'title', 'Columna de mapeo',
    'position', 0, 'created_at', '2025-01-01T00:00:00Z'
  ));
  task_records jsonb := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'id', 'task_' || repeat('f', 64), 'column_id', 'column_' || repeat('e', 64),
    'title', 'Tarea asignada de control', 'description', NULL, 'priority', 'medium',
    'position', 0, 'due_on', NULL, 'is_completed', false, 'completed_at', NULL,
    'steps', '[]'::jsonb, 'created_at', '2025-01-01T00:00:00Z',
    'updated_at', '2025-01-02T00:00:00Z', 'assignee_ref', 'member_' || repeat('9', 64)
  ));
  result jsonb;
  revision bigint;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  SELECT pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'path', file.value->>'path',
      'size_bytes', CASE WHEN file.value->>'path' IN (
        'data/board.json', 'data/columns.ndjson', 'data/tasks.ndjson'
      ) THEN 1 ELSE 0 END,
      'sha256', CASE WHEN file.value->>'path' IN (
        'data/board.json', 'data/columns.ndjson', 'data/tasks.ndjson'
      ) THEN source_sha ELSE empty_sha END,
      'content_type', file.value->>'content_type',
      'records', CASE file.value->>'path'
        WHEN 'data/board.json' THEN 1
        WHEN 'data/columns.ndjson' THEN 1
        WHEN 'data/tasks.ndjson' THEN 1
        ELSE 0 END
    ) ORDER BY file.ordinality
  ) INTO files
  FROM pg_catalog.jsonb_array_elements(fixture.source_manifest->'files')
    WITH ORDINALITY AS file(value, ordinality)
  WHERE file.value->>'path' NOT LIKE 'objects/%';
  manifest := pg_catalog.jsonb_build_object(
    'format','openkanban-board','version',2,'exported_at','2025-01-02T00:00:00Z',
    'schema_version',1,'normalization_version',1,'compression','store','integrity','sha256',
    'calendar',pg_catalog.jsonb_build_object('time_zone','UTC'),
    'identifiers',pg_catalog.jsonb_build_object('scope','package','grant_access',false),
    'files',files
  );
  result := public.prepare_board_import_v2_p(fixture.slug, operation_id, source_sha, manifest);
  IF result->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation_id, 'board', 0,
      pg_catalog.jsonb_build_array(board_record))->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation_id, 'columns', 0,
      column_records)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation_id, 'tasks', 0,
      task_records)->>'status' <> 'staging' THEN
    RAISE EXCEPTION 'member-revalidation operation did not stage: %', result;
  END IF;
  result := public.reserve_board_import_v2_p(fixture.slug, operation_id);
  IF result->>'status' <> 'reserved' THEN
    RAISE EXCEPTION 'member-revalidation operation did not reserve: %', result;
  END IF;
  result := public.finalize_board_import_v2_p(fixture.slug, operation_id);
  IF result->>'status' <> 'prepared' OR jsonb_array_length(result->'member_refs') <> 1 THEN
    RAISE EXCEPTION 'member-revalidation operation did not prepare the assignee ref: %', result;
  END IF;
  revision := (result->>'content_revision')::bigint;
  UPDATE public.issue44_import_fixture SET content_revision = revision;
END;
$$;
COMMIT;

UPDATE public.board_memberships AS membership
SET revoked_at = pg_catalog.clock_timestamp()
FROM public.issue44_import_fixture AS fixture
WHERE membership.board_id = fixture.board_id
  AND membership.user_id = fixture.collaborator_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  result := public.confirm_board_import_v2_p(
    fixture.slug, 'a4440000-0000-4000-8000-000000000004', fixture.content_revision,
    repeat('c', 64), pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'source_ref', 'member_' || repeat('9', 64), 'target_user_id', fixture.collaborator_id
    ))
  );
  IF result->>'status' <> 'member_conflict'
    OR (SELECT board.active_generation_id FROM public.boards AS board WHERE board.id = fixture.board_id)
      <> fixture.published_generation_id THEN
    RAISE EXCEPTION 'confirmation accepted an assignee whose board membership was revoked: %', result;
  END IF;
  result := public.cancel_board_import_v2_p(
    fixture.slug, 'a4440000-0000-4000-8000-000000000004'
  );
  IF result->>'status' <> 'cancelled' THEN
    RAISE EXCEPTION 'member-revalidation staging did not clean up: %', result;
  END IF;
END;
$$;
COMMIT;

UPDATE public.board_memberships AS membership
SET revoked_at = NULL
FROM public.issue44_import_fixture AS fixture
WHERE membership.board_id = fixture.board_id
  AND membership.user_id = fixture.collaborator_id;

DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  imported_generation uuid;
  new_attachment public.task_attachments%ROWTYPE;
  old_attachment public.task_attachments%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  SELECT active_generation_id INTO imported_generation FROM public.boards WHERE id = fixture.board_id;
  SELECT * INTO STRICT new_attachment FROM public.task_attachments WHERE id = fixture.new_attachment_id;
  SELECT * INTO STRICT old_attachment FROM public.task_attachments WHERE id = fixture.old_attachment_id;
  IF new_attachment.state <> 'active'
    OR new_attachment.object_key <> 'attachments/' || fixture.new_attachment_id::text
    OR new_attachment.size_bytes <> 4
    OR old_attachment.state <> 'active'
    OR (SELECT active_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 9
    OR (SELECT recoverable_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 0
    OR (SELECT reserved_bytes + pending_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 0 THEN
    RAISE EXCEPTION 'v2 upload acknowledgement or retained-generation quota is wrong';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.task_comments AS comment
      JOIN public.tasks AS task ON task.id = comment.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.generation_id = imported_generation
        AND comment.author_id IS NULL
        AND comment.author_name = 'Autor importado: Ana importada'
        AND comment.content = 'Mención @persona permanece como texto'
    ) OR EXISTS (
      SELECT 1 FROM public.task_comment_mentions AS mention
      JOIN public.task_comments AS comment ON comment.id = mention.comment_id
      JOIN public.tasks AS task ON task.id = comment.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.generation_id = imported_generation
    ) THEN
    RAISE EXCEPTION 'imported comment attribution or mention text was changed';
  END IF;
  IF (SELECT count(*) FROM public.board_labels WHERE generation_id = imported_generation AND deleted_at IS NULL) <> 1
    OR (SELECT count(*) FROM public.board_label_task_assignments WHERE generation_id = imported_generation) <> 1
    OR (SELECT count(*) FROM public.board_birthdays WHERE generation_id = imported_generation) <> 1
    OR (SELECT count(*) FROM public.board_label_birthday_assignments WHERE generation_id = imported_generation) <> 1
    OR (SELECT count(*) FROM public.board_label_repetition_assignments WHERE generation_id = imported_generation) <> 1 THEN
    RAISE EXCEPTION 'v2 label, birthday, or series-label relationships were not preserved';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.board_labels AS imported
      WHERE imported.generation_id = imported_generation
        AND imported.name = 'Operación reimportada'
        AND imported.id <> 'a4470000-0000-4000-8000-000000000001'
    ) OR (SELECT name FROM public.board_labels
        WHERE id = 'a4470000-0000-4000-8000-000000000001') <> 'operación'
    OR (SELECT task.assignee_id FROM public.tasks AS task
        WHERE task.title = 'Tarea importada') <> fixture.collaborator_id
    OR (SELECT task.assignee_id FROM public.tasks AS task
        WHERE task.title = 'Tarea de serie B') IS NOT NULL
    OR (SELECT series.template_snapshot->>'assignee_id'
        FROM public.daily_repetition_series AS series
        WHERE series.generation_id = imported_generation AND series.state = 'stopped')
        <> fixture.collaborator_id::text
    OR (SELECT series.template_snapshot->>'assignee_id'
        FROM public.daily_repetition_series AS series
        WHERE series.generation_id = imported_generation AND series.state = 'active') IS NOT NULL THEN
    RAISE EXCEPTION 'explicit label rename or member assignment mapping was not preserved';
  END IF;
  IF NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_series AS series
      WHERE series.generation_id = imported_generation AND series.state = 'stopped'
        AND series.stopped_at IS NOT NULL AND series.next_due_on IS NULL
    ) OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
      WHERE series.generation_id = imported_generation AND occurrence.state = 'excluded'
    ) OR NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
      JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
      JOIN public.daily_repetition_series AS destination
        ON destination.id = occurrence.transferred_to_series_id
      WHERE series.generation_id = imported_generation AND occurrence.state = 'transferred'
        AND destination.generation_id = imported_generation
    ) OR (SELECT count(*) FROM public.daily_repetition_jobs AS job
      JOIN public.daily_repetition_series AS series ON series.id = job.series_id
      WHERE series.generation_id = imported_generation AND job.job_kind = 'advance') <> 1 THEN
    RAISE EXCEPTION 'calendar exclusions, stopped/transferred history, or no-backlog scheduling failed';
  END IF;
  IF (SELECT count(*) FROM public.task_activity_events AS event
      JOIN public.tasks AS task ON task.id = event.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.generation_id = imported_generation
        AND event.actor_type = 'imported' AND event.actor_name = 'Ana importada') <> 1
    OR EXISTS (
      SELECT 1 FROM public.task_notifications AS notice
      JOIN public.tasks AS task ON task.id = notice.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.generation_id = imported_generation
    ) THEN
    RAISE EXCEPTION 'recent E05 attribution was not imported safely or generated old notices';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  manifest jsonb;
  result jsonb;
  operation uuid := 'a4440000-0000-4000-8000-000000000002';
  source_hash text := repeat('b', 64);
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  SELECT pg_catalog.jsonb_set(
    fixture.source_manifest,
    '{files}',
    (SELECT pg_catalog.jsonb_agg(
      CASE
        WHEN file.value->>'path' IN ('data/board.json','data/columns.ndjson')
          THEN pg_catalog.jsonb_set(file.value, '{records}', '1'::jsonb)
        WHEN file.value->>'path' = 'data/tasks.ndjson'
          THEN pg_catalog.jsonb_set(file.value, '{records}', '2'::jsonb)
        WHEN file.value->>'path' = 'data/attachments.ndjson'
          THEN pg_catalog.jsonb_set(file.value, '{records}', '1'::jsonb)
        WHEN file.value->>'path' LIKE 'objects/%'
          THEN file.value
        ELSE pg_catalog.jsonb_set(file.value, '{records}', '0'::jsonb)
      END ORDER BY file.ordinality
    ) FROM pg_catalog.jsonb_array_elements(fixture.source_manifest->'files')
      WITH ORDINALITY AS file(value, ordinality))
  ) INTO manifest;
  result := public.prepare_board_import_v2_p(
    fixture.slug, operation, source_hash, manifest
  );
  IF result->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation, 'board', 0,
      jsonb_build_array(fixture.board_record))->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation, 'columns', 0,
      fixture.column_records)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation, 'tasks', 0,
      fixture.task_records)->>'status' <> 'staging'
    OR public.stage_board_import_v2_batch_p(fixture.slug, operation, 'attachments', 0,
      fixture.attachment_records)->>'status' <> 'staging' THEN
    RAISE EXCEPTION 'synthetic failure operation did not stage';
  END IF;
  result := public.reserve_board_import_v2_p(fixture.slug, operation);
  IF result->>'status' <> 'reserved' OR jsonb_array_length(result->'targets') <> 1
    OR result->'targets'->0->>'uploaded' <> 'false' THEN
    RAISE EXCEPTION 'synthetic failure operation did not reserve the object: %', result;
  END IF;
  UPDATE public.issue44_import_fixture
  SET cancel_attachment_id = (result->'targets'->0->>'attachment_id')::uuid;
  result := public.cancel_board_import_v2_p(fixture.slug, operation);
  IF result->>'status' <> 'cancelled' OR jsonb_array_length(result->'objects') <> 1 THEN
    RAISE EXCEPTION 'v2 cancellation did not return the pending Storage cleanup target: %', result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE fixture public.issue44_import_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  IF (SELECT state FROM public.task_attachments WHERE id = fixture.cancel_attachment_id) <> 'cleanup_pending'
    OR (SELECT pending_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 4 THEN
    RAISE EXCEPTION 'an unacknowledged Storage cleanup released metadata or quota';
  END IF;
END;
$$;

UPDATE public.application_access
SET state = 'suspended'
WHERE auth_user_id = 'a4400000-0000-4000-8000-000000000001';
BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  result := public.complete_board_import_v2_object_cleanup_p(
    fixture.owner_id, 'a4440000-0000-4000-8000-000000000002',
    fixture.cancel_attachment_id
  );
  IF result->>'status' <> 'cleaned' THEN
    RAISE EXCEPTION 'Storage cleanup acknowledgement failed after identity suspension: %', result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE fixture public.issue44_import_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  IF EXISTS (SELECT 1 FROM public.task_attachments WHERE id = fixture.cancel_attachment_id)
    OR (SELECT pending_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 0
    OR (SELECT active_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 9
    OR (SELECT recoverable_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 0 THEN
    RAISE EXCEPTION 'confirmed cleanup acknowledgement did not release only pending bytes';
  END IF;
END;
$$;

DROP TABLE public.issue44_import_fixture;
\echo 'PASS: v2 preserves all content relationships/history, reserves objects before publication, and swaps metadata/pointer atomically.'
