#!/usr/bin/env bash
# Contract tests for tools/osac-dev/osac-dev-grow-storage.sh.
#
# Every external command (ssh, oc) is faked and logged. The fake ssh models
# virsh domblklist/domblkinfo/blockresize with a "grown" marker switching the
# reported capacities; the fake oc returns the node name and captures the
# base64-carried guest script out of the oc debug command line so its
# content can be asserted.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
wrapper="$repo/tools/osac-dev/osac-dev-grow-storage.sh"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

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

[[ -x "$wrapper" ]] || fail "grow-storage wrapper is missing or not executable: $wrapper"

fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$FAKE_ROOT/commands"
case "$*" in
    *"virsh domblklist 'test-infra-cluster-osac-dev-master-0'"*)
        printf '  Target   Source\n'
        printf '  -----------------------------------------\n'
        printf '  sda      /data/overlays/osac-dev-disk-0.qcow2\n'
        printf '  sdb      /data/overlays/osac-dev-disk-1.qcow2\n'
        ;;
    *'--capacity'*)
        printf "error: command 'domblkinfo' doesn't support option --capacity\n" >&2
        exit 1
        ;;
    *domblkinfo*)
        if [[ -e "$FAKE_ROOT/grown" ]]; then
            printf 'Capacity:       214748364800\n'
        else
            printf 'Capacity:       100000000000\n'
        fi
        ;;
    *blockresize*)
        touch "$FAKE_ROOT/blockresized"
        ;;
    *' id -u')
        printf '0\n'
        ;;
esac
FAKE_SSH
chmod +x "$fake_bin/ssh"

cat > "$fake_bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then
    printf '%s\n' "${FAKE_UID:-0}"
    exit 0
fi
exec /usr/bin/id "$@"
FAKE_ID
chmod +x "$fake_bin/id"

cat > "$fake_bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}
shift || true
printf 'oc %s\n' "$cmd $*" >> "$FAKE_ROOT/commands"
if [[ "$cmd" == get && "$*" == *'.items[0].metadata.name'* ]]; then
    printf '%s\n' "${FAKE_NODE:-test-infra-cluster-osac-dev-master-0}"
    exit 0
fi
if [[ "$cmd" == debug ]]; then
    # Capture the base64-carried guest script for content assertions.
    b64=$(printf '%s\n' "$*" | sed -n "s/.*printf %s '\([A-Za-z0-9+/=]*\)'.*/\1/p")
    if [[ -n "$b64" ]]; then
        printf '%s' "$b64" | base64 -d > "$FAKE_ROOT/grow-script.sh"
    fi
    printf 'guest grow complete\n'
    exit 0
fi
exit 0
FAKE_OC
chmod +x "$fake_bin/oc"

setup_case() {
    local name=$1
    CASE_ROOT="$tmpdir/$name"
    mkdir -p "$CASE_ROOT"
    printf 'apiVersion: v1\nkind: Config\n' > "$CASE_ROOT/kubeconfig"
    chmod 600 "$CASE_ROOT/kubeconfig"
    : > "$CASE_ROOT/commands"
}

run_wrapper() {
    local output=$1
    shift
    env \
        PATH="$fake_bin:$PATH" \
        FAKE_ROOT="$CASE_ROOT" \
        REMOTE_HOST=root@fake.example.com \
        OSAC_DEV_KUBECONFIG="$CASE_ROOT/kubeconfig" \
        "$@" \
        "$wrapper" > "$output" 2>&1
}

run_local_wrapper() {
    local output=$1
    shift
    env \
        PATH="$CASE_ROOT/bin:$fake_bin:$PATH" \
        FAKE_ROOT="$CASE_ROOT" \
        REMOTE_HOST='' \
        OSAC_DEV_KUBECONFIG="$CASE_ROOT/kubeconfig" \
        "$@" \
        "$wrapper" > "$output" 2>&1
}

# A missing REMOTE_HOST selects the localhost target and runs virsh here.
setup_case local
mkdir -p "$CASE_ROOT/bin"
cat > "$CASE_ROOT/bin/virsh" <<'FAKE_VIRSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'virsh %s\n' "$*" >> "$FAKE_ROOT/commands"
case "${1:-}" in
    domblklist)
        printf '  Target   Source\n'
        printf '  sda      /data/overlays/osac-dev-disk-0.qcow2\n'
        printf '  sdb      /data/overlays/osac-dev-disk-1.qcow2\n'
        ;;
    domblkinfo)
        printf 'Capacity:       100000000000\n'
        ;;
    blockresize)
        touch "$FAKE_ROOT/blockresized"
        ;;
esac
FAKE_VIRSH
chmod +x "$CASE_ROOT/bin/virsh"
run_local_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'localhost grow run failed'
}
# A local shell consumes the quoting, so the recorded argv is unquoted.
assert_contains 'virsh blockresize test-infra-cluster-osac-dev-master-0 /data/overlays/osac-dev-disk-0.qcow2 200G' "$CASE_ROOT/commands"
assert_not_contains 'ssh ' "$CASE_ROOT/commands"
[[ -e "$CASE_ROOT/blockresized" ]] || fail 'localhost blockresize was not invoked'
assert_contains 'storage growth complete' "$CASE_ROOT/out"

# The localhost target refuses to touch libvirt without root.
setup_case local-unprivileged
mkdir -p "$CASE_ROOT/bin"
cp "$tmpdir/local/bin/virsh" "$CASE_ROOT/bin/virsh" 2>/dev/null || true
if run_local_wrapper "$CASE_ROOT/out" FAKE_UID=1000; then
    fail 'localhost grow run should require root'
fi
assert_contains 'as root' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'commands ran without root on the localhost target'

# An invalid target fails validation.
setup_case invalid-target
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_DISK_TARGET=200; then
    fail 'wrapper should fail for an invalid target'
fi
assert_contains 'OSAC_DEV_DISK_TARGET must be' "$CASE_ROOT/out"

# A missing kubeconfig fails before any command runs.
setup_case missing-kubeconfig
if env PATH="$fake_bin:$PATH" FAKE_ROOT="$CASE_ROOT" \
        REMOTE_HOST=root@fake.example.com \
        OSAC_DEV_KUBECONFIG="$CASE_ROOT/absent.kubeconfig" \
        "$wrapper" > "$CASE_ROOT/out" 2>&1; then
    fail 'wrapper should fail without a kubeconfig'
fi
assert_contains 'kubeconfig not found' "$CASE_ROOT/out"

# A kubeconfig pointing to another clone must never resize that clone's VM.
setup_case wrong-cluster
if run_wrapper "$CASE_ROOT/out" FAKE_NODE=test-infra-cluster-demo-dev-master-0; then
    fail 'accepted a node outside the selected clone'
fi
assert_not_contains 'virsh' "$CASE_ROOT/commands"

# Disks below the target are grown: blockresize for both disks and the
# guest-side script carries growpart, xfs_growfs, pvresize, and the guarded
# thin-pool extension.
setup_case grow
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'grow run failed'
}
assert_contains "virsh blockresize 'test-infra-cluster-osac-dev-master-0' '/data/overlays/osac-dev-disk-0.qcow2' '200G'" "$CASE_ROOT/commands"
assert_contains "virsh blockresize 'test-infra-cluster-osac-dev-master-0' '/data/overlays/osac-dev-disk-1.qcow2' '200G'" "$CASE_ROOT/commands"
[[ -e "$CASE_ROOT/blockresized" ]] || fail 'blockresize was not invoked'
[[ -f "$CASE_ROOT/grow-script.sh" ]] || fail 'the guest grow script was not captured'
assert_contains 'growpart "$root_dev" 4' "$CASE_ROOT/grow-script.sh"
assert_not_contains 'chroot /host' "$CASE_ROOT/grow-script.sh"
assert_contains "bash -s -- '/dev/sda' '/dev/sdb'" "$CASE_ROOT/commands"
assert_contains 'xfs_growfs /var' "$CASE_ROOT/grow-script.sh"
assert_contains 'pvresize "$lvm_dev"' "$CASE_ROOT/grow-script.sh"
assert_contains 'lvextend -l +100%FREE vg1/thin-pool-1' "$CASE_ROOT/grow-script.sh"
assert_contains 'guest grow complete' "$CASE_ROOT/out"
assert_contains 'storage growth complete' "$CASE_ROOT/out"

# Disks already at the target are skipped remotely; the idempotent guest
# side still runs.
setup_case already-grown
touch "$CASE_ROOT/grown"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'already-grown run failed'
}
assert_not_contains 'blockresize' "$CASE_ROOT/commands"
assert_contains 'already at 200G; skipping' "$CASE_ROOT/out"
assert_contains 'guest grow complete' "$CASE_ROOT/out"

# User overrides must never weaken the 200 GiB minimum.
setup_case too-small
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_DISK_TARGET=100G; then
    fail 'accepted a disk target below 200 GiB'
fi
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'commands ran with an undersized target'

# Execute the actual carried guest script; mocks cannot merely assert strings.
setup_case guest-script
run_wrapper "$CASE_ROOT/out"
mkdir -p "$CASE_ROOT/bin"
for command in growpart xfs_growfs pvs pvresize vgs lvextend blockdev findmnt; do
    cat > "$CASE_ROOT/bin/$command" <<'GUEST_COMMAND'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$FAKE_ROOT/guest-commands"
case "${0##*/}" in
    growpart) printf 'NOCHANGE: partition 4 is size unchanged\n'; exit 1 ;;
    findmnt) printf '/dev/sda4[/ostree/deploy/rhcos/var]\n' ;;
    blockdev) printf '214748364800\n' ;;
    vgs) printf '0\n' ;;
esac
GUEST_COMMAND
    chmod +x "$CASE_ROOT/bin/$command"
done
if ! PATH="$CASE_ROOT/bin:$PATH" FAKE_ROOT="$CASE_ROOT" bash "$CASE_ROOT/grow-script.sh" /dev/sda /dev/sdb 214748364800 > "$CASE_ROOT/guest-out" 2>&1; then
    cat "$CASE_ROOT/guest-out" >&2
    fail 'repeated guest-side growth failed'
fi
assert_contains 'xfs_growfs /var' "$CASE_ROOT/guest-commands"
assert_contains 'pvresize /dev/sdb' "$CASE_ROOT/guest-commands"
assert_not_contains 'lvextend' "$CASE_ROOT/guest-commands"
assert_contains 'guest grow complete' "$CASE_ROOT/guest-out"

# RHCOS may not include cloud-utils-growpart. Exercise util-linux fallback.
rm "$CASE_ROOT/bin/growpart"
for command in sfdisk partx; do
    cat > "$CASE_ROOT/bin/$command" <<'FALLBACK'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$FAKE_ROOT/guest-commands"
if [[ $1 == --dump ]]; then
    printf '/dev/sda4 : start=1050624, size=194261369\n'
else
    cat >> "$FAKE_ROOT/partition-input"
fi
FALLBACK
    chmod +x "$CASE_ROOT/bin/$command"
done
# partx has no stdin; keep the recording stub simple.
printf '#!/usr/bin/env bash\nprintf "partx %%s\\n" "$*" >> "$FAKE_ROOT/guest-commands"\n' > "$CASE_ROOT/bin/partx"
if ! PATH="$CASE_ROOT/bin:$PATH" FAKE_ROOT="$CASE_ROOT" bash "$CASE_ROOT/grow-script.sh" /dev/sda /dev/sdb 214748364800 > "$CASE_ROOT/fallback-out" 2>&1; then
    cat "$CASE_ROOT/fallback-out" >&2
    fail 'guest growth needs an unavailable growpart command'
fi
assert_contains 'sfdisk --no-reread --force -N 4 /dev/sda' "$CASE_ROOT/guest-commands"
assert_contains 'partx --update --nr 4 /dev/sda' "$CASE_ROOT/guest-commands"
printf 'All grow-storage wrapper tests passed.\n'
