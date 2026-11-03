\set ON_ERROR_STOP on
\echo 'Verifying independent checklist step persistence and retries'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added jsonb;
  v_replayed jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Checklist independiente #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000015'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000016',
    v_board.id,
    v_column_id,
    'Publicar la entrega'
  )->'task';

  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000017',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Preparar publicación')
  );
  IF v_added->>'status' IS DISTINCT FROM 'confirmed'
    OR v_added->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Preparar publicación'
    OR v_added->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'false'
    OR v_added->'task'->'steps'->0->>'position' IS DISTINCT FROM '0'
    OR v_added->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Adding a step did not persist independently of task fields: %', v_added;
  END IF;

  v_replayed := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000017',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Preparar publicación')
  );
  IF v_replayed->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_replayed->'task'->'steps') IS DISTINCT FROM 1
    OR v_replayed->'task'->'steps'->0->>'id'
      IS DISTINCT FROM v_added->'task'->'steps'->0->>'id' THEN
    RAISE EXCEPTION 'Retrying one step action duplicated or lost its result: %', v_replayed;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: checklist steps persist independently and action retries do not duplicate them'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added jsonb;
  v_marked jsonb;
  v_replayed jsonb;
  v_step_id uuid;
  v_mark_command jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Checklist estado deseado #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000018'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000019',
    v_board.id,
    v_column_id,
    'Verificar reintento'
  )->'task';
  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000020',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Marcar revisión')
  );
  v_step_id := (v_added->'task'->'steps'->0->>'id')::uuid;
  v_mark_command := jsonb_build_object(
    'action', 'mark',
    'step_id', v_step_id,
    'is_completed', true,
    'expected_version', 1
  );

  v_marked := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000021',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_mark_command
  );
  IF v_marked->>'status' IS DISTINCT FROM 'confirmed'
    OR v_marked->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_marked->'task'->'steps'->0->>'version' IS DISTINCT FROM '2'
    OR v_marked->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Marking a step did not save its desired state independently: %', v_marked;
  END IF;

  v_replayed := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000021',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_mark_command
  );
  IF v_replayed->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replayed->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_replayed->'task'->'steps'->0->>'version' IS DISTINCT FROM '2'
    OR jsonb_array_length(v_replayed->'task'->'steps') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Retrying a desired-state mark toggled or duplicated its step: %', v_replayed;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: checklist marks are desired-state operations and do not version task fields'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added jsonb;
  v_marked jsonb;
  v_edited jsonb;
  v_replayed jsonb;
  v_step_id uuid;
  v_edit_command jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Checklist edición independiente #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000022'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000023',
    v_board.id,
    v_column_id,
    'Editar texto del paso'
  )->'task';
  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000024',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Texto inicial')
  );
  v_step_id := (v_added->'task'->'steps'->0->>'id')::uuid;
  v_marked := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000025',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'mark',
      'step_id', v_step_id,
      'is_completed', true,
      'expected_version', 1
    )
  );
  v_edit_command := jsonb_build_object(
    'action', 'edit',
    'step_id', v_step_id,
    'text', 'Texto corregido',
    'expected_version', 2
  );
  v_edited := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000026',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_edit_command
  );
  IF v_edited->>'status' IS DISTINCT FROM 'confirmed'
    OR v_edited->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Texto corregido'
    OR v_edited->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_edited->'task'->'steps'->0->>'version' IS DISTINCT FROM '3'
    OR v_edited->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Editing step text lost its mark or touched task field versions: %', v_edited;
  END IF;
  v_replayed := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000026',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_edit_command
  );
  IF v_replayed->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replayed->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Texto corregido'
    OR v_replayed->'task'->'steps'->0->>'version' IS DISTINCT FROM '3' THEN
    RAISE EXCEPTION 'Retrying an edit changed the checklist step twice: %', v_replayed;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: editing step text preserves its mark and retries are idempotent'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added_first jsonb;
  v_added_second jsonb;
  v_marked jsonb;
  v_reordered jsonb;
  v_replayed jsonb;
  v_first_step_id uuid;
  v_second_step_id uuid;
  v_order_command jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Checklist orden manual #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000027'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000028',
    v_board.id,
    v_column_id,
    'Ordenar los pasos'
  )->'task';
  v_added_first := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000029',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Primero')
  );
  v_first_step_id := (v_added_first->'task'->'steps'->0->>'id')::uuid;
  v_added_second := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000030',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Segundo')
  );
  v_second_step_id := (v_added_second->'task'->'steps'->1->>'id')::uuid;
  v_marked := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000031',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'mark',
      'step_id', v_first_step_id,
      'is_completed', true,
      'expected_version', 1
    )
  );
  v_order_command := jsonb_build_object(
    'action', 'reorder',
    'step_ids', jsonb_build_array(v_second_step_id, v_first_step_id),
    'expected_order_version', 3
  );
  v_reordered := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000032',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_order_command
  );
  IF v_reordered->>'status' IS DISTINCT FROM 'confirmed'
    OR v_reordered->'task'->'steps'->0->>'id' IS DISTINCT FROM v_second_step_id::text
    OR v_reordered->'task'->'steps'->0->>'position' IS DISTINCT FROM '0'
    OR v_reordered->'task'->'steps'->1->>'id' IS DISTINCT FROM v_first_step_id::text
    OR v_reordered->'task'->'steps'->1->>'position' IS DISTINCT FROM '1'
    OR v_reordered->'task'->'steps'->1->>'is_completed' IS DISTINCT FROM 'true'
    OR v_reordered->'task'->>'steps_order_version' IS DISTINCT FROM '4'
    OR v_reordered->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Reordering did not preserve flat step state/order independently: %', v_reordered;
  END IF;
  v_replayed := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000032',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_order_command
  );
  IF v_replayed->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replayed->'task'->>'steps_order_version' IS DISTINCT FROM '4'
    OR v_replayed->'task'->'steps'->0->>'id' IS DISTINCT FROM v_second_step_id::text THEN
    RAISE EXCEPTION 'Retrying a checklist reorder changed its order twice: %', v_replayed;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: checklist steps keep manual order, state, and task field versions'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added jsonb;
  v_marked jsonb;
  v_stale_delete jsonb;
  v_deleted jsonb;
  v_restored jsonb;
  v_delete_replay jsonb;
  v_step_id uuid;
  v_recovery record;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Checklist recuperación ordinaria #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000033'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000034',
    v_board.id,
    v_column_id,
    'Recuperar el paso'
  )->'task';
  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000035',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Paso recuperable')
  );
  v_step_id := (v_added->'task'->'steps'->0->>'id')::uuid;
  v_marked := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000061',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'mark',
      'step_id', v_step_id,
      'is_completed', true,
      'expected_version', 1
    )
  );
  v_stale_delete := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000062',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', v_step_id,
      'expected_version', 1
    )
  );
  IF v_marked->>'status' IS DISTINCT FROM 'confirmed'
    OR v_stale_delete->>'status' IS DISTINCT FROM 'conflict'
    OR v_stale_delete->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR jsonb_array_length(v_stale_delete->'task'->'steps') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'A stale delete changed or tombstoned the current checklist step: % / %',
      v_marked, v_stale_delete;
  END IF;
  v_deleted := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000036',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', v_step_id,
      'expected_version', 2
    )
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_deleted->'task'->'steps') IS DISTINCT FROM 0
    OR v_deleted->'task'->>'steps_order_version' IS DISTINCT FROM '3'
    OR v_deleted->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Deleting a step did not persist independently: %', v_deleted;
  END IF;
  SELECT * INTO STRICT v_recovery
  FROM public.list_deleted_task_checklist_steps_p(v_board.slug)
  WHERE task_id = (v_task->>'id')::uuid AND step_id = v_step_id;
  IF v_recovery.text IS DISTINCT FROM 'Paso recuperable'
    OR v_recovery.can_restore IS DISTINCT FROM true
    OR v_recovery.expires_at IS DISTINCT FROM v_recovery.deleted_at + interval '168 hours' THEN
    RAISE EXCEPTION 'Deleted step recovery did not use the current actor and fixed 168-hour window: %',
      row_to_json(v_recovery);
  END IF;

  v_restored := public.restore_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000037',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_step_id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR v_restored->'task'->'steps'->0->>'id' IS DISTINCT FROM v_step_id::text
    OR v_restored->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Paso recuperable'
    OR v_restored->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_restored->'task'->>'steps_order_version' IS DISTINCT FROM '4'
    OR v_restored->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Restoring the deleted step did not return its prior state: %', v_restored;
  END IF;
  v_delete_replay := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000036',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', v_step_id,
      'expected_version', 2
    )
  );
  IF v_delete_replay->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_delete_replay->'task'->'steps') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'Replaying a recovered deletion applied it a second time: %', v_delete_replay;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: checklist deletion is recoverable for seven days and does not repeat on retry'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added jsonb;
  v_step_deleted jsonb;
  v_parent_deleted jsonb;
  v_parent_restored jsonb;
  v_step_restored jsonb;
  v_step_id uuid;
  v_steps jsonb;
  v_field_versions jsonb;
  v_child_trash_count integer;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Checklist y tarea se recuperan por separado #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000038'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000039',
    v_board.id,
    v_column_id,
    'Restaurar tarea y paso de forma independiente'
  )->'task';
  v_field_versions := v_task->'field_versions';
  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000040',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Paso aparte')
  );
  v_step_id := (v_added->'task'->'steps'->0->>'id')::uuid;
  v_step_deleted := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000041',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', v_step_id,
      'expected_version', 1
    )
  );
  v_parent_deleted := public.delete_task_p(
    'a8888888-0000-4000-8000-000000000042',
    v_board.slug,
    (v_task->>'id')::uuid,
    'user_requested'
  );
  SELECT count(*) INTO v_child_trash_count
  FROM public.list_deleted_task_checklist_steps_p(v_board.slug)
  WHERE task_id = (v_task->>'id')::uuid AND step_id = v_step_id;
  IF v_parent_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_child_trash_count <> 0 THEN
    RAISE EXCEPTION 'A child step was listed while its parent task was deleted: % / %',
      v_parent_deleted, v_child_trash_count;
  END IF;

  v_parent_restored := public.restore_task_p(
    'a8888888-0000-4000-8000-000000000043',
    v_board.slug,
    (v_task->>'id')::uuid
  );
  SELECT task.steps INTO STRICT v_steps
  FROM public.get_tasks_by_board_p(v_board.id) AS task
  WHERE task.id = (v_task->>'id')::uuid;
  SELECT count(*) INTO v_child_trash_count
  FROM public.list_deleted_task_checklist_steps_p(v_board.slug)
  WHERE task_id = (v_task->>'id')::uuid AND step_id = v_step_id
    AND text = 'Paso aparte' AND can_restore;
  IF v_parent_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_steps) <> 0
    OR v_child_trash_count <> 1 THEN
    RAISE EXCEPTION 'Restoring the parent revived or lost its separately deleted child: % / % / %',
      v_parent_restored, v_steps, v_child_trash_count;
  END IF;

  v_step_restored := public.restore_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000044',
    v_board.slug,
    (v_task->>'id')::uuid,
    v_step_id
  );
  IF v_step_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR v_step_restored->'task'->'steps'->0->>'id' IS DISTINCT FROM v_step_id::text
    OR v_step_restored->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Paso aparte'
    OR v_step_restored->'task'->>'steps_order_version' IS DISTINCT FROM '4'
    OR v_step_restored->'task'->'field_versions' IS DISTINCT FROM v_field_versions THEN
    RAISE EXCEPTION 'Restoring the child did not preserve independent step/task state: %',
      v_step_restored;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: restoring a task does not revive a separately deleted checklist step'

CREATE TABLE public.issue15_checklist_recovery_fixture (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  step_id uuid NOT NULL
);
GRANT SELECT, INSERT ON public.issue15_checklist_recovery_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added jsonb;
  v_deleted jsonb;
  v_step_id uuid;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Permisos de recuperación de pasos #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000045'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000046',
    v_board.id,
    v_column_id,
    'Recuperar solo con acceso vigente'
  )->'task';
  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000047',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Solo miembros actuales')
  );
  v_step_id := (v_added->'task'->'steps'->0->>'id')::uuid;
  v_deleted := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000048',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', v_step_id,
      'expected_version', 1
    )
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the deleted step permission fixture: %', v_deleted;
  END IF;
  INSERT INTO public.issue15_checklist_recovery_fixture(
    board_id, board_slug, task_id, step_id
  ) VALUES (v_board.id, v_board.slug, (v_task->>'id')::uuid, v_step_id);
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT fixture.board_id, '40000000-0000-4000-8000-000000000005', 'collaborator'
FROM public.issue15_checklist_recovery_fixture AS fixture;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_fixture record;
  v_step_trash_count integer;
  v_restored jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue15_checklist_recovery_fixture;
  SELECT count(*) INTO v_step_trash_count
  FROM public.list_deleted_task_checklist_steps_p(v_fixture.board_slug)
  WHERE task_id = v_fixture.task_id
    AND step_id = v_fixture.step_id
    AND can_restore;
  IF v_step_trash_count <> 1 THEN
    RAISE EXCEPTION 'A current collaborator could not list the deleted step';
  END IF;
  v_restored := public.restore_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000049',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.step_id
  );
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR v_restored->'task'->'steps'->0->>'text' IS DISTINCT FROM 'Solo miembros actuales' THEN
    RAISE EXCEPTION 'A current collaborator could not restore the deleted step: %', v_restored;
  END IF;
END;
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_task jsonb;
  v_added jsonb;
  v_deleted jsonb;
  v_step_id uuid;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue15_checklist_recovery_fixture;
  SELECT to_jsonb(task) INTO v_task
  FROM public.get_tasks_by_board_p(v_fixture.board_id) AS task
  WHERE task.id = v_fixture.task_id;
  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000050',
    v_fixture.board_slug,
    v_fixture.task_id,
    jsonb_build_object('action', 'add', 'text', 'Revocación invalida el acceso')
  );
  v_step_id := (v_added->'task'->'steps'->1->>'id')::uuid;
  v_deleted := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000051',
    v_fixture.board_slug,
    v_fixture.task_id,
    jsonb_build_object(
      'action', 'delete',
      'step_id', v_step_id,
      'expected_version', 1
    )
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_task->>'id' IS NULL THEN
    RAISE EXCEPTION 'Could not prepare the revocation check: %', v_deleted;
  END IF;
END;
$$;
COMMIT;

UPDATE public.board_memberships
SET revoked_at = clock_timestamp()
WHERE board_id = (SELECT board_id FROM public.issue15_checklist_recovery_fixture)
  AND user_id = '40000000-0000-4000-8000-000000000005'
  AND revoked_at IS NULL;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_fixture record;
  v_step_trash_count integer;
  v_restore_denied boolean := false;
  v_restore_result jsonb;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue15_checklist_recovery_fixture;
  SELECT count(*) INTO v_step_trash_count
  FROM public.list_deleted_task_checklist_steps_p(v_fixture.board_slug)
  WHERE task_id = v_fixture.task_id;
  IF v_step_trash_count <> 0 THEN
    RAISE EXCEPTION 'A revoked collaborator still lists deleted checklist content';
  END IF;
  BEGIN
    v_restore_result := public.restore_task_checklist_step_p(
      'a8888888-0000-4000-8000-000000000052',
      v_fixture.board_slug,
      v_fixture.task_id,
      v_fixture.step_id
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_restore_denied := true;
  END;
  IF NOT v_restore_denied THEN
    RAISE EXCEPTION 'A revoked collaborator was not denied step restoration: %',
      v_restore_result;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: checklist recovery follows current collaborator membership and revocation'

CREATE TABLE public.issue15_checklist_expiry_fixture (
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  restore_before_step_id uuid NOT NULL,
  expire_at_step_id uuid NOT NULL
);
GRANT SELECT, INSERT ON public.issue15_checklist_expiry_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_first jsonb;
  v_second jsonb;
  v_deleted_first jsonb;
  v_deleted_second jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Vencimiento de pasos controlado #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000053'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000054',
    v_board.id,
    v_column_id,
    'Vencer a las 168 horas'
  )->'task';
  v_first := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000055',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Antes del límite')
  );
  v_second := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000056',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'En el límite')
  );
  v_deleted_first := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000057',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', (v_first->'task'->'steps'->0->>'id')::uuid,
      'expected_version', 1
    )
  );
  v_deleted_second := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000058',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', (v_second->'task'->'steps'->1->>'id')::uuid,
      'expected_version', 1
    )
  );
  IF v_deleted_first->>'status' IS DISTINCT FROM 'confirmed'
    OR v_deleted_second->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare the controlled expiry test: % / %',
      v_deleted_first, v_deleted_second;
  END IF;
  INSERT INTO public.issue15_checklist_expiry_fixture(
    board_slug, task_id, restore_before_step_id, expire_at_step_id
  ) VALUES (
    v_board.slug,
    (v_task->>'id')::uuid,
    (v_first->'task'->'steps'->0->>'id')::uuid,
    (v_second->'task'->'steps'->1->>'id')::uuid
  );
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_before_expiry timestamptz;
  v_at_expiry timestamptz;
  v_restored jsonb;
  v_replayed jsonb;
  v_expired jsonb;
  v_step_state text;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue15_checklist_expiry_fixture;
  SELECT expires_at INTO STRICT v_before_expiry
  FROM public.task_checklist_deletions
  WHERE step_id = v_fixture.restore_before_step_id;
  v_restored := public.restore_task_checklist_step_internal_p(
    'a8888888-0000-4000-8000-000000000059',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.restore_before_step_id,
    v_before_expiry - interval '1 microsecond'
  );
  v_replayed := public.restore_task_checklist_step_internal_p(
    'a8888888-0000-4000-8000-000000000059',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.restore_before_step_id,
    v_before_expiry - interval '1 microsecond'
  );
  SELECT expires_at INTO STRICT v_at_expiry
  FROM public.task_checklist_deletions
  WHERE step_id = v_fixture.expire_at_step_id;
  v_expired := public.restore_task_checklist_step_internal_p(
    'a8888888-0000-4000-8000-000000000060',
    v_fixture.board_slug,
    v_fixture.task_id,
    v_fixture.expire_at_step_id,
    v_at_expiry
  );
  SELECT state INTO STRICT v_step_state
  FROM public.task_checklist_deletions
  WHERE step_id = v_fixture.expire_at_step_id;
  IF v_restored->>'status' IS DISTINCT FROM 'confirmed'
    OR v_replayed->>'status' IS DISTINCT FROM 'confirmed'
    OR jsonb_array_length(v_replayed->'task'->'steps') IS DISTINCT FROM 1
    OR v_replayed->'task'->'steps'->0->>'id'
      IS DISTINCT FROM v_fixture.restore_before_step_id::text
    OR v_expired->>'status' IS DISTINCT FROM 'expired'
    OR v_step_state IS DISTINCT FROM 'purged'
    OR EXISTS (
      SELECT 1 FROM public.task_checklist_deletions
      WHERE step_id = v_fixture.expire_at_step_id AND step_snapshot IS NOT NULL
    ) THEN
    RAISE EXCEPTION 'The exact 168-hour deadline did not separate restore and purge safely: % / % / %',
      v_restored, v_replayed, v_expired;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: checklist restoration wins just before 168 hours and expires at the exact deadline'

CREATE TABLE public.issue15_checklist_parent_purge_fixture (
  board_slug text NOT NULL,
  task_id uuid NOT NULL,
  step_id uuid NOT NULL
);
GRANT SELECT, INSERT ON public.issue15_checklist_parent_purge_fixture TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added jsonb;
  v_deleted jsonb;
  v_step_id uuid;
  v_parent_deleted jsonb;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Purga coordinada del paso padre #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000063'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000064',
    v_board.id,
    v_column_id,
    'Purga padre e hijo juntos'
  )->'task';
  v_added := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000065',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Dato que debe purgarse')
  );
  v_step_id := (v_added->'task'->'steps'->0->>'id')::uuid;
  v_deleted := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000066',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'delete',
      'step_id', v_step_id,
      'expected_version', 1
    )
  );
  v_parent_deleted := public.delete_task_p(
    'a8888888-0000-4000-8000-000000000067',
    v_board.slug,
    (v_task->>'id')::uuid
  );
  IF v_deleted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_parent_deleted->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not prepare parent and checklist purge: % / %',
      v_deleted, v_parent_deleted;
  END IF;
  INSERT INTO public.issue15_checklist_parent_purge_fixture(board_slug, task_id, step_id)
  VALUES (v_board.slug, (v_task->>'id')::uuid, v_step_id);
END;
$$;
COMMIT;

BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_fixture record;
  v_parent_expires_at timestamptz;
  v_purge_status text;
  v_child_state text;
  v_receipt_count integer;
BEGIN
  SELECT * INTO STRICT v_fixture
  FROM public.issue15_checklist_parent_purge_fixture;
  SELECT expires_at INTO STRICT v_parent_expires_at
  FROM public.task_deletions
  WHERE task_id = v_fixture.task_id;
  v_purge_status := public.purge_expired_task_internal_p(
    v_fixture.task_id,
    v_parent_expires_at
  );
  SELECT state INTO STRICT v_child_state
  FROM public.task_checklist_deletions
  WHERE step_id = v_fixture.step_id;
  SELECT count(*) INTO v_receipt_count
  FROM public.task_checklist_receipts
  WHERE task_id = v_fixture.task_id;
  IF v_purge_status IS DISTINCT FROM 'purged'
    OR v_child_state IS DISTINCT FROM 'purged'
    OR EXISTS (
      SELECT 1 FROM public.task_checklist_deletions
      WHERE step_id = v_fixture.step_id AND step_snapshot IS NOT NULL
    )
    OR v_receipt_count <> 0 THEN
    RAISE EXCEPTION 'Purging the parent retained child data or operation receipts: % / % / %',
      v_purge_status, v_child_state, v_receipt_count;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: purging a parent task also purges its separately deleted checklist snapshots'

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_task jsonb;
  v_added_first jsonb;
  v_added_second jsonb;
  v_preview jsonb;
  v_marked jsonb;
  v_stale_accept jsonb;
  v_accepted jsonb;
  v_reopened jsonb;
  v_marked_last jsonb;
  v_completed_all jsonb;
  v_reopened_all jsonb;
  v_first_step_id uuid;
  v_second_step_id uuid;
  v_reviewed_checklist_version bigint;
BEGIN
  SELECT * INTO v_board
  FROM public.create_board_p(
    'Confirmación vigente de checklist #15',
    'UTC',
    'a8888888-0000-4000-8000-000000000068'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Trabajo', 0);
  v_task := public.create_task_p(
    'a8888888-0000-4000-8000-000000000069',
    v_board.id,
    v_column_id,
    'Confirmar los pasos actuales'
  )->'task';
  v_added_first := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000070',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Revisar el contenido')
  );
  v_first_step_id := (v_added_first->'task'->'steps'->0->>'id')::uuid;
  v_added_second := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000071',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object('action', 'add', 'text', 'Guardar el resultado')
  );
  v_second_step_id := (v_added_second->'task'->'steps'->1->>'id')::uuid;
  v_preview := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000072',
    v_board.slug,
    (v_task->>'id')::uuid,
    true,
    1
  );
  v_reviewed_checklist_version := (v_preview->>'checklist_version')::bigint;
  IF v_preview->>'status' IS DISTINCT FROM 'confirmation_required'
    OR v_preview->>'pending_steps_count' IS DISTINCT FROM '2'
    OR v_preview->>'checklist_version' IS NULL
    OR v_preview->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_preview->'task'->>'completion_version' IS DISTINCT FROM '1'
    OR v_preview->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'false'
    OR v_preview->'task'->'steps'->1->>'is_completed' IS DISTINCT FROM 'false'
    OR v_preview->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Completion did not return a fresh, no-effect checklist confirmation preview: %',
      v_preview;
  END IF;

  -- One item changes while the confirmation dialog is open. The old review
  -- token must not complete the task, and the server returns the new count.
  v_marked := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000073',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'mark',
      'step_id', v_first_step_id,
      'is_completed', true,
      'expected_version', 1
    )
  );
  v_stale_accept := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000072',
    v_board.slug,
    (v_task->>'id')::uuid,
    true,
    1,
    v_reviewed_checklist_version
  );
  IF v_marked->>'status' IS DISTINCT FROM 'confirmed'
    OR v_stale_accept->>'status' IS DISTINCT FROM 'conflict'
    OR v_stale_accept->>'pending_steps_count' IS DISTINCT FROM '1'
    OR v_stale_accept->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_stale_accept->'task'->>'checklist_version' IS DISTINCT FROM '4' THEN
    RAISE EXCEPTION 'A stale checklist review completed the task or hid the new pending count: % / %',
      v_marked, v_stale_accept;
  END IF;

  v_accepted := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000072',
    v_board.slug,
    (v_task->>'id')::uuid,
    true,
    1,
    (v_stale_accept->>'checklist_version')::bigint
  );
  IF v_accepted->>'status' IS DISTINCT FROM 'confirmed'
    OR v_accepted->'task'->>'is_completed' IS DISTINCT FROM 'true'
    OR v_accepted->'task'->>'completion_version' IS DISTINCT FROM '2'
    OR v_accepted->'task'->'steps'->0->>'id' IS DISTINCT FROM v_first_step_id::text
    OR v_accepted->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_accepted->'task'->'steps'->1->>'id' IS DISTINCT FROM v_second_step_id::text
    OR v_accepted->'task'->'steps'->1->>'is_completed' IS DISTINCT FROM 'false'
    OR v_accepted->'task'->'field_versions' IS DISTINCT FROM v_task->'field_versions' THEN
    RAISE EXCEPTION 'Accepting the fresh count changed checklist marks or task fields: %',
      v_accepted;
  END IF;

  v_reopened := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000074',
    v_board.slug,
    (v_task->>'id')::uuid,
    false,
    2
  );
  IF v_reopened->>'status' IS DISTINCT FROM 'confirmed'
    OR v_reopened->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_reopened->'task'->>'completion_version' IS DISTINCT FROM '3'
    OR v_reopened->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_reopened->'task'->'steps'->1->>'is_completed' IS DISTINCT FROM 'false' THEN
    RAISE EXCEPTION 'Reopening changed checklist marks: %', v_reopened;
  END IF;

  v_marked_last := public.mutate_task_checklist_step_p(
    'a8888888-0000-4000-8000-000000000075',
    v_board.slug,
    (v_task->>'id')::uuid,
    jsonb_build_object(
      'action', 'mark',
      'step_id', v_second_step_id,
      'is_completed', true,
      'expected_version', 1
    )
  );
  IF v_marked_last->>'status' IS DISTINCT FROM 'confirmed'
    OR v_marked_last->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_marked_last->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_marked_last->'task'->'steps'->1->>'is_completed' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Marking every checklist step completed also completed the task: %',
      v_marked_last;
  END IF;
  v_completed_all := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000076',
    v_board.slug,
    (v_task->>'id')::uuid,
    true,
    3
  );
  v_reopened_all := public.set_task_completion_p(
    'a8888888-0000-4000-8000-000000000077',
    v_board.slug,
    (v_task->>'id')::uuid,
    false,
    4
  );
  IF v_completed_all->>'status' IS DISTINCT FROM 'confirmed'
    OR v_completed_all->'task'->>'is_completed' IS DISTINCT FROM 'true'
    OR v_reopened_all->>'status' IS DISTINCT FROM 'confirmed'
    OR v_reopened_all->'task'->>'is_completed' IS DISTINCT FROM 'false'
    OR v_reopened_all->'task'->'steps'->0->>'is_completed' IS DISTINCT FROM 'true'
    OR v_reopened_all->'task'->'steps'->1->>'is_completed' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Completing with no pending steps or reopening lost the current marks: % / %',
      v_completed_all, v_reopened_all;
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: completion reviews fresh checklist state, confirms explicitly, and preserves marks'
