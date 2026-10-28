from __future__ import annotations

import subprocess
from typing import Any
from unittest.mock import Mock, call

import pytest

from tests.e2e import conftest as e2e_fixtures
from tests.e2e.core import helpers, runner
from tests.e2e.core.grpc_client import PRIVATE_API, GRPCClient

_NETWORKING_READY = "TENANT_CONDITION_TYPE_DEFAULT_NETWORKING_READY"


def _tenant(*conditions: dict[str, str]) -> dict[str, Any]:
    return {"id": "tenant-id", "status": {"state": "TENANT_STATE_SYNCED", "conditions": list(conditions)}}


def test_tenant_setup_creates_both_tenants_then_waits_for_their_networking(monkeypatch: pytest.MonkeyPatch) -> None:
    grpc = Mock(spec=GRPCClient)
    operations = Mock()
    operations.attach_mock(grpc.ensure_tenant, "create")
    wait = Mock()
    operations.attach_mock(wait, "wait")
    monkeypatch.setattr(e2e_fixtures, "wait_for_grpc_tenant_default_networking_ready", wait, raising=False)

    e2e_fixtures.ensure_tenants.__wrapped__(None, grpc)

    assert operations.mock_calls == [
        call.create(name="tenant1"),
        call.create(name="tenant2"),
        call.wait(grpc=grpc, name="tenant1"),
        call.wait(grpc=grpc, name="tenant2"),
    ]


def test_tenant_setup_replaces_the_separate_subnet_readiness_fixture() -> None:
    assert not hasattr(e2e_fixtures, "_wait_for_default_subnets_ready")


def test_tenant_networking_wait_requires_the_exact_condition_to_be_true(monkeypatch: pytest.MonkeyPatch) -> None:
    grpc = Mock(spec=GRPCClient)
    grpc.list_with_filter.side_effect = [
        [],
        [_tenant()],
        [_tenant({"type": "TENANT_CONDITION_TYPE_VAULT_READY", "status": "CONDITION_STATUS_TRUE"})],
        [_tenant({"type": _NETWORKING_READY, "status": "CONDITION_STATUS_UNSPECIFIED"})],
        [_tenant({"type": _NETWORKING_READY, "status": "CONDITION_STATUS_FALSE"})],
        [_tenant({"type": _NETWORKING_READY, "status": "CONDITION_STATUS_TRUE"})],
    ]
    sleep = Mock()
    monkeypatch.setattr(runner.time, "sleep", sleep)

    helpers.wait_for_grpc_tenant_default_networking_ready(grpc=grpc, name="tenant2")

    assert grpc.list_with_filter.call_count == 6
    grpc.list_with_filter.assert_called_with(
        service=f"{PRIVATE_API}.Tenants/List", filter_expr='this.metadata.name == "tenant2"'
    )
    assert sleep.call_args_list == [call(5)] * 5


@pytest.mark.parametrize("reason", ["AllResourcesReady", "NoDefaultNetworking", "ProvisioningDisabled"])
def test_tenant_networking_wait_accepts_ready_without_enumerating_resources(
    monkeypatch: pytest.MonkeyPatch, reason: str
) -> None:
    grpc = Mock(spec=GRPCClient)
    grpc.list_with_filter.return_value = [
        _tenant({"type": _NETWORKING_READY, "status": "CONDITION_STATUS_TRUE", "reason": reason})
    ]
    sleep = Mock()
    monkeypatch.setattr(runner.time, "sleep", sleep)

    helpers.wait_for_grpc_tenant_default_networking_ready(grpc=grpc, name="tenant1")

    assert grpc.list_with_filter.call_count == 1
    grpc.list_subnet_ids.assert_not_called()
    grpc.list_security_group_ids.assert_not_called()
    sleep.assert_not_called()


def test_tenant_networking_wait_retries_api_failures(monkeypatch: pytest.MonkeyPatch) -> None:
    grpc = Mock(spec=GRPCClient)
    grpc.list_with_filter.side_effect = [
        subprocess.CalledProcessError(returncode=1, cmd="grpcurl"),
        [_tenant({"type": _NETWORKING_READY, "status": "CONDITION_STATUS_TRUE"})],
    ]
    sleep = Mock()
    monkeypatch.setattr(runner.time, "sleep", sleep)

    helpers.wait_for_grpc_tenant_default_networking_ready(grpc=grpc, name="tenant1")

    assert grpc.list_with_filter.call_count == 2
    sleep.assert_called_once_with(5)


@pytest.mark.parametrize("status", [None, "CONDITION_STATUS_UNSPECIFIED", "CONDITION_STATUS_FALSE"])
def test_tenant_networking_wait_times_out_without_exposing_condition_messages(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture, status: str | None
) -> None:
    grpc = Mock(spec=GRPCClient)
    conditions = (
        []
        if status is None
        else [{"type": _NETWORKING_READY, "status": status, "message": "sensitive-provider-details"}]
    )
    grpc.list_with_filter.return_value = [_tenant(*conditions)]
    sleep = Mock()
    monkeypatch.setattr(runner.time, "sleep", sleep)

    with pytest.raises(TimeoutError) as exc_info:
        helpers.wait_for_grpc_tenant_default_networking_ready(grpc=grpc, name="tenant1")

    assert grpc.list_with_filter.call_count == 120
    assert sleep.call_args_list == [call(5)] * 119
    assert "sensitive-provider-details" not in str(exc_info.value) + caplog.text


def test_tenant_networking_wait_bounds_api_failures_without_exposing_credentials(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    grpc = Mock(spec=GRPCClient)
    grpc.list_with_filter.side_effect = subprocess.CalledProcessError(
        returncode=1, cmd=["grpcurl", "Bearer confidential-credential"], stderr="sensitive-error-details"
    )
    monkeypatch.setattr(runner.time, "sleep", lambda _: None)

    with pytest.raises(TimeoutError) as exc_info:
        helpers.wait_for_grpc_tenant_default_networking_ready(grpc=grpc, name="tenant1")

    assert grpc.list_with_filter.call_count == 120
    diagnostics = str(exc_info.value) + caplog.text
    assert "confidential-credential" not in diagnostics
    assert "sensitive-error-details" not in diagnostics
