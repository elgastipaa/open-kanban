#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-35-race.sh PSQL_BIN SOCKET_DIR PORT TEST_DIR' >&2
  exit 2
fi

psql_bin=$1
socket_dir=$2
port=$3
test_dir=$4
mkdir -p -- "$test_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1)

actor_id=43500000-0000-4000-8000-000000000003
"${psql[@]}" -q <<SQL
INSERT INTO public.application_access (email, state, is_admin)
VALUES ('issue35-view-race@example.test', 'pending', false);
INSERT INTO auth.users (id, email, email_confirmed_at, raw_app_meta_data)
VALUES ('$actor_id', 'issue35-view-race@example.test', now(), '{"provider":"google"}');
INSERT INTO auth.identities (id, user_id, provider, provider_id, identity_data)
VALUES (
  '53500000-0000-4000-8000-000000000003', '$actor_id', 'google',
  'issue35-view-race',
  '{"email":"issue35-view-race@example.test","email_verified":true}'
);
UPDATE public.application_access AS access
SET auth_user_id = auth_user.id,
    google_subject = identity.provider_id,
    state = 'active'
FROM auth.users AS auth_user
JOIN auth.identities AS identity ON identity.user_id = auth_user.id
WHERE access.email = auth_user.email
  AND access.email = 'issue35-view-race@example.test';
SQL

seed_count=$("${psql[@]}" -qAt <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '43500000-0000-4000-8000-000000000003', true) \gset
DO $$
DECLARE
  v_index integer;
  v_context text;
  v_definition jsonb;
  v_result jsonb;
BEGIN
  FOR v_index IN 1..49 LOOP
    v_context := CASE WHEN v_index % 2 = 0 THEN 'my_tasks' ELSE 'search' END;
    IF v_context = 'search' THEN
      v_definition := jsonb_build_object(
        'query', '', 'scope', 'all', 'boardId', NULL,
        'includeCompleted', false, 'includeHistory', false,
        'filterBoardId', NULL, 'dueFilter', NULL, 'priority', NULL,
        'assigneeId', NULL, 'unassigned', false, 'labels', '[]'::jsonb,
        'order', 'due'
      );
    ELSE
      v_definition := jsonb_build_object(
        'query', '', 'scope', 'my_tasks', 'boardId', NULL,
        'includeCompleted', true, 'includeHistory', false,
        'filterBoardId', NULL, 'dueFilter', NULL, 'priority', NULL,
        'assigneeId', NULL, 'unassigned', false, 'labels', '[]'::jsonb,
        'order', 'due'
      );
    END IF;
    v_result := public.create_my_saved_view_p(
      v_context, 'Base de carrera ' || v_index, v_definition
    );
    IF v_result->>'status' IS DISTINCT FROM 'saved' THEN
      RAISE EXCEPTION 'Could not create baseline view %: %', v_index, v_result;
    END IF;
  END LOOP;
END;
$$;
COMMIT;
SELECT count(*) FROM public.user_saved_views
WHERE user_id = '43500000-0000-4000-8000-000000000003'::uuid
  AND deleted_at IS NULL;
SQL
)
if [[ "$seed_count" != 49 ]]; then
  echo "Issue #35 race fixture expected 49 active views, created $seed_count." >&2
  exit 1
fi

first_log="$test_dir/first.log"
second_log="$test_dir/second.log"
PGAPPNAME=openkanban_issue35_view_first "${psql[@]}" -qAt >"$first_log" 2>&1 <<SQL &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$actor_id', true);
SELECT public.create_my_saved_view_p(
  'search', 'Último lugar A',
  jsonb_build_object(
    'query', '', 'scope', 'all', 'boardId', NULL,
    'includeCompleted', false, 'includeHistory', false,
    'filterBoardId', NULL, 'dueFilter', NULL, 'priority', NULL,
    'assigneeId', NULL, 'unassigned', false, 'labels', '[]'::jsonb,
    'order', 'due'
  )
)->>'status';
SELECT pg_sleep(2);
COMMIT;
SQL
first_pid=$!

first_holding_lock=false
for _ in $(seq 1 120); do
  first_state=$("${psql[@]}" -qAt -c "SELECT state FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue35_view_first'
      AND state = 'active' AND query LIKE '%pg_sleep(2)%'")
  if [[ "$first_state" == active ]]; then
    first_holding_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$first_holding_lock" != true ]]; then
  cat -- "$first_log" >&2
  echo 'Issue #35 first client did not hold the per-user view quota lock.' >&2
  wait "$first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue35_view_second "${psql[@]}" -qAt >"$second_log" 2>&1 <<SQL &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '$actor_id', true);
SELECT public.create_my_saved_view_p(
  'my_tasks', 'Último lugar B',
  jsonb_build_object(
    'query', '', 'scope', 'my_tasks', 'boardId', NULL,
    'includeCompleted', true, 'includeHistory', false,
    'filterBoardId', NULL, 'dueFilter', NULL, 'priority', NULL,
    'assigneeId', NULL, 'unassigned', false, 'labels', '[]'::jsonb,
    'order', 'due'
  )
)->>'status';
COMMIT;
SQL
second_pid=$!

second_waiting=false
for _ in $(seq 1 120); do
  wait_count=$("${psql[@]}" -qAt -c "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'openkanban_issue35_view_second'
      AND wait_event_type = 'Lock'")
  if [[ "$wait_count" == 1 ]]; then
    second_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$second_waiting" != true ]]; then
  cat -- "$first_log" "$second_log" >&2
  echo 'Issue #35 second client did not wait behind the final quota slot.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue35_view_first'" >/dev/null
  wait "$first_pid" || true
  wait "$second_pid" || true
  exit 1
fi

first_exit=0
wait "$first_pid" || first_exit=$?
second_exit=0
wait "$second_pid" || second_exit=$?
if [[ "$first_exit" != 0 || "$second_exit" != 0 ]]; then
  cat -- "$first_log" "$second_log" >&2
  echo "Issue #35 concurrent view creates failed (first=$first_exit, second=$second_exit)." >&2
  exit 1
fi
if ! grep -Fxq 'saved' "$first_log" || ! grep -Fxq 'limit_reached' "$second_log"; then
  cat -- "$first_log" "$second_log" >&2
  echo 'Exactly one concurrent create must win the final per-user view slot.' >&2
  exit 1
fi

race_result=$("${psql[@]}" -qAt <<SQL
SELECT count(*) || '|' || count(*) FILTER (WHERE name IN ('Último lugar A', 'Último lugar B'))
FROM public.user_saved_views
WHERE user_id = '$actor_id'::uuid AND deleted_at IS NULL;
SQL
)
if [[ "$race_result" != '50|1' ]]; then
  echo "Issue #35 last-slot race expected 50 active views and one winner; got $race_result." >&2
  exit 1
fi

echo 'PASS: two PostgreSQL clients serialize on the shared 50-view quota.'
