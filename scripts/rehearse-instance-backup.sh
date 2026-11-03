#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pg_bin=${PG_BINDIR:?El arnés descartable debe proporcionar PG_BINDIR}
source_dir=${OPENKANBAN_TEST_DB_DIR:?El arnés descartable debe proporcionar OPENKANBAN_TEST_DB_DIR}
source_port=${OPENKANBAN_TEST_DB_PORT:?El arnés descartable debe proporcionar OPENKANBAN_TEST_DB_PORT}
source_socket=$source_dir
run_dir=$source_dir/issue50-rehearsal
bundle_dir=$run_dir/bundle
source_storage=$run_dir/source-storage
archive_path=$run_dir/openkanban-instance-backup.tar.gz
archive_checksum=$run_dir/openkanban-instance-backup.tar.gz.sha256
target_dir=$run_dir/restore-target
target_socket=$target_dir/socket
target_port=$source_port
target_started=false
object_key=attachments/issue50/fixture.txt
fixture_hash=3809ddda411bb00f1716d380bc095848b006bf43c459fcee801ca4bfe6fe7e73

case "$source_dir" in
  /tmp/openkanban-db.*) ;;
  *) printf 'Se rechaza el directorio PostgreSQL que no es descartable: %s\n' "$source_dir" >&2; exit 1 ;;
esac

for binary in initdb pg_ctl psql pg_dump pg_dumpall pg_restore createdb dropdb pg_config; do
  if [[ ! -x "$pg_bin/$binary" ]]; then
    printf 'Falta el ejecutable PostgreSQL: %s/%s\n' "$pg_bin" "$binary" >&2
    exit 1
  fi
done

mkdir -m 700 -- "$run_dir"
mkdir -p -m 700 -- "$bundle_dir" "$source_storage" "$target_dir"

cleanup_target() {
  if [[ "$target_started" == true ]]; then
    "$pg_bin/pg_ctl" -D "$target_dir/data" -m immediate stop >/dev/null 2>&1 || true
  fi
}
trap cleanup_target EXIT

safe_env=(env -u DATABASE_URL -u PGHOSTADDR -u PGSERVICE -u PGSERVICEFILE \
  -u PGOPTIONS -u PGPASSWORD -u PGPASSFILE)

source_psql() {
  "${safe_env[@]}" "$pg_bin/psql" -X -w -h "$source_socket" -p "$source_port" \
    -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

target_psql() {
  local database=$1
  shift
  "${safe_env[@]}" "$pg_bin/psql" -X -w -h "$target_socket" -p "$target_port" \
    -U postgres -d "$database" -v ON_ERROR_STOP=1 "$@"
}

target_pg_restore() {
  local database=$1
  "${safe_env[@]}" "$pg_bin/pg_restore" -w --exit-on-error --single-transaction \
    -h "$target_socket" -p "$target_port" -U postgres --role=postgres \
    --dbname="$database" "$bundle_dir/database.dump"
}

assert_issue52_restore() {
  if [[ "${OPENKANBAN_TEST_DB_FOCUS:-}" == 'issue52' ]]; then
    target_psql "$1" -q -f "$repo_dir/tests/db/issue52_restore_assert.sql"
  fi
}

printf 'Cargando un fixture local de mantenimiento con actores y bytes sintéticos.\n'
source_psql -q -f "$repo_dir/tests/db/issue50_rehearsal_fixture.sql"
source_psql -q -f "$repo_dir/tests/db/anonymous_surface.sql"

snapshot_id=$(source_psql -At -c 'SELECT snapshot_id FROM issue50_rehearsal.instance_snapshot WHERE singleton')
checkpoint_ms=$(source_psql -At -c "SELECT floor(extract(epoch FROM checkpoint_at) * 1000)::bigint FROM issue50_rehearsal.instance_snapshot WHERE snapshot_id = '$snapshot_id'")
if [[ "$snapshot_id" != '86100000-0000-4000-8000-000000000001' || ! "$checkpoint_ms" =~ ^[0-9]+$ ]]; then
  printf 'El checkpoint sintético de mantenimiento falta o no es válido.\n' >&2
  exit 1
fi

mkdir -p -- "$source_storage/attachments/issue50"
printf 'Issue 50 synthetic attachment\n' > "$source_storage/$object_key"
chmod 600 -- "$source_storage/$object_key"
source_hash=$(sha256sum -- "$source_storage/$object_key" | cut -d ' ' -f 1)
source_size=$(wc -c < "$source_storage/$object_key" | tr -d '[:space:]')
database_attachment=$(source_psql -At -c "SELECT size_bytes::text || ':' || encode(sha256, 'hex') FROM public.task_attachments WHERE object_key = '$object_key'")
if [[ "$source_hash" != "$fixture_hash" || "$source_size" != '30' || "$database_attachment" != "30:$fixture_hash" ]]; then
  printf 'Los bytes de Storage sintético no coinciden con el fixture (bytes=%s, sha256=%s, base=%s).\n' \
    "$source_size" "$source_hash" "$database_attachment" >&2
  exit 1
fi

mkdir -p -- "$bundle_dir/storage/attachments/issue50"
cp -- "$source_storage/$object_key" "$bundle_dir/storage/$object_key"
(
  cd -- "$bundle_dir"
  find storage -type f -print0 | sort -z | xargs -0 sha256sum > storage.sha256
)

printf 'Registrando versiones y configuración no secreta mediante una lista explícita.\n'
(
  cd -- "$repo_dir"
  sha256sum package.json pnpm-lock.yaml next.config.ts vercel.json LICENSE
  find supabase/migrations -maxdepth 1 -type f -name '*.sql' -print0 \
    | sort -z | xargs -0 sha256sum
) > "$bundle_dir/release-files.sha256"

app_version=$(cd -- "$repo_dir" && node -p 'require("./package.json").version')
git_commit=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null \
  || git.exe -C "$(wslpath -w "$repo_dir")" rev-parse HEAD)
migration_head=$(find "$repo_dir/supabase/migrations" -maxdepth 1 -type f -name '*.sql' -printf '%f\n' | sort | tail -n 1)
postgres_version=$("$pg_bin/pg_config" --version)

cat > "$bundle_dir/runtime-config-allowlist.txt" <<'CONFIG'
profile=issue50-synthetic-local-v1
database=postgresql-local-unix-socket-only
authentication=synthetic-test-principals
storage=synthetic-filesystem-object-fixture
jobs=stopped-throughout-restore
realtime=database-schema-stub-only
credentials=excluded-recover-through-authorized-secure-channel
CONFIG

config_hash=$(sha256sum -- "$bundle_dir/runtime-config-allowlist.txt" | cut -d ' ' -f 1)
if grep -Eiq '^[[:space:]]*(password|secret|token|.*api[_-]?key|service[_-]?role[_-]?key)[[:space:]]*=[[:space:]]*[^[:space:]]' \
  "$bundle_dir/runtime-config-allowlist.txt"; then
  printf 'La lista sintética de configuración contiene inesperadamente valores secretos.\n' >&2
  exit 1
fi
cat > "$bundle_dir/manifest.txt" <<MANIFEST
format=openkanban-instance-rehearsal-v1
snapshot_id=$snapshot_id
checkpoint_epoch_ms=$checkpoint_ms
app_version=$app_version
repository_commit=$git_commit
migration_head=$migration_head
postgres_server=$postgres_version
runtime_config_profile=issue50-synthetic-local-v1
runtime_config_sha256=$config_hash
release_files_manifest=release-files.sha256
credentials=excluded
MANIFEST

printf 'Creando el archivo personalizado de PostgreSQL y los roles sin contraseñas.\n'
"${safe_env[@]}" "$pg_bin/pg_dumpall" --globals-only --no-role-passwords --no-tablespaces \
  --database="dbname=postgres host=$source_socket port=$source_port user=postgres" \
  --no-password > "$bundle_dir/global-roles.sql"
if grep -Eiq '(^|[[:space:]])PASSWORD([[:space:]]|=)' "$bundle_dir/global-roles.sql"; then
  printf 'La exportación de roles contiene inesperadamente un campo de contraseña.\n' >&2
  exit 1
fi
sed '/^CREATE ROLE postgres;$/d' "$bundle_dir/global-roles.sql" \
  > "$bundle_dir/global-roles-for-restore.sql"
"${safe_env[@]}" "$pg_bin/pg_dump" --format=custom --dbname=postgres \
  --host="$source_socket" --port="$source_port" --username=postgres --no-password \
  --file="$bundle_dir/database.dump"

tar -czf "$archive_path" -C "$bundle_dir" .
(cd -- "$run_dir" && sha256sum "$(basename -- "$archive_path")" > "$(basename -- "$archive_checksum")")
(
  cd -- "$run_dir"
  sha256sum -c "$(basename -- "$archive_checksum")" >/dev/null
)

printf 'Simulando una pérdida después del snapshot con una escritura sintética posterior.\n'
source_psql -q -c "UPDATE issue50_rehearsal.instance_snapshot SET state_marker = 'post-snapshot-write' WHERE singleton"
printf 'Changed after snapshot\n' > "$source_storage/$object_key"
failure_ms=$(date +%s%3N)
restore_started_ms=$failure_ms

mkdir -m 700 -- "$target_socket"
"$pg_bin/initdb" -D "$target_dir/data" -U postgres --no-locale \
  --encoding=UTF8 --auth-local=trust --auth-host=reject > "$target_dir/init.log"
"$pg_bin/pg_ctl" -D "$target_dir/data" -l "$target_dir/server.log" \
  -o "-F -k $target_socket -p $target_port -c listen_addresses='' -c unix_socket_permissions=0700" \
  -w start >/dev/null
target_started=true

printf 'Restaurando los roles PostgreSQL sin material de contraseña.\n'
target_psql postgres -q -f "$bundle_dir/global-roles-for-restore.sql"

printf 'Ejecutando el primer restore aislado.\n'
"${safe_env[@]}" "$pg_bin/createdb" -w -h "$target_socket" -p "$target_port" \
  -U postgres --owner=postgres --template=template0 issue50_failed_upgrade
target_pg_restore issue50_failed_upgrade
target_psql issue50_failed_upgrade -q -f "$repo_dir/tests/db/issue50_restore_assert.sql"
assert_issue52_restore issue50_failed_upgrade
target_psql issue50_failed_upgrade -q -f "$repo_dir/tests/db/anonymous_surface.sql"

printf 'Inyectando una migración fallida y comprobando el rollback de su DDL.\n'
failure_log=$run_dir/failed-upgrade.log
if target_psql issue50_failed_upgrade -f "$repo_dir/tests/db/issue50_failing_upgrade.sql" > "$failure_log" 2>&1; then
  printf 'La inyección de fallo de migración terminó inesperadamente con éxito.\n' >&2
  exit 1
fi
if ! grep -q 'division by zero' "$failure_log"; then
  printf 'La migración fallida no produjo el error aislado esperado.\n' >&2
  exit 1
fi
failed_upgrade_rolled_back=$(target_psql issue50_failed_upgrade -At -c \
  "SELECT NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'boards' AND column_name = 'issue50_failed_upgrade_marker')")
if [[ "$failed_upgrade_rolled_back" != 't' ]]; then
  printf 'La migración fallida dejó un cambio parcial en el esquema restaurado.\n' >&2
  exit 1
fi
if [[ "${OPENKANBAN_TEST_DB_FOCUS:-}" == 'issue52' ]]; then
  printf 'Comprobando privacidad y contenido después del rollback de migración.\n'
  target_psql issue50_failed_upgrade -q -f "$repo_dir/tests/db/issue50_restore_assert.sql"
  assert_issue52_restore issue50_failed_upgrade
  target_psql issue50_failed_upgrade -q -f "$repo_dir/tests/db/anonymous_surface.sql"
fi

printf 'Reintentando el restore en una base aislada y limpia.\n'
"${safe_env[@]}" "$pg_bin/dropdb" -w -h "$target_socket" -p "$target_port" \
  -U postgres issue50_failed_upgrade
"${safe_env[@]}" "$pg_bin/createdb" -w -h "$target_socket" -p "$target_port" \
  -U postgres --owner=postgres --template=template0 issue50_recovered
target_pg_restore issue50_recovered
assert_issue52_restore issue50_recovered

restore_stage=$run_dir/restored-bundle
mkdir -m 700 -- "$restore_stage"
tar -xzf "$archive_path" -C "$restore_stage"
manifest_snapshot_id=$(sed -n 's/^snapshot_id=//p' "$restore_stage/manifest.txt")
manifest_config_hash=$(sed -n 's/^runtime_config_sha256=//p' "$restore_stage/manifest.txt")
restored_config_hash=$(sha256sum -- "$restore_stage/runtime-config-allowlist.txt" | cut -d ' ' -f 1)
if [[ "$manifest_snapshot_id" != "$snapshot_id" || "$manifest_config_hash" != "$config_hash" \
  || "$restored_config_hash" != "$config_hash" ]]; then
  printf 'El manifiesto de restore no coincide con el snapshot o la configuración sintética.\n' >&2
  exit 1
fi
(
  cd -- "$restore_stage"
  sha256sum -c storage.sha256 >/dev/null
)
(
  cd -- "$repo_dir"
  sha256sum -c "$restore_stage/release-files.sha256" >/dev/null
)
restored_storage_hash=$(sha256sum -- "$restore_stage/storage/$object_key" | cut -d ' ' -f 1)
restored_storage_size=$(wc -c < "$restore_stage/storage/$object_key" | tr -d '[:space:]')
restored_marker=$(target_psql issue50_recovered -At -c 'SELECT state_marker FROM issue50_rehearsal.instance_snapshot WHERE singleton')
if [[ "$restored_marker" != 'snapshot-v1' || "$restored_storage_hash" != "$fixture_hash" || "$restored_storage_size" != '30' ]]; then
  printf 'El reintento no restauró el marcador previo al fallo y los bytes del objeto.\n' >&2
  exit 1
fi
target_psql issue50_recovered -q -f "$repo_dir/tests/db/issue50_restore_assert.sql"
target_psql issue50_recovered -q -f "$repo_dir/tests/db/anonymous_surface.sql"

source_acl=$run_dir/source-acl.txt
target_acl=$run_dir/target-acl.txt
source_psql -At -f "$repo_dir/tests/db/issue50_acl_snapshot.sql" > "$source_acl"
target_psql issue50_recovered -At -f "$repo_dir/tests/db/issue50_acl_snapshot.sql" > "$target_acl"
if ! cmp -s -- "$source_acl" "$target_acl"; then
  diff -u -- "$source_acl" "$target_acl" | head -n 80 >&2 || true
  printf 'El restore aislado cambió roles, grants, RLS, políticas o ACL predeterminados.\n' >&2
  exit 1
fi

restore_ready_ms=$(date +%s%3N)
if [[ ! "$failure_ms" =~ ^[0-9]+$ || ! "$checkpoint_ms" =~ ^[0-9]+$ \
  || ! "$restore_started_ms" =~ ^[0-9]+$ || ! "$restore_ready_ms" =~ ^[0-9]+$ \
  || "$restore_ready_ms" -lt "$restore_started_ms" ]]; then
  printf 'El reloj del ensayo devolvió marcas RPO/RTO inválidas.\n' >&2
  exit 1
fi
rpo_ms=$((failure_ms - checkpoint_ms))
rto_ms=$((restore_ready_ms - restore_started_ms))
if (( rpo_ms < 0 || rto_ms < 0 )); then
  printf 'El ensayo produjo una medición RPO/RTO negativa.\n' >&2
  exit 1
fi

archive_hash=$(cut -d ' ' -f 1 "$archive_checksum")
printf 'PASS: dump/restore, bytes sintéticos, roles/ACL, cuota, serie/exclusión y trabajos detenidos.\n'
printf 'PASS: migración fallida revertida; el reintento conservó el snapshot anterior.\n'
printf 'MEASURED_RPO_MS=%s\n' "$rpo_ms"
printf 'MEASURED_RTO_MS=%s\n' "$rto_ms"
printf 'BACKUP_SHA256=%s\n' "$archive_hash"
printf 'RESTORED_OBJECT_SHA256=%s\n' "$restored_storage_hash"
