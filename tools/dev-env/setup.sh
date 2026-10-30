#!/usr/bin/env bash
# shellcheck shell=bash
#
# setup.sh — install the client-side resolver prerequisites.
#
# Usage: tools/dev-env/setup.sh [--force]
#
# Runs `cluster-tool setup client`, which installs dnsmasq and NetworkManager
# dns=dnsmasq and writes one wildcard rule per clone
# (address=/test-infra-cluster-<name>.redhat.com/<ip>). Skipped when
# /etc/NetworkManager/conf.d/cluster-tool-dns.conf already has dns=dnsmasq and
# dnsmasq is running, so `make osac-dev` can call it every time.
#
# Routing that zone through dnsmasq is dns.sh's job: when systemd-resolved owns
# /etc/resolv.conf the 127.0.0.1 dnsmasq is never queried. `make osac-dev` runs
# this script and then dns.sh.
#
# --force (or FORCE=1 through the Makefile) re-runs the client setup even when it
# is already configured.
#
# Needs sudo; run it as your normal user.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
	cat <<'EOF'
Usage: tools/dev-env/setup.sh [--force]

Install the client-side resolver prerequisites, idempotently:

  cluster-tool setup client    dnsmasq + NetworkManager dns=dnsmasq
  skipped when /etc/NetworkManager/conf.d/cluster-tool-dns.conf has dns=dnsmasq
  and dnsmasq is running

Routing the hub zone through that dnsmasq is dns.sh's job (make osac-dev-dns);
make osac-dev runs this script and then dns.sh.

--force re-runs the client setup even when it is already configured
(shortcut: make osac-dev-setup FORCE=1).

Needs sudo; run it as your normal user.
EOF
}

# cluster-tool's own setup client, skipped once its DNS plumbing is in place.
# Its last step expects NetworkManager to own /etc/resolv.conf, so it exits
# non-zero on hosts where systemd-resolved does; the zone routing below covers
# that case.
ensure_client_setup() {
	if [ "${OSAC_DEV_FORCE}" != "1" ] && client_configured; then
		log "dnsmasq client already configured, skipping cluster-tool setup client"
		return 0
	fi
	command -v "${CLUSTER_TOOL}" >/dev/null 2>&1 ||
		die "${CLUSTER_TOOL} not found in PATH"
	# sudo resets PATH, so hand it the resolved path.
	log "cluster-tool client setup: ${CLUSTER_TOOL} setup client (needs sudo)"
	sudo "$(command -v "${CLUSTER_TOOL}")" setup client ||
		warn "cluster-tool setup client exited non-zero (expected when systemd-resolved owns /etc/resolv.conf); routing the zone below instead"
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

	require_non_root

	ensure_client_setup
}

main "$@"
