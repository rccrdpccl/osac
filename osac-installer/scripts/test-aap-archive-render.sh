#!/usr/bin/env bash
# Verify the frozen AAP playbook archive contract:
#   - With no projectArchive values, nothing archive-related renders and the
#     git project variables keep flowing (AAP_PROJECT_GIT_URI/BRANCH only).
#   - With projectArchive.data, the chart serves the tarball in-cluster:
#     ConfigMap + Deployment + Service named <fullname>-playbooks, and the
#     config-as-code secret gets AAP_PROJECT_ARCHIVE_URI pointing at the
#     in-cluster Service URL the chart itself creates.
#   - With projectArchive.uri, no server renders and the secret uses the URI.
#   - With both, uri wins and no server renders.
#   - Oversized data fails rendering with the ConfigMap-limit guard message.
#   - The umbrella chart accepts the value through its values schema and
#     renders the same in-cluster URI (schema contract).

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
AAP_CHART=$(cd -- "${SCRIPT_DIR}/../../osac-aap/charts/aap" && pwd)
OSAC_CHART=$(cd -- "${SCRIPT_DIR}/../charts/osac" && pwd)
HELM_BIN=${HELM_BIN:-helm}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# Minimal fixture archive with the required top-level osac-aap/ layout.
mkdir -p "${TMP_DIR}/fixture/osac-aap"

cat > "${TMP_DIR}/fixture/osac-aap/playbook_osac_stub.yml" <<'EOF'
- hosts: localhost
  gather_facts: false
  tasks: []
EOF
tar -czf "${TMP_DIR}/fixture.tgz" -C "${TMP_DIR}/fixture" osac-aap
base64 -w0 "${TMP_DIR}/fixture.tgz" > "${TMP_DIR}/fixture.tgz.b64"

render_subchart() {
	"${HELM_BIN}" template test "${AAP_CHART}" "$@"
}

render_umbrella() {
	"${HELM_BIN}" template osac "${OSAC_CHART}" \
		--namespace osac \
		--values "${SCRIPT_DIR}/../values/dev/instance.yaml" \
		--set-string global.clusterDomain=example.com \
		--set service.externalHostname=fulfillment-api.example.com \
		--set service.internalHostname=fulfillment-internal-api.example.com \
		"$@"
}

errors=0
fail() {
	echo "ERROR: $*" >&2
	errors=$((errors + 1))
}

# --- 1. Defaults: git project, nothing archive-related ---
echo "Checking default render (git project, no archive)..."
default_render=$(render_subchart \
	--set "configAsCode.projectGitUri=https://github.com/osac-project/osac" \
	--set "configAsCode.projectGitBranch=main")

if grep -q "AAP_PROJECT_ARCHIVE_URI" <<<"${default_render}"; then
	fail "AAP_PROJECT_ARCHIVE_URI must not render without projectArchive values"
fi
if grep -q "test-osac-aap-playbooks" <<<"${default_render}"; then
	fail "archive server resources must not render without projectArchive values"
fi
if ! grep -q "AAP_PROJECT_GIT_URI: \"https://github.com/osac-project/osac\"" <<<"${default_render}"; then
	fail "AAP_PROJECT_GIT_URI must keep rendering without projectArchive values"
fi

# --- 2. data: in-cluster server + URI ---
echo "Checking projectArchive.data render (in-cluster server)..."
data_render=$(render_subchart --set-file "configAsCode.projectArchive.data=${TMP_DIR}/fixture.tgz.b64")

if ! grep -q "AAP_PROJECT_ARCHIVE_URI: \"http://test-osac-aap-playbooks.default.svc.cluster.local:8080/osac-aap.tgz\"" <<<"${data_render}"; then
	fail "data must set AAP_PROJECT_ARCHIVE_URI to the in-cluster Service URL"
fi
for resource in ConfigMap Deployment Service; do
	if ! grep -q "kind: ${resource}" <<<"${data_render}"; then
		fail "archive server ${resource} must render with data set"
	fi
done
if ! grep -q "name: test-osac-aap-playbooks$" <<<"${data_render}"; then
	fail "archive server resources must be named <fullname>-playbooks"
fi
if ! grep -q "/usr/bin/python3.12" <<<"${data_render}"; then
	fail "archive server must serve via python3.12"
fi
if ! grep -q "mountPath: /srv" <<<"${data_render}"; then
	fail "archive server must mount the playbooks ConfigMap at /srv"
fi
if ! grep -q "osac-aap.tgz: " <<<"${data_render}"; then
	fail "ConfigMap must carry the osac-aap.tgz binaryData entry"
fi

# --- 3. uri: external URL, no server ---
echo "Checking projectArchive.uri render (external URL, no server)..."
uri_render=$(render_subchart --set "configAsCode.projectArchive.uri=https://artifacts.example.com/osac-aap.tgz")

if ! grep -q "AAP_PROJECT_ARCHIVE_URI: \"https://artifacts.example.com/osac-aap.tgz\"" <<<"${uri_render}"; then
	fail "uri must set AAP_PROJECT_ARCHIVE_URI verbatim"
fi
if grep -q "kind: Deployment" <<<"${uri_render}"; then
	fail "archive server must not render with uri set"
fi

# --- 4. uri wins over data ---
echo "Checking uri+data precedence (uri wins, no server)..."
both_render=$(render_subchart \
	--set "configAsCode.projectArchive.uri=https://artifacts.example.com/osac-aap.tgz" \
	--set-file "configAsCode.projectArchive.data=${TMP_DIR}/fixture.tgz.b64")

if ! grep -q "AAP_PROJECT_ARCHIVE_URI: \"https://artifacts.example.com/osac-aap.tgz\"" <<<"${both_render}"; then
	fail "uri must take precedence over data"
fi
if grep -q "kind: Deployment" <<<"${both_render}"; then
	fail "archive server must not render when uri overrides data"
fi

# --- 5. Size guard ---
echo "Checking oversized data guard..."
python3 -c "print('A' * 1400000, end='')" > "${TMP_DIR}/oversized.b64"
if render_subchart --set-file "configAsCode.projectArchive.data=${TMP_DIR}/oversized.b64" \
	> "${TMP_DIR}/oversized.out" 2>&1; then
	fail "oversized data must fail rendering"
fi
if ! grep -q "too large" "${TMP_DIR}/oversized.out"; then
	fail "oversized data must fail with the ConfigMap-limit message"
fi

# --- 6. Umbrella chart schema accepts the value ---
echo "Checking umbrella chart schema and URI consistency..."
umbrella_render=$(render_umbrella --set-file "aap.configAsCode.projectArchive.data=${TMP_DIR}/fixture.tgz.b64")

if ! grep -q "AAP_PROJECT_ARCHIVE_URI: \"http://osac-aap-playbooks.osac.svc.cluster.local:8080/osac-aap.tgz\"" <<<"${umbrella_render}"; then
	fail "umbrella chart must render the same in-cluster archive URI"
fi
if ! grep -q "kind: Deployment" <<<"${umbrella_render}"; then
	fail "umbrella chart must render the archive server Deployment"
fi

if [[ ${errors} -gt 0 ]]; then
	echo "FAILED: ${errors} error(s) in AAP archive render checks" >&2
	exit 1
fi

echo "AAP playbook archive render checks passed."
