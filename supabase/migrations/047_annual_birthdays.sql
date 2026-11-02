BEGIN;

CREATE TABLE public.board_birthdays (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  name text NOT NULL CHECK (
    name = btrim(name) AND name <> '' AND char_length(name) <= 100
  ),
  birth_month integer NOT NULL CHECK (birth_month BETWEEN 1 AND 12),
  birth_day integer NOT NULL CHECK (birth_day BETWEEN 1 AND 31),
  advance_days integer CHECK (
    advance_days IS NULL OR advance_days BETWEEN 0 AND 366
  ),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
  CONSTRAINT board_birthdays_valid_calendar_date CHECK (
    pg_catalog.make_date(2000, birth_month, birth_day) IS NOT NULL
  ),
  CONSTRAINT board_birthdays_generation_fk FOREIGN KEY (board_id, generation_id)
    REFERENCES public.board_generations(board_id, id) ON DELETE CASCADE
);
CREATE INDEX board_birthdays_generation_name_idx
  ON public.board_birthdays(board_id, generation_id, name, id);
ALTER TABLE public.board_birthdays ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_birthdays FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.birthday_create_operation_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  birthday_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id),
  CONSTRAINT birthday_create_receipt_generation_fk
    FOREIGN KEY (board_id, generation_id)
    REFERENCES public.board_generations(board_id, id) ON DELETE CASCADE
);
ALTER TABLE public.birthday_create_operation_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.birthday_create_operation_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.birthday_create_payload_hash_p(p_payload jsonb)
RETURNS bytea
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, extensions, pg_temp
AS $$
  SELECT extensions.digest(
    pg_catalog.convert_to(p_payload::text, 'UTF8'), 'sha256'
  );
$$;

CREATE TABLE public.birthday_deletions (
  birthday_id uuid PRIMARY KEY,
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  deleted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  deleted_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  birthday_snapshot jsonb,
  state text NOT NULL CHECK (state IN ('deleted', 'restored', 'purged')),
  restored_at timestamptz,
  purged_at timestamptz,
  CONSTRAINT birthday_deletions_exact_window CHECK (
    expires_at = deleted_at + interval '168 hours'
  ),
  CONSTRAINT birthday_deletions_state_shape CHECK (
    (state = 'deleted' AND birthday_snapshot IS NOT NULL
      AND restored_at IS NULL AND purged_at IS NULL)
    OR (state = 'restored' AND birthday_snapshot IS NULL
      AND restored_at IS NOT NULL AND purged_at IS NULL)
    OR (state = 'purged' AND birthday_snapshot IS NULL
      AND restored_at IS NULL AND purged_at IS NOT NULL)
  )
);
CREATE INDEX birthday_deletions_board_expiry_idx
  ON public.birthday_deletions(board_id, expires_at, birthday_id)
  WHERE state = 'deleted';
ALTER TABLE public.birthday_deletions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.birthday_deletions
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.birthday_date_for_year_p(
  p_month integer,
  p_day integer,
  p_year integer
)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_day integer := p_day;
  v_is_leap boolean;
BEGIN
  IF p_month < 1 OR p_month > 12 OR p_day < 1 OR p_day > 31
    OR p_year < 1 OR p_year > 9999 THEN
    RAISE EXCEPTION 'Birthday date is invalid' USING ERRCODE = '22023';
  END IF;

  v_is_leap := p_year % 400 = 0 OR (p_year % 4 = 0 AND p_year % 100 <> 0);
  IF p_month = 2 AND p_day = 29 AND NOT v_is_leap THEN
    v_day := 28;
  END IF;

  RETURN pg_catalog.make_date(p_year, p_month, v_day);
END;
$$;

CREATE FUNCTION public.create_birthday_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_name text,
  p_birth_month integer,
  p_birth_day integer,
  p_advance_days integer,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_membership_id uuid;
  v_birthday public.board_birthdays%ROWTYPE;
  v_receipt public.birthday_create_operation_receipts%ROWTYPE;
  v_payload_hash bytea;
  v_birthday_id uuid := gen_random_uuid();
  v_now timestamptz := coalesce(p_now, pg_catalog.clock_timestamp());
  v_today date;
  v_next_on date;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_name IS NULL
    OR p_birth_month IS NULL OR p_birth_day IS NULL
    OR p_advance_days < 0 OR p_advance_days > 366 THEN
    RAISE EXCEPTION 'Birthday capture requires a name, date, and valid advance window'
      USING ERRCODE = '22023';
  END IF;
  IF p_name <> btrim(p_name) OR p_name = '' OR char_length(p_name) > 100 THEN
    RAISE EXCEPTION 'Birthday name must contain 1 to 100 characters'
      USING ERRCODE = '22023';
  END IF;
  PERFORM public.birthday_date_for_year_p(p_birth_month, p_birth_day, 2000);

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  v_payload_hash := public.birthday_create_payload_hash_p(jsonb_build_object(
    'action', 'create_birthday',
    'board_id', v_board.id,
    'name', p_name,
    'birth_month', p_birth_month,
    'birth_day', p_birth_day,
    'advance_days', p_advance_days
  ));

  INSERT INTO public.birthday_create_operation_receipts (
    actor_id, operation_id, board_id, generation_id, birthday_id, payload_hash
  ) VALUES (
    v_actor_id, p_operation_id, v_board.id, v_board.active_generation_id,
    v_birthday_id, v_payload_hash
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;

  IF NOT FOUND THEN
    SELECT receipt.* INTO v_receipt
    FROM public.birthday_create_operation_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;

    IF NOT FOUND OR v_receipt.board_id IS DISTINCT FROM v_board.id
      OR v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'Birthday create operation key was already used with different details'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= v_now THEN
      RETURN jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    IF v_receipt.generation_id IS DISTINCT FROM v_board.active_generation_id THEN
      RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
    END IF;

    SELECT birthday.* INTO v_birthday
    FROM public.board_birthdays AS birthday
    WHERE birthday.id = v_receipt.birthday_id
      AND birthday.board_id = v_board.id
      AND birthday.generation_id = v_board.active_generation_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
    END IF;
  ELSE
    INSERT INTO public.board_birthdays (
      id, board_id, generation_id, name, birth_month, birth_day,
      advance_days, created_by
    ) VALUES (
      v_birthday_id, v_board.id, v_board.active_generation_id, p_name,
      p_birth_month, p_birth_day, p_advance_days, v_actor_id
    ) RETURNING * INTO v_birthday;
  END IF;

  v_today := public.board_calendar_day(v_board.time_zone, v_now);
  v_next_on := public.birthday_date_for_year_p(
    v_birthday.birth_month, v_birthday.birth_day, extract(year FROM v_today)::integer
  );
  IF v_next_on < v_today THEN
    v_next_on := public.birthday_date_for_year_p(
      v_birthday.birth_month, v_birthday.birth_day, extract(year FROM v_today)::integer + 1
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'birthday', jsonb_build_object(
      'id', v_birthday.id,
      'board_id', v_board.id,
      'board_slug', v_board.slug,
      'name', v_birthday.name,
      'birth_month', v_birthday.birth_month,
      'birth_day', v_birthday.birth_day,
      'advance_days', v_birthday.advance_days,
      'next_on', v_next_on,
      'created_at', v_birthday.created_at,
      'updated_at', v_birthday.updated_at,
      'version', v_birthday.version
    )
  );
END;
$$;

CREATE FUNCTION public.create_birthday_p(
  p_operation_id uuid,
  p_slug text,
  p_name text,
  p_birth_month integer,
  p_birth_day integer,
  p_advance_days integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.create_birthday_internal_p(
    p_operation_id, p_slug, p_name, p_birth_month, p_birth_day,
    p_advance_days, NULL
  );
$$;

CREATE FUNCTION public.list_board_birthdays_internal_p(
  p_slug text,
  p_now timestamptz,
  p_include_hidden boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_today date;
  v_birthdays jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'birthdays', '[]'::jsonb);
  END IF;
  IF NOT public.is_application_user() OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'birthdays', '[]'::jsonb);
  END IF;

  v_today := public.board_calendar_day(
    v_board.time_zone, coalesce(p_now, pg_catalog.clock_timestamp())
  );

  WITH computed AS (
    SELECT birthday.*,
      CASE
        WHEN public.birthday_date_for_year_p(
          birthday.birth_month, birthday.birth_day,
          extract(year FROM v_today)::integer
        ) >= v_today THEN public.birthday_date_for_year_p(
          birthday.birth_month, birthday.birth_day,
          extract(year FROM v_today)::integer
        )
        ELSE public.birthday_date_for_year_p(
          birthday.birth_month, birthday.birth_day,
          extract(year FROM v_today)::integer + 1
        )
      END AS next_on
    FROM public.board_birthdays AS birthday
    WHERE birthday.board_id = v_board.id
      AND birthday.generation_id = v_board.active_generation_id
  )
  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', computed.id,
        'board_id', v_board.id,
        'board_slug', v_board.slug,
        'board_name', v_board.name,
        'board_time_zone', v_board.time_zone,
        'name', computed.name,
        'birth_month', computed.birth_month,
        'birth_day', computed.birth_day,
        'advance_days', computed.advance_days,
        'next_on', computed.next_on,
        'visible', (computed.advance_days IS NULL
          OR v_today BETWEEN computed.next_on - computed.advance_days AND computed.next_on),
        'created_at', computed.created_at,
        'updated_at', computed.updated_at,
        'version', computed.version
      ) ORDER BY computed.next_on, computed.id
    ),
    '[]'::jsonb
  ) INTO v_birthdays
  FROM computed
  WHERE p_include_hidden OR computed.advance_days IS NULL
    OR v_today BETWEEN computed.next_on - computed.advance_days AND computed.next_on;

  RETURN jsonb_build_object(
    'status', 'available',
    'board_id', v_board.id,
    'board_slug', v_board.slug,
    'today', v_today,
    'birthdays', v_birthdays
  );
END;
$$;

CREATE FUNCTION public.list_board_birthdays_p(p_slug text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.list_board_birthdays_internal_p(p_slug, NULL, false);
$$;

CREATE FUNCTION public.list_my_birthdays_p(p_board_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board record;
  v_result jsonb;
  v_birthdays jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;

  IF p_board_id IS NOT NULL AND NOT public.is_board_member(p_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'birthdays', '[]'::jsonb);
  END IF;

  FOR v_board IN
    SELECT board.id, board.slug
    FROM public.boards AS board
    WHERE (p_board_id IS NULL OR board.id = p_board_id)
      AND public.is_board_member(board.id)
    ORDER BY board.id
  LOOP
    v_result := public.list_board_birthdays_internal_p(v_board.slug, NULL, true);
    IF v_result->>'status' = 'available' THEN
      v_birthdays := v_birthdays || coalesce(v_result->'birthdays', '[]'::jsonb);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('status', 'available', 'birthdays', v_birthdays);
END;
$$;

CREATE FUNCTION public.update_birthday_p(
  p_operation_id uuid,
  p_slug text,
  p_birthday_id uuid,
  p_expected_version bigint,
  p_name text,
  p_birth_month integer,
  p_birth_day integer,
  p_advance_days integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_birthday public.board_birthdays%ROWTYPE;
  v_membership_id uuid;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_birthday_id IS NULL
    OR p_expected_version IS NULL OR p_name IS NULL
    OR p_birth_month IS NULL OR p_birth_day IS NULL
    OR p_advance_days < 0 OR p_advance_days > 366 THEN
    RAISE EXCEPTION 'Birthday editing requires complete valid fields'
      USING ERRCODE = '22023';
  END IF;
  IF p_name <> btrim(p_name) OR p_name = '' OR char_length(p_name) > 100 THEN
    RAISE EXCEPTION 'Birthday name must contain 1 to 100 characters'
      USING ERRCODE = '22023';
  END IF;
  PERFORM public.birthday_date_for_year_p(p_birth_month, p_birth_day, 2000);

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.board_birthdays AS birthday ON birthday.board_id = board.id
  WHERE board.slug = p_slug AND birthday.id = p_birthday_id
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT birthday.* INTO v_birthday
  FROM public.board_birthdays AS birthday
  WHERE birthday.id = p_birthday_id
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_birthday.version IS DISTINCT FROM p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'birthday_id', v_birthday.id, 'current_version', v_birthday.version
    );
  END IF;

  UPDATE public.board_birthdays AS birthday
  SET name = p_name,
      birth_month = p_birth_month,
      birth_day = p_birth_day,
      advance_days = p_advance_days,
      updated_at = pg_catalog.clock_timestamp(),
      version = birthday.version + 1
  WHERE birthday.id = v_birthday.id
  RETURNING * INTO v_birthday;

  RETURN jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'birthday_id', v_birthday.id, 'version', v_birthday.version
  );
END;
$$;

CREATE FUNCTION public.delete_birthday_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_birthday_id uuid,
  p_expected_version bigint,
  p_deleted_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_board public.boards%ROWTYPE;
  v_birthday public.board_birthdays%ROWTYPE;
  v_membership_id uuid;
  v_deleted_at timestamptz := coalesce(p_deleted_at, pg_catalog.clock_timestamp());
  v_expires_at timestamptz;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_birthday_id IS NULL
    OR p_expected_version IS NULL THEN
    RAISE EXCEPTION 'Birthday deletion requires an operation and current item version'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.board_birthdays AS birthday ON birthday.board_id = board.id
  WHERE board.slug = p_slug AND birthday.id = p_birthday_id
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT birthday.* INTO v_birthday
  FROM public.board_birthdays AS birthday
  WHERE birthday.id = p_birthday_id
    AND birthday.board_id = v_board.id
    AND birthday.generation_id = v_board.active_generation_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_birthday.version IS DISTINCT FROM p_expected_version THEN
    RETURN jsonb_build_object(
      'status', 'conflict', 'operation_id', p_operation_id,
      'birthday_id', v_birthday.id, 'current_version', v_birthday.version
    );
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.birthday_deletions AS deletion
    WHERE deletion.birthday_id = v_birthday.id AND deletion.state = 'deleted'
  ) THEN
    RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;

  v_expires_at := v_deleted_at + interval '168 hours';
  INSERT INTO public.birthday_deletions (
    birthday_id, board_id, generation_id, deleted_by, deleted_at,
    expires_at, birthday_snapshot, state
  ) VALUES (
    v_birthday.id, v_board.id, v_birthday.generation_id, v_actor_id,
    v_deleted_at, v_expires_at, pg_catalog.to_jsonb(v_birthday), 'deleted'
  ) ON CONFLICT (birthday_id) DO UPDATE
    SET board_id = EXCLUDED.board_id,
        generation_id = EXCLUDED.generation_id,
        deleted_by = EXCLUDED.deleted_by,
        deleted_at = EXCLUDED.deleted_at,
        expires_at = EXCLUDED.expires_at,
        birthday_snapshot = EXCLUDED.birthday_snapshot,
        state = 'deleted', restored_at = NULL, purged_at = NULL;

  DELETE FROM public.board_birthdays AS birthday
  WHERE birthday.id = v_birthday.id;

  RETURN jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'birthday_id', v_birthday.id,
    'deleted_at', v_deleted_at,
    'expires_at', v_expires_at
  );
END;
$$;

CREATE FUNCTION public.delete_birthday_p(
  p_operation_id uuid,
  p_slug text,
  p_birthday_id uuid,
  p_expected_version bigint
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.delete_birthday_internal_p(
    p_operation_id, p_slug, p_birthday_id, p_expected_version, NULL
  );
$$;

CREATE FUNCTION public.list_deleted_birthdays_p(p_board_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_birthdays jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_board_id IS NOT NULL AND NOT public.is_board_member(p_board_id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'birthdays', '[]'::jsonb);
  END IF;

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', deletion.birthday_id,
        'board_id', board.id,
        'board_slug', board.slug,
        'board_name', board.name,
        'name', deletion.birthday_snapshot->>'name',
        'birth_month', (deletion.birthday_snapshot->>'birth_month')::integer,
        'birth_day', (deletion.birthday_snapshot->>'birth_day')::integer,
        'advance_days', deletion.birthday_snapshot->'advance_days',
        'deleted_at', deletion.deleted_at,
        'expires_at', deletion.expires_at,
        'can_restore', deletion.expires_at > pg_catalog.statement_timestamp()
          AND board.active_generation_id = deletion.generation_id
      ) ORDER BY deletion.deleted_at DESC, deletion.birthday_id
    ),
    '[]'::jsonb
  ) INTO v_birthdays
  FROM public.birthday_deletions AS deletion
  JOIN public.boards AS board ON board.id = deletion.board_id
  WHERE deletion.state = 'deleted'
    AND deletion.expires_at > pg_catalog.statement_timestamp()
    AND (p_board_id IS NULL OR board.id = p_board_id)
    AND public.is_board_member(board.id);

  RETURN jsonb_build_object('status', 'available', 'birthdays', v_birthdays);
END;
$$;

CREATE FUNCTION public.restore_birthday_internal_p(
  p_operation_id uuid,
  p_slug text,
  p_birthday_id uuid,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_board_id uuid;
  v_deletion public.birthday_deletions%ROWTYPE;
  v_membership_id uuid;
  v_now timestamptz := coalesce(p_now, pg_catalog.clock_timestamp());
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_birthday_id IS NULL THEN
    RAISE EXCEPTION 'Birthday recovery requires an operation and item'
      USING ERRCODE = '22023';
  END IF;

  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.birthday_deletions AS deletion ON deletion.board_id = board.id
  WHERE board.slug = p_slug AND deletion.birthday_id = p_birthday_id
    AND deletion.state = 'deleted' AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = v_board_id
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = v_board.id
    AND membership.user_id = v_actor_id
    AND membership.revoked_at IS NULL
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_board_member(v_board.id) THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  SELECT deletion.* INTO v_deletion
  FROM public.birthday_deletions AS deletion
  WHERE deletion.birthday_id = p_birthday_id
    AND deletion.board_id = v_board.id
    AND deletion.state = 'deleted'
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_deletion.expires_at <= v_now THEN
    RETURN jsonb_build_object('status', 'expired', 'operation_id', p_operation_id);
  END IF;
  IF v_deletion.generation_id IS DISTINCT FROM v_board.active_generation_id THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.board_birthdays AS birthday
    WHERE birthday.id = p_birthday_id
  ) THEN
    RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;

  INSERT INTO public.board_birthdays (
    id, board_id, generation_id, name, birth_month, birth_day,
    advance_days, created_by, created_at, updated_at, version
  ) VALUES (
    (v_deletion.birthday_snapshot->>'id')::uuid,
    (v_deletion.birthday_snapshot->>'board_id')::uuid,
    (v_deletion.birthday_snapshot->>'generation_id')::uuid,
    v_deletion.birthday_snapshot->>'name',
    (v_deletion.birthday_snapshot->>'birth_month')::integer,
    (v_deletion.birthday_snapshot->>'birth_day')::integer,
    (v_deletion.birthday_snapshot->>'advance_days')::integer,
    nullif(v_deletion.birthday_snapshot->>'created_by', '')::uuid,
    (v_deletion.birthday_snapshot->>'created_at')::timestamptz,
    (v_deletion.birthday_snapshot->>'updated_at')::timestamptz,
    (v_deletion.birthday_snapshot->>'version')::bigint
  );
  UPDATE public.birthday_deletions AS deletion
  SET state = 'restored', birthday_snapshot = NULL, restored_at = v_now
  WHERE deletion.birthday_id = v_deletion.birthday_id;

  RETURN jsonb_build_object(
    'status', 'confirmed', 'operation_id', p_operation_id,
    'birthday_id', p_birthday_id
  );
END;
$$;

CREATE FUNCTION public.restore_birthday_p(
  p_operation_id uuid,
  p_slug text,
  p_birthday_id uuid
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.restore_birthday_internal_p(
    p_operation_id, p_slug, p_birthday_id, NULL
  );
$$;

CREATE FUNCTION public.purge_expired_birthday_internal_p(
  p_birthday_id uuid,
  p_now timestamptz
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_deletion public.birthday_deletions%ROWTYPE;
  v_now timestamptz := coalesce(p_now, pg_catalog.clock_timestamp());
BEGIN
  SELECT deletion.board_id INTO v_board_id
  FROM public.birthday_deletions AS deletion
  WHERE deletion.birthday_id = p_birthday_id;
  IF FOUND THEN
    PERFORM board.id FROM public.boards AS board
    WHERE board.id = v_board_id FOR UPDATE;
  END IF;

  SELECT deletion.* INTO v_deletion
  FROM public.birthday_deletions AS deletion
  WHERE deletion.birthday_id = p_birthday_id
  FOR UPDATE;
  IF NOT FOUND OR v_deletion.state <> 'deleted' THEN
    RETURN 'already_terminal';
  END IF;
  IF v_now < v_deletion.expires_at THEN
    RETURN 'too_early';
  END IF;

  UPDATE public.birthday_deletions AS deletion
  SET state = 'purged', birthday_snapshot = NULL, purged_at = v_now
  WHERE deletion.birthday_id = v_deletion.birthday_id;
  RETURN 'purged';
END;
$$;

CREATE FUNCTION public.purge_expired_birthday_deletions_p(p_limit integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_birthday_id uuid;
  v_purged integer := 0;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Trusted worker access is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
    RAISE EXCEPTION 'Choose a purge limit from 1 to 1000' USING ERRCODE = '22023';
  END IF;
  FOR v_birthday_id IN
    SELECT deletion.birthday_id
    FROM public.birthday_deletions AS deletion
    WHERE deletion.state = 'deleted'
      AND deletion.expires_at <= pg_catalog.clock_timestamp()
    ORDER BY deletion.expires_at, deletion.birthday_id
    LIMIT p_limit
  LOOP
    IF public.purge_expired_birthday_internal_p(
      v_birthday_id, pg_catalog.clock_timestamp()
    ) = 'purged' THEN
      v_purged := v_purged + 1;
    END IF;
  END LOOP;
  RETURN v_purged;
END;
$$;

REVOKE ALL ON FUNCTION public.birthday_date_for_year_p(integer, integer, integer)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.birthday_create_payload_hash_p(jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_birthday_internal_p(uuid, text, text, integer, integer, integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_board_birthdays_internal_p(text, timestamptz, boolean)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_birthday_p(uuid, text, text, integer, integer, integer)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_board_birthdays_p(text)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_my_birthdays_p(uuid)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.update_birthday_p(uuid, text, uuid, bigint, text, integer, integer, integer)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.delete_birthday_internal_p(uuid, text, uuid, bigint, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_birthday_p(uuid, text, uuid, bigint)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.list_deleted_birthdays_p(uuid)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.restore_birthday_internal_p(uuid, text, uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_birthday_p(uuid, text, uuid)
  FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_birthday_internal_p(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.purge_expired_birthday_deletions_p(integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_birthday_p(uuid, text, text, integer, integer, integer)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_board_birthdays_p(text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_my_birthdays_p(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_birthday_p(uuid, text, uuid, bigint, text, integer, integer, integer)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_birthday_p(uuid, text, uuid, bigint)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_deleted_birthdays_p(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.restore_birthday_p(uuid, text, uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.purge_expired_birthday_deletions_p(integer)
  TO service_role;

COMMIT;
