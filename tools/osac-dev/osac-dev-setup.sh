#!/usr/bin/env bash
# Install the prerequisites the osac-dev workflow needs.
#
# REMOTE_HOST selects the target: unset, empty, or `localhost` treats this
# machine as the cluster-tool host; anything else installs the host prerequisites
# on that host over root SSH. Two independent scopes:
#
#   workstation   Helm (pinned), Skaffold, the docker->podman shim and the
#                 rootless podman socket. Always on this machine, because this
#                 is where images are built and the charts are installed, for
#                 both targets. Never needs root.
#   cluster host  Python 3, Git, dnsmasq, nftables, NetworkManager, chrony,
#                 libvirt client and podman, plus cluster-tool. Needs root on the
#                 cluster host, so it is installed only when this script already
#                 has those privileges and is printed as a command otherwise.
#                 libvirt, QEMU, podman, HAProxy, firewall and storage are
#                 configured by cluster-tool itself on its first `connect local`.
#
# Every step is idempotent and only touches what is missing. This script never
# runs sudo and never stores credentials: registry login stays manual.
#
# Usage: make osac-dev-setup
#        make osac-dev-setup DRY_RUN=1   # print the plan, change nothing
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$script_dir/osac-dev-target.sh"

LOCAL_BIN="$HOME/.local/bin"
SKAFFOLD_VERSION=${OSAC_DEV_SKAFFOLD_VERSION:-latest}
SKAFFOLD_URL="https://storage.googleapis.com/skaffold/releases/${SKAFFOLD_VERSION}/skaffold-linux-amd64"
# Helm is pinned in .github/helm-version, the one file CI (through
# .github/actions/setup-helm) and this script both read, because the workflow
# relies on flags Helm 4 still accepts (--wait-for-jobs, and --take-ownership
# when a cluster already carries objects from an earlier install).
# OSAC_DEV_HELM_VERSION overrides the pin for a one-off run.
HELM_PIN_FILE="$script_dir/../../.github/helm-version"
# Packages the tooling drives directly. cluster-tool adds the rest of the VM
# server stack (libvirt, QEMU, podman, HAProxy, firewall, storage) on connect.
HOST_PACKAGES=(python3 git make curl tar dnsmasq nftables NetworkManager chrony libvirt-client podman)
# Commands the osac-dev targets require on the machine that runs them.
WORKSTATION_COMMANDS=(oc kubectl helm skaffold docker podman uv go python3 awk getent make)
DRY_RUN=0
manual=()

info() { printf '==> %s\n' "$*"; }
warn() { printf 'osac-dev-setup: %s\n' "$*" >&2; }
fail() {
    printf 'osac-dev-setup: %s\n' "$*" >&2
    exit 1
}
have() { command -v "$1" >/dev/null 2>&1; }
note_manual() { manual+=("$1"); }

helm_pinned_version() {
    [[ -r ${HELM_PIN_FILE} ]] || fail "cannot read the Helm version pin at ${HELM_PIN_FILE}"
    local version
    version=$(tr -d '[:space:]' <"${HELM_PIN_FILE}")
    [[ -n ${version} ]] || fail "the Helm version pin at ${HELM_PIN_FILE} is empty"
    printf '%s\n' "${version}"
}

HELM_VERSION=${OSAC_DEV_HELM_VERSION:-$(helm_pinned_version)}

usage() {
    printf 'usage: osac-dev-setup.sh [--dry-run]\n'
    printf 'Installs missing osac-dev prerequisites; REMOTE_HOST selects the cluster host.\n'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run | -n) DRY_RUN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

# --- workstation scope --------------------------------------------------------

# As root through sudo, $HOME is root's home: installing the user's build tooling
# there would leave the real user without it.
skip_user_scope() {
    osac_dev_is_localhost && [[ $(id -u) == 0 && -n ${SUDO_USER:-} ]] || return 1
    info "skipping workstation tooling (Helm, Skaffold, docker shim, podman socket): it belongs to '$SUDO_USER'; run make osac-dev-setup without sudo for those"
    return 0
}

create_local_bin() {
    [[ -d "$LOCAL_BIN" ]] && return 0
    if ((DRY_RUN)); then
        info "would create $LOCAL_BIN"
    else
        mkdir -p "$LOCAL_BIN"
        info "created $LOCAL_BIN"
    fi
}

# get.helm.sh publishes linux-amd64 and linux-arm64 only.
helm_arch() {
    case $(uname -m) in
        x86_64 | amd64) printf 'amd64' ;;
        aarch64 | arm64) printf 'arm64' ;;
        *) return 1 ;;
    esac
}

helm_matches_pin() {
    local current
    have helm || return 1
    current=$(helm version --short 2>/dev/null) || return 1
    current=${current#v}
    [[ ${current%%[+-]*} == "${HELM_VERSION#v}" ]]
}

install_helm() {
    local arch url download extracted status=0
    if helm_matches_pin; then
        info "Helm ${HELM_VERSION} already installed: $(command -v helm)"
        return 0
    fi
    if have helm; then
        warn "replacing Helm $(helm version --short 2>/dev/null || echo unknown) with the pinned ${HELM_VERSION} in $LOCAL_BIN"
    fi
    if ! arch=$(helm_arch); then
        note_manual "install Helm ${HELM_VERSION} from https://get.helm.sh (no linux build for $(uname -m))"
        return 0
    fi
    url="https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz"
    if ((DRY_RUN)); then
        info "would download Helm ${HELM_VERSION} from ${url} into $LOCAL_BIN"
        return 0
    fi
    for tool in curl tar; do
        have "$tool" || {
            note_manual "install $tool, then re-run make osac-dev-setup for Helm"
            return 0
        }
    done
    create_local_bin
    download=$(mktemp "${TMPDIR:-/tmp}/helm.XXXXXX.tar.gz")
    info "downloading Helm ${HELM_VERSION}"
    curl -fsSL -o "$download" "$url" || status=$?
    if ((status != 0)); then
        rm -f -- "$download"
        note_manual "download Helm ${HELM_VERSION} from ${url} into $LOCAL_BIN"
        return 0
    fi
    extracted=$(mktemp -d "${TMPDIR:-/tmp}/helm.XXXXXX")
    if ! tar -xzf "$download" -C "$extracted" "linux-${arch}/helm"; then
        rm -rf -- "$download" "$extracted"
        note_manual "extract Helm ${HELM_VERSION} from ${url} into $LOCAL_BIN"
        return 0
    fi
    rm -f -- "$download"
    # Remove first: install(1) would follow a symlink into its target.
    rm -f -- "$LOCAL_BIN/helm"
    install -m 0755 "$extracted/linux-${arch}/helm" "$LOCAL_BIN/helm"
    rm -rf -- "$extracted"
    if ! "$LOCAL_BIN/helm" version --short >/dev/null 2>&1; then
        fail "the Helm binary installed in $LOCAL_BIN does not run; remove it and retry"
    fi
    # Bash caches command locations, so it would keep resolving the old Helm.
    hash -r 2>/dev/null || true
    info "installed Helm ${HELM_VERSION} into $LOCAL_BIN"
}

install_skaffold() {
    if have skaffold; then
        info "Skaffold already installed: $(command -v skaffold)"
        return 0
    fi
    if ((DRY_RUN)); then
        info "would download Skaffold ${SKAFFOLD_VERSION} from ${SKAFFOLD_URL} into $LOCAL_BIN"
        return 0
    fi
    have curl || {
        note_manual 'install curl, then re-run make osac-dev-setup for Skaffold'
        return 0
    }
    create_local_bin
    local download status=0
    download=$(mktemp "${TMPDIR:-/tmp}/skaffold.XXXXXX")
    info "downloading Skaffold ${SKAFFOLD_VERSION}"
    curl -fsSL -o "$download" "$SKAFFOLD_URL" || status=$?
    if ((status != 0)); then
        rm -f -- "$download"
        note_manual "download Skaffold manually from ${SKAFFOLD_URL} into $LOCAL_BIN"
        return 0
    fi
    install -m 0755 "$download" "$LOCAL_BIN/skaffold"
    rm -f -- "$download"
    if ! "$LOCAL_BIN/skaffold" version >/dev/null 2>&1; then
        fail "the Skaffold binary installed in $LOCAL_BIN does not run; remove it and retry"
    fi
    info "installed Skaffold into $LOCAL_BIN"
}

install_docker_shim() {
    local docker_path
    if docker_path=$(command -v docker); then
        if grep -qs 'exec podman' "$docker_path" 2>/dev/null; then
            info "docker->podman shim already installed: $docker_path"
        else
            info "docker CLI already present: $docker_path"
        fi
        return 0
    fi
    have podman || {
        note_manual 'install podman, then re-run make osac-dev-setup for the docker shim'
        return 0
    }
    if ((DRY_RUN)); then
        info "would install the docker->podman shim in $LOCAL_BIN/docker"
        return 0
    fi
    create_local_bin
    printf '#!/bin/sh\nexec podman "$@"\n' >"$LOCAL_BIN/docker"
    chmod 0755 "$LOCAL_BIN/docker"
    info "installed the docker->podman shim in $LOCAL_BIN/docker"
}

ensure_podman_socket() {
    if [[ -n ${DOCKER_HOST:-} ]]; then
        info "DOCKER_HOST is already set to $DOCKER_HOST"
        return 0
    fi
    have systemctl || {
        note_manual 'start the container daemon yourself and export DOCKER_HOST'
        return 0
    }
    if systemctl --user is-enabled podman.socket >/dev/null 2>&1; then
        info 'podman.socket is already enabled'
        return 0
    fi
    if ((DRY_RUN)); then
        info 'would enable and start the rootless podman socket (podman.socket)'
        return 0
    fi
    if systemctl --user enable --now podman.socket >/dev/null 2>&1; then
        info 'enabled and started podman.socket'
    else
        note_manual 'systemctl --user enable --now podman.socket'
    fi
}

# --- cluster host scope -------------------------------------------------------

host_is_root() {
    local uid
    uid=$(osac_dev_host_run 'id -u') || return 1
    [[ $uid == 0 ]]
}

# Emit the HOST_PACKAGES that are not installed on the cluster host. One host
# round trip: rpm prints the installed names and the comparison happens here.
missing_host_packages() {
    local installed package
    installed=$(osac_dev_host_run "rpm -q --qf '%{NAME}\n' ${HOST_PACKAGES[*]} 2>/dev/null || true") || return 1
    for package in "${HOST_PACKAGES[@]}"; do
        grep -qx -- "$package" <<<"$installed" || printf '%s\n' "$package"
    done
}

package_list() {
    local joined=${1//$'\n'/ }
    printf '%s' "${joined% }"
}

install_host_packages() {
    if ! osac_dev_host_has_command dnf; then
        note_manual "install on ${OSAC_DEV_TARGET_DESCRIPTION} with the local package manager: ${HOST_PACKAGES[*]}"
        return 0
    fi
    local missing list
    missing=$(missing_host_packages) || fail "could not inspect packages on $OSAC_DEV_TARGET_DESCRIPTION"
    if [[ -z $missing ]]; then
        info "cluster host packages already present on $OSAC_DEV_TARGET_DESCRIPTION"
        return 0
    fi
    list=$(package_list "$missing")
    if ! host_is_root; then
        if osac_dev_is_localhost; then
            note_manual "sudo dnf install -y $list (or rerun make osac-dev-setup as root)"
        else
            note_manual "install on $REMOTE_HOST as root: dnf install -y $list"
        fi
        return 0
    fi
    if ((DRY_RUN)); then
        info "would install on $OSAC_DEV_TARGET_DESCRIPTION: $list"
        return 0
    fi
    info "installing on $OSAC_DEV_TARGET_DESCRIPTION: $list"
    osac_dev_host_run_tty "dnf install -y $list" || fail "package installation failed on $OSAC_DEV_TARGET_DESCRIPTION"
}

install_cluster_tool() {
    if osac_dev_host_has_command cluster-tool; then
        info "cluster-tool already available on $OSAC_DEV_TARGET_DESCRIPTION"
        return 0
    fi
    if ((DRY_RUN)); then
        info "would install cluster-tool on $OSAC_DEV_TARGET_DESCRIPTION"
        return 0
    fi
    if ! osac_dev_host_has_command git; then
        note_manual "install git on $OSAC_DEV_TARGET_DESCRIPTION, then re-run make osac-dev-setup for cluster-tool"
        return 0
    fi
    if ! host_is_root; then
        note_manual "install cluster-tool in the root home on $OSAC_DEV_TARGET_DESCRIPTION (make osac-dev-cluster offers to do this)"
        return 0
    fi
    info "installing cluster-tool on $OSAC_DEV_TARGET_DESCRIPTION"
    osac_dev_host_run_with_stdin 'sh -s' "$script_dir/osac-dev-install-cluster-tool.sh" || \
        fail "cluster-tool installation failed on $OSAC_DEV_TARGET_DESCRIPTION"
    osac_dev_host_has_command cluster-tool || fail 'cluster-tool is still missing after installation'
}

# --- verification -------------------------------------------------------------

manual_command_hint() {
    case "$1" in
        oc | kubectl) printf 'install the OpenShift CLI (%s)' "$1" ;;
        helm) printf 'install Helm %s into %s (make osac-dev-setup needs curl and tar)' "$HELM_VERSION" "$LOCAL_BIN" ;;
        go) printf 'install Go (needed by make osac-dev-e2e)' ;;
        uv) printf 'install uv (needed by make osac-dev-deploy)' ;;
        skaffold) printf 'install Skaffold into %s' "$LOCAL_BIN" ;;
        docker) printf 'install podman, then the docker->podman shim in %s' "$LOCAL_BIN" ;;
        podman) printf 'sudo dnf install -y podman' ;;
        ssh | scp) printf 'sudo dnf install -y openssh-clients' ;;
        *) printf 'install %s' "$1" ;;
    esac
}

verify_workstation() {
    local candidate missing=()
    hash -r 2>/dev/null || true
    for candidate in "${WORKSTATION_COMMANDS[@]}"; do
        have "$candidate" || missing+=("$candidate")
    done
    if osac_dev_is_remote; then
        for candidate in ssh scp; do
            have "$candidate" || missing+=("$candidate")
        done
    fi
    if ((${#missing[@]} == 0)); then
        if helm_matches_pin; then
            return 0
        fi
        warn "Helm $(helm version --short 2>/dev/null || echo missing) at $(command -v helm) does not match the pinned ${HELM_VERSION}"
        note_manual "$(manual_command_hint helm)"
        return 1
    fi
    warn "missing workstation commands: ${missing[*]}"
    for candidate in "${missing[@]}"; do
        note_manual "$(manual_command_hint "$candidate")"
    done
    return 1
}

verify_host() {
    if osac_dev_host_has_command cluster-tool; then
        return 0
    fi
    note_manual "cluster-tool is still missing on $OSAC_DEV_TARGET_DESCRIPTION"
    return 1
}

summarize() {
    if ((${#manual[@]} == 0)); then
        info 'all osac-dev prerequisites are present'
        return 0
    fi
    printf '\nosac-dev-setup: remaining manual steps:\n' >&2
    printf '  - %s\n' "${manual[@]}" >&2
    return 1
}

dedupe_manual() {
    local unique
    ((${#manual[@]})) || return 0
    unique=$(printf '%s\n' "${manual[@]}" | awk '!seen[$0]++')
    manual=()
    while IFS= read -r line; do
        [[ -z $line ]] || manual+=("$line")
    done <<<"$unique"
}

main() {
    osac_dev_target_init
    osac_dev_require_transport
    export PATH="$LOCAL_BIN:$PATH"

    if ((DRY_RUN)); then
        info "plan for the $OSAC_DEV_TARGET target (dry run: nothing will change)"
    fi

    if ! skip_user_scope; then
        install_helm
        install_skaffold
        install_docker_shim
        ensure_podman_socket
    fi
    install_host_packages
    install_cluster_tool

    if ((DRY_RUN)); then
        dedupe_manual
        summarize || exit 1
        exit 0
    fi

    local status=0
    verify_workstation || status=1
    verify_host || status=1
    dedupe_manual
    summarize || status=1
    if ((status != 0)); then
        printf 'Registry login is always manual: podman login %s\n' "${OSAC_DEV_REGISTRY:-quay.io}" >&2
        exit 1
    fi
    printf 'Next: podman login %s, then make osac-dev-check (PULL_SECRET_FILE, OSAC_DEV_REGISTRY, AAP license)\n' \
        "${OSAC_DEV_REGISTRY:-quay.io}"
}

main "$@"
