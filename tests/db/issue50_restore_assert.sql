\set ON_ERROR_STOP on
\echo 'Verificando el estado restaurado de la instancia sintética de OpenKanban'

DO $$
DECLARE
  v_snapshot_id uuid;
  v_fixture issue50_rehearsal.fixture%ROWTYPE;
  v_snapshot issue50_rehearsal.instance_snapshot%ROWTYPE;
  v_board public.boards%ROWTYPE;
  v_quota public.task_attachment_quota_ledger%ROWTYPE;
  v_series public.daily_repetition_series%ROWTYPE;
  v_occurrence_count integer;
  v_current_count integer;
  v_excluded_count integer;
  v_queued_count integer;
  v_leased_count integer;
BEGIN
  SELECT * INTO v_fixture
  FROM issue50_rehearsal.fixture
  WHERE singleton;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La base restaurada no contiene el fixture sintético de recuperación';
  END IF;

  SELECT * INTO v_snapshot
  FROM issue50_rehearsal.instance_snapshot
  WHERE singleton AND maintenance_mode;
  v_snapshot_id := v_snapshot.snapshot_id;

  IF v_snapshot_id IS DISTINCT FROM '86100000-0000-4000-8000-000000000001'::uuid
    OR v_snapshot.state_marker IS DISTINCT FROM 'snapshot-v1'
    OR v_snapshot.app_version IS DISTINCT FROM '1.0.0'
    OR v_snapshot.migration_head IS DISTINCT FROM '073_revoke_public_helper_execute.sql' THEN
    RAISE EXCEPTION 'El respaldo restaurado no conserva el marcador del snapshot de mantenimiento';
  END IF;

  SELECT * INTO v_board FROM public.boards
  WHERE id = v_fixture.board_id;
  IF v_board.id IS NULL
    OR v_board.owner_id IS DISTINCT FROM v_fixture.owner_id
    OR v_board.name IS DISTINCT FROM 'Issue 50 synthetic recovery board'
    OR v_board.active_generation_id IS DISTINCT FROM v_fixture.generation_id THEN
    RAISE EXCEPTION 'Cambió la identidad, el propietario, el nombre o la generación activa del tablero restaurado';
  END IF;

  IF (SELECT count(*) FROM public.board_memberships
      WHERE board_id = v_board.id AND revoked_at IS NULL) <> 2
    OR NOT EXISTS (
      SELECT 1 FROM public.board_memberships
      WHERE board_id = v_board.id
        AND user_id = '85000000-0000-4000-8000-000000000001'
        AND role = 'owner' AND revoked_at IS NULL
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.board_memberships
      WHERE board_id = v_board.id
        AND user_id = v_fixture.collaborator_id
        AND role = 'collaborator' AND revoked_at IS NULL
    )
    OR EXISTS (
      SELECT 1 FROM public.board_memberships
      WHERE board_id = v_board.id
        AND user_id = v_fixture.outsider_admin_id
    ) THEN
    RAISE EXCEPTION 'Cambió la membresía sintética o el ACL del tablero restaurado';
  END IF;

  IF (SELECT count(*) FROM public.columns
      WHERE board_id = v_board.id
        AND generation_id = v_board.active_generation_id) <> 2
    OR (SELECT count(*) FROM public.tasks AS task
        JOIN public.columns AS column_row ON column_row.id = task.column_id
        WHERE column_row.board_id = v_board.id) <> 1 THEN
    RAISE EXCEPTION 'Cambió el conteo de columnas o tareas del tablero restaurado';
  END IF;

  SELECT * INTO v_quota FROM public.task_attachment_quota_ledger
  WHERE singleton;
  IF v_quota.active_bytes <> 30
    OR v_quota.recoverable_bytes <> 0
    OR v_quota.reserved_bytes <> 0
    OR v_quota.pending_bytes <> 0 THEN
    RAISE EXCEPTION 'El ledger de cuota de adjuntos restaurado es inconsistente: %', row_to_json(v_quota);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.task_attachments AS attachment
    JOIN storage.objects AS object
      ON object.bucket_id = 'task-attachments'
      AND object.name = attachment.object_key
    WHERE attachment.id = '85900000-0000-4000-8000-000000000001'
      AND attachment.board_id = v_board.id
      AND attachment.task_id = v_fixture.task_id
      AND attachment.state = 'active'
      AND attachment.size_bytes = 30
      AND encode(attachment.sha256, 'hex') = '3809ddda411bb00f1716d380bc095848b006bf43c459fcee801ca4bfe6fe7e73'
      AND attachment.object_key = 'attachments/issue50/fixture.txt'
  ) THEN
    RAISE EXCEPTION 'Cambió el metadata del adjunto o el objeto Storage sintético restaurado';
  END IF;

  SELECT * INTO v_series FROM public.daily_repetition_series
  WHERE id = v_fixture.series_id;
  IF v_series.board_id IS DISTINCT FROM v_board.id
    OR v_series.generation_id IS DISTINCT FROM v_board.active_generation_id
    OR v_series.created_by IS DISTINCT FROM '85000000-0000-4000-8000-000000000001'::uuid
    OR v_series.state IS DISTINCT FROM 'active'
    OR v_series.next_due_on IS NULL THEN
    RAISE EXCEPTION 'Cambió la identidad, el autor o la programación de la serie restaurada';
  END IF;

  SELECT count(*)::integer,
    count(*) FILTER (WHERE state = 'current')::integer,
    count(*) FILTER (WHERE state = 'excluded')::integer
  INTO v_occurrence_count, v_current_count, v_excluded_count
  FROM public.daily_repetition_occurrences
  WHERE series_id = v_series.id;
  IF v_occurrence_count <> 2 OR v_current_count <> 1 OR v_excluded_count <> 1 THEN
    RAISE EXCEPTION 'Cambió la serie o sus exclusiones restauradas: total %, vigentes %, excluidas %',
      v_occurrence_count, v_current_count, v_excluded_count;
  END IF;

  SELECT count(*) FILTER (WHERE state = 'queued')::integer,
    count(*) FILTER (WHERE state = 'leased')::integer
  INTO v_queued_count, v_leased_count
  FROM public.daily_repetition_jobs
  WHERE series_id = v_series.id;
  IF v_queued_count <> 1 OR v_leased_count <> 0 THEN
    RAISE EXCEPTION 'Los trabajos no permanecieron detenidos al restaurar: en cola %, arrendados %',
      v_queued_count, v_leased_count;
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class
      WHERE oid = 'public.boards'::regclass)
    OR has_table_privilege('anon', 'public.boards', 'SELECT')
    OR NOT has_table_privilege('authenticated', 'public.boards', 'SELECT')
    OR has_function_privilege('anon', 'public.get_board_p(text)', 'EXECUTE')
    OR NOT has_function_privilege('authenticated', 'public.get_board_p(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'La base restaurada no conserva RLS ni grants del tablero';
  END IF;

  IF NOT (SELECT relrowsecurity FROM pg_class
      WHERE oid = 'storage.objects'::regclass)
    OR NOT EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'storage'
        AND tablename = 'objects'
        AND policyname = 'openkanban_task_attachments_server_only'
    ) THEN
    RAISE EXCEPTION 'La base restaurada no conserva la política de aislamiento de Storage';
  END IF;
END;
$$;

\echo 'PASS: identidad sintética, membresías, ACL, cuota, serie, exclusión y trabajos en cola preservados.'
