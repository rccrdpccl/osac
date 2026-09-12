from __future__ import annotations

from collections.abc import Callable
from unittest.mock import Mock

import pytest

from tests.e2e.core import helpers


def test_wait_for_cluster_ready_fails_immediately_on_failed_order(monkeypatch: pytest.MonkeyPatch) -> None:
    k8s = Mock()
    k8s.get_cluster_order_phase.return_value = "Failed"

    def run_once(*, fn: Callable[[], str], until: Callable[[str], bool], **_kwargs: object) -> str:
        return fn()

    monkeypatch.setattr(helpers, "poll_until", run_once)

    with pytest.raises(AssertionError, match="order-test entered Failed phase"):
        helpers.wait_for_cluster_ready(k8s=k8s, name="order-test")
