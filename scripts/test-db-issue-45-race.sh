#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'Usage: test-db-issue-45-race.sh PSQL TEST_DIR PORT RACE_DIR' >&2
  exit 2
fi
psql_bin=$1
socket_dir=$2
port=$3
race_dir=$4
mkdir -p -- "$race_dir"
psql=(env -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE
  "$psql_bin" -X -h "$socket_dir" -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt)

"${psql[@]}" <<'SQL'
UPDATE public.board_generation_retention AS retention
SET retained_board_name = 'Destino previo', retained_time_zone = 'UTC'
FROM public.issue44_import_fixture AS fixture
WHERE retention.board_id = fixture.board_id
  AND retention.generation_id = fixture.old_generation_id;
SQL

preview_revision=$("${psql[@]}" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true) \gset
SELECT public.prepare_board_import_restore_p(
  fixture.slug, fixture.old_generation_id, 'a4550000-0000-4000-8000-000000000007'
)->>'content_revision'
FROM public.issue44_import_fixture AS fixture;
COMMIT;
SQL
)
if [[ ! "$preview_revision" =~ ^[0-9]+$ ]]; then
  echo "Could not prepare the restore and cleanup race; revision was '$preview_revision'." >&2
  exit 1
fi

"${psql[@]}" <<'SQL'
CREATE FUNCTION public.issue45_hold_restore_publication_tg()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_catalog.pg_sleep(5);
  RETURN NEW;
END;
$$;
CREATE TRIGGER issue45_hold_restore_publication
  BEFORE UPDATE OF active_generation_id ON public.boards
  FOR EACH ROW WHEN (OLD.active_generation_id IS DISTINCT FROM NEW.active_generation_id)
  EXECUTE FUNCTION public.issue45_hold_restore_publication_tg();
WITH expiry AS (
  SELECT pg_catalog.clock_timestamp() + interval '3 seconds' AS expires_at
)
UPDATE public.board_generation_retention AS retention
SET retained_at = expiry.expires_at - interval '168 hours',
    expires_at = expiry.expires_at
FROM expiry, public.issue44_import_fixture AS fixture
WHERE retention.board_id = fixture.board_id
  AND retention.generation_id = fixture.old_generation_id;
SQL

restore_log="$race_dir/restore.log"
cleanup_log="$race_dir/cleanup.log"
PGAPPNAME=openkanban_issue45_restore_race "${psql[@]}" >"$restore_log" 2>&1 <<SQL &
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true);
SELECT public.confirm_board_import_restore_p(
  fixture.slug, fixture.old_generation_id, 'a4550000-0000-4000-8000-000000000007',
  $preview_revision
)->>'status'
FROM public.issue44_import_fixture AS fixture;
COMMIT;
SQL
restore_pid=$!

restore_waiting=false
for _ in $(seq 1 100); do
  sleeping=$(
    "${psql[@]}" -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'openkanban_issue45_restore_race' AND wait_event = 'PgSleep'"
  )
  if [[ "$sleeping" == 1 ]]; then
    restore_waiting=true
    break
  fi
  sleep 0.05
done
if [[ "$restore_waiting" != true ]]; then
  cat -- "$restore_log" >&2
  echo 'The restore confirmation did not reach its serialized publication window.' >&2
  wait "$restore_pid" || true
  exit 1
fi

sleep 3.2
PGAPPNAME=openkanban_issue45_cleanup_race "${psql[@]}" >"$cleanup_log" 2>&1 <<'SQL' &
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_generation_retention_p(50);
COMMIT;
SQL
cleanup_pid=$!
wait "$cleanup_pid" || { cat -- "$cleanup_log" >&2; wait "$restore_pid" || true; exit 1; }
wait "$restore_pid" || { cat -- "$restore_log" >&2; exit 1; }
if ! grep -Fxq 'confirmed' "$restore_log" || ! grep -Fxq '0' "$cleanup_log"; then
  cat -- "$restore_log" "$cleanup_log" >&2
  echo 'The concurrent cleanup did not skip the board while restore held its lock.' >&2
  exit 1
fi

race_state=$("${psql[@]}" <<'SQL'
SELECT CASE WHEN board.active_generation_id = fixture.old_generation_id
    AND target.status = 'active'
    AND NOT EXISTS (
      SELECT 1 FROM public.board_generation_retention AS retention
      WHERE retention.board_id = fixture.board_id
        AND retention.generation_id = fixture.old_generation_id
    ) THEN 'valid' ELSE 'invalid' END
FROM public.issue44_import_fixture AS fixture
JOIN public.boards AS board ON board.id = fixture.board_id
JOIN public.board_generations AS target
  ON target.board_id = fixture.board_id AND target.id = fixture.old_generation_id;
SQL
)
if [[ "$race_state" != valid ]]; then
  echo 'The restore/cleanup race left the active generation retained or purged.' >&2
  exit 1
fi

"${psql[@]}" -c 'DROP TRIGGER issue45_hold_restore_publication ON public.boards; DROP FUNCTION public.issue45_hold_restore_publication_tg()' >/dev/null

expired_preview_revision=$("${psql[@]}" <<'SQL'
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true) \gset
SELECT public.prepare_board_import_restore_p(
  fixture.slug, fixture.published_generation_id, 'a4550000-0000-4000-8000-000000000008'
)->>'content_revision'
FROM public.issue44_import_fixture AS fixture;
COMMIT;
SQL
)
if [[ ! "$expired_preview_revision" =~ ^[0-9]+$ ]]; then
  echo "Could not prepare the cleanup_pending fail-closed case; revision was '$expired_preview_revision'." >&2
  exit 1
fi

"${psql[@]}" <<'SQL'
WITH expired AS (
  SELECT pg_catalog.clock_timestamp() - interval '169 hours' AS retained_at
)
UPDATE public.board_generation_retention AS retention
SET retained_at = expired.retained_at,
    expires_at = expired.retained_at + interval '168 hours'
FROM expired, public.issue44_import_fixture AS fixture
WHERE retention.board_id = fixture.board_id
  AND retention.generation_id = fixture.published_generation_id;
SQL
"${psql[@]}" <<'SQL'
BEGIN;
SET LOCAL ROLE service_role;
SELECT public.cleanup_expired_board_generation_retention_p(50);
COMMIT;
SQL

failed_restore=$("${psql[@]}" <<SQL
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'a4400000-0000-4000-8000-000000000001', true) \gset
SELECT public.confirm_board_import_restore_p(
  fixture.slug, fixture.published_generation_id, 'a4550000-0000-4000-8000-000000000008',
  $expired_preview_revision
)->>'status'
FROM public.issue44_import_fixture AS fixture;
COMMIT;
SQL
)
cleanup_pending_state=$("${psql[@]}" <<'SQL'
SELECT CASE WHEN board.active_generation_id = fixture.old_generation_id
    AND previous.status = 'archived'
    AND attachment.state = 'cleanup_pending' THEN 'valid' ELSE 'invalid' END
FROM public.issue44_import_fixture AS fixture
JOIN public.boards AS board ON board.id = fixture.board_id
JOIN public.board_generations AS previous
  ON previous.board_id = fixture.board_id AND previous.id = fixture.published_generation_id
JOIN public.task_attachments AS attachment
  ON attachment.id = fixture.new_attachment_id;
SQL
)
if [[ "$failed_restore" != expired || "$cleanup_pending_state" != valid ]]; then
  echo "An expired or cleanup_pending generation was resurrected: status='$failed_restore', state='$cleanup_pending_state'." >&2
  exit 1
fi

echo 'PASS: a restore holding the board lock wins without purge; an expired cleanup_pending target cannot be restored.'
