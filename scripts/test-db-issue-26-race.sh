#!/usr/bin/env bash
set -euo pipefail

psql_bin=$1
socket_dir=$2
port=$3
log_dir=$4
mkdir -p -- "$log_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

race_ref=$("${psql[@]}" -qAt -F '|' -c "
  SELECT board_id, board_slug, task_id, series_id, revision, job_id,
    current_occurrence_id, current_column_id, current_due_on, edit_start_on, next_due_on
  FROM public.issue26_repetition_race_ref WHERE singleton
")
if [[ -z "$race_ref" ]]; then
  echo 'Issue #26 race fixture is missing.' >&2
  exit 1
fi
IFS='|' read -r board_id board_slug task_id series_id expected_revision job_id \
  current_occurrence_id current_column_id current_due_on edit_start_on next_due_on <<< "$race_ref"

# Keep the scheduler race isolated from unrelated durable jobs in the full DB
# suite, then restore every changed schedule after the assertions.
"${psql[@]}" -q -v race_job_id="$job_id" <<'SQL'
CREATE TABLE public.issue26_repetition_race_saved_jobs AS
SELECT id, available_at, lease_expires_at
FROM public.daily_repetition_jobs
WHERE id <> :'race_job_id'::uuid;
UPDATE public.daily_repetition_jobs AS job
SET available_at = 'infinity'::timestamptz
WHERE job.id <> :'race_job_id'::uuid
  AND job.state IN ('queued', 'retry_wait');
UPDATE public.daily_repetition_jobs AS job
SET lease_expires_at = 'infinity'::timestamptz
WHERE job.id <> :'race_job_id'::uuid AND job.state = 'leased';
SQL

edit_log="$log_dir/edit.log"
worker_log="$log_dir/worker.log"

# Hold the board lock while the worker starts. Once the worker is confirmed
# waiting on that lock, this same session edits the series and commits.
PGAPPNAME=openkanban_issue26_edit_lock_holder "${psql[@]}" -qAt \
  -v board_id="$board_id" -v board_slug="$board_slug" -v task_id="$task_id" \
  -v expected_revision="$expected_revision" -v edit_start_on="$edit_start_on" \
  >"$edit_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '42600000-0000-4000-8000-000000000002', true);
SELECT board.id FROM public.boards AS board WHERE board.id = :'board_id'::uuid FOR UPDATE;
SELECT pg_sleep(6);
SELECT (public.edit_repetition_p(
  '26000000-0000-4000-8000-000000000095', :'board_slug', :'task_id'::uuid,
  :'expected_revision'::bigint, :'edit_start_on'::date, 'count', 2, NULL,
  series.calendar_pattern, series.advance_days, series.appearance_column_id,
  series.template_snapshot, false
)->>'status')
FROM public.issue26_repetition_race_ref AS ref
JOIN public.daily_repetition_series AS series ON series.id = ref.series_id
WHERE ref.singleton;
COMMIT;
SQL
edit_pid=$!

holder_ready=false
for _ in $(seq 1 100); do
  holder_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue26_edit_lock_holder'
      AND state = 'active' AND query LIKE '%pg_sleep(6)%'")
  if [[ "$holder_state" == active ]]; then
    holder_ready=true
    break
  fi
  sleep 0.05
done
if [[ "$holder_ready" != true ]]; then
  cat -- "$edit_log" >&2
  echo 'Issue #26 edit session did not acquire the board lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue26_advance_worker "${psql[@]}" -qAt \
  >"$worker_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.run_daily_repetition_jobs_p(100)->>'claimed';
COMMIT;
SQL
worker_pid=$!

worker_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue26_advance_worker'
      AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    worker_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$worker_waiting" != true ]]; then
  cat -- "$worker_log" >&2
  echo 'Issue #26 worker did not wait behind the held board lock.' >&2
  exit 1
fi

edit_exit=0
wait "$edit_pid" || edit_exit=$?
worker_exit=0
wait "$worker_pid" || worker_exit=$?
if [[ "$edit_exit" != 0 || "$worker_exit" != 0 ]]; then
  cat -- "$edit_log" >&2
  cat -- "$worker_log" >&2
  echo "Issue #26 edit/worker sessions failed (edit=$edit_exit, worker=$worker_exit)." >&2
  exit 1
fi
if ! grep -Fxq 'confirmed' "$edit_log" || ! grep -Fxq '0' "$worker_log"; then
  cat -- "$edit_log" >&2
  cat -- "$worker_log" >&2
  echo 'Issue #26 edit did not win cleanly before the queued scheduler job was claimed.' >&2
  exit 1
fi

race_checks=$("${psql[@]}" -qAt -F '|' -c "
  SELECT
    (series.revision = ref.revision + 1),
    (series.next_due_on = ref.edit_start_on),
    (series.current_occurrence_id = ref.current_occurrence_id),
    ((SELECT count(*) FROM public.daily_repetition_occurrences AS occurrence
      WHERE occurrence.series_id = series.id AND occurrence.state = 'current') = 1),
    ((SELECT task.column_id FROM public.tasks AS task
      WHERE task.id = ref.task_id) = ref.current_column_id),
    ((SELECT task.due_on FROM public.tasks AS task
      WHERE task.id = ref.task_id) = ref.current_due_on),
    ((SELECT job.state FROM public.daily_repetition_jobs AS job
      WHERE job.id = ref.job_id) = 'superseded'),
    ((SELECT count(*) FROM public.daily_repetition_jobs AS job
      WHERE job.series_id = series.id AND job.job_kind = 'advance'
        AND job.series_revision = series.revision
        AND job.state IN ('queued', 'retry_wait', 'leased')) = 1),
    ((SELECT count(*) FROM public.tasks AS task
      WHERE task.column_id = ref.current_column_id AND task.due_on = ref.next_due_on) = 0)
  FROM public.issue26_repetition_race_ref AS ref
  JOIN public.daily_repetition_series AS series ON series.id = ref.series_id
  WHERE ref.singleton
")
if [[ "$race_checks" != 't|t|t|t|t|t|t|t|t' ]]; then
  echo "Issue #26 edit/worker serialization assertions failed: $race_checks" >&2
  exit 1
fi

"${psql[@]}" -q <<'SQL'
UPDATE public.daily_repetition_jobs AS job
SET available_at = saved.available_at,
    lease_expires_at = saved.lease_expires_at
FROM public.issue26_repetition_race_saved_jobs AS saved
WHERE job.id = saved.id;
DROP TABLE public.issue26_repetition_race_saved_jobs;
SQL

echo 'PASS: run_daily waits board-first, then skips the superseded queued job without deadlock or duplicate.'
