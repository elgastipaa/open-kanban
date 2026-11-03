\set ON_ERROR_STOP on
\echo 'Issue #19: suspend access with atomic board succession and recovery'

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('41900000-0000-4000-8000-000000000001', 'suspension-target@example.test', now(), '{"provider":"google"}'),
  ('41900000-0000-4000-8000-000000000002', 'suspension-successor@example.test', now(), '{"provider":"google"}'),
  ('41900000-0000-4000-8000-000000000003', 'suspension-recovery-successor@example.test', now(), '{"provider":"google"}'),
  ('41900000-0000-4000-8000-000000000004', 'rollback-target@example.test', now(), '{"provider":"google"}'),
  ('41900000-0000-4000-8000-000000000005', 'rollback-successor@example.test', now(), '{"provider":"google"}'),
  ('41900000-0000-4000-8000-000000000006', 'race-target@example.test', now(), '{"provider":"google"}'),
  ('41900000-0000-4000-8000-000000000007', 'race-successor@example.test', now(), '{"provider":"google"}'),
  ('41900000-0000-4000-8000-000000000008', 'race-invitee@example.test', now(), '{"provider":"google"}');

INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('51900000-0000-4000-8000-000000000001', '41900000-0000-4000-8000-000000000001', 'google', 'issue19-suspension-target', '{"email":"suspension-target@example.test","email_verified":true,"name":"Suspension Target"}'),
  ('51900000-0000-4000-8000-000000000002', '41900000-0000-4000-8000-000000000002', 'google', 'issue19-suspension-successor', '{"email":"suspension-successor@example.test","email_verified":true,"name":"Successor A"}'),
  ('51900000-0000-4000-8000-000000000003', '41900000-0000-4000-8000-000000000003', 'google', 'issue19-recovery-successor', '{"email":"suspension-recovery-successor@example.test","email_verified":true,"name":"Successor B"}'),
  ('51900000-0000-4000-8000-000000000004', '41900000-0000-4000-8000-000000000004', 'google', 'issue19-rollback-target', '{"email":"rollback-target@example.test","email_verified":true,"name":"Rollback Target"}'),
  ('51900000-0000-4000-8000-000000000005', '41900000-0000-4000-8000-000000000005', 'google', 'issue19-rollback-successor', '{"email":"rollback-successor@example.test","email_verified":true,"name":"Rollback Successor"}'),
  ('51900000-0000-4000-8000-000000000006', '41900000-0000-4000-8000-000000000006', 'google', 'issue19-race-target', '{"email":"race-target@example.test","email_verified":true,"name":"Race Target"}'),
  ('51900000-0000-4000-8000-000000000007', '41900000-0000-4000-8000-000000000007', 'google', 'issue19-race-successor', '{"email":"race-successor@example.test","email_verified":true,"name":"Race Successor"}'),
  ('51900000-0000-4000-8000-000000000008', '41900000-0000-4000-8000-000000000008', 'google', 'issue19-race-invitee', '{"email":"race-invitee@example.test","email_verified":true,"name":"Race Invitee"}');

INSERT INTO public.application_access(email, auth_user_id, google_subject, state) VALUES
  ('suspension-target@example.test', '41900000-0000-4000-8000-000000000001', 'issue19-suspension-target', 'active'),
  ('suspension-successor@example.test', '41900000-0000-4000-8000-000000000002', 'issue19-suspension-successor', 'active'),
  ('suspension-recovery-successor@example.test', '41900000-0000-4000-8000-000000000003', 'issue19-recovery-successor', 'active'),
  ('rollback-target@example.test', '41900000-0000-4000-8000-000000000004', 'issue19-rollback-target', 'active'),
  ('rollback-successor@example.test', '41900000-0000-4000-8000-000000000005', 'issue19-rollback-successor', 'active'),
  ('race-target@example.test', '41900000-0000-4000-8000-000000000006', 'issue19-race-target', 'active'),
  ('race-successor@example.test', '41900000-0000-4000-8000-000000000007', 'issue19-race-successor', 'active'),
  ('race-invitee@example.test', '41900000-0000-4000-8000-000000000008', 'issue19-race-invitee', 'active');

CREATE TEMP TABLE issue19_suspension_fixture (
  name text PRIMARY KEY,
  board_id uuid NOT NULL,
  slug text NOT NULL,
  column_id uuid,
  task_id uuid,
  invitation_id uuid,
  comment_id uuid,
  expires_at timestamptz
);
GRANT SELECT, INSERT, UPDATE ON issue19_suspension_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
BEGIN
  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 active transfer board', 'UTC', 'a9190000-0000-4000-8000-000000000001'
  );
  SELECT * INTO STRICT v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Privado', 0
  );
  v_task := public.create_task_p(
    'a9190000-0000-4000-8000-000000000002', v_board.id, v_column.id,
    'Contenido privado de suspensión'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug, column_id, task_id)
  VALUES ('active_transfer', v_board.id, v_board.slug, v_column.id, (v_task->>'task_id')::uuid);

  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 active board without successor', 'UTC', 'a9190000-0000-4000-8000-000000000003'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug)
  VALUES ('active_recover', v_board.id, v_board.slug);

  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 existing recoverable board', 'UTC', 'a9190000-0000-4000-8000-000000000004'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug)
  VALUES ('existing_recovery', v_board.id, v_board.slug);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_board record;
BEGIN
  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 rollback transfer board', 'UTC', 'a9190000-0000-4000-8000-000000000015'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug)
  VALUES ('rollback_transfer', v_board.id, v_board.slug);

  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 rollback recovery board', 'UTC', 'a9190000-0000-4000-8000-000000000016'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug)
  VALUES ('rollback_recover', v_board.id, v_board.slug);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
BEGIN
  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 collaborator board', 'UTC', 'a9190000-0000-4000-8000-000000000005'
  );
  SELECT * INTO STRICT v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'Privado', 0
  );
  v_task := public.create_task_p(
    'a9190000-0000-4000-8000-000000000006', v_board.id, v_column.id,
    'Tarea asignada en tablero colaborativo'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug, column_id, task_id)
  VALUES ('collaborator', v_board.id, v_board.slug, v_column.id, (v_task->>'task_id')::uuid);

  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 invitation board', 'UTC', 'a9190000-0000-4000-8000-000000000007'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug)
  VALUES ('incoming_invitation', v_board.id, v_board.slug);
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '41900000-0000-4000-8000-000000000002', 'collaborator'
FROM pg_temp.issue19_suspension_fixture AS fixture
WHERE fixture.name = 'active_transfer';
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '41900000-0000-4000-8000-000000000003', 'collaborator'
FROM pg_temp.issue19_suspension_fixture AS fixture
WHERE fixture.name = 'existing_recovery';
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '41900000-0000-4000-8000-000000000001', 'collaborator'
FROM pg_temp.issue19_suspension_fixture AS fixture
WHERE fixture.name = 'collaborator';
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '41900000-0000-4000-8000-000000000005', 'collaborator'
FROM pg_temp.issue19_suspension_fixture AS fixture
WHERE fixture.name = 'rollback_transfer';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture
  WHERE name = 'active_transfer';
  v_result := public.create_direct_board_invitation_p(
    v_fixture.slug, 'suspension-recovery-successor@example.test'
  );
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Suspended owner invitation fixture was not created: %', v_result;
  END IF;
  UPDATE pg_temp.issue19_suspension_fixture
  SET invitation_id = (v_result->>'id')::uuid
  WHERE name = 'active_transfer';

  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture
  WHERE name = 'existing_recovery';
  v_result := public.delete_board_p(
    'a9190000-0000-4000-8000-000000000008', v_fixture.slug, v_fixture.board_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'recoverable' THEN
    RAISE EXCEPTION 'Existing recovery fixture was not created: %', v_result;
  END IF;
  UPDATE pg_temp.issue19_suspension_fixture
  SET expires_at = (v_result->>'expires_at')::timestamptz
  WHERE name = 'existing_recovery';
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_comment jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture
  WHERE name = 'active_transfer';
  v_result := public.set_task_assignee_p(
    'a9190000-0000-4000-8000-000000000009', v_fixture.slug, v_fixture.task_id,
    '41900000-0000-4000-8000-000000000001', 1
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Active task assignment fixture failed: %', v_result;
  END IF;
  v_comment := public.create_task_comment_p(
    'a9190000-0000-4000-8000-000000000010', v_fixture.slug, v_fixture.task_id,
    'Hola @Suspension Target',
    jsonb_build_array(jsonb_build_object(
      'user_id', '41900000-0000-4000-8000-000000000001',
      'start_char', 5,
      'length_chars', char_length('@Suspension Target')
    ))
  );
  UPDATE pg_temp.issue19_suspension_fixture
  SET comment_id = (v_comment->>'comment_id')::uuid
  WHERE name = 'active_transfer';

  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture
  WHERE name = 'collaborator';
  v_result := public.set_task_assignee_p(
    'a9190000-0000-4000-8000-000000000011', v_fixture.slug, v_fixture.task_id,
    '41900000-0000-4000-8000-000000000001', 1
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Collaborator-board assignment fixture failed: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture
  WHERE name = 'incoming_invitation';
  v_result := public.create_direct_board_invitation_p(
    v_fixture.slug, 'suspension-target@example.test'
  );
  IF v_result->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Incoming invitation fixture was not created: %', v_result;
  END IF;
  UPDATE pg_temp.issue19_suspension_fixture
  SET invitation_id = (v_result->>'id')::uuid
  WHERE name = 'incoming_invitation';
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_preview jsonb;
  v_board jsonb;
  v_fixture record;
BEGIN
  v_preview := public.admin_preview_account_suspension_p('suspension-target@example.test');
  IF v_preview->>'status' IS DISTINCT FROM 'ready'
    OR jsonb_array_length(v_preview->'boards') <> 4 THEN
    RAISE EXCEPTION 'Suspension preview did not summarize every owned/member board: %', v_preview;
  END IF;

  SELECT value INTO STRICT v_board
  FROM jsonb_array_elements(v_preview->'boards') AS entries(value)
  JOIN pg_temp.issue19_suspension_fixture AS fixture
    ON fixture.name = 'active_transfer'
   AND value->>'board_id' = fixture.board_id::text;
  IF v_board->>'state' IS DISTINCT FROM 'active'
    OR v_board->>'relationship' IS DISTINCT FROM 'owner'
    OR jsonb_array_length(v_board->'candidates') <> 1
    OR v_board->'candidates'->0->>'user_id' IS DISTINCT FROM '41900000-0000-4000-8000-000000000002'
    OR v_preview::text LIKE '%Contenido privado de suspensión%' THEN
    RAISE EXCEPTION 'Active board preview exposed content or wrong successors: %', v_board;
  END IF;

  SELECT value INTO STRICT v_board
  FROM jsonb_array_elements(v_preview->'boards') AS entries(value)
  JOIN pg_temp.issue19_suspension_fixture AS fixture
    ON fixture.name = 'active_recover'
   AND value->>'board_id' = fixture.board_id::text;
  IF jsonb_array_length(v_board->'candidates') <> 0 THEN
    RAISE EXCEPTION 'A nonmember was offered as active-board successor: %', v_board;
  END IF;

  SELECT value INTO STRICT v_board
  FROM jsonb_array_elements(v_preview->'boards') AS entries(value)
  JOIN pg_temp.issue19_suspension_fixture AS fixture
    ON fixture.name = 'collaborator'
   AND value->>'board_id' = fixture.board_id::text;
  IF v_board->>'relationship' IS DISTINCT FROM 'collaborator' THEN
    RAISE EXCEPTION 'Collaborator board was not included in the suspension preview: %', v_board;
  END IF;

  SELECT value INTO STRICT v_board
  FROM jsonb_array_elements(v_preview->'boards') AS entries(value)
  JOIN pg_temp.issue19_suspension_fixture AS fixture
    ON fixture.name = 'existing_recovery'
   AND value->>'board_id' = fixture.board_id::text;
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture
  WHERE name = 'existing_recovery';
  IF v_board->>'state' IS DISTINCT FROM 'recoverable'
    OR (v_board->>'expires_at')::timestamptz IS DISTINCT FROM v_fixture.expires_at
    OR jsonb_array_length(v_board->'candidates') <> 1
    OR v_board->'candidates'->0->>'user_id' IS DISTINCT FROM '41900000-0000-4000-8000-000000000003' THEN
    RAISE EXCEPTION 'Existing recovery preview lost its date or eligible owner: %', v_board;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_transfer record;
  v_recover record;
  v_existing record;
  v_incoming record;
  v_result jsonb;
  v_mention_membership_id uuid;
  v_mention_text text;
BEGIN
  SELECT * INTO STRICT v_transfer FROM pg_temp.issue19_suspension_fixture WHERE name = 'active_transfer';
  SELECT * INTO STRICT v_recover FROM pg_temp.issue19_suspension_fixture WHERE name = 'active_recover';
  SELECT * INTO STRICT v_existing FROM pg_temp.issue19_suspension_fixture WHERE name = 'existing_recovery';
  SELECT * INTO STRICT v_incoming FROM pg_temp.issue19_suspension_fixture WHERE name = 'incoming_invitation';

  v_result := public.admin_suspend_access_with_successions_p(
    'suspension-target@example.test',
    jsonb_build_array(
      jsonb_build_object('board_id', v_transfer.board_id, 'action', 'transfer', 'successor_id', '41900000-0000-4000-8000-000000000002'),
      jsonb_build_object('board_id', v_recover.board_id, 'action', 'recover', 'successor_id', NULL),
      jsonb_build_object('board_id', v_existing.board_id, 'action', 'set_recovery_owner', 'successor_id', '41900000-0000-4000-8000-000000000003')
    )
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Atomic suspension did not confirm: %', v_result;
  END IF;
END;
$$;

RESET ROLE;
DO $$
DECLARE
  v_transfer record;
  v_recover record;
  v_existing record;
  v_incoming record;
  v_mention_membership_id uuid;
  v_mention_text text;
BEGIN
  SELECT * INTO STRICT v_transfer FROM pg_temp.issue19_suspension_fixture WHERE name = 'active_transfer';
  SELECT * INTO STRICT v_recover FROM pg_temp.issue19_suspension_fixture WHERE name = 'active_recover';
  SELECT * INTO STRICT v_existing FROM pg_temp.issue19_suspension_fixture WHERE name = 'existing_recovery';
  SELECT * INTO STRICT v_incoming FROM pg_temp.issue19_suspension_fixture WHERE name = 'incoming_invitation';

  IF (SELECT access.state FROM public.admin_list_access() AS access
      WHERE access.email = 'suspension-target@example.test') <> 'suspended' THEN
    RAISE EXCEPTION 'The requested account remained active after suspension';
  END IF;
  IF (SELECT owner_id FROM public.boards WHERE id = v_transfer.board_id)
    <> '41900000-0000-4000-8000-000000000002'::uuid THEN
    RAISE EXCEPTION 'The explicit active-board successor did not receive ownership';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.board_memberships
    WHERE board_id = v_transfer.board_id AND user_id = '41900000-0000-4000-8000-000000000001'
      AND revoked_at IS NULL
  ) OR EXISTS (
    SELECT 1 FROM public.board_memberships
    WHERE board_id = v_recover.board_id AND revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Suspension left an active owner or member episode behind';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions
    WHERE board_id = v_recover.board_id
      AND (cause <> 'admin_suspended_owner' OR expires_at <> deleted_at + interval '168 hours')
  ) THEN
    RAISE EXCEPTION 'An owner board without candidates did not enter its own recovery window';
  END IF;
  IF (SELECT assignee_id FROM public.tasks WHERE id = v_transfer.task_id) IS NOT NULL
    OR (SELECT assignee_id FROM public.tasks WHERE id = (SELECT task_id FROM pg_temp.issue19_suspension_fixture WHERE name = 'collaborator')) IS NOT NULL THEN
    RAISE EXCEPTION 'Suspension retained an active assignment in one of the person’s boards';
  END IF;
  IF (SELECT recovery_owner_id FROM public.board_recoverable_deletions WHERE board_id = v_existing.board_id)
      <> '41900000-0000-4000-8000-000000000003'::uuid
    OR (SELECT expires_at FROM public.board_recoverable_deletions WHERE board_id = v_existing.board_id)
      IS DISTINCT FROM v_existing.expires_at THEN
    RAISE EXCEPTION 'Existing recoverable board was reactivated or its deadline changed';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.board_invitations
    WHERE status = 'pending'
      AND (inviter_id = '41900000-0000-4000-8000-000000000001'
        OR recipient_id = '41900000-0000-4000-8000-000000000001')
  ) THEN
    RAISE EXCEPTION 'Suspension left an outgoing or incoming invitation pending';
  END IF;
  SELECT mention.membership_id, mention.display_text
  INTO v_mention_membership_id, v_mention_text
  FROM public.task_comment_mentions AS mention
  WHERE mention.comment_id = v_transfer.comment_id;
  IF v_mention_membership_id IS NOT NULL
    OR v_mention_text IS DISTINCT FROM '@Suspension Target' THEN
    RAISE EXCEPTION 'Historical mention was not frozen to its original text';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.user_id = '41900000-0000-4000-8000-000000000001'
      AND membership.revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Suspended identity retained an active board membership episode';
  END IF;
  IF (SELECT status FROM public.board_invitations WHERE id = v_incoming.invitation_id) <> 'revoked' THEN
    RAISE EXCEPTION 'Incoming invitation did not become revoked';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_denied boolean := false;
BEGIN
  IF public.is_application_user() OR EXISTS (SELECT 1 FROM public.list_my_boards()) THEN
    RAISE EXCEPTION 'The old JWT retained application or board access after suspension';
  END IF;
  SELECT * INTO STRICT v_board FROM pg_temp.issue19_suspension_fixture WHERE name = 'active_transfer';
  IF public.get_full_board_p(v_board.slug) IS NOT NULL THEN
    RAISE EXCEPTION 'The old JWT read a board after suspension';
  END IF;
  BEGIN
    PERFORM public.create_task_p(
      'a9190000-0000-4000-8000-000000000012', v_board.board_id, v_board.column_id,
      'A stale JWT must not write'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'The old JWT wrote after suspension';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
SELECT public.admin_enable_access('suspension-target@example.test');
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_board_count integer;
BEGIN
  SELECT count(*) INTO v_board_count FROM public.list_my_boards();
  IF v_board_count <> 0 THEN
    RAISE EXCEPTION 'Rehabilitation restored memberships or ownership';
  END IF;
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture WHERE name = 'active_transfer';
  IF public.is_board_member(v_fixture.board_id)
    OR (SELECT assignee_id FROM public.tasks WHERE id = v_fixture.task_id) IS NOT NULL THEN
    RAISE EXCEPTION 'Rehabilitation reconstructed membership or responsibility';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture WHERE name = 'existing_recovery';
  v_result := public.restore_board_p(
    'a9190000-0000-4000-8000-000000000013', v_fixture.board_id, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (SELECT owner_id FROM public.boards WHERE id = v_fixture.board_id)
      <> '41900000-0000-4000-8000-000000000003'::uuid
    OR NOT public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'The designated recovery authority could not explicitly restore its board: %', v_result;
  END IF;
END;
$$;

RESET ROLE;
DO $$
DECLARE
  v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue19_suspension_fixture WHERE name = 'existing_recovery';
  IF EXISTS (
    SELECT 1 FROM public.board_memberships
    WHERE board_id = v_fixture.board_id
      AND user_id = '41900000-0000-4000-8000-000000000001'
      AND revoked_at IS NULL
  ) THEN
    RAISE EXCEPTION 'Restoring a board revived the suspended owner membership';
  END IF;
END;
$$;
COMMIT;

-- Force a genuine constraint failure after membership cleanup begins. The RPC
-- exception must roll back every board effect and the account state together.
CREATE FUNCTION public.issue19_fail_recoverable_insert_p()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('test.issue19_fail_recoverable_insert', true) = 'on' THEN
    RAISE EXCEPTION 'Injected issue #19 transaction failure' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER issue19_fail_recoverable_insert
  AFTER INSERT ON public.board_recoverable_deletions
  FOR EACH ROW EXECUTE FUNCTION public.issue19_fail_recoverable_insert_p();

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_transfer record;
  v_recover record;
  v_failed boolean := false;
BEGIN
  SELECT * INTO STRICT v_transfer FROM pg_temp.issue19_suspension_fixture WHERE name = 'rollback_transfer';
  SELECT * INTO STRICT v_recover FROM pg_temp.issue19_suspension_fixture WHERE name = 'rollback_recover';
  PERFORM set_config('test.issue19_fail_recoverable_insert', 'on', true);
  BEGIN
    PERFORM public.admin_suspend_access_with_successions_p(
      'rollback-target@example.test',
      jsonb_build_array(
        jsonb_build_object('board_id', v_transfer.board_id, 'action', 'transfer', 'successor_id', '41900000-0000-4000-8000-000000000005'),
        jsonb_build_object('board_id', v_recover.board_id, 'action', 'recover', 'successor_id', NULL)
      )
    );
  EXCEPTION WHEN check_violation THEN
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'The injected database failure did not abort suspension';
  END IF;
END;
$$;

RESET ROLE;
DO $$
DECLARE
  v_transfer record;
  v_recover record;
BEGIN
  SELECT * INTO STRICT v_transfer FROM pg_temp.issue19_suspension_fixture WHERE name = 'rollback_transfer';
  SELECT * INTO STRICT v_recover FROM pg_temp.issue19_suspension_fixture WHERE name = 'rollback_recover';
  IF (SELECT access.state FROM public.admin_list_access() AS access
      WHERE access.email = 'rollback-target@example.test') <> 'active'
    OR (SELECT owner_id FROM public.boards WHERE id = v_transfer.board_id)
      <> '41900000-0000-4000-8000-000000000004'::uuid
    OR EXISTS (SELECT 1 FROM public.board_recoverable_deletions WHERE board_id = v_recover.board_id)
    OR NOT EXISTS (
      SELECT 1 FROM public.board_memberships
      WHERE board_id = v_transfer.board_id
        AND user_id = '41900000-0000-4000-8000-000000000004'
        AND role = 'owner' AND revoked_at IS NULL
    ) THEN
    RAISE EXCEPTION 'A failed suspension left partial board or account state';
  END IF;
END;
$$;
COMMIT;

DROP TRIGGER issue19_fail_recoverable_insert ON public.board_recoverable_deletions;
DROP FUNCTION public.issue19_fail_recoverable_insert_p();

-- Fixtures for the two-session writer and invitation races in test-db.sh.
CREATE TABLE public.issue19_suspension_race_fixture (
  name text PRIMARY KEY,
  board_id uuid NOT NULL,
  slug text NOT NULL,
  column_id uuid,
  successor_id uuid NOT NULL,
  invite_board_id uuid NOT NULL,
  invite_slug text NOT NULL,
  invitee_email text NOT NULL
);
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_board record;
  v_column record;
BEGIN
  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 write race board', 'UTC', 'a9190000-0000-4000-8000-000000000014'
  );
  SELECT * INTO STRICT v_column FROM public.create_column_p(v_board.slug, v_board.id, 'Race', 0);
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug, column_id)
  VALUES ('write_race', v_board.id, v_board.slug, v_column.id);

  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Issue 19 invitation race board', 'UTC', 'a9190000-0000-4000-8000-000000000017'
  );
  INSERT INTO pg_temp.issue19_suspension_fixture(name, board_id, slug)
  VALUES ('race_invitation', v_board.id, v_board.slug);
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, '41900000-0000-4000-8000-000000000007', 'collaborator'
FROM pg_temp.issue19_suspension_fixture WHERE name = 'write_race';

INSERT INTO public.issue19_suspension_race_fixture (
  name, board_id, slug, column_id, successor_id, invite_board_id, invite_slug, invitee_email
)
SELECT 'suspend_write_invite', write_board.board_id, write_board.slug,
  write_board.column_id, '41900000-0000-4000-8000-000000000007',
  invite_board.board_id, invite_board.slug, 'race-invitee@example.test'
FROM pg_temp.issue19_suspension_fixture AS write_board
JOIN pg_temp.issue19_suspension_fixture AS invite_board ON invite_board.name = 'race_invitation'
WHERE write_board.name = 'write_race';

\echo 'PASS: issue #19 succession, recovery, revocation, and rollback scenarios.'
