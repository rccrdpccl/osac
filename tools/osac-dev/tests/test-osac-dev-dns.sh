#!/usr/bin/env bash
# Unit/contract boundary: real installer wrapper, fake SSH; no host mutation.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/ssh" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOG"
if [[ "$*" == *'install -m'* ]]; then cat > "$PAYLOAD"; fi
[[ ${SSH_FAIL:-0} == 0 ]]
SSH
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH" LOG="$tmp/log" PAYLOAD="$tmp/payload"
wrapper="$repo/tools/osac-dev/osac-dev-dns.sh"
if [[ ! -x "$wrapper" ]]; then echo 'FAIL: DNS installer wrapper missing' >&2; exit 1; fi
# An unset/empty REMOTE_HOST selects the localhost target: no SSH, and the
# privileged helper install is required before anything runs.
mkdir -p "$tmp/local/bin"
cat > "$tmp/local/bin/id" <<'LOCAL_ID'
#!/usr/bin/env bash
if [[ ${1:-} == -u ]]; then printf '%s\n' "${FAKE_UID:-0}"; exit 0; fi
exec /usr/bin/id "$@"
LOCAL_ID
cat > "$tmp/local/bin/python3" <<'LOCAL_PYTHON'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >> "$LOCAL_LOG"
LOCAL_PYTHON
chmod +x "$tmp/local/bin/id" "$tmp/local/bin/python3"
export LOCAL_LOG="$tmp/local.log"
: > "$LOCAL_LOG"
if PATH="$tmp/local/bin:$PATH" REMOTE_HOST='' FAKE_UID=1000 DEV_ENV_NAME=lab \
    OSAC_DEV_DNS_HELPER="$tmp/local/osac-dev-dns" "$wrapper" > "$tmp/out" 2>&1; then
    echo 'localhost target installed the helper without root' >&2
    exit 1
fi
grep -Fq 'requires root' "$tmp/out"
[[ ! -e "$LOG" ]] || exit 1
[[ ! -e "$tmp/local/osac-dev-dns" ]] || exit 1
REMOTE_HOST=root@fake DEV_ENV_NAME=lab OSAC_DEV_NTP_SERVER=192.0.2.123 "$wrapper"
grep -Fq 'configure lab-dev --ntp 192.0.2.123' "$LOG"
grep -Fq 'def records(' "$PAYLOAD"
if REMOTE_HOST=root@fake DEV_ENV_NAME='../bad' "$wrapper"; then exit 1; fi
if REMOTE_HOST=root@fake SSH_FAIL=1 "$wrapper"; then exit 1; fi
: > "$LOG"
# Baseline repair must work without an API or usable NTP override.
REMOTE_HOST=root@fake DEV_ENV_NAME=lab OSAC_DEV_NTP_SERVER=not-an-ip "$wrapper" --recover
grep -Fq 'recover lab-dev' "$LOG"
if grep -Fq -- '--ntp' "$LOG"; then echo 'recovery incorrectly requires NTP' >&2; exit 1; fi
if grep -Fq 'configure lab-dev' "$LOG"; then echo 'recovery ran full DNS sync' >&2; exit 1; fi
: > "$LOG"
REMOTE_HOST=root@fake DEV_ENV_NAME=lab "$wrapper" --install-only
grep -Fq 'install -m' "$LOG"
if grep -Fq 'python3 /usr/local/sbin/osac-dev-dns ' "$LOG"; then exit 1; fi
: > "$LOG"
REMOTE_HOST=root@fake DEV_ENV_NAME=lab "$wrapper" --remove
grep -Fq 'remove lab-dev' "$LOG"
# --- localhost target -------------------------------------------------------
: > "$LOG"
: > "$LOCAL_LOG"
PATH="$tmp/local/bin:$PATH" REMOTE_HOST='' DEV_ENV_NAME=lab \
    OSAC_DEV_DNS_HELPER="$tmp/local/osac-dev-dns" "$wrapper" --install-only
[[ -x "$tmp/local/osac-dev-dns" ]] || { echo 'localhost helper was not installed' >&2; exit 1; }
[[ ! -s "$LOG" ]] || { echo 'localhost target used ssh' >&2; exit 1; }
[[ ! -s "$LOCAL_LOG" ]] || { echo 'install-only ran the helper locally' >&2; exit 1; }
PATH="$tmp/local/bin:$PATH" REMOTE_HOST='' DEV_ENV_NAME=lab \
    OSAC_DEV_DNS_HELPER="$tmp/local/osac-dev-dns" OSAC_DEV_NTP_SERVER=192.0.2.123 \
    "$wrapper"
grep -Fq "python3 $tmp/local/osac-dev-dns configure lab-dev --ntp 192.0.2.123" "$LOCAL_LOG"
[[ ! -s "$LOG" ]] || { echo 'localhost target used ssh' >&2; exit 1; }
printf 'All DNS installer tests passed.\n'
