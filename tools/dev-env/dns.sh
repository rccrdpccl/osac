#!/usr/bin/env bash
# shellcheck shell=bash
#
# dns.sh — make the hub's names resolve through NetworkManager's dnsmasq.
#
# Usage: tools/dev-env/dns.sh [--force]
#
# cluster-tool writes one wildcard rule per clone into
# /etc/NetworkManager/dnsmasq.d/cluster-<name>.conf
# (address=/test-infra-cluster-<name>.redhat.com/<server-ip>), which covers api,
# *.apps, and keycloak. When systemd-resolved owns /etc/resolv.conf that dnsmasq
# (127.0.0.1) is never queried, so the hub looks unreachable.
#
# This writes a systemd-resolved drop-in that routes only the hub zone to
# 127.0.0.1, leaving per-link servers (LAN, corp split DNS) untouched, then
# restarts systemd-resolved and verifies the API name resolves. Skipped when the
# hub name already resolves. The same dnsmasq entry is then added on REMOTE_HOST,
# which runs the hub and therefore has to resolve its own API name; both halves
# are skipped when the entry is already in place. With REMOTE_HOST=local that
# host is this machine and cluster-tool's boot already wrote the entry, so the
# second half usually only confirms it.
#
# The zone comes from OSAC_DEV_HUB_KUBECONFIG (or CLUSTER_DOMAIN when set).
# Needs sudo locally unless already root; run it as your normal user or as
# root directly.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
	cat <<'EOF'
Usage: tools/dev-env/dns.sh [--force]

Route the hub zone (test-infra-cluster-<name>.redhat.com) to NetworkManager's
dnsmasq through a systemd-resolved drop-in, then restart systemd-resolved and
verify that the API name resolves. With REMOTE_HOST set, the same dnsmasq entry
is added there as well: REMOTE_HOST runs the hub, so its own oc and the virtual
BMH step need the API name to resolve on that machine.

cluster-tool writes one wildcard rule per clone into
/etc/NetworkManager/dnsmasq.d/cluster-<name>.conf covering api, *.apps, and
keycloak. When systemd-resolved owns /etc/resolv.conf that dnsmasq (127.0.0.1)
is never queried, so the hub looks unreachable. Only the hub zone is routed
here; per-link servers (LAN, corp split DNS) stay untouched.

The zone comes from OSAC_DEV_HUB_KUBECONFIG, or CLUSTER_DOMAIN when set.

--force rewrites both entries even when the hub name already resolves
(shortcut: make osac-dev-dns FORCE=1).

Needs sudo locally unless already root; run it as your normal user or as root
EOF
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

	local kubeconfig zone
	kubeconfig=$(hub_kubeconfig)
	zone=$(hub_zone)
	if [ -z "${zone}" ]; then
		warn "no hub zone yet from ${kubeconfig}; skipped DNS routing (re-run after the cluster is up)"
		return 0
	fi

	ensure_zone_routed "${zone}"
	ensure_remote_zone_routed "${zone}"
}

main "$@"
