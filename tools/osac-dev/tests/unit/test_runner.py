import subprocess
import unittest
from unittest.mock import patch

from osac_dev.runner import CommandError, Runner


class RunnerTests(unittest.TestCase):
    def test_backend_failures_do_not_print_output_or_credential_arguments(self):
        result = subprocess.CompletedProcess([], 1, 'synthetic-secret', 'synthetic-secret')
        with patch('osac_dev.runner.subprocess.run', return_value=result):
            with self.assertRaises(CommandError) as error:
                Runner().run(['helm', '--password', 'synthetic-secret'])
        self.assertNotIn('synthetic-secret', str(error.exception))

    def test_timeout_is_bounded_and_redacted(self):
        with patch('osac_dev.runner.subprocess.run', side_effect=subprocess.TimeoutExpired(['oc', 'synthetic-secret'], 5)) as run:
            with self.assertRaises(CommandError) as error:
                Runner().run(['oc', 'synthetic-secret'], timeout=5)
        self.assertEqual(run.call_args.kwargs['timeout'], 5)
        self.assertNotIn('synthetic-secret', str(error.exception))
