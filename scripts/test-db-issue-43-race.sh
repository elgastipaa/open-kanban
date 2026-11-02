#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-43-race.sh PSQL TEST_DIR PORT RACE_DIR' >&2
  exit 2
fi
psql_bin=$1
test_dir=$2
port=$3
race_dir=$4
mkdir -p -- "$race_dir"
editor_log="$race_dir/editor.log"
confirm_log="$race_dir/confirm.log"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$test_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

IFS='|' read -r board_slug task_id owner_id active_generation_id title_version < <(
  "${psql[@]}" -AtF '|' -c \
    "SELECT board.slug, task.id, fixture.owner_id, board.active_generation_id, task.field_versions->>'title'
     FROM public.issue43_import_fixture AS fixture
     JOIN public.boards AS board ON board.id = fixture.board_id
     JOIN public.columns AS column_row ON column_row.board_id = board.id
       AND column_row.generation_id = board.active_generation_id
     JOIN public.tasks AS task ON task.column_id = column_row.id
     ORDER BY column_row.position, task.position, task.id LIMIT 1"
)

preview_revision=$("${psql[@]}" -qAt <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$owner_id', true) AS actor \gset
SELECT public.prepare_board_import_p(
  '$board_slug', 'a4360000-0000-4000-8000-000000000005', repeat('d', 64),
  '{"columns":[{"title":"Importación en carrera","position":0,"tasks":[]}]}'::jsonb
)->>'content_revision' AS revision \gset
\echo :revision
COMMIT;
SQL
)
if [[ ! "$preview_revision" =~ ^[0-9]+$ ]]; then
  echo "Could not prepare a race preview; received '$preview_revision'." >&2
  exit 1
fi

PGAPPNAME=openkanban_issue43_editor "${psql[@]}" -q > "$editor_log" 2>&1 <<SQL &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$owner_id', true);
SELECT public.issue43_hold_board_lock_p('$board_slug', 3);
SELECT public.edit_task_fields_p(
  'a4370000-0000-4000-8000-000000000005', '$board_slug', '$task_id',
  '{"title":"Edit confirmada en la carrera"}'::jsonb, '{"title":$title_version}'::jsonb
);
COMMIT;
SQL
editor_pid=$!

editor_locked=false
for _ in $(seq 1 100); do
  editor_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue43_editor' AND state = 'active' AND query LIKE '%issue43_hold_board_lock_p%'")
  if [[ "$editor_state" == active ]]; then
    editor_locked=true
    break
  fi
  sleep 0.05
done
if [[ "$editor_locked" != true ]]; then
  cat -- "$editor_log" >&2
  echo 'The concurrent editor did not acquire the board lock.' >&2
  wait "$editor_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue43_import_confirm "${psql[@]}" -qAt > "$confirm_log" 2>&1 <<SQL &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$owner_id', true);
SELECT public.confirm_board_import_p(
  '$board_slug', 'a4360000-0000-4000-8000-000000000005',
  $preview_revision, repeat('d', 64)
);
COMMIT;
SQL
confirm_pid=$!

confirm_waiting=false
for _ in $(seq 1 100); do
  wait_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue43_import_confirm' AND wait_event_type = 'Lock'")
  if [[ "$wait_count" == 1 ]]; then
    confirm_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$confirm_waiting" != true ]]; then
  cat -- "$confirm_log" >&2
  echo 'The import confirmation did not wait on the concurrent editor.' >&2
  wait "$editor_pid" || true
  wait "$confirm_pid" || true
  exit 1
fi

wait "$editor_pid" || { cat -- "$editor_log" >&2; exit 1; }
wait "$confirm_pid" || { cat -- "$confirm_log" >&2; exit 1; }
result_status=$("${psql[@]}" -At <<SQL
SELECT operation.status
FROM public.board_import_operations AS operation
WHERE operation.actor_id = '$owner_id'
  AND operation.operation_id = 'a4360000-0000-4000-8000-000000000005';
SQL
)
board_state=$("${psql[@]}" -AtF '|' -c \
  "SELECT board.active_generation_id, task.title FROM public.boards AS board JOIN public.tasks AS task ON task.id = '$task_id' WHERE board.slug = '$board_slug'")
if [[ "$result_status" != conflict || "$board_state" != "$active_generation_id|Edit confirmada en la carrera" ]]; then
  cat -- "$editor_log" >&2
  cat -- "$confirm_log" >&2
  echo "A concurrent edit was not preserved and rejected: operation='$result_status', board='$board_state'." >&2
  exit 1
fi

echo 'PASS: a board edit committed while import confirmation waited, so the stale generation was not published.'
