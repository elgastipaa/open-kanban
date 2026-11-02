#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-30-race.sh PSQL_BIN SOCKET_DIR PORT TEST_DIR' >&2
  exit 2
fi

psql_bin=$1
socket_dir=$2
port=$3
test_dir=$4
mkdir -p -- "$test_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

board_ref=$("${psql[@]}" -qAtF '|' <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true) \gset
SELECT id || '|' || slug
FROM public.create_board_p(
  'Issue 30 last active label race', 'America/Argentina/Buenos_Aires',
  '33000000-0000-4000-8000-000000000099'
);
COMMIT;
SQL
)
if [[ -z "$board_ref" ]]; then
  echo 'Issue #30 last-slot race board could not be created.' >&2
  exit 1
fi
IFS='|' read -r board_id board_slug <<< "$board_ref"

created_count=$("${psql[@]}" -qAt -v board_slug="$board_slug" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true) \gset
WITH created AS MATERIALIZED (
  SELECT public.create_board_label_p(:'board_slug', 'Race baseline ' || n, 'gray') AS result
  FROM generate_series(1, 99) AS labels(n)
)
SELECT count(*) FILTER (WHERE result->>'status' = 'confirmed')
FROM created;
COMMIT;
SQL
)
if [[ "$created_count" != 99 ]]; then
  echo "Issue #30 race fixture expected 99 active labels, created $created_count." >&2
  exit 1
fi

"${psql[@]}" -q -v board_id="$board_id" <<'SQL'
INSERT INTO public.board_memberships (board_id, user_id, role)
VALUES (:'board_id'::uuid, '43000000-0000-4000-8000-000000000003', 'collaborator');
SQL

owner_log="$test_dir/owner.log"
collaborator_log="$test_dir/collaborator.log"

PGAPPNAME=openkanban_issue30_slot_owner "${psql[@]}" -qAt \
  -v board_id="$board_id" -v board_slug="$board_slug" \
  >"$owner_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true) \gset
SELECT public.create_board_label_p(:'board_slug', 'Carrera propietaria', 'blue')->>'status';
SELECT pg_sleep(5);
COMMIT;
SQL
owner_pid=$!

owner_holds_board=false
for _ in $(seq 1 120); do
  owner_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue30_slot_owner'
      AND state = 'active' AND query LIKE '%pg_sleep(5)%'")
  if [[ "$owner_state" == active ]]; then
    owner_holds_board=true
    break
  fi
  sleep 0.05
done
if [[ "$owner_holds_board" != true ]]; then
  cat -- "$owner_log" >&2
  echo 'Issue #30 owner session did not acquire the board lock.' >&2
  wait "$owner_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue30_slot_collaborator "${psql[@]}" -qAt \
  -v board_slug="$board_slug" \
  >"$collaborator_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000003', true) \gset
SELECT public.create_board_label_p(:'board_slug', 'Carrera colaboradora', 'green')->>'status';
COMMIT;
SQL
collaborator_pid=$!

collaborator_waiting=false
for _ in $(seq 1 120); do
  wait_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue30_slot_collaborator'
      AND wait_event_type = 'Lock'")
  if [[ "$wait_count" == 1 ]]; then
    collaborator_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$collaborator_waiting" != true ]]; then
  cat -- "$owner_log" "$collaborator_log" >&2
  echo 'Issue #30 collaborator did not wait behind the last-slot transaction.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue30_slot_owner'" >/dev/null
  wait "$owner_pid" || true
  wait "$collaborator_pid" || true
  exit 1
fi

owner_exit=0
wait "$owner_pid" || owner_exit=$?
collaborator_exit=0
wait "$collaborator_pid" || collaborator_exit=$?
if [[ "$owner_exit" != 0 || "$collaborator_exit" != 0 ]]; then
  cat -- "$owner_log" "$collaborator_log" >&2
  echo "Issue #30 concurrent label creates failed (owner=$owner_exit, collaborator=$collaborator_exit)." >&2
  exit 1
fi
if ! grep -Fxq 'confirmed' "$owner_log" || ! grep -Fxq 'conflict' "$collaborator_log"; then
  cat -- "$owner_log" "$collaborator_log" >&2
  echo 'Exactly one concurrent create must win the final active label slot.' >&2
  exit 1
fi

active_count=$("${psql[@]}" -qAt -v board_id="$board_id" <<'SQL'
SELECT count(*)
FROM public.board_labels
WHERE board_id = :'board_id'::uuid AND deleted_at IS NULL;
SQL
)
race_label_count=$("${psql[@]}" -qAt -v board_id="$board_id" <<'SQL'
SELECT count(*)
FROM public.board_labels
WHERE board_id = :'board_id'::uuid AND deleted_at IS NULL
  AND name IN ('Carrera propietaria', 'Carrera colaboradora');
SQL
)
if [[ "$active_count" != 100 || "$race_label_count" != 1 ]]; then
  echo "Issue #30 last-slot race expected 100 active labels and one winner; got active=$active_count, winners=$race_label_count." >&2
  exit 1
fi

echo 'PASS: concurrent owner and collaborator creates serialize on the final board label slot.'

label_restore_ref=$("${psql[@]}" -qAtF '|' -v board_id="$board_id" -v board_slug="$board_slug" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true) \gset
SELECT (rows.item->>'id')::uuid AS purge_label_id
FROM jsonb_array_elements(public.list_board_labels_p(:'board_slug')->'labels') AS rows(item)
WHERE rows.item->>'name' = 'Race baseline 1'
\gset
SELECT (rows.item->>'id')::uuid AS keep_label_id
FROM jsonb_array_elements(public.list_board_labels_p(:'board_slug')->'labels') AS rows(item)
WHERE rows.item->>'name' = 'Race baseline 2'
\gset
SELECT (public.create_column_p(
  :'board_slug', :'board_id'::uuid, 'Recuperación de etiqueta', 0
)).id AS column_id
\gset
SELECT (public.create_task_p(
  '33000000-0000-4000-8000-000000000101',
  :'board_id'::uuid,
  :'column_id'::uuid,
  'Tarea con etiqueta por purgar', NULL, 'medium'
)->>'task_id')::uuid AS task_id
\gset
SELECT public.set_task_labels_p(
  :'board_slug', :'task_id'::uuid, ARRAY[]::uuid[],
  ARRAY[:'purge_label_id'::uuid, :'keep_label_id'::uuid]
)->>'status' AS label_set_status
\gset
SELECT public.delete_board_label_p(
  :'board_slug', :'purge_label_id'::uuid, 1
)->>'status' AS label_delete_status
\gset
SELECT public.delete_task_p(
  '33000000-0000-4000-8000-000000000102',
  :'board_slug', :'task_id'::uuid
)->>'status' AS task_delete_status
\gset
RESET ROLE;
UPDATE public.board_labels
SET deleted_at = clock_timestamp() - interval '168 hours'
WHERE id = :'purge_label_id'::uuid;
SELECT :'task_id'::uuid::text || '|' || :'purge_label_id'::uuid::text || '|' || :'keep_label_id'::uuid::text
  || '|' || :'label_set_status' || '|' || :'label_delete_status' || '|' || :'task_delete_status';
COMMIT;
SQL
)
IFS='|' read -r restore_task_id purge_label_id keep_label_id label_set_status label_delete_status task_delete_status <<< "$label_restore_ref"
if [[ -z "$restore_task_id" || -z "$purge_label_id" || -z "$keep_label_id" || \
  "$label_set_status" != confirmed || "$label_delete_status" != confirmed || \
  "$task_delete_status" != confirmed ]]; then
  echo 'Issue #30 restore/purge race fixture could not be created.' >&2
  exit 1
fi

purge_log="$test_dir/label-purge.log"
restore_log="$test_dir/task-restore.log"
PGAPPNAME=openkanban_issue30_label_purge "${psql[@]}" -qAt \
  -v purge_label_id="$purge_label_id" >"$purge_log" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM public.board_labels WHERE id = :'purge_label_id'::uuid FOR UPDATE;
SELECT pg_sleep(5);
SELECT public.purge_expired_board_labels_p(100);
COMMIT;
SQL
purge_pid=$!

purger_holding_label=false
for _ in $(seq 1 120); do
  purge_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue30_label_purge'
      AND state = 'active' AND query LIKE '%pg_sleep(5)%'")
  if [[ "$purge_state" == active ]]; then
    purger_holding_label=true
    break
  fi
  sleep 0.05
done
if [[ "$purger_holding_label" != true ]]; then
  cat -- "$purge_log" >&2
  echo 'Issue #30 purge session did not acquire the expired label lock.' >&2
  wait "$purge_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue30_task_restore "${psql[@]}" -qAt \
  -v board_slug="$board_slug" -v task_id="$restore_task_id" \
  >"$restore_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000002', true);
SELECT public.restore_task_p(
  '33000000-0000-4000-8000-000000000103',
  :'board_slug', :'task_id'::uuid
)->>'status';
COMMIT;
SQL
restore_pid=$!

restore_waiting=false
for _ in $(seq 1 120); do
  wait_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue30_task_restore'
      AND wait_event_type = 'Lock'")
  if [[ "$wait_count" == 1 ]]; then
    restore_waiting=true
    break
  fi
  if ! kill -0 "$restore_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$restore_waiting" != true ]]; then
  cat -- "$purge_log" "$restore_log" >&2
  echo 'Issue #30 task restore did not wait on the purged snapshot label.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue30_label_purge'" >/dev/null
  wait "$purge_pid" || true
  wait "$restore_pid" || true
  exit 1
fi

purge_exit=0
wait "$purge_pid" || purge_exit=$?
restore_exit=0
wait "$restore_pid" || restore_exit=$?
if [[ "$purge_exit" != 0 ]]; then
  cat -- "$purge_log" >&2
  echo "Issue #30 label purge failed ($purge_exit)." >&2
  exit 1
fi
if [[ "$restore_exit" != 0 ]]; then
  cat -- "$purge_log" "$restore_log" >&2
  echo "Issue #30 item restore failed while label purge raced ($restore_exit)." >&2
  exit 1
fi
if ! grep -Fxq 'confirmed' "$restore_log"; then
  cat -- "$purge_log" "$restore_log" >&2
  echo 'Issue #30 item restore must complete after the label purge commits.' >&2
  exit 1
fi

remaining_assignments=$("${psql[@]}" -qAt \
  -v task_id="$restore_task_id" -v purge_label_id="$purge_label_id" \
  -v keep_label_id="$keep_label_id" <<'SQL'
SELECT
  count(*) FILTER (WHERE assignment.label_id = :'purge_label_id'::uuid) || '|' ||
  count(*) FILTER (WHERE assignment.label_id = :'keep_label_id'::uuid) || '|' ||
  CASE WHEN EXISTS (SELECT 1 FROM public.tasks WHERE id = :'task_id'::uuid)
    THEN 'present' ELSE 'missing' END
FROM public.board_label_task_assignments AS assignment
WHERE assignment.task_id = :'task_id'::uuid;
SQL
)
if [[ "$remaining_assignments" != '0|1|present' ]]; then
  echo "Issue #30 restore/purge must skip only the purged relation and restore the item; got $remaining_assignments." >&2
  exit 1
fi

echo 'PASS: task restore waits for concurrent label purge, then skips only the purged relation.'
