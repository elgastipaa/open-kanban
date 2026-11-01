\set ON_ERROR_STOP on
\echo 'Testing private Realtime authorization epochs and revocation'

BEGIN;

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('62000000-0000-4000-8000-000000000001', 'issue20-owner@example.test', now(), '{"provider":"google"}'),
  ('62000000-0000-4000-8000-000000000002', 'issue20-member@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('62000000-0000-4000-8000-000000000003', '62000000-0000-4000-8000-000000000001', 'google', 'issue20-google-owner', '{"email":"issue20-owner@example.test","email_verified":true}'),
  ('62000000-0000-4000-8000-000000000004', '62000000-0000-4000-8000-000000000002', 'google', 'issue20-google-member', '{"email":"issue20-member@example.test","email_verified":true}');
INSERT INTO public.application_access (email, auth_user_id, google_subject, state) VALUES
  ('issue20-owner@example.test', '62000000-0000-4000-8000-000000000001', 'issue20-google-owner', 'active'),
  ('issue20-member@example.test', '62000000-0000-4000-8000-000000000002', 'issue20-google-member', 'active');

SELECT set_config('request.jwt.claim.sub', '62000000-0000-4000-8000-000000000001', true);
SELECT created.id AS board_id, created.slug AS board_slug
FROM public.create_board_p(
  'Tablero de prueba Realtime',
  'UTC',
  '62000000-0000-4000-8000-000000000005'
) AS created \gset
INSERT INTO public.board_memberships (board_id, user_id, role)
VALUES (:'board_id'::uuid, '62000000-0000-4000-8000-000000000002', 'collaborator')
RETURNING id AS membership_id \gset
SELECT authorized.auth_epoch AS old_epoch,
  authorized.sync_topic AS old_topic,
  authorized.presence_topic AS old_presence_topic
FROM public.get_board_p(:'board_slug') AS authorized \gset
SELECT set_config('test.issue20.board_id', :'board_id', true);
SELECT set_config('test.issue20.board_slug', :'board_slug', true);
SELECT set_config('test.issue20.membership_id', :'membership_id', true);
SELECT set_config('test.issue20.old_epoch', :'old_epoch', true);
SELECT set_config('test.issue20.old_topic', :'old_topic', true);
SELECT set_config('test.issue20.old_presence_topic', :'old_presence_topic', true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '62000000-0000-4000-8000-000000000001', true);
SELECT set_config('request.jwt.claim.topic', :'old_topic', true);
DO $$
BEGIN
  IF NOT public.can_access_board_topic(current_setting('request.jwt.claim.topic')) THEN
    RAISE EXCEPTION 'The current owner must be able to join the current private topic';
  END IF;
END;
$$;

SELECT set_config('request.jwt.claim.sub', '62000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_direct_publish_denied boolean := false;
BEGIN
  IF NOT public.can_access_board_topic(current_setting('request.jwt.claim.topic')) THEN
    RAISE EXCEPTION 'A current collaborator must be able to join the current private topic';
  END IF;

  BEGIN
    INSERT INTO realtime.messages (extension, topic, payload)
    VALUES ('broadcast', current_setting('request.jwt.claim.topic'), '{}'::jsonb);
  EXCEPTION WHEN insufficient_privilege THEN
    v_direct_publish_denied := true;
  END;
  IF NOT v_direct_publish_denied THEN
    RAISE EXCEPTION 'An authenticated client published a server-owned Realtime signal';
  END IF;

  INSERT INTO realtime.messages (extension, topic, payload)
  VALUES ('presence', current_setting('test.issue20.old_presence_topic'), '{}'::jsonb);
END;
$$;

SELECT set_config('request.jwt.claim.sub', '62000000-0000-4000-8000-000000000001', true);
SELECT public.remove_board_collaborator_p(
  '62000000-0000-4000-8000-000000000006',
  current_setting('test.issue20.board_id')::uuid,
  current_setting('test.issue20.membership_id')::uuid
);

SELECT set_config('request.jwt.claim.sub', '62000000-0000-4000-8000-000000000001', true);
SELECT authorized.auth_epoch AS new_epoch, authorized.sync_topic AS new_topic
FROM public.get_board_p(current_setting('test.issue20.board_slug')) AS authorized \gset
SELECT set_config('test.issue20.new_topic', :'new_topic', true);

DO $$
DECLARE
  v_board_metadata jsonb;
BEGIN
  SELECT pg_catalog.to_jsonb(board_access) INTO v_board_metadata
  FROM public.get_board_p(current_setting('test.issue20.board_slug')) AS board_access;

  IF v_board_metadata IS NULL OR NOT (v_board_metadata ? 'auth_epoch')
    OR NOT (v_board_metadata ? 'sync_topic')
    OR NOT (v_board_metadata ? 'presence_topic') THEN
    RAISE EXCEPTION 'The authorized board response must include its Realtime epoch and private topics';
  END IF;
  IF (v_board_metadata->>'auth_epoch')::bigint <= current_setting('test.issue20.old_epoch')::bigint THEN
    RAISE EXCEPTION 'Removing a collaborator must rotate the board authorization epoch';
  END IF;
END;
$$;

RESET ROLE;
DO $$
DECLARE
  v_revocation_signal record;
BEGIN
  SELECT message.event, message.payload, message.private INTO v_revocation_signal
  FROM realtime.messages AS message
  WHERE message.topic = current_setting('test.issue20.old_topic')
  ORDER BY message.id DESC
  LIMIT 1;
  IF v_revocation_signal.event IS DISTINCT FROM 'revalidate'
    OR (v_revocation_signal.payload - 'id') IS DISTINCT FROM '{}'::jsonb
    OR v_revocation_signal.private IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Revocation must leave only a prior in-transit private invalidation signal on the old topic: %', v_revocation_signal;
  END IF;
END;
$$;

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '62000000-0000-4000-8000-000000000002', true);
SELECT set_config('request.jwt.claim.topic', current_setting('test.issue20.old_topic'), true);
DO $$
DECLARE
  v_direct_publish_denied boolean := false;
BEGIN
  IF public.can_access_board_topic(current_setting('request.jwt.claim.topic')) THEN
    RAISE EXCEPTION 'A revoked collaborator rejoined a topic from the previous authorization epoch';
  END IF;

  BEGIN
    INSERT INTO realtime.messages (extension, topic, payload)
    VALUES ('broadcast', current_setting('request.jwt.claim.topic'), '{}'::jsonb);
  EXCEPTION WHEN insufficient_privilege THEN
    v_direct_publish_denied := true;
  END;
  IF NOT v_direct_publish_denied THEN
    RAISE EXCEPTION 'A non-cooperative client published directly after revocation';
  END IF;
END;
$$;

RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '62000000-0000-4000-8000-000000000001', true);
SELECT set_config(
  'test.issue20.old_topic_count',
  (SELECT count(*)::text FROM realtime.messages WHERE topic = current_setting('test.issue20.old_topic')),
  true
);
SELECT id AS column_id FROM public.create_column_p(
  current_setting('test.issue20.board_slug'),
  current_setting('test.issue20.board_id')::uuid,
  'Después de revocar',
  0
) \gset
DO $$
DECLARE
  v_old_topic_count integer;
  v_new_topic_count integer;
  v_latest_signal record;
BEGIN
  SELECT count(*)::integer INTO v_old_topic_count
  FROM realtime.messages
  WHERE topic = current_setting('test.issue20.old_topic');
  SELECT count(*)::integer INTO v_new_topic_count
  FROM realtime.messages
  WHERE topic = current_setting('test.issue20.new_topic');
  SELECT message.topic, message.event, message.payload, message.private
  INTO v_latest_signal
  FROM realtime.messages AS message
  WHERE message.topic = current_setting('test.issue20.new_topic')
  ORDER BY message.id DESC
  LIMIT 1;

  IF v_old_topic_count <> current_setting('test.issue20.old_topic_count')::integer THEN
    RAISE EXCEPTION 'A server publication reached the previous topic after revocation';
  END IF;
  IF v_new_topic_count < 1 THEN
    RAISE EXCEPTION 'A confirmed board mutation did not publish to the current topic';
  END IF;
  IF v_latest_signal.topic IS DISTINCT FROM current_setting('test.issue20.new_topic')
    OR v_latest_signal.event IS DISTINCT FROM 'sync'
    OR (v_latest_signal.payload - 'id') IS DISTINCT FROM '{}'::jsonb
    OR v_latest_signal.private IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Server synchronization must be a private, content-free Realtime signal: %', v_latest_signal;
  END IF;
END;
$$;

DO $$
DECLARE
  v_column_count integer;
  v_signal_count_before integer;
  v_signal_count_after integer;
BEGIN
  SELECT count(*)::integer INTO v_signal_count_before
  FROM realtime.messages
  WHERE topic = current_setting('test.issue20.new_topic') AND event = 'sync';
  PERFORM set_config('test.fail_realtime_send', 'true', true);
  PERFORM public.create_column_p(
    current_setting('test.issue20.board_slug'),
    current_setting('test.issue20.board_id')::uuid,
    'Realtime demorado; escritura confirmada',
    1
  );
  PERFORM set_config('test.fail_realtime_send', 'false', true);
  SELECT count(*)::integer INTO v_column_count
  FROM public.columns
  WHERE board_id = current_setting('test.issue20.board_id')::uuid
    AND title = 'Realtime demorado; escritura confirmada';
  IF v_column_count <> 1 THEN
    RAISE EXCEPTION 'A Realtime send warning incorrectly rolled back the confirmed product write';
  END IF;
  SELECT count(*)::integer INTO v_signal_count_after
  FROM realtime.messages
  WHERE topic = current_setting('test.issue20.new_topic') AND event = 'sync';
  IF v_signal_count_after <> v_signal_count_before THEN
    RAISE EXCEPTION 'The injected Realtime warning unexpectedly emitted a new signal';
  END IF;
END;
$$;

DO $$
DECLARE
  v_signal_count integer;
BEGIN
  SELECT count(*)::integer INTO v_signal_count
  FROM realtime.messages
  WHERE topic = current_setting('test.issue20.new_topic') AND event = 'sync';
  BEGIN
    PERFORM public.create_column_p(
      current_setting('test.issue20.board_slug'),
      current_setting('test.issue20.board_id')::uuid,
      'Se revierte después de emitir',
      2
    );
    RAISE EXCEPTION 'Injected transaction failure after Realtime send'
      USING ERRCODE = '58001';
  EXCEPTION WHEN SQLSTATE '58001' THEN
    NULL;
  END;
  IF EXISTS (
      SELECT 1 FROM public.columns
      WHERE board_id = current_setting('test.issue20.board_id')::uuid
        AND title = 'Se revierte después de emitir'
    ) OR (
      SELECT count(*)::integer FROM realtime.messages
      WHERE topic = current_setting('test.issue20.new_topic') AND event = 'sync'
    ) <> v_signal_count THEN
    RAISE EXCEPTION 'The aborted transaction retained its board write or Realtime message';
  END IF;
END;
$$;

ROLLBACK;
\echo 'PASS: private Realtime signals rotate with authorization and reject direct client publication'
