from __future__ import annotations

import logging
from unittest.mock import Mock

import pytest

from tests.e2e.caas.readiness_diagnostics import log_worker_readiness_snapshot


def test_snapshot_logs_only_owned_worker_state_without_secrets(caplog: pytest.LogCaptureFixture) -> None:
    secret = "credential-very-private"
    k8s = Mock(namespace="osac-e2e-ci")
    k8s.get_json.return_value = {
        "status": {
            "readyWorkers": 0,
            "workers": [{"name": "order-abc-worker-0", "phase": "Binding", "resourceID": secret}],
        }
    }
    k8s.get_cluster_order_namespace.return_value = "osac-e2e-ci-order-abc"
    k8s.list_json.side_effect = [
        {
            "items": [
                {
                    "metadata": {"name": "agent-1", "labels": {"osac.openshift.io/clusterorder": "order-abc"}},
                    "spec": {"clusterDeploymentName": {"name": "order-abc", "secret": secret}},
                    "status": {
                        "debugInfo": {"state": "binding", "secret": secret},
                        "conditions": [
                            {
                                "type": "Installed",
                                "status": "False",
                                "reason": "InstallationPending",
                                "message": secret,
                            },
                            {"type": "Ready", "status": "False", "reason": secret, "message": secret},
                        ],
                    },
                },
                {
                    "metadata": {
                        "name": "unbound-agent",
                        "labels": {"infraenvs.agent-install.openshift.io": "order-abc-infraenv"},
                    },
                    "status": {"debugInfo": {"state": "known-unbound"}},
                },
                {
                    "metadata": {"name": "other-agent", "labels": {"osac.openshift.io/clusterorder": "other"}},
                    "status": {"conditions": [{"message": secret}]},
                },
            ]
        },
        {
            "items": [
                {
                    "metadata": {"name": "pool-1", "labels": {"osac.openshift.io/clusterorder": "order-abc"}},
                    "spec": {"replicas": 1, "secret": secret},
                    "status": {
                        "replicas": 0,
                        "conditions": [
                            {"type": "Ready", "status": "False", "reason": "AwaitingNodes", "message": secret}
                        ],
                    },
                },
                {"metadata": {"name": "other-pool", "labels": {"osac.openshift.io/clusterorder": "other"}}},
            ]
        },
    ]

    with caplog.at_level(logging.WARNING):
        log_worker_readiness_snapshot(k8s=k8s, order_name="order-abc")

    assert "InstallationPending" in caplog.text
    assert "AwaitingNodes" in caplog.text
    assert '"bound": true' in caplog.text
    assert '"bound": false' in caplog.text
    assert "unbound-agent" in caplog.text
    assert "Binding" in caplog.text
    assert "other-agent" not in caplog.text
    assert "other-pool" not in caplog.text
    assert secret not in caplog.text
    k8s.list_json.assert_any_call(resource="agents.agent-install.openshift.io", namespace="osac-e2e-ci")
    k8s.list_json.assert_any_call(resource="nodepools.hypershift.openshift.io", namespace="osac-e2e-ci-order-abc")


def test_snapshot_failure_does_not_mask_timeout_or_log_exception(caplog: pytest.LogCaptureFixture) -> None:
    k8s = Mock(namespace="osac-e2e-ci")
    k8s.get_json.side_effect = RuntimeError("token-plain")
    k8s.get_cluster_order_namespace.side_effect = RuntimeError("token-plain")
    k8s.list_json.side_effect = RuntimeError("token-plain")
    with caplog.at_level(logging.WARNING):
        log_worker_readiness_snapshot(k8s=k8s, order_name="order-abc")
    assert "unavailable" in caplog.text
    assert "token-plain" not in caplog.text
