# Integration testing

Use the touched-area map in the affected component's `AGENTS.md` to select
validation. Read the corresponding section below for suite boundaries and gaps.
Commands and inline paths in each component section are relative to that
component's directory unless explicitly marked as repository-root commands.

## Shared tiers and boundaries

Use these tier names consistently:

- **Unit** — one package or function with external dependencies mocked.
- **Envtest** — a real Kubernetes API server and etcd process with the
  component's controllers or providers driven in-process; this is not a Kind
  integration test.
- **Component integration** — the component runs against a real Kind,
  testcontainer, broker, database, or protocol endpoint as documented by the
  component.
- **Contract** — a focused test of a boundary between two components or
  between a component and a provider.
- **E2E** — a cross-component user journey through the deployed OSAC stack.

Component-specific test labels in a matrix are subtiers of one of these canonical
tiers. The matrix must make that mapping explicit; a local label does not add
another tier or satisfy a Contract requirement by itself.

A lower tier does not satisfy a higher-tier requirement. Every component
integration section must disclose which dependencies are real and which are
faked or stubbed. If the required boundary has no qualifying suite, record
the gap and link the owning follow-up task; do not describe a lower-tier or
stub-only test as coverage of that boundary.

When a suite, command, or dependency boundary changes, update this guide and
its component's touched-area map in the same change. Link follow-up tickets
with their Jira URLs.

Build/package validation checks image assembly and dependencies. It is separate
from the test tiers and does not replace the applicable integration tests.

### Work ownership

Use the test tier to route implementation work. Unit, Envtest,
component-integration, and Contract tests for changed code belong to the owning
`[DEV]` story. Deployed cross-component user journeys belong to `[QE]` stories.
The reviewed test plan must classify each case by tier and owner; do not copy a
component-integration case into a QE story or treat an E2E case as covered by a
lower-tier test.

## Planning evidence

Design test plans must include a coverage matrix derived from the affected
components' touched-area maps and the actual test infrastructure. Use one row
per behavior and required boundary; a cross-component case may need several
rows. Include unit-only changes with their applicable tier rather than requiring
integration tests for every change.

Each row must identify:

- The owning component, touched behavior, and requirement/interface references.
- The required tier and the boundary whose behavior the test proves.
- The test-case IDs and existing suite/file to extend, or a clearly marked
  proposed location for new coverage.
- The execution command, working directory, and environment prerequisites.
- Which services, APIs, databases, providers, and controllers run for real,
  and which are simulated, mocked, or omitted.
- Any unavailable suite or unresolved infrastructure prerequisite, with the
  owning follow-up's Jira URL. If no owner or ticket exists, report that as
  unresolved; do not invent a ticket or claim the boundary is covered.

Verify existing suite paths and commands against the repository. Mark proposed
commands as proposed; where execution is not yet defined, record the gap
instead of supplying a plausible command. Name a specific tier and harness
rather than leaving alternatives such as "envtest or Kind" or "Cypress or
equivalent". Describe the running dependencies: a fixture-based test is not
evidence of a deployed boundary merely because it is labelled integration.

For timing or asynchronous behavior, identify the trigger, observable result,
measurement interval, and pass/fail bound. State how the test isolates the path
being measured from fallback polling, periodic resync, or mocked completion.
Flag contradictory or unspecified source behavior instead of inventing an
expected result.

Decomposition must carry the applicable matrix evidence into each
implementation or QE task's testing approach, including case IDs and
unresolved gaps. A task must remain actionable when ingested independently of
the feature test plan. Keep new suite/infrastructure work explicit in the
decomposition.

Before reporting a plan or decomposition ready, check every touched area against
its required boundary. Distinguish "has a planned test case" from "has an
identified execution path" and from "execution passed". Report missing or
wrong-tier coverage as unresolved even when all requirement and interface IDs
have mappings. A documented provider gap does not require real hardware for
an unrelated status-projection change; scope the test to the changed behavior.

### Evidence checks before completing a phase

Apply these checks during generation and self-review, then correct the artifacts
before reporting the phase complete:

| Claim | Evidence required |
|---|---|
| Integration coverage | Identify the exercised boundary and running dependencies. Lint, typechecking, collection, and schema-generation checks are static/build validation, not integration tests. |
| Envtest coverage | Envtest provides a Kubernetes API server and etcd. It does not provide fulfillment-service, PostgreSQL, or provider controllers; name and start those separately when the test requires them. |
| Cross-component coverage | A fake endpoint proves the caller's handling of that double, not the receiving service's persistence or reconciliation. Separate those cases and choose the harness for each. |
| Runnable test | Cite the repository file defining the command and the suite it runs. Replace vague instructions such as "run focused integration tests" with that command, or record execution as blocked pending an explicitly proposed harness. |
| Source contradiction or missing requirement | Cite the exact source file, section, and passage. Re-read the authoritative PRD/design before declaring a blocker; distinguish stale Jira text from a contradiction in those documents. |

For an existing approved design, retain its explicit assertions (including
negative, exhaustive, lifecycle, and timing assertions) or record why an
assertion cannot be planned. Do not replace them with a generic compatibility
check simply because it shares the same requirement or interface ID.

After decomposition, reconcile the test plan and tasks in both directions. If a
task restores a missing assertion or corrects a boundary, update the
corresponding test case and coverage row in the same phase. Do not report a
complete mapping while leaving the plan and tasks with different expected
behavior. Preserve earlier versions separately when conducting an evaluation.

Report behavioral coverage, execution readiness, and test execution results
separately. A case with a proposed harness or unresolved command is planned but
not execution-ready; static checks passing does not change that status.

## fulfillment-service

Touched-area requirements: [component guide](../fulfillment-service/AGENTS.md#integration-tests).

### Test tiers and commands

| Tier | Location / command | Exercises for real | Faked or omitted |
|---|---|---|---|
| Unit | `internal/`; `ginkgo run -r internal` | Fulfillment logic and adapters covered by package tests | External services are mocked where the package tests use mocks. |
| Component integration | `it/`; `make -C ../osac-installer test PLATFORM=kind PROFILE=dev NS=osac SUITE=fulfillment` | Deployed Fulfillment Service, its database, and the CLI built from this checkout. The NetworkClass manager-registration spec runs separately with the local OSAC Operator image deployed. | CaaS, VMaaS, BMaaS, and external provider workflows unless a specific test exercises them. |
| E2E | `../tests/e2e/` | Cross-component OSAC user journeys | Depends on the deployed test environment and its configured providers. |

### Coverage notes

- **CLI commands that only call Fulfillment APIs:** Cover them in `fulfillment-service/it/`.
- **Canonical networking Hub routing:** [`fulfillment-service/it/it_networking_hub_placement_test.go`](../fulfillment-service/it/it_networking_hub_placement_test.go) covers VirtualNetwork, Subnet, SecurityGroup, ExternalIPPool, ExternalIP, ExternalIPAttachment, and NATGateway CR placement on the NetworkClass canonical Hub and absence on a valid alternate Hub. It also verifies that SecurityGroup retains its stored Hub assignment and does not create a duplicate CR when the canonical Hub changes. The fixture uses distinct Hub entries and namespaces on the service Kind cluster; it tests Hub entry and namespace routing, not isolation across separate Kubernetes clusters. The unavailable-canonical/no-fallback case remains controller unit coverage because this deployed-service harness cannot isolate or reset the reconcilers' cached Hub resolution between cases.
- **NetworkClass manager registration and capability propagation:** `it_networkclass_manager_capabilities_test.go` creates the NetworkClass first, then adds fabric and Kubernetes manager registrations and verifies the deployed operator persists their capability intersection. The installer target runs this spec separately with the local operator image so the rest of the service-only suite remains isolated from operator reconciliation.
- **Provisioning journeys that cross into operators or providers:** Keep them in `tests/e2e/` and exercise those boundaries explicitly.
- **Catalog Items:** `it/` checks creation and update behavior, publication visibility, CLI creation, and the ClusterOrder release image written by Fulfillment. Catalog-backed provisioning journeys that exercise other components remain in the CaaS, VMaaS, BMaaS, and reference E2E suites.

## osac-operator

Touched-area requirements: [component guide](../osac-operator/AGENTS.md#integration-testing).

### Test tiers and commands

| Tier | Location / command | Exercises for real | Faked or omitted |
|---|---|---|---|
| Unit | Co-located `*_test.go`; `make test` | Controller helpers, validation, provisioning state logic | External APIs and providers are mocked. |
| Envtest | Controller tests under `internal/controller/*_envtest_test.go`; run by `make test` | Kubernetes API server, etcd, loaded CRDs, and in-process reconciliation | The controller is not deployed to Kind; provisioning uses controllable or noop providers. |
| Component integration | `test/integration/`; deploy the current operator into a Kind cluster, then run `make integration-tests` | Installed operator, Kubernetes API, CRDs, controller-manager, console proxy, networking behavior, and startup with the Volume controller enabled but no LVMS endpoint or TopoLVM CRD | AAP/provider provisioning and external infrastructure are not real in the current suite; the LVMS-disabled case does not exercise LogicalVolume provisioning. Some tests remove finalizers to bypass external-provider boundaries. |
| Component integration (CI) | `make -C osac-installer test PLATFORM=kind PROFILE=dev NS=osac SUITE=operator` (from repository root) | The thin Kind deployment used by the PR workflow | The same external-provider limitations as the local Kind suite. |
| Component integration / fulfillment-worker contract (opt-in) | `test/integration/caas/`; `make sim-up`, then `make test-integration-caas` | Dedicated marked Kind API, real fulfillment gRPC/Postgres/Keycloak/controller/hub, fulfillment-created ClusterOrder, host-built worker reconciler, real BMI persistence and duplicate-name check | Network readiness/NetworkClass prerequisite and discovery ignition simulated; no running operator/BMF, Agent binding, AAP, hardware, public auth, deployed metrics HTTP or guest install. See [usage](../osac-operator/test/integration/caas/README.md). |
| Contract | `test/contract/`; included by `make test` | Helm chart RBAC templates against the operator permission contract | No deployed operator or external provider is exercised. |
| E2E | `../tests/e2e/` | Cross-component fulfillment journeys | Depends on the deployed test environment and its configured providers. |

### Coverage notes

- **Pure helpers, validation, or state calculations:** Add error and edge-case coverage.
- **Controller reconciliation, finalizers, status, or CRD interactions:** The envtest suite must exercise the changed lifecycle through the public reconciler behavior.
- **LVMS Volume lifecycle:** `lvms_vendor_provisioner_envtest_test.go` exercises RWO/RWOP provisioning, API-generated LogicalVolume names, persisted name/UID resumes, replacement while an old CR is terminating, and deletion through the public Volume reconciler. Stale parent snapshots are injected to verify authoritative reads prevent another create after context persistence. `volume_controller_test.go` injects status conflicts to verify newer vendor context, deletion and replacement UIDs are preserved. Kubernetes and etcd are real; the cached snapshots and TopoLVM status are simulated, and the TopoLVM CRD is a minimal fixture. Default-device-class selection, LVMD provisioning, and CSI mounting remain real-provider/E2E coverage under [OSAC-3711](https://redhat.atlassian.net/browse/OSAC-3711).
- **Controller deployment, watches, RBAC, console proxy, networking, or Helm wiring:** Unit/envtest coverage alone does not prove deployed wiring.
- **AAP, dispatcher, provisioning-provider, KubeVirt, or fulfillment boundary:** A controllable provider in envtest is not coverage of the real provider boundary.
- **Generated CRDs or manifests:** Do not hand-edit generated output.
- **Bare-metal worker identity ([DEV], Unit/Envtest):** Unit tests in `internal/controller/baremetalworker/nodesets_test.go` verify bounded opaque names, reservation before external creation, stale-snapshot resumes, retry backoff, and logical NodeSet-based scale-down, including multiple NodeSets sharing a hardware profile. NodePool capacity/readiness and feedback unit tests verify independent counts and exact map-key attribution without instance-type fallback. The acceptance envtest suite verifies persisted BMI name/ID references, interrupted-create recovery, existing-worker reuse, independent request scaling/reordering, and recovery before cluster finalization. Missing-name references are rejected without guessing from worker names; finalization retains the worker and finalizer for reference repair. Kubernetes/etcd and generated CRDs are real; fulfillment and Agent state are simulated. This does not replace deployed fulfillment/BMaaS, provider, or hardware coverage; those boundary gaps remain owned by [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).

- **Bare-metal worker Agent convergence ([DEV], Unit/Envtest):** `internal/controller/baremetalworker/agent_reconcile_test.go` and `correlation_test.go` cover all eligible worker phases and protected states, early capacity/stale-ignition observation, unique MAC matching, authoritative binding isolation/conflicts, registration timeout measured from the persisted attempt origin, interrupted status recovery, continuous ReadySince intervals that are cleared on demotion, and transition event/metric counts. The Agent convergence scenarios in `acceptance/reconciler_test.go` invoke public `Reconcile` manually and read back real persisted phases/counts after Installed-condition changes or Agent removal. They also verify bound-Agent/stale-Waiting recovery without another BMI or Agent patch, lifecycle-state preservation while provider deletion is pending, and ambiguous binding refusal. Kubernetes/etcd and CRDs are real; fulfillment and Agent state are simulated. These tests do not run a manager or establish watch delivery/restart latency, deployed Assisted Service, or hardware behavior; provider gaps remain under [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).

- **Unified bare-metal worker convergence ([DEV], Unit/Envtest):** The `worker_*_test.go` and BMI identity suites under `internal/controller/baremetalworker/` cover the single invocation-local BMI/Agent observation (one List, one Agent stage, memoized recorded-ID fallback Gets), one pure identity/phase projection, one-shot optimistic status patches, authoritative reservation/capacity checks, interruption after a successful create, concurrent foreign-reference/spec/tenant/UID interruption, one fresh ownership/existence Get per destructive attempt, and finalizer retention for concurrently appended workers. The former `projected`/`agentsInvalidated` continuation caches, post-mutation `recordBMI`/`invalidateBMI` index repair, and variadic optional observation/resolver parameters are removed; capacity consumes the explicit observation and uses its canonical name/ambiguity index instead of a second name view. `acceptance/worker_reconcile_test.go` drives public `Reconcile` through real CRD status persistence and optimistic-lock conflicts. It checks successful-create ID-write recovery without another create, authoritative NotFound replacement, list-omission fallback, unknown List/Get errors and service-unavailable requeues, repair before InfraEnv gates, rejection of stale-failure persistence before recording a recreated UID, conflict interruption followed by fresh aggregate convergence while preserving concurrent status, and finalization recovery without resetting history or allocating capacity. The older rebuild pipeline is removed; its mixed/protected worker, MAC fallback, and clock/history cases are covered by the combined observation tests. Explicit successful reconciliations establish the convergence assertions, not fallback polling. R04 adds prerequisite-free progress coverage: retirement and BMI cleanup with an absent pull secret, a deleted InfraEnv and an unresolvable disk image (no discovery-ignition fetch and no Create), Agent binding while another worker's retry/cleanup is pending, an aggregate worker summary written before the blocked create gate, shortest-positive recheck selection with no timer for a stable Ready order, and stale-ignition failure persistence while the image input is blocked. R07 replaces the condition-gated InfraEnv lookup with one resource-driven observation: present/absent lookup against every Ready state, owner validation before any UID or boot artifact is consumed, scripted ignition outcomes that cannot authorize a Create, and a recreated InfraEnv whose replacement UID is recorded only after the stale waiting worker's failure is durable. R08 removes the adapter-wide consecutive-failure counter: each fulfillment call is classified from its own evidence (`Unavailable`, and `DeadlineExceeded` with an active parent, wrap `ErrFulfillmentServiceUnavailable` while preserving the original gRPC code; semantic codes and parent cancellation pass through), no state is shared across operations or orders, and public `Reconcile` is the single boundary that persists the order-scoped `FulfillmentServiceUnavailable` condition with the one bounded unavailable delay. A transport failure in the authoritative Cluster lookup fails closed as unavailable instead of emitting an ownership-mismatch event. Kubernetes/etcd and generated CRDs are real; fulfillment, ignition and Agent status are simulated. These cases do not establish watch delivery, real fulfillment/BMaaS wire behavior, deployed Assisted Service, or hardware provisioning; missing boundary coverage remains owned by [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843). R09 records one durable per-attempt registration clock and requires a continuous Ready interval: `WorkerStatus.AttemptStartedAt` is persisted with the reservation and, for a legacy ID-less attempt or a due retry, immediately before `Create`, then never refreshed by an error, Get or re-observation; the registration timeout is `AttemptStartedAt + agentRegistrationTimeout` against a caller-captured `now`; confirmed old-attempt cleanup clears the origin with the old ID; a pre-existing worker is migrated once from the backing BMI's creation timestamp when usable, otherwise one observation-time origin; and `ReadySince` starts on entry to Ready and is cleared by every demotion, failure or cleanup transition. Fixed-clock Unit cases and real-status Envtest traces cover the origin, lost acknowledgement, backfill and demotion/re-entry separately from real provider timing.

Focused commands from `osac-operator/` (also included by `make test`):

```bash
go test ./internal/controller/baremetalworker -count=1
go test -race ./internal/controller/baremetalworker -count=1
KUBEBUILDER_ASSETS="$PWD/bin/k8s/1.31.0-linux-amd64" \
  go test ./internal/controller/baremetalworker/acceptance -count=1
KUBEBUILDER_ASSETS="$PWD/bin/k8s/1.31.0-linux-amd64" \
  go test ./internal/controller/baremetalworker/acceptance -count=1 -ginkgo.focus='R05-'
KUBEBUILDER_ASSETS="$PWD/bin/k8s/1.31.0-linux-amd64" \
  go test ./internal/controller/baremetalworker/acceptance -count=1 -ginkgo.focus='R04-'
KUBEBUILDER_ASSETS="$PWD/bin/k8s/1.31.0-linux-amd64" \
  go test ./internal/controller/baremetalworker/acceptance -count=1 -ginkgo.focus='R07-'
KUBEBUILDER_ASSETS="$PWD/bin/k8s/1.31.0-linux-amd64" \
  go test ./internal/controller/baremetalworker/acceptance -count=1 -ginkgo.focus='R08-'
KUBEBUILDER_ASSETS="$PWD/bin/k8s/1.31.0-linux-amd64" \
  go test ./internal/controller/baremetalworker/acceptance -count=1 -ginkgo.focus='R09-'
```

The focused Envtest command requires the existing Kubernetes 1.31.0 binaries at
that path; `make test` obtains the platform-appropriate assets through setup-envtest.
Allocation convergence uses explicit finalizer, observation-repair, reservation,
and single-Create checkpoints. R01 Unit cases and the R01-E1 acceptance spec
assert stable opaque names, authoritative stale-snapshot resumes, independent
NodeSets sharing a type, one Create and durable ID per invocation, waiting-retry
selection, a single failed-worker retry Delete (including errors), stale-ignition
repair before UID advancement/deletion, and no hot loop for unchanged capacity. Legacy stage fixtures drive
finite sequences (bounded by `16 + 8*N` for ready fixture dependencies), assert
persisted progress at each allocation checkpoint and at most one Create per
call, and return errors/dependency/backoff results unchanged. This is a fixture
termination bound, not a production latency promise. R01-E2 Envtest cases
exercise a committed Create/lost transport acknowledgement, restart, delayed
List visibility (including the AlreadyExists re-list), same-name recovery and
rejection of foreign, ambiguous or deleting recovery candidates. The fake's
scoped-name uniqueness is independent of ID, but does not establish the real
fulfillment/Postgres contract.

The [connected worker suite](../osac-operator/test/integration/caas/README.md)
includes R01-C1, a [DEV] component-integration case with real fulfillment,
Postgres uniqueness and Kubernetes, simulated ignition/networking readiness,
and no hardware or manager watches. It deliberately loses one successful real
Create response, restarts the reconciler, omits one List to force a real
AlreadyExists re-list, and counts one persisted owned incarnation per reserved
name. Connected fixtures use explicit calls within the same `16 + 8*N` bound.
**Execution evidence:** R01 Unit/Envtest cases executed/passed; R01-C1 is
implemented and compile-checked, not executed against a real backend. The
connected command fails before fixtures because `hack/sim.env` is absent; the
explicit sim kubeconfig endpoint also refuses connections. Do not count this
preflight failure or fake uniqueness as passed real-boundary coverage. Restore
an approved marked sim environment and run the focused R01-C1 case, then
`make test-integration-caas` twice. Deployed provider/hardware gaps remain
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).
Phase repair/demotion is persisted at its own successful explicit reconciliation.
Creation inputs are resolved only for a due reservation or create, so the worker
summary, Agent binding, NodePool replicas, retirement and cleanup converge while a
pull secret, discovery ignition, disk image or instance type is unavailable; the
prerequisite wait or error surfaces after that independent work is persisted
instead of returning first. A future retry deadline and a pending failed-worker
cleanup contribute a bounded recheck to the final scheduling decision rather than
a global gate, so another actionable worker still reserves, binds or cleans up in
the same invocation. A failed retry Delete still preserves its slot, publishes the
failure summary and schedules the retry checkpoint only after a fresh
authoritative absence; protected lifecycle fixtures assert no resurrection from
installed Agents. A stable order with no pending work returns no timer and relies
on watches. No controller watch, RBAC, or deployment wiring changes are involved.

### R03 unified worker cleanup implementation checkpoint

The local implementation shares Agent-before-BMI cleanup across retry,
scale-down and finalization. `cleanup_test.go`, `retry_test.go`,
`worker_teardown_test.go` and `fake/fake_test.go` cover asynchronous deletion,
lost acknowledgement, ID retention, one retry checkpoint, retirement intent,
ID-less recovery, unknown/foreign references, ambiguous/malformed/bound Agents,
authoritative reads despite cached omission, and UID-conditioned Agent Delete.
These are **Unit / osac-operator [DEV]** cases with simulated APIs. The unit UID
race checks Delete options and simulates rejection because the Kubernetes fake
ignores UID preconditions. Existing acceptance Envtest specs are migrated to
explicit retirement/Agent/BMI/absence checkpoints; they run real Kubernetes/etcd
but simulated fulfillment and Agent lifecycle progression.

Dedicated **R03-E1–E5 Envtest / osac-operator [DEV]** fault traces in
`acceptance/worker_reconcile_test.go` are implemented and executed/passed (seven
specs). They drive public Reconcile with real persistence and explicit delayed
BMI/Agent completion, once-only retry scheduling and distinct replacement IDs,
failed scale-down/parent finalizer retention through outages, interrupted Create
ID recovery during deletion without provisioning prerequisites, authoritative
Agent reads despite cached List omission, real API UID-precondition rejection,
and bound Failed blocking/readiness isolation. Every trace uses finite calls
within `16 + 8*N`; the fixture moves retry deadlines rather than sleeping.
A temporary premature-completion mutation made R03-E1 fail on the lost old ID;
the mutation was restored before final validation.

**R03-C1 component integration / osac-operator [DEV]** is explicitly **skipped**
at the user's request because the sim environment is slated for removal. Its
added fixture-finalizer helpers and table entry have been removed from
`test/integration/caas/worker_test.go`; the pre-existing connected suite and
R01-C1 are preserved. R03-C1 is no longer a local completion gate. No live
fulfillment/Postgres retention/name-reuse or provider cleanup pass is claimed.
Unit/Envtest establish the cleanup policy/persistence invariants, not that real
service boundary or hardware release. No replacement deployed integration
harness is required for this refactor; optional same-UID Agent binding-change
Delete resourceVersion coverage (R03-E6, Envtest / [DEV]) remains proposed,
not implemented or a completion gate.
Production archived-Cluster ownership lookup needs an approved fix and a dedicated
owner/ticket (unresolved). Automated bound-worker remediation is not implemented:
cleanup waits for owner-driven detach and preserves identity/finalizers. Deployed
CAP-Agent/drain/hardware coverage remains **[QE] E2E** under
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).

### R05 single observation snapshot implementation checkpoint

The local implementation (`worker_observation.go`, `agent_observation.go`,
`agent.go`, `worker_capacity.go`, `bmi.go`, `retry.go`, `worker_teardown.go`)
derives worker identity and eligible Agent phases once per invocation from one
explicit `*workerObservation`, memoizes recorded-ID fallback Gets including
unknown results, and returns at every resource mutation without repairing
indexes, re-listing Agents after teardown, or re-projecting phases. The variadic
optional `observations ...*workerObservation`/`resolvers ...MACResolver`
parameters and the duplicated capacity `existingByName` view are removed. No
mutation is followed by post-mutation index repair or another projection in the
same invocation. Read budgets are structural assertions, not a reason to skip a
fresh destructive authorization.

**R05-U1–U5 Unit / osac-operator [DEV]** in `worker_observation_test.go`,
`worker_reconcile_test.go` and the migrated stage fixtures assert one logical BMI
List and one Agent observation stage per invocation, no Get for listed recorded
IDs, at most one fallback Get per invocation for success/NotFound/error, no
post-mutation index repair after a Create, independent per-order observation
state with a configured MAC override, and exactly one Agent-phase projection.
Existing `cleanup_test.go`/`worker_teardown_test.go` cases keep the fresh
ownership/existence Get per destructive attempt as an explicit exception.

**R05-E1–E3 Envtest / osac-operator [DEV]** in
`acceptance/worker_reconcile_test.go` drive public `Reconcile` through real
status persistence: a lost worker-status write after a successful Agent patch
recovers Binding/Ready from the Agent without a second patch or Create; Ready
demotion and protected Unbinding retain identity/history while provisioning
prerequisites are blocked; and a pre-bind Agent snapshot never yields a Ready
decision before a fresh invocation observes completion. Existing Envtest cases
continue to cover Ready demotion after Agent disappearance or Installed False,
status repair without a rebind, protected lifecycle preservation, ambiguous and
tenant/owner rejection, NIC-source and restart behavior, and stale-ignition
repair. Explicit reconciliations establish the checkpoints, not fallback polling.

These cases require real Kubernetes/etcd and generated CRDs; fulfillment,
ignition and Agent progression are simulated. They do not establish watch
delivery, deployed Assisted Service, real fulfillment/BMaaS wire behavior, or
hardware provisioning; those gaps remain owned by
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843). No new provider
protocol, production fault-injection API, managed cache framework, worker CRD, or
status reconstruction is introduced.

### R04 independent existing-worker convergence implementation checkpoint

`worker_reconcile.go` now runs named stages in dependency order: observation and
repair, InfraEnv UID evidence, the input-free existing-worker lifecycle
(retirement intent and failed-incarnation cleanup), creation with lazily resolved
inputs (a durable reservation, then at most one create), and finally teardown,
Agent binding, NodePool replicas and the worker summary. `infraenv.go` split
InfraEnv observation/UID handling from discovery-ignition fetching;
`worker_capacity.go` resolves the pull secret, ignition, disk image and instance
type only when a reservation or create is due; `retry.go` replaced the
earliest-retry global early return with one merged, clamped recheck deadline
that still selects the earliest positive wait. A prerequisite wait or error is
returned after the independent stages have persisted their own boundaries, so a
missing pull secret, ignition, image or instance type cannot starve retirement,
cleanup, Agent binding, NodePool replicas or the summary. Stale-ignition
classification still precedes acknowledging a recreated InfraEnv UID.

**R04-U1–U5 Unit / osac-operator [DEV]** in `worker_reconcile_test.go`,
`worker_capacity_test.go` and `retry_test.go` assert prerequisite-free retirement
and cleanup with no Create and no discovery-ignition fetch, binding progress while
another worker's retry/cleanup is pending, the aggregate summary written before a
blocked image lookup, the shortest positive recheck deadline (including no timer
for a stable Ready order), and fairness across blocked and actionable workers.

**R04-E1–E3 Envtest / osac-operator [DEV]** in
`acceptance/worker_reconcile_test.go` and `acceptance/reconciler_test.go` drive
public `Reconcile` with real Kubernetes/etcd status persistence and explicit
finite calls: retirement and cleanup after the pull secret, InfraEnv and image
input are removed; Agent binding in the same trace as another worker's pending
retry Delete; the demoted worker summary persisted while the resolved
ClusterVersion references an unknown disk image; bounded rechecks for
WaitingForAgent/Binding and no timer for a stable Ready order; and stale-ignition
failure persistence before the recreated InfraEnv UID is recorded while the image
input cannot resolve. These traces call `Reconcile` directly, so they do not
establish manager watch delivery, and no timing SLA is inferred from the
synthetic recheck intervals.

**R04-C1** reuses the existing connected worker suite (real fulfillment,
Postgres uniqueness and Kubernetes; simulated ignition/networking; no hardware or
manager watches) and adds no new connected entry point. That command still
requires the approved marked sim environment, which is not available in this
workspace, so it remains implemented/compile-checked rather than passed.
**R04-M1** remains a component-integration follow-up for optional Agent-CRD
startup and manager watch delivery with a deployed manager; no suitable harness
exists yet, and the gap is owned by
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).

### R06 strict shared Agent association implementation checkpoint

`correlation.go` now owns one `agentAssociation` result — established, absent,
ambiguous or invalid — used by phase projection, late binding and cleanup, with
`agentBindingConflict` applying the same namespace/cluster/binding checks to
observation, mutation and cleanup. `listAgents` stages the union of both
supported selectors (InfraEnv registration and cluster-order watch filter) and
deduplicates by Kubernetes UID, so a mixed population is never truncated to
whichever selector matched first and a failed selector List makes the whole
observation unknown. Readiness and bound deletion use only a unique compatible
established worker-name binding; initial discovery matches an unbound compatible
Agent to an eligible waiting worker by inventory NIC MACs only when the match is
unique in both directions, and an already-labelled or bound Agent is never a MAC
fallback. An incompatible candidate is a returned, observable error; ambiguity
or unreadable inventory never authorizes an Agent patch or deletion. The
first-match `findAgentForWorker`/`matchAgentToBMI` helpers and the
InfraEnv-else-cluster-order fallback are removed.

**R06-U1–U4 Unit / osac-operator [DEV]** in `correlation_test.go`,
`agent_reconcile_test.go` and `worker_projection_test.go` characterize the
selector union with shared-object deduplication, duplicate worker-label
ambiguity, bidirectional MAC ambiguity (one Agent matching several workers and
several Agents matching one worker), already-assigned Agents never used as a MAC
fallback, incompatible/foreign bindings, malformed inventory treated as unknown,
and an established worker-name label taking precedence over MAC correlation.

**R06-E1–E4 Envtest / osac-operator [DEV]** in
`acceptance/reconciler_test.go` and `acceptance/worker_reconcile_test.go` drive
public `Reconcile` through real Kubernetes UIDs/CRDs and persistence: a mixed
selector population binds the cluster-selector-only Agent while a shared-selector
object is observed once and every Agent survives; duplicate MAC matches and
duplicate worker-name claimants yield no readiness, no Agent patch or Delete, and
no BMI Delete while the slot and finalizer remain; a same-name Agent recreated
with a new UID between observation and action is not taken over under stale
evidence, and a later fresh reconciler binds the replacement as a new
incarnation; and a successful Agent patch followed by a lost worker-status write
is reconstructed from the durable Agent label by a brand-new reconciler without a
second Agent patch. These traces call `Reconcile` directly, so they do not
establish manager watch delivery or deployed Assisted Service behavior.
**R06-C1** (real Assisted Service selector/UID/binding behavior; the current
connected suite has no Agent controller) and **R06-Q1** (the existing deployed
CaaS create/scale/delete journey) remain owned by
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843)/[QE]; no identity or API
contract was expanded.

### R07 resource-driven InfraEnv evidence implementation checkpoint

`observeInfraEnvEvidence` performs the invocation's single InfraEnv observation:
one cached Get, confirmed by an uncached read when the cache omits the object,
creation only on authoritative absence, and ownership validation (namespace,
controller kind and name, plus the recorded order UID when set) before any UID or
boot artifact is consumed. `InfraEnvReady` is output evidence, not a control
gate: a missing or replaced artifact URL clears a stale Ready claim, and only a
fetched, JSON-valid discovery ignition reports Ready. The recorded InfraEnv UID
remains a durable checkpoint until stale-worker failures are persisted, so the
classification write and the UID recording stay separate invocations.

**R07-U1–U7 Unit / osac-operator [DEV]** in `worker_reconcile_test.go`
characterize condition-independent lookup (present and absent InfraEnv against
Ready True, Ready False and a missing condition, including a stale Ready claim
with no artifact URL), owner validation by namespace, controller kind, name and
incarnation UID, scripted ignition outcomes that cannot authorize a BMI Create
(missing URL, invalid JSON, fetch failure, foreign owner), interruption safety
for the stale-UID checkpoint, and a stable Ready order that writes no status and
fetches no ignition. Fault injection covers an interrupted stale-classification
status write, which must leave the recorded UID and the waiting worker untouched
until a later invocation persists the same classification, and a lost UID patch,
after which the next invocation records the UID without re-emitting failure
accounting.

**R07-E1–E2 Envtest / osac-operator [DEV]** in `acceptance/reconciler_test.go`
and `acceptance/worker_reconcile_test.go` drive public `Reconcile` through real
owner UIDs, metadata and status: a removed boot-artifact URL clears Ready and a
recreated InfraEnv's new UID advances without requiring a condition transition to
authorize the Get; and, with creation inputs blocked, replacing the InfraEnv
fails only the stale waiting worker while a bound, installed Agent stays Ready,
records the replacement UID only in a following invocation, and creates no BMI.
These traces call `Reconcile` directly, so they do not establish manager watch
delivery.

**R07-C1** reuses the existing connected worker suite (real fulfillment and
Kubernetes; simulated InfraEnv/ignition; no real Assisted Service artifact
behavior). That command still requires the approved marked sim environment, which
is not available in this workspace, so it is recorded as not executed here rather
than passed; the real Assisted Service boundary remains owned by
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).

### R08 stateless fulfillment classification implementation checkpoint

`fulfillment.go` keeps a per-call deadline but no cross-call state. Each result
is classified from that call's own evidence: `codes.Unavailable`, and
`codes.DeadlineExceeded` while the parent context is still active, wrap the
original gRPC error with `ErrFulfillmentServiceUnavailable` so `errors.Is` and
`status.Code` both keep working; `NotFound`, `AlreadyExists`, `InvalidArgument`,
`FailedPrecondition`, `ResourceExhausted`, `PermissionDenied`, `Unauthenticated`,
`Internal`, `Unknown` and a canceled/expired parent context pass through
unchanged. The consecutive-failure counter, its mutex and the three-failure
threshold are removed. Public `Reconcile` is the single orchestration boundary
for availability evidence: it persists the order-scoped
`FulfillmentServiceUnavailable` condition with the one bounded unavailable delay,
returns a condition-write failure instead of claiming the condition was recorded,
and leaves every non-availability error to its caller policy. A transport failure
in `authoritativeWorkerTenant` fails closed as unavailable rather than emitting a
`WorkerOwnershipMismatch` event, unknown discovery results retain workers and
recorded IDs, and the condition clears only after an explicit later invocation's
required reads and actions succeed.

**R08-U1–U3 Unit / osac-operator [DEV]** in `fulfillment_test.go` and
`fulfillment_error_test.go` characterize the per-call policy across every adapter
method: the first transport failure is classified without waiting for a
threshold, semantic codes are never marked unavailable, an unrelated success
cannot change another operation's evidence, the sentinel and original gRPC code
survive wrapping, and a canceled parent context is not misreported. A
reconciler-level Unit case drives public `Reconcile` for the ordinary-error,
unavailable and condition-persistence-error outcomes.

**R08-E1 Envtest / osac-operator [DEV]** in `acceptance/worker_reconcile_test.go`
drives two orders through real status persistence: one order's authoritative
NotFound prunes its stale slot while the other order's transport outage persists
its `FulfillmentServiceUnavailable` condition and retains its recorded
incarnation; neither order's result changes the other, and the outage clears only
on an explicit later successful invocation. The fake gRPC outcomes are simulated;
no server outage is injected.

**R08-C1** reuses the existing connected suite for real client/server happy-path
compatibility. Outage injection is not claimed without an explicit test-local
wrapper, so real backend outages and authorization visibility remain owned by
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843).

### R09 explicit worker attempt clocks implementation checkpoint

`WorkerStatus.AttemptStartedAt` is an optional durable timestamp for the current
attempt. It is persisted with the reservation (there is no extra round for a fresh
slot) and, for a legacy ID-less attempt or a due retry, in its own status write
that returns before the external `Create`; it is never refreshed by an error,
Get or re-observation and is cleared only when confirmed old-attempt cleanup
schedules the retry checkpoint, together with the old ID and `ReadySince`.
`checkAgentRegistrationTimeout` measures `AttemptStartedAt +
agentRegistrationTimeout` against a caller-captured `now`; `workerPhaseStartTime`
and its parent-`CreationTimestamp`/`LastFailureTime` approximation are removed.
A pre-existing worker is migrated once: the backing BMI's creation timestamp when
usable, otherwise a single observation-time origin with a compatibility
diagnostic. `ReadySince` is a continuous interval: entering Ready starts it,
leaving Ready for any reason clears it, and the healthy-history reset requires
`MinHealthyDuration` of uninterrupted readiness with `workerRecheckDeadline`
scheduling that deadline for a quiet Ready worker. Policy helpers
(`isRetryDue`, `projectReadySince`, `resetHealthyWorkers`,
`checkAgentRegistrationTimeout`, `workerRecheckDeadline`) take the captured `now`
instead of reading the clock, so no unit test sleeps through a timeout or backoff.

**R09-U1–U6 Unit / osac-operator [DEV]** in `agent_reconcile_test.go`,
`retry_test.go`, `worker_projection_test.go` and `worker_capacity_test.go`:
`TestR09NewWorkerOnOldOrder` (parent age is not the clock),
`TestR09RetryClockExcludesBackoff` (a stale `LastFailureTime` is not the clock),
`TestR09ClockSurvivesLostAcknowledgement` (repeated same-name Create keeps the
persisted origin), `TestR09ContinuousHealthyInterval` (demotion clears, re-entry
restarts), `TestR09PolicyClockBoundaries` (exact, just-before and just-after for
the registration timeout, retry due and healthy reset with fixed clocks), and
`TestR09LegacyAttemptBackfill` (BMI-clock backfill, one-time persistence and the
missing-clock fallback).

**R09-E1–E4 Envtest / osac-operator [DEV]** in
`acceptance/worker_reconcile_test.go` and `acceptance/reconciler_test.go` drive
public `Reconcile` through real CRD status persistence: the timeout is measured
from the persisted origin; a lost Create acknowledgement and a restarted
reconciler recover the same identity and origin; a legacy attempt is backfilled
once and its persisted origin schedules the timeout; and a Ready demotion clears
`ReadySince` before a re-entry starts a fresh interval. The updated
`persists Ready worker demotion after one explicit reconcile` table asserts the
cleared interval rather than the historical retention.

**R09-C1** reuses the existing connected worker suite to confirm the additional
durable boundary is stored by the real Kubernetes API; simulated
ignition/networking and no hardware timing are claimed. The suite could not run
locally (`hack/sim.env` absent), so real provider timeout/health behavior and the
deployed scale/retry journey remain owned by
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) and [QE]. No measured
latency SLA is established by the fixed clocks. Because the field is optional, an
older independently deployed controller retains the previous parent-age timeout
behavior; that is not a guaranteed safe downgrade.

### Coverage gaps

The current component integration suite does not exercise real AAP,
OpenStack, KubeVirt, or hardware provisioning. Changes to those boundaries
must be covered by a contract or real-provider suite owned by the relevant
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) follow-up task; they cannot be marked covered by envtest alone.

## bare-metal-fulfillment-operator

Touched-area requirements: [component guide](../bare-metal-fulfillment-operator/AGENTS.md#integration-testing).

### Test tiers and commands

| Tier | Location / command | Exercises for real | Faked or omitted |
|---|---|---|---|
| Unit | Co-located `*_test.go`; `make test` | Allocation, lifecycle, client, and provider logic in isolation | Kubernetes and external provider APIs are mocked or intercepted. |
| Envtest | Controller tests under `internal/controller/*_envtest_test.go`; run by `make test` | Kubernetes API server, etcd, OSAC CRDs, and static Metal3 CRDs | Metal3 controller, Ironic/BMC, hardware, and some provider clients are faked. |
| Component integration | `test/integration/`; deploy the current operator into a Kind cluster, then run `make integration-tests` | Deployed operator behavior, CRDs, Kubernetes API, pool/instance flows, and status transitions | The suite creates static `BareMetalHost` state and simulates provider transitions; it does not run a real Metal3 operator, Ironic, BMC, or hardware. |
| Component integration (CI) | `make -C osac-installer test PLATFORM=kind PROFILE=dev NS=osac SUITE=bmf` (from repository root) | The thin Kind deployment used by the PR workflow | Same static Metal3/provider boundary as the local suite. |
| Contract | No dedicated contract suite; follow [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) for qualifying provider-contract coverage | No real external provider boundary is exercised by the current suite | Static Metal3 CRDs, patched status, and simulated provider transitions do not exercise a real Metal3/Ironic/BMC contract. |
| E2E | Cross-component OSAC E2E suites | Fulfillment-to-operator user journeys where the environment provides them | Real hardware and provider availability remain environment-dependent. |

### Coverage notes

- **Pure inventory, selection, validation, or client logic:** Cover success, no-match, and provider-error paths.
- **Reconciliation, finalizers, allocation, or status transitions:** Use the public reconciler behavior and the appropriate CRD fixtures.
- **Controller deployment, CRDs, pool flows, or Kubernetes wiring:** Envtest alone does not prove the deployed controller path.
- **Metal3, BCM, Ironic, BMC, power, or hardware semantics:** Static CRDs and HTTP test doubles do not satisfy a real-boundary requirement.
- **Generated CRDs or Helm CRDs:** Keep generated artifacts synchronized.

### Coverage gaps

The current Kind suite deliberately stops at static Metal3 resources and
simulated provider status. Work that changes the real Metal3/Ironic/BCM/BMC
boundary must add the qualifying coverage under [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) or its contract-test
follow-up; extending the existing static-fixture suite alone is insufficient.

## osac-aap

Touched-area requirements: [component guide](../osac-aap/AGENTS.md#integration-testing).

### Test tiers and commands

| Tier | Location / command | Exercises for real | Faked or omitted |
|---|---|---|---|
| Unit | `tests/unit/`; `uv run pytest tests/unit` | Filter and isolated plugin behavior | Kubernetes, AAP, cloud, and storage services are mocked or fixture-driven. |
| Unit / isolated role transform ([DEV]) | `uv run --group development ansible-playbook collections/ansible_collections/osac/service/roles/hosted_cluster/tests/test.yml` | Executable NodePool definition transforms: distinct NodeSet names and selectors for the same hardware profile, independent replica counts and scale-up | No Kubernetes resources are created. This is not component-integration or deployed AAP/provider coverage; those gaps remain owned by [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843). |
| Component integration | `tests/integration/`; `make test` (creates Kind, runs playbooks, and tears it down) | Ansible roles/playbooks against a real Kind API, CRDs, leases, finalizers, and test-runner pod | AAP, OpenStack, KubeVirt/RHACM, and other provider APIs are not generally real; the VMS storage target uses a mock server. |
| Component integration (focused) | A target under `tests/integration/targets/`; run the corresponding playbook from `tests/integration/` | The specific role workflow and its documented fixtures | Only the dependencies declared by that target; inspect its setup and overrides before claiming a real boundary. |
| Contract | No dedicated contract suite; use the qualifying [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) task for AAP/provider coverage | No AAP or provider endpoint is exercised as a contract | The Kind API, mock VMS server, and fixture-driven provider behavior do not prove an AAP or provider contract. |
| E2E | Cross-component OSAC E2E suites | Complete fulfillment and provisioning flows | Depends on the deployed AAP and provider environment. |

### Build/package validation

Run `make execution-environment-build` when the execution-environment definition
or dependencies change. This validates image assembly and packaging; run the
applicable integration tests separately to validate workflow behavior.

### Coverage notes

- **Filters, variable transforms, and isolated plugin logic:** Include invalid input and default handling.
- **Ansible roles, workflow tasks, hooks, leases, finalizers, or Kubernetes resources:** The test must exercise the role/playbook through Ansible against Kind.
- **Execution-environment definition or dependency inputs:** Image success does not prove the workflow boundary.
- **AAP, OpenStack, KubeVirt/RHACM, or provider provisioning:** Kind-only tests with mocks cannot claim provider coverage.
- **Storage-provider behavior:** The mock VMS server validates role logic, not the provider API.

### Coverage gaps

The integration harness still has provider-dependent scenarios that cannot run
without AAP or additional infrastructure. Changes to provisioning behavior
must identify the real or contract boundary explicitly and link any missing
coverage to [OSAC-4850](https://redhat.atlassian.net/browse/OSAC-4850) or the relevant [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843) follow-up.

## osac-csi-driver

Touched-area requirements: [component guide](../osac-csi-driver/AGENTS.md#integration-testing).

### Test tiers and commands

| Tier | Location / command | Exercises for real | Faked or omitted |
|---|---|---|---|
| Unit | Co-located Go tests; `make test` | Driver, node/controller mapping, fulfillment client, and validation logic in-process | Fulfillment service and vendor storage endpoints are mocked. |
| Unit (CSI sanity) | `test/sanity/`; included by `make test` | CSI protocol calls over Unix sockets and the meta-driver's routing behavior | The vendor controller/node implementation is `fakeVendor`; fulfillment volume operations use a stub. |
| Component integration | No dedicated real-backend suite currently exists | — | No real storage vendor, attach/detach, mount, or fulfillment deployment is exercised by `make test`. |
| Contract | No dedicated contract suite; track [OSAC-4845](https://redhat.atlassian.net/browse/OSAC-4845) for vendor and fulfillment-boundary coverage | No deployed fulfillment or real vendor endpoint is exercised | Fulfillment and vendor calls use stubs and `fakeVendor`. |
| E2E | `../tests/e2e/storage/` when enabled | Tenant/CaaS storage-controller lifecycle and StorageClass setup | These flows do not currently create a PVC through the OSAC CSI driver or verify CSI `CreateVolume`, node publish/mount, or pod I/O. They depend on the selected storage tier and environment gates. |

### Coverage notes

- **Request/response mapping, validation, or driver helpers:** Cover protocol errors and backend status mapping.
- **CSI controller/node routing or CSI protocol behavior:** The sanity suite is required but remains fake-vendor coverage.
- **Fulfillment private Volume API contract:** A fake generated client does not prove compatibility with the deployed service.
- **Vendor attach, detach, mount, or storage lifecycle:** The fake vendor cannot satisfy a real storage-backend requirement.
- **Helm/deployment changes:** Build an image when container/deployment inputs change.

### Coverage gaps

The current sanity suite intentionally stops at a fake vendor and a fulfillment
stub. Changes to a real storage backend, attach/detach, mount, or deployed
fulfillment boundary require the real-backend coverage tracked by [OSAC-4845](https://redhat.atlassian.net/browse/OSAC-4845);
do not label fake-vendor sanity coverage as component integration coverage.
The current storage E2Es validate orchestration and StorageClass setup, not the
full CSI delivery path from PVC creation through LVMS/TopoLVM to a mounted
workload. That end-to-end user journey still needs an explicitly owned QE test.

## osac-metering

Touched-area requirements: [component guide](../osac-metering/AGENTS.md#integration-testing).

### Test tiers and commands

| Tier | Location / command | Exercises for real | Faked or omitted |
|---|---|---|---|
| Unit | Co-located Ginkgo tests in `schema/`, `metering-service/`, and `adapters/`; `make test` | Schema, mapping, runner, retry, ordering, and adapter behavior in-process | Kafka, fulfillment Watch, and most external services are mocked. |
| Component integration (database) | `metering-service/internal/projection/postgres_test.go`; included by `make test` | A real PostgreSQL testcontainer, schema, persistence, versioning, and queries | Kafka and fulfillment event delivery are not exercised. `SKIP_DB_TESTS` disables this tier. |
| Component integration | No dedicated real-Kafka component suite currently exists | — | Kafka, CloudEvents delivery, fulfillment Watch, offset commits, retries, and DLQ behavior are currently tested with mocks. |
| Contract | No dedicated contract suite; track [OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843)/[OSAC-4846](https://redhat.atlassian.net/browse/OSAC-4846) for fulfillment Watch and Kafka boundaries | No deployed Watch or Kafka protocol endpoint is exercised | Mock streams and Kafka mocks are used. |
| E2E | Cross-component OSAC metering/E2E deployment | The deployed metering pipeline and its configured Kafka/provider dependencies | Depends on the installer environment and enabled metering path. |

### Coverage notes

- **Event schema or transition mapping:** Schema changes affect `schema/`, `metering-service/`, and `adapters/`.
- **Projection/database code:** Do not set `SKIP_DB_TESTS` when validating database behavior.
- **Kafka producer/consumer, CloudEvents transport, offsets, retries, or DLQ:** Mock Kafka tests alone do not prove the pipeline boundary.
- **Fulfillment Watch or gRPC event ingestion:** Mock streams validate local handling, not the wire contract.
- **Provider adapters:** The shared runner must remain the owner of ordering, retry, deduplication, and DLQ behavior.

### Coverage gaps

There is no component-level suite that runs the full fulfillment Watch → Kafka
→ CloudEvents pipeline. Changes to that path must not claim integration
coverage from mock-based tests; add or extend the real-Kafka coverage under
[OSAC-4846](https://redhat.atlassian.net/browse/OSAC-4846).

## tests/e2e

Touched-area requirements: [component guide](../tests/e2e/AGENTS.md#touched-area-map).

| Tier | Location / command | Exercises for real | Faked or omitted |
|---|---|---|---|
| E2E (VMaaS regression) | From the repository root: `uv run pytest tests/e2e/vmaas/regression/test_compute_instance_instance_type.py` | InstanceType resize through CLI/API, CatalogItem provisioning, and Kubernetes/KubeVirt resources | Requires a configured single-node VMaaS environment; no services are mocked. |
| Unit ([DEV], CaaS teardown) | From the repository root: `uv run pytest -n 0 tests/unit/test_caas_teardown_order.py tests/unit/test_cluster_deletion_polling.py tests/unit/test_caas_deletion_diagnostics.py tests/unit/test_caas_worker_bmi_visibility.py tests/unit/test_caas_two_node_sets.py tests/unit/test_caas_selector_contracts.py` | Read-only wait logic, exact-resource NotFound, ordered worker/parent/dependent waits, shared single/two-node-set budgets, stage-specific safe failures, snapshot throttling and sanitization, worker ownership checks, NodeSet selectors with shared BMITs, and shared-only BMIT reference expectations | API/client responses and time are mocked. No deployed controllers, fulfillment, AAP, provider, or metering is exercised. |
| E2E ([QE], focused bare-metal CaaS lifecycle) | From the repository root: `uv run pytest -n 0 tests/e2e/caas/sanity/test_cluster_create.py::test_cluster_create --junitxml=/tmp/test-output/caas-bm-teardown-junit.xml` | CLI/API/database, Kubernetes, OSAC operators, AAP, HyperShift/CAPI/CAP-Agent, Assisted Service, provider-backed virtual BMHs, and Kafka/metering; creation, guest readiness, scale events, natural worker/parent teardown, independent InfraEnv GC, fulfillment removal, and deleted events | Requires the compatible deployed CaaS profile; no mocked completion or workaround-enabled deletion wait. Virtual BMHs do not prove physical-hardware coverage. Guest LVMS device readiness, PVC/CSI mount, and application I/O are not established by this lifecycle test. |

Resize lifecycle tests expect `RestartRequired`. Multi-node live hot-plug
coverage is tracked under
[OSAC-5335](https://redhat.atlassian.net/browse/OSAC-5335).

### Focused CaaS natural-teardown boundary

Both `test_cluster_create` and `test_cluster_create_with_two_node_sets` use the
same natural teardown assertions. The two-node-set scenario additionally
checks ready worker aggregates, installed Agents, and per-NodeSet
NodePool isolation. Unit regressions additionally cover distinct NodeSets
sharing one BMIT; that same-profile case is not exercised by this deployed
scenario. Run that [QE] E2E with
`uv run pytest -n 0 tests/e2e/caas/sanity/test_cluster_create.py::test_cluster_create_with_two_node_sets`;
it requires the same source-pinned environment described below and enough
available BMHs for both worker sets.

The deletion request triggers the test-owned worker BMI wait (480 attempts at
five-second intervals). Worker ownership is verified through both fulfillment
and Kubernetes tenant/owner annotations before those IDs enter the deletion
assertions. Only after all verified BMIs disappear does the
read-only parent wait observe the exact ClusterOrder NotFound (121 attempts at
ten-second intervals); only after parent removal does the separate InfraEnv GC
wait observe that exact InfraEnv NotFound in the same namespace (60 attempts at
five-second intervals). Empty status, a terminating object, or an API error is
not absence. Parent lookup errors fail fast; InfraEnv lookup errors retain the
existing retry policy but cannot satisfy the absence assertion.

The parent and dependent budgets schedule at most 1,200 and 295 seconds of
sleeps, respectively. Command execution and approximately sixty-second,
monotonic-throttled diagnostic snapshots add time, so these are not strict
elapsed deadlines or production SLAs. Either stage timing out remains a test
failure, with a final sanitized snapshot, even if resources disappear later.
The focused path does not remove lifecycle hooks or finalizers. Other scenarios
that still call the legacy cleanup-enabled `wait_for_cluster_deletion` do not
prove natural teardown. Unit tests and collection do not prove deployed E2E
success; this test-only change adds no Envtest/component-integration/Contract
tier.

Use `tests/e2e/conftest.py` for fixture configuration: hub kubeconfig and
`OSAC_NAMESPACE`, public/private fulfillment endpoints and auth, current CLI and
required utilities, template/release/disk images, pull-secret/SSH-key inputs,
available virtual BareMetalHosts, and healthy Kafka/metering. Verify compatible
source revisions and image digests for OSAC, operators, installer, and the AAP
execution environment/project; AAP must resolve the exact tested revision, not
mutable `main`/`latest`. Preserve JUnit, lifecycle logs, and cleanup evidence
before infrastructure teardown.

Guest LVMS disk prerequisites are a separate storage/infrastructure follow-up;
its infrastructure source revision, owner, and Jira URL remain unresolved. Do
not wipe or reuse the guest OS disk to make the lifecycle test pass.
