BEGIN;

-- E04 copies are available from any current task the member may access,
-- including a pending task. Historical sources continue to use the same
-- current task/occurrence authorization path; deleted sources stay unavailable.
CREATE OR REPLACE FUNCTION public.historical_task_copy_preview_internal_p(
  p_board_id uuid,
  p_generation_id uuid,
  p_task_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, extensions, pg_temp
AS $$
DECLARE
  v_board public.boards%ROWTYPE;
  v_task public.tasks%ROWTYPE;
  v_steps jsonb;
  v_copy_steps jsonb;
  v_copy_labels jsonb;
  v_hash_labels jsonb;
  v_source_hash bytea;
BEGIN
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.id = p_board_id
    AND board.active_generation_id = p_generation_id;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;
  SELECT task.* INTO v_task
  FROM public.tasks AS task
  JOIN public.columns AS column_row
    ON column_row.id = task.column_id
    AND column_row.board_id = v_board.id
    AND column_row.generation_id = v_board.active_generation_id
  WHERE task.id = p_task_id
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = task.id
        AND deletion.board_id = v_board.id
        AND deletion.state IN ('deleted', 'purged')
    );
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('status', 'unavailable'); END IF;

  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', label.id,
    'name', label.name,
    'color', label.color
  ) ORDER BY label.created_at, label.id), '[]'::jsonb)
  INTO v_copy_labels
  FROM public.board_label_task_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.task_id = v_task.id
    AND label.deleted_at IS NULL;
  SELECT coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', label.value->'id',
    'name', label.value->'name'
  ) ORDER BY label.ordinality), '[]'::jsonb)
  INTO v_hash_labels
  FROM pg_catalog.jsonb_array_elements(v_copy_labels)
    WITH ORDINALITY AS label(value, ordinality);

  SELECT
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'text', step.value->>'text',
      'position', coalesce((step.value->>'position')::integer,
        (step.ordinality - 1)::integer),
      'is_completed', false
    ) ORDER BY step.ordinality), '[]'::jsonb),
    coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'text', step.value->>'text',
      'position', coalesce((step.value->>'position')::integer,
        (step.ordinality - 1)::integer)
    ) ORDER BY step.ordinality), '[]'::jsonb)
  INTO v_copy_steps, v_steps
  FROM pg_catalog.jsonb_array_elements(v_task.steps)
    WITH ORDINALITY AS step(value, ordinality);
  v_copy_steps := coalesce(v_copy_steps, '[]'::jsonb);
  v_steps := coalesce(v_steps, '[]'::jsonb);
  v_source_hash := extensions.digest(pg_catalog.convert_to(
    pg_catalog.jsonb_build_object(
      'title', v_task.title,
      'description', v_task.description,
      'priority', v_task.priority,
      'steps', v_steps,
      'labels', v_hash_labels
    )::text, 'UTF8'
  ), 'sha256');
  RETURN pg_catalog.jsonb_build_object(
    'status', 'available',
    'board_id', v_board.id,
    'source_task_id', v_task.id,
    'source_column_id', v_task.column_id,
    'target_column_id', v_task.column_id,
    'title', v_task.title,
    'description', v_task.description,
    'priority', v_task.priority,
    'steps', v_copy_steps,
    'labels', v_copy_labels,
    'step_count', pg_catalog.jsonb_array_length(v_copy_steps),
    'source_hash', pg_catalog.encode(v_source_hash, 'hex')
  );
END;
$$;

CREATE FUNCTION public.preview_task_copy_p(
  p_slug text,
  p_task_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
BEGIN
  RETURN public.preview_historical_task_copy_p(p_slug, p_task_id);
END;
$$;
REVOKE ALL ON FUNCTION public.preview_task_copy_p(text, uuid)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.preview_task_copy_p(text, uuid)
  TO authenticated;

ALTER FUNCTION public.copy_historical_task_p(uuid, text, uuid, uuid, text, text)
  RENAME TO copy_task_without_labels_internal_p;
REVOKE ALL ON FUNCTION public.copy_task_without_labels_internal_p(
  uuid, text, uuid, uuid, text, text
) FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.copy_task_p(
  p_operation_id uuid,
  p_slug text,
  p_source_task_id uuid,
  p_target_column_id uuid,
  p_title text,
  p_expected_source_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_board public.boards%ROWTYPE;
  v_has_receipt boolean;
  v_result jsonb;
  v_source_label_ids uuid[];
  v_labels_result jsonb;
  v_copied_task public.tasks%ROWTYPE;
BEGIN
  IF v_actor_id IS NULL OR NOT public.is_application_user() THEN
    RAISE EXCEPTION 'Se requiere acceso al tablero' USING ERRCODE = '42501';
  END IF;
  IF p_operation_id IS NULL OR p_slug IS NULL OR p_source_task_id IS NULL
    OR p_target_column_id IS NULL OR p_title IS NULL
    OR p_expected_source_hash IS NULL
    OR p_expected_source_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'Revisa la copia antes de confirmarla' USING ERRCODE = '22023';
  END IF;

  -- Keep copy and label selection serialized with label deletion/restore.
  SELECT board.* INTO v_board
  FROM public.boards AS board
  WHERE board.slug = p_slug
    AND public.is_board_member(board.id)
  FOR UPDATE;
  IF NOT FOUND OR NOT public.is_application_user()
    OR NOT public.is_board_member(v_board.id) THEN
    RETURN pg_catalog.jsonb_build_object(
      'status', 'unavailable', 'operation_id', p_operation_id
    );
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.task_copy_receipts AS receipt
    WHERE receipt.actor_id = v_actor_id
      AND receipt.operation_id = p_operation_id
  ) INTO v_has_receipt;
  v_result := public.copy_task_without_labels_internal_p(
    p_operation_id, p_slug, p_source_task_id, p_target_column_id,
    p_title, p_expected_source_hash
  );
  IF v_result->>'status' IS DISTINCT FROM 'confirmed' OR v_has_receipt THEN
    RETURN v_result;
  END IF;

  SELECT coalesce(pg_catalog.array_agg(label.id ORDER BY label.created_at, label.id),
    ARRAY[]::uuid[])
  INTO v_source_label_ids
  FROM public.board_label_task_assignments AS assignment
  JOIN public.board_labels AS label
    ON label.id = assignment.label_id
    AND label.board_id = assignment.board_id
    AND label.generation_id = assignment.generation_id
    AND label.deleted_at IS NULL
  JOIN public.tasks AS source
    ON source.id = assignment.task_id
  JOIN public.columns AS source_column
    ON source_column.id = source.column_id
    AND source_column.board_id = v_board.id
    AND source_column.generation_id = v_board.active_generation_id
  WHERE assignment.board_id = v_board.id
    AND assignment.generation_id = v_board.active_generation_id
    AND assignment.task_id = p_source_task_id
    AND NOT EXISTS (
      SELECT 1 FROM public.task_deletions AS deletion
      WHERE deletion.task_id = source.id
        AND deletion.board_id = v_board.id
        AND deletion.state IN ('deleted', 'purged')
    );

  v_labels_result := public.set_task_labels_p(
    p_slug, (v_result->>'task_id')::uuid, ARRAY[]::uuid[], v_source_label_ids
  );
  IF v_labels_result->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'No se pudieron copiar las etiquetas activas del origen'
      USING ERRCODE = '40001';
  END IF;

  SELECT task.* INTO v_copied_task
  FROM public.tasks AS task
  WHERE task.id = (v_result->>'task_id')::uuid;
  RETURN pg_catalog.jsonb_set(
    v_result, '{task}', pg_catalog.to_jsonb(v_copied_task), true
  );
END;
$$;
REVOKE ALL ON FUNCTION public.copy_task_p(
  uuid, text, uuid, uuid, text, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.copy_task_p(
  uuid, text, uuid, uuid, text, text
) TO authenticated;

CREATE FUNCTION public.copy_historical_task_p(
  p_operation_id uuid,
  p_slug text,
  p_source_task_id uuid,
  p_target_column_id uuid,
  p_title text,
  p_expected_source_hash text
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $$
  SELECT public.copy_task_p(
    p_operation_id, p_slug, p_source_task_id, p_target_column_id,
    p_title, p_expected_source_hash
  );
$$;
REVOKE ALL ON FUNCTION public.copy_historical_task_p(
  uuid, text, uuid, uuid, text, text
) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.copy_historical_task_p(
  uuid, text, uuid, uuid, text, text
) TO authenticated;

COMMIT;
