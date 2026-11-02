\set ON_ERROR_STOP on
\echo 'Checking date-only deadlines, board-local days, and owner time-zone preview'

CREATE TEMP TABLE issue11_date_refs (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  before_today_task uuid NOT NULL,
  after_today_task uuid NOT NULL,
  already_overdue_task uuid NOT NULL,
  completed_task uuid NOT NULL,
  before_today date NOT NULL,
  after_today date NOT NULL
);
GRANT SELECT, INSERT ON issue11_date_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column_id uuid;
  v_before_today date;
  v_after_today date;
  v_task_before_today jsonb;
  v_task_after_today jsonb;
  v_task_overdue jsonb;
  v_task_completed jsonb;
  v_result jsonb;
  v_conflict jsonb;
  v_preview jsonb;
  v_changed jsonb;
  v_full_board jsonb;
  v_rpc_today date;
  v_now timestamptz := statement_timestamp();
  v_invalid_date_denied boolean := false;
BEGIN
  IF public.board_calendar_day('America/Los_Angeles', '2026-11-01 01:00:00+00')
       IS DISTINCT FROM DATE '2026-10-31'
    OR public.board_calendar_day('Europe/Paris', '2026-11-01 01:00:00+00')
       IS DISTINCT FROM DATE '2026-11-01' THEN
    RAISE EXCEPTION 'IANA zones did not cross the controlled date boundary as expected';
  END IF;

  v_before_today := public.board_calendar_day('Etc/GMT+12', v_now);
  v_after_today := public.board_calendar_day('Pacific/Kiritimati', v_now);
  IF v_before_today >= v_after_today THEN
    RAISE EXCEPTION 'The fixture zones must differ by at least one board-local day';
  END IF;

  SELECT * INTO v_board
  FROM public.create_board_p(
    'Fechas puntuales y zonas',
    'Etc/GMT+12',
    'b1111111-0000-4000-8000-000000000001'
  );
  SELECT id INTO v_column_id
  FROM public.create_column_p(v_board.slug, v_board.id, 'Pendientes', 0);

  v_task_before_today := public.create_task_p(
    'b1111111-0000-4000-8000-000000000002', v_board.id, v_column_id, 'Vence hoy'
  )->'task';
  v_task_after_today := public.create_task_p(
    'b1111111-0000-4000-8000-000000000003', v_board.id, v_column_id, 'Vence en la nueva zona'
  )->'task';
  v_task_overdue := public.create_task_p(
    'b1111111-0000-4000-8000-000000000004', v_board.id, v_column_id, 'Ya vencida'
  )->'task';
  v_task_completed := public.create_task_p(
    'b1111111-0000-4000-8000-000000000005', v_board.id, v_column_id, 'Completada'
  )->'task';
  IF v_task_before_today->'due_on' IS DISTINCT FROM 'null'::jsonb
    OR v_task_after_today->'due_on' IS DISTINCT FROM 'null'::jsonb
    OR v_task_overdue->'due_on' IS DISTINCT FROM 'null'::jsonb
    OR v_task_completed->'due_on' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'A newly created task without a deadline did not keep due_on optional';
  END IF;

  v_result := public.edit_task_fields_p(
    'b1111111-0000-4000-8000-000000000006', v_board.slug,
    (v_task_before_today->>'id')::uuid,
    jsonb_build_object('due_on', v_before_today), '{"due_on":1}'::jsonb
  );
  IF v_result->>'status' <> 'confirmed'
    OR v_result->'task'->>'due_on' <> v_before_today::text THEN
    RAISE EXCEPTION 'Saving a date-only deadline did not preserve its calendar day: %', v_result;
  END IF;

  v_conflict := public.edit_task_fields_p(
    'b1111111-0000-4000-8000-000000000011', v_board.slug,
    (v_task_before_today->>'id')::uuid,
    jsonb_build_object('due_on', v_before_today + 3), '{"due_on":1}'::jsonb
  );
  IF v_conflict->>'status' <> 'conflict'
    OR v_conflict->'conflicts'->'due_on'->>'current' <> v_before_today::text
    OR v_conflict->'conflicts'->'due_on'->>'draft' <> (v_before_today + 3)::text
    OR v_conflict->'task'->>'due_on' <> v_before_today::text THEN
    RAISE EXCEPTION 'A stale deadline edit did not preserve the current date and draft: %', v_conflict;
  END IF;

  BEGIN
    PERFORM public.edit_task_fields_p(
      'b1111111-0000-4000-8000-000000000012', v_board.slug,
      (v_task_before_today->>'id')::uuid,
      '{"due_on":"infinity"}'::jsonb, '{"due_on":2}'::jsonb
    );
  EXCEPTION WHEN invalid_parameter_value THEN
    v_invalid_date_denied := true;
  END;
  IF NOT v_invalid_date_denied THEN
    RAISE EXCEPTION 'The special DATE value infinity was accepted as a task deadline';
  END IF;

  v_result := public.edit_task_fields_p(
    'b1111111-0000-4000-8000-000000000007', v_board.slug,
    (v_task_after_today->>'id')::uuid,
    jsonb_build_object('due_on', v_after_today), '{"due_on":1}'::jsonb
  );
  IF v_result->>'status' <> 'confirmed'
    OR v_result->'task'->>'due_on' <> v_after_today::text THEN
    RAISE EXCEPTION 'The second IANA-zone deadline did not persist as a DATE: %', v_result;
  END IF;

  v_result := public.edit_task_fields_p(
    'b1111111-0000-4000-8000-000000000008', v_board.slug,
    (v_task_overdue->>'id')::uuid,
    jsonb_build_object('due_on', v_before_today - 1), '{"due_on":1}'::jsonb
  );
  IF v_result->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'The overdue fixture deadline did not save: %', v_result;
  END IF;

  v_result := public.edit_task_fields_p(
    'b1111111-0000-4000-8000-000000000009', v_board.slug,
    (v_task_completed->>'id')::uuid,
    jsonb_build_object('due_on', v_before_today), '{"due_on":1}'::jsonb
  );
  IF v_result->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'The completed fixture deadline did not save: %', v_result;
  END IF;
  v_result := public.set_task_completion_p(
    'b1111111-0000-4000-8000-000000000010', v_board.slug,
    (v_task_completed->>'id')::uuid, true, 1
  );
  IF v_result->>'status' <> 'confirmed' THEN
    RAISE EXCEPTION 'The completed fixture task could not be completed: %', v_result;
  END IF;

  v_preview := public.preview_board_time_zone_p(v_board.slug, 'Pacific/Kiritimati');
  IF v_preview->>'time_zone' <> 'Etc/GMT+12'
    OR v_preview->>'preview_time_zone' <> 'Pacific/Kiritimati'
    OR v_preview->>'due_dates_unchanged' <> 'true'
    OR (v_preview->>'due_today_before')::integer <> 1
    OR (v_preview->>'overdue_before')::integer <> 1
    OR (v_preview->>'due_today_after')::integer <> 1
    OR (v_preview->>'overdue_after')::integer <> 2 THEN
    RAISE EXCEPTION 'The preview did not explain the board-local date change: %', v_preview;
  END IF;

  v_changed := public.update_board_time_zone_p(
    v_board.slug, 'Etc/GMT+12', 'Pacific/Kiritimati'
  );
  IF v_changed->>'time_zone' <> 'Pacific/Kiritimati'
    OR v_changed->>'role' <> 'owner' THEN
    RAISE EXCEPTION 'The owner did not update the board time zone: %', v_changed;
  END IF;

  SELECT today INTO v_rpc_today
  FROM public.get_board_p(v_board.slug);
  v_full_board := public.get_full_board_p(v_board.slug)::jsonb;
  IF v_rpc_today IS DISTINCT FROM v_after_today
    OR v_full_board->'board'->>'today' IS DISTINCT FROM v_after_today::text THEN
    RAISE EXCEPTION 'Board read RPCs did not return the new board-local day';
  END IF;

  IF (SELECT count(*) FROM public.tasks WHERE column_id = v_column_id) <> 4
    OR NOT EXISTS (
      SELECT 1 FROM public.tasks
      WHERE id = (v_task_before_today->>'id')::uuid
        AND due_on = v_before_today
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.tasks
      WHERE id = (v_task_after_today->>'id')::uuid
        AND due_on = v_after_today
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.tasks
      WHERE id = (v_task_overdue->>'id')::uuid
        AND due_on = v_before_today - 1
    )
    OR NOT EXISTS (
      SELECT 1 FROM public.tasks
      WHERE id = (v_task_completed->>'id')::uuid
        AND due_on = v_before_today
    ) THEN
    RAISE EXCEPTION 'Changing a board zone rewrote or removed a saved due date';
  END IF;

  v_result := public.edit_task_fields_p(
    'b1111111-0000-4000-8000-000000000013', v_board.slug,
    (v_task_before_today->>'id')::uuid,
    '{"due_on":null}'::jsonb, '{"due_on":2}'::jsonb
  );
  IF v_result->>'status' <> 'confirmed'
    OR v_result->'task'->>'due_on' IS NOT NULL THEN
    RAISE EXCEPTION 'The optional date could not be cleared: %', v_result;
  END IF;

  INSERT INTO issue11_date_refs VALUES (
    v_board.id, v_board.slug, v_column_id,
    (v_task_before_today->>'id')::uuid,
    (v_task_after_today->>'id')::uuid,
    (v_task_overdue->>'id')::uuid,
    (v_task_completed->>'id')::uuid,
    v_before_today, v_after_today
  );
END;
$$;
COMMIT;

INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, '40000000-0000-4000-8000-000000000005', 'collaborator'
FROM issue11_date_refs;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
DO $$
DECLARE
  v_fixture record;
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue11_date_refs;
  BEGIN
    PERFORM public.preview_board_time_zone_p(v_fixture.board_slug, 'Europe/Paris');
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A collaborator previewed an owner-only time-zone change';
  END IF;
  v_denied := false;
  BEGIN
    PERFORM public.update_board_time_zone_p(
      v_fixture.board_slug, 'Pacific/Kiritimati', 'Europe/Paris'
    );
  EXCEPTION WHEN insufficient_privilege THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A collaborator changed the board time zone';
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
  v_denied boolean := false;
BEGIN
  SELECT * INTO STRICT v_fixture FROM issue11_date_refs;
  BEGIN
    PERFORM public.update_board_time_zone_p(
      v_fixture.board_slug, 'Etc/GMT+12', 'Europe/Paris'
    );
  EXCEPTION WHEN check_violation THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A stale preview overwrote another time-zone change';
  END IF;
END;
$$;
COMMIT;

\echo 'PASS: optional DATE deadlines, controlled IANA day changes, owner preview/update, and unchanged due dates'
