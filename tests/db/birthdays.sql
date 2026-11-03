\set ON_ERROR_STOP on
\echo 'Issue #29: birthdays are annual, board-local dates and not tasks'

INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue29@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '42900000-0000-4000-8000-000000000002',
  'issue29@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '52900000-0000-4000-8000-000000000002',
  '42900000-0000-4000-8000-000000000002', 'google', 'issue29-google-subject',
  '{"email":"issue29@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '42900000-0000-4000-8000-000000000002',
    google_subject = 'issue29-google-subject', state = 'active'
WHERE email = 'issue29@example.test';

INSERT INTO public.application_access (email, state, is_admin)
VALUES
  ('issue29-collaborator@example.test', 'pending', false),
  ('issue29-outsider@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('42900000-0000-4000-8000-000000000003', 'issue29-collaborator@example.test', now(), '{"provider":"google"}'),
  ('42900000-0000-4000-8000-000000000004', 'issue29-outsider@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('52900000-0000-4000-8000-000000000003', '42900000-0000-4000-8000-000000000003', 'google', 'issue29-collaborator', '{"email":"issue29-collaborator@example.test","email_verified":true}'),
  ('52900000-0000-4000-8000-000000000004', '42900000-0000-4000-8000-000000000004', 'google', 'issue29-outsider', '{"email":"issue29-outsider@example.test","email_verified":true}');
UPDATE public.application_access AS access
SET auth_user_id = users.id, google_subject = identity.provider_id, state = 'active'
FROM auth.users AS users
JOIN auth.identities AS identity ON identity.user_id = users.id
WHERE access.email = users.email
  AND users.id IN (
    '42900000-0000-4000-8000-000000000003',
    '42900000-0000-4000-8000-000000000004'
  );

CREATE TEMP TABLE issue29_birthday_board_refs (
  label text PRIMARY KEY,
  board_id uuid NOT NULL UNIQUE,
  board_slug text NOT NULL
);
CREATE TEMP TABLE issue29_birthday_refs (
  label text PRIMARY KEY,
  birthday_id uuid NOT NULL
);
GRANT SELECT, INSERT ON issue29_birthday_board_refs TO authenticated;
GRANT SELECT, INSERT ON issue29_birthday_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Cumpleaños #29', 'America/Argentina/Buenos_Aires',
    '29000000-0000-4000-8000-000000000001'
  );
  INSERT INTO pg_temp.issue29_birthday_board_refs(label, board_id, board_slug)
  VALUES ('main', v_board.id, v_board.slug);

  SELECT * INTO v_board
  FROM public.create_board_p(
    'Cumpleaños #29 DST', 'America/New_York',
    '29000000-0000-4000-8000-000000000010'
  );
  INSERT INTO pg_temp.issue29_birthday_board_refs(label, board_id, board_slug)
  VALUES ('dst', v_board.id, v_board.slug);
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '42900000-0000-4000-8000-000000000003', 'collaborator'
FROM pg_temp.issue29_birthday_board_refs AS fixture
WHERE fixture.label = 'main';

SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000002', false);
DO $$
DECLARE
  v_board_id uuid;
  v_generation_id uuid;
  v_rejected boolean := false;
BEGIN
  SELECT board.id, board.active_generation_id
  INTO STRICT v_board_id, v_generation_id
  FROM public.boards AS board
  JOIN pg_temp.issue29_birthday_board_refs AS fixture
    ON fixture.board_id = board.id
  WHERE fixture.label = 'main';

  BEGIN
    INSERT INTO public.board_birthdays (
      board_id, generation_id, name, birth_month, birth_day, advance_days
    ) VALUES (
      v_board_id, v_generation_id, 'Ventana anual inválida', 8, 10, 367
    );
  EXCEPTION WHEN check_violation THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'Birthday storage must reject anticipation longer than 366 days';
  END IF;
END;
$$;

DO $$
DECLARE
  v_board_slug text;
  v_result jsonb;
  v_rejected boolean := false;
BEGIN
  SELECT board_slug INTO STRICT v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  BEGIN
    v_result := public.create_birthday_p(
      '29000000-0000-4000-8000-000000000090', v_board_slug,
      'Ventana anual inválida', 8, 10, 367
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'The birthday create RPC must reject anticipation longer than 366 days: %',
      v_result;
  END IF;
END;
$$;

DO $$
DECLARE
  v_birthday jsonb;
  v_windowed jsonb;
  v_max_window jsonb;
  v_board_slug text;
  v_dst_board_slug text;
  v_dst_birthday jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  v_birthday := public.create_birthday_internal_p(
    '29000000-0000-4000-8000-000000000002', v_board_slug,
    'Cumple de prueba', 2, 29, NULL,
    '2026-03-01 01:00:00+00'
  );
  IF v_birthday->>'status' IS DISTINCT FROM 'confirmed'
    OR v_birthday->'birthday'->>'name' IS DISTINCT FROM 'Cumple de prueba'
    OR v_birthday->'birthday'->>'next_on' IS DISTINCT FROM '2026-02-28'
    OR v_birthday->'birthday' ? 'assignee_id'
    OR v_birthday->'birthday' ? 'is_completed' THEN
    RAISE EXCEPTION 'A birthday should be an annual non-task entry with a board-local next date: %',
      v_birthday;
  END IF;

  INSERT INTO pg_temp.issue29_birthday_refs(label, birthday_id)
  VALUES ('leap_day', (v_birthday->'birthday'->>'id')::uuid);

  v_windowed := public.create_birthday_internal_p(
    '29000000-0000-4000-8000-000000000003', v_board_slug,
    'Ventana inclusiva', 3, 10, 3, '2026-03-06 15:00:00+00'
  );
  IF v_windowed->>'status' IS DISTINCT FROM 'confirmed'
    OR v_windowed->'birthday'->>'next_on' IS DISTINCT FROM '2026-03-10' THEN
    RAISE EXCEPTION 'The birthday window fixture did not resolve its next annual date: %',
      v_windowed;
  END IF;
  INSERT INTO pg_temp.issue29_birthday_refs(label, birthday_id)
  VALUES ('windowed', (v_windowed->'birthday'->>'id')::uuid);

  v_max_window := public.create_birthday_p(
    '29000000-0000-4000-8000-000000000004', v_board_slug,
    'Ventana anual máxima', 8, 10, 366
  );
  IF v_max_window->>'status' IS DISTINCT FROM 'confirmed'
    OR v_max_window->'birthday'->>'advance_days' IS DISTINCT FROM '366' THEN
    RAISE EXCEPTION 'A 366-day advance window must remain valid: %', v_max_window;
  END IF;
  INSERT INTO pg_temp.issue29_birthday_refs(label, birthday_id)
  VALUES ('max_window', (v_max_window->'birthday'->>'id')::uuid);

  SELECT board_slug INTO STRICT v_dst_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'dst';
  v_dst_birthday := public.create_birthday_internal_p(
    '29000000-0000-4000-8000-000000000011', v_dst_board_slug,
    'Cumple durante DST', 3, 8, NULL, '2026-03-08 04:30:00+00'
  );
  INSERT INTO pg_temp.issue29_birthday_refs(label, birthday_id)
  VALUES ('dst', (v_dst_birthday->'birthday'->>'id')::uuid);
END;
$$;

DO $$
DECLARE
  v_board_slug text;
  v_windowed_id uuid;
  v_leap_day_id uuid;
  v_dst_id uuid;
  v_dst_board_slug text;
  v_result jsonb;
  v_item jsonb;
  v_series_result jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  SELECT birthday_id INTO STRICT v_windowed_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'windowed';
  SELECT birthday_id INTO STRICT v_leap_day_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'leap_day';
  SELECT birthday_id INTO STRICT v_dst_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'dst';

  v_result := public.list_board_birthdays_internal_p(
    v_board_slug, '2026-03-07 02:30:00+00', false
  );
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_result->'birthdays') AS item
    WHERE item->>'id' = v_windowed_id::text
  ) THEN
    RAISE EXCEPTION 'A birthday before D−X was visible on the board: %', v_result;
  END IF;

  v_series_result := public.list_my_birthdays_p(
    (SELECT board_id FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main')
  );
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_series_result->'birthdays') AS rows(item)
    WHERE rows.item->>'id' = v_windowed_id::text
  ) THEN
    RAISE EXCEPTION 'Series must keep an out-of-window birthday locatable: %', v_series_result;
  END IF;

  v_result := public.list_board_birthdays_internal_p(
    v_board_slug, '2026-03-07 15:00:00+00', true
  );
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_result->'birthdays') AS item
  WHERE item->>'id' = v_windowed_id::text;
  IF v_item IS NULL OR v_item->>'visible' IS DISTINCT FROM 'true'
    OR v_item->>'next_on' IS DISTINCT FROM '2026-03-10' THEN
    RAISE EXCEPTION 'D−X must be inclusive in the birthday window: %', v_result;
  END IF;

  v_result := public.list_board_birthdays_internal_p(
    v_board_slug, '2026-03-10 15:00:00+00', true
  );
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_result->'birthdays') AS item
  WHERE item->>'id' = v_windowed_id::text;
  IF v_item IS NULL OR v_item->>'visible' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'The birthday date D must be inclusive: %', v_result;
  END IF;

  v_result := public.list_board_birthdays_internal_p(
    v_board_slug, '2026-03-11 15:00:00+00', true
  );
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_result->'birthdays') AS item
  WHERE item->>'id' = v_windowed_id::text;
  IF v_item IS NULL OR v_item->>'visible' IS DISTINCT FROM 'false'
    OR v_item->>'next_on' IS DISTINCT FROM '2027-03-10' THEN
    RAISE EXCEPTION 'The day after D must hide until the next window and resolve next year: %', v_result;
  END IF;

  v_result := public.list_board_birthdays_internal_p(
    v_board_slug, '2026-03-01 03:00:00+00', true
  );
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_result->'birthdays') AS rows(item)
  WHERE item->>'id' = v_leap_day_id::text;
  IF v_item->>'next_on' IS DISTINCT FROM '2027-02-28' THEN
    RAISE EXCEPTION 'After the local Feb 28 birthday, the non-leap next date must be Feb 28: %', v_item;
  END IF;

  v_result := public.list_board_birthdays_internal_p(
    v_board_slug, '2028-02-28 15:00:00+00', true
  );
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_result->'birthdays') AS rows(item)
  WHERE item->>'id' = v_leap_day_id::text;
  IF v_item->>'next_on' IS DISTINCT FROM '2028-02-29' THEN
    RAISE EXCEPTION 'A leap year should retain the nominal Feb 29 date: %', v_item;
  END IF;

  SELECT board_slug INTO STRICT v_dst_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'dst';
  v_result := public.list_board_birthdays_internal_p(
    v_dst_board_slug, '2026-03-08 04:30:00+00', true
  );
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_result->'birthdays') AS rows(item)
  WHERE item->>'id' = v_dst_id::text;
  IF v_item->>'next_on' IS DISTINCT FROM '2026-03-08' THEN
    RAISE EXCEPTION 'The New York board-local date before DST start was wrong: %', v_item;
  END IF;

  v_result := public.list_board_birthdays_internal_p(
    v_dst_board_slug, '2026-03-08 07:30:00+00', true
  );
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_result->'birthdays') AS rows(item)
  WHERE item->>'id' = v_dst_id::text;
  IF v_item->>'next_on' IS DISTINCT FROM '2026-03-08' THEN
    RAISE EXCEPTION 'DST transition changed the board-local calendar day: %', v_item;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_slug text;
  v_birthday_id uuid;
  v_result jsonb;
  v_page jsonb;
  v_item jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  SELECT birthday_id INTO STRICT v_birthday_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'leap_day';

  v_result := public.update_birthday_p(
    '29000000-0000-4000-8000-000000000004', v_board_slug,
    v_birthday_id, 1, 'Cumple actualizado', 2, 29, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_result->>'version')::bigint IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'An accessible member could not update the birthday: %', v_result;
  END IF;

  v_page := public.list_board_birthdays_p(v_board_slug);
  SELECT item INTO v_item
  FROM jsonb_array_elements(v_page->'birthdays') AS rows(item)
  WHERE item->>'id' = v_birthday_id::text;
  IF v_item->>'name' IS DISTINCT FROM 'Cumple actualizado'
    OR v_item->>'version' IS DISTINCT FROM '2'
    OR v_item ? 'assignee_id'
    OR v_item ? 'is_completed' THEN
    RAISE EXCEPTION 'The visible birthday update changed task semantics or was not returned: %', v_item;
  END IF;

  v_result := public.update_birthday_p(
    '29000000-0000-4000-8000-000000000005', v_board_slug,
    v_birthday_id, 1, 'Edición obsoleta', 1, 1, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'conflict'
    OR (v_result->>'current_version')::bigint IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'A stale birthday edit did not retain an explicit conflict: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_board_slug text;
  v_birthday_id uuid;
  v_deleted jsonb;
  v_recoverable jsonb;
  v_restored jsonb;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  SELECT birthday_id INTO STRICT v_birthday_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'leap_day';

  v_deleted := public.delete_birthday_p(
    '29000000-0000-4000-8000-000000000006', v_board_slug, v_birthday_id, 2
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_deleted->>'expires_at')::timestamptz
      - (v_deleted->>'deleted_at')::timestamptz IS DISTINCT FROM interval '168 hours' THEN
    RAISE EXCEPTION 'Birthday deletion did not retain its exact seven-day recovery window: %', v_deleted;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(
      public.list_board_birthdays_p(v_board_slug)->'birthdays'
    ) AS rows(item)
    WHERE rows.item->>'id' = v_birthday_id::text
  ) THEN
    RAISE EXCEPTION 'A deleted birthday remained visible in the board calendar';
  END IF;

  v_recoverable := public.list_deleted_birthdays_p(v_board_id);
  IF NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_recoverable->'birthdays') AS rows(item)
    WHERE rows.item->>'id' = v_birthday_id::text
      AND rows.item->>'can_restore' = 'true'
  ) THEN
    RAISE EXCEPTION 'The deleted birthday was not available for seven-day recovery: %', v_recoverable;
  END IF;

  v_restored := public.restore_birthday_p(
    '29000000-0000-4000-8000-000000000007', v_board_slug, v_birthday_id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(
        public.list_board_birthdays_p(v_board_slug)->'birthdays'
      ) AS rows(item)
      WHERE rows.item->>'id' = v_birthday_id::text
    ) THEN
    RAISE EXCEPTION 'An authorized member could not restore the birthday: %', v_restored;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_slug text;
  v_birthday_id uuid;
  v_deleted jsonb;
  v_restored jsonb;
  v_item jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  SELECT birthday_id INTO STRICT v_birthday_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'max_window';

  v_deleted := public.delete_birthday_p(
    '29000000-0000-4000-8000-000000000091', v_board_slug, v_birthday_id, 1
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The maximum annual window could not be deleted for recovery: %', v_deleted;
  END IF;
  v_restored := public.restore_birthday_p(
    '29000000-0000-4000-8000-000000000092', v_board_slug, v_birthday_id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The maximum annual window could not be restored: %', v_restored;
  END IF;

  SELECT item INTO v_item
  FROM jsonb_array_elements(
    public.list_board_birthdays_p(v_board_slug)->'birthdays'
  ) AS rows(item)
  WHERE item->>'id' = v_birthday_id::text;
  IF v_item->>'advance_days' IS DISTINCT FROM '366' THEN
    RAISE EXCEPTION 'Deleting/restoring a birthday changed its maximum advance window: %', v_item;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  v_board_slug text;
  v_created jsonb;
  v_create_retry jsonb;
  v_updated jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_birthday_id uuid;
  v_denied boolean := false;
  v_operation_key_reuse_rejected boolean := false;
  v_invalid_advance_rejected boolean := false;
BEGIN
  SELECT board_slug INTO STRICT v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  v_created := public.create_birthday_p(
    '29000000-0000-4000-8000-000000000020', v_board_slug,
    'Cumple de colaborador', 4, 5, NULL
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A current collaborator could not create a birthday: %', v_created;
  END IF;
  v_birthday_id := (v_created->'birthday'->>'id')::uuid;
  v_create_retry := public.create_birthday_p(
    '29000000-0000-4000-8000-000000000020', v_board_slug,
    'Cumple de colaborador', 4, 5, NULL
  );
  IF v_create_retry->>'status' IS DISTINCT FROM 'confirmed'
    OR (v_create_retry->'birthday'->>'id')::uuid IS DISTINCT FROM v_birthday_id THEN
    RAISE EXCEPTION 'Retrying the same birthday create operation duplicated or lost its result: %', v_create_retry;
  END IF;
  BEGIN
    PERFORM public.create_birthday_p(
      '29000000-0000-4000-8000-000000000020', v_board_slug,
      'Otro cumpleaños', 4, 5, NULL
    );
  EXCEPTION WHEN check_violation THEN
    v_operation_key_reuse_rejected := true;
  END;
  IF NOT v_operation_key_reuse_rejected THEN
    RAISE EXCEPTION 'A birthday create operation id was reused with a different payload';
  END IF;
  INSERT INTO pg_temp.issue29_birthday_refs(label, birthday_id)
  VALUES ('collaborator', v_birthday_id);

  v_updated := public.update_birthday_p(
    '29000000-0000-4000-8000-000000000021', v_board_slug,
    v_birthday_id, 1, 'Cumple de colaborador editado', 4, 5, 2
  );
  IF v_updated->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A current collaborator could not edit a birthday: %', v_updated;
  END IF;
  BEGIN
    PERFORM public.update_birthday_p(
      '29000000-0000-4000-8000-000000000024', v_board_slug,
      v_birthday_id, 2, 'Anticipación inválida', 4, 5, 367
    );
  EXCEPTION WHEN SQLSTATE '22023' THEN
    v_invalid_advance_rejected := true;
  END;
  IF NOT v_invalid_advance_rejected THEN
    RAISE EXCEPTION 'The birthday update RPC must reject anticipation longer than 366 days';
  END IF;
  v_deleted := public.delete_birthday_p(
    '29000000-0000-4000-8000-000000000022', v_board_slug,
    v_birthday_id, 2
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A current collaborator could not delete a birthday: %', v_deleted;
  END IF;
  v_restored := public.restore_birthday_p(
    '29000000-0000-4000-8000-000000000023', v_board_slug, v_birthday_id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'A current collaborator could not restore a birthday: %', v_restored;
  END IF;

  IF EXISTS (SELECT 1 FROM public.get_my_tasks_p('due')) THEN
    RAISE EXCEPTION 'A birthday appeared in My Tasks as work to complete';
  END IF;
  BEGIN
    PERFORM count(*) FROM public.board_birthdays;
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'Authenticated members can read the private birthday table directly';
  END IF;
END;
$$;
COMMIT;

SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000003', false);
DO $$
DECLARE
  v_board_id uuid;
  v_board_slug text;
  v_birthday_id uuid;
  v_result jsonb;
  v_count integer;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  SELECT receipt.birthday_id INTO STRICT v_birthday_id
  FROM public.birthday_create_operation_receipts AS receipt
  WHERE receipt.actor_id = '42900000-0000-4000-8000-000000000003'
    AND receipt.operation_id = '29000000-0000-4000-8000-000000000020';

  v_result := public.create_birthday_internal_p(
    '29000000-0000-4000-8000-000000000020', v_board_slug,
    'Cumple de colaborador', 4, 5, NULL, '2035-01-01 00:00:00+00'
  );
  IF v_result->>'status' IS DISTINCT FROM 'expired_unknown' THEN
    RAISE EXCEPTION 'An expired birthday create receipt must not blindly replay: %', v_result;
  END IF;
  SELECT count(*) INTO v_count
  FROM public.board_birthdays AS birthday
  WHERE birthday.id = v_birthday_id AND birthday.board_id = v_board_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'An expired create retry changed the existing birthday row count to %', v_count;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000004', true);
DO $$
DECLARE
  v_board_id uuid;
  v_board_slug text;
  v_birthday_id uuid;
  v_result jsonb;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  SELECT birthday_id INTO STRICT v_birthday_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'collaborator';

  v_result := public.list_board_birthdays_p(v_board_slug);
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR jsonb_array_length(v_result->'birthdays') <> 0 THEN
    RAISE EXCEPTION 'A non-member read birthday names through a known slug: %', v_result;
  END IF;
  IF public.list_my_birthdays_p(v_board_id)->>'status' IS DISTINCT FROM 'unavailable'
    OR public.list_deleted_birthdays_p(v_board_id)->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A non-member enumerated active or deleted birthdays';
  END IF;

  v_result := public.create_birthday_p(
    '29000000-0000-4000-8000-000000000030', v_board_slug,
    'No autorizado', 5, 6, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A non-member created a birthday: %', v_result;
  END IF;
  v_result := public.update_birthday_p(
    '29000000-0000-4000-8000-000000000031', v_board_slug,
    v_birthday_id, 3, 'No autorizado', 5, 6, NULL
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A non-member edited a birthday: %', v_result;
  END IF;
  v_result := public.delete_birthday_p(
    '29000000-0000-4000-8000-000000000032', v_board_slug, v_birthday_id, 3
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A non-member deleted a birthday: %', v_result;
  END IF;
  v_result := public.restore_birthday_p(
    '29000000-0000-4000-8000-000000000033', v_board_slug, v_birthday_id
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A non-member restored a birthday: %', v_result;
  END IF;
END;
$$;
COMMIT;

SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000002', false);
DO $$
DECLARE
  v_board_slug text;
  v_birthday_id uuid;
  v_deleted jsonb;
  v_expires_at timestamptz;
  v_restore jsonb;
  v_state text;
  v_snapshot jsonb;
BEGIN
  SELECT board_slug INTO STRICT v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'main';
  SELECT birthday_id INTO STRICT v_birthday_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'leap_day';

  v_deleted := public.delete_birthday_internal_p(
    '29000000-0000-4000-8000-000000000008', v_board_slug, v_birthday_id, 2,
    '2026-03-08 01:30:00-05'
  );
  v_expires_at := (v_deleted->>'expires_at')::timestamptz;
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_expires_at IS DISTINCT FROM '2026-03-15 02:30:00-04'::timestamptz THEN
    RAISE EXCEPTION 'Birthday recovery must retain exactly 168 hours across DST: %', v_deleted;
  END IF;

  v_restore := public.restore_birthday_internal_p(
    '29000000-0000-4000-8000-000000000009', v_board_slug,
    v_birthday_id, v_expires_at
  );
  IF v_restore->>'status' IS DISTINCT FROM 'expired' THEN
    RAISE EXCEPTION 'Birthday recovery should close at the exact expiration instant: %', v_restore;
  END IF;
  IF public.purge_expired_birthday_internal_p(
    v_birthday_id, v_expires_at - interval '1 microsecond'
  ) IS DISTINCT FROM 'too_early' THEN
    RAISE EXCEPTION 'Birthday snapshot purged before the 168-hour deadline';
  END IF;
  IF public.purge_expired_birthday_internal_p(
    v_birthday_id, v_expires_at
  ) IS DISTINCT FROM 'purged' THEN
    RAISE EXCEPTION 'Birthday snapshot did not purge at the exact deadline';
  END IF;
  SELECT deletion.state, deletion.birthday_snapshot
  INTO STRICT v_state, v_snapshot
  FROM public.birthday_deletions AS deletion
  WHERE deletion.birthday_id = v_birthday_id;
  IF v_state IS DISTINCT FROM 'purged' OR v_snapshot IS NOT NULL THEN
    RAISE EXCEPTION 'Purged birthday content remained recoverable: %, %', v_state, v_snapshot;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42900000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board_id uuid;
  v_board_slug text;
  v_created jsonb;
  v_deleted jsonb;
  v_board_deleted jsonb;
  v_birthday_id uuid;
BEGIN
  SELECT board_id, board_slug INTO STRICT v_board_id, v_board_slug
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'dst';
  v_created := public.create_birthday_p(
    '29000000-0000-4000-8000-000000000080', v_board_slug,
    'Cumple borrado con el tablero', 7, 9, NULL
  );
  IF v_created->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the board-purge birthday fixture: %', v_created;
  END IF;
  v_birthday_id := (v_created->'birthday'->>'id')::uuid;
  INSERT INTO pg_temp.issue29_birthday_refs(label, birthday_id)
  VALUES ('board_purge', v_birthday_id);

  v_deleted := public.delete_birthday_p(
    '29000000-0000-4000-8000-000000000081', v_board_slug, v_birthday_id, 1
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not soft-delete the board-purge birthday fixture: %', v_deleted;
  END IF;

  v_board_deleted := public.delete_board_p(
    '29000000-0000-4000-8000-000000000082', v_board_slug, v_board_id
  );
  IF v_board_deleted->>'status' IS DISTINCT FROM 'recoverable' THEN
    RAISE EXCEPTION 'Could not soft-delete the birthday fixture board: %', v_board_deleted;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_board_id uuid;
BEGIN
  SELECT board_id INTO STRICT v_board_id
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'dst';
  UPDATE public.board_recoverable_deletions AS recovery
  SET deleted_at = statement_timestamp() - interval '169 hours',
      expires_at = statement_timestamp() - interval '1 hour'
  WHERE recovery.board_id = v_board_id;
END;
$$;

BEGIN;
SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
DO $$
DECLARE
  v_purged integer;
BEGIN
  v_purged := public.purge_expired_boards_p(100);
  IF v_purged <> 1 THEN
    RAISE EXCEPTION 'Expected one expired birthday fixture board to purge, got %', v_purged;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_board_id uuid;
  v_birthday_id uuid;
BEGIN
  SELECT board_id INTO STRICT v_board_id
  FROM pg_temp.issue29_birthday_board_refs WHERE label = 'dst';
  SELECT birthday_id INTO STRICT v_birthday_id
  FROM pg_temp.issue29_birthday_refs WHERE label = 'board_purge';
  IF EXISTS (
    SELECT 1 FROM public.birthday_deletions AS deletion
    WHERE deletion.birthday_id = v_birthday_id OR deletion.board_id = v_board_id
  ) THEN
    RAISE EXCEPTION 'Hard-purging a board left a birthday snapshot recoverable';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.birthday_create_operation_receipts AS receipt
    WHERE receipt.board_id = v_board_id
  ) THEN
    RAISE EXCEPTION 'Hard-purging a board left birthday operation receipts';
  END IF;
END;
$$;

\echo 'PASS: birthday capture returns an annual entity without task fields'
\echo 'PASS: birthday visibility uses an inclusive board-local annual window'
\echo 'PASS: birthday advance caps at 366 days; create/update RPCs and restore preserve the boundary'
\echo 'PASS: leap-day and DST calculations use board-local calendar dates'
\echo 'PASS: birthday edits use a member-authorized version check'
\echo 'PASS: birthday deletion remains recoverable for seven days'
\echo 'PASS: current collaborators can manage birthdays; non-members and direct table reads are denied'
\echo 'PASS: expired birthday create receipts require reconciliation and do not create a duplicate'
\echo 'PASS: birthday purging clears snapshots at the exact 168-hour deadline across DST'
\echo 'PASS: hard-purging a board clears birthday snapshots and create receipts'
