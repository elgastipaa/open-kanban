\set ON_ERROR_STOP on
\echo 'Issue #17 RED: a chosen successor who leaves before confirmation cannot receive ownership'

CREATE TEMP TABLE issue17_departure_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  owner_id uuid NOT NULL,
  selected_successor_id uuid,
  task_id uuid NOT NULL,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON issue17_departure_fixture TO authenticated;

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
    'Issue 17 stale successor',
    'UTC',
    'a7170000-0000-4000-8000-000000000001'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Tarea que debe conservarse', 0);
  v_task := public.create_task_p(
    'a7170000-0000-4000-8000-000000000005',
    v_board.id,
    v_column.id,
    'Trabajo que conserva autoría'
  );
  INSERT INTO pg_temp.issue17_departure_fixture (
    board_id, board_slug, owner_id, task_id, operation_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    (v_task->>'task_id')::uuid,
    'a7170000-0000-4000-8000-000000000002'
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT fixture.board_id, '41600000-0000-4000-8000-000000000002', 'collaborator'
FROM pg_temp.issue17_departure_fixture AS fixture;

UPDATE public.application_access
SET state = 'suspended'
WHERE auth_user_id = '41600000-0000-4000-8000-000000000002';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_disabled_successor_visible boolean;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue17_departure_fixture;
  IF public.has_other_current_board_members_p(v_fixture.board_id) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'The server did not report the current collaborator as another member';
  END IF;
  SELECT EXISTS (
    SELECT 1
    FROM public.list_assignable_board_members_p(v_fixture.board_slug) AS member
    WHERE member.user_id = '41600000-0000-4000-8000-000000000002'
  ) INTO v_disabled_successor_visible;
  IF v_disabled_successor_visible THEN
    RAISE EXCEPTION 'A suspended current collaborator was offered as an eligible successor';
  END IF;
END;
$$;
COMMIT;

UPDATE public.application_access
SET state = 'active'
WHERE auth_user_id = '41600000-0000-4000-8000-000000000002';

\echo 'PASS: departure options preserve disabled current membership without offering that member as successor'

DO $$
DECLARE
  v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_departure_fixture;
  IF NOT EXISTS (
    SELECT 1
    FROM public.board_memberships AS membership
    WHERE membership.board_id = v_fixture.board_id
      AND membership.user_id = '41600000-0000-4000-8000-000000000002'
      AND membership.role = 'collaborator'
      AND membership.revoked_at IS NULL
      AND public.is_enabled_application_identity_p(membership.user_id)
  ) THEN
    RAISE EXCEPTION 'The selected successor was not an enabled current board member';
  END IF;
  UPDATE pg_temp.issue17_departure_fixture
  SET selected_successor_id = '41600000-0000-4000-8000-000000000002';
END;
$$;

-- The successor was selected while eligible, then another action removed the
-- membership before the owner's confirmation reaches the database boundary.
UPDATE public.board_memberships AS membership
SET revoked_at = clock_timestamp()
FROM pg_temp.issue17_departure_fixture AS fixture
WHERE membership.board_id = fixture.board_id
  AND membership.user_id = fixture.selected_successor_id
  AND membership.revoked_at IS NULL;

CREATE TEMP TABLE issue17_departure_before_confirmation AS
SELECT
  board.id AS board_id,
  to_jsonb(board) AS board_state,
  coalesce((
    SELECT jsonb_agg(to_jsonb(membership) ORDER BY membership.user_id)
    FROM public.board_memberships AS membership
    WHERE membership.board_id = board.id
  ), '[]'::jsonb) AS memberships_state,
  coalesce((
    SELECT jsonb_agg(to_jsonb(task) ORDER BY task.id)
    FROM public.tasks AS task
    JOIN public.columns AS task_column ON task_column.id = task.column_id
    WHERE task_column.board_id = board.id
  ), '[]'::jsonb) AS tasks_state
FROM public.boards AS board
JOIN pg_temp.issue17_departure_fixture AS fixture ON fixture.board_id = board.id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_departure_fixture;

  v_result := public.leave_board_p(
    v_fixture.operation_id,
    v_fixture.board_id,
    v_fixture.selected_successor_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'A successor who left before confirmation must block owner departure: %',
      v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_before record;
  v_board_state jsonb;
  v_memberships_state jsonb;
  v_tasks_state jsonb;
BEGIN
  SELECT * INTO STRICT v_before
  FROM pg_temp.issue17_departure_before_confirmation;

  SELECT to_jsonb(board) INTO STRICT v_board_state
  FROM public.boards AS board
  WHERE board.id = v_before.board_id;
  SELECT coalesce(
    jsonb_agg(to_jsonb(membership) ORDER BY membership.user_id),
    '[]'::jsonb
  ) INTO v_memberships_state
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_before.board_id;

  SELECT coalesce(
    jsonb_agg(to_jsonb(task) ORDER BY task.id),
    '[]'::jsonb
  ) INTO v_tasks_state
  FROM public.tasks AS task
  JOIN public.columns AS task_column ON task_column.id = task.column_id
  WHERE task_column.board_id = v_before.board_id;

  IF v_board_state IS DISTINCT FROM v_before.board_state
    OR v_memberships_state IS DISTINCT FROM v_before.memberships_state
    OR v_tasks_state IS DISTINCT FROM v_before.tasks_state THEN
    RAISE EXCEPTION 'Rejected owner departure changed board, membership, or task state';
  END IF;
END;
$$;

\echo 'PASS: an ineligible chosen successor cannot receive ownership or remove its current owner'

\echo 'Issue #17 RED: an eligible successor receives ownership as the owner leaves atomically'

CREATE TEMP TABLE issue17_successful_departure_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  owner_id uuid NOT NULL,
  successor_id uuid NOT NULL,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT ON issue17_successful_departure_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 17 successful successor',
    'UTC',
    'a7170000-0000-4000-8000-000000000003'
  );
  INSERT INTO pg_temp.issue17_successful_departure_fixture (
    board_id, board_slug, owner_id, successor_id, operation_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    '41600000-0000-4000-8000-000000000002',
    'a7170000-0000-4000-8000-000000000004'
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT fixture.board_id, fixture.successor_id, 'collaborator'
FROM pg_temp.issue17_successful_departure_fixture AS fixture;

CREATE TEMP TABLE issue17_missing_successor_before AS
SELECT
  board.id AS board_id,
  to_jsonb(board) AS board_state,
  coalesce((
    SELECT jsonb_agg(to_jsonb(membership) ORDER BY membership.user_id)
    FROM public.board_memberships AS membership
    WHERE membership.board_id = board.id
  ), '[]'::jsonb) AS memberships_state
FROM public.boards AS board
JOIN pg_temp.issue17_successful_departure_fixture AS fixture
  ON fixture.board_id = board.id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;
  v_result := public.leave_board_p(
    'a7170000-0000-4000-8000-000000000008',
    v_fixture.board_id,
    NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'An owner with another current member must choose a successor before leaving: %',
      v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_before record;
  v_board_state jsonb;
  v_memberships_state jsonb;
BEGIN
  SELECT * INTO STRICT v_before
  FROM pg_temp.issue17_missing_successor_before;
  SELECT to_jsonb(board) INTO STRICT v_board_state
  FROM public.boards AS board
  WHERE board.id = v_before.board_id;
  SELECT coalesce(
    jsonb_agg(to_jsonb(membership) ORDER BY membership.user_id),
    '[]'::jsonb
  ) INTO v_memberships_state
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_before.board_id;
  IF v_board_state IS DISTINCT FROM v_before.board_state
    OR v_memberships_state IS DISTINCT FROM v_before.memberships_state THEN
    RAISE EXCEPTION 'A missing-successor conflict changed board or membership state';
  END IF;
END;
$$;
\echo 'PASS: owner leave without a chosen successor conflicts and makes no membership change'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;
  v_result := public.delete_last_member_board_p(
    'a7170000-0000-4000-8000-000000000090',
    v_fixture.board_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'Explicit last-member deletion must conflict while another current member remains: %',
      v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_before record;
  v_board_state jsonb;
  v_memberships_state jsonb;
BEGIN
  SELECT * INTO STRICT v_before
  FROM pg_temp.issue17_missing_successor_before;
  SELECT to_jsonb(board) INTO STRICT v_board_state
  FROM public.boards AS board
  WHERE board.id = v_before.board_id;
  SELECT coalesce(
    jsonb_agg(to_jsonb(membership) ORDER BY membership.user_id),
    '[]'::jsonb
  ) INTO v_memberships_state
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_before.board_id;
  IF v_board_state IS DISTINCT FROM v_before.board_state
    OR v_memberships_state IS DISTINCT FROM v_before.memberships_state
    OR EXISTS (
      SELECT 1
      FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = v_before.board_id
    ) THEN
    RAISE EXCEPTION 'A non-last-member deletion conflict changed board state';
  END IF;
END;
$$;
\echo 'PASS: explicit last-member deletion conflicts while another current member remains'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;

  -- Discard this response to model a successful commit whose HTTP response is lost.
  PERFORM public.leave_board_p(
    v_fixture.operation_id,
    v_fixture.board_id,
    v_fixture.successor_id
  );
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_board_owner_id uuid;
  v_active_owner_count integer;
  v_old_owner_membership_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;
  SELECT board.owner_id INTO v_board_owner_id
  FROM public.boards AS board
  WHERE board.id = v_fixture.board_id;
  SELECT count(*) INTO v_active_owner_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = v_fixture.successor_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL;
  SELECT count(*) INTO v_old_owner_membership_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = v_fixture.owner_id
    AND membership.revoked_at IS NULL;

  IF v_board_owner_id IS DISTINCT FROM v_fixture.successor_id
    OR v_active_owner_count <> 1
    OR v_old_owner_membership_count <> 0 THEN
    RAISE EXCEPTION 'Owner transfer did not leave exactly one current successor and revoke the former owner';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;

  v_result := public.leave_board_p(
    v_fixture.operation_id,
    v_fixture.board_id,
    v_fixture.successor_id
  );
  IF v_result IS DISTINCT FROM jsonb_build_object(
    'status', 'confirmed',
    'operation_id', v_fixture.operation_id
  ) THEN
    RAISE EXCEPTION 'A lost owner-departure response must replay only its minimal receipt: %',
      v_result;
  END IF;
  IF public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'Replaying a departure receipt must not restore board membership';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: a lost owner-departure response replays minimally without restoring access'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_rejected boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;

  BEGIN
    PERFORM public.leave_board_p(
      v_fixture.operation_id,
      v_fixture.board_id,
      '41600000-0000-4000-8000-000000000003'
    );
  EXCEPTION WHEN SQLSTATE '23514' THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Reusing a departure operation id with a different successor must conflict';
  END IF;
  IF public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'A payload conflict must not restore former owner membership';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: a departure operation id cannot be reused with another successor'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_rejected boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;

  BEGIN
    PERFORM public.leave_board_p(
      v_fixture.operation_id,
      v_fixture.board_id,
      v_fixture.successor_id
    );
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'A different actor must not read or replay the former owner receipt';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: departure receipts are isolated to the authenticated actor'

UPDATE public.board_departure_operation_receipts AS receipt
SET result_expires_at = clock_timestamp()
FROM pg_temp.issue17_successful_departure_fixture AS fixture
WHERE receipt.actor_id = fixture.owner_id
  AND receipt.operation_id = fixture.operation_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_successful_departure_fixture;

  v_result := public.leave_board_p(
    v_fixture.operation_id,
    v_fixture.board_id,
    v_fixture.successor_id
  );
  IF v_result IS DISTINCT FROM jsonb_build_object(
    'status', 'expired_unknown',
    'operation_id', v_fixture.operation_id
  ) THEN
    RAISE EXCEPTION 'A receipt at its exact expiry deadline must not replay as confirmed: %',
      v_result;
  END IF;
  IF public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'An expired departure receipt must not restore former owner membership';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: a departure receipt expires at 168 hours without replaying the action'

\echo 'Issue #17 RED: a collaborator can leave without choosing a successor'

CREATE TEMP TABLE issue17_collaborator_departure_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  owner_id uuid NOT NULL,
  collaborator_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  member_episode_id uuid,
  task_id uuid,
  task_assignee_version bigint,
  comment_id uuid,
  departing_invitation_id uuid,
  owner_invitation_id uuid,
  invitation_id uuid
);
GRANT SELECT, INSERT, UPDATE ON issue17_collaborator_departure_fixture TO authenticated;

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
    'Issue 17 collaborator exit',
    'UTC',
    'a7170000-0000-4000-8000-000000000005'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Conservar al salir', 0);
  INSERT INTO pg_temp.issue17_collaborator_departure_fixture (
    board_id, board_slug, column_id, owner_id, collaborator_id, operation_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    v_column.id,
    auth.uid(),
    '41600000-0000-4000-8000-000000000002',
    'a7170000-0000-4000-8000-000000000006'
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT fixture.board_id, fixture.collaborator_id, 'collaborator'
FROM pg_temp.issue17_collaborator_departure_fixture AS fixture;
WITH added_membership AS (
  SELECT membership.board_id, membership.user_id, membership.id
  FROM public.board_memberships AS membership
  JOIN pg_temp.issue17_collaborator_departure_fixture AS fixture
    ON fixture.board_id = membership.board_id
   AND fixture.collaborator_id = membership.user_id
)
UPDATE pg_temp.issue17_collaborator_departure_fixture AS fixture
SET member_episode_id = added_membership.id
FROM added_membership
WHERE added_membership.board_id = fixture.board_id
  AND added_membership.user_id = fixture.collaborator_id;

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
  FROM pg_temp.issue17_collaborator_departure_fixture;
  v_task := public.create_task_p(
    'a7170000-0000-4000-8000-000000000010',
    v_fixture.board_id,
    v_fixture.column_id,
    'Tarea que conserva autoría'
  );
  IF v_task->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The collaborator could not create the task used by the departure test: %',
      v_task;
  END IF;

  v_assignment := public.set_task_assignee_p(
    'a7170000-0000-4000-8000-000000000011',
    v_fixture.board_slug,
    (v_task->>'task_id')::uuid,
    auth.uid(),
    1
  );
  IF v_assignment->>'status' IS DISTINCT FROM 'confirmed'
    OR v_assignment->'task'->>'assignee_version' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'The collaborator could not assign the pending task to themself: %',
      v_assignment;
  END IF;
  UPDATE pg_temp.issue17_collaborator_departure_fixture
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
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  v_comment := public.create_task_comment_p(
    p_operation_id => 'a7170000-0000-4000-8000-000000000012',
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_content => '@issue16-member@example.test conserva autoría',
    p_mentions => '[{"user_id":"41600000-0000-4000-8000-000000000002","start_char":0,"length_chars":28}]'::jsonb
  );
  IF v_comment->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The owner could not create the membership mention used by the departure test: %',
      v_comment;
  END IF;
  UPDATE pg_temp.issue17_collaborator_departure_fixture
  SET comment_id = (v_comment->>'comment_id')::uuid;
END;
$$;
COMMIT;

-- This synthetic pending invitation records the issuer being retired. Current
-- invitation RPCs are owner-only; the fixture exercises issuer cleanup without
-- adding collaborator invitation authority.
WITH departing_invitation AS (
  INSERT INTO public.board_invitations (
    board_id, inviter_id, invitation_type, recipient_id
  )
  SELECT
    fixture.board_id,
    fixture.collaborator_id,
    'direct',
    '40000000-0000-4000-8000-000000000006'
  FROM pg_temp.issue17_collaborator_departure_fixture AS fixture
  RETURNING id, board_id, inviter_id
)
UPDATE pg_temp.issue17_collaborator_departure_fixture AS fixture
SET departing_invitation_id = departing_invitation.id
FROM departing_invitation
WHERE departing_invitation.board_id = fixture.board_id
  AND departing_invitation.inviter_id = fixture.collaborator_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_invitation jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  v_invitation := public.create_direct_board_invitation_p(
    v_fixture.board_slug,
    'enabled-user@example.test'
  );
  IF v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'The owner could not create the invitation that must survive collaborator departure: %',
      v_invitation;
  END IF;
  UPDATE pg_temp.issue17_collaborator_departure_fixture
  SET owner_invitation_id = (v_invitation->>'id')::uuid;
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
  FROM pg_temp.issue17_collaborator_departure_fixture;

  v_result := public.leave_board_p(
    v_fixture.operation_id,
    v_fixture.board_id,
    NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A collaborator must be able to leave without a successor: %',
      v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_board_owner_id uuid;
  v_active_owner_count integer;
  v_active_collaborator_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  SELECT board.owner_id INTO v_board_owner_id
  FROM public.boards AS board
  WHERE board.id = v_fixture.board_id;
  SELECT count(*) INTO v_active_owner_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = v_fixture.owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL;
  SELECT count(*) INTO v_active_collaborator_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = v_fixture.collaborator_id
    AND membership.revoked_at IS NULL;
  IF v_board_owner_id IS DISTINCT FROM v_fixture.owner_id
    OR v_active_owner_count <> 1
    OR v_active_collaborator_count <> 0 THEN
    RAISE EXCEPTION 'Collaborator departure changed board ownership or kept the member active';
  END IF;
END;
$$;
\echo 'PASS: collaborator departure revokes only the departing membership'

DO $$
DECLARE
  v_fixture record;
  v_departing_invitation_status text;
  v_owner_invitation_status text;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  SELECT invitation.status INTO v_departing_invitation_status
  FROM public.board_invitations AS invitation
  WHERE invitation.id = v_fixture.departing_invitation_id;
  SELECT invitation.status INTO v_owner_invitation_status
  FROM public.board_invitations AS invitation
  WHERE invitation.id = v_fixture.owner_invitation_id;
  IF v_departing_invitation_status IS DISTINCT FROM 'revoked' THEN
    RAISE EXCEPTION 'The departing issuer left a pending invitation active: %',
      v_departing_invitation_status;
  END IF;
  IF v_owner_invitation_status IS DISTINCT FROM 'pending' THEN
    RAISE EXCEPTION 'Departing collaborator invalidated another member’s invitation: %',
      v_owner_invitation_status;
  END IF;
END;
$$;
\echo 'PASS: departure revokes only pending invitations issued by the departing member'

DO $$
DECLARE
  v_fixture record;
  v_task_assignee_id uuid;
  v_task_assignee_version bigint;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  SELECT task.assignee_id, task.assignee_version
    INTO v_task_assignee_id, v_task_assignee_version
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'A task assigned to the departing collaborator was deleted';
  END IF;
  IF v_task_assignee_id IS NOT NULL
    OR v_task_assignee_version <> v_fixture.task_assignee_version + 1 THEN
    RAISE EXCEPTION 'Departure did not clear the pending assignment and advance its version (assignee %, version %)',
      v_task_assignee_id, v_task_assignee_version;
  END IF;
END;
$$;
\echo 'PASS: departure clears a pending assignee and advances the assignment version'

DO $$
DECLARE
  v_fixture record;
  v_task public.tasks%ROWTYPE;
  v_comment public.task_comments%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  SELECT comment_row.* INTO v_comment
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = v_fixture.comment_id;
  IF NOT FOUND
    OR v_task.created_by IS DISTINCT FROM v_fixture.collaborator_id
    OR v_task.title IS DISTINCT FROM 'Tarea que conserva autoría'
    OR v_comment.author_id IS DISTINCT FROM v_fixture.owner_id
    OR v_comment.content IS DISTINCT FROM '@issue16-member@example.test conserva autoría' THEN
    RAISE EXCEPTION 'Departure did not preserve task or comment authorship and content';
  END IF;
END;
$$;
\echo 'PASS: departure preserves task and comment authorship'

DO $$
DECLARE
  v_fixture record;
  v_mention public.task_comment_mentions%ROWTYPE;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  SELECT mention.* INTO v_mention
  FROM public.task_comment_mentions AS mention
  WHERE mention.comment_id = v_fixture.comment_id;
  IF NOT FOUND
    OR v_mention.membership_id IS NOT NULL
    OR v_mention.display_text IS DISTINCT FROM '@issue16-member@example.test' THEN
    RAISE EXCEPTION 'Departure did not preserve mention text while freezing its membership identity';
  END IF;
END;
$$;
\echo 'PASS: departure freezes a mention to text without identity'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_invitation jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  v_invitation := public.create_direct_board_invitation_p(
    v_fixture.board_slug,
    'issue16-member@example.test'
  );
  IF v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'The owner could not create a re-entry invitation: %', v_invitation;
  END IF;
  UPDATE pg_temp.issue17_collaborator_departure_fixture
  SET invitation_id = (v_invitation->>'id')::uuid;
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
  FROM pg_temp.issue17_collaborator_departure_fixture;
  v_result := public.accept_direct_board_invitation_p(
    v_fixture.invitation_id,
    'a7170000-0000-4000-8000-000000000013'
  );
  IF v_result->>'status' IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'The collaborator could not rejoin as a new membership episode: %',
      v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_current_episode_id uuid;
  v_task_assignee_id uuid;
  v_task_assignee_version bigint;
  v_old_mention_membership_id uuid;
  v_comment_page jsonb;
  v_comment jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_collaborator_departure_fixture;
  SELECT membership.id INTO STRICT v_current_episode_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = v_fixture.collaborator_id
    AND membership.revoked_at IS NULL;
  SELECT task.assignee_id, task.assignee_version
    INTO v_task_assignee_id, v_task_assignee_version
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  SELECT mention.membership_id INTO v_old_mention_membership_id
  FROM public.task_comment_mentions AS mention
  WHERE mention.comment_id = v_fixture.comment_id;

  IF v_current_episode_id IS NOT DISTINCT FROM v_fixture.member_episode_id
    OR v_task_assignee_id IS NOT NULL
    OR v_task_assignee_version <> v_fixture.task_assignee_version + 1
    OR v_old_mention_membership_id IS NOT NULL THEN
    RAISE EXCEPTION 'Rejoining restored a previous role episode, assignment, or mention identity';
  END IF;

  PERFORM set_config(
    'request.jwt.claim.sub',
    v_fixture.owner_id::text,
    true
  );
  v_comment_page := public.get_task_comments_p(
    p_slug => v_fixture.board_slug,
    p_task_id => v_fixture.task_id,
    p_limit => 20
  );
  SELECT row_value INTO STRICT v_comment
  FROM pg_catalog.jsonb_array_elements(v_comment_page->'comments') AS row_value
  WHERE row_value->>'id' = v_fixture.comment_id::text;
  IF v_comment->'mentions'->0->>'text' IS DISTINCT FROM '@issue16-member@example.test'
    OR v_comment->'mentions'->0 ? 'user_id' THEN
    RAISE EXCEPTION 'A rejoined member regained identity on an old mention: %', v_comment;
  END IF;
END;
$$;

\echo 'Issue #17 RED: departure preserves authorship and text while clearing assignment and mention identity'

CREATE TEMP TABLE issue17_last_member_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  owner_id uuid NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  comment_id uuid NOT NULL,
  invitation_id uuid NOT NULL,
  ordinary_leave_operation_id uuid NOT NULL,
  delete_operation_id uuid NOT NULL,
  expected_expires_at timestamptz
);
GRANT SELECT, INSERT, UPDATE ON issue17_last_member_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_assignment jsonb;
  v_comment jsonb;
  v_invitation jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 17 last member recovery',
    'UTC',
    'a7170000-0000-4000-8000-000000000083'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Datos recuperables', 0);
  v_task := public.create_task_p(
    'a7170000-0000-4000-8000-000000000084',
    v_board.id,
    v_column.id,
    'Tarea que debe permanecer en recuperación',
    'Contenido conservado'
  );
  v_assignment := public.set_task_assignee_p(
    'a7170000-0000-4000-8000-000000000085',
    v_board.slug,
    (v_task->>'task_id')::uuid,
    auth.uid(),
    1
  );
  v_comment := public.create_task_comment_p(
    'a7170000-0000-4000-8000-000000000086',
    v_board.slug,
    (v_task->>'task_id')::uuid,
    'Conversación que debe permanecer en recuperación',
    '[]'::jsonb
  );
  v_invitation := public.create_board_invitation_link_p(
    v_board.slug,
    'a7170000-0000-4000-8000-000000000087',
    repeat('c', 64)
  );
  IF v_task->>'status' IS DISTINCT FROM 'confirmed'
    OR v_assignment->>'status' IS DISTINCT FROM 'confirmed'
    OR v_comment->>'status' IS DISTINCT FROM 'confirmed'
    OR v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'The last-member recovery fixture is incomplete: task %, assignment %, comment %, invitation %',
      v_task->>'status', v_assignment->>'status',
      v_comment->>'status', v_invitation->>'status';
  END IF;

  INSERT INTO pg_temp.issue17_last_member_fixture (
    board_id, board_slug, owner_id, column_id, task_id, comment_id,
    invitation_id, ordinary_leave_operation_id, delete_operation_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    v_column.id,
    (v_task->>'task_id')::uuid,
    (v_comment->>'comment_id')::uuid,
    (v_invitation->>'id')::uuid,
    'a7170000-0000-4000-8000-000000000088',
    'a7170000-0000-4000-8000-000000000089'
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
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue17_last_member_fixture;
  IF public.has_other_current_board_members_p(v_fixture.board_id) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'The server did not report a true last-current-member board';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: departure options confirm when no other current member remains'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_last_member_fixture;
  v_result := public.leave_board_p(
    v_fixture.ordinary_leave_operation_id,
    v_fixture.board_id,
    NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict' THEN
    RAISE EXCEPTION 'Ordinary owner leave must not imply last-member recovery: %', v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_owner_id uuid;
  v_active_members integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_last_member_fixture;
  PERFORM set_config('request.jwt.claim.sub', v_fixture.owner_id::text, true);
  SELECT board.owner_id INTO v_owner_id
  FROM public.boards AS board
  WHERE board.id = v_fixture.board_id;
  SELECT count(*) INTO v_active_members
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.revoked_at IS NULL;
  IF v_owner_id IS DISTINCT FROM v_fixture.owner_id
    OR v_active_members <> 1
    OR NOT public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'Ordinary NULL-successor leave changed a last-member board without confirmation';
  END IF;
END;
$$;
\echo 'PASS: ordinary last-owner leave requires an explicit separate confirmation'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_last_member_fixture;
  v_result := public.delete_last_member_board_p(
    v_fixture.delete_operation_id,
    v_fixture.board_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'recoverable' THEN
    RAISE EXCEPTION 'An explicitly confirmed last-owner deletion must be recoverable: %',
      v_result;
  END IF;
  IF v_result->>'expires_at' IS NULL OR public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'Recoverable deletion did not close ordinary membership access: %',
      v_result;
  END IF;
  UPDATE pg_temp.issue17_last_member_fixture
  SET expected_expires_at = (v_result->>'expires_at')::timestamptz;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_recovery public.board_recoverable_deletions%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_comment public.task_comments%ROWTYPE;
  v_invitation_status text;
  v_active_member_count integer;
  v_column_count integer;
  v_task_count integer;
  v_comment_count integer;
  v_receipt_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_last_member_fixture;
  SELECT * INTO STRICT v_recovery
  FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = v_fixture.board_id;
  SELECT * INTO STRICT v_board
  FROM public.boards AS board
  WHERE board.id = v_fixture.board_id;
  SELECT * INTO STRICT v_task
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  SELECT * INTO STRICT v_comment
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = v_fixture.comment_id;
  SELECT invitation.status INTO STRICT v_invitation_status
  FROM public.board_invitations AS invitation
  WHERE invitation.id = v_fixture.invitation_id;
  SELECT count(*) INTO v_active_member_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.revoked_at IS NULL;
  SELECT count(*) INTO v_column_count
  FROM public.columns AS column_row
  WHERE column_row.board_id = v_fixture.board_id;
  SELECT count(*) INTO v_task_count
  FROM public.tasks AS task
  JOIN public.columns AS column_row ON column_row.id = task.column_id
  WHERE column_row.board_id = v_fixture.board_id;
  SELECT count(*) INTO v_comment_count
  FROM public.task_comments AS comment_row
  WHERE comment_row.board_id = v_fixture.board_id;
  SELECT count(*) INTO v_receipt_count
  FROM public.board_departure_operation_receipts AS receipt
  WHERE receipt.actor_id = v_fixture.owner_id
    AND receipt.operation_id = v_fixture.delete_operation_id
    AND receipt.action = 'delete_last_member'
    AND receipt.result_status = 'recoverable';

  IF v_recovery.actor_id IS DISTINCT FROM v_fixture.owner_id
    OR v_recovery.cause IS DISTINCT FROM 'owner_confirmed_last_member'
    OR v_recovery.deleted_at IS NULL
    OR v_recovery.expires_at IS DISTINCT FROM (
      v_recovery.deleted_at + interval '168 hours'
    )
    OR v_recovery.expires_at IS DISTINCT FROM v_fixture.expected_expires_at
    OR v_board.owner_id IS DISTINCT FROM v_fixture.owner_id
    OR v_column_count <> 1
    OR v_task_count <> 1
    OR v_task.created_by IS DISTINCT FROM v_fixture.owner_id
    OR v_task.title IS DISTINCT FROM 'Tarea que debe permanecer en recuperación'
    OR v_task.description IS DISTINCT FROM 'Contenido conservado'
    OR v_task.assignee_id IS NOT NULL
    OR v_task.assignee_version <> 3
    OR v_comment.author_id IS DISTINCT FROM v_fixture.owner_id
    OR v_comment.content IS DISTINCT FROM 'Conversación que debe permanecer en recuperación'
    OR v_comment_count <> 1
    OR v_invitation_status IS DISTINCT FROM 'revoked'
    OR v_active_member_count <> 0
    OR v_receipt_count <> 1
    OR to_jsonb(v_recovery) ?| ARRAY['title', 'content', 'task_text'] THEN
    RAISE EXCEPTION 'Recoverable deletion lost board content or has incorrect actor/cause/window metadata';
  END IF;
END;
$$;
\echo 'PASS: confirmed last-owner deletion retains content and records exact 168-hour recovery metadata'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_full_board json;
  v_visible_board_count integer;
  v_visible_task_count integer;
  v_direct_board_count integer;
  v_write_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_last_member_fixture;
  IF public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'A recoverable board still grants ordinary membership';
  END IF;
  v_full_board := public.get_full_board_p(v_fixture.board_slug);
  IF v_full_board IS NOT NULL THEN
    RAISE EXCEPTION 'A recoverable board is visible through the ordinary board read';
  END IF;
  SELECT count(*) INTO v_visible_board_count
  FROM public.list_my_boards() AS board
  WHERE board.id = v_fixture.board_id;
  SELECT count(*) INTO v_visible_task_count
  FROM public.get_my_tasks_p('due');
  SELECT count(*) INTO v_direct_board_count
  FROM public.boards AS board
  WHERE board.id = v_fixture.board_id;
  IF v_visible_board_count <> 0
    OR v_visible_task_count <> 0
    OR v_direct_board_count <> 0 THEN
    RAISE EXCEPTION 'A recoverable board remained visible through ordinary board/task lists';
  END IF;

  BEGIN
    PERFORM public.create_column_p(
      v_fixture.board_slug,
      v_fixture.board_id,
      'No debe persistir',
      1
    );
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_write_denied := true;
  END;
  IF NOT v_write_denied THEN
    RAISE EXCEPTION 'An ordinary board write succeeded after recoverable deletion';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: recoverable boards are hidden from ordinary reads and reject writes'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue17_last_member_fixture;
  v_result := public.delete_last_member_board_p(
    v_fixture.delete_operation_id,
    v_fixture.board_id
  );
  IF v_result IS DISTINCT FROM jsonb_build_object(
    'status', 'recoverable',
    'operation_id', v_fixture.delete_operation_id,
    'expires_at', v_fixture.expected_expires_at
  ) THEN
    RAISE EXCEPTION 'A lost last-owner deletion response did not replay minimally: %',
      v_result;
  END IF;
  IF public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'Recoverable deletion replay restored membership';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: last-owner recovery receipt replays after membership revocation'

CREATE TABLE public.issue17_departure_concurrency_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  actor_id uuid NOT NULL,
  successor_id uuid NOT NULL,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT ON public.issue17_departure_concurrency_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 17 same-operation concurrency',
    'UTC',
    'a7170000-0000-4000-8000-000000000070'
  );
  INSERT INTO public.issue17_departure_concurrency_fixture (
    board_id, board_slug, actor_id, successor_id, operation_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    '41600000-0000-4000-8000-000000000002',
    'a7170000-0000-4000-8000-000000000071'
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT fixture.board_id, fixture.successor_id, 'collaborator'
FROM public.issue17_departure_concurrency_fixture AS fixture;
