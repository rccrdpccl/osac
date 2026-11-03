#!/usr/bin/env bash
# shellcheck shell=bash
#
# deps.sh — install the OSAC prerequisites (osac-deps + osac-infra) on the hub.
#
# Usage: tools/dev-env/deps.sh [--force]
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
Usage: tools/dev-env/deps.sh [--force]

Install the OSAC prerequisites on the hub through the installer wrapper:

  make -C osac-installer install-infra PLATFORM=openshift PROFILE=<profile> NS=<ns>

Skipped when the osac-deps and osac-infra releases are already deployed at the
in-tree chart version. A release that is not `deployed` (failed,
pending-upgrade) always reinstalls. Only the chart version is compared, so
values-only changes (PROFILE, toggles in values/<profile>/infra.yaml) are not
detected: --force reinstalls anyway (shortcut: make osac-dev-deps FORCE=1).

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

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) OSAC_DEV_FORCE=1 ;;
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

	if [ "${OSAC_DEV_FORCE}" != "1" ] && phase1_up_to_date; then
		log "prerequisites already at the in-tree chart version, skipping osac-deps + osac-infra (FORCE=1 to reinstall)"
		return 0
	fi
	if [ "${OSAC_DEV_FORCE}" = "1" ]; then
		log "FORCE=1: installing osac-deps + osac-infra regardless of installed versions"
	fi

	log "installing OSAC prerequisites: PROFILE=${PROFILE} NS=${NS} KUBECONFIG=${kubeconfig}"
	exec make -C "${installer}" install-infra \
		PLATFORM="${PLATFORM}" PROFILE="${PROFILE}" NS="${NS}" KUBECONFIG="${kubeconfig}"
}

main "$@"
