\set ON_ERROR_STOP on
\echo 'Issue #17 RED: owner removes one current collaborator membership episode'

CREATE TEMP TABLE issue17_member_removal_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  owner_id uuid NOT NULL,
  target_user_id uuid NOT NULL,
  owner_membership_id uuid,
  target_membership_id uuid,
  column_id uuid,
  task_id uuid,
  task_assignee_version bigint,
  comment_id uuid,
  departing_invitation_id uuid,
  owner_invitation_id uuid,
  reentry_invitation_id uuid,
  new_membership_id uuid
);
GRANT SELECT, INSERT, UPDATE ON issue17_member_removal_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 17 collaborator removal',
    'UTC',
    'a7180000-0000-4000-8000-000000000001'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo conservado', 0);
  INSERT INTO pg_temp.issue17_member_removal_fixture (
    board_id, board_slug, owner_id, target_user_id, column_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    '41600000-0000-4000-8000-000000000002',
    v_column.id
  );
END;
$$;
COMMIT;

WITH added_membership AS (
  INSERT INTO public.board_memberships (board_id, user_id, role)
  SELECT fixture.board_id, fixture.target_user_id, 'collaborator'
  FROM pg_temp.issue17_member_removal_fixture AS fixture
  RETURNING id, board_id, user_id
)
UPDATE pg_temp.issue17_member_removal_fixture AS fixture
SET target_membership_id = added_membership.id
FROM added_membership
WHERE added_membership.board_id = fixture.board_id
  AND added_membership.user_id = fixture.target_user_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_member_count integer;
  v_invalid_members integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT count(*), count(*) FILTER (WHERE name = '' OR role NOT IN ('owner', 'collaborator'))
    INTO v_member_count, v_invalid_members
  FROM public.list_board_members_p(v_fixture.board_slug);
  IF v_member_count <> 2 OR v_invalid_members <> 0 THEN
    RAISE EXCEPTION 'The owner did not see the current member names and roles';
  END IF;
  UPDATE pg_temp.issue17_member_removal_fixture AS fixture
  SET owner_membership_id = member.membership_id
  FROM public.list_board_members_p(v_fixture.board_slug) AS member
  WHERE member.role = 'owner'
    AND fixture.board_id = v_fixture.board_id;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_member_count integer;
  v_owner_count integer;
  v_collaborator_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT count(*), count(*) FILTER (WHERE role = 'owner'),
    count(*) FILTER (WHERE role = 'collaborator')
    INTO v_member_count, v_owner_count, v_collaborator_count
  FROM public.list_board_members_p(v_fixture.board_slug);
  IF v_member_count <> 2 OR v_owner_count <> 1 OR v_collaborator_count <> 1 THEN
    RAISE EXCEPTION 'A collaborator could not see the current board member list';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_member_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT count(*) INTO v_member_count
  FROM public.list_board_members_p(v_fixture.board_slug);
  IF v_member_count <> 0 THEN
    RAISE EXCEPTION 'A nonmember administrator could read the member list';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: current board members can see the roster, but nonmembers cannot'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_task jsonb;
  v_assignment jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  v_task := public.create_task_p(
    'a7180000-0000-4000-8000-000000000003',
    v_fixture.board_id,
    v_fixture.column_id,
    'Tarea del colaborador que conserva autoría'
  );
  v_assignment := public.set_task_assignee_p(
    'a7180000-0000-4000-8000-000000000004',
    v_fixture.board_slug,
    (v_task->>'task_id')::uuid,
    auth.uid(),
    1
  );
  IF v_task->>'status' IS DISTINCT FROM 'confirmed'
    OR v_assignment->>'status' IS DISTINCT FROM 'confirmed'
    OR v_assignment->'task'->>'assignee_version' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'Could not create the collaborator-owned assigned task fixture';
  END IF;
  UPDATE pg_temp.issue17_member_removal_fixture
  SET task_id = (v_task->>'task_id')::uuid,
      task_assignee_version = 2;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_comment jsonb;
  v_invitation jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  v_comment := public.create_task_comment_p(
    p_operation_id => 'a7180000-0000-4000-8000-000000000005',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => '@issue16-member@example.test conserva autoría',
    p_mentions => '[{"user_id":"41600000-0000-4000-8000-000000000002","start_char":0,"length_chars":28}]'::jsonb
  );
  v_invitation := public.create_direct_board_invitation_p(
    v_fixture.board_slug,
    'revocation-user@example.test'
  );
  IF v_comment->>'status' IS DISTINCT FROM 'confirmed'
    OR v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Could not create mention and owner invitation fixtures';
  END IF;
  UPDATE pg_temp.issue17_member_removal_fixture
  SET comment_id = (v_comment->>'comment_id')::uuid,
      owner_invitation_id = (v_invitation->>'id')::uuid;
END;
$$;
COMMIT;

WITH departing_invitation AS (
  INSERT INTO public.board_invitations (
    board_id, inviter_id, invitation_type, recipient_id
  )
  SELECT
    fixture.board_id,
    fixture.target_user_id,
    'direct',
    '40000000-0000-4000-8000-000000000001'
  FROM pg_temp.issue17_member_removal_fixture AS fixture
  RETURNING id, board_id
)
UPDATE pg_temp.issue17_member_removal_fixture AS fixture
SET departing_invitation_id = departing_invitation.id
FROM departing_invitation
WHERE departing_invitation.board_id = fixture.board_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  BEGIN
    PERFORM public.remove_board_collaborator_p(
      'a7180000-0000-4000-8000-000000000006',
      v_fixture.board_id,
      v_fixture.target_membership_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A collaborator was allowed to remove another member';
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
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  v_result := public.remove_board_collaborator_p(
    'a7180000-0000-4000-8000-000000000007',
    v_fixture.board_id,
    v_fixture.owner_membership_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'The owner removal RPC must never remove an owner membership: %', v_result;
  END IF;
END;
$$;
COMMIT;

UPDATE public.application_access
SET state = 'suspended'
WHERE auth_user_id = '41600000-0000-4000-8000-000000000002';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_member_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT count(*) INTO v_member_count
  FROM public.list_board_members_p(v_fixture.board_slug) AS member
  WHERE member.membership_id = v_fixture.target_membership_id
    AND member.role = 'collaborator';
  IF v_member_count <> 1 THEN
    RAISE EXCEPTION 'A suspended but current collaborator disappeared from the owner roster';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: the owner roster retains current suspended collaborators for removal'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  BEGIN
    PERFORM public.remove_board_collaborator_p(
      'a7180000-0000-4000-8000-000000000008',
      v_fixture.board_id,
      v_fixture.target_membership_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'An application administrator without board ownership removed a collaborator';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: an application administrator without board ownership cannot remove a collaborator'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_rpc_missing boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  BEGIN
    EXECUTE 'SELECT public.remove_board_collaborator_p($1, $2, $3)'
      INTO v_result
      USING
        'a7180000-0000-4000-8000-000000000002'::uuid,
        v_fixture.board_id,
        v_fixture.target_membership_id;
  EXCEPTION WHEN undefined_function THEN
    v_rpc_missing := true;
  END;

  IF v_rpc_missing THEN
    RAISE EXCEPTION 'The owner removal operation is missing (expected current episode removal)';
  END IF;
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The owner could not remove the current collaborator episode: %',
      v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_owner_count integer;
  v_target_revoked_at timestamptz;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT count(*) INTO v_owner_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = v_fixture.owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL;
  SELECT membership.revoked_at INTO v_target_revoked_at
  FROM public.board_memberships AS membership
  WHERE membership.id = v_fixture.target_membership_id;
  IF v_owner_count <> 1 OR v_target_revoked_at IS NULL THEN
    RAISE EXCEPTION 'Removal did not revoke exactly the requested collaborator episode';
  END IF;
END;
$$;
\echo 'PASS: owner can remove one current collaborator membership episode'

DO $$
DECLARE
  v_fixture record;
  v_task public.tasks%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  IF NOT FOUND
    OR v_task.assignee_id IS NOT NULL
    OR v_task.assignee_version <> v_fixture.task_assignee_version + 1 THEN
    RAISE EXCEPTION 'Owner removal did not clear the pending assignee and advance the field version';
  END IF;
END;
$$;
\echo 'PASS: owner removal clears pending assignments and advances the field version'

DO $$
DECLARE
  v_fixture record;
  v_task public.tasks%ROWTYPE;
  v_comment public.task_comments%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  SELECT comment_row.* INTO v_comment
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = v_fixture.comment_id;
  IF NOT FOUND
    OR v_task.created_by IS DISTINCT FROM v_fixture.target_user_id
    OR v_task.title IS DISTINCT FROM 'Tarea del colaborador que conserva autoría'
    OR v_comment.author_id IS DISTINCT FROM v_fixture.owner_id
    OR v_comment.content IS DISTINCT FROM '@issue16-member@example.test conserva autoría' THEN
    RAISE EXCEPTION 'Owner removal changed task/comment authorship or content';
  END IF;
END;
$$;
\echo 'PASS: owner removal preserves task and comment authorship'

DO $$
DECLARE
  v_fixture record;
  v_mention public.task_comment_mentions%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT mention.* INTO v_mention
  FROM public.task_comment_mentions AS mention
  WHERE mention.comment_id = v_fixture.comment_id;
  IF NOT FOUND
    OR v_mention.membership_id IS NOT NULL
    OR v_mention.display_text IS DISTINCT FROM '@issue16-member@example.test' THEN
    RAISE EXCEPTION 'Owner removal did not freeze the mention to text without identity';
  END IF;
END;
$$;
\echo 'PASS: owner removal freezes historical mentions to text'

DO $$
DECLARE
  v_fixture record;
  v_departing_status text;
  v_owner_status text;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT invitation.status INTO v_departing_status
  FROM public.board_invitations AS invitation
  WHERE invitation.id = v_fixture.departing_invitation_id;
  SELECT invitation.status INTO v_owner_status
  FROM public.board_invitations AS invitation
  WHERE invitation.id = v_fixture.owner_invitation_id;
  IF v_departing_status IS DISTINCT FROM 'revoked'
    OR v_owner_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'Owner removal did not revoke only invitations issued by the target';
  END IF;
END;
$$;
\echo 'PASS: owner removal revokes only pending invitations issued by the target'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  v_result := public.remove_board_collaborator_p(
    'a7180000-0000-4000-8000-000000000002',
    v_fixture.board_id,
    v_fixture.target_membership_id
  );
  IF v_result IS DISTINCT FROM jsonb_build_object(
    'status', 'confirmed',
    'operation_id', 'a7180000-0000-4000-8000-000000000002'::uuid
  ) THEN
    RAISE EXCEPTION 'A lost owner-removal response did not replay minimally: %', v_result;
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: owner-removal receipt replays after the membership is revoked'

UPDATE public.application_access
SET state = 'active'
WHERE auth_user_id = '41600000-0000-4000-8000-000000000002';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_invitation jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  v_invitation := public.create_direct_board_invitation_p(
    v_fixture.board_slug,
    'issue16-member@example.test'
  );
  IF v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'The owner could not issue a fresh re-entry invitation: %', v_invitation;
  END IF;
  UPDATE pg_temp.issue17_member_removal_fixture
  SET reentry_invitation_id = (v_invitation->>'id')::uuid;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  v_result := public.accept_direct_board_invitation_p(
    v_fixture.reentry_invitation_id,
    'a7180000-0000-4000-8000-000000000009'
  );
  IF v_result->>'status' IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'The collaborator could not rejoin as a fresh episode: %', v_result;
  END IF;
END;
$$;
COMMIT;

UPDATE pg_temp.issue17_member_removal_fixture AS fixture
SET new_membership_id = membership.id
FROM public.board_memberships AS membership
WHERE membership.board_id = fixture.board_id
  AND membership.user_id = fixture.target_user_id
  AND membership.revoked_at IS NULL;

DO $$
DECLARE
  v_fixture record;
  v_task public.tasks%ROWTYPE;
  v_mention public.task_comment_mentions%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  SELECT mention.* INTO v_mention
  FROM public.task_comment_mentions AS mention
  WHERE mention.comment_id = v_fixture.comment_id;
  IF v_fixture.new_membership_id IS NULL
    OR v_fixture.new_membership_id = v_fixture.target_membership_id
    OR v_task.assignee_id IS NOT NULL
    OR v_task.assignee_version <> v_fixture.task_assignee_version + 1
    OR v_task.created_by IS DISTINCT FROM v_fixture.target_user_id
    OR v_mention.membership_id IS NOT NULL THEN
    RAISE EXCEPTION 'Re-entry restored an old membership, assignment, or mention identity';
  END IF;
END;
$$;
\echo 'PASS: re-entry creates a new episode without restoring old assignment or mention identity'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  v_result := public.remove_board_collaborator_p(
    'a7180000-0000-4000-8000-000000000002',
    v_fixture.board_id,
    v_fixture.target_membership_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (
      SELECT 1 FROM public.list_board_members_p(v_fixture.board_slug) AS member
      WHERE member.membership_id = v_fixture.new_membership_id
        AND member.role = 'collaborator'
    ) THEN
    RAISE EXCEPTION 'A replay of the old episode receipt removed or changed re-entry';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: an old receipt cannot remove a rejoined membership episode'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_payload_conflict boolean := false;
  v_stale_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_member_removal_fixture;
  BEGIN
    PERFORM public.remove_board_collaborator_p(
      'a7180000-0000-4000-8000-000000000002',
      v_fixture.board_id,
      v_fixture.new_membership_id
    );
  EXCEPTION WHEN check_violation THEN
    v_payload_conflict := true;
  END;
  IF NOT v_payload_conflict THEN
    RAISE EXCEPTION 'An operation receipt key was reused for a different membership episode';
  END IF;

  v_stale_result := public.remove_board_collaborator_p(
    'a7180000-0000-4000-8000-00000000000a',
    v_fixture.board_id,
    v_fixture.target_membership_id
  );
  IF v_stale_result->>'status' IS DISTINCT FROM 'conflict'
    OR NOT EXISTS (
      SELECT 1 FROM public.list_board_members_p(v_fixture.board_slug) AS member
      WHERE member.membership_id = v_fixture.new_membership_id
        AND member.role = 'collaborator'
    ) THEN
    RAISE EXCEPTION 'A stale episode removal affected the rejoined member: %', v_stale_result;
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: old episode IDs conflict after re-entry and cannot revoke the new membership'

CREATE TABLE public.issue17_member_removal_concurrency_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  owner_id uuid NOT NULL,
  collaborator_id uuid NOT NULL,
  membership_id uuid,
  task_id uuid,
  remove_operation_id uuid NOT NULL,
  leave_operation_id uuid NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON public.issue17_member_removal_concurrency_fixture
  TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 17 removal versus leave race',
    'UTC',
    'a7180000-0000-4000-8000-0000000000f0'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Carrera de salida', 0);
  v_task := public.create_task_p(
    'a7180000-0000-4000-8000-0000000000f1',
    v_board.id,
    v_column.id,
    'Asignación limpiada una sola vez'
  );
  IF v_task->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the task for the member removal race';
  END IF;
  INSERT INTO public.issue17_member_removal_concurrency_fixture (
    board_id, board_slug, owner_id, collaborator_id, task_id,
    remove_operation_id, leave_operation_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    '41600000-0000-4000-8000-000000000002',
    (v_task->>'task_id')::uuid,
    'a7180000-0000-4000-8000-0000000000f2',
    'a7180000-0000-4000-8000-0000000000f3'
  );
END;
$$;
COMMIT;

WITH added_membership AS (
  INSERT INTO public.board_memberships (board_id, user_id, role)
  SELECT fixture.board_id, fixture.collaborator_id, 'collaborator'
  FROM public.issue17_member_removal_concurrency_fixture AS fixture
  RETURNING id, board_id, user_id
)
UPDATE public.issue17_member_removal_concurrency_fixture AS fixture
SET membership_id = added_membership.id
FROM added_membership
WHERE added_membership.board_id = fixture.board_id
  AND added_membership.user_id = fixture.collaborator_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_assignment jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue17_member_removal_concurrency_fixture;
  v_assignment := public.set_task_assignee_p(
    'a7180000-0000-4000-8000-0000000000f4',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.collaborator_id,
    1
  );
  IF v_assignment->>'status' IS DISTINCT FROM 'confirmed'
    OR v_assignment->'task'->>'assignee_version' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'Could not assign the race task to the current collaborator';
  END IF;
END;
$$;
COMMIT;
