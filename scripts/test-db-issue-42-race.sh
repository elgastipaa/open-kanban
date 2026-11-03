#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-42-race.sh PSQL TEST_DIR PORT RACE_DIR' >&2
  exit 2
fi
psql_bin=$1
test_dir=$2
port=$3
race_dir=$4
mkdir -p -- "$race_dir"
editor_log="$race_dir/editor.log"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$test_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

IFS='|' read -r board_slug task_id < <(
  "${psql[@]}" -AtF '|' -c \
    "SELECT board_slug, task_id FROM issue42_export_fixture"
)

PGAPPNAME=openkanban_issue42_editor "${psql[@]}" > "$editor_log" 2>&1 <<SQL &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '84200000-0000-4000-8000-000000000001', true);
SELECT id FROM public.tasks WHERE id = '$task_id' FOR UPDATE;
SELECT pg_sleep(4);
UPDATE public.tasks SET title = 'Edit race committed' WHERE id = '$task_id';
COMMIT;
SQL
editor_pid=$!

editor_locked=false
for _ in $(seq 1 100); do
  editor_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue42_editor' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$editor_state" == active ]]; then
    editor_locked=true
    break
  fi
  sleep 0.05
done
if [[ "$editor_locked" != true ]]; then
  cat -- "$editor_log" >&2
  echo 'The edit race did not hold its task row.' >&2
  wait "$editor_pid" || true
  exit 1
fi

export_id=$("${psql[@]}" -At -v board_slug="$board_slug" <<'SQL'
SELECT public.create_board_export_snapshot_p(
  '84200000-0000-4000-8000-000000000001', :'board_slug'
)->>'export_id';
SQL
)
wait "$editor_pid" || { cat -- "$editor_log" >&2; exit 1; }

snapshot_title=$("${psql[@]}" -At -v export_id="$export_id" -v task_id="$task_id" <<'SQL'
SELECT payload->>'title'
FROM public.board_export_snapshot_items
WHERE export_id = :'export_id'::uuid
  AND entity = 'tasks'
  AND payload->>'id' = public.board_export_package_ref_p(
    :'export_id'::uuid, 'task', :'task_id'::uuid
  );
SQL
)
live_title=$("${psql[@]}" -At -v task_id="$task_id" <<'SQL'
SELECT title FROM public.tasks WHERE id = :'task_id'::uuid;
SQL
)
if [[ "$snapshot_title" != 'Editado después de capturar' \
  || "$live_title" != 'Edit race committed' ]]; then
  cat -- "$editor_log" >&2
  echo "A concurrent edit changed the snapshot: snapshot='$snapshot_title', live='$live_title'." >&2
  exit 1
fi

"${psql[@]}" -q -v export_id="$export_id" <<'SQL'
SELECT public.delete_board_export_snapshot_p(
  '84200000-0000-4000-8000-000000000001', :'export_id'::uuid
);
SQL
echo 'PASS: a task edit racing snapshot creation is isolated to the live board.'

export_log="$race_dir/export-pin.log"
purge_log="$race_dir/purge.log"
PGAPPNAME=openkanban_issue42_export_pin "${psql[@]}" -qAt \
  > "$export_log" 2>&1 <<SQL &
BEGIN;
SELECT public.create_board_export_snapshot_p(
  '84200000-0000-4000-8000-000000000001', '$board_slug'
)->>'export_id';
SELECT pg_sleep(4);
COMMIT;
SQL
export_pid=$!

export_lock_held=false
for _ in $(seq 1 100); do
  export_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue42_export_pin' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$export_state" == active ]]; then
    export_lock_held=true
    break
  fi
  sleep 0.05
done
if [[ "$export_lock_held" != true ]]; then
  cat -- "$export_log" >&2
  echo 'The export did not hold its active attachment pin lock.' >&2
  wait "$export_pid" || true
  exit 1
fi
PGAPPNAME=openkanban_issue42_purge_race "${psql[@]}" \
  > "$purge_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '84200000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_now_at timestamptz := pg_catalog.clock_timestamp();
  v_claimed integer;
BEGIN
  UPDATE public.task_attachments
  SET state = 'recoverable',
      deleted_at = v_now_at - interval '169 hours',
      deleted_by = '84200000-0000-4000-8000-000000000001',
      deletion_cause = 'author',
      expires_at = v_now_at - interval '1 hour'
  WHERE id = '84c00000-0000-4000-8000-000000000002';
  SELECT count(*) INTO v_claimed
  FROM public.claim_expired_task_attachment_cleanup_p(
    '84c20000-0000-4000-8000-000000000003', 50
  ) AS claimed
  WHERE claimed.attachment_id = '84c00000-0000-4000-8000-000000000002';
  IF v_claimed <> 0 THEN
    RAISE EXCEPTION 'Attachment purge claimed an object pinned by a concurrent export';
  END IF;
END;
$$;
COMMIT;
SQL
purge_pid=$!

purge_waiting=false
for _ in $(seq 1 100); do
  purge_waits=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue42_purge_race' AND wait_event_type = 'Lock'")
  if [[ "$purge_waits" == 1 ]]; then
    purge_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$purge_waiting" != true ]]; then
  cat -- "$purge_log" >&2
  echo 'The concurrent attachment delete did not wait on the export pin.' >&2
  wait "$purge_pid" || true
  wait "$export_pid" || true
  exit 1
fi

wait "$export_pid" || { cat -- "$export_log" >&2; exit 1; }
wait "$purge_pid" || { cat -- "$purge_log" >&2; exit 1; }
pin_export_id=$("${psql[@]}" -At \
  -c "SELECT id FROM public.board_export_snapshots WHERE actor_id = '84200000-0000-4000-8000-000000000001' ORDER BY created_at DESC LIMIT 1")

"${psql[@]}" -q -v export_id="$pin_export_id" <<'SQL'
SELECT set_config('test.issue42_export_id', :'export_id', false);
DO $$
DECLARE
  v_export_id uuid := pg_catalog.current_setting('test.issue42_export_id')::uuid;
  v_attachment public.task_attachments%ROWTYPE;
  v_claimed integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.board_export_attachment_pins AS pin
    WHERE pin.export_id = v_export_id
      AND pin.attachment_id = '84c00000-0000-4000-8000-000000000002'
  ) THEN
    RAISE EXCEPTION 'Concurrent export did not retain its attachment pin';
  END IF;
  SELECT * INTO v_attachment FROM public.task_attachments
  WHERE id = '84c00000-0000-4000-8000-000000000002';
  IF v_attachment.state <> 'recoverable'
    OR v_attachment.expires_at <> v_attachment.deleted_at + interval '168 hours' THEN
    RAISE EXCEPTION 'The concurrent export altered the recovery deadline';
  END IF;
  IF NOT public.delete_board_export_snapshot_p(
    '84200000-0000-4000-8000-000000000001', v_export_id
  ) THEN
    RAISE EXCEPTION 'The pin race export did not clean up';
  END IF;
  SELECT count(*) INTO v_claimed
  FROM public.claim_expired_task_attachment_cleanup_p(
    '84c20000-0000-4000-8000-000000000004', 50
  ) AS claimed
  WHERE claimed.attachment_id = v_attachment.id;
  IF v_claimed <> 1 OR NOT EXISTS (
    SELECT 1 FROM public.task_attachments AS attachment
    WHERE attachment.id = v_attachment.id
      AND attachment.state = 'purging'
      AND attachment.expires_at = v_attachment.expires_at
  ) THEN
    RAISE EXCEPTION 'Purge did not resume after the export pin was removed';
  END IF;
END;
$$;
SQL
echo 'PASS: a concurrent attachment purge waits for an export pin and keeps its original recovery cutoff.'
