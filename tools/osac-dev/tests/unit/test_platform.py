import contextlib
import io
import unittest
from pathlib import Path
from unittest.mock import patch

from osac_dev.cli import parse_options
from osac_dev.platform import select_platform


class PlatformTests(unittest.TestCase):
    def test_kind_before_reference_or_credential_reads(self):
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('read')), patch('osac_dev.cli.Reference.parse', side_effect=AssertionError('resolve')), contextlib.redirect_stderr(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as error:
                parse_options(['plan', '--hub', 'invalid', '--platform', 'kind', '--pull-secret-file', '/missing'], {})
        self.assertEqual(error.exception.code, 2)
        self.assertIn('not implemented', output.getvalue())

    def test_ocp_profile_boundary(self):
        self.assertEqual(select_platform('ocp').installer_profile, 'openshift')
        self.assertIn('config.openshift.io', select_platform('ocp').required_apis)
