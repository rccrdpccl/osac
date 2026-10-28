#!/usr/bin/env bash
# Target resolution and the host seam for the osac-dev workflow.
#
# Sourced by the osac-dev wrappers. This is the only file that may invoke ssh or
# scp: every other wrapper reaches the cluster host through these functions, so
# that one control flow runs against either target.
#
# Target selection reuses REMOTE_HOST:
#   REMOTE_HOST unset        -> localhost target (this machine is the cluster host)
#   REMOTE_HOST=localhost    -> localhost target
#   anything else            -> remote target over root SSH, unchanged
# Loopback addresses (127.0.0.1, ::1) stay remote targets so an intentional
# SSH-to-self setup keeps working.
#
# Both targets require root; the check happens where the privileged work runs.

# shellcheck shell=bash

osac_dev_fail() {
    printf 'osac-dev: %s\n' "$*" >&2
    exit 1
}

osac_dev_target_init() {
    if [[ -n ${OSAC_DEV_TARGET:-} ]]; then
        osac_dev_fail 'OSAC_DEV_TARGET is derived from REMOTE_HOST and cannot be set; export REMOTE_HOST=localhost (or leave it unset) for the localhost target, or REMOTE_HOST=root@host for a remote one'
    fi

    if [[ -z ${REMOTE_HOST:-} || ${REMOTE_HOST} == localhost ]]; then
        OSAC_DEV_TARGET=localhost
        OSAC_DEV_TARGET_DESCRIPTION='this host (localhost target)'
    else
        OSAC_DEV_TARGET=remote
        OSAC_DEV_TARGET_DESCRIPTION=$REMOTE_HOST
    fi
    readonly OSAC_DEV_TARGET
    readonly OSAC_DEV_TARGET_DESCRIPTION
    # Normalize for the stage scripts: an unset target means the localhost one.
    # Only REMOTE_HOST is exported: every child re-derives the target from it, so
    # an exported OSAC_DEV_TARGET could never disagree with the environment and
    # is withheld to keep the `cannot be set` guard meaningful.
    export REMOTE_HOST="${REMOTE_HOST:-localhost}"
}

osac_dev_is_localhost() {
    [[ ${OSAC_DEV_TARGET:-} == localhost ]]
}

osac_dev_is_remote() {
    [[ ${OSAC_DEV_TARGET:-} == remote ]]
}

# Require root on the cluster host. The remote check stays remote-side, so a
# logged-in root shell is never assumed to imply remote privileges.
osac_dev_require_root() {
    local uid
    if osac_dev_is_localhost; then
        uid=$(id -u)
        [[ $uid == 0 ]] || osac_dev_fail 'the localhost target runs privileged host setup (cluster-tool, libvirt, dnsmasq, nftables, systemd units, /etc/osac-dev); rerun as root'
    else
        uid=$(ssh "$REMOTE_HOST" 'id -u') || \
            osac_dev_fail "cannot connect to remote host '$REMOTE_HOST'"
        [[ $uid == 0 ]] || \
            osac_dev_fail 'REMOTE_HOST must connect as root (cluster-tool local mode and host DNS setup require it)'
    fi
}

# Require the transport only when the target needs one.
osac_dev_require_transport() {
    osac_dev_is_remote || return 0
    command -v ssh >/dev/null 2>&1 || osac_dev_fail 'required local command not found: ssh'
    command -v scp >/dev/null 2>&1 || osac_dev_fail 'required local command not found: scp'
}

# Run one shell command string on the cluster host.
osac_dev_host_run() {
    local command=$1
    if osac_dev_is_localhost; then
        bash -c "$command"
    else
        ssh "$REMOTE_HOST" "$command"
    fi
}

# Run a command string on the host with a local file on its stdin. Used to feed
# the host-side lifecycle script to `bash -s` on either target.
osac_dev_host_run_with_stdin() {
    local command=$1
    local stdin_file=$2
    if osac_dev_is_localhost; then
        bash -c "$command" < "$stdin_file"
    else
        ssh "$REMOTE_HOST" "$command" < "$stdin_file"
    fi
}

# Run a command string on the host with a TTY, for interactive package installs.
osac_dev_host_run_tty() {
    local command=$1
    if osac_dev_is_localhost; then
        bash -c "$command"
    else
        ssh -tt "$REMOTE_HOST" "$command"
    fi
}

# Return 0 when the named command exists on the cluster host. A transport
# failure is reported, not mistaken for a missing command.
osac_dev_host_has_command() {
    local dependency=$1
    local status=0
    [[ "$dependency" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || \
        osac_dev_fail "internal error: unsupported dependency check: $dependency"

    if osac_dev_is_localhost; then
        command -v "$dependency" >/dev/null 2>&1 || status=$?
        return "$status"
    fi

    # The dependency is validated above; build the remote command locally.
    # shellcheck disable=SC2029
    ssh "$REMOTE_HOST" "PATH=\"\$HOME/.local/bin:\$PATH\" command -v '$dependency' >/dev/null 2>&1" \
        >/dev/null 2>&1 || status=$?
    if [[ "$status" -eq 255 ]]; then
        osac_dev_fail "SSH connection to '$REMOTE_HOST' failed while checking '$dependency'"
    fi
    return "$status"
}

# Copy a host path to a local path.
osac_dev_host_copy_from() {
    local host_path=$1
    local local_path=$2
    if osac_dev_is_localhost; then
        cp -- "$host_path" "$local_path"
    else
        scp -q -- "${REMOTE_HOST}:${host_path}" "$local_path"
    fi
}

# Copy a local path to a host path.
osac_dev_host_copy_to() {
    local local_path=$1
    local host_path=$2
    if osac_dev_is_localhost; then
        cp -- "$local_path" "$host_path"
    else
        scp -q -- "$local_path" "${REMOTE_HOST}:${host_path}"
    fi
}

# Create a mode-restricted temporary directory on the cluster host.
osac_dev_host_mktemp_dir() {
    local template=$1
    if osac_dev_is_localhost; then
        (umask 077 && mktemp -d "$template")
    else
        ssh "$REMOTE_HOST" "umask 077; mktemp -d $(printf '%q' "$template")"
    fi
}

osac_dev_host_remove() {
    local path=$1
    if osac_dev_is_localhost; then
        rm -rf -- "$path"
    else
        # The path is validated by the caller before it reaches this point.
        # shellcheck disable=SC2029
        ssh "$REMOTE_HOST" "rm -rf -- $(printf '%q' "$path")"
    fi
}

# Open an SSH local port forward and print its PID. Remote targets only: a
# localhost target reaches the API directly.
osac_dev_host_open_tunnel() {
    local local_endpoint=$1
    local log=$2
    osac_dev_is_remote || osac_dev_fail 'internal error: a port forward is only needed for a remote target'
    ssh -o ExitOnForwardFailure=yes -N -L "$local_endpoint" "$REMOTE_HOST" >"$log" 2>&1 &
    printf '%s\n' "$!"
}

# Open an SSH dynamic (SOCKS) proxy and print its PID. Remote targets only.
# The optional host defaults to REMOTE_HOST; the e2e runner may route through a
# separate SSH hop.
osac_dev_host_open_socks() {
    local port=$1
    local log=$2
    local host=${3:-$REMOTE_HOST}
    osac_dev_is_remote || osac_dev_fail 'internal error: a SOCKS proxy is only needed for a remote target'
    ssh -o ExitOnForwardFailure=yes -N -D "127.0.0.1:${port}" "$host" >"$log" 2>&1 &
    printf '%s\n' "$!"
}

# Run one shell command string on an explicitly named SSH host. Remote targets
# only, and only when the host may differ from REMOTE_HOST (the e2e SOCKS hop).
osac_dev_host_run_on() {
    local host=$1
    local command=$2
    [[ -n "$host" ]] || osac_dev_fail 'internal error: a host is required'
    osac_dev_is_remote || \
        osac_dev_fail 'internal error: an explicit SSH host is only reachable from a remote target'
    ssh "$host" "$command"
}

# Wait for a remote target to accept SSH again after it restarts
# NetworkManager. A localhost target has no session to lose.
osac_dev_host_wait_reconnect() {
    local attempts=${1:-30}
    local delay=${2:-2}
    local attempt
    osac_dev_is_remote || return 0
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if ssh -o ConnectTimeout=5 "$REMOTE_HOST" true >/dev/null 2>&1; then
            return 0
        fi
        sleep "$delay"
    done
    return 1
}

# Atomically install the host DNS helper. Never execute a partially copied
# script; the pending copy is renamed into place only after it is complete.
osac_dev_host_install_dns_helper() {
    local source=$1
    local destination=${2:-/usr/local/sbin/osac-dev-dns}
    if osac_dev_is_localhost; then
        [[ $(id -u) == 0 ]] || osac_dev_fail 'installing the host DNS helper requires root'
        command -v python3 >/dev/null 2>&1 || osac_dev_fail 'python3 is required on the cluster host'
        install -m 0755 "$source" "$destination.pending" && mv -- "$destination.pending" "$destination"
    else
        ssh "$REMOTE_HOST" \
            "set -eu; test \"\$(id -u)\" = 0; command -v python3 >/dev/null; install -m 0755 /dev/stdin $(printf '%q' "$destination").pending; mv -- $(printf '%q' "$destination").pending $(printf '%q' "$destination")" \
            < "$source"
    fi
}

# Resolve the host name or address the API should be reached through. Only the
# remote target needs an SSH-reachable address; the localhost target keeps the
# cluster-tool kubeconfig untouched.
osac_dev_host_address() {
    local hostname resolved
    if osac_dev_is_localhost; then
        printf '127.0.0.1\n'
        return 0
    fi

    hostname=$(ssh -G "$REMOTE_HOST" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }') || true
    if [[ -z "$hostname" ]]; then
        hostname=${REMOTE_HOST#*@}
    fi
    [[ -n "$hostname" ]] || return 1
    resolved=$(getent ahostsv4 "$hostname" 2>/dev/null | awk 'NR == 1 { print $1; exit }') || true
    if [[ -n "$resolved" ]]; then
        printf '%s\n' "$resolved"
    else
        printf '%s\n' "$hostname"
    fi
}
