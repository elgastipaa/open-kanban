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
"${psql[@]}" -f "$repo_dir/tests/db/realtime_epoch.sql"
"${psql[@]}" -f "$repo_dir/tests/db/admin_authorization.sql"
"${psql[@]}" -f "$repo_dir/tests/db/private_boards.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/board_invitations.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/board_invitation_operation_receipts.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/my_tasks.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/task_recovery.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/board_column_recovery.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/task_comment_recovery_window.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/task_comment_operation.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/board_membership_departure.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/board_recovery.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/board_member_removal.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/access_suspension.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/board_favorites.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/theme_preferences.sql"

# Suspension takes the account lock before boards. A waiting task write and
# outgoing invitation must observe the committed suspension before touching a
# board or creating durable state.
issue19_suspension_race_dir="$test_dir/issue19-suspension-race"
mkdir -- "$issue19_suspension_race_dir"
issue19_suspension_admin_log="$issue19_suspension_race_dir/admin.log"
issue19_suspension_write_log="$issue19_suspension_race_dir/write.log"
issue19_suspension_invite_log="$issue19_suspension_race_dir/invite.log"
IFS='|' read -r issue19_suspension_board_id issue19_suspension_board_slug \
  issue19_suspension_column_id issue19_suspension_successor_id \
  issue19_suspension_invite_board_id issue19_suspension_invite_slug \
  issue19_suspension_invitee_email < <(
    "${psql[@]}" -AtF '|' -c "SELECT board_id, slug, column_id, successor_id, invite_board_id, invite_slug, invitee_email FROM public.issue19_suspension_race_fixture WHERE name = 'suspend_write_invite'"
  )

PGAPPNAME=openkanban_issue19_suspension_admin "${psql[@]}" \
  -v board_id="$issue19_suspension_board_id" \
  -v successor_id="$issue19_suspension_successor_id" \
  -v invite_board_id="$issue19_suspension_invite_board_id" \
  > "$issue19_suspension_admin_log" 2>&1 <<'SQL' &
BEGIN;
SELECT access.auth_user_id
FROM public.application_access AS access
WHERE access.auth_user_id = '41900000-0000-4000-8000-000000000006'
FOR UPDATE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
SELECT pg_sleep(4);
SELECT public.admin_suspend_access_with_successions_p(
  'race-target@example.test',
  jsonb_build_array(
    jsonb_build_object('board_id', :'board_id'::uuid, 'action', 'transfer', 'successor_id', :'successor_id'::uuid),
    jsonb_build_object('board_id', :'invite_board_id'::uuid, 'action', 'recover', 'successor_id', NULL)
  )
);
COMMIT;
SQL
issue19_suspension_admin_pid=$!

issue19_suspension_admin_locking=false
for _ in $(seq 1 100); do
  issue19_suspension_admin_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue19_suspension_admin' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$issue19_suspension_admin_state" == active ]]; then
    issue19_suspension_admin_locking=true
    break
  fi
  sleep 0.05
done
if [[ "$issue19_suspension_admin_locking" != true ]]; then
  cat -- "$issue19_suspension_admin_log" >&2
  echo 'The issue #19 administrator did not acquire the account lock before suspension.' >&2
  wait "$issue19_suspension_admin_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue19_suspension_writer "${psql[@]}" \
  -v board_id="$issue19_suspension_board_id" \
  -v column_id="$issue19_suspension_column_id" \
  > "$issue19_suspension_write_log" 2>&1 <<'SQL' &
\set VERBOSITY verbose
\set ON_ERROR_STOP off
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000006', true);
SELECT public.create_task_p(
  'a9190000-0000-4000-8000-000000000018',
  :'board_id'::uuid,
  :'column_id'::uuid,
  'Issue 19 write racing suspension'
);
COMMIT;
SQL
issue19_suspension_writer_pid=$!

PGAPPNAME=openkanban_issue19_suspension_inviter "${psql[@]}" \
  -v invite_slug="$issue19_suspension_invite_slug" \
  -v invitee_email="$issue19_suspension_invitee_email" \
  > "$issue19_suspension_invite_log" 2>&1 <<'SQL' &
\set VERBOSITY verbose
\set ON_ERROR_STOP off
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '41900000-0000-4000-8000-000000000006', true);
SELECT public.create_direct_board_invitation_p(:'invite_slug', :'invitee_email');
COMMIT;
SQL
issue19_suspension_inviter_pid=$!

issue19_suspension_writers_waiting=false
for _ in $(seq 1 100); do
  issue19_suspension_write_waiting=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue19_suspension_writer' AND wait_event_type = 'Lock'")
  issue19_suspension_invite_waiting=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue19_suspension_inviter' AND wait_event_type = 'Lock'")
  if [[ "$issue19_suspension_write_waiting" == 1 && "$issue19_suspension_invite_waiting" == 1 ]]; then
    issue19_suspension_writers_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$issue19_suspension_writers_waiting" != true ]]; then
  cat -- "$issue19_suspension_admin_log" "$issue19_suspension_write_log" "$issue19_suspension_invite_log" >&2
  echo 'A task write and invitation did not wait on the suspended account lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue19_suspension_admin'" >/dev/null
  wait "$issue19_suspension_admin_pid" || true
  wait "$issue19_suspension_writer_pid" || true
  wait "$issue19_suspension_inviter_pid" || true
  exit 1
fi

wait "$issue19_suspension_admin_pid" || { cat -- "$issue19_suspension_admin_log" >&2; exit 1; }
wait "$issue19_suspension_writer_pid" || { cat -- "$issue19_suspension_write_log" >&2; exit 1; }
wait "$issue19_suspension_inviter_pid" || { cat -- "$issue19_suspension_invite_log" >&2; exit 1; }
if ! grep -Eq '42501:' "$issue19_suspension_write_log" \
  || ! grep -Eq '42501:' "$issue19_suspension_invite_log"; then
  echo 'A write or outgoing invitation committed after account suspension.' >&2
  cat -- "$issue19_suspension_admin_log" "$issue19_suspension_write_log" "$issue19_suspension_invite_log" >&2
  exit 1
fi

issue19_suspension_write_count=$("${psql[@]}" -At -v board_id="$issue19_suspension_board_id" <<'SQL'
SELECT count(*)
FROM public.tasks AS task
JOIN public.columns AS column_row ON column_row.id = task.column_id
WHERE column_row.board_id = :'board_id'::uuid
  AND task.title = 'Issue 19 write racing suspension';
SQL
)
issue19_suspension_invite_count=$("${psql[@]}" -At -v invite_board_id="$issue19_suspension_invite_board_id" <<'SQL'
SELECT count(*)
FROM public.board_invitations AS invitation
WHERE invitation.board_id = :'invite_board_id'::uuid
  AND invitation.recipient_id = '41900000-0000-4000-8000-000000000008'
  AND invitation.status = 'pending';
SQL
)
if [[ "$issue19_suspension_write_count" != 0 || "$issue19_suspension_invite_count" != 0 ]]; then
  echo 'A concurrent write or invitation survived the account suspension.' >&2
  cat -- "$issue19_suspension_admin_log" "$issue19_suspension_write_log" "$issue19_suspension_invite_log" >&2
  exit 1
fi
echo 'PASS: suspension serializes with a concurrent task write and outgoing invitation.'

# The owner departure is atomic even when two sessions submit the same
# operation after one has committed but before its response reaches the client.
issue17_departure_race_dir="$test_dir/issue17-departure-race"
mkdir -- "$issue17_departure_race_dir"
issue17_departure_first_log="$issue17_departure_race_dir/first.log"
issue17_departure_second_log="$issue17_departure_race_dir/second.log"
IFS='|' read -r issue17_departure_board_id issue17_departure_actor_id \
  issue17_departure_successor_id issue17_departure_operation_id < <(
    "${psql[@]}" -AtF '|' -c "SELECT board_id, actor_id, successor_id, operation_id FROM public.issue17_departure_concurrency_fixture"
  )

PGAPPNAME=openkanban_issue17_departure_actor_a "${psql[@]}" -qAt \
  -v board_id="$issue17_departure_board_id" \
  -v actor_id="$issue17_departure_actor_id" \
  -v successor_id="$issue17_departure_successor_id" \
  -v operation_id="$issue17_departure_operation_id" \
  > "$issue17_departure_first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM public.boards WHERE id = :'board_id'::uuid FOR UPDATE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'actor_id', true);
SELECT pg_sleep(4);
SELECT public.leave_board_p(
  :'operation_id'::uuid, :'board_id'::uuid, :'successor_id'::uuid
)->>'status';
COMMIT;
SQL
issue17_departure_first_pid=$!

issue17_departure_first_holds_lock=false
for _ in $(seq 1 100); do
  issue17_departure_first_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue17_departure_actor_a' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$issue17_departure_first_state" == active ]]; then
    issue17_departure_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$issue17_departure_first_holds_lock" != true ]]; then
  cat -- "$issue17_departure_first_log" >&2
  echo 'The first owner-departure session did not hold the board lock.' >&2
  wait "$issue17_departure_first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue17_departure_actor_b "${psql[@]}" -qAt \
  -v board_id="$issue17_departure_board_id" \
  -v actor_id="$issue17_departure_actor_id" \
  -v successor_id="$issue17_departure_successor_id" \
  -v operation_id="$issue17_departure_operation_id" \
  > "$issue17_departure_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'actor_id', true);
SELECT public.leave_board_p(
  :'operation_id'::uuid, :'board_id'::uuid, :'successor_id'::uuid
)->>'status';
COMMIT;
SQL
issue17_departure_second_pid=$!

issue17_departure_second_waiting=false
for _ in $(seq 1 100); do
  issue17_departure_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue17_departure_actor_b' AND wait_event_type = 'Lock'")
  if [[ "$issue17_departure_waiters" == 1 ]]; then
    issue17_departure_second_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$issue17_departure_second_waiting" != true ]]; then
  cat -- "$issue17_departure_first_log" "$issue17_departure_second_log" >&2
  echo 'The second owner-departure session did not wait for the board/receipt lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue17_departure_actor_a'" >/dev/null
  wait "$issue17_departure_first_pid" || true
  wait "$issue17_departure_second_pid" || true
  exit 1
fi

wait "$issue17_departure_first_pid" || { cat -- "$issue17_departure_first_log" >&2; exit 1; }
wait "$issue17_departure_second_pid" || { cat -- "$issue17_departure_second_log" >&2; exit 1; }
issue17_departure_first_result=$(grep -xc 'confirmed' "$issue17_departure_first_log" || true)
issue17_departure_second_result=$(grep -xc 'confirmed' "$issue17_departure_second_log" || true)
issue17_departure_state=$("${psql[@]}" -At \
  -v board_id="$issue17_departure_board_id" \
  -v actor_id="$issue17_departure_actor_id" \
  -v successor_id="$issue17_departure_successor_id" \
  -v operation_id="$issue17_departure_operation_id" <<'SQL'
SELECT CASE WHEN (
  board.owner_id = :'successor_id'::uuid
  AND (SELECT count(*) FROM public.board_memberships AS membership
       WHERE membership.board_id = board.id
         AND membership.user_id = :'successor_id'::uuid
         AND membership.role = 'owner'
         AND membership.revoked_at IS NULL) = 1
  AND (SELECT count(*) FROM public.board_memberships AS membership
       WHERE membership.board_id = board.id
         AND membership.user_id = :'actor_id'::uuid
         AND membership.revoked_at IS NULL) = 0
  AND (SELECT count(*) FROM public.board_departure_operation_receipts AS receipt
       WHERE receipt.actor_id = :'actor_id'::uuid
         AND receipt.operation_id = :'operation_id'::uuid
         AND receipt.result_status = 'confirmed') = 1
) THEN 'ok' ELSE 'bad' END
FROM public.boards AS board WHERE board.id = :'board_id'::uuid;
SQL
)
if [[ "$issue17_departure_first_result" != 1 \
  || "$issue17_departure_second_result" != 1 \
  || "$issue17_departure_state" != ok ]]; then
  echo 'Concurrent owner departure retries did not return one confirmed result and one transfer.' >&2
  cat -- "$issue17_departure_first_log" "$issue17_departure_second_log" >&2
  echo "first_confirmed=$issue17_departure_first_result second_confirmed=$issue17_departure_second_result state=$issue17_departure_state" >&2
  exit 1
fi
echo 'PASS: two concurrent owner departure requests share one receipt and transfer'
"${psql[@]}" -q -c 'DROP TABLE public.issue17_departure_concurrency_fixture'

# Owner removal and collaborator self-departure serialize on the board lock.
issue17_removal_race_dir="$test_dir/issue17-removal-race"
mkdir -- "$issue17_removal_race_dir"
issue17_removal_race_first_log="$issue17_removal_race_dir/owner.log"
issue17_removal_race_second_log="$issue17_removal_race_dir/collaborator.log"
IFS='|' read -r issue17_removal_board_id issue17_removal_slug \
  issue17_removal_owner_id issue17_removal_collaborator_id \
  issue17_removal_membership_id issue17_removal_task_id \
  issue17_removal_operation_id issue17_leave_operation_id < <(
    "${psql[@]}" -AtF '|' -c "SELECT board_id, board_slug, owner_id, collaborator_id, membership_id, task_id, remove_operation_id, leave_operation_id FROM public.issue17_member_removal_concurrency_fixture"
  )

PGAPPNAME=openkanban_issue17_removal_owner "${psql[@]}" -qAt \
  -v board_id="$issue17_removal_board_id" \
  -v owner_id="$issue17_removal_owner_id" \
  -v membership_id="$issue17_removal_membership_id" \
  -v operation_id="$issue17_removal_operation_id" \
  > "$issue17_removal_race_first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM public.boards WHERE id = :'board_id'::uuid FOR UPDATE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT pg_sleep(4);
SELECT public.remove_board_collaborator_p(
  :'operation_id'::uuid, :'board_id'::uuid, :'membership_id'::uuid
)->>'status';
SELECT pg_sleep(2);
COMMIT;
SQL
issue17_removal_race_first_pid=$!

issue17_removal_race_first_holds_lock=false
for _ in $(seq 1 100); do
  issue17_removal_race_first_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue17_removal_owner' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$issue17_removal_race_first_state" == active ]]; then
    issue17_removal_race_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$issue17_removal_race_first_holds_lock" != true ]]; then
  cat -- "$issue17_removal_race_first_log" >&2
  echo 'The owner-removal session did not acquire the board lock.' >&2
  wait "$issue17_removal_race_first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_issue17_removal_collaborator "${psql[@]}" -qAt \
  -v board_id="$issue17_removal_board_id" \
  -v collaborator_id="$issue17_removal_collaborator_id" \
  -v leave_operation_id="$issue17_leave_operation_id" \
  > "$issue17_removal_race_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'collaborator_id', true);
SELECT public.leave_board_p(
  :'leave_operation_id'::uuid, :'board_id'::uuid, NULL
)->>'status';
COMMIT;
SQL
issue17_removal_race_second_pid=$!

issue17_removal_race_second_waiting=false
for _ in $(seq 1 100); do
  issue17_removal_race_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue17_removal_collaborator' AND wait_event_type = 'Lock'")
  if [[ "$issue17_removal_race_waiters" == 1 ]]; then
    issue17_removal_race_second_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$issue17_removal_race_second_waiting" != true ]]; then
  cat -- "$issue17_removal_race_first_log" "$issue17_removal_race_second_log" >&2
  echo 'The collaborator departure did not wait for the owner-removal board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue17_removal_owner'" >/dev/null
  wait "$issue17_removal_race_first_pid" || true
  wait "$issue17_removal_race_second_pid" || true
  exit 1
fi

wait "$issue17_removal_race_first_pid" || { cat -- "$issue17_removal_race_first_log" >&2; exit 1; }
wait "$issue17_removal_race_second_pid" || { cat -- "$issue17_removal_race_second_log" >&2; exit 1; }
issue17_removal_owner_confirmed=$(grep -xc 'confirmed' "$issue17_removal_race_first_log" || true)
issue17_removal_collaborator_unavailable=$(grep -xc 'unavailable' "$issue17_removal_race_second_log" || true)
issue17_removal_race_state=$("${psql[@]}" -At \
  -v board_id="$issue17_removal_board_id" \
  -v owner_id="$issue17_removal_owner_id" \
  -v collaborator_id="$issue17_removal_collaborator_id" \
  -v task_id="$issue17_removal_task_id" \
  -v operation_id="$issue17_removal_operation_id" <<'SQL'
SELECT CASE WHEN (
  board.owner_id = :'owner_id'::uuid
  AND (SELECT count(*) FROM public.board_memberships AS membership
       WHERE membership.board_id = board.id
         AND membership.user_id = :'owner_id'::uuid
         AND membership.role = 'owner'
         AND membership.revoked_at IS NULL) = 1
  AND (SELECT count(*) FROM public.board_memberships AS membership
       WHERE membership.board_id = board.id
         AND membership.user_id = :'collaborator_id'::uuid
         AND membership.revoked_at IS NULL) = 0
  AND (SELECT task.assignee_id IS NULL AND task.assignee_version = 3
       FROM public.tasks AS task WHERE task.id = :'task_id'::uuid)
  AND (SELECT count(*) FROM public.board_departure_operation_receipts AS receipt
       WHERE receipt.actor_id = :'owner_id'::uuid
         AND receipt.operation_id = :'operation_id'::uuid
         AND receipt.action = 'remove_collaborator'
         AND receipt.result_status = 'confirmed') = 1
) THEN 'ok' ELSE 'bad' END
FROM public.boards AS board
WHERE board.id = :'board_id'::uuid;
SQL
)
if [[ "$issue17_removal_owner_confirmed" != 1 \
  || "$issue17_removal_collaborator_unavailable" != 1 \
  || "$issue17_removal_race_state" != ok ]]; then
  echo 'Concurrent owner removal and collaborator departure left an invalid state.' >&2
  cat -- "$issue17_removal_race_first_log" "$issue17_removal_race_second_log" >&2
  echo "owner_confirmed=$issue17_removal_owner_confirmed collaborator_unavailable=$issue17_removal_collaborator_unavailable state=$issue17_removal_race_state" >&2
  exit 1
fi
echo 'PASS: owner removal serializes with collaborator departure without duplicate cleanup'
"${psql[@]}" -q -c 'DROP TABLE public.issue17_member_removal_concurrency_fixture'

# Two sessions can both lose the response to one comment operation. The
# receipt's unique-key winner must be returned to both without duplicating text.
task_comment_race_dir="$test_dir/task-comment-race"
mkdir -- "$task_comment_race_dir"
task_comment_race_first_log="$task_comment_race_dir/actor-a.log"
task_comment_race_second_log="$task_comment_race_dir/actor-b.log"
IFS='|' read -r task_comment_race_slug task_comment_race_task_id \
  task_comment_race_actor_id task_comment_race_operation_id task_comment_race_content < <(
    "${psql[@]}" -AtF '|' -c "SELECT board_slug, task_id, actor_id, operation_id, content FROM public.issue16_comment_concurrency_fixture"
  )

PGAPPNAME=openkanban_task_comment_actor_a "${psql[@]}" -qAt \
  -v board_slug="$task_comment_race_slug" -v task_id="$task_comment_race_task_id" \
  -v actor_id="$task_comment_race_actor_id" -v operation_id="$task_comment_race_operation_id" \
  -v content="$task_comment_race_content" > "$task_comment_race_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'actor_id', true);
WITH operation AS MATERIALIZED (
  SELECT public.create_task_comment_p(
    :'operation_id'::uuid, :'board_slug', :'task_id'::uuid, :'content'
  ) AS result
)
SELECT (result->>'status') || ':' || (result->>'comment_id') FROM operation;
SELECT pg_sleep(6);
COMMIT;
SQL
task_comment_race_first_pid=$!

task_comment_race_first_holding=false
for _ in $(seq 1 100); do
  race_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_task_comment_actor_a' AND state = 'active' AND query LIKE '%pg_sleep(6)%'")
  if [[ "$race_state" == active ]]; then
    task_comment_race_first_holding=true
    break
  fi
  sleep 0.05
done
if [[ "$task_comment_race_first_holding" != true ]]; then
  cat -- "$task_comment_race_first_log" >&2
  echo 'The first comment session did not hold its transaction.' >&2
  wait "$task_comment_race_first_pid" || true
  exit 1
fi

PGAPPNAME=openkanban_task_comment_actor_b "${psql[@]}" -qAt \
  -v board_slug="$task_comment_race_slug" -v task_id="$task_comment_race_task_id" \
  -v actor_id="$task_comment_race_actor_id" -v operation_id="$task_comment_race_operation_id" \
  -v content="$task_comment_race_content" > "$task_comment_race_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'actor_id', true);
WITH operation AS MATERIALIZED (
  SELECT public.create_task_comment_p(
    :'operation_id'::uuid, :'board_slug', :'task_id'::uuid, :'content'
  ) AS result
)
SELECT (result->>'status') || ':' || (result->>'comment_id') FROM operation;
COMMIT;
SQL
task_comment_race_second_pid=$!

task_comment_race_second_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_task_comment_actor_b' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    task_comment_race_second_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$task_comment_race_second_waiting" != true ]]; then
  cat -- "$task_comment_race_first_log" "$task_comment_race_second_log" >&2
  echo 'The second comment session did not wait for the operation receipt.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_task_comment_actor_a'" >/dev/null
  wait "$task_comment_race_first_pid" || true
  wait "$task_comment_race_second_pid" || true
  exit 1
fi

wait "$task_comment_race_first_pid" || { cat -- "$task_comment_race_first_log" >&2; exit 1; }
wait "$task_comment_race_second_pid" || { cat -- "$task_comment_race_second_log" >&2; exit 1; }
task_comment_race_first_result=$(grep -E '^confirmed:' "$task_comment_race_first_log" | tail -n 1)
task_comment_race_second_result=$(grep -E '^confirmed:' "$task_comment_race_second_log" | tail -n 1)
task_comment_race_count=$("${psql[@]}" -At -c "SELECT count(*) FROM public.task_comments WHERE task_id = '$task_comment_race_task_id' AND content = '$task_comment_race_content'")
if [[ -z "$task_comment_race_first_result" \
  || "$task_comment_race_first_result" != "$task_comment_race_second_result" \
  || "$task_comment_race_count" != 1 ]]; then
  echo 'Concurrent comment retries did not return one shared confirmed result.' >&2
  cat -- "$task_comment_race_first_log" "$task_comment_race_second_log" >&2
  echo "matching_comments=$task_comment_race_count" >&2
  exit 1
fi
echo 'PASS: two concurrent sessions reconcile one comment operation without a duplicate'
"${psql[@]}" -q -c 'DROP TABLE public.issue16_comment_concurrency_fixture'

# Restore and expiry purge lock the same task deletion. Exercise both possible
# winners with independent psql sessions and the private controlled-clock seam.
task_recovery_race_dir="$test_dir/task-recovery-race"
mkdir -- "$task_recovery_race_dir"
purge_wins_dir="$task_recovery_race_dir/purge-wins"
restore_wins_dir="$task_recovery_race_dir/restore-wins"
mkdir -- "$purge_wins_dir" "$restore_wins_dir"
purge_wins_task_id=$(
  "${psql[@]}" -At -c "SELECT task_id FROM public.issue14_task_recovery_race_fixture WHERE scenario = 'purge_wins'"
)
purge_wins_board_slug=$(
  "${psql[@]}" -At -c "SELECT board_slug FROM public.issue14_task_recovery_race_fixture WHERE scenario = 'purge_wins'"
)
restore_wins_task_id=$(
  "${psql[@]}" -At -c "SELECT task_id FROM public.issue14_task_recovery_race_fixture WHERE scenario = 'restore_wins'"
)
restore_wins_board_slug=$(
  "${psql[@]}" -At -c "SELECT board_slug FROM public.issue14_task_recovery_race_fixture WHERE scenario = 'restore_wins'"
)
recovery_boundary='2030-01-08 00:00:00+00'
"${psql[@]}" -q -v purge_wins_task_id="$purge_wins_task_id" \
  -v restore_wins_task_id="$restore_wins_task_id" \
  -v recovery_boundary="$recovery_boundary" <<'SQL'
UPDATE public.task_deletions
SET deleted_at = :'recovery_boundary'::timestamptz - interval '168 hours',
    expires_at = :'recovery_boundary'::timestamptz
WHERE task_id IN (:'purge_wins_task_id'::uuid, :'restore_wins_task_id'::uuid);
UPDATE public.issue14_task_recovery_race_fixture
SET expires_at = :'recovery_boundary'::timestamptz;
SQL

purge_wins_first_log="$purge_wins_dir/purger.log"
purge_wins_second_log="$purge_wins_dir/restorer.log"
PGAPPNAME=openkanban_issue14_purge_wins_purger "${psql[@]}" -qAt \
  -v task_id="$purge_wins_task_id" -v expires_at="$recovery_boundary" \
  > "$purge_wins_first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT deletion.board_id AS board_id
FROM public.task_deletions AS deletion
WHERE deletion.task_id = :'task_id'::uuid \gset
SELECT board.id FROM public.boards AS board
WHERE board.id = :'board_id'::uuid FOR UPDATE;
SELECT task_id FROM public.task_deletions WHERE task_id = :'task_id'::uuid FOR UPDATE;
SELECT pg_sleep(4);
SELECT public.purge_expired_task_internal_p(:'task_id'::uuid, :'expires_at'::timestamptz);
COMMIT;
SQL
purge_wins_first_pid=$!
purge_wins_first_holds_lock=false
for _ in $(seq 1 100); do
  purge_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue14_purge_wins_purger' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$purge_wins_state" == active ]]; then
    purge_wins_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$purge_wins_first_holds_lock" != true ]]; then
  cat -- "$purge_wins_first_log" >&2
  echo 'The purger did not acquire the task-deletion lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue14_purge_wins_restorer "${psql[@]}" -qAt \
  -v task_id="$purge_wins_task_id" -v board_slug="$purge_wins_board_slug" \
  -v expires_at="$recovery_boundary" \
  > "$purge_wins_second_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.restore_task_internal_p(
  '14000000-0000-4000-8000-000000000101', :'board_slug', :'task_id'::uuid,
  NULL, :'expires_at'::timestamptz
)->>'status';
COMMIT;
SQL
purge_wins_second_pid=$!
purge_wins_second_waits=false
for _ in $(seq 1 100); do
  purge_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue14_purge_wins_restorer' AND wait_event_type = 'Lock'")
  if [[ "$purge_wins_waiters" == 1 ]]; then
    purge_wins_second_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$purge_wins_second_waits" != true ]]; then
  cat -- "$purge_wins_second_log" >&2
  echo 'The restorer did not wait for the concurrent purge.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue14_purge_wins_purger'" >/dev/null
  wait "$purge_wins_first_pid" || true
  wait "$purge_wins_second_pid" || true
  exit 1
fi
wait "$purge_wins_first_pid" || { cat -- "$purge_wins_first_log" >&2; exit 1; }
wait "$purge_wins_second_pid" || { cat -- "$purge_wins_second_log" >&2; exit 1; }
if ! grep -Fxq 'purged' "$purge_wins_first_log" \
  || ! grep -Fxq 'unavailable' "$purge_wins_second_log"; then
  echo 'Purge-first task recovery race did not produce one terminal result.' >&2
  cat -- "$purge_wins_first_log" "$purge_wins_second_log" >&2
  exit 1
fi
purge_wins_final=$("${psql[@]}" -At -v task_id="$purge_wins_task_id" <<'SQL'
SELECT CASE WHEN deletion.state = 'purged' AND deletion.task_snapshot IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = deletion.task_id)
  THEN 'valid' ELSE 'invalid' END
FROM public.task_deletions AS deletion
WHERE deletion.task_id = :'task_id'::uuid;
SQL
)
if [[ "$purge_wins_final" != valid ]]; then
  echo 'Purge-first recovery race left partial task content or a restored row.' >&2
  exit 1
fi
echo 'PASS: an exact-deadline purge wins atomically over a waiting restore.'

# Column restore and purge lock the same recovery snapshot. Exercise each
# possible winner against the issue #18 controlled-deadline fixtures.
column_recovery_race_dir="$test_dir/column-recovery-race"
mkdir -- "$column_recovery_race_dir"
column_purge_wins_dir="$column_recovery_race_dir/purge-wins"
column_restore_wins_dir="$column_recovery_race_dir/restore-wins"
mkdir -- "$column_purge_wins_dir" "$column_restore_wins_dir"
column_purge_wins_id=$(
  "${psql[@]}" -At -c "SELECT column_id FROM public.issue18_column_recovery_race_fixture WHERE scenario = 'purge_wins'"
)
column_purge_wins_slug=$(
  "${psql[@]}" -At -c "SELECT board_slug FROM public.issue18_column_recovery_race_fixture WHERE scenario = 'purge_wins'"
)
column_restore_wins_id=$(
  "${psql[@]}" -At -c "SELECT column_id FROM public.issue18_column_recovery_race_fixture WHERE scenario = 'restore_wins'"
)
column_restore_wins_slug=$(
  "${psql[@]}" -At -c "SELECT board_slug FROM public.issue18_column_recovery_race_fixture WHERE scenario = 'restore_wins'"
)
column_recovery_boundary='2035-10-26 12:00:00+00'

column_purge_wins_purger_log="$column_purge_wins_dir/purger.log"
column_purge_wins_restorer_log="$column_purge_wins_dir/restorer.log"
PGAPPNAME=openkanban_issue18_column_purge_wins_purger "${psql[@]}" -qAt \
  -v column_id="$column_purge_wins_id" -v expires_at="$column_recovery_boundary" \
  > "$column_purge_wins_purger_log" 2>&1 <<'SQL' &
BEGIN;
SELECT deletion.board_id AS board_id
FROM public.column_deletions AS deletion
WHERE deletion.column_id = :'column_id'::uuid \gset
SELECT board.id FROM public.boards AS board
WHERE board.id = :'board_id'::uuid FOR UPDATE;
SELECT column_id FROM public.column_deletions WHERE column_id = :'column_id'::uuid FOR UPDATE;
SELECT pg_sleep(2);
SELECT public.purge_expired_column_internal_p(:'column_id'::uuid, :'expires_at'::timestamptz);
COMMIT;
SQL
column_purge_wins_purger_pid=$!
column_purge_wins_lock_held=false
for _ in $(seq 1 100); do
  column_purge_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_column_purge_wins_purger' AND state = 'active' AND query LIKE '%pg_sleep(2)%'")
  if [[ "$column_purge_wins_state" == active ]]; then
    column_purge_wins_lock_held=true
    break
  fi
  sleep 0.05
done
if [[ "$column_purge_wins_lock_held" != true ]]; then
  cat -- "$column_purge_wins_purger_log" >&2
  echo 'The column purger did not acquire the recovery lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue18_column_purge_wins_restorer "${psql[@]}" -qAt \
  -v column_id="$column_purge_wins_id" -v board_slug="$column_purge_wins_slug" \
  -v expires_at="$column_recovery_boundary" \
  > "$column_purge_wins_restorer_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.restore_column_internal_p(
  '18000000-0000-4000-8000-000000000131', :'board_slug', :'column_id'::uuid,
  :'expires_at'::timestamptz
)->>'status';
COMMIT;
SQL
column_purge_wins_restorer_pid=$!
column_purge_wins_waits=false
for _ in $(seq 1 100); do
  column_purge_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_column_purge_wins_restorer' AND wait_event_type = 'Lock'")
  if [[ "$column_purge_wins_waiters" == 1 ]]; then
    column_purge_wins_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$column_purge_wins_waits" != true ]]; then
  cat -- "$column_purge_wins_restorer_log" >&2
  echo 'The column restorer did not wait for the concurrent purge.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_column_purge_wins_purger'" >/dev/null
  wait "$column_purge_wins_purger_pid" || true
  wait "$column_purge_wins_restorer_pid" || true
  exit 1
fi
wait "$column_purge_wins_purger_pid" || { cat -- "$column_purge_wins_purger_log" >&2; exit 1; }
wait "$column_purge_wins_restorer_pid" || { cat -- "$column_purge_wins_restorer_log" >&2; exit 1; }
if ! grep -Fxq 'purged' "$column_purge_wins_purger_log" \
  || ! grep -Fxq 'unavailable' "$column_purge_wins_restorer_log"; then
  echo 'Purge-first column recovery race did not produce one terminal result.' >&2
  cat -- "$column_purge_wins_purger_log" "$column_purge_wins_restorer_log" >&2
  exit 1
fi
column_purge_wins_final=$("${psql[@]}" -At -v column_id="$column_purge_wins_id" <<'SQL'
SELECT CASE WHEN deletion.state = 'purged' AND deletion.column_snapshot IS NULL
  AND NOT EXISTS (SELECT 1 FROM public.columns AS column_row WHERE column_row.id = deletion.column_id)
  THEN 'valid' ELSE 'invalid' END
FROM public.column_deletions AS deletion
WHERE deletion.column_id = :'column_id'::uuid;
SQL
)
if [[ "$column_purge_wins_final" != valid ]]; then
  echo 'Purge-first column race left a partial snapshot or restored row.' >&2
  exit 1
fi
echo 'PASS: an exact-deadline column purge wins atomically over a waiting restore.'

column_restore_wins_restorer_log="$column_restore_wins_dir/restorer.log"
column_restore_wins_purger_log="$column_restore_wins_dir/purger.log"
PGAPPNAME=openkanban_issue18_column_restore_wins_restorer "${psql[@]}" -qAt \
  -v column_id="$column_restore_wins_id" -v board_slug="$column_restore_wins_slug" \
  -v expires_at="$column_recovery_boundary" \
  > "$column_restore_wins_restorer_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.restore_column_internal_p(
  '18000000-0000-4000-8000-000000000132', :'board_slug', :'column_id'::uuid,
  :'expires_at'::timestamptz - interval '1 microsecond'
)->>'status';
SELECT pg_sleep(2);
COMMIT;
SQL
column_restore_wins_restorer_pid=$!
column_restore_wins_lock_held=false
for _ in $(seq 1 100); do
  column_restore_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_column_restore_wins_restorer' AND state = 'active' AND query LIKE '%pg_sleep(2)%'")
  if [[ "$column_restore_wins_state" == active ]]; then
    column_restore_wins_lock_held=true
    break
  fi
  sleep 0.05
done
if [[ "$column_restore_wins_lock_held" != true ]]; then
  cat -- "$column_restore_wins_restorer_log" >&2
  echo 'The column restorer did not acquire the recovery lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue18_column_restore_wins_purger "${psql[@]}" -qAt \
  -v column_id="$column_restore_wins_id" -v expires_at="$column_recovery_boundary" \
  > "$column_restore_wins_purger_log" 2>&1 <<'SQL' &
BEGIN;
SELECT deletion.board_id AS board_id
FROM public.column_deletions AS deletion
WHERE deletion.column_id = :'column_id'::uuid \gset
SELECT board.id FROM public.boards AS board
WHERE board.id = :'board_id'::uuid FOR UPDATE;
SELECT column_id FROM public.column_deletions WHERE column_id = :'column_id'::uuid FOR UPDATE;
SELECT public.purge_expired_column_internal_p(:'column_id'::uuid, :'expires_at'::timestamptz);
COMMIT;
SQL
column_restore_wins_purger_pid=$!
column_restore_wins_waits=false
for _ in $(seq 1 100); do
  column_restore_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_column_restore_wins_purger' AND wait_event_type = 'Lock'")
  if [[ "$column_restore_wins_waiters" == 1 ]]; then
    column_restore_wins_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$column_restore_wins_waits" != true ]]; then
  cat -- "$column_restore_wins_purger_log" >&2
  echo 'The column purger did not wait for the concurrent restore.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_column_restore_wins_restorer'" >/dev/null
  wait "$column_restore_wins_restorer_pid" || true
  wait "$column_restore_wins_purger_pid" || true
  exit 1
fi
wait "$column_restore_wins_restorer_pid" || { cat -- "$column_restore_wins_restorer_log" >&2; exit 1; }
wait "$column_restore_wins_purger_pid" || { cat -- "$column_restore_wins_purger_log" >&2; exit 1; }
if ! grep -Fxq 'confirmed' "$column_restore_wins_restorer_log" \
  || ! grep -Fxq 'already_terminal' "$column_restore_wins_purger_log"; then
  echo 'Restore-first column recovery race did not produce one terminal result.' >&2
  cat -- "$column_restore_wins_restorer_log" "$column_restore_wins_purger_log" >&2
  exit 1
fi
column_restore_wins_final=$("${psql[@]}" -At -v column_id="$column_restore_wins_id" <<'SQL'
SELECT CASE WHEN EXISTS (SELECT 1 FROM public.columns AS column_row WHERE column_row.id = :'column_id'::uuid)
  AND NOT EXISTS (SELECT 1 FROM public.column_deletions AS deletion WHERE deletion.column_id = :'column_id'::uuid)
  THEN 'valid' ELSE 'invalid' END;
SQL
)
if [[ "$column_restore_wins_final" != valid ]]; then
  echo 'Restore-first column race left a missing column or deletion snapshot.' >&2
  exit 1
fi
echo 'PASS: a column restore wins atomically over a waiting exact-deadline purge.'
"${psql[@]}" -q -c 'DROP TABLE public.issue18_column_recovery_race_fixture'

# Board purge/restore serialize on the board row and recovery ledger. Also
# exercise edits racing the tombstone in both commit orders.
board_recovery_race_dir="$test_dir/board-recovery-race"
mkdir -- "$board_recovery_race_dir"
board_recovery_boundary='2020-10-26 12:00:00+00'
board_purge_wins_id=$(
  "${psql[@]}" -At -c "SELECT board_id FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'purge_wins'"
)
board_restore_wins_id=$(
  "${psql[@]}" -At -c "SELECT board_id FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'restore_wins'"
)
board_edit_wins_id=$(
  "${psql[@]}" -At -c "SELECT board_id FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'edit_wins'"
)
board_edit_wins_slug=$(
  "${psql[@]}" -At -c "SELECT board_slug FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'edit_wins'"
)
board_edit_wins_task=$(
  "${psql[@]}" -At -c "SELECT task_id FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'edit_wins'"
)
board_delete_wins_id=$(
  "${psql[@]}" -At -c "SELECT board_id FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'delete_wins'"
)
board_delete_wins_slug=$(
  "${psql[@]}" -At -c "SELECT board_slug FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'delete_wins'"
)
board_delete_wins_task=$(
  "${psql[@]}" -At -c "SELECT task_id FROM public.issue18_board_recovery_race_fixture WHERE scenario = 'delete_wins'"
)

board_purge_wins_purger_log="$board_recovery_race_dir/purge-wins-purger.log"
board_purge_wins_restorer_log="$board_recovery_race_dir/purge-wins-restorer.log"
PGAPPNAME=openkanban_issue18_board_purge_wins_purger "${psql[@]}" -qAt \
  -v board_id="$board_purge_wins_id" -v expires_at="$board_recovery_boundary" \
  > "$board_purge_wins_purger_log" 2>&1 <<'SQL' &
BEGIN;
SELECT id FROM public.boards WHERE id = :'board_id'::uuid FOR UPDATE;
SELECT pg_sleep(2);
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.purge_expired_board_internal_p(:'board_id'::uuid, :'expires_at'::timestamptz);
COMMIT;
SQL
board_purge_wins_purger_pid=$!
board_purge_wins_lock_held=false
for _ in $(seq 1 100); do
  board_purge_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_purge_wins_purger' AND state = 'active' AND query LIKE '%pg_sleep(2)%'")
  if [[ "$board_purge_wins_state" == active ]]; then
    board_purge_wins_lock_held=true
    break
  fi
  sleep 0.05
done
if [[ "$board_purge_wins_lock_held" != true ]]; then
  cat -- "$board_purge_wins_purger_log" >&2
  echo 'The board purger did not acquire the board lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue18_board_purge_wins_restorer "${psql[@]}" -qAt \
  -v board_id="$board_purge_wins_id" -v expires_at="$board_recovery_boundary" \
  > "$board_purge_wins_restorer_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
SELECT public.restore_board_internal_p(
  'a8180000-0000-4000-8000-000000000431', :'board_id'::uuid, NULL,
  :'expires_at'::timestamptz
)->>'status';
COMMIT;
SQL
board_purge_wins_restorer_pid=$!
board_purge_wins_waits=false
for _ in $(seq 1 100); do
  board_purge_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_purge_wins_restorer' AND wait_event_type = 'Lock'")
  if [[ "$board_purge_wins_waiters" == 1 ]]; then
    board_purge_wins_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$board_purge_wins_waits" != true ]]; then
  cat -- "$board_purge_wins_restorer_log" >&2
  echo 'The board restorer did not wait for the concurrent purge.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_purge_wins_purger'" >/dev/null
  wait "$board_purge_wins_purger_pid" || true
  wait "$board_purge_wins_restorer_pid" || true
  exit 1
fi
wait "$board_purge_wins_purger_pid" || { cat -- "$board_purge_wins_purger_log" >&2; exit 1; }
wait "$board_purge_wins_restorer_pid" || { cat -- "$board_purge_wins_restorer_log" >&2; exit 1; }
if ! grep -Fxq 'purged' "$board_purge_wins_purger_log" \
  || ! grep -Fxq 'unavailable' "$board_purge_wins_restorer_log"; then
  echo 'Purge-first board recovery race did not produce one terminal result.' >&2
  cat -- "$board_purge_wins_purger_log" "$board_purge_wins_restorer_log" >&2
  exit 1
fi
board_purge_wins_final=$("${psql[@]}" -At -v board_id="$board_purge_wins_id" <<'SQL'
SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM public.boards WHERE id = :'board_id'::uuid)
  AND NOT EXISTS (SELECT 1 FROM public.tasks WHERE id = (
    SELECT task_id FROM public.issue18_board_recovery_race_fixture
    WHERE scenario = 'purge_wins'
  )) THEN 'valid' ELSE 'invalid' END;
SQL
)
if [[ "$board_purge_wins_final" != valid ]]; then
  echo 'Purge-first board race left board/task content behind.' >&2
  exit 1
fi
echo 'PASS: an exact-deadline board purge wins atomically over a waiting restore.'

board_restore_wins_restorer_log="$board_recovery_race_dir/restore-wins-restorer.log"
board_restore_wins_purger_log="$board_recovery_race_dir/restore-wins-purger.log"
PGAPPNAME=openkanban_issue18_board_restore_wins_restorer "${psql[@]}" -qAt \
  -v board_id="$board_restore_wins_id" -v expires_at="$board_recovery_boundary" \
  > "$board_restore_wins_restorer_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
SELECT public.restore_board_internal_p(
  'a8180000-0000-4000-8000-000000000432', :'board_id'::uuid, NULL,
  :'expires_at'::timestamptz - interval '1 microsecond'
)->>'status';
SELECT pg_sleep(2);
COMMIT;
SQL
board_restore_wins_restorer_pid=$!
board_restore_wins_lock_held=false
for _ in $(seq 1 100); do
  board_restore_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_restore_wins_restorer' AND state = 'active' AND query LIKE '%pg_sleep(2)%'")
  if [[ "$board_restore_wins_state" == active ]]; then
    board_restore_wins_lock_held=true
    break
  fi
  sleep 0.05
done
if [[ "$board_restore_wins_lock_held" != true ]]; then
  cat -- "$board_restore_wins_restorer_log" >&2
  echo 'The board restorer did not acquire the board lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue18_board_restore_wins_purger "${psql[@]}" -qAt \
  -v board_id="$board_restore_wins_id" -v expires_at="$board_recovery_boundary" \
  > "$board_restore_wins_purger_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.role', 'service_role', true);
SELECT public.purge_expired_board_internal_p(:'board_id'::uuid, :'expires_at'::timestamptz);
COMMIT;
SQL
board_restore_wins_purger_pid=$!
board_restore_wins_waits=false
for _ in $(seq 1 100); do
  board_restore_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_restore_wins_purger' AND wait_event_type = 'Lock'")
  if [[ "$board_restore_wins_waiters" == 1 ]]; then
    board_restore_wins_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$board_restore_wins_waits" != true ]]; then
  cat -- "$board_restore_wins_purger_log" >&2
  echo 'The board purger did not wait for the concurrent restore.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_restore_wins_restorer'" >/dev/null
  wait "$board_restore_wins_restorer_pid" || true
  wait "$board_restore_wins_purger_pid" || true
  exit 1
fi
wait "$board_restore_wins_restorer_pid" || { cat -- "$board_restore_wins_restorer_log" >&2; exit 1; }
wait "$board_restore_wins_purger_pid" || { cat -- "$board_restore_wins_purger_log" >&2; exit 1; }
if ! grep -Fxq 'confirmed' "$board_restore_wins_restorer_log" \
  || ! grep -Fxq 'already_terminal' "$board_restore_wins_purger_log"; then
  echo 'Restore-first board recovery race did not produce one terminal result.' >&2
  cat -- "$board_restore_wins_restorer_log" "$board_restore_wins_purger_log" >&2
  exit 1
fi
board_restore_wins_final=$("${psql[@]}" -At -v board_id="$board_restore_wins_id" <<'SQL'
SELECT CASE WHEN EXISTS (SELECT 1 FROM public.boards WHERE id = :'board_id'::uuid)
  AND EXISTS (
    SELECT 1 FROM public.tasks AS task
    JOIN public.columns AS column_row ON column_row.id = task.column_id
    WHERE column_row.board_id = :'board_id'::uuid
  )
  AND NOT EXISTS (SELECT 1 FROM public.board_recoverable_deletions WHERE board_id = :'board_id'::uuid)
  THEN 'valid' ELSE 'invalid' END;
SQL
)
if [[ "$board_restore_wins_final" != valid ]]; then
  echo 'Restore-first board race left a missing board/task or recovery marker.' >&2
  exit 1
fi
echo 'PASS: a board restore wins atomically over a waiting exact-deadline purge.'

board_edit_wins_editor_log="$board_recovery_race_dir/edit-wins-editor.log"
board_edit_wins_deleter_log="$board_recovery_race_dir/edit-wins-deleter.log"
PGAPPNAME=openkanban_issue18_board_edit_wins_editor "${psql[@]}" -qAt \
  -v board_slug="$board_edit_wins_slug" -v task_id="$board_edit_wins_task" \
  > "$board_edit_wins_editor_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
SELECT public.edit_task_fields_p(
  'a8180000-0000-4000-8000-000000000441', :'board_slug', :'task_id'::uuid,
  '{"title":"Edición concurrente conservada"}'::jsonb, '{"title":1}'::jsonb
)->>'status';
SELECT pg_sleep(2);
COMMIT;
SQL
board_edit_wins_editor_pid=$!
board_edit_wins_lock_held=false
for _ in $(seq 1 100); do
  board_edit_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_edit_wins_editor' AND state = 'active' AND query LIKE '%pg_sleep(2)%'")
  if [[ "$board_edit_wins_state" == active ]]; then
    board_edit_wins_lock_held=true
    break
  fi
  sleep 0.05
done
if [[ "$board_edit_wins_lock_held" != true ]]; then
  cat -- "$board_edit_wins_editor_log" >&2
  echo 'The task editor did not acquire the board lock.' >&2
  exit 1
fi
PGAPPNAME=openkanban_issue18_board_edit_wins_deleter "${psql[@]}" -qAt \
  -v board_id="$board_edit_wins_id" \
  -v board_slug="$board_edit_wins_slug" \
  > "$board_edit_wins_deleter_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
SELECT public.delete_board_p(
  'a8180000-0000-4000-8000-000000000451', :'board_slug', :'board_id'::uuid
)->>'status';
COMMIT;
SQL
board_edit_wins_deleter_pid=$!
board_edit_wins_waits=false
for _ in $(seq 1 100); do
  board_edit_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_edit_wins_deleter' AND wait_event_type = 'Lock'")
  if [[ "$board_edit_wins_waiters" == 1 ]]; then
    board_edit_wins_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$board_edit_wins_waits" != true ]]; then
  cat -- "$board_edit_wins_deleter_log" >&2
  echo 'The board deleter did not wait for the concurrent edit.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_edit_wins_editor'" >/dev/null
  wait "$board_edit_wins_editor_pid" || true
  wait "$board_edit_wins_deleter_pid" || true
  exit 1
fi
wait "$board_edit_wins_editor_pid" || { cat -- "$board_edit_wins_editor_log" >&2; exit 1; }
wait "$board_edit_wins_deleter_pid" || { cat -- "$board_edit_wins_deleter_log" >&2; exit 1; }
if ! grep -Fxq 'confirmed' "$board_edit_wins_editor_log" \
  || ! grep -Fxq 'recoverable' "$board_edit_wins_deleter_log"; then
  echo 'Edit-first board deletion race did not preserve one ordered result.' >&2
  cat -- "$board_edit_wins_editor_log" "$board_edit_wins_deleter_log" >&2
  exit 1
fi
board_edit_wins_final=$("${psql[@]}" -At -v task_id="$board_edit_wins_task" <<'SQL'
SELECT CASE WHEN task.title = 'Edición concurrente conservada'
  AND EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS recovery
    JOIN public.columns AS column_row ON column_row.board_id = recovery.board_id
    WHERE column_row.id = task.column_id
  ) THEN 'valid' ELSE 'invalid' END
FROM public.tasks AS task WHERE task.id = :'task_id'::uuid;
SQL
)
if [[ "$board_edit_wins_final" != valid ]]; then
  echo 'Edit-first board deletion race lost the committed task content or tombstone.' >&2
  exit 1
fi
echo 'PASS: a task edit that wins the board lock commits before the board tombstone.'

board_delete_wins_deleter_log="$board_recovery_race_dir/delete-wins-deleter.log"
board_delete_wins_editor_log="$board_recovery_race_dir/delete-wins-editor.log"
PGAPPNAME=openkanban_issue18_board_delete_wins_deleter "${psql[@]}" -qAt \
  -v board_id="$board_delete_wins_id" -v board_slug="$board_delete_wins_slug" \
  > "$board_delete_wins_deleter_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
SELECT public.delete_board_p(
  'a8180000-0000-4000-8000-000000000452', :'board_slug', :'board_id'::uuid
)->>'status';
SELECT pg_sleep(2);
COMMIT;
SQL
board_delete_wins_deleter_pid=$!
board_delete_wins_lock_held=false
for _ in $(seq 1 100); do
  board_delete_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_delete_wins_deleter' AND state = 'active' AND query LIKE '%pg_sleep(2)%'")
  if [[ "$board_delete_wins_state" == active ]]; then
    board_delete_wins_lock_held=true
    break
  fi
  sleep 0.05
done
if [[ "$board_delete_wins_lock_held" != true ]]; then
  cat -- "$board_delete_wins_deleter_log" >&2
  echo 'The board deleter did not acquire the board lock.' >&2
  exit 1
fi
PGAPPNAME=openkanban_issue18_board_delete_wins_editor "${psql[@]}" -qAt \
  > "$board_delete_wins_editor_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  v_result jsonb;
  v_board_slug text;
  v_task_id uuid;
BEGIN
  SELECT fixture.board_slug, fixture.task_id
  INTO STRICT v_board_slug, v_task_id
  FROM public.issue18_board_recovery_race_fixture AS fixture
  WHERE fixture.scenario = 'delete_wins';
  BEGIN
    v_result := public.edit_task_fields_p(
      'a8180000-0000-4000-8000-000000000442', v_board_slug, v_task_id,
      '{"title":"No debe escribirse"}'::jsonb, '{"title":1}'::jsonb
    );
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'board access blocked';
    RETURN;
  END;
  IF v_result->>'status' = 'unavailable' THEN
    RAISE NOTICE 'board access blocked';
    RETURN;
  END IF;
  RAISE EXCEPTION 'An edit crossed the board tombstone: %', v_result;
END;
$$;
COMMIT;
SQL
board_delete_wins_editor_pid=$!
board_delete_wins_waits=false
for _ in $(seq 1 100); do
  board_delete_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_delete_wins_editor' AND wait_event_type = 'Lock'")
  if [[ "$board_delete_wins_waiters" == 1 ]]; then
    board_delete_wins_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$board_delete_wins_waits" != true ]]; then
  cat -- "$board_delete_wins_editor_log" >&2
  echo 'The task editor did not wait for the board tombstone.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_board_delete_wins_deleter'" >/dev/null
  wait "$board_delete_wins_deleter_pid" || true
  wait "$board_delete_wins_editor_pid" || true
  exit 1
fi
wait "$board_delete_wins_deleter_pid" || { cat -- "$board_delete_wins_deleter_log" >&2; exit 1; }
wait "$board_delete_wins_editor_pid" || { cat -- "$board_delete_wins_editor_log" >&2; exit 1; }
if ! grep -Fxq 'recoverable' "$board_delete_wins_deleter_log" \
  || ! grep -Fq 'board access blocked' "$board_delete_wins_editor_log"; then
  echo 'Delete-first board content race did not block the waiting edit.' >&2
  cat -- "$board_delete_wins_deleter_log" "$board_delete_wins_editor_log" >&2
  exit 1
fi
board_delete_wins_final=$("${psql[@]}" -At -v task_id="$board_delete_wins_task" <<'SQL'
SELECT CASE WHEN task.title = 'Título inicial delete_wins'
  AND EXISTS (
    SELECT 1 FROM public.board_recoverable_deletions AS recovery
    JOIN public.columns AS column_row ON column_row.board_id = recovery.board_id
    WHERE column_row.id = task.column_id
  ) THEN 'valid' ELSE 'invalid' END
FROM public.tasks AS task WHERE task.id = :'task_id'::uuid;
SQL
)
if [[ "$board_delete_wins_final" != valid ]]; then
  echo 'Delete-first board content race changed content after the tombstone.' >&2
  exit 1
fi
echo 'PASS: a board tombstone that wins the lock blocks a waiting task edit.'

"${psql[@]}" -q -c 'DROP TABLE public.issue18_board_recovery_race_fixture'

# Invitation wrappers must lock the board before checking ownership. A delete
# that wins the row lock commits its tombstone before waiting create/list calls
# revalidate; if a create wins, deletion waits and revokes the new invitation.
issue18_invitation_race_dir="$test_dir/issue18-invitation-wrapper-race"
mkdir -- "$issue18_invitation_race_dir"
issue18_delete_first_lock_log="$issue18_invitation_race_dir/delete-first-lock.log"
issue18_delete_first_create_log="$issue18_invitation_race_dir/delete-first-create.log"
issue18_delete_first_list_log="$issue18_invitation_race_dir/delete-first-list.log"
issue18_create_first_log="$issue18_invitation_race_dir/create-first.log"
issue18_create_first_delete_log="$issue18_invitation_race_dir/create-first-delete.log"

IFS='|' read -r issue18_delete_first_board_id issue18_delete_first_slug \
  issue18_delete_first_owner_id issue18_delete_first_operation_id < <(
  "${psql[@]}" -AtF '|' -c "SELECT board_id, board_slug, owner_id, delete_operation_id FROM public.issue18_board_invitation_race_fixture WHERE scenario = 'delete_first'"
)
IFS='|' read -r issue18_create_first_board_id issue18_create_first_slug \
  issue18_create_first_owner_id issue18_create_first_operation_id < <(
  "${psql[@]}" -AtF '|' -c "SELECT board_id, board_slug, owner_id, delete_operation_id FROM public.issue18_board_invitation_race_fixture WHERE scenario = 'create_first'"
)

PGAPPNAME=openkanban_issue18_invitation_delete_first "${psql[@]}" -qAt \
  -v board_id="$issue18_delete_first_board_id" \
  -v board_slug="$issue18_delete_first_slug" \
  -v owner_id="$issue18_delete_first_owner_id" \
  -v operation_id="$issue18_delete_first_operation_id" \
  > "$issue18_delete_first_lock_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT public.delete_board_p(:'operation_id'::uuid, :'board_slug', :'board_id'::uuid)->>'status';
SELECT pg_sleep(8);
COMMIT;
SQL
issue18_delete_first_pid=$!
issue18_delete_first_holds_lock=false
for _ in $(seq 1 100); do
  issue18_delete_first_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_invitation_delete_first' AND state = 'active' AND query LIKE '%pg_sleep(8)%'")
  if [[ "$issue18_delete_first_state" == active ]]; then
    issue18_delete_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$issue18_delete_first_holds_lock" != true ]]; then
  cat -- "$issue18_delete_first_lock_log" >&2
  echo 'The delete-first invitation race did not hold the board lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue18_invitation_create_waiting "${psql[@]}" -qAt \
  -v board_slug="$issue18_delete_first_slug" \
  -v owner_id="$issue18_delete_first_owner_id" \
  > "$issue18_delete_first_create_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.board_slug', :'board_slug', true);
DO $$
DECLARE
  v_denied boolean := false;
BEGIN
  BEGIN
    PERFORM public.create_direct_board_invitation_p(
      current_setting('test.board_slug'), 'revocation-user@example.test'
    );
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A create waiting behind deletion was not denied after tombstone commit';
  END IF;
END;
$$;
COMMIT;
SQL
issue18_delete_first_create_pid=$!

PGAPPNAME=openkanban_issue18_invitation_list_waiting "${psql[@]}" -qAt \
  -v board_slug="$issue18_delete_first_slug" \
  -v owner_id="$issue18_delete_first_owner_id" \
  > "$issue18_delete_first_list_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT set_config('test.board_slug', :'board_slug', true);
DO $$
DECLARE
  v_count integer;
  v_denied boolean := false;
BEGIN
  BEGIN
    SELECT count(*) INTO v_count
    FROM public.list_board_invitations_p(current_setting('test.board_slug'));
  EXCEPTION WHEN SQLSTATE '42501' THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'A list waiting behind deletion exposed % invitation rows after tombstone commit', v_count;
  END IF;
END;
$$;
COMMIT;
SQL
issue18_delete_first_list_pid=$!

issue18_delete_first_waiting=false
for _ in $(seq 1 100); do
  issue18_delete_first_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('openkanban_issue18_invitation_create_waiting', 'openkanban_issue18_invitation_list_waiting') AND wait_event_type = 'Lock'")
  if [[ "$issue18_delete_first_waiters" == 2 ]]; then
    issue18_delete_first_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$issue18_delete_first_waiting" != true ]]; then
  cat -- "$issue18_delete_first_create_log" "$issue18_delete_first_list_log" >&2
  echo 'Invitation create/list did not both wait for the delete-first board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_invitation_delete_first'" >/dev/null
  wait "$issue18_delete_first_pid" || true
  wait "$issue18_delete_first_create_pid" || true
  wait "$issue18_delete_first_list_pid" || true
  exit 1
fi
wait "$issue18_delete_first_pid" || { cat -- "$issue18_delete_first_lock_log" >&2; exit 1; }
wait "$issue18_delete_first_create_pid" || { cat -- "$issue18_delete_first_create_log" >&2; exit 1; }
wait "$issue18_delete_first_list_pid" || { cat -- "$issue18_delete_first_list_log" >&2; exit 1; }
issue18_delete_first_final=$("${psql[@]}" -At -v board_id="$issue18_delete_first_board_id" <<'SQL'
SELECT CASE WHEN EXISTS (
  SELECT 1 FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = :'board_id'::uuid
) AND NOT EXISTS (
  SELECT 1 FROM public.board_invitations AS invitation
  WHERE invitation.board_id = :'board_id'::uuid AND invitation.status = 'pending'
) THEN 'valid' ELSE 'invalid' END;
SQL
)
if [[ "$issue18_delete_first_final" != valid ]]; then
  echo 'Delete-first wrapper race left a pending invitation or lost its tombstone.' >&2
  exit 1
fi
echo 'PASS: invitation create/list wait behind a board delete and are denied after its tombstone commits.'

PGAPPNAME=openkanban_issue18_invitation_create_first "${psql[@]}" -qAt \
  -v board_slug="$issue18_create_first_slug" \
  -v owner_id="$issue18_create_first_owner_id" \
  > "$issue18_create_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT public.create_direct_board_invitation_p(
  :'board_slug', 'revocation-user@example.test'
)->>'status';
SELECT pg_sleep(8);
COMMIT;
SQL
issue18_create_first_pid=$!
issue18_create_first_holds_lock=false
for _ in $(seq 1 100); do
  issue18_create_first_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_invitation_create_first' AND state = 'active' AND query LIKE '%pg_sleep(8)%'")
  if [[ "$issue18_create_first_state" == active ]]; then
    issue18_create_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$issue18_create_first_holds_lock" != true ]]; then
  cat -- "$issue18_create_first_log" >&2
  echo 'The create-first invitation race did not hold the board lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue18_invitation_delete_waiting "${psql[@]}" -qAt \
  -v board_id="$issue18_create_first_board_id" \
  -v board_slug="$issue18_create_first_slug" \
  -v owner_id="$issue18_create_first_owner_id" \
  -v operation_id="$issue18_create_first_operation_id" \
  > "$issue18_create_first_delete_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'owner_id', true);
SELECT public.delete_board_p(:'operation_id'::uuid, :'board_slug', :'board_id'::uuid)->>'status';
COMMIT;
SQL
issue18_create_first_delete_pid=$!
issue18_create_first_delete_waits=false
for _ in $(seq 1 100); do
  issue18_create_first_delete_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_invitation_delete_waiting' AND wait_event_type = 'Lock'")
  if [[ "$issue18_create_first_delete_waiters" == 1 ]]; then
    issue18_create_first_delete_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$issue18_create_first_delete_waits" != true ]]; then
  cat -- "$issue18_create_first_delete_log" >&2
  echo 'The delete did not wait for the create-first board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue18_invitation_create_first'" >/dev/null
  wait "$issue18_create_first_pid" || true
  wait "$issue18_create_first_delete_pid" || true
  exit 1
fi
wait "$issue18_create_first_pid" || { cat -- "$issue18_create_first_log" >&2; exit 1; }
wait "$issue18_create_first_delete_pid" || { cat -- "$issue18_create_first_delete_log" >&2; exit 1; }
if ! grep -Fxq 'created' "$issue18_create_first_log" \
  || ! grep -Fxq 'recoverable' "$issue18_create_first_delete_log"; then
  echo 'Create-first invitation race did not finish in the expected order.' >&2
  cat -- "$issue18_create_first_log" "$issue18_create_first_delete_log" >&2
  exit 1
fi
issue18_create_first_final=$("${psql[@]}" -At -v board_id="$issue18_create_first_board_id" <<'SQL'
SELECT CASE WHEN EXISTS (
  SELECT 1 FROM public.board_recoverable_deletions AS recovery
  WHERE recovery.board_id = :'board_id'::uuid
) AND (
  SELECT count(*) FROM public.board_invitations AS invitation
  WHERE invitation.board_id = :'board_id'::uuid AND invitation.status = 'revoked'
) = 1 AND NOT EXISTS (
  SELECT 1 FROM public.board_invitations AS invitation
  WHERE invitation.board_id = :'board_id'::uuid AND invitation.status = 'pending'
) THEN 'valid' ELSE 'invalid' END;
SQL
)
if [[ "$issue18_create_first_final" != valid ]]; then
  echo 'The delete after a committed create did not revoke its invitation.' >&2
  exit 1
fi
echo 'PASS: an invitation create that wins the board lock commits before delete and is then revoked.'

restore_wins_first_log="$restore_wins_dir/restorer.log"
restore_wins_second_log="$restore_wins_dir/purger.log"
PGAPPNAME=openkanban_issue14_restore_wins_restorer "${psql[@]}" -qAt \
  -v task_id="$restore_wins_task_id" -v board_slug="$restore_wins_board_slug" \
  -v expires_at="$recovery_boundary" \
  > "$restore_wins_first_log" 2>&1 <<'SQL' &
BEGIN;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.restore_task_internal_p(
  '14000000-0000-4000-8000-000000000102', :'board_slug', :'task_id'::uuid,
  NULL, :'expires_at'::timestamptz - interval '1 microsecond'
)->>'status';
SELECT pg_sleep(4);
COMMIT;
SQL
restore_wins_first_pid=$!
restore_wins_first_holds_lock=false
for _ in $(seq 1 100); do
  restore_wins_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue14_restore_wins_restorer' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$restore_wins_state" == active ]]; then
    restore_wins_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$restore_wins_first_holds_lock" != true ]]; then
  cat -- "$restore_wins_first_log" >&2
  echo 'The restorer did not retain the task-deletion lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue14_restore_wins_purger "${psql[@]}" -qAt \
  -v task_id="$restore_wins_task_id" -v expires_at="$recovery_boundary" \
  > "$restore_wins_second_log" 2>&1 <<'SQL' &
BEGIN;
SELECT public.purge_expired_task_internal_p(:'task_id'::uuid, :'expires_at'::timestamptz);
COMMIT;
SQL
restore_wins_second_pid=$!
restore_wins_second_waits=false
for _ in $(seq 1 100); do
  restore_wins_waiters=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue14_restore_wins_purger' AND wait_event_type = 'Lock'")
  if [[ "$restore_wins_waiters" == 1 ]]; then
    restore_wins_second_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$restore_wins_second_waits" != true ]]; then
  cat -- "$restore_wins_second_log" >&2
  echo 'The purger did not wait for the concurrent restore.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_issue14_restore_wins_restorer'" >/dev/null
  wait "$restore_wins_first_pid" || true
  wait "$restore_wins_second_pid" || true
  exit 1
fi
wait "$restore_wins_first_pid" || { cat -- "$restore_wins_first_log" >&2; exit 1; }
wait "$restore_wins_second_pid" || { cat -- "$restore_wins_second_log" >&2; exit 1; }
if ! grep -Fxq 'confirmed' "$restore_wins_first_log" \
  || ! grep -Fxq 'already_terminal' "$restore_wins_second_log"; then
  echo 'Restore-first task recovery race did not produce one terminal result.' >&2
  cat -- "$restore_wins_first_log" "$restore_wins_second_log" >&2
  exit 1
fi
restore_wins_final=$("${psql[@]}" -At -v task_id="$restore_wins_task_id" <<'SQL'
SELECT CASE WHEN deletion.state = 'restored' AND deletion.task_snapshot IS NULL
  AND EXISTS (SELECT 1 FROM public.tasks AS task WHERE task.id = deletion.task_id)
  THEN 'valid' ELSE 'invalid' END
FROM public.task_deletions AS deletion
WHERE deletion.task_id = :'task_id'::uuid;
SQL
)
if [[ "$restore_wins_final" != valid ]]; then
  echo 'Restore-first recovery race purged content or failed to restore the task.' >&2
  exit 1
fi
echo 'PASS: a restore before expiry wins atomically over a waiting purge.'
"${psql[@]}" -q -c 'DROP TABLE public.issue14_task_recovery_race_fixture'

# Two current board members race to assign one task from the same version.
# The board lock serializes the operation and the later command receives a
# version conflict instead of overwriting the winner.
task_assignment_race_dir="$test_dir/task-assignment-race"
mkdir -- "$task_assignment_race_dir"
task_assignment_first_log="$task_assignment_race_dir/member-a.log"
task_assignment_second_log="$task_assignment_race_dir/member-b.log"
task_assignment_slug=$("${psql[@]}" -At -c "SELECT board_slug FROM public.issue13_task_assignment_race_fixture")
task_assignment_task_id=$("${psql[@]}" -At -c "SELECT task_id FROM public.issue13_task_assignment_race_fixture")

PGAPPNAME=openkanban_issue13_assign_a "${psql[@]}" -qAt \
  -v board_slug="$task_assignment_slug" -v task_id="$task_assignment_task_id" \
  > "$task_assignment_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.set_task_assignee_p(
  '13000000-0000-4000-8000-000000000111', :'board_slug', :'task_id'::uuid,
  '40000000-0000-4000-8000-000000000001', 1
)->>'status';
SELECT pg_sleep(4);
COMMIT;
SQL
task_assignment_first_pid=$!

task_assignment_first_holds_lock=false
for _ in $(seq 1 100); do
  task_assignment_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_issue13_assign_a' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$task_assignment_state" == active ]]; then
    task_assignment_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$task_assignment_first_holds_lock" != true ]]; then
  cat -- "$task_assignment_first_log" >&2
  echo 'The first assignment did not retain its transaction lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_issue13_assign_b "${psql[@]}" -qAt \
  -v board_slug="$task_assignment_slug" -v task_id="$task_assignment_task_id" \
  > "$task_assignment_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
SELECT public.set_task_assignee_p(
  '13000000-0000-4000-8000-000000000112', :'board_slug', :'task_id'::uuid,
  '40000000-0000-4000-8000-000000000002', 1
)->>'status';
COMMIT;
SQL
task_assignment_second_pid=$!

task_assignment_second_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue13_assign_b' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    task_assignment_second_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$task_assignment_second_waiting" != true ]]; then
  cat -- "$task_assignment_second_log" >&2
  echo 'The second assignment did not wait on the first transaction.' >&2
  exit 1
fi
wait "$task_assignment_first_pid" || { cat -- "$task_assignment_first_log" >&2; exit 1; }
wait "$task_assignment_second_pid" || { cat -- "$task_assignment_second_log" >&2; exit 1; }
if ! grep -q '^confirmed$' "$task_assignment_first_log" \
  || ! grep -q '^conflict$' "$task_assignment_second_log"; then
  echo 'Concurrent assignment did not produce one confirmation and one conflict.' >&2
  cat -- "$task_assignment_first_log" "$task_assignment_second_log" >&2
  exit 1
fi
task_assignment_final=$("${psql[@]}" -At -c "SELECT CASE WHEN task.assignee_id = '40000000-0000-4000-8000-000000000001' AND task.assignee_version = 2 THEN 'valid' ELSE 'invalid' END FROM public.tasks AS task WHERE task.id = '$task_assignment_task_id'::uuid")
if [[ "$task_assignment_final" != valid ]]; then
  echo 'The concurrent assignment left an unexpected final task state.' >&2
  exit 1
fi
"${psql[@]}" -q -c 'DROP TABLE public.issue13_task_assignment_race_fixture'
echo 'PASS: two current members racing to assign one task produce one winner and one version conflict'

# Two enabled synthetic users race to consume the same transferable link.
# The first transaction holds the board/invitation locks after acceptance;
# the second waits, then must receive the same generic unavailable result.
invitation_race_dir="$test_dir/board-invitation-race"
mkdir -- "$invitation_race_dir"
invitation_race_first_log="$invitation_race_dir/actor-a.log"
invitation_race_second_log="$invitation_race_dir/actor-b.log"
invitation_race_board_id=$(
  "${psql[@]}" -At -c "SELECT board_id FROM public.issue12_invitation_race_fixture"
)
invitation_race_slug=$(
  "${psql[@]}" -At -c "SELECT board_slug FROM public.issue12_invitation_race_fixture"
)
invitation_race_token=$(
  "${psql[@]}" -At -c "SELECT token FROM public.issue12_invitation_race_fixture"
)

PGAPPNAME=openkanban_invitation_actor_a "${psql[@]}" -qAt \
  -v invitation_token="$invitation_race_token" \
  > "$invitation_race_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
SELECT public.accept_board_invitation_link_p(
  :'invitation_token', '11220000-0000-4000-8000-000000000004'
)->>'status';
SELECT pg_sleep(4);
COMMIT;
SQL
invitation_race_first_pid=$!

invitation_race_first_holds_lock=false
for _ in $(seq 1 100); do
  invitation_race_state=$(
    "${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_invitation_actor_a' AND state = 'active' AND query LIKE '%pg_sleep(4)%'"
  )
  if [[ "$invitation_race_state" == active ]]; then
    invitation_race_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$invitation_race_first_holds_lock" != true ]]; then
  cat -- "$invitation_race_first_log" >&2
  echo 'The first invitation acceptance did not hold its transaction.' >&2
  exit 1
fi

PGAPPNAME=openkanban_invitation_actor_b "${psql[@]}" -qAt \
  -v invitation_token="$invitation_race_token" \
  > "$invitation_race_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
SELECT public.accept_board_invitation_link_p(
  :'invitation_token', '11220000-0000-4000-8000-000000000005'
)->>'status';
COMMIT;
SQL
invitation_race_second_pid=$!

invitation_race_second_waits=false
for _ in $(seq 1 100); do
  invitation_race_waiters=$(
    "${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_invitation_actor_b' AND wait_event_type = 'Lock'"
  )
  if [[ "$invitation_race_waiters" == 1 ]]; then
    invitation_race_second_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$invitation_race_second_waits" != true ]]; then
  cat -- "$invitation_race_second_log" >&2
  echo 'The second invitation acceptance did not wait on the serialized board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_invitation_actor_a'" >/dev/null
  wait "$invitation_race_first_pid" || true
  wait "$invitation_race_second_pid" || true
  exit 1
fi

wait "$invitation_race_first_pid" || { cat -- "$invitation_race_first_log" >&2; exit 1; }
wait "$invitation_race_second_pid" || { cat -- "$invitation_race_second_log" >&2; exit 1; }
if ! grep -Fxq 'accepted' "$invitation_race_first_log" \
  || ! grep -Fxq 'unavailable' "$invitation_race_second_log"; then
  echo 'Concurrent invitation acceptance did not return one success and one generic denial.' >&2
  cat -- "$invitation_race_first_log" "$invitation_race_second_log" >&2
  exit 1
fi
invitation_race_memberships=$(
  "${psql[@]}" -At -v board_id="$invitation_race_board_id" \
    <<'SQL'
SELECT count(*)
FROM public.board_memberships
WHERE board_id = :'board_id'::uuid
  AND user_id IN (
    '40000000-0000-4000-8000-000000000001',
    '40000000-0000-4000-8000-000000000005'
  )
  AND role = 'collaborator'
  AND revoked_at IS NULL;
SQL
)
if [[ "$invitation_race_memberships" != 1 ]]; then
  echo "Concurrent invitation acceptance created $invitation_race_memberships memberships; expected one." >&2
  exit 1
fi
"${psql[@]}" -q \
  -v board_id="$invitation_race_board_id" \
  -v board_slug="$invitation_race_slug" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.delete_board_p(
  'e1240000-0000-4000-8000-000000000021'::uuid,
  :'board_slug',
  :'board_id'::uuid
);
COMMIT;
DROP TABLE public.issue12_invitation_race_fixture;
SQL
echo 'PASS: two enabled recipients race for one generic link; one membership is created and the loser sees no invitation content.'

"${psql[@]}" -f "$repo_dir/tests/db/task_capture.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/task_field_versions.sql"

# Two authenticated editors start from the same field version. A genuine
# board-row lock releases both requests into the versioned edit command; one
# must confirm and the other must return a conflict containing both texts.
task_field_race_dir="$test_dir/task-field-same-field-race"
mkdir -- "$task_field_race_dir"
task_field_race_holder_log="$task_field_race_dir/lock-holder.log"
task_field_race_first_log="$task_field_race_dir/actor-a.log"
task_field_race_second_log="$task_field_race_dir/actor-b.log"
task_field_race_board_id=$("${psql[@]}" -At -c "SELECT board_id FROM public.issue8_task_field_fixture WHERE purpose = 'same-field'")
task_field_race_slug=$("${psql[@]}" -At -c "SELECT board_slug FROM public.issue8_task_field_fixture WHERE purpose = 'same-field'")
task_field_race_task_id=$("${psql[@]}" -At -c "SELECT task_id FROM public.issue8_task_field_fixture WHERE purpose = 'same-field'")

PGAPPNAME=openkanban_task_field_lock_holder "${psql[@]}" > "$task_field_race_holder_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM public.boards WHERE id = '$task_field_race_board_id' FOR UPDATE;
SELECT pg_sleep(3);
COMMIT;
SQL
task_field_race_holder_pid=$!
task_field_race_holder_active=false
for _ in $(seq 1 100); do
  lock_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_task_field_lock_holder' AND state = 'active' AND query LIKE '%pg_sleep(3)%'")
  if [[ "$lock_state" == active ]]; then
    task_field_race_holder_active=true
    break
  fi
  sleep 0.05
done
if [[ "$task_field_race_holder_active" != true ]]; then
  cat -- "$task_field_race_holder_log" >&2
  echo 'Task-field race lock holder did not start.' >&2
  exit 1
fi

PGAPPNAME=openkanban_task_field_actor_a "${psql[@]}" -qAtF '|' \
  -v board_slug="$task_field_race_slug" -v task_id="$task_field_race_task_id" \
  > "$task_field_race_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true) \gset
WITH response AS (
  SELECT public.edit_task_fields_p(
    'e8888888-0000-4000-8000-000000000001',
    :'board_slug',
    :'task_id'::uuid,
    '{"title":"Título de Ana"}'::jsonb,
    '{"title":1}'::jsonb
  ) AS result
)
SELECT result->>'status' || '|' || coalesce(result->'task'->>'title', '') || '|' || coalesce(result->'conflicts'->'title'->>'draft', '')
FROM response;
COMMIT;
SQL
task_field_race_first_pid=$!

PGAPPNAME=openkanban_task_field_actor_b "${psql[@]}" -qAtF '|' \
  -v board_slug="$task_field_race_slug" -v task_id="$task_field_race_task_id" \
  > "$task_field_race_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true) \gset
WITH response AS (
  SELECT public.edit_task_fields_p(
    'e8888888-0000-4000-8000-000000000002',
    :'board_slug',
    :'task_id'::uuid,
    '{"title":"Título de Bruno"}'::jsonb,
    '{"title":1}'::jsonb
  ) AS result
)
SELECT result->>'status' || '|' || coalesce(result->'task'->>'title', '') || '|' || coalesce(result->'conflicts'->'title'->>'draft', '')
FROM response;
COMMIT;
SQL
task_field_race_second_pid=$!

task_field_race_both_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('openkanban_task_field_actor_a', 'openkanban_task_field_actor_b') AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 2 ]]; then
    task_field_race_both_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$task_field_race_both_waiting" != true ]]; then
  cat -- "$task_field_race_first_log" "$task_field_race_second_log" >&2
  echo 'Both task-field editor sessions did not wait on the board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_task_field_lock_holder'" >/dev/null
  wait "$task_field_race_holder_pid" || true
  wait "$task_field_race_first_pid" || true
  wait "$task_field_race_second_pid" || true
  exit 1
fi

wait "$task_field_race_holder_pid" || { cat -- "$task_field_race_holder_log" >&2; exit 1; }
wait "$task_field_race_first_pid" || { cat -- "$task_field_race_first_log" >&2; exit 1; }
wait "$task_field_race_second_pid" || { cat -- "$task_field_race_second_log" >&2; exit 1; }
task_field_first_result=$(grep -E '^(confirmed|conflict)\|' "$task_field_race_first_log" | tail -n 1)
task_field_second_result=$(grep -E '^(confirmed|conflict)\|' "$task_field_race_second_log" | tail -n 1)
if [[ -z "$task_field_first_result" || -z "$task_field_second_result" ]]; then
  echo 'Concurrent task-field edits did not return typed results.' >&2
  cat -- "$task_field_race_first_log" "$task_field_race_second_log" >&2
  exit 1
fi
task_field_first_status=${task_field_first_result%%|*}
task_field_second_status=${task_field_second_result%%|*}
if [[ "$task_field_first_status" == "$task_field_second_status" ]]; then
  echo 'Same-field concurrent edits must produce one confirmation and one reviewable conflict.' >&2
  cat -- "$task_field_race_first_log" "$task_field_race_second_log" >&2
  exit 1
fi
if [[ "$task_field_first_status" == conflict ]]; then
  task_field_conflict_result="$task_field_first_result"
  task_field_winner_title='Título de Bruno'
  task_field_draft_title='Título de Ana'
else
  task_field_conflict_result="$task_field_second_result"
  task_field_winner_title='Título de Ana'
  task_field_draft_title='Título de Bruno'
fi
if [[ "$task_field_conflict_result" != "conflict|$task_field_winner_title|$task_field_draft_title" ]]; then
  echo 'Conflict response did not preserve the winning server title and the other editor draft.' >&2
  cat -- "$task_field_race_first_log" "$task_field_race_second_log" >&2
  exit 1
fi
task_field_same_title=$("${psql[@]}" -At -c "SELECT title FROM public.tasks WHERE id = '$task_field_race_task_id'")
if [[ "$task_field_same_title" != 'Título de Ana' && "$task_field_same_title" != 'Título de Bruno' ]]; then
  echo 'Same-field conflict changed the persisted title unexpectedly.' >&2
  exit 1
fi
echo 'PASS: two authenticated editors race on one field; the loser sees both versions without overwriting'

# Different fields retain independent versions. The second editor starts from
# the same task snapshot but can still save description after the title edit.
task_field_merge_dir="$test_dir/task-field-different-fields-race"
mkdir -- "$task_field_merge_dir"
task_field_merge_holder_log="$task_field_merge_dir/lock-holder.log"
task_field_merge_first_log="$task_field_merge_dir/actor-a.log"
task_field_merge_second_log="$task_field_merge_dir/actor-b.log"
task_field_merge_board_id=$("${psql[@]}" -At -c "SELECT board_id FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields'")
task_field_merge_slug=$("${psql[@]}" -At -c "SELECT board_slug FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields'")
task_field_merge_task_id=$("${psql[@]}" -At -c "SELECT task_id FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields'")

PGAPPNAME=openkanban_task_field_merge_lock_holder "${psql[@]}" > "$task_field_merge_holder_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM public.boards WHERE id = '$task_field_merge_board_id' FOR UPDATE;
SELECT pg_sleep(3);
COMMIT;
SQL
task_field_merge_holder_pid=$!
task_field_merge_holder_active=false
for _ in $(seq 1 100); do
  lock_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_task_field_merge_lock_holder' AND state = 'active' AND query LIKE '%pg_sleep(3)%'")
  if [[ "$lock_state" == active ]]; then
    task_field_merge_holder_active=true
    break
  fi
  sleep 0.05
done
if [[ "$task_field_merge_holder_active" != true ]]; then
  cat -- "$task_field_merge_holder_log" >&2
  echo 'Different-field race lock holder did not start.' >&2
  exit 1
fi

PGAPPNAME=openkanban_task_field_merge_actor_a "${psql[@]}" -qAtF '|' \
  -v board_slug="$task_field_merge_slug" -v task_id="$task_field_merge_task_id" \
  > "$task_field_merge_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true) \gset
WITH response AS (
  SELECT public.edit_task_fields_p(
    'e8888888-0000-4000-8000-000000000003',
    :'board_slug',
    :'task_id'::uuid,
    '{"title":"Título independiente"}'::jsonb,
    '{"title":1}'::jsonb
  ) AS result
)
SELECT result->>'status'
FROM response;
COMMIT;
SQL
task_field_merge_first_pid=$!

PGAPPNAME=openkanban_task_field_merge_actor_b "${psql[@]}" -qAtF '|' \
  -v board_slug="$task_field_merge_slug" -v task_id="$task_field_merge_task_id" \
  > "$task_field_merge_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true) \gset
WITH response AS (
  SELECT public.edit_task_fields_p(
    'e8888888-0000-4000-8000-000000000004',
    :'board_slug',
    :'task_id'::uuid,
    '{"description":"Descripción independiente"}'::jsonb,
    '{"description":1}'::jsonb
  ) AS result
)
SELECT result->>'status'
FROM response;
COMMIT;
SQL
task_field_merge_second_pid=$!

task_field_merge_both_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('openkanban_task_field_merge_actor_a', 'openkanban_task_field_merge_actor_b') AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 2 ]]; then
    task_field_merge_both_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$task_field_merge_both_waiting" != true ]]; then
  cat -- "$task_field_merge_first_log" "$task_field_merge_second_log" >&2
  echo 'Both different-field editor sessions did not wait on the board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_task_field_merge_lock_holder'" >/dev/null
  wait "$task_field_merge_holder_pid" || true
  wait "$task_field_merge_first_pid" || true
  wait "$task_field_merge_second_pid" || true
  exit 1
fi
wait "$task_field_merge_holder_pid" || { cat -- "$task_field_merge_holder_log" >&2; exit 1; }
wait "$task_field_merge_first_pid" || { cat -- "$task_field_merge_first_log" >&2; exit 1; }
wait "$task_field_merge_second_pid" || { cat -- "$task_field_merge_second_log" >&2; exit 1; }
task_field_merge_first_result=$(grep -E '^confirmed$' "$task_field_merge_first_log" | tail -n 1)
task_field_merge_second_result=$(grep -E '^confirmed$' "$task_field_merge_second_log" | tail -n 1)
if [[ "$task_field_merge_first_result" != 'confirmed' \
  || "$task_field_merge_second_result" != 'confirmed' ]]; then
  echo 'Different-field concurrent edits did not both confirm against independent versions.' >&2
  cat -- "$task_field_merge_first_log" "$task_field_merge_second_log" >&2
  exit 1
fi
task_field_merged_values=$("${psql[@]}" -AtF '|' -c "SELECT title, description, field_versions->>'title', field_versions->>'description', field_versions->>'priority' FROM public.tasks WHERE id = '$task_field_merge_task_id'")
if [[ "$task_field_merged_values" != 'Título independiente|Descripción independiente|2|2|1' ]]; then
  echo 'Independent-field writes did not merge or increment only their own versions.' >&2
  echo "$task_field_merged_values" >&2
  exit 1
fi
echo 'PASS: two authenticated editors concurrently save different fields using independent versions'

"${psql[@]}" -q -f "$repo_dir/tests/db/task_completion.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/task_checklist.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/task_due_date_and_zone.sql"

# A real opposing completion/reopen race must keep the first confirmed state
# and return a reviewable conflict to the client that used the stale version.
task_completion_race_dir="$test_dir/task-completion-race"
mkdir -- "$task_completion_race_dir"
task_completion_race_first_log="$task_completion_race_dir/actor-a.log"
task_completion_race_second_log="$task_completion_race_dir/actor-b.log"
task_completion_race_board_id=$("${psql[@]}" -At -c "SELECT board_id FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields'")
task_completion_race_slug=$("${psql[@]}" -At -c "SELECT board_slug FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields'")
task_completion_race_task_id=$("${psql[@]}" -At -c "SELECT task_id FROM public.issue8_task_field_fixture WHERE purpose = 'different-fields'")

PGAPPNAME=openkanban_task_completion_actor_a "${psql[@]}" -qAt \
  -v board_slug="$task_completion_race_slug" -v task_id="$task_completion_race_task_id" \
  > "$task_completion_race_first_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT public.set_task_completion_p(
  'b8888888-0000-4000-8000-000000000001',
  :'board_slug', :'task_id'::uuid, true, 1
)->>'status';
SELECT pg_sleep(4);
COMMIT;
SQL
task_completion_race_first_pid=$!

task_completion_race_first_holds_lock=false
for _ in $(seq 1 100); do
  completion_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_task_completion_actor_a' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$completion_state" == active ]]; then
    task_completion_race_first_holds_lock=true
    break
  fi
  sleep 0.05
done
if [[ "$task_completion_race_first_holds_lock" != true ]]; then
  cat -- "$task_completion_race_first_log" >&2
  echo 'The first completion client did not hold the task board lock.' >&2
  exit 1
fi

PGAPPNAME=openkanban_task_completion_actor_b "${psql[@]}" -qAt \
  -v board_slug="$task_completion_race_slug" -v task_id="$task_completion_race_task_id" \
  > "$task_completion_race_second_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000005', true);
SELECT public.set_task_completion_p(
  'b8888888-0000-4000-8000-000000000002',
  :'board_slug', :'task_id'::uuid, false, 1
)->>'status';
COMMIT;
SQL
task_completion_race_second_pid=$!

task_completion_race_second_waits=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_task_completion_actor_b' AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 1 ]]; then
    task_completion_race_second_waits=true
    break
  fi
  sleep 0.05
done
if [[ "$task_completion_race_second_waits" != true ]]; then
  cat -- "$task_completion_race_first_log" "$task_completion_race_second_log" >&2
  echo 'The opposing completion client did not wait for the in-flight task mutation.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_task_completion_actor_a'" >/dev/null
  wait "$task_completion_race_first_pid" || true
  wait "$task_completion_race_second_pid" || true
  exit 1
fi

wait "$task_completion_race_first_pid" || { cat -- "$task_completion_race_first_log" >&2; exit 1; }
wait "$task_completion_race_second_pid" || { cat -- "$task_completion_race_second_log" >&2; exit 1; }
task_completion_first_status=$(grep -E '^(confirmed|conflict)$' "$task_completion_race_first_log" | tail -n 1)
task_completion_second_status=$(grep -E '^(confirmed|conflict)$' "$task_completion_race_second_log" | tail -n 1)
task_completion_race_state=$("${psql[@]}" -AtF '|' -c "SELECT is_completed, completion_version FROM public.tasks WHERE id = '$task_completion_race_task_id'")
if [[ "$task_completion_first_status" != 'confirmed' \
  || "$task_completion_second_status" != 'conflict' \
  || "$task_completion_race_state" != 't|2' ]]; then
  echo 'Opposing concurrent completion commands did not preserve one confirmed completion and one conflict.' >&2
  cat -- "$task_completion_race_first_log" "$task_completion_race_second_log" >&2
  echo "$task_completion_race_state" >&2
  exit 1
fi
echo 'PASS: two authenticated clients race to complete/reopen; the stale opposite action receives conflict'

"${psql[@]}" -q -f "$repo_dir/tests/db/task_field_versions_assertions.sql"
"${psql[@]}" -q -f "$repo_dir/tests/db/task_ordering.sql"

# Two authenticated actors submit the same multi-column batch against one
# order-version snapshot. Exactly one may commit; the stale request must return
# a reviewable conflict without partially applying either move.
task_order_race_dir="$test_dir/task-order-same-version-race"
mkdir -- "$task_order_race_dir"
task_order_race_holder_log="$task_order_race_dir/lock-holder.log"
task_order_race_first_log="$task_order_race_dir/actor-a.log"
task_order_race_second_log="$task_order_race_dir/actor-b.log"
task_order_race_board_id=$("${psql[@]}" -At -c "SELECT board_id FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_slug=$("${psql[@]}" -At -c "SELECT board_slug FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_source_id=$("${psql[@]}" -At -c "SELECT source_column_id FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_target_id=$("${psql[@]}" -At -c "SELECT target_column_id FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_second_source_id=$("${psql[@]}" -At -c "SELECT second_source_column_id FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_second_target_id=$("${psql[@]}" -At -c "SELECT second_target_column_id FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_task_b=$("${psql[@]}" -At -c "SELECT task_b FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_task_d=$("${psql[@]}" -At -c "SELECT task_d FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_target_before=$("${psql[@]}" -At -c "SELECT target_before_id FROM public.issue9_order_fixture WHERE purpose = 'main'")
task_order_race_source_version=$("${psql[@]}" -At -c "SELECT task_order_version FROM public.columns WHERE id = '$task_order_race_source_id'")
task_order_race_target_version=$("${psql[@]}" -At -c "SELECT task_order_version FROM public.columns WHERE id = '$task_order_race_target_id'")
task_order_race_second_source_version=$("${psql[@]}" -At -c "SELECT task_order_version FROM public.columns WHERE id = '$task_order_race_second_source_id'")
task_order_race_second_target_version=$("${psql[@]}" -At -c "SELECT task_order_version FROM public.columns WHERE id = '$task_order_race_second_target_id'")
PGAPPNAME=openkanban_task_order_lock_holder "${psql[@]}" > "$task_order_race_holder_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM public.boards WHERE id = '$task_order_race_board_id' FOR UPDATE;
SELECT pg_sleep(3);
COMMIT;
SQL
task_order_race_holder_pid=$!
task_order_race_holder_active=false
for _ in $(seq 1 100); do
  holder_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_task_order_lock_holder' AND state = 'active' AND query LIKE '%pg_sleep(3)%'")
  if [[ "$holder_state" == active ]]; then
    task_order_race_holder_active=true
    break
  fi
  sleep 0.05
done
if [[ "$task_order_race_holder_active" != true ]]; then
  cat -- "$task_order_race_holder_log" >&2
  echo 'Task-order race lock holder did not start.' >&2
  exit 1
fi

for actor in a b; do
  if [[ "$actor" == a ]]; then
    actor_id='40000000-0000-4000-8000-000000000002'
    operation_id='f9999999-0000-4000-8000-000000000201'
    target_log="$task_order_race_first_log"
  else
    actor_id='40000000-0000-4000-8000-000000000005'
    operation_id='f9999999-0000-4000-8000-000000000202'
    target_log="$task_order_race_second_log"
  fi
  PGAPPNAME="openkanban_task_order_actor_$actor" "${psql[@]}" -qAt \
    -v actor_id="$actor_id" -v operation_id="$operation_id" \
    -v board_slug="$task_order_race_slug" \
    -v task_b="$task_order_race_task_b" -v task_d="$task_order_race_task_d" \
    -v target_id="$task_order_race_target_id" \
    -v second_source_id="$task_order_race_second_source_id" \
    -v target_before="$task_order_race_target_before" \
    -v source_id="$task_order_race_source_id" \
    -v second_target_id="$task_order_race_second_target_id" \
    -v source_version="$task_order_race_source_version" \
    -v target_version="$task_order_race_target_version" \
    -v second_source_version="$task_order_race_second_source_version" \
    -v second_target_version="$task_order_race_second_target_version" \
    > "$target_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', :'actor_id', true) \gset
WITH response AS (
  SELECT public.update_task_positions_p(
    :'operation_id'::uuid,
    :'board_slug',
    jsonb_build_array(
      jsonb_build_object(
        'id', :'task_b'::uuid,
        'source_column_id', :'source_id'::uuid,
        'column_id', :'target_id'::uuid,
        'before_task_id', NULL,
        'after_task_id', :'target_before'::uuid
      ),
      jsonb_build_object(
        'id', :'task_d'::uuid,
        'source_column_id', :'second_target_id'::uuid,
        'column_id', :'second_source_id'::uuid,
        'before_task_id', NULL,
        'after_task_id', NULL
      )
    ),
    jsonb_build_object(
      :'source_id', :'source_version'::bigint,
      :'target_id', :'target_version'::bigint,
      :'second_source_id', :'second_source_version'::bigint,
      :'second_target_id', :'second_target_version'::bigint
    )
  ) AS result
)
SELECT result->>'status' FROM response;
COMMIT;
SQL
  if [[ "$actor" == a ]]; then
    task_order_race_first_pid=$!
  else
    task_order_race_second_pid=$!
  fi
done

task_order_race_both_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('openkanban_task_order_actor_a', 'openkanban_task_order_actor_b') AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 2 ]]; then
    task_order_race_both_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$task_order_race_both_waiting" != true ]]; then
  cat -- "$task_order_race_first_log" "$task_order_race_second_log" >&2
  echo 'Both task-order requests did not wait on the board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_task_order_lock_holder'" >/dev/null
  wait "$task_order_race_holder_pid" || true
  wait "$task_order_race_first_pid" || true
  wait "$task_order_race_second_pid" || true
  exit 1
fi
wait "$task_order_race_holder_pid" || { cat -- "$task_order_race_holder_log" >&2; exit 1; }
wait "$task_order_race_first_pid" || { cat -- "$task_order_race_first_log" >&2; exit 1; }
wait "$task_order_race_second_pid" || { cat -- "$task_order_race_second_log" >&2; exit 1; }
task_order_first_status=$(grep -E '^(confirmed|conflict)$' "$task_order_race_first_log" | tail -n 1)
task_order_second_status=$(grep -E '^(confirmed|conflict)$' "$task_order_race_second_log" | tail -n 1)
if [[ ! ( "$task_order_first_status" == confirmed && "$task_order_second_status" == conflict ) \
  && ! ( "$task_order_first_status" == conflict && "$task_order_second_status" == confirmed ) ]]; then
  echo 'Concurrent same-version task ordering must produce one confirmation and one reviewable conflict.' >&2
  cat -- "$task_order_race_first_log" "$task_order_race_second_log" >&2
  exit 1
fi
task_order_race_state=$("${psql[@]}" -AtF '|' -c "SELECT (SELECT count(*) FROM public.tasks WHERE id = '$task_order_race_task_b' AND column_id = '$task_order_race_target_id'), (SELECT count(*) FROM public.tasks WHERE id = '$task_order_race_task_d' AND column_id = '$task_order_race_second_source_id'), (SELECT count(*) FROM public.tasks WHERE id = '$task_order_race_task_b' AND column_id = '$task_order_race_source_id'), (SELECT count(*) FROM public.tasks WHERE id = '$task_order_race_task_d' AND column_id = '$task_order_race_second_target_id')")
if [[ "$task_order_race_state" != '1|1|0|0' ]]; then
  echo "Concurrent task-order batch was partially applied: $task_order_race_state" >&2
  cat -- "$task_order_race_first_log" "$task_order_race_second_log" >&2
  exit 1
fi
echo 'PASS: concurrent same-version ordering yields one atomic batch and one reviewable conflict'

# A reconciliation locks the actor's active membership before looking up its
# receipt. If revocation wins the membership row first, the resolver must wait
# and then deny the request rather than returning a previously captured task.
task_capture_revoke_dir="$test_dir/task-capture-revocation-race"
mkdir -- "$task_capture_revoke_dir"
task_capture_revoke_holder_log="$task_capture_revoke_dir/revoker.log"
task_capture_revoke_resolver_log="$task_capture_revoke_dir/resolver.log"
"${psql[@]}" -q <<'SQL'
CREATE TABLE public.issue7_task_capture_revoke_fixture (
  board_id uuid NOT NULL,
  column_id uuid NOT NULL,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT ON public.issue7_task_capture_revoke_fixture TO authenticated;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  board record;
  column_id uuid;
BEGIN
  SELECT * INTO board FROM public.create_board_p(
    'Issue 7 revocation race',
    'UTC',
    'f7777777-0000-4000-8000-000000000011'
  );
  SELECT id INTO column_id
  FROM public.create_column_p(board.slug, board.id, 'Concurrent revoke', 0);
  INSERT INTO public.issue7_task_capture_revoke_fixture(board_id, column_id, operation_id)
  VALUES (board.id, column_id, 'a7777777-0000-4000-8000-000000000011');
END;
$$;
COMMIT;
INSERT INTO public.board_memberships(board_id, user_id, role)
SELECT board_id, '40000000-0000-4000-8000-000000000001', 'collaborator'
FROM public.issue7_task_capture_revoke_fixture;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  fixture record;
BEGIN
  SELECT * INTO STRICT fixture FROM public.issue7_task_capture_revoke_fixture;
  PERFORM public.create_task_p(
    fixture.operation_id,
    fixture.board_id,
    fixture.column_id,
    'Committed before concurrent revocation'
  );
END;
$$;
COMMIT;
SQL
task_capture_revoke_board_id=$("${psql[@]}" -At -c "SELECT board_id FROM public.issue7_task_capture_revoke_fixture")
task_capture_revoke_column_id=$("${psql[@]}" -At -c "SELECT column_id FROM public.issue7_task_capture_revoke_fixture")
task_capture_revoke_operation_id=$("${psql[@]}" -At -c "SELECT operation_id FROM public.issue7_task_capture_revoke_fixture")

PGAPPNAME=openkanban_task_capture_revoker "${psql[@]}" > "$task_capture_revoke_holder_log" 2>&1 <<SQL &
BEGIN;
UPDATE public.board_memberships
SET revoked_at = clock_timestamp()
WHERE board_id = '$task_capture_revoke_board_id'
  AND user_id = '40000000-0000-4000-8000-000000000001'
  AND revoked_at IS NULL;
SELECT pg_sleep(3);
COMMIT;
SQL
task_capture_revoke_holder_pid=$!
task_capture_revoke_holder_active=false
for _ in $(seq 1 100); do
  revoke_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_task_capture_revoker' AND state = 'active' AND query LIKE '%pg_sleep(3)%'")
  if [[ "$revoke_state" == active ]]; then
    task_capture_revoke_holder_active=true
    break
  fi
  sleep 0.05
done
if [[ "$task_capture_revoke_holder_active" != true ]]; then
  cat -- "$task_capture_revoke_holder_log" >&2
  echo 'Task capture membership revocation lock holder did not start.' >&2
  exit 1
fi

PGAPPNAME=openkanban_task_capture_resolver "${psql[@]}" -v board_id="$task_capture_revoke_board_id" \
  -v column_id="$task_capture_revoke_column_id" -v operation_id="$task_capture_revoke_operation_id" \
  > "$task_capture_revoke_resolver_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000001', true);
SELECT set_config('test.capture_board_id', :'board_id', true);
SELECT set_config('test.capture_column_id', :'column_id', true);
SELECT set_config('test.capture_operation_id', :'operation_id', true);
DO $$
DECLARE
  v_denial_code text;
  v_denial_message text;
BEGIN
  BEGIN
    PERFORM public.get_task_creation_result_p(
      current_setting('test.capture_operation_id')::uuid,
      current_setting('test.capture_board_id')::uuid,
      current_setting('test.capture_column_id')::uuid,
      'Committed before concurrent revocation',
      NULL,
      'medium'
    );
    RAISE EXCEPTION 'Reconciliation returned a task after membership revocation won the race';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS
      v_denial_code = RETURNED_SQLSTATE,
      v_denial_message = MESSAGE_TEXT;
  END;
  IF v_denial_code IS DISTINCT FROM '42501'
    OR v_denial_message IS DISTINCT FROM 'Board access is required' THEN
    RAISE EXCEPTION 'Concurrent revoke did not produce the generic denial: %/%',
      v_denial_code, v_denial_message;
  END IF;
END;
$$;
COMMIT;
SQL
task_capture_revoke_resolver_pid=$!
task_capture_revoke_resolver_waiting=false
for _ in $(seq 1 100); do
  revoke_waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_task_capture_resolver' AND wait_event_type = 'Lock'")
  if [[ "$revoke_waiting_count" == 1 ]]; then
    task_capture_revoke_resolver_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$task_capture_revoke_resolver_waiting" != true ]]; then
  cat -- "$task_capture_revoke_resolver_log" >&2
  echo 'Task capture resolver did not wait for the membership revocation lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_task_capture_revoker'" >/dev/null
  wait "$task_capture_revoke_holder_pid" || true
  wait "$task_capture_revoke_resolver_pid" || true
  exit 1
fi
wait "$task_capture_revoke_holder_pid" || { cat -- "$task_capture_revoke_holder_log" >&2; exit 1; }
wait "$task_capture_revoke_resolver_pid" || { cat -- "$task_capture_revoke_resolver_log" >&2; exit 1; }
"${psql[@]}" -q -c 'DROP TABLE public.issue7_task_capture_revoke_fixture'
echo 'PASS: reconciliation waits for concurrent membership revocation and then denies access'

# Hold the destination board row so two authenticated sessions submit the same
# explicit task-capture intent concurrently and must both resolve one receipt.
task_capture_race_dir="$test_dir/task-capture-race"
mkdir -- "$task_capture_race_dir"
task_capture_race_fixture="$task_capture_race_dir/fixture.log"
task_capture_race_lock_log="$task_capture_race_dir/lock-holder.log"
task_capture_race_first_log="$task_capture_race_dir/first.log"
task_capture_race_second_log="$task_capture_race_dir/second.log"
"${psql[@]}" -q <<'SQL'
CREATE TABLE public.issue7_task_capture_race_fixture (
  board_id uuid NOT NULL,
  column_id uuid NOT NULL,
  operation_id uuid NOT NULL
);
GRANT SELECT, INSERT ON public.issue7_task_capture_race_fixture TO authenticated;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  board record;
  column_id uuid;
BEGIN
  SELECT * INTO board FROM public.create_board_p(
    'Issue 7 concurrent capture',
    'UTC',
    'f7777777-0000-4000-8000-000000000010'
  );
  SELECT id INTO column_id
  FROM public.create_column_p(board.slug, board.id, 'Concurrent', 0);
  INSERT INTO public.issue7_task_capture_race_fixture(board_id, column_id, operation_id)
  VALUES (board.id, column_id, 'a7777777-0000-4000-8000-000000000010');
END;
$$;
COMMIT;
SQL
task_capture_race_board_id=$("${psql[@]}" -At -c "SELECT board_id FROM public.issue7_task_capture_race_fixture")
task_capture_race_column_id=$("${psql[@]}" -At -c "SELECT column_id FROM public.issue7_task_capture_race_fixture")
task_capture_race_operation_id=$("${psql[@]}" -At -c "SELECT operation_id FROM public.issue7_task_capture_race_fixture")

PGAPPNAME=openkanban_task_capture_lock_holder "${psql[@]}" > "$task_capture_race_lock_log" 2>&1 <<SQL &
BEGIN;
SELECT id FROM public.boards WHERE id = '$task_capture_race_board_id' FOR UPDATE;
SELECT pg_sleep(3);
COMMIT;
SQL
task_capture_race_lock_pid=$!
task_capture_race_lock_active=false
for _ in $(seq 1 100); do
  lock_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_task_capture_lock_holder' AND state = 'active' AND query LIKE '%pg_sleep(3)%'")
  if [[ "$lock_state" == active ]]; then
    task_capture_race_lock_active=true
    break
  fi
  sleep 0.05
done
if [[ "$task_capture_race_lock_active" != true ]]; then
  cat -- "$task_capture_race_lock_log" >&2
  echo 'Task capture race lock holder did not start.' >&2
  exit 1
fi

for attempt in first second; do
  if [[ "$attempt" == first ]]; then
    target_log="$task_capture_race_first_log"
  else
    target_log="$task_capture_race_second_log"
  fi
  PGAPPNAME="openkanban_task_capture_$attempt" "${psql[@]}" -At \
    -v board_id="$task_capture_race_board_id" \
    -v column_id="$task_capture_race_column_id" \
    -v operation_id="$task_capture_race_operation_id" > "$target_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true) \gset
SELECT public.create_task_p(
  :'operation_id'::uuid,
  :'board_id'::uuid,
  :'column_id'::uuid,
  'Una intención concurrente'
)->'task'->>'id';
COMMIT;
SQL
  if [[ "$attempt" == first ]]; then
    task_capture_race_first_pid=$!
  else
    task_capture_race_second_pid=$!
  fi
done

task_capture_race_both_waiting=false
for _ in $(seq 1 100); do
  waiting_count=$("${psql[@]}" -At -c "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('openkanban_task_capture_first', 'openkanban_task_capture_second') AND wait_event_type = 'Lock'")
  if [[ "$waiting_count" == 2 ]]; then
    task_capture_race_both_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$task_capture_race_both_waiting" != true ]]; then
  cat -- "$task_capture_race_first_log" "$task_capture_race_second_log" >&2
  echo 'Both task capture sessions did not wait on the board lock.' >&2
  "${psql[@]}" -q -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'openkanban_task_capture_lock_holder'" >/dev/null
  wait "$task_capture_race_lock_pid" || true
  wait "$task_capture_race_first_pid" || true
  wait "$task_capture_race_second_pid" || true
  exit 1
fi

wait "$task_capture_race_lock_pid" || { cat -- "$task_capture_race_lock_log" >&2; exit 1; }
wait "$task_capture_race_first_pid" || { cat -- "$task_capture_race_first_log" >&2; exit 1; }
wait "$task_capture_race_second_pid" || { cat -- "$task_capture_race_second_log" >&2; exit 1; }
task_capture_uuid_pattern='[[:xdigit:]]{8}-([[:xdigit:]]{4}-){3}[[:xdigit:]]{12}'
task_capture_first_id=$(grep -Eo "$task_capture_uuid_pattern" "$task_capture_race_first_log" | tail -n 1)
task_capture_second_id=$(grep -Eo "$task_capture_uuid_pattern" "$task_capture_race_second_log" | tail -n 1)
task_capture_receipt_count=$("${psql[@]}" -At \
  -c "SELECT count(*) FROM public.task_capture_receipts WHERE actor_id = '40000000-0000-4000-8000-000000000002' AND operation_id = '$task_capture_race_operation_id'::uuid")
task_capture_task_count=$("${psql[@]}" -At \
  -c "SELECT count(*) FROM public.tasks WHERE id = (SELECT task_id FROM public.task_capture_receipts WHERE actor_id = '40000000-0000-4000-8000-000000000002' AND operation_id = '$task_capture_race_operation_id'::uuid)")
if [[ -z "$task_capture_first_id" || "$task_capture_first_id" != "$task_capture_second_id" \
  || "$task_capture_receipt_count" != 1 || "$task_capture_task_count" != 1 ]]; then
  echo 'Concurrent capture sessions did not resolve to the one committed task.' >&2
  cat -- "$task_capture_race_first_log" "$task_capture_race_second_log" >&2
  exit 1
fi
"${psql[@]}" -q -c 'DROP TABLE public.issue7_task_capture_race_fixture'
echo 'PASS: two authenticated concurrent task captures with one operation id produce one task'

# Keep two authenticated database sessions open at once: the owner can read the
# board while an unrelated global admin is denied its content and listing.
private_board_slug=$("${psql[@]}" -At -c "SELECT slug FROM public.boards WHERE name = 'Trabajo renombrado' AND owner_id = '40000000-0000-4000-8000-000000000002' ORDER BY created_at DESC LIMIT 1")
if [[ -z "$private_board_slug" ]]; then
  echo 'Private board isolation fixture did not create the expected owner board.' >&2
  exit 1
fi
private_board_dir="$test_dir/private-board-sessions"
mkdir -- "$private_board_dir"
owner_session_log="$private_board_dir/owner.log"
outsider_session_log="$private_board_dir/outsider.log"
PGAPPNAME=openkanban_board_owner_session "${psql[@]}" -v board_slug="$private_board_slug" > "$owner_session_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT set_config('test.board_slug', :'board_slug', true);
DO $$
BEGIN
  IF public.get_full_board_p(current_setting('test.board_slug')) IS NULL THEN
    RAISE EXCEPTION 'Owner session did not read its private board';
  END IF;
END;
$$;
SELECT pg_sleep(4);
COMMIT;
SQL
owner_session_pid=$!
owner_session_active=false
for _ in $(seq 1 100); do
  owner_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_board_owner_session' AND state = 'active' AND query LIKE '%pg_sleep(4)%'")
  if [[ "$owner_state" == active ]]; then
    owner_session_active=true
    break
  fi
  sleep 0.05
done
if [[ "$owner_session_active" != true ]]; then
  cat -- "$owner_session_log" >&2
  echo 'Owner session did not hold the fixture connection open.' >&2
  exit 1
fi
PGAPPNAME=openkanban_board_unrelated_admin "${psql[@]}" -v board_slug="$private_board_slug" > "$outsider_session_log" 2>&1 <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000006', true);
SELECT set_config('test.board_slug', :'board_slug', true);
DO $$
DECLARE
  v_count integer;
BEGIN
  IF public.get_full_board_p(current_setting('test.board_slug')) IS NOT NULL THEN
    RAISE EXCEPTION 'An unrelated administrator read the owner board';
  END IF;
  SELECT count(*) INTO v_count FROM public.list_my_boards()
  WHERE slug = current_setting('test.board_slug');
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'An unrelated administrator listed the owner board';
  END IF;
END;
$$;
COMMIT;
\echo 'PASS: two concurrent authenticated sessions preserve board isolation'
SQL
wait "$owner_session_pid" || { cat -- "$owner_session_log" >&2; exit 1; }

# Race the same create intent from two authenticated sessions while both wait
# behind a table lock. The unique owner/request key must return one board twice.
board_create_race_dir="$test_dir/private-board-create-race"
mkdir -- "$board_create_race_dir"
board_create_lock_log="$board_create_race_dir/lock-holder.log"
board_create_first_log="$board_create_race_dir/first.log"
board_create_second_log="$board_create_race_dir/second.log"
PGAPPNAME=openkanban_board_create_lock_holder "${psql[@]}" > "$board_create_lock_log" 2>&1 <<'SQL' &
BEGIN;
LOCK TABLE public.board_creation_requests IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(3);
COMMIT;
SQL
board_create_lock_pid=$!
board_create_lock_active=false
for _ in $(seq 1 100); do
  lock_state=$("${psql[@]}" -At -c "SELECT state FROM pg_stat_activity WHERE application_name = 'openkanban_board_create_lock_holder' AND state = 'active' AND query LIKE '%pg_sleep(3)%'")
  if [[ "$lock_state" == active ]]; then
    board_create_lock_active=true
    break
  fi
  sleep 0.05
done
if [[ "$board_create_lock_active" != true ]]; then
  cat -- "$board_create_lock_log" >&2
  echo 'Board creation lock holder did not start.' >&2
  exit 1
fi
for attempt in first second; do
  if [[ "$attempt" == first ]]; then
    target_log="$board_create_first_log"
  else
    target_log="$board_create_second_log"
  fi
  PGAPPNAME="openkanban_board_create_$attempt" "${psql[@]}" > "$target_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '40000000-0000-4000-8000-000000000002', true);
SELECT id FROM public.create_board_p(
  'Intención concurrente', 'UTC', 'eeeeeeee-0000-4000-8000-000000000001'
);
COMMIT;
SQL
  if [[ "$attempt" == first ]]; then
    board_create_first_pid=$!
  else
    board_create_second_pid=$!
  fi
done
wait "$board_create_lock_pid" || { cat -- "$board_create_lock_log" >&2; exit 1; }
wait "$board_create_first_pid" || { cat -- "$board_create_first_log" >&2; exit 1; }
wait "$board_create_second_pid" || { cat -- "$board_create_second_log" >&2; exit 1; }
board_create_uuid_pattern='[[:xdigit:]]{8}-([[:xdigit:]]{4}-){3}[[:xdigit:]]{12}'
board_create_first_id=$(grep -Eo "$board_create_uuid_pattern" "$board_create_first_log" | tail -n 1)
board_create_second_id=$(grep -Eo "$board_create_uuid_pattern" "$board_create_second_log" | tail -n 1)
board_create_receipt_id=$("${psql[@]}" -At -c "SELECT board_id FROM public.board_creation_requests WHERE user_id = '40000000-0000-4000-8000-000000000002' AND operation_id = 'eeeeeeee-0000-4000-8000-000000000001'")
if [[ -z "$board_create_first_id" || "$board_create_first_id" != "$board_create_second_id" || "$board_create_first_id" != "$board_create_receipt_id" ]]; then
  echo 'Concurrent create retries did not return the same board recorded by the receipt.' >&2
  cat -- "$board_create_first_log" "$board_create_second_log" >&2
  exit 1
fi
board_create_count=$("${psql[@]}" -At -c "SELECT count(*) FROM public.board_creation_requests WHERE user_id = '40000000-0000-4000-8000-000000000002' AND operation_id = 'eeeeeeee-0000-4000-8000-000000000001'")
if [[ "$board_create_count" != 1 ]]; then
  echo "Concurrent create intent produced $board_create_count request receipts; expected 1." >&2
  cat -- "$board_create_first_log" "$board_create_second_log" >&2
  exit 1
fi
echo 'PASS: two concurrent retries of one board creation intent produce one board'

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
