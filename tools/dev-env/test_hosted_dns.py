"""Hosted DNS publisher tests with a fake hub and hypervisor."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class HostedDNS(unittest.TestCase):
    def test_dry_run_publishes_claimed_vip_and_prunes_only_own_hub(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            config = home / 'config'
            config.touch()
            orders = {
                'items': [{
                    'metadata': {'uid': 'order-uid', 'namespace': 'osac', 'name': 'order-1'},
                    'status': {'clusterReference': {'hostedClusterName': 'guest-1', 'namespace': 'clusters'}},
                }],
            }
            fixtures = {
                'kubectl': (
                    'case "$2" in\n'
                    '  namespace) echo hub-uid ;;\n'
                    '  clusterorder) printf "%s\\n" "$ORDERS" ;;\n'
                    '  ingress.config.openshift.io) echo apps.dev.test ;;\n'
                    '  hostedcluster) echo hosted.dev.test ;;\n'
                    '  service) echo 192.0.2.240 ;;\n'
                    '  configmap) echo \'{"data":{"order-uid":"192.0.2.124 osac/order-1"}}\' ;;\n'
                    '  *) exit 1 ;;\n'
                    'esac'
                ),
                'ssh': (
                    'case "${!#}" in\n'
                    '  ls*) printf "%s\\n" /etc/NetworkManager/dnsmasq.d/hosted-{hub-uid,other-hub}-stale.conf ;;\n'
                    '  cat*hub-uid-stale.conf*) echo "# managed by tools/dev-env/hosted-dns.sh" ;;\n'
                    '  *) exit 1 ;;\n'
                    'esac'
                ),
            }
            for name, body in fixtures.items():
                stub = home / name
                stub.write_text(f'#!/bin/bash\n{body}\n')
                stub.chmod(0o755)
            result = subprocess.run(
                ['bash', str(HERE / 'hosted-dns.sh'), '--dry-run'],
                env={
                    'PATH': f'{home}:{os.environ["PATH"]}',
                    'HOME': tmp,
                    'OSAC_DEV_HUB_KUBECONFIG': str(config),
                    'REMOTE_HOST': 'root@dev-hypervisor',
                    'ORDERS': json.dumps(orders),
                },
                capture_output=True, text=True, timeout=10,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('address=/api.guest-1.hosted.dev.test/192.0.2.240', result.stdout)
        self.assertIn('address=/.apps.guest-1.hosted.dev.test/192.0.2.124', result.stdout)
        self.assertIn('would remove /etc/NetworkManager/dnsmasq.d/hosted-hub-uid-stale.conf', result.stdout)
        self.assertNotIn('other-hub', result.stdout)


if __name__ == '__main__':
    unittest.main()
