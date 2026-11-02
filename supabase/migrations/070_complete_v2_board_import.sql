-- Import the complete v2 portable package into an invisible generation.
BEGIN;

ALTER TABLE public.board_import_operations
  ADD COLUMN source_version smallint NOT NULL DEFAULT 1
    CHECK (source_version IN (1, 2)),
  ADD COLUMN source_manifest jsonb,
  ADD COLUMN v2_materialized boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT board_import_operations_manifest_shape CHECK (
    (source_version = 1 AND source_manifest IS NULL AND NOT v2_materialized)
    OR (source_version = 2 AND pg_catalog.jsonb_typeof(source_manifest) = 'object')
  );

-- Imported conversations retain their visible author snapshot without
-- assigning an old comment to the current owner.
ALTER TABLE public.task_comments ALTER COLUMN author_id DROP NOT NULL;
-- A package does not prove the identity of a series creator.
ALTER TABLE public.daily_repetition_series ALTER COLUMN created_by DROP NOT NULL;

CREATE TABLE public.board_import_v2_batches (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  entity text NOT NULL CHECK (entity IN (
    'board', 'columns', 'tasks', 'comments', 'labels', 'task_labels',
    'birthdays', 'birthday_labels', 'repetitions', 'repetition_labels',
    'repetition_occurrences', 'activity', 'attachments'
  )),
  batch_index integer NOT NULL CHECK (batch_index BETWEEN 0 AND 10000),
  batch_sha256 bytea NOT NULL CHECK (pg_catalog.octet_length(batch_sha256) = 32),
  record_count integer NOT NULL CHECK (record_count BETWEEN 1 AND 100),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (actor_id, operation_id, entity, batch_index),
  FOREIGN KEY (actor_id, operation_id)
    REFERENCES public.board_import_operations(actor_id, operation_id) ON DELETE CASCADE
);
CREATE TABLE public.board_import_v2_records (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  entity text NOT NULL,
  batch_index integer NOT NULL,
  record_index bigint NOT NULL CHECK (record_index >= 0),
  record jsonb NOT NULL CHECK (pg_catalog.jsonb_typeof(record) = 'object'),
  PRIMARY KEY (actor_id, operation_id, entity, record_index),
  FOREIGN KEY (actor_id, operation_id, entity, batch_index)
    REFERENCES public.board_import_v2_batches(actor_id, operation_id, entity, batch_index)
    ON DELETE CASCADE
);
CREATE INDEX board_import_v2_records_lookup_idx
  ON public.board_import_v2_records(actor_id, operation_id, entity, record_index);

CREATE TABLE public.board_import_v2_refs (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  ref_kind text NOT NULL CHECK (ref_kind IN (
    'board', 'column', 'task', 'comment', 'label', 'birthday',
    'repetition', 'occurrence', 'activity', 'attachment', 'step'
  )),
  source_ref text NOT NULL,
  destination_id uuid NOT NULL DEFAULT pg_catalog.gen_random_uuid(),
  PRIMARY KEY (actor_id, operation_id, source_ref),
  UNIQUE (actor_id, operation_id, destination_id),
  CHECK (source_ref ~ CASE ref_kind
    WHEN 'board' THEN '^board_[0-9a-f]{64}$'
    WHEN 'column' THEN '^column_[0-9a-f]{64}$'
    WHEN 'task' THEN '^task_[0-9a-f]{64}$'
    WHEN 'comment' THEN '^comment_[0-9a-f]{64}$'
    WHEN 'label' THEN '^label_[0-9a-f]{64}$'
    WHEN 'birthday' THEN '^birthday_[0-9a-f]{64}$'
    WHEN 'repetition' THEN '^repetition_[0-9a-f]{64}$'
    WHEN 'occurrence' THEN '^occurrence_[0-9a-f]{64}$'
    WHEN 'activity' THEN '^activity_[0-9a-f]{64}$'
    WHEN 'attachment' THEN '^attachment_[0-9a-f]{64}$'
    WHEN 'step' THEN '^step_[0-9a-f]{64}$'
  END),
  FOREIGN KEY (actor_id, operation_id)
    REFERENCES public.board_import_operations(actor_id, operation_id) ON DELETE CASCADE
);

CREATE TABLE public.board_import_v2_objects (
  actor_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  attachment_id uuid NOT NULL,
  source_ref text NOT NULL,
  object_key text NOT NULL,
  uploaded boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.clock_timestamp(),
  PRIMARY KEY (actor_id, operation_id, attachment_id),
  UNIQUE (actor_id, operation_id, source_ref),
  FOREIGN KEY (actor_id, operation_id)
    REFERENCES public.board_import_operations(actor_id, operation_id) ON DELETE CASCADE
);

ALTER TABLE public.board_import_v2_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_import_v2_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_import_v2_refs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.board_import_v2_objects ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_import_v2_batches,
  public.board_import_v2_records, public.board_import_v2_refs,
  public.board_import_v2_objects FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_import_v2_target_id_p(
  p_actor_id uuid, p_operation_id uuid, p_source_ref text, p_ref_kind text
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT reference.destination_id
  FROM public.board_import_v2_refs AS reference
  WHERE reference.actor_id = p_actor_id
    AND reference.operation_id = p_operation_id
    AND reference.source_ref = p_source_ref
    AND reference.ref_kind = p_ref_kind;
$$;
REVOKE ALL ON FUNCTION public.board_import_v2_target_id_p(uuid, uuid, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_import_v2_steps_p(
  p_actor_id uuid, p_operation_id uuid, p_steps jsonb
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'id', public.board_import_v2_target_id_p(
        p_actor_id, p_operation_id, step.value->>'id', 'step'
      ),
      'text', step.value->>'text',
      'is_completed', (step.value->>'is_completed')::boolean,
      'position', (step.value->>'position')::integer,
      'version', 1
    ) ORDER BY step.ordinality
  ), '[]'::jsonb)
  FROM pg_catalog.jsonb_array_elements(p_steps)
    WITH ORDINALITY AS step(value, ordinality);
$$;
REVOKE ALL ON FUNCTION public.board_import_v2_steps_p(uuid, uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.board_import_preview_result_p(
  p_operation public.board_import_operations,
  p_revision bigint
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT pg_catalog.jsonb_build_object(
    'status', p_operation.status,
    'operation_id', p_operation.operation_id,
    'content_revision', p_revision,
    'source_sha256', p_operation.source_sha256,
    'expires_at', p_operation.expires_at,
    'current', public.board_import_generation_summary_p(
      p_operation.board_id, p_operation.base_generation_id
    ),
    'imported', public.board_import_generation_summary_p(
      p_operation.board_id, p_operation.generation_id
    ),
    'capacity', public.board_import_capacity_snapshot_p(),
    'retains_current_members', true,
    'source_version', p_operation.source_version,
    'time_zone', COALESCE(p_operation.source_manifest #>> '{calendar,time_zone}', 'UTC'),
    'member_refs', '[]'::jsonb,
    'members', '[]'::jsonb
  );
$$;
REVOKE ALL ON FUNCTION public.board_import_preview_result_p(
  public.board_import_operations, bigint
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.prepare_board_import_v2_p(
  p_slug text, p_operation_id uuid, p_source_sha256 text, p_manifest jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_operation public.board_import_operations%ROWTYPE;
  v_revision bigint;
  v_expected_paths text[] := ARRAY[
    'data/board.json', 'data/columns.ndjson', 'data/tasks.ndjson',
    'data/comments.ndjson', 'data/labels.ndjson', 'data/task-labels.ndjson',
    'data/birthdays.ndjson', 'data/birthday-labels.ndjson',
    'data/repetitions.ndjson', 'data/repetition-labels.ndjson',
    'data/repetition-occurrences.ndjson', 'data/activity.ndjson',
    'data/attachments.ndjson'
  ];
  v_file_count integer;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_slug = '' OR p_operation_id IS NULL
    OR p_source_sha256 IS NULL OR p_source_sha256 !~ '^[0-9a-f]{64}$'
    OR pg_catalog.jsonb_typeof(p_manifest) IS DISTINCT FROM 'object'
    OR p_manifest->>'format' IS DISTINCT FROM 'openkanban-board'
    OR p_manifest->>'version' IS DISTINCT FROM '2'
    OR pg_catalog.jsonb_typeof(p_manifest->'exported_at') IS DISTINCT FROM 'string'
    OR pg_catalog.length(p_manifest->>'exported_at') NOT BETWEEN 1 AND 100
    OR pg_catalog.jsonb_typeof(p_manifest->'schema_version') IS DISTINCT FROM 'number'
    OR (p_manifest->>'schema_version') !~ '^[1-9][0-9]*$'
    OR p_manifest->>'normalization_version' IS DISTINCT FROM '1'
    OR p_manifest->>'compression' IS DISTINCT FROM 'store'
    OR p_manifest->>'integrity' IS DISTINCT FROM 'sha256'
    OR p_manifest #>> '{identifiers,scope}' IS DISTINCT FROM 'package'
    OR p_manifest #>> '{identifiers,grant_access}' IS DISTINCT FROM 'false'
    OR pg_catalog.jsonb_typeof(p_manifest->'files') IS DISTINCT FROM 'array'
    OR pg_catalog.jsonb_typeof(p_manifest #> '{calendar}') IS DISTINCT FROM 'object'
    OR pg_catalog.jsonb_typeof(p_manifest #> '{identifiers}') IS DISTINCT FROM 'object'
    OR pg_catalog.jsonb_typeof(p_manifest #> '{calendar,time_zone}') IS DISTINCT FROM 'string'
    OR pg_catalog.octet_length(p_manifest::text) > 8000000 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  IF (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(p_manifest)) <> 10
    OR (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(p_manifest->'calendar')) <> 1
    OR (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(p_manifest->'identifiers')) <> 2
    OR (p_manifest->>'schema_version')::numeric > 9007199254740991 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  BEGIN
    PERFORM 1 FROM pg_catalog.pg_timezone_names AS zone
    WHERE zone.name = p_manifest #>> '{calendar,time_zone}';
    IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'invalid'); END IF;
    PERFORM (p_manifest->>'exported_at')::timestamptz;
  EXCEPTION WHEN OTHERS THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END;
  SELECT pg_catalog.count(*) INTO v_file_count
  FROM pg_catalog.jsonb_array_elements(p_manifest->'files') AS file(value)
  WHERE file.value->>'path' = ANY(v_expected_paths);
  IF v_file_count <> pg_catalog.cardinality(v_expected_paths)
    OR (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements(p_manifest->'files'))
      NOT BETWEEN pg_catalog.cardinality(v_expected_paths) AND 24999
    OR (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements(p_manifest->'files'))
      <> (SELECT pg_catalog.count(DISTINCT value->>'path')
          FROM pg_catalog.jsonb_array_elements(p_manifest->'files'))
    OR EXISTS (
      SELECT 1 FROM pg_catalog.jsonb_array_elements(p_manifest->'files') AS file(value)
      WHERE pg_catalog.jsonb_typeof(file.value) IS DISTINCT FROM 'object'
        OR CASE WHEN pg_catalog.jsonb_typeof(file.value) = 'object'
          THEN (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(file.value)) <> 5
          ELSE true END
        OR file.value->>'path' IS NULL
        OR (file.value->>'path' <> ALL(v_expected_paths)
          AND file.value->>'path' !~ '^objects/attachment_[0-9a-f]{64}[.](txt|md)$')
        OR pg_catalog.jsonb_typeof(file.value->'size_bytes') IS DISTINCT FROM 'number'
        OR file.value->>'sha256' !~ '^[0-9a-f]{64}$'
        OR (file.value->>'size_bytes') !~ '^(0|[1-9][0-9]*)$'
        OR CASE
          WHEN (file.value->>'size_bytes') ~ '^(0|[1-9][0-9]*)$'
          THEN (file.value->>'size_bytes')::numeric > CASE
            WHEN file.value->>'path' LIKE 'objects/%' THEN 24000
            ELSE 220000000 END
          ELSE true
        END
        OR (file.value->>'path' = ANY(v_expected_paths)
          AND ((file.value->>'records') !~ '^(0|[1-9][0-9]*)$'
            OR pg_catalog.jsonb_typeof(file.value->'records') IS DISTINCT FROM 'number'
            OR file.value->>'content_type' IS DISTINCT FROM CASE file.value->>'path'
              WHEN 'data/board.json' THEN 'application/json'
              ELSE 'application/x-ndjson'
            END))
        OR (file.value->>'path' LIKE 'objects/%'
          AND (file.value->>'records' IS NOT NULL
            OR file.value->>'content_type' IS DISTINCT FROM 'text/plain; charset=utf-8'))
        OR (file.value->>'path' = 'data/board.json' AND file.value->>'records' <> '1')
    ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  IF (SELECT COALESCE(pg_catalog.sum((file.value->>'size_bytes')::numeric), 0)
      FROM pg_catalog.jsonb_array_elements(p_manifest->'files') AS file(value)) > 220000000 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  PERFORM 1 FROM public.application_access AS access
  WHERE access.auth_user_id = v_actor_id AND access.state = 'active'
  FOR SHARE;
  IF NOT FOUND OR NOT public.is_application_user() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND OR v_board.owner_id IS DISTINCT FROM v_actor_id
    OR NOT public.is_board_owner(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_board.id FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF v_operation.board_id <> v_board.id OR v_operation.source_version <> 2
      OR v_operation.source_sha256 <> p_source_sha256
      OR v_operation.source_manifest IS DISTINCT FROM p_manifest THEN
      RETURN pg_catalog.jsonb_build_object('status', 'conflict');
    END IF;
    IF v_operation.status = 'prepared' THEN
      RETURN public.board_import_preview_result_p(v_operation, v_revision);
    END IF;
    IF v_operation.status = 'confirmed' THEN RETURN v_operation.result; END IF;
    IF v_operation.status = 'staging' AND v_operation.expires_at > pg_catalog.clock_timestamp() THEN
      RETURN pg_catalog.jsonb_build_object('status', 'staging');
    END IF;
    RETURN pg_catalog.jsonb_build_object('status', v_operation.status);
  END IF;
  INSERT INTO public.board_generations(id, board_id, status, created_by)
  VALUES (pg_catalog.gen_random_uuid(), v_board.id, 'preparing', v_actor_id)
  RETURNING id INTO v_operation.generation_id;
  INSERT INTO public.board_import_operations(
    actor_id, operation_id, board_id, generation_id, base_generation_id,
    expected_content_revision, source_sha256, source_version, source_manifest,
    v2_materialized, status, expires_at
  ) VALUES (
    v_actor_id, p_operation_id, v_board.id, v_operation.generation_id,
    v_board.active_generation_id, v_revision, p_source_sha256, 2, p_manifest,
    false, 'staging', pg_catalog.clock_timestamp() + interval '1 hour'
  );
  RETURN pg_catalog.jsonb_build_object('status', 'staging');
END;
$$;
REVOKE ALL ON FUNCTION public.prepare_board_import_v2_p(text, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.prepare_board_import_v2_p(text, uuid, text, jsonb)
  TO authenticated;

CREATE FUNCTION public.stage_board_import_v2_batch_p(
  p_slug text, p_operation_id uuid, p_entity text, p_batch_index integer, p_records jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_operation public.board_import_operations%ROWTYPE;
  v_board_id uuid;
  v_digest bytea;
  v_record_count integer;
  v_existing public.board_import_v2_batches%ROWTYPE;
  v_total_records bigint;
  v_total_bytes bigint;
  v_batch_bytes bigint;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_operation_id IS NULL OR p_entity IS NULL OR p_entity NOT IN (
      'board', 'columns', 'tasks', 'comments', 'labels', 'task_labels',
      'birthdays', 'birthday_labels', 'repetitions', 'repetition_labels',
      'repetition_occurrences', 'activity', 'attachments'
    ) OR p_batch_index IS NULL OR p_batch_index NOT BETWEEN 0 AND 10000
    OR pg_catalog.jsonb_typeof(p_records) IS DISTINCT FROM 'array' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  v_record_count := pg_catalog.jsonb_array_length(p_records);
  v_batch_bytes := pg_catalog.octet_length(p_records::text);
  IF v_record_count NOT BETWEEN 1 AND 100 OR v_batch_bytes > 262144 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug AND board.owner_id = v_actor_id
    AND public.is_board_owner(board.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
    AND operation.board_id = v_board_id AND operation.source_version = 2
  FOR UPDATE;
  IF NOT FOUND OR v_operation.status <> 'staging'
    OR v_operation.expires_at <= pg_catalog.clock_timestamp()
    OR v_operation.v2_materialized THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  v_digest := extensions.digest(pg_catalog.convert_to(p_records::text, 'UTF8'), 'sha256');
  SELECT batch.* INTO v_existing
  FROM public.board_import_v2_batches AS batch
  WHERE batch.actor_id = v_actor_id AND batch.operation_id = p_operation_id
    AND batch.entity = p_entity AND batch.batch_index = p_batch_index
  FOR UPDATE;
  IF FOUND THEN
    IF v_existing.batch_sha256 = v_digest AND v_existing.record_count = v_record_count THEN
      RETURN pg_catalog.jsonb_build_object('status', 'staging');
    END IF;
    RETURN pg_catalog.jsonb_build_object('status', 'conflict');
  END IF;
  SELECT pg_catalog.count(*), COALESCE(pg_catalog.sum(pg_catalog.octet_length(record.record::text)), 0)
  INTO v_total_records, v_total_bytes
  FROM public.board_import_v2_records AS record
  WHERE record.actor_id = v_actor_id AND record.operation_id = p_operation_id;
  IF v_total_records + v_record_count > 100000 OR v_total_bytes + v_batch_bytes > 220000000 THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  INSERT INTO public.board_import_v2_batches(
    actor_id, operation_id, entity, batch_index, batch_sha256, record_count
  ) VALUES (
    v_actor_id, p_operation_id, p_entity, p_batch_index, v_digest, v_record_count
  );
  INSERT INTO public.board_import_v2_records(
    actor_id, operation_id, entity, batch_index, record_index, record
  )
  SELECT v_actor_id, p_operation_id, p_entity, p_batch_index,
    p_batch_index::bigint * 100 + item.ordinality - 1, item.value
  FROM pg_catalog.jsonb_array_elements(p_records)
    WITH ORDINALITY AS item(value, ordinality);
  RETURN pg_catalog.jsonb_build_object('status', 'staging');
END;
$$;
REVOKE ALL ON FUNCTION public.stage_board_import_v2_batch_p(text, uuid, text, integer, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.stage_board_import_v2_batch_p(text, uuid, text, integer, jsonb)
  TO authenticated;

CREATE FUNCTION public.reserve_board_import_v2_p(p_slug text, p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_operation public.board_import_operations%ROWTYPE;
  v_record jsonb;
  v_file jsonb;
  v_path text;
  v_entity text;
  v_expected bigint;
  v_actual bigint;
  v_target record;
  v_task record;
  v_revision bigint;
  v_targets jsonb;
  v_ledger public.task_attachment_quota_ledger%ROWTYPE;
  v_new_attachment_bytes bigint;
  v_object_count bigint;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_operation_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug AND board.owner_id = v_actor_id
    AND public.is_board_owner(board.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
    AND operation.board_id = v_board.id AND operation.source_version = 2
  FOR UPDATE;
  IF NOT FOUND OR v_operation.expires_at <= pg_catalog.clock_timestamp()
    OR v_operation.status NOT IN ('staging', 'prepared') THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_operation.v2_materialized THEN
    SELECT COALESCE(pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'source_ref', object.source_ref,
        'attachment_id', object.attachment_id,
        'file_name', attachment.file_name,
        'size_bytes', attachment.size_bytes,
        'sha256', pg_catalog.encode(attachment.sha256, 'hex'),
        'object_key', object.object_key,
        'uploaded', object.uploaded
      ) ORDER BY object.attachment_id
    ), '[]'::jsonb) INTO v_targets
    FROM public.board_import_v2_objects AS object
    JOIN public.task_attachments AS attachment ON attachment.id = object.attachment_id
    WHERE object.actor_id = v_actor_id AND object.operation_id = p_operation_id;
    RETURN pg_catalog.jsonb_build_object('status', 'reserved', 'targets', v_targets);
  END IF;
  IF v_operation.status <> 'staging' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;

  FOR v_file IN SELECT value FROM pg_catalog.jsonb_array_elements(v_operation.source_manifest->'files')
  LOOP
    v_path := v_file->>'path';
    v_entity := CASE v_path
      WHEN 'data/board.json' THEN 'board'
      WHEN 'data/columns.ndjson' THEN 'columns'
      WHEN 'data/tasks.ndjson' THEN 'tasks'
      WHEN 'data/comments.ndjson' THEN 'comments'
      WHEN 'data/labels.ndjson' THEN 'labels'
      WHEN 'data/task-labels.ndjson' THEN 'task_labels'
      WHEN 'data/birthdays.ndjson' THEN 'birthdays'
      WHEN 'data/birthday-labels.ndjson' THEN 'birthday_labels'
      WHEN 'data/repetitions.ndjson' THEN 'repetitions'
      WHEN 'data/repetition-labels.ndjson' THEN 'repetition_labels'
      WHEN 'data/repetition-occurrences.ndjson' THEN 'repetition_occurrences'
      WHEN 'data/activity.ndjson' THEN 'activity'
      WHEN 'data/attachments.ndjson' THEN 'attachments'
      ELSE NULL END;
    IF v_entity IS NOT NULL THEN
      v_expected := (v_file->>'records')::bigint;
      SELECT pg_catalog.count(*) INTO v_actual
      FROM public.board_import_v2_records AS record
      WHERE record.actor_id = v_actor_id AND record.operation_id = p_operation_id
        AND record.entity = v_entity;
      IF v_actual <> v_expected THEN
        RETURN pg_catalog.jsonb_build_object('status', 'invalid');
      END IF;
    ELSIF v_path !~ '^objects/attachment_[0-9a-f]{64}[.](txt|md)$'
      OR v_file->>'records' IS NOT NULL THEN
      RETURN pg_catalog.jsonb_build_object('status', 'invalid');
    END IF;
  END LOOP;
  SELECT record.record INTO v_record
  FROM public.board_import_v2_records AS record
  WHERE record.actor_id = v_actor_id AND record.operation_id = p_operation_id
    AND record.entity = 'board' AND record.record_index = 0;
  IF NOT FOUND OR pg_catalog.jsonb_typeof(v_record) IS DISTINCT FROM 'object'
    OR v_record->>'id' !~ '^board_[0-9a-f]{64}$'
    OR pg_catalog.btrim(v_record->>'name') = ''
    OR v_record->>'name' IS DISTINCT FROM pg_catalog.btrim(v_record->>'name')
    OR pg_catalog.length(v_record->>'name') > 100
    OR v_record->>'time_zone' IS DISTINCT FROM v_operation.source_manifest #>> '{calendar,time_zone}' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  SELECT pg_catalog.count(*) INTO v_object_count
  FROM pg_catalog.jsonb_array_elements(v_operation.source_manifest->'files') AS file(value)
  WHERE file.value->>'path' LIKE 'objects/%';
  IF v_object_count <> (
    SELECT pg_catalog.count(*) FROM public.board_import_v2_records AS attachment
    WHERE attachment.actor_id = v_actor_id AND attachment.operation_id = p_operation_id
      AND attachment.entity = 'attachments'
  ) OR EXISTS (
    SELECT 1
    FROM public.board_import_v2_records AS attachment
    WHERE attachment.actor_id = v_actor_id AND attachment.operation_id = p_operation_id
      AND attachment.entity = 'attachments'
      AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.jsonb_array_elements(v_operation.source_manifest->'files') AS file(value)
        WHERE file.value->>'path' = 'objects/' || (attachment.record->>'id') ||
          CASE WHEN pg_catalog.lower(attachment.record->>'file_name') LIKE '%.md' THEN '.md' ELSE '.txt' END
          AND file.value->>'content_type' = 'text/plain; charset=utf-8'
          AND (file.value->>'size_bytes')::bigint = (attachment.record->>'size_bytes')::bigint
          AND file.value->>'sha256' = attachment.record->>'sha256'
      )
  ) OR EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS comment_record
    WHERE comment_record.actor_id = v_actor_id
      AND comment_record.operation_id = p_operation_id
      AND comment_record.entity = 'comments'
      AND NOT EXISTS (
        SELECT 1 FROM public.board_import_v2_records AS task_record
        WHERE task_record.actor_id = v_actor_id
          AND task_record.operation_id = p_operation_id
          AND task_record.entity = 'tasks'
          AND task_record.record->>'id' = comment_record.record->>'task_id'
      )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS record
    WHERE record.actor_id = v_actor_id AND record.operation_id = p_operation_id
      AND record.entity = 'board' AND record.record_index <> 0
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;

  -- Reject dangling relationships before any destination rows are created.
  IF EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS task
    WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id
      AND task.entity = 'tasks'
      AND NOT EXISTS (
        SELECT 1 FROM public.board_import_v2_records AS column_record
        WHERE column_record.actor_id = v_actor_id AND column_record.operation_id = p_operation_id
          AND column_record.entity = 'columns'
          AND column_record.record->>'id' = task.record->>'column_id'
      )
  ) OR EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS relation
    WHERE relation.actor_id = v_actor_id AND relation.operation_id = p_operation_id
      AND ((relation.entity = 'task_labels' AND (
        NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS task
          WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id
            AND task.entity = 'tasks' AND task.record->>'id' = relation.record->>'task_id')
        OR NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS label
          WHERE label.actor_id = v_actor_id AND label.operation_id = p_operation_id
            AND label.entity = 'labels' AND label.record->>'id' = relation.record->>'label_id')
      )) OR (relation.entity = 'birthday_labels' AND (
        NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS birthday
          WHERE birthday.actor_id = v_actor_id AND birthday.operation_id = p_operation_id
            AND birthday.entity = 'birthdays' AND birthday.record->>'id' = relation.record->>'birthday_id')
        OR NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS label
          WHERE label.actor_id = v_actor_id AND label.operation_id = p_operation_id
            AND label.entity = 'labels' AND label.record->>'id' = relation.record->>'label_id')
      )) OR (relation.entity = 'repetition_labels' AND (
        NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS series
          WHERE series.actor_id = v_actor_id AND series.operation_id = p_operation_id
            AND series.entity = 'repetitions' AND series.record->>'id' = relation.record->>'series_id')
        OR NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS label
          WHERE label.actor_id = v_actor_id AND label.operation_id = p_operation_id
            AND label.entity = 'labels' AND label.record->>'id' = relation.record->>'label_id')
      )) OR (relation.entity = 'repetition_occurrences' AND (
        NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS series
          WHERE series.actor_id = v_actor_id AND series.operation_id = p_operation_id
            AND series.entity = 'repetitions' AND series.record->>'id' = relation.record->>'series_id')
        OR NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS task
          WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id
            AND task.entity = 'tasks' AND task.record->>'id' = relation.record->>'task_id')
        OR (relation.record->>'transferred_to_series_id' IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM public.board_import_v2_records AS series
          WHERE series.actor_id = v_actor_id AND series.operation_id = p_operation_id
            AND series.entity = 'repetitions'
            AND series.record->>'id' = relation.record->>'transferred_to_series_id'
        ))
      )))
  ) OR EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS series
    WHERE series.actor_id = v_actor_id AND series.operation_id = p_operation_id
      AND series.entity = 'repetitions'
      AND (NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS task
          WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id
            AND task.entity = 'tasks' AND task.record->>'id' = series.record->>'origin_task_id')
        OR NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS task
          WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id
            AND task.entity = 'tasks' AND task.record->>'id' = series.record->>'first_task_id')
        OR NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS column_record
          WHERE column_record.actor_id = v_actor_id AND column_record.operation_id = p_operation_id
            AND column_record.entity = 'columns'
            AND column_record.record->>'id' = series.record->>'appearance_column_id')
        OR (series.record->>'current_occurrence_id' IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM public.board_import_v2_records AS occurrence
          WHERE occurrence.actor_id = v_actor_id AND occurrence.operation_id = p_operation_id
            AND occurrence.entity = 'repetition_occurrences'
            AND occurrence.record->>'id' = series.record->>'current_occurrence_id'
            AND occurrence.record->>'series_id' = series.record->>'id'
        )))
  ) OR EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS activity
    WHERE activity.actor_id = v_actor_id AND activity.operation_id = p_operation_id
      AND activity.entity = 'activity'
      AND NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS task
        WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id
          AND task.entity = 'tasks' AND task.record->>'id' = activity.record->>'task_id')
  ) OR EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS attachment
    WHERE attachment.actor_id = v_actor_id AND attachment.operation_id = p_operation_id
      AND attachment.entity = 'attachments'
      AND NOT EXISTS (SELECT 1 FROM public.board_import_v2_records AS task
        WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id
          AND task.entity = 'tasks' AND task.record->>'id' = attachment.record->>'task_id')
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;

  -- Lock the same global ledger row used by regular attachment reservations.
  -- Existing active bytes remain charged after the pointer swap and are counted
  -- once; only the incoming package bytes are added here.
  SELECT ledger.* INTO v_ledger
  FROM public.task_attachment_quota_ledger AS ledger
  WHERE ledger.singleton FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT COALESCE(pg_catalog.sum((staged.record->>'size_bytes')::bigint), 0)
  INTO v_new_attachment_bytes
  FROM public.board_import_v2_records AS staged
  WHERE staged.actor_id = v_actor_id AND staged.operation_id = p_operation_id
    AND staged.entity = 'attachments';
  IF v_ledger.active_bytes + v_ledger.recoverable_bytes + v_ledger.reserved_bytes
      + v_ledger.pending_bytes + v_new_attachment_bytes > v_ledger.limit_bytes THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'capacity', 'capacity', public.board_import_capacity_snapshot_p()
    );
  END IF;

  INSERT INTO public.board_import_v2_refs(actor_id, operation_id, ref_kind, source_ref)
  SELECT v_actor_id, p_operation_id, source_refs.ref_kind, source_refs.source_ref
  FROM (
    SELECT 'board'::text AS ref_kind, record->>'id' AS source_ref
      FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'board'
    UNION ALL SELECT 'column', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'columns'
    UNION ALL SELECT 'task', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'tasks'
    UNION ALL SELECT 'comment', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'comments'
    UNION ALL SELECT 'label', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'labels'
    UNION ALL SELECT 'birthday', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'birthdays'
    UNION ALL SELECT 'repetition', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'repetitions'
    UNION ALL SELECT 'occurrence', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'repetition_occurrences'
    UNION ALL SELECT 'activity', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'activity'
    UNION ALL SELECT 'attachment', record->>'id' FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'attachments'
    UNION ALL
    SELECT 'step', step.value->>'id'
    FROM public.board_import_v2_records AS task
    CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(task.record->'steps') AS step(value)
    WHERE task.actor_id = v_actor_id AND task.operation_id = p_operation_id AND task.entity = 'tasks'
    UNION ALL
    SELECT 'step', step.value->>'id'
    FROM public.board_import_v2_records AS series
    CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(series.record #> '{template_snapshot,steps}') AS step(value)
    WHERE series.actor_id = v_actor_id AND series.operation_id = p_operation_id AND series.entity = 'repetitions'
  ) AS source_refs(ref_kind, source_ref);

  INSERT INTO public.board_import_stage_contexts(transaction_id, actor_id, board_id, generation_id)
  VALUES (pg_catalog.txid_current(), v_actor_id, v_board.id, v_operation.generation_id)
  ON CONFLICT DO NOTHING;

  INSERT INTO public.columns(id, board_id, generation_id, title, position, created_at)
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'column'),
    v_board.id, v_operation.generation_id, record->>'title', (record->>'position')::integer,
    (record->>'created_at')::timestamptz
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'columns';

  INSERT INTO public.tasks(
    id, column_id, title, description, priority, position, created_by, assignee_id,
    due_on, is_completed, completed_at, steps, created_at, updated_at
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'task'),
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'column_id', 'column'),
    record->>'title', NULLIF(record->'description', 'null'::jsonb)#>>'{}',
    record->>'priority', (record->>'position')::integer, NULL, NULL,
    NULLIF(record->>'due_on', '')::date, (record->>'is_completed')::boolean,
    NULLIF(record->>'completed_at', '')::timestamptz,
    public.board_import_v2_steps_p(v_actor_id, p_operation_id, record->'steps'),
    (record->>'created_at')::timestamptz, (record->>'updated_at')::timestamptz
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'tasks';

  INSERT INTO public.board_labels(
    id, board_id, generation_id, name, color, created_by, created_at, updated_at
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'label'),
    v_board.id, v_operation.generation_id, record->>'name', record->>'color', NULL,
    (record->>'created_at')::timestamptz, (record->>'updated_at')::timestamptz
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'labels';

  INSERT INTO public.board_birthdays(
    id, board_id, generation_id, name, birth_month, birth_day, advance_days,
    created_by, created_at, updated_at
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'birthday'),
    v_board.id, v_operation.generation_id, record->>'name', (record->>'birth_month')::integer,
    (record->>'birth_day')::integer, NULLIF(record->>'advance_days', '')::integer, NULL,
    (record->>'created_at')::timestamptz, (record->>'updated_at')::timestamptz
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'birthdays';

  INSERT INTO public.board_label_task_assignments(board_id, generation_id, label_id, task_id)
  SELECT v_board.id, v_operation.generation_id,
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'label_id', 'label'),
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'task_id', 'task')
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'task_labels';
  INSERT INTO public.board_label_birthday_assignments(board_id, generation_id, label_id, birthday_id)
  SELECT v_board.id, v_operation.generation_id,
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'label_id', 'label'),
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'birthday_id', 'birthday')
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'birthday_labels';

  INSERT INTO public.task_comments(
    id, board_id, task_id, author_id, author_name, content, created_at, edited_at, version
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'comment'),
    v_board.id, public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'task_id', 'task'),
    NULL,
    CASE WHEN record->>'author_name' LIKE 'Autor importado: %'
      THEN record->>'author_name'
      ELSE 'Autor importado: ' || (record->>'author_name') END,
    record->>'content', (record->>'created_at')::timestamptz,
    NULLIF(record->>'edited_at', '')::timestamptz, (record->>'version')::bigint
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'comments';

  INSERT INTO public.daily_repetition_series(
    id, board_id, generation_id, created_by, origin_task_id, first_task_id,
    appearance_column_id, rule, start_on, end_on, occurrence_limit, consumed_count,
    latest_occurrence_on, current_occurrence_id, next_due_on, state, calendar_pattern,
    advance_days, template_snapshot, created_at, updated_at, stopped_at
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'repetition'),
    v_board.id, v_operation.generation_id, NULL,
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'origin_task_id', 'task'),
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'first_task_id', 'task'),
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'appearance_column_id', 'column'),
    record->>'rule', (record->>'start_on')::date, NULLIF(record->>'end_on', '')::date,
    NULLIF(record->>'occurrence_limit', '')::bigint, (record->>'consumed_count')::bigint,
    (record->>'latest_occurrence_on')::date, NULL,
    NULLIF(record->>'next_due_on', '')::date, record->>'state', record->'calendar_pattern',
    NULLIF(record->>'advance_days', '')::integer,
    pg_catalog.jsonb_build_object(
      'title', record #>> '{template_snapshot,title}',
      'description', record #> '{template_snapshot,description}',
      'priority', record #>> '{template_snapshot,priority}',
      'assignee_id', NULL,
      'steps', public.board_import_v2_steps_p(
        v_actor_id, p_operation_id, record #> '{template_snapshot,steps}'
      ),
      'redacted', record #> '{template_snapshot,redacted}'
    ),
    (record->>'created_at')::timestamptz, (record->>'updated_at')::timestamptz,
    NULLIF(record->>'stopped_at', '')::timestamptz
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'repetitions';

  DELETE FROM public.board_label_repetition_assignments AS assignment
  USING public.daily_repetition_series AS series
  WHERE series.id = assignment.series_id AND series.board_id = v_board.id
    AND series.generation_id = v_operation.generation_id;
  INSERT INTO public.board_label_repetition_assignments(board_id, generation_id, label_id, series_id)
  SELECT v_board.id, v_operation.generation_id,
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'label_id', 'label'),
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'series_id', 'repetition')
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'repetition_labels';

  INSERT INTO public.daily_repetition_occurrences(
    id, series_id, occurrence_on, task_id, state, due_on_override,
    transferred_to_series_id, created_at
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'occurrence'),
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'series_id', 'repetition'),
    (record->>'occurrence_on')::date,
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'task_id', 'task'),
    record->>'state', NULLIF(record->>'due_on_override', '')::date,
    CASE WHEN record->>'transferred_to_series_id' IS NULL THEN NULL ELSE
      public.board_import_v2_target_id_p(v_actor_id, p_operation_id,
        record->>'transferred_to_series_id', 'repetition') END,
    (record->>'created_at')::timestamptz
  FROM public.board_import_v2_records WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'repetition_occurrences';

  UPDATE public.daily_repetition_series AS series
  SET current_occurrence_id = public.board_import_v2_target_id_p(
    v_actor_id, p_operation_id, record.record->>'current_occurrence_id', 'occurrence'
  )
  FROM public.board_import_v2_records AS record
  WHERE record.actor_id = v_actor_id AND record.operation_id = p_operation_id
    AND record.entity = 'repetitions'
    AND record.record->>'current_occurrence_id' IS NOT NULL
    AND series.id = public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record.record->>'id', 'repetition');

  INSERT INTO public.task_activity_events(
    id, board_id, task_id, category, actor_type, actor_name,
    occurred_at, before_value, after_value
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'activity'),
    v_board.id, public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'task_id', 'task'),
    record->>'category', CASE WHEN record->>'actor_type' = 'system' THEN 'system' ELSE 'imported' END,
    CASE WHEN record->>'actor_type' = 'system' THEN NULL ELSE record->>'actor_name' END,
    (record->>'occurred_at')::timestamptz, record->'before_value', record->'after_value'
  FROM public.board_import_v2_records
  WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'activity'
    AND (record->>'occurred_at')::timestamptz >= pg_catalog.clock_timestamp() - interval '180 days';

  IF EXISTS (
    SELECT 1 FROM public.board_import_v2_records AS record
    WHERE record.actor_id = v_actor_id AND record.operation_id = p_operation_id
      AND record.entity = 'attachments'
      AND (record.record->>'file_name' ~ '[[:cntrl:]]'
        OR position('/' in record.record->>'file_name') > 0
        OR position(pg_catalog.chr(92) in record.record->>'file_name') > 0
        OR (SELECT pg_catalog.count(*) FROM public.board_import_v2_records AS per_task
            WHERE per_task.actor_id = v_actor_id AND per_task.operation_id = p_operation_id
              AND per_task.entity = 'attachments'
              AND per_task.record->>'task_id' = record.record->>'task_id') > 20)
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  INSERT INTO public.task_attachments(
    id, board_id, task_id, uploaded_by, upload_operation_id,
    file_name, size_bytes, sha256, object_key, state, created_at,
    reservation_expires_at
  )
  SELECT public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'attachment'),
    v_board.id,
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'task_id', 'task'),
    v_actor_id, pg_catalog.gen_random_uuid(), record->>'file_name',
    (record->>'size_bytes')::integer, pg_catalog.decode(record->>'sha256', 'hex'),
    'attachments/' || public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'attachment')::text,
    'reserved', (record->>'created_at')::timestamptz,
    pg_catalog.clock_timestamp() + interval '1 hour'
  FROM public.board_import_v2_records
  WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'attachments';
  INSERT INTO public.board_import_v2_objects(
    actor_id, operation_id, attachment_id, source_ref, object_key
  )
  SELECT v_actor_id, p_operation_id,
    public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'attachment'),
    record->>'id',
    'attachments/' || public.board_import_v2_target_id_p(v_actor_id, p_operation_id, record->>'id', 'attachment')::text
  FROM public.board_import_v2_records
  WHERE actor_id = v_actor_id AND operation_id = p_operation_id AND entity = 'attachments';

  -- One durable job per active series; the worker uses the board's local day
  -- and advances a stale schedule in one pass instead of replaying a backlog.
  INSERT INTO public.daily_repetition_jobs(
    job_kind, series_id, series_revision, scheduled_on, dedupe_key, available_at
  )
  SELECT 'advance', series.id, series.revision, series.next_due_on,
    pg_catalog.format('advance:%s:%s:%s', series.id, series.revision, series.next_due_on),
    GREATEST(
      series.next_due_on::timestamp AT TIME ZONE (v_record->>'time_zone'),
      pg_catalog.clock_timestamp()
    )
  FROM public.daily_repetition_series AS series
  WHERE series.board_id = v_board.id AND series.generation_id = v_operation.generation_id
    AND series.state = 'active'
  ON CONFLICT (dedupe_key) DO NOTHING;

  DELETE FROM public.board_import_stage_contexts AS context
  WHERE context.transaction_id = pg_catalog.txid_current()
    AND context.generation_id = v_operation.generation_id;
  UPDATE public.board_import_operations AS operation
  SET v2_materialized = true
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;

  SELECT COALESCE(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'source_ref', object.source_ref,
      'attachment_id', object.attachment_id,
      'file_name', attachment.file_name,
      'size_bytes', attachment.size_bytes,
      'sha256', pg_catalog.encode(attachment.sha256, 'hex'),
      'object_key', object.object_key,
      'uploaded', object.uploaded
    ) ORDER BY object.attachment_id
  ), '[]'::jsonb) INTO v_targets
  FROM public.board_import_v2_objects AS object
  JOIN public.task_attachments AS attachment ON attachment.id = object.attachment_id
  WHERE object.actor_id = v_actor_id AND object.operation_id = p_operation_id;
  RETURN pg_catalog.jsonb_build_object('status', 'reserved', 'targets', v_targets);
END;
$$;
REVOKE ALL ON FUNCTION public.reserve_board_import_v2_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reserve_board_import_v2_p(text, uuid)
  TO authenticated;

CREATE FUNCTION public.mark_board_import_v2_object_uploaded_p(
  p_actor_id uuid, p_operation_id uuid, p_attachment_id uuid,
  p_verified_size_bytes integer, p_verified_sha256 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_operation public.board_import_operations%ROWTYPE;
  v_attachment public.task_attachments%ROWTYPE;
BEGIN
  IF p_actor_id IS NULL OR p_operation_id IS NULL OR p_attachment_id IS NULL
    OR p_verified_size_bytes IS NULL OR p_verified_sha256 !~ '^[0-9a-f]{64}$'
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id
    AND operation.source_version = 2 AND operation.status = 'staging'
    AND operation.v2_materialized AND operation.expires_at > pg_catalog.clock_timestamp()
  FOR UPDATE;
  IF NOT FOUND OR NOT EXISTS (
    SELECT 1 FROM public.boards AS board
    JOIN public.board_memberships AS membership
      ON membership.board_id = board.id AND membership.user_id = p_actor_id
      AND membership.role = 'owner' AND membership.revoked_at IS NULL
    WHERE board.id = v_operation.board_id AND board.owner_id = p_actor_id
      AND NOT EXISTS (
        SELECT 1 FROM public.board_recoverable_deletions AS deletion
        WHERE deletion.board_id = board.id
      )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT attachment.* INTO v_attachment
  FROM public.task_attachments AS attachment
  JOIN public.board_import_v2_objects AS object
    ON object.actor_id = p_actor_id AND object.operation_id = p_operation_id
    AND object.attachment_id = attachment.id
  WHERE attachment.id = p_attachment_id AND attachment.board_id = v_operation.board_id
  FOR UPDATE OF attachment;
  IF NOT FOUND OR v_attachment.uploaded_by <> p_actor_id
    OR v_attachment.size_bytes <> p_verified_size_bytes
    OR v_attachment.sha256 <> pg_catalog.decode(p_verified_sha256, 'hex') THEN
    RETURN pg_catalog.jsonb_build_object('status', 'object_mismatch');
  END IF;
  IF v_attachment.state = 'active' AND EXISTS (
    SELECT 1 FROM public.board_import_v2_objects AS object
    WHERE object.actor_id = p_actor_id AND object.operation_id = p_operation_id
      AND object.attachment_id = p_attachment_id AND object.uploaded
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'uploaded');
  END IF;
  IF v_attachment.state <> 'reserved'
    OR v_attachment.reservation_expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'expired');
  END IF;
  UPDATE public.task_attachments AS attachment
  SET state = 'active', reservation_expires_at = NULL
  WHERE attachment.id = p_attachment_id;
  UPDATE public.board_import_v2_objects AS object
  SET uploaded = true
  WHERE object.actor_id = p_actor_id AND object.operation_id = p_operation_id
    AND object.attachment_id = p_attachment_id;
  RETURN pg_catalog.jsonb_build_object('status', 'uploaded');
END;
$$;
REVOKE ALL ON FUNCTION public.mark_board_import_v2_object_uploaded_p(
  uuid, uuid, uuid, integer, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_board_import_v2_object_uploaded_p(
  uuid, uuid, uuid, integer, text
) TO service_role;

CREATE FUNCTION public.finalize_board_import_v2_p(p_slug text, p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_operation public.board_import_operations%ROWTYPE;
  v_revision bigint;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_operation_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.* INTO v_board
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug AND board.owner_id = v_actor_id
    AND public.is_board_owner(board.id)
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF board, membership;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
    AND operation.board_id = v_board.id AND operation.source_version = 2
  FOR UPDATE;
  IF NOT FOUND OR NOT v_operation.v2_materialized
    OR v_operation.expires_at <= pg_catalog.clock_timestamp() THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_operation.status = 'prepared' THEN
    SELECT revision.revision INTO v_revision
    FROM public.board_content_revisions AS revision
    WHERE revision.board_id = v_board.id;
    RETURN public.board_import_preview_result_p(v_operation, v_revision);
  END IF;
  IF v_operation.status <> 'staging' OR EXISTS (
    SELECT 1 FROM public.board_import_v2_objects AS object
    JOIN public.task_attachments AS attachment ON attachment.id = object.attachment_id
    WHERE object.actor_id = v_actor_id AND object.operation_id = p_operation_id
      AND (NOT object.uploaded OR attachment.state <> 'active')
  ) OR EXISTS (
    SELECT 1 FROM public.board_import_v2_objects AS object
    LEFT JOIN public.task_attachments AS attachment ON attachment.id = object.attachment_id
    WHERE object.actor_id = v_actor_id AND object.operation_id = p_operation_id
      AND attachment.id IS NULL
  ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_board.id FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  UPDATE public.board_import_operations AS operation
  SET staged_content_hash = public.board_import_generation_hash_p(
        v_board.id, v_operation.generation_id
      ),
      status = 'prepared'
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
  RETURNING * INTO v_operation;
  RETURN public.board_import_preview_result_p(v_operation, v_revision);
END;
$$;
REVOKE ALL ON FUNCTION public.finalize_board_import_v2_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.finalize_board_import_v2_p(text, uuid)
  TO authenticated;

CREATE FUNCTION public.cancel_board_import_v2_p(p_slug text, p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_operation public.board_import_operations%ROWTYPE;
  v_targets jsonb;
  v_deleted_at timestamptz := pg_catalog.clock_timestamp();
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user()
    OR p_slug IS NULL OR p_operation_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.slug = p_slug AND board.owner_id = v_actor_id
    AND public.is_board_owner(board.id)
  FOR UPDATE OF board, membership;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
    AND operation.board_id = v_board_id AND operation.source_version = 2
  FOR UPDATE;
  IF NOT FOUND OR v_operation.status = 'confirmed' THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  IF v_operation.status NOT IN ('cancelled', 'expired') THEN
    UPDATE public.task_attachments AS attachment
    SET state = 'cleanup_pending',
        reservation_expires_at = NULL,
        deleted_at = COALESCE(attachment.deleted_at, v_deleted_at),
        deleted_by = COALESCE(attachment.deleted_by, v_actor_id),
        deletion_cause = COALESCE(attachment.deletion_cause, 'admin_cleanup'),
        expires_at = COALESCE(attachment.expires_at, v_deleted_at + interval '168 hours')
    FROM public.board_import_v2_objects AS object
    WHERE object.actor_id = v_actor_id AND object.operation_id = p_operation_id
      AND object.attachment_id = attachment.id
      AND attachment.state IN ('reserved', 'active');
    UPDATE public.board_import_operations AS operation
    SET status = 'cancelled'
    WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;
    PERFORM public.cleanup_board_import_generation_p(v_board_id, v_operation.generation_id);
  END IF;
  SELECT COALESCE(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'attachment_id', object.attachment_id,
      'object_key', object.object_key,
      'uploaded', object.uploaded
    ) ORDER BY object.attachment_id
  ), '[]'::jsonb) INTO v_targets
  FROM public.board_import_v2_objects AS object
  WHERE object.actor_id = v_actor_id AND object.operation_id = p_operation_id;
  RETURN pg_catalog.jsonb_build_object('status', 'cancelled', 'objects', v_targets);
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_board_import_v2_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_board_import_v2_p(text, uuid)
  TO authenticated;

CREATE FUNCTION public.complete_board_import_v2_object_cleanup_p(
  p_actor_id uuid, p_operation_id uuid, p_attachment_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_deleted integer;
BEGIN
  IF p_actor_id IS NULL OR p_operation_id IS NULL OR p_attachment_id IS NULL
  THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  DELETE FROM public.task_attachments AS attachment
  USING public.board_import_v2_objects AS object,
    public.board_import_operations AS operation
  WHERE object.actor_id = p_actor_id AND object.operation_id = p_operation_id
    AND object.attachment_id = p_attachment_id
    AND operation.actor_id = p_actor_id AND operation.operation_id = p_operation_id
    AND operation.status IN ('cancelled', 'expired')
    AND attachment.id = p_attachment_id AND attachment.state = 'cleanup_pending';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN pg_catalog.jsonb_build_object(
    'status', CASE WHEN v_deleted = 1 THEN 'cleaned' ELSE 'unavailable' END
  );
END;
$$;
REVOKE ALL ON FUNCTION public.complete_board_import_v2_object_cleanup_p(uuid, uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_board_import_v2_object_cleanup_p(uuid, uuid, uuid)
  TO service_role;

CREATE FUNCTION public.board_import_v2_generation_cleanup_tg()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  UPDATE public.task_attachments AS attachment
  SET state = 'cleanup_pending',
      reservation_expires_at = NULL,
      deleted_at = COALESCE(attachment.deleted_at, pg_catalog.clock_timestamp()),
      deleted_by = COALESCE(attachment.deleted_by, operation.actor_id),
      deletion_cause = COALESCE(attachment.deletion_cause, 'admin_cleanup'),
      expires_at = COALESCE(attachment.expires_at,
        pg_catalog.clock_timestamp() + interval '168 hours')
  FROM public.board_import_v2_objects AS object
  JOIN public.board_import_operations AS operation
    ON operation.actor_id = object.actor_id AND operation.operation_id = object.operation_id
  WHERE operation.board_id = OLD.board_id AND operation.generation_id = OLD.id
    AND operation.status <> 'confirmed'
    AND attachment.id = object.attachment_id
    AND attachment.state IN ('reserved', 'active');
  RETURN OLD;
END;
$$;
CREATE TRIGGER board_import_v2_generation_cleanup
  BEFORE DELETE ON public.board_generations
  FOR EACH ROW EXECUTE FUNCTION public.board_import_v2_generation_cleanup_tg();
REVOKE ALL ON FUNCTION public.board_import_v2_generation_cleanup_tg()
  FROM PUBLIC, anon, authenticated, service_role;

-- Keep the legacy v1 RPC as the implementation for v1 while applying v2
-- board metadata and content generation in the same SQL transaction.
ALTER FUNCTION public.confirm_board_import_p(text, uuid, bigint, text)
  RENAME TO confirm_board_import_base_p;
REVOKE ALL ON FUNCTION public.confirm_board_import_base_p(text, uuid, bigint, text)
  FROM PUBLIC, anon, authenticated, service_role;
CREATE FUNCTION public.confirm_board_import_p(
  p_slug text, p_operation_id uuid, p_expected_content_revision bigint, p_source_sha256 text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, extensions, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board_id uuid;
  v_operation public.board_import_operations%ROWTYPE;
  v_board_name text;
  v_time_zone text;
  v_result jsonb;
  v_revision bigint;
BEGIN
  IF v_actor_id IS NULL THEN
    RETURN public.confirm_board_import_base_p(
      p_slug, p_operation_id, p_expected_content_revision, p_source_sha256
    );
  END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;
  IF NOT FOUND OR v_operation.source_version = 1 THEN
    RETURN public.confirm_board_import_base_p(
      p_slug, p_operation_id, p_expected_content_revision, p_source_sha256
    );
  END IF;
  SELECT board.id INTO v_board_id
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id AND membership.user_id = v_actor_id
    AND membership.role = 'owner' AND membership.revoked_at IS NULL
  WHERE board.id = v_operation.board_id AND board.slug = p_slug
    AND board.owner_id = v_actor_id AND public.is_board_owner(board.id)
  FOR UPDATE OF board, membership;
  IF NOT FOUND THEN
    RETURN public.confirm_board_import_base_p(
      p_slug, p_operation_id, p_expected_content_revision, p_source_sha256
    );
  END IF;
  SELECT operation.* INTO v_operation
  FROM public.board_import_operations AS operation
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id
  FOR UPDATE;
  IF NOT FOUND OR v_operation.source_version <> 2 THEN
    RETURN public.confirm_board_import_base_p(
      p_slug, p_operation_id, p_expected_content_revision, p_source_sha256
    );
  END IF;
  IF v_operation.status = 'confirmed' THEN
    RETURN COALESCE(v_operation.result,
      pg_catalog.jsonb_build_object('status', 'confirmed', 'operation_id', p_operation_id));
  END IF;
  IF v_operation.status <> 'prepared' OR NOT v_operation.v2_materialized
    OR EXISTS (
      SELECT 1 FROM public.board_import_v2_objects AS object
      LEFT JOIN public.task_attachments AS attachment ON attachment.id = object.attachment_id
      WHERE object.actor_id = v_actor_id AND object.operation_id = p_operation_id
        AND (NOT object.uploaded OR attachment.id IS NULL OR attachment.state <> 'active')
    ) THEN
    RETURN pg_catalog.jsonb_build_object('status', 'unavailable');
  END IF;
  SELECT staged.record->>'name', staged.record->>'time_zone'
  INTO v_board_name, v_time_zone
  FROM public.board_import_v2_records AS staged
  WHERE staged.actor_id = v_actor_id AND staged.operation_id = p_operation_id
    AND staged.entity = 'board' AND staged.record_index = 0;
  IF NOT FOUND OR v_board_name IS NULL OR v_time_zone IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('status', 'invalid');
  END IF;
  v_result := public.confirm_board_import_base_p(
    p_slug, p_operation_id, p_expected_content_revision, p_source_sha256
  );
  IF v_result->>'status' <> 'confirmed' THEN RETURN v_result; END IF;
  UPDATE public.boards AS board
  SET name = v_board_name, time_zone = v_time_zone
  WHERE board.id = v_operation.board_id
    AND (board.name IS DISTINCT FROM v_board_name OR board.time_zone IS DISTINCT FROM v_time_zone);
  SELECT revision.revision INTO v_revision
  FROM public.board_content_revisions AS revision
  WHERE revision.board_id = v_operation.board_id;
  v_result := v_result || pg_catalog.jsonb_build_object('content_revision', v_revision);
  UPDATE public.board_import_operations AS operation
  SET result = v_result
  WHERE operation.actor_id = v_actor_id AND operation.operation_id = p_operation_id;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.confirm_board_import_p(text, uuid, bigint, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_board_import_p(text, uuid, bigint, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;


