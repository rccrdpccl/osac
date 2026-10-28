#!/usr/bin/env bash
# Contract tests for tools/osac-dev/osac-dev-deploy.sh.
#
# Every external command (ssh, scp, oc, helm, skaffold, make, uv) is faked and
# logged; no cluster, registry, or remote host is contacted. EE generation
# belongs to Skaffold's custom builder, not this workstation wrapper.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
wrapper="$repo/tools/osac-dev/osac-dev-deploy.sh"
tmpdir=$(mktemp -d)
fake_domain='apps.test-infra-cluster-osac-dev.redhat.com'

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

[[ -x "$wrapper" ]] || fail "deploy wrapper is missing or not executable: $wrapper"

trap 'rm -rf -- "$tmpdir"' EXIT

fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$FAKE_ROOT/commands"
FAKE_SSH
chmod +x "$fake_bin/ssh"

cat > "$fake_bin/scp" <<'FAKE_SCP'
#!/usr/bin/env bash
set -euo pipefail
printf 'scp %s\n' "$*" >> "$FAKE_ROOT/commands"
while [[ ${1:-} == -q || ${1:-} == -- ]]; do shift; done
source=${1:?missing source}
destination=${2:?missing destination}
[[ "$source" == "$FAKE_REMOTE_HOST:"* ]] || exit 92
cp -- "$FAKE_ROOT/license-fixture" "$destination"
FAKE_SCP
chmod +x "$fake_bin/scp"

cat > "$fake_bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}
shift || true
printf 'oc %s\n' "$cmd $*" >> "$FAKE_ROOT/commands"
case "$cmd" in
    config)
        [[ ${1:-} == current-context ]] || exit 93
        printf 'system:admin\n'
        ;;
    get)
        case ${1:-} in
            ingresses.config/cluster)
                printf '%s\n' "$(<"$FAKE_ROOT/domain")"
                ;;
            nodes)
                # Single fake InternalIP for Provisioning CR discovery.
                printf '192.0.2.10\n'
                ;;
            *)
                exit 94
                ;;
        esac
        ;;
    create)
        if [[ ${1:-} == namespace ]]; then
            printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: faked\n'
        else
            printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: faked\n'
        fi
        ;;
    apply)
        # Log the resource kind from stdin so tests can pin what was applied.
        sed -n -E \
            -e 's/^kind: ([A-Za-z]*)$/applied-kind \1/p' \
            -e 's/^  (provisioningNetwork|provisioningIP|watchAllNamespaces): (.*)$/applied-spec \1 \2/p' \
            | tee -a "$FAKE_ROOT/commands" >/dev/null
        ;;
    label)
        :
        ;;
    *)
        printf 'unexpected oc command: %s\n' "$cmd $*" >&2
        exit 95
        ;;
esac
FAKE_OC
chmod +x "$fake_bin/oc"

cat > "$fake_bin/helm" <<'FAKE_HELM'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "$FAKE_ROOT/commands"
if [[ ${1:-} == version ]]; then
    printf '%s\n' "${FAKE_HELM_VERSION:-v4.3.1+g0f00000}"
    exit 0
fi
[[ ${1:-} == status ]] || exit 90
release=$2
shift 2
namespace=
while (($#)); do
    case "$1" in
        -n|--namespace) namespace=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ "$namespace" == "$release" ]] || exit 91
if [[ "$release" == osac-deps && -f "$FAKE_ROOT/deps-missing" ]]; then
    exit 1
fi
exit 0
FAKE_HELM
chmod +x "$fake_bin/helm"

cat > "$fake_bin/skaffold" <<'FAKE_SKAFFOLD'
#!/usr/bin/env bash
printf 'FAIL: wrapper must delegate deployment to make install-osac\n' >&2
exit 98
FAKE_SKAFFOLD
chmod +x "$fake_bin/skaffold"

cat > "$fake_bin/make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'make %s\n' "$*"
    printf 'KUBECONFIG=%s\n' "${KUBECONFIG:-}"
    printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST:-}"
} >> "$FAKE_ROOT/skaffold-log"
exit "${FAKE_MAKE_EXIT:-0}"
FAKE_MAKE
chmod +x "$fake_bin/make"

# Fake docker (podman shim stand-in) so the wrapper's docker prerequisite
# check passes deterministically even on workstations without the shim.
cat > "$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
exit 0
FAKE_DOCKER
chmod +x "$fake_bin/docker"

cat > "$fake_bin/uv" <<'FAKE_UV'
#!/usr/bin/env bash
printf 'FAIL: EE generation belongs to the Skaffold builder, not the wrapper\n' >&2
exit 96
FAKE_UV
chmod +x "$fake_bin/uv"

setup_case() {
    local name=$1
    CASE_ROOT="$tmpdir/$name"
    mkdir -p "$CASE_ROOT/home" "$CASE_ROOT/run/podman"
    printf 'apiVersion: v1\nkind: Config\n' > "$CASE_ROOT/kubeconfig"
    chmod 600 "$CASE_ROOT/kubeconfig"
    printf 'fake-license\n' > "$CASE_ROOT/license-fixture"
    printf '%s\n' "$fake_domain" > "$CASE_ROOT/domain"
    # Default to an existing in-place license; scenarios that test the SSH
    # fetch remove it.
    printf 'fake-license\n' > "$CASE_ROOT/license.zip"
    chmod 600 "$CASE_ROOT/license.zip"
    : > "$CASE_ROOT/commands"
    : > "$CASE_ROOT/skaffold-log"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
        "$CASE_ROOT/run/podman/podman.sock"
}

# Usage: run_wrapper <output-file> [ENV=VALUE...] [-- <wrapper argument>...]
# Environment assignments after the defaults override them (env applies them
# in order); arguments after -- are passed to the wrapper itself.
run_wrapper() {
    local output=$1
    shift
    local -a env_overrides=()
    while [[ $# -gt 0 && $1 != -- ]]; do
        env_overrides+=("$1")
        shift
    done
    [[ ${1:-} == -- ]] && shift
    env \
        -u DOCKER_HOST -u KUBECONFIG -u REMOTE_HOST \
        -u OSAC_DEV_CLUSTER_DOMAIN -u OSAC_DEV_REGISTRY \
        PATH="$fake_bin:$PATH" \
        HOME="$CASE_ROOT/home" \
        XDG_RUNTIME_DIR="$CASE_ROOT/run" \
        FAKE_ROOT="$CASE_ROOT" \
        FAKE_REMOTE_HOST='root@remote.example' \
        OSAC_DEV_KUBECONFIG="$CASE_ROOT/kubeconfig" \
        OSAC_DEV_LICENSE_FILE="$CASE_ROOT/license.zip" \
        "${env_overrides[@]}" \
        "$wrapper" "$@" > "$output" 2>&1
}

# A missing kubeconfig fails before any cluster or build action.
setup_case missing-kubeconfig
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_KUBECONFIG="$CASE_ROOT/absent.kubeconfig"; then
    fail 'wrapper should fail when the kubeconfig is missing'
fi
assert_contains "kubeconfig not found at $CASE_ROOT/absent.kubeconfig" "$CASE_ROOT/out"
assert_contains 'make osac-dev-kubeconfig' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/skaffold-log" ]] || fail 'skaffold was invoked without a kubeconfig'

# Missing infrastructure releases fail before the license fetch or build.
setup_case missing-infra
touch "$CASE_ROOT/deps-missing"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper should fail when the osac-deps release is missing'
fi
assert_contains 'make osac-dev-install-infra' "$CASE_ROOT/out"
assert_not_contains 'scp' "$CASE_ROOT/commands"
[[ ! -s "$CASE_ROOT/skaffold-log" ]] || fail 'skaffold was invoked without infrastructure releases'

# A missing license is fetched over SSH and passed to the shared installer.
# Secret creation belongs to install-osac, not this wrapper.
setup_case license-fetch
rm -f "$CASE_ROOT/license.zip"
run_wrapper "$CASE_ROOT/out" REMOTE_HOST='root@remote.example' || {
    cat "$CASE_ROOT/out" >&2
    fail 'license fetch run failed'
}
[[ -f "$CASE_ROOT/license.zip" ]] || fail 'AAP license was not fetched'
[[ "$(stat -c '%a' "$CASE_ROOT/license.zip")" == 600 ]] || fail 'AAP license is not mode 0600'
cmp -s "$CASE_ROOT/license-fixture" "$CASE_ROOT/license.zip" || fail 'AAP license content does not match the remote fixture'
assert_contains 'root@remote.example:/root/license.zip' "$CASE_ROOT/commands"
assert_contains "AAP_LICENSE_FILE=$CASE_ROOT/license.zip" "$CASE_ROOT/skaffold-log"
assert_not_contains 'oc create namespace' "$CASE_ROOT/commands"
assert_not_contains 'oc create secret' "$CASE_ROOT/commands"
assert_not_contains 'osac.openshift.io/project=osac-aap' "$CASE_ROOT/commands"
assert_contains 'applied-kind Provisioning' "$CASE_ROOT/commands"
assert_contains 'applied-spec provisioningNetwork "Disabled"' "$CASE_ROOT/commands"
assert_contains 'applied-spec provisioningIP "192.0.2.10"' "$CASE_ROOT/commands"

# An existing license skips the SSH fetch entirely.
setup_case license-present
printf 'existing-license\n' > "$CASE_ROOT/license.zip"
chmod 600 "$CASE_ROOT/license.zip"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with an existing license failed'
}
assert_not_contains 'scp' "$CASE_ROOT/commands"

# The localhost target reads the license from this machine; no transport runs.
setup_case local-license
rm -f "$CASE_ROOT/license.zip"
run_wrapper "$CASE_ROOT/out" REMOTE_HOST= OSAC_DEV_LICENSE_REMOTE="$CASE_ROOT/license-fixture" || {
    cat "$CASE_ROOT/out" >&2
    fail 'localhost license fetch run failed'
}
[[ -f "$CASE_ROOT/license.zip" ]] || fail 'localhost AAP license was not copied'
[[ "$(stat -c '%a' "$CASE_ROOT/license.zip")" == 600 ]] || fail 'localhost AAP license is not mode 0600'
cmp -s "$CASE_ROOT/license-fixture" "$CASE_ROOT/license.zip" || \
    fail 'localhost AAP license content does not match the fixture'
assert_contains 'on this host (localhost target)' "$CASE_ROOT/out"
assert_not_contains 'scp' "$CASE_ROOT/commands"
assert_not_contains 'ssh ' "$CASE_ROOT/commands"

# A missing local license fails with an actionable message and no mutation.
setup_case local-license-missing
rm -f "$CASE_ROOT/license.zip"
if run_wrapper "$CASE_ROOT/out" REMOTE_HOST= OSAC_DEV_LICENSE_REMOTE="$CASE_ROOT/absent-license.zip"; then
    fail 'localhost target should fail when no license is readable'
fi
assert_contains 'is unreadable on the localhost target' "$CASE_ROOT/out"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"

# One-shot delegates to the installer with the personal registry and exported
# build environment; the installer owns all Helm and namespace settings.
setup_case skaffold-run
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'one-shot deploy run failed'
}
assert_contains "make -C $repo/osac-installer install-osac" "$CASE_ROOT/skaffold-log"
assert_contains 'PLATFORM=openshift PROFILE=caas-ci NS=osac' "$CASE_ROOT/skaffold-log"
assert_contains 'DEV_MODE=1 SKAFFOLD_MODE=run' "$CASE_ROOT/skaffold-log"
assert_contains 'OSAC_DEV_REGISTRY=quay.io/rh_ee_rpiccoli' "$CASE_ROOT/skaffold-log"
assert_contains 'EXTRA_HELM_ARGS=-f values/osac-dev/aap-noop-dns.yaml' "$CASE_ROOT/skaffold-log"
assert_contains "KUBECONFIG=$CASE_ROOT/kubeconfig" "$CASE_ROOT/skaffold-log"
assert_contains "DOCKER_HOST=unix://$CASE_ROOT/run/podman/podman.sock" "$CASE_ROOT/skaffold-log"

# Relative local inputs keep their meaning after make -C changes directory.
setup_case relative-inputs
relative_license=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1]))' "$CASE_ROOT/license.zip")
relative_kubeconfig=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1]))' "$CASE_ROOT/kubeconfig")
run_wrapper "$CASE_ROOT/out" \
    OSAC_DEV_LICENSE_FILE="$relative_license" OSAC_DEV_KUBECONFIG="$relative_kubeconfig" || {
    cat "$CASE_ROOT/out" >&2
    fail 'relative input deploy run failed'
}
assert_contains "AAP_LICENSE_FILE=$PWD/$relative_license" "$CASE_ROOT/skaffold-log"
assert_contains "KUBECONFIG=$PWD/$relative_kubeconfig" "$CASE_ROOT/skaffold-log"

# Watch mode delegates to the same installer with only SKAFFOLD_MODE changed.
setup_case skaffold-dev
run_wrapper "$CASE_ROOT/out" -- --dev || {
    cat "$CASE_ROOT/out" >&2
    fail 'watch mode deploy run failed'
}
assert_contains "make -C $repo/osac-installer install-osac" "$CASE_ROOT/skaffold-log"
assert_contains 'DEV_MODE=1 SKAFFOLD_MODE=dev' "$CASE_ROOT/skaffold-log"
assert_contains 'OSAC_DEV_REGISTRY=quay.io/rh_ee_rpiccoli' "$CASE_ROOT/skaffold-log"
assert_contains 'EXTRA_HELM_ARGS=-f values/osac-dev/aap-noop-dns.yaml' "$CASE_ROOT/skaffold-log"

# An installer failure is returned unchanged, with no fallback deployment.
setup_case installer-failure
if run_wrapper "$CASE_ROOT/out" FAKE_MAKE_EXIT=42; then
    fail 'wrapper should propagate installer failure'
else
    [[ $? == 42 ]] || fail 'installer exit status was not preserved'
fi
assert_contains 'DEV_MODE=1 SKAFFOLD_MODE=run' "$CASE_ROOT/skaffold-log"

# A missing skaffold binary fails before any cluster-mutating command.
setup_case missing-skaffold
no_skaffold_bin="$tmpdir/bin-without-skaffold"
mkdir -p "$no_skaffold_bin"
for executable in "$fake_bin"/*; do
    name=$(basename "$executable")
    [[ "$name" == skaffold ]] || ln -s "$executable" "$no_skaffold_bin/$name"
done
# Strip every PATH entry that provides a skaffold binary (e.g. ~/.local/bin
# after a real install) so the scenario is deterministic on any workstation.
stripped_path=$(printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do
    [[ -x "$dir/skaffold" ]] || printf '%s\n' "$dir"
done | paste -sd:)
if run_wrapper "$CASE_ROOT/out" PATH="$no_skaffold_bin:$stripped_path"; then
    fail 'wrapper should fail when skaffold is missing from PATH'
fi
assert_contains "required command 'skaffold' not found" "$CASE_ROOT/out"
assert_contains "run 'make osac-dev-setup'" "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'cluster commands ran before the skaffold availability check'

printf 'All deploy wrapper tests passed.\n'
