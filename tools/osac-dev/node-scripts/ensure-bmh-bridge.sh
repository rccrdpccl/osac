#!/usr/bin/env bash
set -euo pipefail
nic=$1
bridge=$2

bridge_ipv4() { ip -4 -o addr show dev "$bridge" 2>/dev/null | awk '{print $4}' | head -1; }
nic_enslaved() { ip link show "$nic" 2>/dev/null | grep -q "master $bridge"; }
nic_has_ipv4() { ip -4 -o addr show dev "$nic" 2>/dev/null | grep -q .; }

# Evaluate the bridge configuration; sets state_ok (0/1) and state_reason.
bridge_state() {
    state_ok=1
    state_reason=
    if ! ip link show "$bridge" &>/dev/null; then
        state_ok=0
        state_reason="bridge $bridge does not exist"
    elif ! nic_enslaved; then
        state_ok=0
        state_reason="$nic is not enslaved to $bridge"
    elif nic_has_ipv4; then
        state_ok=0
        state_reason="$nic still carries its own IPv4 address"
    elif [[ -z "$(bridge_ipv4)" ]]; then
        state_ok=0
        state_reason="$bridge has no IPv4 address"
    fi
}

bridge_state
if [[ "$state_ok" == 1 ]]; then
    echo "node bridge $bridge already healthy over $nic"
    echo "BRIDGE_IPV4=$(bridge_ipv4 | cut -d/ -f1)"
    exit 0
fi
echo "node bridge needs convergence: $state_reason"

# --- detect NetworkManager --------------------------------------------------
use_nm=0
if command -v nmcli >/dev/null 2>&1 && nmcli device show "$nic" >/dev/null 2>&1; then
    nm_state=$(nmcli -g GENERAL.STATE device show "$nic" 2>/dev/null) || nm_state=
    if [[ "$nm_state" != *unmanaged* ]]; then
        use_nm=1
    fi
fi

if [[ "$use_nm" == 1 ]]; then
    # NetworkManager owns the NIC. Converge on an NM-owned bridge so
    # renewals happen on the bridge and can never steal the uplink.

    # Collect foreign ports (VM taps) on the bridge first: they must
    # survive both a bridge recreation and NM taking the device over --
    # NM detaches interfaces it does not know as its own slaves when it
    # activates the bridge connection, even on a bridge it merely adopted.
    ports=()
    if ip link show "$bridge" &>/dev/null; then
        while IFS= read -r p; do
            if [[ -n "$p" && "$p" != "$nic" ]]; then
                ports+=("$p")
            fi
        done < <(ls "/sys/class/net/$bridge/brif" 2>/dev/null || true)
        # An unmanaged externally created bridge cannot be activated on;
        # delete it and let NM recreate it (collected ports are re-attached
        # below). A bridge NM already manages -- e.g. through an
        # auto-created profile -- is kept and taken over in place.
        bridge_mgmt=$(nmcli -g GENERAL.STATE device show "$bridge" 2>/dev/null) || bridge_mgmt=
        if [[ "$bridge_mgmt" == *unmanaged* ]]; then
            ip link del "$bridge"
        fi
    fi

    nic_mac=$(cat "/sys/class/net/$nic/address")
    if ! nmcli con show "$bridge" &>/dev/null; then
        nmcli con add type bridge ifname "$bridge" con-name "$bridge"
    fi

    # Copy the NIC connection's IPv4 identity onto the bridge: the same MAC
    # (a DHCP server keyed on MAC re-issues the same address) and the same
    # addressing, so DHCP and static profiles both survive the move.
    v4_method=auto
    nic_con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
        | awk -F: -v dev="$nic" '$2 == dev {print $1; exit}') || nic_con=
    v4_args=()
    if [[ -n "$nic_con" ]]; then
        m=$(nmcli -g ipv4.method con show "$nic_con" 2>/dev/null) || m=
        if [[ "$m" == manual || "$m" == disabled ]]; then
            v4_method=$m
        fi
        for prop in ipv4.addresses ipv4.gateway ipv4.dns; do
            val=$(nmcli -g "$prop" con show "$nic_con" 2>/dev/null) || val=
            if [[ -n "$val" ]]; then
                v4_args+=("$prop" "$val")
            fi
        done
    fi
    nmcli con mod "$bridge" bridge.mac-address "$nic_mac" \
        connection.autoconnect yes ipv6.method auto \
        ipv4.method "$v4_method" "${v4_args[@]}"

    # The NIC becomes a bridge port owned by its own connection profile.
    slave_con="$bridge-$nic"
    if ! nmcli con show "$slave_con" &>/dev/null; then
        nmcli con add type bridge-slave ifname "$nic" master "$bridge" \
            con-name "$slave_con"
    fi
    nmcli con mod "$slave_con" connection.autoconnect yes

    # Demote every connection that is not ours on either device: the
    # NIC's standalone profile (whose renewal re-asserts the NIC and steals
    # the uplink) and any foreign profile active on the bridge device
    # (e.g. an NM auto-created one). The profiles themselves are kept for
    # a manual revert, but nothing can re-assert them behind our backs.
    for target_dev in "$bridge" "$nic"; do
        while IFS= read -r c; do
            if [[ -n "$c" && "$c" != "$bridge" && "$c" != "$slave_con" ]]; then
                nmcli con mod "$c" connection.autoconnect no 2>/dev/null || true
                nmcli con down "$c" 2>/dev/null || true
            fi
        done < <(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
            | awk -F: -v dev="$target_dev" '$2 == dev {print $1}')
    done

    nmcli con up "$bridge" >/dev/null
    if ! nic_enslaved; then
        nmcli con up "$slave_con" >/dev/null
    fi
    # nmcli may report a controller as activated while it is still waiting
    # for ports. Default bridge STP takes about 30s before forwarding, then
    # DHCP needs its own budget (45s on RHCOS). Do not disable STP or declare
    # failure after 20s while NetworkManager is still converging normally.
    bridge_wait=120
    echo "waiting up to ${bridge_wait}s for $bridge uplink and IPv4 (including STP and DHCP)"
    for ((attempt = 0; attempt < bridge_wait; attempt++)); do
        bridge_state
        if [[ "$state_ok" == 1 ]]; then
            break
        fi
        sleep 1
    done

    # Re-attach preserved VM tap ports to the recreated bridge.
    for p in "${ports[@]}"; do
        if ip link show "$p" &>/dev/null; then
            ip link set "$p" master "$bridge"
        fi
    done
else
    # No NetworkManager, or it does not manage the NIC: a manual bridge is
    # stable, nothing re-asserts a profile on the NIC behind its back.
    ip link add "$bridge" type bridge 2>/dev/null || true
    ip link set "$bridge" up
    if ! nic_enslaved; then
        nic_addrs=$(ip -4 -o addr show dev "$nic" | awk '{print $4}' || true)
        if [[ -z "$nic_addrs" ]] && ! ip -4 -o addr show dev "$bridge" | grep -q .; then
            echo "ERROR: no IPv4 address on $nic or $bridge" >&2
            exit 1
        fi
        if [[ -n "$nic_addrs" ]]; then
            ip addr flush dev "$nic"
        fi
        ip link set "$nic" master "$bridge"
        for addr in $nic_addrs; do
            ip addr add "$addr" dev "$bridge" 2>/dev/null || true
        done
        ip link set "$nic" up
    fi
fi

bridge_state
if [[ "$state_ok" != 1 ]]; then
    echo "ERROR: node bridge $bridge did not converge: $state_reason" >&2
    exit 1
fi
managed_by=manual
if [[ "$use_nm" == 1 ]]; then
    managed_by=NetworkManager
fi
echo "node bridge $bridge ready over $nic (managed by: $managed_by)"
echo "BRIDGE_IPV4=$(bridge_ipv4 | cut -d/ -f1)"
