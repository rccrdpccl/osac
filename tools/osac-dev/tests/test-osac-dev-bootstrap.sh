#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
bootstrap="$repo/tools/osac-dev/osac-dev-bootstrap.sh"
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

remote="$tmpdir/remote"
mkdir -p "$tmpdir/bin" "$remote/bin" "$remote/state" \
    "$remote/etc/NetworkManager/conf.d" "$remote/etc/NetworkManager/dnsmasq.d"
printf 'sno-4-22\n' > "$remote/state/flavors"
: > "$remote/state/clones"
touch "$remote/state/server" "$remote/state/python3-installed" "$remote/state/git-installed"
printf 'nameserver 127.0.0.1\n' > "$remote/etc/resolv.conf"
printf 'dns=dnsmasq\n' > "$remote/etc/NetworkManager/conf.d/cluster-tool-dns.conf"

cat > "$remote/bin/cluster-tool" <<'FAKE_CLUSTER_TOOL'
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
        [[ ${1:-} == local ]] || exit 65
        touch "$FAKE_CLUSTER_TOOL_STATE/server"
        ;;
    pull)
        image=
        for arg in "$@"; do
            case "$arg" in
                quay.io/*:*) image=$arg ;;
            esac
        done
        [[ -n "$image" ]] || exit 66
        printf '%s\n' "${image##*:}" >> "$FAKE_CLUSTER_TOOL_STATE/flavors"
        ;;
    flavors)
        printf 'NAME SOURCE RAM CPU DISKS CREATED\n'
        while IFS= read -r flavor; do
            [[ -n "$flavor" ]] && printf '%s source 64GB 16 1 now\n' "$flavor"
        done < "$FAKE_CLUSTER_TOOL_STATE/flavors"
        ;;
    list)
        printf 'NAME FLAVOR SUBNET CREATED\n'
        while IFS='|' read -r name flavor; do
            [[ -n "$name" ]] && printf '%s %s 192.168.1.0/24 now\n' "$name" "$flavor"
        done < "$FAKE_CLUSTER_TOOL_STATE/clones"
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
        [[ -n "$name" && -n "$flavor" && -r "$pull_secret" ]] || exit 70
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
        [[ -n "$name" ]] || exit 71
        awk -F'|' -v name="$name" '$1 != name' "$FAKE_CLUSTER_TOOL_STATE/clones" \
            > "$FAKE_CLUSTER_TOOL_STATE/clones.tmp"
        mv "$FAKE_CLUSTER_TOOL_STATE/clones.tmp" "$FAKE_CLUSTER_TOOL_STATE/clones"
        ;;
    *)
        printf 'unexpected cluster-tool command: %s\n' "$cmd" >&2
        exit 72
        ;;
esac
FAKE_CLUSTER_TOOL
chmod +x "$remote/bin/cluster-tool"

cat > "$remote/bin/dnsmasq" <<'FAKE_DNSMASQ'
#!/usr/bin/env sh
exit 0
FAKE_DNSMASQ
chmod +x "$remote/bin/dnsmasq"
cat > "$remote/bin/dnf" <<'FAKE_DNF'
#!/usr/bin/env sh
exit 0
FAKE_DNF
chmod +x "$remote/bin/dnf"

cat > "$remote/bin/id" <<'FAKE_ID'
#!/usr/bin/env sh
if [ "${1:-}" = -u ]; then
    printf '0\n'
else
    exec /usr/bin/id "$@"
fi
FAKE_ID
chmod +x "$remote/bin/id"

cat > "$tmpdir/bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
while [[ ${1:-} == -o || ${1:-} == -t || ${1:-} == -tt || ${1:-} == -T ]]; do
    if [[ "$1" == -o ]]; then shift 2; else shift; fi
done
host=${1:?missing host}
shift
[[ "$host" == "$FAKE_REMOTE_HOST" ]] || exit 90
remote_command=$*
: "${FAKE_SSH_LOG:=/dev/null}"
printf '%s\n' "$remote_command" >> "$FAKE_SSH_LOG"
case "$remote_command" in
    *'install -m'*'/usr/local/sbin/osac-dev-dns.pending'*)
        cat > "$FAKE_REMOTE_ROOT/state/dns-helper-payload"
        [[ ${FAKE_DNS_INSTALL_FAIL:-0} == 0 ]] || exit 1
        exit 0
        ;;
    *"command -v 'python3'"*) [[ -f "$FAKE_REMOTE_ROOT/state/python3-installed" ]] && exit 0 || exit 1 ;;
    *"command -v 'git'"*) [[ -f "$FAKE_REMOTE_ROOT/state/git-installed" ]] && exit 0 || exit 1 ;;
    *"command -v 'dnf'"*) [[ -x "$FAKE_REMOTE_BIN/dnf" ]] && exit 0 || exit 1 ;;
    *"command -v 'cluster-tool'"*) [[ -x "$FAKE_REMOTE_BIN/cluster-tool" ]] && exit 0 || exit 1 ;;
    "dnf install -y 'python3'"|'dnf install -y python3') touch "$FAKE_REMOTE_ROOT/state/python3-installed"; exit 0 ;;
    "dnf install -y 'git'"|'dnf install -y git') touch "$FAKE_REMOTE_ROOT/state/git-installed"; exit 0 ;;
    'sh -s')
        cat >/dev/null
        cp -- "$FAKE_CLUSTER_TOOL_TEMPLATE" "$FAKE_REMOTE_BIN/cluster-tool"
        chmod +x "$FAKE_REMOTE_BIN/cluster-tool"
        exit 0
        ;;
esac
export HOME="$FAKE_REMOTE_HOME"
export PATH="$FAKE_REMOTE_BIN:$PATH"
export FAKE_CLUSTER_TOOL_LOG="$FAKE_REMOTE_ROOT/state/commands"
export FAKE_CLUSTER_TOOL_STATE="$FAKE_REMOTE_ROOT/state"
export OSAC_DEV_DNSMASQ_DIR="$FAKE_REMOTE_ROOT/etc/NetworkManager/dnsmasq.d"
export OSAC_DEV_NM_CONF="$FAKE_REMOTE_ROOT/etc/NetworkManager/conf.d/cluster-tool-dns.conf"
export OSAC_DEV_RESOLV_CONF="$FAKE_REMOTE_ROOT/etc/resolv.conf"
export OSAC_DEV_DNS_HELPER="$FAKE_REMOTE_ROOT/state/absent-dns-helper"
status=0
bash -c "$remote_command" || status=$?
if [[ ${FAKE_DISCONNECT_AFTER_PREPARE:-} == 1 && "$remote_command" == *'bash -s -- prepare'* && ! -e "$FAKE_REMOTE_ROOT/state/setup-disconnected" ]]; then
    touch "$FAKE_REMOTE_ROOT/state/setup-disconnected"
    exit 255
fi
exit "$status"
FAKE_SSH
chmod +x "$tmpdir/bin/ssh"

cat > "$tmpdir/bin/scp" <<'FAKE_SCP'
#!/usr/bin/env bash
set -euo pipefail
while [[ ${1:-} == -q || ${1:-} == -- ]]; do
    shift
done
source=${1:?missing source}
destination=${2:?missing destination}
remote_path=${destination#*:}
cp -- "$source" "$remote_path"
printf '%s\n' "$destination" >> "$FAKE_SCP_LOG"
FAKE_SCP
chmod +x "$tmpdir/bin/scp"

secret="$tmpdir/pull-secret.json"
printf '{"auths":{"example.invalid":{"auth":"never-log-this"}}}\n' > "$secret"
: > "$remote/state/commands"
: > "$tmpdir/scp.log"

# --- localhost target ------------------------------------------------------
# REMOTE_HOST unset or empty keeps the same privileged host operations but runs
# them here, so no ssh or scp may be invoked and the pull secret is read in
# place instead of being staged.
local_host() {
    local tree=$1
    local uid=$2
    local pull_secret=$3
    local output=$4
    local ssh_log=$5

    cat > "$tmpdir/bin/id" <<FAKE_LOCAL_ID
#!/usr/bin/env sh
if [ "\${1:-}" = -u ]; then
    printf '%s\\n' "$uid"
    exit 0
fi
exec /usr/bin/id "\$@"
FAKE_LOCAL_ID
    chmod +x "$tmpdir/bin/id"
    PATH="$tmpdir/bin:$tree/bin:$PATH" \
        HOME="$tree/home" \
        FAKE_CLUSTER_TOOL_LOG="$tree/state/commands" \
        FAKE_CLUSTER_TOOL_STATE="$tree/state" \
        OSAC_DEV_DNSMASQ_DIR="$tree/etc/NetworkManager/dnsmasq.d" \
        OSAC_DEV_NM_CONF="$tree/etc/NetworkManager/conf.d/cluster-tool-dns.conf" \
        OSAC_DEV_RESOLV_CONF="$tree/etc/resolv.conf" \
        OSAC_DEV_DNS_HELPER="$tree/state/absent-dns-helper" \
        CLUSTER_TOOL_DATA_PATH="$tree/data" \
        FAKE_REMOTE_HOST='root@remote.example' \
        FAKE_SSH_LOG="$ssh_log" \
        FAKE_SCP_LOG="$tmpdir/local-scp.log" \
        REMOTE_HOST='' \
        PULL_SECRET_FILE="$pull_secret" \
        DEV_ENV_NAME=osac \
        "$bootstrap" up > "$output" 2>&1
}

local_tree="$tmpdir/local"
mkdir -p "$local_tree/bin" "$local_tree/state" "$local_tree/home" \
    "$local_tree/etc/NetworkManager/conf.d" "$local_tree/etc/NetworkManager/dnsmasq.d"
cp "$remote/bin/cluster-tool" "$remote/bin/dnsmasq" "$remote/bin/dnf" "$local_tree/bin/"
printf 'sno-4-22\n' > "$local_tree/state/flavors"
: > "$local_tree/state/clones"
: > "$local_tree/state/commands"
touch "$local_tree/state/server" "$local_tree/state/python3-installed" "$local_tree/state/git-installed"
printf 'nameserver 127.0.0.1\n' > "$local_tree/etc/resolv.conf"
printf 'dns=dnsmasq\n' > "$local_tree/etc/NetworkManager/conf.d/cluster-tool-dns.conf"
: > "$tmpdir/local-ssh.log"
: > "$tmpdir/local-scp.log"

if local_host "$local_tree" 1000 "$secret" "$tmpdir/local-unprivileged.out" "$tmpdir/local-ssh.log"; then
    fail 'localhost target should require root'
fi
assert_contains 'as root' "$tmpdir/local-unprivileged.out"
[[ ! -s "$tmpdir/local-ssh.log" ]] || fail 'unprivileged localhost run contacted SSH'
[[ ! -s "$local_tree/state/commands" ]] || fail 'unprivileged localhost run mutated the host'

if ! local_host "$local_tree" 0 "$secret" "$tmpdir/local-up.out" "$tmpdir/local-ssh.log"; then
    cat "$tmpdir/local-up.out" >&2
    fail 'localhost bootstrap up failed'
fi
assert_contains 'boot --server local --flavor sno-4-22 --name osac-dev' "$local_tree/state/commands"
grep -Fq 'osac-dev|sno-4-22' "$local_tree/state/clones" || fail 'localhost SNO cluster was not booted'
[[ ! -s "$tmpdir/local-ssh.log" ]] || fail 'localhost target invoked ssh'
[[ ! -s "$tmpdir/local-scp.log" ]] || fail 'localhost target invoked scp'
if grep -Fq 'never-log-this' "$tmpdir/local-up.out" "$local_tree/state/commands"; then
    fail 'pull-secret contents appeared in logs'
fi

# An existing local cluster is reused without touching the pull secret.
cp "$local_tree/state/clones" "$tmpdir/local-clones-before"
: > "$local_tree/state/commands"
if ! local_host "$local_tree" 0 '' "$tmpdir/local-reuse.out" "$tmpdir/local-ssh.log"; then
    cat "$tmpdir/local-reuse.out" >&2
    fail 'localhost bootstrap should reuse the existing cluster without a pull secret'
fi
assert_contains 'Reusing existing SNO cluster osac-dev' "$tmpdir/local-reuse.out"
if grep -q '^boot ' "$local_tree/state/commands"; then
    fail 'localhost reuse booted a second cluster'
fi
[[ ! -s "$tmpdir/local-ssh.log" ]] || fail 'localhost reuse invoked ssh'
rm -f "$tmpdir/bin/id"

# A missing SNO cluster receives a temporary copy of the local pull secret.
output="$tmpdir/up.out"
PATH="$tmpdir/bin:$PATH" \
FAKE_REMOTE_HOST='root@remote.example' \
FAKE_REMOTE_ROOT="$remote" \
FAKE_REMOTE_HOME="$remote/home" \
FAKE_REMOTE_BIN="$remote/bin" \
FAKE_CLUSTER_TOOL_TEMPLATE="$remote/bin/cluster-tool" \
FAKE_SCP_LOG="$tmpdir/scp.log" \
REMOTE_HOST='root@remote.example' \
PULL_SECRET_FILE="$secret" \
DEV_ENV_NAME=osac \
"$bootstrap" up > "$output" 2>&1 || { cat "$output" >&2; fail 'bootstrap up command failed'; }
assert_contains 'boot --server local --flavor sno-4-22 --name osac-dev' "$remote/state/commands"
[[ -s "$tmpdir/scp.log" ]] || fail 'expected a pull-secret transfer to the remote host'
grep -Fq 'osac-dev|sno-4-22' "$remote/state/clones" || fail 'SNO development cluster was not booted'
if grep -Fq 'never-log-this' "$output" "$remote/state/commands"; then
    fail 'pull-secret contents appeared in logs'
fi
scp_destination=$(<"$tmpdir/scp.log")
remote_secret_path=${scp_destination#*:}
remote_secret_dir=${remote_secret_path%/*}
[[ ! -e "$remote_secret_dir" ]] || fail 'temporary remote pull-secret directory was not removed'

# Reuse an existing cluster named osac-dev regardless of its recorded flavor.
legacy="$tmpdir/legacy"
mkdir -p "$legacy/bin" "$legacy/state" "$legacy/etc/NetworkManager/conf.d" "$legacy/etc/NetworkManager/dnsmasq.d"
cp "$remote/bin/cluster-tool" "$remote/bin/dnsmasq" "$remote/bin/dnf" "$remote/bin/id" "$legacy/bin/"
printf 'caas-4-22\n' > "$legacy/state/flavors"
printf 'osac-dev|caas-4-22\n' > "$legacy/state/clones"
: > "$legacy/state/commands"
touch "$legacy/state/server" "$legacy/state/python3-installed" "$legacy/state/git-installed"
printf 'nameserver 127.0.0.1\n' > "$legacy/etc/resolv.conf"
printf 'dns=dnsmasq\n' > "$legacy/etc/NetworkManager/conf.d/cluster-tool-dns.conf"
: > "$tmpdir/legacy-scp.log"
env -u PULL_SECRET_FILE \
    PATH="$tmpdir/bin:$PATH" \
    FAKE_REMOTE_HOST='root@remote.example' \
    FAKE_REMOTE_ROOT="$legacy" \
    FAKE_REMOTE_HOME="$legacy/home" \
    FAKE_REMOTE_BIN="$legacy/bin" \
    FAKE_CLUSTER_TOOL_TEMPLATE="$remote/bin/cluster-tool" \
    FAKE_SCP_LOG="$tmpdir/legacy-scp.log" \
    REMOTE_HOST='root@remote.example' \
    DEV_ENV_NAME=osac \
    "$bootstrap" up > "$tmpdir/legacy.out" 2>&1 || {
    cat "$tmpdir/legacy.out" >&2
    fail 'bootstrap up should reuse the selected cluster regardless of flavor'
}
assert_contains 'Reusing existing cluster osac-dev (flavor caas-4-22)' "$tmpdir/legacy.out"
[[ ! -s "$tmpdir/legacy-scp.log" ]] || fail 'reusing a cluster must not copy a pull secret'
if grep -q '^boot ' "$legacy/state/commands"; then
    fail 'existing cluster was booted again'
fi

# Missing Python is installed remotely only after local confirmation.
deps_python="$tmpdir/deps-python"
mkdir -p "$deps_python/bin" "$deps_python/state" "$deps_python/etc/NetworkManager/conf.d" "$deps_python/etc/NetworkManager/dnsmasq.d"
cp "$remote/bin/cluster-tool" "$remote/bin/dnsmasq" "$remote/bin/dnf" "$remote/bin/id" "$deps_python/bin/"
printf 'sno-4-22\n' > "$deps_python/state/flavors"
printf 'osac-dev|sno-4-22\n' > "$deps_python/state/clones"
touch "$deps_python/state/server" "$deps_python/state/git-installed"
printf 'nameserver 127.0.0.1\n' > "$deps_python/etc/resolv.conf"
printf 'dns=dnsmasq\n' > "$deps_python/etc/NetworkManager/conf.d/cluster-tool-dns.conf"
if PATH="$tmpdir/bin:$PATH" \
    FAKE_REMOTE_HOST='root@remote.example' \
    FAKE_REMOTE_ROOT="$deps_python" \
    FAKE_REMOTE_HOME="$deps_python/home" \
    FAKE_REMOTE_BIN="$deps_python/bin" \
    FAKE_CLUSTER_TOOL_TEMPLATE="$remote/bin/cluster-tool" \
    FAKE_SCP_LOG="$tmpdir/scp.log" \
    FAKE_SSH_LOG="$tmpdir/deps-python-ssh.log" \
    REMOTE_HOST='root@remote.example' \
    DEV_ENV_NAME=osac \
    "$bootstrap" up <<< 'yes' > "$tmpdir/deps-python.out" 2>&1; then
    :
else
    cat "$tmpdir/deps-python.out" >&2
    fail 'confirmed Python installation failed'
fi
assert_contains "Dependency 'python3' is missing" "$tmpdir/deps-python.out"
assert_contains 'dnf install -y python3' "$tmpdir/deps-python-ssh.log"

# Missing git and cluster-tool are separately confirmed before remote installation.
deps_tool="$tmpdir/deps-tool"
mkdir -p "$deps_tool/bin" "$deps_tool/state" "$deps_tool/etc/NetworkManager/conf.d" "$deps_tool/etc/NetworkManager/dnsmasq.d"
cp "$remote/bin/dnsmasq" "$remote/bin/dnf" "$remote/bin/id" "$deps_tool/bin/"
cp "$remote/bin/cluster-tool" "$tmpdir/cluster-tool-template"
printf 'sno-4-22\n' > "$deps_tool/state/flavors"
printf 'osac-dev|sno-4-22\n' > "$deps_tool/state/clones"
touch "$deps_tool/state/server" "$deps_tool/state/python3-installed"
printf 'nameserver 127.0.0.1\n' > "$deps_tool/etc/resolv.conf"
printf 'dns=dnsmasq\n' > "$deps_tool/etc/NetworkManager/conf.d/cluster-tool-dns.conf"
PATH="$tmpdir/bin:$PATH" \
FAKE_REMOTE_HOST='root@remote.example' \
FAKE_REMOTE_ROOT="$deps_tool" \
FAKE_REMOTE_HOME="$deps_tool/home" \
FAKE_REMOTE_BIN="$deps_tool/bin" \
FAKE_CLUSTER_TOOL_TEMPLATE="$tmpdir/cluster-tool-template" \
FAKE_SCP_LOG="$tmpdir/scp.log" \
FAKE_SSH_LOG="$tmpdir/deps-tool-ssh.log" \
REMOTE_HOST='root@remote.example' \
DEV_ENV_NAME=osac \
"$bootstrap" up <<< $'yes\nyes' > "$tmpdir/deps-tool.out" 2>&1
assert_contains "Dependency 'git' is missing" "$tmpdir/deps-tool.out"
assert_contains "cluster-tool is missing" "$tmpdir/deps-tool.out"
assert_contains 'dnf install -y git' "$tmpdir/deps-tool-ssh.log"
[[ -x "$deps_tool/bin/cluster-tool" ]] || fail 'cluster-tool installer did not install the fake tool'

# First-time setup asks locally, then configures DNS before server setup and flavor pulls.
fresh="$tmpdir/fresh"
mkdir -p "$fresh/bin" "$fresh/state" "$fresh/etc/NetworkManager/conf.d" "$fresh/etc/NetworkManager/dnsmasq.d"
: > "$fresh/state/flavors"
: > "$fresh/state/clones"
: > "$fresh/state/commands"
: > "$fresh/etc/resolv.conf"
touch "$fresh/state/python3-installed" "$fresh/state/git-installed"
cp "$remote/bin/cluster-tool" "$remote/bin/dnsmasq" "$remote/bin/dnf" "$remote/bin/id" "$fresh/bin/"
: > "$tmpdir/fresh-scp.log"
PATH="$tmpdir/bin:$PATH" \
FAKE_REMOTE_HOST='root@remote.example' \
FAKE_REMOTE_ROOT="$fresh" \
FAKE_REMOTE_HOME="$fresh/home" \
FAKE_REMOTE_BIN="$fresh/bin" \
FAKE_SCP_LOG="$tmpdir/fresh-scp.log" \
FAKE_DISCONNECT_AFTER_PREPARE=1 \
REMOTE_HOST='root@remote.example' \
PULL_SECRET_FILE="$secret" \
DEV_ENV_NAME=osac \
"$bootstrap" up <<< 'yes' > "$tmpdir/fresh.out" 2>&1 || {
    cat "$tmpdir/fresh.out" >&2
    fail 'first-time SNO setup failed'
}
assert_contains 'restart NetworkManager (an SSH session may briefly disconnect)' "$tmpdir/fresh.out"
assert_contains 'checking whether the NetworkManager restart interrupted the session' "$tmpdir/fresh.out"
assert_contains 'setup client' "$fresh/state/commands"
assert_contains 'connect local --host local' "$fresh/state/commands"
assert_contains 'boot --server local --flavor sno-4-22 --name osac-dev' "$fresh/state/commands"
if grep -Fq 'osac-bme' "$fresh/state/commands"; then
    fail 'first-time setup booted a second BM/CNV cluster'
fi
setup_line=$(grep -n '^setup client' "$fresh/state/commands" | cut -d: -f1)
connect_line=$(grep -n '^connect local' "$fresh/state/commands" | cut -d: -f1)
pull_line=$(grep -n '^pull ' "$fresh/state/commands" | head -1 | cut -d: -f1)
((setup_line < connect_line && connect_line < pull_line)) || fail 'first-time setup steps ran out of order'

# Missing pull-secret input fails before any first-time remote changes.
fresh_cancel="$tmpdir/fresh-cancel"
mkdir -p "$fresh_cancel/bin" "$fresh_cancel/state" "$fresh_cancel/etc/NetworkManager/conf.d" "$fresh_cancel/etc/NetworkManager/dnsmasq.d"
: > "$fresh_cancel/state/flavors"
: > "$fresh_cancel/state/clones"
: > "$fresh_cancel/state/commands"
: > "$fresh_cancel/etc/resolv.conf"
touch "$fresh_cancel/state/python3-installed" "$fresh_cancel/state/git-installed"
cp "$remote/bin/cluster-tool" "$remote/bin/dnsmasq" "$remote/bin/dnf" "$remote/bin/id" "$fresh_cancel/bin/"
if env -u PULL_SECRET_FILE \
    PATH="$tmpdir/bin:$PATH" \
    FAKE_REMOTE_HOST='root@remote.example' \
    FAKE_REMOTE_ROOT="$fresh_cancel" \
    FAKE_REMOTE_HOME="$fresh_cancel/home" \
    FAKE_REMOTE_BIN="$fresh_cancel/bin" \
    FAKE_SCP_LOG="$tmpdir/fresh-scp.log" \
    REMOTE_HOST='root@remote.example' \
    DEV_ENV_NAME=osac \
    "$bootstrap" up > "$tmpdir/no-secret.out" 2>&1; then
    fail 'booting a missing cluster without PULL_SECRET_FILE should fail'
fi
assert_contains 'set PULL_SECRET_FILE to a readable local pull-secret file' "$tmpdir/no-secret.out"
if grep -Eq '^(setup|connect|pull|boot) ' "$fresh_cancel/state/commands"; then
    fail 'missing pull secret should be detected before remote changes'
fi

# Declining first-time setup must not install/configure anything remotely.
if PATH="$tmpdir/bin:$PATH" \
    FAKE_REMOTE_HOST='root@remote.example' \
    FAKE_REMOTE_ROOT="$fresh_cancel" \
    FAKE_REMOTE_HOME="$fresh_cancel/home" \
    FAKE_REMOTE_BIN="$fresh_cancel/bin" \
    FAKE_SCP_LOG="$tmpdir/fresh-scp.log" \
    REMOTE_HOST='root@remote.example' \
    PULL_SECRET_FILE="$secret" \
    DEV_ENV_NAME=osac \
    "$bootstrap" up <<< 'no' > "$tmpdir/cancel.out" 2>&1; then
    fail 'declining remote preparation should stop the SNO workflow'
fi
assert_contains 'host preparation was declined' "$tmpdir/cancel.out"
if grep -Eq '^(setup|connect|pull|boot) ' "$fresh_cancel/state/commands"; then
    fail 'declined setup made remote changes'
fi

# An already-present SNO cluster is reused without requiring or transferring a secret.
: > "$remote/state/commands"
: > "$tmpdir/scp.log"
mv "$remote/bin/dnf" "$remote/bin/dnf.disabled"
PATH="$tmpdir/bin:$PATH" \
FAKE_REMOTE_HOST='root@remote.example' \
FAKE_REMOTE_ROOT="$remote" \
FAKE_REMOTE_HOME="$remote/home" \
FAKE_REMOTE_BIN="$remote/bin" \
FAKE_SCP_LOG="$tmpdir/scp.log" \
REMOTE_HOST='root@remote.example' \
DEV_ENV_NAME=osac \
"$bootstrap" up > "$tmpdir/reuse.out" 2>&1
mv "$remote/bin/dnf.disabled" "$remote/bin/dnf"
[[ ! -s "$tmpdir/scp.log" ]] || fail 'reused cluster should not copy a pull secret'
if grep -q '^boot ' "$remote/state/commands"; then
    fail 'reused cluster should not boot again'
fi

# Cluster teardown is locally confirmed and targets only the selected SNO.
: > "$remote/state/commands"
if PATH="$tmpdir/bin:$PATH" \
    FAKE_REMOTE_HOST='root@remote.example' \
    FAKE_REMOTE_ROOT="$remote" \
    FAKE_REMOTE_HOME="$remote/home" \
    FAKE_REMOTE_BIN="$remote/bin" \
    FAKE_SCP_LOG="$tmpdir/scp.log" \
    REMOTE_HOST='root@remote.example' \
    DEV_ENV_NAME=osac \
    "$bootstrap" down <<< 'no' > "$tmpdir/down-cancel.out" 2>&1; then
    fail 'declining cluster teardown should leave the SNO running'
fi
assert_contains 'cluster teardown was cancelled' "$tmpdir/down-cancel.out"
if grep -q '^destroy ' "$remote/state/commands"; then
    fail 'declined teardown destroyed a cluster'
fi
PATH="$tmpdir/bin:$PATH" \
FAKE_REMOTE_HOST='root@remote.example' \
FAKE_REMOTE_ROOT="$remote" \
FAKE_REMOTE_HOME="$remote/home" \
FAKE_REMOTE_BIN="$remote/bin" \
FAKE_SCP_LOG="$tmpdir/scp.log" \
REMOTE_HOST='root@remote.example' \
DEV_ENV_NAME=osac \
"$bootstrap" down <<< 'yes' > "$tmpdir/down.out" 2>&1
assert_contains 'destroy osac-dev --server local' "$remote/state/commands"
[[ -s "$remote/state/dns-helper-payload" ]] || fail 'teardown did not install the current DNS helper'
if grep -Fq 'destroy osac-bme' "$remote/state/commands"; then
    fail 'teardown targeted an unrelated BM/CNV cluster'
fi
[[ ! -s "$remote/state/clones" ]] || fail 'confirmed teardown left the SNO clone behind'

# A helper upload failure must abort before destroying any clone.
printf 'osac-dev|sno-4-22\n' > "$remote/state/clones"
: > "$remote/state/commands"
if PATH="$tmpdir/bin:$PATH" \
    FAKE_REMOTE_HOST='root@remote.example' \
    FAKE_REMOTE_ROOT="$remote" FAKE_REMOTE_HOME="$remote/home" \
    FAKE_REMOTE_BIN="$remote/bin" FAKE_SCP_LOG="$tmpdir/scp.log" \
    FAKE_DNS_INSTALL_FAIL=1 REMOTE_HOST='root@remote.example' DEV_ENV_NAME=osac \
    "$bootstrap" down <<< 'yes' > "$tmpdir/down-upload-fail.out" 2>&1; then
    fail 'DNS helper upload failure did not abort teardown'
fi
if grep -q '^destroy ' "$remote/state/commands"; then
    fail 'teardown proceeded after DNS helper installation failed'
fi

# Invalid name input fails locally before any SSH call.
: > "$tmpdir/ssh.log"
if PATH="$tmpdir/bin:$PATH" \
    FAKE_SSH_LOG="$tmpdir/ssh.log" \
    FAKE_REMOTE_HOST='root@remote.example' \
    FAKE_REMOTE_ROOT="$remote" \
    FAKE_REMOTE_HOME="$remote/home" \
    FAKE_REMOTE_BIN="$remote/bin" \
    FAKE_SCP_LOG="$tmpdir/scp.log" \
    REMOTE_HOST='root@remote.example' \
    DEV_ENV_NAME=toolong \
    "$bootstrap" up > "$tmpdir/invalid.out" 2>&1; then
    fail 'expected an invalid DEV_ENV_NAME to be rejected'
fi
assert_contains 'DEV_ENV_NAME must be 1-4 lowercase letters or digits' "$tmpdir/invalid.out"
[[ ! -s "$tmpdir/ssh.log" ]] || fail 'invalid name was rejected only after contacting the remote host'

printf 'All local bootstrap tests passed.\n'
