#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-28-restore-purge-race.sh PSQL_BIN SOCKET_DIR PORT TEST_DIR' >&2
  exit 2
fi
psql_bin=$1
socket_dir=$2
port=$3
test_dir=$4
mkdir -p -- "$test_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

wait_for_blocker() {
  local app=$1
  local blocker=$2
  local count
  for _ in $(seq 1 120); do
    count=$("${psql[@]}" -At -v app="$app" -v blocker="$blocker" <<'SQL'
SELECT count(*) FROM pg_stat_activity AS activity
WHERE activity.application_name = :'app' AND activity.wait_event_type = 'Lock'
  AND EXISTS (
    SELECT 1 FROM unnest(pg_catalog.pg_blocking_pids(activity.pid)) AS blocker_pid(pid)
    JOIN pg_stat_activity AS blocker ON blocker.pid = blocker_pid.pid
    WHERE blocker.application_name = :'blocker'
  );
SQL
    )
    if [[ "$count" == 1 ]]; then return 0; fi
    sleep 0.05
  done
  return 1
}

capture_blocker() {
  local app=$1
  local blocker=$2
  local output=$3
  "${psql[@]}" -At -v app="$app" -v blocker="$blocker" <<'SQL' > "$output"
SELECT pg_catalog.format(
  'waiter=%s pid=%s event=%s.%s blocker=%s pid=%s query=%s',
  activity.application_name, activity.pid,
  activity.wait_event_type, activity.wait_event,
  blocker.application_name, blocker.pid,
  pg_catalog.left(blocker.query, 160)
)
FROM pg_stat_activity AS activity
CROSS JOIN LATERAL unnest(pg_catalog.pg_blocking_pids(activity.pid)) AS blocker_pid(pid)
JOIN pg_stat_activity AS blocker ON blocker.pid = blocker_pid.pid
WHERE activity.application_name = :'app'
  AND blocker.application_name = :'blocker';
SQL
  "${psql[@]}" -At -v app="$app" -v blocker="$blocker" <<'SQL' >> "$output"
SELECT pg_catalog.format(
  'lock app=%s pid=%s type=%s relation=%s page=%s tuple=%s transaction=%s mode=%s granted=%s',
  activity.application_name, lock.pid, lock.locktype,
  lock.relation::regclass, lock.page, lock.tuple, lock.transactionid,
  lock.mode, lock.granted
)
FROM pg_locks AS lock
JOIN pg_stat_activity AS activity ON activity.pid = lock.pid
WHERE activity.application_name IN (:'app', :'blocker')
ORDER BY activity.application_name, lock.granted, lock.locktype, lock.mode;
SQL
}

restore_fixture=$("${psql[@]}" -AtF '|' -c "
  SELECT board_slug, board_id, column_id, task_id, series_id, purge_at
  FROM public.issue28_task_purge_race_fixture WHERE scenario = 'restore_first'
")
IFS='|' read -r restore_slug restore_board_id restore_column_id restore_task_id \
  restore_series_id restore_purge_at <<< "$restore_fixture"
restore_live=$("${psql[@]}" -At -v task_id="$restore_task_id" <<'SQL'
SELECT EXISTS (SELECT 1 FROM public.tasks WHERE id = :'task_id'::uuid);
SQL
)
if [[ "$restore_live" != f ]]; then
  echo 'Restore/purge fixture candidate is still live in public.tasks.' >&2
  exit 1
fi

restore_log="$test_dir/restore-first.log"
purge_log="$test_dir/purge-after-restore.log"
restore_blockers="$test_dir/restore-first-board-blocker.log"
PGAPPNAME=openkanban_issue28_restore_first "${psql[@]}" -qAt \
  -v slug="$restore_slug" -v board_id="$restore_board_id" \
  -v column_id="$restore_column_id" -v task_id="$restore_task_id" \
  > "$restore_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL deadlock_timeout = '12s';
SELECT board.id FROM public.boards AS board
WHERE board.id = :'board_id'::uuid FOR UPDATE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT pg_sleep(15);
SELECT public.restore_task_p(
  '42800000-0000-4000-8000-000000000630', :'slug', :'task_id'::uuid,
  :'column_id'::uuid
)->>'status';
COMMIT;
SQL
restore_pid=$!

restore_holding_board=false
for _ in $(seq 1 120); do
  restore_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue28_restore_first'
      AND state = 'active' AND query LIKE '%pg_sleep(15)%'")
  if [[ "$restore_state" == active ]]; then
    restore_holding_board=true
    break
  fi
  sleep 0.05
done
if [[ "$restore_holding_board" != true ]]; then
  cat -- "$restore_log" >&2
  echo 'Restore transaction did not reach the board-lock hold point.' >&2
  wait "$restore_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue28_purge_after_restore "${psql[@]}" -qAt \
  -v purge_at="$restore_purge_at" > "$purge_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL deadlock_timeout = '12s';
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.purge_daily_repetition_tasks_internal_p(1, :'purge_at'::timestamptz);
COMMIT;
SQL
purge_pid=$!
if ! wait_for_blocker openkanban_issue28_purge_after_restore openkanban_issue28_restore_first; then
  cat -- "$restore_log" "$purge_log" >&2
  wait "$restore_pid" || true
  wait "$purge_pid" || true
  echo 'Purge did not wait on the restore transaction owning the board.' >&2
  exit 1
fi
capture_blocker openkanban_issue28_purge_after_restore \
  openkanban_issue28_restore_first "$restore_blockers"

cycle_observed=false
for _ in $(seq 1 600); do
  cycle_count=$("${psql[@]}" -At <<'SQL'
SELECT count(*)
FROM pg_stat_activity AS restore_activity
WHERE restore_activity.application_name = 'openkanban_issue28_restore_first'
  AND restore_activity.wait_event_type = 'Lock'
  AND EXISTS (
    SELECT 1 FROM unnest(pg_catalog.pg_blocking_pids(restore_activity.pid)) AS blocker_pid(pid)
    JOIN pg_stat_activity AS purger ON purger.pid = blocker_pid.pid
    WHERE purger.application_name = 'openkanban_issue28_purge_after_restore'
      AND purger.wait_event_type = 'Lock'
      AND EXISTS (
        SELECT 1 FROM unnest(pg_catalog.pg_blocking_pids(purger.pid)) AS restore_pid(pid)
        JOIN pg_stat_activity AS owner ON owner.pid = restore_pid.pid
        WHERE owner.application_name = 'openkanban_issue28_restore_first'
      )
  );
SQL
  )
  if [[ "$cycle_count" == 1 ]]; then
    cycle_observed=true
    capture_blocker openkanban_issue28_restore_first \
      openkanban_issue28_purge_after_restore "$test_dir/restore-waits-on-purge.log"
    capture_blocker openkanban_issue28_purge_after_restore \
      openkanban_issue28_restore_first "$test_dir/purge-waits-on-restore.log"
    break
  fi
  restore_exists=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue28_restore_first'")
  if [[ "$restore_exists" == 0 ]]; then break; fi
  sleep 0.05
done

restore_status=0
purge_status=0
wait "$restore_pid" || restore_status=$?
wait "$purge_pid" || purge_status=$?
if [[ "$restore_status" != 0 || "$purge_status" != 0 ]] \
  || ! grep -Fxq 'confirmed' "$restore_log" \
  || ! grep -Fxq '0' "$purge_log"; then
  cat -- "$restore_blockers" "$test_dir/restore-waits-on-purge.log" \
    "$test_dir/purge-waits-on-restore.log" "$restore_log" "$purge_log" >&2
  echo 'Restore-first/purge-second deadlocked or returned unexpected results.' >&2
  exit 1
fi
restored_state=$("${psql[@]}" -At -v task_id="$restore_task_id" \
  -v series_id="$restore_series_id" <<'SQL'
SELECT CASE WHEN deletion.state = 'restored' AND deletion.task_snapshot IS NULL
  AND task.id = deletion.task_id AND occurrence.state = 'current'
  AND series.current_occurrence_id = occurrence.id
  THEN 'ok' ELSE 'bad' END
FROM public.task_deletions AS deletion
JOIN public.tasks AS task ON task.id = deletion.task_id
JOIN public.daily_repetition_occurrences AS occurrence
  ON occurrence.task_id = task.id AND occurrence.series_id = :'series_id'::uuid
JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
WHERE deletion.task_id = :'task_id'::uuid;
SQL
)
if [[ "$restored_state" != ok || "$cycle_observed" == true ]]; then
  cat -- "$restore_blockers" "$test_dir/restore-waits-on-purge.log" \
    "$test_dir/purge-waits-on-restore.log" >&2
  echo 'Restore-first did not complete without a restore/purge lock cycle.' >&2
  exit 1
fi
echo 'PASS: restore-first purger waits on board without pre-locking task_deletions.'

purge_fixture=$("${psql[@]}" -AtF '|' -c "
  SELECT board_slug, column_id, task_id, series_id, purge_at
  FROM public.issue28_task_purge_race_fixture WHERE scenario = 'purge_first_restore'
")
IFS='|' read -r purge_slug purge_column_id purge_task_id purge_series_id \
  purge_at <<< "$purge_fixture"
purge_live=$("${psql[@]}" -At -v task_id="$purge_task_id" <<'SQL'
SELECT EXISTS (SELECT 1 FROM public.tasks WHERE id = :'task_id'::uuid);
SQL
)
if [[ "$purge_live" != f ]]; then
  echo 'Purge-first fixture candidate is still live in public.tasks.' >&2
  exit 1
fi
purge_first_log="$test_dir/purge-first.log"
restore_after_purge_log="$test_dir/restore-after-purge.log"
purge_first_blockers="$test_dir/purge-first-blocker.log"
PGAPPNAME=openkanban_issue28_purge_first "${psql[@]}" -qAt \
  -v purge_at="$purge_at" > "$purge_first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.purge_daily_repetition_tasks_internal_p(1, :'purge_at'::timestamptz);
SELECT pg_sleep(8);
COMMIT;
SQL
purge_first_pid=$!
purge_holding_board=false
for _ in $(seq 1 120); do
  purge_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue28_purge_first'
      AND state = 'active' AND query LIKE '%pg_sleep(8)%'")
  if [[ "$purge_state" == active ]]; then
    purge_holding_board=true
    break
  fi
  sleep 0.05
done
if [[ "$purge_holding_board" != true ]]; then
  cat -- "$purge_first_log" >&2
  echo 'Purge-first transaction did not reach its board-lock hold point.' >&2
  wait "$purge_first_pid" || true
  exit 1
fi
PGAPPNAME=openkanban_issue28_restore_after_purge "${psql[@]}" -qAt \
  -v slug="$purge_slug" -v column_id="$purge_column_id" \
  -v task_id="$purge_task_id" > "$restore_after_purge_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT public.restore_task_p(
  '42800000-0000-4000-8000-000000000631', :'slug', :'task_id'::uuid,
  :'column_id'::uuid
)->>'status';
COMMIT;
SQL
restore_after_purge_pid=$!
if ! wait_for_blocker openkanban_issue28_restore_after_purge openkanban_issue28_purge_first; then
  cat -- "$purge_first_log" "$restore_after_purge_log" >&2
  wait "$purge_first_pid" || true
  wait "$restore_after_purge_pid" || true
  echo 'Restore after purge did not wait on the purger.' >&2
  exit 1
fi
capture_blocker openkanban_issue28_restore_after_purge \
  openkanban_issue28_purge_first "$purge_first_blockers"
wait "$purge_first_pid" || { cat -- "$purge_first_log" >&2; exit 1; }
wait "$restore_after_purge_pid" || { cat -- "$restore_after_purge_log" >&2; exit 1; }
if ! grep -Fxq '1' "$purge_first_log" \
  || ! grep -Fxq 'unavailable' "$restore_after_purge_log"; then
  cat -- "$purge_first_blockers" "$purge_first_log" "$restore_after_purge_log" >&2
  echo 'Purge-first/restore-second did not purge once and deny recovery generically.' >&2
  exit 1
fi
purged_state=$("${psql[@]}" -At -v task_id="$purge_task_id" \
  -v series_id="$purge_series_id" <<'SQL'
SELECT CASE WHEN deletion.state = 'purged' AND deletion.task_snapshot IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = :'task_id'::uuid)
  AND occurrence.state = 'purged' AND series.current_occurrence_id IS NULL
  THEN 'ok' ELSE 'bad' END
FROM public.task_deletions AS deletion
JOIN public.daily_repetition_occurrences AS occurrence
  ON occurrence.task_id = deletion.task_id AND occurrence.series_id = :'series_id'::uuid
JOIN public.daily_repetition_series AS series ON series.id = occurrence.series_id
WHERE deletion.task_id = :'task_id'::uuid;
SQL
)
if [[ "$purged_state" != ok ]]; then
  echo 'Purge-first did not retain only purged history or restore a task.' >&2
  exit 1
fi
echo 'PASS: restore and expiry purge serialize in both orders without deadlock.'
