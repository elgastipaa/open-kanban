#!/usr/bin/env bash
set -euo pipefail
TEST_DB_FOCUS=issue31-upgrade bash scripts/test-db.sh
