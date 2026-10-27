import unittest
from dataclasses import replace

from osac_dev.reconcile import Desired, Observation, Policy, decide, reconcile
from osac_dev.planner import Step, execute


class Adapter:
    def __init__(self, observations, failure=None):
        self.observations = iter(observations)
        self.calls = []
        self.failure = failure

    def inspect(self):
        self.calls.append('inspect')
        return next(self.observations)

    def apply(self):
        self.calls.append('apply')
        if self.failure:
            raise self.failure

    def record(self, marker):
        self.calls.append(('record', marker))


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self.desired = Desired('fixture', '1.0', 'public-content-digest')
        self.good = Observation(True, 'deployed', 'tool', '1.0', 'public-content-digest', True, True)
        self.policy = Policy(allow_install=True, allow_upgrade=True)

    def test_decision_table(self):
        rows = [(replace(self.good, exists=False, owner='none'), 'install'),
                (self.good, 'reuse'),
                (replace(self.good, fingerprint='old'), 'upgrade'),
                (replace(self.good, live_matches=False), 'upgrade'),
                (replace(self.good, healthy=False), 'blocked'),
                (replace(self.good, status='failed'), 'blocked'),
                (replace(self.good, status='pending-upgrade'), 'blocked'),
                (replace(self.good, status='uninstalled'), 'blocked'),
                (replace(self.good, owner='foreign'), 'reuse'),
                (replace(self.good, owner='foreign', live_matches=False), 'blocked'),
                (replace(self.good, version='2.0'), 'blocked')]
        for observed, expected in rows:
            with self.subTest(observed=observed):
                self.assertEqual(decide(self.desired, observed, self.policy).action, expected)
        self.assertEqual(decide(self.desired, replace(self.good, exists=False), Policy()).action, 'blocked')

    def test_second_complete_run_is_noop(self):
        absent = replace(self.good, exists=False, owner='none')
        adapter = Adapter([absent, self.good, self.good])
        reconcile(self.desired, adapter, self.policy)
        reconcile(self.desired, adapter, self.policy)
        self.assertEqual(adapter.calls.count('apply'), 1)
        self.assertEqual(sum(isinstance(c, tuple) for c in adapter.calls), 1)
        self.assertEqual(adapter.calls[-1], 'inspect')

    def test_matching_marker_does_not_hide_manual_drift(self):
        adapter = Adapter([replace(self.good, live_matches=False), self.good])
        reconcile(self.desired, adapter, self.policy)
        self.assertIn('apply', adapter.calls)

    def test_failed_health_or_interrupted_apply_never_records_or_runs_dependents(self):
        for failure, verified in ((RuntimeError('interrupted'), self.good), (None, replace(self.good, healthy=False))):
            adapter = Adapter([replace(self.good, exists=False), verified], failure)
            downstream = []
            steps = [Step('infra', (), lambda: reconcile(self.desired, adapter, self.policy)), Step('deploy', ('infra',), lambda: downstream.append('deploy'))]
            with self.assertRaises(RuntimeError):
                execute(steps)
            self.assertFalse(any(isinstance(c, tuple) for c in adapter.calls))
            self.assertEqual(downstream, [])

    def test_foreign_reuse_never_records_ownership(self):
        adapter = Adapter([replace(self.good, owner='foreign')])
        reconcile(self.desired, adapter, self.policy)
        self.assertEqual(adapter.calls, ['inspect'])

    def test_preview_is_redacted_and_does_not_apply(self):
        adapter = Adapter([self.good])
        result = reconcile(self.desired, adapter, self.policy, preview=True)
        self.assertEqual(result.action, 'reuse')
        self.assertEqual(adapter.calls, ['inspect'])
        self.assertNotIn('public-content-digest', str(result))

    def test_invalid_graph_fails_before_any_work(self):
        calls = []
        for steps in ([Step('a', ('missing',), lambda: calls.append(1))], [Step('a', ('b',), lambda: calls.append(1)), Step('b', ('a',), lambda: None)]):
            with self.assertRaises(ValueError):
                execute(steps)
        self.assertEqual(calls, [])
