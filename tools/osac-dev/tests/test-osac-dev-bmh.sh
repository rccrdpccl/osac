#!/usr/bin/env bash
# Contract tests for tools/osac-dev/osac-dev-bmh.sh.
#
# Every external command (oc, helm, sleep) is faked and logged; no cluster
# and no chart repository is contacted. The fake oc captures `apply -f -`
# stdin into per-command files so the exact YAML handed to the cluster can
# be asserted, and its `get bmh` handler advances a state machine
# (registering -> inspecting -> available) so the wrapper's polling loop is
# exercised without real delays. The fake also models the environment the
# wrapper must heal: a Provisioning CR with a stale IP, an ironic-proxy
# front end answering HTTP 500 until its (and optionally metal3's)
# DaemonSet/deployment is restarted, leftover virtual media on a re-run,
# stuck or erroring BareMetalHosts, and a node bridge broken by
# NetworkManager reclaiming the bridged NIC (healed by re-running the
# node-bridge ensure, both at startup and between host-creation attempts).
# Script-payload assertions and template fixtures intentionally contain literal $variables.
# shellcheck disable=SC2016
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
wrapper="$repo/tools/osac-dev/osac-dev-bmh.sh"
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

[[ -x "$wrapper" ]] || fail "virtual BMH wrapper is missing or not executable: $wrapper"

fake_bin="$tmpdir/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/oc" <<'FAKE_OC'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}
shift || true
printf 'oc %s\n' "$cmd $*" >> "$FAKE_ROOT/commands"
case "$cmd" in
    get)
        resource=${1:-}
        case "$resource" in
            hyperconverged)
                if [[ -e "$FAKE_ROOT/cnv-not-ready" ]]; then
                    printf 'False\n'
                else
                    printf 'True\n'
                fi
                ;;
            pods)
                if [[ -e "$FAKE_ROOT/metal3-missing" ]]; then
                    printf 'No resources found in openshift-machine-api namespace.\n' >&2
                    exit 0
                fi
                if [[ "$*" == *'metadata.name'* ]]; then
                    printf 'metal3-1\n'
                else
                    printf 'pod/metal3-1\n'
                fi
                ;;
            nodes)
                if [[ "$*" == 'nodes -o json' ]]; then
                    printf '%s\n' '{"items":[{"metadata":{"name":"fake-node-0"},"status":{"addresses":[{"type":"InternalIP","address":"192.168.161.10"}]}}]}'
                else
                    printf 'fake-node-0\n'
                fi
                ;;
            kubevirt)
                if [[ -e "$FAKE_ROOT/gate-present" ]]; then
                    printf '[CPUManager Snapshot DeclarativeHotplugVolumes]\n'
                else
                    printf '[CPUManager Snapshot HotplugVolumes]\n'
                fi
                ;;
            provisioning)
                # provisioningIP and externalIPs queries: the stale primary
                # address until the wrapper patches the CR (or the fake was
                # pre-fixed), the bridge address afterwards.
                if [[ -e "$FAKE_ROOT/prov-ip-wrong" && ! -e "$FAKE_ROOT/prov-ip-fixed" ]]; then
                    printf '192.168.161.10\n'
                else
                    printf '192.168.179.10\n'
                fi
                ;;
            vm)
                if [[ "$*" == *'.spec.template.spec.volumes'* ]]; then
                    if [[ -e "$FAKE_ROOT/vm-cdrom-volume" ]]; then
                        printf 'rootdisk\ncdrom\n'
                    else
                        printf 'rootdisk\n'
                    fi
                    exit 0
                fi
                printf 'unexpected oc get vm: %s\n' "$*" >&2
                exit 97
                ;;
            virtualmachinebmc)
                # Only the pre-existence probe (-o name) is expected.
                if [[ "$*" == *'-o name'* ]]; then
                    [[ -e "$FAKE_ROOT/vmbmc-exists" ]] || exit 1
                    printf 'virtualmachinebmc.bmc.kubevirt.io/%s\n' "${2:-}"
                    exit 0
                fi
                printf 'unexpected oc get virtualmachinebmc: %s\n' "$*" >&2
                exit 98
                ;;
            bmh)
                if [[ ${2:-} == -n ]]; then
                    printf 'NAME           STATE       ONLINE   ERROR\n'
                    printf 'virtual-bmh-1  available   true\n'
                    printf 'virtual-bmh-2  available   true\n'
                    exit 0
                fi
                name=${2:-}
                if [[ "$*" == *'-o yaml'* ]]; then
                    printf 'apiVersion: metal3.io/v1alpha1\nkind: BareMetalHost\nmetadata:\n  name: %s\nstatus:\n  errorMessage: fake inspection error message\n' "$name"
                    exit 0
                fi
                if [[ "$*" == *'.spec.consumerRef.name'* ]]; then
                    if [[ -e "$FAKE_ROOT/bmh-consumer" ]]; then
                        printf 'my-bmi\n'
                    fi
                    exit 0
                fi
                if [[ "$*" == *'.status.errorMessage'* ]]; then
                    printf 'fake inspection error message\n'
                    exit 0
                fi
                if [[ -e "$FAKE_ROOT/bmh-absent" ]]; then
                    exit 1
                fi
                if [[ -e "$FAKE_ROOT/bmh-provisioned" ]]; then
                    printf 'provisioned\n'
                    exit 0
                fi
                if [[ -e "$FAKE_ROOT/bmh-stuck" || -e "$FAKE_ROOT/bmh-stuck-forever" ]]; then
                    printf 'inspecting\n'
                    # Model a NetworkManager DHCP renewal reclaiming the
                    # bridged NIC while the hosts sit stuck in inspecting
                    # (their ramdisks can no longer reach DHCP or Ironic).
                    if [[ -e "$FAKE_ROOT/bridge-breaks-mid-run" ]]; then
                        touch "$FAKE_ROOT/bridge-broken"
                    fi
                    exit 0
                fi
                if [[ -e "$FAKE_ROOT/bmh-error" ]]; then
                    printf 'error\n'
                    exit 0
                fi
                mkdir -p "$FAKE_ROOT/bmh-state"
                state_file="$FAKE_ROOT/bmh-state/$name"
                calls=0
                [[ -f "$state_file" ]] && calls=$(<"$state_file")
                calls=$((calls + 1))
                printf '%s' "$calls" > "$state_file"
                case "$calls" in
                    1) printf 'registering\n' ;;
                    2) printf 'inspecting\n' ;;
                    *) printf 'available\n' ;;
                esac
                ;;
            svc)
                printf 'NAME                      TYPE        PORT(S)\n'
                printf 'virtual-bmh-1-virtbmc     ClusterIP   80/TCP\n'
                ;;
            *)
                printf 'unexpected oc get resource: %s\n' "$resource" >&2
                exit 94
                ;;
        esac
        ;;
    patch)
        case "$1" in
            hyperconverged)
                touch "$FAKE_ROOT/gate-present"
                ;;
            provisioning)
                if [[ "$*" == *provisioningIP* ]]; then
                    touch "$FAKE_ROOT/prov-ip-fixed"
                fi
                ;;
            vm)
                # Removing the leftover cdrom volume clears the stale state.
                if [[ "$*" == *remove* ]]; then
                    rm -f "$FAKE_ROOT/vm-cdrom-volume"
                fi
                ;;
        esac
        ;;
    rollout)
        case "$*" in
            *'restart daemonset/ironic-proxy'*)
                touch "$FAKE_ROOT/ironic-api-proxy-restarted"
                ;;
            *'restart deployment/metal3'*)
                touch "$FAKE_ROOT/ironic-api-metal3-restarted"
                ;;
        esac
        ;;
    exec)
        if [[ "$*" == *curl* && "$*" == *6385* ]]; then
            if [[ -e "$FAKE_ROOT/ironic-api-down" ]]; then
                exit 7
            fi
            if [[ -e "$FAKE_ROOT/ironic-api-500" ]]; then
                if [[ -e "$FAKE_ROOT/ironic-api-stubborn" ]]; then
                    # Only a metal3 restart (plus the proxy) heals this one.
                    if [[ -e "$FAKE_ROOT/ironic-api-metal3-restarted" && -e "$FAKE_ROOT/ironic-api-proxy-restarted" ]]; then
                        printf '200\n'
                    else
                        printf '500\n'
                    fi
                elif [[ -e "$FAKE_ROOT/ironic-api-proxy-restarted" ]]; then
                    printf '200\n'
                else
                    printf '500\n'
                fi
            else
                printf '200\n'
            fi
        else
            printf 'unexpected oc exec: %s\n' "$*" >&2
            exit 96
        fi
        ;;
    wait)
        :
        ;;
    apply)
        mkdir -p "$FAKE_ROOT/applied"
        count=$(ls "$FAKE_ROOT/applied" 2>/dev/null | wc -l)
        dest="$FAKE_ROOT/applied/$(printf '%03d' "$count").yaml"
        cat > "$dest"
        # Applying a BareMetalHost makes it visible to subsequent gets and
        # restarts the state machine walk.
        if grep -q 'kind: BareMetalHost' "$dest"; then
            rm -f "$FAKE_ROOT/bmh-absent"
            rm -rf "$FAKE_ROOT/bmh-state"
        fi
        ;;
    debug)
        # The node-bridge script travels base64-encoded on the command
        # line; decode it so the tests can assert its contract. A broken
        # bridge (NetworkManager reclaimed the NIC) is healed by the call;
        # a bridge that cannot get an address fails the run.
        b64=$(printf '%s\n' "$*" | sed -n "s/.*printf %s '\([A-Za-z0-9+/=]*\)'.*/\1/p")
        if [[ -n "$b64" ]]; then
            printf '%s' "$b64" | base64 -d > "$FAKE_ROOT/node-script.sh"
        fi
        if grep -q OSAC_NIC_DISCOVERY "$FAKE_ROOT/node-script.sh"; then
            cp -- "$FAKE_ROOT/node-script.sh" "$FAKE_ROOT/inventory-script.sh"
            printf '%s\n' 'OSAC_NIC_links=[{"ifname":"ens3","link_type":"ether","flags":["UP","LOWER_UP"]},{"ifname":"enp2s0","link_type":"ether","flags":["UP","LOWER_UP"]}]'
            if [[ -e "$FAKE_ROOT/no-lab-nic" ]]; then
                printf '%s\n' 'OSAC_NIC_addresses=[{"ifname":"ens3","addr_info":[{"family":"inet","scope":"global","local":"192.168.161.10"}]}]'
            else
                printf '%s\n' 'OSAC_NIC_addresses=[{"ifname":"ens3","addr_info":[{"family":"inet","scope":"global","local":"192.168.161.10"}]},{"ifname":"enp2s0","addr_info":[{"family":"inet","scope":"global","local":"192.168.179.10"}]}]'
            fi
            printf '%s\n' 'OSAC_NIC_routes=[{"dst":"default","dev":"ens3"}]' 'OSAC_NIC_physical=["ens3","enp2s0"]'
            exit 0
        fi
        if [[ -e "$FAKE_ROOT/bridge-no-ip" ]]; then
            printf 'ERROR: node bridge br-bmh did not converge: br-bmh has no IPv4 address\n' >&2
            exit 1
        fi
        if [[ -e "$FAKE_ROOT/bridge-broken" ]]; then
            rm -f "$FAKE_ROOT/bridge-broken"
            touch "$FAKE_ROOT/bridge-healed"
            printf 'node bridge needs convergence: enp2s0 is not enslaved to br-bmh\n'
            printf 'node bridge br-bmh ready over enp2s0 (managed by: NetworkManager)\n'
        else
            printf 'node bridge br-bmh already healthy over enp2s0\n'
        fi
        printf 'BRIDGE_IPV4=192.168.179.10\n'
        ;;
    config)
        # The wrapper pins the admin context before touching the cluster.
        case "$*" in
            *get-contexts*) printf 'system:admin\n' ;;
            *use-context*) : ;;
        esac
        ;;
    delete)
        # Deleting a BMH clears error/stuck markers and the state machine;
        # bmh-stuck-forever deliberately survives (it models a failure no
        # re-create can heal).
        if [[ "$1" == bmh ]]; then
            rm -f "$FAKE_ROOT/bmh-error" "$FAKE_ROOT/bmh-stuck"
            rm -rf "$FAKE_ROOT/bmh-state"
        fi
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
if [[ ${1:-} == status ]]; then
    [[ -e "$FAKE_ROOT/kvbmc-installed" ]] || exit 1
fi
exit 0
FAKE_HELM
chmod +x "$fake_bin/helm"

# Instant sleep so the wrapper's polling loops exercise their retry logic
# without delaying the test.
cat > "$fake_bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
:
FAKE_SLEEP
chmod +x "$fake_bin/sleep"

setup_case() {
    local name=$1
    CASE_ROOT="$tmpdir/$name"
    mkdir -p "$CASE_ROOT/applied" "$CASE_ROOT/home"
    printf 'apiVersion: v1\nkind: Config\n' > "$CASE_ROOT/kubeconfig"
    chmod 600 "$CASE_ROOT/kubeconfig"
    : > "$CASE_ROOT/commands"
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
        -u KUBECONFIG \
        PATH="$fake_bin:$PATH" \
        HOME="$CASE_ROOT/home" \
        FAKE_ROOT="$CASE_ROOT" \
        OSAC_DEV_KUBECONFIG="$CASE_ROOT/kubeconfig" \
        OSAC_DEV_BMH_NODE_NIC= \
        "${env_overrides[@]}" \
        "$wrapper" "$@" > "$output" 2>&1
}

applied_yaml() {
    cat "$CASE_ROOT"/applied/*.yaml > "$CASE_ROOT/applied-all.yaml"
}

# A missing kubeconfig fails before any cluster or helm action.
setup_case missing-kubeconfig
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_KUBECONFIG="$CASE_ROOT/absent.kubeconfig"; then
    fail 'wrapper should fail when the kubeconfig is missing'
fi
assert_contains "kubeconfig not found at $CASE_ROOT/absent.kubeconfig" "$CASE_ROOT/out"
assert_contains 'make osac-dev-kubeconfig' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'cluster commands ran without a kubeconfig'

# An invalid host count fails before any cluster or helm action.
setup_case invalid-count
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_BMH_COUNT=0; then
    fail 'wrapper should fail when OSAC_DEV_BMH_COUNT is 0'
fi
assert_contains 'OSAC_DEV_BMH_COUNT must be an integer from 1 through 15' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'cluster commands ran with an invalid count'

# An invalid timeout fails before any cluster or helm action.
setup_case invalid-timeout
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_BMH_TIMEOUT_MIN=0; then
    fail 'wrapper should fail when OSAC_DEV_BMH_TIMEOUT_MIN is 0'
fi
assert_contains 'OSAC_DEV_BMH_TIMEOUT_MIN must be a positive integer' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'cluster commands ran with an invalid timeout'

# Missing source assets fail before any cluster command. Clean mode still
# works from the wrapper alone because it does not render or carry scripts.
setup_case missing-template
original_wrapper=$wrapper
mkdir -p "$CASE_ROOT/tool"
cp -- "$wrapper" "$CASE_ROOT/tool/osac-dev-bmh.sh"
wrapper="$CASE_ROOT/tool/osac-dev-bmh.sh"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper accepted a missing resource template'
fi
assert_contains 'missing BMH template:' "$CASE_ROOT/out"
[[ ! -s "$CASE_ROOT/commands" ]] || fail 'cluster commands ran before the template preflight'
run_wrapper "$CASE_ROOT/clean-out" -- --clean || fail 'cleanup should not require template or script assets'
wrapper=$original_wrapper

# A rendering error must not feed partial YAML to oc apply. Use a disposable
# copy so this check never changes the real templates or source scripts.
setup_case invalid-template
mkdir -p "$CASE_ROOT/tool"
for source in osac-dev-bmh.sh osac-dev-render-template.py; do
    cp -- "$repo/tools/osac-dev/$source" "$CASE_ROOT/tool/$source"
done
cp -R -- "$repo/tools/osac-dev/templates" "$repo/tools/osac-dev/node-scripts" "$CASE_ROOT/tool/"
for source in osac-dev-nic.py osac-dev-provisioning.sh; do
    ln -s "$repo/tools/osac-dev/$source" "$CASE_ROOT/tool/$source"
done
printf '%s\n' 'kind: Namespace' 'metadata:' '  name: ${missing}' > "$CASE_ROOT/tool/templates/bmh/namespace.yaml.tmpl"
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present"
wrapper="$CASE_ROOT/tool/osac-dev-bmh.sh"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper accepted an incomplete template'
fi
assert_contains 'could not render BMH template namespace' "$CASE_ROOT/out"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"
wrapper=$original_wrapper

# CNV not being Available fails before the helm install or any apply.
setup_case cnv-not-ready
touch "$CASE_ROOT/cnv-not-ready"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper should fail when CNV is not Available'
fi
assert_contains 'make osac-dev-install-infra' "$CASE_ROOT/out"
assert_not_contains 'helm' "$CASE_ROOT/commands"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"

# Discovery failures stop before any BMH-stage cluster/network mutations.
setup_case no-lab-nic
touch "$CASE_ROOT/no-lab-nic"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper accepted a node with no safe lab NIC'
fi
assert_contains 'no safe secondary lab NIC found' "$CASE_ROOT/out"
assert_not_contains 'oc patch' "$CASE_ROOT/commands"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"
assert_not_contains 'helm' "$CASE_ROOT/commands"

setup_case unsafe-nic-override
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_BMH_NODE_NIC=ens3; then
    fail 'wrapper accepted the primary NIC override'
fi
assert_contains 'protected primary/default-route interface' "$CASE_ROOT/out"
assert_not_contains 'oc patch' "$CASE_ROOT/commands"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"
assert_not_contains 'helm' "$CASE_ROOT/commands"

# Ironic startup is bounded and fails before the helm install.
setup_case metal3-missing
touch "$CASE_ROOT/metal3-missing"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper should fail when metal3 is not running'
fi
assert_contains 'Ironic/metal3 did not start' "$CASE_ROOT/out"
assert_not_contains 'helm' "$CASE_ROOT/commands"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"

# A missing KubeVirtBMC release is installed from the pinned chart version.
setup_case kubevirtbmc-install
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a missing KubeVirtBMC release failed'
}
assert_contains 'helm repo add kubevirtbmc https://charts.kubevirtbmc.io/' "$CASE_ROOT/commands"
assert_contains 'helm repo update kubevirtbmc' "$CASE_ROOT/commands"
assert_contains 'helm upgrade --install kubevirtbmc kubevirtbmc/kubevirtbmc' "$CASE_ROOT/commands"
assert_contains '--version 0.8.0' "$CASE_ROOT/commands"
assert_contains '--namespace kubevirtbmc-system --create-namespace' "$CASE_ROOT/commands"
assert_contains 'oc wait --for=condition=Available deployment/kubevirtbmc-controller-manager -n kubevirtbmc-system --timeout=300s' "$CASE_ROOT/commands"

# An existing KubeVirtBMC release skips the chart installation.
setup_case kubevirtbmc-present
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with an existing KubeVirtBMC release failed'
}
assert_not_contains 'helm upgrade' "$CASE_ROOT/commands"
assert_not_contains 'helm repo add' "$CASE_ROOT/commands"
assert_contains 'oc wait --for=condition=Available deployment/kubevirtbmc-controller-manager -n kubevirtbmc-system --timeout=300s' "$CASE_ROOT/commands"

# A missing DeclarativeHotplugVolumes gate is enabled through the
# HyperConverged CR, and the virt rollouts are waited on.
setup_case feature-gate-patch
touch "$CASE_ROOT/kvbmc-installed"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a missing feature gate failed'
}
assert_contains 'oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv --type merge' "$CASE_ROOT/commands"
assert_contains 'declarativeHotplugVolumes' "$CASE_ROOT/commands"
assert_contains 'oc rollout status deployment/virt-api -n openshift-cnv --timeout=600s' "$CASE_ROOT/commands"
assert_contains 'oc rollout status deployment/virt-controller -n openshift-cnv --timeout=600s' "$CASE_ROOT/commands"

# An already-enabled feature gate skips the patch and the rollouts (a
# healthy Ironic API probe performs no rollouts either).
setup_case feature-gate-present
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with an existing feature gate failed'
}
assert_not_contains 'oc patch hyperconverged' "$CASE_ROOT/commands"
assert_not_contains 'oc rollout status' "$CASE_ROOT/commands"

# A Provisioning CR advertising a stale address is patched to the bridge IP
# before any host is created.
setup_case provisioning-cr-patch
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/prov-ip-wrong"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a stale Provisioning CR failed'
}
assert_contains 'oc patch provisioning provisioning-configuration -n openshift-machine-api --type merge' "$CASE_ROOT/commands"
assert_contains '"provisioningIP":"192.168.179.10"' "$CASE_ROOT/commands"
assert_contains '"externalIPs":["192.168.179.10"]' "$CASE_ROOT/commands"
assert_contains 'oc exec -n openshift-machine-api metal3-1 -c metal3-ironic' "$CASE_ROOT/commands"
assert_contains 'https://192.168.179.10:6385/' "$CASE_ROOT/commands"

# An Ironic API answering HTTP 500 is healed by restarting the ironic-proxy
# DaemonSet alone; metal3 is not restarted.
setup_case ironic-api-proxy-heal
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/ironic-api-500"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with an unhealthy Ironic API failed'
}
assert_contains 'Ironic API is unhealthy (HTTP 500)' "$CASE_ROOT/out"
assert_contains 'oc rollout restart daemonset/ironic-proxy -n openshift-machine-api' "$CASE_ROOT/commands"
assert_contains 'oc rollout status daemonset/ironic-proxy -n openshift-machine-api --timeout=300s' "$CASE_ROOT/commands"
assert_not_contains 'oc rollout restart deployment/metal3' "$CASE_ROOT/commands"
assert_contains 'Ironic API is healthy (HTTP 200)' "$CASE_ROOT/out"

# When the proxy restart alone does not heal the API (metal3 serves a
# certificate the proxy does not trust), metal3 is restarted as well.
setup_case ironic-api-metal3-heal
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/ironic-api-500" "$CASE_ROOT/ironic-api-stubborn"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a stubbornly unhealthy Ironic API failed'
}
assert_contains 'oc rollout restart deployment/metal3 -n openshift-machine-api' "$CASE_ROOT/commands"
assert_contains 'restarting metal3 so it serves the current TLS secret' "$CASE_ROOT/out"
assert_contains 'Ironic API is healthy (HTTP 200)' "$CASE_ROOT/out"

# An Ironic API that never becomes healthy fails the run with a pointer at
# the ironic-proxy logs.
setup_case ironic-api-never-heals
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/ironic-api-down"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper should fail when the Ironic API never becomes healthy'
fi
assert_contains 'did not become healthy' "$CASE_ROOT/out"
assert_contains 'oc logs -n openshift-machine-api daemonset/ironic-proxy' "$CASE_ROOT/out"

# A node bridge broken before the run (NetworkManager reclaimed the bridged
# NIC's standalone profile) is converged by the startup ensure; the run
# proceeds normally afterwards.
setup_case bridge-broken-at-start
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bridge-broken"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a pre-broken node bridge failed'
}
assert_contains 'node bridge needs convergence' "$CASE_ROOT/out"
assert_contains 'node bridge br-bmh ready over enp2s0 (managed by: NetworkManager)' "$CASE_ROOT/out"
[[ -e "$CASE_ROOT/bridge-healed" ]] || fail 'the pre-broken bridge was not healed'
count=$(grep -Fc 'oc debug node/fake-node-0' "$CASE_ROOT/commands")
[[ "$count" -eq 2 ]] || fail "expected discovery and one bridge ensure, found $count debug calls"

# Regression (observed live): a NetworkManager DHCP renewal reclaiming the
# bridged NIC mid-run leaves the stuck hosts without DHCP and Ironic
# heartbeats; the wrapper must re-ensure the bridge (and the Provisioning CR
# and Ironic API) between attempts, and the retry then succeeds.
setup_case bridge-breaks-mid-run
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bmh-stuck" \
    "$CASE_ROOT/vmbmc-exists" "$CASE_ROOT/bridge-breaks-mid-run"
run_wrapper "$CASE_ROOT/out" OSAC_DEV_BMH_TIMEOUT_MIN=1 || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a mid-run bridge break should recover'
}
assert_contains 'hosts not available after attempt 1' "$CASE_ROOT/out"
assert_contains 'node bridge needs convergence' "$CASE_ROOT/out"
assert_contains 'node bridge br-bmh ready over enp2s0 (managed by: NetworkManager)' "$CASE_ROOT/out"
[[ -e "$CASE_ROOT/bridge-healed" ]] || fail 'the mid-run bridge break was not healed'
count=$(grep -Fc 'oc debug node/fake-node-0' "$CASE_ROOT/commands")
[[ "$count" -eq 3 ]] || fail "expected discovery and two bridge ensures, found $count debug calls"
count=$(grep -Fc 'Provisioning CR already advertises 192.168.179.10' "$CASE_ROOT/out")
[[ "$count" -ge 2 ]] || fail "expected the Provisioning CR to be re-checked between attempts"

# A bridge that cannot converge (no IPv4 address ends up on it) fails the
# run with a pointer at the NIC before any host resources are applied.
setup_case bridge-no-ip
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bridge-no-ip"
if run_wrapper "$CASE_ROOT/out"; then
    fail 'wrapper should fail when the node bridge cannot converge'
fi
assert_contains 'failed to ensure the node bridge br-bmh over enp2s0' "$CASE_ROOT/out"
assert_contains 'ERROR: node bridge br-bmh did not converge: br-bmh has no IPv4 address' "$CASE_ROOT/out"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"
assert_not_contains '"provisioningIP":' "$CASE_ROOT/commands"

# The happy path creates the full per-host resource stack and waits for the
# BMHs to become available.
setup_case happy-path
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'happy path run failed'
}
applied_yaml
assert_contains 'kind: Namespace' "$CASE_ROOT/applied-all.yaml"
assert_contains 'name: host-inventory' "$CASE_ROOT/applied-all.yaml"
# Node bridge ensure runs on the node before any resources are applied, and
# the bridge address it reports is used for the Provisioning CR check and
# the Ironic API probe.
assert_contains 'oc debug node/fake-node-0' "$CASE_ROOT/commands"
# The shared kubeconfig's current-context is pinned to the cluster's admin
# context before any cluster command relies on it.
assert_contains 'oc config use-context system:admin' "$CASE_ROOT/commands"
# The carried node script converges through NetworkManager when it manages
# the NIC, demotes the NIC's standalone profile, preserves VM tap ports and
# the IPv4 identity, falls back to a manual bridge without NM, and
# short-circuits on an already-healthy bridge.
[[ -f "$CASE_ROOT/node-script.sh" ]] || fail 'the node-bridge script was not captured'
cmp -s "$repo/tools/osac-dev/node-scripts/ensure-bmh-bridge.sh" "$CASE_ROOT/node-script.sh" || \
    fail 'the transported bridge script differs from its readable source'
cmp -s "$repo/tools/osac-dev/node-scripts/inspect-nics.sh" "$CASE_ROOT/inventory-script.sh" || \
    fail 'the transported inventory script differs from its readable source'
assert_contains 'nmcli con add type bridge' "$CASE_ROOT/node-script.sh"
assert_contains 'type bridge-slave' "$CASE_ROOT/node-script.sh"
assert_contains 'connection.autoconnect no' "$CASE_ROOT/node-script.sh"
assert_contains 'GENERAL.STATE' "$CASE_ROOT/node-script.sh"
assert_contains 'brif' "$CASE_ROOT/node-script.sh"
assert_contains 'bridge.mac-address' "$CASE_ROOT/node-script.sh"
assert_contains 'for target_dev in "$bridge" "$nic"' "$CASE_ROOT/node-script.sh"
assert_contains 'ip link del "$bridge"' "$CASE_ROOT/node-script.sh"
assert_contains 'already healthy' "$CASE_ROOT/node-script.sh"
assert_contains 'ip link set "$nic" master "$bridge"' "$CASE_ROOT/node-script.sh"
assert_contains 'Provisioning CR already advertises 192.168.179.10' "$CASE_ROOT/out"
assert_contains 'oc exec -n openshift-machine-api metal3-1 -c metal3-ironic' "$CASE_ROOT/commands"
assert_contains 'https://192.168.179.10:6385/' "$CASE_ROOT/commands"
assert_contains 'Ironic API is healthy (HTTP 200)' "$CASE_ROOT/out"
# A fresh create must not reset anything.
assert_not_contains 'oc patch vm' "$CASE_ROOT/commands"
assert_not_contains 'oc delete --ignore-not-found datavolume' "$CASE_ROOT/commands"
assert_not_contains 'oc delete --ignore-not-found secret' "$CASE_ROOT/commands"
# Host network NAD.
assert_contains 'kind: NetworkAttachmentDefinition' "$CASE_ROOT/applied-all.yaml"
assert_contains '"type": "cnv-bridge"' "$CASE_ROOT/applied-all.yaml"
assert_contains '"cniVersion": "1.1.0"' "$CASE_ROOT/applied-all.yaml"
assert_contains '"bridge": "br-bmh"' "$CASE_ROOT/applied-all.yaml"
for i in 1 2; do
    mac="52:54:00:bb:cc:$(printf '%02x' "$i")"
    name="virtual-bmh-$i"
    assert_contains "name: $name" "$CASE_ROOT/applied-all.yaml"
    # PVC root disk (named <host>-root: KubeVirtBMC names its virtual-media
    # DataVolume after the VM, so the root PVC must not share that name).
    assert_contains "name: ${name}-root" "$CASE_ROOT/applied-all.yaml"
    assert_contains "claimName: ${name}-root" "$CASE_ROOT/applied-all.yaml"
    assert_contains 'volumeMode: Block' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'storage: 150Gi' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'storageClassName: lvms-vg1' "$CASE_ROOT/applied-all.yaml"
    # VM shape.
    assert_contains 'runStrategy: Halted' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'cores: 4' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'guest: 8Gi' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'cpu: 500m' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'secureBoot: false' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'bus: virtio' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'bus: sata' "$CASE_ROOT/applied-all.yaml"
    assert_contains "macAddress: \"$mac\"" "$CASE_ROOT/applied-all.yaml"
    assert_contains 'bridge: {}' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'networkName: br-bmh-nad' "$CASE_ROOT/applied-all.yaml"
    assert_not_contains 'masquerade' "$CASE_ROOT/applied-all.yaml"
    # The cdrom disk exists for virtual media but has no volume entry (the
    # KubeVirtBMC controller attaches the DataVolume on insert).
    count=$(grep -Fc 'name: cdrom' "$CASE_ROOT/applied-all.yaml")
    [[ "$count" -eq 2 ]] || fail "expected exactly one cdrom entry per host, found $count"
    # BMC credentials shared by VirtualMachineBMC and BareMetalHost.
    assert_contains 'name: virtual-bmh-'"$i"'-bmc' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'username: admin' "$CASE_ROOT/applied-all.yaml"
    # VirtualMachineBMC wiring.
    assert_contains 'kind: VirtualMachineBMC' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'virtualMachineRef:' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'authSecretRef:' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'bmc.kubevirt.io/datavolume-size-margin: "30"' "$CASE_ROOT/applied-all.yaml"
    # BareMetalHost wiring.
    assert_contains 'kind: BareMetalHost' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'online: true' "$CASE_ROOT/applied-all.yaml"
    assert_contains "bootMACAddress: \"$mac\"" "$CASE_ROOT/applied-all.yaml"
    assert_contains 'bootMode: UEFI' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'automatedCleaningMode: metadata' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'deviceName: /dev/vda' "$CASE_ROOT/applied-all.yaml"
    assert_contains "redfish-virtualmedia+http://$name-virtbmc.host-inventory.svc.cluster.local:80/redfish/v1/Systems/1" \
        "$CASE_ROOT/applied-all.yaml"
    assert_contains 'credentialsName: virtual-bmh-'"$i"'-bmc' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'disableCertificateVerification: true' "$CASE_ROOT/applied-all.yaml"
    assert_contains 'osac.openshift.io/host-type: default' "$CASE_ROOT/applied-all.yaml"
    assert_contains "{\"data-0\":\"$mac\"}" "$CASE_ROOT/applied-all.yaml"
    # Per-host waits.
    assert_contains "oc wait --for=condition=ServiceReady virtualmachinebmc $name -n host-inventory --timeout=180s" "$CASE_ROOT/commands"
    assert_contains "oc get svc $name-virtbmc -n host-inventory" "$CASE_ROOT/commands"
done
# The BMH polling walked through the intermediate states and the summary was
# printed.
assert_contains 'inspecting' "$CASE_ROOT/out"
assert_contains 'oc get bmh -n host-inventory' "$CASE_ROOT/commands"

# A re-run without BareMetalHosts resets stale virtual media: the VM is
# halted, a leftover cdrom volume is stripped, the DataVolume is deleted,
# and the BMC Secret is rotated (restarting the virtbmc pod and its
# in-memory Redfish state).
setup_case stale-media-reset
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/vmbmc-exists" "$CASE_ROOT/vm-cdrom-volume" "$CASE_ROOT/bmh-absent"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'stale media reset run failed'
}
assert_contains 'resetting stale state for virtual-bmh-1' "$CASE_ROOT/out"
assert_contains 'oc patch vm virtual-bmh-1 -n host-inventory --type merge -p {"spec":{"runStrategy":"Halted"}}' "$CASE_ROOT/commands"
assert_contains 'oc patch vm virtual-bmh-1 -n host-inventory --type json -p [{"op":"remove","path":"/spec/template/spec/volumes/1"}]' "$CASE_ROOT/commands"
assert_contains 'oc delete --ignore-not-found datavolume virtual-bmh-1 -n host-inventory' "$CASE_ROOT/commands"
assert_contains 'oc delete --ignore-not-found secret virtual-bmh-1-bmc -n host-inventory' "$CASE_ROOT/commands"
applied_yaml
# The rotated Secret is re-applied: three Secret manifests total (host 1 in
# the create loop, host 1 in the reset, host 2 in the create loop).
count=$(grep -Fc 'kind: Secret' "$CASE_ROOT/applied-all.yaml")
[[ "$count" -eq 3 ]] || fail "expected the rotated BMC Secret to be re-applied, found $count Secret manifests"

# A BMH in the error state is deleted, reset, and re-created instead of
# failing the run on the first error.
setup_case bmh-error-recovers
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bmh-error" "$CASE_ROOT/vmbmc-exists"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with an erroring BMH should recover'
}
assert_contains 'BareMetalHost virtual-bmh-1 is in state error; deleting and resetting it before re-creation' "$CASE_ROOT/out"
assert_contains 'oc delete bmh virtual-bmh-1 -n host-inventory --wait --timeout=600s' "$CASE_ROOT/commands"
assert_contains 'resetting stale state for virtual-bmh-1' "$CASE_ROOT/out"

# Hosts stuck in inspecting time out after OSAC_DEV_BMH_TIMEOUT_MIN minutes
# and are deleted, reset, and re-created once; a retry that heals succeeds.
setup_case bmh-stuck-recovers
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bmh-stuck" "$CASE_ROOT/vmbmc-exists"
run_wrapper "$CASE_ROOT/out" OSAC_DEV_BMH_TIMEOUT_MIN=1 || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with a stuck BMH should recover through the retry'
}
assert_contains 'hosts not available after attempt 1' "$CASE_ROOT/out"
assert_contains 'oc delete bmh virtual-bmh-1 -n host-inventory --wait --timeout=600s' "$CASE_ROOT/commands"
assert_contains 'resetting stale state for virtual-bmh-1' "$CASE_ROOT/out"

# A stuck BMH that not even a re-create can heal fails the run after the
# configured attempts, surfacing the BMH error message and status.
setup_case bmh-stuck-fails
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bmh-stuck-forever" "$CASE_ROOT/vmbmc-exists"
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_BMH_TIMEOUT_MIN=1; then
    fail 'wrapper should fail when a stuck BMH never becomes available'
fi
assert_contains 'did not reach the available state within 1 minutes across 2 attempts' "$CASE_ROOT/out"
assert_contains 'last state: inspecting' "$CASE_ROOT/out"
assert_contains 'fake inspection error message' "$CASE_ROOT/out"
assert_contains 'oc get bmh virtual-bmh-1 -n host-inventory -o yaml' "$CASE_ROOT/commands"

# A stuck BMH held by a consumer is never deleted; the run fails with a
# pointer at the owning instance instead.
setup_case bmh-consumer-protected
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bmh-stuck-forever" "$CASE_ROOT/bmh-consumer" "$CASE_ROOT/vmbmc-exists"
if run_wrapper "$CASE_ROOT/out" OSAC_DEV_BMH_TIMEOUT_MIN=1; then
    fail 'wrapper should fail when a consumer-held BMH is stuck'
fi
assert_contains 'held by a consumer; refusing to delete it' "$CASE_ROOT/out"
assert_not_contains 'oc delete bmh virtual-bmh-1' "$CASE_ROOT/commands"

# Provisioned hosts are treated as ready and left untouched.
setup_case bmh-provisioned
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present" "$CASE_ROOT/bmh-provisioned" "$CASE_ROOT/vmbmc-exists"
run_wrapper "$CASE_ROOT/out" || {
    cat "$CASE_ROOT/out" >&2
    fail 'run with provisioned BMHs failed'
}
assert_contains '(held by a consumer); treating it as ready' "$CASE_ROOT/out"
assert_not_contains 'oc delete bmh' "$CASE_ROOT/commands"

# Environment overrides shape every created resource.
setup_case env-overrides
touch "$CASE_ROOT/gate-present"
run_wrapper "$CASE_ROOT/out" \
    OSAC_DEV_BMH_COUNT=1 \
    OSAC_DEV_BMH_NAMESPACE=other-inventory \
    OSAC_DEV_BMH_PREFIX=vb \
    OSAC_DEV_BMH_CPU=2 \
    OSAC_DEV_BMH_MEMORY=4Gi \
    OSAC_DEV_BMH_DISK=100Gi \
    OSAC_DEV_BMH_STORAGE_CLASS=custom-sc \
    OSAC_DEV_BMH_KUBEVIRTBMC_VERSION=0.7.0 || {
    cat "$CASE_ROOT/out" >&2
    fail 'env override run failed'
}
applied_yaml
assert_contains 'name: other-inventory' "$CASE_ROOT/applied-all.yaml"
assert_contains 'name: vb-1' "$CASE_ROOT/applied-all.yaml"
assert_not_contains 'virtual-bmh' "$CASE_ROOT/applied-all.yaml"
assert_contains 'cores: 2' "$CASE_ROOT/applied-all.yaml"
assert_contains 'guest: 4Gi' "$CASE_ROOT/applied-all.yaml"
assert_contains 'storage: 100Gi' "$CASE_ROOT/applied-all.yaml"
assert_contains 'storageClassName: custom-sc' "$CASE_ROOT/applied-all.yaml"
assert_contains 'macAddress: "52:54:00:bb:cc:01"' "$CASE_ROOT/applied-all.yaml"
assert_contains 'claimName: vb-1-root' "$CASE_ROOT/applied-all.yaml"
assert_contains 'redfish-virtualmedia+http://vb-1-virtbmc.other-inventory.svc.cluster.local:80/redfish/v1/Systems/1' \
    "$CASE_ROOT/applied-all.yaml"
assert_contains 'helm upgrade --install kubevirtbmc kubevirtbmc/kubevirtbmc --version 0.7.0' "$CASE_ROOT/commands"

# Clean mode removes the full per-host stack in dependency order and leaves
# the shared KubeVirtBMC release and feature gate alone.
setup_case clean
touch "$CASE_ROOT/kvbmc-installed" "$CASE_ROOT/gate-present"
run_wrapper "$CASE_ROOT/out" -- --clean || {
    cat "$CASE_ROOT/out" >&2
    fail 'clean run failed'
}
for i in 1 2; do
    name="virtual-bmh-$i"
    bmh_line=$(grep -nF "oc delete --ignore-not-found bmh $name -n host-inventory --wait --timeout=1200s" "$CASE_ROOT/commands" | cut -d: -f1)
    vmbmc_line=$(grep -nF "oc delete --ignore-not-found virtualmachinebmc $name -n host-inventory --wait --timeout=600s" "$CASE_ROOT/commands" | cut -d: -f1)
    vm_line=$(grep -nF "oc delete --ignore-not-found vm $name -n host-inventory --wait --timeout=600s" "$CASE_ROOT/commands" | cut -d: -f1)
    pvc_line=$(grep -nF "oc delete --ignore-not-found pvc $name-root -n host-inventory --wait --timeout=600s" "$CASE_ROOT/commands" | cut -d: -f1)
    dv_line=$(grep -nF "oc delete --ignore-not-found datavolume $name -n host-inventory --wait --timeout=600s" "$CASE_ROOT/commands" | cut -d: -f1)
    secret_line=$(grep -nF "oc delete --ignore-not-found secret $name-bmc -n host-inventory" "$CASE_ROOT/commands" | cut -d: -f1)
    [[ -n "$bmh_line" && -n "$vmbmc_line" && -n "$vm_line" && -n "$pvc_line" && -n "$dv_line" && -n "$secret_line" ]] ||
        fail "clean mode did not delete every resource for $name"
    ((bmh_line < vmbmc_line && vmbmc_line < vm_line && vm_line < pvc_line && pvc_line < dv_line && dv_line < secret_line)) ||
        fail "clean mode deleted $name resources in the wrong order"
done
assert_not_contains 'helm uninstall' "$CASE_ROOT/commands"
assert_not_contains 'oc patch hyperconverged' "$CASE_ROOT/commands"
assert_not_contains 'oc apply' "$CASE_ROOT/commands"
assert_not_contains 'status.provisioning.state' "$CASE_ROOT/commands"
assert_contains 'oc delete --ignore-not-found network-attachment-definition br-bmh-nad -n host-inventory' "$CASE_ROOT/commands"

printf 'All virtual BMH wrapper tests passed.\n'
