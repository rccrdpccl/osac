#!/usr/bin/env bash
set -euo pipefail
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
