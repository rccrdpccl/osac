# CaaS quality report — coverage status and plan

**Snapshot 2026-10-20** · `osac` @ `2a0d95f8` · details and artifacts:
[quality-report.md](quality-report.md),
[coverage-osac-6117/](coverage-osac-6117/),
[full-e2e-reqs.md](full-e2e-reqs.md).

## Current coverage (measured, statement coverage)

| Area | UT | IT | Combined |
|---|---|---|---|
| CaaS core (cluster servers, ClusterOrder + worker controllers, metering events) | **81.3%** | 63.1% | **82.6%** |
| Worker path (BMF operator, BMaaS-owned tests) | 63.9% | — | 63.9% |

All executed suites green; 59/59 caas-labeled IT specs passed against a
deployed Kind stack. The **AAP boundary is the weakest link**: the operator's
AAP client and provisioning lifecycle are unit-tested against fakes
(`pkg/aap` 83.8%, `pkg/provisioning` lifecycle 89.8%), the playbooks run
against Kind without a real AWX server, and the operator↔AAP job loop is
only truly exercised in the nightly E2E. Eight cluster-chain Ansible roles
and the `ci.steps` collection have **zero** unit-level coverage.

## The AAP flow

The provisioning brain of CaaS lives in Ansible jobs, not in the operator:

```text
ClusterOrder CR
  -> operator: RunProvisioningLifecycle (pkg/provisioning)
       guards: API-server job check + statusFlush (no duplicate jobs)
  -> AAPProvider.TriggerProvision -> AWX API (LaunchJobTemplate + extra_vars,
       incl. admin kubeconfig, redacted in logs)
  -> AWX runs the osac EE pod (ghcr.io/osac-project/osac-aap)
       playbook_osac_create_hosted_cluster.yml:
       write_ssh_keys → cluster_settings → extract_template_info
       → cluster_working_namespace → LEASE (cluster-<name>-lock, SSA)
       → finalizer (infrastructure) → cluster_infra
       → cluster_network (steps collection; ci.steps waits for Agents)
       → hosted_cluster (HostedCluster/NodePool) → manage_agents
       → metallb_ingress → external_access (DNS) → retrieve_kubeconfig
       → post_install → set_stats osac_result → release lease
  -> operator polls GetJob (status + Artifacts JSON -> ExtraVars handoff)
  -> feedback: ClusterOrder status -> fulfillment-service (Signal + resync)
  delete: TriggerDeprovision -> cancel running job -> reverse playbook
```

**Components it brings on:** AWX API server (+ its postgres/redis), the
execution-environment image, git project checkout of the osac repo (pinned
ref), job templates + instance groups (`clusterFulfillment` with
`NETWORK_CLASS`/`NETWORK_STEPS_COLLECTION`), the `osac.service` and steps
collections, credentials, extra_vars delivery (including an admin
kubeconfig), job artifacts (`osac_result` set_stats), the cancellation API,
and the coordination `Lease` objects. A second job family runs in parallel:
BMF-operator jobs provisioning worker BMIs (RHCOS + ignition + fabric port
move) whose Agents the CaaS job's `cluster_network` step waits for.

## Operator ↔ AAP races to cover

| # | Race window | Guard today | Covered? |
|---|---|---|---|
| R1 | Operator resync/`Signal` while a job is pending/running → duplicate job launch | `CheckAPIServerForNonTerminalProvisionJob` + `statusFlush` ([provision_lifecycle.go](../../osac-operator/pkg/provisioning/provision_lifecycle.go)) | Unit tests assert flush is *called*; the actual concurrent-reconcile race is never executed |
| R2 | Optimistic-concurrency conflict on CR status during job trigger (flush fails) | statusFlush retry + end-of-reconcile update | Comment-documented; only mocked |
| R3 | CR deleted while provision job in flight (incl. the launch→registered window where cancel is impossible) | `isReadyForDeprovision` + `CanCancelJob`/`CancelJob` | Mirrors the BMI "intent-before-Create" ambiguity documented as unresolved in the worker specs |
| R4 | Stale `Lease` holder: job pod dies (BackoffLimitExceeded) → lease blocks the retried job | SSA holder-identity conflict; pod ownerRef GC; **no TTL set** | Zero tests — deadlock candidate |
| R5 | Finalizer role does read-modify-write `union()` on the target CR's finalizer list while the operator mutates the same list | None (last-write-wins on the array) | Zero tests |
| R6 | Two job families converge: CaaS create job waits for Agents that BMF jobs produce; scale event shifts the wait condition mid-flight | `ci.steps` retry-until on agent count; worker capacity specs | Only in E2E (two-node-set test), never deterministically |
| R7 | Template cache: job template renamed/updated while operator holds a cached ID | `invalidateTemplateCache` | Unit only |
| R8 | Artifact handoff: job succeeds but `osac_result` artifact missing/malformed → operator requeues or stalls | Requeue-and-retry callback | Unit tests exist with fakes (`PollJob output callbacks`) |

## Plan 1 — give the AAP flow real coverage

1. **AAP API double in envtest (Contract tier).** An in-process HTTP server
   implementing the AWX endpoints the client uses (templates, launch, job
   status, artifacts, cancel) with **fault injection**: job stuck pending,
   slow status, artifact arriving late/missing, 409s. Wire it into the
   operator's envtest suite so the full ClusterOrder reconcile runs against
   it. This is where R1–R3, R7, R8 become **deterministically testable
   races** — inject the interleaving, assert one job / correct cancel / no
   stall.
2. **Lease and finalizer role tests (osac-aap Kind targets).** R4: kill a
   lease-holding job pod, assert the retried job acquires the lease (or the
   role gains a TTL/stale-holder check — flag as a probable code fix, not
   just a test). R5: run the finalizer role concurrently with a status
   writer on the same CR, assert no lost update.
3. **Unit tests for the 8 uncovered cluster-chain roles** (`cluster_network`,
   `external_access`, `manage_agents`, `metallb_ingress`, `cluster_infra`,
   `retrieve_kubeconfig`, `write_ssh_keys`, `nmstate_config`) and a
   `ci.steps` Kind target — today failures in these roles surface only as
   opaque E2E failures.
4. **R6 as an envtest scenario:** fake-BMF Agents appearing out of order +
   a scale event mid-wait, asserting the wait converges and worker metrics
   stay correct.

## Plan 2 — shift left

Today the operator↔AAP boundary first runs real at nightly E2E; nothing
between "mocked unit" and "full deployed cluster" exercises it. Path
forward, each step gating earlier and cheaper than the last:

| Step | What | Tier / pipeline placement | Closes |
|---|---|---|---|
| S1 | AAP API double + race scenarios (Plan 1.1, 1.4) | Envtest, **every PR** (minutes, no AAP deployment) | R1–R3, R7, R8 at contract level |
| S2 | Role-level Kind targets incl. lease/finalizer races (Plan 1.2, 1.3) | `osac-aap` component integration, every PR | R4, R5 + role coverage |
| S3 | **Real AWX in Kind**: awx-operator minimal install, publish templates via the existing `publish_templates` role, operator round trip (launch → poll → artifact → cancel) against a real AWX | Contract tier, nightly + label-gated dispatch (AWX in Kind is too heavy for every PR) | the real protocol/format gaps the double can miss (auth, pagination, artifact JSON shape) |
| S4 | Keep E2E nightly as the deployed journey, now focused on what only it can prove (real EE image, real workers, fabric, metering) | unchanged | integration with the rest of the chain |

Sequencing: S1 and S2 are pure test work in existing suites (no new
infrastructure); S3 needs a small workflow in `osac-test-infra` reusing the
Kind runner pattern. The `osac_result` artifact schema and the launch
extra_vars contract should be pinned by S1's double so S3 validates against
the same fixtures.

## IT redundancy analysis — marginal-guarantee framework

An IT spec always carries stronger guarantees than UT (real stack), so the
question is never "UT covers it → delete" but "what marginal guarantee does
spec N add over specs 1..N-1 plus UT". Three guarantee kinds:

1. **Wire-contract probes** — this RPC method × message shape × identity
   class works through the deployed stack. Needed once per distinct
   contract: List and Get are two contracts; create-by-id and create-by-name
   are two shapes; service-account and JWT-tenant are two identity classes.
2. **Deployment-real behavior** — what UT fakes: tenancy/attribution with
   real identities, validation against real CR state, the reconciler loop,
   error codes surviving envoy + interceptors.
3. **Behavior repetition** — logic UT already proves with the same real
   PostgreSQL. Marginal value reaches zero here — but only after 1 and 2
   for that path are banked by an earlier spec.

Case-count is not the criterion; **shape/identity variation is**: the
catalog-item policy Entry table earns its IT place (each case is a distinct
proto policy shape across the wire — 37 IT-only executed statements), while
the not-found trio re-proves one error-mapping contract three times.

Applied to the 59 caas-labeled IT specs (evidence: block-level IT∩UT
execution analysis, [coverage-osac-6117/](coverage-osac-6117/)):

| Verdict | Specs | Rationale |
|---|---|---|
| Keep — wire probes | ClusterVersions CRUD; public templates List+Get; clusters Get/List/Create/Update/Delete; pull-secret by-id + by-name | One probe per distinct RPC/shape; some are the only exercise of that service's deployed contract |
| Keep — deployment-real | reconciler specs (all 5); creator attribution; missing-image rejection; catalog governance/visibility + policy Entry table; attachment READY-state validation | Depend on real identities, real CR state, or the deployed controller loop — UT fakes these |
| Fold/drop (~7–9) | ClusterVersions immutability; 2 of 3 not-found; attachment-immutability pair; extra pull-secret rejections; explicit-version create | Same wiring already probed + behavior UT-proven (91–100% on the relevant functions) |

Payoff: the folded specs are ~30–40% of the caas IT runtime plus their flake
surface; the freed time goes to the AAP-loop IT expansion below. UT's role
is to keep the behavioral matrix cheap so IT can shrink to probes +
deployment-real behavior without losing breadth.

## Success criteria

- R1–R8 each have a deterministic failing-then-passing test at or below
  Contract tier; R4/R5 outcomes decide whether lease TTL / SSA-based
  finalizer writes are needed as code fixes.
- The 8 cluster-chain roles have Kind-level coverage; no E2E-only role
  failures.
- Operator↔AAP boundary covered before every merge (S1), real AWX validated
  at least nightly (S3) — E2E stops being the first place AAP bugs appear.
