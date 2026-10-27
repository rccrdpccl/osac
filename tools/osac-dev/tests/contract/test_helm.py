"""Real CLI checks are offline; recorded release shapes do not prove live Helm."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from osac_dev.reconcile import Helm
from osac_dev.model import Reference, Target
from osac_dev.runner import CommandError


class RecordingRunner:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []

    def run(self, args, **kwargs):
        self.calls.append(list(map(str, args)))
        result = next(self.responses)
        if isinstance(result, Exception):
            raise result
        return result


class HelmContracts(unittest.TestCase):
    def setUp(self):
        self.target = Target(Reference.parse('kubeconfig:/tmp/config with spaces'), Path('/tmp/config with spaces'), 'hub-context', 'https://api')

    def test_list_all_statuses_without_helm4_incompatible_all_flag(self):
        for version in ('v3.16.3', 'v4.2.0'):
            runner = RecordingRunner([json.dumps([{'name': 'osac-infra', 'namespace': 'osac', 'status': 'pending-upgrade', 'chart': 'osac-infra-1.0.0'}])])
            release = Helm(runner, self.target, 'osac', 'osac-infra').inspect_release()
            self.assertEqual(release['status'], 'pending-upgrade')
            args = runner.calls[0]
            self.assertNotIn('--all', args, version)
            for flag in ('--deployed', '--failed', '--pending', '--uninstalled', '--uninstalling', '--superseded'):
                self.assertIn(flag, args)
            self.assertEqual(args[args.index('--kubeconfig') + 1], str(self.target.kubeconfig))
            self.assertEqual(args[args.index('--kube-context') + 1], 'hub-context')
            self.assertEqual(args[args.index('--namespace') + 1], 'osac')

    def test_absence_errors_unknown_shapes_and_exact_name(self):
        self.assertIsNone(Helm(RecordingRunner(['[]']), self.target, 'osac', 'infra').inspect_release())
        for output in ('{}', '[{}]', '[{"name":"other","status":"deployed"}]', CommandError('denied')):
            with self.subTest(output=output), self.assertRaises((ValueError, CommandError)):
                Helm(RecordingRunner([output]), self.target, 'osac', 'infra').inspect_release()

    def test_upgrade_arguments_and_no_force_ownership(self):
        runner = RecordingRunner([''])
        Helm(runner, self.target, 'osac', 'infra').upgrade(Path('/chart with spaces'), [Path('/values one.yaml')], timeout=300)
        args = runner.calls[0]
        self.assertEqual(args[:4], ['helm', 'upgrade', '--install', 'infra'])
        self.assertNotIn('--take-ownership', args)
        self.assertNotIn('--force', args)
        self.assertIn('--wait', args)
        self.assertIn('300s', args)

    def test_real_installed_helm_cli_contracts_without_cluster_access(self):
        executables = [p for p in (shutil.which('helm'), os.environ.get('OSAC_DEV_TEST_HELM4')) if p]
        if not executables:
            self.skipTest('Helm not installed; real CLI checks unavailable')
        for executable in executables:
            with self.subTest(executable=executable):
                result = subprocess.run([executable, 'version', '--template', '{{.Version}}'], capture_output=True, text=True, check=True)
                self.assertRegex(result.stdout, r'^v[34]\.')
                help_text = subprocess.run([executable, 'list', '--help'], capture_output=True, text=True, check=True).stdout
                for flag in Helm.STATUS_FLAGS:
                    self.assertIn(flag, help_text)
                upgrade_help = subprocess.run([executable, 'upgrade', '--help'], capture_output=True, text=True, check=True).stdout
                for flag in ('--install', '--wait', '--timeout', '--kube-context', '--namespace'):
                    self.assertIn(flag, upgrade_help)
                with tempfile.TemporaryDirectory() as tmp:
                    chart = Path(tmp)
                    (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: fixture\nversion: 1.0.0\n')
                    (chart / 'templates').mkdir()
                    (chart / 'templates/cm.yaml').write_text('apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fixture\n')
                    rendered = subprocess.run([executable, 'template', 'fixture', str(chart), '--namespace', 'osac'], capture_output=True, text=True, check=True)
                    self.assertIn('kind: ConfigMap', rendered.stdout)
