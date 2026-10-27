import tempfile
import unittest
from pathlib import Path

from osac_dev.fingerprints import fingerprint, owned_matches


class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.chart = Path(self.tmp.name)
        (self.chart / 'templates').mkdir()
        (self.chart / 'Chart.yaml').write_text('name: fixture\nversion: 1.0.0\n')
        (self.chart / 'values.yaml').write_text('replicas: 1\n')
        (self.chart / 'templates/hook.yaml').write_text('initial hook')

    def digest(self, **kwargs):
        return fingerprint(self.chart, platform='ocp', values=kwargs.get('values', [{'replicas': 1}]), dependencies=kwargs.get('dependencies', {'image': 'sha256:a'}))

    def test_same_version_template_hook_values_and_dependency_changes(self):
        original = self.digest()
        self.assertEqual(original, self.digest())
        (self.chart / 'templates/hook.yaml').write_text('changed hook')
        self.assertNotEqual(original, self.digest())
        after = self.digest()
        self.assertNotEqual(after, self.digest(dependencies={'image': 'sha256:b'}))
        self.assertNotEqual(after, self.digest(values=[{'replicas': 2}]))
        self.assertNotEqual(after, fingerprint(self.chart, platform='other', values=[{'replicas': 1}], dependencies={'image': 'sha256:a'}))

    def test_chart_file_payload_changes_identity(self):
        (self.chart / 'config').mkdir()
        payload = self.chart / 'config/settings.conf'
        payload.write_text('first')
        original = self.digest()
        payload.write_text('second')
        self.assertNotEqual(original, self.digest())

    def test_mapping_order_canonical_list_and_layer_order_preserved(self):
        self.assertEqual(self.digest(values=[{'a': 1, 'b': 2}]), self.digest(values=[{'b': 2, 'a': 1}]))
        self.assertNotEqual(self.digest(values=[{'a': 1}, {'a': 2}]), self.digest(values=[{'a': 2}, {'a': 1}]))
        self.assertNotEqual(self.digest(values=[{'a': [1, 2]}]), self.digest(values=[{'a': [2, 1]}]))

    def test_only_chart_sources_not_paths_times_caches_or_unrelated_files(self):
        original = self.digest()
        for name in ('README.md', '.env'):
            (self.chart / name).write_text('not a chart input')
        (self.chart / 'templates/__pycache__').mkdir()
        (self.chart / 'templates/__pycache__/runtime.pyc').write_bytes(b'cache')
        self.assertEqual(original, self.digest())
        (self.chart / 'Chart.lock').write_text('dependency identity')
        self.assertNotEqual(original, self.digest())

    def test_escaping_symlink_and_secret_values_rejected_without_echo(self):
        for values in ([{'password': 'never-print-me'}], [{'nested': {'token': 'never-print-me'}}]):
            with self.assertRaises(ValueError) as error:
                self.digest(values=values)
            self.assertNotIn('never-print-me', str(error.exception))
        (self.chart / 'templates/escape').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.digest()

    def test_owned_projection_ignores_defaults_and_status_not_drift(self):
        desired = {'spec': {'replicas': 1, 'ports': [{'port': 443}]}}
        actual = {'spec': {'replicas': 1, 'ports': [{'port': 443, 'protocol': 'TCP'}], 'defaulted': True}, 'status': {'ready': True}}
        self.assertTrue(owned_matches(desired, actual))
        actual['spec']['replicas'] = 2
        self.assertFalse(owned_matches(desired, actual))
        self.assertFalse(owned_matches(desired, {}))
