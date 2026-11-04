#!/usr/bin/env bash
# shellcheck shell=bash
#
# dns.sh — make the hub's names resolve through NetworkManager's dnsmasq.
#
# Usage: tools/dev-env/dns.sh [--force]
#
# cluster-tool writes one wildcard rule per clone into
# /etc/NetworkManager/dnsmasq.d/cluster-<name>.conf
# (address=/test-infra-cluster-<name>.redhat.com/<server-ip>). When
# systemd-resolved owns /etc/resolv.conf that dnsmasq (127.0.0.1) is never
# queried, so the hub looks unreachable.
#
# This writes a systemd-resolved drop-in that routes only the hub zone to
# 127.0.0.1, leaving per-link servers (LAN, corp split DNS) untouched, then
# restarts systemd-resolved and verifies the API name resolves. Skipped when the
# hub name already resolves. The same zone is then set up on REMOTE_HOST, which
# runs the hub and therefore has to resolve its own API name; that half replaces
# cluster-tool's wildcard with the hub names alone, see
# ensure_remote_zone_routed. With REMOTE_HOST=local that host is this machine
# and cluster-tool's boot already wrote the entry, so the second half narrows it.
#
# The hub's CoreDNS then forwards the hosted-cluster zone to that dnsmasq,
# because the corp resolver answers NXDOMAIN for the hosted-cluster names
# (api.<order>.hosted.<zone>) that live only on the hub host. That forwarding is
# zone scoped: the global upstreams stay on SystemResolvConf, see
# ensure_hub_dns_zone_forward. The records themselves are hosted-dns.sh's job;
# this script only makes the hub ask the right server.
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
verify that the API name resolves. With REMOTE_HOST set, the zone is answered
there as well: REMOTE_HOST runs the hub, so its own oc and the virtual BMH step
need the API name to resolve on that machine.

cluster-tool writes one wildcard rule per clone into
/etc/NetworkManager/dnsmasq.d/cluster-<name>.conf. On REMOTE_HOST that wildcard
is replaced by the names the hub actually owns (api, api-int, *.apps), with the
rest of the zone answered NXDOMAIN: a wildcard there also answers public names
that guest pods ask for with their search domain appended
(console.redhat.com.<zone>), and those pods then reach the hub instead of the
internet. Only the hub zone is routed here; per-link servers (LAN, corp split
DNS) stay untouched.

The zone comes from OSAC_DEV_HUB_KUBECONFIG, or CLUSTER_DOMAIN when set.

Hub CoreDNS forwards the hosted-cluster zone (hosted.<hub zone>) to that
dnsmasq, so hub pods resolve hosted-cluster names (api.<order>.hosted.<zone>);
the records themselves come from hosted-dns.sh (make osac-dev-hosted-dns).

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
	ensure_hub_dns_zone_forward
}

main "$@"
