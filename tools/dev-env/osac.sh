#!/usr/bin/env bash
# shellcheck shell=bash
#
# osac.sh — install or upgrade the OSAC instance (Helm release `osac`), split
# into preparation and deployment so each half can be re-run on its own.
#
# Usage: tools/dev-env/osac.sh [--force] [--license FILE] [COMMAND] [ARGS...]
#
#   COMMAND  prep     prepare everything the deployment needs, then build and
#                     push every image: namespace, AAP license Secret, chart
#                     dependencies, `skaffold build` writing the image tags to
#                     ARTIFACTS_FILE
#            deploy   `skaffold deploy` with the tags recorded by prep, then
#                     Helm waits for the rollout (no build, no push)
#            dev      the watch loop: build, deploy, then rebuild and redeploy
#                     on every source change (`skaffold dev`, cleanup off)
#            delete   uninstall the release
#            render   print the rendered manifests (debugging)
#            diagnose print Skaffold's resolved configuration
#   ARGS     appended verbatim to the Skaffold command line
#
# The pipeline itself is the repository-root `skaffold.yaml`: seven images built
# by each component's own Makefile (osac-operator, fulfillment-service,
# bare-metal-fulfillment-operator, metering-service, metering-echo-adapter,
# osac-ui, osac-aap) and one Helm release, `osac`, deployed from
# osac-installer/charts/osac with values/full-ci/instance.yaml.
#
# prep adds what Skaffold cannot derive by itself, mirroring the parts of
# `make -C osac-installer install-osac` that happen before `helm` runs:
#
#   * namespace            created when absent
#   * AAP license          `config-as-code-manifest-ig` from AAP_LICENSE_FILE,
#                          re-uploaded only when the file's checksum changed
#   * chart dependencies   osac-installer/charts/osac/charts rebuilt from the
#                          local file:// subcharts, so a subchart template edit
#                          reaches the cluster on the next deploy
#
# deploy adds the cluster domain (read from the live cluster into
# OSAC_CLUSTER_DOMAIN, which skaffold.yaml templates every hostname from) and
# replays the recorded image tags, so it never touches a build.
#
# Both exec skaffold with `--default-repo` set to IMAGE_PREFIX, so no in-cluster
# registry is involved: every image is pushed straight to quay.io/<you> (podman
# login quay.io first) and pulled from there by the hub.
#
# Pulling needs no extra pull secret, but only as long as those registries are
# readable anonymously: the hub carries the Red Hat pull secret, whose quay.io
# token only covers openshift-release-dev, and quay creates a repository as
# private on its first push. deploy therefore probes every recorded tag
# anonymously and warns -- before Helm waits -- when one is not public.
#
# Images are built through the component Makefiles -- `image-build` plus
# `image-push`, or `execution-environment-build`/`-push` for osac-aap -- because
# those own the build flags. osac-aap therefore needs uv and network access, and
# it is by far the slowest artifact: Skaffold's artifact cache keeps unchanged
# ones out of the rebuild, and dropping it from skaffold.yaml is the quickest
# way to iterate on the Go services.
#
# Inputs (defaults in common.sh):
#   OSAC_DEV_HUB_KUBECONFIG  kubeconfig of the hub, else ~/.kube/<CLUSTER_NAME>
#   NS=osac                  namespace and Helm release namespace
#   PROFILE=full-ci          profile whose values/ directory holds license.zip
#   IMAGE_PREFIX             registry namespace, default quay.io/rh_ee_rpiccoli
#   AAP_LICENSE_FILE         AAP subscription manifest, else
#                            osac-installer/values/<profile>/license.zip
#   ARTIFACTS_FILE           image tags written by prep, default
#                            ~/.cache/osac-dev/builds.json
#   SKAFFOLD=skaffold  HELM=helm
#
# Re-run with --force (make osac-dev-prep FORCE=1) to re-upload the license and
# rebuild the chart dependencies even when they look current. FORCE does not
# bypass Skaffold's build cache: pass --cache-artifacts=false through ARGS.
#
# Run `make osac-dev` first: the hub must exist, resolve, and carry the
# osac-deps + osac-infra prerequisites that `helm upgrade` of the osac chart
# depends on (CRDs, Keycloak, PostgreSQL).

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

: "${SKAFFOLD:=skaffold}"
: "${IMAGE_PREFIX:=quay.io/rh_ee_rpiccoli}"
: "${AAP_LICENSE_FILE:=}"
: "${ARTIFACTS_FILE:=${XDG_CACHE_HOME:-${HOME}/.cache}/osac-dev/builds.json}"

LICENSE_SECRET=config-as-code-manifest-ig
LICENSE_ANNOTATION='osac\.openshift\.io/license-sha256'

usage() {
	cat <<'EOF'
Usage: tools/dev-env/osac.sh [--force] [--license FILE] [COMMAND] [ARGS...]

Install or upgrade the OSAC instance (Helm release `osac`), split in two:

  prep     create the namespace, upload the AAP license, rebuild the chart
           dependencies, then build and push every image. Skaffold's cache
           skips images whose inputs did not change, so re-running is cheap.
           Records the resulting image tags in ARTIFACTS_FILE.
  deploy   `skaffold deploy` with those recorded tags, then Helm waits for the
           rollout. Does not build or push anything.

COMMAND  (default: prep)
  prep | deploy   as above
  dev             the watch loop: initial build + deploy, then rebuild and
                  redeploy on change (`skaffold dev --cleanup=false`, so leaving
                  the loop keeps OSAC running)
  delete          uninstall the release (osac-deps/osac-infra stay)
  render          print the rendered manifests
  diagnose        print Skaffold's resolved configuration
ARGS              appended verbatim to the Skaffold command line

Images are pushed to IMAGE_PREFIX (quay.io/rh_ee_rpiccoli by default) instead
of an in-cluster registry: podman login quay.io once, then the hub pulls from
there.

Inputs (defaults in common.sh):
  OSAC_DEV_HUB_KUBECONFIG  kubeconfig of the hub, else ~/.kube/<CLUSTER_NAME>
  NS=osac  PROFILE=full-ci  IMAGE_PREFIX  AAP_LICENSE_FILE  ARTIFACTS_FILE
  SKAFFOLD=skaffold  HELM=helm

--force / -f    re-upload the license and rebuild the chart dependencies
--license FILE  AAP subscription manifest (else values/<profile>/license.zip)

Run `make osac-dev` first: it boots or adopts the hub, routes its names here
and on REMOTE_HOST, installs osac-deps + osac-infra, and emulates the virtual
BareMetalHosts the CaaS service needs.
EOF
}

# The hub API answers on the kubeconfig we are about to hand to Helm and
# Skaffold.
hub_api_reachable() {
	local kubectl=$1 kubeconfig=$2
	"${kubectl}" --kubeconfig "${kubeconfig}" get --raw /readyz \
		--request-timeout=5s >/dev/null 2>&1
}

ensure_namespace() {
	local kubectl=$1 ns=$2
	"${kubectl}" create namespace "${ns}" --dry-run=client -o yaml |
		"${kubectl}" apply -f - >/dev/null
	log "namespace ${ns} present"
}

# Upload the AAP subscription manifest only when its content changed: a Secret
# update makes the AAP operator re-read the manifest and restart the bootstrap
# job, which is slow and pointless on an unchanged file.
ensure_license_secret() {
	local kubectl=$1 ns=$2 file=$3 sum current
	sum=$(sha256sum "${file}" | awk '{ print $1 }')
	current=$("${kubectl}" get secret "${LICENSE_SECRET}" -n "${ns}" \
		-o jsonpath="{.metadata.annotations.${LICENSE_ANNOTATION}}" 2>/dev/null) || current=""
	if [ "${OSAC_DEV_FORCE}" != "1" ] && [ "${current}" = "${sum}" ]; then
		log "AAP license in ${ns}/${LICENSE_SECRET} is current, skipping upload"
		return 0
	fi
	log "uploading AAP license ${file} to ${ns}/${LICENSE_SECRET}"
	"${kubectl}" create secret generic "${LICENSE_SECRET}" \
		--from-file=license.zip="${file}" -n "${ns}" \
		--dry-run=client -o yaml |
		"${kubectl}" apply --server-side -f - >/dev/null
	"${kubectl}" label secret "${LICENSE_SECRET}" \
		osac.openshift.io/project=osac-aap -n "${ns}" --overwrite >/dev/null
	"${kubectl}" annotate secret "${LICENSE_SECRET}" \
		"osac.openshift.io/license-sha256=${sum}" -n "${ns}" --overwrite >/dev/null
}

license_secret_present() {
	local kubectl=$1 ns=$2
	"${kubectl}" get secret "${LICENSE_SECRET}" -n "${ns}" >/dev/null 2>&1
}

# A prep that never finished leaves {"builds":null} behind: the file exists, so
# a -f test alone hands an empty artifact list to Skaffold, which fails with
# "no tag provided for image [x]" instead of naming the missing prep.
artifacts_have_tags() {
	local artifacts=$1
	grep -q '"imageName"' "${artifacts}"
}

# Helm 4 applies server-side by default, and the AAP operator takes field
# ownership of app.kubernetes.io/managed-by on the osac-aap CR, so every upgrade
# after the first install conflicts. Helm 4 is the only release with
# --force-conflicts, so gate the flag on the major version exactly like
# osac-installer/Makefile does, and let skaffold.yaml decide through a profile.
enable_helm4_conflict_overrides() {
	local major
	major=$({ "${HELM}" version --short 2>/dev/null || true; } |
		sed -nE 's/^v([0-9]+).*/\1/p')
	[ "${major}" = "4" ] || return 0
	export OSAC_DEV_HELM_FORCE_CONFLICTS=1
}

# The hub pulls with the Red Hat pull secret only, whose quay.io token is scoped
# to openshift-release-dev. Our own images are pulled anonymously, so a quay
# repository created by the first push -- private by default -- reaches the
# cluster only after Helm has waited 40 minutes for it. An unauthenticated
# registry query separates public from private before anything is deployed.
check_image_pullability() {
	local artifacts=$1 refs ref repo code failed=0
	command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
	refs=$(python3 - "${artifacts}" <<-'EOF' 2>/dev/null
		import json, sys
		for build in json.load(open(sys.argv[1])).get("builds", []):
		    print(build.get("tag") or build.get("imageName", ""))
	EOF
	) || return 0
	while read -r ref; do
		case ${ref} in
		quay.io/*) ;;
		*) continue ;;
		esac
		repo=${ref#quay.io/}
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
			"https://quay.io/v2/${repo%%:*}/tags/list") || code=000
		[ "${code}" = "200" ] && continue
		failed=1
		warn "${ref} is not publicly pullable (quay.io returned ${code})"
	done <<<"${refs}"
	if [ "${failed}" = "1" ]; then
		warn "the hub has the Red Hat pull secret only; either make these"
		warn "repositories public in quay.io, or add your credentials to the"
		warn "cluster-wide pull secret (openshift-config/pull-secret)"
	fi
}

# The osac chart depends on the sibling components through local file:// charts,
# which Helm copies into charts/. Rebuild them on every deploy: editing a
# subchart template (osac-operator/charts/..., bare-metal-fulfillment-operator/
# charts/...) only reaches the cluster when the copy is refreshed first.
ensure_chart_dependencies() {
	local chart=$1
	log "rebuilding chart dependencies in ${chart}/charts from the local subcharts"
	"${HELM}" --repository-config /dev/null dependency build "${chart}" >/dev/null
}

# The same values `install-osac` derives from the live cluster; skaffold.yaml
# templates every domain-derived hostname from them.
read_cluster_domain() {
	local kubectl=$1 domain
	domain=$("${kubectl}" get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null) ||
		domain=""
	[ -n "${domain}" ] || return 1
	printf '%s\n' "${domain}"
}

main() {
	local command="" kubeconfig kubectl installer chart domain needs_cluster=0 needs_domain=0

	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) OSAC_DEV_FORCE=1 ;;
		--license)
			[ $# -ge 2 ] || die "--license needs a file argument"
			AAP_LICENSE_FILE=$2
			shift
			;;
		-h | --help)
			usage
			return 0
			;;
		-*) die "unknown argument: $1 (try --help)" ;;
		*)
			command=$1
			shift
			break
			;;
		esac
		shift
	done
	: "${command:=prep}"
	case ${command} in
	prepare | build) command=prep ;;
	apply) command=deploy ;;
	watch) command=dev ;;
	prep | deploy | dev | delete | render | diagnose) ;;
	*) die "unknown command: ${command} (try --help)" ;;
	esac

	require_non_root
	command -v "${SKAFFOLD}" >/dev/null 2>&1 ||
		die "${SKAFFOLD} not found in PATH (install skaffold v2)"
	command -v "${HELM}" >/dev/null 2>&1 || die "${HELM} not found in PATH"
	[ "${PLATFORM}" = "openshift" ] ||
		die "skaffold.yaml deploys the OpenShift profile (PLATFORM=${PLATFORM})"
	installer=$(installer_dir)
	chart="${installer}/charts/osac"
	[ -d "${chart}" ] || die "chart directory ${chart} not found"

	kubeconfig=$(hub_kubeconfig)
	kubectl=$(kubectl_bin)
	[ -n "${kubectl}" ] || die "neither kubectl nor oc found in PATH"
	enable_helm4_conflict_overrides

	# prep/deploy/dev/delete act on the cluster; render and diagnose do not.
	case ${command} in
	prep | deploy | dev | delete) needs_cluster=1 ;;
	esac
	case ${command} in
	deploy | dev | delete | render) needs_domain=1 ;;
	esac

	if [ "${needs_cluster}" = "1" ]; then
		[ -f "${kubeconfig}" ] ||
			die "hub kubeconfig ${kubeconfig} not found; set OSAC_DEV_HUB_KUBECONFIG"
		hub_api_reachable "${kubectl}" "${kubeconfig}" ||
			die "the hub API at ${kubeconfig} does not answer;
       run 'make osac-dev' first, and 'make osac-dev-dns' when the name does not resolve"
	fi
	# Helm, Skaffold and the domain lookup all read KUBECONFIG.
	if [ -f "${kubeconfig}" ]; then
		export KUBECONFIG="${kubeconfig}"
	fi

	domain=""
	if [ "${needs_domain}" = "1" ]; then
		domain=$(read_cluster_domain "${kubectl}") || domain=""
		if [ -z "${domain}" ]; then
			[ "${command}" = "render" ] ||
				die "cannot read the cluster domain (${kubectl} get ingresses.config/cluster)"
			warn "cannot read the cluster domain; the rendered hostnames will be empty"
		fi
	fi

	case ${command} in
	prep | dev)
		[ -n "${AAP_LICENSE_FILE}" ] ||
			AAP_LICENSE_FILE="${installer}/values/${PROFILE}/license.zip"
		# Refuse before touching the cluster: a missing manifest would only
		# surface later, as an AAP bootstrap job stuck without a license.
		[ -f "${AAP_LICENSE_FILE}" ] ||
			die "AAP license ${AAP_LICENSE_FILE} not found;
       set AAP_LICENSE_FILE=/path/to/license.zip (or make osac-dev-prep AAP_LICENSE_FILE=...)"
		ensure_namespace "${kubectl}" "${NS}"
		ensure_license_secret "${kubectl}" "${NS}" "${AAP_LICENSE_FILE}"
		ensure_chart_dependencies "${chart}"
		;;
	deploy)
		[ -f "${ARTIFACTS_FILE}" ] ||
			die "no image tags in ${ARTIFACTS_FILE}; run 'make osac-dev-prep' first"
		artifacts_have_tags "${ARTIFACTS_FILE}" ||
			die "${ARTIFACTS_FILE} holds no image tags; run 'make osac-dev-prep' first"
		license_secret_present "${kubectl}" "${NS}" ||
			die "AAP license Secret ${NS}/${LICENSE_SECRET} is missing; run 'make osac-dev-prep' first"
		check_image_pullability "${ARTIFACTS_FILE}"
		ensure_chart_dependencies "${chart}"
		;;
	render) ensure_chart_dependencies "${chart}" ;;
	esac

	export OSAC_NAMESPACE="${NS}"
	export OSAC_CLUSTER_DOMAIN="${domain}"
	export IMAGE_PREFIX

	local -a args
	case ${command} in
	prep)
		mkdir -p "$(dirname "${ARTIFACTS_FILE}")"
		args=(build --file-output "${ARTIFACTS_FILE}")
		;;
	deploy)
		args=(deploy --build-artifacts "${ARTIFACTS_FILE}")
		;;
	dev)
		args=(dev --cleanup=false)
		;;
	render)
		args=(render --digest-source=tag)
		;;
	*) args=("${command}") ;;
	esac
	args+=(--filename "${REPO_ROOT}/skaffold.yaml")
	[ "${command}" = "diagnose" ] || args+=("--default-repo=${IMAGE_PREFIX}")
	args+=("$@")

	if [ "${command}" != "diagnose" ]; then
		log "skaffold ${args[0]} -> ${IMAGE_PREFIX}, release osac in ${NS}"
	fi
	cd "${REPO_ROOT}"
	exec "${SKAFFOLD}" "${args[@]}"
}

main "$@"
