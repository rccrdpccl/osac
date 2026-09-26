"""Small, redacted snapshot of the CaaS worker-install boundary on test timeout."""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from tests.e2e.core.k8s_client import K8sClient

logger = logging.getLogger(__name__)
_SAFE_CODE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\Z")
_SENSITIVE = re.compile(r"secret|token|password|credential|kubeconfig|bearer|private", re.I)


def _code(value: object) -> str:
    if isinstance(value, str) and _SAFE_CODE.fullmatch(value) and not _SENSITIVE.search(value):
        return value
    return "redacted"


def _count(value: object) -> int | None:
    return value if type(value) is int else None


def _conditions(status: dict[str, Any]) -> list[dict[str, str]]:
    return [
        {key: _code(condition.get(key)) for key in ("type", "status", "reason")}
        for condition in status.get("conditions", [])[:8]
        if isinstance(condition, dict)
    ]


def log_worker_readiness_snapshot(*, k8s: K8sClient, order_name: str) -> None:
    """Log only selected state; never log raw objects, messages, MACs, or exception text."""
    snapshot: dict[str, Any] = {"order": _code(order_name)}
    try:
        status = k8s.get_json(resource="clusterorder", name=order_name).get("status", {})
        snapshot["workers"] = [
            {"name": _code(worker.get("name")), "phase": _code(worker.get("phase"))}
            for worker in status.get("workers", [])[:10]
            if isinstance(worker, dict)
        ]
        snapshot["readyWorkers"] = _count(status.get("readyWorkers"))
    except Exception:  # Diagnostic collection must not mask the original timeout.
        snapshot["workers"] = "unavailable"

    try:
        items = k8s.list_json(resource="agents.agent-install.openshift.io", namespace=k8s.namespace).get("items", [])
        snapshot["agents"] = [
            {
                "name": _code(item.get("metadata", {}).get("name")),
                "bound": item.get("spec", {}).get("clusterDeploymentName", {}).get("name") == order_name,
                "state": _code(item.get("status", {}).get("debugInfo", {}).get("state")),
                "conditions": _conditions(item.get("status", {})),
            }
            for item in items
            if (
                item.get("metadata", {}).get("labels", {}).get("osac.openshift.io/clusterorder") == order_name
                or item.get("metadata", {}).get("labels", {}).get("infraenvs.agent-install.openshift.io")
                == f"{order_name}-infraenv"
            )
        ][:10]
    except Exception:
        snapshot["agents"] = "unavailable"

    try:
        namespace = k8s.get_cluster_order_namespace(name=order_name)
        if not namespace:
            raise ValueError("no hosted cluster namespace")
        items = k8s.list_json(resource="nodepools.hypershift.openshift.io", namespace=namespace).get("items", [])
        snapshot["nodePools"] = [
            {
                "name": _code(item.get("metadata", {}).get("name")),
                "desired": _count(item.get("spec", {}).get("replicas")),
                "current": _count(item.get("status", {}).get("replicas")),
                "conditions": _conditions(item.get("status", {})),
            }
            for item in items
            if item.get("metadata", {}).get("labels", {}).get("osac.openshift.io/clusterorder") == order_name
        ][:10]
    except Exception:
        snapshot["nodePools"] = "unavailable"

    logger.warning("CaaS worker readiness snapshot: %s", json.dumps(snapshot, sort_keys=True))
