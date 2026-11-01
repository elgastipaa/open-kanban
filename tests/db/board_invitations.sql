\set ON_ERROR_STOP on
\echo 'Verifying private, direct and transferable board invitations'

CREATE TEMP TABLE issue12_invitation_refs (
  label text PRIMARY KEY,
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  invitation_id uuid,
  token text,
  expires_at timestamptz
);
GRANT SELECT, INSERT, UPDATE ON issue12_invitation_refs TO authenticated;

-- This synthetic fixture lets the shell harness coordinate two independent
-- database sessions for a genuine acceptance race in the disposable cluster.
CREATE TABLE public.issue12_invitation_race_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  token text NOT NULL
);
GRANT INSERT ON public.issue12_invitation_race_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_invitation jsonb;
  v_repeat jsonb;
  v_link jsonb;
  v_renewal_board record;
  v_renewal_link jsonb;
  v_deleted_board record;
  v_deleted_link jsonb;
  v_orphan_board record;
  v_orphan_link jsonb;
  v_race_board record;
  v_race_link jsonb;
  v_bad_target_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_board FROM public.create_board_p(
    'Tablero de invitaciones', 'America/Argentina/Buenos_Aires',
    'c1220000-0000-4000-8000-000000000001'
  );
  INSERT INTO pg_temp.issue12_invitation_refs(label, board_id, board_slug)
  VALUES ('main', v_board.id, v_board.slug);

  v_invitation := public.create_direct_board_invitation_p(
    v_board.slug, ' REVOCATION-USER@EXAMPLE.TEST '
  );
  IF v_invitation->>'status' IS DISTINCT FROM 'created'
    OR v_invitation->>'id' IS NULL
    OR abs(extract(epoch FROM (
      (v_invitation->>'expires_at')::timestamptz - clock_timestamp()
    )) - 259200) > 2 THEN
    RAISE EXCEPTION 'Direct invitation was not created for 72 hours: %', v_invitation;
  END IF;
  UPDATE pg_temp.issue12_invitation_refs
  SET invitation_id = (v_invitation->>'id')::uuid WHERE label = 'main';

  v_repeat := public.create_direct_board_invitation_p(
    v_board.slug, 'revocation-user@example.test'
  );
  IF v_repeat->>'status' IS DISTINCT FROM 'existing'
    OR v_repeat->>'id' IS DISTINCT FROM v_invitation->>'id'
    OR v_repeat->>'expires_at' IS DISTINCT FROM v_invitation->>'expires_at' THEN
    RAISE EXCEPTION 'Repeated direct invitation created or renewed another record: %', v_repeat;
  END IF;

  v_link := public.create_board_invitation_link_p(
    v_board.slug, 'd1220000-0000-4000-8000-000000000001', repeat('1', 64)
  );
  IF v_link->>'status' IS DISTINCT FROM 'created'
    OR v_link->>'role' IS DISTINCT FROM 'collaborator'
    OR v_link->>'token' !~ '^[0-9a-f]{64}$'
    OR abs(extract(epoch FROM (
      (v_link->>'expires_at')::timestamptz - clock_timestamp()
    )) - 259200) > 2 THEN
    RAISE EXCEPTION 'Generic invitation link has the wrong shape or lifetime: %', v_link;
  END IF;
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  ) VALUES (
    'main-link', v_board.id, v_board.slug,
    (v_link->>'id')::uuid, v_link->>'token'
  );

  v_invitation := public.create_direct_board_invitation_p(
    v_board.slug, 'bootstrap-admin@example.test'
  );
  IF v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Could not create the direct rejection fixture: %', v_invitation;
  END IF;
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id
  ) VALUES (
    'rejected-direct', v_board.id, v_board.slug, (v_invitation->>'id')::uuid
  );

  v_invitation := public.create_direct_board_invitation_p(
    v_board.slug, 'second-admin@example.test'
  );
  IF v_invitation->>'status' IS DISTINCT FROM 'created' THEN
    RAISE EXCEPTION 'Could not create the direct expiry fixture: %', v_invitation;
  END IF;
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id
  ) VALUES (
    'expiring-direct', v_board.id, v_board.slug, (v_invitation->>'id')::uuid
  );

  v_link := public.create_board_invitation_link_p(
    v_board.slug, 'd1220000-0000-4000-8000-000000000002', repeat('2', 64)
  );
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  ) VALUES (
    'revoked-link', v_board.id, v_board.slug,
    (v_link->>'id')::uuid, v_link->>'token'
  );
  v_link := public.create_board_invitation_link_p(
    v_board.slug, 'd1220000-0000-4000-8000-000000000003', repeat('3', 64)
  );
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  ) VALUES (
    'expired-link', v_board.id, v_board.slug,
    (v_link->>'id')::uuid, v_link->>'token'
  );

  BEGIN
    PERFORM public.create_direct_board_invitation_p(
      v_board.slug, 'denied-user@example.test'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_bad_target_denied := true;
  END;
  IF NOT v_bad_target_denied THEN
    RAISE EXCEPTION 'Owner invited an identity that is not enabled';
  END IF;

  SELECT * INTO STRICT v_renewal_board FROM public.create_board_p(
    'Tablero para renovar', 'UTC', 'c1220000-0000-4000-8000-000000000002'
  );
  v_renewal_link := public.create_board_invitation_link_p(
    v_renewal_board.slug, 'd1220000-0000-4000-8000-000000000004', repeat('4', 64)
  );
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  ) VALUES (
    'renew-link', v_renewal_board.id, v_renewal_board.slug,
    (v_renewal_link->>'id')::uuid, v_renewal_link->>'token'
  );

  SELECT * INTO STRICT v_deleted_board FROM public.create_board_p(
    'Tablero eliminado', 'UTC', 'c1220000-0000-4000-8000-000000000003'
  );
  v_deleted_link := public.create_board_invitation_link_p(
    v_deleted_board.slug, 'd1220000-0000-4000-8000-000000000005', repeat('5', 64)
  );
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  ) VALUES (
    'deleted-link', v_deleted_board.id, v_deleted_board.slug,
    (v_deleted_link->>'id')::uuid, v_deleted_link->>'token'
  );

  SELECT * INTO STRICT v_orphan_board FROM public.create_board_p(
    'Tablero sin emisor', 'UTC', 'c1220000-0000-4000-8000-000000000004'
  );
  v_orphan_link := public.create_board_invitation_link_p(
    v_orphan_board.slug, 'd1220000-0000-4000-8000-000000000006', repeat('6', 64)
  );
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  ) VALUES (
    'orphan-link', v_orphan_board.id, v_orphan_board.slug,
    (v_orphan_link->>'id')::uuid, v_orphan_link->>'token'
  );

  SELECT * INTO STRICT v_race_board FROM public.create_board_p(
    'Tablero para carrera', 'UTC', 'c1220000-0000-4000-8000-000000000005'
  );
  v_race_link := public.create_board_invitation_link_p(
    v_race_board.slug, 'd1220000-0000-4000-8000-000000000007', repeat('7', 64)
  );
  INSERT INTO public.issue12_invitation_race_fixture(board_id, board_slug, token)
  VALUES (v_race_board.id, v_race_board.slug, v_race_link->>'token');
END;
$$;
COMMIT;

-- An unrelated enabled identity cannot accept or list another person's direct
-- invitation. A non-enabled identity cannot preview or consume a generic link.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_result jsonb;
  v_count integer;
BEGIN
  v_result := public.accept_direct_board_invitation_p(
    (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'main'),
    'e1220000-0000-4000-8000-000000000001'
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A different enabled user accepted a direct invitation: %', v_result;
  END IF;
  SELECT count(*) INTO v_count FROM public.list_my_pending_board_invitations_p();
  IF v_count <> 1 OR NOT EXISTS (
    SELECT 1 FROM public.list_my_pending_board_invitations_p()
    WHERE board_name = 'Tablero de invitaciones'
      AND inviter_email = 'enabled-user@example.test'
  ) THEN
    RAISE EXCEPTION 'A direct invitation was not visible only to its recipient';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'main-link');
  v_preview jsonb;
  v_result jsonb;
BEGIN
  v_preview := public.preview_board_invitation_p(v_token);
  v_result := public.accept_board_invitation_link_p(
    v_token, 'e1220000-0000-4000-8000-000000000002'
  );
  IF v_preview <> jsonb_build_object('status', 'unavailable')
    OR v_result <> jsonb_build_object('status', 'unavailable') THEN
    RAISE EXCEPTION 'A non-enabled identity learned invitation details or consumed a link: %, %',
      v_preview, v_result;
  END IF;
END;
$$;
COMMIT;

-- Direct recipient review/acceptance and non-consumption of a generic link for
-- a person who already became a member through a direct invitation.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_direct_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'main');
  v_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'main-link');
  v_result jsonb;
  v_board_slug text := (SELECT board_slug FROM pg_temp.issue12_invitation_refs WHERE label = 'main');
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.list_my_pending_board_invitations_p()
  WHERE id = v_direct_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'The intended recipient cannot see their direct invitation';
  END IF;
  v_result := public.accept_direct_board_invitation_p(
    v_direct_id, 'e1220000-0000-4000-8000-000000000003'
  );
  IF v_result->>'status' IS DISTINCT FROM 'accepted'
    OR v_result->>'board_slug' IS DISTINCT FROM v_board_slug THEN
    RAISE EXCEPTION 'Direct acceptance did not create board access: %', v_result;
  END IF;
  SELECT count(*) INTO v_count FROM public.list_my_boards()
  WHERE slug = v_board_slug AND role = 'collaborator';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Direct acceptance did not create exactly one collaborator membership';
  END IF;

  v_result := public.accept_board_invitation_link_p(
    v_token, 'e1220000-0000-4000-8000-000000000004'
  );
  IF v_result->>'status' IS DISTINCT FROM 'already_member'
    OR v_result->>'board_slug' IS DISTINCT FROM v_board_slug THEN
    RAISE EXCEPTION 'A current member did not retain an unconsumed generic link: %', v_result;
  END IF;
END;
$$;
COMMIT;

-- Rejection releases the one-pending uniqueness slot; a later invitation is a
-- new record. Membership acquired by another valid route does not consume it.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_old_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'rejected-direct');
BEGIN
  IF NOT public.reject_direct_board_invitation_p(v_old_id) THEN
    RAISE EXCEPTION 'The invited recipient could not reject their direct invitation';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_old_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'rejected-direct');
  v_main_slug text := (SELECT board_slug FROM pg_temp.issue12_invitation_refs WHERE label = 'main');
  v_new jsonb;
  v_result jsonb;
  v_count integer;
BEGIN
  v_new := public.create_direct_board_invitation_p(v_main_slug, 'bootstrap-admin@example.test');
  IF v_new->>'status' IS DISTINCT FROM 'created'
    OR v_new->>'id' IS NOT DISTINCT FROM v_old_id::text THEN
    RAISE EXCEPTION 'A rejected direct invitation blocked a future invitation: %', v_new;
  END IF;
  INSERT INTO pg_temp.issue12_invitation_refs(label, board_id, board_slug, invitation_id)
  SELECT 'reinvitated-direct', board_id, board_slug, (v_new->>'id')::uuid
  FROM pg_temp.issue12_invitation_refs WHERE label = 'main';

  v_result := public.create_direct_board_invitation_p(
    v_main_slug, 'revocation-user@example.test'
  );
  IF v_result->>'status' IS DISTINCT FROM 'already_member' THEN
    RAISE EXCEPTION 'A current member received a new direct invitation: %', v_result;
  END IF;
END;
$$;
COMMIT;

-- An enabled person can preview only the approved metadata and explicitly
-- accept a transferable link. The one-use token then goes dark. A direct invite
-- that remains after joining through the link does not create a duplicate.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'main-link');
  v_direct_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'reinvitated-direct');
  v_result jsonb;
  v_preview jsonb;
  v_board_slug text := (SELECT board_slug FROM pg_temp.issue12_invitation_refs WHERE label = 'main');
  v_count integer;
  v_denied boolean := false;
BEGIN
  v_preview := public.preview_board_invitation_p(v_token);
  IF v_preview->>'status' IS DISTINCT FROM 'available'
    OR v_preview->>'board_name' IS DISTINCT FROM 'Tablero de invitaciones'
    OR v_preview->>'inviter' IS DISTINCT FROM 'enabled-user@example.test'
    OR v_preview->>'role' IS DISTINCT FROM 'collaborator'
    OR (SELECT count(*) FROM jsonb_object_keys(v_preview)) <> 4 THEN
    RAISE EXCEPTION 'Preview returned missing or unauthorized metadata: %', v_preview;
  END IF;

  v_result := public.accept_board_invitation_link_p(
    v_token, 'e1220000-0000-4000-8000-000000000005'
  );
  IF v_result->>'status' IS DISTINCT FROM 'accepted'
    OR v_result->>'board_slug' IS DISTINCT FROM v_board_slug THEN
    RAISE EXCEPTION 'Explicit generic acceptance failed: %', v_result;
  END IF;
  SELECT count(*) INTO v_count FROM public.list_my_boards()
  WHERE slug = v_board_slug AND role = 'collaborator';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Generic acceptance did not create exactly one collaborator membership';
  END IF;

  v_result := public.accept_direct_board_invitation_p(
    v_direct_id, 'e1220000-0000-4000-8000-000000000006'
  );
  IF v_result->>'status' IS DISTINCT FROM 'already_member'
    OR v_result->>'board_slug' IS DISTINCT FROM v_board_slug THEN
    RAISE EXCEPTION 'A current member could not open their board through a direct invite: %', v_result;
  END IF;
  v_result := public.accept_board_invitation_link_p(
    v_token, 'e1220000-0000-4000-8000-000000000007'
  );
  IF v_result <> jsonb_build_object('status', 'unavailable') THEN
    RAISE EXCEPTION 'A used generic link disclosed or granted access a second time: %', v_result;
  END IF;

  BEGIN
    PERFORM public.create_board_invitation_link_p(
      v_board_slug, 'e1220000-0000-4000-8000-000000000008', repeat('8', 64)
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A collaborator created an invitation link';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_slug text := (SELECT board_slug FROM pg_temp.issue12_invitation_refs WHERE label = 'main');
  v_count integer;
BEGIN
  IF NOT public.revoke_board_invitation_p((
    SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'revoked-link'
  )) THEN
    RAISE EXCEPTION 'Owner could not revoke a generic link';
  END IF;
  IF NOT public.revoke_board_invitation_p((
    SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'reinvitated-direct'
  )) THEN
    RAISE EXCEPTION 'Owner could not revoke a direct invitation';
  END IF;

  SELECT count(*) INTO v_count FROM public.list_board_invitations_p(v_slug)
  WHERE invitation_status = 'revoked';
  IF v_count < 2 THEN
    RAISE EXCEPTION 'Owner list did not expose the current invitation states';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'expiring-direct');
  v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.list_my_pending_board_invitations_p()
  WHERE id = v_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'The direct invitee cannot review their pending invitation';
  END IF;
END;
$$;
COMMIT;

-- Expiry is measured by the database clock. Creating again does not renew; an
-- explicit owner renewal refreshes exactly 72 hours and rotates generic links.
RESET ROLE;
UPDATE public.board_invitations AS invitation
SET created_at = clock_timestamp() - interval '2 hours',
    expires_at = clock_timestamp() - interval '1 minute'
FROM pg_temp.issue12_invitation_refs AS reference
WHERE invitation.id = reference.invitation_id
  AND reference.label = 'expiring-direct';
UPDATE public.board_invitations AS invitation
SET created_at = clock_timestamp() - interval '2 hours',
    expires_at = clock_timestamp() - interval '1 minute'
FROM pg_temp.issue12_invitation_refs AS reference
WHERE invitation.id = reference.invitation_id
  AND reference.label = 'expired-link';
UPDATE public.board_invitations AS invitation
SET created_at = clock_timestamp() - interval '2 hours',
    expires_at = clock_timestamp() - interval '1 minute'
FROM pg_temp.issue12_invitation_refs AS reference
WHERE invitation.id = reference.invitation_id
  AND reference.label = 'renew-link';

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_direct_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'expiring-direct');
  v_direct_slug text := (SELECT board_slug FROM pg_temp.issue12_invitation_refs WHERE label = 'main');
  v_repeat jsonb;
  v_renewed_direct jsonb;
  v_old_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link');
  v_link_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link');
  v_renewed_link jsonb;
  v_renewal_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link');
  v_early jsonb;
BEGIN
  v_repeat := public.create_direct_board_invitation_p(v_direct_slug, 'second-admin@example.test');
  IF v_repeat->>'status' IS DISTINCT FROM 'expired'
    OR v_repeat->>'id' IS DISTINCT FROM v_direct_id::text THEN
    RAISE EXCEPTION 'Repeating an expired direct invite silently renewed or duplicated it: %', v_repeat;
  END IF;
  v_early := public.renew_board_invitation_p(
    v_renewal_id, 'f1220000-0000-4000-8000-000000000001', repeat('8', 64)
  );
  IF v_early->>'status' IS DISTINCT FROM 'renewed' THEN
    RAISE EXCEPTION 'Expired generic invitation could not be explicitly renewed: %', v_early;
  END IF;
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  )
  SELECT 'renew-link-old', board_id, board_slug, invitation_id, token
  FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link';
  UPDATE pg_temp.issue12_invitation_refs
  SET token = v_early->>'token',
      expires_at = (v_early->>'expires_at')::timestamptz
  WHERE label = 'renew-link';

  v_renewed_direct := public.renew_board_invitation_p(
    v_direct_id, 'f1220000-0000-4000-8000-000000000002', NULL
  );
  IF v_renewed_direct->>'status' IS DISTINCT FROM 'renewed'
    OR v_renewed_direct->>'id' IS DISTINCT FROM v_direct_id::text
    OR abs(extract(epoch FROM (
      (v_renewed_direct->>'expires_at')::timestamptz - clock_timestamp()
    )) - 259200) > 2 THEN
    RAISE EXCEPTION 'Explicit direct renewal did not refresh the same invite for 72 hours: %', v_renewed_direct;
  END IF;
  INSERT INTO pg_temp.issue12_invitation_refs(
    label, board_id, board_slug, invitation_id, token
  )
  SELECT 'expired-link-old', board_id, board_slug, invitation_id, token
  FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link';

  v_renewed_link := public.renew_board_invitation_p(
    v_link_id, 'f1220000-0000-4000-8000-000000000003', repeat('9', 64)
  );
  IF v_renewed_link->>'status' IS DISTINCT FROM 'renewed'
    OR v_renewed_link->>'token' IS NULL
    OR v_renewed_link->>'token' = v_old_token
    OR abs(extract(epoch FROM (
      (v_renewed_link->>'expires_at')::timestamptz - clock_timestamp()
    )) - 259200) > 2 THEN
    RAISE EXCEPTION 'Explicit generic renewal did not rotate the link for 72 hours: %', v_renewed_link;
  END IF;
  UPDATE pg_temp.issue12_invitation_refs
  SET token = v_renewed_link->>'token',
      expires_at = (v_renewed_link->>'expires_at')::timestamptz
  WHERE label = 'expired-link';
  UPDATE pg_temp.issue12_invitation_refs
  SET expires_at = (v_renewed_direct->>'expires_at')::timestamptz
  WHERE label = 'expiring-direct';
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_direct_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'expiring-direct');
  v_direct_expiry timestamptz := (SELECT expires_at FROM pg_temp.issue12_invitation_refs WHERE label = 'expiring-direct');
  v_early_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link');
  v_early_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link');
  v_early_expiry timestamptz := (SELECT expires_at FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link');
  v_link_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link');
  v_link_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link');
  v_link_expiry timestamptz := (SELECT expires_at FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link');
  v_direct_replay jsonb;
  v_early_replay jsonb;
  v_link_replay jsonb;
  v_conflict boolean := false;
BEGIN
  v_early_replay := public.renew_board_invitation_p(
    v_early_id, 'f1220000-0000-4000-8000-000000000001', repeat('8', 64)
  );
  IF v_early_replay->>'status' IS DISTINCT FROM 'renewed'
    OR v_early_replay->>'token' IS DISTINCT FROM v_early_token
    OR (v_early_replay->>'expires_at')::timestamptz IS DISTINCT FROM v_early_expiry THEN
    RAISE EXCEPTION 'Generic renewal replay did not return its original token/result: %', v_early_replay;
  END IF;

  v_direct_replay := public.renew_board_invitation_p(
    v_direct_id, 'f1220000-0000-4000-8000-000000000002', NULL
  );
  IF v_direct_replay->>'status' IS DISTINCT FROM 'renewed'
    OR (v_direct_replay->>'expires_at')::timestamptz IS DISTINCT FROM v_direct_expiry THEN
    RAISE EXCEPTION 'Direct renewal replay extended or changed its result: %', v_direct_replay;
  END IF;

  v_link_replay := public.renew_board_invitation_p(
    v_link_id, 'f1220000-0000-4000-8000-000000000003', repeat('9', 64)
  );
  IF v_link_replay->>'status' IS DISTINCT FROM 'renewed'
    OR v_link_replay->>'token' IS DISTINCT FROM v_link_token
    OR (v_link_replay->>'expires_at')::timestamptz IS DISTINCT FROM v_link_expiry THEN
    RAISE EXCEPTION 'Rotated generic renewal replay did not return its original result: %', v_link_replay;
  END IF;

  BEGIN
    PERFORM public.renew_board_invitation_p(
      v_link_id, 'f1220000-0000-4000-8000-000000000003', repeat('c', 64)
    );
  EXCEPTION WHEN check_violation THEN
    v_conflict := true;
  END;
  IF NOT v_conflict OR public.preview_board_invitation_p(v_link_token)->>'status'
      IS DISTINCT FROM 'available' THEN
    RAISE EXCEPTION 'A renewal key accepted a different token or replaced the renewed link';
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
DO $$
DECLARE
  v_id uuid := (SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'expiring-direct');
  v_result jsonb;
BEGIN
  v_result := public.accept_direct_board_invitation_p(
    v_id, 'e1220000-0000-4000-8000-000000000009'
  );
  IF v_result->>'status' IS DISTINCT FROM 'accepted' THEN
    RAISE EXCEPTION 'A renewed direct invitation could not be accepted: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_old_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link-old');
  v_result jsonb;
  v_preview jsonb;
BEGIN
  v_result := public.accept_board_invitation_link_p(
    v_old_token, 'e1220000-0000-4000-8000-000000000010'
  );
  v_preview := public.preview_board_invitation_p(v_old_token);
  IF v_result <> jsonb_build_object('status', 'unavailable')
    OR v_preview <> jsonb_build_object('status', 'unavailable') THEN
    RAISE EXCEPTION 'Malformed or expired token leaked invitation data: %, %', v_result, v_preview;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_old_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link-old');
  v_new_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'expired-link');
  v_result jsonb;
BEGIN
  v_result := public.preview_board_invitation_p(v_old_token);
  IF v_result <> jsonb_build_object('status', 'unavailable') THEN
    RAISE EXCEPTION 'Rotated/expired link revealed preview data: %', v_result;
  END IF;
  v_result := public.preview_board_invitation_p(v_new_token);
  IF v_result->>'status' IS DISTINCT FROM 'available'
    OR v_result->>'board_name' IS DISTINCT FROM 'Tablero de invitaciones' THEN
    RAISE EXCEPTION 'New explicitly renewed link is not available to an enabled identity: %', v_result;
  END IF;
  v_result := public.accept_board_invitation_link_p(
    v_new_token, 'e1220000-0000-4000-8000-000000000011'
  );
  IF v_result->>'status' IS DISTINCT FROM 'already_member' THEN
    RAISE EXCEPTION 'An existing member consumed a renewed generic link: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_old_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link-old');
  v_new_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link');
  v_result jsonb;
BEGIN
  v_result := public.preview_board_invitation_p(v_old_token);
  IF v_result <> jsonb_build_object('status', 'unavailable') THEN
    RAISE EXCEPTION 'Expired pre-renewal token still exposes preview: %', v_result;
  END IF;
  v_result := public.preview_board_invitation_p(v_new_token);
  IF v_result->>'status' IS DISTINCT FROM 'available' THEN
    RAISE EXCEPTION 'Explicitly renewed invitation link is not available: %', v_result;
  END IF;
  v_result := public.accept_board_invitation_link_p(
    v_new_token, 'e1220000-0000-4000-8000-000000000012'
  );
  IF v_result->>'status' IS DISTINCT FROM 'accepted'
    OR v_result->>'board_slug' IS DISTINCT FROM (
      SELECT board_slug FROM pg_temp.issue12_invitation_refs WHERE label = 'renew-link'
    ) THEN
    RAISE EXCEPTION 'Explicitly renewed generic link could not be accepted: %', v_result;
  END IF;
END;
$$;
COMMIT;

-- Deleting a board or losing the current owner authority invalidates its link.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_ref record;
BEGIN
  SELECT * INTO STRICT v_ref FROM pg_temp.issue12_invitation_refs WHERE label = 'deleted-link';
  PERFORM public.delete_board_p(v_ref.board_slug, v_ref.board_id);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'deleted-link');
  v_result jsonb := public.preview_board_invitation_p(v_token);
BEGIN
  IF v_result <> jsonb_build_object('status', 'unavailable') THEN
    RAISE EXCEPTION 'A deleted board left a usable or descriptive invitation: %', v_result;
  END IF;
END;
$$;
COMMIT;

RESET ROLE;
SET session_replication_role = replica;
UPDATE public.board_memberships AS membership
SET revoked_at = clock_timestamp()
FROM pg_temp.issue12_invitation_refs AS reference
WHERE reference.label = 'orphan-link'
  AND membership.board_id = reference.board_id
  AND membership.user_id = '40000000-0000-4000-8000-000000000002'
  AND membership.role = 'owner'
  AND membership.revoked_at IS NULL;
SET session_replication_role = origin;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'orphan-link');
  v_result jsonb;
  v_count integer;
BEGIN
  v_result := public.preview_board_invitation_p(v_token);
  IF v_result <> jsonb_build_object('status', 'unavailable') THEN
    RAISE EXCEPTION 'A removed issuer left a descriptive invitation: %', v_result;
  END IF;
  v_result := public.accept_board_invitation_link_p(
    v_token, 'e1220000-0000-4000-8000-000000000013'
  );
  SELECT count(*) INTO v_count FROM public.list_my_boards()
  WHERE slug = (SELECT board_slug FROM pg_temp.issue12_invitation_refs WHERE label = 'orphan-link');
  IF v_result <> jsonb_build_object('status', 'unavailable') OR v_count <> 0 THEN
    RAISE EXCEPTION 'A removed issuer link granted access or leaked its state: %, membership count %',
      v_result, v_count;
  END IF;
END;
$$;
COMMIT;

RESET ROLE;
DO $$
DECLARE
  v_token text := (SELECT token FROM pg_temp.issue12_invitation_refs WHERE label = 'main-link');
  v_hash bytea;
BEGIN
  SELECT invitation.token_hash INTO v_hash
  FROM public.board_invitations AS invitation
  WHERE invitation.id = (
    SELECT invitation_id FROM pg_temp.issue12_invitation_refs WHERE label = 'main-link'
  );
  IF v_hash IS DISTINCT FROM extensions.digest(convert_to(v_token, 'UTF8'), 'sha256') THEN
    RAISE EXCEPTION 'The database stored a plaintext or incorrect generic invitation token';
  END IF;
  IF has_table_privilege('authenticated', 'public.board_invitations', 'SELECT')
    OR has_table_privilege('authenticated', 'public.board_invitations', 'INSERT')
    OR has_function_privilege('anon', 'public.accept_board_invitation_link_p(text,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Invitation storage or RPC privileges are broader than intended';
  END IF;
END;
$$;

\echo 'PASS: direct and generic invitation privacy, eligibility, expiry, revocation, membership, and owner revalidation'
