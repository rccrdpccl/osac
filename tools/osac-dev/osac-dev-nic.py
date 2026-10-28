#!/usr/bin/env python3
"""Discover a safe, addressed SNO lab NIC without changing node networking."""
import base64
import json
import ipaddress
import subprocess
import sys


INVENTORY = r"""set -euo pipefail
# OSAC_NIC_DISCOVERY: read-only inspection, no bridge or connection changes.
printf 'OSAC_NIC_links='; ip -j -d link show
printf 'OSAC_NIC_addresses='; ip -j -4 address show
printf 'OSAC_NIC_routes='; ip -j -4 route show table all
printf 'OSAC_NIC_physical=['
separator=
for device in /sys/class/net/*; do
    if [[ -e "$device/device" ]]; then
        printf '%s"%s"' "$separator" "${device##*/}"
        separator=,
    fi
done
printf ']\n'
"""


def select(data, node_ip, override=""):
    """Select exactly one eligible NIC; explicit overrides cannot bypass safety."""
    links = {link["ifname"]: link for link in data["links"]}
    ipv4 = {
        item["ifname"]: [a["local"] for a in item.get("addr_info", [])
                         if a.get("family") == "inet" and a.get("scope") == "global"]
        for item in data["addresses"]
    }
    if not any(node_ip in addresses for addresses in ipv4.values()):
        raise ValueError(f"could not locate the SNO InternalIP {node_ip} on an interface; refusing to guess")
    default_routes = [r for r in data["routes"]
                      if r.get("dst") == "default" and "dev" in r]
    node_interfaces = {name for name, addresses in ipv4.items() if node_ip in addresses}
    protected = set(node_interfaces)
    primary_route_metrics = [
        route.get("metric") or 0 for route in default_routes
        if route["dev"] in node_interfaces
    ]
    if primary_route_metrics:
        # DHCP may install a less-preferred default route on the secondary
        # lab NIC. Protect the node-IP route and any equally/more preferred
        # defaults, but allow higher-metric secondary routes to be bridged.
        primary_metric = min(primary_route_metrics)
        protected.update(
            route["dev"] for route in default_routes
            if (route.get("metric") or 0) <= primary_metric
        )
    else:
        # Without a default route tied to the node IP, keep the conservative
        # behavior rather than guessing which default route is primary.
        protected.update(route["dev"] for route in default_routes)
    # Protect slaves of a primary bridge/bond as well as the L3 device itself.
    changed = True
    while changed:
        before = set(protected)
        protected.update(name for name, link in links.items()
                         if link.get("master") in protected)
        changed = protected != before

    reasons = {}
    candidates = []
    for name, link in links.items():
        master = link.get("master")
        if name in protected:
            reason = "protected primary/default-route interface"
        elif name not in data["physical"] or link.get("link_type") != "ether":
            reason = "not a physical guest Ethernet NIC"
        elif master and master != "br-bmh":
            reason = f"already attached to {master} (not br-bmh)"
        elif not {"UP", "LOWER_UP"}.issubset(link.get("flags", [])):
            reason = "link is not up with carrier"
        elif not ipv4.get("br-bmh" if master == "br-bmh" else name):
            reason = "no global IPv4 address on NIC/existing br-bmh"
        else:
            reason = "eligible secondary lab NIC"
            candidates.append(name)
        reasons[name] = reason

    details = "; ".join(f"{name}: {reason}" for name, reason in reasons.items())
    if override:
        if override not in candidates:
            raise ValueError(f"override {override}: {reasons.get(override, 'missing interface')}. {details}")
        return override
    if len(candidates) == 1:
        return candidates[0]
    problem = "ambiguous secondary NICs" if candidates else "no safe secondary lab NIC found"
    raise ValueError(
        f"{problem}. {details}. Provide a connected, IPv4-addressed secondary lab NIC; "
        "if several exist, set OSAC_DEV_BMH_NODE_NIC to the lab NIC and retry. "
        "The lab network must provide DHCP for the BMH VMs."
    )


def main():
    nodes = json.loads(subprocess.check_output(["oc", "get", "nodes", "-o", "json"], text=True))["items"]
    if len(nodes) != 1:
        raise ValueError("NIC discovery requires exactly one SNO node")
    node = nodes[0]
    internal_ips = [a["address"] for a in node["status"]["addresses"]
                    if a["type"] == "InternalIP" and ipaddress.ip_address(a["address"]).version == 4]
    if len(internal_ips) != 1:
        raise ValueError("expected exactly one IPv4 InternalIP on the SNO node")
    node_ip = internal_ips[0]
    encoded = base64.b64encode(INVENTORY.encode()).decode()
    output = subprocess.check_output(
        ["oc", "debug", f"node/{node['metadata']['name']}", "--", "chroot", "/host", "bash", "-c",
         f"printf %s '{encoded}' | base64 -d | bash"], text=True,
    )
    data = {}
    for line in output.splitlines():
        if line.startswith("OSAC_NIC_"):
            key, value = line[len("OSAC_NIC_"):].split("=", 1)
            data[key] = json.loads(value)
    for key in ("links", "addresses", "routes", "physical"):
        if key not in data:
            raise ValueError(f"node inspection omitted {key}")
    print(select(data, node_ip, sys.argv[1] if len(sys.argv) > 1 else ""))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"osac-dev NIC discovery: {error}", file=sys.stderr)
        sys.exit(1)
