#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
installer="$repo/tools/osac-dev/osac-dev-install-infra.sh"
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

[[ -x "$installer" ]] || fail "infra installer is missing or not executable: $installer"
fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -G ]]; then
    printf 'user root\nhostname remote.example\n'
    exit 0
fi
for arg in "$@"; do
    if [[ "$arg" == -N ]]; then
        printf 'ssh-tunnel %s\n' "$*" >> "$FAKE_ROOT/commands"
        touch "$FAKE_ROOT/tunnel-active"
        while :; do sleep 1; done
    fi
done
host=${1:?missing host}
shift
[[ "$host" == "$FAKE_REMOTE_HOST" ]] || exit 90
remote_command=$*
printf 'ssh %s\n' "$remote_command" >> "$FAKE_ROOT/commands"
case "$remote_command" in
    'id -u')
        printf '0\n'
        ;;
    *'install -m'*'/usr/local/sbin/osac-dev-dns.pending'*)
        cat > "$FAKE_ROOT/dns-helper-payload"
        ;;
    *'/usr/local/sbin/osac-dev-dns recover osac-dev'*)
        if [[ ${FAKE_DNS_RECOVERY_FAIL:-0} == 1 ]]; then
            printf 'lease helper init failed\n' >&2
            exit 1
        fi
        touch "$FAKE_ROOT/dns-recovery-checked"
        printf 'RECOVERED_LISTENERS=%s\n' "${FAKE_DNS_RECOVERY_NEEDED:-0}"
        ;;
    *'cluster-tool list --server local'*)
        printf 'NAME FLAVOR SUBNET CREATED\n'
        while IFS='|' read -r name flavor; do
            [[ -n "$name" ]] && printf '%s %s 192.0.2.0/24 now\n' "$name" "$flavor"
        done < "$FAKE_ROOT/clones"
        ;;
    *)
        printf 'unexpected remote command: %s\n' "$remote_command" >&2
        exit 91
        ;;
esac
FAKE_SSH
chmod +x "$fake_bin/ssh"

cat > "$fake_bin/scp" <<'FAKE_SCP'
#!/usr/bin/env bash
set -euo pipefail
while [[ ${1:-} == -q || ${1:-} == -- ]]; do shift; done
source=${1:?missing source}
destination=${2:?missing destination}
[[ "$source" == "$FAKE_REMOTE_HOST:"* ]] || exit 92
remote_path=${source#*:}
[[ "$remote_path" == /root/.kube/osac-dev.kubeconfig ]] || exit 93
cp -- "$FAKE_ROOT/source.kubeconfig" "$destination"
printf '%s\n' "$destination" > "$FAKE_ROOT/scp-destination"
FAKE_SCP
chmod +x "$fake_bin/scp"

cat > "$fake_bin/cluster-tool" <<'FAKE_CLUSTER_TOOL'
#!/usr/bin/env bash
set -euo pipefail
printf 'cluster-tool %s\n' "$*" >> "$FAKE_ROOT/commands"
[[ " $* " == *' list --server local '* || "$*" == 'list --server local' ]] || exit 89
printf 'NAME FLAVOR SUBNET CREATED\n'
while IFS='|' read -r name flavor; do
    [[ -n "$name" ]] && printf '%s %s 192.0.2.0/24 now\n' "$name" "$flavor"
done < "$FAKE_ROOT/clones"
FAKE_CLUSTER_TOOL
chmod +x "$fake_bin/cluster-tool"

# Only the host DNS helper is a double; kubeconfig parsing still needs the real
# interpreter, so every other invocation is delegated.
REAL_PYTHON3=$(command -v python3)
cat > "$fake_bin/python3" <<'FAKE_PYTHON3'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == */osac-dev-dns ]]; then
    printf 'python3 %s\n' "$*" >> "$FAKE_ROOT/commands"
    if [[ ${FAKE_DNS_RECOVERY_FAIL:-0} == 1 ]]; then
        printf 'lease helper init failed\n' >&2
        exit 1
    fi
    printf 'RECOVERED_LISTENERS=%s\n' "${FAKE_DNS_RECOVERY_NEEDED:-0}"
    exit 0
fi
exec "$REAL_PYTHON3" "$@"
FAKE_PYTHON3
chmod +x "$fake_bin/python3"

cat > "$fake_bin/getent" <<'FAKE_GETENT'
#!/usr/bin/env sh
if [ "${1:-}" = ahostsv4 ] && [ "${2:-}" = remote.example ]; then
    printf '192.0.2.11 STREAM remote.example\n'
    exit 0
fi
exit 2
FAKE_GETENT
chmod +x "$fake_bin/getent"

cat > "$fake_bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}
shift || true
printf 'oc %s\n' "$cmd $*" >> "$FAKE_ROOT/commands"
case "$cmd" in
    config)
        subcmd=${1:-}
        shift || true
        case "$subcmd" in
            view)
                [[ -n ${KUBECONFIG:-} && -f "$KUBECONFIG" ]] || exit 94
                [[ "$(stat -c '%a' "$KUBECONFIG")" == 600 ]] || exit 95
                printf '{"clusters":[{"name":"cluster-api","cluster":{"server":"https://api.test-infra-cluster-osac-dev.redhat.com:6443"}}]}\n'
                ;;
            set-cluster)
                server=
                tls_name=
                for arg in "$@"; do
                    case "$arg" in
                        --server=*) server=${arg#--server=} ;;
                        --tls-server-name=*) tls_name=${arg#--tls-server-name=} ;;
                    esac
                done
                [[ -n "$server" && -n "$tls_name" ]] || exit 96
                printf '%s\n' "$server" > "$FAKE_ROOT/api-server"
                printf '%s\n' "$tls_name" > "$FAKE_ROOT/tls-server-name"
                ;;
            *) exit 97 ;;
        esac
        ;;
    get)
        if [[ " $* " == *' --raw=/readyz '* ]]; then
            server=
            if [[ -f "$FAKE_ROOT/api-server" ]]; then
                server=$(<"$FAKE_ROOT/api-server")
            fi
            if [[ "$server" == *127.0.0.1* ]]; then
                [[ -f "$FAKE_ROOT/tunnel-active" ]] || exit 98
            else
                [[ ${FAKE_DIRECT_API_OK:-1} == 1 ]] || exit 99
            fi
            exit 0
        fi
        if [[ " $* " == *' subscription kubevirt-hyperconverged '* && " $* " == *' -o json '* ]]; then
            printf '{"spec":{"channel":"stable"},"status":{"currentCSV":"kubevirt-hyperconverged-operator.v4.22.0"}}\n'
            exit 0
        fi
        if [[ " $* " == *' csv kubevirt-hyperconverged-operator.v4.22.0 '* ]]; then
            if [[ "$(<"$FAKE_ROOT/cnv-state")" == healthy ]]; then printf 'Succeeded\n'; else printf 'Pending\n'; fi
            exit 0
        fi
        if [[ " $* " == *' hyperconverged kubevirt-hyperconverged '* ]]; then
            if [[ "$(<"$FAKE_ROOT/cnv-state")" == healthy ]]; then printf 'True\n'; else printf 'False\n'; fi
            exit 0
        fi
        printf 'unexpected oc get: %s\n' "$*" >&2
        exit 100
        ;;
    label|annotate)
        printf '%s %s\n' "$cmd" "$*" >> "$FAKE_ROOT/crd-adopt"
        if [[ ${FAKE_OC_FAIL_ADOPT:-0} == 1 ]]; then
            printf 'error: another change is in progress\n' >&2
            exit 1
        fi
        ;;
    *)
        printf 'unexpected oc command: %s\n' "$cmd" >&2
        exit 101
        ;;
esac
FAKE_OC
chmod +x "$fake_bin/oc"

cat > "$fake_bin/helm" <<'FAKE_HELM'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "$FAKE_ROOT/helm-commands"
helm_version=${FAKE_HELM_VERSION:-v4.3.1+g0000000}
if [[ ${1:-} == version ]]; then
    printf '%s\n' "$helm_version"
    exit 0
fi
[[ ${1:-} == list ]] || exit 99
shift
namespace=
all_states=0
while (($#)); do
    case "$1" in
        --all)
            if [[ "$helm_version" == v4.* ]]; then
                printf 'Error: unknown flag: --all\n' >&2
                exit 1
            fi
            all_states=1; shift ;;
        --namespace|-n) namespace=$2; shift 2 ;;
        --output|-o) [[ $2 == json ]] || exit 99; shift 2 ;;
        *) printf 'unexpected helm list flag: %s\n' "$1" >&2; exit 99 ;;
    esac
done
release_status=${FAKE_RELEASE_STATUS:-deployed}
if [[ "$helm_version" == v3.* && $all_states == 0 && "$release_status" != deployed && "$release_status" != failed ]]; then
    printf '[]\n'
    exit 0
fi
case "$namespace" in
    osac-deps) release=osac-deps ;;
    osac-infra) release=osac-infra ;;
    *) printf '[]\n'; exit 0 ;;
esac
version=$(awk -F= -v key="$release" '$1 == key { print $2; exit }' "$FAKE_ROOT/helm-versions")
if [[ -z "$version" || "$version" == missing ]]; then
    printf '[]\n'
else
    printf '[{"name":"%s","namespace":"%s","chart":"%s-%s","status":"%s"}]\n' \
        "$release" "$namespace" "$release" "$version" "$release_status"
fi
FAKE_HELM
chmod +x "$fake_bin/helm"

cat > "$fake_bin/make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_ROOT/make-commands"
attempt=0
if [[ -f "$FAKE_ROOT/make-count" ]]; then
    attempt=$(<"$FAKE_ROOT/make-count")
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$FAKE_ROOT/make-count"
if [[ ${FAKE_MAKE_CRD_CONFLICT:-0} != 0 ]] && ((attempt <= FAKE_MAKE_CRD_CONFLICT)); then
    printf 'Error: Unable to continue with install: %s "%s" in namespace "%s" exists and cannot be imported into the current release: invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm"; annotation validation error: missing key "meta.helm.sh/release-name": must be set to "osac-infra"; annotation validation error: missing key "meta.helm.sh/release-namespace": must be set to "osac-infra"\n' \
        "${FAKE_MAKE_CONFLICT_KIND:-CustomResourceDefinition}" \
        "${FAKE_MAKE_CONFLICT_NAME:-logicalvolumes.topolvm.io}" \
        "${FAKE_MAKE_CONFLICT_NAMESPACE:-}" >&2
    exit 2
fi
if [[ ${FAKE_MAKE_ERROR:-0} == 1 ]]; then
    printf 'Error: INSTALLATION FAILED: context deadline exceeded\n' >&2
    exit 2
fi
if [[ ${FAKE_MAKE_FIX:-1} == 1 ]]; then
    printf 'osac-deps=0.0.1\nosac-infra=0.0.1\n' > "$FAKE_ROOT/helm-versions"
    printf 'healthy\n' > "$FAKE_ROOT/cnv-state"
fi
FAKE_MAKE
chmod +x "$fake_bin/make"

setup_case() {
    local name=$1
    CASE_ROOT="$tmpdir/$name"
    mkdir -p "$CASE_ROOT/home"
    printf 'osac-dev|caas-4-22\n' > "$CASE_ROOT/clones"
    printf 'osac-deps=0.0.1\nosac-infra=0.0.1\n' > "$CASE_ROOT/helm-versions"
    printf 'healthy\n' > "$CASE_ROOT/cnv-state"
    printf 'apiVersion: v1\nkind: Config\n' > "$CASE_ROOT/source.kubeconfig"
    : > "$CASE_ROOT/commands"
}

run_installer() {
    local output=$1
    shift
    env \
        PATH="$fake_bin:$PATH" \
        REMOTE_HOST='root@remote.example' \
        DEV_ENV_NAME=osac \
        OSAC_DEV_API_RECOVERY_TIMEOUT=900 \
        HOME="$CASE_ROOT/home" \
        FAKE_ROOT="$CASE_ROOT" \
        FAKE_REMOTE_HOST='root@remote.example' \
        REAL_PYTHON3="$REAL_PYTHON3" \
        "$@" \
        "$installer" > "$output" 2>&1
}

# A same-name cluster is reused even when it records a different flavor.
setup_case existing
run_installer "$CASE_ROOT/out" || { cat "$CASE_ROOT/out" >&2; fail 'existing cluster installation check failed'; }
assert_contains 'Reusing existing cluster osac-dev (flavor caas-4-22)' "$CASE_ROOT/out"
assert_contains '/usr/local/sbin/osac-dev-dns recover osac-dev' "$CASE_ROOT/commands"
recover_line=$(grep -n 'osac-dev-dns recover' "$CASE_ROOT/commands" | cut -d: -f1)
api_line=$(grep -n 'oc get --raw=/readyz' "$CASE_ROOT/commands" | head -1 | cut -d: -f1)
((recover_line < api_line)) || fail 'API was required before DNS recovery'
[[ -s "$CASE_ROOT/dns-helper-payload" ]] || fail 'recovery used an outdated host helper'
assert_contains 'Type=exec' "$CASE_ROOT/dns-helper-payload"
assert_contains 'ExecStartPost=' "$CASE_ROOT/dns-helper-payload"
assert_contains 'https://192.0.2.11:6443' "$CASE_ROOT/api-server"
assert_contains 'api.test-infra-cluster-osac-dev.redhat.com' "$CASE_ROOT/tls-server-name"
[[ ! -e "$(<"$CASE_ROOT/scp-destination")" ]] || fail 'temporary transfer kubeconfig was not removed'
local_config="$CASE_ROOT/home/.kube/osac-dev.kubeconfig"
[[ -f "$local_config" ]] || fail 'persistent local kubeconfig was not created'
[[ "$(stat -c '%a' "$local_config")" == 600 ]] || fail 'persistent kubeconfig is not mode 0600'
[[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'matching releases and healthy CNV should skip upgrades'
assert_not_contains 'cluster-tool boot' "$CASE_ROOT/commands"
assert_not_contains 'install-osac' "$CASE_ROOT/commands"

# Kubeconfig-only mode persists access without running workload upgrades.
setup_case kubeconfig-only
run_installer "$CASE_ROOT/out" OSAC_DEV_KUBECONFIG_ONLY=1 || { cat "$CASE_ROOT/out" >&2; fail 'kubeconfig-only mode failed'; }
assert_contains 'Kubeconfig ready' "$CASE_ROOT/out"
[[ -f "$CASE_ROOT/home/.kube/osac-dev.kubeconfig" ]] || fail 'kubeconfig-only mode did not persist the kubeconfig'
[[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'kubeconfig-only mode attempted a workload upgrade'

# Check-only verifies a restored snapshot without upgrading or hiding drift.
setup_case check-only
run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=1 || {
    cat "$CASE_ROOT/out" >&2; fail 'healthy check-only verification failed';
}
assert_contains 'Infrastructure verified; no upgrade attempted' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'check-only upgraded healthy releases'

setup_case check-only-drift
printf 'osac-deps=0.0.0\nosac-infra=0.0.1\n' > "$CASE_ROOT/helm-versions"
if run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=1; then
    fail 'check-only repaired or ignored chart drift'
fi
assert_contains 'infrastructure verification failed; no upgrade attempted' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'check-only attempted to repair drift'

setup_case check-only-cnv
printf 'Pending\n' > "$CASE_ROOT/cnv-state"
if run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=1; then
    fail 'check-only repaired or ignored unhealthy CNV'
fi
[[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'check-only attempted to repair CNV'

setup_case check-only-invalid
if run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=invalid; then
    fail 'accepted invalid check-only flag'
fi
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'invalid check-only flag contacted host'

setup_case conflicting-check-only-modes
if run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=1 OSAC_DEV_KUBECONFIG_ONLY=1; then
    fail 'kubeconfig-only bypassed infrastructure verification'
fi
assert_contains 'mutually exclusive' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'conflicting flags contacted host'

# Helm 3 needs --all, whereas Helm 4 lists every state by default and rejects it.
for helm_version in v3.18.0 v4.3.1; do
    setup_case "list-compatible-$helm_version"
    run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=1 FAKE_HELM_VERSION="$helm_version" || {
        cat "$CASE_ROOT/out" >&2; fail "$helm_version release listing failed";
    }
    [[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'release inspection upgraded healthy infrastructure'
    for release_status in failed pending-upgrade; do
        setup_case "list-status-$helm_version-$release_status"
        if run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=1 \
            FAKE_HELM_VERSION="$helm_version" FAKE_RELEASE_STATUS="$release_status"; then
            fail 'check-only accepted a non-deployed release'
        fi
        assert_contains "status $release_status" "$CASE_ROOT/out"
        [[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'check-only repaired a non-deployed release'
    done
done
setup_case list-unreadable-version
if run_installer "$CASE_ROOT/out" OSAC_DEV_INFRA_CHECK_ONLY=1 FAKE_HELM_VERSION=unknown; then
    fail 'accepted an unreadable Helm version'
fi
[[ ! -s "$CASE_ROOT/make-commands" ]] || fail 'unreadable Helm version triggered an upgrade'

# Missing cluster fails safely without attempting to provision one.
setup_case missing
: > "$CASE_ROOT/clones"
if run_installer "$CASE_ROOT/out"; then
    fail 'installer should reject a missing cluster rather than booting it'
fi
assert_contains 'cluster osac-dev was not found' "$CASE_ROOT/out"
assert_not_contains 'cluster-tool boot' "$CASE_ROOT/commands"
[[ ! -e "$CASE_ROOT/scp-destination" ]] || fail 'kubeconfig was fetched for a missing cluster'

# Recovery runs even in kubeconfig-only mode and extends the API wait budget
# only when a listener was actually missing. Healthy reuses stay fast.
setup_case missing-primary-listener
run_installer "$CASE_ROOT/out" OSAC_DEV_KUBECONFIG_ONLY=1 FAKE_DNS_RECOVERY_NEEDED=1 || {
    cat "$CASE_ROOT/out" >&2; fail 'DNS recovery path failed';
}
assert_contains 'allowing up to 900s for DHCP retry and control-plane/API recovery' "$CASE_ROOT/out"
assert_contains 'Kubeconfig ready' "$CASE_ROOT/out"

# A failed host repair must stop before API calls, preserving useful errors.
setup_case recovery-fails
if run_installer "$CASE_ROOT/out" FAKE_DNS_RECOVERY_FAIL=1; then
    fail 'ignored DNS recovery failure'
fi
assert_contains 'lease helper init failed' "$CASE_ROOT/out"
assert_not_contains 'oc get --raw=/readyz' "$CASE_ROOT/commands"
[[ ! -e "$CASE_ROOT/scp-destination" ]] || fail 'fetched kubeconfig before recovery succeeded'

# Invalid wait budgets fail before any remote or API operation.
setup_case invalid-api-timeout
if run_installer "$CASE_ROOT/out" OSAC_DEV_API_RECOVERY_TIMEOUT=9999; then
    fail 'accepted an unbounded API wait'
fi
assert_contains 'OSAC_DEV_API_RECOVERY_TIMEOUT must be 1-3600 seconds' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'remote commands ran before timeout validation'

# A direct API connection failure falls back to a temporary SSH tunnel.
setup_case tunnel
run_installer "$CASE_ROOT/out" FAKE_DIRECT_API_OK=0 || { cat "$CASE_ROOT/out" >&2; fail 'SSH tunnel fallback failed'; }
assert_contains 'https://127.0.0.1:16443' "$CASE_ROOT/api-server"
assert_contains 'ssh-tunnel' "$CASE_ROOT/commands"
assert_contains 'api.test-infra-cluster-osac-dev.redhat.com' "$CASE_ROOT/tls-server-name"

# Missing/mismatched chart releases or unhealthy CNV trigger only install-infra.
setup_case update
printf 'osac-deps=0.0.0\nosac-infra=missing\n' > "$CASE_ROOT/helm-versions"
printf 'Pending\n' > "$CASE_ROOT/cnv-state"
run_installer "$CASE_ROOT/out" || { cat "$CASE_ROOT/out" >&2; fail 'infra upgrade failed'; }
assert_contains 'install-infra' "$CASE_ROOT/make-commands"
assert_contains 'PLATFORM=openshift' "$CASE_ROOT/make-commands"
assert_contains 'PROFILE=caas-ci' "$CASE_ROOT/make-commands"
assert_contains 'NS=osac' "$CASE_ROOT/make-commands"
assert_contains 'values/osac-dev/infra-cnv.yaml' "$CASE_ROOT/make-commands"
assert_not_contains 'install-osac' "$CASE_ROOT/make-commands"

# Failed post-install checks are reported rather than claimed as successful.
setup_case unhealthy
printf 'osac-deps=0.0.0\nosac-infra=0.0.1\n' > "$CASE_ROOT/helm-versions"
if run_installer "$CASE_ROOT/out" FAKE_MAKE_FIX=0; then
    fail 'installer should fail when post-install checks remain unhealthy'
fi
assert_contains 'post-install verification failed' "$CASE_ROOT/out"

# helm's CRD ownership conflict is adopted and the install retried, so a rerun
# against a cluster whose operators created their CRDs first stays upgradable.
setup_case adopt-crds
printf 'osac-deps=missing\nosac-infra=missing\n' > "$CASE_ROOT/helm-versions"
run_installer "$CASE_ROOT/out" FAKE_MAKE_CRD_CONFLICT=1 || {
    cat "$CASE_ROOT/out" >&2
    fail 'installer did not adopt the conflicting CRD and retry'
}
[[ "$(wc -l < "$CASE_ROOT/make-commands")" == 2 ]] || fail 'expected one retry after adopting the CRD'
assert_contains 'adopting CustomResourceDefinition logicalvolumes.topolvm.io into Helm release osac-infra (namespace osac-infra)' "$CASE_ROOT/out"
assert_contains 'retrying the install-infra target after adopting the conflicting objects' "$CASE_ROOT/out"
assert_contains 'label crd logicalvolumes.topolvm.io app.kubernetes.io/managed-by=Helm --overwrite' "$CASE_ROOT/crd-adopt"
assert_contains 'annotate crd logicalvolumes.topolvm.io meta.helm.sh/release-name=osac-infra meta.helm.sh/release-namespace=osac-infra --overwrite' "$CASE_ROOT/crd-adopt"
assert_not_contains 'install-infra target failed' "$CASE_ROOT/out"

# Adoption is opt-out: the failure then surfaces with the manual remedy.
setup_case adopt-crds-disabled
printf 'osac-deps=missing\nosac-infra=missing\n' > "$CASE_ROOT/helm-versions"
if run_installer "$CASE_ROOT/out" FAKE_MAKE_CRD_CONFLICT=1 OSAC_DEV_ADOPT_CRDS=0; then
    fail 'OSAC_DEV_ADOPT_CRDS=0 should surface the install failure'
fi
assert_contains 'install-infra target failed' "$CASE_ROOT/out"
[[ "$(wc -l < "$CASE_ROOT/make-commands")" == 1 ]] || fail 'retried even though CRD adoption was disabled'
[[ ! -e "$CASE_ROOT/crd-adopt" ]] || fail 'adopted a CRD even though OSAC_DEV_ADOPT_CRDS=0'

# Adoption is not CRD-only: Helm refuses to import any object another
# controller created, so a cluster-scoped ClusterRole is adopted the same way.
setup_case adopt-clusterrole
printf 'osac-deps=missing\nosac-infra=missing\n' > "$CASE_ROOT/helm-versions"
run_installer "$CASE_ROOT/out" FAKE_MAKE_CRD_CONFLICT=1 \
    FAKE_MAKE_CONFLICT_KIND=ClusterRole FAKE_MAKE_CONFLICT_NAME=cert-manager-controller-issuers \
    OSAC_DEV_INSTALL_LOG="$CASE_ROOT/install.log" || {
    cat "$CASE_ROOT/out" >&2
    fail 'installer did not adopt the conflicting ClusterRole and retry'
}
assert_contains 'adopting ClusterRole cert-manager-controller-issuers into Helm release osac-infra' "$CASE_ROOT/out"
assert_contains 'label clusterrole cert-manager-controller-issuers app.kubernetes.io/managed-by=Helm --overwrite' "$CASE_ROOT/crd-adopt"
[[ "$([ -f "$CASE_ROOT/crd-adopt" ] && grep -c '^annotate clusterrole' "$CASE_ROOT/crd-adopt")" == 1 ]] || \
    fail 'ClusterRole was not annotated'

# A failure that is not an ownership conflict keeps its log and says so,
# instead of sending the reader after CRD labels.
setup_case failure-not-ownership
printf 'osac-deps=missing\nosac-infra=missing\n' > "$CASE_ROOT/helm-versions"
if run_installer "$CASE_ROOT/out" FAKE_MAKE_ERROR=1 OSAC_DEV_INSTALL_LOG="$CASE_ROOT/install.log"; then
    fail 'a non-ownership install failure should fail the target'
fi
assert_contains 'not a Helm ownership conflict' "$CASE_ROOT/out"
assert_contains 'last errors from the install-infra log:' "$CASE_ROOT/out"
assert_contains 'Error: INSTALLATION FAILED: context deadline exceeded' "$CASE_ROOT/out"
assert_contains "full install-infra log: $CASE_ROOT/install.log" "$CASE_ROOT/out"
[[ -s "$CASE_ROOT/install.log" ]] || fail 'the failed install log was not kept'
[[ ! -e "$CASE_ROOT/crd-adopt" ]] || fail 'labelled objects for an unrelated failure'
[[ "$(wc -l < "$CASE_ROOT/make-commands")" == 1 ]] || fail 'retried an unrelated failure'

# An adoption that cannot be applied is reported as its own cause.
setup_case adoption-rejected
printf 'osac-deps=missing\nosac-infra=missing\n' > "$CASE_ROOT/helm-versions"
if run_installer "$CASE_ROOT/out" FAKE_MAKE_CRD_CONFLICT=1 FAKE_OC_FAIL_ADOPT=1 \
    OSAC_DEV_INSTALL_LOG="$CASE_ROOT/install.log"; then
    fail 'a rejected adoption should fail the target'
fi
assert_contains 'could not label CustomResourceDefinition logicalvolumes.topolvm.io' "$CASE_ROOT/out"
assert_contains 'could not be labelled or annotated' "$CASE_ROOT/out"
[[ "$(wc -l < "$CASE_ROOT/make-commands")" == 1 ]] || fail 'retried without adopting anything'

# --- localhost target ------------------------------------------------------
# The same installer runs on this machine: cluster-tool is invoked directly,
# the kubeconfig is copied as-is, and no SSH tunnel is considered.
run_local_installer() {
    local output=$1
    shift
    cat > "$tmpdir/bin/id" <<'FAKE_ID'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == -u ]]; then printf '0\n'; exit 0; fi
exec /usr/bin/id "$@"
FAKE_ID
    chmod +x "$tmpdir/bin/id"
    env \
        PATH="$fake_bin:$PATH" \
        REMOTE_HOST='' \
        DEV_ENV_NAME=osac \
        OSAC_DEV_API_RECOVERY_TIMEOUT=900 \
        OSAC_DEV_DNS_HELPER="$CASE_ROOT/host/osac-dev-dns" \
        OSAC_DEV_HOST_KUBECONFIG="$CASE_ROOT/host.kubeconfig" \
        HOME="$CASE_ROOT/home" \
        FAKE_ROOT="$CASE_ROOT" \
        FAKE_REMOTE_HOST='root@remote.example' \
        REAL_PYTHON3="$REAL_PYTHON3" \
        "$@" \
        "$installer" > "$output" 2>&1
}

setup_case local-access
mkdir -p "$CASE_ROOT/host"
cp "$CASE_ROOT/source.kubeconfig" "$CASE_ROOT/host.kubeconfig"
chmod 600 "$CASE_ROOT/host.kubeconfig"
run_local_installer "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'localhost installation check failed'
}
assert_contains 'Reusing existing cluster osac-dev (flavor caas-4-22)' "$CASE_ROOT/out"
assert_contains 'API is reachable from this host; TLS server name is api.test-infra-cluster-osac-dev.redhat.com.' "$CASE_ROOT/out"
assert_contains 'cluster-tool list --server local' "$CASE_ROOT/commands"
assert_not_contains 'ssh ' "$CASE_ROOT/commands"
# The cluster-tool kubeconfig is authoritative here: no rewrite, no SNI pin.
assert_not_contains 'config set-cluster' "$CASE_ROOT/commands"
[[ -e "$CASE_ROOT/host/osac-dev-dns" ]] || fail 'localhost target did not install the DNS helper'
local_config="$CASE_ROOT/home/.kube/osac-dev.kubeconfig"
[[ -f "$local_config" ]] || fail 'localhost target did not persist the kubeconfig'
[[ "$(stat -c '%a' "$local_config")" == 600 ]] || fail 'localhost kubeconfig is not mode 0600'

# An unreachable API on the localhost target names the local remedies and never
# opens a tunnel.
setup_case local-api-unreachable
mkdir -p "$CASE_ROOT/host"
cp "$CASE_ROOT/source.kubeconfig" "$CASE_ROOT/host.kubeconfig"
if run_local_installer "$CASE_ROOT/out" FAKE_DIRECT_API_OK=0; then
    fail 'localhost target should fail when the API is unreachable'
fi
assert_contains 'the Kubernetes API is not reachable from this host' "$CASE_ROOT/out"
assert_contains 'make osac-dev-dns' "$CASE_ROOT/out"
assert_not_contains 'ssh ' "$CASE_ROOT/commands"
assert_not_contains 'Opening an SSH tunnel' "$CASE_ROOT/out"

# OSAC_DEV_API_HOST is a remote-only workstation adaptation.
setup_case local-api-host-ignored
mkdir -p "$CASE_ROOT/host"
cp "$CASE_ROOT/source.kubeconfig" "$CASE_ROOT/host.kubeconfig"
run_local_installer "$CASE_ROOT/out" OSAC_DEV_API_HOST=192.0.2.99 || {
    cat "$CASE_ROOT/out" >&2
    fail 'localhost run with OSAC_DEV_API_HOST failed'
}
assert_contains 'Ignoring OSAC_DEV_API_HOST' "$CASE_ROOT/out"
assert_not_contains 'config set-cluster' "$CASE_ROOT/commands"

# The localhost target adopts operator-created CRDs through the same seam.
setup_case local-adopt-crds
mkdir -p "$CASE_ROOT/host"
cp "$CASE_ROOT/source.kubeconfig" "$CASE_ROOT/host.kubeconfig"
printf 'osac-deps=missing\nosac-infra=missing\n' > "$CASE_ROOT/helm-versions"
run_local_installer "$CASE_ROOT/out" FAKE_MAKE_CRD_CONFLICT=1 || {
    cat "$CASE_ROOT/out" >&2
    fail 'localhost target did not adopt the conflicting CRD'
}
assert_contains 'label crd logicalvolumes.topolvm.io' "$CASE_ROOT/crd-adopt"
assert_contains 'annotate crd logicalvolumes.topolvm.io' "$CASE_ROOT/crd-adopt"
assert_not_contains 'ssh ' "$CASE_ROOT/commands"

rm -f "$tmpdir/bin/id"

# Make exposes kubeconfig setup separately and runs it after base-cluster setup.
make -C "$repo" -n osac-dev-cluster > "$tmpdir/osac-dev-dry-run"
assert_contains 'tools/osac-dev/osac-dev-bootstrap.sh up' "$tmpdir/osac-dev-dry-run"
assert_contains 'OSAC_DEV_KUBECONFIG_ONLY=1 tools/osac-dev/osac-dev-install-infra.sh' "$tmpdir/osac-dev-dry-run"
make -C "$repo" -n osac-dev-kubeconfig > "$tmpdir/kubeconfig-dry-run"
assert_contains 'OSAC_DEV_KUBECONFIG_ONLY=1 tools/osac-dev/osac-dev-install-infra.sh' "$tmpdir/kubeconfig-dry-run"

printf 'All local infra installer tests passed.\n'
