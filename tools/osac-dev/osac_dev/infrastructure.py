"""OCP prerequisite contracts and dependency barriers.

No implicit ownership, version guessing, operator adoption, or repair-by-upgrade.
The caller supplies the reviewed operator version policy and explicit per-target
write authorization. These adapters do not deploy OSAC or configure lab networks.
"""

import base64
import json
import re
import time
from dataclasses import dataclass
from pathlib import Path

from .fingerprints import fingerprint, owned_matches
from .kubernetes import Kubernetes
from .planner import Step, execute
from .platform import select_platform
from .reconcile import Desired, Observation
from .targets import group_targets


@dataclass(frozen=True)
class Requirements:
    target: object
    roles: tuple[str, ...]
    capabilities: tuple[str, ...]


def requirements(context, platform):
    if platform.name != 'ocp' or platform.installer_profile != 'openshift':
        raise ValueError('infrastructure requires the implemented OCP capability profile')
    result = []
    for target in group_targets([context.hub, context.bm_cnv]):
        roles = tuple(role for role, binding in (('hub', context.hub), ('bm-cnv', context.bm_cnv))
                      if len(group_targets([target, binding])) == 1)
        # The resolver proves physical identity; namespace UIDs alone never do.
        capabilities = set()
        if 'hub' in roles:
            capabilities.update(('cert-manager', 'trust-manager', 'aap', 'keycloak', 'kafka', 'mce', 'storage'))
        if 'bm-cnv' in roles:
            capabilities.update(('cnv', 'storage'))
        result.append(Requirements(target, roles, tuple(sorted(capabilities))))
    return result


def run_layers(dependencies, admission, operands, health):
    """A failed release or admission gate cannot start Certificate consumers."""
    return execute([
        Step('dependencies', (), dependencies),
        Step('admission', ('dependencies',), admission),
        Step('operands', ('admission',), operands),
        Step('health', ('operands',), health),
    ])


def condition_ready(obj, condition='Ready'):
    generation = obj.get('metadata', {}).get('generation', 0)
    status = obj.get('status', {})
    return any(c.get('type') == condition and c.get('status') == 'True'
               and c.get('observedGeneration', status.get('observedGeneration', generation)) >= generation
               for c in status.get('conditions', []))


def workload_ready(obj):
    if not obj or obj.get('metadata', {}).get('deletionTimestamp'):
        return False
    status = obj.get('status', {})
    count = obj.get('spec', {}).get('replicas', 1)
    return (count > 0 and status.get('observedGeneration', -1) >= obj.get('metadata', {}).get('generation', 0)
            and status.get('updatedReplicas', 0) == count and status.get('availableReplicas', 0) >= count)


def wait_ready(identity, check, *, timeout=600, clock=time.monotonic, pause=time.sleep):
    if timeout <= 0:
        raise ValueError('readiness timeout must be positive')
    deadline = clock() + timeout
    while True:
        if check():
            return
        remaining = deadline - clock()
        if remaining <= 0:
            raise RuntimeError(f'{identity}: readiness deadline exceeded; inspect operator, events, storage and image access')
        pause(min(2, remaining))


@dataclass(frozen=True)
class Operator:
    package: str
    namespace: str
    channel: str
    catalog: str
    catalog_namespace: str
    versions: tuple[str, ...]
    crds: tuple[str, ...]

    def __post_init__(self):
        if not self.versions or not all(isinstance(v, str) and v for v in self.versions):
            raise ValueError('supported operator CSV versions must be explicitly supplied')


def operator_ready(api, target, contract):
    sub = api.get(target, f'subscription/{contract.package}', namespace=contract.namespace)
    expected = {'name': contract.package, 'channel': contract.channel, 'source': contract.catalog,
                'sourceNamespace': contract.catalog_namespace}
    if not owned_matches(expected, sub.get('spec', {})):
        return False
    csv_name = sub.get('status', {}).get('installedCSV')
    if not csv_name:
        return False
    csv = api.get(target, f'clusterserviceversion/{csv_name}', namespace=contract.namespace)
    if csv.get('status', {}).get('phase') != 'Succeeded' or csv.get('spec', {}).get('version') not in contract.versions:
        return False
    return all(condition_ready(api.get(target, f'customresourcedefinition/{name}'), 'Established') for name in contract.crds)


def cert_manager_barrier(api, target, *, apply=False):
    namespace, name = 'cert-manager', 'cert-manager-webhook'
    if not workload_ready(api.get(target, f'deployment/{name}', namespace=namespace)):
        raise RuntimeError('cert-manager/cert-manager-webhook: deployment not ready')
    service = api.get(target, f'service/{name}', namespace=namespace)
    endpoints = api.get(target, f'endpoints/{name}', namespace=namespace)
    if not service.get('spec', {}).get('ports') or not any(s.get('addresses') for s in endpoints.get('subsets', [])):
        raise RuntimeError('cert-manager/cert-manager-webhook: service endpoints not ready')
    config = api.get(target, f'validatingwebhookconfiguration/{name}')
    webhooks = config.get('webhooks', [])
    if not webhooks or not all(w.get('clientConfig', {}).get('caBundle')
                               and w['clientConfig'].get('service', {}).get('name') == name
                               and w['clientConfig']['service'].get('namespace') == namespace for w in webhooks):
        raise RuntimeError('cert-manager/cert-manager-webhook: CA/service binding not ready')
    if apply:
        # Server dry-run exercises the actual API -> webhook TLS/admission path.
        api.admission_probe(target, namespace)


def projection(obj):
    """Only Helm-declared fields; ignore live status and API metadata."""
    result = {key: value for key, value in obj.items() if key not in ('status', 'metadata')}
    metadata = obj.get('metadata', {})
    result['metadata'] = {key: metadata[key] for key in ('name', 'namespace', 'labels', 'annotations') if key in metadata}
    if result.get('kind') == 'Secret' and 'stringData' in result:
        data = dict(result.get('data', {}))
        data.update({key: base64.b64encode(value.encode()).decode() for key, value in result.pop('stringData').items()})
        result['data'] = data
    return result


def layer_observation(desired, release, manifests, live, *, marker, healthy, authorized):
    if release is None:
        return Observation(False)
    if len(manifests) != len(live) or not manifests:
        raise ValueError('a nonempty complete live projection is required')
    ownership = all(obj.get('metadata', {}).get('annotations', {}).get('meta.helm.sh/release-name') == desired.component
                    and obj['metadata']['annotations'].get('meta.helm.sh/release-namespace') == 'osac' for obj in live)
    matches = ownership and all(owned_matches(projection(wanted), actual) for wanted, actual in zip(manifests, live))
    prefix = desired.component + '-'
    version = release['chart'][len(prefix):] if release['chart'].startswith(prefix) else None
    # Live fields cannot prove a foreign release's hooks/source identity. Reuse
    # external operators through their explicit Operator contracts instead.
    return Observation(True, release['status'], 'tool' if ownership and authorized and marker else 'foreign',
                       version, marker, matches, healthy)


def layer_identity(chart, release, public_values, platform):
    if platform.name != 'ocp' or platform.installer_profile != 'openshift':
        raise ValueError('installer layers require the OCP profile')
    if release not in ('osac-deps', 'osac-infra'):
        raise ValueError('only installer prerequisite releases are permitted')
    metadata = (Path(chart) / 'Chart.yaml').read_text()
    version = re.findall(r'^version: ([0-9]+\.[0-9]+\.[0-9]+)\s*$', metadata, re.MULTILINE)
    name = re.findall(r'^name: (\S+)\s*$', metadata, re.MULTILINE)
    if len(version) != 1 or name != [release]:
        raise ValueError('unsupported installer chart metadata')
    digest = fingerprint(chart, platform=platform.name, values=public_values,
                         dependencies={'installer_profile': platform.installer_profile})
    return Desired(release, version[0], digest)


class InfrastructureAPI(Kubernetes):
    """Absence is explicit; RBAC/transport errors are never inferred as absence."""

    def get(self, target, resource, *, namespace=None):
        args = self.args(target) + ['get', resource, '--ignore-not-found']
        if namespace:
            args += ['--namespace', namespace]
        output = self.runner.run(args + ['-o', 'json'])
        return json.loads(output) if output.strip() else {}

    def admission_probe(self, target, namespace):
        probe = {'apiVersion': 'cert-manager.io/v1', 'kind': 'Certificate',
                 'metadata': {'generateName': 'osac-dev-admission-', 'namespace': namespace},
                 'spec': {'secretName': 'osac-dev-admission-probe', 'dnsNames': ['probe.invalid'],
                          'issuerRef': {'name': 'osac-dev-probe', 'kind': 'Issuer'}}}
        self.runner.run(self.args(target) + ['create', '--namespace', namespace, '--dry-run=server', '-f', '-', '-o', 'name'],
                        input=json.dumps(probe))

    def live_objects(self, target, manifests):
        output = self.runner.run(self.args(target) + ['get', '--namespace', 'osac', '--ignore-not-found', '-f', '-', '-o', 'json'],
                                 input=json.dumps({'apiVersion': 'v1', 'kind': 'List', 'items': manifests}))
        data = json.loads(output)
        rows = data.get('items') if data.get('kind') == 'List' or 'items' in data else [data]
        if not isinstance(rows, list):
            raise ValueError('unknown live resource JSON shape')
        def key(obj):
            metadata = obj.get('metadata', {})
            return obj.get('apiVersion'), obj.get('kind'), metadata.get('namespace'), metadata.get('name')
        by_key = {key(obj): obj for obj in rows}
        if len(by_key) != len(rows):
            raise ValueError('duplicate live object identity')
        result = []
        for manifest in manifests:
            identity = key(manifest)
            obj = by_key.get(identity)
            if obj is None and identity[2] is None:
                # Helm defaults omitted namespaced metadata to its release NS.
                defaulted = (identity[0], identity[1], 'osac', identity[3])
                obj = by_key.get(defaulted)
            result.append(obj or {})
        return result


class InstallerLayer:
    """Concrete inspect/apply/verify transport for a reviewed installer layer.

    Manifests must be the effective rendered, non-hook Helm objects, including
    Secrets for private comparison only. Marker callbacks use the private journal;
    neither markers nor diagnostics include manifests, values, or credential hashes.
    Write authorization is per physical target, not inherited from target access.
    """

    def __init__(self, helm, api, desired, chart, values, manifests, *, health,
                 marker, record, authorized=False, timeout=600):
        if helm.namespace != 'osac' or helm.release != desired.component:
            raise ValueError('installer release/namespace binding mismatch')
        if not manifests:
            raise ValueError('effective installer manifests are required')
        self.helm, self.api, self.desired = helm, api, desired
        self.chart, self.values, self.manifests = chart, values, manifests
        self.health, self.marker, self.record = health, marker, record
        self.authorized, self.timeout = authorized, timeout
        self.applied = False

    def inspect(self):
        release = self.helm.inspect_release()
        if release is None:
            return Observation(False)
        live = self.api.live_objects(self.helm.target, self.manifests)
        marker = self.desired.fingerprint if self.applied else self.marker()
        return layer_observation(self.desired, release, self.manifests, live, marker=marker,
                                 healthy=self.health(), authorized=self.authorized)

    def apply(self):
        if not self.authorized:
            raise RuntimeError('cluster-scoped prerequisite reconciliation is not authorized')
        self.applied = False
        self.api.verify_platform(self.helm.target, select_platform('ocp'))
        self.helm.upgrade(self.chart, self.values, timeout=self.timeout)
        wait_ready(self.desired.component, self.health, timeout=self.timeout)
        self.applied = True
