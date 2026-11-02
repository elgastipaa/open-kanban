#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-31-race.sh PSQL_BIN SOCKET_DIR PORT TEST_DIR' >&2
  exit 2
fi

psql_bin=$1
socket_dir=$2
port=$3
test_dir=$4
mkdir -p -- "$test_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

create_fixture() {
  local suffix=$1
  local board_name=$2
  local fixture
  fixture=$("${psql[@]}" -qAtF '|' -v suffix="$suffix" -v board_name="$board_name" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true) \gset
SELECT id AS board_id, slug AS board_slug
FROM public.create_board_p(
  :'board_name', 'America/Argentina/Buenos_Aires',
  ('31100000-0000-4000-8000-000000000' || :'suffix')::uuid
) \gset
SELECT (public.create_column_p(:'board_slug', :'board_id'::uuid, 'A organizar', 0)).id
  AS column_id \gset
SELECT public.create_board_label_p(:'board_slug', 'Etiqueta de carrera', 'blue')->'label'->>'id'
  AS label_id \gset
SELECT (public.create_task_p(
  ('31200000-0000-4000-8000-000000000' || :'suffix')::uuid,
  :'board_id'::uuid, :'column_id'::uuid, 'Tarea de carrera', NULL, 'medium'
)->>'task_id')::uuid AS task_id \gset
SELECT public.set_task_labels_p(
  :'board_slug', :'task_id'::uuid, ARRAY[]::uuid[], ARRAY[:'label_id'::uuid]
)->>'status' AS label_status \gset
SELECT public.edit_task_fields_p(
  ('31300000-0000-4000-8000-000000000' || :'suffix')::uuid,
  :'board_slug', :'task_id'::uuid,
  jsonb_build_object('due_on', current_date), '{"due_on":1}'::jsonb
)->>'status' AS due_status \gset
SELECT public.create_repetition_with_advance_p(
  ('31400000-0000-4000-8000-000000000' || :'suffix')::uuid,
  :'board_slug', :'task_id'::uuid, current_date, NULL, 3, 2, false, NULL,
  '{"frequency":"daily","interval":1}'::jsonb, 0, :'column_id'::uuid
)->>'series_id' AS series_id \gset
RESET ROLE;
SELECT :'board_id' || '|' || :'board_slug' || '|' || :'task_id' || '|'
  || :'series_id' || '|' || :'label_id' || '|' || current_date::text;
COMMIT;
SQL
)
  printf '%s' "$fixture"
}

gen_first_ref=$(create_fixture 001 'Issue #31 generation first')
delete_first_ref=$(create_fixture 002 'Issue #31 deletion first')
IFS='|' read -r gen_first_board gen_first_slug gen_first_task gen_first_series gen_first_label gen_first_start <<< "$gen_first_ref"
IFS='|' read -r delete_first_board delete_first_slug delete_first_task delete_first_series delete_first_label delete_first_start <<< "$delete_first_ref"

if [[ -z "$gen_first_series" || -z "$delete_first_series" ]]; then
  echo 'Issue #31 generation/delete race fixtures could not be created.' >&2
  exit 1
fi

gen_first_log="$test_dir/generation-first.log"
delete_after_log="$test_dir/delete-after-generation.log"
PGAPPNAME=openkanban_issue31_generation_first "${psql[@]}" -qAt \
  -v board_id="$gen_first_board" -v series_id="$gen_first_series" -v start_on="$gen_first_start" \
  >"$gen_first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM public.boards WHERE id = :'board_id'::uuid FOR UPDATE;
SELECT pg_sleep(2) /* issue31 generation lock held */;
SELECT (public.advance_daily_repetition_internal_p(
  job,
  ((series.start_on + 1)::timestamp + interval '12 hours') AT TIME ZONE board.time_zone
))->>'status'
FROM public.daily_repetition_jobs AS job
JOIN public.daily_repetition_series AS series ON series.id = job.series_id
JOIN public.boards AS board ON board.id = series.board_id
WHERE job.series_id = :'series_id'::uuid AND job.job_kind = 'advance'
  AND job.state = 'queued'
ORDER BY job.created_at DESC LIMIT 1;
SELECT pg_sleep(4) /* issue31 generation completed while holding board */;
COMMIT;
SQL
gen_first_pid=$!

gen_first_ready=false
for _ in $(seq 1 120); do
  gen_first_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue31_generation_first'
      AND state = 'active' AND query LIKE '%issue31 generation completed while holding board%'")
  if [[ "$gen_first_state" == active ]]; then
    gen_first_ready=true
    break
  fi
  sleep 0.05
done
if [[ "$gen_first_ready" != true ]]; then
  cat -- "$gen_first_log" >&2
  echo 'Issue #31 generation-first session did not hold the board after inserting an occurrence.' >&2
  wait "$gen_first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue31_delete_after_generation "${psql[@]}" -qAt \
  -v board_slug="$gen_first_slug" -v label_id="$gen_first_label" \
  >"$delete_after_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true) \gset
SELECT public.delete_board_label_p(
  :'board_slug', :'label_id'::uuid, 1
)->>'status';
COMMIT;
SQL
delete_after_pid=$!

delete_after_waiting=false
for _ in $(seq 1 120); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue31_delete_after_generation'
      AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    delete_after_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$delete_after_waiting" != true ]]; then
  cat -- "$delete_after_log" >&2
  echo 'Issue #31 label deletion did not wait behind generation-first board lock.' >&2
  wait "$gen_first_pid" || true
  wait "$delete_after_pid" || true
  exit 1
fi

gen_first_exit=0
wait "$gen_first_pid" || gen_first_exit=$?
delete_after_exit=0
wait "$delete_after_pid" || delete_after_exit=$?
if [[ "$gen_first_exit" != 0 || "$delete_after_exit" != 0 ]] \
  || ! grep -Fxq 'confirmed' "$gen_first_log" \
  || ! grep -Fxq 'confirmed' "$delete_after_log"; then
  cat -- "$gen_first_log" "$delete_after_log" >&2
  echo "Issue #31 generation-first sessions failed (generation=$gen_first_exit, delete=$delete_after_exit)." >&2
  exit 1
fi

delete_first_log="$test_dir/delete-first.log"
generation_after_log="$test_dir/generation-after-delete.log"
PGAPPNAME=openkanban_issue31_delete_first "${psql[@]}" -qAt \
  -v board_slug="$delete_first_slug" -v label_id="$delete_first_label" \
  >"$delete_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000002', true) \gset
SELECT public.delete_board_label_p(
  :'board_slug', :'label_id'::uuid, 1
)->>'status';
SELECT pg_sleep(4) /* issue31 deletion completed while holding board */;
COMMIT;
SQL
delete_first_pid=$!

delete_first_ready=false
for _ in $(seq 1 120); do
  delete_first_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue31_delete_first'
      AND state = 'active' AND query LIKE '%issue31 deletion completed while holding board%'")
  if [[ "$delete_first_state" == active ]]; then
    delete_first_ready=true
    break
  fi
  sleep 0.05
done
if [[ "$delete_first_ready" != true ]]; then
  cat -- "$delete_first_log" >&2
  echo 'Issue #31 deletion-first session did not hold the board after soft deletion.' >&2
  wait "$delete_first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue31_generation_after_delete "${psql[@]}" -qAt \
  -v board_id="$delete_first_board" -v series_id="$delete_first_series" -v start_on="$delete_first_start" \
  >"$generation_after_log" 2>&1 <<'SQL' &
BEGIN;
SELECT (public.advance_daily_repetition_internal_p(
  job,
  ((series.start_on + 1)::timestamp + interval '12 hours') AT TIME ZONE board.time_zone
))->>'status'
FROM public.daily_repetition_jobs AS job
JOIN public.daily_repetition_series AS series ON series.id = job.series_id
JOIN public.boards AS board ON board.id = series.board_id
WHERE job.series_id = :'series_id'::uuid AND job.job_kind = 'advance'
  AND job.state = 'queued'
ORDER BY job.created_at DESC LIMIT 1;
COMMIT;
SQL
generation_after_pid=$!

generation_after_waiting=false
for _ in $(seq 1 120); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue31_generation_after_delete'
      AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    generation_after_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$generation_after_waiting" != true ]]; then
  cat -- "$generation_after_log" >&2
  echo 'Issue #31 generation session did not wait behind delete-first board lock.' >&2
  wait "$delete_first_pid" || true
  wait "$generation_after_pid" || true
  exit 1
fi

delete_first_exit=0
wait "$delete_first_pid" || delete_first_exit=$?
generation_after_exit=0
wait "$generation_after_pid" || generation_after_exit=$?
if [[ "$delete_first_exit" != 0 || "$generation_after_exit" != 0 ]] \
  || ! grep -Fxq 'confirmed' "$delete_first_log" \
  || ! grep -Fxq 'confirmed' "$generation_after_log"; then
  cat -- "$delete_first_log" "$generation_after_log" >&2
  echo "Issue #31 delete-first sessions failed (delete=$delete_first_exit, generation=$generation_after_exit)." >&2
  exit 1
fi

race_checks=$("${psql[@]}" -qAtF '|' \
  -v gen_first_series="$gen_first_series" -v gen_first_label="$gen_first_label" \
  -v delete_first_series="$delete_first_series" -v delete_first_label="$delete_first_label" <<'SQL'
SELECT
  (SELECT count(*) = 1
   FROM public.daily_repetition_occurrences AS occurrence
   WHERE occurrence.series_id = :'gen_first_series'::uuid
     AND occurrence.occurrence_on = (SELECT series.start_on + 1
       FROM public.daily_repetition_series AS series WHERE series.id = :'gen_first_series'::uuid)
     AND EXISTS (
       SELECT 1 FROM public.board_label_task_assignments AS assignment
       WHERE assignment.task_id = occurrence.task_id
         AND assignment.label_id = :'gen_first_label'::uuid
     )),
  (SELECT count(*) = 1
   FROM public.board_labels AS label
   JOIN public.daily_repetition_series AS series ON series.board_id = label.board_id
   WHERE label.id = :'gen_first_label'::uuid AND label.deleted_at IS NOT NULL),
  (SELECT count(*) = 1
   FROM public.daily_repetition_occurrences AS occurrence
   WHERE occurrence.series_id = :'delete_first_series'::uuid
     AND occurrence.occurrence_on = (SELECT series.start_on + 1
       FROM public.daily_repetition_series AS series WHERE series.id = :'delete_first_series'::uuid)
     AND NOT EXISTS (
       SELECT 1 FROM public.board_label_task_assignments AS assignment
       WHERE assignment.task_id = occurrence.task_id
         AND assignment.label_id = :'delete_first_label'::uuid
     )),
  (SELECT count(*) = 1
   FROM public.board_labels AS label
   WHERE label.id = :'delete_first_label'::uuid AND label.deleted_at IS NOT NULL)
SQL
)
if [[ "$race_checks" != 't|t|t|t' ]]; then
  cat -- "$gen_first_log" "$delete_after_log" "$delete_first_log" "$generation_after_log" >&2
  echo "Issue #31 generation/delete race assertions failed: $race_checks" >&2
  exit 1
fi

assignment_lock_log="$test_dir/assignment-table-lock.log"
unauthorized_restore_log="$test_dir/unauthorized-restore.log"
PGAPPNAME=openkanban_issue31_assignment_table_lock "${psql[@]}" -qAt \
  >"$assignment_lock_log" 2>&1 <<'SQL' &
BEGIN;
LOCK TABLE public.board_label_repetition_assignments IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(20) /* issue31 unauthorized wrapper lock held */;
COMMIT;
SQL
assignment_lock_pid=$!

assignment_lock_ready=false
for _ in $(seq 1 120); do
  assignment_lock_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue31_assignment_table_lock'
      AND state = 'active' AND query LIKE '%issue31 unauthorized wrapper lock held%'")
  if [[ "$assignment_lock_state" == active ]]; then
    assignment_lock_ready=true
    break
  fi
  sleep 0.05
done
if [[ "$assignment_lock_ready" != true ]]; then
  cat -- "$assignment_lock_log" >&2
  echo 'Issue #31 assignment-table lock probe did not acquire its holdpoint.' >&2
  kill "$assignment_lock_pid" 2>/dev/null || true
  wait "$assignment_lock_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue31_unauthorized_restore "${psql[@]}" -qAt \
  -v board_slug="$gen_first_slug" -v label_id="$gen_first_label" \
  >"$unauthorized_restore_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43100000-0000-4000-8000-000000000003', true) \gset
SELECT public.restore_board_label_p(
  :'board_slug', :'label_id'::uuid, 1, 'Etiqueta no autorizada',
  ARRAY[]::uuid[], ARRAY[]::uuid[]
);
COMMIT;
SQL
unauthorized_restore_pid=$!

unauthorized_waiting=false
for _ in $(seq 1 20); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue31_unauthorized_restore'
      AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    unauthorized_waiting=true
    break
  fi
  if grep -q '"status": "unavailable"' "$unauthorized_restore_log"; then
    break
  fi
  sleep 0.05
done

unauthorized_lock_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
  WHERE application_name = 'openkanban_issue31_unauthorized_restore'
    AND wait_event_type = 'Lock'")
kill "$assignment_lock_pid" 2>/dev/null || true
wait "$assignment_lock_pid" || true
unauthorized_restore_exit=0
wait "$unauthorized_restore_pid" || unauthorized_restore_exit=$?
if [[ "$unauthorized_waiting" == true || "$unauthorized_lock_count" != 0 \
  || "$unauthorized_restore_exit" != 0 ]] \
  || ! grep -q '"status": "unavailable"' "$unauthorized_restore_log" \
  || grep -Eq 'series_ids|restored_series_ids|omitted_series_ids' "$unauthorized_restore_log"; then
  cat -- "$unauthorized_restore_log" >&2
  echo 'Issue #31 unauthorized restore read template assignments before denying access.' >&2
  exit 1
fi

echo 'PASS: delete and occurrence generation serialize by board in both orders; labels are inherited only when active.'
echo 'PASS: non-member restore is denied before it reads the repetition-assignment table.'
