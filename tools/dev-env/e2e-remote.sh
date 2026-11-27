#!/usr/bin/env bash
# shellcheck shell=bash
# Sourced by e2e.sh. The clients and pytest environment come from the same
# recipe as full-regression CI, in the test-infra checkout set up by bmh.sh.

remote_e2e_dir=
remote_e2e_stage=
remote_e2e_output=
remote_e2e_container=
remote_e2e_infra=
remote_e2e_ready=

prepare_remote_e2e() {
	local repo=$1 kubectl=$2 cache infra_arg
	require_tools ssh git tar jq
	[[ -s ${OSAC_PULL_SECRET_PATH:-} && -f ${OSAC_SSH_PUBLIC_KEY_PATH:-} ]] ||
		die 'remote E2E needs an OpenShift pull secret and an SSH public key'
	[[ -z ${TEST_INFRA_DIR} || ${TEST_INFRA_DIR} == /* ]] || die 'TEST_INFRA_DIR must be an absolute remote path'
	printf -v infra_arg '%q' "${TEST_INFRA_DIR}"
	remote_e2e_infra=$(ssh_remote "bash -s -- ${infra_arg}" <<'REMOTE'
set -euo pipefail
infra=${1:-"$HOME/osac-test-infra"}
command -v podman >/dev/null || { printf 'Podman is required on the hypervisor\n' >&2; exit 1; }
git -C "$infra" cat-file -e HEAD:Containerfile
printf '%s\n' "$infra"
REMOTE
	) || die "cannot find Podman or the CI test-infra checkout on ${REMOTE_HOST}"

	cache=$(dirname "$(expand_path "${ARTIFACTS_FILE}")")
	mkdir -p "${cache}"
	remote_e2e_output=$(mktemp -d "${cache}/e2e.XXXXXXXX")
	remote_e2e_stage=$(mktemp -d)
	mkdir -p "${remote_e2e_stage}/context" "${remote_e2e_stage}/inputs"
	chmod 700 "${remote_e2e_stage}/inputs"
	log "remote E2E artifacts: ${remote_e2e_output}"

	# Copy working-tree test contents, but only paths tracked by git. Do not
	# send a checkout, .git, untracked config, caches, SSH keys or credentials
	# to the build context. Mount credentials separately at runtime.
	git -C "${repo}" ls-files -z -- tests/__init__.py tests/e2e |
		tar -C "${repo}" --null --no-recursion -T - -cf - |
		tar -C "${remote_e2e_stage}/context" -xf -
	if [[ -n ${OSAC_CLI_PATH} ]]; then
		[[ -x ${OSAC_CLI_PATH} ]] || die 'OSAC_CLI_PATH is not executable'
		cp -- "${OSAC_CLI_PATH}" "${remote_e2e_stage}/context/osac-cli-bin"
	else
		"${kubectl}" -n "${NS}" exec deploy/fulfillment-grpc-server -c grpc-server -- cat /usr/local/bin/osac \
			>"${remote_e2e_stage}/context/osac-cli-bin" || die 'could not copy the deployed Fulfillment CLI'
	fi
	[[ -s ${remote_e2e_stage}/context/osac-cli-bin ]] || die 'the Fulfillment CLI is empty'
	chmod 755 "${remote_e2e_stage}/context/osac-cli-bin"
	(
		umask 077
		"${kubectl}" config view --minify --flatten --raw >"${remote_e2e_stage}/inputs/kubeconfig"
		cp -- "${OSAC_PULL_SECRET_PATH}" "${remote_e2e_stage}/inputs/pull-secret.json"
		cp -- "${OSAC_SSH_PUBLIC_KEY_PATH}" "${remote_e2e_stage}/inputs/ssh.pub"
		cp -- "${repo}/pyproject.toml" "${remote_e2e_stage}/inputs/pyproject.toml"
		printf '%s\n' 'nameserver 127.0.0.1' >"${remote_e2e_stage}/inputs/resolv.conf"
	)

	remote_e2e_dir=$(ssh_remote 'mktemp -d /tmp/osac-dev-e2e.XXXXXXXX') || die 'cannot stage the remote E2E run'
	if [[ ! ${remote_e2e_dir} =~ ^/tmp/osac-dev-e2e\.[a-zA-Z0-9]{8}$ ]]; then
		remote_e2e_dir=
		die 'unexpected remote E2E directory; refusing to use it'
	fi
	remote_e2e_container="osac-dev-e2e-${remote_e2e_dir##*.}"
	# Keep the inputs private, but own them as the remote Podman user.
	# Rootful tar otherwise preserves the workstation UID, which a container
	# with no DAC override capability cannot read even as UID 0.
	tar -C "${remote_e2e_stage}" -cf - context inputs |
		ssh_remote "tar -C ${remote_e2e_dir} --no-same-owner -xf - && mkdir ${remote_e2e_dir}/output" ||
		die 'could not transfer the E2E inputs'
	remote_e2e_ready=1
}

# Older, still-valid BMH checkouts may predate the CI VIP picker. Use a known
# upstream version in that case rather than fetching or updating the shared
# checkout. Check the digest before running the helper on the hypervisor.
find_dev_guest_vip_range() {
	local path=.github/scripts/guest_ingress_vip_range.py command
	local helper="${remote_e2e_stage}/guest_ingress_vip_range.py"
	local ref=88114b182cb70dc1c3d32ab5435ac6624679a951
	local sha=2012799d559d189ed42161736b878b69459b6760a76a97ec7f6ee6fae48dfbe4
	printf -v command 'git -C %q show HEAD:%s' "${remote_e2e_infra}" "${path}"
	if ! ssh_remote "${command}" >"${helper}" 2>/dev/null; then
		require_tools curl sha256sum
		curl --fail --silent --show-error --location --max-time 30 \
			"https://raw.githubusercontent.com/osac-project/osac-test-infra/${ref}/${path}" \
			-o "${helper}" || die 'cannot download the pinned CI guest ingress VIP picker'
		printf '%s  %s\n' "${sha}" "${helper}" | sha256sum --check --status ||
			die 'CI guest ingress VIP picker checksum mismatch'
	fi
	printf -v command 'env CLONE_NAME=%q python3 - --explain' "${CLUSTER_NAME}"
	ssh_remote_root "${command}" <"${helper}"
}

# Apply only missing CI settings on the dev no-op DNS profile. Preserve
# explicit values and never change the DNS contract while orders still exist.
configure_dev_caas() {
	local kubectl=$1 cm zone vip patch orders
	cm=$("${kubectl}" -n "${NS}" get configmap cluster-fulfillment-ig -o json) ||
		die 'cannot read the dev CaaS instance group'
	if ! jq -e '.data.DNS_CLASS == "dns.noop.dns"' <<<"${cm}" >/dev/null; then
		die 'remote dev CaaS DNS publishing requires DNS_CLASS=dns.noop.dns'
	fi
	zone=$(hosted_dns_zone)
	[[ -n ${zone} ]] || die 'cannot derive the dev hosted zone'
	jq -e --arg zone "${zone}" '
		.data.HOSTED_CLUSTER_BASE_DOMAIN == $zone and
		(.data.EXTERNAL_ACCESS_BASE_DOMAIN // "" | . == "" or . == $zone) and
		(.data.EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS // "" | . == "" or
		  (split(",") | map(gsub("^\\s+|\\s+$"; "")) | index($zone) != null))' \
		<<<"${cm}" >/dev/null || die 'the configured CaaS domains do not match the dev hosted zone'
	if jq -e '.data | [.EXTERNAL_ACCESS_BASE_DOMAIN, .EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS,
		.CI_GUEST_INGRESS_IP_RANGE] | all(type == "string" and length > 0)' <<<"${cm}" >/dev/null; then
		return 0
	fi
	orders=$("${kubectl}" get clusterorders --all-namespaces -o json) || die 'cannot check for active ClusterOrders'
	jq -e '.items | length == 0' <<<"${orders}" >/dev/null ||
		die 'cannot configure the dev CaaS DNS domain or ingress VIP range while ClusterOrders exist'
	vip=$(jq -r '.data.CI_GUEST_INGRESS_IP_RANGE // ""' <<<"${cm}")
	if [[ -z ${vip} ]]; then
		vip=$(find_dev_guest_vip_range) ||
			die 'cannot derive a guest ingress VIP range from the clone network'
		[[ ${vip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}-([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
			die 'the CI guest ingress VIP picker did not return an IPv4 range'
	fi
	patch=$(jq -ec --arg zone "${zone}" --arg vip "${vip}" '
		.metadata.resourceVersion as $rv | select($rv | strings | length > 0) |
		{metadata: {resourceVersion: $rv}, data: ( .data as $data | {
			EXTERNAL_ACCESS_BASE_DOMAIN: $zone, EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS: $zone,
			CI_GUEST_INGRESS_IP_RANGE: $vip
		} | with_entries(select(($data[.key] // "") == "")) )}' <<<"${cm}") ||
		die 'cannot guard the CaaS config patch with a resource version'
	log 'configuring missing dev CaaS domain and ingress VIP settings'
	"${kubectl}" -n "${NS}" patch configmap cluster-fulfillment-ig --type=merge -p "${patch}" >/dev/null
}

run_remote_e2e() {
	local command
	printf -v command '%q ' "${remote_e2e_dir}" "${remote_e2e_infra}" "${remote_e2e_container}" "${NS}" \
		"${BMH_NAMESPACE}" "${OSAC_E2E_KEEP_RESOURCES:-}" "$@"
	ssh_remote "bash -s -- ${command}" <<'REMOTE'
set -euo pipefail
dir=$1 infra=$2 name=$3 ns=$4 bmh_ns=$5 keep=$6
shift 6
cd "$dir"
# Use one test-infra revision for the build recipe and dependencies. Don't
# fetch or move the hypervisor checkout that the virtual BMH tools also use.
ref=$(git -C "$infra" rev-parse HEAD)
printf '>> building the CI E2E runner from test-infra %s\n' "$ref"
for file in Containerfile pyproject.toml uv.lock; do
	git -C "$infra" show "$ref:$file" >"context/$file"
done
image="localhost/osac-dev-e2e:${name##*-}"
# OCI image metadata drops the CI Containerfile's SHELL instruction.
podman build --format docker --build-arg OSAC_CLI_BIN=osac-cli-bin --tag "$image" "$dir/context"
# Explicitly use the hypervisor's dnsmasq, not the workstation or Podman's
# default resolv.conf. Loopback reaches the host only with host networking.
runner=(podman run --rm --network=host --dns=none --cap-drop=all --security-opt=no-new-privileges
	-v "$dir/inputs:/inputs:ro,Z" -v "$dir/inputs/resolv.conf:/etc/resolv.conf:ro,Z"
	-v "$dir/inputs/pyproject.toml:/tests/pyproject.toml:ro,Z"
	-v "$dir/output:/tmp/test-output:Z" -e KUBECONFIG=/inputs/kubeconfig
	-e OSAC_NAMESPACE="$ns" -e OSAC_BMH_NAMESPACE="$bmh_ns"
	-e OSAC_CLI_PATH=/usr/local/bin/osac -e OSAC_PULL_SECRET_PATH=/inputs/pull-secret.json
	-e OSAC_SSH_PUBLIC_KEY_PATH=/inputs/ssh.pub -e OSAC_E2E_KEEP_RESOURCES="$keep")
"${runner[@]}" "$image" kubectl version --request-timeout=15s >/dev/null
pytest=$1
shift
"${runner[@]}" --name "$name" "$image" "$pytest" \
	--junitxml=/tmp/test-output/junit.xml "$@"
REMOTE
}

cleanup_remote_e2e() {
	if [[ -n ${remote_e2e_stage} ]]; then
		rm -rf -- "${remote_e2e_stage}"
	fi
	[[ -n ${remote_e2e_dir} ]] || return 0
	local dir=${remote_e2e_dir} name=${remote_e2e_container} image="localhost/osac-dev-e2e:${remote_e2e_container##*-}"
	# Only this run's container, image tag and private remote directory.
	ssh_remote "podman stop --ignore --time 5 ${name}" >/dev/null 2>&1 || true
	local remove=${dir}
	if [[ -n ${remote_e2e_ready} ]] &&
		! ssh_remote "tar -C ${dir}/output -cf - ." | tar -C "${remote_e2e_output}" -xf -; then
		warn "could not retrieve remote E2E artifacts; left them in ${dir}/output"
		remove="${dir}/inputs ${dir}/context"
	fi
	ssh_remote "podman rmi ${image} >/dev/null 2>&1 || true; rm -rf -- ${remove}" ||
		warn "could not clean up the remote E2E run ${dir}"
}
