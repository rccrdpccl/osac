#!/usr/bin/env python3
"""Execute real access/recovery polling with a virtual clock, never live SSH."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'osac-dev-install-infra.sh'


class APIWaitTests(unittest.TestCase):
    def execute(self, ready_at, timeout=None, restored=1):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            # Load actual functions and defaults, without invoking the installer.
            code = SOURCE.read_text()
            self.assertTrue(code.rstrip().endswith('main "$@"'))
            (root / 'installer.sh').write_text(code.rsplit('\nmain "$@"', 1)[0] + '\n')
            # Keep the wrapper's sourced dependencies beside the extracted
            # functions, just as in the real workflow directory.
            for name in ('osac-dev-target.sh', 'osac-dev-helm.sh'):
                shutil.copy(SOURCE.with_name(name), root / name)
            helper = root / 'osac-dev-dns.sh'
            helper.write_text('#!/bin/sh\nprintf "RECOVERED_LISTENERS=%s\\n" "$RESTORED"\n')
            helper.chmod(0o755)
            (root / 'run').mkdir()
            harness = r'''
source "$TEST_ROOT/installer.sh"
TEMP_DIR="$TEST_ROOT/run"
REMOTE_HOST=root@fake
osac_dev_target_init
DEV_ENV_NAME=osac
API_TLS_NAME=api.example.test
# Transport/liveness are doubles; only readiness polling and time are under test.
ssh() { :; }
kill() { :; }
set_api_endpoint() { :; }
api_ready() { ((SECONDS >= READY_AT)); }
# Ten virtual seconds per iteration makes timeouts deterministic and fast.
sleep() { SECONDS=$((SECONDS + 10)); }
trap 'rc=$?; printf "VIRTUAL_SECONDS=%s\n" "$SECONDS"; cleanup; exit "$rc"' EXIT
SECONDS=0
recover_host_dns
start_ssh_tunnel
'''
            env = {**os.environ, 'TEST_ROOT': temp, 'READY_AT': str(ready_at), 'RESTORED': str(restored)}
            env.pop('OSAC_DEV_API_RECOVERY_TIMEOUT', None)
            if timeout is not None:
                env['OSAC_DEV_API_RECOVERY_TIMEOUT'] = str(timeout)
            result = subprocess.run(['bash', '-c', harness], env=env, text=True,
                                    capture_output=True, timeout=10)
            clock = re.search(r'VIRTUAL_SECONDS=(\d+)', result.stdout)
            self.assertIsNotNone(clock, result.stdout + result.stderr)
            return result, int(clock[1])

    def test_readiness_after_dhcp_backoff_and_control_plane_restart(self):
        # Observed live: DNS restored 08:37:51, API ready 08:45:12 (441s).
        result, elapsed = self.execute(ready_at=441)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreaterEqual(elapsed, 441)
        self.assertIn('API is reachable through the SSH tunnel', result.stdout)
        self.assertIn('Still waiting for SNO API', result.stdout)

    def test_healthy_api_returns_without_waiting(self):
        result, elapsed = self.execute(ready_at=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(elapsed, 0)

    def test_user_timeout_is_bounded_and_not_overwritten_by_recovery(self):
        result, elapsed = self.execute(ready_at=1000, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertGreaterEqual(elapsed, 30)
        self.assertLess(elapsed, 40)
        self.assertIn('configured wait 30s', result.stderr)

    def test_recent_recovery_can_finish_on_rerun_without_new_missing_listener(self):
        result, elapsed = self.execute(ready_at=441, restored=0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreaterEqual(elapsed, 441)


if __name__ == '__main__':
    unittest.main()
