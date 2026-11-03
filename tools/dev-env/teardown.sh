#!/usr/bin/env bash
# shellcheck shell=bash
#
# teardown.sh — remove the dev environment, one concern at a time.
#
# Usage: tools/dev-env/teardown.sh <step> [options]
#        tools/dev-env/teardown.sh all [options]
#
# Steps, each also a make target:
#
#   bmh      delete the virtual BMHs, stop the Redfish emulator, and undefine
#            the VMs and their disks on REMOTE_HOST
#   osac     uninstall the osac release and remove the AAP project archive
#            server; osac-deps and osac-infra stay
#   cluster  destroy the cluster-tool clone and its kubeconfig
#   dns      remove the hub zone routing on this machine and on REMOTE_HOST
#   local    remove the image-tag cache that the prep step wrote
#
# `all` runs the steps in that order, which is the only order that works: the
# BMHs finalize through controllers that the osac release provides, so they go
# first; the DNS drop-in is how this machine reaches the hub, so it goes last.
# Every step tolerates state that is already gone, so a step can be repeated or
# run alone long after the others.
#
# Options:
#   -y | --yes      skip the confirmation prompts          (make YES=1)
#   -n | --dry-run  print the commands instead of running  (make DRY_RUN=1)
#   --client        with dns: also drop cluster-tool's NetworkManager
#                   dns=dnsmasq config                     (TEARDOWN_CLIENT=1)
#   --flavor        with cluster: also delete the snapshot flavor; pulling it
#                   again takes 10-15 minutes               (TEARDOWN_FLAVOR=1)
#
# Inputs (defaults in common.sh): REMOTE_HOST, CLUSTER_NAME, SERVER_NAME, NS,
# HELM, BMH_NAMESPACE, BMH_COUNT, ARTIFACTS_FILE, RESOLVED_DROPIN.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

: "${TEARDOWN_YES:=}"
: "${TEARDOWN_DRY_RUN:=}"
: "${TEARDOWN_CLIENT:=}"
: "${TEARDOWN_FLAVOR:=}"

# Everything except a dry run is destructive enough to spell out first.
confirm() {
	[ "${TEARDOWN_DRY_RUN}" = "1" ] && return 0
	[ "${TEARDOWN_YES}" = "1" ] && return 0
	[ -t 0 ] ||
		die "refusing to $1 without --yes (there is no terminal to confirm on)"
	printf '>> about to %s\n' "$1"
	printf '   type "yes" to continue: '
	local answer=""
	read -r answer || answer=""
	[ "${answer}" = "yes" ] || die "aborted"
}

run() {
	if [ "${TEARDOWN_DRY_RUN}" = "1" ]; then
		printf '   would run:'
		printf ' %q' "$@"
		printf '\n'
		return 0
	fi
	"$@"
}

usage() {
	# Everything between the shebang lines and the first statement.
	awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' \
		"${BASH_SOURCE[0]}"
}

# The BMHs are resources of the hub: their finalizers are removed by the
# controllers of the osac release, which is why this runs before `osac`.
step_bmh() {
	local kubeconfig kubectl index
	kubeconfig=$(hub_kubeconfig)
	kubectl=$(kubectl_bin)
	if [ -z "${kubectl}" ] || [ ! -f "${kubeconfig}" ]; then
		log "no kubeconfig at ${kubeconfig}, skipping the BMH resources"
	else
		confirm "delete the ${BMH_COUNT} virtual BMH(s) in ${BMH_NAMESPACE}"
		for ((index = 1; index <= BMH_COUNT; index++)); do
			run "${kubectl}" --kubeconfig "${kubeconfig}" -n "${BMH_NAMESPACE}" \
				delete bmh "virtual-bmh-${CLUSTER_NAME}-${index}" \
				--ignore-not-found --wait=true --timeout=15m ||
				warn "BMH virtual-bmh-${CLUSTER_NAME}-${index} was not deleted;
       a finalizer may be waiting for a controller that is already gone"
		done
	fi

	if [ -z "${REMOTE_HOST}" ]; then
		warn "REMOTE_HOST unset, leaving the emulator, the VMs and their network alone"
		return 0
	fi
	step_bmh_remote
}

# Remote work is a here-document so quoting stays simple: the variables travel
# through env, and everything inside runs on REMOTE_HOST.
step_bmh_remote() {
	confirm "stop the emulator and undefine the VMs on ${REMOTE_HOST}"
	if [ "${TEARDOWN_DRY_RUN}" = "1" ]; then
		log "would stop the Redfish emulator, undefine virtual-bmh-${CLUSTER_NAME}-1..${BMH_COUNT} with their disks, and drop the test-infra-net-${CLUSTER_NAME} network on ${REMOTE_HOST}"
		return 0
	fi
	ssh_remote true ||
		die "cannot ssh to ${REMOTE_HOST} without a password (check your ssh agent)"
	log "tearing down the BMH emulation on ${REMOTE_HOST}"
	ssh_remote env "CLONE=${CLUSTER_NAME}" "COUNT=${BMH_COUNT}" bash -s <<'REMOTE'
set -uo pipefail
prefix="virtual-bmh-${CLONE}"
pid_file="${HOME}/sushy-${CLONE}/sushy.pid"
if [ -f "${pid_file}" ]; then
	pid=$(cat "${pid_file}")
	kill "${pid}" 2>/dev/null || true
	printf 'stopped the Redfish emulator (pid %s)\n' "${pid}"
fi
pkill -f "sushy-emulator.*${CLONE}" 2>/dev/null || true
for ((i = 1; i <= COUNT; i++)); do
	virsh -c qemu:///system destroy "${prefix}-${i}" 2>/dev/null || true
	virsh -c qemu:///system undefine "${prefix}-${i}" \
		--nvram --remove-all-storage >/dev/null 2>&1 ||
		virsh -c qemu:///system undefine "${prefix}-${i}" >/dev/null 2>&1 || true
	printf 'undefined %s-%s\n' "${prefix}" "${i}"
done
rm -rf "${HOME}/sushy-${CLONE}" "${HOME}/sushy-vmedia-tmp-${CLONE}"
virsh -c qemu:///system net-destroy "test-infra-net-${CLONE}" 2>/dev/null || true
virsh -c qemu:///system net-undefine "test-infra-net-${CLONE}" 2>/dev/null || true
REMOTE
}

step_osac() {
	local kubeconfig
	kubeconfig=$(hub_kubeconfig)
	if [ ! -f "${kubeconfig}" ]; then
		log "no kubeconfig at ${kubeconfig}, the release is already gone"
		return 0
	fi
	confirm "uninstall the osac release in ${NS} (osac-deps and osac-infra stay)"
	run "${HELM}" --kubeconfig "${kubeconfig}" -n "${NS}" uninstall osac \
		--ignore-not-found --wait --timeout 10m ||
		warn "'${HELM} uninstall osac' failed; look for resources holding finalizers"
	# The archive server is applied by aap-project.sh, not by the release, so it
	# outlives the uninstall.
	run "${DEV_ENV_DIR}/aap-project.sh" --delete ||
		warn "could not remove the AAP project archive server"
}

# Mirror of cluster.sh's boot check: the clone is only ours to destroy when the
# server lists it.
clone_exists() {
	local names
	names=$("${CLUSTER_TOOL}" list --server "${SERVER_NAME}" 2>/dev/null |
		awk 'NR > 2 { print $1 }') || names=""
	awk -v want="${CLUSTER_NAME}" '$1 == want { found = 1 } END { exit !found }' \
		<<<"${names}"
}

step_cluster() {
	local kubeconfig
	if clone_exists; then
		confirm "destroy the cluster-tool clone ${CLUSTER_NAME} on ${SERVER_NAME}"
		run "${CLUSTER_TOOL}" destroy "${CLUSTER_NAME}" --server "${SERVER_NAME}"
	else
		log "${CLUSTER_NAME} does not exist on ${SERVER_NAME}, nothing to destroy"
	fi

	kubeconfig=$(hub_kubeconfig)
	if [ -f "${kubeconfig}" ]; then
		confirm "remove the kubeconfig ${kubeconfig}"
		run rm -f "${kubeconfig}"
	else
		log "${kubeconfig} is already gone"
	fi

	if [ "${TEARDOWN_FLAVOR}" = "1" ]; then
		confirm "delete the ${FLAVOR} flavor; pulling it again takes 10-15 minutes"
		run "${CLUSTER_TOOL}" flavors --delete "${FLAVOR}" --server "${SERVER_NAME}"
	fi
}

# dns.sh's work is two files, so the zone only goes into the log line: the paths
# stay valid once the kubeconfig is gone.
step_dns() {
	local zone remote_conf
	zone=$(hub_zone)
	[ -n "${zone}" ] ||
		zone=$(sed -n 's/^Domains=~//p' "${RESOLVED_DROPIN}" 2>/dev/null | head -1) ||
		zone=""
	[ -n "${zone}" ] || zone="the hub"

	if [ -f "${RESOLVED_DROPIN}" ]; then
		confirm "remove ${RESOLVED_DROPIN} and restart systemd-resolved"
		run sudo rm -f "${RESOLVED_DROPIN}"
		run sudo systemctl restart systemd-resolved
	else
		log "${RESOLVED_DROPIN} is already gone"
	fi

	if [ -z "${REMOTE_HOST}" ]; then
		warn "REMOTE_HOST unset, leaving the DNS entry on the hub's host alone"
	elif [ "${TEARDOWN_DRY_RUN}" = "1" ]; then
		log "would remove /etc/NetworkManager/dnsmasq.d/cluster-${CLUSTER_NAME}.conf on ${REMOTE_HOST}"
	else
		remote_conf="/etc/NetworkManager/dnsmasq.d/cluster-${CLUSTER_NAME}.conf"
		confirm "remove ${remote_conf} on ${REMOTE_HOST}"
		ssh_remote true ||
			die "cannot ssh to ${REMOTE_HOST} without a password (check your ssh agent)"
		ssh_remote env "CONF=${remote_conf}" bash -s <<'REMOTE'
set -uo pipefail
if [ -f "${CONF}" ]; then
	rm -f "${CONF}"
	systemctl reload NetworkManager || systemctl restart NetworkManager
	printf 'removed %s\n' "${CONF}"
else
	printf '%s is already gone\n' "${CONF}"
fi
REMOTE
	fi

	if [ "${TEARDOWN_CLIENT}" = "1" ]; then
		confirm "drop cluster-tool's dns=dnsmasq NetworkManager config"
		run sudo rm -f /etc/NetworkManager/conf.d/cluster-tool-dns.conf
		run sudo systemctl reload NetworkManager
	fi

	log "${zone} is no longer routed by this environment"
}

step_local() {
	local cache
	cache=$(dirname "$(expand_path "${ARTIFACTS_FILE}")")
	# dirname of an empty path is '.', which is never what we mean here.
	case ${cache} in
	"." | "/" | "${HOME}") die "refusing to remove '${cache}'; ARTIFACTS_FILE='${ARTIFACTS_FILE}'" ;;
	esac
	if [ -e "${cache}" ]; then
		confirm "remove the local cache ${cache}"
		run rm -rf "${cache}"
	else
		log "${cache} is already gone"
	fi
}

# One confirmation for the whole thing, then the steps run in dependency order.
step_all() {
	confirm "tear down the dev environment: BMHs, osac release, cluster ${CLUSTER_NAME}, and DNS"
	TEARDOWN_YES=1
	step_bmh
	step_osac
	step_cluster
	step_dns
	step_local
}

main() {
	local step
	require_non_root

	while [ $# -gt 0 ]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		-y | --yes) TEARDOWN_YES=1 ;;
		-n | --dry-run) TEARDOWN_DRY_RUN=1 ;;
		--client) TEARDOWN_CLIENT=1 ;;
		--flavor) TEARDOWN_FLAVOR=1 ;;
		-*) die "unknown option: $1 (try --help)" ;;
		*)
			[ -z "${step:-}" ] || die "only one step at a time (try --help)"
			step=$1
			;;
		esac
		shift
	done

	case ${step:-} in
	"") usage >&2 && return 2 ;;
	bmh | osac | cluster | dns | local) "step_${step}" ;;
	all) step_all ;;
	*) die "unknown step: ${step} (try --help)" ;;
	esac
}

main "$@"
