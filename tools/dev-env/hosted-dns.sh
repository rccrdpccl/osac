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
# apps domain to the guest ingress VIP the ClusterOrder published
# (osac.openshift.io/ingress-endpoint), which is where the guest routers listen
# once the ingress controller is bound to the MetalLB Service the AAP role
# configures. Worker addresses are the fallback only for an order that has not
# published an endpoint yet: the guest IngressController does listen on the host
# network there, but with more than one worker the name then resolves to a set of
# addresses only one of which a given router answers on, and a two-node guest
# flakes. Both values come from the hub, so the records follow the orders a suite
# creates and are dropped when an order is deleted. The hub CoreDNS half —
# delegating this dnsmasq the hosted zone, because the corp resolver answers
# NXDOMAIN for it — is ensure_hub_dns_zone_forward in common.sh.
#
# Each record is published twice, because two different resolvers answer for the
# hosted zone. The NetworkManager drop-in is what the hub host and the suites ask,
# and it is the only one that can hold the *.apps wildcard. Hub pods never see it:
# they ask CoreDNS, which forwards the hosted zone to the network's dnsmasq, and
# libvirt writes local=/<hub zone>/ into that instance, so it answers only what
# the network definition holds and forwards nothing else. sync_network_hosts
# therefore also adds the exact names to the clone network with virsh net-update,
# which is the only live way in: the guest admin kubeconfig points at
# https://api.<order>.<baseDomain>:6443, so without it the AAP job that configures
# the guest cannot reach the API it was handed.
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
  address=/.apps.<order>.<baseDomain>/<worker node address>   (one per worker)

and, because hub pods ask CoreDNS and CoreDNS forwards the hosted zone to the
clone network's dnsmasq instead, the same API names in that network's addn-hosts
entry (virsh net-update). The apps wildcard cannot live in addn-hosts, so pods
get the concrete default-router.<order>.<baseDomain> name the AAP role waits on.

<baseDomain> comes from the HostedCluster (spec.dns.baseDomain, hosted.<hub
zone>); the addresses come from the hub's kube-apiserver Service and the
AgentMachines of the hosted control plane namespace. The hosted zone is
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

# order<TAB>order namespace<TAB>hosted cluster<TAB>hosted cluster namespace,
# one per line. The ClusterOrder's own namespace is where the ingress endpoint
# annotation is read from.
hosted_orders() {
	kube get clusterorder --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.namespace}{"\t"}{.status.clusterReference.hostedClusterName}{"\t"}{.status.clusterReference.namespace}{"\n"}{end}' 2>/dev/null ||
		true
}

# Every zone this run has to keep resolvable: the hosted zone from the hub's
# ingress domain, plus the baseDomain each live HostedCluster actually set.
hosted_zones() {
	local _order hc hc_ns base
	{
		hosted_dns_zone
		while IFS=$'\t' read -r _order _order_ns hc hc_ns; do
			[ -n "${hc}" ] || continue
			base=$(kube get hostedcluster "${hc}" -n "${hc_ns}" \
				-o jsonpath='{.spec.dns.baseDomain}' 2>/dev/null) || base=""
			[ -n "${base}" ] && printf '%s\n' "${base}"
		done < <(hosted_orders)
	} | sort -u
}

# The guest ingress VIP the ClusterOrder published, empty until the AAP role has
# reserved and configured it.
ingress_endpoint() {
	local order_ns=$1 order=$2
	kube get clusterorder "${order}" -n "${order_ns}" \
		-o jsonpath='{.metadata.annotations.osac\.openshift\.io/ingress-endpoint}' 2>/dev/null ||
		true
}

# The dnsmasq records one hosted cluster needs, one address= line each. Silent
# while the control plane has no LoadBalancer address yet or no worker has
# registered: there is nothing truthful to publish then, and the next pass picks
# it up.
order_records() {
	local order_ns=$1 order=$2 hc=$3 hc_ns=$4
	local hcp_ns="${hc_ns}-${hc}" base kas vip node_ips ip
	base=$(kube get hostedcluster "${hc}" -n "${hc_ns}" \
		-o jsonpath='{.spec.dns.baseDomain}' 2>/dev/null) || base=""
	[ -n "${base}" ] || return 0
	kas=$(kube get service kube-apiserver -n "${hcp_ns}" \
		-o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || kas=""
	if [ -n "${kas}" ]; then
		printf 'address=/api.%s.%s/%s\n' "${hc}" "${base}" "${kas}"
		printf 'address=/api-int.%s.%s/%s\n' "${hc}" "${base}" "${kas}"
	fi
	vip=$(ingress_endpoint "${order_ns}" "${order}")
	if [ -n "${vip}" ]; then
		printf 'address=/.apps.%s.%s/%s\n' "${hc}" "${base}" "${vip}"
		return 0
	fi
	warn "${order}: no ingress endpoint yet; answering *.apps.${hc}.${base} with the worker addresses"
	node_ips=$(kube get agentmachine -n "${hcp_ns}" \
		-o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="ExternalIP")].address}{"\n"}{end}' \
		2>/dev/null) || node_ips=""
	while read -r ip; do
		if [ -n "${ip}" ]; then
			printf 'address=/.apps.%s.%s/%s\n' "${hc}" "${base}" "${ip}"
		fi
	done <<<"${node_ips}"
}

# The names hub pods have to resolve, one "<address> <name>" pair per line: the
# two API names and, once the ingress VIP is published, the concrete router name
# that stands in for the apps wildcard. Silent until there is something truthful
# to publish, exactly like order_records.
order_names() {
	local order_ns=$1 order=$2 hc=$3 hc_ns=$4
	local hcp_ns="${hc_ns}-${hc}" base kas vip
	base=$(kube get hostedcluster "${hc}" -n "${hc_ns}" \
		-o jsonpath='{.spec.dns.baseDomain}' 2>/dev/null) || base=""
	[ -n "${base}" ] || return 0
	kas=$(kube get service kube-apiserver -n "${hcp_ns}" \
		-o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) || kas=""
	if [ -n "${kas}" ]; then
		printf '%s api.%s.%s\n' "${kas}" "${hc}" "${base}"
		printf '%s api-int.%s.%s\n' "${kas}" "${hc}" "${base}"
	fi
	vip=$(ingress_endpoint "${order_ns}" "${order}") || vip=""
	if [ -n "${vip}" ]; then
		printf '%s default-router.apps.%s.%s\n' "${vip}" "${hc}" "${base}"
	fi
	return 0
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

# Drop the drop-ins of hosted clusters that no longer exist. $* is the set of
# clusters still published.
prune_stale() {
	local dry_run=$1 keep=" $* " files file hc
	files=$(ssh_remote_root "ls -1 ${DNSMASQ_DIR}/hosted-*.conf" 2>/dev/null) || files=""
	for file in ${files}; do
		hc=${file##*/hosted-}
		hc=${hc%.conf}
		case ${keep} in
		*" ${hc} "*) continue ;;
		esac
		remote_read "${file}" | awk 'NR == 1' | grep -qxF "${MARKER}" || continue
		if [ "${dry_run}" = "1" ]; then
			log "would remove ${file} (no ClusterOrder for ${hc})"
			continue
		fi
		log "removing ${file} (no ClusterOrder for ${hc})"
		ssh_remote_root "rm -f $(printf '%q' "${file}")" ||
			warn "could not remove ${file}"
	done
}

# Publish the same names into the clone network's dnsmasq.
#
# libvirt declares the hub zone as the network's DHCP domain, so it writes
# local=/<hub zone>/ into that dnsmasq: the instance is authoritative for the zone
# and forwards none of it. A name therefore only answers there if the network
# definition holds it, and the NetworkManager drop-in above does not. virsh
# net-update rewrites the network's addn-hosts file and reloads dnsmasq, which is
# the only live way to add a name without restarting the network the hub runs on.
# Entries under the hosted zones that nothing wants any more are removed; an entry
# that also carries a name outside those zones is left alone, because libvirt can
# only add and delete a whole host element.
sync_network_hosts() {
	local dry_run=$1 desired=$2 net="test-infra-net-${CLUSTER_NAME}"
	local zones
	zones=$(hosted_zones | tr '\n' ' ')
	[ -n "${zones// /}" ] || return 0
	ssh_remote_root "env DRY_RUN=$(printf '%q' "${dry_run}") NETWORK=$(printf '%q' "${net}") \
ZONES=$(printf '%q' "${zones}") DESIRED=$(printf '%q' "${desired}") python3 -" <<'PY'
import os
import subprocess
import sys
import xml.etree.ElementTree as ET

net = os.environ["NETWORK"]
zones = os.environ.get("ZONES", "").split()
dry = os.environ.get("DRY_RUN", "") == "1"
desired = {}
for line in os.environ.get("DESIRED", "").splitlines():
    fields = line.split()
    if len(fields) == 2:
        desired[fields[1]] = fields[0]


def owned(name):
    return any(name == zone or name.endswith("." + zone) for zone in zones)


def virsh(*args):
    return subprocess.run(
        ["virsh", "-c", "qemu:///system", *args], capture_output=True, text=True
    )


def host_element(names, address):
    body = "".join("<hostname>%s</hostname>" % name for name in names)
    return "<host ip='%s'>%s</host>" % (address, body)


dump = virsh("net-dumpxml", net)
if dump.returncode != 0:
    sys.stderr.write(dump.stderr.strip() + "\n")
    sys.exit(1)

live = {}
for host in ET.fromstring(dump.stdout).iter("host"):
    address = host.get("ip") or ""
    names = [(name.text or "").strip() for name in host.iter("hostname")]
    if address:
        live.setdefault(address, []).extend(names)

want = {}
for name, address in desired.items():
    want.setdefault(address, []).append(name)
for names in want.values():
    names.sort()

changed = 0


def replace(address, live_names, want_names):
    if live_names:
        result = virsh(
            "net-update", net, "delete", "dns-host", host_element(live_names, address), "--live"
        )
        if result.returncode != 0:
            sys.stderr.write(result.stderr.strip() + "\n")
            return
    if want_names:
        result = virsh(
            "net-update", net, "add", "dns-host", host_element(want_names, address), "--live"
        )
        if result.returncode != 0:
            sys.stderr.write(result.stderr.strip() + "\n")
            return
    print(
        "%s in %s: %s -> %s"
        % (
            "would set" if dry else "set",
            net,
            address,
            " ".join(want_names) or "(none)",
        )
    )


for address in sorted(set(live) | set(want)):
    live_names = live.get(address, [])
    want_names = want.get(address, [])
    if not want_names and not live_names:
        continue
    if not want_names and len([n for n in live_names if owned(n)]) != len(live_names):
        # libvirt adds and deletes a whole host element, so an entry that also
        # carries a name outside the hosted zones is left alone.
        continue
    if sorted(live_names) == want_names:
        continue
    changed += 1
    if dry:
        print(
            "would replace %s in %s: %s -> %s"
            % (address, net, " ".join(live_names) or "(none)", " ".join(want_names) or "(none)")
        )
        continue
    replace(address, live_names, want_names)

sys.exit(0)
PY
}

# One pass: publish every hosted order's records, then prune what died.
publish_once() {
	local dry_run=$1 prune=$2 orders order order_ns hc hc_ns records conf current
	local desired changed="" kept="" apps domain addr names net_names=""
	local -a published=()
	orders=$(hosted_orders)
	if [ -z "${orders}" ]; then
		log "no ClusterOrder owns a hosted cluster yet"
	fi
	while IFS=$'\t' read -r order order_ns hc hc_ns; do
		[ -n "${hc:-}" ] || continue
		kept="${kept} ${hc}"
		names=$(order_names "${order_ns}" "${order}" "${hc}" "${hc_ns}") || names=""
		if [ -n "${names}" ]; then
			net_names="${net_names}${names}"$'\n'
		fi
		records=$(order_records "${order_ns}" "${order}" "${hc}" "${hc_ns}") || records=""
		if [ -z "${records}" ]; then
			log "${hc}: no API address or worker yet, nothing to publish"
			continue
		fi
		conf="${DNSMASQ_DIR}/hosted-${hc}.conf"
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
		# Both API names are single addresses dnsmasq has to answer with exactly,
		# so they are checked. The apps name is too, but only once the order
		# published an ingress endpoint: a worker-based apps record is a set of
		# addresses, one per router, that no single-address check can carry.
		while read -r api; do
			[ -n "${api}" ] || continue
			domain=${api#address=/}
			domain=${domain%%/*}
			addr=${api##*/}
			published+=("${domain} ${addr}")
		done < <(printf '%s\n' "${records}" | grep '^address=/api' || true)
		apps=$(printf '%s\n' "${records}" | grep -c '^address=/.apps' || true)
		if [ "${apps}" = "1" ]; then
			api=$(printf '%s\n' "${records}" | grep '^address=/.apps')
			domain=${api#address=/}
			domain=${domain%%/*}
			addr=${api##*/}
			# The wildcard is probed through a name it has to answer.
			published+=("default-router${domain} ${addr}")
		fi
	done <<<"${orders}"
	sync_network_hosts "${dry_run}" "${net_names}" ||
		warn "could not publish the hosted names in the clone network's dnsmasq"
	if [ "${prune}" = "1" ]; then
		prune_stale "${dry_run}" "${kept}"
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
	local dry_run="" watch="" prune=1 interval=${HOSTED_DNS_INTERVAL}
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
	if [ "${dry_run}" = "1" ]; then
		log "would let hub CoreDNS forward $(hosted_zones | tr '\n' ' ')to the host dnsmasq"
	else
		# shellcheck disable=SC2046 # zone names never contain whitespace
		ensure_hub_dns_zone_forward $(hosted_zones)
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
