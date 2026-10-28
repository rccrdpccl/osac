#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/oc" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$LOG"
case "$1 $2" in
    'get provisioning') [[ ${PRESENT:-0} == 1 ]] ;;
    'get nodes') printf '192.0.2.10' ;;
    'apply --server-side') cat > "$SPEC" ;;
    'patch provisioning') ;;
    *) exit 99 ;;
esac
FAKE
chmod +x "$tmp/bin/oc"
export PATH="$tmp/bin:$PATH" LOG="$tmp/log" SPEC="$tmp/spec"
bash "$repo/tools/osac-dev/osac-dev-provisioning.sh"
grep -q 'provisioningIP: "192.0.2.10"' "$SPEC"
rm "$SPEC"
PRESENT=1 bash "$repo/tools/osac-dev/osac-dev-provisioning.sh"
[[ ! -e "$SPEC" ]] || { printf 'FAIL: existing Provisioning addresses overwritten\n'; exit 1; }
printf 'All Provisioning tests passed.\n'
