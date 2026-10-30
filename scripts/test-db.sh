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
"${psql[@]}" -q -f "$repo_dir/supabase/migrations/015_closed_google_access.sql"
"${psql[@]}" -f "$repo_dir/tests/fixtures/google-access.sql"
"${psql[@]}" -f "$repo_dir/tests/db/closed_access.sql"
"${psql[@]}" -f "$repo_dir/tests/db/authentication.sql"
printf 'Database regression tests passed (disposable PostgreSQL).\n'
