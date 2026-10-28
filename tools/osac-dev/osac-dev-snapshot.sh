#!/usr/bin/env bash
# Build and smoke-test a private infra-only cluster-tool flavor.
# Existing builders are prepared in place; validation clones/flavors must be new.
# No existing cluster/flavor is replaced, destroyed or pushed to a registry.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$SCRIPT_DIR/osac-dev-target.sh"
# shellcheck source=tools/osac-dev/osac-dev-helm.sh
source "$SCRIPT_DIR/osac-dev-helm.sh"

fail() { printf 'osac-dev-snapshot: %s\n' "$*" >&2; exit 1; }
info() { printf 'osac-dev-snapshot: %s\n' "$*"; }

host_cluster_tool() {
    local command
    printf -v command '%q ' cluster-tool "$@"
    osac_dev_host_run "export PATH=\"\$HOME/.local/bin:\$PATH\"; $command"
}

validate_inputs() {
    local name target_num target_bytes
    [[ $# == 0 ]] || fail 'usage: SNAPSHOT_NAME=<new-flavor> make osac-dev-snapshot'
    [[ "$SNAPSHOT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]] || \
        fail 'SNAPSHOT_NAME is required and must be a simple new flavor name (letters, digits, dot, underscore, hyphen)'
    for name in DEV_ENV_NAME OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME; do
        [[ "${!name}" =~ ^[a-z0-9]{1,4}$ ]] || fail "$name must be 1-4 lowercase letters or digits"
    done
    [[ "$DEV_ENV_NAME" != "$OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME" ]] || \
        fail 'builder and verification environments must have different names'
    [[ "$OSAC_DEV_KUBECONFIG" == /* && "$OSAC_DEV_KUBECONFIG" != *:* ]] || \
        fail 'OSAC_DEV_KUBECONFIG must be a single absolute path'
    [[ "$OSAC_DEV_KUBECONFIG" != "$VERIFY_KUBECONFIG" ]] || fail 'builder and verification kubeconfigs must have different paths'
    [[ "$OSAC_DEV_SNAPSHOT_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || fail 'OSAC_DEV_SNAPSHOT_TIMEOUT must be 1-7200 seconds'
    ((OSAC_DEV_SNAPSHOT_TIMEOUT <= 7200)) || fail 'OSAC_DEV_SNAPSHOT_TIMEOUT must be 1-7200 seconds'
    [[ "$OSAC_DEV_DISK_TARGET" =~ ^[1-9][0-9]{0,6}[GM]$ ]] || fail 'OSAC_DEV_DISK_TARGET must be <number>G or <number>M'
    target_num=${OSAC_DEV_DISK_TARGET%?}
    target_bytes=$((target_num * 1024 * 1024))
    [[ "$OSAC_DEV_DISK_TARGET" != *G ]] || target_bytes=$((target_bytes * 1024))
    ((target_bytes >= 200 * 1024**3)) || fail 'OSAC_DEV_DISK_TARGET must be at least 200 GiB'
    DISK_TARGET_BYTES=$target_bytes
    [[ "$PULL_SECRET_FILE" == /* && -r "$PULL_SECRET_FILE" && -s "$PULL_SECRET_FILE" ]] || \
        fail 'PULL_SECRET_FILE must be an absolute readable nonempty local file'
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("auths"), dict) and d["auths"]' \
        "$PULL_SECRET_FILE" || fail 'invalid OpenShift pull-secret JSON'
}

refuse_existing_resources() {
    local clones flavors
    osac_dev_host_has_command cluster-tool || fail "cluster-tool is required on $OSAC_DEV_TARGET_DESCRIPTION; run make osac-dev-setup first"
    clones=$(host_cluster_tool list --server local) || fail 'could not list clusters; refusing to provision'
    flavors=$(host_cluster_tool flavors --server local) || fail 'could not list flavors; refusing to provision'
    if awk -v name="${OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME}-dev" '$1 == name {found=1} END {exit !found}' <<< "$clones"; then
        fail "validation cluster ${OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME}-dev already exists; choose a fresh validation name (nothing was removed)"
    fi
    if awk -v name="${DEV_ENV_NAME}-dev" '$1 == name {found=1} END {exit !found}' <<< "$clones"; then
        info "Reusing existing builder ${DEV_ENV_NAME}-dev; storage, infrastructure and health checks will still run."
    fi
    if awk -v name="$SNAPSHOT_NAME" '$1 == name {found=1} END {exit !found}' <<< "$flavors"; then
        fail "flavor $SNAPSHOT_NAME already exists; choose a versioned SNAPSHOT_NAME (nothing was overwritten)"
    fi
}

prepare_cluster() {
    "$SCRIPT_DIR/osac-dev-bootstrap.sh" up || fail "cluster boot failed for $DEV_ENV_NAME"
    OSAC_DEV_KUBECONFIG_ONLY=1 "$SCRIPT_DIR/osac-dev-install-infra.sh" || fail 'kubeconfig setup failed'
}

selected_node() {
    local node
    node=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' --request-timeout=30s) || fail 'could not identify SNO node'
    [[ "$node" == "test-infra-cluster-${DEV_ENV_NAME}-dev-master-0" ]] || fail 'kubeconfig does not identify the selected SNO clone'
    printf '%s\n' "$node"
}

check_disk_capacity() {
    local node=$1 mode=${2:-verify} disks dev details capacity needs_growth=0
    local -a devices
    disks=$(osac_dev_host_run "virsh domblklist '$node'") || fail 'could not inspect SNO disks'
    mapfile -t devices < <(awk '/[.]qcow2$/ {print $1}' <<< "$disks")
    ((${#devices[@]} == 2)) || fail 'expected exactly two SNO qcow2 disks'
    for dev in "${devices[@]}"; do
        [[ "$dev" =~ ^[sv]d[a-z]$ ]] || fail 'unexpected SNO disk target'
        details=$(osac_dev_host_run "virsh domblkinfo '$node' '$dev'") || fail "could not inspect $dev capacity"
        capacity=$(awk '/^Capacity:/ {print $2}' <<< "$details")
        [[ "$capacity" =~ ^[0-9]+$ ]] || fail "could not read $dev capacity"
        if ((capacity < DISK_TARGET_BYTES)); then needs_growth=1; fi
    done
    if ((needs_growth)); then
        [[ "$mode" == prepare ]] || fail "$node has a disk smaller than $OSAC_DEV_DISK_TARGET; refusing to resize during verification"
        "$SCRIPT_DIR/osac-dev-grow-storage.sh" || fail '200 GiB storage growth failed'
    else
        info "$node: both disk capacities >= $OSAC_DEV_DISK_TARGET; skipping storage growth (read-only verification)."
    fi
}

check_infra_only() {
    local releases
    releases=$(osac_dev_helm_list_all --all-namespaces --output json) || fail 'could not inspect Helm releases'
    python3 -c 'import json,re,sys; sys.exit(any(r.get("name") == "osac" or re.match(r"osac-[0-9]", r.get("chart", "")) for r in json.load(sys.stdin)))' \
        <<< "$releases" || fail 'selected cluster contains an OSAC platform release; refusing an infra-only snapshot'
}

wait_for_health() {
    local node condition namespace workloads workload jobs job
    local timeout="${OSAC_DEV_SNAPSHOT_TIMEOUT}s"
    export KUBECONFIG="$OSAC_DEV_KUBECONFIG"
    oc get --raw=/readyz --request-timeout=30s >/dev/null || fail 'Kubernetes API is not ready'
    check_infra_only
    node=$(selected_node) || exit 1
    check_disk_capacity "$node"
    oc wait nodes --all --for=condition=Ready --timeout="$timeout" || fail 'SNO node is not Ready'
    for condition in Available=True Progressing=False Degraded=False; do
        oc wait clusteroperators --all --for="condition=$condition" --timeout="$timeout" || fail "cluster operators: $condition not satisfied"
    done
    # caas-ci + infra-cnv enables these namespaces. Rollout checks include
    # observed generation and replica convergence, not just Available=True.
    for namespace in cert-manager keycloak osac-infra openshift-storage openshift-cnv \
        metallb-system multicluster-engine ansible-aap osac-kafka; do
        workloads=$(oc get deployment,statefulset,daemonset -n "$namespace" -o name --request-timeout=30s) || \
            fail "could not list workloads in $namespace"
        [[ -n "$workloads" ]] || fail "no infrastructure workloads found in $namespace"
        while IFS= read -r workload; do
            oc rollout status "$workload" -n "$namespace" --timeout="$timeout" || fail "$namespace/$workload is not ready"
        done <<< "$workloads"
    done
    oc wait hyperconverged/kubevirt-hyperconverged -n openshift-cnv --for=condition=Available --timeout="$timeout" || fail 'CNV is not Available'
    oc wait kafka/osac-kafka -n osac-kafka --for=condition=Ready --timeout="$timeout" || fail 'Kafka is not Ready'
    # Completed hook Jobs may already have been removed by their TTL controller.
    jobs=$(oc get jobs -n osac-infra -o name --request-timeout=30s) || fail 'could not list infrastructure hook jobs'
    if [[ -n "$jobs" ]]; then
        while IFS= read -r job; do
            oc wait "$job" -n osac-infra --for=condition=Complete --timeout="$timeout" || fail "infrastructure hook $job did not complete"
        done <<< "$jobs"
    fi
}

main() {
    local command builder_name node
    osac_dev_target_init
    export PATH="$HOME/.local/bin:$PATH"
    export DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
    export SNO_FLAVOR=${SNO_FLAVOR:-sno-4-22}
    export OSAC_DEV_DISK_TARGET=${OSAC_DEV_DISK_TARGET:-200G}
    export OSAC_DEV_KUBECONFIG=${OSAC_DEV_KUBECONFIG:-$HOME/.kube/${DEV_ENV_NAME}-dev.kubeconfig}
    export OSAC_DEV_KUBECONFIG_ONLY=0 OSAC_DEV_INFRA_CHECK_ONLY=0
    SNAPSHOT_NAME=${SNAPSHOT_NAME:-}
    PULL_SECRET_FILE=${PULL_SECRET_FILE:-}
    OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME=${OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME:-svfy}
    OSAC_DEV_SNAPSHOT_TIMEOUT=${OSAC_DEV_SNAPSHOT_TIMEOUT:-1800}
    VERIFY_KUBECONFIG="$HOME/.kube/${OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME}-dev.kubeconfig"
    for command in python3 oc helm awk make; do
        command -v "$command" >/dev/null || fail "required local command not found: $command; run make osac-dev-setup"
    done
    validate_inputs "$@"
    osac_dev_require_transport
    osac_dev_require_root
    refuse_existing_resources
    info "Building private flavor $SNAPSHOT_NAME from ${DEV_ENV_NAME}-dev; both disks >= $OSAC_DEV_DISK_TARGET."
    info 'Snapshots contain credentials and private keys. No registry push or automatic cleanup will run.'
    prepare_cluster
    export KUBECONFIG="$OSAC_DEV_KUBECONFIG"
    node=$(selected_node) || exit 1
    check_infra_only
    check_disk_capacity "$node" prepare
    "$SCRIPT_DIR/osac-dev-install-infra.sh" || fail 'infrastructure installation failed; no snapshot taken'
    wait_for_health
    # Re-check releases/CNV without any repair immediately before capture.
    OSAC_DEV_INFRA_CHECK_ONLY=1 "$SCRIPT_DIR/osac-dev-install-infra.sh" || fail 'pre-snapshot infrastructure verification failed'
    host_cluster_tool snapshot --server local --source "${DEV_ENV_NAME}-dev" --name "$SNAPSHOT_NAME" || fail 'snapshot capture failed; inspect the retained builder and cluster-tool state'
    info "Captured $SNAPSHOT_NAME; testing restore into ${OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME}-dev."
    builder_name=$DEV_ENV_NAME
    (
        export DEV_ENV_NAME="$OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME" SNO_FLAVOR="$SNAPSHOT_NAME"
        export OSAC_DEV_KUBECONFIG="$VERIFY_KUBECONFIG"
        export OSAC_DEV_HOST_KUBECONFIG="/root/.kube/${DEV_ENV_NAME}-dev.kubeconfig"
        prepare_cluster
        wait_for_health
        OSAC_DEV_INFRA_CHECK_ONLY=1 "$SCRIPT_DIR/osac-dev-install-infra.sh" || fail 'restored infrastructure verification failed; no upgrade attempted'
    )
    info "Reusable snapshot verified: $SNAPSHOT_NAME (local flavor on $OSAC_DEV_TARGET_DESCRIPTION)."
    info "Builder ${builder_name}-dev and validation clone ${OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME}-dev are retained."
    info 'Clone smoke checks do not replace CaaS E2E or validate every service credential and identity.'
}

main "$@"
