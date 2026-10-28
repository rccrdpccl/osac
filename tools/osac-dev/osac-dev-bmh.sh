#!/usr/bin/env bash
# Provision virtual BareMetalHosts for BMaaS on the osac-dev cluster.
#
# The CNV counterpart of osac-test-infra's setup-virtual-bmh.sh (libvirt +
# sushy-tools): instead of libvirt VMs on the cluster-tool host, this creates
# KubeVirt VirtualMachines through OpenShift Virtualization and gives each
# one a Redfish BMC served by KubeVirtBMC. BareMetalHost CRs wired to those
# BMCs are created in the BMaaS host-inventory namespace, and Ironic inspects
# and provisions them exactly as it would physical hardware.
#
# Prerequisites (verified, not installed): make osac-dev-cluster (cluster +
# kubeconfig), make osac-dev-install-infra (CNV). Initializes Ironic through
# the shared Provisioning prerequisite. The tool itself installs the
# KubeVirtBMC Helm release, enables the declarativeHotplugVolumes CNV feature
# gate (cluster-wide, required for Redfish virtual media), bridges the VMs
# onto the node's secondary lab NIC (through NetworkManager when it manages
# the NIC, so DHCP renewals cannot steal it back), and re-advertises that
# bridge address in the Provisioning CR so the inspection ISOs point the IPA
# agents at an Ironic API they can actually reach.
#
# Usage:
#   make osac-dev-bmh          # create N virtual BMHs (default 2)
#   make osac-dev-bmh-clean    # remove them again
#
# Environment:
#   OSAC_DEV_BMH_COUNT               number of hosts (default 2, 1-15)
#   OSAC_DEV_BMH_NAMESPACE           namespace for all host resources (default host-inventory)
#   OSAC_DEV_BMH_PREFIX              resource name prefix (default virtual-bmh)
#   OSAC_DEV_BMH_CPU                 vCPUs per host (default 4)
#   OSAC_DEV_BMH_MEMORY              guest memory per host (default 8Gi)
#   OSAC_DEV_BMH_DISK                root disk size per host (default 150Gi)
#   OSAC_DEV_BMH_STORAGE_CLASS       StorageClass for root disks and virtual media (default lvms-vg1)
#   OSAC_DEV_BMH_KUBEVIRTBMC_VERSION KubeVirtBMC chart version (default 0.8.0)
#   OSAC_DEV_BMH_NODE_NIC            optional secondary lab NIC override (discovered after boot);
#                                    primary/API NICs are rejected. The lab network must provide
#                                    DHCP and Ironic <-> agent connectivity.
#   OSAC_DEV_BMH_TIMEOUT_MIN         minutes to wait per attempt for the hosts to become
#                                    available (default 10; a healthy inspection completes in
#                                    a few minutes, a stuck one never recovers on its own)
#   OSAC_DEV_BMH_ATTEMPTS            total create+wait attempts (default 2: hosts that are not
#                                    available after the timeout are deleted, reset, and
#                                    re-created once before the run fails)
#   OSAC_DEV_KUBECONFIG              kubeconfig path (default ~/.kube/osac-dev.kubeconfig)
set -euo pipefail

tool_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
template_dir="$tool_dir/templates/bmh"
node_script_dir="$tool_dir/node-scripts"

OSAC_DEV_KUBECONFIG=${OSAC_DEV_KUBECONFIG:-$HOME/.kube/${DEV_ENV_NAME:-osac}-dev.kubeconfig}
OSAC_DEV_BMH_COUNT=${OSAC_DEV_BMH_COUNT:-2}
OSAC_DEV_BMH_NAMESPACE=${OSAC_DEV_BMH_NAMESPACE:-host-inventory}
OSAC_DEV_BMH_PREFIX=${OSAC_DEV_BMH_PREFIX:-virtual-bmh}
OSAC_DEV_BMH_CPU=${OSAC_DEV_BMH_CPU:-4}
OSAC_DEV_BMH_MEMORY=${OSAC_DEV_BMH_MEMORY:-8Gi}
OSAC_DEV_BMH_DISK=${OSAC_DEV_BMH_DISK:-150Gi}
OSAC_DEV_BMH_STORAGE_CLASS=${OSAC_DEV_BMH_STORAGE_CLASS:-lvms-vg1}
OSAC_DEV_BMH_KUBEVIRTBMC_VERSION=${OSAC_DEV_BMH_KUBEVIRTBMC_VERSION:-0.8.0}
OSAC_DEV_BMH_NODE_NIC=${OSAC_DEV_BMH_NODE_NIC:-}
OSAC_DEV_BMH_TIMEOUT_MIN=${OSAC_DEV_BMH_TIMEOUT_MIN:-10}
OSAC_DEV_BMH_ATTEMPTS=${OSAC_DEV_BMH_ATTEMPTS:-2}

CNV_NAMESPACE=openshift-cnv
HYPERCONVERGED=kubevirt-hyperconverged
KUBEVIRT_CR=kubevirt-kubevirt-hyperconverged
MACHINE_API_NAMESPACE=openshift-machine-api
PROVISIONING_CR=provisioning-configuration
KVBMC_RELEASE=kubevirtbmc
KVBMC_NAMESPACE=kubevirtbmc-system
KVBMC_CONTROLLER_DEPLOYMENT=kubevirtbmc-controller-manager
NODE_BRIDGE=br-bmh
BMH_POLL_INTERVAL=15
BMH_RETRIES=$((OSAC_DEV_BMH_TIMEOUT_MIN * 60 / BMH_POLL_INTERVAL))
mode=create

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean) mode=clean ;;
        *) fail "unknown argument: $1" ;;
    esac
    shift
done

if [[ ! "$OSAC_DEV_BMH_COUNT" =~ ^[0-9]+$ ]] || ! ((OSAC_DEV_BMH_COUNT >= 1 && OSAC_DEV_BMH_COUNT <= 15)); then
    fail "OSAC_DEV_BMH_COUNT must be an integer from 1 through 15 (got: $OSAC_DEV_BMH_COUNT)"
fi
[[ "$OSAC_DEV_BMH_TIMEOUT_MIN" =~ ^[1-9][0-9]*$ ]] || \
    fail "OSAC_DEV_BMH_TIMEOUT_MIN must be a positive integer (got: $OSAC_DEV_BMH_TIMEOUT_MIN)"
[[ "$OSAC_DEV_BMH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || \
    fail "OSAC_DEV_BMH_ATTEMPTS must be a positive integer (got: $OSAC_DEV_BMH_ATTEMPTS)"

require_local_command() {
    command -v "$1" &>/dev/null || fail "required command '$1' not found in PATH${2:+ ($2)}"
}

# make osac-dev-setup installs the pinned Helm here; prefer it over a system
# Helm of a different version, as osac-dev.sh already does.
export PATH="$HOME/.local/bin:$PATH"

require_local_command oc
require_local_command helm
require_local_command python3

# --- kubeconfig -----------------------------------------------------------
[[ -f "$OSAC_DEV_KUBECONFIG" ]] || \
    fail "kubeconfig not found at $OSAC_DEV_KUBECONFIG; run 'make osac-dev-kubeconfig' (requires REMOTE_HOST) first"
export KUBECONFIG="$OSAC_DEV_KUBECONFIG"

# Clean mode only deletes existing resources; it does not need render inputs.
if [[ "$mode" == create ]]; then
    for template in namespace network-attachment bmc-secret baremetalhost virtual-host; do
        [[ -r "$template_dir/$template.yaml.tmpl" ]] || fail "missing BMH template: $template_dir/$template.yaml.tmpl"
    done
    for asset in "$tool_dir/osac-dev-render-template.py" \
            "$node_script_dir/ensure-bmh-bridge.sh" "$node_script_dir/inspect-nics.sh"; do
        [[ -r "$asset" ]] || fail "missing BMH source file: $asset"
    done
fi

# The kubeconfig file is shared with other workflows, and unrelated
# `oc config` merges can repoint its current-context at a different
# cluster. This tool must only ever talk to the osac-dev cluster, so pin
# its admin context when the file carries one.
if oc config get-contexts -o name 2>/dev/null | grep -qx 'system:admin'; then
    oc config use-context system:admin >/dev/null
fi

host_names() {
    local i
    for ((i = 1; i <= OSAC_DEV_BMH_COUNT; i++)); do
        printf '%s\n' "${OSAC_DEV_BMH_PREFIX}-${i}"
    done
}

host_mac() {
    printf '52:54:00:bb:cc:%02x' "$1"
}

bmh_state() {
    oc get bmh "$1" -n "$OSAC_DEV_BMH_NAMESPACE" \
        -o jsonpath='{.status.provisioning.state}' 2>/dev/null || true
}

# --- clean mode -------------------------------------------------------------
if [[ "$mode" == clean ]]; then
    info "removing ${OSAC_DEV_BMH_COUNT} virtual BMHs from namespace $OSAC_DEV_BMH_NAMESPACE"
    for ((i = OSAC_DEV_BMH_COUNT; i >= 1; i--)); do
        name="${OSAC_DEV_BMH_PREFIX}-${i}"
        info "deleting $name"
        # The BareMetalHost finalizer deprovisions and cleans the host; this
        # is the slow step. --ignore-not-found keeps cleanup going when an
        # earlier run stopped halfway.
        oc delete --ignore-not-found bmh "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=1200s
        oc delete --ignore-not-found virtualmachinebmc "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=600s
        oc delete --ignore-not-found vm "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=600s
        oc delete --ignore-not-found pvc "${name}-root" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=600s
        # KubeVirtBMC names the virtual-media DataVolume after the VM; it is
        # normally deleted when the BMH deprovisioning ejects the media, but
        # remove any leftover (e.g. after an aborted inspection) explicitly.
        oc delete --ignore-not-found datavolume "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=600s
        oc delete --ignore-not-found secret "${name}-bmc" -n "$OSAC_DEV_BMH_NAMESPACE"
    done
    oc delete --ignore-not-found network-attachment-definition "${NODE_BRIDGE}-nad" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=120s
    info "done; the node bridge $NODE_BRIDGE, KubeVirtBMC, and the declarativeHotplugVolumes feature gate were left in place"
    info "to remove them manually: helm uninstall $KVBMC_RELEASE -n $KVBMC_NAMESPACE"
    exit 0
fi

# --- CNV must be deployed ---------------------------------------------------
cnv_available=$(oc get hyperconverged "$HYPERCONVERGED" -n "$CNV_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null) || cnv_available=
[[ "$cnv_available" == "True" ]] || \
    fail "CNV (OpenShift Virtualization) is not Available; run 'make osac-dev-install-infra' first"

# Discover and validate the guest NIC after boot, before any BMH-stage writes.
# Overrides are validated too: never bridge the primary/API/default-route NIC.
OSAC_DEV_BMH_NODE_NIC=$(python3 "$(dirname -- "${BASH_SOURCE[0]}")/osac-dev-nic.py" "$OSAC_DEV_BMH_NODE_NIC") || \
    fail 'could not select a safe secondary lab NIC; see discovery diagnostics above'
[[ "$OSAC_DEV_BMH_NODE_NIC" =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail 'discovery returned an invalid NIC name'
info "selected SNO lab NIC: $OSAC_DEV_BMH_NODE_NIC"

# --- Initialize Ironic without requiring the OSAC platform release -----------
"$(dirname -- "${BASH_SOURCE[0]}")/osac-dev-provisioning.sh"
for ((attempt = 1; attempt <= 60; attempt++)); do
    if oc get pods -n "$MACHINE_API_NAMESPACE" \
            -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state \
            -o name 2>/dev/null | grep -q '^pod/'; then
        break
    fi
    ((attempt < 60)) || fail "Ironic/metal3 did not start in $MACHINE_API_NAMESPACE; inspect the Provisioning CR and cluster-baremetal-operator"
    sleep 5
done

# --- KubeVirtBMC (BMC emulation layer) ---------------------------------------
if ! helm status "$KVBMC_RELEASE" -n "$KVBMC_NAMESPACE" &>/dev/null; then
    info "installing KubeVirtBMC chart ${OSAC_DEV_BMH_KUBEVIRTBMC_VERSION}"
    helm repo add kubevirtbmc https://charts.kubevirtbmc.io/
    helm repo update kubevirtbmc
    helm upgrade --install "$KVBMC_RELEASE" kubevirtbmc/kubevirtbmc \
        --version "$OSAC_DEV_BMH_KUBEVIRTBMC_VERSION" \
        --namespace "$KVBMC_NAMESPACE" --create-namespace
else
    info "KubeVirtBMC release $KVBMC_RELEASE already installed"
fi
oc wait --for=condition=Available "deployment/$KVBMC_CONTROLLER_DEPLOYMENT" \
    -n "$KVBMC_NAMESPACE" --timeout=300s

# --- DeclarativeHotplugVolumes feature gate ----------------------------------
# KubeVirtBMC's Redfish virtual media attaches ISO images as hotpluggable
# DataVolumes; the bare CD-ROM disk this requires is rejected by virt-api
# unless the DeclarativeHotplugVolumes feature gate is enabled. On CNV the
# supported path is the HyperConverged CR's featureGates list.
kubevirt_feature_gates() {
    oc get kubevirt "$KUBEVIRT_CR" -n "$CNV_NAMESPACE" \
        -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || true
}

if ! grep -q DeclarativeHotplugVolumes <<<"$(kubevirt_feature_gates)"; then
    info "enabling the declarativeHotplugVolumes feature gate (cluster-wide CNV change)"
    oc patch hyperconverged "$HYPERCONVERGED" -n "$CNV_NAMESPACE" --type merge \
        -p '{"spec":{"featureGates":[{"name":"declarativeHotplugVolumes","state":"Enabled"}]}}'
    gate_attempts=30
    for ((attempt = 1; attempt <= gate_attempts; attempt++)); do
        grep -q DeclarativeHotplugVolumes <<<"$(kubevirt_feature_gates)" && break
        if ((attempt == gate_attempts)); then
            fail "the DeclarativeHotplugVolumes feature gate did not appear in the kubevirt CR"
        fi
        sleep 5
    done
    oc rollout status deployment/virt-api -n "$CNV_NAMESPACE" --timeout=600s
    oc rollout status deployment/virt-controller -n "$CNV_NAMESPACE" --timeout=600s
else
    info "DeclarativeHotplugVolumes feature gate already enabled"
fi

# --- node bridge --------------------------------------------------------------
# Ironic (hostNetwork in openshift-machine-api) must reach the IPA agent
# inside each VM, and masquerade networking cannot receive inbound
# connections. Bridge the hosts onto the node's secondary lab NIC instead:
# the VM interfaces bind to a cnv-bridge NAD on NODE_BRIDGE, the lab
# network's DHCP server serves the VMs, and the metal3 pod reaches them on
# the same L2.
#
# The bridge is created through NetworkManager whenever NM manages the NIC
# (RHCOS and most RHEL-family hosts, remote or local): NM owns the bridge
# and its slave profile, so DHCP renewals and connection re-activations
# happen on the bridge and can never pull the NIC out of it. A raw
# `ip link set master` enslavement is reverted by the next NM renewal,
# which re-asserts the NIC's standalone profile, strands the VMs on an
# uplink-less bridge, and duplicates the address on both interfaces. When
# NM does not manage the NIC, the manual enslavement is used instead
# (nothing re-asserts a profile behind its back). Both paths preserve the
# NIC's IPv4 identity on the bridge and any VM tap ports already attached
# to it, and the NM profiles persist across node reboots. Everything runs
# inside `oc debug node`, so it works identically for remote-host and
# local-host deployments.
NODE_BRIDGE_IP=
ensure_node_bridge() {
    local node out script_b64
    node=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
    [[ -n "$node" ]] || fail "could not determine the cluster node"
    info "ensuring node bridge $NODE_BRIDGE over $OSAC_DEV_BMH_NODE_NIC (node $node)"
    # oc debug does not forward local stdin into the debug pod, so the
    # setup script travels base64-encoded inside the command line. The
    # script is idempotent and short-circuits when the bridge is already
    # healthy, so re-running it (e.g. between host-creation attempts) is
    # free and never flaps a working bridge.
    script_b64=$(base64 -w0 "$node_script_dir/ensure-bmh-bridge.sh")
    out=$(oc debug "node/$node" -- chroot /host bash -c \
        "printf %s '$script_b64' | base64 -d | bash -s -- '$OSAC_DEV_BMH_NODE_NIC' '$NODE_BRIDGE'" 2>&1) \
        || {
            printf '%s\n' "$out" >&2
            fail "failed to ensure the node bridge $NODE_BRIDGE over $OSAC_DEV_BMH_NODE_NIC on $node; see node diagnostics above"
        }
    printf '%s\n' "$out" >&2
    NODE_BRIDGE_IP=$(sed -n 's/^BRIDGE_IPV4=//p' <<<"$out" | head -1)
    [[ -n "$NODE_BRIDGE_IP" ]] || \
        fail "could not determine the IPv4 address of $NODE_BRIDGE on node $node"
}

ensure_node_bridge

# --- Provisioning CR: advertise the bridge address ----------------------------
# The CBO bakes IRONIC_BASE_URL (and with it the api_url in every inspection
# ISO) from the Provisioning CR's provisioningIP/externalIPs. make
# osac-dev-deploy preserves the addresses configured here. This tool
# advertises the bridge IP -- the VMs share that L2 with
# the hostNetwork metal3 pod -- before any host inspects.
ensure_provisioning_cr() {
    local prov_ip prov_external
    prov_ip=$(oc get provisioning "$PROVISIONING_CR" -n "$MACHINE_API_NAMESPACE" \
        -o jsonpath='{.spec.provisioningIP}' 2>/dev/null) || prov_ip=
    prov_external=$(oc get provisioning "$PROVISIONING_CR" -n "$MACHINE_API_NAMESPACE" \
        -o jsonpath='{.spec.externalIPs[*]}' 2>/dev/null) || prov_external=
    if [[ "$prov_ip" != "$NODE_BRIDGE_IP" || " $prov_external " != *" $NODE_BRIDGE_IP "* ]]; then
        info "patching the Provisioning CR to advertise the bridge address $NODE_BRIDGE_IP (was: provisioningIP=${prov_ip:-unset} externalIPs=[${prov_external}])"
        oc patch provisioning "$PROVISIONING_CR" -n "$MACHINE_API_NAMESPACE" --type merge \
            -p "{\"spec\":{\"provisioningIP\":\"$NODE_BRIDGE_IP\",\"externalIPs\":[\"$NODE_BRIDGE_IP\"]}}"
    else
        info "Provisioning CR already advertises $NODE_BRIDGE_IP"
    fi
}

ensure_provisioning_cr

# --- Ironic API health (through the CBO ironic-proxy) -------------------------
# IRONIC_BASE_URL points the IPA agents at https://<provisioningIP>:6385,
# which the CBO fronts with its ironic-proxy DaemonSet (TLS, pinned to the
# metal3-ironic-tls secret). Two failure modes make every request through
# that port answer HTTP 500 while 6388 keeps working:
#   - the proxy holds the CA it loaded at its own start, so a secret
#     rotation leaves it distrusting the current metal3 certificate, and
#   - when the CBO rotates the secret AFTER a metal3 (re)start, metal3
#     serves a self-generated certificate instead of the secret's.
# Both are healed by restarting the proxy (and, for the second case,
# metal3 first); verify the endpoint instead of assuming it works.
ironic_api_code() {
    local pod out
    pod=$(oc get pods -n "$MACHINE_API_NAMESPACE" \
        -l baremetal.openshift.io/cluster-baremetal-operator=metal3-state \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || pod=
    if [[ -z "$pod" ]]; then
        printf '000\n'
        return
    fi
    out=$(oc exec -n "$MACHINE_API_NAMESPACE" "$pod" -c metal3-ironic -- \
        curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://$1:6385/" 2>/dev/null) || out=
    printf '%s\n' "${out:-000}"
}

ensure_ironic_api() {
    local ip=$1 code attempt
    info "verifying the Ironic API at https://$ip:6385 (CBO ironic-proxy front end)"
    code=$(ironic_api_code "$ip")
    case "$code" in
        200|401|403) info "Ironic API is healthy (HTTP $code)"; return 0 ;;
    esac
    info "Ironic API is unhealthy (HTTP $code); waiting for an in-flight metal3 rollout, then healing the ironic-proxy"
    oc rollout status deployment/metal3 -n "$MACHINE_API_NAMESPACE" --timeout=600s
    for ((attempt = 1; attempt <= 4; attempt++)); do
        info "restarting the ironic-proxy DaemonSet (heal attempt $attempt/4)"
        oc rollout restart daemonset/ironic-proxy -n "$MACHINE_API_NAMESPACE"
        oc rollout status daemonset/ironic-proxy -n "$MACHINE_API_NAMESPACE" --timeout=300s
        if ((attempt >= 2)); then
            # Restarting metal3 makes it serve the current TLS secret's
            # certificate again after a secret rotation raced its start.
            info "restarting metal3 so it serves the current TLS secret"
            oc rollout restart deployment/metal3 -n "$MACHINE_API_NAMESPACE"
            oc rollout status deployment/metal3 -n "$MACHINE_API_NAMESPACE" --timeout=600s
            oc rollout restart daemonset/ironic-proxy -n "$MACHINE_API_NAMESPACE"
            oc rollout status daemonset/ironic-proxy -n "$MACHINE_API_NAMESPACE" --timeout=300s
        fi
        sleep 15
        code=$(ironic_api_code "$ip")
        case "$code" in
            200|401|403) info "Ironic API is healthy (HTTP $code)"; return 0 ;;
        esac
        info "Ironic API still unhealthy (HTTP $code)"
    done
    fail "the Ironic API at https://$ip:6385 did not become healthy; check 'oc logs -n $MACHINE_API_NAMESPACE daemonset/ironic-proxy' and the metal3 deployment"
}

ensure_ironic_api "$NODE_BRIDGE_IP"

# Render completely before starting oc: a missing value must not apply a
# partial manifest. Only explicit arguments are substituted, never shell code
# or arbitrary environment variables.
apply_resource_template() {
    local template=$1 rendered
    shift
    rendered=$(python3 "$tool_dir/osac-dev-render-template.py" "$template_dir/$template.yaml.tmpl" \
        "namespace=$OSAC_DEV_BMH_NAMESPACE" "bridge=$NODE_BRIDGE" \
        "cpu=$OSAC_DEV_BMH_CPU" "memory=$OSAC_DEV_BMH_MEMORY" \
        "disk=$OSAC_DEV_BMH_DISK" "storage_class=$OSAC_DEV_BMH_STORAGE_CLASS" "$@") || \
        fail "could not render BMH template $template"
    printf '%s\n' "$rendered" | oc apply -f -
}

# --- namespace ---------------------------------------------------------------
info "ensuring namespace $OSAC_DEV_BMH_NAMESPACE"
apply_resource_template namespace

# --- host network NAD ---------------------------------------------------------
# cniVersion is required by the multus thin CNI conversion on OpenShift
# (without it every sandbox creation fails with "cannot convert: no valid
# IP addresses"); no ipam is intended: the VMs DHCP from the lab network.
info "ensuring host network attachment $NODE_BRIDGE-nad"
apply_resource_template network-attachment

# --- per-host helpers ---------------------------------------------------------

apply_bmc_secret() {
    local name=$1
    apply_resource_template bmc-secret "name=$name"
}

wait_vmbmc_ready() {
    local name=$1
    info "waiting for the VirtualMachineBMC of $name to become Ready"
    # KubeVirtBMC v0.11 reports ServiceReady/VirtualMachineAvailable/SecretAvailable
    # conditions (no aggregate Ready condition; the upstream docs' --for=condition=Ready
    # is stale).
    if ! oc wait --for=condition=ServiceReady virtualmachinebmc "$name" \
            -n "$OSAC_DEV_BMH_NAMESPACE" --timeout=180s; then
        fail "VirtualMachineBMC $name did not become Ready; check 'oc get pods -n $OSAC_DEV_BMH_NAMESPACE -l kubevirt.io/virtualmachinebmc-name=$name' and the $KVBMC_RELEASE controller logs"
    fi
    oc get svc "${name}-virtbmc" -n "$OSAC_DEV_BMH_NAMESPACE"
}

# Remove the virtual-media volume KubeVirtBMC patched into the VM template
# on InsertMedia (a volume named after the bare cdrom disk). A leftover
# entry blocks the next InsertMedia and keeps a deleted DataVolume
# referenced, so re-runs after aborted inspections must strip it.
strip_cdrom_volume() {
    local name=$1 idx
    idx=$(oc get vm "$name" -n "$OSAC_DEV_BMH_NAMESPACE" \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null \
        | awk '$0 == "cdrom" {print NR - 1; exit}') || idx=
    [[ -n "$idx" ]] || return 0
    info "  removing the leftover virtual-media volume from VM $name"
    oc patch vm "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --type json \
        -p "[{\"op\":\"remove\",\"path\":\"/spec/template/spec/volumes/$idx\"}]"
}

# Clear everything an aborted inspection cycle leaves behind so a fresh
# BareMetalHost starts from a clean slate:
#   - the VM is halted (inspection boots reliably only from a halted VM:
#     while it runs, KubeVirtBMC's one-shot boot override is consumed by
#     the boot-order restore before the reboot lands),
#   - leftover virtual media is stripped (see strip_cdrom_volume), and the
#     DataVolume named after the VM is deleted, and
#   - the BMC credentials Secret is rotated, which makes the KubeVirtBMC
#     controller restart the virtbmc pod: the Redfish Inserted/Image state
#     lives only in that pod's memory, and a stale "inserted" flag makes
#     every Ironic eject fail with HTTP 500 ("no media inserted") until
#     inspection errors out with "No suitable virtual media device found".
reset_host_for_reuse() {
    local name=$1
    info "resetting stale state for $name (halt VM, drop virtual media, restart the Redfish endpoint)"
    oc patch vm "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --type merge \
        -p '{"spec":{"runStrategy":"Halted"}}'
    strip_cdrom_volume "$name"
    oc delete --ignore-not-found datavolume "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=600s
    oc delete --ignore-not-found secret "${name}-bmc" -n "$OSAC_DEV_BMH_NAMESPACE"
    apply_bmc_secret "$name"
    wait_vmbmc_ready "$name"
}

apply_bmh() {
    local name=$1 mac=$2
    info "creating BareMetalHost $name"
    apply_resource_template baremetalhost "name=$name" "mac=$mac"
}

# Never delete a host a consumer (a provisioned BareMetalInstance) holds.
bmh_protected() {
    local name=$1 consumer state
    consumer=$(oc get bmh "$name" -n "$OSAC_DEV_BMH_NAMESPACE" \
        -o jsonpath='{.spec.consumerRef.name}' 2>/dev/null) || consumer=
    [[ -z "$consumer" ]] || return 0
    state=$(bmh_state "$name")
    case "$state" in
        provisioned|provisioning|deprovisioning|'externally provisioned') return 0 ;;
    esac
    return 1
}

# --- virtual hosts -----------------------------------------------------------
# Per host: root-disk PVC, BMC credentials Secret (shared by the
# VirtualMachineBMC and the BareMetalHost), the VirtualMachine, and its
# VirtualMachineBMC. The VM carries a bare sata CD-ROM disk (no volume) that
# KubeVirtBMC attaches the virtual-media DataVolume to on Redfish InsertMedia.
declare -A VMBMC_EXISTED=()
for ((i = 1; i <= OSAC_DEV_BMH_COUNT; i++)); do
    mac=$(host_mac "$i")
    name="${OSAC_DEV_BMH_PREFIX}-${i}"
    if oc get virtualmachinebmc "$name" -n "$OSAC_DEV_BMH_NAMESPACE" -o name &>/dev/null; then
        VMBMC_EXISTED[$name]=1
    fi
    info "creating virtual host $name (MAC $mac)"
    apply_resource_template virtual-host "name=$name" "mac=$mac"
    wait_vmbmc_ready "$name"
done

# --- BareMetalHosts ----------------------------------------------------------
for ((i = 1; i <= OSAC_DEV_BMH_COUNT; i++)); do
    mac=$(host_mac "$i")
    name="${OSAC_DEV_BMH_PREFIX}-${i}"
    state=$(bmh_state "$name")
    if [[ -n "$state" ]]; then
        case "$state" in
            available|provisioned|provisioning|deprovisioning|'externally provisioned'|registering|inspecting|preparing)
                info "BareMetalHost $name already exists in state $state; leaving it in place"
                ;;
            *)
                if bmh_protected "$name"; then
                    fail "BareMetalHost $name is in state $state but held by a consumer; refusing to delete it -- deprovision its instance or run 'make osac-dev-bmh-clean' first"
                fi
                info "BareMetalHost $name is in state $state; deleting and resetting it before re-creation"
                oc delete bmh "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=600s
                reset_host_for_reuse "$name"
                ;;
        esac
    elif [[ -n "${VMBMC_EXISTED[$name]:-}" ]]; then
        # No BareMetalHost, but the host stack exists from an earlier run:
        # clear whatever media and Redfish state its deleted BMH left behind.
        info "no BareMetalHost $name, but the virtual host exists; resetting stale state"
        reset_host_for_reuse "$name"
    fi
    apply_bmh "$name" "$mac"
done

# --- wait for the hosts to become available -----------------------------------
# States: registering -> inspecting -> preparing -> available. A healthy
# inspection completes in a few minutes (the first one imports the ramdisk
# ISO into a DataVolume). Hosts that are not available within
# OSAC_DEV_BMH_TIMEOUT_MIN minutes -- or that enter the error state -- never
# recover on their own (Ironic retry backoff is long, and a ramdisk that
# never boots just cycles BMO's inspection timeout), so they are deleted,
# reset, and re-created up to OSAC_DEV_BMH_ATTEMPTS times in total.
attempt=1
while :; do
    failed=()
    for ((i = 1; i <= OSAC_DEV_BMH_COUNT; i++)); do
        name="${OSAC_DEV_BMH_PREFIX}-${i}"
        info "waiting for $name to become available (attempt ${attempt}/${OSAC_DEV_BMH_ATTEMPTS}; registering -> inspecting -> preparing -> available)"
        state=
        last_printed=
        ok=0
        for ((poll = 1; poll <= BMH_RETRIES; poll++)); do
            state=$(bmh_state "$name")
            case "$state" in
                available)
                    info "  $name is available"
                    ok=1
                    break
                    ;;
                provisioned|'externally provisioned')
                    info "  $name is $state (held by a consumer); treating it as ready"
                    ok=1
                    break
                    ;;
                error)
                    info "  $name entered the error state"
                    break
                    ;;
            esac
            if [[ -n "$state" && "$state" != "$last_printed" ]]; then
                info "  $name: ${state} (poll ${poll}/${BMH_RETRIES})"
                last_printed=$state
            fi
            sleep "$BMH_POLL_INTERVAL"
        done
        ((ok)) || failed+=("$name")
    done
    (( ${#failed[@]} == 0 )) && break
    if ((attempt >= OSAC_DEV_BMH_ATTEMPTS)); then
        for name in "${failed[@]}"; do
            error_message=$(oc get bmh "$name" -n "$OSAC_DEV_BMH_NAMESPACE" \
                -o jsonpath='{.status.errorMessage}' 2>/dev/null) || error_message=
            last_state=$(bmh_state "$name")
            printf 'ERROR: BareMetalHost %s did not reach the available state within %s minutes across %s attempts (last state: %s)\n' \
                "$name" "$OSAC_DEV_BMH_TIMEOUT_MIN" "$OSAC_DEV_BMH_ATTEMPTS" "${last_state:-unknown}" >&2
            [[ -z "$error_message" ]] || printf 'ERROR: %s: %s\n' "$name" "$error_message" >&2
            oc get bmh "$name" -n "$OSAC_DEV_BMH_NAMESPACE" -o yaml >&2 || true
        done
        fail "see the dumped BareMetalHost statuses above; also check the metal3 logs in $MACHINE_API_NAMESPACE and the ${OSAC_DEV_BMH_PREFIX}-N-virtbmc pods"
    fi
    info "hosts not available after attempt $attempt: ${failed[*]}; deleting and re-creating them (a stuck inspection does not recover on its own)"
    # The node environment can drift under a long polling loop exactly like
    # it can between runs (the observed case: a NetworkManager DHCP renewal
    # re-asserted the bridged NIC's standalone profile mid-run, and every
    # subsequent inspection booted a ramdisk that could never reach DHCP or
    # the Ironic API). Re-ensure the bridge, the Provisioning CR, and the
    # Ironic API before spending another attempt on re-created hosts.
    ensure_node_bridge
    ensure_provisioning_cr
    ensure_ironic_api "$NODE_BRIDGE_IP"
    for name in "${failed[@]}"; do
        if bmh_protected "$name"; then
            fail "BareMetalHost $name is held by a consumer; refusing to delete it -- deprovision its instance or run 'make osac-dev-bmh-clean' first"
        fi
        oc delete bmh "$name" -n "$OSAC_DEV_BMH_NAMESPACE" --wait --timeout=600s
        reset_host_for_reuse "$name"
    done
    for ((i = 1; i <= OSAC_DEV_BMH_COUNT; i++)); do
        name="${OSAC_DEV_BMH_PREFIX}-${i}"
        # shellcheck disable=SC2076
        if [[ " ${failed[*]} " == *" $name "* ]]; then
            apply_bmh "$name" "$(host_mac "$i")"
        fi
    done
    ((attempt++))
done

# --- summary -------------------------------------------------------------------
info "virtual BMHs are ready for BMaaS in namespace $OSAC_DEV_BMH_NAMESPACE"
oc get bmh -n "$OSAC_DEV_BMH_NAMESPACE"
info "hosts are labeled osac.openshift.io/host-type=default; the interface-macs annotation exposes fabric port data-0 per host"
