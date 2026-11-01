\set ON_ERROR_STOP on
\echo 'Issue #18 RED: board deletion must retain a hidden board for recovery'

CREATE TEMP TABLE issue18_board_recovery_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  owner_id uuid NOT NULL,
  collaborator_id uuid NOT NULL,
  revoked_collaborator_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  restore_operation_id uuid NOT NULL,
  task_id uuid NOT NULL,
  deleted_task_id uuid NOT NULL,
  deleted_task_expires_at timestamptz,
  invitation_id uuid NOT NULL,
  expected_expires_at timestamptz
);
GRANT SELECT, INSERT, UPDATE ON issue18_board_recovery_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_deleted_task jsonb;
  v_task_delete_result jsonb;
  v_invitation jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 18 recoverable board',
    'UTC',
    'a8180000-0000-4000-8000-000000000001'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Contenido privado', 0);
  v_task := public.create_task_p(
    'a8180000-0000-4000-8000-000000000002',
    v_board.id,
    v_column.id,
    'Tarea privada que se conserva'
  );
  v_deleted_task := public.create_task_p(
    'a8180000-0000-4000-8000-000000000005',
    v_board.id,
    v_column.id,
    'Tarea borrada independientemente'
  );
  v_task_delete_result := public.delete_task_p(
    'a8180000-0000-4000-8000-000000000006',
    v_board.slug,
    (v_deleted_task->>'task_id')::uuid
  );
  IF v_task_delete_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The independent task recovery fixture could not be created: %', v_task_delete_result;
  END IF;
  v_invitation := public.create_direct_board_invitation_p(
    v_board.slug,
    'enabled-user@example.test'
  );
  INSERT INTO pg_temp.issue18_board_recovery_fixture (
    board_id, board_slug, owner_id, collaborator_id, revoked_collaborator_id,
    operation_id, restore_operation_id, task_id, deleted_task_id,
    deleted_task_expires_at, invitation_id
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    '41600000-0000-4000-8000-000000000002',
    '40000000-0000-4000-8000-000000000005',
    'a8180000-0000-4000-8000-000000000003',
    'a8180000-0000-4000-8000-000000000004',
    (v_task->>'task_id')::uuid,
    (v_deleted_task->>'task_id')::uuid,
    NULL,
    (v_invitation->>'id')::uuid
  );
END;
$$;
COMMIT;

UPDATE pg_temp.issue18_board_recovery_fixture AS fixture
SET deleted_task_expires_at = deletion.expires_at
FROM public.task_deletions AS deletion
WHERE deletion.task_id = fixture.deleted_task_id;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT fixture.board_id, fixture.collaborator_id, 'collaborator'
FROM pg_temp.issue18_board_recovery_fixture AS fixture;
INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT fixture.board_id, fixture.revoked_collaborator_id, 'collaborator'
FROM pg_temp.issue18_board_recovery_fixture AS fixture;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
  v_expires_at timestamptz;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM pg_temp.issue18_board_recovery_fixture;

  v_result := public.delete_board_p(
    v_fixture.operation_id,
    v_fixture.board_slug,
    v_fixture.board_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'recoverable'
    OR v_result->>'expires_at' IS NULL THEN
    RAISE EXCEPTION 'Board deletion did not return a recovery deadline: %', v_result;
  END IF;
  v_expires_at := (v_result->>'expires_at')::timestamptz;
  UPDATE pg_temp.issue18_board_recovery_fixture
  SET expected_expires_at = v_expires_at;

  IF v_expires_at - clock_timestamp() > interval '168 hours'
    OR public.is_board_member(v_fixture.board_id)
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL THEN
    RAISE EXCEPTION 'Deletion did not hide the board from its owner or return a valid recovery deadline';
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
  v_listed boolean;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_board_recovery_fixture;
  SELECT EXISTS (
    SELECT 1 FROM public.admin_list_recoverable_boards_p() AS recovery
    WHERE recovery.id = v_fixture.board_id
      AND recovery.cause = 'owner_requested'
      AND recovery.owner_is_valid
  ) INTO v_listed;
  IF NOT v_listed
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL
    OR public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'Admin recovery metadata must include the board without granting content access';
  END IF;
  BEGIN
    PERFORM public.restore_board_p(
      'a8180000-0000-4000-8000-000000000007',
      v_fixture.board_id,
      NULL
    );
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_denied := true;
  END;
  IF NOT v_denied OR public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'An unrelated administrator restored a board with a valid current owner';
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_recovery public.board_recoverable_deletions%ROWTYPE;
  v_active_members integer;
  v_task_title text;
  v_child_expires_at timestamptz;
  v_invitation_status text;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_board_recovery_fixture;
  SELECT * INTO STRICT v_recovery
  FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = v_fixture.board_id;
  SELECT count(*) INTO v_active_members
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.revoked_at IS NULL;
  SELECT task.title INTO STRICT v_task_title
  FROM public.tasks AS task
  WHERE task.id = v_fixture.task_id;
  SELECT deletion.expires_at INTO STRICT v_child_expires_at
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = v_fixture.deleted_task_id
    AND deletion.state = 'deleted';
  SELECT invitation.status INTO STRICT v_invitation_status
  FROM public.board_invitations AS invitation
  WHERE invitation.id = v_fixture.invitation_id;
  IF v_recovery.cause IS DISTINCT FROM 'owner_requested'
    OR v_recovery.actor_id IS DISTINCT FROM v_fixture.owner_id
    OR v_recovery.expires_at IS DISTINCT FROM v_fixture.expected_expires_at
    OR v_active_members <> 3
    OR v_task_title IS DISTINCT FROM 'Tarea privada que se conserva'
    OR v_child_expires_at IS DISTINCT FROM v_fixture.deleted_task_expires_at
    OR v_invitation_status IS DISTINCT FROM 'revoked' THEN
    RAISE EXCEPTION 'The recovery ledger must preserve content and current memberships with an exact deadline';
  END IF;
END;
$$;

UPDATE public.board_memberships AS membership
SET revoked_at = clock_timestamp()
FROM pg_temp.issue18_board_recovery_fixture AS fixture
WHERE membership.board_id = fixture.board_id
  AND membership.user_id = fixture.revoked_collaborator_id
  AND membership.revoked_at IS NULL;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_board_recovery_fixture;
  v_result := public.restore_board_p(
    v_fixture.restore_operation_id,
    v_fixture.board_id,
    NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'expires_at')::timestamptz IS DISTINCT FROM v_fixture.expected_expires_at
    OR v_result->>'owner_id' IS DISTINCT FROM v_fixture.owner_id::text
    OR NOT public.is_board_member(v_fixture.board_id)
    OR public.get_full_board_p(v_fixture.board_slug) IS NULL THEN
    RAISE EXCEPTION 'The current enabled owner could not restore the board: %', v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_active_members integer;
  v_invitation_status text;
  v_deleted_task_count integer;
  v_child_expires_at timestamptz;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_board_recovery_fixture;
  SELECT count(*) INTO v_active_members
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.revoked_at IS NULL;
  SELECT invitation.status INTO STRICT v_invitation_status
  FROM public.board_invitations AS invitation
  WHERE invitation.id = v_fixture.invitation_id;
  SELECT count(*) INTO v_deleted_task_count
  FROM public.tasks AS task
  WHERE task.id = v_fixture.deleted_task_id;
  SELECT deletion.expires_at INTO STRICT v_child_expires_at
  FROM public.task_deletions AS deletion
  WHERE deletion.task_id = v_fixture.deleted_task_id
    AND deletion.state = 'deleted';
  IF EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = v_fixture.board_id
    )
    OR v_active_members <> 2
    OR v_invitation_status IS DISTINCT FROM 'revoked'
    OR v_deleted_task_count <> 0
    OR v_child_expires_at IS DISTINCT FROM v_fixture.deleted_task_expires_at THEN
    RAISE EXCEPTION 'Restore resurrected a withdrawn membership/invitation/task or reset a child deadline';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
DO $$
DECLARE v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_board_recovery_fixture;
  IF NOT public.is_board_member(v_fixture.board_id)
    OR public.get_full_board_p(v_fixture.board_slug) IS NULL THEN
    RAISE EXCEPTION 'A membership that remained current during recovery was not retained';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_board_recovery_fixture;
  IF public.is_board_member(v_fixture.board_id)
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL THEN
    RAISE EXCEPTION 'A membership independently withdrawn in recovery was restored';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: ordinary board deletion preserves current membership episodes, revokes invitations, and restores only current members'

CREATE TEMP TABLE issue18_admin_recovery_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  former_owner_id uuid NOT NULL,
  task_id uuid NOT NULL,
  expires_at timestamptz NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON issue18_admin_recovery_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_deleted jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 18 ownerless recovery',
    'UTC',
    'a8180000-0000-4000-8000-000000000101'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Contenido oculto', 0);
  v_task := public.create_task_p(
    'a8180000-0000-4000-8000-000000000102',
    v_board.id,
    v_column.id,
    'Contenido privado no visible para admin'
  );
  v_deleted := public.delete_last_member_board_p(
    'a8180000-0000-4000-8000-000000000103',
    v_board.id
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'recoverable' THEN
    RAISE EXCEPTION 'The last-member board was not placed into recovery: %', v_deleted;
  END IF;
  INSERT INTO pg_temp.issue18_admin_recovery_fixture (
    board_id, board_slug, former_owner_id, task_id, expires_at
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    (v_task->>'task_id')::uuid,
    (v_deleted->>'expires_at')::timestamptz
  );
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_recovery record;
  v_owner_options integer;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_admin_recovery_fixture;
  SELECT * INTO STRICT v_recovery
  FROM public.admin_list_recoverable_boards_p() AS recovery
  WHERE recovery.id = v_fixture.board_id;
  SELECT count(*) INTO v_owner_options
  FROM public.admin_list_recovery_owners_p(v_fixture.board_id) AS owner_option
  WHERE owner_option.user_id = '40000000-0000-4000-8000-000000000002';

  IF v_recovery.owner_is_valid
    OR v_recovery.active_member_count <> 0
    OR v_recovery.cause IS DISTINCT FROM 'owner_confirmed_last_member'
    OR to_jsonb(v_recovery) ? 'task_title'
    OR v_owner_options <> 1
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL
    OR public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'Admin recovery must list metadata and eligible identities without content or membership';
  END IF;

  v_result := public.restore_board_p(
    'a8180000-0000-4000-8000-000000000104',
    v_fixture.board_id,
    NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'owner_required'
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL THEN
    RAISE EXCEPTION 'An ownerless recoverable board must require an explicit owner choice: %', v_result;
  END IF;

  v_result := public.restore_board_p(
    'a8180000-0000-4000-8000-000000000105',
    v_fixture.board_id,
    v_fixture.former_owner_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL THEN
    RAISE EXCEPTION 'A previously removed owner was offered as a recovery choice: %', v_result;
  END IF;

  v_result := public.restore_board_p(
    'a8180000-0000-4000-8000-000000000106',
    v_fixture.board_id,
    '40000000-0000-4000-8000-000000000002'
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->>'owner_id' IS DISTINCT FROM '40000000-0000-4000-8000-000000000002'
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL
    OR public.is_board_member(v_fixture.board_id) THEN
    RAISE EXCEPTION 'Admin recovery did not assign the chosen owner without granting admin content access: %', v_result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
  v_owner_id uuid;
  v_owner_membership_count integer;
  v_former_owner_current boolean;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_admin_recovery_fixture;
  SELECT board.owner_id INTO STRICT v_owner_id
  FROM public.boards AS board WHERE board.id = v_fixture.board_id;
  SELECT count(*) INTO v_owner_membership_count
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_fixture.board_id
    AND membership.user_id = v_owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL;
  SELECT EXISTS (
    SELECT 1 FROM public.board_memberships AS membership
    WHERE membership.board_id = v_fixture.board_id
      AND membership.user_id = v_fixture.former_owner_id
      AND membership.revoked_at IS NULL
  ) INTO v_former_owner_current;
  IF v_owner_id IS DISTINCT FROM '40000000-0000-4000-8000-000000000002'
    OR v_owner_membership_count <> 1
    OR v_former_owner_current THEN
    RAISE EXCEPTION 'Admin recovery revived the former owner or failed to create the chosen owner episode';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_admin_recovery_fixture;
  IF NOT public.is_board_member(v_fixture.board_id)
    OR public.get_full_board_p(v_fixture.board_slug) IS NULL THEN
    RAISE EXCEPTION 'The explicitly selected owner did not receive the restored board';
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
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_admin_recovery_fixture;
  IF public.is_board_member(v_fixture.board_id)
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL THEN
    RAISE EXCEPTION 'The administrator acquired content access after assigning a new owner';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: an administrator can resolve an ownerless board from metadata and explicit active-owner selection without content access'

CREATE TEMP TABLE issue18_expired_recovery_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  owner_id uuid NOT NULL,
  task_id uuid NOT NULL,
  child_task_id uuid NOT NULL,
  child_expires_at timestamptz
);
GRANT SELECT, INSERT, UPDATE ON issue18_expired_recovery_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_task jsonb;
  v_child jsonb;
  v_child_delete jsonb;
  v_board_delete jsonb;
BEGIN
  SELECT * INTO STRICT v_board
  FROM public.create_board_p(
    'Issue 18 expired board',
    'UTC',
    'a8180000-0000-4000-8000-000000000201'
  );
  SELECT * INTO STRICT v_column
  FROM public.create_column_p(v_board.slug, v_board.id, 'Purgable', 0);
  v_task := public.create_task_p(
    'a8180000-0000-4000-8000-000000000202',
    v_board.id,
    v_column.id,
    'Tarea de tablero expirado'
  );
  v_child := public.create_task_p(
    'a8180000-0000-4000-8000-000000000203',
    v_board.id,
    v_column.id,
    'Hijo borrado por separado'
  );
  v_child_delete := public.delete_task_p(
    'a8180000-0000-4000-8000-000000000204',
    v_board.slug,
    (v_child->>'task_id')::uuid
  );
  v_board_delete := public.delete_board_p(
    'a8180000-0000-4000-8000-000000000205',
    v_board.slug,
    v_board.id
  );
  IF v_child_delete->>'status' IS DISTINCT FROM 'confirmed'
    OR v_board_delete->>'status' IS DISTINCT FROM 'recoverable' THEN
    RAISE EXCEPTION 'The expired purge fixture did not enter both recovery windows';
  END IF;
  INSERT INTO pg_temp.issue18_expired_recovery_fixture (
    board_id, board_slug, owner_id, task_id, child_task_id, child_expires_at
  ) VALUES (
    v_board.id,
    v_board.slug,
    auth.uid(),
    (v_task->>'task_id')::uuid,
    (v_child->>'task_id')::uuid,
    NULL
  );
END;
$$;
COMMIT;

UPDATE pg_temp.issue18_expired_recovery_fixture AS fixture
SET child_expires_at = deletion.expires_at
FROM public.task_deletions AS deletion
WHERE deletion.task_id = fixture.child_task_id;

WITH expiry_clock AS MATERIALIZED (
  SELECT clock_timestamp() AS expires_at
)
UPDATE public.board_recoverable_deletions AS recovery
SET deleted_at = expiry_clock.expires_at - interval '168 hours',
    expires_at = expiry_clock.expires_at
FROM pg_temp.issue18_expired_recovery_fixture AS fixture
CROSS JOIN expiry_clock
WHERE recovery.board_id = fixture.board_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_fixture record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_expired_recovery_fixture;
  v_result := public.restore_board_p(
    'a8180000-0000-4000-8000-000000000206',
    v_fixture.board_id,
    NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired'
    OR public.is_board_member(v_fixture.board_id)
    OR public.get_full_board_p(v_fixture.board_slug) IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM public.list_my_recoverable_boards_p() AS recovery
      WHERE recovery.id = v_fixture.board_id
    ) THEN
    RAISE EXCEPTION 'Restoration at the exact seven-day deadline must be denied: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_purged integer;
BEGIN
  v_purged := public.purge_expired_boards_p(100);
  IF v_purged <> 1 THEN
    RAISE EXCEPTION 'The service-role purge should remove one expired board, removed %', v_purged;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_fixture record;
BEGIN
  SELECT * INTO STRICT v_fixture FROM pg_temp.issue18_expired_recovery_fixture;
  IF EXISTS (SELECT 1 FROM public.boards WHERE id = v_fixture.board_id)
    OR EXISTS (SELECT 1 FROM public.task_deletions WHERE board_id = v_fixture.board_id)
    OR EXISTS (SELECT 1 FROM public.tasks WHERE id = v_fixture.task_id)
    OR EXISTS (SELECT 1 FROM public.task_deletions WHERE task_id = v_fixture.child_task_id) THEN
    RAISE EXCEPTION 'Expired board purge left parent content or independent child recovery data';
  END IF;
END;
$$;

\echo 'PASS: exact seven-day expiry rejects restore and purges the board with its independently deleted child metadata'

CREATE TABLE public.issue18_board_recovery_race_fixture (
  scenario text PRIMARY KEY,
  board_id uuid NOT NULL UNIQUE,
  board_slug text NOT NULL,
  task_id uuid NOT NULL UNIQUE
);
GRANT SELECT, INSERT ON public.issue18_board_recovery_race_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_case record;
  v_board record;
  v_column record;
  v_task jsonb;
  v_delete_result jsonb;
BEGIN
  FOR v_case IN
    SELECT * FROM (VALUES
      ('purge_wins'::text, true, 'a8180000-0000-4000-8000-000000000401'::uuid,
        'a8180000-0000-4000-8000-000000000411'::uuid,
        'a8180000-0000-4000-8000-000000000421'::uuid),
      ('restore_wins', true, 'a8180000-0000-4000-8000-000000000402'::uuid,
        'a8180000-0000-4000-8000-000000000412'::uuid,
        'a8180000-0000-4000-8000-000000000422'::uuid),
      ('edit_wins', false, 'a8180000-0000-4000-8000-000000000403'::uuid,
        'a8180000-0000-4000-8000-000000000413'::uuid, NULL::uuid),
      ('delete_wins', false, 'a8180000-0000-4000-8000-000000000404'::uuid,
        'a8180000-0000-4000-8000-000000000414'::uuid, NULL::uuid)
    ) AS cases(scenario, should_delete, create_operation_id, task_operation_id, delete_operation_id)
  LOOP
    SELECT * INTO STRICT v_board
    FROM public.create_board_p(
      'Issue 18 recovery race ' || v_case.scenario,
      'UTC',
      v_case.create_operation_id
    );
    SELECT * INTO STRICT v_column
    FROM public.create_column_p(v_board.slug, v_board.id, 'Contenido', 0);
    v_task := public.create_task_p(
      v_case.task_operation_id,
      v_board.id,
      v_column.id,
      'Título inicial ' || v_case.scenario
    );
    INSERT INTO public.issue18_board_recovery_race_fixture (
      scenario, board_id, board_slug, task_id
    ) VALUES (
      v_case.scenario, v_board.id, v_board.slug, (v_task->>'task_id')::uuid
    );

    IF v_case.should_delete THEN
      v_delete_result := public.delete_board_p(
        v_case.delete_operation_id, v_board.slug, v_board.id
      );
      IF v_delete_result->>'status' IS DISTINCT FROM 'recoverable' THEN
        RAISE EXCEPTION 'The % board recovery race fixture could not be deleted: %',
          v_case.scenario, v_delete_result;
      END IF;
    END IF;
  END LOOP;
END;
$$;
COMMIT;

UPDATE public.board_recoverable_deletions AS recovery
SET deleted_at = '2020-10-26 12:00:00+00'::timestamptz - interval '168 hours',
    expires_at = '2020-10-26 12:00:00+00'::timestamptz
FROM public.issue18_board_recovery_race_fixture AS fixture
WHERE fixture.board_id = recovery.board_id;

\echo 'PASS: board recovery race fixtures cover purge/restore and content/delete ordering'
