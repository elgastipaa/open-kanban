\set ON_ERROR_STOP on
\echo 'Issue #31 upgrade regression: create a recoverable series tombstone before migration 056'

INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue31-upgrade@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES (
  '43110000-0000-4000-8000-000000000002',
  'issue31-upgrade@example.test', now(), '{"provider":"google"}'
);
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53110000-0000-4000-8000-000000000002',
  '43110000-0000-4000-8000-000000000002', 'google', 'issue31-upgrade-subject',
  '{"email":"issue31-upgrade@example.test","email_verified":true}'
);
UPDATE public.application_access
SET auth_user_id = '43110000-0000-4000-8000-000000000002',
    google_subject = 'issue31-upgrade-subject', state = 'active'
WHERE email = 'issue31-upgrade@example.test';

CREATE TABLE public.issue31_upgrade_refs (
  board_id uuid NOT NULL,
  board_slug text NOT NULL,
  column_id uuid NOT NULL,
  task_id uuid NOT NULL,
  series_id uuid NOT NULL,
  active_label_id uuid NOT NULL,
  hidden_label_id uuid NOT NULL,
  PRIMARY KEY (series_id)
);
GRANT SELECT, INSERT ON public.issue31_upgrade_refs TO authenticated;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43110000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_board record;
  v_column record;
  v_label_active jsonb;
  v_label_hidden jsonb;
  v_task jsonb;
  v_due jsonb;
  v_labels jsonb;
  v_series jsonb;
  v_deleted_label jsonb;
  v_status jsonb;
  v_deleted_series jsonb;
  v_active_label_id uuid;
  v_hidden_label_id uuid;
  v_task_id uuid;
BEGIN
  SELECT * INTO v_board FROM public.create_board_p(
    'Issue #31 upgrade before 056', 'America/Argentina/Buenos_Aires',
    '31500000-0000-4000-8000-000000000001'
  );
  SELECT * INTO v_column FROM public.create_column_p(
    v_board.slug, v_board.id, 'A organizar', 0
  );
  v_label_active := public.create_board_label_p(v_board.slug, 'Upgrade activa', 'blue');
  v_label_hidden := public.create_board_label_p(v_board.slug, 'Upgrade oculta', 'red');
  IF v_label_active->>'status' IS DISTINCT FROM 'confirmed'
    OR v_label_hidden->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create upgrade fixture labels: %, %', v_label_active, v_label_hidden;
  END IF;
  v_active_label_id := (v_label_active->'label'->>'id')::uuid;
  v_hidden_label_id := (v_label_hidden->'label'->>'id')::uuid;

  v_task := public.create_task_p(
    '31500000-0000-4000-8000-000000000002', v_board.id,
    v_column.id, 'Tarea actual upgrade', NULL, 'medium'
  );
  v_task_id := (v_task->>'task_id')::uuid;
  v_due := public.edit_task_fields_p(
    '31500000-0000-4000-8000-000000000003', v_board.slug, v_task_id,
    jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
  );
  IF v_due->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not set the upgrade fixture due date: %', v_due;
  END IF;
  v_labels := public.set_task_labels_p(
    v_board.slug, v_task_id, ARRAY[]::uuid[],
    ARRAY[v_active_label_id, v_hidden_label_id]::uuid[]
  );
  IF v_labels->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not set the upgrade fixture current labels: %', v_labels;
  END IF;
  v_series := public.create_repetition_with_advance_p(
    '31500000-0000-4000-8000-000000000004', v_board.slug, v_task_id,
    current_date, NULL, 5, 2, false, NULL,
    '{"frequency":"daily","interval":1}'::jsonb, 0, v_column.id
  );
  IF v_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the pre-056 series: %', v_series;
  END IF;
  v_deleted_label := public.delete_board_label_p(v_board.slug, v_hidden_label_id, 1);
  IF v_deleted_label->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not soft-delete one pre-056 label: %', v_deleted_label;
  END IF;
  v_status := public.get_repetition_p(v_board.slug, v_task_id);
  v_deleted_series := public.delete_repetition_series_p(
    '31500000-0000-4000-8000-000000000005', v_board.slug,
    (v_series->>'series_id')::uuid, (v_status->>'revision')::bigint, true
  );
  IF v_deleted_series->>'status' IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'Could not create the pre-056 series tombstone: %', v_deleted_series;
  END IF;
  INSERT INTO public.issue31_upgrade_refs(
    board_id, board_slug, column_id, task_id, series_id,
    active_label_id, hidden_label_id
  ) VALUES (
    v_board.id, v_board.slug, v_column.id, v_task_id,
    (v_series->>'series_id')::uuid, v_active_label_id, v_hidden_label_id
  );
END;
$$;
COMMIT;

DO $$
DECLARE
  v_ref public.issue31_upgrade_refs%ROWTYPE;
  v_deletion public.daily_repetition_series_deletions%ROWTYPE;
  v_task_deletion public.task_deletions%ROWTYPE;
  v_expected uuid[];
BEGIN
  SELECT * INTO STRICT v_ref FROM public.issue31_upgrade_refs;
  SELECT * INTO STRICT v_deletion FROM public.daily_repetition_series_deletions
  WHERE series_id = v_ref.series_id;
  SELECT * INTO STRICT v_task_deletion FROM public.task_deletions
  WHERE task_id = v_ref.task_id;
  SELECT array_agg(selected.id ORDER BY selected.id)
  INTO v_expected FROM unnest(ARRAY[v_ref.active_label_id, v_ref.hidden_label_id]) AS selected(id);
  IF v_deletion.state IS DISTINCT FROM 'deleted'
    OR v_deletion.series_snapshot ? 'template_label_ids'
    OR v_task_deletion.label_ids IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'Pre-056 tombstone fixture is not the expected legacy state: %, %',
      v_deletion.series_snapshot, v_task_deletion.label_ids;
  END IF;
END;
$$;
