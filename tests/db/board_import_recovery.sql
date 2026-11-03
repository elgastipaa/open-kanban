\echo 'Testing restore of retained import generations'

DO $$
BEGIN
  IF pg_catalog.has_table_privilege(
      'authenticated', 'public.board_generation_notification_epochs', 'SELECT'
    ) OR pg_catalog.has_function_privilege(
      'authenticated',
      'public.task_notification_matches_active_generation_epoch_p(uuid,uuid,uuid)',
      'EXECUTE'
    ) THEN
    RAISE EXCEPTION 'notification activation epochs are exposed to authenticated clients';
  END IF;
END;
$$;

UPDATE public.application_access AS access
SET state = 'active'
FROM public.issue44_import_fixture AS fixture
WHERE access.auth_user_id = fixture.owner_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  result jsonb;
  retained jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  result := public.list_board_import_recoveries_p(fixture.slug);
  IF result->>'status' <> 'ok'
    OR result->'current_board'->>'name' <> 'Respaldo completo'
    OR result->'current_board'->>'time_zone' <> 'America/Argentina/Buenos_Aires'
    OR (result->'capacity'->>'used_bytes')::bigint <> 9
    OR (result->'capacity'->>'limit_bytes')::bigint <> 200000000
    OR jsonb_array_length(result->'recoveries') <> 1 THEN
    RAISE EXCEPTION 'owner could not list retained import generations: %', result;
  END IF;
  retained := result->'recoveries'->0;
  IF retained->>'generation_id' <> fixture.old_generation_id::text
    OR retained->>'restorable' <> 'true'
    OR retained->'board'->>'name' <> 'Destino previo'
    OR retained->'board'->>'time_zone' <> 'UTC'
    OR (retained->'content'->>'tasks')::integer <> 1
    OR (retained->'content'->>'attachments')::integer <> 1
    OR (retained->'content'->>'attachment_bytes')::bigint <> 5 THEN
    RAISE EXCEPTION 'retained snapshot or summary was incomplete: %', retained;
  END IF;
END;
$$;
COMMIT;

CREATE TABLE public.issue45_restore_fixture (
  board_id uuid NOT NULL,
  slug text NOT NULL,
  owner_id uuid NOT NULL,
  collaborator_id uuid NOT NULL,
  older_generation_id uuid NOT NULL,
  restore_generation_id uuid NOT NULL,
  current_generation_id uuid NOT NULL,
  stale_preview_operation_id uuid NOT NULL,
  current_preview_operation_id uuid NOT NULL,
  notification_id uuid NOT NULL,
  notification_snapshot jsonb,
  notification_epoch uuid,
  restored_notification_epoch uuid,
  preview_revision bigint,
  capacity_result jsonb,
  confirmed_result jsonb,
  repeated_result jsonb,
  wrong_target_result jsonb,
  notifications_before bigint,
  expired_preview_revision bigint
);
GRANT SELECT, INSERT, UPDATE ON public.issue45_restore_fixture
  TO authenticated, service_role;

INSERT INTO public.task_notifications(
  id, board_id, generation_id, task_id, source_kind, source_id,
  recipient_user_id, recipient_membership_id, reason_codes, actor_name,
  occurred_at, state, delivered_at
)
SELECT 'a4550000-0000-4000-8000-000000000000', fixture.board_id,
  fixture.published_generation_id, task.id, 'task_change',
  'a4550000-0000-4000-8000-00000000000a', fixture.owner_id, membership.id,
  ARRAY['assignment']::text[], 'Colaborador sintético',
  pg_catalog.clock_timestamp() - interval '1 minute', 'delivered',
  pg_catalog.clock_timestamp() - interval '1 minute'
FROM public.issue44_import_fixture AS fixture
JOIN public.boards AS board ON board.id = fixture.board_id
JOIN public.columns AS column_row
  ON column_row.board_id = fixture.board_id
  AND column_row.generation_id = fixture.published_generation_id
JOIN public.tasks AS task
  ON task.column_id = column_row.id AND task.title = 'Tarea importada'
JOIN public.board_memberships AS membership
  ON membership.board_id = fixture.board_id
  AND membership.user_id = fixture.owner_id
  AND membership.role = 'owner' AND membership.revoked_at IS NULL
WHERE board.active_generation_id = fixture.published_generation_id
LIMIT 1;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.task_notifications
      WHERE id = 'a4550000-0000-4000-8000-000000000000') THEN
    RAISE EXCEPTION 'the synthetic pre-import notification fixture was not created';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  import_preview jsonb;
  import_result jsonb;
  restore_preview jsonb;
  restore_operation uuid := 'a4550000-0000-4000-8000-000000000001';
  stale_preview_operation uuid := 'a4550000-0000-4000-8000-000000000002';
  source_hash text := repeat('d', 64);
  document jsonb := pg_catalog.jsonb_build_object(
    'columns', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'title', 'Columna posterior', 'position', 0,
      'tasks', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'title', 'Trabajo posterior', 'description', 'Contenido sintético nuevo',
        'priority', 'medium', 'position', 0
      ))
    ))
  );
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  import_preview := public.prepare_board_import_p(
    fixture.slug, restore_operation, source_hash, document
  );
  IF import_preview->>'status' <> 'prepared' THEN
    RAISE EXCEPTION 'successive synthetic import did not prepare: %', import_preview;
  END IF;
  import_result := public.confirm_board_import_p(
    fixture.slug, restore_operation,
    (import_preview->>'content_revision')::bigint, source_hash
  );
  IF import_result->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'successive synthetic import did not publish: %', import_result;
  END IF;

  INSERT INTO public.issue45_restore_fixture(
    board_id, slug, owner_id, collaborator_id, older_generation_id,
    restore_generation_id, current_generation_id, stale_preview_operation_id,
    current_preview_operation_id, notification_id, notification_snapshot,
    notification_epoch, notifications_before
  ) VALUES (
    fixture.board_id, fixture.slug, fixture.owner_id, fixture.collaborator_id,
    fixture.old_generation_id, fixture.published_generation_id,
    (SELECT board.active_generation_id FROM public.boards AS board
      WHERE board.id = fixture.board_id),
    stale_preview_operation, 'a4550000-0000-4000-8000-000000000003',
    'a4550000-0000-4000-8000-000000000000',
    NULL, NULL, 0
  );
  PERFORM public.rename_board_p(fixture.slug, 'Trabajo posterior');
  PERFORM public.update_board_time_zone_p(
    fixture.slug, 'America/Argentina/Buenos_Aires', 'UTC'
  );

  restore_preview := public.prepare_board_import_restore_p(
    fixture.slug, fixture.published_generation_id, stale_preview_operation
  );
  IF restore_preview->>'status' <> 'ready'
    OR restore_preview->>'restored_generation_id' <> fixture.published_generation_id::text
    OR restore_preview->>'replaced_generation_id'
      <> (SELECT board.active_generation_id::text FROM public.boards AS board
        WHERE board.id = fixture.board_id)
    OR restore_preview->'restored_board'->>'name' <> 'Respaldo completo'
    OR restore_preview->'restored_board'->>'time_zone'
      <> 'America/Argentina/Buenos_Aires'
    OR restore_preview->'current_board'->>'name' <> 'Trabajo posterior'
    OR restore_preview->'current_board'->>'time_zone' <> 'UTC'
    OR (restore_preview->'restored'->>'tasks')::integer <> 2
    OR (restore_preview->'restored'->>'attachments')::integer <> 1
    OR (restore_preview->'restored'->>'attachment_bytes')::bigint <> 4
    OR (restore_preview->'current'->>'tasks')::integer <> 1
    OR (restore_preview->'capacity'->>'used_bytes')::bigint <> 9
    OR (restore_preview->'capacity'->>'limit_bytes')::bigint <> 200000000
    OR restore_preview->'capacity'->>'can_replace' <> 'true' THEN
    RAISE EXCEPTION 'restore preview omitted the retained generation, replacement or capacity: %',
      restore_preview;
  END IF;
  UPDATE public.issue45_restore_fixture
  SET preview_revision = (restore_preview->>'content_revision')::bigint;
END;
$$;
COMMIT;

UPDATE public.issue45_restore_fixture AS fixture
SET notification_snapshot = pg_catalog.to_jsonb(notice),
    notification_epoch = notice.generation_notification_epoch,
    notifications_before = (
      SELECT count(*) FROM public.task_notifications AS board_notice
      WHERE board_notice.board_id = fixture.board_id
    )
FROM public.task_notifications AS notice
WHERE notice.id = fixture.notification_id;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue45_restore_fixture%ROWTYPE;
  stale_result jsonb;
  fresh_preview jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  PERFORM public.rename_board_p(fixture.slug, 'Cambio posterior a la vista previa');
  stale_result := public.confirm_board_import_restore_p(
    fixture.slug, fixture.restore_generation_id, fixture.stale_preview_operation_id,
    fixture.preview_revision
  );
  IF stale_result->>'status' <> 'conflict'
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
      <> fixture.current_generation_id THEN
    RAISE EXCEPTION 'stale restore preview changed the published generation: %', stale_result;
  END IF;

  fresh_preview := public.prepare_board_import_restore_p(
    fixture.slug, fixture.restore_generation_id, fixture.current_preview_operation_id
  );
  IF fresh_preview->>'status' <> 'ready'
    OR fresh_preview->'current_board'->>'name' <> 'Cambio posterior a la vista previa'
    OR fresh_preview->'restored_board'->>'name' <> 'Respaldo completo'
    OR (fresh_preview->>'content_revision')::bigint <= fixture.preview_revision THEN
    RAISE EXCEPTION 'new content version did not require and produce a fresh preview: %', fresh_preview;
  END IF;
  UPDATE public.issue45_restore_fixture
  SET preview_revision = (fresh_preview->>'content_revision')::bigint;
END;
$$;
COMMIT;

BEGIN;
UPDATE public.task_attachment_quota_ledger
SET active_bytes = limit_bytes + 1
WHERE singleton;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue45_restore_fixture%ROWTYPE;
  v_capacity_result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  v_capacity_result := public.confirm_board_import_restore_p(
    fixture.slug, fixture.restore_generation_id,
    fixture.current_preview_operation_id, fixture.preview_revision
  );
  IF v_capacity_result->>'status' <> 'capacity'
    THEN
    RAISE EXCEPTION 'insufficient quota partially published a restore: %', v_capacity_result;
  END IF;
  UPDATE public.issue45_restore_fixture
  SET capacity_result = v_capacity_result;
END;
$$;
COMMIT;

DO $$
DECLARE fixture public.issue45_restore_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  IF fixture.capacity_result->>'status' <> 'capacity'
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
      <> fixture.current_generation_id
    OR NOT EXISTS (SELECT 1 FROM public.board_generation_retention AS retention
      WHERE retention.board_id = fixture.board_id
        AND retention.generation_id = fixture.restore_generation_id) THEN
    RAISE EXCEPTION 'insufficient quota partially published a restore: %', fixture.capacity_result;
  END IF;
END;
$$;

BEGIN;
UPDATE public.task_attachment_quota_ledger SET active_bytes = 9 WHERE singleton;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue45_restore_fixture%ROWTYPE;
  confirmed jsonb;
  repeated jsonb;
  wrong_target jsonb;
  retained jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  confirmed := public.confirm_board_import_restore_p(
    fixture.slug, fixture.restore_generation_id,
    fixture.current_preview_operation_id, fixture.preview_revision
  );
  repeated := public.confirm_board_import_restore_p(
    fixture.slug, fixture.restore_generation_id,
    fixture.current_preview_operation_id, fixture.preview_revision
  );
  wrong_target := public.confirm_board_import_restore_p(
    fixture.slug, fixture.older_generation_id,
    fixture.current_preview_operation_id, fixture.preview_revision
  );
  IF confirmed->>'status' <> 'confirmed'
    OR repeated IS DISTINCT FROM confirmed
    OR wrong_target->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'restore receipt or idempotent replay was incorrect: confirmed %, replay %, wrong target %',
      confirmed, repeated, wrong_target;
  END IF;
  UPDATE public.issue45_restore_fixture
  SET confirmed_result = confirmed,
      repeated_result = repeated,
      wrong_target_result = wrong_target;
END;
$$;
COMMIT;

UPDATE public.issue45_restore_fixture AS fixture
SET restored_notification_epoch = epoch.notification_epoch
FROM public.board_generation_notification_epochs AS epoch
WHERE epoch.board_id = fixture.board_id
  AND epoch.generation_id = fixture.restore_generation_id;

INSERT INTO public.task_notifications(
  id, board_id, generation_id, task_id, source_kind, source_id,
  recipient_user_id, recipient_membership_id, reason_codes, actor_name,
  occurred_at, state, delivered_at
)
SELECT 'a4550000-0000-4000-8000-000000000011', fixture.board_id,
  fixture.restore_generation_id, task.id, 'task_change',
  'a4550000-0000-4000-8000-00000000000b', fixture.owner_id, membership.id,
  ARRAY['assignment']::text[], 'Colaborador actual',
  pg_catalog.clock_timestamp(), 'delivered', pg_catalog.clock_timestamp()
FROM public.issue45_restore_fixture AS fixture
JOIN public.columns AS column_row
  ON column_row.board_id = fixture.board_id
  AND column_row.generation_id = fixture.restore_generation_id
JOIN public.tasks AS task
  ON task.column_id = column_row.id AND task.title = 'Tarea importada'
JOIN public.board_memberships AS membership
  ON membership.board_id = fixture.board_id
  AND membership.user_id = fixture.owner_id
  AND membership.role = 'owner' AND membership.revoked_at IS NULL
LIMIT 1;

DO $$
DECLARE
  fixture public.issue45_restore_fixture%ROWTYPE;
  retained jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  IF (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
      <> fixture.restore_generation_id
    OR (SELECT status FROM public.board_generations
      WHERE board_id = fixture.board_id AND id = fixture.restore_generation_id) <> 'active'
    OR (SELECT status FROM public.board_generations
      WHERE board_id = fixture.board_id AND id = fixture.current_generation_id) <> 'archived'
    OR EXISTS (SELECT 1 FROM public.board_generation_retention AS retention
      WHERE retention.board_id = fixture.board_id
        AND retention.generation_id = fixture.restore_generation_id)
    OR (SELECT name FROM public.boards WHERE id = fixture.board_id) <> 'Respaldo completo'
    OR (SELECT time_zone FROM public.boards WHERE id = fixture.board_id)
      <> 'America/Argentina/Buenos_Aires'
    OR (SELECT revision FROM public.board_content_revisions
      WHERE board_id = fixture.board_id) <> fixture.preview_revision + 1 THEN
    RAISE EXCEPTION 'restore publication mismatch: active %, expected %, target status %, replaced status %, header % / %, revision % expected %',
      (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id),
      fixture.restore_generation_id,
      (SELECT status FROM public.board_generations
        WHERE board_id = fixture.board_id AND id = fixture.restore_generation_id),
      (SELECT status FROM public.board_generations
        WHERE board_id = fixture.board_id AND id = fixture.current_generation_id),
      (SELECT name FROM public.boards WHERE id = fixture.board_id),
      (SELECT time_zone FROM public.boards WHERE id = fixture.board_id),
      (SELECT revision FROM public.board_content_revisions WHERE board_id = fixture.board_id),
      fixture.preview_revision + 1;
  END IF;
  IF fixture.confirmed_result IS DISTINCT FROM fixture.repeated_result
    OR fixture.wrong_target_result->>'status' <> 'unavailable'
    OR fixture.restored_notification_epoch IS NULL
    OR fixture.notification_epoch IS NOT DISTINCT FROM fixture.restored_notification_epoch
    OR (SELECT epoch.notification_epoch
      FROM public.board_generation_notification_epochs AS epoch
      WHERE epoch.board_id = fixture.board_id
        AND epoch.generation_id = fixture.restore_generation_id)
      IS DISTINCT FROM fixture.restored_notification_epoch THEN
    RAISE EXCEPTION 'restore operation ID replay accepted a different target';
  END IF;
  IF (SELECT status FROM public.board_generations
      WHERE board_id = fixture.board_id AND id = fixture.older_generation_id) <> 'archived'
    OR NOT EXISTS (SELECT 1 FROM public.board_generation_retention AS retention
      WHERE retention.board_id = fixture.board_id
        AND retention.generation_id = fixture.older_generation_id)
    OR NOT EXISTS (SELECT 1 FROM public.board_generation_retention AS retention
      WHERE retention.board_id = fixture.board_id
        AND retention.generation_id = fixture.current_generation_id
        AND retention.replacement_generation_id = fixture.restore_generation_id
        AND retention.expires_at = retention.retained_at + interval '168 hours') THEN
    RAISE EXCEPTION 'restore purged an earlier backup or failed to retain the replaced generation';
  END IF;
  retained := public.board_import_generation_summary_p(
    fixture.board_id, fixture.restore_generation_id
  );
  IF (retained->>'tasks')::integer <> 2
    OR (retained->>'attachments')::integer <> 1
    OR (retained->>'attachment_bytes')::bigint <> 4
    OR (SELECT count(*) FROM public.task_attachments AS attachment
      JOIN public.tasks AS task ON task.id = attachment.task_id
      JOIN public.columns AS column_row ON column_row.id = task.column_id
      WHERE column_row.board_id = fixture.board_id
        AND column_row.generation_id = fixture.restore_generation_id
        AND attachment.state = 'active') <> 1 THEN
    RAISE EXCEPTION 'restore failed to reuse the original content generation and attachment';
  END IF;
  IF (SELECT count(*) FROM public.board_memberships WHERE board_id = fixture.board_id) <> 2
    OR (SELECT owner_id FROM public.boards WHERE id = fixture.board_id) <> fixture.owner_id
    OR (SELECT count(*) FROM public.task_notifications WHERE board_id = fixture.board_id)
      <> fixture.notifications_before + 1
    OR (SELECT pg_catalog.to_jsonb(notice) FROM public.task_notifications AS notice
      WHERE notice.id = fixture.notification_id) IS DISTINCT FROM fixture.notification_snapshot THEN
    RAISE EXCEPTION 'restore changed current memberships or mutated prior notifications';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue45_restore_fixture%ROWTYPE;
  inbox jsonb;
  target jsonb;
  marked jsonb;
  batch jsonb;
  batch_replay jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  inbox := public.list_my_task_notifications_p('all', 30, NULL, NULL);
  target := public.get_my_task_notification_target_p(fixture.notification_id);
  marked := public.mark_my_task_notification_read_p(fixture.notification_id);
  batch := public.mark_my_task_notifications_batch_p(
    'a4550000-0000-4000-8000-000000000012', ARRAY[fixture.notification_id], false
  );
  batch_replay := public.mark_my_task_notifications_batch_p(
    'a4550000-0000-4000-8000-000000000012', ARRAY[fixture.notification_id], false
  );
  IF inbox->>'status' <> 'available'
    OR inbox->>'unread_count' <> '1'
    OR EXISTS (SELECT 1 FROM jsonb_array_elements(inbox->'items') AS item
      WHERE item.value->>'id' = fixture.notification_id::text)
    OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(inbox->'items') AS item
      WHERE item.value->>'id' = 'a4550000-0000-4000-8000-000000000011')
    OR target->>'status' <> 'unavailable'
    OR marked->>'status' <> 'unavailable'
    OR batch->'items'->0->>'result' <> 'unavailable'
    OR batch_replay IS DISTINCT FROM batch THEN
    RAISE EXCEPTION 'restoring a generation exposed or changed an old notification; inbox %, target %, mark %, batch %, replay %',
      inbox, target, marked, batch, batch_replay;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE fixture public.issue45_restore_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  IF (SELECT pg_catalog.to_jsonb(notice) FROM public.task_notifications AS notice
      WHERE notice.id = fixture.notification_id) IS DISTINCT FROM fixture.notification_snapshot THEN
    RAISE EXCEPTION 'restore or inbox replay altered the pre-import notification row';
  END IF;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  fixture public.issue44_import_fixture%ROWTYPE;
  result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue44_import_fixture;
  result := public.list_board_import_recoveries_p(fixture.slug);
  IF result->>'status' <> 'unavailable' THEN
    RAISE EXCEPTION 'a collaborator could inspect retained imports: %', result;
  END IF;
END;
$$;
COMMIT;

DO $$
DECLARE fixture public.issue45_restore_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  UPDATE public.board_generation_retention AS retention
  SET retained_board_name = NULL, retained_time_zone = NULL
  WHERE retention.board_id = fixture.board_id
    AND retention.generation_id = fixture.older_generation_id;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue45_restore_fixture%ROWTYPE;
  result jsonb;
  legacy jsonb;
  current_preview jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  result := public.list_board_import_recoveries_p(fixture.slug);
  SELECT item.value INTO STRICT legacy
  FROM jsonb_array_elements(result->'recoveries') AS item(value)
  WHERE item.value->>'generation_id' = fixture.older_generation_id::text;
  IF legacy->>'restorable' <> 'false'
    OR legacy->>'reason' <> 'metadata_unavailable'
    OR legacy->'board' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'legacy recovery row implied a historical header that was never captured: %', legacy;
  END IF;
  result := public.prepare_board_import_restore_p(
    fixture.slug, fixture.older_generation_id,
    'a4550000-0000-4000-8000-000000000005'
  );
  IF result->>'status' <> 'metadata_unavailable' THEN
    RAISE EXCEPTION 'legacy recovery target did not fail closed: %', result;
  END IF;

  current_preview := public.prepare_board_import_restore_p(
    fixture.slug, fixture.current_generation_id,
    'a4550000-0000-4000-8000-000000000006'
  );
  IF current_preview->>'status' <> 'ready'
    OR current_preview->'restored_board'->>'name'
      <> 'Cambio posterior a la vista previa' THEN
    RAISE EXCEPTION 'the replaced generation did not receive a fresh recovery window: %', current_preview;
  END IF;
  UPDATE public.issue45_restore_fixture
  SET expired_preview_revision = (current_preview->>'content_revision')::bigint;
END;
$$;
COMMIT;

DO $$
DECLARE fixture public.issue45_restore_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  WITH expired AS (
    SELECT pg_catalog.clock_timestamp() - interval '169 hours' AS retained_at
  )
  UPDATE public.board_generation_retention AS retention
  SET retained_at = expired.retained_at,
      expires_at = expired.retained_at + interval '168 hours'
  FROM expired
  WHERE retention.board_id = fixture.board_id
    AND retention.generation_id = fixture.current_generation_id;
END;
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture public.issue45_restore_fixture%ROWTYPE;
  result jsonb;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  result := public.confirm_board_import_restore_p(
    fixture.slug, fixture.current_generation_id,
    'a4550000-0000-4000-8000-000000000006', fixture.expired_preview_revision
  );
  IF result->>'status' <> 'expired'
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
      <> fixture.restore_generation_id THEN
    RAISE EXCEPTION 'a target expired after preview but still became active: %', result;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_generation_retention_p(50);
COMMIT;

DO $$
DECLARE fixture public.issue45_restore_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  IF EXISTS (SELECT 1 FROM public.board_generations
      WHERE board_id = fixture.board_id AND id = fixture.current_generation_id)
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
      <> fixture.restore_generation_id
    OR (SELECT status FROM public.board_generations
      WHERE board_id = fixture.board_id AND id = fixture.older_generation_id) <> 'archived' THEN
    RAISE EXCEPTION 'expired target cleanup mixed generations or removed the active generation';
  END IF;
  WITH old_operation AS (
    SELECT pg_catalog.clock_timestamp() - interval '171 hours' AS created_at
  )
  UPDATE public.board_import_restore_operations AS operation
  SET created_at = old_operation.created_at,
      expires_at = old_operation.created_at + interval '1 hour'
  FROM old_operation
  WHERE operation.operation_id IN (
    'a4550000-0000-4000-8000-000000000005',
    'a4550000-0000-4000-8000-000000000006'
  );
END;
$$;

BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_import_restore_operations_p(50);
COMMIT;

DO $$
DECLARE fixture public.issue45_restore_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  IF EXISTS (SELECT 1 FROM public.board_import_restore_operations AS operation
      WHERE operation.operation_id IN (
        'a4550000-0000-4000-8000-000000000005',
        'a4550000-0000-4000-8000-000000000006'
      ))
    OR (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
      <> fixture.restore_generation_id THEN
    RAISE EXCEPTION 'restore receipt cleanup deleted or changed a board generation';
  END IF;
  UPDATE public.board_import_operations AS operation
  SET confirmed_at = pg_catalog.clock_timestamp() - interval '169 hours'
  WHERE operation.operation_id = 'a4440000-0000-4000-8000-000000000001';
END;
$$;

BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_import_operations_p(50);
COMMIT;

DO $$
DECLARE fixture public.issue45_restore_fixture%ROWTYPE;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue45_restore_fixture;
  IF (SELECT active_generation_id FROM public.boards WHERE id = fixture.board_id)
      <> fixture.restore_generation_id
    OR (SELECT status FROM public.board_generations
      WHERE board_id = fixture.board_id AND id = fixture.restore_generation_id) <> 'active' THEN
    RAISE EXCEPTION 'the prior import cleanup job touched the restored generation';
  END IF;
END;
$$;
