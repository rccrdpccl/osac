#!/usr/bin/env bash
# Unit/contract boundary: real setup wrapper, fake package manager, package
# probes, downloader, service manager and SSH; no host mutation.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
setup="$repo/tools/osac-dev/osac-dev-setup.sh"
[[ -x "$setup" ]] || {
    echo 'FAIL: osac-dev-setup.sh is missing or not executable' >&2
    exit 1
}

# The pin is one file shared with CI and fulfillment-service's e2e tool
# installer, so expectations come from it rather than from a copied literal:
# bumping .github/helm-version does not need an edit here.
pin_file="$repo/.github/helm-version"
pin=$(tr -d '[:space:]' <"$pin_file") || pin=
[[ -n "$pin" ]] || {
    echo "FAIL: $pin_file is missing or empty" >&2
    exit 1
}
# Exported so the helm and curl doubles below resolve it at run time.
export HELM_PIN="$pin"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
harness="$tmp/harness"
tools="$tmp/tools"
minbin="$tmp/minbin"
hostbin="$tmp/hostbin"
mkdir -p "$harness" "$tools" "$minbin" "$hostbin" "$tmp/home"

# --- harness doubles ---------------------------------------------------------
cat >"$harness/id" <<'ID'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then
    printf '%s\n' "${FAKE_UID:-0}"
    exit 0
fi
exec /usr/bin/id "$@"
ID

cat >"$harness/rpm" <<'RPM'
#!/usr/bin/env bash
printf 'rpm %s\n' "$*" >> "$LOG"
for argument in "$@"; do
    case "$argument" in
        -* | *%*) continue ;;
    esac
    case " ${FAKE_RPM_INSTALLED:-} " in
        *" $argument "*) printf '%s\n' "$argument" ;;
    esac
done
exit 0
RPM

cat >"$harness/curl" <<'CURL'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$LOG"
target=
url=
while (($#)); do
    case "$1" in
        -o)
            target=$2
            shift 2
            ;;
        http*)
            url=$1
            shift
            ;;
        *) shift ;;
    esac
done
[[ -n "$target" ]] || exit 0
case "$url" in
    *helm-v*.tar.gz)
        [[ ${FAKE_CURL_FAIL_HELM:-0} == 1 ]] && exit 22
        stage="${target%/*}/helm-stage"
        mkdir -p "$stage/linux-amd64"
        printf '#!/bin/sh\n[ "${1:-}" = version ] && { echo "%s"; exit 0; }\nexit 0\n' \
            "${FAKE_HELM_DOWNLOAD_VERSION:-${HELM_PIN}+g0f00000}" >"$stage/linux-amd64/helm"
        chmod 0755 "$stage/linux-amd64/helm"
        tar -czf "$target" -C "$stage" linux-amd64/helm
        rm -rf -- "$stage"
        ;;
    *)
        printf '#!/bin/sh\n[ "${1:-}" = version ] && echo v2.0.0\nexit 0\n' >"$target"
        ;;
esac
CURL

cat >"$harness/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$LOG"
if [[ ${1:-} == --user && ${2:-} == is-enabled ]]; then
    [[ ${FAKE_SYSTEMCTL_ENABLED:-0} == 1 ]] && exit 0
    exit 1
fi
exit 0
SYSTEMCTL

cat >"$harness/dnf" <<'DNF'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >> "$LOG"
exit 0
DNF

cat >"$harness/sh" <<'SH'
#!/usr/bin/env bash
printf 'sh %s\n' "$*" >> "$LOG"
cat >/dev/null
[[ -n ${FAKE_HOST_CLUSTER_TOOL_STATE:-} ]] && : >"$FAKE_HOST_CLUSTER_TOOL_STATE"
exit 0
SH

cat >"$harness/ssh" <<'SSH'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$LOG"
command=${!#}
case "$command" in
    *'command -v cluster-tool'*)
        [[ -n ${FAKE_HOST_CLUSTER_TOOL_STATE:-} && -e ${FAKE_HOST_CLUSTER_TOOL_STATE} ]] && exit 0
        exit 1
        ;;
    'id -u')
        printf '%s\n' "${FAKE_HOST_UID:-0}"
        exit 0
        ;;
esac
# Run the host command string against the local doubles so rpm, dnf and sh
# behave as they would on the cluster host. FAKE_HOST_BIN adds commands that
# exist there and not on this machine.
PATH="$HARNESS:${FAKE_HOST_BIN:-}:$PATH" bash -c "$command"
SSH

printf '#!/usr/bin/env bash\nexit 0\n' >"$hostbin/git"
chmod +x "$hostbin/git"
printf '#!/usr/bin/env bash\nexit 0\n' >"$harness/scp"
printf '#!/usr/bin/env bash\nexit 0\n' >"$harness/podman"
chmod +x "$harness"/*

# Workstation-only tools the setup target may install or report.
for tool in oc kubectl skaffold docker uv go cluster-tool; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$tools/$tool"
done
printf '#!/usr/bin/env bash\n[[ ${1:-} == version ]] && { printf "%%s\\n" "${FAKE_HELM_VERSION:-${HELM_PIN}+g0f00000}"; exit 0; }\nexit 0\n' >"$tools/helm"
for tool in skaffold; do
    printf '#!/usr/bin/env bash\n[[ ${1:-} == version ]] && echo v2.0.0\nexit 0\n' >"$tools/$tool"
done
chmod +x "$tools"/*

# A PATH with the plugin doubles removed, so the genuinely missing tools stay
# missing instead of resolving to whatever the developer machine has installed.
for tool in awk bash basename cat chmod cp cut dirname env getent gzip grep head install \
    make mkdir mktemp mv python3 rm sed sh sleep sort tail tar touch tr uname xargs; do
    resolved=$(command -v "$tool" || true)
    [[ -n "$resolved" ]] && ln -s "$resolved" "$minbin/$tool"
done

# The package set osac-dev-setup.sh installs on the cluster host.
host_packages='python3 git make curl tar dnsmasq nftables NetworkManager chrony libvirt-client podman'

base_env=(
    -u OSAC_DEV_TARGET -u OSAC_DEV_TARGET_DESCRIPTION -u REMOTE_HOST
    -u SUDO_USER -u DOCKER_HOST -u OSAC_DEV_SKAFFOLD_VERSION -u OSAC_DEV_HELM_VERSION
    -u FAKE_HELM_VERSION
)

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    [[ -f "$tmp/out" ]] && sed -n '1,80p' "$tmp/out" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$2" "$tmp/out" || fail "expected '$2' in the output ($1)"
}

assert_absent() {
    if grep -Fq -- "$2" "$tmp/out"; then fail "did not expect '$2' in the output ($1)"; fi
}

assert_log() {
    grep -Fq -- "$2" "$tmp/log" || fail "expected '$2' in the command log ($1)"
}

# run <case> <path> <expected-status> [VAR=value ...]
run() {
    local case_name=$1 path=$2 expected=$3
    shift 3
    : >"$tmp/log"
    local status=0
    env "${base_env[@]}" HOME="$tmp/home" PATH="$path" LOG="$tmp/log" \
        HARNESS="$harness" "$@" "$setup" >"$tmp/out" 2>&1 || status=$?
    [[ $status == "$expected" ]] || fail "$case_name: exit $status, expected $expected"
}

all_installed_path="$harness:$tools:$minbin"
missing_path="$harness:$minbin"

# --- everything present: no changes ------------------------------------------
run 'all-present' "$all_installed_path" 0 FAKE_UID=0 FAKE_RPM_INSTALLED="$host_packages" \
    FAKE_SYSTEMCTL_ENABLED=1 FAKE_HOST_CLUSTER_TOOL_STATE="$tmp/cluster-tool-state"
assert_contains 'all-present' "Helm ${pin} already installed"
assert_contains 'all-present' 'Skaffold already installed'
assert_contains 'all-present' 'docker CLI already present'
assert_contains 'all-present' 'podman.socket is already enabled'
assert_contains 'all-present' 'all osac-dev prerequisites are present'
assert_contains 'all-present' 'Next: podman login'
if grep -Eq 'curl -fsSL|dnf install|systemctl --user enable --now|sh -s' "$tmp/log"; then
    fail 'all-present: changed the system'
fi
[[ ! -e "$tmp/home/.local" ]] || fail 'all-present: created local tooling'

# --- fresh machine as root: installs what it can, reports the rest -----------
rm -rf "$tmp/home" "$tmp/cluster-tool-state"
mkdir -p "$tmp/home"
run 'fresh' "$missing_path" 1 FAKE_UID=0 FAKE_RPM_INSTALLED="python3 git make curl tar nftables NetworkManager chrony libvirt-client podman" \
    FAKE_HOST_CLUSTER_TOOL_STATE="$tmp/fresh-cluster-tool" DEV_ENV_NAME=lab
assert_contains 'fresh' "downloading Helm ${pin}"
assert_contains 'fresh' "installed Helm ${pin} into"
assert_contains 'fresh' 'downloading Skaffold latest'
assert_contains 'fresh' 'installed the docker->podman shim'
assert_contains 'fresh' 'installed Skaffold into'
assert_contains 'fresh' 'enabled and started podman.socket'
assert_contains 'fresh' 'installing on this host (localhost target): dnsmasq'
assert_contains 'fresh' 'install git on this host (localhost target), then re-run make osac-dev-setup for cluster-tool'
assert_contains 'fresh' 'remaining manual steps'
assert_contains 'fresh' 'install the OpenShift CLI (oc)'
assert_log 'fresh' "curl -fsSL -o"
assert_log 'fresh' 'systemctl --user is-enabled podman.socket'
assert_log 'fresh' 'systemctl --user enable --now podman.socket'
assert_log 'fresh' 'dnf install -y dnsmasq'
[[ -x "$tmp/home/.local/bin/skaffold" ]] || fail 'fresh: Skaffold was not installed'
[[ -x "$tmp/home/.local/bin/helm" ]] || fail 'fresh: Helm was not installed'
[[ $("$tmp/home/.local/bin/helm" version --short) == "${pin}+g0f00000" ]] || fail 'fresh: pinned Helm version is wrong'
grep -Fq 'exec podman' "$tmp/home/.local/bin/docker" || fail 'fresh: docker shim content is wrong'
if grep -Fq 'ssh ' "$tmp/log"; then fail 'fresh: localhost target used ssh'; fi

# --- an older Helm is replaced with the pinned version ----------------------
rm -rf "$tmp/home"
mkdir -p "$tmp/home"
run 'helm-pinned' "$all_installed_path" 0 FAKE_UID=0 FAKE_RPM_INSTALLED="$host_packages" \
    FAKE_SYSTEMCTL_ENABLED=1 FAKE_HOST_CLUSTER_TOOL_STATE="$tmp/cluster-tool-state" \
    FAKE_HELM_VERSION=v3.16.3+gcfd0749
assert_contains 'helm-pinned' "replacing Helm v3.16.3+gcfd0749 with the pinned ${pin}"
assert_contains 'helm-pinned' "installed Helm ${pin} into"
assert_log 'helm-pinned' "https://get.helm.sh/helm-${pin}-linux-amd64.tar.gz"
[[ $("$tmp/home/.local/bin/helm" version --short) == "${pin}+g0f00000" ]] || fail 'helm-pinned: installed Helm version is wrong'

# --- an older Helm that cannot be replaced is reported, not ignored ---------
rm -rf "$tmp/home"
mkdir -p "$tmp/home"
run 'helm-stale' "$all_installed_path" 1 FAKE_UID=0 FAKE_RPM_INSTALLED="$host_packages" \
    FAKE_SYSTEMCTL_ENABLED=1 FAKE_HOST_CLUSTER_TOOL_STATE="$tmp/cluster-tool-state" \
    FAKE_HELM_VERSION=v3.16.3+gcfd0749 FAKE_CURL_FAIL_HELM=1
assert_contains 'helm-stale' "download Helm ${pin} from https://get.helm.sh/helm-${pin}-linux-amd64.tar.gz into"
assert_contains 'helm-stale' "does not match the pinned ${pin}"
assert_contains 'helm-stale' "install Helm ${pin} into"
assert_contains 'helm-stale' 'remaining manual steps'

# --- non-root localhost: prints the sudo command instead of failing to run it -
rm -rf "$tmp/home"
mkdir -p "$tmp/home"
run 'non-root' "$all_installed_path" 1 FAKE_UID=1000 FAKE_RPM_INSTALLED="python3 git make curl tar dnsmasq nftables NetworkManager libvirt-client podman" \
    FAKE_HOST_CLUSTER_TOOL_STATE="$tmp/cluster-tool-state" DEV_ENV_NAME=lab
assert_contains 'non-root' 'sudo dnf install -y chrony'
assert_absent 'non-root' 'installing on this host'
assert_log 'non-root' 'rpm -q'
if grep -Fq 'dnf install' "$tmp/log"; then fail 'non-root: ran dnf without root'; fi
assert_contains 'non-root' 'remaining manual steps'

# --- non-root localhost with root-only gaps: nothing privileged runs ----------
rm -rf "$tmp/home"
mkdir -p "$tmp/home"
: >"$tmp/log"
status=0
env "${base_env[@]}" HOME="$tmp/home" PATH="$all_installed_path" LOG="$tmp/log" \
    HARNESS="$harness" FAKE_UID=0 FAKE_RPM_INSTALLED="$host_packages" SUDO_USER=developer \
    "$setup" >"$tmp/out" 2>&1 || status=$?
[[ $status == 0 ]] || fail "sudo-user: exit $status, expected 0"
assert_contains 'sudo-user' "skipping workstation tooling (Helm, Skaffold, docker shim, podman socket): it belongs to 'developer'"
if grep -Fq 'curl -fsSL' "$tmp/log"; then fail 'sudo-user: installed workstation tooling as root'; fi
if grep -Fq 'systemctl --user enable' "$tmp/log"; then fail 'sudo-user: enabled the socket for the wrong user'; fi

# --- remote target: host work over SSH, workstation work stays local ---------
rm -rf "$tmp/home"
mkdir -p "$tmp/home"
state="$tmp/remote-cluster-tool"
rm -f "$state"
run 'remote' "$missing_path" 1 REMOTE_HOST=root@fake.example FAKE_UID=1000 FAKE_HOST_UID=0 \
    FAKE_HOST_BIN="$hostbin" FAKE_RPM_INSTALLED="$host_packages" \
    FAKE_HOST_CLUSTER_TOOL_STATE="$state" DEV_ENV_NAME=lab
assert_contains 'remote' "downloading Helm ${pin}"
assert_contains 'remote' 'downloading Skaffold latest'
assert_contains 'remote' 'cluster host packages already present on root@fake.example'
assert_contains 'remote' 'installing cluster-tool on root@fake.example'
assert_log 'remote' 'curl -fsSL -o'
assert_log 'remote' 'ssh root@fake.example rpm -q'
assert_log 'remote' 'sh -s'
[[ -e "$state" ]] || { cat "$tmp/log" >&2; fail 'remote: cluster-tool install did not run on the host'; }
if grep -Eq 'ssh .*curl -fsSL' "$tmp/log"; then fail 'remote: workstation tooling was installed over SSH'; fi

# --- remote target with a missing host package ------------------------------
rm -rf "$tmp/home" "$state"
mkdir -p "$tmp/home"
run 'remote-packages' "$missing_path" 1 REMOTE_HOST=root@fake.example FAKE_HOST_UID=0 \
    FAKE_HOST_BIN="$hostbin" FAKE_RPM_INSTALLED="python3 git make curl tar dnsmasq nftables NetworkManager libvirt-client podman" \
    FAKE_HOST_CLUSTER_TOOL_STATE="$state" DEV_ENV_NAME=lab
assert_log 'remote-packages' 'ssh -tt root@fake.example dnf install -y chrony'
assert_contains 'remote-packages' 'installing on root@fake.example: chrony'

# --- dry run: plan only -----------------------------------------------------
rm -rf "$tmp/home"
mkdir -p "$tmp/home"
: >"$tmp/log"
status=0
env "${base_env[@]}" HOME="$tmp/home" PATH="$missing_path" LOG="$tmp/log" HARNESS="$harness" \
    FAKE_UID=0 FAKE_RPM_INSTALLED="python3 git make curl tar dnsmasq nftables NetworkManager libvirt-client podman" \
    FAKE_HOST_CLUSTER_TOOL_STATE="$tmp/dry-cluster-tool" DEV_ENV_NAME=lab \
    OSAC_DEV_SKAFFOLD_VERSION=2.16.1 "$setup" --dry-run >"$tmp/out" 2>&1 || status=$?
[[ $status == 0 ]] || fail "dry-run: exit $status, expected 0"
assert_contains 'dry-run' 'plan for the localhost target (dry run: nothing will change)'
assert_contains 'dry-run' "would download Helm ${pin} from https://get.helm.sh/helm-${pin}-linux-amd64.tar.gz"
assert_contains 'dry-run' 'would download Skaffold 2.16.1 from https://storage.googleapis.com/skaffold/releases/2.16.1/skaffold-linux-amd64'
assert_contains 'dry-run' 'would install the docker->podman shim'
assert_contains 'dry-run' 'would enable and start the rootless podman socket'
assert_contains 'dry-run' 'would install on this host (localhost target): chrony'
assert_contains 'dry-run' 'would install cluster-tool on this host (localhost target)'
assert_log 'dry-run' 'rpm -q'
if grep -Eq 'curl -fsSL|dnf install|systemctl --user enable --now|sh -s' "$tmp/log"; then
    fail 'dry-run: changed the system'
fi
[[ ! -e "$tmp/home/.local" ]] || fail 'dry-run: created local tooling'

# --- argument handling ------------------------------------------------------
status=0
env "${base_env[@]}" HOME="$tmp/home" PATH="$all_installed_path" LOG="$tmp/log" \
    HARNESS="$harness" "$setup" --nonsense >"$tmp/out" 2>&1 || status=$?
[[ $status == 1 ]] || fail 'unknown argument did not fail'
assert_contains 'unknown-argument' 'unknown argument: --nonsense'

env "${base_env[@]}" HOME="$tmp/home" PATH="$all_installed_path" LOG="$tmp/log" \
    HARNESS="$harness" "$setup" --help >"$tmp/out" 2>&1 || fail '--help failed'
assert_contains 'help' 'usage: osac-dev-setup.sh [--dry-run]'

# --- remote target without ssh transport ------------------------------------
status=0
env "${base_env[@]}" HOME="$tmp/home" PATH="$minbin" LOG="$tmp/log" HARNESS="$harness" \
    REMOTE_HOST=root@fake.example "$setup" >"$tmp/out" 2>&1 || status=$?
[[ $status == 1 ]] || fail 'remote target without ssh did not fail'
assert_contains 'no-ssh' 'required local command not found: ssh'

printf 'All setup installer tests passed.\n'
