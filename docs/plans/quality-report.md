# Quality report — CaaS testing status

**Snapshot:** 2026-10-20, `osac` @ `2a0d95f8` (branch `plan/osac-6348`) plus
the uncommitted CaaS marking changes. Executed on a lab host with
go 1.26.3, podman and Kind. Companion documents:
[full-e2e-reqs.md](full-e2e-reqs.md) (environment dependencies) and
[2026-10-20-osac-6117-caas-unified-nightly-e2e-requirements.md](2026-10-20-osac-6117-caas-unified-nightly-e2e-requirements.md)
(scoping and backlog). Coverage artifacts are generated into
`coverage-osac-6117/` by [`tools/caas-coverage/`](../../tools/caas-coverage/SCOPE.md)
and are not committed.

---

## Executive summary

- **Measured coverage (CaaS core, Go statements): UT 81.3%** (3966/4879),
  **IT 63.1%** (1152/1827, service side), **combined 82.6%** (4030/4879).
  Worker-path dependency (BMF operator): 63.9% UT.
- **All executed suites green**: fulfillment servers, operator (incl.
  envtest), BMF, metering unit suites, and 59/59 caas-labeled `it/` specs
  (twice) against a deployed Kind stack.
- **9 pre-existing Python unit failures at this baseline** (verified
  unchanged without the marking edits) — test/workflow drift, not
  regressions; root causes below.
- **Deployed E2E (the 5 `tests/e2e/caas` tests) not executed in this
  session** — they need the full cluster-tool shape; the nightly chain that
  runs them is healthy and documented.
- Biggest quality risks: zero E2E coverage of the tenant-network attachment
  path (the exact cross-WG gap the epic exists for), zero coverage of 8 AAP
  cluster-chain roles and the `ci.steps` collection at unit level, and no
  upgrade/addon E2E.

## Test inventory (CaaS scope, after marking)

Runtime selection now works: `ginkgo --label-filter=caas`, `go test <pkg>
-args -ginkgo.label-filter=caas`, `pytest -m caas`. Marking details and
decisions: [`tools/caas-coverage/SCOPE.md`](../../tools/caas-coverage/SCOPE.md).

| Suite | Tier | caas-labeled | Total | Status (this session) |
|---|---|---|---|---|
| fulfillment `internal/servers` | Unit | 438 | 2323 | PASSED (full suite, 372 s) |
| fulfillment `internal/database/migrations` | Component integration | n/a (plain `DescribeMigration`) | — | PASSED (podman PostgreSQL) |
| fulfillment `it/` | Component integration (Kind) | 59 | 512 | **59/59 PASSED** ×2 runs |
| operator `internal/controller` | Unit + Envtest | 414 | 1424 | PASSED (full suite) |
| operator `internal/controller/baremetalworker` | Unit + Envtest | 434 (suite-level) | 434 | PASSED |
| operator `test/integration` | Component integration (Kind) | 1 container | — | NOT RUN (needs deployed operator) |
| `tests/unit` (pytest) | Unit (harness) | 102 collected | 111 | 93 passed / **9 pre-existing failures** |
| `tests/e2e/caas` | E2E | 5 tests (sanity/regression markers) | — | NOT RUN here; nightly chain runs them |
| `tests/e2e/references` (`requires_caas`) | E2E | 6 tests | — | NOT RUN here |
| `tests/e2e/storage/test_caas_cluster_storage.py` | E2E | 1 test | — | NOT RUN here |

## Measured coverage

Full report with per-file numbers:
[coverage-osac-6117/caas-coverage.md](coverage-osac-6117/caas-coverage.md);
profiles and browsable HTML beside it (`caas-ut-`, `caas-it-`,
`caas-combined-coverage.{out,html}`).

| Section | UT | IT (service) | Combined |
|---|---|---|---|
| fulfillment cluster servers (10 files) | 78.2% | 63.1% | 81.7% |
| operator ClusterOrder controllers (incl. feedback) | 85.6% | — | 85.6% |
| operator baremetalworker (CaaS workers) | 82.0% | — | 82.0% |
| metering cluster events (`events/cluster.go`) | 74.1% | — | 74.1% |
| **CaaS core total** | **81.3%** | **63.1%** | **82.6%** |
| BMF operator (worker path, BMaaS-owned tests) | 63.9% | 0.7% | 63.9% |

Weakest files (UT): `baremetalworker/reconciler.go` 32.4%,
`baremetalworker/image.go` 50.0%, `baremetalworker/bmi.go` 55.7%,
`cluster_versions_server.go` 58.4%, BMF `internal/profile` 0%,
`bmcdiscovery/redfish.go` 0%. IT-low: `cluster_versions_server.go` 15.2%,
`cluster_templates_server.go` 37.2%.

Python harness coverage achieved by the caas-marked unit tests
(`pytest -m caas --cov=tests/e2e`): `caas/deletion_diagnostics.py` 97.6%,
`core/caas_versions.py` 100%, `caas/regression/test_cluster_node_sets.py`
93.5%, `caas/sanity/test_cluster_create.py` 60.8%, shared `core/*` helpers
13–80% (raw: `coverage-osac-6117/ut-raw/python-caas.json`).

## Execution status detail

**Green (executed 2026-10-20):**

- `go test ./internal/servers` — 77.2% package coverage, 372 s.
- `go test ./internal/database/migrations` — pass (SQL statements are not
  Go-measurable; migration 125's worker owner-reference checks are exercised).
- operator full suite (envtest 1.31.0) — controller 79.0%, baremetalworker
  82.0%, feedback 94.0%, all packages `ok`.
- BMF full suite — controller 76.9%, inventory 79.6%, netboxclient 84.8%.
- metering `internal/events` — 76.6%.
- Kind IT: coverage-instrumented service deployed
  (`ARG COVERAGE=true` Containerfile, `GOCOVERDIR` on emptyDir), 59 caas
  specs PASSED in 220 s, counters collected after graceful flush.

**Red (pre-existing, not caused by the marking — verified via stash):**

| Failure | Root cause |
|---|---|
| `test_caas_ci_suite_policy.py` — 5 cases (`test_caller_trigger_policy[osac-*]`, `test_pr_events_ignore_overrides[osac-*]`, `test_manual_overrides[osac]`) | The eval harness in the test does not stub `inputs.sha`, which `.github/workflows/e2e-caas-full-install.yml:78` now references — test/workflow drift at this commit |
| `test_caas_teardown_order.py`, `test_caas_worker_bmi_visibility.py` — 4 cases | Scenario mock returns a version dict without `id`, which `test_cluster_create.py:597` now reads (`KeyError: 'id'`); one case also needs the `/tmp/test-key.pub` fixture file to exist |

**Not executed here (needs deployed environment):**

- `tests/e2e/caas` sanity+regression, `references` (`requires_caas`),
  `storage/test_caas_cluster_storage.py` — the full cluster-tool shape of
  [full-e2e-reqs.md](full-e2e-reqs.md). Execution paths that run them:
  nightly `e2e-caas-test`, periodic caller (8 h),
  `e2e-full-regression-caller.yml` (unified prototype, every other day).
- operator `test/integration` Kind suite (RBAC-only CaaS coverage).
- Fabric variants: Netris (manual dispatch), agentless-net (**periodic
  disabled while failing** — job-level red, see
  `e2e-caas-agentless-net-full-install.yml` header).

## Known gaps

1. **Zero E2E on tenant-network attachment**: no test exercises
   `Cluster.network_attachment`, the BMaaS-owned `move_network_attachment`,
   or MAC-based DHCP discovery; the CLI test helper does not expose the
   flag. This is the Networking+BMaaS gap the epic records.
2. **Zero unit coverage** on 8 AAP cluster-chain roles (`cluster_network`,
   `external_access`, `manage_agents`, `metallb_ingress`, `cluster_infra`,
   `retrieve_kubeconfig`, `write_ssh_keys`, `nmstate_config`) and the
   `ci.steps` collection — Kind targets exist for the top-level playbooks
   only (`cluster_create_caas`, `cluster_delete_caas`, `cluster_post_install`,
   `cluster_status_reporting`, `cluster_working_namespace`).
3. **No PVC/CSI-mount or application-I/O assertion on guest clusters**; the
   cluster-storage lifecycle test stops at `ClusterStorageReady` + tenant
   status (guest LVMS prerequisites unresolved).
4. **No upgrade E2E** ([OSAC-1415](https://redhat.atlassian.net/browse/OSAC-1415)),
   no addon-operator E2E ([OSAC-4090](https://redhat.atlassian.net/browse/OSAC-4090)).
5. `requires_caas_fabric` marker referenced by the Netris caller but defined
   nowhere in the mono-repo.
6. IT coverage measures the service side only in the phase-1 shape
   (operator disabled); the operator's Kind suite was not run.

## Recommendations

1. Fix the two pre-existing failure clusters (stub `inputs.sha` in the
   selection-policy harness; update the scenario mocks for the catalog-item
   `version["id"]` shape) — they mask real signal in the python UT tier.
2. Close gap 1 first (P1 backlog: cluster-on-tenant-fabric-Subnet) — it is
   the epic's reason to exist and needs the helper `network_attachment`
   support as prerequisite work.
3. Extend the coverage tooling into CI: run
   `tools/caas-coverage/run-ut-coverage.sh` on PRs (cheap) and the
   in-cluster IT instrumentation on periodics; trend the section numbers.
4. Re-enable or delete the agentless-net periodic (currently neither
   running nor removed).

## Backlog (from the OSAC-6117 document)

| Priority | Scenario | Effort |
|---|---|---|
| P1 | Cluster on tenant fabric Subnet (port move + DHCP + Ready) | L |
| P1 | Cluster API/ingress reachable (MetalLB + DNS) | M |
| P1 | Guest-cluster PVC end to end (CSI mount + I/O + VIP reachability) | L |
| P1 | Natural teardown with fabric port return + leak checks | M |
| P2 | Scale up/down metering (exists — extend), two node sets (exists), version resolution (exists), deprecated-DiskImage rejection, worker provenance | S |
| P3 | Cluster upgrade, addon operator, agent-flow parity on fabric, shared-tenant rejection | S–L |

## Reproduce

```bash
bash tools/caas-coverage/run-ut-coverage.sh   # UT profiles + report
bash tools/caas-coverage/run-it-coverage.sh   # Kind IT run (prereqs in header)
pytest tests/unit -m caas                     # marked python unit tests
```

Environment note: the `osac-dev` Kind cluster from the IT run is still up
with the coverage-instrumented service; teardown commands are in
[coverage-osac-6117/caas-coverage.md](coverage-osac-6117/caas-coverage.md).
