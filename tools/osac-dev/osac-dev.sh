#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

ACTION=${1:-}
DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
SNO_FLAVOR=${SNO_FLAVOR:-sno-4-22}
CLUSTER_TOOL_DATA_PATH=${CLUSTER_TOOL_DATA_PATH:-/data/cluster-tool}
PULL_SECRET_PATH=${PULL_SECRET_PATH:-}
CLUSTER_TOOL_BIN=${CLUSTER_TOOL_BIN:-cluster-tool}
OSAC_DEV_DNSMASQ_DIR=${OSAC_DEV_DNSMASQ_DIR:-/etc/NetworkManager/dnsmasq.d}
OSAC_DEV_NM_CONF=${OSAC_DEV_NM_CONF:-/etc/NetworkManager/conf.d/cluster-tool-dns.conf}
OSAC_DEV_RESOLV_CONF=${OSAC_DEV_RESOLV_CONF:-/etc/resolv.conf}
OSAC_DEV_DNS_HELPER=${OSAC_DEV_DNS_HELPER:-/usr/local/sbin/osac-dev-dns}

readonly ACTION DEV_ENV_NAME SNO_FLAVOR CLUSTER_TOOL_DATA_PATH
readonly PULL_SECRET_PATH CLUSTER_TOOL_BIN OSAC_DEV_DNSMASQ_DIR OSAC_DEV_NM_CONF OSAC_DEV_RESOLV_CONF

DEV_CLUSTER_NAME="${DEV_ENV_NAME}-dev"
readonly DEV_CLUSTER_NAME
readonly FLAVOR_REPOSITORY='quay.io/osac-project/cluster-flavors'

fail() {
    printf 'osac-dev: %s\n' "$*" >&2
    exit 1
}

validate_inputs() {
    [[ "$DEV_ENV_NAME" =~ ^[a-z0-9]{1,4}$ ]] || \
        fail 'DEV_ENV_NAME must be 1-4 lowercase letters or digits'
    [[ "$SNO_FLAVOR" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || \
        fail 'SNO_FLAVOR contains unsupported characters'
    [[ "$CLUSTER_TOOL_DATA_PATH" == /* ]] || \
        fail 'CLUSTER_TOOL_DATA_PATH must be an absolute remote path'
    command -v "$CLUSTER_TOOL_BIN" >/dev/null 2>&1 || \
        fail "cluster-tool not found: $CLUSTER_TOOL_BIN"
}

cluster_tool() {
    "$CLUSTER_TOOL_BIN" "$@"
}

require_root() {
    [[ "$(id -u)" == 0 ]] || fail 'remote cluster lifecycle commands must run as root'
}

server_host() {
    local output
    output=$(cluster_tool servers) || fail 'could not read cluster-tool server configuration'
    awk '$1 == "local" { print $2; exit }' <<< "$output"
}

server_state() {
    local host
    host=$(server_host)
    if [[ -z "$host" ]]; then
        printf 'needed\n'
    elif [[ "$host" == local ]]; then
        printf 'ready\n'
    else
        fail "cluster-tool alias 'local' points to '$host', not this remote host"
    fi
}

client_setup_state() {
    if command -v dnsmasq >/dev/null 2>&1 &&
        [[ -d "$OSAC_DEV_DNSMASQ_DIR" ]] &&
        [[ -f "$OSAC_DEV_NM_CONF" ]] &&
        grep -Fq 'dns=dnsmasq' "$OSAC_DEV_NM_CONF" &&
        [[ -r "$OSAC_DEV_RESOLV_CONF" ]] &&
        grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1([[:space:]]|$)' "$OSAC_DEV_RESOLV_CONF"; then
        printf 'ready\n'
    else
        printf 'needed\n'
    fi
}

flavor_exists() {
    local flavor=$1
    local output
    output=$(cluster_tool flavors --server local) || return 1
    awk -v wanted="$flavor" '$1 == wanted { found = 1 } END { exit !found }' <<< "$output"
}

clone_exists() {
    local name=$1
    local output
    output=$(cluster_tool list --server local) || return 1
    awk -v wanted="$name" '$1 == wanted { found = 1 } END { exit !found }' <<< "$output"
}

clone_row() {
    local name=$1
    local output
    output=$(cluster_tool list --server local) || return 1
    awk -v wanted="$name" '$1 == wanted { print; found = 1 } END { exit !found }' <<< "$output"
}

clone_flavor() {
    local name=$1 row
    row=$(clone_row "$name") || return 1
    awk 'NR == 1 { print $2; found = 1; exit } END { if (!found) exit 1 }' <<< "$row"
}

selected_cluster_state() {
    if clone_exists "$DEV_CLUSTER_NAME"; then
        printf 'present\n'
    else
        printf 'missing\n'
    fi
}

print_plan() {
    local server client sno_flavor cluster cluster_flavor
    client=$(client_setup_state)
    server=$(server_state)

    if [[ "$server" == ready ]]; then
        cluster=$(selected_cluster_state)
        if [[ "$cluster" == missing ]]; then
            cluster_flavor=none
            if flavor_exists "$SNO_FLAVOR"; then sno_flavor=present; else sno_flavor=missing; fi
        else
            cluster_flavor=$(clone_flavor "$DEV_CLUSTER_NAME")
            sno_flavor=not-needed
        fi
    else
        sno_flavor=missing
        cluster=missing
        cluster_flavor=none
    fi

    printf 'dev_env_name=%s\n' "$DEV_ENV_NAME"
    printf 'cluster_name=%s\n' "$DEV_CLUSTER_NAME"
    printf 'client_setup=%s\n' "$client"
    printf 'server_setup=%s\n' "$server"
    printf 'sno_flavor=%s\n' "$sno_flavor"
    printf 'cluster=%s\n' "$cluster"
    printf 'cluster_flavor=%s\n' "$cluster_flavor"
}

prepare_cluster() {
    local server
    require_root

    if [[ "$(client_setup_state)" != ready ]]; then
        printf 'Configuring remote dnsmasq/NetworkManager client setup...\n'
        cluster_tool setup client
    fi
    [[ "$(client_setup_state)" == ready ]] || \
        fail 'cluster-tool client DNS setup did not complete successfully'

    server=$(server_state)
    if [[ "$server" == needed ]]; then
        printf 'Connecting cluster-tool to the remote host and configuring the VM server...\n'
        cluster_tool connect local --host local --data-path "$CLUSTER_TOOL_DATA_PATH"
    fi
    [[ "$(server_state)" == ready ]] || \
        fail 'cluster-tool local server connection did not complete successfully'

    if ! clone_exists "$DEV_CLUSTER_NAME" && ! flavor_exists "$SNO_FLAVOR"; then
        printf 'Pulling SNO flavor %s...\n' "$SNO_FLAVOR"
        cluster_tool pull "${FLAVOR_REPOSITORY}:${SNO_FLAVOR}" --server local
    fi
}

boot_cluster() {
    local state existing_flavor
    require_root
    [[ "$(server_state)" == ready ]] || fail 'cluster-tool server is not configured; run make osac-dev first'

    state=$(selected_cluster_state)
    if [[ "$state" == present ]]; then
        existing_flavor=$(clone_flavor "$DEV_CLUSTER_NAME")
        if [[ "$existing_flavor" == "$SNO_FLAVOR" ]]; then
            printf 'Reusing existing SNO cluster %s.\n' "$DEV_CLUSTER_NAME"
        else
            printf 'Reusing existing cluster %s (flavor %s).\n' "$DEV_CLUSTER_NAME" "$existing_flavor"
        fi
        return 0
    fi

    [[ -n "$PULL_SECRET_PATH" && -r "$PULL_SECRET_PATH" ]] || \
        fail 'a readable temporary remote PULL_SECRET_PATH is required to boot the SNO cluster'
    flavor_exists "$SNO_FLAVOR" || fail "flavor '$SNO_FLAVOR' is not pulled; run make osac-dev first"

    printf 'Booting SNO development cluster %s from flavor %s...\n' "$DEV_CLUSTER_NAME" "$SNO_FLAVOR"
    cluster_tool boot --server local --flavor "$SNO_FLAVOR" --name "$DEV_CLUSTER_NAME" \
        --pull-secret "$PULL_SECRET_PATH"
}

show_cluster_status() {
    local server row flavor
    server=$(server_state)
    if [[ "$server" == needed ]]; then
        printf 'cluster-tool server is not configured on this host.\n'
        printf 'SNO development cluster (%s): not booted\n' "$DEV_CLUSTER_NAME"
        return 0
    fi

    if row=$(clone_row "$DEV_CLUSTER_NAME"); then
        flavor=$(clone_flavor "$DEV_CLUSTER_NAME")
        if [[ "$flavor" == "$SNO_FLAVOR" ]]; then
            printf 'SNO development cluster (%s): %s\n' "$DEV_CLUSTER_NAME" "$row"
        else
            printf 'Development cluster (%s) uses flavor %s: %s\n' \
                "$DEV_CLUSTER_NAME" "$flavor" "$row"
        fi
    else
        printf 'SNO development cluster (%s): not booted\n' "$DEV_CLUSTER_NAME"
    fi
}

destroy_cluster() {
    require_root
    if [[ "$(server_state)" == needed ]]; then
        printf 'cluster-tool server is not configured; no SNO cluster to destroy.\n'
        return 0
    fi

    if [[ "$(selected_cluster_state)" != missing ]]; then
        printf 'Destroying selected development cluster %s...\n' "$DEV_CLUSTER_NAME"
        if [[ -f "$OSAC_DEV_DNS_HELPER" ]]; then
            python3 "$OSAC_DEV_DNS_HELPER" destroy "$DEV_CLUSTER_NAME" \
                --cluster-tool "$CLUSTER_TOOL_BIN"
        else
            cluster_tool destroy "$DEV_CLUSTER_NAME" --server local
        fi
    else
        printf 'SNO development cluster %s is not present; skipping.\n' "$DEV_CLUSTER_NAME"
        if [[ -f "$OSAC_DEV_DNS_HELPER" ]]; then
            python3 "$OSAC_DEV_DNS_HELPER" cleanup "$DEV_CLUSTER_NAME"
        fi
    fi
}

validate_inputs
case "$ACTION" in
    plan) print_plan ;;
    prepare) prepare_cluster ;;
    boot) boot_cluster ;;
    status) show_cluster_status ;;
    down) destroy_cluster ;;
    *) fail 'usage: osac-dev.sh {plan|prepare|boot|status|down}' ;;
esac
