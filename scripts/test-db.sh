#!/usr/bin/env bash
set -euo pipefail

# Always creates its own local cluster. Never consumes DATABASE_URL or PGHOST.
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pg_bin=${PG_BINDIR:-$(pg_config --bindir)}
for binary in initdb pg_ctl psql; do
  if [[ ! -x "$pg_bin/$binary" ]]; then
    printf 'Missing PostgreSQL executable: %s/%s\n' "$pg_bin" "$binary" >&2
    exit 1
  fi
done

test_dir=$(mktemp -d /tmp/openkanban-db.XXXXXXXX)
cleanup() {
  "$pg_bin/pg_ctl" -D "$test_dir/data" -m immediate stop >/dev/null 2>&1 || true
  # Only remove the disposable directory created above, never a supplied path.
  if [[ $(realpath "$test_dir") == /tmp/openkanban-db.* ]]; then
    rm -rf -- "$test_dir"
  fi
}
trap cleanup EXIT

"$pg_bin/initdb" -D "$test_dir/data" --username=postgres --no-locale \
  --encoding=UTF8 --auth-local=trust --auth-host=reject > "$test_dir/init.log"
"$pg_bin/pg_ctl" -D "$test_dir/data" -l "$test_dir/server.log" \
  -o "-F -k $test_dir -p 55439 -c listen_addresses='' -c unix_socket_permissions=0700" \
  -w start >/dev/null
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$pg_bin/psql" -X -h "$test_dir" -p 55439 -U postgres -d postgres -v ON_ERROR_STOP=1)

# Match the public roles and default table privileges used by Supabase.
"${psql[@]}" -q <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO anon, authenticated;
SQL

for migration in "$repo_dir"/supabase/migrations/*.sql; do
  if [[ "$(basename -- "$migration")" == '015_closed_google_access.sql' ]]; then
    break
  fi
  printf 'Applying %s\n' "$(basename -- "$migration")"
  "${psql[@]}" -q -f "$migration"
done

"${psql[@]}" -f "$repo_dir/tests/db/security.sql"

# Force a genuine concurrent edit/move race. The editor holds the task row,
# the move RPC starts and waits on it, then the editor commits its field change.
race_dir="$test_dir/task-move-race"
mkdir -- "$race_dir"
race_editor_log="$race_dir/editor.log"
race_mover_log="$race_dir/mover.log"

"${psql[@]}" -q <<'SQL'
INSERT INTO public.boards (id, slug) VALUES
  ('10000000-0000-4000-8000-000000000001', 'task-move-race');
INSERT INTO public.columns (id, board_id, title, position) VALUES
  ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Source', 0),
  ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000001', 'Destination', 1);
INSERT INTO public.tasks (id, column_id, title, description, priority, position) VALUES
  ('30000000-0000-4000-8000-000000000001', '20000000-0000-4000-8000-000000000001', 'Initial title', 'Initial description', 'medium', 0);
SQL

PGAPPNAME=openkanban_race_editor "${psql[@]}" > "$race_editor_log" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM public.tasks WHERE id = '30000000-0000-4000-8000-000000000001' FOR UPDATE;
SELECT pg_sleep(8);
SELECT public.edit_task_fields_p(
  'task-move-race',
  '30000000-0000-4000-8000-000000000001',
  '{"title":"Concurrent title","description":"Concurrent description","priority":"urgent"}'::jsonb
);
COMMIT;
SQL
race_editor_pid=$!

editor_locked=false
for _ in $(seq 1 100); do
  editor_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_race_editor' AND state = 'active' AND query LIKE '%pg_sleep(8)%'")
  if [[ "$editor_state" == active ]]; then
    editor_locked=true
    break
  fi
  sleep 0.05
done
if [[ "$editor_locked" != true ]]; then
  cat -- "$race_editor_log" >&2
  echo 'The editor session did not acquire its task lock.' >&2
  exit 1
fi

(
  PGAPPNAME=openkanban_race_mover "${psql[@]}" > "$race_mover_log" 2>&1 <<'SQL'
BEGIN;
SELECT public.update_task_positions_p(
  'task-move-race',
  '[{"id":"30000000-0000-4000-8000-000000000001","column_id":"20000000-0000-4000-8000-000000000002","position":0}]'::jsonb
);
COMMIT;
SQL
) &
race_mover_pid=$!

mover_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_race_mover' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    mover_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$mover_waiting" != true ]]; then
  cat -- "$race_mover_log" >&2
  echo 'The move session did not wait on the editor transaction.' >&2
  exit 1
fi

wait "$race_editor_pid" || { cat -- "$race_editor_log" >&2; exit 1; }
wait "$race_mover_pid" || { cat -- "$race_mover_log" >&2; exit 1; }

"${psql[@]}" -q <<'SQL'
DO $$
DECLARE
  task public.tasks;
BEGIN
  SELECT * INTO task FROM public.get_tasks_by_board_p(
    (SELECT id FROM public.get_board_p('task-move-race'))
  ) WHERE id = '30000000-0000-4000-8000-000000000001';
  IF task.title IS DISTINCT FROM 'Concurrent title'
    OR task.description IS DISTINCT FROM 'Concurrent description'
    OR task.priority IS DISTINCT FROM 'urgent'
    OR task.column_id IS DISTINCT FROM '20000000-0000-4000-8000-000000000002'::uuid
    OR task.position IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'Concurrent move did not preserve the latest task fields: %', row_to_json(task);
  END IF;
END;
$$;
SQL
echo 'PASS: concurrent task edit and move preserve current task fields.'

# A transaction may start before an edit but reach its task update afterward.
# updated_at must follow the row-write order, not transaction start time.
write_order_dir="$test_dir/task-write-order-race"
mkdir -- "$write_order_dir"
write_order_mover_log="$write_order_dir/mover.log"

"${psql[@]}" -q <<'SQL'
INSERT INTO public.boards (id, slug) VALUES
  ('10000000-0000-4000-8000-000000000002', 'task-write-order-race');
INSERT INTO public.columns (id, board_id, title, position) VALUES
  ('20000000-0000-4000-8000-000000000003', '10000000-0000-4000-8000-000000000002', 'Source', 0),
  ('20000000-0000-4000-8000-000000000004', '10000000-0000-4000-8000-000000000002', 'Destination', 1);
INSERT INTO public.tasks (id, column_id, title, description, priority, position) VALUES
  ('30000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000003', 'Order title', 'Order description', 'medium', 0);
CREATE TABLE public.task_write_order_reference (
  task_id uuid PRIMARY KEY,
  edit_updated_at timestamptz NOT NULL
);
SQL

PGAPPNAME=openkanban_write_order_mover "${psql[@]}" > "$write_order_mover_log" 2>&1 <<'SQL' &
BEGIN;
SELECT pg_sleep(6);
SELECT public.update_task_positions_p(
  'task-write-order-race',
  '[{"id":"30000000-0000-4000-8000-000000000002","column_id":"20000000-0000-4000-8000-000000000004","position":0}]'::jsonb
);
COMMIT;
SQL
write_order_mover_pid=$!

mover_transaction_open=false
for _ in $(seq 1 100); do
  mover_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_write_order_mover' AND state = 'active' AND query LIKE '%pg_sleep(6)%'")
  if [[ "$mover_state" == active ]]; then
    mover_transaction_open=true
    break
  fi
  sleep 0.05
done
if [[ "$mover_transaction_open" != true ]]; then
  cat -- "$write_order_mover_log" >&2
  echo 'The delayed mover transaction did not start.' >&2
  exit 1
fi

"${psql[@]}" -q <<'SQL'
SELECT public.edit_task_fields_p(
  'task-write-order-race',
  '30000000-0000-4000-8000-000000000002',
  '{"title":"Edited before the delayed move","description":"Newer fields","priority":"high"}'::jsonb
);
INSERT INTO public.task_write_order_reference (task_id, edit_updated_at)
SELECT id, updated_at FROM public.tasks
WHERE id = '30000000-0000-4000-8000-000000000002';
SQL

wait "$write_order_mover_pid" || { cat -- "$write_order_mover_log" >&2; exit 1; }

"${psql[@]}" -q <<'SQL'
DO $$
DECLARE
  task public.tasks;
  edit_updated_at timestamptz;
BEGIN
  SELECT * INTO task FROM public.tasks
  WHERE id = '30000000-0000-4000-8000-000000000002';
  SELECT reference.edit_updated_at INTO edit_updated_at
  FROM public.task_write_order_reference AS reference
  WHERE reference.task_id = task.id;

  IF task.title IS DISTINCT FROM 'Edited before the delayed move'
    OR task.description IS DISTINCT FROM 'Newer fields'
    OR task.priority IS DISTINCT FROM 'high'
    OR task.column_id IS DISTINCT FROM '20000000-0000-4000-8000-000000000004'::uuid
    OR task.updated_at <= edit_updated_at THEN
    RAISE EXCEPTION 'Delayed move did not advance the task version after the edit: %, prior edit timestamp %', row_to_json(task), edit_updated_at;
  END IF;
END;
$$;
DROP TABLE public.task_write_order_reference;
SQL
echo 'PASS: task updated_at follows write order after a delayed transaction start.'

"${psql[@]}" -q -f "$repo_dir/tests/db/auth_schema.sql"
private_migrations=false
for migration in "$repo_dir"/supabase/migrations/*.sql; do
  if [[ "$(basename -- "$migration")" == '015_closed_google_access.sql' ]]; then
    private_migrations=true
  fi
  if [[ "$private_migrations" == true ]]; then
    printf 'Applying %s\n' "$(basename -- "$migration")"
    "${psql[@]}" -q -f "$migration"
  fi
done
"${psql[@]}" -f "$repo_dir/tests/fixtures/google-access.sql"
"${psql[@]}" -f "$repo_dir/tests/db/closed_access.sql"
"${psql[@]}" -f "$repo_dir/tests/db/authentication.sql"
"${psql[@]}" -f "$repo_dir/tests/db/admin_authorization.sql"

# An active non-admin must be rejected before waiting on another transaction's
# access-management lock, for every admin mutation.
nonadmin_race_dir="$test_dir/admin-nonadmin-lock-race"
mkdir -- "$nonadmin_race_dir"
nonadmin_lock_log="$nonadmin_race_dir/lock-holder.log"
nonadmin_attempt_log="$nonadmin_race_dir/nonadmin-attempt.log"

PGAPPNAME=openkanban_admin_nonadmin_lock_holder "${psql[@]}" > "$nonadmin_lock_log" 2>&1 <<'SQL' &
BEGIN;
LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
BEGIN
  IF NOT public.is_application_admin() THEN
    RAISE EXCEPTION 'The lock holder is not an active administrator.';
  END IF;
END;
$$;
SELECT pg_sleep(7);
COMMIT;
SQL
nonadmin_lock_pid=$!

nonadmin_lock_acquired=false
for _ in $(seq 1 100); do
  holder_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_admin_nonadmin_lock_holder' AND state = 'active' AND query LIKE '%pg_sleep(7)%'")
  if [[ "$holder_state" == active ]]; then
    nonadmin_lock_acquired=true
    break
  fi
  sleep 0.05
done
if [[ "$nonadmin_lock_acquired" != true ]]; then
  cat -- "$nonadmin_lock_log" >&2
  echo 'The administrator lock holder did not start its wait.' >&2
  wait "$nonadmin_lock_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_admin_nonadmin_lock_attempt "${psql[@]}" > "$nonadmin_attempt_log" 2>&1 <<'SQL' &
\set VERBOSITY verbose
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  v_sqlstate text;
BEGIN
  BEGIN
    PERFORM public.admin_enable_access('unauthorized-lock-test@example.test');
    RAISE EXCEPTION 'An active non-admin enabled access';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> '42501' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    PERFORM public.admin_remove_pending_access('pending-target@example.test');
    RAISE EXCEPTION 'An active non-admin removed pending access';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> '42501' THEN
      RAISE;
    END IF;
  END;
  BEGIN
    PERFORM public.admin_suspend_access('revocation-user@example.test');
    RAISE EXCEPTION 'An active non-admin suspended access';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
    IF v_sqlstate <> '42501' THEN
      RAISE;
    END IF;
  END;
END;
$$;
COMMIT;
\echo 'PASS: active non-admin admin RPCs return 42501 before waiting for the access lock.'
SQL
nonadmin_attempt_pid=$!

nonadmin_attempt_passed=false
nonadmin_attempt_waited=false
for _ in $(seq 1 100); do
  if grep -q 'PASS: active non-admin admin RPCs return 42501 before waiting' "$nonadmin_attempt_log"; then
    nonadmin_attempt_passed=true
    break
  fi
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_admin_nonadmin_lock_attempt' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    nonadmin_attempt_waited=true
    break
  fi
  sleep 0.05
done

if [[ "$nonadmin_attempt_passed" != true ]]; then
  if [[ "$nonadmin_attempt_waited" == true ]]; then
    echo 'An active non-admin waited on the access lock before authorization was checked.' >&2
  else
    echo 'An active non-admin RPC did not finish promptly with an authorization error.' >&2
  fi
  cat -- "$nonadmin_attempt_log" >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_admin_nonadmin_lock_holder'" >/dev/null
  wait "$nonadmin_lock_pid" || true
  wait "$nonadmin_attempt_pid" || true
  exit 1
fi

"${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_admin_nonadmin_lock_holder'" >/dev/null
wait "$nonadmin_lock_pid" || true
wait "$nonadmin_attempt_pid" || { cat -- "$nonadmin_attempt_log" >&2; exit 1; }
echo 'PASS: active non-admin admin RPCs return 42501 before waiting for the access lock.'

# A former administrator must lose authority if another administrator
# suspends their account while a second admin action is waiting on the lock.
admin_race_dir="$test_dir/admin-access-race"
mkdir -- "$admin_race_dir"
admin_a_log="$admin_race_dir/admin-a.log"
admin_b_log="$admin_race_dir/admin-b.log"

PGAPPNAME=openkanban_admin_race_a "${psql[@]}" > "$admin_a_log" 2>&1 <<'SQL' &
BEGIN;
LOCK TABLE public.application_access IN SHARE ROW EXCLUSIVE MODE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
SELECT pg_sleep(5);
SELECT public.admin_suspend_access('second-admin@example.test');
COMMIT;
SQL
admin_a_pid=$!

admin_a_holding_lock=false
for _ in $(seq 1 100); do
  admin_a_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_admin_race_a' AND state = 'active' AND query LIKE '%pg_sleep(5)%'")
  if [[ "$admin_a_state" == active ]]; then
    admin_a_holding_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$admin_a_holding_lock" != true ]]; then
  cat -- "$admin_a_log" >&2
  echo 'The first administrator did not acquire the access-management lock.' >&2
  wait "$admin_a_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_admin_race_b "${psql[@]}" > "$admin_b_log" 2>&1 <<'SQL' &
\set VERBOSITY verbose
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
SELECT public.admin_suspend_access('revocation-user@example.test');
COMMIT;
SQL
admin_b_pid=$!

admin_b_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_admin_race_b' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    admin_b_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$admin_b_waiting" != true ]]; then
  cat -- "$admin_b_log" >&2
  echo 'The second administrator did not wait for the active suspension.' >&2
  wait "$admin_a_pid" || true
  wait "$admin_b_pid" || true
  exit 1
fi

wait "$admin_a_pid" || { cat -- "$admin_a_log" >&2; exit 1; }
if wait "$admin_b_pid"; then
  echo 'A former administrator completed an action after losing administration.' >&2
  cat -- "$admin_b_log" >&2
  exit 1
fi
if ! grep -q '42501: Administrator access required' "$admin_b_log"; then
  echo 'The waiting administrator action failed for an unexpected reason.' >&2
  cat -- "$admin_b_log" >&2
  exit 1
fi

"${psql[@]}" -q <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_active_admins integer;
  v_second_admin_state text;
  v_target_state text;
BEGIN
  SELECT count(*) INTO v_active_admins
  FROM public.admin_list_access() AS access
  WHERE access.is_admin AND access.state = 'active';
  SELECT access.state INTO v_second_admin_state
  FROM public.admin_list_access() AS access
  WHERE access.email = 'second-admin@example.test';
  SELECT access.state INTO v_target_state
  FROM public.admin_list_access() AS access
  WHERE access.email = 'revocation-user@example.test';
  IF v_active_admins <> 1
    OR v_second_admin_state <> 'suspended'
    OR v_target_state <> 'active' THEN
    RAISE EXCEPTION 'Concurrent administration left an invalid final state: admins %, second admin %, target %',
      v_active_admins, v_second_admin_state, v_target_state;
  END IF;
END;
$$;
COMMIT;
SQL
echo 'PASS: concurrent admins cannot use a stale administrator authority.'
printf 'Database regression tests passed (disposable PostgreSQL).\n'
