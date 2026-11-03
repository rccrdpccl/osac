#!/usr/bin/env bash
# shellcheck shell=bash
#
# e2e.sh — run the pytest E2E suites against the deployed dev environment.
#
# Usage: tools/dev-env/e2e.sh --suite <suite> [--filter EXPR] [--marker EXPR]
#                             [--cli PATH] [--rebuild] [--dry-run] [-- ARGS...]
#
# <suite> is a path (tests/e2e/vmaas/sanity) or a short name (vmaas/sanity),
# which is resolved under tests/e2e/. There is no default: the suites differ by
# an order of magnitude in what they need, from tenant/project CRUD to a
# bare-metal cluster, so the caller names one.
#
# What this wires, which the tests' own defaults do not:
#
#   KUBECONFIG              the dev hub (OSAC_DEV_HUB_KUBECONFIG, else
#                           ~/.kube/<CLUSTER_NAME>)
#   OSAC_NAMESPACE          NS (osac); the tests default to osac-devel
#   OSAC_CLI_PATH           the osac CLI, built from the worktree when missing
#   OSAC_PULL_SECRET_PATH   PULL_SECRET_FILE, when it is a file
#
# Everything else keeps the tests' defaults, which already resolve from the
# cluster: the cluster domain, the fulfillment and Keycloak routes, the service
# account, the tenant users, and the VMaaS storage tier.
#
# Filtering:
#   --filter/-k EXPR   pytest -k, selects test names   (make E2E_FILTER=)
#   --marker/-m EXPR   pytest -m, selects markers      (make E2E_MARKER=)
#   -- ARGS...         appended verbatim after the selectors, e.g.
#                      `-- -x -vv --junitxml=/tmp/e2e.xml`   (make E2E_ARGS=)
#
# Every option also reads an environment variable, which is how the make target
# passes them: E2E_SUITE, E2E_FILTER, E2E_MARKER, E2E_ARGS, OSAC_CLI_PATH.
#
# Inputs (defaults in common.sh): OSAC_DEV_HUB_KUBECONFIG, CLUSTER_NAME, NS,
# PULL_SECRET_FILE, ARTIFACTS_FILE, REPO_ROOT.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "${script_dir}/common.sh"

: "${E2E_SUITE:=}"
: "${E2E_FILTER:=}"
: "${E2E_MARKER:=}"
: "${E2E_ARGS:=}"
: "${OSAC_CLI_PATH:=}"

suite=${E2E_SUITE}
filter_expr=${E2E_FILTER}
marker_expr=${E2E_MARKER}
rebuild=0
dry_run=0
declare -a extra_args=()

usage() {
	awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' \
		"${BASH_SOURCE[0]}"
	printf '\nSuites under tests/e2e/:\n'
	(cd "${REPO_ROOT}/tests/e2e" && find . -mindepth 1 -maxdepth 2 -type d \
		-not -name __pycache__ | sed 's|^\./||' | sort | sed 's/^/  /')
}

# A short name is a path under tests/e2e/, so `vmaas/sanity` and
# `tests/e2e/vmaas/sanity` both work.
resolve_suite() {
	local requested=$1 path
	case ${requested} in
	tests/*) path=${requested} ;;
	*) path="tests/e2e/${requested}" ;;
	esac
	if [ ! -e "${REPO_ROOT}/${path}" ]; then
		die "no suite at ${path}"
	fi
	printf '%s\n' "${path}"
}

# The E2E tests shell out to the osac CLI for most of what they assert, and the
# binary they get by default may be older than the API it talks to. Order:
# OSAC_CLI_PATH, then `osac` on PATH, then a build of this worktree that is
# rebuilt whenever the CLI sources are newer than it.
cli_cache_path() {
	printf '%s/osac\n' "$(dirname "$(expand_path "${ARTIFACTS_FILE}")")"
}

cli_is_stale() {
	local cli=$1
	[ -f "${cli}" ] || return 0
	[ -n "$(find "${REPO_ROOT}/fulfillment-service/cmd/osac" \
		"${REPO_ROOT}/fulfillment-service/internal" "${REPO_ROOT}/proto/gen" \
		-name '*.go' -newer "${cli}" -print -quit 2>/dev/null)" ]
}

build_cli() {
	local cli=$1
	mkdir -p "$(dirname "${cli}")"
	log "building the osac CLI -> ${cli}"
	(cd "${REPO_ROOT}/fulfillment-service" && go build -o "${cli}" ./cmd/osac) ||
		die "could not build the osac CLI; set OSAC_CLI_PATH to a working binary"
}

resolve_cli() {
	local cli
	if [ -n "${OSAC_CLI_PATH}" ]; then
		if [ ! -x "${OSAC_CLI_PATH}" ]; then
			die "OSAC_CLI_PATH=${OSAC_CLI_PATH} is not an executable"
		fi
		printf '%s\n' "${OSAC_CLI_PATH}"
		return 0
	fi
	if command -v osac >/dev/null 2>&1; then
		command -v osac
		return 0
	fi
	cli=$(cli_cache_path)
	if [ "${dry_run}" = "1" ]; then
		# Report where it would come from without spending the build.
		if cli_is_stale "${cli}"; then
			printf '%s (would build)\n' "${cli}"
		else
			printf '%s\n' "${cli}"
		fi
		return 0
	fi
	if [ "${rebuild}" = "1" ] || cli_is_stale "${cli}"; then
		build_cli "${cli}"
	fi
	printf '%s\n' "${cli}"
}

require_tools() {
	local missing=""
	local tool
	for tool in "$@"; do
		command -v "${tool}" >/dev/null 2>&1 || missing="${missing} ${tool}"
	done
	[ -z "${missing}" ] || die "missing on PATH:${missing}"
}

# The suites drive kubectl themselves, so an unreachable hub has to fail here
# rather than inside a session fixture several minutes in.
check_hub() {
	local kubeconfig=$1 kubectl
	kubectl=$(kubectl_bin) || kubectl=kubectl
	[ -f "${kubeconfig}" ] ||
		die "no kubeconfig at ${kubeconfig}; boot the hub first (make osac-dev-cluster)"
	KUBECONFIG="${kubeconfig}" "${kubectl}" version --request-timeout=10s >/dev/null 2>&1 ||
		die "cannot reach the hub API with ${kubeconfig}"
}

main() {
	local kubeconfig cli pull_secret
	require_non_root

	while [ $# -gt 0 ]; do
		case $1 in
		-h | --help)
			usage
			return 0
			;;
		--suite)
			[ $# -ge 2 ] || die "--suite needs a suite name"
			suite=$2
			shift
			;;
		--filter)
			[ $# -ge 2 ] || die "--filter needs an expression"
			filter_expr=$2
			shift
			;;
		--marker)
			[ $# -ge 2 ] || die "--marker needs an expression"
			marker_expr=$2
			shift
			;;
		--cli)
			[ $# -ge 2 ] || die "--cli needs a path"
			OSAC_CLI_PATH=$2
			shift
			;;
		--rebuild) rebuild=1 ;;
		--dry-run) dry_run=1 ;;
		--)
			shift
			extra_args=("$@")
			break
			;;
		-*) die "unknown option: $1 (try --help)" ;;
		*)
			[ -z "${suite}" ] || die "only one suite at a time (try --help)"
			suite=$1
			;;
		esac
		shift
	done

	[ -n "${suite}" ] ||
		die "E2E_SUITE is required, because the prerequisites differ per suite
       (see --help); e.g. make osac-dev-e2e E2E_SUITE=vmaas/sanity"

	suite=$(resolve_suite "${suite}")
	require_tools uv kubectl
	command -v grpcurl >/dev/null 2>&1 ||
		warn "grpcurl is not on PATH; suites that use the gRPC client will fail"

	kubeconfig=$(hub_kubeconfig)
	check_hub "${kubeconfig}"
	cli=$(resolve_cli)

	export KUBECONFIG="${kubeconfig}"
	export OSAC_NAMESPACE="${NS}"
	export OSAC_CLI_PATH="${cli}"
	if [ -n "${PULL_SECRET_FILE}" ] && [ -f "$(expand_path "${PULL_SECRET_FILE}")" ]; then
		# Keep it absolute: the tests run from REPO_ROOT, but a caller may not.
		pull_secret=$(expand_path "${PULL_SECRET_FILE}")
		case ${pull_secret} in
		/*) ;;
		*) pull_secret="${REPO_ROOT}/${pull_secret}" ;;
		esac
		export OSAC_PULL_SECRET_PATH="${pull_secret}"
	fi

	local -a args=(pytest "${suite}")
	[ -z "${filter_expr}" ] || args+=(-k "${filter_expr}")
	[ -z "${marker_expr}" ] || args+=(-m "${marker_expr}")
	args+=("${extra_args[@]}")
	if [ -n "${E2E_ARGS}" ]; then
		local -a env_args=()
		read -r -a env_args <<<"${E2E_ARGS}"
		args+=("${env_args[@]}")
	fi

	log "suite ${suite} on ${kubeconfig}"
	log "cli ${OSAC_CLI_PATH}"
	[ -z "${filter_expr}" ] || log "filter -k ${filter_expr}"
	[ -z "${marker_expr}" ] || log "marker -m ${marker_expr}"

	if [ "${dry_run}" = "1" ]; then
		log "would run: uv run ${args[*]}"
		return 0
	fi

	cd "${REPO_ROOT}"
	exec uv run "${args[@]}"
}

main "$@"
