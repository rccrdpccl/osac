#!/usr/bin/env python3
"""One-shot CaaS test marking for OSAC-6117 coverage scoping.

Adds Ginkgo Label("caas") to CaaS-related spec containers and pytest markers.
Every replacement is an exact string that must occur exactly once in its file;
the script fails loudly otherwise. Run from the repository root.
"""

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent

# (file relative to repo root, old text, new text)
EDITS: list[tuple[str, str, str]] = []

# --- fulfillment-service/internal/servers (10 containers, 8 files) ---
for f, desc in [
    ("internal/servers/clusters_server_test.go", "Clusters server"),
    ("internal/servers/private_clusters_server_test.go", "Private clusters server"),
    ("internal/servers/cluster_templates_server_test.go", "Cluster templates server"),
    ("internal/servers/private_cluster_templates_server_test.go", "Private cluster templates server"),
    ("internal/servers/cluster_versions_server_test.go", "Public cluster versions server"),
    ("internal/servers/private_cluster_versions_server_test.go", "Private cluster versions server"),
]:
    EDITS.append(
        (f"fulfillment-service/{f}", f'Describe("{desc}", func() {{', f'Describe("{desc}", Label("caas"), func() {{')
    )
for desc in ["Cluster catalog items server", "Catalog publication and references"]:
    EDITS.append(
        (
            "fulfillment-service/internal/servers/cluster_catalog_items_server_test.go",
            f'Describe("{desc}", func() {{',
            f'Describe("{desc}", Label("caas"), func() {{',
        )
    )
for desc in ["Private cluster catalog items server", "Cluster Catalog Item policy application"]:
    EDITS.append(
        (
            "fulfillment-service/internal/servers/private_cluster_catalog_items_server_test.go",
            f'Describe("{desc}", func() {{',
            f'Describe("{desc}", Label("caas"), func() {{',
        )
    )

# --- fulfillment-service/it (8 containers, 8 files) ---
for f, desc in [
    ("it_cluster_reconciler_test.go", "Cluster reconciler"),
    ("it_private_cluster_templates_test.go", "Private cluster templates"),
    ("it_private_cluster_versions_test.go", "Private cluster versions"),
    ("it_public_cluster_templates_test.go", "Cluster templates"),
    ("it_public_clusters_network_attachment_test.go", "Cluster with ClusterNetworkAttachment"),
    ("it_public_clusters_test.go", "Public clusters"),
]:
    EDITS.append(
        (f"fulfillment-service/it/{f}", f'Describe("{desc}", func() {{', f'Describe("{desc}", Label("caas"), func() {{')
    )
EDITS.append(
    (
        "fulfillment-service/it/it_cluster_catalog_items_test.go",
        'Label("catalog-items")',
        'Label("catalog-items", "caas")',
    )
)
EDITS.append(
    (
        "fulfillment-service/it/it_cluster_pull_secret_test.go",
        'Label("secrets", "cluster")',
        'Label("secrets", "cluster", "caas")',
    )
)

# --- osac-operator/internal/controller clusterorder (11 containers + 2 Its) ---
for f, desc in [
    ("clusterorder_addon_operator_controller_test.go", "AddOnOperatorReconciler"),
    ("clusterorder_addon_operator_envtest_test.go", "AddOnOperatorReconciler envtest"),
    ("clusterorder_cleanup_test.go", "reconcileAutoExternalIPCleanup"),
    ("clusterorder_controller_test.go", "ClusterOrder Controller"),
    ("clusterorder_controller_test.go", "ClusterOrder phase transition time"),
    ("clusterorder_envtest_test.go", "ClusterOrder Integration Tests"),
    ("clusterorder_events_test.go", "ClusterOrder transition events"),
    ("clusterorder_feedback_controller_test.go", "ClusterOrder FeedbackReconciler"),
    ("clusterorder_feedback_controller_test.go", "humanizeConditionName"),
    ("clusterorder_stall_test.go", "ClusterOrder stall detection"),
    ("clusterorder_worker_status_test.go", "ClusterOrder worker status contract"),
]:
    EDITS.append(
        (
            f"osac-operator/internal/controller/{f}",
            f'Describe("{desc}", func() {{',
            f'Describe("{desc}", Label("caas"), func() {{',
        )
    )
for it in [
    "tracks independent NodePool capacity when NodeSets share hardware",
    "synchronizes feedback by NodeSet rather than the first matching instance type",
]:
    EDITS.append(
        (
            "osac-operator/internal/controller/clusterorder_nodesets_test.go",
            f'It("{it}", func() {{',
            f'It("{it}", Label("caas"), func() {{',
        )
    )

# --- osac-operator internal/controller baremetalworker_* (4 files, 13 labels) ---
# These files carry N identical Label("baremetalworker") declarations;
# replace all of them in one pass per file.
for f, count in [
    ("baremetalworker_convergence_test.go", 1),
    ("baremetalworker_lifecycle_test.go", 1),
    ("baremetalworker_reconciler_test.go", 10),
    ("baremetalworker_tenant_safety_test.go", 1),
]:
    EDITS.append(
        (f"osac-operator/internal/controller/{f}", 'Label("baremetalworker")', 'Label("baremetalworker", "caas")')
    )
    EDITS[-1] = (*EDITS[-1], count)  # expected occurrence count

# --- osac-operator/internal/controller/baremetalworker subpackage: suite label ---
EDITS.append(
    (
        "osac-operator/internal/controller/baremetalworker/fulfillment_test.go",
        'RunSpecs(t, "BareMetalWorker Suite")',
        'RunSpecs(t, "BareMetalWorker Suite", Label("caas", "baremetalworker"))',
    )
)

# --- osac-operator/test/integration (Kind suite, 1 container) ---
EDITS.append(
    (
        "osac-operator/test/integration/baremetalworker_test.go",
        'Describe("Bare-metal worker deployment", func() {',
        'Describe("Bare-metal worker deployment", Label("caas"), func() {',
    )
)


def main() -> int:
    failures: list[str] = []
    for edit in EDITS:
        rel, old, new, *rest = edit
        expected = rest[0] if rest else 1
        path = ROOT / rel
        text = path.read_text()
        n = text.count(old)
        if n != expected:
            failures.append(f"{rel}: expected {expected} occurrence(s) of {old!r}, found {n}")
            continue
        path.write_text(text.replace(old, new))
        print(f"marked: {rel}: {n}x {old[:50]}...")
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(" ", f)
        return 1
    print(f"\nAll {len(EDITS)} edit groups applied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
