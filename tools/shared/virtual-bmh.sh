#!/usr/bin/env bash
# shellcheck shell=bash
#
# virtual-bmh.sh — stand up virtual BareMetalHosts for BMaaS/CaaS work.
#
# Creates libvirt VMs on the cluster-tool network, runs sushy-tools as a Redfish
# BMC emulator, and creates BareMetalHost resources that Ironic inspects and
# provisions exactly as it would physical hardware.
#
# This is the shared implementation: it runs on the machine that hosts the
# libvirt VMs (the CI runner host, a lab host reached over SSH), needs no OSAC
# checkout, and takes its configuration from the environment only. Callers
# (CI job, dev-env wrapper) own transport, credentials, and escalation.
#
# Re-runnable: the Ironic activation, the storage pool, the emulator, the VMs,
# and the BMH resources are each created only when missing, so a second run is a
# no-op apart from re-applying the BMH manifests. Existing VMs are adopted as
# they are — their pool directory, disk, and MAC are read back instead of
# recomputed — so a run that follows a CI or manual setup keeps pointing Ironic
# at the hardware that actually exists.
#
# Names match what the CI teardown script derives, so cleanup stays unchanged:
#   pool       bmh-<clone>                  VMs   virtual-bmh-<clone>-<n>
#   disks      pool bmh-<clone> target (default /tmp/virtual-bmh-disks-<clone>)
#   emulator   ~/sushy-<clone>/             vmedia cache ~/sushy-vmedia-tmp-<clone>
#
# Required environment:
#   CLONE_NAME     cluster-tool clone name; selects the libvirt network
#   KUBECONFIG     kubeconfig of the cluster Ironic runs in
#
# Optional environment:
#   BMH_NAMESPACE   namespace for BMH resources        (host-inventory)
#   BMH_COUNT       number of virtual hosts            (2)
#   BMH_DISK_SIZE   qcow2 size for new disks           (150G)
#   BMH_LABELS      space-separated labels for the BMHs (osac.openshift.io/host-type=default)
#   BMC_USERNAME / BMC_PASSWORD                        (admin / password)
#   SUSHY_PORT      sushy-tools listen port            (8000)
#   KUBECTL         kubectl/oc binary                  (oc)
#   VIRSH_URI       libvirt connection                 (qemu:///system)
#   OVMF_CODE / OVMF_VARS_TEMPLATE                     (/usr/share/OVMF/*)
#   PIP_PACKAGES    installed when sushy-emulator is missing (sushy-tools libvirt-python)
#   INSPECT_RETRIES / INSPECT_DELAY  inspection wait budget (120 x 10s)
#
# Usage: virtual-bmh.sh [--help]
set -euo pipefail

CLONE_NAME="${CLONE_NAME:-}"
KUBECONFIG="${KUBECONFIG:-}"

BMH_NAMESPACE="${BMH_NAMESPACE:-host-inventory}"
BMH_COUNT="${BMH_COUNT:-2}"
BMH_DISK_SIZE="${BMH_DISK_SIZE:-150G}"
BMH_LABELS="${BMH_LABELS:-osac.openshift.io/host-type=default}"
BMC_USERNAME="${BMC_USERNAME:-admin}"
BMC_PASSWORD="${BMC_PASSWORD:-password}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
KUBECTL="${KUBECTL:-oc}"
VIRSH_URI="${VIRSH_URI:-qemu:///system}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.secboot.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/OVMF/OVMF_VARS.fd}"
PIP_PACKAGES="${PIP_PACKAGES:-sushy-tools libvirt-python}"
MAC_PREFIX="${MAC_PREFIX:-52:54:00:bb:cc}"
SUSHY_ATTEMPTS="${SUSHY_ATTEMPTS:-3}"
INSPECT_RETRIES="${INSPECT_RETRIES:-120}"
INSPECT_DELAY="${INSPECT_DELAY:-10}"

SUSHY_CONFIG_DIR="${HOME}/sushy-${CLONE_NAME}"
SUSHY_CONF="${SUSHY_CONFIG_DIR}/sushy-emulator.conf"
SUSHY_LOG="${SUSHY_CONFIG_DIR}/sushy.log"
SUSHY_PID_FILE="${SUSHY_CONFIG_DIR}/sushy.pid"
SUSHY_VMEDIA_TMP="${HOME}/sushy-vmedia-tmp-${CLONE_NAME}"
CT_NETWORK="test-infra-net-${CLONE_NAME}"
VM_DISK_DIR="/tmp/virtual-bmh-disks-${CLONE_NAME}"
POOL_NAME="bmh-${CLONE_NAME}"
VM_NAME_PREFIX="virtual-bmh-${CLONE_NAME}"
METAL3_SELECTOR="baremetal.openshift.io/cluster-baremetal-operator=metal3-state"
METAL3_NAMESPACE="openshift-machine-api"
WEBHOOK_SVC="baremetal-operator-webhook-service"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

virsh() { command virsh -c "${VIRSH_URI}" "$@"; }
kube() { "${KUBECTL}" "$@"; }

vm_name() { printf '%s-%s' "${VM_NAME_PREFIX}" "$1"; }
vm_mac() { printf '%s:%02x' "${MAC_PREFIX}" "$1"; }

# MAC of an existing VM, else the one a new VM would get.
vm_mac_of() {
	local name=$1 index=$2 mac
	mac=$(virsh dumpxml "${name}" --inactive 2>/dev/null |
		awk -F"'" '/<mac address=/ && !found { found = 1; print $2 }')
	if [ -n "${mac}" ]; then
		printf '%s\n' "${mac}"
	else
		vm_mac "${index}"
	fi
}

# "150G" -> bytes, so an existing disk can be compared with BMH_DISK_SIZE.
size_to_bytes() {
	python3 - "$1" <<'PY'
import sys
value = sys.argv[1].strip()
units = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}
number, unit = value, ""
if value and not value[-1].isdigit():
    number, unit = value[:-1], value[-1].upper()
print(int(float(number) * units[unit]))
PY
}

# An existing disk that is smaller than BMH_DISK_SIZE is left alone: resizing
# under a defined VM hides state that a later Assisted install would trip over.
warn_if_disk_too_small() {
	local disk=$1 name=$2 current requested
	[ -n "${disk}" ] && [ -f "${disk}" ] || return 0
	current=$(qemu-img info --force-share --output=json "${disk}" 2>/dev/null |
		python3 -c 'import json, sys

try:
    print(json.load(sys.stdin)["virtual-size"])
except Exception:
    raise SystemExit(1)' 2>/dev/null) || return 0
	requested=$(size_to_bytes "${BMH_DISK_SIZE}" 2>/dev/null) || return 0
	if [ "${current}" -lt "${requested}" ]; then
		warn "${name} already has a $((current / 1024 / 1024 / 1024))G disk, smaller than BMH_DISK_SIZE=${BMH_DISK_SIZE}; keeping it"
		warn "  to recreate it: virsh -c ${VIRSH_URI} destroy ${name} && virsh -c ${VIRSH_URI} undefine ${name}, then remove ${disk} and re-run"
	fi
}

usage() {
	cat <<'EOF'
Usage: virtual-bmh.sh

Create virtual BareMetalHosts backed by libvirt VMs and sushy-tools, then let
Ironic inspect them until they are available. Configuration is environment-only
(see the header of this script); the run is idempotent.

Requires virsh, qemu-img, curl, python3, and oc/kubectl on this host, plus the
metal3.io Provisioning API on the target cluster.
EOF
}

require_tools() {
	local tool missing=""
	[ -n "${CLONE_NAME}" ] || die "CLONE_NAME is required (cluster-tool clone name)"
	[ -n "${KUBECONFIG}" ] || die "KUBECONFIG is required"
	for tool in virsh qemu-img curl python3 "${KUBECTL}"; do
		command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
	done
	[ -z "${missing}" ] || die "missing required tools:${missing}"
	[ -f "${OVMF_CODE}" ] || die "OVMF firmware ${OVMF_CODE} not found (set OVMF_CODE)"
	[ -f "${OVMF_VARS_TEMPLATE}" ] || die "OVMF vars ${OVMF_VARS_TEMPLATE} not found (set OVMF_VARS_TEMPLATE)"
}

# Ironic is managed by the cluster's baremetal operator and only runs once a
# Provisioning resource exists; without it there are no BMH webhooks to talk to.
activate_ironic() {
	if kube get provisioning provisioning-configuration >/dev/null 2>&1; then
		log "Provisioning/provisioning-configuration already present"
	else
		log "activating Ironic (creating Provisioning/provisioning-configuration)"
		# Created only when absent: an existing Provisioning may be tuned by
		# whoever owns the cluster, and re-applying would overwrite that.
		kube apply -f - <<'EOF'
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  watchAllNamespaces: true
EOF
	fi
	if [ -z "$(kube get pods -n "${METAL3_NAMESPACE}" -l "${METAL3_SELECTOR}" -o name 2>/dev/null)" ]; then
		log "waiting for metal3 pods to appear"
		kube wait --for=create pods -l "${METAL3_SELECTOR}" \
			-n "${METAL3_NAMESPACE}" --timeout=300s
	fi
	log "waiting for metal3 pods to be ready"
	kube wait --for=condition=Ready pods -l "${METAL3_SELECTOR}" \
		-n "${METAL3_NAMESPACE}" --timeout=600s
}

network_gateway_ip() {
	virsh net-info "${CT_NETWORK}" >/dev/null 2>&1 || {
		printf 'error: libvirt network %s not found; available networks:\n' \
			"${CT_NETWORK}" >&2
		virsh net-list --all >&2
		exit 1
	}
	virsh net-dumpxml "${CT_NETWORK}" | python3 -c '
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.stdin).getroot().find(".//ip").get("address"))
'
}

ensure_pool() {
	local state target
	if state=$(virsh pool-info "${POOL_NAME}" 2>/dev/null); then
		case "${state}" in
		*running*) log "storage pool ${POOL_NAME} already running" ;;
		*)
			log "starting storage pool ${POOL_NAME}"
			virsh pool-start "${POOL_NAME}" >/dev/null
			;;
		esac
		# Reuse the directory a previous (CI or manual) run chose, otherwise our
		# disk paths would not match the existing VMs.
		target=$(virsh pool-dumpxml "${POOL_NAME}" |
			awk -F'[<>]' '/<path>/ && !found { found = 1; print $3 }')
		if [ -n "${target}" ] && [ "${target}" != "${VM_DISK_DIR}" ]; then
			log "adopting pool path ${target}"
			VM_DISK_DIR=${target}
		fi
	else
		log "defining storage pool ${POOL_NAME} -> ${VM_DISK_DIR}"
		virsh pool-define-as "${POOL_NAME}" dir --target "${VM_DISK_DIR}" >/dev/null
		virsh pool-start "${POOL_NAME}" >/dev/null
	fi
	mkdir -p "${VM_DISK_DIR}"
	# sushy-tools runs as qemu and has to write images into the pool.
	chmod 777 "${VM_DISK_DIR}"
}

sushy_responds() {
	curl -sf --connect-timeout 3 --max-time 5 \
		"http://${1}:${SUSHY_PORT}/redfish/v1/" >/dev/null 2>&1
}

# PID listening on the emulator address, empty when nothing is bound there.
port_listener_pid() {
	ss -ltnp 2>/dev/null |
		awk -v addr="${GW_IP}:${SUSHY_PORT}" '$4 == addr { print; exit }' |
		grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2
}

# Clone that owns a sushy-emulator process, taken from its --config path.
emulator_clone() {
	local cmdline
	cmdline=$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null) || return 0
	printf '%s\n' "${cmdline}" |
		sed -n 's|.*sushy-\([^/ ]*\)/sushy-emulator.conf.*|\1|p'
}

# The process our pid file points at, when it is still alive.
our_emulator_pid() {
	local pid
	[ -f "${SUSHY_PID_FILE}" ] || return 0
	pid=$(cat "${SUSHY_PID_FILE}" 2>/dev/null) || return 0
	[ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && printf '%s\n' "${pid}"
}

write_sushy_config() {
	mkdir -p "${SUSHY_CONFIG_DIR}"
	cat >"${SUSHY_CONF}" <<EOF
SUSHY_EMULATOR_LISTEN_IP = "${GW_IP}"
SUSHY_EMULATOR_LISTEN_PORT = ${SUSHY_PORT}
SUSHY_EMULATOR_SSL_CERT = None
SUSHY_EMULATOR_SSL_KEY = None
SUSHY_EMULATOR_LIBVIRT_URI = "${VIRSH_URI}"
SUSHY_EMULATOR_IGNORE_BOOT_DEVICE = False
SUSHY_EMULATOR_STORAGE_POOL = "${POOL_NAME}"
SUSHY_EMULATOR_BOOT_LOADER_MAP = {
    "UEFI": {
        "x86_64": "${OVMF_CODE}"
    },
    "Legacy": {
        "x86_64": None
    }
}
EOF
}

# sushy-tools caches each virtual-media boot ISO through plain
# tempfile.mkdtemp()/NamedTemporaryFile() calls, which resolve through
# tempfile.gettempdir() and therefore honour TMPDIR. Pointing TMPDIR at a
# directory named for this clone keeps that cache removable by name.
start_sushy() {
	local pip_packages attempt settled pid
	read -r -a pip_packages <<<"${PIP_PACKAGES}"
	if ! command -v sushy-emulator >/dev/null 2>&1; then
		log "installing sushy-tools (${PIP_PACKAGES})"
		python3 -m pip install --quiet "${pip_packages[@]}"
	fi
	mkdir -p "${SUSHY_VMEDIA_TMP}"
	for attempt in $(seq 1 "${SUSHY_ATTEMPTS}"); do
		log "starting sushy-emulator on ${GW_IP}:${SUSHY_PORT} (attempt ${attempt}/${SUSHY_ATTEMPTS})"
		TMPDIR="${SUSHY_VMEDIA_TMP}" SUSHY_VMEDIA_TMP="${SUSHY_VMEDIA_TMP}" \
			nohup sushy-emulator --config "${SUSHY_CONF}" \
			>"${SUSHY_LOG}" 2>&1 &
		pid=$!
		printf '%s\n' "${pid}" >"${SUSHY_PID_FILE}"
		settled=false
		for _ in $(seq 1 15); do
			if sushy_responds "${GW_IP}" && [ "$(port_listener_pid)" = "${pid}" ]; then
				settled=true
				break
			fi
			kill -0 "${pid}" 2>/dev/null || break
			sleep 2
		done
		if [ "${settled}" = "true" ]; then
			log "sushy-emulator running (pid ${pid})"
			return 0
		fi
		kill "${pid}" 2>/dev/null || true
		for _ in $(seq 1 10); do
			kill -0 "${pid}" 2>/dev/null || break
			sleep 1
		done
		kill -9 "${pid}" 2>/dev/null || true
	done
	cat "${SUSHY_LOG}" >&2 || true
	die "sushy-emulator did not come up after ${SUSHY_ATTEMPTS} attempts (log: ${SUSHY_LOG})"
}

# sushy-tools enumerates every libvirt domain on the connection, so an emulator
# started for another clone answers on the same Redfish URL. It is not usable:
# its storage pool belongs to a clone that may be gone, and InsertMedia then
# fails with a 500 that leaves the BMH stuck in 'inspecting'. Only a listener
# that is our own pid counts as ours.
ensure_sushy() {
	local listener owner ours
	write_sushy_config
	listener=$(port_listener_pid)
	ours=$(our_emulator_pid)
	if [ -n "${listener}" ] && [ "${listener}" = "${ours}" ]; then
		log "sushy-tools already serving ${GW_IP}:${SUSHY_PORT} (pid ${listener})"
		return 0
	fi
	if [ -n "${listener}" ]; then
		owner=$(emulator_clone "${listener}")
		if [ -n "${owner}" ] && [ "${owner}" != "${CLONE_NAME}" ] &&
			! virsh net-info "test-infra-net-${owner}" >/dev/null 2>&1; then
			log "stopping stale sushy-emulator for clone ${owner} (pid ${listener}, network gone)"
			kill "${listener}" 2>/dev/null || true
			sleep 3
			kill -9 "${listener}" 2>/dev/null || true
		else
			die "${GW_IP}:${SUSHY_PORT} is held by pid ${listener}${owner:+ (sushy-emulator for clone ${owner})}; stop it or use another SUSHY_PORT"
		fi
	fi
	# Our own process can outlive the configuration it was started with.
	if [ -n "${ours}" ] && [ "${ours}" != "${listener}" ]; then
		log "stopping out-of-date sushy-emulator (pid ${ours}) not on ${GW_IP}:${SUSHY_PORT}"
		kill "${ours}" 2>/dev/null || true
		sleep 2
		kill -9 "${ours}" 2>/dev/null || true
	fi
	start_sushy
}

ensure_vm() {
	local index=$1 name disk vars
	name=$(vm_name "${index}")
	if virsh dominfo "${name}" >/dev/null 2>&1; then
		if [ "$(virsh domstate "${name}" 2>/dev/null)" != "running" ]; then
			log "starting existing VM ${name}"
			virsh start "${name}" >/dev/null
		else
			log "VM ${name} already running"
		fi
		# The VM keeps the disk and MAC it was created with; a BMH must point at
		# the MAC that actually exists, not at a freshly computed one.
		warn_if_disk_too_small "$(virsh domblklist "${name}" |
			awk '$1 == "vda" { print $2; exit }')" "${name}"
		return 0
	fi
	disk="${VM_DISK_DIR}/${name}.qcow2"
	vars="${VM_DISK_DIR}/${name}-VARS.fd"
	if [ ! -f "${disk}" ]; then
		log "creating ${BMH_DISK_SIZE} disk for ${name}"
		qemu-img create -f qcow2 "${disk}" "${BMH_DISK_SIZE}" >/dev/null
	else
		warn_if_disk_too_small "${disk}" "${name}"
	fi
	[ -f "${vars}" ] || cp "${OVMF_VARS_TEMPLATE}" "${vars}"
	log "defining VM ${name} (mac $(vm_mac "${index}"))"
	# libvirt 10.10+ rejects firmware='efi' together with an explicit
	# <loader>/<nvram> pair; the pflash paths alone already select UEFI.
	virsh define /dev/stdin <<EOF
<domain type='kvm'>
  <name>${name}</name>
  <memory unit='MiB'>8192</memory>
  <vcpu>4</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <loader readonly='yes' type='pflash'>${OVMF_CODE}</loader>
    <nvram>${vars}</nvram>
    <boot dev='network'/>
    <boot dev='hd'/>
  </os>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${disk}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'>
      <mac address='$(vm_mac "${index}")'/>
      <source network='${CT_NETWORK}'/>
      <model type='virtio'/>
    </interface>
    <console type='pty'/>
  </devices>
  <seclabel type='none'/>
</domain>
EOF
	virsh start "${name}" >/dev/null
}

# The BMH admission webhook is served by the baremetal operator; creating a BMH
# before it has endpoints fails the apply.
wait_for_bmh_webhook() {
	local attempt endpoints
	log "waiting for ${WEBHOOK_SVC} endpoints"
	for attempt in $(seq 1 60); do
		endpoints=$(kube get endpoints "${WEBHOOK_SVC}" -n "${METAL3_NAMESPACE}" \
			-o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
		if [ -n "${endpoints}" ]; then
			log "BMH webhook ready (${endpoints})"
			return 0
		fi
		[ "${attempt}" -lt 60 ] || {
			kube get endpoints "${WEBHOOK_SVC}" -n "${METAL3_NAMESPACE}" -o yaml >&2 || true
			die "no ${WEBHOOK_SVC} endpoints in ${METAL3_NAMESPACE} after 300s"
		}
		sleep 5
	done
}

# A BMH that ended inspection in error keeps that error until it is recreated;
# BMO only retries with a growing backoff and never clears errorMessage, so a
# fixed emulator would still leave the host unusable. Recreate it when nothing
# consumes it and it is not mid-operation.
reset_failed_bmh() {
	local name info state operational consumer
	name=$1
	info=$(kube get bmh "${name}" -n "${BMH_NAMESPACE}" \
		-o jsonpath='{.status.provisioning.state}{"|"}{.status.operationalStatus}{"|"}{.spec.consumerRef.name}' \
		2>/dev/null) || return 0
	IFS='|' read -r state operational consumer <<<"${info}"
	[ "${operational}" = "error" ] || return 0
	case "${state}" in
	available | inspecting | preparing) ;;
	*) return 0 ;;
	esac
	[ -z "${consumer}" ] || return 0
	log "recreating ${name}: left in '${state}' with an error"
	kube delete bmh "${name}" -n "${BMH_NAMESPACE}" --ignore-not-found \
		--timeout=180s >/dev/null
}

ensure_bmh() {
	local index name mac uuid
	index=$1
	name=$(vm_name "${index}")
	reset_failed_bmh "${name}"
	mac=$(vm_mac_of "${name}" "${index}")
	uuid=$(virsh domuuid "${name}")
	kube apply -f - >/dev/null <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${name}-bmc-secret
  namespace: ${BMH_NAMESPACE}
type: Opaque
stringData:
  username: ${BMC_USERNAME}
  password: ${BMC_PASSWORD}
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${name}
  namespace: ${BMH_NAMESPACE}
spec:
  online: true
  bootMACAddress: "${mac}"
  bootMode: UEFI
  automatedCleaningMode: metadata
  rootDeviceHints:
    deviceName: /dev/vda
  bmc:
    address: "redfish-virtualmedia+http://${GW_IP}:${SUSHY_PORT}/redfish/v1/Systems/${uuid}"
    credentialsName: ${name}-bmc-secret
EOF
	log "BMH ${name} applied (uuid ${uuid}, mac ${mac})"
}

bmh_state() {
	kube get bmh "$1" -n "${BMH_NAMESPACE}" \
		-o jsonpath='{.status.provisioning.state}' 2>/dev/null || true
}

# Ironic's reason for the current state, so a long wait shows why.
bmh_error() {
	kube get bmh "$1" -n "${BMH_NAMESPACE}" \
		-o jsonpath='{.status.errorMessage}' 2>/dev/null || true
}

wait_for_available() {
	local name attempt state error label
	local -a labels
	name=$(vm_name "$1")
	read -r -a labels <<<"${BMH_LABELS}"
	for label in "${labels[@]}"; do
		kube label bmh "${name}" -n "${BMH_NAMESPACE}" "${label}" --overwrite >/dev/null
	done
	state=$(bmh_state "${name}")
	if [ "${state}" = "available" ]; then
		log "${name} already available"
		return 0
	fi
	log "waiting for ${name} to become available (inspection takes a few minutes)"
	for attempt in $(seq 1 "${INSPECT_RETRIES}"); do
		state=$(bmh_state "${name}")
		if [ "${state}" = "available" ]; then
			log "${name} is available"
			return 0
		fi
		if [ "${attempt}" -eq "${INSPECT_RETRIES}" ]; then
			kube get bmh "${name}" -n "${BMH_NAMESPACE}" -o yaml >&2 || true
			die "${name} did not reach available after $((INSPECT_RETRIES * INSPECT_DELAY))s (state: ${state:-unknown}${error:+, error: ${error}})"
		fi
		if [ $((attempt % 6)) -eq 0 ]; then
			error=$(bmh_error "${name}")
			log "${name}: ${state:-unknown} after $((attempt * INSPECT_DELAY))s${error:+ (${error:0:200})}"
		fi
		sleep "${INSPECT_DELAY}"
	done
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	require_tools
	kube get --raw /readyz >/dev/null 2>&1 ||
		die "cluster at ${KUBECONFIG} is not reachable"
	kube get crd provisionings.metal3.io >/dev/null 2>&1 ||
		die "metal3.io Provisioning API missing; install the BMaaS prerequisites first"

	activate_ironic

	GW_IP=$(network_gateway_ip)
	log "cluster-tool network ${CT_NETWORK} gateway ${GW_IP}"

	ensure_pool
	ensure_sushy

	log "ensuring ${BMH_COUNT} virtual BMH VMs"
	local index
	for index in $(seq 1 "${BMH_COUNT}"); do
		ensure_vm "${index}"
	done

	wait_for_bmh_webhook
	kube create namespace "${BMH_NAMESPACE}" --dry-run=client -o yaml |
		kube apply -f - >/dev/null
	for index in $(seq 1 "${BMH_COUNT}"); do
		ensure_bmh "${index}"
	done
	for index in $(seq 1 "${BMH_COUNT}"); do
		wait_for_available "${index}"
	done

	log "virtual BMH setup complete: ${BMH_COUNT} host(s) available in ${BMH_NAMESPACE}"
}

main "$@"
