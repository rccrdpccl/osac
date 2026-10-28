#!/usr/bin/env bash
# Gather all first-run inputs before running any mutating stage.
#
# The target comes from REMOTE_HOST: unset or `localhost` runs the privileged
# host work on this machine, anything else drives a remote cluster-tool host.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$script_dir/../.." && pwd)
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$script_dir/osac-dev-target.sh"
fail() { printf 'osac-dev: %s\n' "$*" >&2; exit 1; }
request() {
    local name=$1 description=$2 value
    if [[ -z "${!name:-}" ]]; then
        [[ -t 0 ]] || fail "$name is required ($description); export it before running make osac-dev"
        read -r -p "$name ($description): " value || fail "could not read $name"
        [[ -n "$value" ]] || fail "$name must not be empty"
        printf -v "$name" '%s' "$value"
    fi
    export "${name?}"
}
[[ $# == 0 || ( $# == 1 && $1 == --check ) ]] || fail 'usage: osac-dev-workflow.sh [--check]'
osac_dev_target_init
request PULL_SECRET_FILE 'absolute local path to OpenShift pull-secret JSON (required even for reuse)'
request OSAC_DEV_REGISTRY 'writable registry namespace, e.g. quay.io/your-user; log in with docker first'
export OSAC_DEV_KUBECONFIG_ONLY=0
export DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
export OSAC_DEV_KUBECONFIG=${OSAC_DEV_KUBECONFIG:-$HOME/.kube/${DEV_ENV_NAME}-dev.kubeconfig}
export OSAC_DEV_LICENSE_FILE=${OSAC_DEV_LICENSE_FILE:-$repo/osac-installer/values/osac-dev/license.zip}
[[ "$DEV_ENV_NAME" =~ ^[a-z0-9]{1,4}$ ]] || fail 'DEV_ENV_NAME must be 1-4 lowercase letters or digits'
[[ "$OSAC_DEV_KUBECONFIG" == /* && "$OSAC_DEV_KUBECONFIG" != *:* ]] || fail 'OSAC_DEV_KUBECONFIG must be a single absolute path'
[[ "$PULL_SECRET_FILE" == /* && -r "$PULL_SECRET_FILE" && -s "$PULL_SECRET_FILE" ]] || fail 'PULL_SECRET_FILE must be an absolute readable nonempty local file'
[[ "${CLUSTER_TOOL_DATA_PATH:-/data/cluster-tool}" == /* ]] || fail 'CLUSTER_TOOL_DATA_PATH must be absolute'
[[ "${SNO_FLAVOR:-sno-4-22}" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || fail 'SNO_FLAVOR contains unsupported characters'
[[ -z "${OSAC_DEV_BMH_NODE_NIC:-}" || "$OSAC_DEV_BMH_NODE_NIC" =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail 'OSAC_DEV_BMH_NODE_NIC contains unsupported characters'
[[ "$OSAC_DEV_REGISTRY" =~ ^[a-zA-Z0-9.-]+(/[a-zA-Z0-9_.-]+)+$ ]] || fail 'OSAC_DEV_REGISTRY must be a registry/namespace without a URL scheme'
port=${OSAC_DEV_LOCAL_API_PORT:-16443}
[[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1024 && 10#$port <= 65535)) || fail 'OSAC_DEV_LOCAL_API_PORT must be 1024-65535'
api_timeout=${OSAC_DEV_API_RECOVERY_TIMEOUT:-900}
[[ "$api_timeout" =~ ^[1-9][0-9]{0,3}$ ]] && ((api_timeout <= 3600)) || fail 'OSAC_DEV_API_RECOVERY_TIMEOUT must be 1-3600 seconds'
count=${OSAC_DEV_BMH_COUNT:-2}
[[ "$count" =~ ^[1-9][0-9]?$ ]] && ((10#$count >= 1 && 10#$count <= 15)) || fail 'OSAC_DEV_BMH_COUNT must be 1-15'
for name in OSAC_DEV_BMH_ATTEMPTS OSAC_DEV_BMH_TIMEOUT_MIN; do
    [[ "${!name:-1}" =~ ^[1-9][0-9]*$ ]] || fail "$name must be positive"
done
# ssh/scp are only needed when the cluster host is a different machine.
local_commands=(oc helm skaffold docker uv python3 awk getent make)
if osac_dev_is_remote; then
    local_commands=(ssh scp "${local_commands[@]}")
fi
for command in "${local_commands[@]}"; do
    command -v "$command" >/dev/null || \
        fail "required local command not found: $command; run 'make osac-dev-setup' to install missing prerequisites"
done
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("auths"), dict) and d["auths"], "pull secret must contain nonempty auths"' "$PULL_SECRET_FILE" || fail 'invalid OpenShift pull-secret JSON'
if [[ -z "${DOCKER_HOST:-}" ]]; then
    socket=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock
    [[ -S "$socket" ]] || fail 'set DOCKER_HOST or start systemctl --user start podman.socket'
    export DOCKER_HOST="unix://$socket"
fi
docker info >/dev/null || fail 'container build daemon is not available'
# Read-only host checks. Never install packages or copy credentials here.
osac_dev_require_transport
osac_dev_require_root
if [[ -f "$OSAC_DEV_LICENSE_FILE" ]]; then
    [[ -r "$OSAC_DEV_LICENSE_FILE" && -s "$OSAC_DEV_LICENSE_FILE" && "$(stat -c %a "$OSAC_DEV_LICENSE_FILE")" == 600 ]] || fail 'OSAC_DEV_LICENSE_FILE must be readable, nonempty and mode 0600'
else
    if osac_dev_is_localhost && [[ -z ${OSAC_DEV_LICENSE_REMOTE:-} && -r /root/license.zip && -s /root/license.zip ]]; then
        OSAC_DEV_LICENSE_REMOTE=/root/license.zip
    fi
    request OSAC_DEV_LICENSE_REMOTE 'absolute AAP license path on the cluster host, e.g. /root/license.zip'
    [[ "$OSAC_DEV_LICENSE_REMOTE" == /* ]] || fail 'OSAC_DEV_LICENSE_REMOTE must be absolute'
    printf -v license_check 'test -r %q && test -s %q' "$OSAC_DEV_LICENSE_REMOTE" "$OSAC_DEV_LICENSE_REMOTE"
    osac_dev_host_run "$license_check" || \
        fail "AAP license is missing, empty or unreadable on $OSAC_DEV_TARGET_DESCRIPTION"
fi
printf 'Preflight passed for the %s target. Registry login/push permissions, host capacity, DNS, and cluster readiness are still runtime prerequisites.\n' \
    "$OSAC_DEV_TARGET"
[[ ${1:-} != --check ]] || exit 0
for stage in cluster grow-storage install-infra bmh deploy dns; do
    printf '\n==> osac-dev-%s\n' "$stage"
    case "$stage" in
        cluster)
            "$script_dir/osac-dev-bootstrap.sh" up
            OSAC_DEV_KUBECONFIG_ONLY=1 "$script_dir/osac-dev-install-infra.sh"
            ;;
        *) "$script_dir/osac-dev-$stage.sh" ;;
    esac
done
