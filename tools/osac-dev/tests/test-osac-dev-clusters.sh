#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
remote_script="$repo/tools/osac-dev/osac-dev.sh"
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

setup_fake_remote() {
    local root=$1
    mkdir -p "$root/bin" "$root/state" "$root/etc/NetworkManager/conf.d" \
        "$root/etc/NetworkManager/dnsmasq.d"
    : > "$root/state/flavors"
    : > "$root/state/clones"
    : > "$root/state/commands"
    : > "$root/etc/resolv.conf"

    cat > "$root/bin/cluster-tool" <<'FAKE_CLUSTER_TOOL'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:?missing command}
shift
printf '%s' "$cmd" >> "$FAKE_CLUSTER_TOOL_LOG"
printf ' %s' "$@" >> "$FAKE_CLUSTER_TOOL_LOG"
printf '\n' >> "$FAKE_CLUSTER_TOOL_LOG"

case "$cmd" in
    servers)
        if [[ -f "$FAKE_CLUSTER_TOOL_STATE/server" ]]; then
            printf 'NAME HOST DEFAULT\nlocal local *\n'
        else
            printf 'No servers connected.\n'
        fi
        ;;
    setup)
        [[ ${1:-} == client ]] || exit 64
        mkdir -p "$OSAC_DEV_DNSMASQ_DIR" "$(dirname -- "$OSAC_DEV_NM_CONF")"
        printf 'dns=dnsmasq\n' > "$OSAC_DEV_NM_CONF"
        printf 'nameserver 127.0.0.1\n' > "$OSAC_DEV_RESOLV_CONF"
        touch "$FAKE_CLUSTER_TOOL_STATE/dns-ready"
        ;;
    connect)
        [[ ${1:-} == local ]] || exit 64
        touch "$FAKE_CLUSTER_TOOL_STATE/server"
        ;;
    flavors)
        if [[ -s "$FAKE_CLUSTER_TOOL_STATE/flavors" ]]; then
            printf 'NAME SOURCE RAM CPU DISKS CREATED\n'
            while IFS= read -r flavor; do
                [[ -n "$flavor" ]] && printf '%s source 64GB 16 1 now\n' "$flavor"
            done < "$FAKE_CLUSTER_TOOL_STATE/flavors"
        else
            printf 'No flavors available.\n'
        fi
        ;;
    pull)
        image=
        for arg in "$@"; do
            case "$arg" in
                quay.io/*:*) image=$arg ;;
            esac
        done
        [[ -n "$image" ]] || exit 65
        printf '%s\n' "${image##*:}" >> "$FAKE_CLUSTER_TOOL_STATE/flavors"
        ;;
    list)
        if [[ -s "$FAKE_CLUSTER_TOOL_STATE/clones" ]]; then
            printf 'NAME FLAVOR SUBNET CREATED\n'
            while IFS='|' read -r name flavor; do
                [[ -n "$name" ]] && printf '%s %s 192.168.1.0/24 now\n' "$name" "$flavor"
            done < "$FAKE_CLUSTER_TOOL_STATE/clones"
        else
            printf 'No clones running.\n'
        fi
        ;;
    boot)
        name=
        flavor=
        pull_secret=
        while (($#)); do
            case "$1" in
                --name) name=$2; shift 2 ;;
                --flavor) flavor=$2; shift 2 ;;
                --pull-secret) pull_secret=$2; shift 2 ;;
                --server) shift 2 ;;
                *) shift ;;
            esac
        done
        [[ -n "$name" && -n "$flavor" && -r "$pull_secret" ]] || exit 66
        printf '%s|%s\n' "$name" "$flavor" >> "$FAKE_CLUSTER_TOOL_STATE/clones"
        ;;
    destroy)
        name=
        skip_next=0
        for arg in "$@"; do
            if ((skip_next)); then
                skip_next=0
                continue
            fi
            case "$arg" in
                --server) skip_next=1 ;;
                --*) ;;
                *) name=$arg ;;
            esac
        done
        [[ -n "$name" ]] || exit 67
        awk -F'|' -v name="$name" '$1 != name' "$FAKE_CLUSTER_TOOL_STATE/clones" \
            > "$FAKE_CLUSTER_TOOL_STATE/clones.tmp"
        mv "$FAKE_CLUSTER_TOOL_STATE/clones.tmp" "$FAKE_CLUSTER_TOOL_STATE/clones"
        ;;
    *)
        printf 'unexpected cluster-tool command: %s\n' "$cmd" >&2
        exit 68
        ;;
esac
FAKE_CLUSTER_TOOL
    chmod +x "$root/bin/cluster-tool"

    cat > "$root/bin/dnsmasq" <<'FAKE_DNSMASQ'
#!/usr/bin/env sh
exit 0
FAKE_DNSMASQ
    chmod +x "$root/bin/dnsmasq"

    cat > "$root/bin/id" <<'FAKE_ID'
#!/usr/bin/env sh
if [ "${1:-}" = -u ]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
FAKE_ID
    chmod +x "$root/bin/id"
}

run_remote() {
    local root=$1
    shift
    env \
        PATH="$root/bin:$PATH" \
        FAKE_CLUSTER_TOOL_LOG="$root/state/commands" \
        FAKE_CLUSTER_TOOL_STATE="$root/state" \
        OSAC_DEV_DNSMASQ_DIR="$root/etc/NetworkManager/dnsmasq.d" \
        OSAC_DEV_NM_CONF="$root/etc/NetworkManager/conf.d/cluster-tool-dns.conf" \
        OSAC_DEV_RESOLV_CONF="$root/etc/resolv.conf" \
        OSAC_DEV_DNS_HELPER="$root/dns-helper.py" \
        "$@"
}

# A short default name maps to one SNO development cluster.
setup_fake_remote "$tmpdir/default"
plan="$tmpdir/default-plan"
run_remote "$tmpdir/default" env DEV_ENV_NAME=osac "$remote_script" plan > "$plan" 2>&1 || true
assert_contains 'cluster=missing' "$plan"
assert_contains 'sno_flavor=missing' "$plan"
assert_contains 'cluster_name=osac-dev' "$plan"
assert_not_contains 'bm_cnv' "$plan"

# Preparation sets up DNS first, connects the server, then pulls only sno-4-22.
setup_fake_remote "$tmpdir/prepare"
run_remote "$tmpdir/prepare" env DEV_ENV_NAME=osac "$remote_script" prepare > "$tmpdir/prepare.out" 2>&1
commands="$tmpdir/prepare/state/commands"
assert_contains 'setup client' "$commands"
assert_contains 'connect local --host local' "$commands"
assert_contains 'quay.io/osac-project/cluster-flavors:sno-4-22' "$commands"
assert_not_contains 'caas-4-22' "$commands"
assert_not_contains 'vmaas-4-22' "$commands"
setup_line=$(grep -n '^setup client' "$commands" | cut -d: -f1)
connect_line=$(grep -n '^connect local' "$commands" | cut -d: -f1)
((setup_line < connect_line)) || fail 'dnsmasq client setup must precede cluster-tool connect'

# An existing development cluster is reused without pulling its flavor.
setup_fake_remote "$tmpdir/existing"
printf 'sno-4-22\n' > "$tmpdir/existing/state/flavors"
printf 'osac-dev|sno-4-22\n' > "$tmpdir/existing/state/clones"
touch "$tmpdir/existing/state/server"
printf 'dns=dnsmasq\n' > "$tmpdir/existing/etc/NetworkManager/conf.d/cluster-tool-dns.conf"
printf 'nameserver 127.0.0.1\n' > "$tmpdir/existing/etc/resolv.conf"
run_remote "$tmpdir/existing" env DEV_ENV_NAME=osac "$remote_script" prepare > "$tmpdir/existing.out" 2>&1
if grep -q '^pull ' "$tmpdir/existing/state/commands"; then
    fail 'prepare pulled a flavor for a cluster that already exists'
fi

# Reuse a selected cluster by name even when its recorded flavor differs.
setup_fake_remote "$tmpdir/mismatch"
printf 'caas-4-22\n' > "$tmpdir/mismatch/state/flavors"
printf 'osac-dev|caas-4-22\n' > "$tmpdir/mismatch/state/clones"
touch "$tmpdir/mismatch/state/server"
plan="$tmpdir/mismatch-plan"
run_remote "$tmpdir/mismatch" env DEV_ENV_NAME=osac "$remote_script" plan > "$plan" 2>&1
assert_contains 'cluster=present' "$plan"
assert_contains 'cluster_flavor=caas-4-22' "$plan"
run_remote "$tmpdir/mismatch" env DEV_ENV_NAME=osac "$remote_script" status > "$tmpdir/mismatch-status.out" 2>&1
assert_contains 'Development cluster (osac-dev) uses flavor caas-4-22' "$tmpdir/mismatch-status.out"
run_remote "$tmpdir/mismatch" env DEV_ENV_NAME=osac "$remote_script" boot > "$tmpdir/mismatch.out" 2>&1 || \
    fail 'boot should reuse a selected cluster with a different flavor'
assert_contains 'Reusing existing cluster osac-dev (flavor caas-4-22)' "$tmpdir/mismatch.out"
assert_not_contains 'boot --server local' "$tmpdir/mismatch/state/commands"

# Booting a new environment provisions one SNO cluster with the temporary pull secret.
setup_fake_remote "$tmpdir/boot"
run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac "$remote_script" prepare >/dev/null
printf '{}\n' > "$tmpdir/pull-secret.json"
run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac PULL_SECRET_PATH="$tmpdir/pull-secret.json" \
    "$remote_script" boot > "$tmpdir/boot.out" 2>&1
assert_contains 'boot --server local --flavor sno-4-22 --name osac-dev' "$tmpdir/boot/state/commands"
assert_not_contains 'osac-bme' "$tmpdir/boot/state/commands"
[[ -e "$tmpdir/pull-secret.json" ]] || fail 'remote lifecycle script deleted the caller-owned secret'

# Repeated runs reuse the selected cluster and do not require a pull secret.
: > "$tmpdir/boot/state/commands"
run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac "$remote_script" prepare >/dev/null
run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac "$remote_script" boot > "$tmpdir/reuse.out" 2>&1
if grep -q '^boot ' "$tmpdir/boot/state/commands"; then
    fail 'repeat run booted an existing cluster'
fi
assert_contains 'Reusing existing SNO cluster osac-dev' "$tmpdir/reuse.out"

# Teardown is scoped to the selected development cluster and leaves unrelated clones alone.
printf 'other-cluster|sno-4-22\n' >> "$tmpdir/boot/state/clones"
run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac "$remote_script" down > "$tmpdir/down.out" 2>&1
assert_contains 'destroy osac-dev --server local' "$tmpdir/boot/state/commands"
assert_not_contains 'destroy osac-bme' "$tmpdir/boot/state/commands"
assert_not_contains 'destroy --all' "$tmpdir/boot/state/commands"
grep -Fq 'other-cluster|sno-4-22' "$tmpdir/boot/state/clones" || fail 'teardown removed an unrelated cluster'

# A configured helper owns quiescence, baseline recovery and selected cleanup.
cat > "$tmpdir/boot/dns-helper.py" <<'FAKE_DNS_HELPER'
import os
import subprocess
import sys
with open(os.environ['FAKE_CLUSTER_TOOL_LOG'], 'a') as log:
    log.write('dns-helper ' + ' '.join(sys.argv[1:]) + '\n')
if os.environ.get('FAKE_DNS_HELPER_FAIL') == '1':
    sys.exit(23)
if sys.argv[1] == 'destroy':
    subprocess.run([sys.argv[4], 'destroy', sys.argv[2], '--server', 'local'], check=True)
FAKE_DNS_HELPER
printf 'osac-dev|sno-4-22\nother-cluster|sno-4-22\n' > "$tmpdir/boot/state/clones"
: > "$tmpdir/boot/state/commands"
if run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac FAKE_DNS_HELPER_FAIL=1 \
    "$remote_script" down > "$tmpdir/helper-fail.out" 2>&1; then
    fail 'DNS quiescence failure should prevent destruction'
fi
assert_not_contains 'destroy osac-dev --server local' "$tmpdir/boot/state/commands"
run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac "$remote_script" down > "$tmpdir/managed-down.out" 2>&1
assert_contains 'dns-helper destroy osac-dev --cluster-tool cluster-tool' "$tmpdir/boot/state/commands"
assert_contains 'destroy osac-dev --server local' "$tmpdir/boot/state/commands"
run_remote "$tmpdir/boot" env DEV_ENV_NAME=osac "$remote_script" down > "$tmpdir/repeated-down.out" 2>&1
assert_contains 'dns-helper cleanup osac-dev' "$tmpdir/boot/state/commands"
assert_not_contains 'dns-helper cleanup other-cluster' "$tmpdir/boot/state/commands"

# Reject invalid DEV_ENV_NAME values rather than silently truncating IDs.
if run_remote "$tmpdir/boot" env DEV_ENV_NAME=toolong "$remote_script" plan > "$tmpdir/invalid.out" 2>&1; then
    fail 'expected a DEV_ENV_NAME longer than four characters to be rejected'
fi
assert_contains 'DEV_ENV_NAME must be 1-4 lowercase letters or digits' "$tmpdir/invalid.out"

printf 'All single-SNO cluster lifecycle tests passed.\n'
