# OSAC operator

Kubernetes controllers for OSAC resources, provisioning through AAP, feedback
to the fulfillment service, and the KubeVirt console proxy.

This component is part of the OSAC monorepo, not an isolated project. Its APIs,
generated artifacts, deployment configuration, and runtime behavior may affect
other components. Apply the repository-wide rules in
[`../AGENTS.md`](../AGENTS.md), consider downstream consumers before changing
behavior, and follow the instructions for every affected component.

## Required context

Before changing this component, identify the documents relevant to the change
below, then read and follow them. These documents are authoritative for their
respective areas.

- Component setup and architecture: [`README.md`](README.md)
- Cross-component contracts: [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) and [`../docs/CONVENTIONS.md`](../docs/CONVENTIONS.md)
- Controller-specific examples: neighboring files in `internal/controller/`
- API consumer changes: [`../fulfillment-service/AGENTS.md`](../fulfillment-service/AGENTS.md)

## Invariants

- Resource controllers generally own provisioning, finalizers, and lifecycle status; feedback controllers synchronize state with the fulfillment service.
- Every resource controller except `tenant_controller.go` must skip reconciliation when `osac.openshift.io/management-state` is `Unmanaged`.
- `StorageReconciler` is an intentional exception to the dual-controller pattern: it reconciles Tenant storage and does not own a separate CRD.
- Preserve tenant namespace isolation and established predicates when creating or watching resources.
- When changing shared controller behavior, inspect every controller using the same lifecycle.
- `pkg/provisioning`, `pkg/aap`, and `pkg/dispatcher` have external consumers, including the bare-metal fulfillment operator; interface changes are cross-component changes.
- When debugging operators, check for stale `vendor/` dependencies and cached images before rebuilding.
- The fulfillment proto types are the shared top-level `proto/` module, imported as `github.com/osac-project/osac/proto/gen/...`. This component no longer generates its own copy.
- Never put credentials in logs, samples, or manifests.

## Generated files

- After changing `api/v1alpha1/*_types.go`, run `make manifests generate`.
- Then run `make helm-crds` to synchronize `config/crd/` with `charts/operator-crds/`; use `make check-helm-crds` to verify the result.
- Fulfillment proto changes are regenerated once in the shared module: `make -C ../proto generate` (see `proto/AGENTS.md`). Do not regenerate anything proto-related from `osac-operator/`.
- Never hand-edit `config/crd/`, `zz_generated.deepcopy.go`, or `go.sum`; run `go mod tidy` for module changes.

## Integration Testing

See [suite boundaries and coverage gaps](../docs/INTEGRATION-TESTING.md#osac-operator).

| Touched area | Required validation | Command / follow-up |
|---|---|---|
| Pure helpers, validation, or state calculations | Unit | `make test` |
| Controller reconciliation, finalizers, status, or CRD interactions | Envtest | `make test` |
| Controller deployment, watches (including optional TopoLVM watch), RBAC, console proxy, networking, or Helm wiring | Component integration | Deploy current image/manifests, then `make integration-tests`; [installer alternative](../docs/INTEGRATION-TESTING.md#osac-operator) |
| AAP, dispatcher, provisioning-provider, KubeVirt, or fulfillment boundary | Qualifying Contract or E2E | Use a boundary-specific suite; follow [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) when coverage is missing |
| Generated CRDs or manifests | Envtest plus applicable Kind suite | `make manifests generate helm-crds check-helm-crds`, then the required test command |

Envtest runs via `make test`; Kind tests require the current operator deployment.
The LVMS envtest lifecycle cases exercise generated LogicalVolume names,
persisted UID-safe resumes, terminating-resource replacement, and deletion
through the public Volume reconciler for RWO and RWOP. They use a minimal
TopoLVM CRD and simulated status; they also inject stale parent snapshots to
verify authoritative reads preserve the recorded LogicalVolume identity.
Status-conflict cases verify newer vendor context, deletion and replacement
UIDs are not overwritten. These tests do not provision or mount real devices.
The bare-metal worker unit tests cover bounded opaque names, authoritative
status reservations from stale snapshots, retry backoff, and per-NodeSet
capacity selection, including distinct NodeSets sharing a hardware profile. The acceptance envtest suite covers persisted BMI name/ID
references, interrupted creation, existing-worker recovery, independent request
scaling/reordering, recovery of unrecorded BMI IDs before finalization, and
retention of workers/finalizers when the recorded BMI name is missing.
Kubernetes/etcd and the generated CRDs are real; fulfillment and Agents are
simulated, so these cases do not prove deployed BMaaS or hardware behavior.
Agent reconciliation unit tests cover phase convergence/protected workers,
registration timeout, binding conflicts and isolation, interrupted-status recovery,
and transition event/metric counts. The acceptance envtest suite drives public
`Reconcile` manually to verify persisted Ready demotion after Agent disappearance
or Installed-condition changes, bound-Agent status repair without another BMI or
Agent patch, protected Failed/Unbinding/Deleting entries, and ambiguous-match
refusal. These cases do not test manager watch delivery or deployed Assisted Service.
Unified worker convergence is covered by `worker_reconcile_test.go`,
`worker_capacity_test.go`, `worker_teardown_test.go`, `worker_projection_test.go`,
`worker_observation_test.go`, and the BMI identity suites. Each invocation takes
one explicit `*workerObservation` (indexed BMIs, one Agent list, memoized
recorded-ID fallback Gets) and projects worker identity/Agent phase exactly once;
`projected`/`agentsInvalidated` continuation caches, post-mutation
`recordBMI`/`invalidateBMI` index repair, and variadic optional
observation/resolver parameters are gone. Unit fault injection covers the
invocation read budget, memoized success/NotFound/error fallback outcomes,
unknown versus absent references, one-shot optimistic status conflicts,
concurrent reference/spec/tenant/UID interruption, capacity interruption, one
fresh ownership/existence Get per BMI delete attempt, independent per-order
observation state with a configured MAC override, and finalizer retention for
concurrently appended workers.
`acceptance/worker_reconcile_test.go` drives public `Reconcile`
through real status persistence and optimistic-lock conflicts: successful-create
ID write interruption, List omission/NotFound/outages, repair before prerequisite
gates, stale-failure write rejection before InfraEnv UID recording, conflict
interruption followed by fresh aggregate convergence, and identity-only finalization recovery. Assertions follow
explicit reconciliation calls, not fallback polling. R05-E1/E2/E3 additionally
drive the public reconciler through a lost worker-status write after a successful
Agent patch (recovering Binding/Ready from the Agent without another patch or
Create), demotion and protected history while prerequisites are blocked, and no
pre-bind Ready decision from the old snapshot. R01 Unit cases and the
R01-E1/E2 acceptance specs and R02-E1/E2 conflict-restart coverage additionally assert separate finalizer/repair/reservation
and single-Create checkpoints, a single rejected optimistic Agent binding patch with no takeover,
stable names across stale parent snapshots,
independent NodeSets sharing one instance type, waiting-retry selection, a
single failed-worker retry Delete (including errors), and no requeue from a
no-op retention ordering. Stale-ignition repair persists without advancing the
InfraEnv UID or deleting the newly failed worker in the same invocation. Legacy fixtures drive finite
multi-reconcile sequences, assert durable progress at each allocation checkpoint,
and propagate errors/backoff rather than polling through them. BMI creates
persist their returned ID before the invocation ends; subsequent invocations
observe all persisted references anew. R01-E2 also injects a successful Create
with a lost transport acknowledgement, restarts the reconciler, hides the BMI
from observation and an AlreadyExists re-list, then recovers the same reserved
name/ID without another successful allocation. Unsafe foreign, ambiguous and
deleting recovery candidates are rejected without changing reservations;
recorded deleting IDs and finalization recovery remain observable. The fake
models tenant/project/name uniqueness independently of ID, not the real DB.
The connected R01-C1 case in `test/integration/caas/worker_test.go` is implemented
and compile-checked, but live execution is blocked until the marked sim backend
and its checkout-specific connection configuration are available. It delegates
Create to the real API before losing one acknowledgement, restarts, forces a
real AlreadyExists re-list, and counts persisted owned incarnations per reserved
name. See the connected suite README for its execution prerequisites and limits.
The Unit/Envtest cases above are [DEV] work, not fulfillment wire,
manager-watch, or deployed-provider coverage; those
remaining boundaries belong to
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).
R04 independent-convergence coverage keeps creation inputs lazy while
prerequisite-free work proceeds. Unit cases (`worker_reconcile_test.go`,
`worker_capacity_test.go`, `retry_test.go`) assert that retirement and BMI
cleanup run with an absent pull secret, a deleted InfraEnv and an unresolvable
disk image while fetching no discovery ignition and creating nothing; that a
pending failed-worker cleanup does not stop another worker's Agent binding; that
the aggregate worker summary is persisted before the create gate rejects a
blocked image lookup; that the recheck deadline prefers the shortest positive
wait among Provisioning/WaitingForAgent/Binding/cleanup states and holds no timer
for a stable Ready order; and that a Ready worker keeps its retry history when
another worker is delayed. R04-E1–E3 in `acceptance/worker_reconcile_test.go`
drive the same boundaries through public `Reconcile` with real status
persistence and simulated fulfillment/ignition outcomes, within the shared
`16 + 8*N` explicit-call bound. The existing stale-ignition Envtest suite adds
`R04-E2`, which persists the WaitingForAgent failure classification before
recording the recreated InfraEnv UID even though the create input cannot resolve.
The Envtest traces invoke `Reconcile` directly, so they do not establish manager
watch delivery or deployed Assisted Service behavior; those remain with
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).
Agent association is one scoped policy shared by phase projection, late binding
and cleanup in `correlation.go`: `agentAssociation` resolves established,
absent, ambiguous or invalid, and `agentBindingConflict` applies the same
namespace/cluster/binding checks to observation, mutation and cleanup. Every
observation stages the union of the InfraEnv registration and cluster-order
selectors, deduplicated by Kubernetes UID, so a mixed population is never
truncated to whichever selector matched first and a failed selector List makes
the observation unknown rather than partial absence evidence. Readiness and bound
deletion use only a unique compatible established worker-name binding; initial
discovery matches an unbound compatible Agent to an eligible waiting worker by
inventory NIC MACs only when the match is unique in both directions, and an
already-labelled or bound Agent is never a MAC fallback. An incompatible
candidate is returned as an observable error; ambiguity or unreadable inventory
never authorizes an Agent patch or deletion. `R06-U1–U4` Unit cases in
`correlation_test.go`, `agent_reconcile_test.go` and `worker_projection_test.go`
characterize the selector union, duplicate-label and bidirectional MAC
ambiguity, incompatible/foreign bindings and malformed inventory; `R06-E1–E4`
Envtest traces in `acceptance/reconciler_test.go` and
`acceptance/worker_reconcile_test.go` drive public `Reconcile` through real
UIDs/CRDs for mixed selectors and shared-object deduplication, ambiguity refusal,
same-name recreation under stale evidence, and binding reconstruction after a
reconciler restart. Real Assisted Service selector/UID/binding behavior
(`R06-C1`) and the deployed CaaS create/scale/delete journey (`R06-Q1`) remain
owned by OSAC-4843/[QE]; no identity or API contract was expanded.
R03 cleanup Unit tests in `cleanup_test.go`, `retry_test.go` and
`worker_teardown_test.go` cover delayed/lost Delete acknowledgements, retention
until fresh Get NotFound, once-only retry scheduling, retirement before cleanup,
ID-less name recovery, unknown/foreign references, authoritative Agent reads
instead of cached omission, ambiguous/malformed/bound Agents, and UID-conditioned
Agent deletion. The Kubernetes fake does not enforce Delete UID preconditions;
the unit race fixture checks the supplied options and simulates API rejection.
The shared fulfillment fake supports explicit pending-deletion completion and
uses distinct generated incarnation IDs. Existing acceptance lifecycle specs
use separate retirement, Agent removal, BMI deletion and absence checkpoints.
Dedicated R03-E1–E5 public Envtest traces in `acceptance/worker_reconcile_test.go`
execute seven specs covering delayed retry/retirement, API outages, interrupted
provisioning recovery without Create, authoritative Agent reads despite cached
omission, real-apiserver UID-precondition rejection and bound-worker blocking
with replacement-readiness isolation. Explicit calls stay within `16 + 8*N`;
retry deadlines and test-owned Agent finalizers advance only in the fixture.
Sim-backed R03-C1 is explicitly skipped at the user's request because the sim
is slated for removal; its added fixture/entry has been removed. It is not a
local R03 completion gate, and no real fulfillment/Postgres/provider cleanup
pass is claimed. The pre-existing connected suite and R01-C1 remain unchanged.
No replacement deployed integration harness is required for this cleanup-policy
refactor; Unit/Envtest cover its local invariants, not the real-service boundary.
Bound-worker remediation deliberately waits for its owner; no Machine/CAP-Agent
hooks or NodePool replicas are manipulated to force cleanup. Production deletion
still requires an approved archived-Cluster ownership fix (dedicated owner/ticket
unresolved); provider/drain/hardware journeys remain [QE] work under
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).
R07 collapses the InfraEnvReady-gated lookup into one resource-driven
observation. `observeInfraEnvEvidence` performs the invocation's single InfraEnv
Get through the cache, confirms a cached omission with an uncached read before
treating it as absence, creates the object only on authoritative absence, and
validates ownership (namespace, controller kind and name, plus the recorded order
UID when set) before consuming any UID or boot artifact. `InfraEnvReady` is
output evidence rather than a control gate: a missing or replaced artifact URL
clears a stale Ready claim, and only a fetched, JSON-valid discovery ignition
reports Ready. The recorded UID stays a durable checkpoint until stale-worker
failures are persisted; the classification write and the UID recording are
separate invocations, and a failed classification write or lost UID patch
re-emits no failure accounting on retry. Foreign same-name objects are errors,
not recreate permission. `R07-U1–U7` Unit cases in `worker_reconcile_test.go`
characterize this with fake InfraEnv/HTTP outcomes and fault-injected status and
metadata patches; `R07-E1–E2` Envtest traces in `acceptance/reconciler_test.go`
and `acceptance/worker_reconcile_test.go` drive public `Reconcile` through real
owner UIDs, metadata and status. These cases do not prove real Assisted Service
artifact behavior (`R07-C1`, owned by
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843)).
R08 removes the adapter-wide consecutive-failure counter from `fulfillment.go`.
The adapter now classifies each call from its own evidence: `codes.Unavailable`,
and `codes.DeadlineExceeded` while the parent context is still active, wrap the
original gRPC error with `ErrFulfillmentServiceUnavailable` so both `errors.Is`
and `status.Code` keep working, while semantic codes and a canceled or expired
parent context pass through unchanged. No state is shared between calls,
operations or orders, so a success on one order cannot suppress or reset another
order's evidence. Public `Reconcile` is the single orchestration boundary: it
persists the order-scoped `FulfillmentServiceUnavailable` condition with the one
bounded unavailable delay, surfaces a condition-write failure instead of
pretending it was recorded, and leaves every non-availability error to its caller
policy. A transport failure in `authoritativeWorkerTenant` fails closed as
unavailable rather than emitting a `WorkerOwnershipMismatch` event, and the
condition clears only after an explicit later invocation's required reads and
actions succeed. `R08-U1–U3` Unit cases in `fulfillment_test.go` and
`fulfillment_error_test.go` characterize the per-call policy, original-code
preservation, wrapping, parent cancellation and cross-call independence;
`R08-E1` Envtest in `acceptance/worker_reconcile_test.go` drives two orders
through real status persistence for an authoritative NotFound and a transport
outage with independent conditions and explicit recovery. These cases inject
simulated gRPC outcomes; real backend outages and authorization visibility
(`R08-C1`) remain with
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).
R09 adds one durable attempt clock per worker. `WorkerStatus.AttemptStartedAt` is
persisted with the reservation, and for a legacy ID-less attempt or a due retry
immediately before `Create`, then never refreshed by an error, Get or
re-observation. `checkAgentRegistrationTimeout` measures
`AttemptStartedAt + agentRegistrationTimeout` against a caller-captured `now`, so
a worker added to an old order and a retry attempt are no longer aged by the
parent ClusterOrder or a stale `LastFailureTime`. Confirmed old-attempt cleanup
clears the origin with the old ID and `ReadySince`; the retry checkpoint keeps its
own `NextRetryTime`; and the replacement attempt persists a fresh origin before
its Create. A pre-existing worker is migrated once: the backing BMI's creation
timestamp when usable, otherwise a single observation-time origin with a
compatibility diagnostic. `ReadySince` is now a continuous interval: entering
Ready starts it, every demotion, failure or cleanup transition clears it, and the
healthy-history reset only fires after `MinHealthyDuration` of uninterrupted
readiness, with `workerRecheckDeadline` scheduling that deadline for a quiet
Ready worker. `R09-U1–U6` Unit cases in `agent_reconcile_test.go`,
`retry_test.go`, `worker_projection_test.go` and `worker_capacity_test.go` use
fixed clocks for the origin, lost-acknowledgement recovery, one-time backfill,
continuous interval and exact/just-before/just-after boundaries; `R09-E1–E4`
Envtest traces in the acceptance suites drive public `Reconcile` through real CRD
status persistence for the timeout origin, a lost Create acknowledgement plus
restart, one-time legacy backfill and Ready demotion/re-entry. Real provider
timeout/health behavior (`R09-C1`) and the deployed scale/retry journey remain
with
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) and [QE]. An older
independently deployed controller that ignores the optional status field keeps
the old parent-age timeout behavior; this is not a guaranteed safe downgrade.
The Kind suite's LVMS-disabled case verifies the Volume controller remains
ready without the TopoLVM `LogicalVolume` CRD; it does not exercise LVMS
provisioning or the CSI data path.

## Validation

From `osac-operator/`:

```bash
make fmt
make lint
make test
make helm-lint
make check-helm-crds
make integration-tests       # Requires a pre-existing Kind cluster
```

`make build` also runs the unit-test path. The console proxy integration tests
are under `test/integration/`; E2E suites are under [`../tests/e2e/`](../tests/e2e/).
