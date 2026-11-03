#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-28-race.sh PSQL_BIN SOCKET_DIR PORT TEST_DIR' >&2
  exit 2
fi
psql_bin=$1
socket_dir=$2
port=$3
test_dir=$4
mkdir -p -- "$test_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

race_fixture=$(${psql[@]} -AtF '|' -c "SELECT board_id, board_slug, series_id, series_revision, job_id, lease_token FROM public.issue28_recovery_race_fixture WHERE scenario = 'worker_delete'")
IFS='|' read -r worker_board_id worker_slug worker_series_id worker_revision worker_job_id worker_lease_token <<< "$race_fixture"
worker_log="$test_dir/worker.log"
delete_log="$test_dir/delete.log"

PGAPPNAME=openkanban_issue28_worker "${psql[@]}" -qAt \
  -v job_id="$worker_job_id" -v lease_token="$worker_lease_token" \
  > "$worker_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT set_config('request.jwt.claim.role', 'service_role', true);
UPDATE public.daily_repetition_jobs AS job
SET state = 'leased', lease_token = :'lease_token'::uuid,
    lease_expires_at = current_date::timestamptz + interval '1 day',
    available_at = current_date::timestamptz,
    attempt_count = job.attempt_count + 1
WHERE job.id = :'job_id'::uuid AND job.state IN ('queued', 'retry_wait');
SELECT public.process_daily_repetition_job_internal_p(
  :'job_id'::uuid, :'lease_token'::uuid,
  current_date::timestamptz + interval '12 hours'
)->>'status';
SELECT pg_sleep(5);
COMMIT;
SQL
worker_pid=$!

worker_holding_board=false
for _ in $(seq 1 120); do
  worker_state=$(${psql[@]} -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue28_worker' AND state = 'active' AND query LIKE '%pg_sleep(5)%'")
  if [[ "$worker_state" == active ]]; then
    worker_holding_board=true
    break
  fi
  sleep 0.05
done
if [[ "$worker_holding_board" != true ]]; then
  cat -- "$worker_log" >&2
  echo 'Worker did not reach its board-lock hold point.' >&2
  wait "$worker_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue28_delete_vs_worker "${psql[@]}" -qAt \
  -v slug="$worker_slug" -v series_id="$worker_series_id" \
  -v expected_revision="$worker_revision" \
  > "$delete_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT public.delete_repetition_series_p(
  '42800000-0000-4000-8000-000000000239', :'slug', :'series_id'::uuid,
  :'expected_revision'::bigint, true
)->>'status';
COMMIT;
SQL
delete_pid=$!

delete_waiting=false
for _ in $(seq 1 120); do
  waiting_count=$(${psql[@]} -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue28_delete_vs_worker' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    delete_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$delete_waiting" != true ]]; then
  cat -- "$worker_log" "$delete_log" >&2
  echo 'Delete did not wait for the due worker transaction.' >&2
  wait "$worker_pid" || true
  wait "$delete_pid" || true
  exit 1
fi

wait "$worker_pid" || { cat -- "$worker_log" >&2; exit 1; }
wait "$delete_pid" || { cat -- "$delete_log" >&2; exit 1; }
if ! grep -qx 'confirmed' "$worker_log" || ! grep -qx 'conflict' "$delete_log"; then
  cat -- "$worker_log" "$delete_log" >&2
  echo 'Concurrent due worker/delete did not preserve the worker update and reject stale deletion.' >&2
  exit 1
fi
worker_state=$(${psql[@]} -At -v series_id="$worker_series_id" <<'SQL'
SELECT CASE WHEN series.state = 'active'
  AND series.revision > (SELECT fixture.series_revision
                         FROM public.issue28_recovery_race_fixture AS fixture
                         WHERE fixture.series_id = series.id)
  AND EXISTS (SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
              WHERE occurrence.series_id = series.id
                AND occurrence.occurrence_on = current_date)
  THEN 'ok' ELSE 'bad' END
FROM public.daily_repetition_series AS series WHERE series.id = :'series_id'::uuid;
SQL
)
if [[ "$worker_state" != ok ]]; then
  echo 'A successful worker update was lost after the stale delete race.' >&2
  exit 1
fi
echo 'PASS: a stale full-series delete waits for and cannot erase a due worker update.'

restore_fixture=$(${psql[@]} -AtF '|' -c "SELECT board_id, board_slug, series_id, series_revision FROM public.issue28_recovery_race_fixture WHERE scenario = 'delete_restore'")
IFS='|' read -r restore_board_id restore_slug restore_series_id restore_revision <<< "$restore_fixture"
delete_restore_log="$test_dir/delete-before-restore.log"
restore_log="$test_dir/restore-after-delete.log"

PGAPPNAME=openkanban_issue28_delete_parent "${psql[@]}" -qAt \
  -v slug="$restore_slug" -v series_id="$restore_series_id" \
  -v expected_revision="$restore_revision" \
  > "$delete_restore_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT public.delete_repetition_series_p(
  '42800000-0000-4000-8000-000000000240', :'slug', :'series_id'::uuid,
  :'expected_revision'::bigint, true
)->>'status';
SELECT pg_sleep(5);
COMMIT;
SQL
delete_restore_pid=$!

delete_parent_holding_board=false
for _ in $(seq 1 120); do
  delete_state=$(${psql[@]} -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue28_delete_parent' AND state = 'active' AND query LIKE '%pg_sleep(5)%'")
  if [[ "$delete_state" == active ]]; then
    delete_parent_holding_board=true
    break
  fi
  sleep 0.05
done
if [[ "$delete_parent_holding_board" != true ]]; then
  cat -- "$delete_restore_log" >&2
  echo 'Full-series delete did not reach its transaction hold point.' >&2
  wait "$delete_restore_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue28_restore_after_delete "${psql[@]}" -qAt \
  -v slug="$restore_slug" -v series_id="$restore_series_id" \
  > "$restore_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT public.restore_repetition_series_p(
  '42800000-0000-4000-8000-000000000241', :'slug', :'series_id'::uuid, NULL
)->>'status';
COMMIT;
SQL
restore_pid=$!

restore_waiting=false
for _ in $(seq 1 120); do
  waiting_count=$(${psql[@]} -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue28_restore_after_delete' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    restore_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$restore_waiting" != true ]]; then
  cat -- "$delete_restore_log" "$restore_log" >&2
  echo 'Series restore did not wait for the deleting parent transaction.' >&2
  wait "$delete_restore_pid" || true
  wait "$restore_pid" || true
  exit 1
fi

wait "$delete_restore_pid" || { cat -- "$delete_restore_log" >&2; exit 1; }
wait "$restore_pid" || { cat -- "$restore_log" >&2; exit 1; }
if ! grep -qx 'confirmed' "$delete_restore_log" || ! grep -qx 'confirmed' "$restore_log"; then
  cat -- "$delete_restore_log" "$restore_log" >&2
  echo 'Delete/restore race did not complete as one serialized recoverable transition.' >&2
  exit 1
fi
restored_state=$(${psql[@]} -At -v series_id="$restore_series_id" <<'SQL'
SELECT CASE WHEN deletion.state = 'restored'
  AND series.id IS NOT NULL
  AND task.id = (SELECT fixture.task_id FROM public.issue28_recovery_race_fixture AS fixture
                 WHERE fixture.series_id = series.id)
  AND NOT EXISTS (SELECT 1 FROM public.daily_repetition_jobs AS job
                  WHERE job.series_id = series.id AND job.job_kind = 'advance'
                    AND job.state IN ('queued', 'retry_wait', 'leased')
                    AND (job.series_revision <> series.revision
                      OR job.scheduled_on <> series.next_due_on))
  THEN 'ok' ELSE 'bad' END
FROM public.daily_repetition_series_deletions AS deletion
LEFT JOIN public.daily_repetition_series AS series ON series.id = deletion.series_id
LEFT JOIN public.tasks AS task ON task.id = series.first_task_id
WHERE deletion.series_id = :'series_id'::uuid;
SQL
)
if [[ "$restored_state" != ok ]]; then
  echo 'Delete/restore race did not restore the same active series with a valid future job.' >&2
  exit 1
fi
echo 'PASS: a restore waiting on full-series deletion rehydrates one valid series and future job.'

"${psql[@]}" -q <<'SQL'
CREATE TABLE public.issue28_purge_race_saved_tasks AS
SELECT deletion.task_id, deletion.deleted_at, deletion.expires_at
FROM public.task_deletions AS deletion
WHERE deletion.state = 'deleted'
  AND deletion.expires_at <= (
    SELECT max(fixture.purge_at) FROM public.issue28_task_purge_race_fixture AS fixture
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.issue28_task_purge_race_fixture AS fixture
    WHERE fixture.task_id = deletion.task_id
  );
WITH hold_clock AS MATERIALIZED (SELECT pg_catalog.clock_timestamp() AS now_at)
UPDATE public.task_deletions AS deletion
SET deleted_at = hold_clock.now_at,
    expires_at = hold_clock.now_at + interval '168 hours'
FROM hold_clock
WHERE deletion.task_id IN (
  SELECT saved.task_id FROM public.issue28_purge_race_saved_tasks AS saved
);
CREATE TABLE public.issue28_purge_race_saved_series AS
SELECT deletion.series_id, deletion.deleted_at, deletion.expires_at
FROM public.daily_repetition_series_deletions AS deletion
WHERE deletion.state = 'deleted'
  AND deletion.expires_at <= (
    SELECT max(fixture.purge_at) FROM public.issue28_task_purge_race_fixture AS fixture
  );
WITH hold_clock AS MATERIALIZED (SELECT pg_catalog.clock_timestamp() AS now_at)
UPDATE public.daily_repetition_series_deletions AS deletion
SET deleted_at = hold_clock.now_at,
    expires_at = hold_clock.now_at + interval '168 hours'
FROM hold_clock
WHERE deletion.series_id IN (
  SELECT saved.series_id FROM public.issue28_purge_race_saved_series AS saved
);
SQL

purge_first_fixture=$(${psql[@]} -AtF '|' -c "
  SELECT board_slug, task_id, series_id, series_revision, purge_at
  FROM public.issue28_task_purge_race_fixture WHERE scenario = 'purge_first'
")
IFS='|' read -r purge_first_slug purge_first_task_id purge_first_series_id \
  purge_first_revision purge_first_at <<< "$purge_first_fixture"
purge_first_log="$test_dir/purge-before-delete.log"
delete_after_purge_log="$test_dir/delete-after-purge.log"

PGAPPNAME=openkanban_issue28_purge_first "${psql[@]}" -qAt \
  -v purge_at="$purge_first_at" > "$purge_first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.purge_daily_repetition_tasks_internal_p(1, :'purge_at'::timestamptz);
SELECT pg_sleep(8);
COMMIT;
SQL
purge_first_pid=$!

purge_holding_board=false
for _ in $(seq 1 120); do
  purge_state=$(${psql[@]} -At -c "SELECT state FROM pg_stat_activity
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
  echo 'Individual occurrence purge did not reach its transaction hold point.' >&2
  wait "$purge_first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue28_delete_after_purge "${psql[@]}" -qAt \
  -v slug="$purge_first_slug" -v series_id="$purge_first_series_id" \
  -v expected_revision="$purge_first_revision" \
  > "$delete_after_purge_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT public.delete_repetition_series_p(
  '42800000-0000-4000-8000-000000000605', :'slug', :'series_id'::uuid,
  :'expected_revision'::bigint, true
)->>'status';
COMMIT;
SQL
delete_after_purge_pid=$!

delete_waiting_on_purge=false
for _ in $(seq 1 120); do
  waiting_count=$(${psql[@]} -At -v app='openkanban_issue28_delete_after_purge' \
    -v blocker='openkanban_issue28_purge_first' <<'SQL'
SELECT count(*) FROM pg_stat_activity AS activity
WHERE activity.application_name = :'app'
  AND activity.wait_event_type = 'Lock'
  AND EXISTS (
    SELECT 1
    FROM unnest(pg_catalog.pg_blocking_pids(activity.pid)) AS blocker_pid(pid)
    JOIN pg_stat_activity AS blocker ON blocker.pid = blocker_pid.pid
    WHERE blocker.application_name = :'blocker'
  );
SQL
  )
  if [[ "$waiting_count" == 1 ]]; then
    delete_waiting_on_purge=true
    break
  fi
  sleep 0.05
done
if [[ "$delete_waiting_on_purge" != true ]]; then
  cat -- "$purge_first_log" "$delete_after_purge_log" >&2
  echo 'Series delete did not serialize behind an individual occurrence purge.' >&2
  wait "$purge_first_pid" || true
  wait "$delete_after_purge_pid" || true
  exit 1
fi

wait "$purge_first_pid" || { cat -- "$purge_first_log" >&2; exit 1; }
wait "$delete_after_purge_pid" || { cat -- "$delete_after_purge_log" >&2; exit 1; }
if ! grep -Fxq '1' "$purge_first_log" \
  || ! grep -Fxq 'confirmed' "$delete_after_purge_log"; then
  cat -- "$purge_first_log" "$delete_after_purge_log" >&2
  echo 'Purge-first/delete-second did not finish as one serialized transition.' >&2
  exit 1
fi
purge_first_state=$(${psql[@]} -At -v task_id="$purge_first_task_id" \
  -v series_id="$purge_first_series_id" <<'SQL'
SELECT CASE WHEN task_deletion.state = 'purged'
  AND task_deletion.task_snapshot IS NULL
  AND task_deletion.cause = 'user_requested'
  AND task_deletion.parent_series_id = :'series_id'::uuid
  AND series_deletion.state = 'deleted'
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(series_deletion.occurrences_snapshot) AS slot(value)
    WHERE slot.value->>'task_id' = :'task_id'
      AND slot.value->>'state' = 'purged'
  )
  AND NOT EXISTS (SELECT 1 FROM public.daily_repetition_series AS series
                  WHERE series.id = :'series_id'::uuid)
  AND NOT EXISTS (SELECT 1 FROM public.daily_repetition_jobs AS job
                  WHERE job.series_id = :'series_id'::uuid)
  THEN 'ok' ELSE 'bad' END
FROM public.task_deletions AS task_deletion
JOIN public.daily_repetition_series_deletions AS series_deletion
  ON series_deletion.series_id = task_deletion.parent_series_id
WHERE task_deletion.task_id = :'task_id'::uuid;
SQL
)
if [[ "$purge_first_state" != ok ]]; then
  echo 'Purge-first ordering did not retain purged history without live series/jobs.' >&2
  exit 1
fi
echo 'PASS: individual occurrence purge serializes before full-series delete and cascades jobs.'

delete_first_fixture=$(${psql[@]} -AtF '|' -c "
  SELECT board_slug, task_id, series_id, series_revision, purge_at
  FROM public.issue28_task_purge_race_fixture WHERE scenario = 'delete_first'
")
IFS='|' read -r delete_first_slug delete_first_task_id delete_first_series_id \
  delete_first_revision delete_first_at <<< "$delete_first_fixture"
delete_first_log="$test_dir/delete-before-purge.log"
purge_after_delete_log="$test_dir/purge-after-delete.log"

PGAPPNAME=openkanban_issue28_delete_first "${psql[@]}" -qAt \
  -v slug="$delete_first_slug" -v series_id="$delete_first_series_id" \
  -v expected_revision="$delete_first_revision" \
  > "$delete_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '42700000-0000-4000-8000-000000000002', true);
SELECT public.delete_repetition_series_p(
  '42800000-0000-4000-8000-000000000606', :'slug', :'series_id'::uuid,
  :'expected_revision'::bigint, true
)->>'status';
SELECT pg_sleep(8);
COMMIT;
SQL
delete_first_pid=$!

delete_first_holding_board=false
for _ in $(seq 1 120); do
  delete_state=$(${psql[@]} -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue28_delete_first'
      AND state = 'active' AND query LIKE '%pg_sleep(8)%'")
  if [[ "$delete_state" == active ]]; then
    delete_first_holding_board=true
    break
  fi
  sleep 0.05
done
if [[ "$delete_first_holding_board" != true ]]; then
  cat -- "$delete_first_log" >&2
  echo 'Series delete did not reach its transaction hold point before purge.' >&2
  wait "$delete_first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue28_purge_after_delete "${psql[@]}" -qAt \
  -v purge_at="$delete_first_at" > "$purge_after_delete_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.purge_daily_repetition_tasks_internal_p(1, :'purge_at'::timestamptz);
COMMIT;
SQL
purge_after_delete_pid=$!

purge_waiting_on_delete=false
for _ in $(seq 1 120); do
  waiting_count=$(${psql[@]} -At -v app='openkanban_issue28_purge_after_delete' \
    -v blocker='openkanban_issue28_delete_first' <<'SQL'
SELECT count(*) FROM pg_stat_activity AS activity
WHERE activity.application_name = :'app'
  AND activity.wait_event_type = 'Lock'
  AND EXISTS (
    SELECT 1
    FROM unnest(pg_catalog.pg_blocking_pids(activity.pid)) AS blocker_pid(pid)
    JOIN pg_stat_activity AS blocker ON blocker.pid = blocker_pid.pid
    WHERE blocker.application_name = :'blocker'
  );
SQL
  )
  if [[ "$waiting_count" == 1 ]]; then
    purge_waiting_on_delete=true
    break
  fi
  sleep 0.05
done
if [[ "$purge_waiting_on_delete" != true ]]; then
  cat -- "$delete_first_log" "$purge_after_delete_log" >&2
  echo 'Expired occurrence purge did not wait for full-series delete.' >&2
  wait "$delete_first_pid" || true
  wait "$purge_after_delete_pid" || true
  exit 1
fi

wait "$delete_first_pid" || { cat -- "$delete_first_log" >&2; exit 1; }
wait "$purge_after_delete_pid" || { cat -- "$purge_after_delete_log" >&2; exit 1; }
if ! grep -Fxq 'confirmed' "$delete_first_log" \
  || ! grep -Fxq '1' "$purge_after_delete_log"; then
  cat -- "$delete_first_log" "$purge_after_delete_log" >&2
  echo 'Delete-first/purge-second did not finish as one serialized transition.' >&2
  exit 1
fi
delete_first_state=$(${psql[@]} -At -v task_id="$delete_first_task_id" \
  -v series_id="$delete_first_series_id" <<'SQL'
SELECT CASE WHEN task_deletion.state = 'purged'
  AND task_deletion.task_snapshot IS NULL
  AND task_deletion.cause = 'user_requested'
  AND task_deletion.parent_series_id = :'series_id'::uuid
  AND series_deletion.state = 'deleted'
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(series_deletion.occurrences_snapshot) AS slot(value)
    WHERE slot.value->>'task_id' = :'task_id'
      AND slot.value->>'state' = 'excluded'
  )
  AND NOT EXISTS (SELECT 1 FROM public.daily_repetition_occurrences AS occurrence
                  WHERE occurrence.series_id = :'series_id'::uuid)
  AND NOT EXISTS (SELECT 1 FROM public.daily_repetition_series AS series
                  WHERE series.id = :'series_id'::uuid)
  AND NOT EXISTS (SELECT 1 FROM public.daily_repetition_jobs AS job
                  WHERE job.series_id = :'series_id'::uuid)
  THEN 'ok' ELSE 'bad' END
FROM public.task_deletions AS task_deletion
JOIN public.daily_repetition_series_deletions AS series_deletion
  ON series_deletion.series_id = task_deletion.parent_series_id
WHERE task_deletion.task_id = :'task_id'::uuid;
SQL
)
if [[ "$delete_first_state" != ok ]]; then
  echo 'Delete-first purge did not complete after the parent occurrence was cascaded.' >&2
  exit 1
fi

"${psql[@]}" -q <<'SQL'
UPDATE public.task_deletions AS deletion
SET deleted_at = saved.deleted_at, expires_at = saved.expires_at
FROM public.issue28_purge_race_saved_tasks AS saved
WHERE deletion.task_id = saved.task_id;
DROP TABLE public.issue28_purge_race_saved_tasks;
UPDATE public.daily_repetition_series_deletions AS deletion
SET deleted_at = saved.deleted_at, expires_at = saved.expires_at
FROM public.issue28_purge_race_saved_series AS saved
WHERE deletion.series_id = saved.series_id;
DROP TABLE public.issue28_purge_race_saved_series;
SQL
echo 'PASS: individual occurrence purge and full-series delete serialize in both orders.'
bash "$(dirname -- "$0")/test-db-issue-28-restore-purge-race.sh" \
  "$psql_bin" "$socket_dir" "$port" "$test_dir/restore-purge"
