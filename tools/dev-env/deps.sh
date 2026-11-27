#!/usr/bin/env bash
# shellcheck shell=bash
#
# deps.sh — install the OSAC prerequisites (osac-deps + osac-infra) on the hub.
#
# Usage: tools/dev-env/deps.sh [--force] [--repair-lvms]
#
# Phase 1 of the installer deployment guide: the prerequisite operators
# (cert-manager, AAP, LVMS, MetalLB, CNV, MCE via OLM) followed by the shared
# infrastructure (ClusterIssuer, trust bundle, Keycloak, LVMCluster,
# HyperConverged, MetalLB pool, credentials). Wraps the supported installer
# entry point:
#
#   make -C osac-installer install-infra PLATFORM=... PROFILE=... NS=...
#
# Skipped entirely when both Helm releases are already deployed at the in-tree
# chart version (charts/osac-deps/Chart.yaml, charts/osac-infra/Chart.yaml).
# A release in any state other than `deployed` (failed, pending-upgrade from an
# interrupted run) always reinstalls.
# That test only looks at the chart version, so a values-only change (a
# different PROFILE, a flipped toggle in values/<profile>/infra.yaml) is not
# detected yet: use --force, or FORCE=1 through the Makefile.
#
# Like cluster-tool full-regression CI, the default full-ci install on a clone
# selects its second disk (/dev/sdb) for LVMS. Netris uses a different bus and
# retains the profile's /dev/vdb default. Adopted hubs and explicit infra
# overrides keep their own configuration. An earlier failed clone install
# needs --repair-lvms before Helm: the LVMS hook skips an existing class.
#
# Helm validates every template up front, so this phase must succeed before
# `install-osac` (phase 2) can run.
#
# Inputs (defaults in common.sh / the installer Makefile):
#   OSAC_DEV_HUB_KUBECONFIG  kubeconfig of the hub, else ~/.kube/<CLUSTER_NAME>
#   PLATFORM=openshift PROFILE=full-ci NS=osac
#   HELM=helm
#
# The hub API must resolve; run tools/dev-env/setup.sh (make osac-dev-setup)
# first when it does not.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

usage() {
	cat <<'EOF'
Usage: tools/dev-env/deps.sh [--force] [--repair-lvms]

Install the OSAC prerequisites on the hub through the installer wrapper:

  make -C osac-installer install-infra PLATFORM=openshift PROFILE=<profile> NS=<ns>

Skipped when the osac-deps and osac-infra releases are already deployed at the
in-tree chart version. A release that is not `deployed` (failed,
pending-upgrade) always reinstalls. Only the chart version is compared, so
values-only changes (PROFILE, toggles in values/<profile>/infra.yaml) are not
detected: --force reinstalls anyway (shortcut: make osac-dev-deps FORCE=1).

On an OpenShift full-ci cluster-tool clone, use /dev/sdb as in full-regression
CI. --repair-lvms fixes the old failed /dev/vdb selector in place and lets
LVMS initialize the verified spare /dev/sdb before retrying the install
(shortcut: make osac-dev-deps REPAIR_LVMS=1). Adopted hubs and custom
INFRA_VALUES_EXTRA or INFRA_HELM_ARGS are excluded from this behavior.

Safe to re-run (helm upgrade --install). Phase 2 (`install-osac`) runs only
after this phase succeeds.

Inputs (defaults in common.sh / the installer Makefile):
  OSAC_DEV_HUB_KUBECONFIG  kubeconfig of the hub, else ~/.kube/<CLUSTER_NAME>
  OSAC_INSTALLER=osac-installer
  PLATFORM=openshift  PROFILE=full-ci  NS=osac  HELM=helm

Requires the hub API to resolve: run tools/dev-env/setup.sh (make osac-dev-setup)
first when it does not.
EOF
}

# Phase 1 releases as "<release>:<chart dir>:<namespace>"; install-infra creates
# both in their own namespaces regardless of NS.
phase1_releases() {
	local installer
	installer=$(installer_dir)
	printf '%s\n' \
		"osac-deps:${installer}/charts/osac-deps:osac-deps" \
		"osac-infra:${installer}/charts/osac-infra:osac-infra"
}

chart_version() {
	awk '/^version:/ { print $2; exit }' "$1/Chart.yaml" 2>/dev/null | tr -d '"'
}

# "<chart version> <status>" of an installed release, empty when it is absent.
# awk reads all input so pipefail stays quiet (no head/exit early).
installed_release() {
	local json version status
	json=$("${HELM}" get metadata "$1" --namespace "$2" -o json 2>/dev/null) || return 0
	version=$(printf '%s' "${json}" | tr ',' '\n' |
		awk -F'"' '/"version":/ && !found { found = 1; print $4 }')
	status=$(printf '%s' "${json}" | tr ',' '\n' |
		awk -F'"' '/"status":/ && !found { found = 1; print $4 }')
	[ -n "${version}" ] || return 0
	printf '%s %s\n' "${version}" "${status:-unknown}"
}

# True only when every phase 1 release is deployed at the in-tree version.
phase1_up_to_date() {
	local entry release chart ns intree installed version status stale=0
	while IFS=: read -r release chart ns; do
		intree=$(chart_version "${chart}")
		if [ -z "${intree}" ]; then
			warn "cannot read the in-tree chart version of ${chart}"
			return 1
		fi
		installed=$(installed_release "${release}" "${ns}")
		version=${installed%% *}
		status=${installed#* }
		if [ "${version}" = "${intree}" ] && [ "${status}" = "deployed" ]; then
			log "${release} (ns ${ns}): ${version} deployed, matches in-tree ${intree}"
		else
			log "${release} (ns ${ns}): ${installed:-not installed}, in-tree ${intree} -> install needed"
			stale=1
		fi
	done <<<"$(phase1_releases)"
	[ "${stale}" = "0" ]
}

uses_clone_lvms_defaults() {
	[[ ${PLATFORM} == openshift && ${PROFILE} == full-ci &&
		-z ${OSAC_DEV_HUB_KUBECONFIG} && -z ${INFRA_VALUES_EXTRA:-} &&
		-z ${INFRA_HELM_ARGS:-} ]]
}

# Match the exact attached per-clone overlay, not just the name of a disk on
# the hypervisor or an arbitrary guest block device.
check_clone_lvms_disk() {
	local vm=$1 command devices disk expected
	[[ -n ${REMOTE_HOST} ]] || die 'set REMOTE_HOST or SERVER_NAME to locate the cluster-tool clone'
	printf -v command 'LC_ALL=C LIBVIRT_DEFAULT_URI=qemu:///system virsh domblklist %q --details' "${vm}"
	devices=$(ssh_remote_root "${command}") || die "cannot inspect disks for clone ${vm}"
	disk=$(awk '$1 == "file" && $2 == "disk" && $3 == "sdb" { print $4 }' <<<"${devices}")
	expected=${CLUSTER_TOOL_DATA%/}/overlays/${CLUSTER_NAME}-disk-1.qcow2
	[[ ${disk} == "${expected}" ]] || die "${vm}: expected ${expected} at sdb for LVMS"
}

repair_clone_lvms() {
	local vm=$1 cluster=$2 nodes report patch
	shift 2
	local -a lvms=("$@")
	nodes=$("${lvms[@]}" get nodes -o json) || die 'cannot inspect hub nodes'
	jq -e --arg vm "${vm}" '[.items[].metadata.name] == [$vm]' <<<"${nodes}" >/dev/null ||
		die "expected a single hub node named ${vm}; not changing LVMS"
	report=$("${lvms[@]}" get lvmvolumegroupnodestatus.lvm.topolvm.io "${vm}" -o json) ||
		die "cannot inspect LVMS device discovery on ${vm}"
	# LVMS must see the spare disk and reject it only because of the old
	# allowlist, not because it has partitions, signatures or other uses.
	jq -e 'any(.spec.nodeStatus[]?; .name == "vg1" and .status == "Failed" and
		any(.excluded[]?; .name == "/dev/sdb" and .reasons ==
			["/dev/sdb is not part of the device selector or could not be resolved via symlink resolution"]))' \
		<<<"${report}" >/dev/null ||
		die 'LVMS has not confirmed that /dev/sdb is excluded only by the old allowlist; not changing LVMS'

	# Abort if the inspected LVMCluster changed before the patch. Never force
	# wipe devices or replace the StorageClass, LVMCluster, or any PVC.
	patch=$(jq -ec '.metadata.resourceVersion | strings | select(length > 0) | [
		{op:"test",path:"/metadata/resourceVersion",value:.},
		{op:"replace",path:"/spec/storage/deviceClasses/0/deviceSelector/optionalPaths",value:["/dev/sdb"]}
	]' <<<"${cluster}") || die 'cannot guard LVMS repair without the LVMCluster resourceVersion'
	log "repairing the failed LVMS selector on ${vm}; LVMS will initialize /dev/sdb"
	"${lvms[@]}" patch lvmclusters.lvm.topolvm.io lvms-cluster --type=json -p "${patch}" ||
		die 'LVMS patch rejected; re-check the cluster before retrying'
	"${lvms[@]}" wait lvmclusters.lvm.topolvm.io/lvms-cluster --for=condition=VolumeGroupsReady --timeout=10m ||
		die 'LVMS did not reach VolumeGroupsReady; inspect lvms-cluster and the vg-manager logs before retrying'
}

check_clone_lvms() {
	local repair=$1 vm="test-infra-cluster-${CLUSTER_NAME}-master-0" kubectl crd cluster=
	kubectl=$(kubectl_bin)
	[[ -n ${kubectl} ]] || die 'kubectl or oc is required to inspect LVMS'
	command -v jq >/dev/null || die 'jq is required to inspect LVMS'
	check_clone_lvms_disk "${vm}"
	local -a lvms=("${kubectl}" -n openshift-storage)
	crd=$("${lvms[@]}" get crd lvmclusters.lvm.topolvm.io --ignore-not-found -o name) ||
		die 'cannot check for the LVMS API'
	if [[ -n ${crd} ]]; then
		cluster=$("${lvms[@]}" get lvmclusters.lvm.topolvm.io lvms-cluster --ignore-not-found -o json) ||
			die 'cannot inspect lvms-cluster'
	fi
	if [[ -n ${cluster} ]] && jq -e '.spec.storage.deviceClasses as $classes |
		.status.state == "Failed" and ($classes | length) == 1 and $classes[0].name == "vg1" and
		$classes[0].deviceSelector == {optionalPaths:["/dev/vdb"]}' <<<"${cluster}" >/dev/null; then
		[[ ${repair} == 1 ]] || die "${vm}: LVMS expects /dev/vdb but this clone uses /dev/sdb.
       Rerun tools/dev-env/deps.sh --repair-lvms (or make osac-dev-deps REPAIR_LVMS=1)
       with the same clone settings to let LVMS initialize the spare disk."
		repair_clone_lvms "${vm}" "${cluster}" "${lvms[@]}"
	elif [[ ${repair} == 1 ]]; then
		die 'repair requires an existing failed lvms-cluster with only /dev/vdb configured for vg1'
	fi
}

main() {
	local repair_lvms=0
	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) OSAC_DEV_FORCE=1 ;;
		--repair-lvms) repair_lvms=1 ;;
		-h | --help)
			usage
			return 0
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	require_user_context

	local installer kubeconfig zone
	installer=$(installer_dir)
	[ -d "${installer}" ] || die "installer directory ${installer} not found"
	command -v "${HELM}" >/dev/null 2>&1 || die "${HELM} not found in PATH"

	kubeconfig=$(hub_kubeconfig)
	[ -f "${kubeconfig}" ] ||
		die "hub kubeconfig ${kubeconfig} not found; set OSAC_DEV_HUB_KUBECONFIG"

	zone=$(hub_zone)
	[ -n "${zone}" ] ||
		die "cannot derive the hub zone from ${kubeconfig};
       set OSAC_DEV_HUB_KUBECONFIG or CLUSTER_DOMAIN"
	getent hosts "api.${zone}" >/dev/null 2>&1 ||
		die "api.${zone} does not resolve; run: make osac-dev-setup"
	export KUBECONFIG="${kubeconfig}"

	if [[ ${repair_lvms} == 1 ]] && ! uses_clone_lvms_defaults; then
		die '--repair-lvms is only for OpenShift full-ci cluster-tool clones without explicit infra overrides'
	fi
	if [[ ${repair_lvms} == 0 && ${OSAC_DEV_FORCE} != 1 ]] && phase1_up_to_date; then
		log "prerequisites already at the in-tree chart version, skipping osac-deps + osac-infra (FORCE=1 to reinstall)"
		return 0
	fi
	if [ "${OSAC_DEV_FORCE}" = "1" ]; then
		log "FORCE=1: installing osac-deps + osac-infra regardless of installed versions"
	fi

	local -a infra_args=()
	if uses_clone_lvms_defaults; then
		check_clone_lvms "${repair_lvms}"
		# Same override as osac-test-infra's full-ci-infra.yaml for the
		# cluster-tool full-regression workflow (not the Netris VM).
		infra_args+=('INFRA_VALUES_EXTRA=--set lvms.deviceSelector.optionalPaths={/dev/sdb}')
	fi
	log "installing OSAC prerequisites: PROFILE=${PROFILE} NS=${NS} KUBECONFIG=${kubeconfig}"
	exec make -C "${installer}" install-infra \
		PLATFORM="${PLATFORM}" PROFILE="${PROFILE}" NS="${NS}" KUBECONFIG="${kubeconfig}" \
		"${infra_args[@]}"
}

main "$@"
