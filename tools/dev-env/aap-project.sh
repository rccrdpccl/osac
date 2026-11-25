#!/usr/bin/env bash
# shellcheck shell=bash
#
# aap-project.sh — serve this worktree as the AAP config-as-code project.
#
# Usage: tools/dev-env/aap-project.sh [--archive FILE] [--force] [--delete] [--from-skaffold]
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
# changed one atomically replaces the file on the persistent volume. The server
# runs the osac-aap artifact from ARTIFACTS_FILE, which the node has already
# cached for the bootstrap job, so this pulls nothing new.
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
# --archive FILE republishes an existing archive instead of packing the worktree.
# --force uploads even when the archive is current (make osac-dev-aap-project
# FORCE=1). --delete removes the server and volume; osac-dev-delete does that
# for you.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

# Direct invocations have no Makefile exporting the tag file.
: "${ARTIFACTS_FILE:=${HOME}/.cache/osac-dev/builds.json}"

# The caller captures this script's stdout, so progress goes to stderr.
log() { printf '>> %s\n' "$*" >&2; }

readonly SRV_NAME="osac-dev-aap-project"
readonly SRV_PORT="8080"
# The default StorageClass provisions this volume. OpenShift's restricted SCC
# supplies the pod's fsGroup, so no privileged init container is needed.
readonly SRV_DIR="/archive"
readonly ARCHIVE_NAME="osac-aap.tar.gz"

archive_local=""
archive_sum=""

usage() {
	cat <<'EOF'
Usage: tools/dev-env/aap-project.sh [--archive FILE] [--force] [--delete] [--from-skaffold]

Pack osac-aap/ from this worktree, serve it in the cluster, and print the URL to
hand to aap.configAsCode.projectArchiveUri. The AAP config-as-code project then
reads the tree the execution environment was built from instead of a branch,
which is what keeps the bootstrap job's playbook paths resolvable.

The server is a Deployment, Service, and PVC named osac-dev-aap-project in NS.
It requires a default StorageClass and runs the osac-aap image recorded in
ARTIFACTS_FILE, so run osac-dev-prep first.

--from-skaffold is for the build hook in skaffold.yaml: it adds nothing but
OSAC_DEV_AAP_PROJECT_SERVE=1 to the run, skips the work when that is unset, and
lets a missing image tag be a warning.
--archive FILE publishes a previously built archive without packing the worktree.
--force uploads even when the archive has not changed
(shortcut: make osac-dev-aap-project FORCE=1).
--delete removes the Deployment, Service, and PVC.
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
	log "packed $(du -h "${archive_local}" | cut -f1) of osac-aap/"
}

# The pod cannot be Ready on first publication until it has an archive. Exclude
# terminating pods, pods with the wrong image, and the legacy /tmp publisher.
server_pod() {
	local kubectl=$1 image=$2
	"${kubectl}" -n "${NS}" get pod --request-timeout=10s \
		-l "app.kubernetes.io/name=${SRV_NAME}" \
		--field-selector status.phase=Running -o json 2>/dev/null |
		python3 -c '
import json, sys

image, claim = sys.argv[1:]
pods = [
    pod for pod in json.load(sys.stdin)["items"]
    if not pod["metadata"].get("deletionTimestamp")
    and any(container["name"] == "archive" and container["image"] == image
            for container in pod["spec"]["containers"])
    and any(volume.get("persistentVolumeClaim", {}).get("claimName") == claim
            for volume in pod["spec"].get("volumes", []))
    and any(status["name"] == "archive" and "running" in status.get("state", {})
            for status in pod.get("status", {}).get("containerStatuses", []))
]
if pods:
    print(max(pods, key=lambda pod: pod["metadata"]["creationTimestamp"])["metadata"]["name"])
' "${image}" "${SRV_NAME}" 2>/dev/null || true
}

ensure_server() {
	local kubectl=$1 image=$2
	log "applying archive server ${NS}/${SRV_NAME}"
	"${kubectl}" apply -f - >&2 <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${SRV_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: osac-dev
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
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
  strategy:
    type: Recreate
    rollingUpdate: null
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
      volumes:
        - name: project-archive
          persistentVolumeClaim:
            claimName: ${SRV_NAME}
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
          volumeMounts:
            - name: project-archive
              mountPath: ${SRV_DIR}
          readinessProbe:
            exec:
              command:
                - /usr/bin/python3
                - -c
                - >-
                  import urllib.request;
                  urllib.request.urlopen(urllib.request.Request(
                  "http://127.0.0.1:${SRV_PORT}/${ARCHIVE_NAME}", method="HEAD"), timeout=2).close()
            periodSeconds: 5
            timeoutSeconds: 3
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
}

# Compare by hash and only replace the served name after the full archive has
# been written to the same volume and verified. A failed upload leaves the
# preceding archive available to AAP.
upload_archive() {
	local kubectl=$1 image=$2 pod served url deadline
	deadline=$((SECONDS + 300))
	while :; do
		pod=$(server_pod "${kubectl}" "${image}")
		[ -z "${pod}" ] || break
		[ "${SECONDS}" -lt "${deadline}" ] || die "no running ${SRV_NAME} pod with its archive volume in ${NS}"
		sleep 2
	done
	served=$("${kubectl}" -n "${NS}" exec "${pod}" -- \
		sha256sum "${SRV_DIR}/${ARCHIVE_NAME}" 2>/dev/null | cut -d' ' -f1) || served=""
	if [ "${OSAC_DEV_FORCE}" != "1" ] && [ "${served}" = "${archive_sum}" ]; then
		log "${pod} already serves this archive"
	else
		log "uploading $(basename "${archive_local}") to ${NS}/${pod}"
		# The variables in the quoted script belong to the container's shell.
		# shellcheck disable=SC2016
		"${kubectl}" -n "${NS}" exec -i "${pod}" -- sh -eu -c '
			tmp=$(mktemp "$1/.upload.XXXXXX")
			trap '\''rm -f -- "$tmp"'\'' EXIT
			cat >"$tmp"
			printf "%s  %s\n" "$3" "$tmp" | sha256sum --check --status
			mv -f -- "$tmp" "$1/$2"
		' sh "${SRV_DIR}" "${ARCHIVE_NAME}" "${archive_sum}" <"${archive_local}" ||
			die "failed to upload and verify the archive in ${NS}/${pod}"
	fi
	url="http://127.0.0.1:${SRV_PORT}/${ARCHIVE_NAME}"
	"${kubectl}" -n "${NS}" exec "${pod}" -- python3 -c \
		'import sys, urllib.request; print("serving", urllib.request.urlopen(urllib.request.Request(sys.argv[1], method="HEAD"), timeout=10).status)' \
		"${url}" >&2 ||
		die "the archive server does not answer ${url}"
	"${kubectl}" -n "${NS}" rollout status deployment/"${SRV_NAME}" --timeout=300s >&2
}

remove_server() {
	local kubectl=$1
	log "removing archive server ${NS}/${SRV_NAME}"
	"${kubectl}" -n "${NS}" delete deployment "${SRV_NAME}" \
		--ignore-not-found >/dev/null
	"${kubectl}" -n "${NS}" delete service "${SRV_NAME}" \
		--ignore-not-found >/dev/null
	"${kubectl}" -n "${NS}" delete persistentvolumeclaim "${SRV_NAME}" \
		--ignore-not-found --timeout=120s >/dev/null
}

main() {
	local delete=0 from_skaffold=0 soft="" kubectl kubeconfig image prebuilt=""

	while [ $# -gt 0 ]; do
		case $1 in
		-f | --force) OSAC_DEV_FORCE=1 ;;
		--archive)
			[ "$#" -ge 2 ] && [ -n "$2" ] || die '--archive requires a file path'
			prebuilt=$2
			shift
			;;
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

	require_user_context
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
	if [ -n "${prebuilt}" ]; then
		archive_local=$(expand_path "${prebuilt}")
		[ -f "${archive_local}" ] && [ -s "${archive_local}" ] ||
			die "missing or empty archive: ${archive_local}"
	else
		pack_archive
	fi
	archive_sum=$(sha256sum -- "${archive_local}" | cut -d' ' -f1)
	ensure_server "${kubectl}" "${image}"
	upload_archive "${kubectl}" "${image}"
	printf 'http://%s.%s.svc:%s/%s\n' \
		"${SRV_NAME}" "${NS}" "${SRV_PORT}" "${ARCHIVE_NAME}"
}

main "$@"
