# OSAC-6348: Reject shared-tenant Clusters before provisioning — Implementation Plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Reject unsupported Cluster creation in the `shared` tenant before any
Cluster is persisted or provisioning starts, instead of stalling on worker creation.

**Architecture:** Remove the Cluster server's temporary shared-tenant opt-in and
reuse the generic server's existing tenancy validation. Keep CaaS worker BMIs in
their parent Cluster's tenant/project; do not move workers into `system` or relax
BMI tenancy, ownership, or database checks.

**Tech Stack:** Go, gRPC, Ginkgo/Gomega, PostgreSQL, pytest, Kubernetes/Kind.

**Issue:** [OSAC-6348](https://redhat.atlassian.net/browse/OSAC-6348).
**Status:** Proposed implementation, not implemented or tested. The user asked to
save this plan after reviewing the proposed approach.

---

## Investigation and decision

The reported flow creates a Cluster/ClusterOrder in `shared`, but the worker
Create RPC returns `PermissionDenied: objects cannot be placed in the 'shared'
tenant`. The Cluster control plane can become available while worker provisioning
remains stalled with `bmiCreateState: Attempted` and no BMI ID.

Source evidence checked on 2026-10-20:

- [PrivateClustersServer builder](../../fulfillment-service/internal/servers/private_clusters_server.go)
  explicitly calls `AddAllowedTenants(auth.SharedTenant)` near line 255. The
  adjacent TODO describes an old CaaS test/storage teardown workaround.
- [GenericServer](../../fulfillment-service/internal/servers/generic_server.go)
  checks allowed tenants in `prepareForCreate`, before candidate preparation or
  database creation. Its default policy rejects both `shared` and `system`.
  Update checks the restriction when the assigned tenant changes, allowing
  existing reserved-tenant objects to be updated in place.
- [PrivateBareMetalInstancesServer](../../fulfillment-service/internal/servers/private_baremetal_instances_server.go)
  does not opt into reserved tenants. Its tests explicitly reject `system` BMIs.
- [Worker ownership](../../osac-operator/internal/controller/baremetalworker/ownership.go)
  validates the ClusterOrder against the authoritative Fulfillment Cluster.
  [BMI creation](../../osac-operator/internal/controller/baremetalworker/bmi.go)
  assigns that Cluster's tenant/project and sets `status.cluster`/`status.node_set`.
- [Migration 125](../../fulfillment-service/internal/database/migrations/125_add_owner_reference_checks.up.sql)
  requires a worker's `status.cluster` target to be live and in the same tenant
  and project. Never edit this applied migration to bypass that invariant.
- The current [OSAC-2135 design, Worker Tenancy and Ownership](https://github.com/osac-project/enhancement-proposals/blob/main/enhancements/OSAC-2135-caas-bare-metal-worker-provisioning/design.md#worker-tenancy-and-ownership)
  explicitly places worker BMIs in the Cluster's tenant. Its visibility
  requirement was revised on 2026-10-14: tenants intentionally see their workers.
- [AUTH.md](../../fulfillment-service/docs/AUTH.md#additional-tenancy-concepts)
  documents Clusters as tenant-scoped resources, not shared/system resources.

**Decision:** Choose the ticket's explicitly permitted early-rejection outcome.
The Jira triage recommendation to place workers in `system` is stale and conflicts
with the current accepted design and the database contract. Allowing `shared`
BMIs would expose tenant-scoped infrastructure globally and is not the fix.

This rejects shared-tenant Clusters generally, not only one worker instance type.
Shared templates, catalog items, instance types, and versions remain supported;
selecting a shared catalog item does not make its resulting Cluster shared.

## Required context before implementation

Read root and applicable component `AGENTS.md`, plus:

- [Feature dimensions](../agent-context/osac-dimensions.md) and
  [review patterns](../agent-context/review-patterns.md).
- [Fulfillment request-path tracing](../../fulfillment-service/docs/REQUEST_PATH_TRACING.md),
  [AUTH.md](../../fulfillment-service/docs/AUTH.md), and the current server code.
- [Integration testing](../INTEGRATION-TESTING.md), particularly planning evidence,
  Fulfillment, and CaaS coverage boundaries.
- [Networking decisions](../agent-context/networking-decisions.md) if evaluating
  tenancy effects on attachment resolution. Accepted CaaS/BMaaS networking uses
  the Cluster's tenant network; no attachment, MAC, or IP changes belong here.

Trace the existing request path: CLI/REST -> authenticated public Clusters server
-> private Clusters server -> generic assigned-tenant validation -> database.
The private and public paths must enforce the same outcome. There are no new
headers, request fields, or gateway propagation requirements.

## Task 1: Add failing regression coverage

**Files:**

- Modify `fulfillment-service/internal/servers/private_clusters_server_test.go`.
- Modify `fulfillment-service/internal/servers/clusters_server_test.go`.

Reuse existing Ginkgo fixtures, including `newCaaSNodeSetCreateRequest` where
applicable. Do not create another harness or hand-edit generated mocks.

1. Add the cases in the coverage matrix below. Use otherwise valid requests so
   unrelated image, template, or networking errors do not mask tenancy behavior.
2. Explicitly model an administrative default of `shared` for the omitted-tenant
   case; the ordinary server suite defaults to `test-tenant`, not `shared`.
3. Assert `PermissionDenied`, nil response, the reserved-tenant error, and no
   persisted Cluster with the test's unique name. A rejected create must not
   allocate related resources. Verify the caller's request is not mutated.
4. Run `ginkgo run --timeout 10m internal/servers` from `fulfillment-service/`.
   Confirm the new shared-tenant rejection cases fail for the expected reason
   before changing the implementation. The suite starts real PostgreSQL and
   requires a working container runtime; tenancy/attribution are mocked.

## Task 2: Remove the exception

**File:** `fulfillment-service/internal/servers/private_clusters_server.go`.

Remove the obsolete TODO/workaround comment and this builder call:

```go
AddAllowedTenants(auth.SharedTenant).
```

Keep all other builder behavior. Do not add a second validation mechanism or
change the generic server, BMI server, worker controller, protos, or migrations.
The existing error is sufficient:

```text
objects cannot be placed in the 'shared' tenant
```

Run the server suite again and verify all regression cases pass. If fixtures
fail because they implicitly relied on shared Cluster creation, set a real
Cluster tenant explicitly; do not change shared catalog resource placement.

## Task 3: Verify the deployed API and existing lifecycle

**Files:**

- Extend `fulfillment-service/it/it_public_clusters_test.go`.
- Audit affected Cluster fixtures in `fulfillment-service/it/`.
- Inspect `tests/e2e/caas/conftest.py`; modify only if necessary.

Add the deployed rejection case using the existing admin connection, so normal
user tenant-assignment refusal cannot accidentally satisfy it. Assert that an
explicit shared-tenant Create fails and a subsequent admin List finds no Cluster.
The existing positive tenant-owned Cluster cases must still pass.

CaaS already defaults `OSAC_CAAS_USE_JWT` to `true` and uses `tenant1_admin`.
Do not use the service-account fallback to obtain a shared-tenant Cluster.
Inspect the stale storage workaround comments and any active callers before
removing the fallback or comments; do not rewrite unrelated authentication.

Run the existing tenant-owned create/worker/natural-delete journey. Its worker
BMIs must remain tenant-visible with the correct ClusterOrder provenance and
must be removed before parent deletion finishes. Do not add a shared-worker
success E2E: shared Cluster creation is intentionally rejected.

## Coverage matrix

Case IDs below are proposed identifiers, not claims of existing/passing tests.
Commands are in the validation section.

| Cases | Behavior and interface | Tier / owner | Suite to extend and actual boundary |
| --- | --- | --- | --- |
| T01 | Explicit `shared` Cluster, direct template and catalog-item creation; rejection and no persistence | Component integration / Fulfillment [DEV] | `internal/servers/private_clusters_server_test.go`; real handlers/PostgreSQL, mocked tenancy/attribution, no deployed operator/provider |
| T02 | Omitted tenant resolves to admin default `shared`; rejected before persistence | Component integration / Fulfillment [DEV] | Same server suite, explicitly configured tenancy double; no real identity-provider claim |
| T03 | Explicit normal tenant succeeds, including shared catalog selection | Component integration / Fulfillment [DEV] | Existing private/public server fixtures; real PostgreSQL, networking/catalog records are fixtures |
| T04 | Public wrapper preserves reserved-tenant refusal | Component integration / Fulfillment [DEV] | `internal/servers/clusters_server_test.go`; in-process public/private servers, real PostgreSQL, no transport/authentication boundary |
| T05 | Moving a Cluster into `shared` is rejected without changing the stored tenant | Component integration / Fulfillment [DEV] | Private server Update suite; real stored object and update-mask merge, mocked tenancy |
| T06 | Legacy shared Clusters can still be read, receive status feedback, and be deleted | Component integration / Fulfillment [DEV] | Existing server suite; seed legacy data through DAO rather than the now-forbidden Create API; no provider teardown claim |
| T07 | Authenticated deployed public Create rejects `shared`; no persisted result; ordinary tenant Create still works | Component integration / Fulfillment [DEV] | `it/it_public_clusters_test.go`; real deployed API, database, and test identities; no bare-metal allocation |
| T08 | Tenant-owned Cluster provisions workers in its tenant and completes natural teardown | E2E / CaaS [QE] | Existing `tests/e2e/caas/sanity/test_cluster_create.py::test_cluster_create`; deployed cross-component stack and configured virtual BMH/provider environment, no mocked completion |

No operator implementation or ownership behavior changes are planned, so no new
operator Envtest case is required. If implementation scope expands into the
worker controller, apply its touched-area map and extend the existing Unit and
shared Controller Envtest suites before considering the work complete.

## Validation commands and prerequisites

From `fulfillment-service/` (the server suite needs PostgreSQL container support):

```bash
ginkgo run --timeout 10m internal/servers
uv run dev.py lint
```

From repository root, after the documented disposable Kind setup (real
Fulfillment/database/identity services; not a deployed provider lifecycle):

```bash
make -C osac-installer test PLATFORM=kind PROFILE=dev NS=osac SUITE=fulfillment
```

From repository root, with a compatible source-pinned CaaS stack, hub access,
Keycloak tenant identity, catalog/image/network prerequisites, pull secret/SSH
key, available virtual BMHs, and healthy metering dependencies:

```bash
OSAC_CAAS_USE_JWT=true uv run pytest -n 0 \
  tests/e2e/caas/sanity/test_cluster_create.py::test_cluster_create
```

Run pre-commit on the actual changed paths, e.g.:

```bash
pre-commit run --files \
  fulfillment-service/internal/servers/private_clusters_server.go \
  fulfillment-service/internal/servers/private_clusters_server_test.go \
  fulfillment-service/internal/servers/clusters_server_test.go \
  fulfillment-service/it/it_public_clusters_test.go
```

If Python fixtures change, also run the repository Ruff checks and collect all
affected suites per `tests/e2e/AGENTS.md`. Update the touched-area/coverage docs
if the test boundary or documented suite changes. Pre-commit is not a complete
secret scan; its gitleaks hook examines staged changes.

## Compatibility, unresolved execution, and scope limits

- This does not automatically repair already-stalled shared Clusters. Inspect
  and clean them up using supported lifecycle operations, then recreate them in
  a real tenant. Do not move live resources across tenants, strip finalizers,
  modify the database, or allocate replacement hardware as an automatic repair.
- The old storage workaround refers to [OSAC-1060](https://redhat.atlassian.net/browse/OSAC-1060),
  which was Closed when checked. Do not assume its status proves tenant-owned
  CaaS teardown works in the target environment. If that still fails, record the
  actual failure and an explicit owner/ticket; a new blocker has not been filed.
- Qualifying deployed worker/provider coverage gaps are documented under
  [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843). Server doubles or a
  Fulfillment-only Kind pass are not evidence of real worker provisioning.
- T01–T07 have identified existing execution paths; T08 has an existing journey
  but requires a configured deployed environment. No tests were run during the
  investigation, and no deployment readiness is claimed.
- No new API/proto fields, schema changes, tenant-visibility redesign, installer
  settings, new test infrastructure, or unrelated storage fixes are in scope.

## Completion checklist

- [ ] Revalidate the current upstream code/design and branch base.
- [ ] Demonstrate failing T01/T02 before the code change.
- [ ] Remove only the Cluster shared-tenant exception and obsolete comment.
- [ ] Pass applicable server, deployed API, lint, and pre-commit checks.
- [ ] Run T08 or report the missing environment/owner and pending execution.
- [ ] Document existing-resource handling and any remaining coverage blockers.
- [ ] Keep unrelated changes and session-specific handoff files out of commits.
- [ ] If committing, follow root DCO, actual-tool attribution, issue-prefix,
      80-column commit-message, and contributor-fork-only push rules.
