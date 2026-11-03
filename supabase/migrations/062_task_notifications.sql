-- In-app notices are durable, private work items. Their producers run in the
-- same transaction as the user mutation; delivery is separate and retryable.
BEGIN;

CREATE TABLE public.task_notifications (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  generation_id uuid NOT NULL,
  task_id uuid NOT NULL,
  comment_id uuid,
  source_kind text NOT NULL CHECK (source_kind IN ('task_change', 'comment')),
  source_id uuid NOT NULL,
  recipient_user_id uuid NOT NULL,
  recipient_membership_id uuid NOT NULL,
  reason_codes text[] NOT NULL CHECK (
    cardinality(reason_codes) > 0
    AND reason_codes <@ ARRAY['assignment', 'mention', 'comment', 'due_date']::text[]
  ),
  actor_name text NOT NULL CHECK (pg_catalog.btrim(actor_name) <> ''),
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'retry_wait', 'delivered', 'skipped')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  available_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  delivered_at timestamptz,
  read_at timestamptz,
  last_error_code text,
  CONSTRAINT task_notification_source_shape CHECK (
    (source_kind = 'task_change' AND comment_id IS NULL)
    OR (source_kind = 'comment' AND comment_id = source_id)
  ),
  CONSTRAINT task_notification_delivery_shape CHECK (
    (state = 'delivered') = (delivered_at IS NOT NULL)
  ),
  CONSTRAINT task_notification_read_after_delivery CHECK (
    read_at IS NULL OR (state = 'delivered' AND read_at >= delivered_at)
  ),
  CONSTRAINT task_notification_source_recipient_unique
    UNIQUE (source_kind, source_id, recipient_membership_id)
);
CREATE INDEX task_notifications_recipient_recent_idx
  ON public.task_notifications(recipient_user_id, occurred_at DESC, id DESC)
  WHERE state = 'delivered';
CREATE INDEX task_notifications_pending_idx
  ON public.task_notifications(available_at, occurred_at, id)
  WHERE state IN ('pending', 'retry_wait');
CREATE INDEX task_notifications_task_idx
  ON public.task_notifications(task_id, occurred_at DESC);

-- This small ledger carries no message, title, or actor text. It keeps a
-- comment/member-episode pair from notifying again after a mention is removed
-- and re-added, even when its 90-day inbox row has expired.
CREATE TABLE public.task_notification_comment_recipients (
  comment_id uuid NOT NULL REFERENCES public.task_comments(id) ON DELETE CASCADE,
  recipient_membership_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (comment_id, recipient_membership_id)
);

ALTER TABLE public.task_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.task_notification_comment_recipients ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_notifications,
  public.task_notification_comment_recipients
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.enqueue_task_notification_internal_p(
  p_board_id uuid,
  p_generation_id uuid,
  p_task_id uuid,
  p_comment_id uuid,
  p_source_kind text,
  p_source_id uuid,
  p_recipient_user_id uuid,
  p_reason_code text,
  p_actor_name text,
  p_occurred_at timestamptz
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_membership_id uuid;
  v_notice_id uuid;
BEGIN
  IF p_board_id IS NULL OR p_generation_id IS NULL OR p_task_id IS NULL
    OR p_source_id IS NULL OR p_recipient_user_id IS NULL
    OR p_source_kind NOT IN ('task_change', 'comment')
    OR p_reason_code NOT IN ('assignment', 'mention', 'comment', 'due_date')
    OR pg_catalog.btrim(coalesce(p_actor_name, '')) = '' THEN
    RETURN NULL;
  END IF;
  IF (p_source_kind = 'comment') <> (p_comment_id IS NOT NULL)
    OR (p_source_kind = 'comment' AND p_comment_id IS DISTINCT FROM p_source_id) THEN
    RETURN NULL;
  END IF;

  SELECT membership.id INTO v_membership_id
  FROM public.board_memberships AS membership
  JOIN public.boards AS board
    ON board.id = membership.board_id
    AND board.active_generation_id = p_generation_id
  WHERE membership.board_id = p_board_id
    AND membership.user_id = p_recipient_user_id
    AND membership.revoked_at IS NULL
    AND public.is_enabled_application_identity_p(membership.user_id)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = p_task_id AND deletion.state IN ('deleted', 'purged')
    );
  IF NOT FOUND THEN RETURN NULL; END IF;

  INSERT INTO public.task_notifications(
    board_id, generation_id, task_id, comment_id, source_kind, source_id,
    recipient_user_id, recipient_membership_id, reason_codes, actor_name, occurred_at
  ) VALUES (
    p_board_id, p_generation_id, p_task_id, p_comment_id, p_source_kind, p_source_id,
    p_recipient_user_id, v_membership_id, ARRAY[p_reason_code], p_actor_name,
    coalesce(p_occurred_at, pg_catalog.clock_timestamp())
  )
  ON CONFLICT (source_kind, source_id, recipient_membership_id) DO UPDATE
  SET reason_codes = ARRAY(
        SELECT DISTINCT reason
        FROM pg_catalog.unnest(
          public.task_notifications.reason_codes || EXCLUDED.reason_codes
        ) AS reason
        ORDER BY reason
      )
  RETURNING id INTO v_notice_id;
  RETURN v_notice_id;
END;
$$;
REVOKE ALL ON FUNCTION public.enqueue_task_notification_internal_p(
  uuid, uuid, uuid, uuid, text, uuid, uuid, text, text, timestamptz
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.enqueue_comment_task_notification_internal_p(
  p_comment_id uuid,
  p_recipient_user_id uuid,
  p_reason_code text,
  p_occurred_at timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_comment public.task_comments%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_board_id uuid;
  v_generation_id uuid;
  v_membership_id uuid;
  v_notice_id uuid;
  v_now timestamptz := pg_catalog.clock_timestamp();
BEGIN
  SELECT comment_row.* INTO v_comment
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = p_comment_id AND comment_row.deleted_at IS NULL;
  IF NOT FOUND OR p_recipient_user_id IS NULL
    OR p_recipient_user_id = v_comment.author_id THEN
    RETURN;
  END IF;

  SELECT task.* INTO v_task
  FROM public.tasks AS task
  WHERE task.id = v_comment.task_id;
  IF NOT FOUND OR v_task.id IS NULL THEN RETURN; END IF;

  SELECT board.id, board.active_generation_id, membership.id
  INTO v_board_id, v_generation_id, v_membership_id
  FROM public.boards AS board
  JOIN public.columns AS column_row
    ON column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = p_recipient_user_id
    AND membership.revoked_at IS NULL
  WHERE board.id = v_comment.board_id
    AND v_task.column_id = column_row.id
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = v_task.id AND deletion.state IN ('deleted', 'purged')
    )
    AND public.is_enabled_application_identity_p(membership.user_id);
  IF NOT FOUND THEN RETURN; END IF;

  INSERT INTO public.task_notification_comment_recipients(
    comment_id, recipient_membership_id
  ) VALUES (v_comment.id, v_membership_id)
  ON CONFLICT DO NOTHING;
  IF FOUND THEN
    v_notice_id := public.enqueue_task_notification_internal_p(
      v_board_id, v_generation_id, v_task.id, v_comment.id,
      'comment', v_comment.id, p_recipient_user_id, p_reason_code,
      v_comment.author_name, coalesce(p_occurred_at, v_now)
    );
  ELSE
    -- If the original notice is still in retention, merge its reason without
    -- resetting delivery/read state. An expired notice is never recreated.
    UPDATE public.task_notifications AS notice
    SET reason_codes = ARRAY(
      SELECT DISTINCT reason
      FROM pg_catalog.unnest(notice.reason_codes || ARRAY[p_reason_code]) AS reason
      ORDER BY reason
    )
    WHERE notice.source_kind = 'comment'
      AND notice.source_id = v_comment.id
      AND notice.recipient_membership_id = v_membership_id
      AND notice.occurred_at > v_now - interval '90 days';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.enqueue_comment_task_notification_internal_p(
  uuid, uuid, text, timestamptz
)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.capture_task_notification_update_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
  v_generation_id uuid;
  v_actor_id uuid := auth.uid();
  v_actor_name text;
  v_source_id uuid := pg_catalog.gen_random_uuid();
BEGIN
  IF OLD.assignee_id IS NOT DISTINCT FROM NEW.assignee_id
    AND OLD.due_on IS NOT DISTINCT FROM NEW.due_on THEN
    RETURN NEW;
  END IF;
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN RETURN NEW; END IF;

  SELECT board.id, board.active_generation_id INTO v_board_id, v_generation_id
  FROM public.boards AS board
  JOIN public.columns AS column_row
    ON column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  WHERE column_row.id = NEW.column_id
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = NEW.id AND deletion.state IN ('deleted', 'purged')
    );
  IF NOT FOUND THEN RETURN NEW; END IF;

  SELECT member.name INTO v_actor_name
  FROM public.list_assignable_board_members_p(
    (SELECT board.slug FROM public.boards AS board WHERE board.id = v_board_id)
  ) AS member
  WHERE member.user_id = v_actor_id;
  IF v_actor_name IS NULL THEN v_actor_name := 'Miembro del tablero'; END IF;

  IF OLD.assignee_id IS DISTINCT FROM NEW.assignee_id
    AND NEW.assignee_id IS NOT NULL
    AND NEW.assignee_id <> v_actor_id THEN
    PERFORM public.enqueue_task_notification_internal_p(
      v_board_id, v_generation_id, NEW.id, NULL,
      'task_change', v_source_id, NEW.assignee_id, 'assignment', v_actor_name,
      pg_catalog.clock_timestamp()
    );
  END IF;

  IF OLD.due_on IS DISTINCT FROM NEW.due_on
    AND NEW.assignee_id IS NOT NULL
    AND NEW.assignee_id <> v_actor_id THEN
    PERFORM public.enqueue_task_notification_internal_p(
      v_board_id, v_generation_id, NEW.id, NULL,
      'task_change', v_source_id, NEW.assignee_id, 'due_date', v_actor_name,
      pg_catalog.clock_timestamp()
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_task_notification_update_tg()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER tasks_capture_notifications
  AFTER UPDATE OF assignee_id, due_on ON public.tasks
  FOR EACH ROW EXECUTE FUNCTION public.capture_task_notification_update_tg();

CREATE FUNCTION public.capture_task_comment_notification_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_task public.tasks%ROWTYPE;
  v_series_creator uuid;
  v_creator_id uuid;
  v_recipient uuid;
BEGIN
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  WHERE task.id = NEW.task_id;
  IF NOT FOUND OR NEW.deleted_at IS NOT NULL THEN RETURN NEW; END IF;

  SELECT series.created_by INTO v_series_creator
  FROM public.daily_repetition_occurrences AS occurrence
  JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
  WHERE occurrence.task_id = NEW.task_id
    AND occurrence.state IN ('current', 'replaced', 'excluded')
  ORDER BY (occurrence.state = 'current') DESC, occurrence.created_at DESC, occurrence.id DESC
  LIMIT 1;
  v_creator_id := coalesce(v_series_creator, v_task.created_by);

  FOR v_recipient IN
    SELECT DISTINCT recipient.user_id
    FROM (VALUES (v_task.assignee_id), (v_creator_id)) AS recipient(user_id)
    WHERE recipient.user_id IS NOT NULL
      AND recipient.user_id <> NEW.author_id
  LOOP
    PERFORM public.enqueue_comment_task_notification_internal_p(
      NEW.id, v_recipient, 'comment', NEW.created_at
    );
  END LOOP;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_task_comment_notification_tg()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER task_comments_capture_notifications
  AFTER INSERT ON public.task_comments
  FOR EACH ROW EXECUTE FUNCTION public.capture_task_comment_notification_tg();

CREATE FUNCTION public.capture_task_comment_mention_notification_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_author_id uuid;
BEGIN
  IF NEW.membership_id IS NULL THEN RETURN NEW; END IF;
  SELECT membership.user_id INTO v_user_id
  FROM public.board_memberships AS membership
  WHERE membership.id = NEW.membership_id AND membership.revoked_at IS NULL;
  SELECT comment_row.author_id INTO v_author_id
  FROM public.task_comments AS comment_row
  WHERE comment_row.id = NEW.comment_id AND comment_row.deleted_at IS NULL;
  IF v_user_id IS NOT NULL AND v_user_id IS DISTINCT FROM v_author_id THEN
    PERFORM public.enqueue_comment_task_notification_internal_p(
      NEW.comment_id, v_user_id, 'mention', NEW.created_at
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.capture_task_comment_mention_notification_tg()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER task_comment_mentions_capture_notifications
  AFTER INSERT ON public.task_comment_mentions
  FOR EACH ROW EXECUTE FUNCTION public.capture_task_comment_mention_notification_tg();

CREATE FUNCTION public.process_task_notification_jobs_internal_p(
  p_limit integer,
  p_now timestamptz,
  p_recipient_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_notice public.task_notifications%ROWTYPE;
  v_processed integer := 0;
  v_skipped integer := 0;
  v_retry integer := 0;
  v_sqlstate text;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500
    OR p_now IS NULL THEN
    RAISE EXCEPTION 'Elige un lote de novedades válido' USING ERRCODE = '22023';
  END IF;

  FOR v_notice IN
    SELECT notice.*
    FROM public.task_notifications AS notice
    WHERE notice.state IN ('pending', 'retry_wait')
      AND notice.available_at <= p_now
      AND notice.occurred_at > p_now - interval '90 days'
      AND (p_recipient_user_id IS NULL
        OR notice.recipient_user_id = p_recipient_user_id)
    ORDER BY notice.available_at, notice.occurred_at, notice.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM public.board_memberships AS membership
        JOIN public.boards AS board
          ON board.id = membership.board_id
          AND board.active_generation_id = v_notice.generation_id
        WHERE membership.id = v_notice.recipient_membership_id
          AND membership.board_id = v_notice.board_id
          AND membership.user_id = v_notice.recipient_user_id
          AND membership.revoked_at IS NULL
          AND public.is_enabled_application_identity_p(membership.user_id)
          AND NOT EXISTS (
            SELECT 1 FROM public.board_recoverable_deletions AS deletion
            WHERE deletion.board_id = board.id
          )
      ) THEN
        UPDATE public.task_notifications AS notice
        SET state = 'delivered',
            delivered_at = coalesce(notice.delivered_at, p_now),
            attempt_count = notice.attempt_count + 1,
            last_error_code = NULL
        WHERE notice.id = v_notice.id;
        v_processed := v_processed + 1;
      ELSE
        UPDATE public.task_notifications AS notice
        SET state = 'skipped',
            delivered_at = NULL,
            attempt_count = notice.attempt_count + 1,
            last_error_code = NULL
        WHERE notice.id = v_notice.id;
        v_skipped := v_skipped + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      UPDATE public.task_notifications AS notice
      SET state = 'retry_wait',
          attempt_count = notice.attempt_count + 1,
          available_at = p_now + pg_catalog.make_interval(secs =>
            LEAST(3600::numeric, 30 * pg_catalog.power(2::numeric,
              LEAST(notice.attempt_count, 7)))::double precision
          ),
          last_error_code = v_sqlstate
      WHERE notice.id = v_notice.id;
      v_retry := v_retry + 1;
    END;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'processed', 'delivered', v_processed,
    'skipped', v_skipped, 'retry_wait', v_retry
  );
END;
$$;
REVOKE ALL ON FUNCTION public.process_task_notification_jobs_internal_p(integer, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.process_task_notification_jobs_p(p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  RETURN public.process_task_notification_jobs_internal_p(
    p_limit, pg_catalog.clock_timestamp(), NULL
  );
END;
$$;
REVOKE ALL ON FUNCTION public.process_task_notification_jobs_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_task_notification_jobs_p(integer) TO service_role;

CREATE FUNCTION public.list_my_task_notifications_p(
  p_filter text DEFAULT 'all',
  p_limit integer DEFAULT 30,
  p_before_occurred_at timestamptz DEFAULT NULL,
  p_before_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_items jsonb;
  v_count integer;
  v_has_more boolean;
  v_unread_count integer;
  v_next_cursor jsonb := NULL;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF p_filter IS NULL OR p_filter NOT IN ('all', 'unread')
    OR p_limit IS NULL OR p_limit < 1 OR p_limit > 100
    OR ((p_before_occurred_at IS NULL) <> (p_before_id IS NULL)) THEN
    RAISE EXCEPTION 'Elige una página de novedades válida' USING ERRCODE = '22023';
  END IF;

  -- A separate, repeatable pass drains this caller's durable queue. A failed
  -- transaction leaves work pending for this request or the service worker.
  PERFORM public.process_task_notification_jobs_internal_p(
    100, pg_catalog.clock_timestamp(), auth.uid()
  );

  SELECT count(*)::integer INTO v_unread_count
  FROM public.task_notifications AS notice
  JOIN public.board_memberships AS recipient
    ON recipient.id = notice.recipient_membership_id
    AND recipient.board_id = notice.board_id
    AND recipient.user_id = auth.uid()
    AND recipient.revoked_at IS NULL
  JOIN public.boards AS board
    ON board.id = notice.board_id
    AND board.active_generation_id = notice.generation_id
  WHERE notice.recipient_user_id = auth.uid()
    AND notice.state = 'delivered' AND notice.read_at IS NULL
    AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND public.is_enabled_application_identity_p(auth.uid())
    AND public.is_board_member(board.id);

  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', page.id,
    'occurred_at', page.occurred_at,
    'actor_name', page.actor_name,
    'reason_codes', page.reason_codes,
    'task_title', CASE WHEN page.target_available THEN page.task_title ELSE NULL END,
    'unavailable', NOT page.target_available,
    'read_at', page.read_at
  ) ORDER BY page.occurred_at DESC, page.id DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT notice.id, notice.occurred_at, notice.actor_name,
      notice.reason_codes, notice.read_at,
      task.title AS task_title,
      task.id IS NOT NULL AND column_row.id IS NOT NULL
        AND (notice.comment_id IS NULL OR comment_row.id IS NOT NULL)
        AS target_available
    FROM public.task_notifications AS notice
    JOIN public.board_memberships AS recipient
      ON recipient.id = notice.recipient_membership_id
      AND recipient.board_id = notice.board_id
      AND recipient.user_id = auth.uid()
      AND recipient.revoked_at IS NULL
    JOIN public.boards AS board
      ON board.id = notice.board_id
      AND board.active_generation_id = notice.generation_id
    LEFT JOIN public.tasks AS task
      ON task.id = notice.task_id
    LEFT JOIN public.columns AS column_row
      ON column_row.id = task.column_id
      AND column_row.board_id = board.id
      AND column_row.generation_id = board.active_generation_id
    LEFT JOIN public.task_comments AS comment_row
      ON comment_row.id = notice.comment_id
      AND comment_row.task_id = notice.task_id
      AND comment_row.deleted_at IS NULL
    WHERE notice.recipient_user_id = auth.uid()
      AND notice.state = 'delivered'
      AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
      AND (p_filter = 'all' OR notice.read_at IS NULL)
      AND (p_before_occurred_at IS NULL
        OR (notice.occurred_at, notice.id) < (p_before_occurred_at, p_before_id))
      AND NOT EXISTS (
        SELECT 1 FROM public.board_recoverable_deletions AS deletion
        WHERE deletion.board_id = board.id
      )
      AND public.is_enabled_application_identity_p(auth.uid())
      AND public.is_board_member(board.id)
    ORDER BY notice.occurred_at DESC, notice.id DESC
    LIMIT p_limit + 1
  ) AS page;

  v_count := pg_catalog.jsonb_array_length(v_items);
  v_has_more := v_count > p_limit;
  IF v_has_more THEN
    v_items := v_items - p_limit;
    v_next_cursor := pg_catalog.jsonb_build_object(
      'occurred_at', v_items->(p_limit - 1)->>'occurred_at',
      'id', v_items->(p_limit - 1)->>'id'
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available', 'items', v_items,
    'unread_count', coalesce(v_unread_count, 0),
    'has_more', v_has_more, 'next_cursor', v_next_cursor,
    'retention_days', 90
  );
END;
$$;
REVOKE ALL ON FUNCTION public.list_my_task_notifications_p(text, integer, timestamptz, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_my_task_notifications_p(text, integer, timestamptz, uuid)
  TO authenticated;

CREATE FUNCTION public.get_my_task_notification_target_p(p_notification_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_target record;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_notification_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT board.slug, task.id AS task_id, notice.comment_id,
    comment_row.id AS visible_comment_id
  INTO v_target
  FROM public.task_notifications AS notice
  JOIN public.board_memberships AS recipient
    ON recipient.id = notice.recipient_membership_id
    AND recipient.board_id = notice.board_id
    AND recipient.user_id = auth.uid()
    AND recipient.revoked_at IS NULL
  JOIN public.boards AS board
    ON board.id = notice.board_id
    AND board.active_generation_id = notice.generation_id
  JOIN public.columns AS column_row
    ON column_row.board_id = board.id
    AND column_row.generation_id = board.active_generation_id
  JOIN public.tasks AS task
    ON task.id = notice.task_id AND task.column_id = column_row.id
  LEFT JOIN public.task_comments AS comment_row
    ON comment_row.id = notice.comment_id
    AND comment_row.task_id = notice.task_id
    AND comment_row.deleted_at IS NULL
  WHERE notice.id = p_notification_id
    AND notice.recipient_user_id = auth.uid()
    AND notice.state = 'delivered'
    AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
    AND (notice.comment_id IS NULL OR comment_row.id IS NOT NULL)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = notice.task_id AND deletion.state IN ('deleted', 'purged')
    )
    AND public.is_enabled_application_identity_p(auth.uid())
    AND public.is_board_member(board.id);
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'available', 'slug', v_target.slug,
    'task_id', v_target.task_id, 'comment_id', v_target.comment_id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_task_notification_target_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_task_notification_target_p(uuid) TO authenticated;

CREATE FUNCTION public.mark_my_task_notification_read_p(p_notification_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_board_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_application_user()
    OR p_notification_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT notice.board_id INTO v_board_id
  FROM public.task_notifications AS notice
  JOIN public.board_memberships AS recipient
    ON recipient.id = notice.recipient_membership_id
    AND recipient.board_id = notice.board_id
    AND recipient.user_id = auth.uid()
    AND recipient.revoked_at IS NULL
  JOIN public.boards AS board
    ON board.id = notice.board_id
    AND board.active_generation_id = notice.generation_id
  WHERE notice.id = p_notification_id
    AND notice.recipient_user_id = auth.uid()
    AND notice.state = 'delivered'
    AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
    AND public.is_enabled_application_identity_p(auth.uid())
    AND public.is_board_member(board.id)
  FOR UPDATE OF notice, recipient, board;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  UPDATE public.task_notifications AS notice
  SET read_at = coalesce(notice.read_at, pg_catalog.clock_timestamp())
  WHERE notice.id = p_notification_id;

  RETURN pg_catalog.jsonb_build_object('status', 'confirmed');
END;
$$;
REVOKE ALL ON FUNCTION public.mark_my_task_notification_read_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_my_task_notification_read_p(uuid) TO authenticated;

CREATE FUNCTION public.purge_expired_task_notifications_p(
  p_limit integer DEFAULT 500,
  p_now timestamptz DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_now timestamptz := coalesce(p_now, pg_catalog.clock_timestamp());
  v_deleted integer;
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
    AND current_user IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role is required' USING ERRCODE = '42501';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 5000 THEN
    RAISE EXCEPTION 'Elige un lote de purga válido' USING ERRCODE = '22023';
  END IF;

  WITH expired AS (
    SELECT notice.id
    FROM public.task_notifications AS notice
    WHERE notice.occurred_at <= v_now - interval '90 days'
    ORDER BY notice.occurred_at, notice.id
    LIMIT p_limit
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM public.task_notifications AS notice
  USING expired
  WHERE notice.id = expired.id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_expired_task_notifications_p(integer, timestamptz)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.purge_expired_task_notifications_p(integer, timestamptz)
  TO service_role;

CREATE FUNCTION public.purge_task_notifications_on_task_purge_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.state = 'purged' AND OLD.state IS DISTINCT FROM 'purged' THEN
    DELETE FROM public.task_notifications AS notice
    WHERE notice.task_id = NEW.task_id;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.purge_task_notifications_on_task_purge_tg()
  FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER task_deletions_purge_notifications
  AFTER UPDATE OF state ON public.task_deletions
  FOR EACH ROW EXECUTE FUNCTION public.purge_task_notifications_on_task_purge_tg();

NOTIFY pgrst, 'reload schema';
COMMIT;
