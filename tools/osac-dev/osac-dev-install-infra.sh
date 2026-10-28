#!/usr/bin/env bash
# Connect to the development cluster and install the infrastructure charts.
#
# REMOTE_HOST selects the target: unset or `localhost` runs against the local
# cluster-tool host and keeps its kubeconfig untouched; anything else reaches a
# remote host over root SSH and adapts the API endpoint for this workstation.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$SCRIPT_DIR/osac-dev-target.sh"
# shellcheck source=tools/osac-dev/osac-dev-helm.sh
source "$SCRIPT_DIR/osac-dev-helm.sh"
# The installer Makefile runs Helm; prefer the pinned Helm that
# make osac-dev-setup installs, as osac-dev.sh already does.
export PATH="$HOME/.local/bin:$PATH"
INSTALLER_DIR="$REPO_ROOT/osac-installer"
REMOTE_HOST=${REMOTE_HOST:-}
DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
OSAC_DEV_API_HOST=${OSAC_DEV_API_HOST:-}
OSAC_DEV_LOCAL_API_PORT=${OSAC_DEV_LOCAL_API_PORT:-16443}
DEV_CLUSTER_NAME="${DEV_ENV_NAME}-dev"
OSAC_DEV_KUBECONFIG=${OSAC_DEV_KUBECONFIG:-${HOME}/.kube/${DEV_CLUSTER_NAME}.kubeconfig}
OSAC_DEV_KUBECONFIG_ONLY=${OSAC_DEV_KUBECONFIG_ONLY:-0}
# Verify a restored snapshot without repairing it through a Helm upgrade.
OSAC_DEV_INFRA_CHECK_ONLY=${OSAC_DEV_INFRA_CHECK_ONLY:-0}
# Where cluster-tool keeps the clone kubeconfig on the cluster host.
OSAC_DEV_HOST_KUBECONFIG=${OSAC_DEV_HOST_KUBECONFIG:-}
TEMP_DIR=
KUBECONFIG_FILE=$OSAC_DEV_KUBECONFIG
WORK_KUBECONFIG=
PENDING_KUBECONFIG=
TUNNEL_PID=
CONFIG_CLUSTER_NAME=
API_TLS_NAME=
# NM can back off DHCP for 300s; control-plane recovery follows that retry.
# This also applies to reruns after a previous command restored the listener.
OSAC_DEV_API_RECOVERY_TIMEOUT=${OSAC_DEV_API_RECOVERY_TIMEOUT:-900}
# Operator subscriptions in osac-deps create their CRDs before Helm installs the
# charts that may also declare them, and Helm refuses to create an object that
# already exists without its release ownership metadata. Adopt those objects
# (the same effect as `helm --take-ownership`) and retry so reruns stay
# upgradable.
OSAC_DEV_ADOPT_CRDS=${OSAC_DEV_ADOPT_CRDS:-1}
# Kept after a failed install so the Helm error is still readable.
OSAC_DEV_INSTALL_LOG=${OSAC_DEV_INSTALL_LOG:-${TMPDIR:-/tmp}/osac-dev-install-infra.log}
INFRA_FAILURE=other

fail() {
    printf 'osac-dev-install-infra: %s\n' "$*" >&2
    exit 1
}

info() {
    printf 'osac-dev-install-infra: %s\n' "$*"
}

require_local_command() {
    command -v "$1" >/dev/null 2>&1 || \
        fail "required local command not found: $1; run 'make osac-dev-setup' to install missing prerequisites"
}

validate_inputs() {
    [[ "$DEV_ENV_NAME" =~ ^[a-z0-9]{1,4}$ ]] || \
        fail 'DEV_ENV_NAME must be 1-4 lowercase letters or digits'
    [[ -d "$INSTALLER_DIR/charts/osac-deps" && -d "$INSTALLER_DIR/charts/osac-infra" ]] || \
        fail "installer charts not found under $INSTALLER_DIR"
    [[ -r "$INSTALLER_DIR/values/caas-ci/infra.yaml" && \
       -r "$INSTALLER_DIR/values/osac-dev/infra-cnv.yaml" ]] || \
        fail 'caas-ci base values or osac-dev CNV overlay is missing'
    [[ "$OSAC_DEV_KUBECONFIG" == /* && "$OSAC_DEV_KUBECONFIG" != *:* ]] || \
        fail 'OSAC_DEV_KUBECONFIG must be a single absolute file path'
    [[ "$OSAC_DEV_KUBECONFIG_ONLY" == 0 || "$OSAC_DEV_KUBECONFIG_ONLY" == 1 ]] || \
        fail 'OSAC_DEV_KUBECONFIG_ONLY must be 0 or 1'
    [[ "$OSAC_DEV_INFRA_CHECK_ONLY" == 0 || "$OSAC_DEV_INFRA_CHECK_ONLY" == 1 ]] || \
        fail 'OSAC_DEV_INFRA_CHECK_ONLY must be 0 or 1'
    [[ "$OSAC_DEV_KUBECONFIG_ONLY" != 1 || "$OSAC_DEV_INFRA_CHECK_ONLY" != 1 ]] || \
        fail 'kubeconfig-only and infrastructure check-only modes are mutually exclusive'
    [[ "$OSAC_DEV_API_RECOVERY_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] && \
        ((OSAC_DEV_API_RECOVERY_TIMEOUT <= 3600)) || \
        fail 'OSAC_DEV_API_RECOVERY_TIMEOUT must be 1-3600 seconds'
    [[ "$OSAC_DEV_ADOPT_CRDS" == 0 || "$OSAC_DEV_ADOPT_CRDS" == 1 ]] || \
        fail 'OSAC_DEV_ADOPT_CRDS must be 0 or 1'
    if [[ -n "$OSAC_DEV_HOST_KUBECONFIG" ]]; then
        [[ "$OSAC_DEV_HOST_KUBECONFIG" == /* && "$OSAC_DEV_HOST_KUBECONFIG" != *$'\n'* ]] || \
            fail 'OSAC_DEV_HOST_KUBECONFIG must be a single absolute file path'
    fi
    [[ "$OSAC_DEV_LOCAL_API_PORT" =~ ^[0-9]+$ ]] &&
        ((OSAC_DEV_LOCAL_API_PORT >= 1024 && OSAC_DEV_LOCAL_API_PORT <= 65535)) || \
        fail 'OSAC_DEV_LOCAL_API_PORT must be an integer from 1024 through 65535'
    if osac_dev_is_localhost && [[ -n "$OSAC_DEV_API_HOST" ]]; then
        info 'Ignoring OSAC_DEV_API_HOST: the localhost target uses the cluster-tool kubeconfig unchanged.'
        OSAC_DEV_API_HOST=
    fi
}

require_dependencies() {
    local command
    local -a commands=(oc python3 awk getent mktemp chmod cp mv mkdir dirname)
    if osac_dev_is_remote; then
        commands=(ssh scp "${commands[@]}")
    fi
    for command in "${commands[@]}"; do
        require_local_command "$command"
    done
    if [[ "$OSAC_DEV_KUBECONFIG_ONLY" == 0 ]]; then
        require_local_command helm
        require_local_command make
    fi
}

cleanup() {
    if [[ -n "$TUNNEL_PID" ]]; then
        kill "$TUNNEL_PID" >/dev/null 2>&1 || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
    if [[ -n "$PENDING_KUBECONFIG" ]]; then
        rm -f -- "$PENDING_KUBECONFIG"
    fi
    if [[ -n "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

remote_cluster_row() {
    local output
    output=$(osac_dev_host_run 'export PATH="$HOME/.local/bin:$PATH"; cluster-tool list --server local') || \
        fail "could not list clusters on $OSAC_DEV_TARGET_DESCRIPTION"
    awk -v wanted="$DEV_CLUSTER_NAME" \
        '$1 == wanted { print; found = 1; exit } END { if (!found) exit 1 }' <<< "$output"
}

recover_host_dns() {
    local output
    info 'Checking host DNS/DHCP listeners before requiring the SNO API.'
    output=$(DEV_ENV_NAME="$DEV_ENV_NAME" "$SCRIPT_DIR/osac-dev-dns.sh" --recover) || {
        printf '%s\n' "$output" >&2
        fail 'host DNS/DHCP recovery failed; the Kubernetes API is not required for this repair'
    }
    printf '%s\n' "$output"
    if grep -Eq '^RECOVERED_LISTENERS=[1-9][0-9]*$' <<< "$output"; then
        info "Restored host DNS/DHCP; allowing up to ${OSAC_DEV_API_RECOVERY_TIMEOUT}s for DHCP retry and control-plane/API recovery."
    fi
}

fetch_kubeconfig() {
    local remote_path=${OSAC_DEV_HOST_KUBECONFIG:-/root/.kube/${DEV_CLUSTER_NAME}.kubeconfig}
    local attempt
    umask 077
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/osac-dev-infra.XXXXXX") || fail 'could not create a temporary directory'
    chmod 700 "$TEMP_DIR"
    WORK_KUBECONFIG="$TEMP_DIR/${DEV_CLUSTER_NAME}.kubeconfig"

    for ((attempt = 1; attempt <= 6; attempt++)); do
        if osac_dev_host_copy_from "$remote_path" "$WORK_KUBECONFIG"; then
            break
        fi
        if ((attempt == 6)); then
            fail "could not fetch the kubeconfig for '$DEV_CLUSTER_NAME' from $OSAC_DEV_TARGET_DESCRIPTION"
        fi
        sleep 5
    done
    chmod 600 "$WORK_KUBECONFIG" || fail 'could not restrict permissions on the temporary kubeconfig'
    export KUBECONFIG="$WORK_KUBECONFIG"
}

inspect_kubeconfig() {
    local config_json
    config_json=$(oc config view --minify -o json --kubeconfig="$WORK_KUBECONFIG") || \
        fail 'could not inspect the fetched kubeconfig'

    CONFIG_CLUSTER_NAME=$(python3 -c '
import json, sys
config = json.load(sys.stdin)
clusters = config.get("clusters", [])
if len(clusters) != 1 or not clusters[0].get("name"):
    raise SystemExit("expected one current kubeconfig cluster")
print(clusters[0]["name"])
' <<< "$config_json") || fail 'could not find the current kubeconfig cluster'
    API_TLS_NAME=$(python3 -c '
import json, sys
from urllib.parse import urlparse
config = json.load(sys.stdin)
clusters = config.get("clusters", [])
if len(clusters) != 1:
    raise SystemExit("expected one current kubeconfig cluster")
host = urlparse(clusters[0].get("cluster", {}).get("server", "")).hostname
if not host:
    raise SystemExit("current kubeconfig cluster has no API server hostname")
print(host)
' <<< "$config_json") || fail 'could not determine the API TLS server name from the kubeconfig'
}

api_host_for_workstation() {
    local ssh_hostname resolved
    if [[ -n "$OSAC_DEV_API_HOST" ]]; then
        printf '%s\n' "$OSAC_DEV_API_HOST"
        return 0
    fi

    ssh_hostname=$(osac_dev_host_address)
    resolved=$(getent ahostsv4 "$ssh_hostname" 2>/dev/null | awk 'NR == 1 { print $1; exit }') || true
    if [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
    else
        printf '%s\n' "$ssh_hostname"
    fi
}

format_url_host() {
    local host=$1
    case "$host" in
        \[*\]) printf '%s\n' "$host" ;;
        *:*) printf '[%s]\n' "$host" ;;
        *) printf '%s\n' "$host" ;;
    esac
}

set_api_endpoint() {
    local api_host=$1
    local api_port=$2
    local url_host
    url_host=$(format_url_host "$api_host")
    oc config set-cluster "$CONFIG_CLUSTER_NAME" \
        --server="https://${url_host}:${api_port}" \
        --tls-server-name="$API_TLS_NAME" \
        --kubeconfig="$WORK_KUBECONFIG" >/dev/null || \
        fail 'could not set the workstation API endpoint in the temporary kubeconfig'
}

api_ready() {
    oc get --raw=/readyz --request-timeout=8s --kubeconfig="$WORK_KUBECONFIG" >/dev/null 2>&1
}

start_ssh_tunnel() {
    local local_endpoint="127.0.0.1:${OSAC_DEV_LOCAL_API_PORT}:127.0.0.1:6443"
    info "Direct API access failed; opening an SSH tunnel on 127.0.0.1:${OSAC_DEV_LOCAL_API_PORT}."
    TUNNEL_PID=$(osac_dev_host_open_tunnel "$local_endpoint" "$TEMP_DIR/ssh-tunnel.log") || \
        fail 'could not start the SSH tunnel'
    set_api_endpoint 127.0.0.1 "$OSAC_DEV_LOCAL_API_PORT"

    local started=$SECONDS deadline next_report
    deadline=$((started + OSAC_DEV_API_RECOVERY_TIMEOUT))
    next_report=$((started + 30))
    while ((SECONDS < deadline)); do
        if api_ready; then
            info "API is reachable through the SSH tunnel; TLS server name is $API_TLS_NAME."
            return 0
        fi
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
            break
        fi
        if ((SECONDS >= next_report && SECONDS < deadline)); then
            info "Still waiting for SNO API: $((SECONDS - started))s elapsed, $((deadline - SECONDS))s remaining (DHCP/control-plane recovery may still be in progress)."
            next_report=$((SECONDS + 30))
        fi
        sleep 1
    done
    if [[ -s "$TEMP_DIR/ssh-tunnel.log" ]]; then
        cat "$TEMP_DIR/ssh-tunnel.log" >&2
    fi
    fail "API was not reachable through the SSH tunnel after $((SECONDS - started))s (configured wait ${OSAC_DEV_API_RECOVERY_TIMEOUT}s); inspect SNO DHCP and control-plane readiness"
}

configure_workstation_api_access() {
    local api_host

    if osac_dev_is_localhost; then
        # The cluster-tool kubeconfig already names an endpoint this host can
        # reach, so there is nothing to rewrite and no tunnel to open.
        if api_ready; then
            info "API is reachable from this host; TLS server name is $API_TLS_NAME."
            return 0
        fi
        fail "the Kubernetes API is not reachable from this host (TLS server name $API_TLS_NAME); check that 'cluster-tool setup client' ran and that the host DNS listener answers for the cluster domain (make osac-dev-dns), then retry"
    fi

    api_host=$(api_host_for_workstation)
    set_api_endpoint "$api_host" 6443
    if api_ready; then
        info "API is reachable at ${api_host}:6443; TLS server name is $API_TLS_NAME."
        return 0
    fi
    start_ssh_tunnel
}

persist_kubeconfig() {
    local destination_dir
    destination_dir=$(dirname -- "$KUBECONFIG_FILE")
    mkdir -p "$destination_dir"
    if [[ "$destination_dir" == "$HOME/.kube" ]]; then
        chmod 700 "$destination_dir"
    fi

    PENDING_KUBECONFIG="${KUBECONFIG_FILE}.tmp.$$"
    cp -- "$WORK_KUBECONFIG" "$PENDING_KUBECONFIG" || fail 'could not stage the local kubeconfig'
    chmod 600 "$PENDING_KUBECONFIG" || fail 'could not restrict permissions on the local kubeconfig'
    mv -f -- "$PENDING_KUBECONFIG" "$KUBECONFIG_FILE" || fail 'could not save the local kubeconfig'
    PENDING_KUBECONFIG=
    export KUBECONFIG="$KUBECONFIG_FILE"
    info "Saved local kubeconfig: $KUBECONFIG_FILE"
}

chart_version() {
    local chart=$1
    local version
    version=$(awk '$1 == "version:" { print $2; exit }' \
        "$INSTALLER_DIR/charts/$chart/Chart.yaml")
    [[ -n "$version" ]] || fail "could not read the chart version for $chart"
    printf '%s\n' "$version"
}

release_state() {
    local namespace=$1
    local release=$2
    local json
    json=$(osac_dev_helm_list_all --namespace "$namespace" --output json) || return 1
    python3 -c '
import json, sys
name = sys.argv[1]
for release in json.load(sys.stdin):
    if release.get("name") == name:
        print("{}|{}".format(release.get("chart", ""), release.get("status", "")))
        break
else:
    print("|")
' "$release" <<< "$json"
}

check_release() {
    local namespace=$1
    local release=$2
    local expected_version=$3
    local info chart status expected_chart
    info=$(release_state "$namespace" "$release") || {
        info "$release: Helm could not list releases in namespace $namespace"
        return 1
    }
    IFS='|' read -r chart status <<< "$info"
    expected_chart="${release}-${expected_version}"
    if [[ "$chart" == "$expected_chart" && "$status" == deployed ]]; then
        info "$release: $chart is deployed"
        return 0
    fi
    info "$release: found ${chart:-no release} (status ${status:-missing}); expected $expected_chart deployed"
    return 1
}

check_helm_releases() {
    local deps_version infra_version status=0
    deps_version=$(chart_version osac-deps)
    infra_version=$(chart_version osac-infra)
    check_release osac-deps osac-deps "$deps_version" || status=1
    check_release osac-infra osac-infra "$infra_version" || status=1
    return "$status"
}

check_cnv_readiness() {
    local subscription_json channel current_csv csv_phase hco_available
    subscription_json=$(oc get subscription kubevirt-hyperconverged -n openshift-cnv -o json 2>/dev/null) || {
        info 'CNV: kubevirt-hyperconverged Subscription is missing'
        return 1
    }
    readarray -t subscription_values < <(python3 -c '
import json, sys
subscription = json.load(sys.stdin)
print(subscription.get("spec", {}).get("channel", ""))
status = subscription.get("status", {})
print(status.get("currentCSV") or status.get("installedCSV") or "")
' <<< "$subscription_json")
    channel=${subscription_values[0]:-}
    current_csv=${subscription_values[1]:-}
    if [[ "$channel" != stable || -z "$current_csv" ]]; then
        info "CNV: expected channel stable and a current CSV; found channel '${channel:-missing}', CSV '${current_csv:-missing}'"
        return 1
    fi
    csv_phase=$(oc get csv "$current_csv" -n openshift-cnv \
        -o jsonpath='{.status.phase}' 2>/dev/null) || csv_phase=
    if [[ "$csv_phase" != Succeeded ]]; then
        info "CNV: current CSV $current_csv is ${csv_phase:-unavailable}, not Succeeded"
        return 1
    fi
    hco_available=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || hco_available=
    if [[ "$hco_available" != True ]]; then
        info "CNV: HyperConverged is ${hco_available:-unavailable}, not Available"
        return 1
    fi
    info "CNV: channel $channel, CSV $current_csv Succeeded, HyperConverged Available"
}

# Print "kind|name|namespace|release|namespace" for each object Helm refused
# to import because another controller created it first.
helm_ownership_conflicts() {
    python3 -c '
import re, sys

seen = set()
conflict = re.compile(
    r"(?P<kind>[A-Z][A-Za-z0-9]*)[ ]+\"(?P<name>[^\"]+)\"[ ]+in namespace \"(?P<namespace>[^\"]*)\""
    r" exists and cannot be imported into the current release"
)
for line in sys.stdin:
    match = conflict.search(line)
    if not match:
        continue
    release = re.search(r"\"meta[.]helm[.]sh/release-name\": must be set to \"([^\"]+)\"", line)
    namespace = re.search(r"\"meta[.]helm[.]sh/release-namespace\": must be set to \"([^\"]+)\"", line)
    if not release or not namespace:
        continue
    key = (match.group("kind"), match.group("name"))
    if key in seen:
        continue
    seen.add(key)
    print("{}|{}|{}|{}|{}".format(
        key[0], key[1], match.group("namespace"), release.group(1), namespace.group(1)))
'
}

# oc accepts the lowercase kind, but `crd` stays readable in the log.
conflict_resource() {
    case "$1" in
        CustomResourceDefinition) printf 'crd' ;;
        *) printf '%s' "${1,,}" ;;
    esac
}

adopt_conflicts() {
    local kind name namespace release release_ns resource adopted=0
    local -a scope
    while IFS='|' read -r kind name namespace release release_ns; do
        [[ -n "$kind" ]] || continue
        resource=$(conflict_resource "$kind")
        scope=()
        [[ -z "$namespace" ]] || scope=(-n "$namespace")
        info "adopting $kind $name into Helm release $release (namespace $release_ns)"
        oc label "$resource" "$name" "${scope[@]}" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null || {
            info "could not label $kind $name; leaving it untouched"
            return 1
        }
        oc annotate "$resource" "$name" "${scope[@]}" \
            "meta.helm.sh/release-name=$release" \
            "meta.helm.sh/release-namespace=$release_ns" --overwrite >/dev/null || {
            info "could not annotate $kind $name; leaving it untouched"
            return 1
        }
        adopted=$((adopted + 1))
    done
    ((adopted > 0))
}

# Helm validates ownership before it writes anything, so a retry after adopting
# the conflicting objects is safe and costs one render pass.
run_install_infra() {
    local attempt conflicts
    INFRA_FAILURE=other
    for attempt in 1 2 3; do
        if make -C "$INSTALLER_DIR" install-infra \
            PLATFORM=openshift PROFILE=caas-ci NS=osac \
            INFRA_VALUES_EXTRA='-f values/osac-dev/infra-cnv.yaml' 2>&1 | tee "$OSAC_DEV_INSTALL_LOG"; then
            return 0
        fi
        if [[ "$OSAC_DEV_ADOPT_CRDS" != 1 ]]; then
            INFRA_FAILURE=disabled
            return 1
        fi
        if ! conflicts=$(helm_ownership_conflicts < "$OSAC_DEV_INSTALL_LOG"); then
            return 1
        fi
        if [[ -z "$conflicts" ]]; then
            INFRA_FAILURE=other
            return 1
        fi
        if ! adopt_conflicts <<< "$conflicts"; then
            INFRA_FAILURE=adoption-failed
            return 1
        fi
        INFRA_FAILURE=still-failing
        info 'retrying the install-infra target after adopting the conflicting objects'
    done
    return 1
}

# Distinguish the reasons, so a Helm failure that has nothing to do with
# ownership does not send the reader after CRD labels.
report_install_failure() {
    local message line
    case "$INFRA_FAILURE" in
        disabled)
            message='another controller owns a cluster-scoped object that the chart also declares; set OSAC_DEV_ADOPT_CRDS=1 to adopt it, or run oc label <kind> <name> app.kubernetes.io/managed-by=Helm --overwrite plus the meta.helm.sh/release-name and release-namespace annotations'
            ;;
        adoption-failed)
            message='a conflicting object could not be labelled or annotated; see the messages above'
            ;;
        still-failing)
            message='the install failed again after adopting every reported conflict; see the Helm error above'
            ;;
        *)
            message='the install failed for a reason that is not a Helm ownership conflict; the Helm error is above, not a CRD adoption problem'
            ;;
    esac
    if [[ -s $OSAC_DEV_INSTALL_LOG ]]; then
        info 'last errors from the install-infra log:'
        while IFS= read -r line; do
            printf '  %s\n' "$line"
        done < <(grep -E '^(Error|error):' "$OSAC_DEV_INSTALL_LOG" | tail -n 5 || true)
    fi
    info "full install-infra log: $OSAC_DEV_INSTALL_LOG"
    fail "infrastructure install-infra target failed: $message"
}

install_or_skip_infra() {
    local needs_install=0
    check_helm_releases || needs_install=1
    check_cnv_readiness || needs_install=1

    if ((needs_install)); then
        info 'Installing/updating osac-deps and osac-infra with CNV enabled; the osac platform chart is not installed.'
        if ! run_install_infra; then
            report_install_failure
        fi
    else
        info 'Helm chart versions and CNV readiness already match; skipping upgrades.'
    fi

    if ! check_helm_releases || ! check_cnv_readiness; then
        fail 'post-install verification failed; inspect the Helm releases and CNV operator state'
    fi
}

main() {
    local cluster_row cluster_flavor
    osac_dev_target_init
    validate_inputs
    require_dependencies
    osac_dev_require_root
    cluster_row=$(remote_cluster_row) || \
        fail "cluster $DEV_CLUSTER_NAME was not found on $OSAC_DEV_TARGET_DESCRIPTION; this installer never provisions clusters"
    cluster_flavor=$(awk '{ print $2; exit }' <<< "$cluster_row")
    info "Reusing existing cluster $DEV_CLUSTER_NAME (flavor ${cluster_flavor:-unknown})."

    recover_host_dns
    fetch_kubeconfig
    inspect_kubeconfig
    configure_workstation_api_access
    persist_kubeconfig
    if [[ "$OSAC_DEV_KUBECONFIG_ONLY" == 1 ]]; then
        info "Kubeconfig ready; use: export KUBECONFIG='$KUBECONFIG_FILE'"
        return 0
    fi
    if [[ "$OSAC_DEV_INFRA_CHECK_ONLY" == 1 ]]; then
        if ! check_helm_releases || ! check_cnv_readiness; then
            fail 'infrastructure verification failed; no upgrade attempted'
        fi
        info 'Infrastructure verified; no upgrade attempted.'
        return 0
    fi
    install_or_skip_infra
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
main "$@"
