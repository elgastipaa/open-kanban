-- A click on the notification inbox is an exact, actor-scoped ID batch. The
-- receipt keeps only IDs and per-ID outcomes (never notification content) so
-- the client can reconcile a lost response and retry only failed IDs.
BEGIN;

CREATE TABLE public.task_notification_batch_receipts (
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  payload_hash bytea NOT NULL CHECK (octet_length(payload_hash) = 32),
  notification_ids uuid[] NOT NULL CHECK (
    cardinality(notification_ids) BETWEEN 1 AND 100
    AND array_position(notification_ids, NULL) IS NULL
  ),
  item_results jsonb NOT NULL DEFAULT '[]'::jsonb
    CHECK (jsonb_typeof(item_results) = 'array'),
  result_status text NOT NULL DEFAULT 'pending'
    CHECK (result_status IN ('pending', 'confirmed')),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  result_expires_at timestamptz NOT NULL
    DEFAULT (pg_catalog.clock_timestamp() + interval '7 days'),
  PRIMARY KEY (actor_id, operation_id)
);

ALTER TABLE public.task_notification_batch_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.task_notification_batch_receipts
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.mark_my_task_notifications_batch_p(
  p_operation_id uuid,
  p_notification_ids uuid[],
  p_retry_failed boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_notification_ids uuid[];
  v_payload_hash bytea;
  v_receipt public.task_notification_batch_receipts%ROWTYPE;
  v_is_new boolean;
  v_notification_id uuid;
  v_previous jsonb;
  v_result text;
  v_read_at timestamptz;
  v_items jsonb := '[]'::jsonb;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR NOT public.is_enabled_application_identity_p(v_actor_id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF p_operation_id IS NULL OR p_notification_ids IS NULL
    OR cardinality(p_notification_ids) < 1 OR cardinality(p_notification_ids) > 100
    OR array_position(p_notification_ids, NULL) IS NOT NULL
    OR p_retry_failed IS NULL
    OR EXISTS (
      SELECT requested.notification_id
      FROM pg_catalog.unnest(p_notification_ids) AS requested(notification_id)
      GROUP BY requested.notification_id HAVING count(*) > 1
    ) THEN
    RAISE EXCEPTION 'Elige un lote de novedades válido' USING ERRCODE = '22023';
  END IF;

  SELECT pg_catalog.array_agg(requested.notification_id ORDER BY requested.notification_id)
  INTO v_notification_ids
  FROM pg_catalog.unnest(p_notification_ids) AS requested(notification_id);
  v_payload_hash := public.task_capture_payload_hash(pg_catalog.jsonb_build_object(
    'action', 'mark_task_notifications_read',
    'notification_ids', pg_catalog.to_jsonb(v_notification_ids)
  ));

  INSERT INTO public.task_notification_batch_receipts(
    actor_id, operation_id, payload_hash, notification_ids
  ) VALUES (
    v_actor_id, p_operation_id, v_payload_hash, v_notification_ids
  )
  ON CONFLICT (actor_id, operation_id) DO NOTHING
  RETURNING * INTO v_receipt;
  v_is_new := FOUND;

  IF v_is_new AND p_retry_failed THEN
    DELETE FROM public.task_notification_batch_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object(
      'status', 'not_found', 'operation_id', p_operation_id
    );
  END IF;

  IF NOT v_is_new THEN
    SELECT receipt.* INTO v_receipt
    FROM public.task_notification_batch_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'processing', 'operation_id', p_operation_id
      );
    END IF;
    IF v_receipt.payload_hash IS DISTINCT FROM v_payload_hash THEN
      RAISE EXCEPTION 'Esta operación de novedades ya se usó con otros elementos'
        USING ERRCODE = '23514';
    END IF;
    IF v_receipt.result_expires_at <= pg_catalog.clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'expired_unknown', 'operation_id', p_operation_id
      );
    END IF;
    IF v_receipt.result_status = 'pending' THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'processing', 'operation_id', p_operation_id
      );
    END IF;
    IF NOT p_retry_failed OR NOT EXISTS (
      SELECT 1
      FROM pg_catalog.jsonb_array_elements(v_receipt.item_results) AS item
      WHERE item->>'result' = 'failed'
    ) THEN
      RETURN pg_catalog.jsonb_build_object(
        'status', 'confirmed',
        'operation_id', p_operation_id,
        'items', v_receipt.item_results
      );
    END IF;
  END IF;

  FOREACH v_notification_id IN ARRAY v_notification_ids LOOP
    IF NOT v_is_new THEN
      SELECT item INTO v_previous
      FROM pg_catalog.jsonb_array_elements(v_receipt.item_results) AS item
      WHERE item->>'id' = v_notification_id::text;
      IF v_previous->>'result' IS DISTINCT FROM 'failed' THEN
        v_items := v_items || pg_catalog.jsonb_build_array(v_previous);
        CONTINUE;
      END IF;
    END IF;

    v_result := 'unavailable';
    BEGIN
      SELECT notice.read_at INTO v_read_at
      FROM public.task_notifications AS notice
      JOIN public.board_memberships AS recipient
        ON recipient.id = notice.recipient_membership_id
        AND recipient.board_id = notice.board_id
        AND recipient.user_id = v_actor_id
        AND recipient.revoked_at IS NULL
      JOIN public.boards AS board
        ON board.id = notice.board_id
        AND board.active_generation_id = notice.generation_id
      WHERE notice.id = v_notification_id
        AND notice.recipient_user_id = v_actor_id
        AND notice.state = 'delivered'
        AND notice.occurred_at > pg_catalog.clock_timestamp() - interval '90 days'
        AND NOT EXISTS (
          SELECT 1 FROM public.board_recoverable_deletions AS deletion
          WHERE deletion.board_id = board.id
        )
        AND public.is_enabled_application_identity_p(v_actor_id)
        AND public.is_board_member(board.id)
      FOR UPDATE OF notice, recipient, board;

      IF FOUND THEN
        IF v_read_at IS NOT NULL THEN
          v_result := 'already_read';
        ELSE
          UPDATE public.task_notifications AS notice
          SET read_at = pg_catalog.clock_timestamp()
          WHERE notice.id = v_notification_id AND notice.read_at IS NULL;
          IF FOUND THEN
            v_result := 'marked';
          ELSE
            v_result := 'already_read';
          END IF;
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- A single row failure must not roll back successful results for the
      -- rest of the frozen batch. Keep the database error private.
      v_result := 'failed';
    END;

    v_items := v_items || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('id', v_notification_id, 'result', v_result)
    );
  END LOOP;

  UPDATE public.task_notification_batch_receipts AS receipt
  SET item_results = v_items, result_status = 'confirmed'
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'items', v_items
  );
END;
$$;
REVOKE ALL ON FUNCTION public.mark_my_task_notifications_batch_p(uuid, uuid[], boolean)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_my_task_notifications_batch_p(uuid, uuid[], boolean)
  TO authenticated;

CREATE FUNCTION public.get_my_task_notification_batch_p(p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_receipt public.task_notification_batch_receipts%ROWTYPE;
  v_actor_id uuid := auth.uid();
BEGIN
  IF v_actor_id IS NULL OR p_operation_id IS NULL
    OR NOT public.is_application_user()
    OR NOT public.is_enabled_application_identity_p(v_actor_id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT receipt.* INTO v_receipt
  FROM public.task_notification_batch_receipts AS receipt
  WHERE receipt.actor_id = v_actor_id
    AND receipt.operation_id = p_operation_id;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'not_found', 'operation_id', p_operation_id
    );
  END IF;
  IF v_receipt.result_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'expired_unknown', 'operation_id', p_operation_id
    );
  END IF;
  IF v_receipt.result_status <> 'confirmed' THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'processing', 'operation_id', p_operation_id
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'status', 'confirmed',
    'operation_id', p_operation_id,
    'items', v_receipt.item_results
  );
END;
$$;
REVOKE ALL ON FUNCTION public.get_my_task_notification_batch_p(uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_my_task_notification_batch_p(uuid)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
