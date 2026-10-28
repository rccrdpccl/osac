#!/usr/bin/env bash
# Converge both SNO clone disks to at least 200 GiB, before installing workloads.
# OSAC_DEV_DISK_TARGET may increase (never decrease) that minimum. No disk shrinks.
#
# REMOTE_HOST selects the target: unset or `localhost` runs virsh on this
# machine, anything else runs it on a remote cluster-tool host over root SSH.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$SCRIPT_DIR/osac-dev-target.sh"
REMOTE_HOST=${REMOTE_HOST:-}
DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
OSAC_DEV_DISK_TARGET=${OSAC_DEV_DISK_TARGET:-200G}
OSAC_DEV_KUBECONFIG=${OSAC_DEV_KUBECONFIG:-$HOME/.kube/${DEV_ENV_NAME}-dev.kubeconfig}
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }
osac_dev_target_init
[[ "$DEV_ENV_NAME" =~ ^[a-z0-9]{1,4}$ ]] || fail 'invalid DEV_ENV_NAME'
[[ "$OSAC_DEV_DISK_TARGET" =~ ^[1-9][0-9]{0,6}[GM]$ ]] || fail 'OSAC_DEV_DISK_TARGET must be <number>G or <number>M'
[[ -f "$OSAC_DEV_KUBECONFIG" ]] || fail "kubeconfig not found at $OSAC_DEV_KUBECONFIG"
for command in oc; do
    command -v "$command" >/dev/null || fail "required command '$command' not found"
done
if osac_dev_is_remote; then
    osac_dev_require_transport
fi
export KUBECONFIG="$OSAC_DEV_KUBECONFIG"
target_num=${OSAC_DEV_DISK_TARGET%?}
target_bytes=$((target_num * 1024 * 1024))
[[ "$OSAC_DEV_DISK_TARGET" != *G ]] || target_bytes=$((target_bytes * 1024))
((target_bytes >= 200 * 1024**3)) || fail 'OSAC_DEV_DISK_TARGET must be at least 200 GiB'
# virsh needs root on whichever machine owns libvirt.
osac_dev_require_root

node=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
[[ "$node" == "test-infra-cluster-${DEV_ENV_NAME}-dev-master-0" ]] || fail 'kubeconfig node does not match the selected SNO clone'
# Do not hide SSH/virsh errors behind process substitution.
disks=$(osac_dev_host_run "virsh domblklist '$node'") || fail 'could not list SNO disks'
mapfile -t disk_lines < <(awk '/\.qcow2$/ { print $1, $2 }' <<< "$disks")
((${#disk_lines[@]} == 2)) || fail "expected exactly two qcow2 disks on $node"
for line in "${disk_lines[@]}"; do
    dev=${line%% *}
    path=${line#* }
    [[ "$dev" =~ ^[sv]d[a-z]+$ && "$path" =~ ^/[a-zA-Z0-9/_.-]+$ ]] || fail 'unexpected disk target or path'
    disk_info=$(osac_dev_host_run "virsh domblkinfo '$node' '$path'") || fail "could not inspect $path"
    capacity=$(awk '/^Capacity:/ {print $2}' <<< "$disk_info")
    [[ "$capacity" =~ ^[0-9]+$ ]] || fail "could not read capacity of $path"
    if ((capacity >= target_bytes)); then
        info "$dev ($path) already at $((capacity / 1024**3))G; skipping"
    else
        info "growing $dev ($path) to $OSAC_DEV_DISK_TARGET"
        osac_dev_host_run "virsh blockresize '$node' '$path' '$OSAC_DEV_DISK_TARGET'" || fail "resize failed: $path"
    fi
done
root_dev="/dev/${disk_lines[0]%% *}"
lvm_dev="/dev/${disk_lines[1]%% *}"
# oc debug doesn't forward stdin. Carry the script encoded, with ONE chroot.
script_b64=$(base64 -w0 <<'GUEST'
set -euo pipefail
root_dev=$1
lvm_dev=$2
target_bytes=$3
root_source=$(findmnt -n -o SOURCE /var)
[[ ${root_source%%\[*} == "${root_dev}4" ]] || {
    echo 'refusing to grow an unexpected root partition' >&2; exit 1;
}
for dev in "$root_dev" "$lvm_dev"; do
    for ((attempt = 0; attempt < 20; attempt++)); do
        size=$(blockdev --getsize64 "$dev")
        ((size < target_bytes)) || break
        sleep 1
    done
    ((size >= target_bytes)) || { echo "guest did not observe resized $dev" >&2; exit 1; }
done
# growpart exits 1 for NOCHANGE, not just real errors. Preserve other failures.
if command -v growpart >/dev/null; then
    if output=$(growpart "$root_dev" 4 2>&1); then
        printf '%s\n' "$output"
    elif [[ "$output" != NOCHANGE:* ]]; then
        printf '%s\n' "$output" >&2; exit 1
    fi
else
    # RHCOS has util-linux but may lack cloud-utils. Only grow the final
    # partition; retain its start/type/UUID and refresh the kernel's size.
    last=$(sfdisk --dump "$root_dev" | awk '/^\/dev\// {name=$1} END {print name}')
    [[ "$last" == "${root_dev}4" ]] || { echo 'root is not the last partition' >&2; exit 1; }
    printf ', +\n' | sfdisk --no-reread --force -N 4 "$root_dev"
    partx --update --nr 4 "$root_dev"
fi
xfs_growfs /var >/dev/null
if pvs "$lvm_dev" >/dev/null 2>&1; then
    pvresize "$lvm_dev" >/dev/null
    free=$(vgs --noheadings --units b --nosuffix -o vg_free vg1 | tr -d ' ')
    if [[ "$free" =~ ^[0-9]+([.][0-9]+)?$ ]] && (( ${free%%.*} > 0 )); then
        lvextend -l +100%FREE vg1/thin-pool-1 >/dev/null
    fi
fi
echo 'guest grow complete'
GUEST
)
out=$(oc debug "node/$node" -- chroot /host bash -c \
    "printf %s '$script_b64' | base64 -d | bash -s -- '$root_dev' '$lvm_dev' '$target_bytes'" 2>&1) || fail "guest-side grow failed: $out"
printf '%s\n' "$out"
info 'storage growth complete'
