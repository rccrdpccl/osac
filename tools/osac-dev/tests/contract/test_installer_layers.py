"""Installer rendering and recorded API/Helm boundaries, never live readiness."""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from osac_dev import infrastructure as infra
from osac_dev.model import Reference, Target
from osac_dev.reconcile import Desired, Policy, reconcile
from osac_dev.runner import CommandError

ROOT = Path(__file__).resolve().parents[4]
INSTALLER = ROOT / 'osac-installer'


class Runner:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []

    def run(self, args, **kwargs):
        self.calls.append((list(map(str, args)), kwargs))
        response = next(self.responses)
        if isinstance(response, Exception):
            raise response
        return response


class InstallerContracts(unittest.TestCase):
    def setUp(self):
        self.target = Target(Reference.parse('kubeconfig:/tmp/config with spaces'), Path('/tmp/config with spaces'), 'hardware-context', 'https://hardware')

    def test_oc_absence_is_not_rbac_failure_and_scope_is_explicit(self):
        runner = Runner(['', CommandError('denied')])
        api = infra.InfrastructureAPI(runner)
        self.assertEqual(api.get(self.target, 'deployment/webhook', namespace='cert-manager'), {})
        with self.assertRaises(CommandError):
            api.get(self.target, 'deployment/webhook', namespace='cert-manager')
        args = runner.calls[0][0]
        self.assertIn('--ignore-not-found', args)
        self.assertEqual(args[args.index('--context') + 1], 'hardware-context')
        self.assertEqual(args[args.index('--namespace') + 1], 'cert-manager')
        self.assertEqual(args[args.index('--kubeconfig') + 1], '/tmp/config with spaces')

    def test_admission_probe_is_server_dry_run_and_never_persists_certificate(self):
        runner = Runner([''])
        infra.InfrastructureAPI(runner).admission_probe(self.target, 'cert-manager')
        args, kwargs = runner.calls[0]
        self.assertIn('--dry-run=server', args)
        obj = json.loads(kwargs['input'])
        self.assertEqual(obj['kind'], 'Certificate')
        self.assertEqual(obj['metadata']['namespace'], 'cert-manager')
        self.assertNotIn('Secret', kwargs['input'])

    def test_layer_inspects_live_objects_and_never_applies_on_healthy_rerun(self):
        manifest = {'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {'name': 'settings', 'namespace': 'osac'}, 'data': {'mode': 'wanted'}}
        live = dict(manifest, metadata=dict(manifest['metadata'], annotations={'meta.helm.sh/release-name': 'osac-deps', 'meta.helm.sh/release-namespace': 'osac'}))
        runner = Runner([json.dumps({'items': [live]})])
        class Helm:
            target = self.target
            release = 'osac-deps'
            namespace = 'osac'
            def inspect_release(self):
                return {'status': 'deployed', 'chart': 'osac-deps-0.0.1'}
            def upgrade(self, *args, **kwargs):
                raise AssertionError('healthy match must not upgrade')
        desired = Desired('osac-deps', '0.0.1', 'matching')
        records = []
        adapter = infra.InstallerLayer(Helm(), infra.InfrastructureAPI(runner), desired, Path('/chart'), (), [manifest],
                                       health=lambda: True, marker=lambda: 'matching', record=records.append, authorized=True)
        self.assertEqual(reconcile(desired, adapter, Policy(allow_upgrade=True)).action, 'reuse')
        self.assertEqual(records, [])
        args = runner.calls[0][0]
        self.assertIn('--ignore-not-found', args)
        self.assertIn('--namespace', args)

    def test_apply_verifies_content_before_record_and_foreign_changes_are_denied(self):
        manifest = {'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {'name': 'settings', 'namespace': 'osac'}, 'data': {'mode': 'wanted'}}
        live = dict(manifest, metadata=dict(manifest['metadata'], annotations={'meta.helm.sh/release-name': 'osac-deps', 'meta.helm.sh/release-namespace': 'osac'}))
        binding = self.target
        class Helm:
            target = binding
            namespace, release = 'osac', 'osac-deps'
            def __init__(self):
                self.applies = 0
            def inspect_release(self):
                return {'status': 'deployed', 'chart': 'osac-deps-0.0.1'} if self.applies else None
            def upgrade(self, *args, **kwargs):
                self.applies += 1
        desired = Desired('osac-deps', '0.0.1', 'matching')
        for authorized, actual in ((False, live), (True, dict(live, data={'mode': 'wrong'})), (True, live)):
            helm, records = Helm(), []
            groups = json.dumps({'groups': [{'name': name} for name in ('config.openshift.io', 'route.openshift.io', 'security.openshift.io')]})
            runner = Runner([groups, json.dumps({'kind': 'List', 'items': [actual]})])
            adapter = infra.InstallerLayer(helm, infra.InfrastructureAPI(runner), desired, Path('/chart'), (), [manifest],
                                           health=lambda: True, marker=lambda: None, record=records.append, authorized=authorized)
            if not authorized:
                with self.assertRaisesRegex(RuntimeError, 'authorized'):
                    adapter.apply()
                self.assertEqual(helm.applies, 0)
            elif actual['data'] != manifest['data']:
                with self.assertRaisesRegex(RuntimeError, 'verification failed'):
                    reconcile(desired, adapter, Policy(allow_install=True))
                self.assertEqual(records, [])
            else:
                self.assertEqual(reconcile(desired, adapter, Policy(allow_install=True)).action, 'install')
                self.assertEqual(records, [{'fingerprint': 'matching', 'version': '0.0.1', 'stage': 'osac-deps'}])

    def test_unsupported_api_target_cannot_apply(self):
        binding = self.target
        class Helm:
            target = binding
            namespace, release = 'osac', 'osac-deps'
            def upgrade(self, *args, **kwargs):
                raise AssertionError('must verify OCP before writing')
        adapter = infra.InstallerLayer(Helm(), infra.InfrastructureAPI(Runner(['{"groups": []}'])),
                                       Desired('osac-deps', '0.0.1', 'matching'), Path('/chart'), (), [{}],
                                       health=lambda: True, marker=lambda: None, record=lambda _: None, authorized=True)
        with self.assertRaisesRegex(ValueError, 'OCP APIs'):
            adapter.apply()

    def test_live_namespace_defaults_and_missing_objects(self):
        manifest = {'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {'name': 'settings'}}
        live = dict(manifest, metadata={'name': 'settings', 'namespace': 'osac'})
        runner = Runner([json.dumps({'kind': 'List', 'items': [live]}), json.dumps({'kind': 'List', 'items': []})])
        api = infra.InfrastructureAPI(runner)
        self.assertEqual(api.live_objects(self.target, [manifest]), [live])
        self.assertEqual(api.live_objects(self.target, [manifest]), [{}])

    def test_source_edits_with_same_chart_version_change_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            chart = Path(tmp)
            (chart / 'Chart.yaml').write_text('apiVersion: v2\nname: osac-deps\nversion: 0.0.1\n')
            (chart / 'payload.sh').write_text('old')
            before = infra.layer_identity(chart, 'osac-deps', {}, select_platform())
            (chart / 'payload.sh').write_text('new')
            after = infra.layer_identity(chart, 'osac-deps', {}, select_platform())
            self.assertEqual(before.version, after.version)
            self.assertNotEqual(before.fingerprint, after.fingerprint)
            with self.assertRaisesRegex(ValueError, 'sensitive'):
                infra.layer_identity(chart, 'osac-deps', {'password': 'do-not-hash'}, select_platform())

    @unittest.skipUnless(shutil.which('helm'), 'Helm unavailable')
    def test_minimal_hardware_profile_has_no_hub_operator_subscriptions(self):
        output = subprocess.run(['helm', 'template', 'osac-deps', str(INSTALLER / 'charts/osac-deps'),
                                 '--namespace', 'osac', '--values', str(INSTALLER / 'values/osac-dev/infra-bm-cnv.yaml')],
                                capture_output=True, text=True, check=True).stdout
        self.assertIn('name: kubevirt-hyperconverged', output)
        for package in ('openshift-cert-manager-operator', 'ansible-automation-platform-operator', 'multicluster-engine', 'amq-streams'):
            self.assertNotIn('name: ' + package, output)

    @unittest.skipUnless(shutil.which('helm'), 'Helm unavailable')
    def test_hardware_operand_profile_suppresses_hub_resources(self):
        chart = INSTALLER / 'charts/osac-infra'
        if not (chart / 'charts/topolvm-17.2.0.tgz').exists():
            self.skipTest('run make -C osac-installer helm-infra-deps for real operand render contracts')
        output = subprocess.run(['helm', 'template', 'osac-infra', str(chart), '--namespace', 'osac',
                                 '--values', str(INSTALLER / 'values/osac-dev/infra-bm-cnv.yaml')],
                                capture_output=True, text=True, check=True).stdout
        # Hook-script ConfigMaps ship all script text, even for disabled hooks;
        # check emitted template sources, not incidental text in those scripts.
        sources = [line for line in output.splitlines() if line.startswith('# Source:')]
        self.assertIn('# Source: osac-infra/templates/cnv.yaml', sources)
        for name in ('ca-issuer', 'kafka', 'mce', 'trust-manager', 'bundled-postgres', 'bundled-openbao'):
            self.assertNotIn(f'# Source: osac-infra/templates/{name}.yaml', sources)
        for cnv, mce in (('false', 'false'), ('true', 'false'), ('false', 'true'), ('true', 'true')):
            rendered = subprocess.run(['helm', 'template', 'osac-deps', str(INSTALLER / 'charts/osac-deps'),
                                       '--namespace', 'osac', '--set', f'cnv.enabled={cnv},mce.enabled={mce}'],
                                      capture_output=True, text=True, check=True).stdout
            self.assertEqual('# Source: osac-deps/templates/cnv.yaml' in rendered, cnv == 'true')
            self.assertEqual('# Source: osac-deps/templates/mce.yaml' in rendered, mce == 'true')


def select_platform():
    from osac_dev.platform import select_platform as select
    return select('ocp')
