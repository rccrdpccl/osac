#!/usr/bin/env bash
# Install persistent lab DNS on the selected cluster-tool host. No baked-in IPs.
#
# REMOTE_HOST selects the target: unset or `localhost` installs and runs the
# helper on this machine, anything else installs it over root SSH.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tools/osac-dev/osac-dev-target.sh
source "$script_dir/osac-dev-target.sh"
REMOTE_HOST=${REMOTE_HOST:-}
DEV_ENV_NAME=${DEV_ENV_NAME:-osac}
OSAC_DEV_NTP_SERVER=${OSAC_DEV_NTP_SERVER:-}
# Same override the host lifecycle script uses, so tests and operators can
# relocate the helper consistently.
OSAC_DEV_DNS_HELPER=${OSAC_DEV_DNS_HELPER:-/usr/local/sbin/osac-dev-dns}
fail() { printf 'osac-dev-dns: %s\n' "$*" >&2; exit 1; }
action=configure
case "$*" in
    '') ;;
    --recover) action=recover ;;
    --remove) action=remove ;;
    --install-only) action=install ;;
    *) fail 'usage: osac-dev-dns.sh [--recover|--remove|--install-only]' ;;
esac
osac_dev_target_init
[[ "$DEV_ENV_NAME" =~ ^[a-z0-9]{1,4}$ ]] || fail 'invalid DEV_ENV_NAME'
[[ "$OSAC_DEV_DNS_HELPER" == /* && "$OSAC_DEV_DNS_HELPER" != *$'\n'* ]] || \
    fail 'OSAC_DEV_DNS_HELPER must be an absolute path'
if [[ "$action" == configure ]]; then
    [[ -z "$OSAC_DEV_NTP_SERVER" || "$OSAC_DEV_NTP_SERVER" =~ ^[0-9.]+$ ]] || fail 'OSAC_DEV_NTP_SERVER must be a reachable IPv4 NTP address'
fi
osac_dev_require_transport
# Atomically upgrade the helper; never execute a partially copied script.
osac_dev_host_install_dns_helper "$script_dir/osac-dev-dns-remote.py" "$OSAC_DEV_DNS_HELPER" || \
    fail 'could not install host DNS helper'
[[ "$action" != install ]] || exit 0
args="$action ${DEV_ENV_NAME}-dev"
if [[ "$action" == configure && -n "$OSAC_DEV_NTP_SERVER" ]]; then
    args+=" --ntp $OSAC_DEV_NTP_SERVER"
fi
# The action, clone ID and optional IPv4 value are validated above.
osac_dev_host_run "PATH=\"\$HOME/.local/bin:\$PATH\" python3 $(printf '%q' "$OSAC_DEV_DNS_HELPER") $args" || \
    fail "DNS $action failed; inspect host logs/configuration before running CaaS tests"
