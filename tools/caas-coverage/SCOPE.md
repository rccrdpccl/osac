# CaaS coverage scope (OSAC-6117)

Definition of "CaaS-related" used by the coverage tooling in this directory.
Keep in sync with the patterns in [`filter_profile.py`](filter_profile.py);
the two must not drift.

## Marking

Tests are marked for runtime selection, following the repository's existing
Ginkgo-label convention (`Label("baremetalworker")`):

- **Go**: `Label("caas")` on every top-level spec container that is
  CaaS-owned, plus a suite-level label on the `baremetalworker` subpackage
  suite. Select with `ginkgo --label-filter=caas` or
  `go test <pkg> -args -ginkgo.label-filter=caas`.
- **Python**: `pytestmark = pytest.mark.caas` at module level in
  `tests/unit/` CaaS files; the marker is registered in `pyproject.toml`.
  Select with `pytest -m caas`.

Applied by [`mark_caas_labels.py`](mark_caas_labels.py) (already executed;
re-running fails loudly because every exact-match target now contains the
label). Marked spec counts at the baseline commit:

| Suite | caas-labeled specs | Total specs |
|---|---|---|
| fulfillment-service `internal/servers` | 438 | 2323 |
| fulfillment-service `it` | 59 | 512 |
| osac-operator `internal/controller` | 414 | 1424 |
| osac-operator `internal/controller/baremetalworker` | 434 (suite-level) | 434 |
| osac-operator `test/integration` (Kind) | 1 container | — |
| `tests/unit` (pytest `-m caas`) | 102 collected | 111 |

Not labeled, by decision:

- **bare-metal-fulfillment-operator tests** — they are BMaaS-owned and serve
  both tenant BMIs and CaaS workers. The BMF module is *measured* as the
  worker-path dependency (see below) but its tests are not caas-labeled, so
  `--label-filter=caas` never runs BMaaS-only specs.
- **fulfillment `internal/database/migrations/125_*`** — uses the
  `DescribeMigration` helper, which does not accept Ginkgo decorators. The
  worker owner-reference migration is exercised by its dedicated (passing)
  test; SQL statements are not measurable by Go statement coverage.
- **`tests/e2e/caas/**`** — already selectable through the
  `sanity`/`regression`/`requires_caas` markers and never runs outside a
  deployed environment; adding a `caas` marker would be inert churn.
- **`it_cluster_nodesets_fixtures_test.go`** — plain Go test of a fixture
  builder, no Ginkgo container to label.

## Code in scope (coverage filter)

### Core (CaaS-owned)

| Section | Files |
|---|---|
| fulfillment-service cluster servers | `internal/servers/{clusters_server, private_clusters_server, cluster_catalog_items_server, private_cluster_catalog_items_server, cluster_catalog_item_policies, cluster_templates_server, private_cluster_templates_server, cluster_versions_server, private_cluster_versions_server, cluster_version_resolution}.go` |
| osac-operator ClusterOrder controllers | `internal/controller/clusterorder_*.go`, `feedback_controller.go`, `feedback_sanitize.go` (the ClusterOrder feedback reconciler; the generic `feedback/bridge.go` is shared by 10+ controllers and excluded) |
| osac-operator CaaS workers | `internal/controller/baremetalworker/*.go` (whole package) |
| osac-metering cluster events | `metering-service/internal/events/cluster.go` |

### Worker-path dependency (measured, reported separately)

| Section | Files |
|---|---|
| bare-metal-fulfillment-operator | the whole module — the CaaS worker chain runs through BMI allocation, Metal3/Netbox inventory, networking, and IP discovery |

### Excluded

- `osac-operator/pkg/{provisioning,aap,dispatcher}` — shared with BMF and
  other controllers (cross-component infrastructure, not CaaS-specific).
- AAP Ansible roles (`osac-aap/`) — Python/Ansible coverage is a separate
  surface; the AAP unit suites are BMaaS/publishing-owned.
- `osac-metering/schema` — contains only the `ResourceTypeClusterOrder`
  constant for CaaS; no meaningful statements to measure.
- CSI driver, UI, installer charts — CaaS-adjacent at most.

## Python unit-test coverage

`pytest -m caas --cov=tests/e2e` measures the E2E **test harness** code the
CaaS unit tests drive (`tests/e2e/caas/**`, `tests/e2e/core/*` helpers). It
does not measure product code; product-side coverage is the Go profiles
above.

## Artifacts

Produced under `docs/plans/coverage-osac-6117/`:

- `caas-ut-coverage.out` — merged, scope-filtered Go UT profile
- `caas-ut-coverage.html` — browsable report (`go tool cover -html`)
- `caas-it-coverage.out` / `.html` — in-cluster service coverage from the
  IT run (when executed; see `run-it-coverage.sh`)
- `ut-raw/` — raw per-module profiles and JSON summaries
- `caas-coverage.md` — the human report
