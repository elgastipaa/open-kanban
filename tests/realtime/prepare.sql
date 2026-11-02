DO $$
DECLARE
  v_owner uuid := '72000000-0000-4000-8000-000000000001';
  v_member uuid := '72000000-0000-4000-8000-000000000002';
  v_board record;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
    (v_owner, 'issue20-realtime-owner@example.test', now(), '{"provider":"google"}'),
    (v_member, 'issue20-realtime-member@example.test', now(), '{"provider":"google"}');
  INSERT INTO auth.identities (user_id, provider, provider_id, identity_data) VALUES
    (v_owner, 'google', 'issue20-realtime-owner', '{"email":"issue20-realtime-owner@example.test","email_verified":true}'),
    (v_member, 'google', 'issue20-realtime-member', '{"email":"issue20-realtime-member@example.test","email_verified":true}');
  INSERT INTO public.application_access (email, auth_user_id, google_subject, state) VALUES
    ('issue20-realtime-owner@example.test', v_owner, 'issue20-realtime-owner', 'active'),
    ('issue20-realtime-member@example.test', v_member, 'issue20-realtime-member', 'active');

  PERFORM set_config('request.jwt.claim.sub', v_owner::text, true);
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Realtime WebSocket smoke',
    'UTC',
    '72000000-0000-4000-8000-000000000003'
  );
  INSERT INTO public.board_memberships (board_id, user_id, role)
  VALUES (v_board.id, v_member, 'collaborator');
END;
$$;
