-- Full board exports use a single MVCC snapshot with short lived object pins.
-- The package is assembled by the server and its IDs never grant access.
BEGIN;

CREATE TABLE public.board_export_snapshots (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  board_id uuid NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  actor_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  board_slug text NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  schema_version integer NOT NULL DEFAULT 68 CHECK (schema_version = 68),
  normalization_version integer NOT NULL DEFAULT 1
    CHECK (normalization_version = 1),
  time_zone text NOT NULL,
  CHECK (expires_at > created_at)
);
CREATE INDEX board_export_snapshots_expiry_idx
  ON public.board_export_snapshots(expires_at, id);
ALTER TABLE public.board_export_snapshots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_export_snapshots
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_export_snapshot_items (
  export_id uuid NOT NULL REFERENCES public.board_export_snapshots(id) ON DELETE CASCADE,
  entity text NOT NULL,
  ordinal bigint NOT NULL CHECK (ordinal > 0),
  payload jsonb NOT NULL,
  object_key text,
  expected_size bigint,
  expected_sha256 text,
  PRIMARY KEY (export_id, entity, ordinal),
  CHECK (
    (entity = 'attachments' AND object_key IS NOT NULL
      AND expected_size BETWEEN 1 AND 24000
      AND expected_sha256 ~ '^[0-9a-f]{64}$')
    OR (entity <> 'attachments' AND object_key IS NULL
      AND expected_size IS NULL AND expected_sha256 IS NULL)
  )
);
ALTER TABLE public.board_export_snapshot_items ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_export_snapshot_items
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE public.board_export_attachment_pins (
  export_id uuid NOT NULL REFERENCES public.board_export_snapshots(id) ON DELETE CASCADE,
  attachment_id uuid NOT NULL,
  object_key text NOT NULL,
  pin_expires_at timestamptz NOT NULL,
  PRIMARY KEY (export_id, attachment_id)
);
CREATE INDEX board_export_attachment_pins_live_idx
  ON public.board_export_attachment_pins(attachment_id, pin_expires_at);
ALTER TABLE public.board_export_attachment_pins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.board_export_attachment_pins
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_export_package_ref_p(
  p_export_id uuid,
  p_entity text,
  p_source_id uuid
)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog, extensions, pg_temp
AS $$
  SELECT CASE WHEN p_entity IN (
    'board', 'column', 'task', 'comment', 'label', 'birthday',
    'repetition', 'occurrence', 'activity', 'attachment'
  ) THEN p_entity || '_' || pg_catalog.encode(extensions.digest(
    pg_catalog.convert_to(
      p_export_id::text || ':' || p_entity || ':' || p_source_id::text,
      'UTF8'
    ),
    'sha256'
  ), 'hex') END;
$$;
REVOKE ALL ON FUNCTION public.board_export_package_ref_p(uuid, text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_export_member_ref_p(
  p_member_key bytea,
  p_email text,
  p_fallback text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, extensions, pg_temp
AS $$
  SELECT 'member_' || pg_catalog.encode(extensions.hmac(
    pg_catalog.convert_to(
      COALESCE(
        NULLIF(pg_catalog.lower(pg_catalog.btrim(p_email)), ''),
        'id:' || p_fallback,
        'unknown'
      ),
      'UTF8'
    ),
    p_member_key,
    'sha256'
  ), 'hex');
$$;
REVOKE ALL ON FUNCTION public.board_export_member_ref_p(bytea, text, text)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.board_export_package_steps_p(
  p_export_id uuid,
  p_scope text,
  p_source_id uuid,
  p_steps jsonb
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = pg_catalog, extensions, pg_temp
AS $$
  SELECT COALESCE(pg_catalog.jsonb_agg(
    pg_catalog.jsonb_build_object(
      'id', 'step_' || pg_catalog.encode(extensions.digest(
        pg_catalog.convert_to(
          p_export_id::text || ':' || p_scope || ':' || p_source_id::text
            || ':step:' || step.ordinality::text,
          'UTF8'
        ),
        'sha256'
      ), 'hex'),
      'text', step.value->'text',
      'is_completed', step.value->'is_completed',
      'position', step.value->'position'
    ) ORDER BY step.ordinality
  ), '[]'::jsonb)
  FROM pg_catalog.jsonb_array_elements(p_steps)
    WITH ORDINALITY AS step(value, ordinality)
  WHERE p_scope IN ('task', 'repetition');
$$;
REVOKE ALL ON FUNCTION public.board_export_package_steps_p(uuid, text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.create_board_export_snapshot_p(
  p_actor_id uuid,
  p_board_slug text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_export_id uuid := pg_catalog.gen_random_uuid();
  v_member_ref_key bytea := extensions.gen_random_bytes(32);
  v_board_id uuid;
  v_time_zone text;
  v_created_at timestamptz := pg_catalog.statement_timestamp();
  v_result jsonb;
BEGIN
  IF p_actor_id IS NULL OR p_board_slug IS NULL OR p_board_slug = ''
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  -- Hold the board and membership stable while the one-statement snapshot is
  -- materialized. Attachment rows are separately share-locked in that query.
  SELECT board.id, board.time_zone
  INTO v_board_id, v_time_zone
  FROM public.boards AS board
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = p_actor_id
    AND membership.revoked_at IS NULL
  WHERE board.slug = p_board_slug
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR SHARE OF board, membership;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  WITH board_snapshot AS MATERIALIZED (
    SELECT board.*
    FROM public.boards AS board
    JOIN public.board_memberships AS membership
      ON membership.board_id = board.id
      AND membership.user_id = p_actor_id
      AND membership.revoked_at IS NULL
    WHERE board.id = v_board_id
      AND board.slug = p_board_slug
      AND NOT EXISTS (
        SELECT 1 FROM public.board_recoverable_deletions AS deletion
        WHERE deletion.board_id = board.id
      )
      AND public.is_enabled_application_identity_p(p_actor_id)
  ),
  inserted_snapshot AS (
    INSERT INTO public.board_export_snapshots(
      id, board_id, actor_id, board_slug, created_at, expires_at, time_zone
    )
    SELECT v_export_id, board.id, p_actor_id, board.slug, v_created_at,
      v_created_at + interval '1 hour', board.time_zone
    FROM board_snapshot AS board
    RETURNING id, board_id, created_at, time_zone
  ),
  live_columns AS MATERIALIZED (
    SELECT column_row.*
    FROM public.columns AS column_row
    JOIN board_snapshot AS board
      ON board.id = column_row.board_id
      AND board.active_generation_id = column_row.generation_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.column_deletions AS deletion
      WHERE deletion.column_id = column_row.id AND deletion.state = 'deleted'
    )
  ),
  live_tasks AS MATERIALIZED (
    SELECT task.*, column_row.board_id
    FROM public.tasks AS task
    JOIN live_columns AS column_row ON column_row.id = task.column_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = task.id AND deletion.state = 'deleted'
    )
  ),
  live_repetitions AS MATERIALIZED (
    SELECT series.*
    FROM public.daily_repetition_series AS series
    JOIN board_snapshot AS board
      ON board.id = series.board_id
      AND board.active_generation_id = series.generation_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.daily_repetition_series_deletions AS deletion
      WHERE deletion.series_id = series.id AND deletion.state = 'deleted'
    )
  ),
  active_attachments AS MATERIALIZED (
    SELECT attachment.*
    FROM public.task_attachments AS attachment
    JOIN live_tasks AS task
      ON task.id = attachment.task_id AND task.board_id = attachment.board_id
    WHERE attachment.state = 'active'
    FOR SHARE OF attachment
  ),
  records AS (
    SELECT 'board'::text AS entity, 1::bigint AS ordinal,
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'board', board.id),
        'name', board.name,
        'time_zone', board.time_zone,
        'created_at', board.created_at,
        'updated_at', board.updated_at
      ) AS payload, NULL::text AS object_key,
      NULL::bigint AS expected_size, NULL::text AS expected_sha256
    FROM board_snapshot AS board
    UNION ALL
    SELECT 'columns', row_number() OVER (ORDER BY column_row.position, column_row.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'column', column_row.id),
        'title', column_row.title,
        'position', column_row.position, 'created_at', column_row.created_at
      ), NULL::text, NULL::bigint, NULL::text
    FROM live_columns AS column_row
    UNION ALL
    SELECT 'tasks', row_number() OVER (ORDER BY task.column_id, task.position, task.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'task', task.id),
        'column_id', public.board_export_package_ref_p(v_export_id, 'column', task.column_id),
        'title', task.title,
        'description', task.description, 'priority', task.priority,
        'position', task.position, 'due_on', task.due_on,
        'is_completed', task.is_completed, 'completed_at', task.completed_at,
        'steps', public.board_export_package_steps_p(
          v_export_id, 'task', task.id, task.steps
        ), 'created_at', task.created_at,
        'updated_at', task.updated_at,
        'assignee_ref', CASE WHEN task.assignee_id IS NULL THEN NULL ELSE
          public.board_export_member_ref_p(
            v_member_ref_key, assignee.email, task.assignee_id::text
          ) END
      ), NULL::text, NULL::bigint, NULL::text
    FROM live_tasks AS task
    LEFT JOIN auth.users AS assignee ON assignee.id = task.assignee_id
    UNION ALL
    SELECT 'comments', row_number() OVER (ORDER BY comment.created_at, comment.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'comment', comment.id),
        'task_id', public.board_export_package_ref_p(v_export_id, 'task', comment.task_id),
        'author_name', CASE
          WHEN comment.author_name ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
          THEN public.board_export_member_ref_p(v_member_ref_key, comment.author_name)
          ELSE comment.author_name
        END,
        'content', comment.content,
        'created_at', comment.created_at, 'edited_at', comment.edited_at,
        'version', comment.version
      ), NULL::text, NULL::bigint, NULL::text
    FROM public.task_comments AS comment
    JOIN live_tasks AS task ON task.id = comment.task_id
    WHERE comment.deleted_at IS NULL
    UNION ALL
    SELECT 'labels', row_number() OVER (ORDER BY label.created_at, label.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'label', label.id),
        'name', label.name, 'color', label.color,
        'created_at', label.created_at, 'updated_at', label.updated_at
      ), NULL::text, NULL::bigint, NULL::text
    FROM public.board_labels AS label
    JOIN board_snapshot AS board
      ON board.id = label.board_id AND board.active_generation_id = label.generation_id
    WHERE label.deleted_at IS NULL
    UNION ALL
    SELECT 'task_labels', row_number() OVER (ORDER BY assignment.task_id, assignment.label_id),
      jsonb_build_object(
        'task_id', public.board_export_package_ref_p(v_export_id, 'task', assignment.task_id),
        'label_id', public.board_export_package_ref_p(v_export_id, 'label', assignment.label_id)
      ),
      NULL::text, NULL::bigint, NULL::text
    FROM public.board_label_task_assignments AS assignment
    JOIN live_tasks AS task ON task.id = assignment.task_id
    JOIN public.board_labels AS label
      ON label.id = assignment.label_id
      AND label.board_id = assignment.board_id
      AND label.generation_id = assignment.generation_id
      AND label.deleted_at IS NULL
    UNION ALL
    SELECT 'birthdays', row_number() OVER (ORDER BY birthday.name, birthday.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'birthday', birthday.id),
        'name', birthday.name,
        'birth_month', birthday.birth_month, 'birth_day', birthday.birth_day,
        'advance_days', birthday.advance_days,
        'created_at', birthday.created_at, 'updated_at', birthday.updated_at
      ), NULL::text, NULL::bigint, NULL::text
    FROM public.board_birthdays AS birthday
    JOIN board_snapshot AS board
      ON board.id = birthday.board_id AND board.active_generation_id = birthday.generation_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.birthday_deletions AS deletion
      WHERE deletion.birthday_id = birthday.id AND deletion.state = 'deleted'
    )
    UNION ALL
    SELECT 'birthday_labels', row_number() OVER (ORDER BY assignment.birthday_id, assignment.label_id),
      jsonb_build_object(
        'birthday_id', public.board_export_package_ref_p(v_export_id, 'birthday', assignment.birthday_id),
        'label_id', public.board_export_package_ref_p(v_export_id, 'label', assignment.label_id)
      ),
      NULL::text, NULL::bigint, NULL::text
    FROM public.board_label_birthday_assignments AS assignment
    JOIN board_snapshot AS board ON board.id = assignment.board_id
    JOIN public.board_birthdays AS birthday
      ON birthday.id = assignment.birthday_id
      AND birthday.generation_id = assignment.generation_id
    JOIN public.board_labels AS label
      ON label.id = assignment.label_id
      AND label.board_id = assignment.board_id
      AND label.generation_id = assignment.generation_id
      AND label.deleted_at IS NULL
    WHERE NOT EXISTS (
      SELECT 1 FROM public.birthday_deletions AS deletion
      WHERE deletion.birthday_id = birthday.id AND deletion.state = 'deleted'
    )
    UNION ALL
    SELECT 'repetitions', row_number() OVER (ORDER BY series.created_at, series.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'repetition', series.id),
        'origin_task_id', public.board_export_package_ref_p(v_export_id, 'task', series.origin_task_id),
        'first_task_id', public.board_export_package_ref_p(v_export_id, 'task', series.first_task_id),
        'appearance_column_id', public.board_export_package_ref_p(v_export_id, 'column', series.appearance_column_id),
        'rule', series.rule, 'start_on', series.start_on, 'end_on', series.end_on,
        'occurrence_limit', series.occurrence_limit,
        'consumed_count', series.consumed_count,
        'latest_occurrence_on', series.latest_occurrence_on,
        'current_occurrence_id', CASE WHEN series.current_occurrence_id IS NULL THEN NULL
          ELSE public.board_export_package_ref_p(v_export_id, 'occurrence', series.current_occurrence_id) END,
        'next_due_on', series.next_due_on, 'state', series.state,
        'calendar_pattern', series.calendar_pattern,
        'advance_days', series.advance_days,
        'template_snapshot', jsonb_build_object(
          'title', series.template_snapshot->'title',
          'description', series.template_snapshot->'description',
          'priority', series.template_snapshot->'priority',
          'assignee_ref', CASE WHEN series.template_snapshot->>'assignee_id' IS NULL THEN NULL
            ELSE public.board_export_member_ref_p(
              v_member_ref_key, template_assignee.email,
              series.template_snapshot->>'assignee_id'
            ) END,
          'steps', public.board_export_package_steps_p(
            v_export_id, 'repetition', series.id, series.template_snapshot->'steps'
          ),
          'redacted', series.template_snapshot->'redacted'
        ),
        'created_at', series.created_at, 'updated_at', series.updated_at,
        'stopped_at', series.stopped_at
      ), NULL::text, NULL::bigint, NULL::text
    FROM live_repetitions AS series
    LEFT JOIN auth.users AS template_assignee
      ON template_assignee.id = CASE
        WHEN series.template_snapshot->>'assignee_id'
          ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
        THEN (series.template_snapshot->>'assignee_id')::uuid END
    UNION ALL
    SELECT 'repetition_labels',
      row_number() OVER (ORDER BY assignment.series_id, assignment.label_id),
      jsonb_build_object(
        'series_id', public.board_export_package_ref_p(
          v_export_id, 'repetition', assignment.series_id
        ),
        'label_id', public.board_export_package_ref_p(
          v_export_id, 'label', assignment.label_id
        )
      ), NULL::text, NULL::bigint, NULL::text
    FROM public.board_label_repetition_assignments AS assignment
    JOIN live_repetitions AS series
      ON series.id = assignment.series_id
      AND series.board_id = assignment.board_id
      AND series.generation_id = assignment.generation_id
    JOIN public.board_labels AS label
      ON label.id = assignment.label_id
      AND label.board_id = assignment.board_id
      AND label.generation_id = assignment.generation_id
      AND label.deleted_at IS NULL
    UNION ALL
    SELECT 'repetition_occurrences', row_number() OVER (ORDER BY occurrence.series_id, occurrence.occurrence_on),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'occurrence', occurrence.id),
        'series_id', public.board_export_package_ref_p(v_export_id, 'repetition', occurrence.series_id),
        'occurrence_on', occurrence.occurrence_on,
        'task_id', public.board_export_package_ref_p(v_export_id, 'task', occurrence.task_id),
        'state', occurrence.state, 'due_on_override', occurrence.due_on_override,
        'transferred_to_series_id', CASE WHEN occurrence.transferred_to_series_id IS NULL THEN NULL
          ELSE public.board_export_package_ref_p(v_export_id, 'repetition', occurrence.transferred_to_series_id) END,
        'created_at', occurrence.created_at
      ), NULL::text, NULL::bigint, NULL::text
    FROM public.daily_repetition_occurrences AS occurrence
    JOIN live_repetitions AS series ON series.id = occurrence.series_id
    UNION ALL
    SELECT 'activity', row_number() OVER (ORDER BY event.occurred_at, event.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'activity', event.id),
        'task_id', public.board_export_package_ref_p(v_export_id, 'task', event.task_id),
        'actor_type', event.actor_type,
        'category', event.category,
        'actor_name', CASE
          WHEN event.actor_name ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
          THEN public.board_export_member_ref_p(v_member_ref_key, event.actor_name)
          ELSE event.actor_name
        END,
        'occurred_at', event.occurred_at,
        'before_value', CASE
          WHEN pg_catalog.jsonb_typeof(event.before_value) = 'string'
            AND event.before_value #>> '{}' ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
          THEN pg_catalog.to_jsonb(public.board_export_member_ref_p(
            v_member_ref_key, event.before_value #>> '{}'
          ))
          ELSE event.before_value
        END,
        'after_value', CASE
          WHEN pg_catalog.jsonb_typeof(event.after_value) = 'string'
            AND event.after_value #>> '{}' ~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
          THEN pg_catalog.to_jsonb(public.board_export_member_ref_p(
            v_member_ref_key, event.after_value #>> '{}'
          ))
          ELSE event.after_value
        END
      ), NULL::text, NULL::bigint, NULL::text
    FROM public.task_activity_events AS event
    JOIN live_tasks AS task ON task.id = event.task_id
    WHERE event.occurred_at >= v_created_at - interval '180 days'
    UNION ALL
    SELECT 'attachments', row_number() OVER (ORDER BY attachment.id),
      jsonb_build_object(
        'id', public.board_export_package_ref_p(v_export_id, 'attachment', attachment.id),
        'task_id', public.board_export_package_ref_p(v_export_id, 'task', attachment.task_id),
        'file_name', attachment.file_name, 'size_bytes', attachment.size_bytes,
        'sha256', pg_catalog.encode(attachment.sha256, 'hex'),
        'created_at', attachment.created_at
      ), attachment.object_key, attachment.size_bytes,
      pg_catalog.encode(attachment.sha256, 'hex')
    FROM active_attachments AS attachment
  ),
  inserted_items AS (
    INSERT INTO public.board_export_snapshot_items(
      export_id, entity, ordinal, payload, object_key, expected_size, expected_sha256
    )
    SELECT snapshot.id, records.entity, records.ordinal, records.payload,
      records.object_key, records.expected_size, records.expected_sha256
    FROM inserted_snapshot AS snapshot CROSS JOIN records
    RETURNING entity, ordinal
  ),
  inserted_pins AS (
    INSERT INTO public.board_export_attachment_pins(
      export_id, attachment_id, object_key, pin_expires_at
    )
    SELECT snapshot.id, attachment.id, attachment.object_key,
      v_created_at + interval '1 hour'
    FROM inserted_snapshot AS snapshot
    CROSS JOIN active_attachments AS attachment
    RETURNING attachment_id
  )
  SELECT jsonb_build_object(
    'status', 'created', 'export_id', snapshot.id,
    'created_at', snapshot.created_at, 'schema_version', 68,
    'normalization_version', 1, 'time_zone', snapshot.time_zone,
    'record_counts', COALESCE((
      SELECT jsonb_object_agg(counts.entity, counts.row_count)
      FROM (
        SELECT entity, count(*) AS row_count
        FROM inserted_items GROUP BY entity
      ) AS counts
    ), '{}'::jsonb),
    'attachment_pins', (SELECT count(*) FROM inserted_pins)
  )
  INTO v_result
  FROM inserted_snapshot AS snapshot;

  IF v_result IS NULL THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;
  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.create_board_export_snapshot_p(uuid, text)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_board_export_snapshot_p(uuid, text)
  TO service_role;

CREATE FUNCTION public.read_board_export_snapshot_page_p(
  p_actor_id uuid,
  p_board_slug text,
  p_export_id uuid,
  p_entity text,
  p_after bigint DEFAULT 0,
  p_limit integer DEFAULT 100
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_snapshot public.board_export_snapshots%ROWTYPE;
  v_items jsonb;
  v_count bigint;
BEGIN
  IF p_actor_id IS NULL OR p_board_slug IS NULL OR p_export_id IS NULL
    OR p_entity IS NULL OR p_after IS NULL OR p_after < 0
    OR p_limit IS NULL OR p_limit < 1 OR p_limit > 250
    OR NOT public.is_enabled_application_identity_p(p_actor_id) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  SELECT snapshot.* INTO v_snapshot
  FROM public.board_export_snapshots AS snapshot
  JOIN public.boards AS board
    ON board.id = snapshot.board_id AND board.slug = p_board_slug
  JOIN public.board_memberships AS membership
    ON membership.board_id = board.id
    AND membership.user_id = p_actor_id
    AND membership.revoked_at IS NULL
  WHERE snapshot.id = p_export_id
    AND snapshot.actor_id = p_actor_id
    AND snapshot.board_slug = p_board_slug
    AND snapshot.expires_at > pg_catalog.clock_timestamp()
    AND NOT EXISTS (
      SELECT 1 FROM public.board_recoverable_deletions AS deletion
      WHERE deletion.board_id = board.id
    )
  FOR UPDATE OF snapshot;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  IF p_entity NOT IN (
    'board', 'columns', 'tasks', 'comments', 'labels', 'task_labels',
    'birthdays', 'birthday_labels', 'repetitions',
    'repetition_labels', 'repetition_occurrences', 'activity', 'attachments'
  ) THEN
    RETURN jsonb_build_object('status', 'unavailable');
  END IF;

  UPDATE public.board_export_snapshots
  SET expires_at = pg_catalog.clock_timestamp() + interval '1 hour'
  WHERE id = v_snapshot.id;
  UPDATE public.board_export_attachment_pins
  SET pin_expires_at = pg_catalog.clock_timestamp() + interval '1 hour'
  WHERE export_id = v_snapshot.id;

  SELECT count(*) INTO v_count
  FROM public.board_export_snapshot_items AS item
  WHERE item.export_id = v_snapshot.id AND item.entity = p_entity;
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'ordinal', page.ordinal, 'payload', page.payload,
      'object_key', page.object_key, 'expected_size', page.expected_size,
      'expected_sha256', page.expected_sha256
    ) ORDER BY page.ordinal
  ), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT item.ordinal, item.payload, item.object_key,
      item.expected_size, item.expected_sha256
    FROM public.board_export_snapshot_items AS item
    WHERE item.export_id = v_snapshot.id
      AND item.entity = p_entity
      AND item.ordinal > p_after
    ORDER BY item.ordinal
    LIMIT p_limit
  ) AS page;

  RETURN jsonb_build_object(
    'status', 'page', 'export_id', v_snapshot.id,
    'created_at', v_snapshot.created_at, 'schema_version', v_snapshot.schema_version,
    'normalization_version', v_snapshot.normalization_version,
    'time_zone', v_snapshot.time_zone, 'entity', p_entity,
    'record_count', v_count, 'items', v_items,
    'has_more', (p_after + jsonb_array_length(v_items)::bigint) < v_count
  );
END;
$$;
REVOKE ALL ON FUNCTION public.read_board_export_snapshot_page_p(uuid, text, uuid, text, bigint, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.read_board_export_snapshot_page_p(uuid, text, uuid, text, bigint, integer)
  TO service_role;

CREATE FUNCTION public.delete_board_export_snapshot_p(
  p_actor_id uuid,
  p_export_id uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  WITH deleted AS (
    DELETE FROM public.board_export_snapshots AS snapshot
    WHERE snapshot.id = p_export_id AND snapshot.actor_id = p_actor_id
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM deleted);
$$;
REVOKE ALL ON FUNCTION public.delete_board_export_snapshot_p(uuid, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_board_export_snapshot_p(uuid, uuid)
  TO service_role;

CREATE FUNCTION public.cleanup_expired_board_export_snapshots_p(
  p_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_deleted integer;
BEGIN
  IF p_limit IS NULL OR p_limit < 1 THEN RETURN 0; END IF;
  WITH expired AS (
    SELECT snapshot.id
    FROM public.board_export_snapshots AS snapshot
    WHERE snapshot.expires_at <= pg_catalog.clock_timestamp()
    ORDER BY snapshot.expires_at, snapshot.id
    FOR UPDATE SKIP LOCKED
    LIMIT LEAST(p_limit, 500)
  ), deleted AS (
    DELETE FROM public.board_export_snapshots AS snapshot
    USING expired
    WHERE snapshot.id = expired.id
    RETURNING snapshot.id
  )
  SELECT count(*)::integer INTO v_deleted FROM deleted;
  RETURN v_deleted;
END;
$$;
REVOKE ALL ON FUNCTION public.cleanup_expired_board_export_snapshots_p(integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cleanup_expired_board_export_snapshots_p(integer)
  TO service_role;

CREATE OR REPLACE FUNCTION public.claim_expired_task_attachment_cleanup_p(
  p_lease_id uuid,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  attachment_id uuid,
  object_key text,
  size_bytes integer,
  prior_state text,
  lease_until timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF p_lease_id IS NULL OR p_limit IS NULL OR p_limit < 1 THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT attachment.id, attachment.state AS prior_state
    FROM public.task_attachments AS attachment
    WHERE (
        (attachment.state = 'recoverable'
          AND attachment.expires_at <= pg_catalog.clock_timestamp())
        OR (attachment.state = 'reserved'
          AND attachment.reservation_expires_at <= pg_catalog.clock_timestamp())
        OR attachment.state IN ('cleanup_pending', 'missing')
        OR (attachment.state = 'purging'
          AND attachment.purge_lease_until <= pg_catalog.clock_timestamp())
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.board_export_attachment_pins AS pin
        WHERE pin.attachment_id = attachment.id
          AND pin.pin_expires_at > pg_catalog.clock_timestamp()
      )
    ORDER BY COALESCE(
      attachment.expires_at, attachment.reservation_expires_at,
      attachment.created_at
    ), attachment.id
    FOR UPDATE SKIP LOCKED
    LIMIT LEAST(p_limit, 100)
  ), claimed AS (
    UPDATE public.task_attachments AS attachment
    SET state = 'purging',
        purge_lease_id = p_lease_id,
        purge_lease_until = pg_catalog.clock_timestamp() + interval '5 minutes',
        purge_attempts = attachment.purge_attempts + 1
    FROM candidates
    WHERE attachment.id = candidates.id
    RETURNING attachment.id, attachment.object_key, attachment.size_bytes,
      attachment.purge_lease_until, candidates.prior_state
  )
  SELECT claimed.id, claimed.object_key, claimed.size_bytes,
    claimed.prior_state, claimed.purge_lease_until
  FROM claimed;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_expired_task_attachment_cleanup_p(uuid, integer)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.claim_expired_task_attachment_cleanup_p(uuid, integer)
  TO service_role;

COMMIT;
