#!/usr/bin/env bash
# Run selected e2e suites from tests/e2e against the osac-dev environment.
#
# Wraps the repository's pytest suites so they target the platform deployed
# by `make osac-dev-deploy`: it builds the osac CLI from this checkout,
# auto-installs a pinned grpcurl when missing, and on a remote target — when
# the cluster's route names do not resolve on this workstation — runs pytest
# inside an unprivileged user+mount namespace with those names bind-mounted
# over /etc/hosts (pointing at the kubeconfig's API host, which forwards TCP
# 443 to the cluster router). It exports the e2e environment (KUBECONFIG,
# OSAC_NAMESPACE, OSAC_CLI_PATH, and METERING_ADAPTER_URL for metering-marked
# suites) and runs pytest serially from the repository root.
#
# REMOTE_HOST selects the target: unset or `localhost` runs everything on this
# machine, where the lab's own DNS and network already reach the routes and
# the hosted cluster VIPs.
#
# Usage:
#   make osac-dev-e2e TESTS="tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py"
#
# TESTS accepts space-separated test paths plus extra pytest arguments
# (e.g. "...::test_baremetal_instance_lifecycle -k lifecycle"); everything is
# passed to `uv run pytest -n 0` verbatim. BMaaS suites additionally require
# virtual hosts from `make osac-dev-bmh`; see tools/osac-dev/README.md.
#
# CaaS suites connect to the hosted clusters' API servers (MetalLB VIPs on
# the cluster's primary lab network). On a remote target, set
# OSAC_DEV_E2E_SSH_HOST (user@host with working SSH auth, typically the same
# REMOTE_HOST as the cluster) to route those connections through a SOCKS proxy
# opened over SSH; the hub API and the cluster routes stay direct.
# OSAC_DEV_E2E_SOCKS_PORT overrides the proxy port (default 1080). The same SSH
# host must run /usr/local/sbin/osac-dev-dns: hosted cluster DNS is maintained
# independently by the provisioning-installed host timer. The localhost target
# reaches those VIPs directly, so it needs no SSH hop and no proxy.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$repo/tools/osac-dev/osac-dev-target.sh"

DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
OSAC_DEV_KUBECONFIG=${OSAC_DEV_KUBECONFIG:-$HOME/.kube/${DEV_ENV_NAME}-dev.kubeconfig}
[[ "$DEV_ENV_NAME" =~ ^[a-z0-9]{1,4}$ ]] || { printf 'invalid DEV_ENV_NAME\n' >&2; exit 1; }
GRPCURL_VERSION=1.9.1
GRPCURL_TARBALL="grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

osac_dev_target_init
if osac_dev_is_localhost; then
    if [[ -n "${OSAC_DEV_E2E_SSH_HOST:-}" ]]; then
        info "ignoring OSAC_DEV_E2E_SSH_HOST=$OSAC_DEV_E2E_SSH_HOST on the localhost target; hosted-cluster APIs are reached directly"
        OSAC_DEV_E2E_SSH_HOST=
    fi
elif [[ ! -v OSAC_DEV_E2E_SSH_HOST ]]; then
    # Remote targets keep the historical default: route hosted traffic through
    # the same host. An explicitly empty value disables the SOCKS hop.
    OSAC_DEV_E2E_SSH_HOST=$REMOTE_HOST
fi

[[ $# -ge 1 ]] || fail "no test paths given; usage: make osac-dev-e2e TESTS=\"tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py\" (space-separated paths and extra pytest arguments are passed through)"

require_local_command() {
    command -v "$1" &>/dev/null || fail "required command '$1' not found in PATH${2:+ ($2)}"
}

require_local_command oc
require_local_command kubectl
require_local_command uv
require_local_command go
require_local_command curl
require_local_command helm
for arg in "$@"; do
    if [[ "$arg" == *caas* || "$arg" == tests/e2e || "$arg" == tests/e2e/ ]]; then
        # The localhost target reaches the hosted VIPs directly.
        osac_dev_is_localhost || [[ -n "$OSAC_DEV_E2E_SSH_HOST" ]] || \
            fail 'CaaS tests require REMOTE_HOST (or OSAC_DEV_E2E_SSH_HOST) for hosted API access'
    fi
done

# --- kubeconfig ---------------------------------------------------------------
[[ -f "$OSAC_DEV_KUBECONFIG" ]] || \
    fail "kubeconfig not found at $OSAC_DEV_KUBECONFIG; run 'make osac-dev-kubeconfig' first"
export KUBECONFIG="$OSAC_DEV_KUBECONFIG"

OSAC_NAMESPACE=${OSAC_NAMESPACE:-osac}

# --- the platform must be deployed --------------------------------------------
helm status osac -n "$OSAC_NAMESPACE" &>/dev/null || \
    fail "the osac platform release was not found in namespace $OSAC_NAMESPACE; run 'make osac-dev-deploy' first"

cli_dir=$(mktemp -d)
grpcurl_archive=
hosts_file=
ssh_tunnel_pid=
cleanup() {
    rm -rf -- "$cli_dir"
    if [[ -n "$grpcurl_archive" ]]; then
        rm -f -- "$grpcurl_archive"
    fi
    if [[ -n "$ssh_tunnel_pid" ]]; then
        kill "$ssh_tunnel_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- grpcurl (used by the e2e gRPC client) -------------------------------------
if ! command -v grpcurl &>/dev/null; then
    info "installing grpcurl ${GRPCURL_VERSION} into ~/.local/bin"
    install_dir="$HOME/.local/bin"
    mkdir -p "$install_dir"
    grpcurl_archive=$(mktemp)
    curl --retry 5 --retry-delay 2 -fsSL -o "$grpcurl_archive" \
        "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/${GRPCURL_TARBALL}"
    # grpcurl publishes one combined checksums.txt per release; verify the
    # matching line against the downloaded archive (same procedure as the
    # osac-test-infra install-grpcurl action).
    curl --retry 5 --retry-delay 2 -fsSL \
        "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_checksums.txt" \
        | grep " ${GRPCURL_TARBALL}\$" \
        | sed "s|${GRPCURL_TARBALL}|$grpcurl_archive|" \
        | sha256sum -c -
    tar xz -C "$install_dir" grpcurl -f "$grpcurl_archive"
    rm -f -- "$grpcurl_archive"
    grpcurl_archive=
fi
export PATH="$HOME/.local/bin:$PATH"

# --- osac CLI from this checkout -----------------------------------------------
info "building the osac CLI from the checkout"
(cd "$repo/fulfillment-service" && go build -o "$cli_dir/osac" ./cmd/osac)
export OSAC_CLI_PATH="$cli_dir/osac"

# --- route reachability ---------------------------------------------------------
# The e2e fixtures reach the platform through the cluster's routes
# (fulfillment external/internal API, Keycloak, and the metering echo
# adapter). When those names do not resolve on this workstation, pytest runs
# inside an unprivileged user+mount
# namespace with a merged /etc/hosts bind-mounted over the system one — the
# kubeconfig's API host (which forwards TCP 443 to the cluster router with
# SNI preserved) is added for each unresolved route name. This covers every
# client, including grpcurl, which ignores HTTP/SOCKS proxy environment
# variables. No root and no system-wide /etc/hosts changes are involved; if
# unprivileged user namespaces are unavailable, the wrapper prints
# ready-to-paste /etc/hosts lines instead.
domain=$(kubectl get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')
[[ -n "$domain" ]] || fail "could not determine the cluster domain; is the cluster reachable?"

fulfillment_host="fulfillment-api-${OSAC_NAMESPACE}.${domain}"
internal_host="fulfillment-internal-api-${OSAC_NAMESPACE}.${domain}"
keycloak_host="keycloak-keycloak.${domain}"
metering_host="osac-metering-echo-adapter-${OSAC_NAMESPACE}.${domain}"

# Metering-marked suites (the CaaS sanity lifecycle) verify lifecycle events
# through the metering echo adapter's HTTP API; default the URL to the
# deployed route when the caller did not set one, and only then require the
# route to be reachable.
route_hosts=("$fulfillment_host" "$internal_host" "$keycloak_host")
if [[ -z "${METERING_ADAPTER_URL:-}" ]]; then
    export METERING_ADAPTER_URL="https://$metering_host"
    info "METERING_ADAPTER_URL defaulted to $METERING_ADAPTER_URL"
    route_hosts+=("$metering_host")
    # The route is edge-terminated with the cluster's self-signed ingress
    # certificate, which the metering collector's urllib verifies against
    # the default trust store. Export a merged CA bundle (system CAs plus
    # the cluster ingress CA) so event fetches verify without disabling
    # TLS checking.
    ingress_ca="$cli_dir/ingress-ca.pem"
    if oc get secret router-certs-default -n openshift-ingress \
            -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$ingress_ca" \
            && [[ -s "$ingress_ca" ]]; then
        ssl_bundle="$cli_dir/ssl-bundle.pem"
        : > "$ssl_bundle"
        for sys_ca in /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
            if [[ -r "$sys_ca" ]]; then
                cat "$sys_ca" >> "$ssl_bundle"
                break
            fi
        done
        cat "$ingress_ca" >> "$ssl_bundle"
        export SSL_CERT_FILE="$ssl_bundle"
        info "SSL_CERT_FILE set to a CA bundle including the cluster ingress CA"
    else
        info "warning: could not fetch the cluster ingress CA; metering event fetches may fail TLS verification" >&2
    fi
fi

missing_hosts=()
for host in "${route_hosts[@]}"; do
    getent hosts "$host" >/dev/null 2>&1 || missing_hosts+=("$host")
done

if ((${#missing_hosts[@]})); then
    if osac_dev_is_localhost; then
        {
            printf 'The cluster routes do not resolve on the localhost target: %s\n' "${missing_hosts[*]}"
            printf 'This host owns the lab DNS; rerun make osac-dev-dns and check the osac-dev-dns-%s-dev.timer unit.\n' "$DEV_ENV_NAME"
        } >&2
        exit 1
    fi
    api_host=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's|^[a-zA-Z]+://([^:/]+).*|\1|')
    [[ -n "$api_host" ]] || fail "could not determine the API host from the kubeconfig"
    code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' --resolve "$fulfillment_host:443:$api_host" "https://$fulfillment_host/")
    if [[ "$code" == "000" ]]; then
        fail "the cluster routes do not resolve, and the router is not reachable at $api_host:443 (curl code $code); fix network access to the cluster first"
    fi
    hosts_file="$cli_dir/hosts"
    cat /etc/hosts > "$hosts_file"
    for host in "${missing_hosts[@]}"; do
        printf '%s %s\n' "$api_host" "$host" >> "$hosts_file"
    done
    if command -v unshare >/dev/null 2>&1 && unshare --user --map-root-user --mount true 2>/dev/null; then
        info "route names do not resolve locally; pytest will run in a private mount namespace with them mapped to $api_host"
    else
        {
            printf 'The cluster routes do not resolve from this workstation, unprivileged user namespaces are unavailable, and the router is reachable at %s:443.\n' "$api_host"
            printf 'Add these lines to /etc/hosts and rerun:\n'
            for host in "${missing_hosts[@]}"; do
                printf '  %s %s\n' "$api_host" "$host"
            done
        } >&2
        exit 1
    fi
fi

# --- hosted-cluster API access (SOCKS tunnel) ----------------------------------
# The CaaS suites connect to the hosted clusters' API servers
# (api.<order>.hosted.<domain>:6443 — MetalLB VIPs on the cluster's primary
# lab network). Those VIPs are reachable from the remote lab host but not
# from this workstation. When OSAC_DEV_E2E_SSH_HOST is set (user@host with
# working SSH auth), open a background SOCKS proxy over SSH and send the
# guest-cluster connections through it; the hub API and the known cluster
# routes stay direct through NO_PROXY. A localhost target owns those VIPs and
# needs neither the timer check over SSH nor the proxy.
dns_unit="osac-dev-dns-${DEV_ENV_NAME}-dev"
if osac_dev_is_localhost; then
    osac_dev_host_run "systemctl is-active --quiet ${dns_unit}.timer && systemctl start ${dns_unit}.service" || \
        fail 'persistent lab DNS is not ready; run make osac-dev-dns'
fi
if [[ -n "${OSAC_DEV_E2E_SSH_HOST:-}" ]]; then
    require_local_command ssh
    osac_dev_host_run_on "$OSAC_DEV_E2E_SSH_HOST" \
        "systemctl is-active --quiet ${dns_unit}.timer && systemctl start ${dns_unit}.service" || \
        fail 'persistent lab DNS is not ready; run REMOTE_HOST=root@host make osac-dev-dns'
    socks_port=${OSAC_DEV_E2E_SOCKS_PORT:-1080}
    hub_api_host=$(oc config view --minify -o jsonpath='{.clusters[0].cluster.server}' \
        | sed -E 's|^[a-zA-Z]+://([^:/]+).*|\1|')
    info "opening a SOCKS proxy on 127.0.0.1:$socks_port through $OSAC_DEV_E2E_SSH_HOST for hosted-cluster API access"
    ssh_tunnel_pid=$(osac_dev_host_open_socks "$socks_port" "$cli_dir/socks.log" "$OSAC_DEV_E2E_SSH_HOST")
    sleep 2
    kill -0 "$ssh_tunnel_pid" 2>/dev/null || \
        fail "the SSH SOCKS proxy did not start; check SSH access to $OSAC_DEV_E2E_SSH_HOST"
    export HTTPS_PROXY="socks5://127.0.0.1:$socks_port"
    export https_proxy="$HTTPS_PROXY"
    no_proxy_values="localhost,127.0.0.1,${hub_api_host},$fulfillment_host,$internal_host,$keycloak_host"
    [[ -z "${METERING_ADAPTER_URL:-}" ]] || no_proxy_values+=",$metering_host"
    export NO_PROXY="$no_proxy_values"
    export no_proxy="$no_proxy_values"

    # Hosted DNS persists after pytest exits and is refreshed by the host timer.
fi

# --- run the suites --------------------------------------------------------------
info "running pytest serially against namespace $OSAC_NAMESPACE (KUBECONFIG=$KUBECONFIG)"
cd "$repo"
export OSAC_NAMESPACE
if [[ -n "$hosts_file" ]]; then
    unshare --user --map-root-user --mount \
        bash -c 'set -e; mount --make-rprivate /; mount --bind "$1" /etc/hosts; shift; exec "$@"' \
        hostswap "$hosts_file" uv run pytest -n 0 "$@"
else
    uv run pytest -n 0 "$@"
fi
