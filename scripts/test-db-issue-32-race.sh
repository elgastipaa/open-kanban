#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-32-race.sh PSQL_BIN SOCKET_DIR PORT TEST_DIR' >&2
  exit 2
fi

psql_bin=$1
socket_dir=$2
port=$3
test_dir=$4
mkdir -p -- "$test_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

fixture=$("${psql[@]}" -qAtF '|' <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43200000-0000-4000-8000-000000000002', true) \gset
SELECT id AS board_id, slug AS board_slug
FROM public.create_board_p(
  'Issue #32 idempotent race', 'America/Argentina/Buenos_Aires',
  '32000000-0000-4000-8000-000000000040'
) \gset
SELECT (public.create_column_p(:'board_slug', :'board_id'::uuid, 'Pendientes', 0)).id
  AS column_id \gset
SELECT (public.create_task_p(
  '32000000-0000-4000-8000-000000000041', :'board_id'::uuid,
  :'column_id'::uuid, 'Origen de operación concurrente', 'Descripción', 'medium'
)->'task'->>'id')::uuid AS source_task_id \gset
SELECT public.preview_task_copy_p(:'board_slug', :'source_task_id'::uuid)
  #>> '{source_hash}' AS source_hash \gset
RESET ROLE;
SELECT :'board_id' || '|' || :'board_slug' || '|' || :'column_id' || '|'
  || :'source_task_id' || '|' || :'source_hash';
COMMIT;
SQL
)
IFS='|' read -r board_id board_slug column_id source_task_id source_hash <<< "$fixture"
if [[ -z "$board_id" || -z "$source_hash" ]]; then
  echo 'Issue #32 same-operation race fixture could not be created.' >&2
  exit 1
fi

operation_id=32000000-0000-4000-8000-000000000042
title='Copia de operación concurrente'
first_log="$test_dir/first.log"
second_log="$test_dir/second.log"

# The first transaction owns the board lock, creates the copy, and commits.
# The second call starts while that lock is held and then resolves the same
# receipt instead of creating a second row.
PGAPPNAME=openkanban_issue32_copy_first "${psql[@]}" -qAt \
  -v board_id="$board_id" -v board_slug="$board_slug" \
  -v source_task_id="$source_task_id" -v column_id="$column_id" \
  -v operation_id="$operation_id" -v title="$title" -v source_hash="$source_hash" \
  >"$first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT board.id FROM public.boards AS board
WHERE board.id = :'board_id'::uuid FOR UPDATE;
SELECT pg_sleep(2) /* issue32 first copy holds board lock */;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43200000-0000-4000-8000-000000000002', true) \gset
SELECT (result->>'status') || '|' || (result->>'task_id')
FROM (SELECT public.copy_task_p(
  :'operation_id'::uuid, :'board_slug', :'source_task_id'::uuid,
  :'column_id'::uuid, :'title', :'source_hash'
) AS result) AS copy_result;
COMMIT;
SQL
first_pid=$!

first_holding_lock=false
for _ in $(seq 1 120); do
  first_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue32_copy_first'
      AND state = 'active' AND query LIKE '%issue32 first copy holds board lock%'")
  if [[ "$first_state" == active ]]; then
    first_holding_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$first_holding_lock" != true ]]; then
  cat -- "$first_log" >&2
  echo 'Issue #32 first copy session did not acquire its board lock.' >&2
  wait "$first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue32_copy_second "${psql[@]}" -qAt \
  -v board_slug="$board_slug" -v source_task_id="$source_task_id" \
  -v column_id="$column_id" -v operation_id="$operation_id" \
  -v title="$title" -v source_hash="$source_hash" \
  >"$second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43200000-0000-4000-8000-000000000002', true) \gset
SELECT (result->>'status') || '|' || (result->>'task_id')
FROM (SELECT public.copy_task_p(
  :'operation_id'::uuid, :'board_slug', :'source_task_id'::uuid,
  :'column_id'::uuid, :'title', :'source_hash'
) AS result) AS copy_result;
COMMIT;
SQL
second_pid=$!

second_waiting=false
for _ in $(seq 1 120); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue32_copy_second'
      AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    second_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$second_waiting" != true ]]; then
  cat -- "$second_log" >&2
  echo 'Issue #32 duplicate operation did not wait behind the first transaction.' >&2
  wait "$first_pid" || true
  wait "$second_pid" || true
  exit 1
fi

first_exit=0
wait "$first_pid" || first_exit=$?
second_exit=0
wait "$second_pid" || second_exit=$?
first_result=$(grep -E '^confirmed\|[0-9a-f-]{36}$' "$first_log" | tail -n 1 || true)
second_result=$(grep -E '^confirmed\|[0-9a-f-]{36}$' "$second_log" | tail -n 1 || true)
if [[ "$first_exit" != 0 || "$second_exit" != 0 || -z "$first_result" \
  || "$first_result" != "$second_result" ]]; then
  cat -- "$first_log" "$second_log" >&2
  echo "Issue #32 same-operation race did not return the same copy (first=$first_exit, second=$second_exit)." >&2
  exit 1
fi

copy_checks=$("${psql[@]}" -qAtF '|' \
  -v operation_id="$operation_id" -v source_task_id="$source_task_id" <<'SQL'
SELECT
  (SELECT count(*) FROM public.task_copy_receipts AS receipt
   WHERE receipt.actor_id = '43200000-0000-4000-8000-000000000002'
     AND receipt.operation_id = :'operation_id'::uuid),
  (SELECT count(*) FROM public.tasks AS task
   WHERE task.id = (SELECT receipt.copied_task_id
     FROM public.task_copy_receipts AS receipt
     WHERE receipt.actor_id = '43200000-0000-4000-8000-000000000002'
       AND receipt.operation_id = :'operation_id'::uuid)
     AND task.title = 'Copia de operación concurrente'
     AND task.is_completed = false
     AND task.due_on IS NULL
     AND task.assignee_id IS NULL),
  (SELECT count(*) FROM public.tasks AS source
   WHERE source.id = :'source_task_id'::uuid
     AND source.title = 'Origen de operación concurrente')
SQL
)
if [[ "$copy_checks" != '1|1|1' ]]; then
  cat -- "$first_log" "$second_log" >&2
  echo "Issue #32 same-operation race assertions failed: $copy_checks" >&2
  exit 1
fi

echo 'PASS: concurrent retries with the same operation ID return one new pending task.'
