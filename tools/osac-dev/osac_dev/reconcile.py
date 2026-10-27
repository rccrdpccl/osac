"""Observation -> policy -> apply -> independent verification -> success record.

Infrastructure adapters (Task 4) must inspect live owned fields and health; a
matching fingerprint marker alone can never populate live_matches or healthy.
"""

import json
import re
from dataclasses import dataclass


@dataclass(frozen=True)
class Desired:
    component: str
    version: str
    fingerprint: str


@dataclass(frozen=True)
class Observation:
    exists: bool
    status: str = 'absent'
    owner: str = 'none'
    version: str | None = None
    fingerprint: str | None = None
    live_matches: bool = False
    healthy: bool = False


@dataclass(frozen=True)
class Policy:
    allow_install: bool = False
    allow_upgrade: bool = False
    allowed_version_transitions: tuple[tuple[str, str], ...] = ()


@dataclass(frozen=True)
class Decision:
    action: str
    reason: str


def decide(desired, observed, policy):
    if not observed.exists:
        return Decision('install', 'required component absent') if policy.allow_install else Decision('blocked', 'installation is not authorized')
    if observed.status != 'deployed':
        return Decision('blocked', 'release is not deployed; pending/failed/interrupted state requires diagnosis')
    if not observed.healthy:
        return Decision('blocked', 'health gate failed; upgrade is not a repair mechanism')
    matches = observed.version == desired.version and observed.fingerprint == desired.fingerprint and observed.live_matches
    if matches:
        return Decision('reuse', 'version, content, live owned fields and health match')
    if observed.owner != 'tool':
        return Decision('blocked', 'foreign or unknown ownership; administrator action required')
    if not policy.allow_upgrade:
        return Decision('blocked', 'reconciliation is not authorized')
    if observed.version != desired.version and (observed.version, desired.version) not in policy.allowed_version_transitions:
        return Decision('blocked', 'version transition is not explicitly supported')
    return Decision('upgrade', 'version/content or live owned fields differ')


def reconcile(desired, adapter, policy, *, preview=False):
    observed = adapter.inspect()
    decision = decide(desired, observed, policy)
    if preview or decision.action == 'reuse':
        return decision
    if decision.action == 'blocked':
        raise RuntimeError(f'{desired.component}: {decision.reason}')
    adapter.apply()
    verified = adapter.inspect()
    if not (verified.exists and verified.status == 'deployed' and verified.owner == 'tool'
            and verified.version == desired.version and verified.fingerprint == desired.fingerprint
            and verified.live_matches and verified.healthy):
        raise RuntimeError(f'{desired.component}: post-apply content/ownership/health verification failed; success not recorded')
    adapter.record({'fingerprint': desired.fingerprint, 'version': desired.version, 'stage': desired.component})
    return decision


class Helm:
    """Transport only; release existence is not an infrastructure health check."""

    STATUS_FLAGS = ('--deployed', '--failed', '--pending', '--uninstalled', '--uninstalling', '--superseded')
    STATUSES = {'deployed', 'failed', 'pending-install', 'pending-upgrade', 'pending-rollback', 'uninstalled', 'uninstalling', 'superseded', 'unknown'}

    def __init__(self, runner, target, namespace, release):
        self.runner = runner
        self.target = target
        self.namespace = namespace
        self.release = release

    def scope(self):
        if not self.target.kubeconfig or not self.target.context:
            raise ValueError('Helm target access is unresolved')
        return ['--kubeconfig', str(self.target.kubeconfig), '--kube-context', self.target.context, '--namespace', self.namespace]

    def inspect_release(self):
        # Helm 4 removed list --all. Explicit status flags work in both 3 and 4.
        output = self.runner.run(['helm', 'list', *self.scope(), '--filter', '^' + re.escape(self.release) + '$',
                                  '--max', '2', *self.STATUS_FLAGS, '-o', 'json'])
        try:
            rows = json.loads(output)
            if not isinstance(rows, list) or len(rows) > 1:
                raise ValueError()
            if not rows:
                return None
            row = rows[0]
            if not isinstance(row, dict) or row.get('name') != self.release or row.get('namespace') != self.namespace or row.get('status') not in self.STATUSES or not isinstance(row.get('chart'), str):
                raise ValueError()
            return {key: row[key] for key in ('name', 'namespace', 'status', 'chart')}
        except (ValueError, TypeError, KeyError):
            raise ValueError('unknown Helm list JSON shape; refusing to infer release absence') from None

    def upgrade(self, chart, values, *, timeout=600):
        args = ['helm', 'upgrade', '--install', self.release, str(chart), *self.scope(), '--wait', '--timeout', f'{timeout}s']
        for path in values:
            args += ['--values', str(path)]
        self.runner.run(args, timeout=timeout + 30)
