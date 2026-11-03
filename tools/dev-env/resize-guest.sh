#!/usr/bin/env bash
# shellcheck shell=bash
#
# resize-guest.sh — grow the hub node's root partition and filesystem.
#
# Usage: resize-guest.sh <target-bytes>
#
# Runs on the node itself, inside the host mount and pid namespaces, started by
# tools/dev-env/resize.sh. Not meant to be run by hand: it changes the partition
# table of the running system.
#
# Growing a disk is two independent layers, and this is the second one. The
# block device is already larger than the root partition when this runs, so all
# that is left is growpart and xfs_growfs. Both are no-ops once the root
# filesystem fills the disk, so re-running is free.

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

target=${1:?usage: resize-guest.sh <target-bytes>}

# /sysroot is the real root filesystem: ostree keeps / read-only and mounts the
# writable root here, which is also what kubelet measures for nodefs/imagefs.
source=$(findmnt -no SOURCE /sysroot) || source=""
[ -n "${source}" ] || {
	printf 'error: /sysroot is not mounted\n' >&2
	exit 1
}
case ${source} in
/dev/*) ;;
*)
	printf 'error: /sysroot is on %s, not a block device\n' "${source}" >&2
	exit 1
	;;
esac

name=$(basename "${source}")
disk=$(lsblk -no PKNAME "${source}" | head -1)
[ -n "${disk}" ] || {
	printf 'error: cannot find the disk behind %s\n' "${source}" >&2
	exit 1
}
number=$(cat "/sys/class/block/${name}/partition" 2>/dev/null) || number=""
[ -n "${number}" ] || {
	printf 'error: cannot find the partition number of %s\n' "${source}" >&2
	exit 1
}

device=/dev/${disk}
size=$(blockdev --getsize64 "${device}")
printf 'device %s is %s bytes, target %s bytes\n' "${device}" "${size}" "${target}"
[ "${size}" -ge "${target}" ] || {
	printf 'error: %s is smaller than the target; grow the disk on the host first\n' \
		"${device}" >&2
	exit 1
}

printf 'before: %s\n' "$(df -h /sysroot | tail -1)"

# growpart exits 1 with NOCHANGE when the partition already fills the device.
status=0
output=$(growpart "${device}" "${number}" 2>&1) || status=$?
printf '%s\n' "${output}"
if [ "${status}" -ne 0 ] && ! printf '%s' "${output}" | grep -q NOCHANGE; then
	printf 'error: growpart %s %s failed (rc=%s)\n' "${device}" "${number}" "${status}" >&2
	exit 1
fi

# xfs_growfs needs a writable mount. Leaving /sysroot read-write is harmless,
# but remount it read-only when nothing holds it busy, as ostree left it.
mount -o remount,rw /sysroot
xfs_growfs /sysroot
mount -o remount,ro /sysroot 2>/dev/null ||
	printf 'note: /sysroot left read-write (mount point busy)\n'

printf 'after:  %s\n' "$(df -h /sysroot | tail -1)"
