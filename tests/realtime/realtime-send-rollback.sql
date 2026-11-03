DO $$
DECLARE
  v_owner uuid := '72100000-0000-4000-8000-000000000001';
  v_board record;
  v_context record;
  v_signal_count integer;
  v_after_rollback_signal_count integer;
  v_failed boolean := false;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
  VALUES (v_owner, 'issue20-send-owner@example.test', clock_timestamp(), '{"provider":"google"}');
  INSERT INTO auth.identities (user_id, provider, provider_id, identity_data)
  VALUES (v_owner, 'google', 'issue20-send-owner',
    '{"email":"issue20-send-owner@example.test","email_verified":true}');
  INSERT INTO public.application_access (email, auth_user_id, google_subject, state)
  VALUES ('issue20-send-owner@example.test', v_owner,
    'issue20-send-owner', 'active');
  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  SELECT * INTO v_board FROM public.create_board_p(
    'Realtime primitive smoke', 'UTC', '72100000-0000-4000-8000-000000000002'
  );
  SELECT * INTO v_context FROM public.get_board_p(v_board.slug);
  IF v_context.sync_topic IS NULL OR v_context.presence_topic IS NULL THEN
    RAISE EXCEPTION 'Authorized Realtime topics were not returned';
  END IF;

  PERFORM public.create_column_p(
    v_board.slug, v_board.id, 'Realtime send committed', 0
  );
  SELECT count(*)::integer INTO v_signal_count
  FROM realtime.messages
  WHERE topic = v_context.sync_topic
    AND extension = 'broadcast'
    AND private IS TRUE
    AND event = 'sync'
    AND (payload - 'id') = '{}'::jsonb;
  IF v_signal_count <> 1 THEN
    RAISE EXCEPTION 'The actual realtime.send primitive did not persist exactly one private empty sync signal: %',
      v_signal_count;
  END IF;

  EXECUTE $ddl$
    CREATE FUNCTION public.issue20_fail_after_realtime_send()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $body$
    BEGIN
      RAISE EXCEPTION 'Injected post-send transaction failure' USING ERRCODE = '58000';
    END;
    $body$
  $ddl$;
  EXECUTE 'CREATE TRIGGER zz_issue20_fail_after_realtime_send
    AFTER INSERT ON public.columns
    FOR EACH ROW EXECUTE FUNCTION public.issue20_fail_after_realtime_send()';
  BEGIN
    PERFORM public.create_column_p(
      v_board.slug, v_board.id, 'Realtime transaction rollback', 1
    );
    RAISE EXCEPTION 'The injected transaction failure did not execute';
  EXCEPTION WHEN SQLSTATE '58000' THEN
    v_failed := true;
  END;
  EXECUTE 'DROP TRIGGER zz_issue20_fail_after_realtime_send ON public.columns';
  EXECUTE 'DROP FUNCTION public.issue20_fail_after_realtime_send()';
  IF NOT v_failed THEN
    RAISE EXCEPTION 'The rollback failure hook did not run';
  END IF;
  SELECT count(*)::integer INTO v_after_rollback_signal_count
  FROM realtime.messages
  WHERE topic = v_context.sync_topic
    AND extension = 'broadcast'
    AND private IS TRUE
    AND event = 'sync'
    AND (payload - 'id') = '{}'::jsonb;
  IF EXISTS (
    SELECT 1 FROM public.columns
    WHERE board_id = v_board.id AND title = 'Realtime transaction rollback'
  ) OR v_after_rollback_signal_count <> v_signal_count THEN
    RAISE EXCEPTION 'The post-send failure left a board write or broadcast committed';
  END IF;
  RAISE NOTICE 'PASS: actual realtime.send persisted one private content-free event; a later transaction failure rolled back both row and message.';
END;
$$;
