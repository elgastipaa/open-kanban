\set ON_ERROR_STOP on
\echo 'Testing durable task-comment replay after a discarded response'

INSERT INTO public.application_access (email, state, is_admin)
VALUES
  ('issue16-owner@example.test', 'pending', false),
  ('issue16-member@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES
  (
    '41600000-0000-4000-8000-000000000001',
    'issue16-owner@example.test',
    clock_timestamp(),
    '{"provider":"google"}'::jsonb
  ),
  (
    '41600000-0000-4000-8000-000000000002',
    'issue16-member@example.test',
    clock_timestamp(),
    '{"provider":"google"}'::jsonb
  );
INSERT INTO auth.identities (
  id, user_id, provider, provider_id, identity_data, created_at
) VALUES
  (
    '51600000-0000-4000-8000-000000000001',
    '41600000-0000-4000-8000-000000000001',
    'google',
    'issue16-owner-subject',
    '{"email":"issue16-owner@example.test","email_verified":true}'::jsonb,
    clock_timestamp()
  ),
  (
    '51600000-0000-4000-8000-000000000002',
    '41600000-0000-4000-8000-000000000002',
    'google',
    'issue16-member-subject',
    '{"email":"issue16-member@example.test","email_verified":true}'::jsonb,
    clock_timestamp()
  );

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_access jsonb;
BEGIN
  v_access := public.resolve_application_access();
  IF v_access->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'The synthetic issue 16 actor could not be enabled: %', v_access;
  END IF;
  PERFORM set_config(
    'request.jwt.claim.sub',
    '41600000-0000-4000-8000-000000000002',
    true
  );
  v_access := public.resolve_application_access();
  IF v_access->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'The synthetic issue 16 member could not be enabled: %', v_access;
  END IF;
END;
$$;
COMMIT;

CREATE TEMP TABLE issue16_comment_operation_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  content text NOT NULL,
  member_episode_id uuid,
  member_comment_id uuid
);
GRANT SELECT, INSERT, UPDATE ON issue16_comment_operation_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task_result jsonb;
  v_task_id uuid;
  v_operation_id constant uuid := 'a6160000-0000-4000-8000-000000000001';
  v_content constant text := 'La respuesta puede perderse sin publicar dos veces.';
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Issue 16 comment replay',
    'UTC',
    'a6160000-0000-4000-8000-000000000002'
  );

  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Conversación', 0);

  v_task_result := public.create_task_p(
    'a6160000-0000-4000-8000-000000000003',
    v_board.id,
    v_column_id,
    'Tarea con conversación'
  );
  v_task_id := (v_task_result->'task'->>'id')::uuid;
  IF v_task_id IS NULL THEN
    RAISE EXCEPTION 'The isolated comment fixture did not create its task: %', v_task_result;
  END IF;

  INSERT INTO pg_temp.issue16_comment_operation_fixture(
    board_id, board_slug, column_id, task_id, operation_id, content
  ) VALUES (
    v_board.id, v_board.slug, v_column_id, v_task_id, v_operation_id, v_content
  );

  -- Discard this successful RPC response, then commit its durable result.
  PERFORM public.create_task_comment_p(
    p_operation_id => v_operation_id,
    p_slug => v_board.slug,
    p_task_id => v_task_id,
    p_content => v_content,
    p_mentions => '[]'::jsonb
  );
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_replay jsonb;
  v_page jsonb;
  v_comment_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;

  v_replay := public.create_task_comment_p(
    p_operation_id => v_fixture.operation_id,
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => v_fixture.content,
    p_mentions => '[]'::jsonb
  );
  IF v_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replay->>'operation_id' IS DISTINCT FROM v_fixture.operation_id::text
    OR v_replay->>'comment_id' IS NULL THEN
    RAISE EXCEPTION 'Replaying the committed comment intent did not return its result: %', v_replay;
  END IF;
  v_comment_id := (v_replay->>'comment_id')::uuid;

  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_page->'comments') <> 1
    OR v_page->'comments'->0->>'id' IS DISTINCT FROM v_comment_id::text
    OR v_page->'comments'->0->>'content' IS DISTINCT FROM v_fixture.content THEN
    RAISE EXCEPTION 'The lost-response replay did not resolve to exactly one visible comment: %', v_page;
  END IF;
END;
$$;
COMMIT;

\echo 'Testing a reused comment operation id rejects a different payload'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_rejected boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  BEGIN
    PERFORM public.create_task_comment_p(
      p_operation_id => v_fixture.operation_id,
      p_slug => v_fixture.board_slug,
      p_task_id => v_fixture.task_id,
      p_content => 'Otra intención con la misma clave.',
      p_mentions => '[]'::jsonb
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Reusing an operation id with another payload was not rejected';
  END IF;
END;
$$;
COMMIT;

\echo 'Testing comment writes are independent from task field versions'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_before_versions jsonb;
  v_after_versions jsonb;
  v_created jsonb;
  v_edited jsonb;
  v_comment_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  SELECT task.field_versions INTO STRICT v_before_versions
  FROM public.get_tasks_by_board_p(v_fixture.board_id) AS task
  WHERE task.id = v_fixture.task_id;

  v_created := public.create_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000018',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => 'El comentario no cambia la versión de los campos.'
  );
  v_comment_id := (v_created->>'comment_id')::uuid;
  v_edited := public.edit_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000019',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_comment_id,
    p_expected_version => 1,
    p_content => 'Editar comentario tampoco cambia la versión de los campos.'
  );

  SELECT task.field_versions INTO STRICT v_after_versions
  FROM public.get_tasks_by_board_p(v_fixture.board_id) AS task
  WHERE task.id = v_fixture.task_id;
  IF v_created->>'status' IS DISTINCT FROM 'confirmed'
    OR v_edited->>'status' IS DISTINCT FROM 'confirmed'
    OR v_edited->>'version' IS DISTINCT FROM '2'
    OR v_after_versions IS DISTINCT FROM v_before_versions THEN
    RAISE EXCEPTION 'Comment persistence changed independent task field versions: before %, after %, create %, edit %',
      v_before_versions, v_after_versions, v_created, v_edited;
  END IF;
END;
$$;
COMMIT;

\echo 'Testing a comment result after its receipt expires'
UPDATE public.task_comment_receipts AS receipt
SET result_expires_at = clock_timestamp() - interval '1 microsecond'
FROM pg_temp.issue16_comment_operation_fixture AS fixture
WHERE receipt.actor_id = '41600000-0000-4000-8000-000000000001'
  AND receipt.operation_id = fixture.operation_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_replay jsonb;
  v_page jsonb;
  v_original_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_replay := public.create_task_comment_p(
    p_operation_id => v_fixture.operation_id,
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => v_fixture.content,
    p_mentions => '[]'::jsonb
  );
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  SELECT count(*) INTO v_original_count
  FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
  WHERE row_value->>'content' = v_fixture.content;
  IF v_replay->>'status' IS DISTINCT FROM 'expired_unknown'
    OR v_original_count <> 1 THEN
    RAISE EXCEPTION 'An expired result was resent or not reported as uncertain: replay %, page %',
      v_replay, v_page;
  END IF;
END;
$$;
COMMIT;

CREATE TABLE public.issue16_comment_concurrency_fixture (
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  content text NOT NULL
);
INSERT INTO public.issue16_comment_concurrency_fixture (
  board_slug, task_id, actor_id, operation_id, content
)
SELECT
  fixture.board_slug,
  fixture.task_id,
  '41600000-0000-4000-8000-000000000001',
  'a6160000-0000-4000-8000-000000000099',
  'Dos sesiones confirmaron la misma intención.'
FROM pg_temp.issue16_comment_operation_fixture AS fixture;
GRANT SELECT ON public.issue16_comment_concurrency_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_read jsonb;
  v_create jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;

  v_read := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  v_create := public.create_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000004',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => 'Texto que no debe salir a un externo.',
    p_mentions => '[]'::jsonb
  );
  IF v_read->>'status' IS DISTINCT FROM 'unavailable'
    OR v_read ? 'comments'
    OR v_create->>'status' IS DISTINCT FROM 'unavailable'
    OR v_create ? 'comment_id' THEN
    RAISE EXCEPTION 'A nonmember received comment data or created a comment: read %, create %',
      v_read, v_create;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_member_episode_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  INSERT INTO public.board_memberships(board_id, user_id, role)
  VALUES (
    v_fixture.board_id,
    '41600000-0000-4000-8000-000000000002',
    'collaborator'
  ) RETURNING id INTO v_member_episode_id;
  UPDATE pg_temp.issue16_comment_operation_fixture
  SET member_episode_id = v_member_episode_id;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_read jsonb;
  v_original_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_read := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  SELECT count(*) INTO v_original_count
  FROM pg_catalog.jsonb_array_elements(v_read->'comments') AS row_value
  WHERE row_value->>'content' = v_fixture.content;
  IF v_read->>'status' IS DISTINCT FROM 'available'
    OR v_original_count <> 1 THEN
    RAISE EXCEPTION 'A current board member could not read the authorized conversation: %', v_read;
  END IF;
END;
$$;
COMMIT;

\echo 'Testing comment author edits and owner moderation boundary'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_created jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_created := public.create_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000006',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => 'Comentario escrito por la persona colaboradora.',
    p_mentions => '[]'::jsonb
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmed'
    OR v_created->>'comment_id' IS NULL THEN
    RAISE EXCEPTION 'The collaborator comment was not confirmed: %', v_created;
  END IF;
  UPDATE pg_temp.issue16_comment_operation_fixture
  SET member_comment_id = (v_created->>'comment_id')::uuid;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_edit jsonb;
  v_page jsonb;
  v_rejected boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  BEGIN
    v_edit := public.edit_task_comment_p(
      p_operation_id => 'a6160000-0000-4000-8000-000000000007',
      p_slug => v_fixture.board_slug,
      p_comment_id => v_fixture.member_comment_id,
      p_expected_version => 1,
      p_content => 'El propietario intentó reescribirlo.',
      p_mentions => '[]'::jsonb
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'The board owner edited another member comment: %', v_edit;
  END IF;

  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
    WHERE row_value->>'id' = v_fixture.member_comment_id::text
      AND row_value->>'content' = 'Comentario escrito por la persona colaboradora.'
      AND NOT (row_value ? 'edited_at')
  ) THEN
    RAISE EXCEPTION 'A denied owner edit changed the authored comment: %', v_page;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_edit jsonb;
  v_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_edit := public.edit_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000008',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_fixture.member_comment_id,
    p_expected_version => 1,
    p_content => 'La autora actualizó el texto.',
    p_mentions => '[]'::jsonb
  );
  IF v_edit->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_edit->>'version')::bigint <> 2 THEN
    RAISE EXCEPTION 'The author could not edit her own comment: %', v_edit;
  END IF;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
    WHERE row_value->>'id' = v_fixture.member_comment_id::text
      AND row_value->>'content' = 'La autora actualizó el texto.'
      AND row_value->>'edited_at' IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'The confirmed edit or edited mark was not visible: %', v_page;
  END IF;
END;
$$;
COMMIT;

\echo 'Testing a collaborator cannot delete another author comment'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_owner_comment_id uuid;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50
  );
  SELECT (row_value->>'id')::uuid INTO STRICT v_owner_comment_id
  FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
  WHERE row_value->>'content' = v_fixture.content;
  BEGIN
    PERFORM public.delete_task_comment_p(
      p_operation_id => 'a6160000-0000-4000-8000-000000000020',
      p_slug => v_fixture.board_slug,
      p_comment_id => v_owner_comment_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A collaborator deleted another author comment';
  END IF;
END;
$$;
COMMIT;

\echo 'Testing owner moderation produces a text-free tombstone'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_deleted jsonb;
  v_page jsonb;
  v_tombstone jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_deleted := public.delete_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000009',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_fixture.member_comment_id
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_deleted->>'comment_id' IS DISTINCT FROM v_fixture.member_comment_id::text
    OR v_deleted->>'deletion_cause' IS DISTINCT FROM 'moderation' THEN
    RAISE EXCEPTION 'The owner did not moderate the comment as a deletion: %', v_deleted;
  END IF;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50
  );
  SELECT row_value INTO STRICT v_tombstone
  FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
  WHERE row_value->>'id' = v_fixture.member_comment_id::text;
  IF v_tombstone->>'can_restore' IS DISTINCT FROM 'true'
    OR v_tombstone->>'expires_at' IS NULL THEN
    RAISE EXCEPTION 'The current owner did not receive current recovery eligibility: %', v_tombstone;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_deleted jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  SELECT row_value INTO v_deleted
  FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
  WHERE row_value->>'id' = v_fixture.member_comment_id::text;
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR v_deleted->>'deleted' IS DISTINCT FROM 'true'
    OR v_deleted ? 'content'
    OR v_deleted ? 'version'
    OR v_deleted->>'author_name' IS DISTINCT FROM 'issue16-member@example.test'
    OR v_deleted->>'created_at' IS NULL
    OR v_deleted->>'edited_at' IS NULL
    OR v_deleted->>'can_restore' IS DISTINCT FROM 'false'
    OR v_deleted->>'expires_at' IS NULL THEN
    RAISE EXCEPTION 'Moderation did not leave a text-free attributed tombstone: %', v_page;
  END IF;
END;
$$;
COMMIT;

\echo 'Testing restore permissions by the original deletion cause'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_restore jsonb;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  BEGIN
    v_restore := public.restore_task_comment_p(
      p_operation_id => 'a6160000-0000-4000-8000-000000000010',
      p_slug => v_fixture.board_slug,
      p_comment_id => v_fixture.member_comment_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'The comment author restored an owner-moderated comment: %', v_restore;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_restore jsonb;
  v_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_restore := public.restore_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000011',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_fixture.member_comment_id
  );
  IF v_restore->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The current owner could not restore a moderated comment: %', v_restore;
  END IF;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
    WHERE row_value->>'id' = v_fixture.member_comment_id::text
      AND row_value->>'deleted' = 'false'
      AND row_value->>'content' = 'La autora actualizó el texto.'
      AND row_value->>'edited_at' IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Restoration did not return the original comment text: %', v_page;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_deleted jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_deleted := public.delete_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000012',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_fixture.member_comment_id
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_deleted->>'deletion_cause' IS DISTINCT FROM 'author' THEN
    RAISE EXCEPTION 'A comment author could not delete their own comment: %', v_deleted;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_restore jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_restore := public.restore_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000013',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_fixture.member_comment_id
  );
  IF v_restore->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The current owner could not restore an author-deleted comment: %', v_restore;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_deleted jsonb;
  v_restore jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_deleted := public.delete_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000014',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_fixture.member_comment_id
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The author could not delete their comment again: %', v_deleted;
  END IF;
  v_restore := public.restore_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000015',
    p_slug => v_fixture.board_slug,
    p_comment_id => v_fixture.member_comment_id
  );
  IF v_restore->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The author could not restore their own comment: %', v_restore;
  END IF;
END;
$$;
COMMIT;

-- Give keyset pagination a deterministic tie and insert a newer row between pages.
DO $$
DECLARE
  v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  UPDATE public.task_comments
  SET created_at = '2019-01-01 00:00:00+00'
  WHERE task_id = v_fixture.task_id;
  INSERT INTO public.task_comments (
    id, board_id, task_id, author_id, author_name, content, created_at
  ) VALUES
    ('ffffffff-ffff-4fff-8fff-000000000001', v_fixture.board_id, v_fixture.task_id,
      '41600000-0000-4000-8000-000000000001', 'issue16-owner@example.test', 'Página antigua 1', '2020-01-01 00:00:00+00'),
    ('ffffffff-ffff-4fff-8fff-000000000002', v_fixture.board_id, v_fixture.task_id,
      '41600000-0000-4000-8000-000000000001', 'issue16-owner@example.test', 'Página antigua 2', '2020-01-01 00:00:00+00'),
    ('ffffffff-ffff-4fff-8fff-000000000003', v_fixture.board_id, v_fixture.task_id,
      '41600000-0000-4000-8000-000000000001', 'issue16-owner@example.test', 'Página antigua 3', '2020-01-01 00:00:00+00'),
    ('ffffffff-ffff-4fff-8fff-000000000004', v_fixture.board_id, v_fixture.task_id,
      '41600000-0000-4000-8000-000000000001', 'issue16-owner@example.test', 'Página antigua 4', '2020-01-01 00:00:00+00');
END;
$$;

\echo 'Testing stable keyset pagination and navigation to a comment outside the latest page'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 2
  );
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR v_page->'comments'->0->>'id' IS DISTINCT FROM 'ffffffff-ffff-4fff-8fff-000000000003'
    OR v_page->'comments'->1->>'id' IS DISTINCT FROM 'ffffffff-ffff-4fff-8fff-000000000004'
    OR v_page->'next_cursor'->>'created_at' IS DISTINCT FROM '2020-01-01T00:00:00+00:00'
    OR v_page->'next_cursor'->>'id' IS DISTINCT FROM 'ffffffff-ffff-4fff-8fff-000000000003' THEN
    RAISE EXCEPTION 'The tied comment page did not return a stable cursor: %', v_page;
  END IF;
END;
$$;
COMMIT;

INSERT INTO public.task_comments (
  id, board_id, task_id, author_id, author_name, content, created_at
)
SELECT
  'ffffffff-ffff-4fff-8fff-000000000005', fixture.board_id, fixture.task_id,
  '41600000-0000-4000-8000-000000000001', 'issue16-owner@example.test',
  'Comentario nuevo entre páginas', '2020-01-02 00:00:00+00'
FROM pg_temp.issue16_comment_operation_fixture AS fixture;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_anchor_page jsonb;
  v_anchor_index integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 2,
    p_before_created_at => '2020-01-01 00:00:00+00',
    p_before_id => 'ffffffff-ffff-4fff-8fff-000000000003'
  );
  IF v_page->'comments'->0->>'id' IS DISTINCT FROM 'ffffffff-ffff-4fff-8fff-000000000001'
    OR v_page->'comments'->1->>'id' IS DISTINCT FROM 'ffffffff-ffff-4fff-8fff-000000000002'
    OR v_page->'comments' @> '[{"id":"ffffffff-ffff-4fff-8fff-000000000005"}]'::jsonb THEN
    RAISE EXCEPTION 'A newer arrival shifted or duplicated an older cursor page: %', v_page;
  END IF;

  v_anchor_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 2,
    p_before_created_at => NULL,
    p_before_id => NULL,
    p_anchor_comment_id => 'ffffffff-ffff-4fff-8fff-000000000001'
  );
  v_anchor_index := (v_anchor_page->>'anchor_index')::integer;
  IF v_anchor_page->>'anchor_id' IS DISTINCT FROM 'ffffffff-ffff-4fff-8fff-000000000001'
    OR v_anchor_page->'comments'->v_anchor_index->>'id'
      IS DISTINCT FROM 'ffffffff-ffff-4fff-8fff-000000000001' THEN
    RAISE EXCEPTION 'The requested historical comment was not included in its anchor page: %', v_anchor_page;
  END IF;
END;
$$;
COMMIT;

\echo 'Testing a mention resolves only to a current membership episode'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_created jsonb;
  v_comment_id uuid;
  v_page jsonb;
  v_rendered_comment jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_created := public.create_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000016',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => '@issue16-member@example.test revisa la conversación',
    p_mentions => '[{"user_id":"41600000-0000-4000-8000-000000000002","start_char":0,"length_chars":28}]'::jsonb
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A current membership mention was rejected: %', v_created;
  END IF;
  v_comment_id := (v_created->>'comment_id')::uuid;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 100
  );
  SELECT row_value INTO STRICT v_rendered_comment
  FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
  WHERE row_value->>'id' = v_comment_id::text;
  IF v_rendered_comment->'mentions'->0->>'text' IS DISTINCT FROM '@issue16-member@example.test'
    OR v_rendered_comment->'mentions'->0->>'user_id'
      IS DISTINCT FROM '41600000-0000-4000-8000-000000000002'
    OR v_rendered_comment->'mentions'->0->>'start_char' IS DISTINCT FROM '0'
    OR v_rendered_comment->'mentions'->0->>'length_chars' IS DISTINCT FROM '28' THEN
    RAISE EXCEPTION 'A current mention did not render with its authorized target: %', v_rendered_comment;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_comment_id uuid;
  v_new_episode_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  SELECT comment_row.id INTO STRICT v_comment_id
  FROM public.task_comments AS comment_row
  WHERE comment_row.task_id = v_fixture.task_id
    AND comment_row.content = '@issue16-member@example.test revisa la conversación';
  IF NOT EXISTS (
    SELECT 1 FROM public.task_comment_mentions AS mention
    WHERE mention.comment_id = v_comment_id
      AND mention.membership_id = v_fixture.member_episode_id
      AND mention.display_text = '@issue16-member@example.test'
  ) THEN
    RAISE EXCEPTION 'The current mention did not retain its membership episode';
  END IF;

  UPDATE public.board_memberships
  SET revoked_at = clock_timestamp()
  WHERE id = v_fixture.member_episode_id;
  INSERT INTO public.board_memberships(board_id, user_id, role)
  VALUES (
    v_fixture.board_id,
    '41600000-0000-4000-8000-000000000002',
    'collaborator'
  ) RETURNING id INTO v_new_episode_id;
  UPDATE pg_temp.issue16_comment_operation_fixture
  SET member_episode_id = v_new_episode_id;

  IF EXISTS (
    SELECT 1 FROM public.task_comment_mentions AS mention
    WHERE mention.comment_id = v_comment_id AND mention.membership_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Leaving the board did not freeze the historical mention target';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_page jsonb;
  v_comment jsonb;
  v_new_created jsonb;
  v_new_page jsonb;
  v_new_comment jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 100
  );
  SELECT row_value INTO STRICT v_comment
  FROM pg_catalog.jsonb_array_elements(v_page->'comments') AS row_value
  WHERE row_value->>'content' = '@issue16-member@example.test revisa la conversación';
  IF v_comment->'mentions'->0->>'text' IS DISTINCT FROM '@issue16-member@example.test'
    OR v_comment->'mentions'->0 ? 'user_id' THEN
    RAISE EXCEPTION 'Rejoining linked an old mention or removed its literal text: %', v_comment;
  END IF;

  v_new_created := public.create_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000017',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => '@issue16-member@example.test volvió al tablero',
    p_mentions => '[{"user_id":"41600000-0000-4000-8000-000000000002","start_char":0,"length_chars":28}]'::jsonb
  );
  v_new_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 100
  );
  SELECT row_value INTO STRICT v_new_comment
  FROM pg_catalog.jsonb_array_elements(v_new_page->'comments') AS row_value
  WHERE row_value->>'id' = v_new_created->>'comment_id';
  IF v_new_created->>'status' IS DISTINCT FROM 'confirmed'
    OR v_new_comment->'mentions'->0->>'user_id'
      IS DISTINCT FROM '41600000-0000-4000-8000-000000000002' THEN
    RAISE EXCEPTION 'A new mention after rejoining did not target the current member episode: %', v_new_comment;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_old_comment_id uuid;
  v_new_comment_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  SELECT comment_row.id INTO STRICT v_old_comment_id
  FROM public.task_comments AS comment_row
  WHERE comment_row.task_id = v_fixture.task_id
    AND comment_row.content = '@issue16-member@example.test revisa la conversación';
  SELECT comment_row.id INTO STRICT v_new_comment_id
  FROM public.task_comments AS comment_row
  WHERE comment_row.task_id = v_fixture.task_id
    AND comment_row.content = '@issue16-member@example.test volvió al tablero';
  IF EXISTS (
    SELECT 1 FROM public.task_comment_mentions AS mention
    WHERE mention.comment_id = v_old_comment_id AND mention.membership_id IS NOT NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.task_comment_mentions AS mention
    WHERE mention.comment_id = v_new_comment_id
      AND mention.membership_id = v_fixture.member_episode_id
  ) THEN
    RAISE EXCEPTION 'A historical mention was reattached or a new mention missed the fresh membership episode';
  END IF;
END;
$$;

UPDATE public.board_memberships AS membership
SET revoked_at = clock_timestamp()
FROM pg_temp.issue16_comment_operation_fixture AS fixture
WHERE membership.id = fixture.member_episode_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_read jsonb;
  v_create jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue16_comment_operation_fixture;
  v_read := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 50,
    p_before_created_at => NULL,
    p_before_id => NULL
  );
  v_create := public.create_task_comment_p(
    p_operation_id => 'a6160000-0000-4000-8000-000000000005',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => 'Acceso revocado.',
    p_mentions => '[]'::jsonb
  );
  IF v_read->>'status' IS DISTINCT FROM 'unavailable'
    OR v_read ? 'comments'
    OR v_create->>'status' IS DISTINCT FROM 'unavailable'
    OR v_create ? 'comment_id' THEN
    RAISE EXCEPTION 'A revoked member retained access to the conversation: read %, create %',
      v_read, v_create;
  END IF;
END;
$$;
COMMIT;
