\set ON_ERROR_STOP on
\echo 'Issue #37 tracer: confirmed assignment becomes one authorized inbox item'

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES
  ('43700000-0000-4000-8000-000000000002', 'issue37-owner@example.test', now(), '{"provider":"google"}'),
  ('43700000-0000-4000-8000-000000000003', 'issue37-recipient@example.test', now(), '{"provider":"google"}'),
  ('43700000-0000-4000-8000-000000000004', 'issue37-third@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES
  ('53700000-0000-4000-8000-000000000002', '43700000-0000-4000-8000-000000000002', 'google', 'issue37-owner', '{"email":"issue37-owner@example.test","name":"Persona autora","email_verified":true}'),
  ('53700000-0000-4000-8000-000000000003', '43700000-0000-4000-8000-000000000003', 'google', 'issue37-recipient', '{"email":"issue37-recipient@example.test","name":"Persona destinataria","email_verified":true}'),
  ('53700000-0000-4000-8000-000000000004', '43700000-0000-4000-8000-000000000004', 'google', 'issue37-third', '{"email":"issue37-third@example.test","name":"Persona terciaria","email_verified":true}');
INSERT INTO public.application_access (email, auth_user_id, google_subject, state)
VALUES
  ('issue37-owner@example.test', '43700000-0000-4000-8000-000000000002', 'issue37-owner', 'active'),
  ('issue37-recipient@example.test', '43700000-0000-4000-8000-000000000003', 'issue37-recipient', 'active'),
  ('issue37-third@example.test', '43700000-0000-4000-8000-000000000004', 'issue37-third', 'active');

CREATE TEMP TABLE issue37_notification_fixture (
  purpose text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  comment_id uuid,
  notice_id uuid,
  stale_notice_id uuid,
  generated_task_id uuid,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON issue37_notification_fixture TO authenticated, service_role;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p('Issue 37 novedades', 'UTC', gen_random_uuid());
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Pendiente', 0);
  v_task := public.create_task_p(
    gen_random_uuid(), v_board.id, v_column.id, 'Tarea asignada'
  );
  INSERT INTO issue37_notification_fixture(
    purpose, board_id, board_slug, column_id, task_id, operation_id
  ) VALUES (
    'assignment', v_board.id, v_board.slug, v_column.id,
    (v_task->>'task_id')::uuid, gen_random_uuid()
  );
END;
$$;
COMMIT;
RESET ROLE;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT board_id, '43700000-0000-4000-8000-000000000003', 'collaborator'
FROM issue37_notification_fixture WHERE purpose = 'assignment';
INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT board_id, '43700000-0000-4000-8000-000000000004', 'collaborator'
FROM issue37_notification_fixture WHERE purpose = 'assignment';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_result := public.set_task_assignee_p(
    v_fixture.operation_id,
    v_fixture.board_slug,
    v_fixture.task_id,
    '43700000-0000-4000-8000-000000000003',
    1
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The assignment mutation did not confirm: %', v_result;
  END IF;
  PERFORM public.set_task_assignee_p(
    v_fixture.operation_id,
    v_fixture.board_slug,
    v_fixture.task_id,
    '43700000-0000-4000-8000-000000000003',
    1
  );
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.process_task_notification_jobs_p(20);
  IF v_result->>'status' IS DISTINCT FROM 'processed' THEN
    RAISE EXCEPTION 'The notification outbox did not process: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_items jsonb;
  v_target jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  v_items := v_page->'items';
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_items) <> 1
    OR NOT (v_items->0->'reason_codes' ? 'assignment')
    OR v_items->0->>'task_title' IS DISTINCT FROM 'Tarea asignada'
    OR v_items->0->>'read_at' IS NOT NULL THEN
    RAISE EXCEPTION 'The current assignee should see one unread assignment notice: %', v_page;
  END IF;
  v_target := public.get_my_task_notification_target_p((v_items->0->>'id')::uuid);
  IF v_target->>'status' IS DISTINCT FROM 'available'
    OR v_target->>'slug' IS DISTINCT FROM v_fixture.board_slug
    OR v_target->>'task_id' IS DISTINCT FROM v_fixture.task_id::text
    OR v_target->>'comment_id' IS NOT NULL THEN
    RAISE EXCEPTION 'Opening a current notice should resolve its private task destination: %', v_target;
  END IF;
  UPDATE issue37_notification_fixture
  SET notice_id = (v_items->0->>'id')::uuid
  WHERE purpose = 'assignment';
  IF public.mark_my_task_notification_read_p((v_items->0->>'id')::uuid)->>'status'
    IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Marking an authorized notice as read should confirm';
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_target jsonb;
  v_mark jsonb;
  v_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_target := public.get_my_task_notification_target_p(v_fixture.notice_id);
  v_mark := public.mark_my_task_notification_read_p(v_fixture.notice_id);
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  IF v_target->>'status' IS DISTINCT FROM 'unavailable'
    OR v_mark->>'status' IS DISTINCT FROM 'unavailable'
    OR jsonb_array_length(v_page->'items') <> 0 THEN
    RAISE EXCEPTION 'Another board member must not inspect or mark a private notification: target %, mark %, list %',
      v_target, v_mark, v_page;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_comment jsonb;
  v_edited jsonb;
  v_mentions jsonb := jsonb_build_array(jsonb_build_object(
    'user_id', '43700000-0000-4000-8000-000000000003',
    'start_char', 5,
    'length_chars', 21
  ));
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_result := public.edit_task_fields_p(
    gen_random_uuid(), v_fixture.board_slug, v_fixture.task_id,
    '{"due_on":"2026-12-25"}'::jsonb,
    '{"due_on":1}'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Changing the due date should be confirmed: %', v_result;
  END IF;

  v_comment := public.create_task_comment_p(
    '63700000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    'Hola @Persona destinataria',
    v_mentions
  );
  IF v_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Creating a comment with a mention should be confirmed: %', v_comment;
  END IF;
  UPDATE issue37_notification_fixture
  SET comment_id = (v_comment->>'comment_id')::uuid
  WHERE purpose = 'assignment';

  v_edited := public.edit_task_comment_p(
    '63700000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    (v_comment->>'comment_id')::uuid,
    1,
    'Hola, corregí el texto.',
    '[]'::jsonb
  );
  IF v_edited->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Correcting the comment should be confirmed: %', v_edited;
  END IF;
  v_edited := public.edit_task_comment_p(
    '63700000-0000-4000-8000-000000000003',
    v_fixture.board_slug,
    (v_comment->>'comment_id')::uuid,
    2,
    'Hola @Persona destinataria',
    v_mentions
  );
  IF v_edited->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Restoring a removed mention should be confirmed: %', v_edited;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

CREATE SEQUENCE public.issue37_notification_delivery_failures;
CREATE FUNCTION public.issue37_fail_first_notification_delivery_tg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.state = 'delivered'
    AND pg_catalog.nextval('public.issue37_notification_delivery_failures') = 1 THEN
    RAISE EXCEPTION 'Synthetic notification delivery failure' USING ERRCODE = '40001';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER issue37_fail_first_notification_delivery
  BEFORE UPDATE ON public.task_notifications
  FOR EACH ROW EXECUTE FUNCTION public.issue37_fail_first_notification_delivery_tg();

DO $$
DECLARE
  v_result jsonb;
  v_retry_count integer;
  v_delivered_count integer;
BEGIN
  v_result := public.process_task_notification_jobs_internal_p(
    20, clock_timestamp(), NULL
  );
  v_retry_count := (v_result->>'retry_wait')::integer;
  v_delivered_count := (v_result->>'delivered')::integer;
  IF v_result->>'status' IS DISTINCT FROM 'processed'
    OR v_retry_count <> 1 OR v_delivered_count <> 1 THEN
    RAISE EXCEPTION 'A transient worker failure should retain one retry and deliver the other item: %', v_result;
  END IF;
END;
$$;

DROP TRIGGER issue37_fail_first_notification_delivery ON public.task_notifications;
DROP FUNCTION public.issue37_fail_first_notification_delivery_tg();
DROP SEQUENCE public.issue37_notification_delivery_failures;

DO $$
DECLARE
  v_result jsonb;
  v_retry_notice public.task_notifications%ROWTYPE;
BEGIN
  SELECT notice.* INTO STRICT v_retry_notice
  FROM public.task_notifications AS notice
  WHERE notice.state = 'retry_wait';
  v_result := public.process_task_notification_jobs_internal_p(
    20, v_retry_notice.available_at + interval '1 second', NULL
  );
  SELECT notice.* INTO STRICT v_retry_notice
  FROM public.task_notifications AS notice
  WHERE notice.id = v_retry_notice.id;
  IF (v_result->>'delivered')::integer <> 1
    OR v_retry_notice.state IS DISTINCT FROM 'delivered'
    OR v_retry_notice.attempt_count <> 2 THEN
    RAISE EXCEPTION 'The durable item should deliver once its retry time arrives: %, %',
      v_result, v_retry_notice;
  END IF;
END;
$$;

UPDATE public.task_comments AS comment_row
SET created_at = clock_timestamp() - interval '10 days'
FROM issue37_notification_fixture AS fixture
WHERE comment_row.id = fixture.comment_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_mentions jsonb := jsonb_build_array(jsonb_build_object(
    'user_id', '43700000-0000-4000-8000-000000000004',
    'start_char', 5,
    'length_chars', 18
  ));
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_result := public.edit_task_comment_p(
    '63700000-0000-4000-8000-000000000004', v_fixture.board_slug,
    v_fixture.comment_id, 3, 'Mira @Persona terciaria', v_mentions
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Adding a new mention to an edited comment should be confirmed: %', v_result;
  END IF;
  v_result := public.edit_task_comment_p(
    '63700000-0000-4000-8000-000000000005', v_fixture.board_slug,
    v_fixture.comment_id, 4, 'Mira sin mención', '[]'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Removing a mention should be confirmed: %', v_result;
  END IF;
  v_result := public.edit_task_comment_p(
    '63700000-0000-4000-8000-000000000006', v_fixture.board_slug,
    v_fixture.comment_id, 5, 'Mira @Persona terciaria', v_mentions
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Re-adding a mention should be confirmed: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_page jsonb;
BEGIN
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page->'items') <> 1
    OR NOT (v_page->'items'->0->'reason_codes' ? 'mention')
    OR (v_page->'items'->0->>'occurred_at')::timestamptz
      <= clock_timestamp() - interval '1 minute' THEN
    RAISE EXCEPTION 'A newly added mention on an old comment should create one notice at edit time: %', v_page;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_fixture record;
  v_created jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_created := public.create_repetition_with_advance_p(
    '63700000-0000-4000-8000-000000000010',
    v_fixture.board_slug,
    v_fixture.task_id,
    '2026-12-25'::date,
    NULL,
    2,
    2,
    false,
    NULL,
    '{"frequency":"daily","interval":1}'::jsonb,
    0,
    v_fixture.column_id
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The synthetic series creator could not create the occurrence fixture: %', v_created;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_fixture record;
  v_series_id uuid;
  v_job_id uuid;
  v_lease_token uuid := gen_random_uuid();
  v_now timestamptz := '2026-12-26 12:00:00+00'::timestamptz;
  v_worker_result jsonb;
  v_generated_task_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  SELECT occurrence.series_id INTO STRICT v_series_id
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.task_id = v_fixture.task_id AND occurrence.state = 'current';
  SELECT job.id INTO STRICT v_job_id
  FROM public.daily_repetition_jobs AS job
  WHERE job.series_id = v_series_id AND job.job_kind = 'advance'
    AND job.state IN ('queued', 'retry_wait')
  ORDER BY job.created_at DESC, job.id DESC
  LIMIT 1;
  UPDATE public.daily_repetition_jobs AS job
  SET state = 'leased', lease_token = v_lease_token,
      lease_expires_at = v_now + interval '1 hour',
      attempt_count = job.attempt_count + 1, updated_at = v_now
  WHERE job.id = v_job_id;
  v_worker_result := public.process_daily_repetition_job_internal_p(
    v_job_id, v_lease_token, v_now
  );
  IF v_worker_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The controlled repetition worker could not create its next occurrence: %',
      v_worker_result;
  END IF;

  SELECT occurrence.task_id INTO STRICT v_generated_task_id
  FROM public.daily_repetition_occurrences AS occurrence
  WHERE occurrence.series_id = v_series_id
    AND occurrence.state = 'current'
    AND occurrence.task_id <> v_fixture.task_id;
  UPDATE issue37_notification_fixture AS fixture
  SET generated_task_id = v_generated_task_id
  WHERE fixture.purpose = 'assignment';
END;
$$;
COMMIT;

RESET ROLE;
DO $$
DECLARE
  v_generated_task_id uuid;
  v_assignee_id uuid;
  v_notification_count integer;
BEGIN
  SELECT fixture.generated_task_id INTO STRICT v_generated_task_id
  FROM issue37_notification_fixture AS fixture
  WHERE fixture.purpose = 'assignment';
  SELECT task.assignee_id INTO STRICT v_assignee_id
  FROM public.tasks AS task WHERE task.id = v_generated_task_id;
  SELECT count(*)::integer INTO v_notification_count
  FROM public.task_notifications AS notice
  WHERE notice.task_id = v_generated_task_id;
  IF v_assignee_id IS DISTINCT FROM '43700000-0000-4000-8000-000000000003'
    OR v_notification_count <> 0 THEN
    RAISE EXCEPTION 'An automatically inserted assigned occurrence must not emit a notice: assignee %, notices %',
      v_assignee_id, v_notification_count;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_steps_result jsonb;
  v_target_column_id uuid;
  v_source_version bigint;
  v_target_version bigint;
  v_move_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  SELECT v_column.id INTO STRICT v_target_column_id
  FROM public.create_column_p(
    v_fixture.board_slug, v_fixture.board_id, 'Columna de prueba', 1
  ) AS v_column;
  SELECT column_row.task_order_version INTO STRICT v_source_version
  FROM public.columns AS column_row WHERE column_row.id = v_fixture.column_id;
  SELECT column_row.task_order_version INTO STRICT v_target_version
  FROM public.columns AS column_row WHERE column_row.id = v_target_column_id;
  v_steps_result := public.mutate_task_checklist_step_p(
    '63700000-0000-4000-8000-000000000100',
    v_fixture.board_slug,
    v_fixture.generated_task_id,
    jsonb_build_object('action', 'add', 'text', 'Paso sin aviso')
  );
  IF v_steps_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A checklist step could not be added to the generated occurrence: %',
      v_steps_result;
  END IF;
  v_move_result := public.update_task_positions_p(
    '63700000-0000-4000-8000-000000000101',
    v_fixture.board_slug,
    jsonb_build_array(jsonb_build_object(
      'id', v_fixture.generated_task_id,
      'source_column_id', v_fixture.column_id,
      'column_id', v_target_column_id,
      'before_task_id', NULL,
      'after_task_id', NULL
    )),
    jsonb_build_object(
      v_fixture.column_id::text, v_source_version,
      v_target_column_id::text, v_target_version
    )
  );
  IF v_move_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The generated occurrence could not be moved without changing its fields: %',
      v_move_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

DO $$
DECLARE
  v_fixture record;
  v_notification_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  SELECT count(*)::integer INTO v_notification_count
  FROM public.task_notifications AS notice
  WHERE notice.task_id = v_fixture.generated_task_id;
  IF v_notification_count <> 0 THEN
    RAISE EXCEPTION 'Checklist edits and column moves must not create task notifications: %',
      v_notification_count;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_membership_id uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  SELECT member.membership_id INTO STRICT v_membership_id
  FROM public.list_board_members_p(v_fixture.board_slug) AS member
  WHERE member.user_id = '43700000-0000-4000-8000-000000000004';
  v_result := public.remove_board_collaborator_p(
    '63700000-0000-4000-8000-000000000011',
    v_fixture.board_id,
    v_membership_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The owner could not retire the series creator: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_result := public.create_task_comment_p(
    '63700000-0000-4000-8000-000000000012',
    v_fixture.board_slug,
    v_fixture.task_id,
    'Comentario después de retirar a quien creó la serie.',
    '[]'::jsonb
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The current assignee could not comment after creator departure: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_page jsonb;
BEGIN
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page->'items') <> 0 THEN
    RAISE EXCEPTION 'The original task creator must not replace an unavailable series creator: %', v_page;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '43700000-0000-4000-8000-000000000004', 'collaborator'
FROM issue37_notification_fixture AS fixture
WHERE fixture.purpose = 'assignment';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_page jsonb;
BEGIN
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page->'items') <> 0 THEN
    RAISE EXCEPTION 'A new membership episode must not recover old notices: %', v_page;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_page jsonb;
  v_items jsonb;
  v_first_page jsonb;
  v_second_page jsonb;
  v_assignment_count integer;
  v_due_count integer;
  v_comment_count integer;
BEGIN
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  v_items := v_page->'items';
  SELECT count(*) FILTER (WHERE item.value->'reason_codes' ? 'assignment'),
    count(*) FILTER (WHERE item.value->'reason_codes' ? 'due_date'),
    count(*) FILTER (WHERE item.value->'reason_codes' ? 'comment')
  INTO v_assignment_count, v_due_count, v_comment_count
  FROM jsonb_array_elements(v_items) AS item(value);
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_items) <> 3
    OR v_assignment_count <> 1
    OR v_due_count <> 1
    OR v_comment_count <> 1
    OR (SELECT count(*) FROM jsonb_array_elements(v_items) AS item(value)
        WHERE item.value->'reason_codes' ? 'mention') <> 1 THEN
    RAISE EXCEPTION 'Assignment, due date, and one comment/mention should yield three distinct notices: %', v_page;
  END IF;
  v_page := public.list_my_task_notifications_p('unread', 20, NULL, NULL);
  IF jsonb_array_length(v_page->'items') <> 2
    OR (v_page->>'unread_count')::integer <> 2 THEN
    RAISE EXCEPTION 'The unread filter should exclude the one notice already marked read: %', v_page;
  END IF;
  v_first_page := public.list_my_task_notifications_p('all', 1, NULL, NULL);
  IF jsonb_array_length(v_first_page->'items') <> 1
    OR v_first_page->>'has_more' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'A one-item inbox page should expose its cursor: %', v_first_page;
  END IF;
  v_second_page := public.list_my_task_notifications_p(
    'all', 1,
    (v_first_page->'next_cursor'->>'occurred_at')::timestamptz,
    (v_first_page->'next_cursor'->>'id')::uuid
  );
  IF jsonb_array_length(v_second_page->'items') <> 1
    OR v_first_page->'items'->0->>'id' = v_second_page->'items'->0->>'id' THEN
    RAISE EXCEPTION 'Inbox cursor pagination should continue without repeating the first item: %, %',
      v_first_page, v_second_page;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
UPDATE public.task_notifications AS notice
SET generation_id = '93700000-0000-4000-8000-000000000001'
WHERE notice.id = (
  SELECT candidate.id
  FROM public.task_notifications AS candidate
  JOIN issue37_notification_fixture AS fixture
    ON fixture.board_id = candidate.board_id
  WHERE fixture.purpose = 'assignment'
    AND candidate.recipient_user_id = '43700000-0000-4000-8000-000000000003'
    AND candidate.read_at IS NULL
  ORDER BY candidate.occurred_at DESC, candidate.id DESC
  LIMIT 1
);
UPDATE issue37_notification_fixture AS fixture
SET stale_notice_id = notice.id
FROM public.task_notifications AS notice
WHERE fixture.purpose = 'assignment'
  AND notice.board_id = fixture.board_id
  AND notice.generation_id = '93700000-0000-4000-8000-000000000001';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_page jsonb;
  v_fixture record;
  v_mark jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  v_mark := public.mark_my_task_notification_read_p(v_fixture.stale_notice_id);
  IF jsonb_array_length(v_page->'items') <> 2
    OR (v_page->>'unread_count')::integer <> 1
    OR v_mark->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'The unread count and read action must use active-generation authorization: list %, mark %',
      v_page, v_mark;
  END IF;
END;
$$;
RESET ROLE;
UPDATE public.task_notifications AS notice
SET generation_id = board.active_generation_id
FROM public.boards AS board
WHERE board.id = notice.board_id
  AND notice.generation_id = '93700000-0000-4000-8000-000000000001';
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_task jsonb;
  v_self_assignment jsonb;
  v_assignment jsonb;
  v_task_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_task := public.create_task_p(
    gen_random_uuid(), v_fixture.board_id, v_fixture.column_id, 'Título privado en papelera'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  v_self_assignment := public.set_task_assignee_p(
    '63700000-0000-4000-8000-000000000020', v_fixture.board_slug,
    v_task_id, auth.uid(), 1
  );
  v_assignment := public.set_task_assignee_p(
    '63700000-0000-4000-8000-000000000021', v_fixture.board_slug,
    v_task_id, '43700000-0000-4000-8000-000000000003', 2
  );
  IF v_task->>'status' IS DISTINCT FROM 'confirmed'
    OR v_self_assignment->>'status' IS DISTINCT FROM 'confirmed'
    OR v_assignment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The unavailable-task notification fixture could not be assigned: %, %, %',
      v_task, v_self_assignment, v_assignment;
  END IF;
  INSERT INTO issue37_notification_fixture(
    purpose, board_id, board_slug, column_id, task_id, operation_id
  ) VALUES (
    'deleted', v_fixture.board_id, v_fixture.board_slug, v_fixture.column_id,
    v_task_id, gen_random_uuid()
  );
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public.process_task_notification_jobs_p(20);
  IF v_result->>'status' IS DISTINCT FROM 'processed' THEN
    RAISE EXCEPTION 'The deleted-task notification was not processed: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'deleted';
  v_result := public.delete_task_p(
    v_fixture.operation_id, v_fixture.board_slug, v_fixture.task_id, 'user_requested'
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The synthetic task could not be moved to recovery: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_unavailable jsonb;
  v_target jsonb;
  v_mark jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'deleted';
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  SELECT item.value INTO v_unavailable
  FROM jsonb_array_elements(v_page->'items') AS item(value)
  WHERE item.value->>'unavailable' = 'true';
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR v_unavailable IS NULL
    OR v_unavailable->>'task_title' IS NOT NULL THEN
    RAISE EXCEPTION 'A deleted task should leave a generic notice without its title: %', v_page;
  END IF;
  UPDATE issue37_notification_fixture
  SET notice_id = (v_unavailable->>'id')::uuid
  WHERE purpose = 'deleted';
  v_target := public.get_my_task_notification_target_p((v_unavailable->>'id')::uuid);
  v_mark := public.mark_my_task_notification_read_p((v_unavailable->>'id')::uuid);
  IF v_target->>'status' IS DISTINCT FROM 'unavailable'
    OR v_mark->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A permitted reader can clear an unavailable notice but cannot open it: target %, mark %',
      v_target, v_mark;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

DO $$
DECLARE
  v_fixture record;
  v_expires_at timestamptz;
  v_result text;
  v_notice_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'deleted';
  SELECT deletion.expires_at INTO STRICT v_expires_at
  FROM public.task_deletions AS deletion WHERE deletion.task_id = v_fixture.task_id;
  v_result := public.purge_expired_task_internal_p(v_fixture.task_id, v_expires_at);
  SELECT count(*) INTO v_notice_count
  FROM public.task_notifications AS notice WHERE notice.task_id = v_fixture.task_id;
  IF v_result IS DISTINCT FROM 'purged' OR v_notice_count <> 0 THEN
    RAISE EXCEPTION 'Purging a task must purge its dependent notice: result %, remaining %',
      v_result, v_notice_count;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_member_id uuid;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  SELECT member.membership_id INTO STRICT v_member_id
  FROM public.list_board_members_p(v_fixture.board_slug) AS member
  WHERE member.user_id = '43700000-0000-4000-8000-000000000003';
  v_result := public.remove_board_collaborator_p(
    '63700000-0000-4000-8000-000000000022', v_fixture.board_id, v_member_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The owner could not close the old recipient episode: %', v_result;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '43700000-0000-4000-8000-000000000003', 'collaborator'
FROM issue37_notification_fixture AS fixture
WHERE fixture.purpose = 'assignment';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_target jsonb;
  v_mark jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM issue37_notification_fixture WHERE purpose = 'assignment';
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  v_target := public.get_my_task_notification_target_p(v_fixture.notice_id);
  v_mark := public.mark_my_task_notification_read_p(v_fixture.notice_id);
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page->'items') <> 0
    OR v_target->>'status' IS DISTINCT FROM 'unavailable'
    OR v_mark->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'Rejoining must not reveal or mark notices from the old membership episode: %, %, %',
      v_page, v_target, v_mark;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

DO $$
DECLARE
  v_board_id uuid;
  v_task_id uuid;
  v_comment_id uuid;
  v_read_count integer;
  v_unread_count integer;
  v_purged integer;
  v_now timestamptz := clock_timestamp();
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  SELECT fixture.board_id, fixture.task_id, fixture.comment_id
    INTO STRICT v_board_id, v_task_id, v_comment_id
  FROM issue37_notification_fixture AS fixture WHERE fixture.purpose = 'assignment';
  SELECT count(*) FILTER (WHERE notice.read_at IS NOT NULL),
    count(*) FILTER (WHERE notice.read_at IS NULL)
  INTO v_read_count, v_unread_count
  FROM public.task_notifications AS notice WHERE notice.board_id = v_board_id;
  IF v_read_count <> 1 OR v_unread_count <> 3 THEN
    RAISE EXCEPTION 'Retention fixture should contain both read and unread notices: read %, unread %',
      v_read_count, v_unread_count;
  END IF;

  UPDATE public.task_notifications AS notice
  SET occurred_at = v_now - interval '90 days'
  WHERE notice.board_id = v_board_id;
  v_purged := public.purge_expired_task_notifications_p(500, v_now);
  IF v_purged <> 4
    OR EXISTS (SELECT 1 FROM public.task_notifications AS notice WHERE notice.board_id = v_board_id)
    OR NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id)
    OR NOT EXISTS (SELECT 1 FROM public.task_comments AS comment_row
      WHERE comment_row.id = v_comment_id) THEN
    RAISE EXCEPTION 'Ninety-day purge must remove read/unread notices without deleting task/comment: purged %, task %, comment %',
      v_purged,
      EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = v_task_id),
      EXISTS (SELECT 1 FROM public.task_comments AS comment_row WHERE comment_row.id = v_comment_id);
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43700000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_page jsonb;
BEGIN
  v_page := public.list_my_task_notifications_p('all', 20, NULL, NULL);
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page->'items') <> 0 THEN
    RAISE EXCEPTION 'The actor must not receive an auto-notice: %', v_page;
  END IF;
END;
$$;
COMMIT;
RESET ROLE;

\echo 'PASS: confirmed assignment is idempotent, private, and excludes its actor'
