# CaaS quality — meeting brief

**2026-10-20 · OSAC-6117** · details: [quality-report-caas.md](quality-report-caas.md)

## Current state

- **UT: 81.3%** of CaaS-core statements (3966/4879), measured by executing
  all unit/envtest suites with coverage instrumentation — green.
- **IT: 63.1%** of cluster-server statements (1152/1827, service side),
  measured from a deployed Kind stack — 59/59 caas-labeled specs green.
- **Sanity E2E (every PR):** full cluster lifecycle — catalog-item-authored
  create → guest Ready → scale up/down with metering events → natural
  teardown (workers released, InfraEnv GC, deleted events); plus deletion
  feedback (DELETING state without full provisioning).
- **Regression E2E (periodic):** two-node-set clusters (per-NodeSet NodePool
  isolation, ready-worker aggregates, installed Agents); explicit and
  invalid cluster-version resolution.
- The **AAP ↔ Operator ↔ Fulfillment-service flow is the weak link**: this
  boundary only runs real in nightly E2E — unit tests use fakes, playbook
  tests run without a real AWX, and 8 cluster-chain Ansible roles plus
  `ci.steps` have zero unit-level coverage.

## Next steps

- **Build an AAP integration test framework.** The AAP ↔ Operator ↔
  Fulfillment-service flow is critical — fulfillment creates the CRs the
  operator dispatches jobs from, receives the feedback, and owns the worker
  BMI API the chain provisions through — and today we have coverage for it
  only in E2E. Objective: **detect this class of bugs before they get to
  E2E**, on a deployed stack (fulfillment + operator + real AAP) that is
  cheap enough to run per change.
- **Focus on testing races between the components dealing with AAP** — 8
  identified race windows (duplicate job launches on resync, delete during
  in-flight job, stale lease deadlock, lost finalizer updates, two job
  families converging on worker Agents). Guards exist in code but are only
  exercised against mocks; two (lease TTL, finalizer write) look like code
  fixes, not test gaps.
- **Increase coverage, especially in IT** — extend the IT tier beyond the
  API-level cluster specs toward the job loop (dispatch → poll → artifact
  handoff → feedback), and add unit/Kind coverage for the uncovered Ansible
  roles.
