#!/usr/bin/env bash
# Deploy the current branch code to the osac-dev SNO cluster.
#
# Builds every OSAC-owned component image from this checkout, pushes it to
# the personal quay.io namespace (OSAC_DEV_REGISTRY), and installs or
# upgrades the `osac` Helm release through make install-osac DEV_MODE=1,
# which feeds its resolved deployment settings to Skaffold. This wrapper
# prepares workstation inputs; the installer owns namespace/license Secret
# creation, PostgreSQL checks, chart dependencies and deployment settings.
#
# Usage:
#   REMOTE_HOST=root@host make osac-dev-deploy   # one-shot build + deploy
#   REMOTE_HOST=localhost make osac-dev-deploy   # cluster host is this machine
#   make osac-dev-dev                            # watch mode (skaffold dev)
#
# REMOTE_HOST only selects where the AAP license is read from; unset or
# `localhost` reads it from this machine.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
skaffold_config="$repo/skaffold.yaml"
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$repo/tools/osac-dev/osac-dev-target.sh"
# make osac-dev-setup installs the pinned Helm here; prefer it over a system
# Helm of a different version, as osac-dev.sh already does.
export PATH="$HOME/.local/bin:$PATH"
osac_dev_target_init

DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
OSAC_DEV_KUBECONFIG=${OSAC_DEV_KUBECONFIG:-$HOME/.kube/${DEV_ENV_NAME}-dev.kubeconfig}
OSAC_DEV_REGISTRY=${OSAC_DEV_REGISTRY:-quay.io/rh_ee_rpiccoli}
OSAC_DEV_LICENSE_REMOTE=${OSAC_DEV_LICENSE_REMOTE:-/root/license.zip}
OSAC_DEV_LICENSE_FILE=${OSAC_DEV_LICENSE_FILE:-$repo/osac-installer/values/osac-dev/license.zip}
# make -C changes the working directory; retain the caller's file locations.
[[ "$OSAC_DEV_KUBECONFIG" == /* ]] || OSAC_DEV_KUBECONFIG="$PWD/$OSAC_DEV_KUBECONFIG"
[[ "$OSAC_DEV_LICENSE_FILE" == /* ]] || OSAC_DEV_LICENSE_FILE="$PWD/$OSAC_DEV_LICENSE_FILE"
# The convenience wrapper targets the standard osac instance. Direct
# install-osac DEV_MODE=1 callers can select a different namespace/profile.
namespace=osac
mode=run

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev) mode=dev ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

[[ -f "$skaffold_config" ]] || fail "missing $skaffold_config"

require_local_command() {
    command -v "$1" &>/dev/null || fail "required command '$1' not found in PATH${2:+ ($2)}"
}

require_local_command oc
require_local_command helm
require_local_command skaffold "run 'make osac-dev-setup'"
require_local_command docker "skaffold builds through the docker CLI; run 'make osac-dev-setup' for the docker->podman shim"
require_local_command uv
require_local_command make

# --- kubeconfig ---------------------------------------------------------
[[ -f "$OSAC_DEV_KUBECONFIG" ]] || fail "kubeconfig not found at $OSAC_DEV_KUBECONFIG; run 'make osac-dev-kubeconfig' first"
export KUBECONFIG="$OSAC_DEV_KUBECONFIG"
context=$(oc config current-context) || fail "could not read current context from $OSAC_DEV_KUBECONFIG; is the cluster reachable?"

# --- infrastructure must already be deployed -----------------------------
for release in osac-deps osac-infra; do
    helm status "$release" -n "$release" &>/dev/null || \
        fail "Helm release $release not found; run 'make osac-dev-install-infra' first"
done

# --- AAP license ---------------------------------------------------------
if [[ ! -f "$OSAC_DEV_LICENSE_FILE" ]]; then
    info "fetching AAP license from ${OSAC_DEV_LICENSE_REMOTE} on $OSAC_DEV_TARGET_DESCRIPTION"
    if osac_dev_is_remote; then
        require_local_command scp
    elif [[ ! -r "$OSAC_DEV_LICENSE_REMOTE" ]]; then
        fail "AAP license not found at $OSAC_DEV_LICENSE_FILE and $OSAC_DEV_LICENSE_REMOTE is unreadable on the localhost target; place the file manually or set OSAC_DEV_LICENSE_REMOTE"
    fi
    mkdir -p "$(dirname "$OSAC_DEV_LICENSE_FILE")"
    tmp_license=$(mktemp)
    trap 'rm -f "$tmp_license"' EXIT
    osac_dev_host_copy_from "$OSAC_DEV_LICENSE_REMOTE" "$tmp_license" || \
        fail "could not read the AAP license from $OSAC_DEV_TARGET_DESCRIPTION"
    install -m 0600 "$tmp_license" "$OSAC_DEV_LICENSE_FILE"
    rm -f "$tmp_license"
    trap - EXIT
    info "AAP license saved to $OSAC_DEV_LICENSE_FILE (gitignored)"
fi
[[ "$(stat -c '%a' "$OSAC_DEV_LICENSE_FILE")" == "600" ]] || \
    fail "AAP license at $OSAC_DEV_LICENSE_FILE must have mode 0600"
[[ -s "$OSAC_DEV_LICENSE_FILE" ]] || fail "AAP license at $OSAC_DEV_LICENSE_FILE is empty"

# --- Metal3 Provisioning CR (cluster prerequisite for the osac chart) -----
# The osac chart's pre-install validation requires the BareMetal Operator to
# watch BareMetalHosts in all namespaces. Same cluster-scoped setup the e2e
# workflows apply during their prepare phase (OSAC-4140): virtual-media-only
# Ironic (provisioningNetwork Disabled), preserving BMH bridge addresses, matching
# the netris lab's prep-osac role. Safe to re-apply.
info "ensuring Metal3 Provisioning CR with watchAllNamespaces=true"
"$repo/tools/osac-dev/osac-dev-provisioning.sh"

# --- podman socket for skaffold builds ------------------------------------
if [[ -z "${DOCKER_HOST:-}" ]]; then
    socket="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ -S "$socket" ]]; then
        export DOCKER_HOST="unix://$socket"
    else
        fail "no docker daemon and no podman socket at $socket; start it with: systemctl --user start podman.socket"
    fi
fi

# --- shared installer ----------------------------------------------------
info "running install-osac DEV_MODE=1 (skaffold $mode, registry $OSAC_DEV_REGISTRY, context $context)"
exec make -C "$repo/osac-installer" install-osac \
    PLATFORM=openshift PROFILE=caas-ci NS="$namespace" \
    DEV_MODE=1 SKAFFOLD_MODE="$mode" \
    AAP_LICENSE_FILE="$OSAC_DEV_LICENSE_FILE" \
    OSAC_DEV_REGISTRY="$OSAC_DEV_REGISTRY" \
    EXTRA_HELM_ARGS="-f values/osac-dev/aap-noop-dns.yaml"
