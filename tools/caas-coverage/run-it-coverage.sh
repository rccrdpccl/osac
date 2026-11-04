#!/usr/bin/env bash
# In-cluster IT coverage for the CaaS sections of the fulfillment it/ suite.
#
# Deploys the coverage-instrumented fulfillment-service into the local Kind
# cluster (PLATFORM=kind PROFILE=dev), runs only the caas-labeled it/ specs,
# then extracts the service's Go coverage counters and converts them to a
# text profile.
#
# Prerequisites:
#   - /etc/hosts entries from fulfillment-service/README.md
#     (keycloak.keycloak.svc.cluster.local, fulfillment-api.osac.svc.cluster.local,
#      fulfillment-internal-api.osac.svc.cluster.local -> 127.0.0.1)
#   - `make -C osac-installer install-infra PLATFORM=kind PROFILE=dev NS=osac`
#   - fulfillment-service/Containerfile supports ARG COVERAGE=true
#
# Hard-won operational notes (validated in a real run, 2026-10-20):
#   - The chart deploys the service as per-role deployments
#     (fulfillment-grpc-server, -controller, -rest-gateway, -event-publisher,
#     -console-proxy, -ingress-proxy), not one fulfillment-service deployment.
#   - Container root filesystems are read-only and the runtime image has no
#     tar: /tmp/gocov must be a mounted emptyDir, and collection must use
#     `kubectl exec -- cat`, not `kubectl cp`.
#   - Go writes counter files only at process exit. The service's SIGTERM
#     shutdown calls GracefulStop(), which blocks forever while envoy and the
#     sibling deployments hold idle pooled gRPC connections; the shutdown
#     sequence then aborts without exiting and kubelet SIGKILLs the container
#     (no flush). Before terminating the grpc-server, scale the sibling
#     deployments to zero and restart the envoy data-plane deployment.
#   - SIGTERM PID 1 via `kubectl exec -- sh -c 'kill -TERM 1'` (kill is a
#     shell builtin; the image has no kill binary). The emptyDir survives the
#     container restart, so the flushed PID-1 counter file is collectable
#     afterwards.
#
# Usage (from the repository root):
#   bash tools/caas-coverage/run-it-coverage.sh [NS]
#
# Output: docs/plans/coverage-osac-6117/caas-it-coverage.out (+ .html),
#         raw covdata under /tmp/caas-it-run/covdata-final/.
set -euo pipefail

NS="${1:-osac}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$ROOT/docs/plans/coverage-osac-6117"
RUN_DIR="/tmp/caas-it-run"
GRPC_DEP=fulfillment-grpc-server
SIBLINGS=(fulfillment-controller fulfillment-rest-gateway fulfillment-event-publisher
  fulfillment-console-proxy fulfillment-ingress-proxy)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/osac-dev-kind.kubeconfig}"

collect() {  # collect <pod> <dest-dir> — live snapshot via exec cat (no tar)
  local pod="$1" dest="$2" f
  mkdir -p "$dest"
  for f in $(kubectl -n "$NS" exec "$pod" -- ls /tmp/gocov 2>/dev/null || true); do
    kubectl -n "$NS" exec "$pod" -- cat "/tmp/gocov/$f" > "$dest/$f" 2>/dev/null || true
  done
  echo "collected $(ls "$dest" | wc -l) files from $pod"
}

grpc_pod() {
  kubectl -n "$NS" get pods -o name | grep "$GRPC_DEP" | head -1 | cut -d/ -f2
}

# --- 1. Build the coverage-instrumented image and load it into Kind -------
if ! podman image inspect localhost/fulfillment-service:it >/dev/null 2>&1; then
  podman build --build-arg GODEBUG=http2client=0 --build-arg COVERAGE=true \
    -t localhost/fulfillment-service:it -f "$ROOT/fulfillment-service/Containerfile" "$ROOT"
fi
tmpfile=$(mktemp /tmp/kind-image-XXXXXX.tar)
trap 'rm -f "$tmpfile"' EXIT
podman save localhost/fulfillment-service:it -o "$tmpfile"
kind load image-archive "$tmpfile" --name osac-dev

# --- 2. Deploy OSAC (phase-1 shape: service only, operator disabled) ------
# Mirrors phase 1 of osac-installer's `make test SUITE=fulfillment`.
make -C "$ROOT/osac-installer" install-osac PLATFORM=kind PROFILE=dev NS="$NS" \
  EXTRA_HELM_ARGS="--set service.images.service.repository=localhost/fulfillment-service \
    --set service.images.service.tag=it --set service.images.service.pullPolicy=Never \
    --set service.controller.sync=false --set operator.enabled=false \
    --set operator.networkManagers.enabled=true --set global.networking.networkClass.enabled=false"
for f in "$ROOT"/fulfillment-service/it/crds/*.yaml; do
  kubectl apply --server-side --field-manager=helm --force-conflicts -f "$f"
done

# --- 3. Enable in-pod coverage: GOCOVERDIR env + emptyDir at /tmp/gocov ---
ALL_DEPS=("$GRPC_DEP" "${SIBLINGS[@]}")
for dep in "${ALL_DEPS[@]}"; do
  kubectl -n "$NS" set env "deployment/$dep" GOCOVERDIR=/tmp/gocov
  kubectl -n "$NS" patch "deploy/$dep" --type strategic -p \
    '{"spec":{"template":{"spec":{"volumes":[{"name":"gocov","emptyDir":{}}]}}}}'
  container="${dep#fulfillment-}"
  kubectl -n "$NS" patch "deploy/$dep" --type strategic -p \
    '{"spec":{"template":{"spec":{"containers":[{"name":"'"$container"'","volumeMounts":[{"name":"gocov","mountPath":"/tmp/gocov"}]}]}}}}' \
    || echo "NOTE: mount /tmp/gocov on $dep manually (container name mismatch)"
  kubectl -n "$NS" rollout status "deployment/$dep" --timeout=300s
done

# --- 4. Run only the caas-labeled IT specs ---------------------------------
cd "$ROOT/fulfillment-service"
ginkgo run --timeout 1h15m -v --label-filter=caas \
  --skip 'NetworkClass manager (capability discovery|readiness)' it

# --- 5. Flush the grpc-server's counters with a clean exit ----------------
# Drop every holder of pooled gRPC connections first (see header notes).
for dep in "${SIBLINGS[@]}"; do
  kubectl -n "$NS" scale "deployment/$dep" --replicas=0
done
ENVOY_DEP=$(kubectl -n envoy-gateway get deploy -o name | grep 'envoy-envoy-gateway' | head -1 | cut -d/ -f2)
if [ -n "$ENVOY_DEP" ]; then
  kubectl -n envoy-gateway rollout restart "deployment/$ENVOY_DEP"
  kubectl -n envoy-gateway rollout status "deployment/$ENVOY_DEP" --timeout=180s
fi
POD=$(grpc_pod)
kubectl -n "$NS" exec "$POD" -- sh -c 'kill -TERM 1'
sleep 30  # graceful shutdown + flush + container restart
for dep in "${SIBLINGS[@]}"; do
  kubectl -n "$NS" scale "deployment/$dep" --replicas=1
done

# --- 6. Collect and convert to a text profile ------------------------------
POD=$(grpc_pod)
collect "$POD" "$RUN_DIR/covdata-final"
go tool covdata textfmt -i="$RUN_DIR/covdata-final" -o="$RUN_DIR/it-service.out"
mkdir -p "$OUT_DIR"
python3 "$ROOT/tools/caas-coverage/filter_profile.py" \
  --profile "$RUN_DIR/it-service.out" \
  --output "$OUT_DIR/caas-it-coverage.out" \
  --json "$OUT_DIR/ut-raw/caas-it-summary.json"
go tool cover -html="$OUT_DIR/caas-it-coverage.out" -o "$OUT_DIR/caas-it-coverage.html"
echo "IT coverage artifacts written to $OUT_DIR"
