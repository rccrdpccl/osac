#!/usr/bin/env bash
# Offline contract tests: never contact a host, cluster, or registry.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
make -C "$repo" -n osac-dev-cluster > "$tmp/cluster"
grep -q 'osac-dev-bootstrap.sh up' "$tmp/cluster" || fail 'cluster target must boot cluster'
grep -q 'osac-dev-grow-storage.sh' "$tmp/cluster" || fail 'cluster target must grow SNO disks'
make -C "$repo" -n osac-dev > "$tmp/all"
grep -q 'osac-dev-workflow.sh' "$tmp/all" || fail 'aggregate must run workflow wrapper'
mkdir -p "$tmp/tools" "$tmp/bin"
cp "$repo/tools/osac-dev/osac-dev-workflow.sh" "$repo/tools/osac-dev/osac-dev-target.sh" "$tmp/tools/"
for stage in bootstrap grow-storage install-infra bmh deploy dns; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "$LOG"\n[[ "${FAIL_STAGE:-}" != "%s" ]]\n' "$stage" "$stage" > "$tmp/tools/osac-dev-$stage.sh"
    chmod +x "$tmp/tools/osac-dev-$stage.sh"
done
for command in ssh scp oc helm skaffold docker uv getent; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/$command"
    chmod +x "$tmp/bin/$command"
done
printf '{"auths":{"example":{}}}\n' > "$tmp/pull-secret"
printf 'fake license\n' > "$tmp/license"
chmod 600 "$tmp/license"
printf '#!/usr/bin/env bash\nprintf "ssh %%s\\n" "$*" >> "${SSH_LOG:-/dev/null}"\nprintf "0\\n"\n' > "$tmp/bin/ssh"
printf '#!/usr/bin/env bash\n[[ ${OSAC_DEV_KUBECONFIG_ONLY:-0} != 1 ]] || exit 0\nprintf "install-infra\\n" >> "$LOG"\n[[ ${FAIL_STAGE:-} != install-infra ]]\n' > "$tmp/tools/osac-dev-install-infra.sh"
export PATH="$tmp/bin:$PATH" LOG="$tmp/log" SSH_LOG="$tmp/ssh-log" REMOTE_HOST=root@example
export PULL_SECRET_FILE="$tmp/pull-secret" OSAC_DEV_LICENSE_FILE="$tmp/license"
export OSAC_DEV_REGISTRY=quay.io/example DOCKER_HOST=unix:///fake
unset OSAC_DEV_BMH_NODE_NIC OSAC_DEV_API_RECOVERY_TIMEOUT
bash "$tmp/tools/osac-dev-workflow.sh" --check
[[ ! -e "$LOG" ]] || fail 'check ran a deployment'
bash "$tmp/tools/osac-dev-workflow.sh"
printf 'bootstrap\ngrow-storage\ninstall-infra\nbmh\ndeploy\ndns\n' > "$tmp/expected"
cmp "$LOG" "$tmp/expected" || fail 'incorrect stage order'
: > "$LOG"
if FAIL_STAGE=install-infra bash "$tmp/tools/osac-dev-workflow.sh"; then fail 'ignored stage failure'; fi
printf 'bootstrap\ngrow-storage\ninstall-infra\n' > "$tmp/expected"
cmp "$LOG" "$tmp/expected" || fail 'continued after failure'
: > "$LOG"
# Localhost target: no REMOTE_HOST is requested and ssh/scp are never used.
printf '#!/usr/bin/env bash\nprintf "1000\\n"\n' > "$tmp/bin/id"
chmod +x "$tmp/bin/id"
if REMOTE_HOST='' bash "$tmp/tools/osac-dev-workflow.sh" --check </dev/null > "$tmp/out" 2>&1; then
    fail 'ran privileged host work without root'
fi
grep -q 'as root' "$tmp/out" || fail 'unprivileged localhost run did not name the root requirement'
[[ ! -s "$LOG" ]] || fail 'deployment ran before validation'
printf '#!/usr/bin/env bash\nprintf "0\\n"\n' > "$tmp/bin/id"
: > "$tmp/ssh-log"
REMOTE_HOST='' bash "$tmp/tools/osac-dev-workflow.sh" --check </dev/null
[[ ! -s "$tmp/ssh-log" ]] || fail 'localhost target used ssh'
: > "$LOG"
REMOTE_HOST='' bash "$tmp/tools/osac-dev-workflow.sh" </dev/null
printf 'bootstrap\ngrow-storage\ninstall-infra\nbmh\ndeploy\ndns\n' > "$tmp/expected"
cmp "$LOG" "$tmp/expected" || fail 'localhost target ran the wrong stage order'
[[ ! -s "$tmp/ssh-log" ]] || fail 'localhost target used ssh during the full run'
rm -f "$tmp/bin/id"
: > "$LOG"
if PULL_SECRET_FILE=/missing bash "$tmp/tools/osac-dev-workflow.sh" --check; then fail 'accepted missing secret'; fi
if DEV_ENV_NAME=toolong bash "$tmp/tools/osac-dev-workflow.sh" --check; then fail 'accepted invalid environment name'; fi
if OSAC_DEV_API_RECOVERY_TIMEOUT=9999 bash "$tmp/tools/osac-dev-workflow.sh" --check; then fail 'accepted invalid API recovery timeout before deployment'; fi
: > "$LOG"
if FAIL_STAGE=grow-storage bash "$tmp/tools/osac-dev-workflow.sh"; then fail 'ignored disk growth failure'; fi
printf 'bootstrap\ngrow-storage\n' > "$tmp/expected"
cmp "$LOG" "$tmp/expected" || fail 'installed workloads before disk growth succeeded'
printf 'All workflow tests passed.\n'
