#!/usr/bin/env bash
# Build a frozen AAP playbook archive from the current working tree.
#
# Packages osac-aap/ (the playbook entry points and the osac.* collections
# the AAP Controller project resolves playbook-adjacent) into a tar.gz,
# base64-encodes it, and prints the encoded file's path on stdout. The path
# is meant for:
#
#   helm ... --set-file aap.configAsCode.projectArchive.data=@<path>
#
# so the AAP Controller project is created with scm_type: archive and serves
# exactly the working tree (committed or not) instead of cloning
# aap.configAsCode.projectGitUri.
#
# Heavy, runtime-irrelevant trees are excluded: vendor/ and the execution
# environment are baked into the EE image, tests/ and docs/ are not consumed
# by AAP jobs, and .venv/ is local tooling. Roles and vendored collections
# inside collections/ stay included to keep playbook-adjacent collection
# resolution identical to a git checkout.
#
# Usage: build-aap-playbooks-archive.sh [output-file]
#   output-file defaults to a mktemp path. Progress goes to stderr; only the
#   output path is printed to stdout (for $(shell) capture in the Makefile).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)

if [[ ! -d "${REPO_ROOT}/osac-aap" ]]; then
	echo "ERROR: osac-aap/ not found at ${REPO_ROOT}" >&2
	exit 1
fi

OUT=${1:-}
if [[ -z "${OUT}" ]]; then
	OUT=$(mktemp "${TMPDIR:-/tmp}/osac-aap-playbooks-XXXXXX.b64")
fi
TARBALL=$(mktemp "${TMPDIR:-/tmp}/osac-aap-playbooks-XXXXXX.tgz")
cleanup() { rm -f "${TARBALL}"; }
trap cleanup EXIT

# Anchored excludes apply to the top-level osac-aap/ member; the last two are
# unanchored so they also drop caches inside collections/.
tar -C "${REPO_ROOT}" -czf "${TARBALL}" \
	--exclude='osac-aap/.ai-bot' \
	--exclude='osac-aap/.ansible' \
	--exclude='osac-aap/.claude' \
	--exclude='osac-aap/.devcontainer' \
	--exclude='osac-aap/.pytest_cache' \
	--exclude='osac-aap/.venv' \
	--exclude='osac-aap/charts' \
	--exclude='osac-aap/context' \
	--exclude='osac-aap/docs' \
	--exclude='osac-aap/execution-environment' \
	--exclude='osac-aap/hack' \
	--exclude='osac-aap/tests' \
	--exclude='osac-aap/vendor' \
	--exclude='__pycache__' \
	--exclude='*.pyc' \
	osac-aap

base64 -w0 "${TARBALL}" > "${OUT}"

echo "Frozen AAP playbook archive: ${OUT} ($(du -h "${TARBALL}" | cut -f1) tar.gz, $(du -h "${OUT}" | cut -f1) base64)" >&2
echo "${OUT}"
