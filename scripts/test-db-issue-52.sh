#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DB_FOCUS=issue52 bash "$repo_dir/scripts/test-db.sh"
