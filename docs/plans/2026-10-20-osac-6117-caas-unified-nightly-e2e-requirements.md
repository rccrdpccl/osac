# OSAC CaaS Tests

**Issue:** [OSAC-6117](https://redhat.atlassian.net/browse/OSAC-6117) —
CaaS: Define minimal requirements for unified nightly E2E environment.
**Parent epic:** [OSAC-6112](https://redhat.atlassian.net/browse/OSAC-6112).
**Status:** Draft for review. Not implemented, not posted to Jira. Evidence
collected 2026-10-20 from the `osac` mono-repo (branch `plan/osac-6348`,
baseline `2a0d95f82314d7d0de326a66ce3ffe660055c876`), plus read-only clones of
`osac-project/osac-test-infra` (`3b45744`) and
`osac-project/enhancement-proposals` (`ca346e0`) under `/root/src/`.

**Measured coverage (2026-10-20):** UT **81.3%** and IT **63.1%** (combined
**82.6%**) of CaaS core statements, plus 63.9% of the BMF worker path — see
[coverage-osac-6117/caas-coverage.md](coverage-osac-6117/caas-coverage.md)
for the full report and artifacts. CaaS tests are now runtime-selectable
(`ginkgo --label-filter=caas`, `pytest -m caas`) via the marking changes in
`tools/caas-coverage/` (uncommitted, for review).

---

## How CaaS is distributed

Unlike a single-component service, a CaaS cluster order crosses eight
repositories/components before a guest cluster is Ready. Every test row below
names the links in this chain that it exercises:

```text
osac CLI / public+private gRPC (fulfillment-service + PostgreSQL)
  -> ClusterOrder CR (osac-operator: ClusterOrder controller)
     -> BareMetalWorkerReconciler -> BareMetalInstance (private gRPC)
        -> BMF operator -> BMH / Metal3 / Ironic (worker hosts)
  -> AAP job (osac-aap): lease, finalizer, cluster_working_namespace,
     cluster_settings, extract_template_info, cluster_network (steps
     collection), hosted_cluster (HostedCluster/NodePool), manage_agents,
     metallb_ingress, external_access (DNS), retrieve_kubeconfig, post_install,
     storage_provider (tenant CSI)
  -> InfraEnv / Agent (Assisted Service, MCE) -> guest nodes
  -> HostedControlPlane (HyperShift) -> guest cluster Ready
  -> metering-service (Kafka events) ; teardown runs the chain in reverse
```

Environment pieces the chain needs (hub SNO + MCE, MetalLB, Route53 DNS zone,
virtual BMHs + sushy-tools, RHCOS DiskImage + ClusterVersion, AAP instance
groups, Keycloak/Kafka/OpenBao, runner tooling) are specified in
[Appendix A](#appendix-a-minimal-caas-environment-requirements) — they are
OSAC-6117's other deliverables and the input to the Enclave/CI unified
environment (epic OSAC-6112).

**Related Jira context**

- Labels on OSAC-6117: `cross-wg`, `e2e`; component: `CaaS`.
- Sibling requirement tasks: Networking OSAC-6113, Storage OSAC-6114, VMaaS
  OSAC-6115, BMaaS OSAC-6116 (in Review — its Netbox/Metal3 answer is the
  model for worker inventory), Metering OSAC-6118, MaaS OSAC-6119.
- CaaS design epics that own the behavior under test: worker provisioning
  [OSAC-2135], cluster networking [OSAC-1436], cluster storage [OSAC-1332],
  cluster upgrade [OSAC-1415], granular status reporting [OSAC-1604], addon
  operator support [OSAC-4090], cross-cluster trust [OSAC-5343].
- Coverage follow-ups already tracked: per-component integration coverage
  [OSAC-4843], CI beyond day-1 [OSAC-5661], CaaS+BMaaS nightly [OSAC-4570,
  Closed], multi-node hot-plug resize [OSAC-5335].

---

## Test layers

| Layer | Tool | Location |
|---|---|---|
| **Unit / Envtest** | Go testing + Ginkgo; envtest API-server | `fulfillment-service/internal/servers`, `osac-operator/internal/controller` (+ `baremetalworker/`), `bare-metal-fulfillment-operator/`, `osac-metering/` |
| **Component integration** | Ginkgo `it/` on installer-deployed Kind; operator Kind suite | `fulfillment-service/it/`, `osac-operator/test/integration/`, `bare-metal-fulfillment-operator/test/integration/` |
| **AAP integration** | Ansible roles/playbooks against Kind | `osac-aap/tests/integration/targets/` |
| **Unit (test-harness)** | pytest, mocked clients/time | `tests/unit/test_caas_*.py`, `test_cluster_*.py` |
| **E2E** | pytest against deployed OSAC (cluster-tool SNO + virtual BMHs) | `tests/e2e/caas/`, `tests/e2e/references/`, `tests/e2e/storage/`; run by osac-test-infra workflows |
| **Render/build** | Helm template + schema contracts | `osac-installer` `mce-render-test`, `kind-runtime-test`, metering-auth render |

Suite selection is itself tested: `tests/unit/test_caas_ci_suite_policy.py`
runs the actual caller YAML and path-selection Bash from both osac and
osac-test-infra (needs `OSAC_TEST_INFRA_DIR`). PRs and merge queue run
`caas/sanity` only (`-m sanity`); periodics run all of `caas` plus
`references` marked `requires_caas`/`reference_common`.

## Coverage by area

### Good coverage — keep green

Measured statement coverage from the 2026-10-20 run
([report](coverage-osac-6117/caas-coverage.md)) is quoted per area.

| Area | Tests | Measured coverage / what is covered |
|---|---|---|
| Fulfillment Cluster APIs | 438 caas-labeled unit specs in `clusters_server_test.go`, `private_clusters_server_test.go`, and the 8 other cluster server test files; 59 caas-labeled `it/` specs across 9 files | **78.2% UT / 63.1% IT** of the cluster-server files — CRUD, catalog-item locking, version resolution, node-set validation, attachment validation, tenant scoping |
| Operator ClusterOrder controller | 414 caas-labeled specs across 10 files (`clusterorder_controller`, `_envtest`, `_feedback`, `_events`, `_stall`, `_cleanup`, `_worker_status`, `_nodesets`, addon-operator) | **85.6% UT** — reconciliation, feedback, stall/cleanup, worker status projection, events, addon operators |
| Operator BareMetalWorker | 434 specs (suite-labeled) across 20 files in `baremetalworker/` (documented R01–R10 in [INTEGRATION-TESTING.md](../../docs/INTEGRATION-TESTING.md)) | **82.0% UT** — reservation/allocation checkpoints, Agent-before-BMI cleanup, strict association, InfraEnv evidence, fulfillment unavailability, metrics, tenant isolation |
| Metering cluster events | `metering-service/internal/events/cluster_test.go` | **74.1% UT** of `events/cluster.go` |
| Test-harness unit regressions | 9 caas-marked files in `tests/unit/` (102 tests; 9 pre-existing failures at baseline, see report) | Teardown ordering, exact-NotFound polling, deletion diagnostics, worker BMI visibility, two-node-set/selector contracts, version selection, CLI node sets, CI suite policy |
| CaaS sanity E2E | 2 tests | Full create→Ready→scale→teardown journey with natural teardown, metering deleted events, worker metrics; fast deletion feedback |

### Medium coverage — known gaps

| Area | Tests / Files | % | Key gaps |
|---|---|---|---|
| CaaS E2E breadth | 5 tests in `caas/` (2 sanity + 3 regression) | — | No tenant-network attachment flow, no API/ingress reachability assertion, no guest-cluster PVC/CSI mount, no upgrade, no deletion under fabric port-move |
| References (`requires_caas`) | 6 tests in `test_cluster_baremetal_references.py` | — | Resource-reference chain only; no lifecycle |
| CaaS cluster storage E2E | 1 test (`storage/test_caas_cluster_storage.py`) | — | Asserts finalizer + `ClusterStorageReady` + tenant `clusterStorage[]`; **no PVC/CSI mount or application I/O on the guest** (explicitly recorded as a gap; guest LVMS prerequisites unresolved) |
| AAP hosted-cluster path | `hosted_cluster` role test.yml (NodePool transforms); integration targets `cluster_create_caas`, `cluster_delete_caas`, `cluster_post_install`, `cluster_status_reporting`, `cluster_working_namespace`, `tenant_cluster_storage_csi_driver_install_gate`; unit `test_hosted_cluster_delete_order.py` (4), `test_server_cluster_identity.py` (24) | — | Targets run against Kind with faked provider APIs — no real Assisted/HyperShift behavior (owned by OSAC-4843) |
| BMF operator (worker hosts) | Unit + Envtest + Kind (static Metal3) | — | Real Ironic/BMC/sushy boundary only exercised in E2E; contract suite missing (OSAC-4843) |
| Installer | `mce-render-test` (CaaS MCE enablement, assisted overrides, RBAC compat), `kind-runtime-test` | — | Render only; no installed-MCE validation |

### Weak / no coverage

| Area | Tests / Files | Key gaps |
|---|---|---|
| AAP service roles in the cluster chain | 0 unit tests each for `cluster_network`, `external_access`, `manage_agents`, `metallb_ingress`, `cluster_infra`, `retrieve_kubeconfig`, `write_ssh_keys`, `nmstate_config` | Only exercised inside deployed E2E; failures are hard to localize to a role |
| `ci.steps` network-step collection | 0 tests | CI-only agent-wait + DNS path has no Kind-level target at all |
| Cluster upgrade (OSAC-1415) | 0 E2E | No periodic validates version upgrade of a guest cluster |
| Addon operator flow (OSAC-4090) | Unit/envtest only (27 + 4 specs) | No deployed E2E |
| Fabric-connected cluster networking | 0 tests in mono-repo (`requires_caas_fabric` marker referenced by the Netris caller but defined nowhere) | The `network_attachment` → BMaaS port-move → DHCP discovery path is never exercised end to end; agentless-net periodic disabled while failing |

E2E infra is ready (nightly chain `nightly-build.yaml` 03:00 UTC → test-infra
`e2e-caas-full-install.yml`; periodic caller every 8 h; unified prototype
`e2e-full-regression.yml` every other day; Netris/agentless-net variants on
ephemeral EC2). Only **5 CaaS E2E tests** exist today. Specs below go in
`tests/e2e/caas/` (regression unless marked) plus `tests/e2e/storage/`.

## Prioritized E2E backlog

| Priority | Test name | Flow summary | Effort | Chain exercised |
|---|---|---|---|---|
| P1 | Cluster on tenant fabric Subnet | VirtualNetwork+Subnet → cluster with `network_attachment` → workers port-moved + DHCP → Ready | L | fulfillment → ClusterOrder → BMI → BMF/fabric → Assisted → HyperShift |
| P1 | Cluster API/ingress reachable | `api.<c>` / `*.apps.<c>` resolve and serve after Ready | M | external_access (MetalLB + DNS) → guest API server |
| P1 | Guest-cluster PVC end to end | After `ClusterStorageReady`: PVC + pod on guest, mount + I/O via storage tier | L | storage_provider (tenant CSI) → guest CSI → storage backend (VIP reachable) |
| P1 | Natural teardown with fabric port return | Delete cluster → workers released, fabric port back to provisioning net, no leaks | M | teardown chain + BMF sanitization + metering deleted events |
| P2 | Scale up/down with metering | Exists (`test_cluster_create`) — extend with ready-worker aggregates per NodeSet | S | BareMetalWorker capacity + metering `updated.v1` |
| P2 | Two node sets | Exists (`test_cluster_create_with_two_node_sets`) | — | per-NodeSet NodePool isolation, BMIT sharing |
| P2 | Version resolution + rejection | Exists (`test_cluster_version`) | — | ClusterVersion + DiskImage binding |
| P2 | Deprecated/obsolete RHCOS DiskImage rejection | Create cluster pinned to deprecated worker image → rejected with reason | S | DiskImage lifecycle → ClusterVersion → BMI creation |
| P2 | Worker provenance + tenant visibility | Exists partly — extend with tenant-user listing and owner-reference checks on unified install | S | public BMI API tenancy |
| P3 | Cluster upgrade (OSAC-1415) | Ready cluster → upgrade ClusterVersion → guest operators converge | L | upgrade path end to end |
| P3 | Addon operator install (OSAC-4090) | ClusterOrder with addon spec → addon operator deployed on guest | M | addon controller → guest OLM |
| P3 | Agent-flow parity on fabric backend | Netris/agentless variant with `caas-agent-flow=cluster-namespace` | M | operator-owned agent provisioning (OSAC-4134) on fabric |
| P3 | Shared-tenant rejection | Create cluster in `shared` tenant → early `INVALID_ARGUMENT` | S | tenancy validation (OSAC-6348 plan) |

## Spec cards (P1 + selected)

### P1 — Cluster on tenant fabric Subnet

- **Flow:** VirtualNetwork → Subnet → SecurityGroup → cluster with
  `network_attachment` (subnet + SG) → workers move provisioning→tenant
  network → DHCP addresses discovered → cluster Ready with tenant-network
  nodes
- **Effort:** L
- **Why:** The core OSAC-1436 contract. Today no test exercises the
  `network_attachment` field, the BMaaS-owned `move_network_attachment`, or
  MAC-based DHCP discovery — this is exactly the Networking+BMaaS annotation
  gap the epic records. The CLI test helper does not even expose the flag yet
  (prerequisite work).
- **Steps:**
  1. Create tenant VirtualNetwork + Subnet through the public networking API;
     wait `Ready` (fixture `wait_for_grpc_subnet_ready` already exists).
  2. Create the cluster with `network_attachment` referencing the Subnet
     (requires adding the flag to `OsacCLI.create_cluster` /
     `GRPCClient` helpers).
  3. Assert each worker BMI's attachment matches the Subnet and its status
     reports a tenant-network IP.
  4. Assert installed Agents report the tenant-network interface addresses.
  5. Assert `ClusterOrder` reaches `Ready` and guest nodes join.
- **Components:** fulfillment public/private Clusters APIs, ClusterOrder
  controller, BareMetalWorkerReconciler, BMF operator (port move, IP
  discovery), fabric manager steps, Assisted Agent inventory, metering
  create events.

### P1 — Cluster API/ingress reachable

- **Flow:** cluster Ready → `api.<name>.<zone>` and `*.apps.<name>.<zone>`
  resolve → kube-apiserver answers → guest ingress route serves
- **Effort:** M
- **Why:** External access is what makes a cluster usable. The VIP path
  (MetalLB `kube-apiserver` LB → `external_access` DNS records → wait for
  authoritative-NS propagation) is only implicitly covered today — no
  assertion ever connects to the guest API or ingress.
- **Steps:**
  1. After `wait_for_cluster_guest_readiness`, retrieve the hosted kubeconfig
     (helper exists: `wait_for_hosted_cluster_kubeconfig`).
  2. Resolve `api.<cluster>.<DNS_ZONE>`; assert it matches the
     kube-apiserver LB IP.
  3. `kubectl --kubeconfig <guest>` `get --raw /readyz` over the public
     hostname.
  4. Assert `*.apps` wildcard record resolves and the default router answers.
- **Components:** `ci.steps`/fabric external_access role, MetalLB, Route53
  (or DNS-API), kube-apiserver LB Service, retrieve_kubeconfig.

### P1 — Guest-cluster PVC end to end

- **Flow:** cluster Ready + `ClusterStorageReady` → PVC on guest → pod mounts
  volume → write/read I/O → teardown clean
- **Effort:** L
- **Why:** Closes the Storage+Networking gap the epic calls out (storage VIP
  unreachable from tenant networks) and the documented CSI gap ("these flows
  do not currently create a PVC through the OSAC CSI driver"). The
  cluster-storage lifecycle test stops at conditions and tenant status.
- **Steps:**
  1. Reuse `test_caas_cluster_storage.py` setup through
     `ClusterStorageReady`.
  2. Using the hosted kubeconfig, create a PVC bound to the tenant
     StorageClass.
  3. Run a pod that writes and reads a file on the volume; assert data.
  4. Delete pod + PVC; assert reclaim per the tier's policy.
- **Components:** storage controller, AAP `storage_provider` +
  `tenant_storage_class`, tenant CSI driver on guest, storage backend
  (LVMS/TopoLVM or VMS), fabric routing to the storage VIP.

### P1 — Natural teardown with fabric port return

- **Flow:** delete Ready cluster → worker BMIs released → BMHs sanitized and
  returned to pool with fabric port back on the provisioning network →
  parent/InfraEnv/fulfillment removal → metering `deleted` events → no leaks
- **Effort:** M
- **Why:** `test_cluster_create` already proves natural teardown on the
  `ci.steps` backend; the unified environment adds the fabric port return
  and host-sanitization assertions that only exist there. Leak checks
  protect the shared unified cluster for the next WG's suite.
- **Steps:**
  1. Delete the cluster; reuse the verified worker-BMI wait (480×5 s), parent
     NotFound wait (121×10 s), InfraEnv GC wait (60×5 s).
  2. Assert each released BMH is `available`/`staged` again with no consumer
     and (fabric backend) its port returned to the provisioning network.
  3. Assert DNS records for the cluster are removed or owned by cleanup.
  4. Assert metering `deleted` events (helper `_assert_worker_scale_metering`
     pattern; `MeteringCollector`).
- **Components:** ClusterOrder deletion chain, BareMetalWorker teardown, BMF
  sanitization, finalizers (infra, cluster-storage), metering projection.

### P2 — Deprecated/obsolete RHCOS DiskImage rejection

- **Flow:** deprecate/obsolete the DiskImage referenced by the test
  ClusterVersion → create cluster pinned to it → rejected with a clear
  condition; no ClusterOrder/BMI created
- **Effort:** S
- **Why:** Worker OS images are BMaaS-owned data the CaaS chain consumes.
  Fulfillment `it/` covers the missing-image `FailedPrecondition`
  (`it_public_clusters_test.go`) and deprecated/obsolete rejection for
  VMaaS ComputeInstances and BMI catalog items — but no test covers cluster
  creation pinned to a deprecated worker image through the deployed path
  (ClusterVersion → BMI create → AAP job).
- **Steps:**
  1. Register a second DiskImage + ClusterVersion pair; deprecate it via the
     private API.
  2. `osac create cluster --version <deprecated>` → expect failure with the
     documented reason.
  3. Assert no ClusterOrder CR and no worker BMI exist.
- **Components:** DiskImages API, ClusterVersion resolution, ClusterOrder
  create validation, BMI create refusal.

## Suite placement, markers, commands

- CaaS tests are now runtime-selectable: Ginkgo `Label("caas")` on the
  spec containers listed in
  [`tools/caas-coverage/SCOPE.md`](../../tools/caas-coverage/SCOPE.md), and
  `pytest -m caas` in `tests/unit` (marker registered in `pyproject.toml`).
- New scenarios live in `tests/e2e/caas/regression/` (cross-WG journeys are
  regression-tier by the [selection policy](../../docs/INTEGRATION-TESTING.md#caas-ci-selection-boundary));
  fabric-dependent ones need a marker — reconcile `requires_caas_fabric`
  (already referenced by the Netris caller) instead of inventing a new one,
  and register it in `tests/e2e/conftest.py`.
- Storage-card scenario extends `tests/e2e/storage/`.
- Keep the suite serial (`-n 0` is forced by `conftest.py` for `caas/`).
- Local validation before running deployed:

```bash
uv run pytest --collect-only tests/e2e/caas/
OSAC_TEST_INFRA_DIR=/root/src/osac-test-infra uv run pytest -n 0 tests/unit/test_caas_ci_suite_policy.py
uv run ruff check tests/e2e/caas/ && uv run ruff format --check tests/e2e/caas/
bash tools/caas-coverage/run-ut-coverage.sh   # measured UT/IT coverage artifacts
```

- Deployed execution: nightly job `e2e-caas-test` in
  `osac-build-and-publish.yaml`, periodic caller (8 h), or the unified
  prototype `e2e-full-regression-caller.yml` (every other day, 02:00 UTC).

## Appendix A: Minimal CaaS environment requirements

Condensed from the current nightly chain; full sources in §Sources. Items
marked **[shared]** are unified-environment responsibilities (epic OSAC-6112),
not CaaS-specific setup.

**Hub.** OpenShift SNO 4.22 `cluster-tool` flavor clone (~20 vCPU/64 GB;
netris-lab equivalent `hgx-00`), internet egress for image pulls,
`redhat-operators` CatalogSource healthy, OVN masquerade patch
`169.254.0.0/17`. **[shared]**

**HCP stack.** MCE (`stable-2.17`, `MultiClusterHub` available) with the
installer's digest-pinned `assisted-service` image overrides; Assisted
Service + InfraEnv/Agent CRDs; HyperShift for `HostedCluster`/`NodePool`;
`SingleReplica` availability policies (SNO-sized hub); MetalLB for the
kube-apiserver LB Service.

**DNS/external access.** Delegated zone (today
`ecoeng-osac-ci.devcluster.openshift.com` in Route53) with credentials
granted `route53:ChangeResourceRecordSets/ListHostedZones/GetChange`;
injected via `cluster-fulfillment-ig` ConfigMap/Secret
(`DNS_ZONE`, `EXTERNAL_ACCESS_BASE_DOMAIN`,
`EXTERNAL_ACCESS_SUPPORTED_BASE_DOMAINS`, `HOSTED_CLUSTER_BASE_DOMAIN`).

**Workers.** **[shared with BMaaS]** ≥3 virtual BMHs (libvirt + sushy-tools,
`provisioningNetwork: Disabled`, `watchAllNamespaces: true`) in
`host-inventory` labeled `osac.openshift.io/host-type=default`, UEFI
network-boot, fabric NIC distinct from BMC NIC; BMF operator metal3 backend
(or the BMaaS Netbox inventory per their OSAC-6116 answer — requires
fabric-interface MAC data either way). Serial-suite peak demand is 2; a
shared pool must sum both suites' concurrency.

**Images/versions/templates.** ClusterVersions 4.20.0 + 4.22.0 (default,
`quay.io/openshift-release-dev/ocp-release:4.22.0-multi`); RHCOS DiskImage
`rhcos-4-22` (`oci://quay.io/osac-project/rhcos:4.22.0`) via the VMaaS-owned
DiskImages API (`vmaas.enabled: true` stays on); cluster template
`ocp-ci-small`; `BareMetalInstanceType` `ci-worker-bm` with a
`role: fabric` network port; published ClusterCatalogItem authoring support;
pull secret (Vault) + per-run generated SSH key.

**AAP.** License; `clusterFulfillment` instance group with
`NETWORK_CLASS: ci`, `NETWORK_STEPS_COLLECTION: ci.steps`, SingleReplica
policies (keep `global.expertOverrides.aap: true` so `ci.steps` stays
authoritative, or consciously replace it in the unified env);
`networkFulfillment`; `storageFulfillment` when the storage controller runs;
project source pinned to the exact OSAC commit under test.

**Platform services. [shared]** Keycloak with `devFixtures` (JWT users
`tenant1_admin`/`tenant1_user`/`tenant2_user`/`tenant2_admin`;
`OSAC_CAAS_USE_JWT=true` default), bundled PostgreSQL + OpenBao,
cert-manager/trust-manager + `default-ca`, Kafka (`osac-kafka`) with
per-tenant topics, metering echo-adapter + Route (`METERING_ADAPTER_URL`),
tenants `shared` + `osac-e2e-ci`.

**Runner/test inputs.** Self-hosted `osac-ci` runner (GH environment
`e2e-test`) with cluster-tool, podman, oc, helm, yq, grpcurl, skopeo; Vault
approle secrets; test env `OSAC_NAMESPACE`, `OSAC_CLUSTER_TEMPLATE`,
`OSAC_PULL_SECRET_PATH`, `OSAC_SSH_PUBLIC_KEY_PATH`,
`OSAC_TEST_RELEASE_IMAGE`, `OSAC_RHCOS_BMI_IMAGE`,
`OSAC_FULFILLMENT_ADDRESS`/`_PRIVATE_`, `METERING_ADAPTER_URL`, hub
`KUBECONFIG` (read-only mount).

**Integration asks (per WG).** Networking: fabric NetworkClass supporting
`move_network_attachment` + MAC-based lease query; storage VIP routable from
tenant subnets. BMaaS: allocatable hosts with fabric-MAC data; sanitization.
Storage: tenant CSI on guests; consumable tier; guest LVMS prerequisites.
VMaaS: DiskImages API. Metering: healthy Kafka + echo adapter. Enclave/CI:
full-ci-based unified profile + overlays, runner capacity, secrets,
scheduling. Open decisions: fabric vs `ci.steps` as nightly default; Route53
vs DNS-API; scenario/marker placement; BMH pool sizing with BMaaS.

## Sources

- Mono-repo: `.github/workflows/nightly-build.yaml`,
  `.github/workflows/osac-build-and-publish.yaml`, `.github/CI.md`,
  `osac-installer/values/caas-ci/` + `values/full-ci/`,
  `osac-installer/scripts/test-mce-render.py`,
  `fulfillment-service/internal/servers/*clusters*`,
  `fulfillment-service/it/it_*cluster*`,
  `osac-operator/internal/controller/clusterorder_*`,
  `osac-operator/internal/controller/baremetalworker/`,
  `osac-operator/test/integration/`, `osac-aap/tests/unit/`,
  `osac-aap/tests/integration/targets/`,
  `osac-aap/collections/ansible_collections/{osac/service/roles,ci/steps,osac/templates/roles}`,
  `tests/unit/`, `tests/e2e/{conftest.py,caas/,references/,storage/}`,
  `tests/e2e/core/{osac_cli.py,caas_versions.py}`,
  `docs/INTEGRATION-TESTING.md`,
  `docs/agent-context/{osac-dimensions,review-patterns,networking-decisions}.md`.
- `osac-test-infra` @ `3b45744`: `e2e-caas-full-install.yml` (+caller),
  `e2e-caas-netris-full-install.yml`, `e2e-caas-agentless-net-full-install.yml`,
  `e2e-full-regression.yml` + `.github/overlays/full-ci-*.yaml`,
  `.github/scripts/setup-virtual-bmh.sh`, `infra/netris/README.md`.
- `enhancement-proposals` @ `ca346e0`: OSAC-1436, OSAC-2135, OSAC-1332,
  OSAC-1415, OSAC-1604, OSAC-4090, OSAC-41 designs/PRDs.
- Example format: "OSAC UI Tests" Confluence page (external share link
  provided by the user 2026-10-20).
