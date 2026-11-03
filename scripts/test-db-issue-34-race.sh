#!/usr/bin/env bash
set -euo pipefail

psql_bin=${1:?pass the local psql binary}
socket_dir=${2:?pass the disposable PostgreSQL socket directory}
port=${3:?pass the disposable PostgreSQL port}
race_dir=${4:?pass a disposable race log directory}
mkdir -p -- "$race_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt)

start_session() {
  local app_name=$1
  local actor_id=$2
  local context_type=$3
  local preference_key=$4
  local value=$5
  local expected_version=$6
  local hold=$7
  local log_file=$8
  PGAPPNAME="$app_name" "${psql[@]}" > "$log_file" 2>&1 <<SQL &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$actor_id', true);
SELECT public.set_my_view_preference_p(
  '$context_type', NULL, '$preference_key', '$value'::jsonb, $expected_version
);
SELECT pg_sleep($hold);
COMMIT;
SQL
  LAST_PID=$!
}

wait_for_sleep() {
  local app_name=$1
  for _ in $(seq 1 100); do
    if [[ $("${psql[@]}" -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$app_name' AND state = 'active' AND query LIKE '%pg_sleep(%'") == 1 ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "Session $app_name did not hold the preference context lock." >&2
  return 1
}

wait_for_lock() {
  local app_name=$1
  for _ in $(seq 1 100); do
    if [[ $("${psql[@]}" -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$app_name' AND wait_event_type = 'Lock'") == 1 ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "Session $app_name did not wait on the context lock." >&2
  return 1
}

different_first_log="$race_dir/different-first.log"
different_second_log="$race_dir/different-second.log"
start_session openkanban_issue34_different_first \
  43400000-0000-4000-8000-000000000001 search_my_tasks order '"created"' 0 2 "$different_first_log"
different_first_pid=$LAST_PID
wait_for_sleep openkanban_issue34_different_first
(
  PGAPPNAME=openkanban_issue34_different_second "${psql[@]}" > "$different_second_log" 2>&1 <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43400000-0000-4000-8000-000000000001', true);
SELECT public.set_my_view_preference_p(
  'search_my_tasks', NULL, 'include_history', 'true'::jsonb, 0
);
COMMIT;
SQL
) &
different_second_pid=$!
wait_for_lock openkanban_issue34_different_second
wait "$different_first_pid" || { cat -- "$different_first_log" >&2; exit 1; }
wait "$different_second_pid" || { cat -- "$different_second_log" >&2; exit 1; }
if ! grep -q '"status": "saved"' "$different_first_log" \
  || ! grep -q '"status": "saved"' "$different_second_log"; then
  cat -- "$different_first_log" "$different_second_log" >&2
  echo 'Different preference changes did not both save.' >&2
  exit 1
fi

"${psql[@]}" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43400000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  snapshot jsonb := public.get_my_view_preferences_p('search_my_tasks', NULL);
BEGIN
  IF snapshot->'preferences'->'order'->'value' IS DISTINCT FROM '"created"'::jsonb
    OR snapshot->'preferences'->'include_history'->'value' IS DISTINCT FROM 'true'::jsonb THEN
    RAISE EXCEPTION 'Independent settings did not combine after two concurrent writes: %', snapshot;
  END IF;
END;
$$;
COMMIT;
SQL
echo 'PASS: concurrent changes to different preferences combine.'

same_first_log="$race_dir/same-first.log"
same_second_log="$race_dir/same-second.log"
start_session openkanban_issue34_same_first \
  43400000-0000-4000-8000-000000000002 search_all order '"created"' 0 2 "$same_first_log"
same_first_pid=$LAST_PID
wait_for_sleep openkanban_issue34_same_first
(
  PGAPPNAME=openkanban_issue34_same_second "${psql[@]}" > "$same_second_log" 2>&1 <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43400000-0000-4000-8000-000000000002', true);
SELECT public.set_my_view_preference_p(
  'search_all', NULL, 'order', '"due"'::jsonb, 0
);
COMMIT;
SQL
) &
same_second_pid=$!
wait_for_lock openkanban_issue34_same_second
wait "$same_first_pid" || { cat -- "$same_first_log" >&2; exit 1; }
wait "$same_second_pid" || { cat -- "$same_second_log" >&2; exit 1; }
if ! grep -q '"status": "saved"' "$same_first_log" \
  || ! grep -q '"status": "conflict"' "$same_second_log"; then
  cat -- "$same_first_log" "$same_second_log" >&2
  echo 'The same-setting race did not preserve the first save and reject the stale write.' >&2
  exit 1
fi

"${psql[@]}" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43400000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  snapshot jsonb := public.get_my_view_preferences_p('search_all', NULL);
BEGIN
  IF snapshot->'preferences'->'order'->'value' IS DISTINCT FROM '"created"'::jsonb
    OR (snapshot->'preferences'->'order'->>'version')::integer IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'A stale same-setting write replaced the committed value: %', snapshot;
  END IF;
END;
$$;
COMMIT;
SQL
echo 'PASS: a stale same-setting client receives a conflict without overwriting.'
