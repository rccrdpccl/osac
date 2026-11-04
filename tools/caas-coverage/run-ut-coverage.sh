#!/usr/bin/env bash
# UT coverage for the CaaS scope (OSAC-6117).
#
# Runs the unit suites of every module that owns CaaS code (core + worker
# path), plus the caas-marked Python unit tests over the E2E harness, and
# produces the filtered merged profile + HTML report under
# docs/plans/coverage-osac-6117/.
#
# Prerequisites: Go 1.26+, uv, and a working container runtime for the
# fulfillment-service PostgreSQL test container (podman is used
# automatically). setup-envtest binaries are downloaded on demand.
#
# Usage (from the repository root):
#   bash tools/caas-coverage/run-ut-coverage.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT/docs/plans/coverage-osac-6117"
RAW="$OUT_DIR/ut-raw"
mkdir -p "$RAW"

# --- Go: fulfillment-service ------------------------------------------------
cd "$ROOT/fulfillment-service"
go test ./internal/servers -covermode=atomic -coverprofile="$RAW/fulfillment-servers.out"
go test ./internal/database/migrations -covermode=atomic \
  -coverprofile="$RAW/fulfillment-migrations.out" || \
  echo "NOTE: migrations suite failed (needs the podman PostgreSQL container)"

# --- Go: osac-operator -------------------------------------------------------
cd "$ROOT/osac-operator"
if [ ! -x bin/setup-envtest ] && [ ! -x "$(go env GOPATH)/bin/setup-envtest" ]; then
  go install sigs.k8s.io/controller-runtime/tools/setup-envtest@release-0.19
fi
SETUP_ENVTEST="$(go env GOPATH)/bin/setup-envtest"
[ -x "$ROOT/osac-operator/bin/setup-envtest" ] && SETUP_ENVTEST="$ROOT/osac-operator/bin/setup-envtest"
KUBEBUILDER_ASSETS="$("$SETUP_ENVTEST" use 1.31.0 --bin-dir "$ROOT/osac-operator/bin" -p path)" \
  go test $(go list ./... | grep -v '/test/integration') \
  -covermode=atomic -coverprofile="$RAW/operator.out"

# --- Go: bare-metal-fulfillment-operator (worker path) ----------------------
cd "$ROOT/bare-metal-fulfillment-operator"
KUBEBUILDER_ASSETS="$("$SETUP_ENVTEST" use 1.31.0 --bin-dir "$ROOT/bare-metal-fulfillment-operator/bin" -p path)" \
  go test $(go list ./... | grep -v '/test/integration') \
  -covermode=atomic -coverprofile="$RAW/bmf.out"

# --- Go: osac-metering cluster events ---------------------------------------
cd "$ROOT/osac-metering/metering-service"
go test ./internal/events -covermode=atomic -coverprofile="$RAW/metering-events.out"

# --- Python: caas-marked unit tests over the E2E harness --------------------
cd "$ROOT"
uv run --with pytest-cov pytest tests/unit -m caas \
  --cov=tests/e2e \
  --cov-report=json:"$RAW/python-caas.json" \
  --cov-report=term-missing:skip-covered

# --- Merge, filter, report ---------------------------------------------------
python3 "$ROOT/tools/caas-coverage/filter_profile.py" \
  --profile "$RAW"/fulfillment-servers.out "$RAW"/operator.out "$RAW"/bmf.out \
            "$RAW"/metering-events.out \
  --output "$OUT_DIR/caas-ut-coverage.out" \
  --json "$RAW/caas-ut-summary.json"
go tool cover -html="$OUT_DIR/caas-ut-coverage.out" -o "$OUT_DIR/caas-ut-coverage.html"

if [ -f "$OUT_DIR/caas-it-coverage.out" ]; then
  echo
  echo "NOTE: $OUT_DIR/caas-it-coverage.out exists; regenerate the combined"
  echo "profile with filter_profile.py if you want UT+IT merged numbers."
fi
echo "UT coverage artifacts written to $OUT_DIR"
