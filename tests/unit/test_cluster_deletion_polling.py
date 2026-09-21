from __future__ import annotations

import subprocess
from typing import Any
from unittest.mock import Mock

import pytest

from tests.e2e.core import helpers
from tests.e2e.core.k8s_client import K8sClient


def _mock_get(k8s: K8sClient, *, output: str, returncode: int) -> None:
    def get(*args: str, checked: bool = True) -> tuple[str, int]:
        return output, returncode

    k8s._get = get  # type: ignore[method-assign]


def test_cluster_order_not_found_is_distinct_from_an_empty_phase() -> None:
    k8s = K8sClient(namespace="tenant-a")

    _mock_get(
        k8s,
        output='Error from server (NotFound): clusterorders.osac.openshift.io "cluster-a" not found',
        returncode=1,
    )
    assert k8s.get_cluster_order_phase(name="cluster-a", checked=False) is None

    _mock_get(k8s, output="", returncode=0)
    assert k8s.get_cluster_order_phase(name="cluster-a", checked=False) == ""


@pytest.mark.parametrize(
    "kubectl_output",
    [
        "Error from server (Forbidden): clusterorders.osac.openshift.io is forbidden",
        'Error from server (NotFound): namespaces "tenant-a" not found',
        'Error from server (NotFound): namespaces "clusterorders" not found',
        'Error from server (NotFound): clusterorders.osac.openshift.io "other-cluster" not found',
        'Error from server (NotFound): clusterorders.osac.openshift.io "cluster-a" not found: extra text',
        'prefix: Error from server (NotFound): clusterorders.osac.openshift.io "cluster-a" not found',
        "Unable to connect to the server: dial tcp: lookup api.example.test: no such host",
    ],
)
def test_cluster_order_phase_propagates_non_resource_not_found_errors(kubectl_output: str) -> None:
    k8s = K8sClient(namespace="tenant-a")
    _mock_get(k8s, output=kubectl_output, returncode=1)

    with pytest.raises(subprocess.CalledProcessError) as exc_info:
        k8s.get_cluster_order_phase(name="cluster-a", checked=False)

    assert exc_info.value.returncode == 1
    assert exc_info.value.stderr == kubectl_output


def test_wait_for_cluster_deleting_accepts_only_not_found_as_already_gone(monkeypatch: pytest.MonkeyPatch) -> None:
    k8s = Mock(spec=K8sClient)
    captured: dict[str, Any] = {}

    def capture_poll(**kwargs: Any) -> None:
        captured.update(kwargs)

    monkeypatch.setattr(helpers, "poll_until", capture_poll)
    helpers.wait_for_cluster_deleting(k8s=k8s, name="cluster-a")

    until = captured["until"]
    assert until("Deleting") is True
    assert until(None) is True
    assert until("") is False


@pytest.mark.parametrize(
    "kubectl_output",
    [
        "Error from server (Forbidden): clusterorders.osac.openshift.io is forbidden",
        'Error from server (NotFound): namespaces "tenant-a" not found',
        "Unable to connect to the server: connection refused",
    ],
)
def test_wait_for_cluster_deleting_propagates_kubectl_errors(
    monkeypatch: pytest.MonkeyPatch, kubectl_output: str
) -> None:
    k8s = Mock(spec=K8sClient)
    k8s.get_cluster_order_phase.side_effect = subprocess.CalledProcessError(
        1, ["kubectl"], stderr=kubectl_output
    )

    def invoke_once(**kwargs: Any) -> None:
        kwargs["fn"]()

    monkeypatch.setattr(helpers, "poll_until", invoke_once)

    with pytest.raises(subprocess.CalledProcessError) as exc_info:
        helpers.wait_for_cluster_deleting(k8s=k8s, name="cluster-a")

    assert exc_info.value.stderr == kubectl_output


@pytest.mark.parametrize("phase, expected", [(None, True), ("", False), ("Deleting", False)])
def test_wait_for_cluster_deletion_uses_not_found_as_the_deletion_signal(
    monkeypatch: pytest.MonkeyPatch, phase: str | None, expected: bool
) -> None:
    k8s = Mock(spec=K8sClient)
    k8s.get_cluster_order_phase.return_value = phase
    captured: dict[str, Any] = {}

    for cleanup in (
        "_force_cleanup_agentcluster_finalizers",
        "_force_cleanup_agent_labels",
        "_force_cleanup_machine_preterminate_hooks",
    ):
        monkeypatch.setattr(helpers, cleanup, lambda **kwargs: None)

    def capture_poll(**kwargs: Any) -> None:
        captured.update(kwargs)

    monkeypatch.setattr(helpers, "poll_until", capture_poll)
    helpers.wait_for_cluster_deletion(k8s=k8s, name="cluster-a")

    assert captured["fn"]() is expected


def test_wait_for_cluster_deletion_propagates_kubectl_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    k8s = Mock(spec=K8sClient)
    error = subprocess.CalledProcessError(1, ["kubectl"], stderr="Unable to connect to the server")
    k8s.get_cluster_order_phase.side_effect = error

    for cleanup in (
        "_force_cleanup_agentcluster_finalizers",
        "_force_cleanup_agent_labels",
        "_force_cleanup_machine_preterminate_hooks",
    ):
        monkeypatch.setattr(helpers, cleanup, lambda **kwargs: None)

    def invoke_once(**kwargs: Any) -> None:
        kwargs["fn"]()

    monkeypatch.setattr(helpers, "poll_until", invoke_once)

    with pytest.raises(subprocess.CalledProcessError) as exc_info:
        helpers.wait_for_cluster_deletion(k8s=k8s, name="cluster-a")

    assert exc_info.value.stderr == "Unable to connect to the server"
