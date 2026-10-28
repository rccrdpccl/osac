#!/usr/bin/env bash
# Contract tests for tools/osac-dev/osac-dev-e2e.sh.
#
# Every external command (oc, kubectl, helm, getent, go, uv, curl, tar,
# sha256sum) is faked and logged; no cluster, registry, or release download
# is contacted. The fake go creates the CLI binary it was asked to build, and
# the fake uv logs its pytest invocation plus the exported environment so
# the wiring can be asserted.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
wrapper="$repo/tools/osac-dev/osac-dev-e2e.sh"
tmpdir=$(mktemp -d)

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

[[ -x "$wrapper" ]] || fail "e2e runner wrapper is missing or not executable: $wrapper"

fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}
shift || true
printf 'oc %s\n' "$cmd $*" >> "$FAKE_ROOT/commands"
if [[ "$cmd" == config ]]; then
    printf 'https://192.0.2.10:6443\n'
fi
if [[ "$cmd" == get && "$1" == bmi ]]; then
    # Worker BMIs labeled with their ClusterOrder (guest DNS sync input).
    printf 'order-fake host-inventory/virtual-bmh-1\n'
    exit 0
fi
if [[ "$cmd" == get && "$1" == bmh ]]; then
    printf '192.0.2.99'
    exit 0
fi
if [[ "$cmd" == get && "$*" == *'router-certs-default'* ]]; then
    # Base64 of a placeholder ingress CA for the metering SSL bundle.
    printf 'ZmFrZS1pbmdyZXNzLWNh\n'
fi
FAKE_OC
chmod +x "$fake_bin/oc"

cat > "$fake_bin/kubectl" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "$FAKE_ROOT/commands"
printf 'apps.fake.example.com\n'
FAKE_KUBECTL
chmod +x "$fake_bin/kubectl"

cat > "$fake_bin/helm" <<'FAKE_HELM'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "$FAKE_ROOT/commands"
if [[ ${1:-} == status ]]; then
    [[ -e "$FAKE_ROOT/osac-release-missing" ]] && exit 1
fi
exit 0
FAKE_HELM
chmod +x "$fake_bin/helm"

cat > "$fake_bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$FAKE_ROOT/commands"
case "$*" in
    *'-N -D'*)
        # A tunnel stays alive like a real one until the wrapper kills it.
        sleep 300
        ;;
    *update*)
        # Guest DNS updates receive their payload on stdin; capture it for
        # assertions (the cleanup's clear call carries no payload).
        cat > "$FAKE_ROOT/guest-dns-stdin"
        ;;
    *)
        :
        ;;
esac
FAKE_SSH
chmod +x "$fake_bin/ssh"

cat > "$fake_bin/systemctl" <<'FAKE_SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "$FAKE_ROOT/commands"
if [[ -e "$FAKE_ROOT/dns-timer-inactive" ]]; then
    exit 3
fi
exit 0
FAKE_SYSTEMCTL
chmod +x "$fake_bin/systemctl"

cat > "$fake_bin/getent" <<'FAKE_GETENT'
#!/usr/bin/env bash
set -euo pipefail
printf 'getent %s\n' "$*" >> "$FAKE_ROOT/commands"
if [[ -e "$FAKE_ROOT/dns-fails" ]]; then
    exit 2
fi
printf '192.0.2.10 %s\n' "${*: -1}"
FAKE_GETENT
chmod +x "$fake_bin/getent"

cat > "$fake_bin/go" <<'FAKE_GO'
#!/usr/bin/env bash
set -euo pipefail
printf 'go %s\n' "$*" >> "$FAKE_ROOT/commands"
out=
while (($#)); do
    case "$1" in
        -o) out=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$out" ]] || exit 91
printf '#!/usr/bin/env bash\necho fake-osac-cli\n' > "$out"
chmod +x "$out"
FAKE_GO
chmod +x "$fake_bin/go"

cat > "$fake_bin/uv" <<'FAKE_UV'
#!/usr/bin/env bash
set -euo pipefail
if [[ -x "${OSAC_CLI_PATH:-}" ]]; then cli_ok=yes; else cli_ok=no; fi
# A brief pause so the guest DNS sync loop completes its first cycle
# before pytest returns.
sleep 1
if [[ -n "${SSL_CERT_FILE:-}" && -f "${SSL_CERT_FILE:-}" ]]; then
    cp "${SSL_CERT_FILE:-}" "$FAKE_ROOT/ssl-bundle-copy.pem"
fi
{
    printf 'uv %s\n' "$*"
    printf 'KUBECONFIG=%s\n' "${KUBECONFIG:-}"
    printf 'OSAC_NAMESPACE=%s\n' "${OSAC_NAMESPACE:-}"
    printf 'OSAC_CLI_PATH=%s\n' "${OSAC_CLI_PATH:-}"
    printf 'METERING_ADAPTER_URL=%s\n' "${METERING_ADAPTER_URL:-}"
    printf 'SSL_CERT_FILE=%s\n' "${SSL_CERT_FILE:-}"
    printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-}"
    printf 'NO_PROXY=%s\n' "${NO_PROXY:-}"
    printf 'CLI_EXECUTABLE=%s\n' "$cli_ok"
} >> "$FAKE_ROOT/uv-log"
FAKE_UV
chmod +x "$fake_bin/uv"

cat > "$fake_bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "$FAKE_ROOT/commands"
out=
url=
resolve=0
args=("$@")
while (($#)); do
    case "$1" in
        -o) out=$2; shift 2 ;;
        --resolve) resolve=1; shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
if [[ "$url" == *fullstorydev/grpcurl* ]]; then
    if [[ -n "$out" ]]; then
        printf 'fake-grpcurl-tarball\n' > "$out"
    else
        printf 'deadbeef  grpcurl_1.9.1_linux_x86_64.tar.gz\n'
    fi
    exit 0
fi
if ((resolve)); then
    if [[ -e "$FAKE_ROOT/probe-fails" ]]; then
        printf '000\n'
    else
        printf '404\n'
    fi
    exit 0
fi
exit 0
FAKE_CURL
chmod +x "$fake_bin/curl"

cat > "$fake_bin/tar" <<'FAKE_TAR'
#!/usr/bin/env bash
set -euo pipefail
printf 'tar %s\n' "$*" >> "$FAKE_ROOT/commands"
dir=
while (($#)); do
    case "$1" in
        -C) dir=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$dir" ]] || exit 92
mkdir -p "$dir"
printf '#!/usr/bin/env bash\necho fake-grpcurl\n' > "$dir/grpcurl"
chmod +x "$dir/grpcurl"
FAKE_TAR
chmod +x "$fake_bin/tar"

cat > "$fake_bin/sha256sum" <<'FAKE_SHA'
#!/usr/bin/env bash
set -euo pipefail
printf 'sha256sum %s\n' "$*" >> "$FAKE_ROOT/commands"
cat >> "$FAKE_ROOT/commands"
exit 0
FAKE_SHA
chmod +x "$fake_bin/sha256sum"

cat > "$fake_bin/unshare" <<'FAKE_UNSHARE'
#!/usr/bin/env bash
set -euo pipefail
printf 'unshare %s\n' "$*" >> "$FAKE_ROOT/commands"
if [[ -e "$FAKE_ROOT/unshare-fails" ]]; then
    exit 1
fi
if [[ "$*" != *hostswap* ]]; then
    # Capability probe (unshare --user --map-root-user --mount true).
    exit 0
fi
# Main invocation: skip the flags, the bash/-c script, and its arg0
# (hostswap); log the bind-mounted hosts file; exec the rest.
while (($#)) && [[ $1 != hostswap ]]; do
    shift
done
(($#)) || exit 91
shift
hosts_file=${1:?missing hosts file}
shift
printf 'hosts-file-contents-begin\n' >> "$FAKE_ROOT/commands"
cat "$hosts_file" >> "$FAKE_ROOT/commands"
printf 'hosts-file-contents-end\n' >> "$FAKE_ROOT/commands"
exec "$@"
FAKE_UNSHARE
chmod +x "$fake_bin/unshare"

fake_remote_host='root@fake.example.com'
setup_case() {
    local name=$1
    CASE_ROOT="$tmpdir/$name"
    mkdir -p "$CASE_ROOT/home" "$CASE_ROOT/applied"
    printf 'apiVersion: v1\nkind: Config\n' > "$CASE_ROOT/kubeconfig"
    chmod 600 "$CASE_ROOT/kubeconfig"
    : > "$CASE_ROOT/commands"
    : > "$CASE_ROOT/uv-log"
}

# Strip every PATH entry that provides a grpcurl binary so the install and
# skip scenarios are deterministic on any workstation.
STRIPPED_PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do
    [[ -x "$dir/grpcurl" ]] || printf '%s\n' "$dir"
done | paste -sd:)

# Usage: run_wrapper <output-file> [ENV=VALUE...] [-- <wrapper argument>...]
run_wrapper() {
    local output=$1
    shift
    local -a env_overrides=()
    while [[ $# -gt 0 && $1 != -- ]]; do
        env_overrides+=("$1")
        shift
    done
    [[ ${1:-} == -- ]] && shift
    # Remote target by default; scenarios that exercise the localhost target
    # pass REMOTE_HOST= explicitly.
    env \
        -u KUBECONFIG -u OSAC_NAMESPACE -u OSAC_CLI_PATH -u METERING_ADAPTER_URL \
        -u OSAC_DEV_E2E_SSH_HOST -u HTTPS_PROXY -u NO_PROXY \
        PATH="$fake_bin:$STRIPPED_PATH" \
        HOME="$CASE_ROOT/home" \
        FAKE_ROOT="$CASE_ROOT" \
        REMOTE_HOST="$fake_remote_host" \
        OSAC_DEV_KUBECONFIG="$CASE_ROOT/kubeconfig" \
        "${env_overrides[@]}" \
        "$wrapper" "$@" > "$output" 2>&1
}

# A missing kubeconfig fails before any build or test action.
setup_case missing-kubeconfig
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_KUBECONFIG="$CASE_ROOT/absent.kubeconfig" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py; then
    fail 'wrapper should fail when the kubeconfig is missing'
fi
assert_contains "kubeconfig not found at $CASE_ROOT/absent.kubeconfig" "$CASE_ROOT/out"
assert_contains 'make osac-dev-kubeconfig' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'cluster commands ran without a kubeconfig'
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without a kubeconfig'

# A missing platform release fails before the CLI build or pytest.
setup_case platform-missing
touch "$CASE_ROOT/osac-release-missing"
if run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py; then
    fail 'wrapper should fail when the osac platform release is missing'
fi
assert_contains 'make osac-dev-deploy' "$CASE_ROOT/out"
assert_not_contains 'go build' "$CASE_ROOT/commands"
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without the platform deployed'

# Running without test arguments prints usage naming the make target.
setup_case no-args
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper should fail without test arguments'
fi
assert_contains 'make osac-dev-e2e' "$CASE_ROOT/out"
assert_contains 'TESTS=' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without test arguments'

# A missing grpcurl is auto-installed from the pinned release.
setup_case grpcurl-install
run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with grpcurl auto-install failed'
}
assert_contains 'https://github.com/fullstorydev/grpcurl/releases/download/v1.9.1/grpcurl_1.9.1_linux_x86_64.tar.gz' "$CASE_ROOT/commands"
assert_contains 'https://github.com/fullstorydev/grpcurl/releases/download/v1.9.1/grpcurl_1.9.1_checksums.txt' "$CASE_ROOT/commands"
assert_contains 'grpcurl_1.9.1_linux_x86_64.tar.gz' "$CASE_ROOT/commands"
[[ -x "$CASE_ROOT/home/.local/bin/grpcurl" ]] || fail 'grpcurl was not installed into $HOME/.local/bin'
assert_contains 'uv run pytest -n 0 tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py' "$CASE_ROOT/uv-log"

# An existing grpcurl skips the download entirely.
setup_case grpcurl-present
printf '#!/usr/bin/env bash\n' > "$fake_bin/grpcurl"
chmod +x "$fake_bin/grpcurl"
run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with an existing grpcurl failed'
}
assert_not_contains 'fullstorydev/grpcurl' "$CASE_ROOT/commands"
assert_contains 'uv run pytest -n 0 tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py' "$CASE_ROOT/uv-log"
rm -f "$fake_bin/grpcurl"

# Unresolved route DNS runs pytest inside the private mount namespace with
# the route entries bind-mounted over /etc/hosts.
setup_case dns-missing
touch "$CASE_ROOT/dns-fails"
run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with unresolved route DNS should use the mount namespace and proceed'
}
assert_contains 'unshare --user --map-root-user --mount' "$CASE_ROOT/commands"
assert_contains 'oc config view' "$CASE_ROOT/commands"
assert_contains 'hosts-file-contents-begin' "$CASE_ROOT/commands"
assert_contains '192.0.2.10 fulfillment-api-osac.apps.fake.example.com' "$CASE_ROOT/commands"
assert_contains '192.0.2.10 fulfillment-internal-api-osac.apps.fake.example.com' "$CASE_ROOT/commands"
assert_contains '192.0.2.10 keycloak-keycloak.apps.fake.example.com' "$CASE_ROOT/commands"
assert_contains '192.0.2.10 osac-metering-echo-adapter-osac.apps.fake.example.com' "$CASE_ROOT/commands"
assert_contains 'hosts-file-contents-end' "$CASE_ROOT/commands"
assert_contains 'uv run pytest -n 0 tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py' "$CASE_ROOT/uv-log"

# Without unprivileged user namespaces the wrapper falls back to printing
# ready-to-paste /etc/hosts lines.
setup_case unshare-unavailable
touch "$CASE_ROOT/dns-fails" "$CASE_ROOT/unshare-fails"
if run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py; then
    fail 'wrapper should fail when user namespaces are unavailable'
fi
assert_contains '192.0.2.10 fulfillment-api-osac.apps.fake.example.com' "$CASE_ROOT/out"
assert_contains '192.0.2.10 keycloak-keycloak.apps.fake.example.com' "$CASE_ROOT/out"
assert_contains '/etc/hosts' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without resolvable routes or a namespace'

# An unreachable 443 path fails with a network message and no namespace run.
setup_case probe-fails
touch "$CASE_ROOT/dns-fails" "$CASE_ROOT/probe-fails"
if run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py; then
    fail 'wrapper should fail when the 443 path is unreachable'
fi
assert_contains '192.0.2.10:443' "$CASE_ROOT/out"
assert_not_contains 'unshare --user' "$CASE_ROOT/commands"
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without a reachable route path'

# The happy path builds the CLI from the checkout and runs pytest serially
# with the environment wired.
setup_case happy-path
run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'happy path run failed'
}
assert_contains 'go build -o' "$CASE_ROOT/commands"
assert_contains './cmd/osac' "$CASE_ROOT/commands"
assert_contains 'CLI_EXECUTABLE=yes' "$CASE_ROOT/uv-log"
cli_path=$(sed -n 's/^OSAC_CLI_PATH=//p' "$CASE_ROOT/uv-log")
[[ -n "$cli_path" && "$cli_path" == */osac ]] || fail "OSAC_CLI_PATH not set to a built CLI binary: $cli_path"
assert_contains 'KUBECONFIG='"$CASE_ROOT"'/kubeconfig' "$CASE_ROOT/uv-log"
assert_contains 'OSAC_NAMESPACE=osac' "$CASE_ROOT/uv-log"
assert_contains 'METERING_ADAPTER_URL=https://osac-metering-echo-adapter-osac.apps.fake.example.com' "$CASE_ROOT/uv-log"
assert_contains 'METERING_ADAPTER_URL defaulted to' "$CASE_ROOT/out"
assert_contains 'SSL_CERT_FILE set to a CA bundle including the cluster ingress CA' "$CASE_ROOT/out"
ssl_cert_file=$(sed -n 's/^SSL_CERT_FILE=//p' "$CASE_ROOT/uv-log")
[[ -n "$ssl_cert_file" ]] || fail "SSL_CERT_FILE not set: $ssl_cert_file"
grep -q 'fake-ingress-ca' "$CASE_ROOT/ssl-bundle-copy.pem" || fail "the SSL bundle does not contain the ingress CA"
assert_not_contains 'unshare --user' "$CASE_ROOT/commands"
assert_contains 'uv run pytest -n 0 tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py' "$CASE_ROOT/uv-log"

# A preset METERING_ADAPTER_URL is passed through verbatim; no default is
# derived and the metering route is not required to resolve.
setup_case metering-url-preset
run_wrapper "$CASE_ROOT/out" METERING_ADAPTER_URL=https://example.com/adapter -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a preset metering adapter URL failed'
}
assert_contains 'METERING_ADAPTER_URL=https://example.com/adapter' "$CASE_ROOT/uv-log"
assert_not_contains 'METERING_ADAPTER_URL defaulted to' "$CASE_ROOT/out"
assert_not_contains 'osac-metering-echo-adapter' "$CASE_ROOT/commands"
assert_not_contains 'SSL_CERT_FILE set to' "$CASE_ROOT/out"
[[ -z $(sed -n 's/^SSL_CERT_FILE=//p' "$CASE_ROOT/uv-log") ]] || fail 'SSL_CERT_FILE should not be set when the metering URL is preset'

# With OSAC_DEV_E2E_SSH_HOST set, a background SOCKS proxy is opened over
# SSH and the guest-cluster connections are routed through it while the
# known routes and the hub API stay direct via NO_PROXY.
setup_case socks-tunnel
run_wrapper "$CASE_ROOT/out" OSAC_DEV_E2E_SSH_HOST=root@fake.example.com -- tests/e2e/caas/sanity/test_cluster_create.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with the SSH SOCKS tunnel failed'
}
assert_contains 'ExitOnForwardFailure=yes -N -D 127.0.0.1:1080 root@fake.example.com' "$CASE_ROOT/commands"
assert_contains 'HTTPS_PROXY=socks5://127.0.0.1:1080' "$CASE_ROOT/uv-log"
assert_contains 'NO_PROXY=localhost,127.0.0.1,192.0.2.10,fulfillment-api-osac.apps.fake.example.com' "$CASE_ROOT/uv-log"
assert_contains 'fulfillment-internal-api-osac.apps.fake.example.com' "$CASE_ROOT/uv-log"
assert_contains 'keycloak-keycloak.apps.fake.example.com' "$CASE_ROOT/uv-log"
assert_contains 'osac-metering-echo-adapter-osac.apps.fake.example.com' "$CASE_ROOT/uv-log"
# Persistent provisioning DNS is checked/refreshed before pytest and is NOT
# cleared when tests exit. The host timer maintains records independently.
assert_contains 'systemctl start osac-dev-dns-osac-dev.service' "$CASE_ROOT/commands"
assert_not_contains 'osac-dev-guest-dns clear' "$CASE_ROOT/commands"

setup_case remote-host-default
run_wrapper "$CASE_ROOT/out" REMOTE_HOST=root@fake.example.com -- tests/e2e/caas/sanity/ || {
    cat "$CASE_ROOT/out" >&2
    fail 'REMOTE_HOST did not enable automatic hosted access'
}
assert_contains 'ExitOnForwardFailure=yes -N -D 127.0.0.1:1080 root@fake.example.com' "$CASE_ROOT/commands"
assert_contains 'systemctl start osac-dev-dns-osac-dev.service' "$CASE_ROOT/commands"

setup_case caas-without-host
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_E2E_SSH_HOST= -- tests/e2e/caas/sanity/; then
    fail 'CaaS silently continued without hosted API access'
fi
assert_contains 'REMOTE_HOST' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without hosted API access'

# An explicitly empty OSAC_DEV_E2E_SSH_HOST disables the SOCKS hop on a
# remote target: no tunnel, no proxy, no DNS timer access over SSH.
setup_case no-socks-tunnel
run_wrapper "$CASE_ROOT/out" OSAC_DEV_E2E_SSH_HOST= -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'run without the SSH SOCKS tunnel failed'
}
assert_not_contains 'ssh -N -D' "$CASE_ROOT/commands"
[[ -z $(sed -n 's/^HTTPS_PROXY=//p' "$CASE_ROOT/uv-log") ]] || fail 'HTTPS_PROXY should not be set without OSAC_DEV_E2E_SSH_HOST'
assert_not_contains 'osac-dev-guest-dns' "$CASE_ROOT/commands"

# Multiple test paths and extra pytest arguments pass through verbatim.
setup_case multiple-paths
run_wrapper "$CASE_ROOT/out" -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py tests/e2e/bmaas/serial/test_baremetal_instance_inventory_exhausted.py -k lifecycle || {
    cat "$CASE_ROOT/out" >&2
    fail 'multiple paths run failed'
}
assert_contains 'uv run pytest -n 0 tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py tests/e2e/bmaas/serial/test_baremetal_instance_inventory_exhausted.py -k lifecycle' "$CASE_ROOT/uv-log"

# --- localhost target -------------------------------------------------------
# The same wrapper runs everything on this machine: no SSH, no SOCKS proxy, no
# NO_PROXY list, no /etc/hosts mount namespace. The lab DNS timer is checked
# locally before pytest.
setup_case local-happy-path
run_wrapper "$CASE_ROOT/out" REMOTE_HOST= -- tests/e2e/caas/sanity/test_cluster_create.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'localhost CaaS run failed'
}
assert_not_contains 'ssh ' "$CASE_ROOT/commands"
assert_contains 'systemctl is-active --quiet osac-dev-dns-osac-dev.timer' "$CASE_ROOT/commands"
assert_contains 'systemctl start osac-dev-dns-osac-dev.service' "$CASE_ROOT/commands"
[[ -z $(sed -n 's/^HTTPS_PROXY=//p' "$CASE_ROOT/uv-log") ]] || fail 'localhost target set HTTPS_PROXY'
[[ -z $(sed -n 's/^NO_PROXY=//p' "$CASE_ROOT/uv-log") ]] || fail 'localhost target set NO_PROXY'
assert_not_contains 'unshare --user' "$CASE_ROOT/commands"
assert_contains 'uv run pytest -n 0 tests/e2e/caas/sanity/test_cluster_create.py' "$CASE_ROOT/uv-log"

# A stale lab DNS timer fails fast with the local remediation.
setup_case local-dns-timer
touch "$CASE_ROOT/dns-timer-inactive"
if run_wrapper "$CASE_ROOT/out" REMOTE_HOST= -- tests/e2e/caas/sanity/test_cluster_create.py; then
    fail 'localhost target should fail when the lab DNS timer is inactive'
fi
assert_contains 'persistent lab DNS is not ready; run make osac-dev-dns' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without lab DNS on the localhost target'

# An SSH hop configured for a remote target is ignored here.
setup_case local-ignores-ssh-host
run_wrapper "$CASE_ROOT/out" REMOTE_HOST= OSAC_DEV_E2E_SSH_HOST="$fake_remote_host" \
    -- tests/e2e/caas/sanity/test_cluster_create.py || {
    cat "$CASE_ROOT/out" >&2
    fail 'localhost run failed with an SSH hop configured'
}
assert_contains "ignoring OSAC_DEV_E2E_SSH_HOST=$fake_remote_host on the localhost target" "$CASE_ROOT/out"
assert_not_contains 'ssh ' "$CASE_ROOT/commands"

# Unresolved route names on the cluster host are a DNS fault, not a hosts-file
# workaround: no mount namespace is attempted.
setup_case local-routes-unresolved
touch "$CASE_ROOT/dns-fails"
if run_wrapper "$CASE_ROOT/out" REMOTE_HOST= -- tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py; then
    fail 'localhost target should fail when the cluster routes do not resolve'
fi
assert_contains 'The cluster routes do not resolve on the localhost target' "$CASE_ROOT/out"
assert_contains 'make osac-dev-dns' "$CASE_ROOT/out"
assert_not_contains 'unshare --user' "$CASE_ROOT/commands"
[[ ! -s "$CASE_ROOT/uv-log" ]] || fail 'pytest ran without resolvable routes'

printf 'All e2e runner wrapper tests passed.\n'
