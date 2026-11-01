\set ON_ERROR_STOP on
\echo 'Testing invitation command replay after discarded responses'

CREATE TEMP TABLE issue12_invitation_operation_refs (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  create_operation_id uuid NOT NULL,
  accept_operation_id uuid NOT NULL,
  direct_invitation_id uuid NOT NULL,
  direct_accept_operation_id uuid NOT NULL,
  token text NOT NULL,
  second_token text NOT NULL
);
GRANT SELECT, INSERT ON issue12_invitation_operation_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_direct jsonb;
  v_token constant text := repeat('a', 64);
  v_second_token constant text := repeat('b', 64);
  v_create_operation constant uuid := '11220000-0000-4000-8000-000000000001';
  v_second_operation constant uuid := '11220000-0000-4000-8000-000000000002';
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Idempotencia de invitaciones', 'UTC', 'd1220000-0000-4000-8000-000000000001'
  );

  -- Discard the result; the next command runs after this transaction commits.
  PERFORM public.create_board_invitation_link_p(
    v_board.slug, v_create_operation, v_token
  );
  PERFORM public.create_board_invitation_link_p(
    v_board.slug, v_second_operation, v_second_token
  );
  v_direct := public.create_direct_board_invitation_p(
    v_board.slug, 'second-admin@example.test'
  );
  IF v_direct->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Could not create a direct acceptance fixture: %', v_direct;
  END IF;
  INSERT INTO pg_temp.issue12_invitation_operation_refs(
    board_id, board_slug, create_operation_id, accept_operation_id,
    direct_invitation_id, direct_accept_operation_id, token, second_token
  ) VALUES (
    v_board.id, v_board.slug, v_create_operation,
    '11220000-0000-4000-8000-000000000003',
    (v_direct->>'id')::uuid, '11220000-0000-4000-8000-000000000006',
    v_token, v_second_token
  );
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref record;
  v_replay jsonb;
  v_conflict boolean := false;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_operation_refs;
  v_replay := public.create_board_invitation_link_p(
    v_ref.board_slug, v_ref.create_operation_id, v_ref.token
  );
  IF v_replay->>'status' IS DISTINCT FROM 'created'
    OR v_replay->>'token' IS DISTINCT FROM v_ref.token
    OR (SELECT count(*) FROM public.list_board_invitations_p(v_ref.board_slug)
      WHERE invitation_type = 'generic') <> 2 THEN
    RAISE EXCEPTION 'Lost create response did not return the same single link: %', v_replay;
  END IF;

  BEGIN
    PERFORM public.create_board_invitation_link_p(
      v_ref.board_slug, v_ref.create_operation_id, v_ref.second_token
    );
  EXCEPTION WHEN check_violation THEN
    v_conflict := true;
  END;
  IF NOT v_conflict OR public.preview_board_invitation_p(v_ref.second_token)->>'status'
      IS DISTINCT FROM 'available' THEN
    RAISE EXCEPTION 'A create key accepted a different token or consumed the other link';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_ref record;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_operation_refs;
  -- Commit the membership mutation without retaining its response.
  PERFORM public.accept_board_invitation_link_p(
    v_ref.token, v_ref.accept_operation_id
  );
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_ref record;
  v_replay jsonb;
  v_membership_count integer;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_operation_refs;
  v_replay := public.accept_board_invitation_link_p(
    v_ref.token, v_ref.accept_operation_id
  );
  IF v_replay->>'status' IS DISTINCT FROM 'accepted'
    OR v_replay->>'board_slug' IS DISTINCT FROM v_ref.board_slug THEN
    RAISE EXCEPTION 'Lost generic acceptance response did not reconcile: %', v_replay;
  END IF;
  SELECT count(*) INTO v_membership_count
  FROM public.list_my_boards() AS board
  WHERE board.slug = v_ref.board_slug
    AND board.role = 'collaborator';
  IF v_membership_count <> 1 THEN
    RAISE EXCEPTION 'Generic acceptance replay created % memberships', v_membership_count;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_ref record;
  v_conflict boolean := false;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_operation_refs;
  BEGIN
    PERFORM public.accept_board_invitation_link_p(
      v_ref.second_token, v_ref.accept_operation_id
    );
  EXCEPTION WHEN check_violation THEN
    v_conflict := true;
  END;
  IF NOT v_conflict OR public.preview_board_invitation_p(v_ref.second_token)->>'status'
      IS DISTINCT FROM 'available' THEN
    RAISE EXCEPTION 'An accept key accepted a different token or consumed it';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_ref record;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_operation_refs;
  PERFORM public.accept_direct_board_invitation_p(
    v_ref.direct_invitation_id, v_ref.direct_accept_operation_id
  );
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_ref record;
  v_replay jsonb;
  v_membership_count integer;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_operation_refs;
  v_replay := public.accept_direct_board_invitation_p(
    v_ref.direct_invitation_id, v_ref.direct_accept_operation_id
  );
  IF v_replay->>'status' IS DISTINCT FROM 'accepted'
    OR v_replay->>'board_slug' IS DISTINCT FROM v_ref.board_slug THEN
    RAISE EXCEPTION 'Lost direct acceptance response did not reconcile: %', v_replay;
  END IF;
  SELECT count(*) INTO v_membership_count
  FROM public.list_my_boards() AS board
  WHERE board.slug = v_ref.board_slug
    AND board.role = 'collaborator';
  IF v_membership_count <> 1 THEN
    RAISE EXCEPTION 'Direct acceptance replay created % memberships', v_membership_count;
  END IF;
END;
$$;
COMMIT;

RESET ROLE;
UPDATE public.board_invitation_operation_receipts AS receipt
SET result_expires_at = clock_timestamp() - interval '1 second'
FROM pg_temp.issue12_invitation_operation_refs AS reference
WHERE receipt.actor_id = '40000000-0000-4000-8000-000000000001'
  AND receipt.operation_id = reference.accept_operation_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_ref record;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_operation_refs;
  v_result := public.accept_board_invitation_link_p(
    v_ref.token, v_ref.accept_operation_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired_unknown'
    OR v_result ? 'board_slug' THEN
    RAISE EXCEPTION 'An expired receipt exposed stale invitation content: %', v_result;
  END IF;
END;
$$;
COMMIT;

RESET ROLE;
DO $$
BEGIN
  IF has_table_privilege('authenticated', 'public.board_invitation_operation_receipts', 'SELECT')
    OR EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'board_invitation_operation_receipts'
        AND column_name = 'token'
    ) THEN
    RAISE EXCEPTION 'Operation receipts expose bearer tokens or direct table access';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.delete_board_p(reference.board_slug, reference.board_id)
FROM pg_temp.issue12_invitation_operation_refs AS reference;
COMMIT;

\echo 'PASS: generic/direct acceptance and link creation reconcile committed commands without storing bearer tokens'
