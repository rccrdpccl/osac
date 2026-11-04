# Full E2E requirements — dependencies needed (CaaS)

**Ticket:** [OSAC-6117](https://redhat.atlassian.net/browse/OSAC-6117) /
epic [OSAC-6112](https://redhat.atlassian.net/browse/OSAC-6112).
**Status:** Draft for review, uncommitted. Consolidated on 2026-10-20 from
the `osac` mono-repo (baseline `2a0d95f8`), `osac-test-infra` (`3b45744`),
and `enhancement-proposals` (`ca346e0`). Companion documents:
[quality-report.md](quality-report.md) (current testing status) and
[2026-10-20-osac-6117-caas-unified-nightly-e2e-requirements.md](2026-10-20-osac-6117-caas-unified-nightly-e2e-requirements.md)
(scoping, coverage backlog, open decisions).

## Dependency principle

This document states only what the CaaS E2E **directly** requires. Sibling
services are stated as *given capabilities* together with the contract CaaS
actually consumes; whatever they need on top of that — databases, identity
providers, inventory backends, fabric gear, emulators — is owned by those
services' own requirement documents (the OSAC-6113–6119 siblings) and is
deliberately not repeated here. Everything CaaS itself installs, configures,
or authors is listed under CaaS-owned requirements. Each entry states **why**
it is needed — what the E2E could not prove without it.

Consumed today by the nightly chain (`nightly-build.yaml` 03:00 UTC →
`osac-build-and-publish.yaml` job `e2e-caas-test` → test-infra
`e2e-caas-full-install.yml`) and its periodic caller (every 8 h); the
fabric-connected variants add the Networking fabric contract below.

## Given services and their contracts

| Service | Why CaaS E2E needs it | Contract relied on | Owner |
|---|---|---|---|
| OpenShift hub cluster | Everything CaaS deploys lives here: the OSAC operator and its CRs (ClusterOrder, Tenant, networking), the hosted control planes of every guest cluster, and the kubeconfig the tests use to assert guest state. Without it there is nowhere to run the journey at all. | SNO 4.22-class cluster reachable by the runner, `redhat-operators` CatalogSource healthy, internet egress for image pulls, pull secret injectable at boot | [ci] Enclave |
| Fulfillment service | It is the tenant-facing API every scenario drives: create/list/scale/delete clusters, catalog browsing, tenancy. It persists state, enforces tenant isolation, and writes the ClusterOrder CR that triggers provisioning. Its JWT test users are how the suite authenticates as tenant identities. | Deployed and healthy; public and private gRPC endpoints reachable (`SERVING`); test identities (devFixtures JWT users); tenants `shared` and `osac-e2e-ci`; ClusterOrder lifecycle and status feedback | [fulfillment] |
| VMaaS | CaaS workers boot an OS image that CaaS registers through the VMaaS-owned DiskImages API — worker provisioning has nothing to install without it, and ClusterVersions cannot reference a `diskImage`. | DiskImages API enabled | [VMaaS] |
| Metering | The suite asserts cluster created/scale/deleted events — the deleted-event assertion doubles as the cross-WG signal that teardown genuinely completed. The echo adapter is the deterministic sink the tests query instead of a real billing provider. | Per-tenant event delivery working; test adapter endpoint exposed (`METERING_ADAPTER_URL`) | [Metering] |
| BMaaS | Every CaaS worker node is an on-demand BareMetalInstance: the operator creates BMIs through BMaaS's private API, and BMaaS owns the host lifecycle CaaS relies on — provisioning the RHCOS image, moving the fabric port onto the tenant network, rebooting, discovering the DHCP address, and sanitizing on release. Without allocatable worker capacity, clusters never get nodes. | ≥3 concurrent hosts (suite peak 2 + headroom; a shared pool sums both suites' concurrency) selectable through the published instance type; full worker BMI lifecycle; hosts carrying fabric-interface MAC data | [BMaaS] |
| Networking | Tenant clusters attach to tenant Subnets: workers must be moved onto the tenant network, receive addresses via DHCP, and (storage scenarios) reach the storage VIP. Without the fabric contract the cluster installs on the wrong network or cannot reach storage. | NetworkClass whose fabric manager supports `move_network_attachment` and MAC-based DHCP lease query; tenant Subnets with DHCP; storage VIP reachable from tenant subnets (target shape; the current `ci.steps` shape uses the CaaS DNS path below) | [Networking] |
| Storage | The storage scenarios prove the tenant-visible outcome of a cluster: PVCs provisioning on the guest through tenant CSI installed per cluster, gated by `ClusterStorageReady`. Without it the suite can only assert control-plane readiness, not that a cluster is usable for stateful work. | Tenant CSI + StorageClasses on guest clusters with `ClusterStorageReady` on the ClusterOrder; a consumable storage tier | [Storage] |
| AAP instance | It is the provisioning brain: the operator dispatches Ansible jobs that create the HostedCluster and NodePools, wait for Agents, write DNS records, and return the kubeconfig artifact. Without AAP, nothing between a ClusterOrder and a running cluster ever executes. | Deployed, licensed, reachable from the operator and from jobs; CaaS configures its own templates and instance groups on it | [ci] Enclave |

## CaaS-owned requirements

### Hub preparation

- **OVN masquerade patch** (`169.254.0.0/17`) — hosted-cluster networking
  overlaps the default OVN masquerade range; without the patch the guest
  API and ingress paths break. The CaaS job applies it after clone boot.

### Hosted-control-plane stack

- **MCE** (`stable-2.17`, `MultiClusterHub` available, digest-pinned
  `assisted-service` image-override bridge — see
  [osac-infra values](../../osac-installer/charts/osac-infra/values.yaml))
  — provides the machinery that makes a cluster a *hosted* cluster:
  HyperShift (`HostedCluster`/`NodePool`) for the control plane and Assisted
  Service (`InfraEnv`/`Agent`) that boots and installs workers. The pinned
  bridge avoids a known Assisted discovery-artifact bug.
- **MetalLB on the hub** — the hosted cluster's `kube-apiserver` Service is
  type LoadBalancer; without a VIP the guest API has no address and the
  `api.<cluster>` records have nothing to point at.
- **`SingleReplica` availability policies** — an SNO-sized hub cannot run
  HighlyAvailable hosted control planes; the policies keep the stack
  schedulable.

### Catalog content (authored/registered by CaaS)

- **ClusterVersions** `4.20.0` and `4.22.0` (default, real release images)
  — the version catalog tenants select from; the positive-path E2E pins
  4.22.0 and its version must reference a `diskImage`.
- **RHCOS DiskImage** `rhcos-4-22` — the worker OS image BMaaS writes to
  disk; worker provisioning boots from it.
- **Cluster template** `ocp-ci-small` — defines the cluster parameters a
  ClusterOrder references; the catalog journey locks it.
- **BareMetalInstanceType** `ci-worker-bm` — maps node-set requests to
  allocatable hosts and declares the `role: fabric` port that the port move
  targets; its `host_label_selector` must match the labels BMaaS publishes
  (the CaaS↔BMaaS host-selection contract).
- **ClusterCatalogItem authoring** — the sanity suite's primary journey is
  catalog-driven creation (an item locking version, node sets, and SSH
  key); this is the user-facing provisioning path under test.
- **Per-run SSH key** (`ed25519`) — the credential the tests inject for
  worker access; per-run so runs never share credentials.

### AAP configuration (on the given instance)

- **`clusterFulfillment` instance group** (`NETWORK_CLASS: ci`,
  `NETWORK_STEPS_COLLECTION: ci.steps`, `SingleReplica` policies) — the jobs
  read their network backend from these env settings; without
  `expertOverrides.aap: true` the derived steps overwrite `ci.steps` and the
  CI network path silently changes.
- **`networkFulfillment` / `storageFulfillment`** — the network and
  storage-scenario job pools.
- **Project source pinned to the exact OSAC commit under test** — AAP must
  execute the revision under test or the run validates the wrong code
  (compatibility gate, not best effort).
- **EE image** (`ghcr.io/osac-project/osac-aap:latest` or the PR-built
  override with `eeImagePull: missing` when node-local) — the container the
  jobs run in; it must carry the Ansible collections the playbooks use.
  The override gap is
  [OSAC-3545](https://redhat.atlassian.net/browse/OSAC-3545).

### External access (current shape)

- **Delegated DNS zone** (today `ecoeng-osac-ci.devcluster.openshift.com`
  in Route53, injected via the `cluster-fulfillment-ig` ConfigMap) — a
  guest cluster is unusable and untestable if `api.<cluster>` and
  `*.apps.<cluster>` do not resolve; the suite's guest-readiness and
  kubeconfig assertions depend on it.
- **AWS credentials** (`route53:ChangeResourceRecordSets/ListHostedZones/
  GetChange` on that zone, in the `cluster-fulfillment-ig` Secret) — what
  the CaaS external-access steps use to create those records.
- Target shape moves external access to Networking (ExternalIP/DNAT per
  OSAC-1436); until then this stays CaaS-side.

## Secrets CaaS consumes

| Secret | Why |
|---|---|
| OpenShift pull secret | Authenticates the release-image and RHCOS pulls at cluster boot and in tests (`OSAC_PULL_SECRET_PATH`). |
| Route53 AWS credentials | The CaaS external-access steps create and wait on the guest DNS records with them. |

All other CI Vault secrets (AAP license, snapshot-registry auth, quay bot
account, Slack) are consumed by the environment provisioning, not by CaaS
steps or tests.

## Test-harness inputs

Environment variables consumed by `tests/e2e/` (CaaS-relevant subset;
defaults in parentheses) — the fixtures resolve every target and input from
these, so a missing value fails the suite at setup, not mid-journey:

```text
OSAC_NAMESPACE (osac-e2e-ci)          OSAC_CLUSTER_TEMPLATE (ocp-ci-small)
OSAC_PULL_SECRET_PATH                 OSAC_SSH_PUBLIC_KEY_PATH (~/.ssh/id_rsa.pub)
OSAC_TEST_RELEASE_IMAGE               OSAC_RHCOS_BMI_IMAGE
OSAC_CLUSTER_VERSION                  OSAC_CAAS_USE_JWT (true)
OSAC_FULFILLMENT_ADDRESS / _PRIVATE_  OSAC_CLI_PATH (osac)
OSAC_JWT_USERNAME (tenant1_admin)     OSAC_JWT_PASSWORD (foobar)
OSAC_KEYCLOAK_REALM (osac)            OSAC_KEYCLOAK_CLIENT_ID (osac-cli)
OSAC_KEYCLOAK_ADMIN_PASSWORD (admin)  OSAC_SERVICE_ACCOUNT (admin)
OSAC_STORAGE_TIER (local)             METERING_ADAPTER_URL
OSAC_BMH_NAMESPACE                    OSAC_FULFILLMENT_TRUST_E2E (trust assertions)
```

Plus a read-only hub `KUBECONFIG` mount (asserting CR and guest state). The
test image needs python 3.11, `jq`, openssh-clients, `oc`, `grpcurl`, and
`uv`; the `osac` CLI comes from the image build arg or the
fulfillment-service image under test.

## Setup order

1. Environment provides the hub cluster and the given services, each
   deployed per its own requirements (fulfillment, metering, BMaaS,
   networking, storage, AAP instance).
2. CaaS prepares the hub (OVN patch) and installs its hosted-control-plane
   stack (MCE, MetalLB).
3. CaaS registers catalog content (ClusterVersions, RHCOS DiskImage,
   template, instance type) and configures AAP instance groups and the
   external-access DNS path.
4. Health check the public gRPC endpoint (`grpcurl` Health/Check SERVING);
   expose the metering adapter route; generate the SSH key.
5. Run pytest in the test image; gather artifacts; teardown.

## Contract owners

| WG | Contract | Tracked by |
|---|---|---|
| Enclave/CI | Hub cluster, AAP instance, runner fleet, unified environment | [OSAC-6112](https://redhat.atlassian.net/browse/OSAC-6112) |
| Networking | Fabric NetworkClass (port move + MAC lease query), tenant Subnets, storage-VIP routability, target external access | [OSAC-6113](https://redhat.atlassian.net/browse/OSAC-6113) |
| BMaaS | Worker capacity and BMI lifecycle incl. port move and sanitization | [OSAC-6116](https://redhat.atlassian.net/browse/OSAC-6116) |
| Storage | Tenant CSI on guests, consumable tier, guest LVMS prerequisites | [OSAC-6114](https://redhat.atlassian.net/browse/OSAC-6114) |
| VMaaS | DiskImages API | [OSAC-6115](https://redhat.atlassian.net/browse/OSAC-6115) |
| Metering | Event delivery, test adapter | [OSAC-6118](https://redhat.atlassian.net/browse/OSAC-6118) |
