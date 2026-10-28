#!/usr/bin/env python3
"""Execute the actual carried node script; only node commands are doubles."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


# Model nmcli's controller activation returning before STP/DHCP finishes.
# Fake sleep advances time; no host network changes or real waits occur.
COMMAND = r'''#!/usr/bin/env bash
set -euo pipefail
source "$FAKE_ROOT/state"
trap 'printf "tick=%s\nbridge_exists=%s\nslave_exists=%s\nenslaved=%s\nnic_ipv4=%s\n" "$tick" "$bridge_exists" "$slave_exists" "$enslaved" "$nic_ipv4" > "$FAKE_ROOT/state"' EXIT
command=${0##*/}
printf '%s %s\n' "$command" "$*" >> "$FAKE_ROOT/commands"
case "$command:$*" in
    'sleep:1') tick=$((tick + 1)) ;;
    'cat:/sys/class/net/enp2s0/address') printf '02:00:00:00:00:02\n' ;;
    'ip:link show br-bmh') ((bridge_exists)) || exit 1; printf 'br-bmh: UP\n' ;;
    'ip:link show enp2s0')
        if ((enslaved)); then printf 'enp2s0: master br-bmh UP\n'; else printf 'enp2s0: UP\n'; fi ;;
    'ip:-4 -o addr show dev enp2s0')
        if ((nic_ipv4)); then printf '3: enp2s0 inet 192.0.2.10/24\n'; fi ;;
    'ip:-4 -o addr show dev br-bmh')
        if ((enslaved && tick >= READY_AT)); then printf '4: br-bmh inet 192.0.2.10/24\n'; fi ;;
    'nmcli:device show enp2s0'|'nmcli:-g GENERAL.STATE device show enp2s0') printf '100 (connected)\n' ;;
    'nmcli:-g GENERAL.STATE device show br-bmh') printf '30 (disconnected)\n' ;;
    'nmcli:con show br-bmh') ((bridge_exists)) || exit 1 ;;
    'nmcli:con show br-bmh-enp2s0') ((slave_exists)) || exit 1 ;;
    'nmcli:-t -f NAME,DEVICE con show --active')
        if ((nic_ipv4)); then printf 'Wired connection 2:enp2s0\n'; fi ;;
    'nmcli:-g ipv4.method con show Wired connection 2') printf 'auto\n' ;;
    'nmcli:-g ipv4.addresses con show Wired connection 2'|'nmcli:-g ipv4.gateway con show Wired connection 2'|'nmcli:-g ipv4.dns con show Wired connection 2') : ;;
    'nmcli:con add type bridge ifname br-bmh con-name br-bmh') bridge_exists=1 ;;
    'nmcli:con add type bridge-slave ifname enp2s0 master br-bmh con-name br-bmh-enp2s0') slave_exists=1 ;;
    'nmcli:con mod br-bmh bridge.mac-address '*|'nmcli:con mod br-bmh-enp2s0 connection.autoconnect yes'|'nmcli:con mod Wired connection 2 connection.autoconnect no') : ;;
    'nmcli:con down Wired connection 2') nic_ipv4=0 ;;
    'nmcli:con up br-bmh') printf 'Connection successfully activated (controller waiting for ports)\n' ;;
    'nmcli:con up br-bmh-enp2s0') enslaved=1 ;;
    *) printf 'Unexpected node command: %s %s\n' "$command" "$*" >&2; exit 90 ;;
esac
'''


class BridgeScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = (Path(__file__).resolve().parents[1] / 'osac-dev-bmh.sh').read_text()
        script = source.split("<<'NODESCRIPT'\n", 1)[1].split('\nNODESCRIPT\n', 1)[0]
        self.script = self.root / 'node.sh'
        self.script.write_text(script)
        binary = self.root / 'bin'
        binary.mkdir()
        command = binary / 'node-command'
        command.write_text(COMMAND)
        command.chmod(0o755)
        for name in ('ip', 'nmcli', 'cat', 'sleep'):
            (binary / name).symlink_to(command)
        self.path = str(binary) + os.pathsep + os.environ['PATH']

    def execute(self, ready_at, healthy=False):
        state = 'tick=0\nbridge_exists=0\nslave_exists=0\nenslaved=0\nnic_ipv4=1\n'
        if healthy:
            state = 'tick=0\nbridge_exists=1\nslave_exists=1\nenslaved=1\nnic_ipv4=0\n'
        (self.root / 'state').write_text(state)
        return subprocess.run(
            ['bash', str(self.script), 'enp2s0', 'br-bmh'],
            env={**os.environ, 'PATH': self.path, 'FAKE_ROOT': str(self.root), 'READY_AT': str(ready_at)},
            text=True, capture_output=True, timeout=30,
        )

    def test_fresh_bridge_waits_for_stp_then_dhcp(self):
        result = self.execute(ready_at=33)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('BRIDGE_IPV4=192.0.2.10', result.stdout)
        self.assertIn('tick=33\n', (self.root / 'state').read_text())

    def test_immediate_dhcp_does_not_wait(self):
        result = self.execute(ready_at=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('tick=0\n', (self.root / 'state').read_text())

    def test_missing_dhcp_has_bounded_failure(self):
        result = self.execute(ready_at=1000)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('br-bmh has no IPv4 address', result.stderr)
        tick = int((self.root / 'state').read_text().splitlines()[0].split('=')[1])
        self.assertLessEqual(tick, 120)
        self.assertNotIn('BRIDGE_IPV4=', result.stdout)

    def test_healthy_bridge_does_not_flap(self):
        result = self.execute(ready_at=0, healthy=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('already healthy', result.stdout)
        self.assertNotIn('nmcli', (self.root / 'commands').read_text())


if __name__ == '__main__':
    unittest.main()
