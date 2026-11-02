\set ON_ERROR_STOP on
\echo 'Testing private attachment reservation through the server database interface'

INSERT INTO public.application_access (email, state, is_admin) VALUES
  ('issue40-owner@example.test', 'pending', false),
  ('issue40-member@example.test', 'pending', false),
  ('issue40-outsider@example.test', 'pending', false),
  ('issue40-admin@example.test', 'pending', true);

INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data) VALUES
  ('74000000-0000-4000-8000-000000000001', 'issue40-owner@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('74000000-0000-4000-8000-000000000002', 'issue40-member@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('74000000-0000-4000-8000-000000000003', 'issue40-outsider@example.test', clock_timestamp(), '{"provider":"google"}'),
  ('74000000-0000-4000-8000-000000000004', 'issue40-admin@example.test', clock_timestamp(), '{"provider":"google"}');

INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data) VALUES
  ('75000000-0000-4000-8000-000000000001', '74000000-0000-4000-8000-000000000001', 'google', 'issue40-owner', '{"email":"issue40-owner@example.test","email_verified":true}'),
  ('75000000-0000-4000-8000-000000000002', '74000000-0000-4000-8000-000000000002', 'google', 'issue40-member', '{"email":"issue40-member@example.test","email_verified":true}'),
  ('75000000-0000-4000-8000-000000000003', '74000000-0000-4000-8000-000000000003', 'google', 'issue40-outsider', '{"email":"issue40-outsider@example.test","email_verified":true}'),
  ('75000000-0000-4000-8000-000000000004', '74000000-0000-4000-8000-000000000004', 'google', 'issue40-admin', '{"email":"issue40-admin@example.test","email_verified":true}');

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000001', true);
SELECT public.resolve_application_access();
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000002', true);
SELECT public.resolve_application_access();
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000003', true);
SELECT public.resolve_application_access();
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000004', true);
SELECT public.resolve_application_access();
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_visible_objects integer;
  v_insert_blocked boolean := false;
BEGIN
  SELECT count(*)::integer INTO v_visible_objects
  FROM storage.objects
  WHERE bucket_id = 'task-attachments';
  IF v_visible_objects <> 0 THEN
    RAISE EXCEPTION 'Authenticated member could list private attachment objects';
  END IF;
  BEGIN
    INSERT INTO storage.objects(bucket_id, name)
    VALUES ('task-attachments', 'attachments/unauthorized-test');
  EXCEPTION WHEN insufficient_privilege THEN
    v_insert_blocked := true;
  END;
  IF NOT v_insert_blocked THEN
    RAISE EXCEPTION 'Authenticated member could insert a private attachment object directly';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: database RLS stub denies direct authenticated bucket listing and insertion.'

CREATE TEMP TABLE issue40_attachment_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  attachment_id uuid,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT, UPDATE ON issue40_attachment_fixture TO authenticated, service_role;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task_id uuid;
  v_task_result jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Issue 40 attachment reservation',
    'UTC',
    '74000000-0000-4000-8000-000000000002'
  );

  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Notas', 0);

  v_task_result := public.create_task_p(
    '76000000-0000-4000-8000-000000000001',
    v_board.id,
    v_column_id,
    'Tarea de textos privados'
  );
  v_task_id := (v_task_result->'task'->>'id')::uuid;
  IF v_task_id IS NULL THEN
    RAISE EXCEPTION 'The isolated issue 40 fixture did not create its task: %', v_task_result;
  END IF;

  INSERT INTO issue40_attachment_fixture(board_id, board_slug, task_id, operation_id)
  VALUES (
    v_board.id,
    v_board.slug,
    v_task_id,
    '77000000-0000-4000-8000-000000000001'
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships (board_id, user_id, role)
SELECT board_id, '74000000-0000-4000-8000-000000000002', 'collaborator'
FROM issue40_attachment_fixture;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_result jsonb;
  v_retry jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_result := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.operation_id,
    v_fixture.board_slug,
    v_fixture.task_id,
    'plan de trabajo.md',
    24000,
    repeat('a', 64)
  );
  IF v_result->>'status' IS DISTINCT FROM 'reserved'
    OR v_result->>'attachment_id' IS NULL THEN
    RAISE EXCEPTION 'An enabled member could not reserve the inclusive 24,000-byte file limit: %', v_result;
  END IF;

  UPDATE issue40_attachment_fixture
  SET attachment_id = (v_result->>'attachment_id')::uuid;
  v_fixture.attachment_id := (v_result->>'attachment_id')::uuid;

  v_retry := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.operation_id,
    v_fixture.board_slug,
    v_fixture.task_id,
    'plan de trabajo.md',
    24000,
    repeat('a', 64)
  );
  IF v_retry->>'attachment_id' IS DISTINCT FROM v_result->>'attachment_id'
    OR v_retry->>'status' IS DISTINCT FROM 'reserved' THEN
    RAISE EXCEPTION 'Retrying the same upload intent created a second reservation: first %, retry %', v_result, v_retry;
  END IF;

  v_result := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000003',
    '77000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    'intruso.txt',
    1,
    repeat('b', 64)
  );
  IF v_result->>'status' IS DISTINCT FROM 'unavailable'
    OR v_result ? 'attachment_id' THEN
    RAISE EXCEPTION 'A non-member could infer or reserve a task attachment: %', v_result;
  END IF;

  v_result := public.publish_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    v_fixture.operation_id,
    24000,
    repeat('a', 64)
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed'
    OR v_result->>'attachment_id' IS DISTINCT FROM v_fixture.attachment_id::text THEN
    RAISE EXCEPTION 'The member could not publish the verified private object: %', v_result;
  END IF;
  v_retry := public.publish_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    v_fixture.operation_id,
    24000,
    repeat('a', 64)
  );
  IF v_retry->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Publishing the same verified object was not idempotent: %', v_retry;
  END IF;
END;
$$;
COMMIT;

WITH fixture AS (
  SELECT * FROM issue40_attachment_fixture
), deletion_time AS (
  SELECT clock_timestamp() AS value
)
INSERT INTO public.task_attachments(
  board_id, task_id, uploaded_by, upload_operation_id, file_name,
  size_bytes, sha256, object_key, state, reservation_expires_at,
  deleted_at, deleted_by, deletion_cause, expires_at
)
SELECT
  fixture.board_id,
  fixture.task_id,
  '74000000-0000-4000-8000-000000000002',
  pg_catalog.gen_random_uuid(),
  'cuota-prueba-' || candidate.number::text || '.txt',
  1,
  pg_catalog.decode(repeat('a', 64), 'hex'),
  'attachments/issue40-task-limit-fixture-' || candidate.number::text,
  CASE WHEN candidate.number = 19 THEN 'reserved' ELSE 'recoverable' END,
  CASE WHEN candidate.number = 19 THEN pg_catalog.clock_timestamp() + interval '1 hour' ELSE NULL END,
  CASE WHEN candidate.number = 19 THEN NULL ELSE deletion_time.value END,
  CASE WHEN candidate.number = 19 THEN NULL ELSE '74000000-0000-4000-8000-000000000002'::uuid END,
  CASE WHEN candidate.number = 19 THEN NULL ELSE 'author' END,
  CASE WHEN candidate.number = 19 THEN NULL ELSE deletion_time.value + interval '168 hours' END
FROM fixture
CROSS JOIN deletion_time
CROSS JOIN pg_catalog.generate_series(1, 19) AS candidate(number);

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_result := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    '78000000-0000-4000-8000-000000000003',
    v_fixture.board_slug,
    v_fixture.task_id,
    'veintiuno.txt',
    1,
    repeat('b', 64)
  );
  IF v_result->>'status' IS DISTINCT FROM 'task_limit' THEN
    RAISE EXCEPTION 'The 20-item task limit did not count active, recoverable and reserved objects: %', v_result;
  END IF;
END;
$$;
COMMIT;
UPDATE public.task_attachments AS attachment
SET state = 'purged', reservation_expires_at = NULL
WHERE attachment.object_key LIKE 'attachments/issue40-task-limit-fixture-%';
\echo 'PASS: the task cap includes recoverable files and open reservations.'

CREATE TEMP TABLE issue40_attachment_quota_snapshot AS
SELECT active_bytes, recoverable_bytes, reserved_bytes, pending_bytes
FROM public.task_attachment_quota_ledger
WHERE singleton;
UPDATE public.task_attachment_quota_ledger AS ledger
SET active_bytes = ledger.limit_bytes - 1 - ledger.recoverable_bytes
  - ledger.reserved_bytes - ledger.pending_bytes
WHERE ledger.singleton;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_exact_limit jsonb;
  v_over_limit jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_exact_limit := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    '78000000-0000-4000-8000-000000000004',
    v_fixture.board_slug,
    v_fixture.task_id,
    'limite.txt',
    1,
    repeat('c', 64)
  );
  v_over_limit := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    '78000000-0000-4000-8000-000000000005',
    v_fixture.board_slug,
    v_fixture.task_id,
    'excede.txt',
    1,
    repeat('d', 64)
  );
  IF v_exact_limit->>'status' IS DISTINCT FROM 'reserved'
    OR v_over_limit->>'status' IS DISTINCT FROM 'quota' THEN
    RAISE EXCEPTION 'Global decimal quota was not inclusive at 200,000,000 bytes: %, %', v_exact_limit, v_over_limit;
  END IF;
END;
$$;
COMMIT;

UPDATE public.task_attachments AS attachment
SET state = 'purged', reservation_expires_at = NULL
WHERE attachment.uploaded_by = '74000000-0000-4000-8000-000000000002'
  AND attachment.upload_operation_id = '78000000-0000-4000-8000-000000000004';
UPDATE public.task_attachment_quota_ledger AS ledger
SET active_bytes = snapshot.active_bytes,
    recoverable_bytes = snapshot.recoverable_bytes,
    reserved_bytes = snapshot.reserved_bytes,
    pending_bytes = snapshot.pending_bytes,
    updated_at = clock_timestamp()
FROM issue40_attachment_quota_snapshot AS snapshot
WHERE ledger.singleton;
\echo 'PASS: the global decimal quota includes reservations and permits exactly 200,000,000 bytes.'

UPDATE public.board_memberships AS membership
SET revoked_at = clock_timestamp()
FROM issue40_attachment_fixture AS fixture
WHERE membership.board_id = fixture.board_id
  AND membership.user_id = '74000000-0000-4000-8000-000000000002'
  AND membership.revoked_at IS NULL;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_retry jsonb;
  v_publish jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_retry := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.operation_id,
    v_fixture.board_slug,
    v_fixture.task_id,
    'plan de trabajo.md',
    24000,
    repeat('a', 64)
  );
  v_publish := public.publish_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    v_fixture.operation_id,
    24000,
    repeat('a', 64)
  );
  IF v_retry->>'status' IS DISTINCT FROM 'unavailable'
    OR v_retry ? 'attachment_id'
    OR v_publish->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A revoked member could replay reservation or publication: %, %', v_retry, v_publish;
  END IF;
END;
$$;
COMMIT;

UPDATE public.board_memberships AS membership
SET revoked_at = NULL
FROM issue40_attachment_fixture AS fixture
WHERE membership.board_id = fixture.board_id
  AND membership.user_id = '74000000-0000-4000-8000-000000000002'
  AND membership.revoked_at IS NOT NULL;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_retry jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_retry := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.operation_id,
    v_fixture.board_slug,
    v_fixture.task_id,
    'plan de trabajo.md',
    24000,
    repeat('a', 64)
  );
  IF v_retry->>'status' IS DISTINCT FROM 'confirmed'
    OR v_retry->>'attachment_id' IS DISTINCT FROM v_fixture.attachment_id::text THEN
    RAISE EXCEPTION 'A restored active membership could not safely reconcile its confirmed reservation: %', v_retry;
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: reservation and publication retries recheck current membership after revocation.'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_list jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_list := public.list_task_attachments_p(v_fixture.board_slug, v_fixture.task_id);
  IF v_list->>'status' IS DISTINCT FROM 'ok'
    OR jsonb_array_length(v_list->'attachments') <> 1
    OR v_list->'attachments'->0->>'id' IS DISTINCT FROM v_fixture.attachment_id::text
    OR v_list->'attachments'->0 ? 'object_key' THEN
    RAISE EXCEPTION 'Member list did not return only safe metadata for the active object: %', v_list;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000003', true);
  v_list := public.list_task_attachments_p(v_fixture.board_slug, v_fixture.task_id);
  IF v_list->>'status' IS DISTINCT FROM 'unavailable'
    OR v_list ? 'attachments' THEN
    RAISE EXCEPTION 'A non-member could list attachment names or task scope: %', v_list;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: reservation, publication, and metadata listing are authorized, private, and idempotent.'

BEGIN;
SET LOCAL ROLE service_role;
SAVEPOINT issue40_reservation_cap;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_result jsonb;
  v_index integer;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  FOR v_index IN 1..5 LOOP
    v_result := public.reserve_task_attachment_p(
      '74000000-0000-4000-8000-000000000002',
      gen_random_uuid(),
      v_fixture.board_slug,
      v_fixture.task_id,
      'reserva-' || v_index::text || '.txt',
      1,
      repeat('b', 64)
    );
    IF v_result->>'status' IS DISTINCT FROM 'reserved' THEN
      RAISE EXCEPTION 'One of five concurrent member reservations was rejected: %', v_result;
    END IF;
  END LOOP;
  v_result := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    gen_random_uuid(),
    v_fixture.board_slug,
    v_fixture.task_id,
    'reserva-6.txt',
    1,
    repeat('c', 64)
  );
  IF v_result->>'status' IS DISTINCT FROM 'reservation_limit' THEN
    RAISE EXCEPTION 'More than five open reservations were allowed for one member: %', v_result;
  END IF;
END;
$$;
ROLLBACK TO SAVEPOINT issue40_reservation_cap;
COMMIT;

\echo 'PASS: the initial per-member open reservation limit is five and test writes were rolled back.'

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_download jsonb;
  v_admin_summary jsonb;
  v_outsider_summary jsonb;
  v_admin_items jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_download := public.resolve_task_attachment_download_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id
  );
  IF v_download->>'status' IS DISTINCT FROM 'ok'
    OR v_download->>'object_key' IS DISTINCT FROM 'attachments/' || v_fixture.attachment_id::text
    OR v_download->>'file_name' IS DISTINCT FROM 'plan de trabajo.md' THEN
    RAISE EXCEPTION 'An active member could not resolve a private download after ACL validation: %', v_download;
  END IF;
  v_download := public.resolve_task_attachment_download_p(
    '74000000-0000-4000-8000-000000000003',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id
  );
  IF v_download->>'status' IS DISTINCT FROM 'unavailable' OR v_download ? 'object_key' THEN
    RAISE EXCEPTION 'A non-member resolved an object key or attachment metadata: %', v_download;
  END IF;

  v_admin_summary := public.admin_task_attachment_storage_summary_p(
    '74000000-0000-4000-8000-000000000004'
  );
  IF v_admin_summary->>'status' IS DISTINCT FROM 'ok'
    OR (v_admin_summary->>'used_bytes')::bigint <> 24000
    OR (v_admin_summary->>'active_bytes')::bigint <> 24000
    OR (v_admin_summary->>'limit_bytes')::bigint <> 200000000 THEN
    RAISE EXCEPTION 'Global admin storage view did not return exact decimal totals: %', v_admin_summary;
  END IF;
  v_admin_items := public.list_admin_task_attachment_cleanup_p(
    '74000000-0000-4000-8000-000000000004', 10
  );
  IF v_admin_items->>'status' IS DISTINCT FROM 'ok'
    OR jsonb_array_length(v_admin_items->'items') <> 1
    OR v_admin_items->'items'->0 ? 'file_name'
    OR v_admin_items->'items'->0 ? 'object_key' THEN
    RAISE EXCEPTION 'Admin cleanup candidates disclosed a filename or Storage key: %', v_admin_items;
  END IF;
  v_outsider_summary := public.admin_task_attachment_storage_summary_p(
    '74000000-0000-4000-8000-000000000003'
  );
  IF v_outsider_summary->>'status' IS DISTINCT FROM 'unavailable'
    OR v_outsider_summary ? 'used_bytes' THEN
    RAISE EXCEPTION 'A non-admin learned global attachment totals: %', v_outsider_summary;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: downloads are member-authorized and global admin views expose only aggregate/minimal cleanup metadata.'

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_deleted jsonb;
  v_retry jsonb;
  v_restored jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_deleted := public.delete_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000003'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_deleted->>'cause' IS DISTINCT FROM 'author'
    OR (v_deleted->>'expires_at')::timestamptz
      - (v_deleted->>'deleted_at')::timestamptz <> interval '168 hours' THEN
    RAISE EXCEPTION 'Deleting an uploaded attachment did not preserve its exact seven-day recovery window: %', v_deleted;
  END IF;
  v_retry := public.delete_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000003'
  );
  IF v_retry->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Retrying the same delete intent was not idempotent: %', v_retry;
  END IF;

  v_restored := public.restore_task_attachment_p(
    '74000000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000004'
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'The current owner could not restore an author-deleted attachment: %', v_restored;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_active_bytes bigint;
  v_recoverable_bytes bigint;
  v_reserved_bytes bigint;
  v_pending_bytes bigint;
BEGIN
  SELECT active_bytes, recoverable_bytes, reserved_bytes, pending_bytes
  INTO v_active_bytes, v_recoverable_bytes, v_reserved_bytes, v_pending_bytes
  FROM public.task_attachment_quota_ledger WHERE singleton;
  IF v_active_bytes <> 24000 OR v_recoverable_bytes <> 0
    OR v_reserved_bytes <> 0 OR v_pending_bytes <> 0 THEN
    RAISE EXCEPTION 'Restoring an attachment charged quota twice or lost its original charge: %, %, %, %',
      v_active_bytes, v_recoverable_bytes, v_reserved_bytes, v_pending_bytes;
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_deleted jsonb;
  v_restore jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_deleted := public.delete_task_attachment_p(
    '74000000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000005'
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_deleted->>'cause' IS DISTINCT FROM 'moderation' THEN
    RAISE EXCEPTION 'Owner moderation was not recorded distinctly: %', v_deleted;
  END IF;

  v_restore := public.restore_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000006'
  );
  IF v_restore->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'The uploader restored an attachment removed by owner moderation: %', v_restore;
  END IF;
END;
$$;
COMMIT;

-- Advance only the synthetic fixture's retention date; production procedures
-- continue to use the database clock and do not accept a caller-supplied time.
WITH test_now AS (SELECT clock_timestamp() AS now)
UPDATE public.task_attachments AS attachment
SET deleted_at = test_now.now - interval '168 hours' - interval '1 second',
    expires_at = test_now.now - interval '1 second'
FROM issue40_attachment_fixture, test_now
WHERE attachment.id = issue40_attachment_fixture.attachment_id;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_claimed record;
  v_restore jsonb;
  v_failed_delete jsonb;
  v_final_claim record;
  v_confirmed jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  SELECT * INTO v_claimed
  FROM public.claim_expired_task_attachment_cleanup_p(
    '78000000-0000-4000-8000-000000000001', 1
  );
  IF v_claimed.attachment_id IS DISTINCT FROM v_fixture.attachment_id
    OR v_claimed.object_key IS NULL THEN
    RAISE EXCEPTION 'An expired attachment was not safely claimed for Storage cleanup: %', v_claimed;
  END IF;

  v_restore := public.restore_task_attachment_p(
    '74000000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000007'
  );
  IF v_restore->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'Restoration succeeded after purge claimed the row: %', v_restore;
  END IF;

  v_failed_delete := public.confirm_task_attachment_purge_p(
    v_fixture.attachment_id,
    '78000000-0000-4000-8000-000000000001',
    false
  );
  IF v_failed_delete->>'status' IS DISTINCT FROM 'cleanup_pending' THEN
    RAISE EXCEPTION 'A failed Storage delete released or lost its cleanup state: %', v_failed_delete;
  END IF;

  SELECT * INTO v_final_claim
  FROM public.claim_expired_task_attachment_cleanup_p(
    '78000000-0000-4000-8000-000000000002', 1
  );
  IF v_final_claim.attachment_id IS DISTINCT FROM v_fixture.attachment_id THEN
    RAISE EXCEPTION 'A cleanup retry was not claimable after a failed Storage delete: %', v_final_claim;
  END IF;
  v_confirmed := public.confirm_task_attachment_purge_p(
    v_fixture.attachment_id,
    '78000000-0000-4000-8000-000000000002',
    true
  );
  IF v_confirmed->>'status' IS DISTINCT FROM 'purged' THEN
    RAISE EXCEPTION 'Confirmed object absence did not finalize purge: %', v_confirmed;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE
  v_active_bytes bigint;
  v_recoverable_bytes bigint;
  v_reserved_bytes bigint;
  v_pending_bytes bigint;
BEGIN
  SELECT active_bytes, recoverable_bytes, reserved_bytes, pending_bytes
  INTO v_active_bytes, v_recoverable_bytes, v_reserved_bytes, v_pending_bytes
  FROM public.task_attachment_quota_ledger WHERE singleton;
  IF v_active_bytes <> 0 OR v_recoverable_bytes <> 0
    OR v_reserved_bytes <> 0 OR v_pending_bytes <> 0 THEN
    RAISE EXCEPTION 'Confirmed object absence did not release the global quota: %, %, %, %',
      v_active_bytes, v_recoverable_bytes, v_reserved_bytes, v_pending_bytes;
  END IF;
END;
$$;

\echo 'PASS: recovery retains quota, restore is single-charge, and purge releases quota only after confirmed absence.'

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_reserved jsonb;
  v_published jsonb;
  v_cleanup jsonb;
  v_retry jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_reserved := public.reserve_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    '77000000-0000-4000-8000-000000000008',
    v_fixture.board_slug,
    v_fixture.task_id,
    'segundo archivo.txt',
    128,
    repeat('d', 64)
  );
  IF v_reserved->>'status' IS DISTINCT FROM 'reserved' THEN
    RAISE EXCEPTION 'Synthetic member could not create the admin cleanup fixture: %', v_reserved;
  END IF;
  UPDATE issue40_attachment_fixture
  SET attachment_id = (v_reserved->>'attachment_id')::uuid;
  v_fixture.attachment_id := (v_reserved->>'attachment_id')::uuid;
  v_published := public.publish_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000008',
    128,
    repeat('d', 64)
  );
  IF v_published->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Synthetic admin cleanup object did not publish: %', v_published;
  END IF;

  v_cleanup := public.admin_delete_task_attachment_p(
    '74000000-0000-4000-8000-000000000004',
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000009'
  );
  IF v_cleanup->>'status' IS DISTINCT FROM 'confirmed'
    OR v_cleanup ? 'file_name'
    OR v_cleanup ? 'object_key' THEN
    RAISE EXCEPTION 'Admin cleanup was not a selected, metadata-only recovery action: %', v_cleanup;
  END IF;
  v_retry := public.admin_delete_task_attachment_p(
    '74000000-0000-4000-8000-000000000004',
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000009'
  );
  IF v_retry->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Admin cleanup did not reconcile its retry: %', v_retry;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '74000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_page jsonb;
  v_items jsonb;
BEGIN
  v_page := public.list_my_task_notifications_p('all', 30, NULL, NULL);
  v_items := v_page->'items';
  IF v_page->>'status' IS DISTINCT FROM 'available'
    OR jsonb_array_length(v_items) <> 1
    OR v_items->0->'reason_codes' <> '["attachment_cleanup"]'::jsonb
    OR v_items->0->>'actor_name' IS DISTINCT FROM 'Administración'
    OR v_items->0->>'task_title' IS DISTINCT FROM 'Tarea de textos privados'
    OR v_items->0 ? 'file_name'
    OR v_items->0 ? 'object_key' THEN
    RAISE EXCEPTION 'The current board owner did not receive a safe admin cleanup notice: %', v_page;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
DO $$
DECLARE
  v_fixture issue40_attachment_fixture%ROWTYPE;
  v_uploader_restore jsonb;
  v_owner_restore jsonb;
  v_restored jsonb;
  v_retry jsonb;
  v_summary jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue40_attachment_fixture;
  v_uploader_restore := public.restore_task_attachment_p(
    '74000000-0000-4000-8000-000000000002',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000011'
  );
  v_owner_restore := public.restore_task_attachment_p(
    '74000000-0000-4000-8000-000000000001',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000012'
  );
  IF v_uploader_restore->>'status' IS DISTINCT FROM 'unavailable'
    OR v_owner_restore->>'status' IS DISTINCT FROM 'unavailable' THEN
    RAISE EXCEPTION 'A member or owner restored an admin-cleaned object: uploader %, owner %',
      v_uploader_restore, v_owner_restore;
  END IF;

  v_restored := public.admin_restore_task_attachment_p(
    '74000000-0000-4000-8000-000000000004',
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000010'
  );
  v_retry := public.admin_restore_task_attachment_p(
    '74000000-0000-4000-8000-000000000004',
    v_fixture.attachment_id,
    '77000000-0000-4000-8000-000000000010'
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR v_retry->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Current administrator could not restore its own cleanup idempotently: %, %',
      v_restored, v_retry;
  END IF;
  v_summary := public.admin_task_attachment_storage_summary_p(
    '74000000-0000-4000-8000-000000000004'
  );
  IF (v_summary->>'active_bytes')::bigint <> 128
    OR (v_summary->>'recoverable_bytes')::bigint <> 0 THEN
    RAISE EXCEPTION 'Admin restore applied a duplicate or lost quota charge: %', v_summary;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: selected admin cleanup is logged, notifies only the current owner, hides names, and restores only for a current admin.'
