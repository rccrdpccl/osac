#!/usr/bin/env bash
# shellcheck shell=bash
#
# bmh.sh — run the virtual BMH setup on REMOTE_HOST against the hub.
#
# Usage: tools/dev-env/bmh.sh [--force]
#
# The emulation is osac-test-infra's: tools/shared/virtual-bmh.sh is a thin
# orchestrator over its activate-ironic.sh, setup-sushy-tools.sh,
# manage-virtual-bmh-vms.py and reconcile-bmhs.py, so this environment and CI
# run the same code. That library knows nothing about REMOTE_HOST, sudo, or this
# repository: it expects to run on the machine that hosts the libvirt VMs, needs
# an osac-test-infra checkout there (TEST_INFRA_DIR), and takes its configuration
# from the environment. This script supplies both the transport — it copies the
# hub kubeconfig over, clones or updates the checkout, pipes the library to a
# remote bash, and passes the inputs through env — and the checkout itself.
#
# The library runs as root on that machine (ssh root@ for a real REMOTE_HOST,
# sudo when it is `local`), because defining VMs, the storage pool, and the
# emulator needs libvirt and the VMs' disks live where root put them. Locally
# the kubeconfig is not pushed (it is already here) and the library gets its
# KUBECONFIG and KUBECTL as absolute paths, since sudo resets HOME and PATH.
#
# REMOTE_HOST is the hypervisor running the cluster: the hub API address is
# local to it and haproxy there routes by SNI, so oc needs the hub name to
# resolve. That entry belongs to the DNS concern and is written by dns.sh; it is
# re-applied here only when the hub API turns out to be unreachable, so the
# target works even when dns.sh was never run for this host. With
# REMOTE_HOST=local that machine is this one, and the entry cluster-tool's boot
# wrote here already covers it.
#
# Skipped only when the setup is verifiably current: for each of the
# BMH_COUNT VMs it expects, the VM exists on REMOTE_HOST with its NIC MAC and
# domain UUID, it is running, and a BMH of that name in BMH_NAMESPACE is
# available and still points at that MAC and UUID. Counting available BMHs
# alone would accept unrelated hosts in the namespace or BMHs left over from a
# recreated VM. Any gap (stopped VM, dead emulator, missing or stale BMH) is
# reconciled by the library.
#
# Inputs (defaults in common.sh / the Makefile):
#   REMOTE_HOST      ssh target that hosts the cluster-tool cluster, or `local`
#   OSAC_DEV_HUB_KUBECONFIG  kubeconfig of the hub, else ~/.kube/<CLUSTER_NAME>
#   CLUSTER_NAME     cluster-tool clone name, used for network/VM names
#   BMH_NAMESPACE=host-inventory BMH_COUNT=2 BMH_DISK_SIZE=150G SUSHY_PORT=8000
#   TEST_INFRA_DIR=~/osac-test-infra  TEST_INFRA_REF=main  TEST_INFRA_UPDATE=

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

LIB="${REPO_ROOT}/tools/shared/virtual-bmh.sh"

usage() {
	cat <<'EOF'
Usage: tools/dev-env/bmh.sh [--force]

Create virtual BareMetalHosts on REMOTE_HOST for the hub: libvirt VMs on the
cluster-tool network plus a sushy-tools Redfish emulator, then BMH resources
that Ironic inspects until they are available.

Skipped only when the expected VMs exist on REMOTE_HOST, are running, and each
has an available BMH still pointing at that VM's MAC and UUID; --force runs the
setup regardless (shortcut: make osac-dev-bmh FORCE=1). Partial state is
repaired in place: stopped VMs are started, a VM whose domain is gone is
replaced, a dead emulator restarted, missing or stale BMHs (re-)applied.

Inputs (defaults in common.sh / the Makefile):
  REMOTE_HOST              ssh target hosting the cluster (user@host), or
                           `local` to run the hub on this machine
  OSAC_DEV_HUB_KUBECONFIG  kubeconfig of the hub, else ~/.kube/<CLUSTER_NAME>
  CLUSTER_NAME=osac-dev    cluster-tool clone name (network and VM names)
  BMH_NAMESPACE=host-inventory  BMH_COUNT=2  BMH_DISK_SIZE=150G
  SUSHY_PORT=8000          BMC_USERNAME=admin  BMC_PASSWORD=password
  BMH_LABELS="osac.openshift.io/host-type=default"
  TEST_INFRA_DIR=${HOME}/osac-test-infra on REMOTE_HOST (default),
  TEST_INFRA_REF=main, TEST_INFRA_UPDATE=1 to move an existing checkout

The library doing the work is tools/shared/virtual-bmh.sh, a thin orchestrator
over the osac-test-infra BMaaS tools; the checkout it runs from is cloned or
updated here.
EOF
}

# Per-host identity on REMOTE_HOST, one line each: <vm name> <mac> <uuid>.
# The raw inventory that osac-test-infra's tools maintain is the source of truth:
# host names carry a generated token, so they are not derivable from the clone,
# and the inventory is what maps a BMH back to the domain that backs it. Fails
# when there is no inventory or any listed domain is not running. Runs as root
# on the hub's host, which is the context the library created them in.
remote_vm_state() {
	ssh_remote_root "env CLONE_NAME=$(printf '%q' "${CLUSTER_NAME}") bash -s" <<'REMOTE'
set -euo pipefail
inventory="${HOME}/virtual-bmh-inventory-${CLONE_NAME}.json"
[ -f "${inventory}" ] || exit 1
python3 - "${inventory}" <<'PY'
import json, subprocess, sys

with open(sys.argv[1]) as inventory_file:
    inventory = json.load(inventory_file)
for host in inventory["hosts"]:
    state = subprocess.run(
        ["virsh", "-c", "qemu:///system", "domstate", host["name"]],
        capture_output=True,
        text=True,
    )
    if state.returncode != 0 or state.stdout.strip() != "running":
        sys.exit(1)
    print(host["name"], host["boot_mac"], host["uuid"])
PY
REMOTE
}

# Absolute path of the osac-test-infra checkout on REMOTE_HOST. It is root that
# executes the tools there, so a relative value has no directory to resolve
# against.
remote_test_infra_dir() {
	if [ -n "${TEST_INFRA_DIR}" ]; then
		case ${TEST_INFRA_DIR} in
		/*) printf '%s\n' "${TEST_INFRA_DIR}" ;;
		*) die "TEST_INFRA_DIR must be an absolute path (got '${TEST_INFRA_DIR}')" ;;
		esac
		return 0
	fi
	ssh_remote 'printf "%s/osac-test-infra\n" "$HOME"'
}

# The emulation runs CI's own tools, so REMOTE_HOST gets an osac-test-infra
# checkout instead of a copy of them: cloned on first use, and moved to
# TEST_INFRA_REF only when TEST_INFRA_UPDATE=1, so an ordinary run does not
# depend on reaching GitHub.
ensure_remote_test_infra() {
	local dir=$1 head
	if ssh_remote "[ -d $(printf '%q' "${dir}")/.git ]"; then
		if [ "${TEST_INFRA_UPDATE}" = "1" ]; then
			log "updating ${dir} on ${REMOTE_HOST} to ${TEST_INFRA_REPO} ${TEST_INFRA_REF}"
			ssh_remote "cd $(printf '%q' "${dir}") &&
				git fetch --quiet $(printf '%q' "${TEST_INFRA_REPO}") $(printf '%q' "${TEST_INFRA_REF}") &&
				git checkout --quiet FETCH_HEAD" ||
				die "could not update ${dir} on ${REMOTE_HOST}"
		else
			head=$(ssh_remote "git -C $(printf '%q' "${dir}") rev-parse --short HEAD") ||
				die "could not read the revision of ${dir} on ${REMOTE_HOST}"
			log "using ${dir} on ${REMOTE_HOST} at ${head} (TEST_INFRA_UPDATE=1 to move it)"
		fi
	else
		log "cloning ${TEST_INFRA_REPO} (${TEST_INFRA_REF}) into ${dir} on ${REMOTE_HOST}"
		ssh_remote "mkdir -p $(printf '%q' "$(dirname "${dir}")") &&
			git clone --quiet --branch $(printf '%q' "${TEST_INFRA_REF}") $(printf '%q' "${TEST_INFRA_REPO}") $(printf '%q' "${dir}")" ||
			die "could not clone ${TEST_INFRA_REPO} on ${REMOTE_HOST}"
	fi
	ssh_remote "for script in activate-ironic.sh setup-sushy-tools.sh manage-virtual-bmh-vms.py \
		reconcile-bmhs.py raw_inventory.py; do
		test -f $(printf '%q' "${dir}")/.github/scripts/\$script || exit 1
	done" ||
		die "${dir} on ${REMOTE_HOST} is not an osac-test-infra checkout (incomplete .github/scripts)"
}

# True when every virtual BMH this setup owns is available on the hub *and* still
# points at the VM that exists on REMOTE_HOST. Counting available BMHs alone is
# not enough: the namespace can hold physical hosts, a recreated VM gets a new
# UUID and MAC, and a powered-off VM stops being usable while its BMH still
# reads available for a while.
bmh_setup_is_current() {
	local kubectl hub_dump vm_dump name mac uuid line jsonpath
	kubectl=$(kubectl_bin)
	[ -n "${kubectl}" ] || return 1
	vm_dump=$(remote_vm_state) || return 1
	[ -n "${vm_dump}" ] || return 1
	# Fewer hosts than the profile asks for is not current, however healthy they
	# are: an earlier run may have stopped after creating the first one.
	[ "$(grep -c . <<<"${vm_dump}")" -ge "${BMH_COUNT}" ] || return 1
	jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.provisioning.state}{" "}'
	jsonpath=$jsonpath'{.spec.bootMACAddress}{" "}{.spec.bmc.address}{"\n"}{end}'
	hub_dump=$("${kubectl}" --kubeconfig "${HUB_KUBECONFIG}" get bmh \
		-n "${BMH_NAMESPACE}" -o jsonpath="${jsonpath}" 2>/dev/null) || return 1
	while read -r name mac uuid; do
		[ -n "${name}" ] || return 1
		line=$(awk -v want="${name}" '$1 == want { print; exit }' <<<"${hub_dump}")
		[ -n "${line}" ] || return 1
		[ "$(awk '{ print $2 }' <<<"${line}")" = "available" ] || return 1
		[ "$(awk '{ print $3 }' <<<"${line}")" = "${mac}" ] || return 1
		case "$(awk '{ print $4 }' <<<"${line}")" in
		*"${uuid}"*) ;;
		*) return 1 ;;
		esac
	done <<<"${vm_dump}"
}

# The library reads the cluster through KUBECONFIG on REMOTE_HOST, which
# cluster-tool does not write there when the boot ran elsewhere.
push_kubeconfig() {
	local remote_kubeconfig='$HOME/.kube/'"${CLUSTER_NAME}"'.kubeconfig'
	local local_sum remote_sum
	if remote_is_local; then
		log "hub kubeconfig is already on this machine, nothing to push"
		return 0
	fi
	local_sum=$(md5sum "${HUB_KUBECONFIG}" | cut -d' ' -f1)
	remote_sum=$(ssh_remote "md5sum ${remote_kubeconfig} 2>/dev/null | cut -d' ' -f1" || true)
	if [ "${local_sum}" = "${remote_sum}" ]; then
		log "hub kubeconfig already current on ${REMOTE_HOST}"
		return 0
	fi
	log "copying hub kubeconfig to ${REMOTE_HOST}:~/.kube/${CLUSTER_NAME}.kubeconfig"
	ssh_remote "mkdir -p \"\$HOME/.kube\" && umask 077 && cat >${remote_kubeconfig}" \
		<"${HUB_KUBECONFIG}"
	ssh_remote "chmod 600 ${remote_kubeconfig}"
}

# oc on REMOTE_HOST, quiet unless the caller wants the error output.
remote_readyz() {
	ssh_remote "oc --kubeconfig \"\$HOME/.kube/${CLUSTER_NAME}.kubeconfig\" get --raw /readyz" 2>&1
}

ensure_remote_hub_access() {
	local out
	if out=$(remote_readyz); then
		log "hub API reachable from ${REMOTE_HOST}"
		return 0
	fi
	warn "hub API not reachable from ${REMOTE_HOST}: ${out}"
	ensure_remote_zone_routed "$(hub_zone)"
	out=$(remote_readyz) ||
		die "hub API still not reachable from ${REMOTE_HOST}: ${out}"
	log "hub API reachable from ${REMOTE_HOST}"
}

# The KUBECONFIG and KUBECTL lines for the library's environment. On a real
# REMOTE_HOST the kubeconfig was pushed to the ssh user's home and that user's
# PATH holds oc. Locally the library runs as root through ssh_remote_root, so
# $HOME would point at /root and sudo's PATH may miss a user-local oc: pass
# both as the absolute values this script already resolved. An empty kubectl
# binary keeps the library's own `oc` default.
remote_kubeconfig_env() {
	if remote_is_local; then
		printf 'KUBECONFIG=%q\nKUBECTL=%q\n' \
			"${HUB_KUBECONFIG}" "$(kubectl_bin)"
	else
		printf 'KUBECONFIG=$HOME/.kube/%s.kubeconfig\n' "${CLUSTER_NAME}"
	fi
}

run_remote_setup() {
	local remote_env
	remote_env=$(
		cat <<EOF
CLONE_NAME=$(printf '%q' "${CLUSTER_NAME}")
TEST_INFRA_DIR=$(printf '%q' "${REMOTE_TEST_INFRA_DIR}")
$(remote_kubeconfig_env)
BMH_NAMESPACE=$(printf '%q' "${BMH_NAMESPACE}")
BMH_COUNT=$(printf '%q' "${BMH_COUNT}")
BMH_DISK_SIZE=$(printf '%q' "${BMH_DISK_SIZE}")
SUSHY_PORT=$(printf '%q' "${SUSHY_PORT}")
SUSHY_CACHE_PORT=$(printf '%q' "${SUSHY_CACHE_PORT}")
BMH_LABELS=$(printf '%q' "${BMH_LABELS}")
BMC_USERNAME=$(printf '%q' "${BMC_USERNAME}")
BMC_PASSWORD=$(printf '%q' "${BMC_PASSWORD}")
EOF
	)
	log "running tools/shared/virtual-bmh.sh on ${REMOTE_HOST}"
	ssh_remote_root "env ${remote_env//$'\n'/ } bash -s" <"${LIB}"
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) OSAC_DEV_FORCE=1 ;;
		-h | --help)
			usage
			return 0
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	require_user_context
	[ -n "${REMOTE_HOST}" ] ||
		die "REMOTE_HOST is required (user@host, or 'local' when the hub runs here)"
	[ -f "${LIB}" ] || die "${LIB} not found"
	HUB_KUBECONFIG=$(hub_kubeconfig)
	[ -f "${HUB_KUBECONFIG}" ] ||
		die "hub kubeconfig ${HUB_KUBECONFIG} not found; set OSAC_DEV_HUB_KUBECONFIG"

	ssh_remote true ||
		die "cannot ssh to ${REMOTE_HOST} without a password (check your ssh agent)"

	if [ "${OSAC_DEV_FORCE}" != "1" ] && bmh_setup_is_current; then
		log "${BMH_COUNT} virtual BMH(s) in ${BMH_NAMESPACE} are available and still linked to their VMs, skipping virtual BMH setup"
		return 0
	fi
	if [ "${OSAC_DEV_FORCE}" = "1" ]; then
		log "FORCE=1: running virtual BMH setup regardless of the current hub state"
	else
		log "virtual BMH state is not up to date; reconciling"
	fi

	push_kubeconfig
	ensure_remote_hub_access
	REMOTE_TEST_INFRA_DIR=$(remote_test_infra_dir) ||
		die "could not determine the osac-test-infra checkout path on ${REMOTE_HOST}"
	ensure_remote_test_infra "${REMOTE_TEST_INFRA_DIR}"
	run_remote_setup
}

main "$@"
