import shlex
import tempfile
import unittest
from pathlib import Path

from osac_dev.host import HostExecutor
from osac_dev.state import State
from test_targets import RecordingRunner


class HostTests(unittest.TestCase):
    def test_local_and_ssh_arguments_are_not_program_interpolation(self):
        args = ['cat', '--', '/path with spaces/$(touch bad)']
        for host in (None, 'localhost', 'root@host'):
            runner = RecordingRunner(['data'])
            self.assertEqual(HostExecutor(runner, host).read_file(args[-1]), b'data')
            command = runner.calls[0]
            if host == 'root@host':
                self.assertEqual(command[:-1], ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '--', host])
                self.assertEqual(shlex.split(command[-1]), args)
            else:
                self.assertEqual(command, args)

    def test_unsafe_hosts_rejected(self):
        for host in ('-oProxyCommand=bad', 'host;bad', 'host name'):
            with self.assertRaises(ValueError):
                HostExecutor(RecordingRunner(), host)

    def test_private_state_and_lock_exclusion(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = State(Path(tmp) / 'state')
            with state.lock('target'):
                with self.assertRaisesRegex(ValueError, 'locked'):
                    with state.lock('target'):
                        pass
                state.record('target', {'fingerprint': 'public'})
            self.assertEqual(state.load('target')['fingerprint'], 'public')
            self.assertEqual(state.root.stat().st_mode & 0o777, 0o700)
            self.assertEqual(next(state.root.glob('*.json')).stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, 'field'):
                state.record('target', {'password': 'never stored'})
