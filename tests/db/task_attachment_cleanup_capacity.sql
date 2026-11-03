\set ON_ERROR_STOP on
\echo 'Testing owner cleanup of attachments from completed tasks'

INSERT INTO public.application_access (email, state, is_admin) VALUES
  ('issue41-owner@example.test', 'pending', false),
  ('issue41-member@example.test', 'pending', false),
  ('issue41-admin@example.test', 'pending', true),
  ('issue41-outsider@example.test', 'pending', false);

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('74100000-0000-4000-8000-000000000001', 'issue41-owner@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('74100000-0000-4000-8000-000000000002', 'issue41-member@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('74100000-0000-4000-8000-000000000003', 'issue41-admin@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('74100000-0000-4000-8000-000000000004', 'issue41-outsider@example.test', clock_timestamp(), '{"provider":"google"}');

INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('75100000-0000-4000-8000-000000000001', '74100000-0000-4000-8000-000000000001', 'google', 'issue41-owner', '{"email":"issue41-owner@example.test","email_verified":true}'),
  ('75100000-0000-4000-8000-000000000002', '74100000-0000-4000-8000-000000000002', 'google', 'issue41-member', '{"email":"issue41-member@example.test","email_verified":true}'),
  ('75100000-0000-4000-8000-000000000003', '74100000-0000-4000-8000-000000000003', 'google', 'issue41-admin', '{"email":"issue41-admin@example.test","email_verified":true}'),
  ('75100000-0000-4000-8000-000000000004', '74100000-0000-4000-8000-000000000004', 'google', 'issue41-outsider', '{"email":"issue41-outsider@example.test","email_verified":true}');

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74100000-0000-4000-8000-000000000001', true);
SELECT public.resolve_application_access();
SELECT set_config('request.jwt.claim.sub', '74100000-0000-4000-8000-000000000002', true);
SELECT public.resolve_application_access();
SELECT set_config('request.jwt.claim.sub', '74100000-0000-4000-8000-000000000003', true);
SELECT public.resolve_application_access();
SELECT set_config('request.jwt.claim.sub', '74100000-0000-4000-8000-000000000004', true);
SELECT public.resolve_application_access();
COMMIT;

CREATE TEMP TABLE issue41_attachment_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  attachment_id uuid NOT NULL,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON issue41_attachment_fixture TO authenticated, service_role;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74100000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task_id uuid;
  v_result jsonb;
  v_completion jsonb;
  v_attachment_id uuid := '77100000-0000-4000-8000-000000000001';
  v_operation_id uuid := '78100000-0000-4000-8000-000000000001';
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Issue 41 completed attachment cleanup',
    'UTC',
    '74100000-0000-4000-8000-000000000002'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Completadas', 0);
  v_result := public.create_task_p(
    '76100000-0000-4000-8000-000000000001',
    v_board.id,
    v_column_id,
    'Informe terminado'
  );
  v_task_id := (v_result->'task'->>'id')::uuid;
  IF v_task_id IS NULL THEN
    RAISE EXCEPTION 'Could not create the completed-task fixture: %', v_result;
  END IF;
  v_completion := public.set_task_completion_p(
    '79100000-0000-4000-8000-000000000008',
    v_board.slug,
    v_task_id,
    true,
    1
  );
  IF v_completion->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not complete the fixture task: %', v_completion;
  END IF;
  RESET ROLE;
  INSERT INTO public.task_attachments(
    id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
    size_bytes, sha256, object_key, state
  ) VALUES (
    v_attachment_id, v_board.id, v_task_id,
    '74100000-0000-4000-8000-000000000002', v_operation_id,
    'informe-final.md', 24000, decode(repeat('a', 64), 'hex'),
    'attachments/issue41-completed-task', 'active'
  );
  INSERT INTO issue41_attachment_fixture(
    board_id, board_slug, task_id, attachment_id, operation_id
  ) VALUES (v_board.id, v_board.slug, v_task_id, v_attachment_id, v_operation_id);
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue41_attachment_fixture%ROWTYPE;
  v_list jsonb;
  v_preview jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue41_attachment_fixture;

  v_list := public.list_board_task_attachment_storage_p(
    '74100000-0000-4000-8000-000000000001', v_fixture.board_slug, 100, NULL, NULL
  );
  IF v_list->>'status' IS DISTINCT FROM 'ok'
    OR v_list->'items'->0->>'file_name' IS DISTINCT FROM 'informe-final.md'
    OR v_list->'items'->0->>'task_completed' IS DISTINCT FROM 'true'
    OR v_list->'items'->0 ? 'object_key' THEN
    RAISE EXCEPTION 'The current board owner did not receive a safe file list for their completed task: %', v_list;
  END IF;

  v_preview := public.preview_completed_task_attachment_cleanup_p(
    '74100000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.attachment_id
  );
  IF v_preview->>'status' IS DISTINCT FROM 'preview'
    OR v_preview->'item'->>'file_name' IS DISTINCT FROM 'informe-final.md'
    OR v_preview->'item'->>'size_bytes' IS DISTINCT FROM '24000'
    OR v_preview->'item'->>'task_title' IS DISTINCT FROM 'Informe terminado' THEN
    RAISE EXCEPTION 'Owner cleanup preview did not describe the selected completed-task attachment: %', v_preview;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74100000-0000-4000-8000-000000000001', true);
SELECT public.set_task_completion_p(
  '79100000-0000-4000-8000-000000000006',
  (SELECT board_slug FROM issue41_attachment_fixture),
  (SELECT task_id FROM issue41_attachment_fixture),
  false,
  2
);
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue41_attachment_fixture%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue41_attachment_fixture;
  v_result := public.cleanup_completed_task_attachment_p(
    '74100000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.attachment_id,
    '79100000-0000-4000-8000-000000000001'
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'Confirming after task completion changed was not rejected: %', v_result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74100000-0000-4000-8000-000000000001', true);
SELECT public.set_task_completion_p(
  '79100000-0000-4000-8000-000000000007',
  (SELECT board_slug FROM issue41_attachment_fixture),
  (SELECT task_id FROM issue41_attachment_fixture),
  true,
  3
);
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue41_attachment_fixture%ROWTYPE;
  v_list jsonb;
  v_preview jsonb;
  v_result jsonb;
  v_retry jsonb;
  v_summary jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue41_attachment_fixture;
  v_result := public.cleanup_completed_task_attachment_p(
    '74100000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.attachment_id,
    '79100000-0000-4000-8000-000000000002'
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->>'expires_at' IS NULL THEN
    RAISE EXCEPTION 'Owner could not clean the selected completed-task attachment: %', v_result;
  END IF;
  v_retry := public.cleanup_completed_task_attachment_p(
    '74100000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.attachment_id,
    '79100000-0000-4000-8000-000000000002'
  );
  IF v_retry->>'status' IS DISTINCT FROM 'confirmed'
    OR v_retry->>'expires_at' IS DISTINCT FROM v_result->>'expires_at' THEN
    RAISE EXCEPTION 'Retrying a confirmed cleanup operation did not return the original receipt: %, %',
      v_result, v_retry;
  END IF;

  v_list := public.list_board_task_attachment_storage_p(
    '74100000-0000-4000-8000-000000000001', v_fixture.board_slug, 100, NULL, NULL
  );
  IF v_list->'items'->0->>'state' IS DISTINCT FROM 'recoverable'
    OR (v_list->'items'->0->>'expires_at')::timestamptz <= clock_timestamp()
    OR v_list->'items'->0->>'deletion_cause' IS DISTINCT FROM 'moderation' THEN
    RAISE EXCEPTION 'Soft cleanup lost recovery state, cause, or expiry: %', v_list;
  END IF;
  v_summary := public.admin_task_attachment_storage_summary_p(
    '74100000-0000-4000-8000-000000000003'
  );
  IF (v_summary->>'recoverable_bytes')::bigint <> 24000 THEN
    RAISE EXCEPTION 'Soft cleanup released quota before purge: %', v_summary;
  END IF;

  v_result := public.restore_task_attachment_p(
    '74100000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '79100000-0000-4000-8000-000000000003'
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'Uploader restored an attachment deleted by owner moderation: %', v_result;
  END IF;
  v_result := public.admin_restore_task_attachment_p(
    '74100000-0000-4000-8000-000000000003',
    v_fixture.attachment_id,
    '79100000-0000-4000-8000-000000000004'
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'Admin restored an attachment not deleted by administrative cleanup: %', v_result;
  END IF;
  v_result := public.restore_task_attachment_p(
    '74100000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '79100000-0000-4000-8000-000000000005'
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Current owner could not restore an owner-cleaned attachment: %', v_result;
  END IF;

  v_list := public.list_board_task_attachment_storage_p(
    '74100000-0000-4000-8000-000000000003', v_fixture.board_slug, 100, NULL, NULL
  );
  IF v_list->>'status' IS DISTINCT FROM 'unavailable' OR v_list ? 'items' THEN
    RAISE EXCEPTION 'An unrelated application admin gained board file metadata: %', v_list;
  END IF;
  v_preview := public.preview_completed_task_attachment_cleanup_p(
    '74100000-0000-4000-8000-000000000004',
    v_fixture.board_slug,
    v_fixture.attachment_id
  );
  IF v_preview->>'status' IS DISTINCT FROM 'unavailable' OR v_preview ? 'item' THEN
    RAISE EXCEPTION 'A non-member previewed another board attachment: %', v_preview;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: owners preview and clean only current attachments of completed tasks, with current-state revalidation and retained quota.'

\echo 'Testing per-person storage threshold notices with a controlled database clock'

DO $$
DECLARE
  v_now timestamptz := '2026-06-01 12:00:00+00'::timestamptz;
  v_owner jsonb;
  v_admin jsonb;
  v_member jsonb;
  v_outsider jsonb;
  v_result jsonb;
BEGIN
  PERFORM public.record_task_attachment_capacity_transition_p(
    159999999, 160000000, v_now
  );
  v_owner := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000001'
  );
  v_admin := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000003'
  );
  v_member := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000002'
  );
  v_outsider := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000004'
  );
  IF v_owner->'items'->0->>'threshold_bytes' IS DISTINCT FROM '160000000'
    OR v_admin->'items'->0->>'threshold_bytes' IS DISTINCT FROM '160000000'
    OR jsonb_array_length(v_member->'items') <> 0
    OR jsonb_array_length(v_outsider->'items') <> 0
    OR v_owner->'items'->0 ? 'file_name' THEN
    RAISE EXCEPTION 'An 80 percent crossing did not notify only current owners and admins with aggregate metadata: owner %, admin %, member %, outsider %',
      v_owner, v_admin, v_member, v_outsider;
  END IF;

  v_result := public.mark_my_task_attachment_capacity_notice_read_p(
    '74100000-0000-4000-8000-000000000001', 160000000
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(public.list_my_task_attachment_capacity_notices_p(
      '74100000-0000-4000-8000-000000000001'
    )->'items') <> 0 THEN
    RAISE EXCEPTION 'The owner could not dismiss their own threshold notice: %', v_result;
  END IF;

  PERFORM public.record_task_attachment_capacity_transition_p(
    160000000, 170000000, v_now + interval '25 hours'
  );
  IF jsonb_array_length(public.list_my_task_attachment_capacity_notices_p(
      '74100000-0000-4000-8000-000000000001'
    )->'items') <> 0 THEN
    RAISE EXCEPTION 'Staying above 80 percent generated a periodic notice';
  END IF;

  PERFORM public.record_task_attachment_capacity_transition_p(
    160000000, 159000000, v_now + interval '26 hours'
  );
  PERFORM public.record_task_attachment_capacity_transition_p(
    159000000, 160000000, v_now + interval '27 hours'
  );
  v_owner := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000001'
  );
  IF jsonb_array_length(v_owner->'items') <> 1
    OR v_owner->'items'->0->>'threshold_bytes' IS DISTINCT FROM '160000000' THEN
    RAISE EXCEPTION 'A fresh crossing after 24 hours did not rearm the owner notice: %', v_owner;
  END IF;
  PERFORM public.mark_my_task_attachment_capacity_notice_read_p(
    '74100000-0000-4000-8000-000000000001', 160000000
  );

  PERFORM public.record_task_attachment_capacity_transition_p(
    160000000, 159000000, v_now + interval '28 hours'
  );
  PERFORM public.record_task_attachment_capacity_transition_p(
    159000000, 160000000, v_now + interval '29 hours'
  );
  PERFORM public.record_task_attachment_capacity_transition_p(
    160000000, 170000000, v_now + interval '54 hours'
  );
  IF jsonb_array_length(public.list_my_task_attachment_capacity_notices_p(
      '74100000-0000-4000-8000-000000000001'
    )->'items') <> 0 THEN
    RAISE EXCEPTION 'A crossing inside the 24-hour cooldown was deferred while usage stayed above threshold';
  END IF;

  PERFORM public.record_task_attachment_capacity_transition_p(
    170000000, 159000000, v_now + interval '55 hours'
  );
  PERFORM public.record_task_attachment_capacity_transition_p(
    159000000, 160000000, v_now + interval '56 hours'
  );
  v_owner := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000001'
  );
  IF jsonb_array_length(v_owner->'items') <> 1
    OR v_owner->'items'->0->>'threshold_bytes' IS DISTINCT FROM '160000000' THEN
    RAISE EXCEPTION 'The owner was not re-notified after dropping below and crossing after the cooldown: %', v_owner;
  END IF;
  PERFORM public.mark_my_task_attachment_capacity_notice_read_p(
    '74100000-0000-4000-8000-000000000001', 160000000
  );

  PERFORM public.record_task_attachment_capacity_transition_p(
    190000000, 200000000, v_now + interval '58 hours'
  );
  v_owner := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000001'
  );
  IF jsonb_array_length(v_owner->'items') <> 1
    OR v_owner->'items'->0->>'threshold_bytes' IS DISTINCT FROM '200000000' THEN
    RAISE EXCEPTION 'The maximum threshold was not independent from the 80 percent notice: %', v_owner;
  END IF;
  PERFORM public.mark_my_task_attachment_capacity_notice_read_p(
    '74100000-0000-4000-8000-000000000001', 200000000
  );
  PERFORM public.record_task_attachment_capacity_transition_p(
    200000000, 190000000, v_now + interval '59 hours'
  );
  PERFORM public.record_task_attachment_capacity_transition_p(
    190000000, 200000000, v_now + interval '60 hours'
  );
  IF jsonb_array_length(public.list_my_task_attachment_capacity_notices_p(
      '74100000-0000-4000-8000-000000000001'
    )->'items') <> 0 THEN
    RAISE EXCEPTION 'The maximum threshold repeated before its own 24-hour cooldown';
  END IF;
END;
$$;

\echo 'PASS: threshold notices are deduplicated per person/threshold and rearm only after a fresh crossing outside 24 hours.'

DO $$
DECLARE
  v_fixture issue41_attachment_fixture%ROWTYPE;
  v_owner jsonb;
  v_admin jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue41_attachment_fixture;
  DELETE FROM public.task_attachment_capacity_notice_states
  WHERE user_id IN (
    '74100000-0000-4000-8000-000000000001',
    '74100000-0000-4000-8000-000000000003'
  );
  UPDATE public.task_attachment_quota_ledger
  SET active_bytes = 159999999,
      recoverable_bytes = 0,
      reserved_bytes = 0,
      pending_bytes = 0
  WHERE singleton;

  INSERT INTO public.task_attachments(
    id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
    size_bytes, sha256, object_key, state
  ) VALUES (
    '77100000-0000-4000-8000-000000000002', v_fixture.board_id, v_fixture.task_id,
    '74100000-0000-4000-8000-000000000002', '78100000-0000-4000-8000-000000000002',
    'ledger-trigger.md', 1, decode(repeat('b', 64), 'hex'),
    'attachments/issue41-ledger-trigger', 'active'
  );

  v_owner := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000001'
  );
  v_admin := public.list_my_task_attachment_capacity_notices_p(
    '74100000-0000-4000-8000-000000000003'
  );
  IF v_owner->'items'->0->>'threshold_bytes' IS DISTINCT FROM '160000000'
    OR v_admin->'items'->0->>'threshold_bytes' IS DISTINCT FROM '160000000'
    OR v_owner->'items'->0->>'last_notified_at' IS NULL
    OR v_owner->'items'->0 ? 'file_name' THEN
    RAISE EXCEPTION 'The quota ledger trigger did not immediately create aggregate owner/admin notices at 80 percent: owner %, admin %',
      v_owner, v_admin;
  END IF;
END;
$$;

\echo 'PASS: the attachment quota ledger trigger creates personal threshold notices immediately on a real ledger crossing.'

\echo 'Testing the privacy-minimal global admin capacity breakdown'

BEGIN;
DO $$
DECLARE
  v_fixture issue41_attachment_fixture%ROWTYPE;
  v_admin uuid := '74100000-0000-4000-8000-000000000003';
  v_non_admin uuid := '74100000-0000-4000-8000-000000000001';
  v_before jsonb;
  v_after jsonb;
  v_denied jsonb;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_keys text[];
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue41_attachment_fixture;
  v_before := public.admin_task_attachment_storage_summary_p(v_admin);
  IF v_before->>'status' IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'An enabled admin could not read the aggregate storage summary: %', v_before;
  END IF;

  INSERT INTO public.task_attachments(
    id, board_id, task_id, uploaded_by, upload_operation_id, file_name,
    size_bytes, sha256, object_key, state, reservation_expires_at,
    deleted_at, deleted_by, deletion_cause, expires_at
  ) VALUES
    (
      '77100000-0000-4000-8000-000000000010', v_fixture.board_id, v_fixture.task_id,
      '74100000-0000-4000-8000-000000000001', '78100000-0000-4000-8000-000000000010',
      'capacity-active.md', 7, decode(repeat('c', 64), 'hex'),
      'attachments/issue41-capacity-active', 'active', NULL, NULL, NULL, NULL, NULL
    ),
    (
      '77100000-0000-4000-8000-000000000011', v_fixture.board_id, v_fixture.task_id,
      '74100000-0000-4000-8000-000000000001', '78100000-0000-4000-8000-000000000011',
      'capacity-recoverable.md', 11, decode(repeat('d', 64), 'hex'),
      'attachments/issue41-capacity-recoverable', 'recoverable', NULL,
      v_now, '74100000-0000-4000-8000-000000000001', 'admin_cleanup', v_now + interval '168 hours'
    ),
    (
      '77100000-0000-4000-8000-000000000012', v_fixture.board_id, v_fixture.task_id,
      '74100000-0000-4000-8000-000000000001', '78100000-0000-4000-8000-000000000012',
      'capacity-reserved.md', 13, decode(repeat('e', 64), 'hex'),
      'attachments/issue41-capacity-reserved', 'reserved', v_now + interval '15 minutes',
      NULL, NULL, NULL, NULL
    ),
    (
      '77100000-0000-4000-8000-000000000013', v_fixture.board_id, v_fixture.task_id,
      '74100000-0000-4000-8000-000000000001', '78100000-0000-4000-8000-000000000013',
      'capacity-pending.md', 17, decode(repeat('f', 64), 'hex'),
      'attachments/issue41-capacity-pending', 'missing', NULL, NULL, NULL, NULL, NULL
    );

  v_after := public.admin_task_attachment_storage_summary_p(v_admin);
  SELECT pg_catalog.array_agg(key ORDER BY key) INTO v_keys
  FROM pg_catalog.jsonb_object_keys(v_after) AS keys(key);
  IF v_after->>'status' IS DISTINCT FROM 'ok'
    OR (v_after->>'active_bytes')::bigint - (v_before->>'active_bytes')::bigint <> 7
    OR (v_after->>'recoverable_bytes')::bigint - (v_before->>'recoverable_bytes')::bigint <> 11
    OR (v_after->>'reserved_bytes')::bigint - (v_before->>'reserved_bytes')::bigint <> 13
    OR (v_after->>'pending_bytes')::bigint - (v_before->>'pending_bytes')::bigint <> 17
    OR (v_after->>'active_count')::bigint - (v_before->>'active_count')::bigint <> 1
    OR (v_after->>'recoverable_count')::bigint - (v_before->>'recoverable_count')::bigint <> 1
    OR (v_after->>'reserved_count')::bigint - (v_before->>'reserved_count')::bigint <> 1
    OR (v_after->>'pending_count')::bigint - (v_before->>'pending_count')::bigint <> 1
    OR (v_after->>'used_bytes')::bigint - (v_before->>'used_bytes')::bigint <> 48
    OR v_keys IS DISTINCT FROM ARRAY[
      'active_bytes', 'active_count', 'limit_bytes', 'pending_bytes', 'pending_count',
      'recoverable_bytes', 'recoverable_count', 'reserved_bytes', 'reserved_count',
      'status', 'used_bytes'
    ]::text[] THEN
    RAISE EXCEPTION 'The admin summary did not keep global states separate and metadata-minimal: before %, after %, keys %',
      v_before, v_after, v_keys;
  END IF;

  v_denied := public.admin_task_attachment_storage_summary_p(v_non_admin);
  IF v_denied->>'status' IS DISTINCT FROM 'unavailable' OR v_denied ? 'used_bytes' THEN
    RAISE EXCEPTION 'A non-admin received aggregate global storage metadata: %', v_denied;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: global active, recoverable, reserved, and pending capacity stay distinct and aggregate-only for admins.'
