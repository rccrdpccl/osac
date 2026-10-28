#!/usr/bin/env bash
# Contract tests for tools/osac-dev/osac-dev-target.sh, the single host seam.
#
# Every probe runs in its own bash process that sources the seam exactly the way
# the wrappers do, so the derived target, the root/transport guards, and the
# host operations can be asserted without any real SSH, scp, libvirt, or systemd.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
target="$repo/tools/osac-dev/osac-dev-target.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local expected=$1
    local file=$2
    grep -Fq -- "$expected" "$file" || fail "expected '$expected' in $file"
}

assert_not_contains() {
    local unexpected=$1
    local file=$2
    if grep -Fq -- "$unexpected" "$file"; then
        fail "did not expect '$unexpected' in $file"
    fi
}

[[ -f "$target" ]] || fail "host seam is missing: $target"

fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$FAKE_ROOT/commands"
case "$*" in
    -G*) printf 'user root\nhostname probe.example\n'; exit 0 ;;
esac
[[ ${FAKE_SSH_EXIT:-0} == 0 ]] || exit "$FAKE_SSH_EXIT"
case "$*" in
    *'id -u') printf '%s\n' "${FAKE_REMOTE_UID:-0}" ;;
    *'-N '*)
        # A forward stays alive like a real one until the probe kills it.
        sleep 300
        ;;
    *'command -v '*missing*' >/dev/null')
        exit 1
        ;;
    *'command -v'*)
        exit 0
        ;;
esac
exit 0
FAKE_SSH
chmod +x "$fake_bin/ssh"

cat > "$fake_bin/scp" <<'FAKE_SCP'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp %s\n' "$*" >> "$FAKE_ROOT/commands"
while [[ ${1:-} == -q || ${1:-} == -- ]]; do shift; done
source=${1:?missing source}
destination=${2:?missing destination}
if [[ "$source" == *:* ]]; then
    cp -- "$FAKE_ROOT/copy-fixture" "$destination"
else
    cp -- "$source" "$FAKE_ROOT/received"
fi
FAKE_SCP
chmod +x "$fake_bin/scp"

cat > "$fake_bin/getent" <<'FAKE_GETENT'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == ahostsv4 && ${2:-} == probe.example ]]; then
    printf '192.0.2.5 STREAM probe.example\n'
    exit 0
fi
exit 2
FAKE_GETENT
chmod +x "$fake_bin/getent"

cat > "$tmpdir/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$LIB"
osac_dev_target_init
eval "$BODY"
PROBE
chmod +x "$tmpdir/probe.sh"

# Usage: probe <output-file> [ENV=VALUE...] -- <body>
# Every probe starts without a target in the environment, like a fresh wrapper.
probe() {
    local output=$1
    shift
    local -a env_overrides=()
    while [[ $# -gt 0 && $1 != -- ]]; do
        env_overrides+=("$1")
        shift
    done
    [[ ${1:-} == -- ]] && shift
    env -u OSAC_DEV_TARGET -u OSAC_DEV_TARGET_DESCRIPTION -u REMOTE_HOST \
        PATH="$fake_bin:$PATH" \
        HOME="$tmpdir/home" \
        LIB="$target" \
        FAKE_ROOT="$tmpdir" \
        "${env_overrides[@]}" \
        BODY="$*" \
        "$tmpdir/probe.sh" > "$output" 2>&1
}

# A background forward logs from its own process, so give it a moment.
wait_for_line() {
    local pattern=$1
    local file=$2
    local attempt
    for attempt in $(seq 1 100); do
        grep -Fq -- "$pattern" "$file" && return 0
        sleep 0.05
    done
    fail "expected '$pattern' in $file"
}

assert_fails() {
    local output=$1
    local expected=$2
    shift 2
    if probe "$output" "$@"; then
        fail "probe should have failed: $expected"
    fi
    assert_contains "$expected" "$output"
}

: > "$tmpdir/commands"

# --- target resolution -----------------------------------------------------
# REMOTE_HOST is the only selector: unset and `localhost` mean the localhost
# target, and every other value stays a remote target.
for case_name in unset empty localhost remote loopback-v4 loopback-v6; do
    case "$case_name" in
        unset)        remote_host=() ;;
        empty)        remote_host=(REMOTE_HOST=) ;;
        localhost)    remote_host=(REMOTE_HOST=localhost) ;;
        remote)       remote_host=(REMOTE_HOST=root@probe.example) ;;
        loopback-v4)  remote_host=(REMOTE_HOST=127.0.0.1) ;;
        loopback-v6)  remote_host=(REMOTE_HOST=::1) ;;
    esac
    probe "$tmpdir/target-$case_name" "${remote_host[@]}" -- \
        'printf "TARGET=%s\nDESCRIPTION=%s\nREMOTE_HOST=%s\n" "$OSAC_DEV_TARGET" "$OSAC_DEV_TARGET_DESCRIPTION" "$REMOTE_HOST"'
    case "$case_name" in
        unset|empty|localhost)
            assert_contains 'TARGET=localhost' "$tmpdir/target-$case_name"
            assert_contains 'DESCRIPTION=this host (localhost target)' "$tmpdir/target-$case_name"
            assert_contains 'REMOTE_HOST=localhost' "$tmpdir/target-$case_name"
            ;;
        *)
            assert_contains 'TARGET=remote' "$tmpdir/target-$case_name"
            ;;
    esac
done
assert_contains 'DESCRIPTION=root@probe.example' "$tmpdir/target-remote"
assert_contains 'DESCRIPTION=127.0.0.1' "$tmpdir/target-loopback-v4"
assert_contains 'DESCRIPTION=::1' "$tmpdir/target-loopback-v6"

# The derived target is not a user knob.
assert_fails "$tmpdir/preset-target" 'OSAC_DEV_TARGET is derived from REMOTE_HOST and cannot be set' \
    OSAC_DEV_TARGET=localhost

# Only REMOTE_HOST is exported, so children re-derive the same target instead of
# inheriting a value they could not recompute.
probe "$tmpdir/exported" REMOTE_HOST=root@probe.example -- \
    'printf "REMOTE_HOST_EXPORTED=%s\nTARGET_EXPORTED=%s\n" \
        "$(bash -c "printf %s \"\${REMOTE_HOST:-}\"")" \
        "$(bash -c "printf %s \"\${OSAC_DEV_TARGET:-unset}\"")"'
assert_contains 'REMOTE_HOST_EXPORTED=root@probe.example' "$tmpdir/exported"
assert_contains 'TARGET_EXPORTED=unset' "$tmpdir/exported"

# --- root guard ------------------------------------------------------------
cat > "$fake_bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -u ]]; then printf '%s\n' "${FAKE_LOCAL_UID:-0}"; exit 0; fi
exec /usr/bin/id "$@"
FAKE_ID
chmod +x "$fake_bin/id"

probe "$tmpdir/root-local" FAKE_LOCAL_UID=0 -- 'osac_dev_require_root; printf "ROOT_OK\n"'
assert_contains 'ROOT_OK' "$tmpdir/root-local"
assert_not_contains 'ssh ' "$tmpdir/commands"

assert_fails "$tmpdir/root-local-fail" 'rerun as root' FAKE_LOCAL_UID=1000 -- 'osac_dev_require_root'

probe "$tmpdir/root-remote" REMOTE_HOST=root@probe.example FAKE_REMOTE_UID=0 -- \
    'osac_dev_require_root; printf "ROOT_OK\n"'
assert_contains 'ROOT_OK' "$tmpdir/root-remote"
assert_contains 'ssh root@probe.example id -u' "$tmpdir/commands"

assert_fails "$tmpdir/root-remote-fail" 'REMOTE_HOST must connect as root' \
    REMOTE_HOST=root@probe.example FAKE_REMOTE_UID=1000 -- 'osac_dev_require_root'
assert_fails "$tmpdir/root-remote-unreachable" "cannot connect to remote host 'root@probe.example'" \
    REMOTE_HOST=root@probe.example FAKE_SSH_EXIT=255 -- 'osac_dev_require_root'

rm -f "$fake_bin/id"

# --- transport guard ------------------------------------------------------
# The localhost target never needs ssh or scp, so a workstation without them
# still runs the whole workflow.
mkdir -p "$tmpdir/no-ssh"
for tool in bash env sh cp install; do
    real=$(command -v "$tool") || fail "cannot locate $tool"
    ln -sf "$real" "$tmpdir/no-ssh/$tool"
done
probe "$tmpdir/transport-local" PATH="$tmpdir/no-ssh" -- \
    'osac_dev_require_transport; printf "TRANSPORT_OK\n"'
assert_contains 'TRANSPORT_OK' "$tmpdir/transport-local"
assert_fails "$tmpdir/transport-remote" 'required local command not found: ssh' \
    PATH="$tmpdir/no-ssh" REMOTE_HOST=root@probe.example -- 'osac_dev_require_transport'

# --- host command execution -----------------------------------------------
: > "$tmpdir/commands"
probe "$tmpdir/run-local" FAKE_LOCAL_UID=0 -- \
    'osac_dev_host_run "printf \"LOCAL_RUN:%s\\n\" \"\$(hostname)\""'
assert_contains 'LOCAL_RUN:' "$tmpdir/run-local"
assert_not_contains 'ssh ' "$tmpdir/commands"

probe "$tmpdir/run-remote" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_run "virsh domblklist osac-dev" >/dev/null'
assert_contains 'ssh root@probe.example virsh domblklist osac-dev' "$tmpdir/commands"

printf 'payload\n' > "$tmpdir/payload"
probe "$tmpdir/run-stdin" FAKE_LOCAL_UID=0 -- \
    'osac_dev_host_run_with_stdin "cat" "$FAKE_ROOT/payload"'
assert_contains 'payload' "$tmpdir/run-stdin"
probe "$tmpdir/run-stdin-remote" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_run_with_stdin "bash -s up" "$FAKE_ROOT/payload"'
assert_contains 'ssh root@probe.example bash -s up' "$tmpdir/commands"

probe "$tmpdir/run-on-remote" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_run_on root@jump.example "systemctl is-active --quiet x.timer" || true'
assert_contains 'ssh root@jump.example systemctl is-active --quiet x.timer' "$tmpdir/commands"
assert_fails "$tmpdir/run-on-local" 'an explicit SSH host is only reachable from a remote target' \
    -- 'osac_dev_host_run_on root@jump.example true'

# --- host capability checks ------------------------------------------------
probe "$tmpdir/has-local" FAKE_LOCAL_UID=0 -- 'osac_dev_host_has_command bash && printf "HAS_BASH\n"'
assert_contains 'HAS_BASH' "$tmpdir/has-local"
probe "$tmpdir/has-local-missing" FAKE_LOCAL_UID=0 -- \
    'osac_dev_host_has_command missing-tool || printf "MISSING\n"'
assert_contains 'MISSING' "$tmpdir/has-local-missing"
probe "$tmpdir/has-remote" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_has_command cluster-tool && printf "HAS_REMOTE\n"'
assert_contains 'HAS_REMOTE' "$tmpdir/has-remote"
# A dropped connection must not look like a missing dependency.
assert_fails "$tmpdir/has-remote-unreachable" "SSH connection to 'root@probe.example' failed" \
    REMOTE_HOST=root@probe.example FAKE_SSH_EXIT=255 -- 'osac_dev_host_has_command cluster-tool'

# --- file copies -----------------------------------------------------------
printf 'fixture\n' > "$tmpdir/copy-fixture"
: > "$tmpdir/commands"
probe "$tmpdir/copy-local-in" FAKE_LOCAL_UID=0 -- \
    'osac_dev_host_copy_from "$FAKE_ROOT/copy-fixture" "$FAKE_ROOT/local-copy"'
cmp -s "$tmpdir/copy-fixture" "$tmpdir/local-copy" || fail 'localhost copy_from did not copy the file'
assert_not_contains 'scp ' "$tmpdir/commands"

probe "$tmpdir/copy-remote-in" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_copy_from /root/license.zip "$FAKE_ROOT/remote-copy"'
assert_contains 'scp -q -- root@probe.example:/root/license.zip' "$tmpdir/commands"
cmp -s "$tmpdir/copy-fixture" "$tmpdir/remote-copy" || fail 'remote copy_from did not copy the file'

probe "$tmpdir/copy-local-out" FAKE_LOCAL_UID=0 -- \
    'osac_dev_host_copy_to "$FAKE_ROOT/payload" "$FAKE_ROOT/local-out"'
cmp -s "$tmpdir/payload" "$tmpdir/local-out" || fail 'localhost copy_to did not copy the file'
probe "$tmpdir/copy-remote-out" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_copy_to "$FAKE_ROOT/payload" /root/.kube/x.kubeconfig'
assert_contains 'root@probe.example:/root/.kube/x.kubeconfig' "$tmpdir/commands"
cmp -s "$tmpdir/payload" "$tmpdir/received" || fail 'remote copy_to did not copy the file'

# --- temporary directories and removal ------------------------------------
probe "$tmpdir/mktemp-local" FAKE_LOCAL_UID=0 -- \
    'dir=$(osac_dev_host_mktemp_dir "$FAKE_ROOT/work.XXXXXX"); stat -c "%a" "$dir"; printf "\n"; rmdir "$dir"'
assert_contains '700' "$tmpdir/mktemp-local"
probe "$tmpdir/mktemp-remote" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_mktemp_dir "/tmp/work.XXXXXX" >/dev/null'
assert_contains "umask 077; mktemp -d /tmp/work.XXXXXX" "$tmpdir/commands"

mkdir -p "$tmpdir/scratch"
probe "$tmpdir/remove-local" FAKE_LOCAL_UID=0 -- \
    'mkdir -p "$FAKE_ROOT/scratch/x"; osac_dev_host_remove "$FAKE_ROOT/scratch/x"; [[ ! -e "$FAKE_ROOT/scratch/x" ]]'
probe "$tmpdir/remove-remote" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_remove "/root/.kube/staged"'
assert_contains 'ssh root@probe.example rm -rf -- /root/.kube/staged' "$tmpdir/commands"

# --- port forwards ---------------------------------------------------------
probe "$tmpdir/tunnel-remote" REMOTE_HOST=root@probe.example -- \
    'pid=$(osac_dev_host_open_tunnel 127.0.0.1:16443:127.0.0.1:6443 "$FAKE_ROOT/tunnel.log")
     [[ "$pid" =~ ^[0-9]+$ ]] && printf "TUNNEL_PID\n"
     sleep 0.3; kill "$pid" 2>/dev/null || true'
assert_contains 'TUNNEL_PID' "$tmpdir/tunnel-remote"
wait_for_line 'ssh -o ExitOnForwardFailure=yes -N -L 127.0.0.1:16443:127.0.0.1:6443 root@probe.example' "$tmpdir/commands"
assert_fails "$tmpdir/tunnel-local" 'a port forward is only needed for a remote target' \
    -- 'osac_dev_host_open_tunnel 127.0.0.1:16443:127.0.0.1:6443 "$FAKE_ROOT/tunnel.log"'

probe "$tmpdir/socks-remote" REMOTE_HOST=root@probe.example -- \
    'pid=$(osac_dev_host_open_socks 1080 "$FAKE_ROOT/socks.log")
     [[ "$pid" =~ ^[0-9]+$ ]] && printf "SOCKS_PID\n"
     sleep 0.3; kill "$pid" 2>/dev/null || true'
assert_contains 'SOCKS_PID' "$tmpdir/socks-remote"
wait_for_line 'ssh -o ExitOnForwardFailure=yes -N -D 127.0.0.1:1080 root@probe.example' "$tmpdir/commands"
probe "$tmpdir/socks-remote-host" REMOTE_HOST=root@probe.example -- \
    'pid=$(osac_dev_host_open_socks 1080 "$FAKE_ROOT/socks.log" root@jump.example)
     sleep 0.3; kill "$pid" 2>/dev/null || true'
wait_for_line 'ssh -o ExitOnForwardFailure=yes -N -D 127.0.0.1:1080 root@jump.example' "$tmpdir/commands"
assert_fails "$tmpdir/socks-local" 'a SOCKS proxy is only needed for a remote target' \
    -- 'osac_dev_host_open_socks 1080 "$FAKE_ROOT/socks.log"'

# A NetworkManager restart can drop a remote session; the localhost target has
# nothing to wait for.
probe "$tmpdir/wait-local" FAKE_LOCAL_UID=0 -- \
    'SECONDS=0; osac_dev_host_wait_reconnect 30 2; printf "WAITED=%s\n" "$SECONDS"'
assert_contains 'WAITED=0' "$tmpdir/wait-local"

# --- DNS helper installation ----------------------------------------------
printf '#!/usr/bin/env python3\nprint("helper")\n' > "$tmpdir/dns-helper-source"
mkdir -p "$tmpdir/dns"

cat > "$fake_bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -u ]]; then printf '%s\n' "${FAKE_LOCAL_UID:-0}"; exit 0; fi
exec /usr/bin/id "$@"
FAKE_ID
chmod +x "$fake_bin/id"

: > "$tmpdir/commands"
probe "$tmpdir/dns-local" FAKE_LOCAL_UID=0 -- \
    'osac_dev_host_install_dns_helper "$FAKE_ROOT/dns-helper-source" "$FAKE_ROOT/dns/osac-dev-dns"
     stat -c "%a" "$FAKE_ROOT/dns/osac-dev-dns"; printf "\n"'
assert_contains '755' "$tmpdir/dns-local"
cmp -s "$tmpdir/dns-helper-source" "$tmpdir/dns/osac-dev-dns" || fail 'localhost DNS helper was not installed'
[[ ! -e "$tmpdir/dns/osac-dev-dns.pending" ]] || fail 'pending DNS helper was left behind'
assert_not_contains 'ssh ' "$tmpdir/commands"
assert_fails "$tmpdir/dns-local-unprivileged" 'installing the host DNS helper requires root' \
    FAKE_LOCAL_UID=1000 -- \
    'osac_dev_host_install_dns_helper "$FAKE_ROOT/dns-helper-source" "$FAKE_ROOT/dns/unprivileged"'
[[ ! -e "$tmpdir/dns/unprivileged" && ! -e "$tmpdir/dns/unprivileged.pending" ]] || \
    fail 'unprivileged install wrote the DNS helper'

rm -f "$fake_bin/id"
probe "$tmpdir/dns-remote" REMOTE_HOST=root@probe.example -- \
    'osac_dev_host_install_dns_helper "$FAKE_ROOT/dns-helper-source" "/usr/local/sbin/osac-dev-dns"'
assert_contains "install -m 0755 /dev/stdin /usr/local/sbin/osac-dev-dns.pending; mv -- /usr/local/sbin/osac-dev-dns.pending /usr/local/sbin/osac-dev-dns" "$tmpdir/commands"

# --- host address ----------------------------------------------------------
probe "$tmpdir/address-local" FAKE_LOCAL_UID=0 -- 'osac_dev_host_address'
assert_contains '127.0.0.1' "$tmpdir/address-local"
probe "$tmpdir/address-remote" REMOTE_HOST=root@probe.example -- 'osac_dev_host_address'
assert_contains '192.0.2.5' "$tmpdir/address-remote"

printf 'All host seam tests passed.\n'
