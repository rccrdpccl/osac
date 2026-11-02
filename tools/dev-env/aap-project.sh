#!/usr/bin/env bash
# shellcheck shell=bash
#
# aap-project.sh — serve this worktree as the AAP config-as-code project.
#
# Usage: tools/dev-env/aap-project.sh [--force] [--delete] [--from-skaffold]
#
# The bootstrap job creates job templates whose playbook paths have to exist in
# the controller project. That project was a git clone of an upstream branch,
# which moves independently of the images an environment builds, so the two
# drift apart. They did: e5187180c moved every networking template onto
# osac-aap/playbook_osac_network_task.yml and deleted the per-operation
# playbooks, the execution environment came from a tree that still named them,
# and every bootstrap since failed with "Playbook not found for project".
#
# This packs the repo root (osac-aap/ plus the top-level files) from the working
# tree, serves it from a small HTTP server in the cluster, and prints the URL for
# aap.configAsCode.projectArchiveUri. That value switches the project to
# scm_type=archive, so the project content is exactly the playbooks the execution
# environment carries and nothing has to be published to a branch first.
#
# Prints the URL on stdout and progress on stderr, so callers capture only the
# URL:  OSAC_DEV_AAP_PROJECT_ARCHIVE_URI=$(tools/dev-env/aap-project.sh)
#
# The served name is stable on purpose: the URL goes into the release, and
# skaffold dev re-runs that deploy on every change. The content hash decides
# whether an upload is needed, so an unchanged tree uploads nothing and a
# changed one replaces the file the pod serves. The server runs the osac-aap
# artifact from ARTIFACTS_FILE, which the node has already cached for the
# bootstrap job, so this pulls nothing new.
#
# skaffold runs this with --from-skaffold after it rebuilds the osac-aap
# artifact (see the hook in skaffold.yaml), which is exactly the moment the
# playbooks the execution environment carries can change, so a watch session
# republishes the payload with no manual step. That mode only acts when osac.sh
# asked for the archive (OSAC_DEV_AAP_PROJECT_SERVE=1), so a plain
# `skaffold build` stays a pure build, and it warns instead of failing while no
# osac-aap tag exists yet (a first prep has not written ARTIFACTS_FILE).
#
# Inputs (defaults in common.sh):
#   NS=osac               namespace of the server and of the release
#   ARTIFACTS_FILE        image tags written by osac-dev-prep, default
#                         ~/.cache/osac-dev/builds.json
#   OSAC_DEV_HUB_KUBECONFIG  kubeconfig of the hub, else ~/.kube/<CLUSTER_NAME>
#   SKAFFOLD_IMAGE        osac-aap tag Skaffold sets for its build hooks; wins
#                         over ARTIFACTS_FILE so a rebuild serves what it built
#   OSAC_DEV_AAP_PROJECT_SERVE  set to 1 by osac.sh to allow the build hook to
#                         publish the archive; anything else makes --from-skaffold
#                         a no-op
#
# --force re-applies the server and re-uploads the archive even when both look
# current (shortcut: make osac-dev-aap-project FORCE=1). --delete removes the
# server; osac-dev-delete does that for you.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

# Direct invocations have no Makefile exporting the tag file.
: "${ARTIFACTS_FILE:=${HOME}/.cache/osac-dev/builds.json}"

# The caller captures this script's stdout, so progress goes to stderr.
log() { printf '>> %s\n' "$*" >&2; }

readonly SRV_NAME="osac-dev-aap-project"
readonly SRV_PORT="8080"
# /tmp is the one place any UID can write, which keeps this pod inside the
# restricted-v2 SCC: an emptyDir would need fsGroup, and that SCC rejects it.
readonly SRV_DIR="/tmp"
readonly ARCHIVE_NAME="osac-aap.tar.gz"

archive_local=""
archive_sum=""

usage() {
	cat <<'EOF'
Usage: tools/dev-env/aap-project.sh [--force] [--delete] [--from-skaffold]

Pack osac-aap/ from this worktree, serve it in the cluster, and print the URL to
hand to aap.configAsCode.projectArchiveUri. The AAP config-as-code project then
reads the tree the execution environment was built from instead of a branch,
which is what keeps the bootstrap job's playbook paths resolvable.

The server is a Deployment plus a Service named osac-dev-aap-project in NS; it
runs the osac-aap image recorded in ARTIFACTS_FILE, so run osac-dev-prep first.

--from-skaffold is for the build hook in skaffold.yaml: it adds nothing but
OSAC_DEV_AAP_PROJECT_SERVE=1 to the run, skips the work when that is unset, and
lets a missing image tag be a warning.
--force re-applies the Deployment and re-uploads the archive even when the tree
has not changed (shortcut: make osac-dev-aap-project FORCE=1).
--delete removes the Deployment and the Service.
EOF
}

# Image reference of the osac-aap artifact, taken from the tags prep recorded.
# With $2=soft an unknown tag is an empty result instead of an error, which the
# build hook needs: it can run before --file-output has ever been written.
aap_image() {
	local artifacts=$1 soft=${2:-} image
	[ -f "${artifacts}" ] || {
		[ -n "${soft}" ] && return 0
		die "no image tags in ${artifacts}; run 'make osac-dev-prep' first"
	}
	image=$(python3 - "${artifacts}" <<-'EOF'
		import json, sys

		for build in json.load(open(sys.argv[1])).get("builds") or []:
		    if build.get("imageName") == "osac-aap":
		        print(build.get("tag") or "")
		        break
	EOF
	) || image=""
	[ -n "${image}" ] || {
		[ -n "${soft}" ] && return 0
		die "${artifacts} has no osac-aap tag; run 'make osac-dev-prep' first"
	}
	printf '%s\n' "${image}"
}

# Pack the repo root as the project: the tracked and not-ignored files of
# osac-aap/ plus the repo's top-level files. Both parts matter.
#
#   - osac-aap/ keeps its prefix because every job template names its playbook
#     that way ("osac-aap/playbook_osac_create_hosted_cluster.yml"), so the
#     project root has to be the repo root, exactly like the git project it
#     replaces. Packing osac-aap/ alone would put its contents at the project
#     root once AAP strips the single top-level directory.
#   - the top-level files are what makes the archive "a project in the archive
#     root" to AAP rather than "a project in one base directory", so nothing
#     gets stripped.
#
# The tree is staged through rsync --copy-links before it is tarred, for two
# reasons the AAP side forces:
#   - its project_archive action plugin only creates a directory when the
#     archive has a directory member, so a file list alone fails with a bare
#     FileNotFoundError on the first nested path of an empty project directory;
#   - that plugin writes every link member as an empty regular file, so the
#     role aliases under collections/ (osac_csi_driver -> osac_csi_storage)
#     have to arrive resolved rather than as links.
#
# gzip runs with -n so an unchanged tree hashes the same on every run, which is
# what makes the upload check below cheap.
pack_archive() {
	local cache_dir staging
	cache_dir=$(dirname "${ARTIFACTS_FILE}")
	mkdir -p "${cache_dir}"
	archive_local="${cache_dir}/osac-aap-project.tar.gz"
	staging=$(mktemp -d)
	log "packing osac-aap/ from ${REPO_ROOT}"
	git -C "${REPO_ROOT}" ls-files -co --exclude-standard -z -- \
		':(glob)*' ':(glob)osac-aap/**' |
		rsync -aLr --from0 --files-from=- \
			"${REPO_ROOT}/" "${staging}/"
	# Unprefixed members (osac-aap/, AGENTS.md, ...) so the archive has several
	# roots, which is what keeps AAP from stripping the top level.
	(cd "${staging}" &&
		find . -mindepth 1 -maxdepth 1 -printf '%P\0' |
		tar --null -T - -cf -) | gzip -n -9 >"${archive_local}"
	rm -rf "${staging}"
	archive_sum=$(sha256sum "${archive_local}" | cut -d' ' -f1)
	log "packed $(du -h "${archive_local}" | cut -f1) of osac-aap/"
}

# The pod currently serving the archive, if any.
server_pod() {
	local kubectl=$1
	"${kubectl}" -n "${NS}" get pod \
		-l "app.kubernetes.io/name=${SRV_NAME}" \
		--field-selector status.phase=Running \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

ensure_server() {
	local kubectl=$1 image=$2 current
	current=$("${kubectl}" -n "${NS}" get deployment "${SRV_NAME}" \
		-o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || current=""
	if [ "${OSAC_DEV_FORCE}" != "1" ] && [ "${current}" = "${image}" ] &&
		"${kubectl}" -n "${NS}" rollout status deployment/"${SRV_NAME}" \
			--timeout=10s >/dev/null 2>&1; then
		log "archive server ${NS}/${SRV_NAME} is already up with this image"
		return 0
	fi
	log "applying archive server ${NS}/${SRV_NAME}"
	"${kubectl}" apply -f - >&2 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SRV_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${SRV_NAME}
    app.kubernetes.io/part-of: osac-dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${SRV_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${SRV_NAME}
        app.kubernetes.io/part-of: osac-dev
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: archive
          image: ${image}
          command:
            - /usr/bin/python3
            - -m
            - http.server
            - "${SRV_PORT}"
            - --directory
            - "${SRV_DIR}"
          ports:
            - name: http
              containerPort: ${SRV_PORT}
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: ${SRV_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: ${SRV_NAME}
    app.kubernetes.io/part-of: osac-dev
spec:
  selector:
    app.kubernetes.io/name: ${SRV_NAME}
  ports:
    - name: http
      port: ${SRV_PORT}
      targetPort: http
EOF
	"${kubectl}" -n "${NS}" rollout status deployment/"${SRV_NAME}" \
		--timeout=300s >&2
}

# Copy the archive into the pod and prove that it is served. The pod's copy is
# compared by hash, so an unchanged tree skips the upload and a changed one
# replaces what the pod serves -- which is what keeps a watch session honest,
# since its URL never changes.
upload_archive() {
	local kubectl=$1 pod served url
	pod=$(server_pod "${kubectl}")
	[ -n "${pod}" ] || die "no running ${SRV_NAME} pod in ${NS}"
	served=$("${kubectl}" -n "${NS}" exec "${pod}" -- \
		sha256sum "${SRV_DIR}/${ARCHIVE_NAME}" 2>/dev/null | cut -d' ' -f1) || served=""
	if [ "${OSAC_DEV_FORCE}" != "1" ] && [ "${served}" = "${archive_sum}" ]; then
		log "${pod} already serves this tree"
	else
		log "uploading $(basename "${archive_local}") to ${NS}/${pod}"
		"${kubectl}" -n "${NS}" exec -i "${pod}" -- \
			sh -c 'cat > "${1}/${2}"' sh "${SRV_DIR}" "${ARCHIVE_NAME}" \
			<"${archive_local}"
	fi
	url="http://127.0.0.1:${SRV_PORT}/${ARCHIVE_NAME}"
	"${kubectl}" -n "${NS}" exec "${pod}" -- python3 -c \
		'import sys, urllib.request; print("serving", urllib.request.urlopen(sys.argv[1], timeout=10).status)' \
		"${url}" >&2 ||
		die "the archive server does not answer ${url}"
}

remove_server() {
	local kubectl=$1
	log "removing archive server ${NS}/${SRV_NAME}"
	"${kubectl}" -n "${NS}" delete deployment "${SRV_NAME}" \
		--ignore-not-found >/dev/null
	"${kubectl}" -n "${NS}" delete service "${SRV_NAME}" \
		--ignore-not-found >/dev/null
}

main() {
	local delete=0 from_skaffold=0 soft="" kubectl kubeconfig image

	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) OSAC_DEV_FORCE=1 ;;
		--delete) delete=1 ;;
		--from-skaffold) from_skaffold=1 ;;
		-h | --help)
			usage
			return 0
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done

	# The build hook must not turn `skaffold build` into a cluster mutation:
	# osac.sh sets OSAC_DEV_AAP_PROJECT_SERVE only for the commands that serve
	# this worktree as the AAP project.
	if [ "${from_skaffold}" = "1" ] &&
		[ "${OSAC_DEV_AAP_PROJECT_SERVE:-}" != "1" ]; then
		log "not publishing the archive: OSAC_DEV_AAP_PROJECT_SERVE is not 1"
		return 0
	fi
	if [ "${from_skaffold}" = "1" ]; then
		soft=1
	fi

	require_non_root
	kubectl=$(kubectl_bin)
	[ -n "${kubectl}" ] || die "neither kubectl nor oc found in PATH"
	kubeconfig=$(hub_kubeconfig)
	[ -f "${kubeconfig}" ] ||
		die "hub kubeconfig ${kubeconfig} not found; set OSAC_DEV_HUB_KUBECONFIG"
	export KUBECONFIG="${kubeconfig}"

	if [ "${delete}" = "1" ]; then
		remove_server "${kubectl}"
		return 0
	fi

	# Skaffold hands its build hooks the tag it just built, which is newer than
	# the one prep recorded and is the image the next deploy will run.
	image=${SKAFFOLD_IMAGE:-}
	[ -n "${image}" ] || image=$(aap_image "${ARTIFACTS_FILE}" "${soft}")
	if [ -z "${image}" ]; then
		log "no osac-aap image tag yet; the deploy publishes the archive"
		return 0
	fi
	pack_archive
	ensure_server "${kubectl}" "${image}"
	upload_archive "${kubectl}"
	printf 'http://%s.%s.svc:%s/%s\n' \
		"${SRV_NAME}" "${NS}" "${SRV_PORT}" "${ARCHIVE_NAME}"
}

main "$@"
