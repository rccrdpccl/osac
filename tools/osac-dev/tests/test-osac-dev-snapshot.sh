#!/usr/bin/env bash
# Offline coordinator contracts. No real host, API, disk or registry is touched.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$1" "$2" || fail "expected '$1' in $2"; }
absent() { if grep -Fq -- "$1" "$2"; then fail "unexpected '$1' in $2"; fi; }
[[ -x "$repo/tools/osac-dev/osac-dev-snapshot.sh" ]] || fail 'snapshot coordinator is missing or not executable'
mkdir -p "$tmp/repo/tools/osac-dev" "$tmp/bin" "$tmp/home"
cp "$repo/tools/osac-dev/"{osac-dev-snapshot.sh,osac-dev-target.sh,osac-dev-helm.sh} "$tmp/repo/tools/osac-dev/"
for stage in bootstrap grow-storage install-infra; do
    cat > "$tmp/repo/tools/osac-dev/osac-dev-$stage.sh" <<'STAGE'
#!/usr/bin/env bash
set -euo pipefail
stage=${0##*/osac-dev-}
stage=${stage%.sh}
if [[ $stage == install-infra ]]; then
    if [[ ${OSAC_DEV_KUBECONFIG_ONLY:-0} == 1 ]]; then
        stage=kubeconfig
        mkdir -p "$(dirname -- "$OSAC_DEV_KUBECONFIG")"
        printf 'fake config\n' > "$OSAC_DEV_KUBECONFIG"
    elif [[ ${OSAC_DEV_INFRA_CHECK_ONLY:-0} == 1 ]]; then
        stage=check-infra
    fi
fi
printf 'stage %s %s %s %s\n' "$stage" "$DEV_ENV_NAME" "${SNO_FLAVOR:-sno-4-22}" "${OSAC_DEV_DISK_TARGET:-200G}" >> "$LOG"
[[ ${FAIL_STAGE:-} != "$stage:$DEV_ENV_NAME" ]]
if [[ $stage == grow-storage ]]; then touch "$GROWN_MARKER"; fi
STAGE
    chmod +x "$tmp/repo/tools/osac-dev/osac-dev-$stage.sh"
done
cat > "$tmp/bin/cluster-tool" <<'CLUSTER'
#!/usr/bin/env bash
set -euo pipefail
printf 'cluster-tool %s\n' "$*" >> "$LOG"
case "$1" in
    list)
        [[ ${FAIL_LIST:-0} != 1 ]] || exit 255
        printf 'NAME FLAVOR SUBNET CREATED\nunrelated sno-4-22 192.0.2.0/24 now\n'
        [[ -z ${EXISTING_CLONE:-} ]] || printf '%s sno-4-22 192.0.3.0/24 now\n' "$EXISTING_CLONE"
        ;;
    flavors)
        [[ ${FAIL_FLAVORS:-0} != 1 ]] || exit 255
        printf 'FLAVOR SOURCE MEMORY VCPUS DISKS CREATED\nsno-4-22 old 64Gi 16 2 now\n'
        [[ ${EXISTING_FLAVOR:-0} != 1 ]] || printf 'infra-v1 old 64Gi 16 2 now\n'
        ;;
    snapshot) [[ ${FAIL_CAPTURE:-0} != 1 ]] ;;
    *) printf 'unexpected cluster-tool: %s\n' "$*" >&2; exit 99 ;;
esac
CLUSTER
cat > "$tmp/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "$SSH_LOG"
[[ $1 == root@example ]] || exit 99
shift
bash -c "$*"
SSH
cat > "$tmp/bin/scp" <<'SCP'
#!/usr/bin/env bash
exit 99
SCP
cat > "$tmp/bin/id" <<'ID'
#!/usr/bin/env bash
[[ $1 == -u ]] || exit 99
printf '%s\n' "${FAKE_UID:-0}"
ID
cat > "$tmp/bin/oc" <<'OC'
#!/usr/bin/env bash
set -euo pipefail
printf 'oc %s %s %s\n' "$DEV_ENV_NAME" "$KUBECONFIG" "$*" >> "$LOG"
[[ "$KUBECONFIG" == "$OSAC_DEV_KUBECONFIG" && -s "$KUBECONFIG" ]] || exit 98
[[ ${FAIL_HEALTH:-} != "$DEV_ENV_NAME" ]] || exit 1
if [[ -n ${FAIL_OC_PATTERN:-} && "$*" == *"$FAIL_OC_PATTERN"* ]]; then exit 1; fi
case "$*" in
    'get --raw=/readyz '* ) [[ ${FAIL_API:-} != "$DEV_ENV_NAME" ]] ;;
    'get nodes '* ) printf 'test-infra-cluster-%s-dev-master-0' "${WRONG_NODE:-$DEV_ENV_NAME}" ;;
    'get deployment,statefulset,daemonset '* )
        [[ ${EMPTY_WORKLOADS:-0} == 1 ]] || printf 'deployment.apps/example\n'
        ;;
    'get jobs '* ) [[ ${NO_JOBS:-0} == 1 ]] || printf 'job.batch/hook\n' ;;
    'wait '*|'rollout status '*) ;;
    *) printf 'unexpected oc: %s\n' "$*" >&2; exit 99 ;;
esac
OC
cat > "$tmp/bin/virsh" <<'VIRSH'
#!/usr/bin/env bash
set -euo pipefail
printf 'virsh %s\n' "$*" >> "$LOG"
case "$1" in
    domblklist)
        [[ ${FAIL_DISK_LIST:-} != "$2" ]] || exit 1
        printf 'Target Source\n------ ------\nsda /data/root.qcow2\n'
        [[ ${MISSING_DISK:-0} == 1 ]] || printf 'sdb /data/lvms.qcow2\n'
        ;;
    domblkinfo)
        if [[ ${SMALL_DISK:-} == "$3" || ${SMALL_DISK_CLONE:-} == "$2" ]]; then
            printf 'Capacity: 107374182400\n'
        elif [[ ( ${NEEDS_GROWTH:-0} == 1 || ${NEEDS_GROWTH:-0} == "$3" ) && ! -f "$GROWN_MARKER" ]]; then
            printf 'Capacity: 107374182400\n'
        else
            printf 'Capacity: %s\n' "${DISK_CAPACITY:-268435456000}"
        fi
        ;;
    *) exit 99 ;;
esac
VIRSH
cat > "$tmp/bin/helm" <<'HELM'
#!/usr/bin/env bash
set -euo pipefail
[[ ${FAIL_HELM:-0} != 1 ]] || exit 1
helm_version=${FAKE_HELM_VERSION:-v4.3.1+g0000000}
if [[ ${1:-} == version ]]; then printf '%s\n' "$helm_version"; exit 0; fi
[[ ${1:-} == list ]] || exit 99
shift
all_states=0
while (($#)); do
    case "$1" in
        --all)
            if [[ "$helm_version" == v4.* ]]; then printf 'Error: unknown flag: --all\n' >&2; exit 1; fi
            all_states=1; shift ;;
        --all-namespaces) shift ;;
        --output) [[ $2 == json ]] || exit 99; shift 2 ;;
        *) printf 'unexpected helm list flag: %s\n' "$1" >&2; exit 99 ;;
    esac
done
release_status=${FAKE_RELEASE_STATUS:-deployed}
if [[ "$helm_version" == v3.* && $all_states == 0 && "$release_status" != deployed && "$release_status" != failed ]]; then
    printf '[]\n'
    exit 0
fi
if [[ ${PLATFORM_PRESENT:-0} == 1 ]]; then
    printf '[{"name":"osac","chart":"osac-0.0.1","status":"%s"}]\n' "$release_status"
else
    printf '[]\n'
fi
HELM
chmod +x "$tmp/bin/"*
printf '{"auths":{"example":{}}}\n' > "$tmp/pull-secret"
export PATH="$tmp/bin:$PATH" HOME="$tmp/home" LOG="$tmp/log" SSH_LOG="$tmp/ssh-log"
export PULL_SECRET_FILE="$tmp/pull-secret" SNAPSHOT_NAME=infra-v1 GROWN_MARKER="$tmp/grown"
unset OSAC_DEV_TARGET OSAC_DEV_KUBECONFIG OSAC_DEV_HOST_KUBECONFIG DEV_ENV_NAME
run() {
    : > "$LOG"
    : > "$SSH_LOG"
    rm -f -- "$GROWN_MARKER"
    env REMOTE_HOST=localhost "$@" bash "$tmp/repo/tools/osac-dev/osac-dev-snapshot.sh" > "$tmp/out" 2>&1
}
reject() {
    if run "$@"; then fail "accepted unsafe/failed case: $*"; fi
    absent 'Reusable snapshot verified' "$tmp/out"
}

# Missing and existing builders run the same preparation sequence in both modes.
for target in localhost root@example; do
  for existing in '' osac-dev; do
    run REMOTE_HOST="$target" EXISTING_CLONE="$existing" NEEDS_GROWTH=1 OSAC_DEV_KUBECONFIG_ONLY=1 OSAC_DEV_INFRA_CHECK_ONLY=1 || {
        cat "$tmp/out" >&2; fail "$target snapshot failed";
    }
    grep -E '^(stage |cluster-tool snapshot|cluster-tool verify)' "$LOG" > "$tmp/actual"
    printf '%s\n' \
        'stage bootstrap osac sno-4-22 200G' \
        'stage kubeconfig osac sno-4-22 200G' \
        'stage grow-storage osac sno-4-22 200G' \
        'stage install-infra osac sno-4-22 200G' \
        'stage check-infra osac sno-4-22 200G' \
        'cluster-tool snapshot --server local --source osac-dev --name infra-v1' \
        'stage bootstrap svfy infra-v1 200G' \
        'stage kubeconfig svfy infra-v1 200G' \
        'stage check-infra svfy infra-v1 200G' > "$tmp/expected"
    cmp "$tmp/expected" "$tmp/actual" || fail 'wrong snapshot/restore stage order'
    contains "oc svfy $HOME/.kube/svfy-dev.kubeconfig" "$LOG"
    contains '--for=condition=Degraded=False' "$LOG"
    contains '--for=condition=Progressing=False' "$LOG"
    contains 'rollout status deployment.apps/example -n cert-manager' "$LOG"
    contains 'wait job.batch/hook -n osac-infra --for=condition=Complete' "$LOG"
    contains 'wait kafka/osac-kafka -n osac-kafka --for=condition=Ready' "$LOG"
    contains 'get --raw=/readyz --request-timeout=30s' "$LOG"
    contains 'virsh domblkinfo test-infra-cluster-svfy-dev-master-0 sda' "$LOG"
    contains 'virsh domblkinfo test-infra-cluster-svfy-dev-master-0 sdb' "$LOG"
    contains 'Reusable snapshot verified' "$tmp/out"
    absent 'cluster-tool verify' "$LOG"
    absent 'push' "$LOG"
    absent 'destroy' "$LOG"
    absent 'deploy.sh' "$LOG"
    if [[ $target == localhost ]]; then
        [[ ! -s "$SSH_LOG" ]] || fail 'localhost snapshot used SSH'
    else
        contains 'ssh root@example' "$SSH_LOG"
    fi
  done
done

# Invalid inputs and validation/flavor collisions fail before any provisioning.
for args in \
    'SNAPSHOT_NAME=' 'SNAPSHOT_NAME=../escape' 'SNAPSHOT_NAME=bad;command' \
    'DEV_ENV_NAME=toolong' 'DEV_ENV_NAME=osac-dev' 'OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME=osac' \
    'OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME=BAD' 'OSAC_DEV_DISK_TARGET=100G' \
    'OSAC_DEV_DISK_TARGET=200' 'OSAC_DEV_SNAPSHOT_TIMEOUT=0' \
    'OSAC_DEV_SNAPSHOT_TIMEOUT=99999' 'PULL_SECRET_FILE=/missing' \
    'EXISTING_CLONE=svfy-dev' \
    'EXISTING_FLAVOR=1' 'FAIL_LIST=1' 'FAIL_FLAVORS=1' 'FAKE_UID=1000'; do
    reject "$args"
    absent 'stage ' "$LOG"
    absent 'cluster-tool snapshot' "$LOG"
done
reject OSAC_DEV_KUBECONFIG="$HOME/.kube/svfy-dev.kubeconfig"
absent 'stage ' "$LOG"

# Failures before capture must never save a broken flavor.
for args in \
    'FAIL_STAGE=bootstrap:osac' 'FAIL_STAGE=kubeconfig:osac' \
    'FAIL_STAGE=grow-storage:osac' 'FAIL_STAGE=install-infra:osac' \
    'FAIL_HEALTH=osac' 'EMPTY_WORKLOADS=1' 'WRONG_NODE=other' \
    'PLATFORM_PRESENT=1' 'FAIL_HELM=1' \
    'SMALL_DISK=sda' 'SMALL_DISK=sdb' 'MISSING_DISK=1' \
    'FAIL_DISK_LIST=test-infra-cluster-osac-dev-master-0' \
    'FAIL_OC_PATTERN=wait nodes' 'FAIL_OC_PATTERN=wait clusteroperators' \
    'FAIL_OC_PATTERN=rollout status' 'FAIL_OC_PATTERN=get deployment,statefulset,daemonset' \
    'FAIL_OC_PATTERN=wait hyperconverged/' 'FAIL_OC_PATTERN=wait kafka/' \
    'FAIL_OC_PATTERN=get jobs' 'FAIL_OC_PATTERN=wait job.batch/hook' \
    'FAIL_STAGE=check-infra:osac'; do
    reject NEEDS_GROWTH=1 "$args"
    absent 'cluster-tool snapshot' "$LOG"
done
reject PLATFORM_PRESENT=1 NEEDS_GROWTH=1
absent 'stage grow-storage' "$LOG"
absent 'stage install-infra ' "$LOG"
reject FAIL_CAPTURE=1
absent 'stage bootstrap svfy' "$LOG"

# Capture is not advertised as reusable until the restore checks pass.
for args in \
    'FAIL_STAGE=bootstrap:svfy' 'FAIL_STAGE=kubeconfig:svfy' \
    'FAIL_HEALTH=svfy' 'FAIL_API=svfy' \
    'SMALL_DISK_CLONE=test-infra-cluster-svfy-dev-master-0' \
    'FAIL_STAGE=check-infra:svfy'; do
    reject "$args"
    contains 'cluster-tool snapshot' "$LOG"
    absent 'stage install-infra svfy' "$LOG"
    absent 'stage grow-storage svfy' "$LOG"
done
run DEV_ENV_NAME=bld EXISTING_CLONE=bld-dev NEEDS_GROWTH=sdb OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME=chk OSAC_DEV_DISK_TARGET=250G NO_JOBS=1 || {
    cat "$tmp/out" >&2; fail 'custom names/storage or expired hook jobs failed';
}
contains 'stage grow-storage bld sno-4-22 250G' "$LOG"
contains 'cluster-tool snapshot --server local --source bld-dev --name infra-v1' "$LOG"
contains 'stage check-infra chk infra-v1 250G' "$LOG"
run OSAC_DEV_KUBECONFIG="$HOME/custom config" || {
    cat "$tmp/out" >&2; fail 'custom builder kubeconfig failed';
}
contains "oc osac $HOME/custom config" "$LOG"
contains "oc svfy $HOME/.kube/svfy-dev.kubeconfig" "$LOG"
for target in localhost root@example; do
    run REMOTE_HOST="$target" EXISTING_CLONE=osac-dev DISK_CAPACITY=214748364800 || {
        cat "$tmp/out" >&2; fail 'existing 200 GiB builder failed';
    }
    contains 'Reusing existing builder osac-dev' "$tmp/out"
    absent 'stage grow-storage' "$LOG"
    contains 'stage install-infra osac' "$LOG"
    contains 'Reusable snapshot verified' "$tmp/out"
done

for helm_version in v3.18.0 v4.3.1; do
    run FAKE_HELM_VERSION="$helm_version" || {
        cat "$tmp/out" >&2; fail "$helm_version snapshot inspection failed";
    }
    for release_status in deployed failed pending-upgrade; do
        reject FAKE_HELM_VERSION="$helm_version" PLATFORM_PRESENT=1 FAKE_RELEASE_STATUS="$release_status"
        contains 'OSAC platform release' "$tmp/out"
        absent 'stage install-infra ' "$LOG"
    done
done
reject FAKE_HELM_VERSION=unknown
absent 'stage install-infra ' "$LOG"

make -C "$repo" -n osac-dev-snapshot > "$tmp/make"
contains 'tools/osac-dev/osac-dev-snapshot.sh' "$tmp/make"
printf 'All snapshot coordinator tests passed.\n'
