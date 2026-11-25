#!/usr/bin/env bash
# Runs as root on the libvirt host, via cluster.sh. Only the named SNO clone
# is eligible for repair; do not restart libvirt networks or change the VIP.
set -euo pipefail
export LC_ALL=C LIBVIRT_DEFAULT_URI=qemu:///system

mode=$1
vm=$2
network=$3
identity=$4

die() { printf 'error: %s: %s\n' "${vm}" "$*" >&2; exit 1; }
[[ ${mode} == check || ${mode} == repair ]] || die "invalid gateway mode: ${mode}"

# Use the clone's primary network attachment, not the current default route.
mac=$(virsh domiflist "${vm}" | awk -v net="${network}" '$2 == "network" && $3 == net {print $5}')
[[ ${mac} =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] ||
	die "expected one NIC on ${network}"
address=$(virsh net-dhcp-leases "${network}" --mac "${mac}" |
	awk -v mac="${mac}" '$3 == mac && $4 == "ipv4" {split($5, ip, "/"); print ip[1]}')
[[ ${address} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
	die "expected one IPv4 lease for ${mac} on ${network}"
[[ -r ${identity} ]] || die "cannot read the cluster-tool SSH identity; check FLAVOR and CLUSTER_TOOL_DATA"

# cluster-tool does not retain the clone's host key. Pin it across the reboot
# without changing the hypervisor's SSH configuration or trust store.
known_hosts=$(mktemp)
trap 'rm -f -- "${known_hosts}"' EXIT

guest_gateway() {
	local command
	printf -v command 'sudo -n bash -s -- %q %q %q %q' "$1" "${vm}" "${mac}" "${address}"
	timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes -o LogLevel=ERROR \
		-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${known_hosts}" \
		-o GlobalKnownHostsFile=/dev/null -i "${identity}" "core@${address}" "${command}" <<'GUEST'
set -euo pipefail
mode=$1 vm=$2 mac=$3 address=$4
die() { printf 'error: %s: %s\n' "${vm}" "$*" >&2; exit 1; }
[[ $(hostname -s) == "${vm}" ]] || die "unexpected guest hostname"

# br-ex can inherit its physical port's MAC, so match only real NICs.
uplink=
for device in /sys/class/net/*; do
	[[ -e ${device}/device ]] || continue
	read -r device_mac <"${device}/address"
	[[ ${device_mac,,} == "${mac,,}" ]] || continue
	[[ -z ${uplink} ]] || die "more than one NIC matches ${mac}"
	uplink=${device##*/}
done
[[ -n ${uplink} ]] || die "no NIC matches the libvirt MAC ${mac}"

has_primary_ip() {
	ip -o -4 addr show dev "$1" |
		awk -v want="${address}" '{split($4, ip, "/"); if (ip[1] == want) found = 1} END {exit !found}'
}

read -r boot_id </proc/sys/kernel/random/boot_id
ovs-vsctl --timeout=5 br-exists br-ex || die 'no OVN external bridge br-ex'
if [[ $(ovs-vsctl --timeout=5 iface-to-br "${uplink}" 2>/dev/null) == br-ex ]] && has_primary_ip br-ex; then
	printf 'ready %s\n' "${boot_id}"
	exit 0
fi
has_primary_ip "${uplink}" || die "${address} is not on the primary NIC ${uplink}; refusing to reconfigure"
if [[ ${mode} == check ]]; then
	printf 'br-ex does not carry %s on %s\n' "${address}" "${uplink}" >&2
	exit 3
fi

# configure-ovs.sh honors this explicit selection on boot, when it also
# discards the old generated NetworkManager OVS profiles. Restarting the
# service in place can reuse those profiles and leave the wrong NIC attached.
config=/etc/ovnk/default_bridge
[[ ! -e /etc/ovnk/extra_bridge ]] || die 'refusing to change a custom extra_bridge configuration'
if [[ -e ${config} ]]; then
	[[ $(<"${config}") == "${uplink}" ]] || die "refusing to replace ${config}"
else
	install -d -m 0755 /etc/ovnk
	printf '%s\n' "${uplink}" >"${config}"
fi
# Give ssh time to acknowledge the request before the guest goes down.
systemd-run --quiet --unit=osac-dev-gateway-reboot --on-active=5s /usr/bin/systemctl reboot
printf 'rebooting %s\n' "${boot_id}"
GUEST
}

if state=$(guest_gateway "${mode}"); then
	read -r status previous_boot <<<"${state}"
else
	if [[ $? == 3 && ${mode} == check ]]; then
		die 'rerun cluster.sh --repair-gateway to repair and reboot this clone'
	fi
	die 'gateway check or repair failed'
fi
[[ -n ${previous_boot} ]] || die 'missing guest boot ID'
case ${status} in
ready)
	printf '>> %s: br-ex is on the primary network (%s)\n' "${vm}" "${address}"
	exit 0
	;;
rebooting) [[ ${mode} == repair ]] || die 'unexpected reboot in check mode' ;;
*) die "unexpected gateway status: ${status}" ;;
esac

printf '>> %s: waiting for reboot onto the primary network (%s)\n' "${vm}" "${address}"
deadline=$((SECONDS + 600))
while ((SECONDS < deadline)); do
	sleep 5
	if state=$(guest_gateway check 2>/dev/null); then
		read -r status boot_id <<<"${state}"
		if [[ ${status} == ready && -n ${boot_id} && ${boot_id} != "${previous_boot}" ]] &&
			curl --noproxy '*' --max-time 5 -fksS "https://${address}:6443/readyz" >/dev/null 2>&1; then
			printf '>> %s: br-ex is on the primary network and the hub API is ready\n' "${vm}"
			exit 0
		fi
	fi
done
die 'timed out waiting for a new boot, br-ex on the primary network, and a ready hub API'
