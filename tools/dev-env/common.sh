#!/usr/bin/env bash
# shellcheck shell=bash
#
# common.sh — defaults and helpers shared by the tools/dev-env scripts.
# Sourced by cluster.sh, dns.sh, and deps.sh; not meant to be run directly.
#
# Every input can be overridden through the environment (the repo root Makefile
# exports them) or, where noted, with a command line flag.
#
# REMOTE_HOST is where the hub runs. It is either an SSH target (root@host) or
# `local`, cluster-tool's own spelling, meaning the hub's libvirt VMs, haproxy,
# and dnsmasq entries all live on this machine. `local` also survives a new
# shell: it is read back from cluster-tool's servers.json like any other host.

set -euo pipefail

# cluster-tool inputs.
: "${CLUSTER_TOOL:=cluster-tool}"
: "${SERVER_NAME:=osac-dev}"
: "${REMOTE_HOST:=}"
: "${PULL_SECRET_FILE:=}"
: "${CLUSTER_TOOL_DATA:=/data/cluster-tool}"
: "${CLUSTER_TOOL_SERVERS:=${HOME}/.config/cluster-tool/servers.json}"
: "${CLUSTER_TOOL_FORCE:=}"
: "${OSAC_DEV_FORCE:=}"
: "${FLAVOR:=sno-4-22}"
: "${FLAVOR_IMAGE:=quay.io/rh-ee-ovishlit/cluster-flavors:${FLAVOR}}"
: "${CLUSTER_NAME:=osac-dev}"
# Root disk size the hub is grown to after boot (tools/dev-env/resize.sh). The
# flavors are post-install images, so a clone inherits the image's disk size
# whatever it is; 150G keeps kubelet's imagefs.available=15% threshold away.
: "${DISK_SIZE:=150G}"

# cluster-tool records where each server lives, which is the ssh target the
# scripts need. Deriving it means REMOTE_HOST survives a new shell.
if [ -z "${REMOTE_HOST}" ] && [ -f "${CLUSTER_TOOL_SERVERS}" ] &&
	command -v jq >/dev/null 2>&1; then
	REMOTE_HOST=$(jq -r --arg name "${SERVER_NAME}" '.servers[$name].host // empty' \
		"${CLUSTER_TOOL_SERVERS}" 2>/dev/null || true)
fi

# Existing hub to reuse instead of booting a cluster.
: "${OSAC_DEV_HUB_KUBECONFIG:=}"
: "${CLUSTER_DOMAIN:=}"
: "${RESOLVED_DROPIN:=/etc/systemd/resolved.conf.d/50-cluster-tool.conf}"

# osac-installer inputs for the prerequisite phase (osac-deps + osac-infra).
: "${OSAC_INSTALLER:=osac-installer}"
: "${PLATFORM:=openshift}"
: "${PROFILE:=full-ci}"
: "${NS:=osac}"
: "${HELM:=helm}"

# Image tags recorded by `osac.sh prep` and replayed by `osac.sh deploy`.
: "${ARTIFACTS_FILE:=${HOME}/.cache/osac-dev/builds.json}"

# Virtual BMH emulation (tools/shared/virtual-bmh.sh via tools/dev-env/bmh.sh).
: "${BMH_NAMESPACE:=host-inventory}"
: "${BMH_COUNT:=2}"
: "${BMH_DISK_SIZE:=150G}"
: "${SUSHY_PORT:=8000}"
: "${BMC_USERNAME:=admin}"
: "${BMC_PASSWORD:=password}"
: "${BMH_LABELS:=osac.openshift.io/host-type=default}"

DEV_ENV_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${DEV_ENV_DIR}/../.." && pwd)

# osac-installer checkout: absolute paths pass through, relative ones are
# resolved against the repository root.
installer_dir() {
	case ${OSAC_INSTALLER} in
	/*) printf '%s\n' "${OSAC_INSTALLER}" ;;
	*) printf '%s\n' "${REPO_ROOT}/${OSAC_INSTALLER}" ;;
	esac
}

log() { printf '>> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

# The scripts escalate with sudo themselves, and the local state — the hub
# kubeconfig, the image-tag cache, cluster-tool's client files — is keyed to
# $HOME. Native root is self-consistent: everything lands in /root, and
# cluster-tool (which keys its writes on SUDO_USER) agrees. Running through
# sudo from a normal user is not: sudo points $HOME at /root while
# cluster-tool writes the kubeconfig into the invoking user's home, and the
# scripts would read the wrong one. So every context is allowed except that
# one.
require_user_context() {
	if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] &&
		[ "${SUDO_USER}" != "root" ]; then
		die "run this as your normal user, or as root directly, not through sudo;
       \$HOME would point at /root while cluster-tool writes the hub kubeconfig
       into the invoking user's home"
	fi
}

# Expand a leading ~/ so file tests work on a quoted path.
expand_path() {
	case $1 in
	"~/"*) printf '%s\n' "${HOME}/${1:2}" ;;
	*) printf '%s\n' "$1" ;;
	esac
}

# True when the hub runs on this machine instead of a remote hypervisor.
# cluster-tool spells that host `local` (`--host local`), and stores it
# verbatim in servers.json, so the value survives the derivation above.
remote_is_local() {
	[ "${REMOTE_HOST}" = "local" ]
}

# Run a command on the hub's host. A real REMOTE_HOST goes over ssh; `local`
# runs in a bash here. ssh joins its arguments with spaces and hands them to
# the remote shell, so `bash -c "$*"` is the same contract, heredoc stdin
# included. Locally it runs as the invoking user, whose $HOME holds the
# kubeconfig, the sushy state, and cluster-tool's client files — use
# ssh_remote_root for hub-host work the remote side did as root.
ssh_remote() {
	if remote_is_local; then
		bash -c "$*"
	else
		ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_HOST}" "$@"
	fi
}

# The same command, but as root on the hub's host: over ssh a real REMOTE_HOST
# already runs as root, so only the local branch differs, escalating through
# sudo. Use this for libvirt, /etc, and systemctl work — the things the remote
# flow got from ssh-ing in as root — and ssh_remote for anything that must see
# the invoking user's $HOME.
ssh_remote_root() {
	if remote_is_local; then
		sudo bash -c "$*"
	else
		ssh -o BatchMode=yes -o ConnectTimeout=10 "${REMOTE_HOST}" "$@"
	fi
}

# cluster-tool command prefix. Its server half (connect, pull, boot, list,
# destroy) needs root for libvirt, haproxy, and the dnsmasq entries: remote
# hosts get that from ssh root@, so only the local branch escalates. sudo
# resets PATH, hence the resolved binary path, and cluster-tool chowns the
# state it writes under sudo back to the invoking user. An array, so `run` in
# teardown.sh can print it verbatim in a dry run.
# shellcheck disable=SC2034 # consumed by cluster.sh and teardown.sh
if remote_is_local; then
	CLUSTER_TOOL_CMD=(sudo "$(command -v "${CLUSTER_TOOL}" 2>/dev/null || true)")
else
	CLUSTER_TOOL_CMD=("${CLUSTER_TOOL}")
fi

kubectl_bin() {
	local bin
	if bin=$(command -v kubectl 2>/dev/null); then
		printf '%s\n' "${bin}"
	elif bin=$(command -v oc 2>/dev/null); then
		printf '%s\n' "${bin}"
	fi
}

# Kubeconfig of the hub: the one handed to us, else the one cluster-tool writes.
hub_kubeconfig() {
	if [ -n "${OSAC_DEV_HUB_KUBECONFIG}" ]; then
		expand_path "${OSAC_DEV_HUB_KUBECONFIG}"
	else
		printf '%s\n' "${HOME}/.kube/${CLUSTER_NAME}.kubeconfig"
	fi
}

# Hub zone: CLUSTER_DOMAIN if set, else api.<zone> from the kubeconfig's server
# URL. cluster-tool always names a clone test-infra-cluster-<name>.redhat.com,
# so the api host carries the clone name. Prints nothing when it cannot tell.
hub_zone() {
	local kubeconfig kubectl server
	if [ -n "${CLUSTER_DOMAIN}" ]; then
		printf '%s\n' "${CLUSTER_DOMAIN}"
		return 0
	fi
	kubeconfig=$(hub_kubeconfig)
	[ -f "${kubeconfig}" ] || return 0
	kubectl=$(kubectl_bin)
	[ -n "${kubectl}" ] || return 0
	server=$("${kubectl}" --kubeconfig "${kubeconfig}" config view \
		-o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) || return 0
	printf '%s\n' "${server}" |
		sed -e 's|^https://||' -e 's|^http://||' -e 's|:[0-9]*$||' -e 's|^api\.||'
}

# True when an explicitly provided hub kubeconfig parses and its API answers.
hub_ready() {
	local kubeconfig kubectl
	[ -n "${OSAC_DEV_HUB_KUBECONFIG}" ] || return 1
	kubeconfig=$(hub_kubeconfig)
	[ -f "${kubeconfig}" ] || return 1
	kubectl=$(kubectl_bin)
	[ -n "${kubectl}" ] || return 1
	"${kubectl}" --kubeconfig "${kubeconfig}" config view >/dev/null 2>&1 || return 1
	"${kubectl}" --kubeconfig "${kubeconfig}" get --raw /readyz \
		--request-timeout=5s >/dev/null 2>&1
}

# The hub API name, as the system resolver sees it.
zone_resolves() {
	getent hosts "api.$1" >/dev/null 2>&1
}

# dnsmasq (NetworkManager's instance) already answers for the zone.
dnsmasq_has_zone() {
	local answer
	answer=$(dig +short "api.$1" @127.0.0.1) || answer=""
	[ -n "${answer}" ]
}

# cluster-tool's client-side DNS plumbing is in place on this machine.
client_configured() {
	grep -qs 'dns=dnsmasq' /etc/NetworkManager/conf.d/cluster-tool-dns.conf &&
		pgrep -x dnsmasq >/dev/null
}

zone_ip() {
	getent hosts "api.$1" | awk 'NR == 1 { print $1 }'
}

# Make the hub zone reachable by name. cluster-tool writes one wildcard rule per
# clone into /etc/NetworkManager/dnsmasq.d/cluster-<name>.conf covering api,
# *.apps, and keycloak; when systemd-resolved owns /etc/resolv.conf that dnsmasq
# (127.0.0.1) is never queried, so only the hub zone is routed to it and
# per-link servers (LAN, corp split DNS) stay untouched.
ensure_zone_routed() {
	local zone=$1 dropin_dir
	command -v dig >/dev/null 2>&1 || die "dig not found in PATH (install bind-utils)"
	dnsmasq_has_zone "${zone}" ||
		die "dnsmasq has no entry for ${zone};
       run 'make osac-dev-setup' (cluster-tool setup client), then retry"
	if [ "${OSAC_DEV_FORCE}" = "1" ] && zone_resolves "${zone}"; then
		log "${zone} already resolves to $(zone_ip "${zone}"), rewriting the drop-in (forced)"
	elif zone_resolves "${zone}"; then
		log "${zone} already resolves to $(zone_ip "${zone}"), skipping DNS patch"
		return 0
	fi
	command -v systemctl >/dev/null 2>&1 || {
		warn "systemctl not found; cluster-tool's own resolver setup must handle ${zone}"
		return 0
	}
	log "sending ${zone} to 127.0.0.1 (dnsmasq) in ${RESOLVED_DROPIN}"
	dropin_dir=$(dirname "${RESOLVED_DROPIN}")
	sudo mkdir -p "${dropin_dir}"
	printf '[Resolve]\nDNS=127.0.0.1\nDomains=~%s\n' "${zone}" |
		sudo tee "${RESOLVED_DROPIN}" >/dev/null
	sudo systemctl restart systemd-resolved
	zone_resolves "${zone}" ||
		die "api.${zone} still unresolved;
       fallback: sudo systemctl disable --now systemd-resolved"
	log "${zone} resolves to $(zone_ip "${zone}")"
}

# The same rule on REMOTE_HOST. It is the hypervisor that runs the hub: haproxy
# there listens on the VM address and routes by SNI, so oc and the BMH library
# need the hub name to resolve on that machine too. cluster-tool writes this
# entry only on the machine that ran the CLI.
ensure_remote_zone_routed() {
	local zone=$1 ip conf want
	if [ -z "${REMOTE_HOST}" ]; then
		log "REMOTE_HOST unset, leaving remote DNS alone"
		return 0
	fi
	ip=$(zone_ip "${zone}")
	[ -n "${ip}" ] ||
		die "cannot resolve api.${zone} on this machine; run: make osac-dev-dns"
	conf="/etc/NetworkManager/dnsmasq.d/cluster-${CLUSTER_NAME}.conf"
	want="address=/${zone}/${ip}"
	if [ "${OSAC_DEV_FORCE}" != "1" ] &&
		ssh_remote "grep -qxF $(printf '%q' "${want}") $(printf '%q' "${conf}")" 2>/dev/null; then
		log "${zone} -> ${ip} already in ${conf} on ${REMOTE_HOST}, skipping remote DNS patch"
		return 0
	fi
	log "adding ${want} to ${conf} on ${REMOTE_HOST}"
	ssh_remote_root bash -s <<EOF
set -euo pipefail
want=$(printf '%q' "${want}")
conf=$(printf '%q' "${conf}")
mkdir -p "\$(dirname "\${conf}")"
printf '%s\n' "\${want}" >"\${conf}"
systemctl reload NetworkManager || systemctl restart NetworkManager
for attempt in 1 2 3 4 5; do
	if [ -n "\$(dig +short $(printf '%q' "api.${zone}") @127.0.0.1 | head -1)" ]; then
		exit 0
	fi
	sleep 2
done
echo "api.${zone} still does not resolve via 127.0.0.1 on this host" >&2
exit 1
EOF
	log "${zone} -> ${ip} on ${REMOTE_HOST}"
}

# Address the hub host answers DNS on: libvirt gives the network's gateway to
# the bridge, and that dnsmasq is what holds the hosted-cluster records
# hosted-dns.sh publishes. Prints nothing when it cannot tell.
host_dnsmasq_ip() {
	local xml
	xml=$(ssh_remote_root "virsh net-dumpxml test-infra-net-${CLUSTER_NAME}" 2>/dev/null) || return 0
	printf '%s\n' "${xml}" |
		sed -n "s/.*<ip [^>]*address='\([0-9.]*\)'.*/\1/p" | awk 'NR == 1'
}

# Zone the hosted clusters are published under: AAP's hosted_cluster role sets
# HOSTED_CLUSTER_BASE_DOMAIN to hosted.<hub zone>, where <hub zone> is the hub's
# ingress domain without its apps. prefix. Prints nothing when it cannot tell.
hosted_dns_zone() {
	local kubeconfig kubectl domain
	kubeconfig=$(hub_kubeconfig)
	kubectl=$(kubectl_bin)
	[ -f "${kubeconfig}" ] && [ -n "${kubectl}" ] || return 0
	domain=$(KUBECONFIG="${kubeconfig}" "${kubectl}" get ingress.config.openshift.io cluster \
		-o jsonpath='{.spec.domain}' 2>/dev/null) || domain=""
	[ -n "${domain}" ] || return 0
	printf 'hosted.%s\n' "${domain#apps.}"
}

# The hub-side half of hosted-cluster name resolution.
#
# Hub pods have to resolve api.<order>.<baseDomain> and *.apps.<order>.<baseDomain>.
# Those records exist only in the hub host's dnsmasq (hosted-dns.sh publishes
# them), and the corp resolver behind SystemResolvConf answers NXDOMAIN for them,
# so HyperShift and capi-provider cannot reach the hosted API and the order never
# leaves "Workers Joining". Delegate just the hosted zone(s) to that dnsmasq via
# spec.servers, which is zone scoped.
#
# Do not point upstreamResolvers (the global list) at the dnsmasq instead. That
# makes CoreDNS answer the search-suffix names pods try before the absolute one
# (ndots 5: postgres.<ns>.svc.cluster.local -> ...svc.cluster.local.<zone>), the
# dnsmasq wildcard cluster-tool writes for the hub zone matches those, and every
# in-cluster service name then resolves to the hypervisor instead of its
# ClusterIP: the hub loses its database and reports DeadlineExceeded.
ensure_hub_dns_zone_forward() {
	local dnsmasq_ip kubeconfig kubectl zones zone name entry entries
	local cur_count cur_zones cur_ups
	dnsmasq_ip=$(host_dnsmasq_ip) || dnsmasq_ip=""
	if [ -z "${dnsmasq_ip}" ]; then
		warn "cannot tell the hub host's dnsmasq address; left CoreDNS servers alone"
		return 0
	fi
	kubeconfig=$(hub_kubeconfig)
	kubectl=$(kubectl_bin)
	if [ ! -f "${kubeconfig}" ] || [ -z "${kubectl}" ]; then
		warn "no hub kubeconfig or kubectl; left CoreDNS servers alone"
		return 0
	fi
	zones=$(printf '%s\n' "$@" "$(hosted_dns_zone)" | sed '/^$/d' | sort -u)
	if [ -z "${zones}" ]; then
		warn "cannot tell which zone hosted clusters use; left CoreDNS servers alone"
		return 0
	fi
	cur_count=$(KUBECONFIG="${kubeconfig}" "${kubectl}" get dns.operator/default \
		-o jsonpath='{range .spec.servers[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -c .) || cur_count=0
	cur_zones=$(KUBECONFIG="${kubeconfig}" "${kubectl}" get dns.operator/default \
		-o jsonpath='{.spec.servers[*].zones[*]}' 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort -u) ||
		cur_zones=""
	cur_ups=$(KUBECONFIG="${kubeconfig}" "${kubectl}" get dns.operator/default \
		-o jsonpath='{.spec.servers[*].forwardPlugin.upstreams[*]}' 2>/dev/null |
		tr ' ' '\n' | sed '/^$/d' | sort -u) || cur_ups=""
	if [ "${cur_count}" = "$(printf '%s\n' "${zones}" | grep -c .)" ] &&
		[ "${cur_zones}" = "${zones}" ] && [ "${cur_ups}" = "${dnsmasq_ip}" ]; then
		log "hub CoreDNS already forwards $(printf '%s\n' "${zones}" | tr '\n' ' ')to ${dnsmasq_ip}"
		return 0
	fi
	log "letting hub CoreDNS forward $(printf '%s\n' "${zones}" | tr '\n' ' ')to ${dnsmasq_ip}"
	entries=""
	for zone in ${zones}; do
		name="hosted-$(printf '%s' "${zone}" | tr '.' '-')"
		name=$(printf '%s' "${name}" | cut -c1-63 | sed 's/-$//')
		entry=$(printf '{"name":"%s","zones":["%s"],"forwardPlugin":{"policy":"Sequential","upstreams":["%s"]}}' \
			"${name}" "${zone}" "${dnsmasq_ip}")
		entries="${entries:+${entries},}${entry}"
	done
	# spec.servers is this function's alone, so replace it wholesale. Appending
	# would let a half-applied earlier run leave two server blocks for one zone,
	# and CoreDNS then refuses to load the Corefile at all.
	KUBECONFIG="${kubeconfig}" "${kubectl}" patch dns.operator/default --type=merge \
		-p "$(printf '{"spec":{"servers":[%s]}}' "${entries}")" >/dev/null || {
		warn "could not patch dns.operator/default; hub pods keep the old Corefile"
		return 0
	}
	# The operator rewrites the dns-default Corefile, but a running CoreDNS keeps
	# serving the ConfigMap it read at startup, so recycle the DaemonSet pods.
	KUBECONFIG="${kubeconfig}" "${kubectl}" rollout restart ds/dns-default \
		-n openshift-dns >/dev/null 2>&1 ||
		warn "could not restart dns-default; its pods keep the old Corefile"
	KUBECONFIG="${kubeconfig}" "${kubectl}" rollout status ds/dns-default \
		-n openshift-dns --timeout=180s >/dev/null 2>&1 ||
		warn "dns-default did not roll out cleanly; check openshift-dns"
}
