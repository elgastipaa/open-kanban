#!/usr/bin/env bash
set -euo pipefail
TEST_DB_FOCUS=issue48 bash "$(dirname -- "$0")/test-db.sh"
