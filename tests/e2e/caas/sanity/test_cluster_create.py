from __future__ import annotations

import contextlib
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import pytest

from tests.e2e.catalog.conftest import unique_name
from tests.e2e.core.grpc_client import GRPCClient
from tests.e2e.core.helpers import (
    wait_for_cluster_deleting,
    wait_for_cluster_deletion,
    wait_for_cluster_grpc_deleting_or_archived,
    wait_for_cluster_grpc_removal,
    wait_for_cluster_guest_readiness,
    wait_for_cluster_order_condition,
    wait_for_cluster_order_cr,
    wait_for_cluster_progressing,
    wait_for_cluster_ready,
    wait_for_hosted_cluster_kubeconfig,
)
from tests.e2e.core.k8s_client import K8sClient
from tests.e2e.core.metering import MeteringCollector
from tests.e2e.core.osac_cli import OsacCLI
from tests.e2e.core.runner import env, poll_until, run

pytestmark = pytest.mark.sanity

# Real OCP release image used to provision the ClusterVersion(s) created by these
# tests. Fixed (not randomly generated) so repeated runs reuse the same
# ClusterVersion via GRPCClient.ensure_cluster_version instead of accumulating
# duplicates on the shared cluster.
TEST_RELEASE_IMAGE = env("OSAC_TEST_RELEASE_IMAGE", "quay.io/openshift-release-dev/ocp-release:4.22.0-multi")
RHCOS_IMAGE = env("OSAC_RHCOS_BMI_IMAGE", "oci://quay.io/rh_ee_rpiccoli/rhcos-bmi:4.22.0")


@pytest.mark.metering
def test_cluster_create(
    cli: OsacCLI,
    grpc: GRPCClient,
    private_grpc: GRPCClient,
    k8s_hub_client: K8sClient,
    cluster_template: str,
    pull_secret_path: str,
    ssh_public_key_path: str,
    metering: MeteringCollector,
) -> None:
    """Verify the full CaaS cluster lifecycle: create, provision to Ready, version and
    releaseImage propagation to the HostedCluster, N+1 metering heartbeat decomposition,
    worker scale-up reflected in updated.v1 metering, and deletion."""

    private_grpc.ensure_host_type(name="ci-worker")
    private_grpc.ensure_bare_metal_instance_type(
        name="ci-worker-bm", host_label_selector={"osac.openshift.io/host-type": "default"}
    )
    disk_image_id = private_grpc.ensure_disk_image(name="rhcos-4-22", source_ref=RHCOS_IMAGE)
    version = private_grpc.ensure_cluster_version(
        version="4.22.0-rhcos", image=TEST_RELEASE_IMAGE, disk_image=disk_image_id
    )
    name = unique_name("e2e-cluster")
    uuid = cli.create_cluster(
        name=name,
        template=cluster_template,
        version=version["name"],
        node_sets={"workers": {"size": 1, "baremetal_instance_type": {"name": "ci-worker-bm"}}},
        template_parameter_files={"pull_secret": pull_secret_path},
        template_parameters={"ssh_public_key": Path(ssh_public_key_path).read_text().strip()},
    )
    metering.expect("osac.resource.created.v1", resource_id=uuid)

    try:
        co_name = wait_for_cluster_order_cr(k8s=k8s_hub_client, uuid=uuid)
        assert uuid in grpc.list_cluster_ids()

        wait_for_cluster_progressing(k8s=k8s_hub_client, name=co_name)
        metering.expect("osac.resource.started.v1", resource_id=uuid)
        metering.verify()

        wait_for_cluster_order_condition(k8s=k8s_hub_client, name=co_name, condition_type="ClusterAvailable")

        # Verify version resolved and propagated end-to-end:
        # fulfillment-service version resolution -> ClusterOrder releaseImage -> HostedCluster image
        cluster = grpc.get_cluster(cluster_id=uuid)
        version_name = cluster.get("object", {}).get("spec", {}).get("version", {}).get("name", "")
        assert version_name, "Cluster should have a resolved version name"
        assert version_name == version["name"]

        cluster_order_spec = k8s_hub_client.get_cluster_order_spec(name=co_name)
        co_release_image = cluster_order_spec.get("releaseImage", "")
        assert co_release_image, "ClusterOrder should have a resolved releaseImage"

        hosted_cluster_name, hosted_cluster_ns = poll_until(
            fn=lambda: (
                k8s_hub_client.get_cluster_order_hosted_cluster_name(name=co_name),
                k8s_hub_client.get_cluster_order_namespace(name=co_name),
            ),
            until=lambda reference: all(reference),
            retries=30,
            delay=5,
            description=f"{co_name} HostedCluster reference",
        )
        hosted_cluster_image = run(
            *k8s_hub_client._base(),
            "get",
            "hostedcluster",
            hosted_cluster_name,
            "-n",
            hosted_cluster_ns,
            "-o",
            "jsonpath={.spec.release.image}",
        )
        assert hosted_cluster_image == co_release_image, (
            f"HostedCluster image {hosted_cluster_image!r} != ClusterOrder releaseImage {co_release_image!r}"
        )

        node_sets = cluster.get("object", {}).get("spec", {}).get("nodeSets", {})
        assert node_sets, "Cluster spec should have at least one node set for the scaling test"
        worker_node_set = next(iter(node_sets))
        original_size = int(node_sets[worker_node_set].get("size", 1))
        node_requests = cluster_order_spec.get("nodeRequests", [])
        assert len(node_requests) == 1, "Expected one node request for the CaaS sanity scenario"
        worker_resource_class = node_requests[0].get("resourceClass", "")

        def _get_node_pool() -> dict[str, Any] | None:
            node_pools = k8s_hub_client.list_json(
                resource="nodepools.hypershift.openshift.io", namespace=hosted_cluster_ns
            ).get("items", [])
            return next(
                (
                    item
                    for item in node_pools
                    if item.get("metadata", {}).get("labels", {}).get("osac.openshift.io/resource_class")
                    == worker_resource_class
                ),
                None,
            )

        workload_kubeconfig = wait_for_hosted_cluster_kubeconfig(
            k8s=k8s_hub_client, hosted_cluster_namespace=hosted_cluster_ns, hosted_cluster_name=hosted_cluster_name
        )
        with tempfile.NamedTemporaryFile(prefix="osac-workload-", suffix=".kubeconfig") as kubeconfig_file:
            kubeconfig_file.write(workload_kubeconfig)
            kubeconfig_file.flush()
            workload_k8s_client = K8sClient(
                namespace=hosted_cluster_ns, kubeconfig=kubeconfig_file.name, as_system_admin=False
            )
            node_pool = wait_for_cluster_guest_readiness(
                k8s=k8s_hub_client,
                name=co_name,
                workload_k8s=workload_k8s_client,
                expected_workers=original_size,
                get_node_pool=_get_node_pool,
                expected_ready_nodes=original_size,
                node_pool_description=f"{hosted_cluster_name} NodePool {worker_resource_class} ready nodes",
            )
        assert node_pool is not None, f"No NodePool found for resource class {worker_resource_class!r}"

        # Derive expected N+1 count from cluster spec
        expected_components = 1 + len(node_sets)

        # Verify N+1 heartbeat decomposition
        metering.expect("osac.resource.heartbeat.v1", resource_id=uuid, timeout=180)
        metering.verify()

        heartbeats = metering.get_all_events("osac.resource.heartbeat.v1", resource_id=uuid)
        hb_components = [ev.get("data", {}).get("billing_dimensions", {}).get("component") for ev in heartbeats]
        cp_count = sum(1 for c in hb_components if c == "control_plane")
        worker_count = sum(1 for c in hb_components if c == "worker")
        assert cp_count >= 1, f"Expected at least 1 control_plane heartbeat, got {cp_count}"
        assert worker_count >= len(node_sets), (
            f"Expected at least {len(node_sets)} worker heartbeat(s), got {worker_count}"
        )
        assert len(heartbeats) >= expected_components, (
            f"Expected at least {expected_components} heartbeat events (1 cp + {len(node_sets)} workers), "
            f"got {len(heartbeats)}"
        )

        # Verify started.v1 carries correct resource type and cluster template
        started = metering.get_event("osac.resource.started.v1", resource_id=uuid)
        assert started.get("osacresourcetype") == "cluster_order"
        started_bd = started.get("data", {}).get("billing_dimensions", {})
        assert started_bd.get("cluster_template") == cluster_template, (
            f"cluster_template mismatch: {started_bd.get('cluster_template')!r} != {cluster_template!r}"
        )

        # Scale a worker node set and verify updated.v1
        scaled_size = original_size + 1
        cli.scale_cluster(uuid=uuid, node_set=worker_node_set, size=scaled_size)
        metering.expect("osac.resource.updated.v1", resource_id=uuid, timeout=120)
        metering.verify()

        updated = metering.get_event("osac.resource.updated.v1", resource_id=uuid)
        updated_bd = updated.get("data", {}).get("billing_dimensions", {})
        assert updated_bd.get("node_set") == worker_node_set, (
            f"updated.v1 node_set mismatch: {updated_bd.get('node_set')!r} != {worker_node_set!r}"
        )
        assert updated_bd.get("node_count") == scaled_size, (
            f"updated.v1 node_count should be {scaled_size}, got {updated_bd.get('node_count')}"
        )

        # Scale back before deletion
        cli.scale_cluster(uuid=uuid, node_set=worker_node_set, size=original_size)

        cli.delete_cluster(uuid=uuid)
        metering.expect("osac.resource.deleted.v1", resource_id=uuid)

        wait_for_cluster_deleting(k8s=k8s_hub_client, name=co_name)
        wait_for_cluster_grpc_deleting_or_archived(grpc=grpc, uuid=uuid)

        wait_for_cluster_deletion(k8s=k8s_hub_client, name=co_name)
        wait_for_cluster_grpc_removal(grpc=grpc, uuid=uuid)
        metering.verify()
    finally:
        with contextlib.suppress(subprocess.SubprocessError):
            cli.delete_cluster(uuid=uuid)


@pytest.mark.metering
def test_cluster_create_with_two_node_sets(
    cli: OsacCLI,
    grpc: GRPCClient,
    private_grpc: GRPCClient,
    k8s_hub_client: K8sClient,
    cluster_template: str,
    pull_secret_path: str,
    ssh_public_key_path: str,
    metering: MeteringCollector,
) -> None:
    """Verify NodePool replicas stay isolated when a cluster has two BMaaS node sets."""

    resource_classes = {"compute": "ci-worker-bm", "gpu": "ci-worker-bm-gpu"}
    for resource_class in resource_classes.values():
        private_grpc.ensure_bare_metal_instance_type(
            name=resource_class, host_label_selector={"osac.openshift.io/host-type": "default"}
        )

    version = private_grpc.ensure_cluster_version(
        version="4.22.0-rhcos",
        image=TEST_RELEASE_IMAGE,
        disk_image=private_grpc.ensure_disk_image(name="rhcos-4-22", source_ref=RHCOS_IMAGE),
    )
    name = unique_name("e2e-cluster-two-node-sets")
    uuid = cli.create_cluster(
        name=name,
        template=cluster_template,
        version=version["name"],
        node_sets={
            node_set: {"size": 1, "baremetal_instance_type": {"name": resource_class}}
            for node_set, resource_class in resource_classes.items()
        },
        template_parameter_files={"pull_secret": pull_secret_path},
        template_parameters={"ssh_public_key": Path(ssh_public_key_path).read_text().strip()},
    )
    metering.expect("osac.resource.created.v1", resource_id=uuid)

    try:
        co_name = wait_for_cluster_order_cr(k8s=k8s_hub_client, uuid=uuid)
        assert uuid in grpc.list_cluster_ids()
        wait_for_cluster_progressing(k8s=k8s_hub_client, name=co_name)
        metering.expect("osac.resource.started.v1", resource_id=uuid)
        metering.verify()
        wait_for_cluster_order_condition(k8s=k8s_hub_client, name=co_name, condition_type="ClusterAvailable")
        wait_for_cluster_ready(k8s=k8s_hub_client, name=co_name)

        cluster_order = k8s_hub_client.get_json(resource="clusterorder", name=co_name)
        node_requests = cluster_order.get("spec", {}).get("nodeRequests", [])
        expected_replicas = {
            request["resourceClass"]: int(request["numberOfNodes"])
            for request in node_requests
            if request.get("resourceClass") in resource_classes.values()
        }
        assert expected_replicas == {resource_class: 1 for resource_class in resource_classes.values()}

        hosted_cluster_ns = k8s_hub_client.get_cluster_order_namespace(name=co_name)
        resource_class_label = "osac.openshift.io/resource_class"

        def _get_node_pools() -> dict[str, dict[str, Any]]:
            items = k8s_hub_client.list_json(
                resource="nodepools.hypershift.openshift.io", namespace=hosted_cluster_ns
            ).get("items", [])
            return {
                item.get("metadata", {}).get("labels", {}).get(resource_class_label, ""): item
                for item in items
                if item.get("metadata", {}).get("labels", {}).get(resource_class_label) in expected_replicas
            }

        node_pools = poll_until(
            fn=_get_node_pools,
            until=lambda pools: (
                set(pools) == set(expected_replicas)
                and all(
                    int(pools[resource_class].get("spec", {}).get("replicas", -1)) == replicas
                    for resource_class, replicas in expected_replicas.items()
                )
            ),
            retries=60,
            delay=10,
            description=f"{co_name} per-resource-class NodePool replicas",
        )

        for resource_class, node_pool in node_pools.items():
            labels = node_pool.get("metadata", {}).get("labels", {})
            assert labels.get("osac.openshift.io/clusterorder") == co_name
            selector = node_pool.get("spec", {}).get("platform", {}).get("agent", {}).get("agentLabelSelector", {})
            assert selector.get("matchLabels", {}).get(resource_class_label) == resource_class

        agents_before = k8s_hub_client.list_json(
            resource="agents.agent-install.openshift.io", namespace="hardware-inventory"
        )
        surviving_agents = {
            item["metadata"]["name"]
            for item in agents_before.get("items", [])
            if item.get("metadata", {}).get("labels", {}).get("osac.openshift.io/clusterorder") == co_name
            and item.get("metadata", {}).get("labels", {}).get(resource_class_label) == resource_classes["gpu"]
        }
        assert len(surviving_agents) == 1, f"Expected one GPU Agent, got {surviving_agents}"

        before_updated_ids = {
            event.get("id") for event in metering.get_all_events("osac.resource.updated.v1", resource_id=uuid)
        }
        cli.scale_cluster(uuid=uuid, node_set="compute", size=0)

        def _scaled_node_pools() -> dict[str, dict[str, Any]]:
            pools = _get_node_pools()
            if set(pools) != set(expected_replicas):
                return {}
            if int(pools[resource_classes["compute"]].get("spec", {}).get("replicas", -1)) != 0:
                return {}
            if int(pools[resource_classes["gpu"]].get("spec", {}).get("replicas", -1)) != 1:
                return {}
            return pools

        poll_until(
            fn=_scaled_node_pools,
            until=lambda pools: bool(pools),
            retries=60,
            delay=10,
            description=f"{co_name} isolated NodePool scale-down",
        )

        def _worker_counts() -> tuple[int, int, int]:
            status = k8s_hub_client.get_json(resource="clusterorder", name=co_name).get("status", {})
            return tuple(int(status.get(key, -1)) for key in ("desiredWorkers", "currentWorkers", "readyWorkers"))

        counts = poll_until(
            fn=_worker_counts,
            until=lambda value: value[0] == 1 and value[1] >= 1 and value[2] >= 1,
            retries=60,
            delay=10,
            description=f"{co_name} worker aggregate after compute scale-down",
        )
        assert counts == (1, 1, 1)

        agents_after = k8s_hub_client.list_json(
            resource="agents.agent-install.openshift.io", namespace="hardware-inventory"
        )
        surviving_agents_after = {
            item["metadata"]["name"]
            for item in agents_after.get("items", [])
            if item.get("metadata", {}).get("labels", {}).get("osac.openshift.io/clusterorder") == co_name
            and item.get("metadata", {}).get("labels", {}).get(resource_class_label) == resource_classes["gpu"]
        }
        assert surviving_agents_after == surviving_agents

        def _find_updated_event() -> dict[str, Any] | None:
            for event in metering.get_all_events("osac.resource.updated.v1", resource_id=uuid):
                if event.get("id") not in before_updated_ids:
                    return event
            return None

        updated = poll_until(
            fn=_find_updated_event,
            until=lambda event: event is not None,
            retries=60,
            delay=2,
            description=f"{co_name} scale update metering event",
        )
        assert updated is not None
        updated_bd = updated.get("data", {}).get("billing_dimensions", {})
        assert updated_bd.get("node_set") == "compute"
        assert updated_bd.get("node_count") == 0

        cli.delete_cluster(uuid=uuid)
        metering.expect("osac.resource.deleted.v1", resource_id=uuid)
        wait_for_cluster_deleting(k8s=k8s_hub_client, name=co_name)
        wait_for_cluster_grpc_deleting_or_archived(grpc=grpc, uuid=uuid)
        wait_for_cluster_deletion(k8s=k8s_hub_client, name=co_name)
        wait_for_cluster_grpc_removal(grpc=grpc, uuid=uuid)
        metering.verify()
    finally:
        with contextlib.suppress(subprocess.SubprocessError):
            cli.delete_cluster(uuid=uuid)


def test_cluster_create_with_version(
    cli: OsacCLI,
    grpc: GRPCClient,
    private_grpc: GRPCClient,
    k8s_hub_client: K8sClient,
    cluster_template: str,
    pull_secret_path: str,
    ssh_public_key_path: str,
) -> None:
    """Verify explicit --version resolution: the Cluster API resource stores the
    version reference, the ClusterVersion cannot be deleted while referenced,
    and the ClusterOrder CR's releaseImage is resolved from the matching
    ClusterVersion. Does not wait for full provisioning — the HostedCluster
    image propagation is covered by test_cluster_create."""
    private_grpc.ensure_bare_metal_instance_type(
        name="ci-worker-bm", host_label_selector={"osac.openshift.io/host-type": "default"}
    )
    disk_image_id = private_grpc.ensure_disk_image(name="rhcos-4-22", source_ref=RHCOS_IMAGE)
    version = private_grpc.ensure_cluster_version(
        version="4.20.0-e2e", image=TEST_RELEASE_IMAGE, disk_image=disk_image_id
    )

    name = unique_name("e2e-cluster-version")
    uuid = cli.create_cluster(
        name=name,
        template=cluster_template,
        version=version["name"],
        node_sets={"workers": {"size": 1, "baremetal_instance_type": {"name": "ci-worker-bm"}}},
        template_parameter_files={"pull_secret": pull_secret_path},
        template_parameters={"ssh_public_key": Path(ssh_public_key_path).read_text().strip()},
    )

    try:
        co_name = wait_for_cluster_order_cr(k8s=k8s_hub_client, uuid=uuid)

        cluster = grpc.get_cluster(cluster_id=uuid)
        assert cluster["object"]["spec"]["version"]["name"] == version["name"]

        # While the cluster references this version, deletion must be rejected
        output, rc = private_grpc.call_unchecked(
            service="osac.private.v1.ClusterVersions/Delete", data={"id": version["id"]}
        )
        assert rc != 0, f"Expected delete to be rejected for referenced version, got: {output}"
        assert "FailedPrecondition" in output or "referenced" in output.lower(), (
            f"Expected FailedPrecondition or 'referenced' in rejection, got: {output}"
        )

        release_image = poll_until(
            fn=lambda: k8s_hub_client.get_cluster_order_spec(name=co_name).get("releaseImage", ""),
            until=lambda v: v != "",
            retries=30,
            delay=5,
            description=f"{co_name} ClusterOrder releaseImage resolution",
        )
        assert release_image == TEST_RELEASE_IMAGE

        cli.delete_cluster(uuid=uuid)

        wait_for_cluster_deleting(k8s=k8s_hub_client, name=co_name)
        wait_for_cluster_grpc_deleting_or_archived(grpc=grpc, uuid=uuid)
        wait_for_cluster_deletion(k8s=k8s_hub_client, name=co_name)
        wait_for_cluster_grpc_removal(grpc=grpc, uuid=uuid)
    finally:
        with contextlib.suppress(subprocess.CalledProcessError):
            cli.delete_cluster(uuid=uuid)


def test_cluster_create_rejected_for_invalid_version(
    grpc: GRPCClient, private_grpc: GRPCClient, cluster_template: str
) -> None:
    """Verify cluster creation is rejected for disabled, obsolete, and
    non-existent versions."""
    disabled = private_grpc.ensure_cluster_version(version="4.20.0-e2e-disabled", image=TEST_RELEASE_IMAGE)
    private_grpc.update_cluster_version(version_id=disabled["id"], enabled=False)

    obsolete = private_grpc.ensure_cluster_version(version="4.20.0-e2e-obsolete", image=TEST_RELEASE_IMAGE)
    private_grpc.update_cluster_version(version_id=obsolete["id"], state="CLUSTER_VERSION_STATE_OBSOLETE")

    def _create_with_version(version_name: str) -> tuple[str, int]:
        return grpc.call_unchecked(
            service="osac.public.v1.Clusters/Create",
            data={"object": {"spec": {"template": {"name": cluster_template}, "version": {"name": version_name}}}},
        )

    output, rc = _create_with_version(disabled["name"])
    assert rc != 0, f"Expected create to reject disabled version, got: {output}"
    assert "disabled" in output.lower(), f"Expected 'disabled' in rejection, got: {output}"

    output, rc = _create_with_version(obsolete["name"])
    assert rc != 0, f"Expected create to reject obsolete version, got: {output}"
    assert "obsolete" in output.lower(), f"Expected 'obsolete' in rejection, got: {output}"

    output, rc = _create_with_version("4-20-0-e2e-does-not-exist")
    assert rc != 0, f"Expected create to reject non-existent version, got: {output}"
    assert "not found" in output.lower(), f"Expected 'not found' in rejection, got: {output}"
