#!/usr/bin/env bash
# shellcheck shell=bash
#
# cluster.sh — provision the OSAC dev cluster with cluster-tool.
#
# Usage: tools/dev-env/cluster.sh [--force]
#
# Prepares cluster-tool on REMOTE_HOST (root@host, or `local` to run the hub on
# this machine), makes sure the FLAVOR is present there, then boots CLUSTER_NAME
# from it. Every step is skipped when the desired state already exists, so
# re-running is cheap.
#
# Fast path: when OSAC_DEV_HUB_KUBECONFIG points at a valid kubeconfig whose API
# server is reachable, cluster-tool is not used at all and the existing hub is
# reused. Without REMOTE_HOST/PULL_SECRET_FILE the script does nothing else.
#
# Required unless OSAC_DEV_HUB_KUBECONFIG is usable:
#   REMOTE_HOST=root@host        SSH target for the cluster-tool server
#   REMOTE_HOST=local            run the hub on this machine instead
#   PULL_SECRET_FILE=~/ps.json   local pull secret injected into the cluster
#
# Other inputs (defaults in common.sh):
#   CLUSTER_TOOL_DATA=/data/cluster-tool  must match the server's data dir
#   FLAVOR=sno-4-22                       flavor to boot (pulled if missing)
#   CLUSTER_NAME=osac-dev                 clone name, also the cluster's zone
#   SERVER_NAME=osac-dev                  cluster-tool server alias locally
#
# With REMOTE_HOST=local the cluster-tool server operations run under sudo
# (libvirt, haproxy, and the dnsmasq entries need root); cluster-tool chowns
# the state and kubeconfig it writes back to the invoking user.
#
# One-time client-side prerequisite (DNS for *.apps on your laptop), run by hand
# once: sudo cluster-tool setup client

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
	cat <<'EOF'
Usage: tools/dev-env/cluster.sh [--force]

Prepare cluster-tool on REMOTE_HOST, pull FLAVOR if missing, and boot
CLUSTER_NAME. Steps are skipped when the desired state already exists.

Fast path: with a valid, reachable OSAC_DEV_HUB_KUBECONFIG the existing hub is
reused and cluster-tool is not used at all.

Required unless OSAC_DEV_HUB_KUBECONFIG is usable:
  REMOTE_HOST=root@host        SSH target for the cluster-tool server
  REMOTE_HOST=local            run the hub on this machine instead
  PULL_SECRET_FILE=~/ps.json   local pull secret injected into the cluster

Other inputs (defaults in common.sh):
  CLUSTER_TOOL_DATA=/data/cluster-tool  must match the server's data dir
  FLAVOR=sno-4-22                       flavor to boot (pulled if missing)
  CLUSTER_NAME=osac-dev                 clone name, also the cluster's zone
  SERVER_NAME=osac-dev                  cluster-tool server alias locally

With REMOTE_HOST=local the server operations run under sudo (libvirt, haproxy,
and the dnsmasq entries need root); cluster-tool chowns the state and
kubeconfig it writes back to the invoking user.

--force re-runs the cluster-tool server setup (CLUSTER_TOOL_FORCE=1).

One-time client-side prerequisite (DNS for *.apps on your laptop):
  sudo cluster-tool setup client
EOF
}

# cluster-tool would pull a second copy of the flavor into another data dir.
# The server config lives in root's home when the server is local (connect
# runs under sudo), hence ssh_remote_root; for a real host it is the same ssh
# as ssh_remote, just run as the ssh user.
check_data_dir() {
	[ "${CLUSTER_TOOL_FORCE}" != "1" ] || return 0
	local remote_data
	remote_data=$(ssh_remote_root \
		'sed -n "s/^CLUSTER_TOOL_DATA=//p" ~/.config/cluster-tool/config' 2>/dev/null) ||
		remote_data=""
	if [ -n "${remote_data}" ] && [ "${remote_data}" != "${CLUSTER_TOOL_DATA}" ]; then
		die "${REMOTE_HOST} uses data dir ${remote_data}, not ${CLUSTER_TOOL_DATA};
       re-run with CLUSTER_TOOL_DATA=${remote_data} to reuse its flavors"
	fi
}

# The remote config file is the last thing cluster-tool's server setup writes.
setup_server() {
	if [ "${CLUSTER_TOOL_FORCE}" != "1" ] &&
		grep -qF "\"${SERVER_NAME}\"" "${CLUSTER_TOOL_SERVERS}" 2>/dev/null &&
		ssh_remote_root 'test -f ~/.config/cluster-tool/config'; then
		log "${SERVER_NAME} already set up on ${REMOTE_HOST}, skipping (--force to redo)"
		return 0
	fi
	log "cluster-tool server setup on ${REMOTE_HOST}"
	"${CLUSTER_TOOL_CMD[@]}" connect "${SERVER_NAME}" --host "${REMOTE_HOST}" \
		--data-path "${CLUSTER_TOOL_DATA}"
}

# First column of `cluster-tool flavors`/`list` table rows, header and rule
# skipped.
remote_names() {
	"${CLUSTER_TOOL_CMD[@]}" "$1" --server "${SERVER_NAME}" | awk 'NR > 2 { print $1 }'
}

# True when the table for `flavors`/`list` contains the given name. Reads all
# input so pipefail stays quiet, unlike `grep -q`.
remote_has() {
	local names
	names=$(remote_names "$1") || return 1
	awk -v want="$2" '$1 == want { found = 1 } END { exit !found }' <<<"${names}"
}

ensure_flavor() {
	if remote_has flavors "${FLAVOR}"; then
		log "flavor ${FLAVOR} already present on ${REMOTE_HOST}, skipping pull"
		return 0
	fi
	log "pulling ${FLAVOR_IMAGE} (takes 10-15 min)"
	"${CLUSTER_TOOL_CMD[@]}" pull "${FLAVOR_IMAGE}" --server "${SERVER_NAME}"
}

boot_cluster() {
	if remote_has list "${CLUSTER_NAME}"; then
		log "${CLUSTER_NAME} is already booted on ${REMOTE_HOST}, skipping boot"
		return 0
	fi
	log "booting ${CLUSTER_NAME} from ${FLAVOR} on ${REMOTE_HOST}"
	"${CLUSTER_TOOL_CMD[@]}" boot --server "${SERVER_NAME}" --flavor "${FLAVOR}" \
		--name "${CLUSTER_NAME}" --pull-secret "${PULL_SECRET_FILE}"
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) CLUSTER_TOOL_FORCE=1 ;;
		-h | --help)
			usage
			return 0
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	local kubeconfig
	if [ "${OSAC_DEV_FORCE}" = "1" ]; then CLUSTER_TOOL_FORCE=1; fi
	kubeconfig=$(hub_kubeconfig)
	if hub_ready; then
		log "OSAC_DEV_HUB_KUBECONFIG=${kubeconfig} is valid and reachable, reusing that hub"
		return 0
	fi

	[ -n "${REMOTE_HOST}" ] ||
		die "REMOTE_HOST is required, e.g. REMOTE_HOST=root@host or REMOTE_HOST=local
       (or set OSAC_DEV_HUB_KUBECONFIG)"
	[ -n "${PULL_SECRET_FILE}" ] ||
		die "PULL_SECRET_FILE is required, e.g. PULL_SECRET_FILE=~/pull-secret.json"
	PULL_SECRET_FILE=$(expand_path "${PULL_SECRET_FILE}")
	[ -f "${PULL_SECRET_FILE}" ] || die "PULL_SECRET_FILE=${PULL_SECRET_FILE} does not exist"
	command -v "${CLUSTER_TOOL}" >/dev/null 2>&1 ||
		die "${CLUSTER_TOOL} not found in PATH"

	check_data_dir
	setup_server
	ensure_flavor
	boot_cluster
	log "ready: export KUBECONFIG=\$HOME/.kube/${CLUSTER_NAME}.kubeconfig"
}

main "$@"
