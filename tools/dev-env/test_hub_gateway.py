"""Unit tests for the dev hub gateway flow; no real SSH or libvirt calls."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
FAKE = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

cmd, *args = sys.argv
cmd = Path(cmd).name
with open(os.environ['CALLS'], 'a') as stream:
    print(json.dumps([cmd, *args]), file=stream)
if cmd == 'virsh':
    if args[0] == 'domiflist':
        print('vnet0 network test-infra-net-dev virtio 02:00:00:bb:cc:01')
        print('vnet1 network test-infra-secondary-network-dev virtio 02:00:00:bb:cc:02')
    elif args[0] == 'net-dhcp-leases':
        if not os.environ.get('NO_LEASE'):
            print('2026-01-01 11:23:45 02:00:00:bb:cc:01 ipv4 192.168.161.10/24 test-infra-cluster-dev-master-0')
    else:
        sys.exit(1)
elif cmd == 'ssh':
    if 'root@lab' in args:
        if args[-1].startswith('test -f ') or args[-1].startswith('sed -n '):
            sys.exit(0)
        if not args[-1].startswith('bash -s -- '):
            sys.exit(1)
        sys.exit(int(os.environ.get('REMOTE_EXIT', '0')))
    if 'core@192.168.161.10' not in args:
        sys.exit(1)
    replies = Path(os.environ['REPLIES'])
    response, *remaining = replies.read_text().splitlines()
    replies.write_text('\\n'.join(remaining))
    if response == 'mismatch':
        print('gateway is on the secondary network', file=sys.stderr)
        sys.exit(3)
    print(response)
elif cmd == 'cluster-tool':
    print('header\\n------')
    if args[0] == 'flavors':
        print('sno-4-22')
    elif args[0] == 'list' and os.environ.get('EXISTING') == '1':
        print('dev')
"""


class HubGatewayTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.tmp = Path(temp.name)
        for name in ['virsh', 'ssh', 'curl', 'sleep', 'cluster-tool', 'kubectl']:
            stub = self.tmp / name
            stub.write_text(FAKE)
            stub.chmod(0o755)
        self.calls = self.tmp / 'calls'
        self.calls.touch()
        self.replies = self.tmp / 'replies'
        self.key = self.tmp / 'fake-identity'
        self.key.touch()
        self.secret = self.tmp / 'fake-pull-secret'
        self.secret.touch()
        self.servers = self.tmp / 'servers.json'
        self.servers.write_text('{"servers":{"dev":{"host":"root@lab"}}}')
        self.env = {
            'HOME': temp.name,
            'PATH': f'{temp.name}:{os.environ["PATH"]}',
            'CALLS': str(self.calls),
            'REPLIES': str(self.replies),
            'CLUSTER_TOOL_SERVERS': str(self.servers),
            'CLUSTER_NAME': 'dev',
            'SERVER_NAME': 'dev',
            'REMOTE_HOST': 'root@lab',
            'PULL_SECRET_FILE': str(self.secret),
        }

    def run_script(self, script, *args):
        result = subprocess.run(
            ['bash', str(HERE / script), *args], env=self.env,
            capture_output=True, text=True, timeout=10,
        )
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return result, calls

    def gateway(self, mode, *replies):
        self.replies.write_text('\n'.join(replies))
        return self.run_script(
            'hub-gateway.sh', mode, 'test-infra-cluster-dev-master-0',
            'test-infra-net-dev', str(self.key),
        )

    def test_aligned_clone_needs_no_reboot(self):
        result, calls = self.gateway('repair', 'ready boot-a')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ['virsh', 'virsh', 'ssh'])

    def test_mismatched_clone_is_not_rebooted_in_check_mode(self):
        result, calls = self.gateway('check', 'mismatch')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--repair-gateway', result.stderr)
        self.assertEqual([call[0] for call in calls], ['virsh', 'virsh', 'ssh'])
        self.assertIn('check', calls[-1][-1].split())

    def test_repair_refuses_to_ssh_without_a_primary_lease(self):
        self.env['NO_LEASE'] = '1'
        result, calls = self.gateway('repair')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('expected one IPv4 lease', result.stderr)
        self.assertEqual([call[0] for call in calls], ['virsh', 'virsh'])

    def test_repair_waits_for_new_boot_before_checking_api(self):
        result, calls = self.gateway('repair', 'rebooting boot-a', 'ready boot-a', 'ready boot-b')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('192.168.161.10:6443/readyz', ' '.join(calls[-1]))
        self.assertEqual([call[0] for call in calls].count('ssh'), 3)
        self.assertEqual([call[0] for call in calls].count('curl'), 1)

    def test_new_clone_enables_repair_after_boot(self):
        result, calls = self.run_script('cluster.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('boot', calls[-2])
        self.assertIn('repair', calls[-1][-1].split())

    def test_existing_clone_only_checks(self):
        self.env['EXISTING'] = '1'
        result, calls = self.run_script('cluster.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('check', calls[-1][-1].split())
        self.assertFalse(any('boot' in call for call in calls))

    def test_gateway_check_failure_stops_provisioning(self):
        self.env.update(EXISTING='1', REMOTE_EXIT='1')
        result, _ = self.run_script('cluster.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('ready: export KUBECONFIG', result.stdout)

    def test_explicit_repair_does_not_need_a_pull_secret(self):
        del self.env['PULL_SECRET_FILE']
        result, calls = self.run_script('cluster.sh', '--repair-gateway')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('repair', calls[-1][-1].split())
        self.assertFalse(any(call[0] == 'cluster-tool' for call in calls))

    def test_explicit_reuse_does_not_touch_the_hypervisor(self):
        kubeconfig = self.tmp / 'kubeconfig'
        kubeconfig.touch()
        self.env['OSAC_DEV_HUB_KUBECONFIG'] = str(kubeconfig)
        result, calls = self.run_script('cluster.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(calls)
        self.assertTrue(all(call[0] == 'kubectl' for call in calls))

    def test_explicit_repair_refuses_an_external_kubeconfig(self):
        self.env['OSAC_DEV_HUB_KUBECONFIG'] = str(self.tmp / 'some-hub')
        result, calls = self.run_script('cluster.sh', '--repair-gateway')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('only for cluster-tool clones', result.stderr)
        self.assertEqual(calls, [])

    def test_server_alias_cannot_point_at_another_hypervisor(self):
        self.servers.write_text('{"servers":{"dev":{"host":"root@other"}}}')
        result, calls = self.run_script('cluster.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('root@other', result.stderr)
        self.assertFalse(any(call[0] in ('ssh', 'cluster-tool') for call in calls))


if __name__ == '__main__':
    unittest.main()
