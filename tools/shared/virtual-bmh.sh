#!/usr/bin/env bash
# shellcheck shell=bash
#
# virtual-bmh.sh — stand up virtual BareMetalHosts for BMaaS/CaaS work.
#
# Thin orchestrator over the osac-test-infra BMaaS tools, so the development
# environment and CI run the same code instead of two copies of it:
#
#   activate-ironic.sh          Ironic activation (Provisioning CR, metal3
#                               pods, BareMetalHost webhook)
#   setup-sushy-tools.sh        libvirt storage pool, sushy-tools Redfish
#                               emulator, nginx virtual-media cache
#   manage-virtual-bmh-vms.py   libvirt VMs; owns the raw inventory file
#   reconcile-bmhs.py           BareMetalHosts reconciled with that inventory
#
# The sequence is the one osac-test-infra's own setup-virtual-bmh.sh runs, but
# that script cannot be reused here: it creates BMH_COUNT VMs unconditionally
# (a fresh group per CI job, so a second call would double the hardware) and has
# no disk-size, label, or credential knobs. This script keeps the tools and adds
# what a development hub needs: clone-scoped names, only the missing hosts, the
# labels the osac installer profile selects hosts by, and the recreation of a
# BMH whose inspection failed (BMO never clears errorMessage, so a fixed
# emulator would leave the host unusable).
#
# It runs on the machine that hosts the libvirt VMs (the CI runner host, a lab
# host reached over SSH), needs no OSAC checkout, and takes its configuration
# from the environment only. tools/dev-env/bmh.sh is the caller: it owns the
# transport, escalation, and the osac-test-infra checkout.
#
# Re-runnable: Ironic activation, the pool, the emulator, and the BMH resources
# are each converged in place. VMs are different — the raw inventory is the
# source of truth, and only the difference between BMH_COUNT and the hosts it
# lists is created, so a second run adds nothing. A stopped VM is started, and a
# host whose domain is gone is dropped and replaced.
#
# Names: the raw inventory's group prefix is seeded with virtual-bmh-<clone>, so
# every VM of the group is virtual-bmh-<clone>-<token> and a stale VM set is
# tied to the cluster it serves. The token is the manage-virtual-bmh-vms.py
# scheme: one random hex byte that is also the last boot MAC byte. VMs created
# by the older index-named tool (virtual-bmh-<clone>-<n>) are not adopted; the
# run stops and prints the two commands that retire them.
#
# Required environment:
#   CLONE_NAME     cluster-tool clone name; selects the libvirt network
#   KUBECONFIG     kubeconfig of the cluster Ironic runs in
#   TEST_INFRA_DIR osac-test-infra checkout holding .github/scripts
#
# Optional environment:
#   BMH_NAMESPACE   namespace for BMH resources        (host-inventory)
#   BMH_COUNT       number of virtual hosts            (2)
#   BMH_DISK_SIZE   qcow2 size for new disks           (150G)
#   BMH_LABELS      space-separated labels for the BMHs
#                   (osac.openshift.io/host-type=default)
#   BMC_USERNAME / BMC_PASSWORD                        (admin / password)
#   SUSHY_PORT      sushy-tools listen port            (8000)
#   SUSHY_CACHE_PORT nginx virtual-media cache port    (8080)
#   KUBECTL         kubectl/oc binary                  (oc, not on PATH)
#   INVENTORY_FILE  raw inventory path
#                   (${HOME}/virtual-bmh-inventory-<clone>.json)
#
# Usage: virtual-bmh.sh [--help]
set -euo pipefail

CLONE_NAME="${CLONE_NAME:-}"
KUBECONFIG="${KUBECONFIG:-}"
TEST_INFRA_DIR="${TEST_INFRA_DIR:-}"

BMH_NAMESPACE="${BMH_NAMESPACE:-host-inventory}"
BMH_COUNT="${BMH_COUNT:-2}"
BMH_DISK_SIZE="${BMH_DISK_SIZE:-150G}"
BMH_LABELS="${BMH_LABELS:-osac.openshift.io/host-type=default}"
BMC_USERNAME="${BMC_USERNAME:-admin}"
BMC_PASSWORD="${BMC_PASSWORD:-password}"
SUSHY_PORT="${SUSHY_PORT:-8000}"
SUSHY_CACHE_PORT="${SUSHY_CACHE_PORT:-8080}"
KUBECTL="${KUBECTL:-oc}"

CT_NETWORK="test-infra-net-${CLONE_NAME}"
VM_DISK_DIR="/tmp/virtual-bmh-disks-${CLONE_NAME}"
POOL_NAME="bmh-${CLONE_NAME}"
SUSHY_CONFIG_DIR="${HOME}/sushy-${CLONE_NAME}"
SUSHY_CACHE_NAME="sushy-cache-${CLONE_NAME}"
SUSHY_VMEDIA_TMP="${HOME}/sushy-vmedia-tmp-${CLONE_NAME}"
INVENTORY_FILE="${INVENTORY_FILE:-${HOME}/virtual-bmh-inventory-${CLONE_NAME}.json}"
VM_NAME_PREFIX="virtual-bmh-${CLONE_NAME}"
# The osac-test-infra tools live here; every step below is one of them.
TEST_INFRA_SCRIPTS="${TEST_INFRA_DIR}/.github/scripts"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

virsh() { command virsh -c qemu:///system "$@"; }

usage() {
	cat <<'EOF'
Usage: virtual-bmh.sh

Create virtual BareMetalHosts backed by libvirt VMs and sushy-tools, then let
Ironic inspect them until they are available. Runs the osac-test-infra BMaaS
tools (activate-ironic.sh, setup-sushy-tools.sh, manage-virtual-bmh-vms.py,
reconcile-bmhs.py) from TEST_INFRA_DIR. Configuration is environment-only (see
the header of this script); the run is idempotent.

Requires virsh, qemu-img, curl, python3, podman, the Fedora OVMF firmware, and
oc on this host, plus the metal3.io Provisioning API on the target cluster.
EOF
}

require_tools() {
	local tool missing="" script firmware
	[ -n "${CLONE_NAME}" ] || die "CLONE_NAME is required (cluster-tool clone name)"
	[ -n "${KUBECONFIG}" ] || die "KUBECONFIG is required"
	[ -n "${TEST_INFRA_DIR}" ] ||
		die "TEST_INFRA_DIR is required (path to an osac-test-infra checkout)"
	for script in activate-ironic.sh setup-sushy-tools.sh manage-virtual-bmh-vms.py \
		reconcile-bmhs.py raw_inventory.py; do
		[ -f "${TEST_INFRA_SCRIPTS}/${script}" ] ||
			die "${TEST_INFRA_SCRIPTS}/${script} not found; is TEST_INFRA_DIR an osac-test-infra checkout?"
	done
	for tool in virsh qemu-img curl python3 podman "${KUBECTL}"; do
		command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
	done
	[ -z "${missing}" ] || die "missing required tools:${missing}"
	# The tools hardcode the Fedora paths (docs/bmaas-tools.md documents
	# VM_EFI_VARS for other distributions; the emulator's boot-loader map has no
	# override at all), so check them here rather than failing mid-install.
	for firmware in /usr/share/OVMF/OVMF_CODE.secboot.fd "${VM_EFI_VARS:-/usr/share/OVMF/OVMF_VARS.fd}"; do
		[ -f "${firmware}" ] || die "OVMF firmware ${firmware} not found (osac-test-infra expects the Fedora paths)"
	done
	virsh net-info "${CT_NETWORK}" >/dev/null 2>&1 || {
		warn "libvirt network ${CT_NETWORK} not found; available networks:"
		virsh net-list --all >&2
		die "the cluster-tool cluster for ${CLONE_NAME} does not exist on this host"
	}
}

# The osac-test-infra scripts call oc and pip by their plain names. Locally this
# script runs as root through sudo, whose PATH may miss a user-local oc and point
# at a python without a `pip` entry point: give both a directory to be found in
# rather than editing the shared tools.
SHIM_DIR="${TMPDIR:-/tmp}/osac-dev-bmh-bin"
prepare_tool_path() {
	local bin
	bin=$(command -v "${KUBECTL}") || die "${KUBECTL} not found"
	if ! command -v oc >/dev/null 2>&1; then
		mkdir -p "${SHIM_DIR}"
		ln -sf "${bin}" "${SHIM_DIR}/oc"
		log "using ${bin} as oc for the osac-test-infra tools"
	fi
	if ! command -v pip >/dev/null 2>&1; then
		python3 -m pip --version >/dev/null 2>&1 ||
			die "neither pip nor 'python3 -m pip' works; install pip on this host"
		mkdir -p "${SHIM_DIR}"
		printf '#!/bin/sh\nexec python3 -m pip "$@"\n' >"${SHIM_DIR}/pip"
		chmod +x "${SHIM_DIR}/pip"
		log "using 'python3 -m pip' as pip for the osac-test-infra tools"
	fi
	export PATH="${SHIM_DIR}:${PATH}"
}

# The group prefix is what ties the VMs to this clone, and the upstream tool
# generates a random one when the inventory does not exist yet. Seeding it is
# the only way to keep the clone in the names, so write the empty inventory
# first — before any VM exists, which is also what makes a crash recoverable.
ensure_inventory() {
	[ -f "${INVENTORY_FILE}" ] && return 0
	log "creating the raw inventory ${INVENTORY_FILE} (group prefix ${VM_NAME_PREFIX})"
	python3 - "${INVENTORY_FILE}" "${VM_NAME_PREFIX}" <<'PY'
import json, pathlib, sys

path, prefix = pathlib.Path(sys.argv[1]), sys.argv[2]
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps({"name_prefix": prefix, "hosts": []}, indent=2) + "\n")
PY
}

inventory_names() {
	python3 - "${INVENTORY_FILE}" <<'PY'
import json, sys

with open(sys.argv[1]) as inventory_file:
    inventory = json.load(inventory_file)
print("\n".join(host["name"] for host in inventory["hosts"]))
PY
}

inventory_count() {
	inventory_names | awk 'NF { count++ } END { print count + 0 }'
}

# Domain names of the index-named tool this script replaced —
# virtual-bmh-<clone>-<decimal> — as opposed to the token-suffixed names of the
# group this script manages. Reads `virsh list --all --name` on stdin.
legacy_domain_names() {
	awk -v prefix="${VM_NAME_PREFIX}-" \
		'index($0, prefix) == 1 && substr($0, length(prefix) + 1) ~ /^[0-9]+$/'
}

# VMs of the index-named tool this script replaced would add a second set of
# virtual hardware for the same clone, and Ironic would see every VM twice.
refuse_legacy_vms() {
	local name known
	local -a legacy=()
	known=$(inventory_names)
	# A token may be all decimal digits, so an inventory host can look legacy:
	# the inventory decides, not the name.
	while read -r name; do
		[ -n "${name}" ] || continue
		grep -qxF "${name}" <<<"${known}" && continue
		legacy+=("${name}")
	done < <(virsh list --all --name | legacy_domain_names)
	[ "${#legacy[@]}" -gt 0 ] || return 0
	for name in "${legacy[@]}"; do
		warn "${name} was created by the index-named tool this script replaced"
		warn "  retire it with: virsh -c qemu:///system destroy ${name} && virsh -c qemu:///system undefine ${name} --nvram --remove-all-storage"
		warn "                  oc -n ${BMH_NAMESPACE} delete bmh ${name} --ignore-not-found"
	done
	die "retire the VM(s) above and re-run"
}

network_gateway_ip() {
	virsh net-dumpxml "${CT_NETWORK}" | python3 -c '
import sys, xml.etree.ElementTree as ET
print(ET.parse(sys.stdin).getroot().find(".//ip").get("address"))
'
}

activate_ironic() {
	log "activating Ironic (osac-test-infra activate-ironic.sh)"
	bash "${TEST_INFRA_SCRIPTS}/activate-ironic.sh"
}

setup_redfish() {
	local pip_env="PIP_DISABLE_PIP_VERSION_CHECK=1"
	# setup-sushy-tools.sh installs on every run. When the emulator is already
	# there that is a no-op, and refusing to consult an index keeps it a no-op
	# without network access; the first run, which has to fetch the packages,
	# gets no such restriction.
	if command -v sushy-emulator >/dev/null 2>&1; then
		pip_env="${pip_env} PIP_NO_INDEX=1"
	fi
	log "starting the Redfish emulation on ${GW_IP} (osac-test-infra setup-sushy-tools.sh)"
	# shellcheck disable=SC2086 # pip_env is a list of NAME=value assignments
	env ${pip_env} \
		SUSHY_LISTEN_IP="${GW_IP}" \
		STORAGE_POOL_NAME="${POOL_NAME}" \
		STORAGE_DIR="${VM_DISK_DIR}" \
		SUSHY_CONFIG_DIR="${SUSHY_CONFIG_DIR}" \
		SUSHY_CACHE_NAME="${SUSHY_CACHE_NAME}" \
		SUSHY_VMEDIA_TMP="${SUSHY_VMEDIA_TMP}" \
		SUSHY_PORT="${SUSHY_PORT}" \
		SUSHY_CACHE_PORT="${SUSHY_CACHE_PORT}" \
		bash "${TEST_INFRA_SCRIPTS}/setup-sushy-tools.sh"
}

# Only the difference is created: the inventory lists the VMs that exist, and
# manage-virtual-bmh-vms.py appends what it creates. More hosts than BMH_COUNT
# are kept rather than deleted — they are usable hardware, and shrinking a
# profile must not destroy someone's running hosts.
grow_vms() {
	local have=$1 want
	want=$((BMH_COUNT - have))
	if [ "${want}" -le 0 ]; then
		if [ "${have}" -gt "${BMH_COUNT}" ]; then
			warn "the inventory lists ${have} hosts, more than BMH_COUNT=${BMH_COUNT}; keeping all of them"
		else
			log "the inventory already lists ${have} virtual host(s)"
		fi
		return 0
	fi
	log "creating ${want} virtual host(s) (osac-test-infra manage-virtual-bmh-vms.py)"
	python3 "${TEST_INFRA_SCRIPTS}/manage-virtual-bmh-vms.py" create \
		--inventory-file "${INVENTORY_FILE}" \
		--network "${CT_NETWORK}" \
		--disk-dir "${VM_DISK_DIR}" \
		--redfish-host "${GW_IP}" \
		--redfish-port "${SUSHY_PORT}" \
		--count "${want}" \
		--disk-size "${BMH_DISK_SIZE}"
}

# sushy-tools accepts any credentials and the tools record their own in the
# inventory, which is where reconcile-bmhs.py builds each BMH Secret from. A
# development environment that sets BMC_USERNAME/BMC_PASSWORD gets those.
record_bmc_credentials() {
	python3 - "${INVENTORY_FILE}" "${BMC_USERNAME}" "${BMC_PASSWORD}" <<'PY'
import json, pathlib, sys

path, username, password = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
inventory = json.loads(path.read_text())
changed = [
    host for host in inventory["hosts"]
    if host["bmc_username"] != username or host["bmc_password"] != password
]
for host in changed:
    host["bmc_username"], host["bmc_password"] = username, password
if changed:
    path.write_text(json.dumps(inventory, indent=2) + "\n")
PY
}

# A BMH that ended inspection in error keeps that error until it is recreated:
# BMO only retries with a growing backoff and never clears errorMessage, so a
# fixed emulator would still leave the host unusable and every later run would
# wait out the full inspection budget before failing.
reset_failed_bmhs() {
	local name info state operational consumer
	while read -r name; do
		[ -n "${name}" ] || continue
		info=$(oc get bmh "${name}" -n "${BMH_NAMESPACE}" \
			-o jsonpath='{.status.provisioning.state}{"|"}{.status.operationalStatus}{"|"}{.spec.consumerRef.name}' \
			2>/dev/null) || continue
		IFS='|' read -r state operational consumer <<<"${info}"
		[ "${operational}" = "error" ] || continue
		case "${state}" in
		available | inspecting | preparing) ;;
		*) continue ;;
		esac
		[ -z "${consumer}" ] || continue
		log "recreating ${name}: left in '${state}' with an error"
		oc delete bmh "${name}" -n "${BMH_NAMESPACE}" --ignore-not-found \
			--timeout=180s >/dev/null
	done < <(inventory_names)
}

# A VM whose domain no longer exists cannot be recreated under its own name —
# the token in it was generated and the MAC that goes with it is gone — so drop
# its inventory entry here: it is the truth these tools converge everything else
# on, reconcile-bmhs.py deletes the matching BMH once it is gone, and grow_vms
# adds a replacement host.
prune_missing_vms() {
	local name
	local -a missing=()
	while read -r name; do
		[ -n "${name}" ] || continue
		virsh dominfo "${name}" >/dev/null 2>&1 || missing+=("${name}")
	done < <(inventory_names)
	[ "${#missing[@]}" -gt 0 ] || return 0
	warn "dropping host(s) whose VM is gone: ${missing[*]}"
	python3 - "${INVENTORY_FILE}" "${missing[@]}" <<'PY'
import json, pathlib, sys

path, gone = pathlib.Path(sys.argv[1]), set(sys.argv[2:])
inventory = json.loads(path.read_text())
inventory["hosts"] = [host for host in inventory["hosts"] if host["name"] not in gone]
path.write_text(json.dumps(inventory, indent=2) + "\n")
PY
}

# A VM that is defined but not running keeps its BMH 'available' until BMO
# notices, so bring them back before Ironic looks at them.
start_stopped_vms() {
	local name state
	while read -r name; do
		[ -n "${name}" ] || continue
		state=$(virsh domstate "${name}" 2>/dev/null) || continue
		case ${state} in
		"shut off")
			log "starting ${name}"
			virsh start "${name}" >/dev/null
			;;
		paused)
			log "resuming ${name}"
			virsh resume "${name}" >/dev/null
			;;
		esac
	done < <(inventory_names)
}

reconcile_bmhs() {
	log "reconciling the BareMetalHosts (osac-test-infra reconcile-bmhs.py)"
	python3 "${TEST_INFRA_SCRIPTS}/reconcile-bmhs.py" \
		--inventory-file "${INVENTORY_FILE}" \
		--namespace "${BMH_NAMESPACE}"
}

# reconcile-bmhs.py labels every host with the default host-type, which is what
# the osac profiles select on. BMH_LABELS adds to that set for a profile that
# needs more; it does not replace the default label.
label_bmhs() {
	local name label
	local -a labels
	read -r -a labels <<<"${BMH_LABELS}"
	[ "${#labels[@]}" -gt 0 ] || return 0
	while read -r name; do
		[ -n "${name}" ] || continue
		for label in "${labels[@]}"; do
			oc label bmh "${name}" -n "${BMH_NAMESPACE}" "${label}" --overwrite >/dev/null
		done
	done < <(inventory_names)
	log "labeled the hosts with ${BMH_LABELS}"
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
	prepare_tool_path

	oc get --raw /readyz >/dev/null 2>&1 ||
		die "cluster at ${KUBECONFIG} is not reachable"
	oc get crd provisionings.metal3.io >/dev/null 2>&1 ||
		die "metal3.io Provisioning API missing; install the BMaaS prerequisites first"

	ensure_inventory
	refuse_legacy_vms

	GW_IP=$(network_gateway_ip)
	log "cluster-tool network ${CT_NETWORK} gateway ${GW_IP}"

	activate_ironic
	setup_redfish
	prune_missing_vms
	grow_vms "$(inventory_count)"
	record_bmc_credentials
	start_stopped_vms
	reset_failed_bmhs
	reconcile_bmhs
	label_bmhs

	log "virtual BMH setup complete: $(inventory_count) host(s) available in ${BMH_NAMESPACE}"
	log "raw inventory: ${INVENTORY_FILE}"
}

main "$@"
