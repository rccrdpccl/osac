"""VM worker proof. Set OSAC_CAAS_VM_CLUSTER_VERSION to a ClusterVersion with a VM-bootable RHCOS DiskImage.

Requires CaaS and VMaaS on the same hub and the published ocp-virt-vm template.
Agent binding and guest Ready are deliberately outside this test until VM MAC feedback lands.
"""

import os

import pytest

from tests.e2e.core.grpc_client import GRPCClient
from tests.e2e.core.helpers import (
    delete_instance_type_if_present,
    unique_name,
    wait_for_cluster_deletion_without_cleanup,
    wait_for_cluster_grpc_removal,
    wait_for_cluster_order_cr,
    wait_for_cr,
    wait_for_deletion,
    wait_for_grpc_removal,
    wait_for_running,
)
from tests.e2e.core.k8s_client import K8sClient
from tests.e2e.core.osac_cli import OsacCLI
from tests.e2e.core.runner import poll_until
from tests.e2e.core.wait_kinds import WaitResourceKind


@pytest.mark.regression
@pytest.mark.skipif(not os.getenv("OSAC_CAAS_VM_CLUSTER_VERSION"), reason="requires a VM-backed CaaS deployment")
def test_compute_worker_lifecycle(
    cli: OsacCLI,
    grpc: GRPCClient,
    private_grpc: GRPCClient,
    k8s_hub_client: K8sClient,
    cluster_template: str,
    pull_secret_name: str,
) -> None:
    k8s = k8s_hub_client
    profile = unique_name("e2e-vm-worker")
    private_grpc.create_instance_type(name=profile, vcpus=4, memory_gib=16)
    try:
        cluster_id = cli.create_cluster(
            name=unique_name("e2e-caas-vm"),
            template=cluster_template,
            version=os.environ["OSAC_CAAS_VM_CLUSTER_VERSION"],
            pull_secret=pull_secret_name,
            node_sets=[f"name=workers,size=1,compute-instance-type={profile}"],
        )
        order = ""
        try:
            order = wait_for_cluster_order_cr(k8s=k8s, uuid=cluster_id)
            workers = poll_until(
                fn=lambda: k8s.get_cluster_order_status(name=order).get("workers", []),
                until=lambda ws: len(ws) == 1 and bool(ws[0].get("bareMetalInstance", {}).get("id")),
                retries=120,
                delay=5,
                description="ComputeInstance worker identity recorded",
                resource_kind=WaitResourceKind.CLUSTER_ORDER,
                resource_id=order,
            )
            assert workers[0]["kind"] == "ComputeInstance"
            vm_id = workers[0]["bareMetalInstance"]["id"]
            vm = grpc.get_compute_instance(ci_id=vm_id)["object"]
            assert vm["metadata"]["annotations"]["osac.openshift.io/owner-reference"] == f"ClusterOrder/{order}"
            assert vm["spec"]["instanceType"]["name"] == profile
            assert vm["spec"]["diskImage"]["id"]
            vm_cr = wait_for_cr(k8s=k8s, uuid=vm_id)
            wait_for_running(k8s=k8s, name=vm_cr)
        finally:
            cli.delete_cluster(uuid=cluster_id)
            if order:
                wait_for_cluster_deletion_without_cleanup(k8s=k8s, name=order)
            wait_for_cluster_grpc_removal(grpc=grpc, uuid=cluster_id)
        wait_for_deletion(k8s=k8s, name=vm_cr)
        wait_for_grpc_removal(grpc=grpc, uuid=vm_id)
    finally:
        delete_instance_type_if_present(grpc=private_grpc, name=profile)
