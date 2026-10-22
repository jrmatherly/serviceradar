#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_COUNT="${SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT:-50000}"
CHUNK_SIZE="${SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE:-1000}"

echo "Running Armis agent large-ingestion release gate (${DEVICE_COUNT} devices)"
(
  cd "${ROOT_DIR}"
  SERVICERADAR_LARGE_INGESTION_TEST=1 go test ./go/pkg/agent \
    -run TestRunArmisSyncReleaseGateStreamsMultipleQueriesAndRefreshesToken \
    -count=1
)

if [[ -z "${SERVICERADAR_TEST_DATABASE_URL:-}" && -f /tmp/sr_identity_validation_db_info ]]; then
  # Created by the SRQL fixture lifecycle (docs/agent-runbooks.md). The file stores a URL-escaped
  # password and must not be printed.
  # shellcheck disable=SC1091
  source /tmp/sr_identity_validation_db_info
  export SERVICERADAR_TEST_DATABASE_URL="postgres://${ADMIN_USER}:${ADMIN_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB}?sslmode=require"
fi

if [[ -z "${SERVICERADAR_TEST_DATABASE_URL:-}" && -z "${SRQL_TEST_DATABASE_URL:-}" ]]; then
  cat >&2 <<'MSG'
SERVICERADAR_TEST_DATABASE_URL or SRQL_TEST_DATABASE_URL is required for the core ingestion gate.
Create an isolated CNPG database per docs/agent-runbooks.md (SRQL Fixture Integration Tests), then rerun this script.
MSG
  exit 1
fi

echo "Running core ResultsRouter large-ingestion release gate (${DEVICE_COUNT} devices, chunk size ${CHUNK_SIZE})"
(
  cd "${ROOT_DIR}/elixir/serviceradar_core"
  SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT="${DEVICE_COUNT}" \
  SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE="${CHUNK_SIZE}" \
  MIX_ENV=test mix test --include large_ingestion --only large_ingestion \
    test/serviceradar/results_router_integration_test.exs
)
