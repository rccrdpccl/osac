#!/usr/bin/env bash
# shellcheck shell=bash
#
# hosted-dns.sh — publish DNS for hosted clusters (CaaS ClusterOrders).
#
# Usage: tools/dev-env/hosted-dns.sh [--dry-run] [--watch [SECONDS]]
#                                   [--no-prune]
#
# Every ClusterOrder that owns a HostedCluster publishes three names:
#
#   api.<order>.<baseDomain>       the hosted kube-apiserver
#   api-int.<order>.<baseDomain>   the same endpoint, as Assisted Service wants
#   *.apps.<order>.<baseDomain>    the guest ingress routers
#
# api-int matters even though nothing in the guest dials it: the Assisted Service
# host validation asks the install host to resolve it and parks the Agent in
# `insufficient` when it cannot, so a cluster whose API name resolves still never
# installs. Both API names point at the kube-apiserver LoadBalancer address.
#
# <baseDomain> is hosted.<hub zone>, which the AAP hosted_cluster role sets on
# the HostedCluster (spec.dns.baseDomain). On a real installation HyperShift's
# external-dns integration creates these records. The dev environment has no DNS
# provider: the hub dnsmasq answers the hub's own names and nothing else (see
# zone_records in common.sh), so a hosted API name that nobody publishes is
# NXDOMAIN and capi-provider cannot resolve it to set the worker's providerID,
# while an apps name caught by a looser rule lands on the hub router, which
# answers with the hub wildcard certificate and fails the guest
# console-operator's route health check. Either way a cluster that is otherwise
# healthy never finishes.
#
# So this publishes, per order, one NetworkManager dnsmasq drop-in on the hub's
# host: the API name to the hosted kube-apiserver LoadBalancer address, and the
# apps domain to the order's reserved guest ingress VIP. Both values come from
# the hub, so records follow the orders a suite creates and are dropped when an
# order is deleted. Drop-ins are keyed by hub UID and order UID, so another
# hub's records (including old, unscoped files) are never pruned. The hub CoreDNS
# half — delegating this dnsmasq the hosted zone because the corp resolver answers
# NXDOMAIN for it — is
# ensure_hub_dns_zone_forward in common.sh. The worker VMs resolve through the
# test-infra network's dnsmasq, which cluster-tool defines with
# localOnly='yes'; flipping that is ensure_vm_net_forwards_hosted_zone in
# common.sh, dns.sh's job.
#
# Skipped, with a message, while no order has a hosted cluster yet: a suite
# creates one minutes into the run, which is what --watch is for.
#
# Inputs (defaults in common.sh): OSAC_DEV_HUB_KUBECONFIG, CLUSTER_NAME,
# REMOTE_HOST. HOSTED_DNS_INTERVAL sets the --watch period (30s).
#
# Needs cluster-admin on the hub and root on the hub's host for the dnsmasq
# drop-ins; run it as your normal user or as root directly.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

DNSMASQ_DIR=/etc/NetworkManager/dnsmasq.d
# First line of every file this script owns. Pruning skips any drop-in without
# it, so a hand-written record survives.
MARKER="# managed by tools/dev-env/hosted-dns.sh"
: "${HOSTED_DNS_INTERVAL:=30}"

usage() {
	cat <<'EOF'
Usage: tools/dev-env/hosted-dns.sh [--dry-run] [--watch [SECONDS]]
                                  [--no-prune]

Publish DNS records for every ClusterOrder that owns a hosted cluster, on the
hub's host (REMOTE_HOST), where NetworkManager's dnsmasq reads them:

  address=/api.<order>.<baseDomain>/<kube-apiserver LoadBalancer address>
  address=/api-int.<order>.<baseDomain>/<kube-apiserver LoadBalancer address>
  address=/.apps.<order>.<baseDomain>/<reserved guest ingress VIP>

<baseDomain> comes from the HostedCluster (spec.dns.baseDomain, hosted.<hub
zone>); the addresses come from the hub's kube-apiserver Service and the
CI guest ingress VIP claim registry. The hosted zone is
delegated nowhere in a dev environment, and the catch-all cluster-tool writes for
the hub zone answers these names with the hub's own address, which stalls a CaaS
order at "Workers Joining" even though the cluster itself came up.

--watch [SECONDS]  keep publishing every SECONDS (default 30) instead of once;
                   for the duration of an E2E run, which creates the order
--dry-run          print what would be written or removed, change nothing
--no-prune         keep records of orders that no longer exist

Idempotent: a drop-in is only rewritten, and dnsmasq only reloaded, when its
content changes. Files this script did not write are never removed.

Needs cluster-admin on the hub and root on the hub's host; run it as your normal
user or as root directly.
EOF
}

kube() {
	KUBECONFIG="${kubeconfig}" "${kubectl}" "$@"
}

# UID, namespace, order, hosted cluster and hosted namespace. The operator
# supplies the namespace before AAP needs DNS, but may not have observed the
# HostedCluster name yet. The dev CI template creates it with the order name.
hosted_orders() {
	kube get clusterorder --all-namespaces -o json | jq -r '.items[] |
		[.metadata.uid, .metadata.namespace, .metadata.name,
		  ((.status.clusterReference.hostedClusterName | select(. != "")) // .metadata.name),
		  (.status.clusterReference.namespace // "")] | @tsv'
}

# Every zone this run has to keep resolvable: the hosted zone from the hub's
# ingress domain, plus the baseDomain each live HostedCluster actually set.
hosted_zones() {
	local orders _uid _namespace _order hc hc_ns base
	orders=$(hosted_orders) || return 1
	{
		hosted_dns_zone
		while IFS=$'\t' read -r _uid _namespace _order hc hc_ns; do
			[ -n "${hc_ns}" ] || continue
			base=$(kube get hostedcluster "${hc}" -n "${hc_ns}" \
				-o jsonpath='{.spec.dns.baseDomain}' 2>/dev/null) || base=""
			[ -n "${base}" ] && printf '%s\n' "${base}"
		done <<<"${orders}"
	} | sort -u
}

# Publish the API as soon as it has a LoadBalancer address, then publish the
# ingress VIP as soon as AAP claims it, before AAP waits for DNS or workers.
order_records() {
	local hc=$1 hc_ns=$2 vip=$3
	local hcp_ns="${hc_ns}-${hc}" base kas
	base=$(kube get hostedcluster "${hc}" -n "${hc_ns}" \
		-o jsonpath='{.spec.dns.baseDomain}' 2>/dev/null) || base=""
	[ -n "${base}" ] || return 0
	kas=$(kube get service kube-apiserver -n "${hcp_ns}" \
		-o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || kas=""
	if [ -n "${kas}" ]; then
		printf 'address=/api.%s.%s/%s\n' "${hc}" "${base}" "${kas}"
		printf 'address=/api-int.%s.%s/%s\n' "${hc}" "${base}" "${kas}"
	fi
	if [[ ${vip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		printf 'address=/.apps.%s.%s/%s\n' "${hc}" "${base}" "${vip}"
	fi
}

remote_read() {
	ssh_remote_root "cat $(printf '%q' "$1") 2>/dev/null" 2>/dev/null || true
}

remote_write() {
	ssh_remote_root "printf '%s\n' $(printf '%q' "$2") >$(printf '%q' "$1")"
}

reload_dnsmasq() {
	log "reloading dnsmasq on ${REMOTE_HOST}"
	ssh_remote_root "systemctl reload NetworkManager 2>/dev/null ||
		systemctl restart NetworkManager" ||
		warn "could not reload NetworkManager; the records apply on its next restart"
}

verify_name() {
	local name=$1 want=$2 got
	got=$(ssh_remote_root "dig +short +time=2 +tries=1 $(printf '%q' "${name}") @127.0.0.1" \
		2>/dev/null | awk 'NR == 1') || got=""
	if [ "${got}" = "${want}" ]; then
		log "${name} -> ${want}"
	else
		warn "${name} resolves to '${got}', expected ${want}"
	fi
}

# Drop only records of this hub's deleted orders. Legacy unscoped files are
# intentionally left alone. Return success only if files were removed.
prune_stale() {
	local dry_run=$1 keep=$2 files file uid removed=1
	local prefix="${DNSMASQ_DIR}/hosted-${hub_uid}-"
	files=$(ssh_remote_root "ls -1 ${prefix}*.conf" 2>/dev/null) || files=""
	for file in ${files}; do
		[[ ${file} == "${prefix}"*.conf ]] || continue
		uid=${file#"${prefix}"}
		uid=${uid%.conf}
		case " ${keep} " in
		*" ${uid} "*) continue ;;
		esac
		remote_read "${file}" | awk 'NR == 1' | grep -qxF "${MARKER}" || continue
		if [ "${dry_run}" = "1" ]; then
			log "would remove ${file} (no ClusterOrder with UID ${uid})"
			continue
		fi
		log "removing ${file} (no ClusterOrder with UID ${uid})"
		if ssh_remote_root "rm -f $(printf '%q' "${file}")"; then
			removed=0
		else
			warn "could not remove ${file}"
		fi
	done
	return "${removed}"
}

# One pass: publish every hosted order's records, then prune what died.
publish_once() {
	local dry_run=$1 prune=$2 orders claims uid namespace order hc hc_ns vip records conf current
	local desired changed="" kept="" api domain addr
	local -a published=()
	orders=$(hosted_orders) || return 1
	claims=$(kube get configmap osac-ci-guest-ingress-vip-claims -n "${NS}" --ignore-not-found -o json) || return 1
	if [ -z "${orders}" ]; then
		log "no ClusterOrder owns a hosted cluster yet"
	fi
	while IFS=$'\t' read -r uid namespace order hc hc_ns; do
		[[ ${uid} =~ ^[a-z0-9-]+$ ]] || continue
		kept="${kept} ${uid}"
		[ -n "${hc_ns}" ] || continue
		vip=$(jq -r --arg uid "${uid}" --arg owner "${namespace}/${order}" '
			(.data[$uid] // "" | split(" ")) | select(length == 2 and .[1] == $owner) | .[0]' \
			<<<"${claims}") || return 1
		records=$(order_records "${hc}" "${hc_ns}" "${vip}") || records=""
		if [ -z "${records}" ]; then
			log "${hc}: no hosted endpoint yet, nothing to publish"
			continue
		fi
		conf="${DNSMASQ_DIR}/hosted-${hub_uid}-${uid}.conf"
		desired=$(printf '%s\n%s' "${MARKER}" "${records}")
		current=$(remote_read "${conf}")
		if [ "${current}" = "${desired}" ]; then
			continue
		fi
		if [ "${dry_run}" = "1" ]; then
			log "would write ${conf} (order ${order}):"
			printf '%s\n' "${desired}" | sed 's/^/    /'
			continue
		fi
		log "publishing ${conf} (order ${order})"
		remote_write "${conf}" "${desired}" ||
			die "could not write ${conf} on ${REMOTE_HOST}"
		changed=1
		# Both API names (api and api-int) are checked; the apps record is a
		# wildcard, so it is only exercised by the guest routers using it.
		while read -r api; do
			[ -n "${api}" ] || continue
			domain=${api#address=/}
			domain=${domain%%/*}
			addr=${api##*/}
			published+=("${domain} ${addr}")
		done < <(printf '%s\n' "${records}" | grep '^address=/api' || true)
	done <<<"${orders}"
	if [ "${prune}" = "1" ] && prune_stale "${dry_run}" "${kept}"; then
		changed=1
	fi
	[ -n "${changed}" ] || return 0
	reload_dnsmasq
	if [ "${#published[@]}" -eq 0 ]; then
		return 0
	fi
	local pair
	for pair in "${published[@]}"; do
		verify_name "${pair%% *}" "${pair##* }"
	done
}

main() {
	local dry_run="" watch="" prune=1 interval=${HOSTED_DNS_INTERVAL} zones
	require_user_context

	while [ $# -gt 0 ]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		--dry-run) dry_run=1 ;;
		--no-prune) prune="" ;;
		--watch)
			watch=1
			if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
				interval=$2
				shift
			fi
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	kubeconfig=$(hub_kubeconfig)
	kubectl=$(kubectl_bin)
	[ -n "${kubectl}" ] || die "neither kubectl nor oc is on PATH"
	[ -f "${kubeconfig}" ] ||
		die "no kubeconfig at ${kubeconfig}; boot the hub first (make osac-dev-cluster)"
	command -v jq >/dev/null || die 'jq is required to publish hosted DNS'
	hub_uid=$(kube get namespace kube-system -o jsonpath='{.metadata.uid}') || die 'cannot identify DNS owner hub'
	[[ ${hub_uid} =~ ^[a-z0-9-]+$ ]] || die 'unexpected hub UID; refusing to change DNS'
	zones=$(hosted_zones) || die 'cannot read ClusterOrders on the hub'
	if [ "${dry_run}" = "1" ]; then
		log "would let hub CoreDNS forward $(tr '\n' ' ' <<<"${zones}")to the host dnsmasq"
	else
		# shellcheck disable=SC2086 # zone names never contain whitespace
		ensure_hub_dns_zone_forward ${zones}
	fi

	if [ "${watch}" = "1" ]; then
		log "publishing hosted-cluster records every ${interval}s (Ctrl-C to stop)"
		trap 'exit 0' INT TERM
		while :; do
			publish_once "${dry_run}" "${prune}" ||
				warn "publish failed; retrying in ${interval}s"
			sleep "${interval}"
		done
	fi
	publish_once "${dry_run}" "${prune}"
}

main "$@"
