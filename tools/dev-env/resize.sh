#!/usr/bin/env bash
# shellcheck shell=bash
#
# resize.sh — grow the dev cluster's root disk to DISK_SIZE.
#
# Usage: tools/dev-env/resize.sh [--size 150G] [--node NAME] [--dry-run]
#
# The cluster-tool flavors are post-install images: RHCOS is already written, so
# the partition table is fixed at whatever disk size the image was built with
# (sno-4-22 ships 93.1 GiB). cluster-tool clones without a size, so every hub
# inherits exactly that geometry. 15% of it, kubelet's imagefs.available
# eviction threshold, leaves ~14 GiB of headroom, which the OSAC images fill in
# minutes: the node goes DiskPressure, evicts the AWX task pods, and every
# AAP-driven provisioning step fails with a controller 500.
#
# Growing the disk before anything is pulled keeps that from happening. It is
# two independent layers:
#
#   1. the block device, on REMOTE_HOST: virsh blockresize on the clone overlay
#   2. the partition and filesystem, in the guest: growpart + xfs_growfs
#
# Both are idempotent, so this runs on every `make osac-dev`: the block device
# is only resized when it is smaller than the target, and the guest steps report
# NOCHANGE once the root filesystem fills the disk.
#
# The guest steps run in a privileged hostPID pod pinned to the node, entering
# the host mount and pid namespaces with nsenter. The pod tolerates every taint
# and is system-node-critical, because the interesting case is a hub that is
# already evicting under disk pressure.
#
# Inputs (defaults in common.sh):
#   DISK_SIZE=150G          target size of the hub's root disk
#   REMOTE_HOST=root@host   where the clone runs; empty skips the whole resize
#   CLUSTER_NAME=osac-dev   clone name, also the VM name's prefix
#   RESIZE_VM=...           VM to grow, default test-infra-cluster-<name>-master-0
#   RESIZE_NODE=            node to grow, default the first one
#   RESIZE_WAIT=600         seconds to wait for the hub API
#
# --size overrides DISK_SIZE, --node overrides RESIZE_NODE, and --dry-run prints
# the pod it would apply instead of touching the node.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

readonly POD_NAME="osac-dev-resize"
readonly POD_IMAGE="registry.access.redhat.com/ubi9/ubi-minimal"
# Outside NS: the pod is dev scaffolding, and teardown owns the osac namespace.
readonly POD_NAMESPACE="default"
readonly POD_TIMEOUT=180

: "${RESIZE_VM:=test-infra-cluster-${CLUSTER_NAME}-master-0}"
: "${RESIZE_NODE:=}"
: "${RESIZE_WAIT:=600}"
: "${DRY_RUN:=}"

usage() {
	cat <<'EOF'
Usage: tools/dev-env/resize.sh [--size 150G] [--node NAME] [--dry-run]

Grow the hub's root disk to DISK_SIZE: virsh blockresize on REMOTE_HOST, then
growpart and xfs_growfs in the guest. Both steps are skipped when the disk is
already that big, so re-running is free.

Inputs (defaults in common.sh):
  DISK_SIZE=150G          target size of the hub's root disk
  REMOTE_HOST=root@host   where the clone runs; empty skips the whole resize
  CLUSTER_NAME=osac-dev   clone name, also the VM name's prefix
  RESIZE_VM=...           VM to grow, default test-infra-cluster-<name>-master-0
  RESIZE_NODE=            node to grow, default the first one
  RESIZE_WAIT=600         seconds to wait for the hub API

--size overrides DISK_SIZE, --node overrides RESIZE_NODE.
EOF
}

# 150G/150GiB/1000000 -> bytes. G/Gi mean GiB, as virsh and qemu-img do.
to_bytes() {
	local value=$1 number suffix
	number=${value%%[KkMmGgTt]*}
	suffix=${value#"${number}"}
	# 150GiB and 150MB are as valid as 150Gi and 150M.
	suffix=${suffix%[Bb]}
	case ${number} in
	'' | *[!0-9]*) die "cannot parse size '${value}' (try 150G)" ;;
	esac
	case ${suffix} in
	'') printf '%s\n' "${number}" ;;
	K | k | Ki | ki) printf '%s\n' "$((number * 1024))" ;;
	M | m | Mi | mi) printf '%s\n' "$((number * 1024 * 1024))" ;;
	G | g | Gi | gi) printf '%s\n' "$((number * 1024 * 1024 * 1024))" ;;
	T | t | Ti | ti) printf '%s\n' "$((number * 1024 * 1024 * 1024 * 1024))" ;;
	*) die "cannot parse size '${value}' (try 150G)" ;;
	esac
}

# Wait for the hub API: a clone that just booted answers only after a few
# minutes, and nothing can be grown before the API server and a node exist.
wait_for_hub() {
	local kubeconfig=$1 kubectl=$2 deadline
	[ -f "${kubeconfig}" ] ||
		die "${kubeconfig} does not exist; run 'make osac-dev-cluster' first"
	if "${kubectl}" --kubeconfig "${kubeconfig}" get --raw /readyz \
		--request-timeout=5s >/dev/null 2>&1; then
		return 0
	fi
	log "waiting up to ${RESIZE_WAIT}s for the hub API in ${kubeconfig}"
	deadline=$((SECONDS + RESIZE_WAIT))
	until "${kubectl}" --kubeconfig "${kubeconfig}" get --raw /readyz \
		--request-timeout=5s >/dev/null 2>&1; do
		[ "${SECONDS}" -lt "${deadline}" ] ||
			die "the hub API in ${kubeconfig} is still not ready after ${RESIZE_WAIT}s"
		sleep 10
	done
}

resolve_node() {
	local kubectl=$1 kubeconfig=$2 node
	if [ -n "${RESIZE_NODE}" ]; then
		printf '%s\n' "${RESIZE_NODE}"
		return 0
	fi
	node=$("${kubectl}" --kubeconfig "${kubeconfig}" get nodes --no-headers \
		-o custom-columns=NAME:.metadata.name --request-timeout=30s 2>/dev/null |
		awk 'NR == 1 { print $1 }') || node=""
	[ -n "${node}" ] || die "no nodes found in ${kubeconfig}; is the hub up?"
	printf '%s\n' "${node}"
}

# Prints "<path> <virtual-size>" for the clone's first disk on REMOTE_HOST.
remote_root_disk() {
	ssh_remote bash -s <<EOF
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
# No early exit in awk: under pipefail virsh would die of SIGPIPE.
disks=\$(virsh domblklist $(printf '%q' "${RESIZE_VM}") --details |
	awk '\$2 == "disk" { print \$4 }')
path=\$(printf '%s\\n' "\${disks}" | sed -n '1p')
if [ -z "\${path}" ]; then
	printf 'no disk found for %s\\n' $(printf '%q' "${RESIZE_VM}") >&2
	exit 1
fi
# Human output on purpose: --output json repeats virtual-size for every child
# node of the backing chain, and the first one is not the disk.
size=\$(qemu-img info -U "\${path}" |
	sed -n 's/^virtual size: .*(\\([0-9]*\\) bytes).*/\\1/p')
if [ -z "\${size}" ]; then
	printf 'cannot read the virtual size of %s\\n' "\${path}" >&2
	exit 1
fi
printf '%s %s\\n' "\${path}" "\${size}"
EOF
}

# Layer 1: the block device the guest sees.
grow_block_device() {
	local target=$1 reply disk size
	reply=$(remote_root_disk) ||
		die "cannot read the disks of ${RESIZE_VM} on ${REMOTE_HOST}"
	read -r disk size <<<"${reply}"
	log "block device ${disk} on ${REMOTE_HOST} is ${size} bytes"
	if [ "${size}" -ge "${target}" ]; then
		# The guest grows the filesystem to the whole device, so a disk that is far
		# bigger than DISK_SIZE would turn this into a very long growpart.
		[ "${size}" -le $((target * 2)) ] ||
			die "${disk} is ${size} bytes, more than twice ${DISK_SIZE}; the
       filesystem would be grown to ${size} bytes. Destroy the clone, or raise
       DISK_SIZE to the size the disk really has."
		log "block device is already at least ${target} bytes, skipping blockresize"
		return 0
	fi
	if [ "${DRY_RUN}" = "1" ]; then
		log "would run: virsh blockresize --domain ${RESIZE_VM} --path ${disk} --size ${target}"
		return 0
	fi
	log "growing ${disk} to ${target} bytes"
	# The trailing B is load bearing: virsh reads a bare number as KiB.
	ssh_remote bash -s <<EOF
set -euo pipefail
export LIBVIRT_DEFAULT_URI=qemu:///system
virsh blockresize --domain $(printf '%q' "${RESIZE_VM}") \
	--path $(printf '%q' "${disk}") --size ${target}B
EOF
	# Never hand a size the guest has to trust to growpart: read it back.
	reply=$(remote_root_disk) ||
		die "cannot read the disks of ${RESIZE_VM} after blockresize"
	read -r disk size <<<"${reply}"
	[ "${size}" = "${target}" ] ||
		die "blockresize left ${disk} at ${size} bytes, expected ${target}"
}

# The guest script runs from a YAML block scalar, so it arrives verbatim: no
# shell quoting layer between this file and /bin/bash on the node.
guest_pod_manifest() {
	local node=$1 target=$2 script
	script=$(sed -e '/^$/!s/^/          /' "${script_dir}/resize-guest.sh")
	cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  labels:
    app.kubernetes.io/name: ${POD_NAME}
spec:
  nodeName: ${node}
  hostPID: true
  restartPolicy: Never
  priorityClassName: system-node-critical
  terminationGracePeriodSeconds: 0
  tolerations:
    - operator: Exists
  containers:
    - name: resize
      image: ${POD_IMAGE}
      imagePullPolicy: IfNotPresent
      securityContext:
        privileged: true
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
      command:
        - chroot
        - /host
        - /usr/bin/nsenter
        - --target
        - "1"
        - --mount
        - --pid
        - --
        - /bin/bash
        - -c
        - |-
${script}
        - resize-guest
        - "${target}"
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
EOF
}

delete_pod() {
	local kubectl=$1 kubeconfig=$2
	"${kubectl}" --kubeconfig "${kubeconfig}" -n "${POD_NAMESPACE}" delete pod \
		"${POD_NAME}" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true
}

# A run that is interrupted still leaves its pod behind, and the guest work keeps
# going in the kernel, so only the pod is cleaned up here.
POD_KUBECTL=""
POD_KUBECONFIG=""
cleanup_pod() {
	[ -n "${POD_KUBECTL}" ] || return 0
	delete_pod "${POD_KUBECTL}" "${POD_KUBECONFIG}"
}
trap cleanup_pod EXIT

# Prints the pod phase once it is terminal.
wait_for_pod() {
	local kubectl=$1 kubeconfig=$2 deadline phase
	deadline=$((SECONDS + POD_TIMEOUT))
	while :; do
		phase=$("${kubectl}" --kubeconfig "${kubeconfig}" -n "${POD_NAMESPACE}" \
			get pod "${POD_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null) || phase=""
		case ${phase} in
		Succeeded | Failed)
			printf '%s\n' "${phase}"
			return 0
			;;
		esac
		[ "${SECONDS}" -lt "${deadline}" ] ||
			die "the resize pod is still ${phase:-absent} after ${POD_TIMEOUT}s"
		sleep 2
	done
}

# Layer 2: the partition table and filesystem inside the guest.
run_guest_pod() {
	local kubectl=$1 kubeconfig=$2 node=$3 target=$4 manifest phase
	manifest=$(guest_pod_manifest "${node}" "${target}")
	if [ "${DRY_RUN}" = "1" ]; then
		log "would apply this pod to ${node}:"
		printf '%s\n' "${manifest}"
		return 0
	fi
	delete_pod "${kubectl}" "${kubeconfig}"
	printf '%s\n' "${manifest}" |
		"${kubectl}" --kubeconfig "${kubeconfig}" -n "${POD_NAMESPACE}" apply -f - >/dev/null
	POD_KUBECTL=${kubectl}
	POD_KUBECONFIG=${kubeconfig}
	phase=$(wait_for_pod "${kubectl}" "${kubeconfig}")
	"${kubectl}" --kubeconfig "${kubeconfig}" -n "${POD_NAMESPACE}" logs \
		"${POD_NAME}" 2>&1 | sed 's/^/   /'
	delete_pod "${kubectl}" "${kubeconfig}"
	POD_KUBECTL=""
	[ "${phase}" = "Succeeded" ] ||
		die "the resize pod finished ${phase} (see the log above)"
}

# Kubelet keeps the disk-pressure taint until its node status catches up, and
# after a resize underneath it that can take a long time. The cause is gone by
# now - the guest steps verified the free space - so clear the stale taint.
clear_stale_taint() {
	local kubectl=$1 kubeconfig=$2 node=$3 taint
	taint=$("${kubectl}" --kubeconfig "${kubeconfig}" get node "${node}" \
		-o jsonpath='{.spec.taints[?(@.key=="node.kubernetes.io/disk-pressure")].key}' \
		2>/dev/null) || taint=""
	[ -n "${taint}" ] || return 0
	if [ "${DRY_RUN}" = "1" ]; then
		log "would run: ${kubectl} taint node ${node} ${taint}-"
		return 0
	fi
	log "clearing a stale ${taint} taint from ${node}"
	"${kubectl}" --kubeconfig "${kubeconfig}" taint node "${node}" "${taint}-" >/dev/null
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		-s | --size)
			[ $# -ge 2 ] || die "--size needs a value, e.g. --size 150G"
			DISK_SIZE=$2
			shift
			;;
		-n | --node)
			[ $# -ge 2 ] || die "--node needs a node name"
			RESIZE_NODE=$2
			shift
			;;
		--dry-run) DRY_RUN=1 ;;
		-h | --help)
			usage
			return 0
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	require_non_root
	local target kubectl kubeconfig node
	target=$(to_bytes "${DISK_SIZE}")
	kubectl=$(kubectl_bin)
	[ -n "${kubectl}" ] || die "neither kubectl nor oc is on PATH"
	kubeconfig=$(hub_kubeconfig)
	wait_for_hub "${kubeconfig}" "${kubectl}"
	node=$(resolve_node "${kubectl}" "${kubeconfig}")
	log "growing the root disk of ${node} to ${DISK_SIZE} (${target} bytes)"
	if [ -z "${REMOTE_HOST}" ]; then
		log "REMOTE_HOST is unset, so the block device cannot be grown; skipping"
		return 0
	fi
	grow_block_device "${target}"
	run_guest_pod "${kubectl}" "${kubeconfig}" "${node}" "${target}"
	clear_stale_taint "${kubectl}" "${kubeconfig}" "${node}"
	if [ "${DRY_RUN}" = "1" ]; then
		log "dry run, nothing was changed"
	else
		log "root disk of ${node} is ready"
	fi
}

main "$@"
