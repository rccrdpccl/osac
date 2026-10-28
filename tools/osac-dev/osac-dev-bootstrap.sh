#!/usr/bin/env bash
# Prepare the cluster-tool host and boot or reuse the selected SNO cluster.
#
# REMOTE_HOST selects the target: unset or `localhost` runs on this machine,
# anything else drives a remote cluster-tool host over root SSH.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$SCRIPT_DIR/osac-dev-target.sh"
REMOTE_CLUSTER_SCRIPT="${SCRIPT_DIR}/osac-dev.sh"
readonly REMOTE_CLUSTER_SCRIPT
REMOTE_INSTALL_SCRIPT="${SCRIPT_DIR}/osac-dev-install-cluster-tool.sh"
readonly REMOTE_INSTALL_SCRIPT
REMOTE_HOST=${REMOTE_HOST:-}
ACTION=${1:-up}
DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
SNO_FLAVOR=${SNO_FLAVOR:-sno-4-22}
CLUSTER_TOOL_DATA_PATH=${CLUSTER_TOOL_DATA_PATH:-/data/cluster-tool}
PULL_SECRET_FILE=${PULL_SECRET_FILE:-}
REMOTE_SECRET_DIR=
REMOTE_SECRET_PATH=

fail() {
    printf 'osac-dev: %s\n' "$*" >&2
    exit 1
}

require_local_command() {
    command -v "$1" >/dev/null 2>&1 || \
        fail "required local command not found: $1; run 'make osac-dev-setup' to install missing prerequisites"
}

validate_inputs() {
    case "$ACTION" in
        up|down|status) ;;
        *) fail 'usage: osac-dev-bootstrap.sh {up|down|status}' ;;
    esac
    [[ "$DEV_ENV_NAME" =~ ^[a-z0-9]{1,4}$ ]] || \
        fail 'DEV_ENV_NAME must be 1-4 lowercase letters or digits'
    [[ "$SNO_FLAVOR" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || \
        fail 'SNO_FLAVOR contains unsupported characters'
    [[ "$CLUSTER_TOOL_DATA_PATH" == /* ]] || \
        fail 'CLUSTER_TOOL_DATA_PATH must be an absolute path on the cluster host'
    [[ -r "$REMOTE_CLUSTER_SCRIPT" ]] || fail "host lifecycle script not found: $REMOTE_CLUSTER_SCRIPT"
    [[ -r "$REMOTE_INSTALL_SCRIPT" ]] || fail "host cluster-tool installer not found: $REMOTE_INSTALL_SCRIPT"
}

remote_has() {
    osac_dev_host_has_command "$1"
}

confirm() {
    local message=$1
    local answer

    printf '%s [y/N] ' "$message" >&2
    if ! IFS= read -r answer; then
        answer=
    fi
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

ensure_remote_package() {
    local package=$1

    if remote_has "$package"; then
        return 0
    fi
    if ! remote_has dnf; then
        fail "cannot install '$package': $OSAC_DEV_TARGET_DESCRIPTION must provide dnf (Fedora/RHEL/CentOS)"
    fi
    if ! confirm "Dependency '$package' is missing on $OSAC_DEV_TARGET_DESCRIPTION. Install it now?"; then
        fail "installation of '$package' was declined"
    fi

    osac_dev_host_run_tty "dnf install -y $(printf '%q' "$package")" || \
        fail "installation of '$package' failed"

    remote_has "$package" || fail "'$package' is still missing after installation"
}

remote_install_cluster_tool() {
    osac_dev_host_run_with_stdin 'sh -s' "$REMOTE_INSTALL_SCRIPT"
}

ensure_cluster_tool() {
    ensure_remote_package python3
    if remote_has cluster-tool; then
        printf 'cluster-tool is already available on %s.\n' "$OSAC_DEV_TARGET_DESCRIPTION"
        return 0
    fi

    ensure_remote_package git
    if ! confirm "cluster-tool is missing on $OSAC_DEV_TARGET_DESCRIPTION. Install it in the cluster-tool user's home?"; then
        fail "installation of 'cluster-tool' was declined"
    fi

    remote_install_cluster_tool || fail 'cluster-tool installation failed'
    remote_has cluster-tool || fail 'cluster-tool is still missing after installation'
    printf 'cluster-tool installed on %s.\n' "$OSAC_DEV_TARGET_DESCRIPTION"
}

run_remote_action() {
    local action=$1
    local pull_secret_path=${2:-}
    local remote_command

    printf -v remote_command \
        'DEV_ENV_NAME=%q SNO_FLAVOR=%q CLUSTER_TOOL_DATA_PATH=%q PULL_SECRET_PATH=%q bash -s -- %q' \
        "$DEV_ENV_NAME" "$SNO_FLAVOR" \
        "$CLUSTER_TOOL_DATA_PATH" "$pull_secret_path" "$action"
    # printf %q above quotes each value for the host Bash invocation.
    osac_dev_host_run_with_stdin "$remote_command" "$REMOTE_CLUSTER_SCRIPT"
}

plan_value() {
    local plan=$1
    local key=$2
    awk -F= -v wanted="$key" '$1 == wanted { print $2; found = 1; exit } END { if (!found) exit 1 }' <<< "$plan"
}

validate_selected_cluster_state() {
    local plan=$1
    local cluster_status
    cluster_status=$(plan_value "$plan" cluster) || fail 'host plan omitted cluster'
    case "$cluster_status" in
        present|missing) ;;
        *) fail "host plan returned unknown cluster state '$cluster_status'" ;;
    esac
}

confirm_preparation() {
    local plan=$1
    local client server sno_flavor
    local -a operations=()

    client=$(plan_value "$plan" client_setup) || fail 'host plan omitted client_setup'
    server=$(plan_value "$plan" server_setup) || fail 'host plan omitted server_setup'
    sno_flavor=$(plan_value "$plan" sno_flavor) || fail 'host plan omitted sno_flavor'

    if [[ "$client" == needed ]]; then
        operations+=("configure host dnsmasq and restart NetworkManager (an SSH session may briefly disconnect)")
    fi
    if [[ "$server" == needed ]]; then
        operations+=("run cluster-tool connect (install/configure libvirt, QEMU, Podman, HAProxy, firewall and storage)")
    fi
    if [[ "$sno_flavor" == missing ]]; then
        operations+=("download SNO flavor image $SNO_FLAVOR (large, about 100 GB)")
    fi

    if ((${#operations[@]} == 0)); then
        return 0
    fi

    printf 'The cluster host needs these one-time preparation steps:\n' >&2
    printf '  - %s\n' "${operations[@]}" >&2
    confirm 'Continue with host preparation?' || fail 'host preparation was declined'
}

wait_for_remote() {
    osac_dev_host_wait_reconnect 30 2
}

prepare_remote() {
    local status=0
    if run_remote_action prepare; then
        return 0
    else
        status=$?
    fi

    printf 'Preparation returned status %s; checking whether the NetworkManager restart interrupted the session...\n' \
        "$status" >&2
    wait_for_remote || fail 'the cluster host did not come back after setup; inspect it locally and retry'

    local plan client_state
    plan=$(run_remote_action plan) || fail 'could not inspect host setup after reconnecting'
    client_state=$(plan_value "$plan" client_setup) || fail 'host plan omitted client_setup'
    [[ "$client_state" == ready ]] || fail 'host preparation failed; dnsmasq client setup is still incomplete'

    run_remote_action prepare || fail 'host preparation did not complete after reconnecting'
}

cleanup_remote_secret() {
    if [[ -n "$REMOTE_SECRET_DIR" ]]; then
        # The mktemp path is validated before it is stored.
        osac_dev_host_remove "$REMOTE_SECRET_DIR" >/dev/null 2>&1 || true
    fi
}

copy_pull_secret() {
    [[ -n "$PULL_SECRET_FILE" ]] || fail 'PULL_SECRET_FILE must point to a readable local pull-secret file when a cluster is missing'
    [[ -f "$PULL_SECRET_FILE" && -r "$PULL_SECRET_FILE" ]] || fail 'PULL_SECRET_FILE must point to a readable local file'

    local restrict_command

    if osac_dev_is_localhost; then
        # The localhost target can read the pull secret in place; there is no
        # transport, so nothing is staged and nothing needs cleaning up.
        REMOTE_SECRET_PATH=$PULL_SECRET_FILE
        return 0
    fi

    require_local_command scp

    REMOTE_SECRET_DIR=$(osac_dev_host_mktemp_dir /tmp/osac-dev-pull-secret.XXXXXX) || \
        fail 'could not create a temporary pull-secret directory on the cluster host'
    [[ "$REMOTE_SECRET_DIR" =~ ^/tmp/osac-dev-pull-secret\.[[:alnum:]]+$ ]] || \
        fail 'the cluster host returned an unexpected temporary directory path'
    REMOTE_SECRET_PATH="${REMOTE_SECRET_DIR}/pull-secret.json"

    printf 'Copying the local pull secret to a temporary restricted directory on %s...\n' \
        "$OSAC_DEV_TARGET_DESCRIPTION"
    osac_dev_host_copy_to "$PULL_SECRET_FILE" "$REMOTE_SECRET_PATH" || \
        fail 'could not copy the pull secret to the cluster host'
    printf -v restrict_command 'chmod 600 -- %q' "$REMOTE_SECRET_PATH"
    osac_dev_host_run "$restrict_command" || \
        fail 'could not restrict permissions on the pull secret'
}

main() {
    osac_dev_target_init
    validate_inputs
    osac_dev_require_transport
    osac_dev_require_root
    ensure_cluster_tool

    case "$ACTION" in
        status)
            run_remote_action status
            ;;
        down)
            local plan cluster_status
            plan=$(run_remote_action plan) || fail 'could not inspect the development cluster'
            cluster_status=$(plan_value "$plan" cluster) || fail 'host plan omitted cluster'
            if [[ "$cluster_status" == missing ]]; then
                printf 'No cluster for DEV_ENV_NAME=%s is running.\n' "$DEV_ENV_NAME"
                "$SCRIPT_DIR/osac-dev-dns.sh" --install-only
                run_remote_action down
                return 0
            fi
            confirm "Destroy only the development cluster ${DEV_ENV_NAME}-dev on $OSAC_DEV_TARGET_DESCRIPTION?" || \
                fail 'cluster teardown was cancelled'
            "$SCRIPT_DIR/osac-dev-dns.sh" --install-only
            run_remote_action down
            ;;
        up)
            ensure_remote_package python3

            local plan cluster_status client_setup server_setup
            plan=$(run_remote_action plan) || fail 'could not inspect the development cluster'
            validate_selected_cluster_state "$plan"
            client_setup=$(plan_value "$plan" client_setup) || fail 'host plan omitted client_setup'
            server_setup=$(plan_value "$plan" server_setup) || fail 'host plan omitted server_setup'
            if [[ "$client_setup" == needed || "$server_setup" == needed ]] && ! remote_has dnf; then
                fail 'cluster setup requires dnf (Fedora/RHEL/CentOS)'
            fi
            cluster_status=$(plan_value "$plan" cluster) || fail 'host plan omitted cluster'
            if [[ "$cluster_status" == missing ]]; then
                [[ -n "$PULL_SECRET_FILE" && -f "$PULL_SECRET_FILE" && -r "$PULL_SECRET_FILE" ]] || \
                    fail 'set PULL_SECRET_FILE to a readable local pull-secret file before booting the SNO cluster'
            fi

            confirm_preparation "$plan"
            prepare_remote

            plan=$(run_remote_action plan) || fail 'could not inspect the prepared development cluster'
            validate_selected_cluster_state "$plan"
            cluster_status=$(plan_value "$plan" cluster) || fail 'host plan omitted cluster'
            if [[ "$cluster_status" == missing ]]; then
                copy_pull_secret
                run_remote_action boot "$REMOTE_SECRET_PATH"
            else
                run_remote_action boot
            fi
            ;;
    esac
}

trap cleanup_remote_secret EXIT
main "$@"
