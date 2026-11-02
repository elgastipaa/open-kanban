-- Suspend application access only after every owned board and open invitation
-- has a durable, explicit outcome.
BEGIN;

ALTER TABLE public.board_recoverable_deletions
  ADD COLUMN recovery_owner_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  DROP CONSTRAINT board_recoverable_deletions_cause_check,
  ADD CONSTRAINT board_recoverable_deletions_cause_check
    CHECK (cause IN (
      'owner_confirmed_last_member', 'owner_requested', 'admin_suspended_owner'
    ));

CREATE TABLE public.account_suspension_write_contexts (
  transaction_id bigint PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  board_ids uuid[] NOT NULL
);
ALTER TABLE public.account_suspension_write_contexts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.account_suspension_write_contexts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.lock_application_access_rows_p(
  p_user_ids uuid[],
  p_exclusive_user_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  FOR v_user_id IN
    SELECT DISTINCT candidate.user_id
    FROM pg_catalog.unnest(coalesce(p_user_ids, ARRAY[]::uuid[])) AS candidate(user_id)
    WHERE candidate.user_id IS NOT NULL
    ORDER BY candidate.user_id
  LOOP
    IF v_user_id = p_exclusive_user_id THEN
      PERFORM 1
      FROM public.application_access AS access
      WHERE access.auth_user_id = v_user_id
      FOR UPDATE;
    ELSE
      PERFORM 1
      FROM public.application_access AS access
      WHERE access.auth_user_id = v_user_id
      FOR SHARE;
    END IF;
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.lock_application_access_rows_p(uuid[], uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.admin_preview_account_suspension_p(p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_target public.application_access%ROWTYPE;
  v_board record;
  v_state text;
  v_relationship text;
  v_recovery_owner_id uuid;
  v_recovery_owner_is_active boolean;
  v_active_member_count integer;
  v_has_enabled_collaborator boolean;
  v_candidates jsonb;
  v_boards jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.require_application_admin();
  SELECT access.* INTO v_target
  FROM public.application_access AS access
  WHERE access.email = pg_catalog.lower(pg_catalog.btrim(p_email))
    AND access.auth_user_id IS NOT NULL;
  IF NOT FOUND OR v_target.state <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable', 'boards', v_boards);
  END IF;

  FOR v_board IN
    SELECT board.id, board.slug, board.name, board.owner_id,
      recovery.deleted_at, recovery.expires_at, recovery.recovery_owner_id,
      recovery.board_id AS recovery_board_id,
      membership.role AS target_role
    FROM public.boards AS board
    LEFT JOIN public.board_recoverable_deletions AS recovery
      ON recovery.board_id = board.id
    LEFT JOIN LATERAL (
      SELECT member.role
      FROM public.board_memberships AS member
      WHERE member.board_id = board.id
        AND member.user_id = v_target.auth_user_id
        AND member.revoked_at IS NULL
      ORDER BY member.joined_at DESC, member.id DESC
      LIMIT 1
    ) AS membership ON true
    WHERE (
        recovery.board_id IS NULL
        AND (board.owner_id = v_target.auth_user_id OR membership.role IS NOT NULL)
      ) OR (
        recovery.expires_at > statement_timestamp()
        AND (board.owner_id = v_target.auth_user_id
          OR recovery.recovery_owner_id = v_target.auth_user_id
          OR membership.role IS NOT NULL)
      )
    ORDER BY board.id
  LOOP
    v_state := CASE WHEN v_board.recovery_board_id IS NULL THEN 'active' ELSE 'recoverable' END;
    v_recovery_owner_id := v_board.recovery_owner_id;
    v_recovery_owner_is_active := v_recovery_owner_id IS NOT NULL
      AND public.is_enabled_application_identity_p(v_recovery_owner_id);
    v_relationship := CASE
      WHEN v_state = 'recoverable' AND v_recovery_owner_id = v_target.auth_user_id
        THEN 'recovery_owner'
      WHEN v_board.owner_id = v_target.auth_user_id THEN 'owner'
      ELSE 'collaborator'
    END;
    SELECT count(*)::integer INTO v_active_member_count
    FROM public.board_memberships AS member
    WHERE member.board_id = v_board.id AND member.revoked_at IS NULL;

    IF v_relationship = 'collaborator'
      OR (v_state = 'recoverable' AND v_recovery_owner_is_active
        AND v_recovery_owner_id <> v_target.auth_user_id) THEN
      v_candidates := '[]'::jsonb;
    ELSIF v_state = 'active' THEN
      SELECT coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'user_id', access.auth_user_id,
          'email', access.email,
          'is_admin', access.is_admin
        ) ORDER BY pg_catalog.lower(access.email), access.auth_user_id
      ), '[]'::jsonb) INTO v_candidates
      FROM public.board_memberships AS member
      JOIN public.application_access AS access
        ON access.auth_user_id = member.user_id
      WHERE member.board_id = v_board.id
        AND member.role = 'collaborator'
        AND member.revoked_at IS NULL
        AND access.auth_user_id <> v_target.auth_user_id
        AND public.is_enabled_application_identity_p(access.auth_user_id);
    ELSE
      SELECT EXISTS (
        SELECT 1
        FROM public.board_memberships AS member
        WHERE member.board_id = v_board.id
          AND member.user_id <> v_target.auth_user_id
          AND member.role = 'collaborator'
          AND member.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(member.user_id)
      ) INTO v_has_enabled_collaborator;
      SELECT coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'user_id', access.auth_user_id,
          'email', access.email,
          'is_admin', access.is_admin
        ) ORDER BY pg_catalog.lower(access.email), access.auth_user_id
      ), '[]'::jsonb) INTO v_candidates
      FROM public.application_access AS access
      WHERE access.auth_user_id <> v_target.auth_user_id
        AND public.is_enabled_application_identity_p(access.auth_user_id)
        AND (
          NOT v_has_enabled_collaborator
          OR EXISTS (
            SELECT 1
            FROM public.board_memberships AS member
            WHERE member.board_id = v_board.id
              AND member.user_id = access.auth_user_id
              AND member.role = 'collaborator'
              AND member.revoked_at IS NULL
          )
        );
    END IF;

    v_boards := v_boards || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'board_id', v_board.id,
        'slug', v_board.slug,
        'name', v_board.name,
        'state', v_state,
        'relationship', v_relationship,
        'active_member_count', v_active_member_count,
        'deleted_at', v_board.deleted_at,
        'expires_at', v_board.expires_at,
        'recovery_owner_id', v_recovery_owner_id,
        'recovery_owner_is_active', coalesce(v_recovery_owner_is_active, false),
        'candidates', v_candidates
      )
    );
  END LOOP;

  RETURN pg_catalog.jsonb_build_object('status', 'ready', 'boards', v_boards);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_preview_account_suspension_p(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_preview_account_suspension_p(text)
  TO authenticated;

CREATE FUNCTION public.admin_suspend_access_with_successions_p(
  p_email text,
  p_resolutions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_target public.application_access%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_recovery public.board_recoverable_deletions%ROWTYPE;
  v_resolution record;
  v_user_id uuid;
  v_lock_ids uuid[];
  v_board_ids uuid[];
  v_expected_resolution_ids uuid[];
  v_supplied_resolution_ids uuid[];
  v_duplicate_resolution boolean;
  v_has_enabled_collaborator boolean;
  v_candidate_count integer;
  v_successor_id uuid;
  v_action text;
  v_suspended_at timestamptz := clock_timestamp();
  v_transferred_count integer := 0;
  v_recoverable_count integer := 0;
BEGIN
  PERFORM public.require_application_admin();
  LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
  PERFORM public.require_application_admin();

  IF p_resolutions IS NULL OR pg_catalog.jsonb_typeof(p_resolutions) <> 'array' THEN
    RAISE EXCEPTION 'Board succession choices are required' USING ERRCODE = '22023';
  END IF;
  SELECT access.* INTO v_target
  FROM public.application_access AS access
  WHERE access.email = pg_catalog.lower(pg_catalog.btrim(p_email))
    AND access.auth_user_id IS NOT NULL;
  IF NOT FOUND OR v_target.state <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT coalesce(array_agg(user_id ORDER BY user_id), ARRAY[]::uuid[])
  INTO v_lock_ids
  FROM (
    SELECT v_target.auth_user_id AS user_id
    UNION
    SELECT nullif(item.value->>'successor_id', '')::uuid
    FROM pg_catalog.jsonb_array_elements(p_resolutions) AS item(value)
    WHERE item.value ? 'successor_id'
  ) AS participants
  WHERE user_id IS NOT NULL;
  PERFORM public.lock_application_access_rows_p(v_lock_ids, v_target.auth_user_id);
  SELECT access.* INTO v_target
  FROM public.application_access AS access
  WHERE access.auth_user_id = v_target.auth_user_id
  FOR UPDATE;
  IF NOT FOUND OR v_target.state <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  PERFORM public.require_application_admin();

  IF v_target.is_admin AND (
    SELECT count(*) FROM public.application_access AS active_admin
    WHERE active_admin.is_admin AND active_admin.state = 'active'
  ) <= 1 THEN
    RAISE EXCEPTION 'At least one active administrator must remain' USING ERRCODE = '23514';
  END IF;

  SELECT coalesce(array_agg(board.id ORDER BY board.id), ARRAY[]::uuid[])
  INTO v_board_ids
  FROM public.boards AS board
  WHERE EXISTS (
      SELECT 1 FROM public.board_memberships AS member
      WHERE member.board_id = board.id
        AND member.user_id = v_target.auth_user_id
        AND member.revoked_at IS NULL
    )
    OR board.owner_id = v_target.auth_user_id
    OR EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = board.id
        AND recovery.recovery_owner_id = v_target.auth_user_id
    )
    OR EXISTS (
      SELECT 1 FROM public.tasks AS task
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.board_id = board.id
        AND task.assignee_id = v_target.auth_user_id
        AND NOT task.is_completed
    )
    OR EXISTS (
      SELECT 1 FROM public.board_invitations AS invitation
      WHERE invitation.board_id = board.id
        AND invitation.status = 'pending'
        AND (invitation.inviter_id = v_target.auth_user_id
          OR invitation.recipient_id = v_target.auth_user_id)
    );

  FOREACH v_user_id IN ARRAY v_board_ids LOOP
    PERFORM 1 FROM public.boards AS board
    WHERE board.id = v_user_id
    FOR UPDATE;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_to_recordset(p_resolutions)
      AS resolution(board_id uuid, action text, successor_id uuid)
    GROUP BY resolution.board_id
    HAVING count(*) > 1
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'conflict');
  END IF;

  SELECT coalesce(array_agg(expected.board_id ORDER BY expected.board_id), ARRAY[]::uuid[])
  INTO v_expected_resolution_ids
  FROM (
    SELECT board.id AS board_id
    FROM public.boards AS board
    LEFT JOIN public.board_recoverable_deletions AS recovery
      ON recovery.board_id = board.id
    WHERE board.id = ANY(v_board_ids)
      AND (
        (recovery.board_id IS NULL AND board.owner_id = v_target.auth_user_id)
        OR (
          recovery.expires_at > v_suspended_at
          AND (
            recovery.recovery_owner_id = v_target.auth_user_id
            OR (
              board.owner_id = v_target.auth_user_id
              AND (
                recovery.recovery_owner_id IS NULL
                OR NOT public.is_enabled_application_identity_p(recovery.recovery_owner_id)
              )
            )
          )
        )
      )
  ) AS expected;
  SELECT coalesce(array_agg(supplied.board_id ORDER BY supplied.board_id), ARRAY[]::uuid[]),
    coalesce(bool_or(supplied.duplicate), false)
  INTO v_supplied_resolution_ids, v_duplicate_resolution
  FROM (
    SELECT resolution.board_id, count(*) > 1 AS duplicate
    FROM pg_catalog.jsonb_to_recordset(p_resolutions)
      AS resolution(board_id uuid, action text, successor_id uuid)
    GROUP BY resolution.board_id
  ) AS supplied;
  IF v_expected_resolution_ids IS DISTINCT FROM v_supplied_resolution_ids
    OR v_duplicate_resolution THEN
    RETURN pg_catalog.jsonb_build_object('status', 'conflict');
  END IF;

  FOR v_board IN
    SELECT board.*
    FROM public.boards AS board
    WHERE board.id = ANY(v_board_ids)
    ORDER BY board.id
  LOOP
    SELECT recovery.* INTO v_recovery
    FROM public.board_recoverable_deletions AS recovery
    WHERE recovery.board_id = v_board.id
    FOR UPDATE;

    IF v_recovery.board_id IS NULL AND v_board.owner_id = v_target.auth_user_id THEN
      SELECT resolution.action, resolution.successor_id
      INTO v_action, v_successor_id
      FROM pg_catalog.jsonb_to_recordset(p_resolutions)
        AS resolution(board_id uuid, action text, successor_id uuid)
      WHERE resolution.board_id = v_board.id;
      SELECT count(*)::integer INTO v_candidate_count
      FROM public.board_memberships AS member
      WHERE member.board_id = v_board.id
        AND member.user_id <> v_target.auth_user_id
        AND member.role = 'collaborator'
        AND member.revoked_at IS NULL
        AND public.is_enabled_application_identity_p(member.user_id);
      IF v_candidate_count > 0 THEN
        IF v_action IS DISTINCT FROM 'transfer' OR v_successor_id IS NULL
          OR NOT EXISTS (
            SELECT 1 FROM public.board_memberships AS member
            WHERE member.board_id = v_board.id
              AND member.user_id = v_successor_id
              AND member.user_id <> v_target.auth_user_id
              AND member.role = 'collaborator'
              AND member.revoked_at IS NULL
              AND public.is_enabled_application_identity_p(member.user_id)
          ) THEN
          RETURN pg_catalog.jsonb_build_object('status', 'conflict');
        END IF;
        UPDATE public.boards AS board
        SET owner_id = v_successor_id
        WHERE board.id = v_board.id;
        UPDATE public.board_memberships AS member
        SET revoked_at = v_suspended_at
        WHERE member.board_id = v_board.id
          AND member.user_id = v_target.auth_user_id
          AND member.revoked_at IS NULL;
        UPDATE public.board_memberships AS member
        SET role = 'owner'
        WHERE member.board_id = v_board.id
          AND member.user_id = v_successor_id
          AND member.role = 'collaborator'
          AND member.revoked_at IS NULL;
        v_transferred_count := v_transferred_count + 1;
      ELSE
        IF v_action IS DISTINCT FROM 'recover' OR v_successor_id IS NOT NULL THEN
          RETURN pg_catalog.jsonb_build_object('status', 'conflict');
        END IF;
        INSERT INTO public.board_recoverable_deletions (
          board_id, actor_id, cause, deleted_at, expires_at, recovery_owner_id
        ) VALUES (
          v_board.id, v_target.auth_user_id, 'admin_suspended_owner',
          v_suspended_at, v_suspended_at + interval '168 hours', NULL
        );
        v_recoverable_count := v_recoverable_count + 1;
      END IF;
    ELSIF v_recovery.board_id IS NOT NULL
      AND v_recovery.expires_at > v_suspended_at
      AND (
        v_recovery.recovery_owner_id = v_target.auth_user_id
        OR (
          v_board.owner_id = v_target.auth_user_id
          AND (v_recovery.recovery_owner_id IS NULL
            OR NOT public.is_enabled_application_identity_p(v_recovery.recovery_owner_id))
        )
      ) THEN
      SELECT resolution.action, resolution.successor_id
      INTO v_action, v_successor_id
      FROM pg_catalog.jsonb_to_recordset(p_resolutions)
        AS resolution(board_id uuid, action text, successor_id uuid)
      WHERE resolution.board_id = v_board.id;
      SELECT EXISTS (
        SELECT 1
        FROM public.board_memberships AS member
        WHERE member.board_id = v_board.id
          AND member.user_id <> v_target.auth_user_id
          AND member.role = 'collaborator'
          AND member.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(member.user_id)
      ) INTO v_has_enabled_collaborator;
      IF v_has_enabled_collaborator THEN
        IF v_action IS DISTINCT FROM 'set_recovery_owner' OR v_successor_id IS NULL
          OR NOT EXISTS (
            SELECT 1
            FROM public.board_memberships AS member
            WHERE member.board_id = v_board.id
              AND member.user_id = v_successor_id
              AND member.user_id <> v_target.auth_user_id
              AND member.role = 'collaborator'
              AND member.revoked_at IS NULL
              AND public.is_enabled_application_identity_p(member.user_id)
          ) THEN
          RETURN pg_catalog.jsonb_build_object('status', 'conflict');
        END IF;
      ELSIF v_action = 'set_recovery_owner' THEN
        IF v_successor_id IS NULL OR v_successor_id = v_target.auth_user_id
          OR NOT public.is_enabled_application_identity_p(v_successor_id) THEN
          RETURN pg_catalog.jsonb_build_object('status', 'conflict');
        END IF;
      ELSIF v_action IS DISTINCT FROM 'leave_recovery_unassigned'
        OR v_successor_id IS NOT NULL THEN
        RETURN pg_catalog.jsonb_build_object('status', 'conflict');
      END IF;
      UPDATE public.board_recoverable_deletions AS recovery
      SET recovery_owner_id = CASE
        WHEN v_action = 'set_recovery_owner' THEN v_successor_id
        ELSE NULL
      END
      WHERE recovery.board_id = v_board.id;
    END IF;
  END LOOP;

  INSERT INTO public.account_suspension_write_contexts(
    transaction_id, actor_id, target_id, board_ids
  ) VALUES (
    txid_current(), auth.uid(), v_target.auth_user_id, v_board_ids
  );
  UPDATE public.tasks AS task
  SET assignee_id = NULL,
      assignee_version = task.assignee_version + 1
  FROM public.columns AS column_row
  JOIN public.boards AS board ON board.id = column_row.board_id
  WHERE task.column_id = column_row.id
    AND board.id = ANY(v_board_ids)
    AND column_row.generation_id = board.active_generation_id
    AND task.assignee_id = v_target.auth_user_id
    AND NOT task.is_completed;
  DELETE FROM public.account_suspension_write_contexts AS context
  WHERE context.transaction_id = txid_current()
    AND context.actor_id = auth.uid()
    AND context.target_id = v_target.auth_user_id;

  UPDATE public.board_invitations AS invitation
  SET status = 'revoked'
  WHERE invitation.status = 'pending'
    AND (invitation.inviter_id = v_target.auth_user_id
      OR invitation.recipient_id = v_target.auth_user_id);

  UPDATE public.board_memberships AS member
  SET revoked_at = v_suspended_at
  WHERE member.user_id = v_target.auth_user_id
    AND member.revoked_at IS NULL
    AND member.board_id = ANY(v_board_ids);

  UPDATE public.application_access AS access
  SET state = 'suspended', updated_at = v_suspended_at
  WHERE access.auth_user_id = v_target.auth_user_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'transferred_boards', v_transferred_count,
    'recoverable_boards', v_recoverable_count
  );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_suspend_access_with_successions_p(text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_suspend_access_with_successions_p(text, jsonb)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_suspend_access(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_target_id uuid;
  v_target_is_admin boolean;
  v_active_admin_count integer;
  v_result jsonb;
BEGIN
  PERFORM public.require_application_admin();
  LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
  PERFORM public.require_application_admin();
  SELECT access.auth_user_id, access.is_admin
  INTO v_target_id, v_target_is_admin
  FROM public.application_access AS access
  WHERE access.email = pg_catalog.lower(pg_catalog.btrim(p_email))
    AND access.auth_user_id IS NOT NULL
    AND access.state = 'active';
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF v_target_is_admin THEN
    SELECT count(*)::integer INTO v_active_admin_count
    FROM public.application_access AS active_admin
    WHERE active_admin.is_admin AND active_admin.state = 'active';
    IF v_active_admin_count <= 1 THEN
      RAISE EXCEPTION 'At least one active administrator must remain'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.boards AS board
    WHERE board.owner_id = v_target_id
  ) THEN
    RAISE EXCEPTION 'Account owns a board; ownership must be resolved before suspension'
      USING ERRCODE = '55000';
  END IF;
  v_result := public.admin_suspend_access_with_successions_p(p_email, '[]'::jsonb);
  IF v_result->>'status' = 'confirmed' THEN RETURN true; END IF;
  IF v_result->>'status' = 'unavailable' THEN RETURN false; END IF;
  RAISE EXCEPTION 'Account ownership must be resolved before suspension'
    USING ERRCODE = '55000';
END;
$$;
REVOKE ALL ON FUNCTION public.admin_suspend_access(text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_suspend_access(text)
  TO authenticated;

-- Any board insertion must serialize with account suspension before the board
-- row is written. Other write RPCs use this same account row lock before boards.
CREATE OR REPLACE FUNCTION public.guard_board_child_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_old_board_id uuid;
  v_new_board_id uuid;
  v_old_generation_id uuid;
  v_new_generation_id uuid;
  v_active_generation_id uuid;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    IF TG_TABLE_NAME = 'columns' THEN
      v_old_board_id := OLD.board_id;
      v_old_generation_id := OLD.generation_id;
    ELSE
      SELECT column_row.board_id, column_row.generation_id
        INTO v_old_board_id, v_old_generation_id
      FROM public.columns AS column_row WHERE column_row.id = OLD.column_id;
    END IF;
  END IF;
  IF TG_OP <> 'DELETE' THEN
    IF TG_TABLE_NAME = 'columns' THEN
      v_new_board_id := NEW.board_id;
      v_new_generation_id := NEW.generation_id;
    ELSE
      SELECT column_row.board_id, column_row.generation_id
        INTO v_new_board_id, v_new_generation_id
      FROM public.columns AS column_row WHERE column_row.id = NEW.column_id;
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' AND v_old_board_id IS DISTINCT FROM v_new_board_id THEN
    RAISE EXCEPTION 'Content cannot move between boards' USING ERRCODE = '42501';
  END IF;
  IF TG_OP <> 'INSERT' AND v_old_board_id IS NOT NULL THEN
    SELECT board.active_generation_id INTO v_active_generation_id
    FROM public.boards AS board WHERE board.id = v_old_board_id;
    IF NOT FOUND AND TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
      RETURN OLD;
    END IF;
    IF v_active_generation_id IS DISTINCT FROM v_old_generation_id THEN
      RAISE EXCEPTION 'Archived board content cannot be changed' USING ERRCODE = '42501';
    END IF;
  END IF;
  IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1
    AND NOT public.is_board_member(v_old_board_id) THEN
    RETURN OLD;
  END IF;
  IF TG_OP <> 'DELETE' THEN
    SELECT board.active_generation_id INTO v_active_generation_id
    FROM public.boards AS board WHERE board.id = v_new_board_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
    END IF;
    IF TG_TABLE_NAME = 'columns' AND v_new_generation_id IS NULL THEN
      NEW.generation_id := v_active_generation_id;
      v_new_generation_id := v_active_generation_id;
    END IF;
    IF v_new_generation_id IS DISTINCT FROM v_active_generation_id THEN
      RAISE EXCEPTION 'Archived board content cannot be changed' USING ERRCODE = '42501';
    END IF;
  END IF;

  IF TG_TABLE_NAME = 'tasks' AND TG_OP = 'UPDATE' THEN
    IF OLD.assignee_id IS NOT NULL
      AND NEW.assignee_id IS NULL
      AND NEW.assignee_version = OLD.assignee_version + 1
      AND (pg_catalog.to_jsonb(NEW) - 'assignee_id' - 'assignee_version')
        IS NOT DISTINCT FROM
        (pg_catalog.to_jsonb(OLD) - 'assignee_id' - 'assignee_version')
      AND public.is_application_admin()
      AND EXISTS (
        SELECT 1
        FROM public.account_suspension_write_contexts AS context
        WHERE context.transaction_id = txid_current()
          AND context.actor_id = auth.uid()
          AND context.target_id = OLD.assignee_id
          AND v_old_board_id = ANY(context.board_ids)
      ) THEN
      RETURN NEW;
    END IF;
  END IF;
  IF NOT public.is_application_user()
    OR (TG_OP <> 'INSERT' AND NOT public.is_board_member(v_old_board_id))
    OR (TG_OP <> 'DELETE' AND NOT public.is_board_member(v_new_board_id)) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.guard_board_owner()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_locked_actor uuid;
  v_recoverable boolean;
  v_service_role boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT access.auth_user_id INTO v_locked_actor
    FROM public.application_access AS access
    WHERE access.auth_user_id = auth.uid()
    FOR SHARE;
    IF NOT FOUND OR NOT public.is_application_user() THEN
      RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
    END IF;
    IF NEW.owner_id IS NOT NULL AND NEW.owner_id <> auth.uid() THEN
      RAISE EXCEPTION 'A board must belong to its creator' USING ERRCODE = '42501';
    END IF;
    NEW.owner_id := auth.uid();
    NEW.name := btrim(NEW.name);
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_service_role := current_setting('request.jwt.claim.role', true) = 'service_role'
      OR current_user = 'service_role';
    IF v_service_role AND EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS recovery
      WHERE recovery.board_id = OLD.id
        AND recovery.expires_at <= clock_timestamp()
    ) THEN
      RETURN OLD;
    END IF;
    IF NOT public.is_board_owner(OLD.id) THEN
      RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id OR NEW.slug IS DISTINCT FROM OLD.slug THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS recovery
    WHERE recovery.board_id = OLD.id
  ) INTO v_recoverable;
  IF NEW.owner_id IS DISTINCT FROM OLD.owner_id THEN
    IF v_recoverable
      AND public.is_enabled_application_identity_p(NEW.owner_id)
      AND (
        public.is_application_admin()
        OR (
          auth.uid() = NEW.owner_id
          AND EXISTS (
            SELECT 1 FROM public.board_recoverable_deletions AS recovery
            WHERE recovery.board_id = OLD.id
              AND recovery.recovery_owner_id = auth.uid()
          )
        )
      ) THEN
      NULL;
    ELSIF (NOT public.is_board_owner(OLD.id) AND NOT public.is_application_admin())
      OR NOT EXISTS (
        SELECT 1 FROM public.board_memberships AS member
        WHERE member.board_id = OLD.id
          AND member.user_id = NEW.owner_id
          AND member.role = 'collaborator'
          AND member.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(member.user_id)
      ) THEN
      RAISE EXCEPTION 'Choose a current enabled board member as owner'
        USING ERRCODE = '42501';
    END IF;
  ELSIF NOT public.is_board_owner(OLD.id) THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  NEW.name := btrim(NEW.name);
  RETURN NEW;
END;
$$;

-- A board owner’s departure selects another identity. Lock both accounts in ID
-- order before the original leave function reaches its board lock.
ALTER FUNCTION public.leave_board_p(uuid, uuid, uuid)
  RENAME TO leave_board_internal_p;
REVOKE ALL ON FUNCTION public.leave_board_internal_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.leave_board_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_successor_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  PERFORM public.lock_application_access_rows_p(
    ARRAY[v_actor_id, p_successor_user_id], NULL
  );
  IF NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.leave_board_internal_p(
    p_operation_id, p_board_id, p_successor_user_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.leave_board_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.leave_board_p(uuid, uuid, uuid)
  TO authenticated;

-- Assignment writes also lock the assigned identity before the board. This
-- lets suspension clear the current assignment or reject the waiting write.
ALTER FUNCTION public.set_task_assignee_p(uuid, text, uuid, uuid, bigint)
  RENAME TO set_task_assignee_internal_p;
REVOKE ALL ON FUNCTION public.set_task_assignee_internal_p(uuid, text, uuid, uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.set_task_assignee_p(
  p_operation_id uuid,
  p_slug text,
  p_id uuid,
  p_assignee_id uuid,
  p_expected_version bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  PERFORM public.lock_application_access_rows_p(
    ARRAY[v_actor_id, p_assignee_id], NULL
  );
  IF NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Board access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.set_task_assignee_internal_p(
    p_operation_id, p_slug, p_id, p_assignee_id, p_expected_version
  );
END;
$$;
REVOKE ALL ON FUNCTION public.set_task_assignee_p(uuid, text, uuid, uuid, bigint)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_task_assignee_p(uuid, text, uuid, uuid, bigint)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.list_my_recoverable_boards_p()
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  owner_id uuid,
  deleted_at timestamptz,
  expires_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT board.id, board.slug, board.name, board.owner_id,
    recovery.deleted_at, recovery.expires_at
  FROM public.board_recoverable_deletions AS recovery
  JOIN public.boards AS board ON board.id = recovery.board_id
  WHERE public.is_application_user()
    AND recovery.expires_at > statement_timestamp()
    AND (
      recovery.recovery_owner_id = auth.uid()
      OR (
        recovery.cause = 'owner_requested'
        AND board.owner_id = auth.uid()
        AND EXISTS (
          SELECT 1
          FROM public.board_memberships AS membership
          WHERE membership.board_id = board.id
            AND membership.user_id = auth.uid()
            AND membership.role = 'owner'
            AND membership.revoked_at IS NULL
        )
      )
    )
  ORDER BY recovery.deleted_at DESC, board.id;
$$;

DROP FUNCTION public.admin_list_recoverable_boards_p();
CREATE FUNCTION public.admin_list_recoverable_boards_p()
RETURNS TABLE (
  id uuid,
  slug text,
  name text,
  owner_id uuid,
  recovery_owner_id uuid,
  owner_is_valid boolean,
  active_member_count integer,
  cause text,
  deleted_at timestamptz,
  expires_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'Administrator access required' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT board.id,
    board.slug,
    board.name,
    board.owner_id,
    recovery.recovery_owner_id,
    public.is_enabled_application_identity_p(board.owner_id)
      AND EXISTS (
        SELECT 1
        FROM public.board_memberships AS owner_membership
        WHERE owner_membership.board_id = board.id
          AND owner_membership.user_id = board.owner_id
          AND owner_membership.role = 'owner'
          AND owner_membership.revoked_at IS NULL
      ) AS owner_is_valid,
    (
      SELECT count(*)::integer
      FROM public.board_memberships AS membership
      WHERE membership.board_id = board.id
        AND membership.revoked_at IS NULL
    ) AS active_member_count,
    recovery.cause,
    recovery.deleted_at,
    recovery.expires_at
  FROM public.board_recoverable_deletions AS recovery
  JOIN public.boards AS board ON board.id = recovery.board_id
  WHERE recovery.expires_at > statement_timestamp()
  ORDER BY recovery.deleted_at DESC, board.id;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_list_recoverable_boards_p()
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_list_recoverable_boards_p()
  TO authenticated;

ALTER FUNCTION public.create_direct_board_invitation_p(text, text)
  RENAME TO create_direct_board_invitation_unlocked_p;
REVOKE ALL ON FUNCTION public.create_direct_board_invitation_unlocked_p(text, text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.create_direct_board_invitation_p(p_slug text, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_recipient_id uuid;
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  SELECT access.auth_user_id INTO v_recipient_id
  FROM public.application_access AS access
  WHERE access.email = pg_catalog.lower(pg_catalog.btrim(p_email))
    AND access.state = 'active'
    AND access.auth_user_id IS NOT NULL
    AND access.google_subject IS NOT NULL;
  PERFORM public.lock_application_access_rows_p(
    ARRAY[v_actor_id, v_recipient_id], NULL
  );
  IF NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.create_direct_board_invitation_unlocked_p(p_slug, p_email);
END;
$$;
REVOKE ALL ON FUNCTION public.create_direct_board_invitation_p(text, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_direct_board_invitation_p(text, text)
  TO authenticated;

ALTER FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  RENAME TO create_board_invitation_link_unlocked_p;
REVOKE ALL ON FUNCTION public.create_board_invitation_link_unlocked_p(text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.create_board_invitation_link_p(
  p_slug text,
  p_operation_id uuid,
  p_token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  PERFORM public.lock_application_access_rows_p(ARRAY[v_actor_id], NULL);
  IF NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Application access is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.create_board_invitation_link_unlocked_p(
    p_slug, p_operation_id, p_token
  );
END;
$$;
REVOKE ALL ON FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_board_invitation_link_p(text, uuid, text)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.restore_board_internal_p(
  p_operation_id uuid,
  p_board_id uuid,
  p_new_owner_id uuid,
  p_now timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_pre_owner_id uuid;
  v_pre_recovery_owner_id uuid;
  v_pre_expires_at timestamptz;
  v_board public.boards%ROWTYPE;
  v_recovery public.board_recoverable_deletions%ROWTYPE;
  v_receipt public.board_departure_operation_receipts%ROWTYPE;
  v_target_membership_id uuid;
  v_owner_is_valid boolean;
  v_has_enabled_successor boolean;
  v_is_admin boolean;
  v_restored_owner_id uuid;
  v_payload_hash bytea;
  v_response jsonb;
  v_now timestamptz := coalesce(p_now, clock_timestamp());
  v_restored_at timestamptz;
BEGIN
  IF p_operation_id IS NULL OR p_board_id IS NULL THEN
    RAISE EXCEPTION 'Board restoration requires an operation and board'
      USING ERRCODE = '22023';
  END IF;
  v_is_admin := public.is_application_admin();
  IF v_actor_id IS NULL OR (NOT public.is_application_user() AND NOT v_is_admin) THEN
    RAISE EXCEPTION 'Board recovery access is required' USING ERRCODE = '42501';
  END IF;

  SELECT board.owner_id, recovery.recovery_owner_id, recovery.expires_at
  INTO v_pre_owner_id, v_pre_recovery_owner_id, v_pre_expires_at
  FROM public.boards AS board
  LEFT JOIN public.board_recoverable_deletions AS recovery
    ON recovery.board_id = board.id
  WHERE board.id = p_board_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;

  PERFORM access.auth_user_id
  FROM public.application_access AS access
  WHERE access.auth_user_id = ANY (
    ARRAY[v_actor_id, v_pre_owner_id, v_pre_recovery_owner_id, p_new_owner_id]::uuid[]
  )
  ORDER BY access.auth_user_id
  FOR SHARE;
  v_is_admin := public.is_application_admin();
  IF v_actor_id IS NULL OR (NOT public.is_application_user() AND NOT v_is_admin) THEN
    RAISE EXCEPTION 'Board recovery access is required' USING ERRCODE = '42501';
  END IF;

  v_payload_hash := extensions.digest(
    pg_catalog.convert_to(
      pg_catalog.jsonb_build_object(
        'action', 'restore_board',
        'board_id', p_board_id,
        'new_owner_id', p_new_owner_id
      )::text,
      'UTF8'
    ),
    'sha256'
  );
  v_response := public.board_departure_operation_result_p(
    v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash
  );
  IF v_response IS NOT NULL THEN RETURN v_response; END IF;

  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_board.owner_id IS DISTINCT FROM v_pre_owner_id THEN
    RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;

  v_response := public.board_departure_operation_result_p(
    v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash
  );
  IF v_response IS NOT NULL THEN RETURN v_response; END IF;

  SELECT recovery.* INTO v_recovery
  FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = p_board_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable', 'operation_id', p_operation_id);
  END IF;
  IF v_recovery.expires_at IS DISTINCT FROM v_pre_expires_at
    OR v_recovery.recovery_owner_id IS DISTINCT FROM v_pre_recovery_owner_id THEN
    RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
  END IF;
  IF v_recovery.expires_at <= v_now THEN
    RETURN jsonb_build_object('status', 'expired', 'operation_id', p_operation_id);
  END IF;

  SELECT membership.id INTO v_target_membership_id
  FROM public.board_memberships AS membership
  WHERE membership.board_id = p_board_id
    AND membership.user_id = v_board.owner_id
    AND membership.role = 'owner'
    AND membership.revoked_at IS NULL
  FOR UPDATE;
  v_owner_is_valid := FOUND
    AND public.is_enabled_application_identity_p(v_board.owner_id);

  IF v_owner_is_valid THEN
    IF v_actor_id IS DISTINCT FROM v_board.owner_id OR p_new_owner_id IS NOT NULL THEN
      RAISE EXCEPTION 'Only the current enabled owner can restore this board'
        USING ERRCODE = '42501';
    END IF;
    v_restored_owner_id := v_board.owner_id;
  ELSIF v_recovery.recovery_owner_id IS NOT NULL
    AND v_actor_id = v_recovery.recovery_owner_id
    AND public.is_enabled_application_identity_p(v_recovery.recovery_owner_id) THEN
    IF p_new_owner_id IS NOT NULL THEN
      RAISE EXCEPTION 'Only an administrator can choose a different recovery owner'
        USING ERRCODE = '42501';
    END IF;
    v_restored_owner_id := v_recovery.recovery_owner_id;
  ELSE
    IF NOT v_is_admin THEN
      RAISE EXCEPTION 'Administrator access is required to choose a new board owner'
        USING ERRCODE = '42501';
    END IF;
    IF p_new_owner_id IS NULL THEN
      RETURN jsonb_build_object('status', 'owner_required', 'operation_id', p_operation_id);
    END IF;
    IF NOT public.is_enabled_application_identity_p(p_new_owner_id) THEN
      RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM public.board_memberships AS membership
      WHERE membership.board_id = p_board_id
        AND membership.user_id <> v_board.owner_id
        AND membership.role = 'collaborator'
        AND membership.revoked_at IS NULL
        AND public.is_enabled_application_identity_p(membership.user_id)
    ) INTO v_has_enabled_successor;
    IF p_new_owner_id = v_board.owner_id
      OR (v_has_enabled_successor AND NOT EXISTS (
        SELECT 1
        FROM public.board_memberships AS membership
        WHERE membership.board_id = p_board_id
          AND membership.user_id = p_new_owner_id
          AND membership.role = 'collaborator'
          AND membership.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(membership.user_id)
      )) THEN
      RETURN jsonb_build_object('status', 'conflict', 'operation_id', p_operation_id);
    END IF;
    v_restored_owner_id := p_new_owner_id;
  END IF;

  INSERT INTO public.board_departure_operation_receipts (
    actor_id, operation_id, action, board_id, payload_hash, result_status
  ) VALUES (
    v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash, 'pending'
  ) ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  IF NOT FOUND THEN
    v_response := public.board_departure_operation_result_p(
      v_actor_id, p_operation_id, 'restore_board', p_board_id, v_payload_hash
    );
    IF v_response IS NOT NULL THEN RETURN v_response; END IF;
    RAISE EXCEPTION 'The board restoration result could not be reconciled'
      USING ERRCODE = '40001';
  END IF;

  v_restored_at := v_now;
  IF v_restored_owner_id IS DISTINCT FROM v_board.owner_id THEN
    UPDATE public.board_memberships AS membership
    SET revoked_at = v_restored_at
    WHERE membership.board_id = p_board_id
      AND membership.role = 'owner'
      AND membership.revoked_at IS NULL;

    SELECT membership.id INTO v_target_membership_id
    FROM public.board_memberships AS membership
    WHERE membership.board_id = p_board_id
      AND membership.user_id = v_restored_owner_id
      AND membership.revoked_at IS NULL
    FOR UPDATE;
    IF FOUND THEN
      UPDATE public.board_memberships AS membership
      SET role = 'owner'
      WHERE membership.id = v_target_membership_id;
    ELSE
      INSERT INTO public.board_memberships (board_id, user_id, role)
      VALUES (p_board_id, v_restored_owner_id, 'owner');
    END IF;
    UPDATE public.boards AS board
    SET owner_id = v_restored_owner_id,
        updated_at = v_restored_at
    WHERE board.id = p_board_id;
  END IF;

  DELETE FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = p_board_id;
  UPDATE public.board_departure_operation_receipts AS receipt
  SET result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;
  RETURN jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'owner_id', v_restored_owner_id,
    'expires_at', v_recovery.expires_at
  );
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
