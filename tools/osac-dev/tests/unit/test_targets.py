import json
import tempfile
import unittest
from pathlib import Path

from osac_dev.model import Reference, Target
from osac_dev.targets import Resolver, group_targets
from osac_dev.kubernetes import Kubernetes
from osac_dev.cluster_tool import ClusterTool
from osac_dev.runner import CommandError


class RecordingRunner:
    def __init__(self, outputs=()):
        self.outputs = iter(outputs)
        self.calls = []

    def run(self, args, **kwargs):
        self.calls.append(list(map(str, args)))
        result = next(self.outputs)
        if isinstance(result, Exception):
            raise result
        return result


IDENTITY = json.dumps({'metadata': {'uid': 'copied-uid'}})
CONFIG = json.dumps({
    'current-context': 'selected',
    'contexts': [{'name': 'selected', 'context': {'cluster': 'hub'}}],
    'clusters': [{'name': 'hub', 'cluster': {'server': 'https://api.example:6443'}}],
})
CLONES = 'NAME           FLAVOR          SUBNET                 CREATED\n' + '-' * 70 + '\nhub            sno-custom      192.168.10.0/24        2026-01-01T12:00:00\n'
SERVERS = 'NAME                 HOST                                                         DEFAULT\n' + '-' * 90 + '\nrdu                  root@hypervisor                                              *\n'


class TargetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        (self.home / '.kube').mkdir()
        self.file = self.home / 'hub with spaces.yaml'
        self.file.touch()
        (self.home / '.kube/hub.kubeconfig').touch()
        (self.home / '.kube/bm.kubeconfig').touch()

    def resolver(self, outputs):
        self.runner = RecordingRunner(outputs)
        return Resolver(Kubernetes(self.runner), ClusterTool(self.runner, self.home))

    def test_selector_matrix(self):
        for hub_kind in ('name', 'kubeconfig'):
            for bm_kind in ('name', 'kubeconfig'):
                with self.subTest(hub=hub_kind, bm=bm_kind):
                    outputs = []
                    for index, kind in enumerate((hub_kind, bm_kind)):
                        outputs.extend([CLONES if index == 0 else CLONES.replace('hub ', 'bm  ')] if kind == 'name' else [])
                        outputs.extend([CONFIG.replace('api.example', f'api-{index}.example'), IDENTITY])
                    resolver = self.resolver(outputs)
                    refs = [Reference.parse(f'name:{name}' if k == 'name' else f'kubeconfig:{self.file}') for name, k in zip(('hub', 'bm'), (hub_kind, bm_kind))]
                    context = resolver.resolve(refs[0], refs[1], hub_server='rdu', bm_server='other')
                    self.assertIsNotNone(context.hub.kubeconfig)
                    self.assertIsNotNone(context.bm_cnv.kubeconfig)

    def test_omission_and_identical_binding_share_object_without_native(self):
        ref = Reference.parse(f'kubeconfig:{self.file}')
        for bm in (None, ref):
            resolver = self.resolver([CONFIG, IDENTITY])
            context = resolver.resolve(ref, bm)
            self.assertIs(context.hub, context.bm_cnv)
            self.assertFalse(any(c[0] == 'cluster-tool' for c in self.runner.calls))

    def test_bad_selectors_and_missing_file_fail_before_native(self):
        for value in ('', 'hub', 'name:../bad', 'name:-bad', 'kubeconfig:'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                Reference.parse(value)
        resolver = self.resolver([])
        with self.assertRaisesRegex(ValueError, 'kubeconfig'):
            resolver.resolve(Reference.parse('name:hub'), Reference.parse('kubeconfig:/nonexistent'), hub_server='rdu')
        self.assertEqual(self.runner.calls, [])

    def test_invalid_context(self):
        resolver = self.resolver([CONFIG])
        with self.assertRaisesRegex(ValueError, 'context'):
            resolver.resolve(Reference.parse(f'kubeconfig:{self.file}'), hub_context='wrong')

    def test_missing_native_access_never_boots(self):
        (self.home / '.kube/hub.kubeconfig').unlink()
        resolver = self.resolver([CLONES])
        with self.assertRaisesRegex(ValueError, 'creator workstation'):
            resolver.resolve(Reference.parse('name:hub'), hub_server='rdu')
        self.assertEqual(len(self.runner.calls), 1)

    def test_flavor_conflict_does_not_replace(self):
        resolver = self.resolver([CLONES])
        with self.assertRaisesRegex(ValueError, 'flavor'):
            resolver.resolve(Reference.parse('name:hub'), hub_server='rdu', flavor_constraint='different')
        self.assertEqual(len(self.runner.calls), 1)

    def test_missing_clone_is_provisional_and_errors_are_not_absence(self):
        resolver = self.resolver(['No clones running.\n'])
        target = resolver.resolve(Reference.parse('name:new'), hub_server='rdu').hub
        self.assertTrue(target.missing)
        self.assertIsNone(target.kubeconfig)
        for output in ('unexpected output', CommandError('native failed')):
            resolver = self.resolver([output])
            with self.assertRaises((ValueError, CommandError)):
                resolver.resolve(Reference.parse('name:hub'), hub_server='rdu')

    def test_native_same_name_on_two_servers_has_ambiguous_workstation_access(self):
        resolver = self.resolver([])
        with self.assertRaisesRegex(ValueError, 'workstation'):
            resolver.resolve(Reference.parse('name:hub'), Reference.parse('name:hub'), hub_server='rdu', bm_server='another')
        self.assertEqual(self.runner.calls, [])

    def test_same_endpoint_without_api_identity_cannot_be_merged(self):
        a = Target(Reference.parse('kubeconfig:/a'), Path('/a'), 'ctx', 'https://same')
        b = Target(Reference.parse('kubeconfig:/b'), Path('/b'), 'ctx', 'https://same')
        with self.assertRaisesRegex(ValueError, 'collision'):
            group_targets([a, b])
        a.cluster_uid = b.cluster_uid = 'observed-uid'
        self.assertEqual(len(group_targets([a, b])), 1)

    def test_copied_uid_different_endpoints_not_merged(self):
        a = Target(Reference.parse('name:a'), None, None, 'https://a:6443', 'rdu', 'same-uid')
        b = Target(Reference.parse('name:b'), None, None, 'https://b:6443', 'rdu', 'same-uid')
        self.assertEqual(len(group_targets([a, b])), 2)
        b.endpoint = a.endpoint
        with self.assertRaisesRegex(ValueError, 'collision'):
            group_targets([a, b])

    def test_kubernetes_role_namespace_is_explicit(self):
        runner = RecordingRunner(['{}'])
        target = Target(Reference.parse(f'kubeconfig:{self.file}'), self.file, 'selected', 'https://api')
        Kubernetes(runner).get(target, 'pods', namespace='osac')
        self.assertEqual(runner.calls[0], ['oc', '--kubeconfig', str(self.file), '--context', 'selected', 'get', 'pods', '--namespace', 'osac', '-o', 'json'])

    def test_creation_preflights_inputs_and_never_creates_in_other_stages(self):
        from osac_dev.platform import select_platform
        for command, secret in (('deploy', None), ('up', None), ('infra', '/missing')):
            resolver = self.resolver(['No clones running.\n'])
            context = resolver.resolve(Reference.parse('name:new'), hub_server='rdu')
            with self.assertRaises(ValueError):
                resolver.create_missing(context, command=command, flavor='sno-4-22', pull_secret=secret, platform=select_platform('ocp'))
            self.assertEqual(len(self.runner.calls), 1)

    def test_creation_reuses_omitted_role_and_verifies_capabilities(self):
        from osac_dev.platform import select_platform
        secret = self.home / 'pull secret.json'
        secret.write_text('{"auths":{"example":{"auth":"synthetic"}}}')
        (self.home / '.kube/new.kubeconfig').touch()
        outputs = ['No clones running.\n', SERVERS, '', '', CONFIG, IDENTITY,
                   json.dumps({'groups': [{'name': name} for name in select_platform('ocp').required_apis]})]
        resolver = self.resolver(outputs)
        context = resolver.resolve(Reference.parse('name:new'), hub_server='rdu')
        resolver.create_missing(context, command='up', flavor='custom', pull_secret=secret, platform=select_platform('ocp'))
        self.assertIs(context.hub, context.bm_cnv)
        self.assertFalse(context.hub.missing)
        self.assertEqual(sum(c[:2] == ['cluster-tool', 'boot'] for c in self.runner.calls), 1)

    def test_native_create_uses_public_arguments(self):
        for flavor in ('sno-4-22', 'custom'):
            runner = RecordingRunner(['', ''])
            ClusterTool(runner, self.home).create('hub', 'rdu', flavor, self.file)
            self.assertEqual(runner.calls, [
                ['cluster-tool', 'pull', '--server', 'rdu', f'quay.io/osac-project/cluster-flavors:{flavor}'],
                ['cluster-tool', 'boot', '--server', 'rdu', '--flavor', flavor, '--name', 'hub', '--pull-secret', str(self.file)],
            ])

    def test_connection_conflicts_and_no_implicit_setup(self):
        runner = RecordingRunner([SERVERS])
        native = ClusterTool(runner, self.home)
        self.assertEqual(native.connection('rdu', 'root@hypervisor'), 'root@hypervisor')
        runner = RecordingRunner([SERVERS])
        with self.assertRaisesRegex(ValueError, 'conflict'):
            ClusterTool(runner, self.home).connection('rdu', 'root@elsewhere')
        self.assertEqual(len(runner.calls), 1)
