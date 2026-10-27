"""Prerequisite graph and OCP readiness; all API/Helm boundaries are simulated."""

import json
import unittest
from pathlib import Path

from osac_dev.model import Context, Reference, Target
from osac_dev.platform import select_platform
from osac_dev.reconcile import Decision
from osac_dev import infrastructure as infra


def target(name):
    return Target(Reference.parse(f'kubeconfig:/tmp/{name}'), Path('/tmp') / name, name, f'https://{name}', cluster_uid=name)


class API:
    def __init__(self, objects):
        self.objects = objects
        self.probes = []

    def get(self, target, resource, *, namespace=None):
        return self.objects.get((namespace, resource), {})

    def admission_probe(self, target, namespace):
        self.probes.append((target, namespace))


class InfrastructureTests(unittest.TestCase):
    def test_combined_roles_union_and_split_minimal_hardware(self):
        hub, hardware = target('hub'), target('hardware')
        shared = infra.requirements(Context(hub, hub), select_platform('ocp'))
        self.assertEqual(len(shared), 1)
        self.assertEqual(shared[0].roles, ('hub', 'bm-cnv'))
        self.assertIn('cnv', shared[0].capabilities)
        split = infra.requirements(Context(hub, hardware), select_platform('ocp'))
        self.assertEqual(split[1].capabilities, ('cnv', 'storage'))
        self.assertNotIn('keycloak', split[1].capabilities)
        self.assertNotIn('mce', split[1].capabilities)

    def test_grouping_uses_resolver_identity_not_copied_uid(self):
        hub, hardware = target('hub'), target('hardware')
        hardware.cluster_uid = hub.cluster_uid
        self.assertEqual(len(infra.requirements(Context(hub, hardware), select_platform('ocp'))), 2)

    def test_webhook_barrier_prevents_consumers_and_deployment(self):
        calls = []
        def blocked():
            calls.append('admission')
            raise RuntimeError('webhook endpoints not ready')
        with self.assertRaisesRegex(RuntimeError, 'webhook'):
            infra.run_layers(lambda: calls.append('deps'), blocked,
                             lambda: calls.append('infra'), lambda: calls.append('operands'))
        self.assertEqual(calls, ['deps', 'admission'])

    def test_blocked_dependency_never_runs_barrier(self):
        calls = []
        with self.assertRaisesRegex(RuntimeError, 'blocked'):
            infra.run_layers(lambda: Decision('blocked', 'foreign prerequisite'),
                             lambda: calls.append('admission'), lambda: calls.append('infra'),
                             lambda: calls.append('operands'))
        self.assertEqual(calls, [])

    def test_external_operator_requires_exact_contract_and_succeeded_csv(self):
        contract = infra.Operator('pkg', 'operators', 'stable', 'catalog', 'marketplace', ('1.2.3',), ('widgets.example.io',))
        objects = {
            ('operators', 'subscription/pkg'): {'spec': {'name': 'pkg', 'channel': 'stable', 'source': 'catalog', 'sourceNamespace': 'marketplace'}, 'status': {'installedCSV': 'pkg.v1.2.3'}},
            ('operators', 'clusterserviceversion/pkg.v1.2.3'): {'spec': {'version': '1.2.3'}, 'status': {'phase': 'Succeeded'}},
            (None, 'customresourcedefinition/widgets.example.io'): {'status': {'conditions': [{'type': 'Established', 'status': 'True'}]}},
        }
        api = API(objects)
        self.assertTrue(infra.operator_ready(api, target('hub'), contract))
        objects[('operators', 'clusterserviceversion/pkg.v1.2.3')]['status']['phase'] = 'Pending'
        self.assertFalse(infra.operator_ready(api, target('hub'), contract))
        objects[('operators', 'clusterserviceversion/pkg.v1.2.3')]['status']['phase'] = 'Succeeded'
        objects[('operators', 'subscription/pkg')]['spec']['channel'] = 'other'
        self.assertFalse(infra.operator_ready(api, target('hub'), contract))
        objects[('operators', 'subscription/pkg')]['spec']['channel'] = 'stable'
        objects[('operators', 'clusterserviceversion/pkg.v1.2.3')]['spec']['version'] = '9.9.9'
        self.assertFalse(infra.operator_ready(api, target('hub'), contract))

    def test_empty_operator_version_policy_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'versions'):
            infra.Operator('pkg', 'operators', 'stable', 'catalog', 'marketplace', (), ())

    def test_webhook_checks_deployment_endpoints_ca_and_admission(self):
        ready = {'metadata': {'generation': 2}, 'spec': {'replicas': 1}, 'status': {'observedGeneration': 2, 'updatedReplicas': 1, 'availableReplicas': 1}}
        objects = {
            ('cert-manager', 'deployment/cert-manager-webhook'): ready,
            ('cert-manager', 'service/cert-manager-webhook'): {'spec': {'ports': [{'port': 443}]}},
            ('cert-manager', 'endpoints/cert-manager-webhook'): {'subsets': [{'addresses': [{'ip': '192.0.2.1'}]}]},
            (None, 'validatingwebhookconfiguration/cert-manager-webhook'): {'webhooks': [{'clientConfig': {'caBundle': 'synthetic-ca', 'service': {'name': 'cert-manager-webhook', 'namespace': 'cert-manager'}}}]},
        }
        api = API(objects)
        binding = target('hub')
        infra.cert_manager_barrier(api, binding, apply=True)
        self.assertEqual(api.probes, [(binding, 'cert-manager')])
        infra.cert_manager_barrier(api, binding, apply=False)
        self.assertEqual(len(api.probes), 1, 'read-only planning must not run admission')
        objects[('cert-manager', 'endpoints/cert-manager-webhook')] = {}
        with self.assertRaisesRegex(RuntimeError, 'endpoints'):
            infra.cert_manager_barrier(api, binding, apply=True)
        self.assertEqual(len(api.probes), 1)

    def test_secret_string_data_is_compared_privately_in_api_form(self):
        from osac_dev.reconcile import Desired
        import base64
        manifest = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': 'credential'}, 'stringData': {'value': 'synthetic-sensitive-value'}}
        live = {'apiVersion': 'v1', 'kind': 'Secret', 'metadata': {'name': 'credential', 'annotations': {'meta.helm.sh/release-name': 'osac-infra', 'meta.helm.sh/release-namespace': 'osac'}}, 'data': {'value': base64.b64encode(b'synthetic-sensitive-value').decode()}}
        state = infra.layer_observation(Desired('osac-infra', '0.0.1', 'public-fingerprint'), {'status': 'deployed', 'chart': 'osac-infra-0.0.1'}, [manifest], [live], marker='public-fingerprint', healthy=True, authorized=True)
        self.assertTrue(state.live_matches)
        self.assertNotIn('synthetic-sensitive-value', repr(state))
        self.assertNotIn(live['data']['value'], repr(state))

    def test_stale_generation_is_not_ready(self):
        self.assertFalse(infra.workload_ready({'metadata': {'generation': 2}, 'spec': {'replicas': 1}, 'status': {'observedGeneration': 1, 'availableReplicas': 1}}))
        self.assertFalse(infra.condition_ready({'metadata': {'generation': 2}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True', 'observedGeneration': 1}]}}))

    def test_bounded_wait_reports_only_allowlisted_identity(self):
        ticks = iter([0, 0, 2])
        with self.assertRaisesRegex(RuntimeError, 'cnv.*deadline'):
            infra.wait_ready('cnv', lambda: False, timeout=1, clock=lambda: next(ticks), pause=lambda _: None)

    def test_live_layer_drift_and_ownership_not_marker_alone(self):
        from osac_dev.reconcile import Desired, Policy, decide
        desired = Desired('osac-deps', '0.0.1', 'new')
        manifest = {'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {'name': 'settings', 'namespace': 'osac'}, 'data': {'mode': 'wanted'}}
        observed = dict(manifest, data={'mode': 'drifted'})
        observed['metadata'] = dict(manifest['metadata'], annotations={'meta.helm.sh/release-name': 'osac-deps', 'meta.helm.sh/release-namespace': 'osac'})
        state = infra.layer_observation(desired, {'status': 'deployed', 'chart': 'osac-deps-0.0.1'}, [manifest], [observed], marker='new', healthy=True, authorized=True)
        self.assertFalse(state.live_matches)
        self.assertEqual(decide(desired, state, Policy(allow_upgrade=True)).action, 'upgrade')
        self.assertEqual(decide(desired, state, Policy()).action, 'blocked')
        unhealthy = infra.layer_observation(desired, {'status': 'deployed', 'chart': 'osac-deps-0.0.1'}, [manifest], [observed], marker='new', healthy=False, authorized=True)
        self.assertEqual(decide(desired, unhealthy, Policy(allow_upgrade=True)).action, 'blocked')
        observed['data'] = manifest['data']
        state = infra.layer_observation(desired, {'status': 'deployed', 'chart': 'osac-deps-0.0.1'}, [manifest], [observed], marker=None, healthy=True, authorized=False)
        self.assertEqual(state.owner, 'foreign')
        self.assertEqual(decide(desired, state, Policy()).action, 'blocked')
        self.assertNotIn('wanted', json.dumps(state.__dict__))

    def test_same_content_new_hook_fingerprint_is_not_falsely_reused(self):
        from osac_dev.reconcile import Desired, Policy, decide
        manifest = {'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {'name': 'settings'}}
        live = dict(manifest, metadata=dict(manifest['metadata'], annotations={'meta.helm.sh/release-name': 'osac-deps', 'meta.helm.sh/release-namespace': 'osac'}))
        desired = Desired('osac-deps', '0.0.1', 'new-hook')
        state = infra.layer_observation(desired, {'status': 'deployed', 'chart': 'osac-deps-0.0.1'}, [manifest], [live], marker='old-hook', healthy=True, authorized=True)
        self.assertEqual(decide(desired, state, Policy(allow_upgrade=True)).action, 'upgrade')

    def test_distinct_bindings_to_proven_same_endpoint_share_capabilities(self):
        hub, hardware = target('hub'), target('hardware')
        hardware.endpoint, hardware.cluster_uid = hub.endpoint, hub.cluster_uid
        shared = infra.requirements(Context(hub, hardware), select_platform('ocp'))
        self.assertEqual(shared[0].roles, ('hub', 'bm-cnv'))

    def test_ownership_annotation_mismatch_blocks_adoption(self):
        from osac_dev.reconcile import Desired
        manifest = {'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {'name': 'settings'}}
        state = infra.layer_observation(Desired('osac-deps', '0.0.1', 'new'), {'status': 'deployed', 'chart': 'osac-deps-0.0.1'}, [manifest], [manifest], marker='new', healthy=True, authorized=True)
        self.assertEqual(state.owner, 'foreign')
        self.assertFalse(state.live_matches)
