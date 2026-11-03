\set ON_ERROR_STOP on
\echo Testing expiration and quota cleanup of prior import generations

-- p_limit caps expired prepared generations within one board, not just board count.
WITH fixture AS (
  SELECT board.id AS board_id, board.active_generation_id, board.owner_id
  FROM public.issue43_import_fixture AS import_fixture
  JOIN public.boards AS board ON board.id = import_fixture.board_id
), synthetic(generation_id, operation_id) AS (
  VALUES
    ('a4390000-0000-4000-8000-00000000000a'::uuid, 'a4360000-0000-4000-8000-00000000000a'::uuid),
    ('a4390000-0000-4000-8000-00000000000b'::uuid, 'a4360000-0000-4000-8000-00000000000b'::uuid),
    ('a4390000-0000-4000-8000-00000000000c'::uuid, 'a4360000-0000-4000-8000-00000000000c'::uuid)
)
INSERT INTO public.board_generations(id, board_id, status, created_by)
SELECT synthetic.generation_id, fixture.board_id, 'preparing', fixture.owner_id
FROM fixture CROSS JOIN synthetic;
WITH fixture AS (
  SELECT board.id AS board_id, board.active_generation_id, board.owner_id
  FROM public.issue43_import_fixture AS import_fixture
  JOIN public.boards AS board ON board.id = import_fixture.board_id
), synthetic(generation_id, operation_id) AS (
  VALUES
    ('a4390000-0000-4000-8000-00000000000a'::uuid, 'a4360000-0000-4000-8000-00000000000a'::uuid),
    ('a4390000-0000-4000-8000-00000000000b'::uuid, 'a4360000-0000-4000-8000-00000000000b'::uuid),
    ('a4390000-0000-4000-8000-00000000000c'::uuid, 'a4360000-0000-4000-8000-00000000000c'::uuid)
)
INSERT INTO public.board_import_operations(
  actor_id, operation_id, board_id, generation_id, base_generation_id,
  expected_content_revision, source_sha256, staged_content_hash, status,
  created_at, expires_at
)
SELECT fixture.owner_id, synthetic.operation_id, fixture.board_id,
  synthetic.generation_id, fixture.active_generation_id, 1, repeat('f', 64),
  extensions.digest(convert_to('issue43 batch fixture', 'UTF8'), 'sha256'),
  'prepared', clock_timestamp() - interval '2 hours', clock_timestamp() - interval '1 hour'
FROM fixture CROSS JOIN synthetic;
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_import_operations_p(2);
COMMIT;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.board_import_operations
      WHERE operation_id IN (
        'a4360000-0000-4000-8000-00000000000a',
        'a4360000-0000-4000-8000-00000000000b',
        'a4360000-0000-4000-8000-00000000000c'
      ) AND status = 'expired') <> 2
    OR (SELECT count(*) FROM public.board_generations
      WHERE id IN (
        'a4390000-0000-4000-8000-00000000000a',
        'a4390000-0000-4000-8000-00000000000b',
        'a4390000-0000-4000-8000-00000000000c'
      )) <> 1 THEN
    RAISE EXCEPTION 'Import cleanup exceeded or missed the per-call row limit';
  END IF;
END;
$$;
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_import_operations_p(1);
COMMIT;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.board_generations
      WHERE id IN (
        'a4390000-0000-4000-8000-00000000000a',
        'a4390000-0000-4000-8000-00000000000b',
        'a4390000-0000-4000-8000-00000000000c'
      )) THEN
    RAISE EXCEPTION 'Import cleanup did not finish the bounded backlog';
  END IF;
END;
$$;

-- p_limit also caps expired retained generations on one board.
WITH fixture AS (
  SELECT board.id AS board_id, board.active_generation_id, board.owner_id
  FROM public.issue43_import_fixture AS import_fixture
  JOIN public.boards AS board ON board.id = import_fixture.board_id
), synthetic(generation_id) AS (
  VALUES
    ('a4390000-0000-4000-8000-00000000001a'::uuid),
    ('a4390000-0000-4000-8000-00000000001b'::uuid),
    ('a4390000-0000-4000-8000-00000000001c'::uuid)
)
INSERT INTO public.board_generations(id, board_id, status, created_by)
SELECT synthetic.generation_id, fixture.board_id, 'archived', fixture.owner_id
FROM fixture CROSS JOIN synthetic;
WITH fixture AS (
  SELECT board.id AS board_id, board.active_generation_id
  FROM public.issue43_import_fixture AS import_fixture
  JOIN public.boards AS board ON board.id = import_fixture.board_id
), synthetic(generation_id) AS (
  VALUES
    ('a4390000-0000-4000-8000-00000000001a'::uuid),
    ('a4390000-0000-4000-8000-00000000001b'::uuid),
    ('a4390000-0000-4000-8000-00000000001c'::uuid)
)
INSERT INTO public.board_generation_retention(
  board_id, generation_id, replacement_generation_id, retained_at, expires_at
)
SELECT fixture.board_id, synthetic.generation_id, fixture.active_generation_id,
  expired_time.retained_at, expired_time.retained_at + interval '168 hours'
FROM fixture CROSS JOIN synthetic
CROSS JOIN (SELECT clock_timestamp() - interval '169 hours' AS retained_at) AS expired_time;
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_generation_retention_p(2);
COMMIT;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.board_generations
      WHERE id IN (
        'a4390000-0000-4000-8000-00000000001a',
        'a4390000-0000-4000-8000-00000000001b',
        'a4390000-0000-4000-8000-00000000001c'
      )) <> 1
    OR (SELECT count(*) FROM public.board_generation_retention
      WHERE generation_id IN (
        'a4390000-0000-4000-8000-00000000001a',
        'a4390000-0000-4000-8000-00000000001b',
        'a4390000-0000-4000-8000-00000000001c'
      )) <> 1 THEN
    RAISE EXCEPTION 'Generation retention cleanup exceeded its per-call row limit';
  END IF;
END;
$$;
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_generation_retention_p(1);
COMMIT;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.board_generations
      WHERE id IN (
        'a4390000-0000-4000-8000-00000000001a',
        'a4390000-0000-4000-8000-00000000001b',
        'a4390000-0000-4000-8000-00000000001c'
      )) THEN
    RAISE EXCEPTION 'Generation retention cleanup did not finish the bounded backlog';
  END IF;
END;
$$;

-- Expired unconfirmed previews are removed by the service cleanup worker.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'expired_preview', public.prepare_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000009', repeat('9', 64),
  '{"columns":[{"title":"Vencida","position":0,"tasks":[]}]}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
COMMIT;
UPDATE public.board_import_operations
SET created_at = clock_timestamp() - interval '2 hours',
    expires_at = clock_timestamp() - interval '1 hour'
WHERE operation_id = 'a4360000-0000-4000-8000-000000000009';
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_import_operations_p(50);
COMMIT;
DO $$
DECLARE
  fixture public.issue43_import_fixture%ROWTYPE;
  generation_id uuid;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  SELECT operation.generation_id INTO STRICT generation_id
  FROM public.board_import_operations AS operation
  WHERE operation.operation_id = 'a4360000-0000-4000-8000-000000000009';
  IF (SELECT status FROM public.board_import_operations
      WHERE operation_id = 'a4360000-0000-4000-8000-000000000009') <> 'expired'
    OR EXISTS (SELECT 1 FROM public.board_generations WHERE id = generation_id) THEN
    RAISE EXCEPTION 'Expired preparation was not removed safely';
  END IF;
END;
$$;
-- Once the seven-day retention expires, attachment bytes remain counted while
-- Storage cleanup is pending, then the archived generation can be deleted.
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4300000-0000-4000-8000-000000000001', true);
INSERT INTO public.issue43_import_results(name, result)
SELECT 'expire_previous', public.prepare_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000008', repeat('e', 64),
  '{"columns":[]}'::jsonb
) FROM public.issue43_import_fixture AS fixture;
INSERT INTO public.issue43_import_results(name, result)
SELECT 'expire_previous_confirm', public.confirm_board_import_p(
  fixture.slug, 'a4360000-0000-4000-8000-000000000008',
  (SELECT (result->>'content_revision')::bigint FROM public.issue43_import_results WHERE name = 'expire_previous'),
  repeat('e', 64)
) FROM public.issue43_import_fixture AS fixture;
COMMIT;
UPDATE public.board_generation_retention AS retention
SET retained_at = expired_time.retained_at,
    expires_at = expired_time.retained_at + interval '168 hours'
FROM (SELECT clock_timestamp() - interval '169 hours' AS retained_at) AS expired_time
WHERE retention.generation_id = (SELECT old_generation_id FROM public.issue43_import_fixture);
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_generation_retention_p(50);
COMMIT;
DO $$
DECLARE fixture public.issue43_import_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  IF (SELECT state FROM public.task_attachments WHERE id = fixture.attachment_id) <> 'cleanup_pending'
    OR (SELECT pending_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 12
    OR NOT EXISTS (SELECT 1 FROM public.board_generation_retention
      WHERE generation_id = fixture.old_generation_id) THEN
    RAISE EXCEPTION 'Expired-generation attachments were not retained in quota during Storage cleanup';
  END IF;
END;
$$;

-- Keep receipts inside the seven-day replay window; delete terminal receipts after it.
UPDATE public.board_import_operations
SET created_at = clock_timestamp() - interval '170 hours',
    expires_at = clock_timestamp() - interval '169 hours',
    confirmed_at = clock_timestamp() - interval '167 hours'
WHERE operation_id = 'a4360000-0000-4000-8000-000000000003';
UPDATE public.board_import_operations
SET created_at = clock_timestamp() - interval '170 hours',
    expires_at = clock_timestamp() - interval '169 hours'
WHERE operation_id = 'a4360000-0000-4000-8000-000000000009';
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_import_operations_p(50);
COMMIT;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.board_import_operations
      WHERE operation_id = 'a4360000-0000-4000-8000-000000000003')
    OR EXISTS (SELECT 1 FROM public.board_import_operations
      WHERE operation_id = 'a4360000-0000-4000-8000-000000000009') THEN
    RAISE EXCEPTION 'Receipt cleanup did not preserve the live window and remove expired rows';
  END IF;
END;
$$;
UPDATE public.board_import_operations
SET confirmed_at = clock_timestamp() - interval '169 hours'
WHERE operation_id = 'a4360000-0000-4000-8000-000000000003';
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_import_operations_p(50);
COMMIT;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.board_import_operations
      WHERE operation_id = 'a4360000-0000-4000-8000-000000000003') THEN
    RAISE EXCEPTION 'Confirmed import receipt remained after its seven-day retention';
  END IF;
END;
$$;
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.confirm_task_attachment_purge_p(
  attachment.attachment_id, 'a4380000-0000-4000-8000-000000000001', true
)
FROM public.claim_expired_task_attachment_cleanup_p(
  'a4380000-0000-4000-8000-000000000001', 50
) AS attachment
WHERE attachment.attachment_id = 'a4340000-0000-4000-8000-000000000001';
SELECT public.cleanup_expired_board_generation_retention_p(50);
COMMIT;
DO $$
DECLARE fixture public.issue43_import_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue43_import_fixture;
  IF (SELECT state FROM public.task_attachments WHERE id = fixture.attachment_id) <> 'purged'
    OR EXISTS (SELECT 1 FROM public.board_generations WHERE id = fixture.old_generation_id)
    OR EXISTS (SELECT 1 FROM public.board_generation_retention
      WHERE generation_id = fixture.old_generation_id)
    OR (SELECT pending_bytes FROM public.task_attachment_quota_ledger WHERE singleton) <> 0 THEN
    RAISE EXCEPTION 'Expired archived generation or attachment quota did not clean up';
  END IF;
END;
$$;
