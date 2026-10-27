import contextlib
import io
import json
import os
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from osac_dev.cli import parse_options
from osac_dev.inputs import validate_pull_secret, validate_license, private_input


class InputTests(unittest.TestCase):
    def parse(self, *args, env=None, wrapper=False):
        return parse_options(['plan', '--hub', 'name:hub', *args], env or {}, wrapper=wrapper)

    def test_precedence_and_defaults(self):
        opts = self.parse()
        self.assertEqual(opts.platform, 'ocp')
        self.assertEqual(opts.flavor, 'sno-4-22')
        opts = self.parse('--pull-secret-file', 'cli path', '--cluster-tool-flavor', 'custom', env={'PULL_SECRET_FILE': 'env', 'SNO_FLAVOR': 'env'})
        self.assertEqual(opts.pull_secret_file, 'cli path')
        self.assertEqual(opts.flavor, 'custom')
        self.assertEqual(self.parse(env={'SNO_FLAVOR': 'env'}).flavor, 'env')

    def test_license_locality_and_explicit_suppression(self):
        env = {'AAP_LICENSE_FILE': '/license with spaces.zip', 'REMOTE_HOST': 'root@host'}
        self.assertEqual(self.parse(env=env).license_source, 'local')
        self.assertEqual(self.parse(env=env, wrapper=True).license_source, 'remote')
        self.assertEqual(self.parse(env={'AAP_LICENSE_FILE': 'x', 'REMOTE_HOST': 'localhost'}, wrapper=True).license_source, 'local')
        opts = self.parse('--aap-license-file', 'explicit', env=env, wrapper=True)
        self.assertEqual((opts.license_source, opts.license_file), ('local', 'explicit'))
        opts = self.parse('--aap-license-remote-file', 'remote', env={'AAP_LICENSE_FILE': 'local'})
        self.assertEqual(opts.license_source, 'remote')
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            self.parse('--aap-license-file', 'x', '--aap-license-remote-file', 'y')

    def test_structure_validation_errors_do_not_leak_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'input'
            path.write_text('private-token-do-not-print')
            for validate in (validate_pull_secret, validate_license):
                with self.assertRaises(ValueError) as error:
                    validate(path)
                self.assertNotIn('private-token-do-not-print', str(error.exception))
            path.write_text(json.dumps({'auths': {'registry.example': {'auth': 'synthetic'}}}))
            validate_pull_secret(path)
            path.write_text('{"auths": {}}')
            with self.assertRaises(ValueError):
                validate_pull_secret(path)
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('manifest.json', '{}')
            validate_license(path)

    def test_private_staging_and_cleanup_on_error(self):
        staged = None
        with self.assertRaises(RuntimeError):
            with private_input(b'synthetic') as path:
                staged = path
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
                self.assertEqual(path.read_bytes(), b'synthetic')
                raise RuntimeError('interrupted')
        self.assertFalse(staged.exists())

    def test_parsing_does_not_read_credentials(self):
        with patch.object(Path, 'read_bytes', side_effect=AssertionError('credential read')):
            self.parse('--pull-secret-file', '/missing', '--aap-license-file', '/missing')
