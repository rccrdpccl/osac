# OSAC development environment (remote host or localhost)

This directory contains the SNO development tooling. Run the
`make osac-dev-*` targets from the repository root; they dispatch to these
scripts without requiring a directory change. The workflow runs either against a
remote cluster-tool host over root SSH or on this machine; see
[Target selection](#target-selection).

## Layout

- `osac-dev-workflow.sh`: preflight and ordered full deployment.
- `osac-dev-setup.sh`: installs missing prerequisites (see
  [Installing prerequisites](#installing-prerequisites)).
- `osac-dev-bootstrap.sh`, `osac-dev.sh`, `osac-dev-install-cluster-tool.sh`:
  cluster lifecycle and cluster-tool setup.
- `osac-dev-install-infra.sh`: kubeconfig setup, infrastructure installation,
  and upgrade-free infrastructure verification.
- `osac-dev-snapshot.sh`: infra-only snapshot factory and restore smoke check.
- `osac-dev-helm.sh`: shared Helm 3/4 release-listing compatibility.
- `osac-dev-bmh.sh`, `osac-dev-nic.py`, `osac-dev-provisioning.sh`: virtual BMH
  setup, safe guest-NIC discovery, and shared Ironic prerequisites.
- `osac-dev-deploy.sh`: branch-image builds and OSAC deployment.
- `osac-dev-dns.sh`, `osac-dev-dns-remote.py`: persistent host-side lab DNS,
  NTP resolution, MetalLB pool and inter-bridge forwarding prerequisites.
- `osac-dev-target.sh`: the single host seam. Owns the target selection, the
  root and transport guards, and every `ssh`/`scp` invocation; all other scripts
  call its `osac_dev_host_*` functions instead of touching SSH directly.
- `osac-dev-e2e.sh`, `osac-dev-grow-storage.sh`, `osac-dev-help.sh`: test runner,
  storage convergence, and quick-reference help.
- `tests/`: offline unit and contract tests; run with `make osac-dev-test`.

## Target selection

`REMOTE_HOST` selects where the workflow runs. It is the only selector; there is
no separate mode variable.

| `REMOTE_HOST` | Target | Host operations run |
|---|---|---|
| unset, empty, or `localhost` | localhost (`this host`) | on this machine, directly |
| any other value, e.g. `root@host.example` | remote (`root@host.example`) | on that host over root SSH |

Loopback values such as `127.0.0.1` and `::1` are treated as remote, so
SSH-to-self keeps working exactly as before. `OSAC_DEV_TARGET` and
`OSAC_DEV_TARGET_DESCRIPTION` are derived from `REMOTE_HOST` and are available to
the scripts and to status/help output; setting `OSAC_DEV_TARGET` yourself fails
with `OSAC_DEV_TARGET is derived from REMOTE_HOST and cannot be set`.

Both targets require root, because `cluster-tool`, libvirt and the host DNS
helper are privileged. The localhost target checks `id -u` on this machine; the
remote target checks it on the host. There is no opt-in flag for either mode.

The localhost target only simplifies the **access paths**, because the machine
that runs `make` is also the machine that owns the lab bridges, the cluster
kubeconfig, the DNS helper and the MetalLB VIP networks:

- the cluster-tool kubeconfig is used as-is: no API endpoint rewrite, no TLS SNI
  pin, no temporary SSH tunnel and no `OSAC_DEV_LOCAL_API_PORT`;
- hosted-cluster routes and MetalLB VIPs are reached directly: no SSH SOCKS
  proxy, no `HTTPS_PROXY`/`NO_PROXY` injection and no `/etc/hosts` mount
  namespace;
- the host DNS helper is installed and run locally at
  `/usr/local/sbin/osac-dev-dns` (override with `OSAC_DEV_DNS_HELPER`);
- `ssh` and `scp` are not required.

The lab topology is the same in both modes: libvirt networks and bridges,
dnsmasq listeners, the MetalLB pool, the `br-bmh` secondary bridge and the
host-side DNS helper's desired state are unchanged. Remote-only knobs are
ignored with an informational message on the localhost target:
`OSAC_DEV_API_HOST`, `OSAC_DEV_LOCAL_API_PORT` and `OSAC_DEV_E2E_SSH_HOST`.

Every example below prefixes the command with `REMOTE_HOST=root@host`. Omit that
prefix — or set `REMOTE_HOST=localhost` — to run the same command on this
machine. Destructive targets stay scoped to `<DEV_ENV_NAME>-dev` in both modes.

## Roadmap

These are future improvements, not capabilities of the current workflow. The
sequence below is intended; implementation details and delivery dates remain
open.

1. **Extend the snapshot factory.** The basic
   [infra-only factory](#infra-only-snapshot-factory) now prepares a new or
   existing SNO, captures it, and boots a validation clone. Add recorded source/chart provenance,
   automated credential sanitization, and complete application identity and
   endpoint validation across restores before treating a flavor as generally
   distributable. The existing smoke check is not that broader guarantee.

2. **Add content-aware image build caching.** First calculate the effective
   inputs for each image; only then decide whether a cached result is safe to
   reuse. The cache key must account for all inputs that affect the artifact,
   including its actual build-context contents, Containerfiles, dependency and
   lock files, build arguments, base-image digests, and generated build
   contexts such as the AAP execution environment. Rebuild when any relevant
   input changes, including uncommitted source changes. Choose local versus
   registry-backed cache storage after defining the input calculation and
   invalidation contract; build correctness takes priority over cache hits.

3. **Support a dedicated KubeVirt cluster for virtual BMHs.** Allow virtual
   BMH/Ironic workloads to run on a dedicated KubeVirt/OpenShift Virtualization
   cluster rather than coupling them to the OSAC SNO cluster. Define the
   cluster boundary, provisioning and control-plane connectivity, storage and
   DHCP prerequisites, capacity expectations, and lifecycle/cleanup ownership.

4. **Reuse existing cluster(s).** Extend reuse beyond the current
   cluster-tool-managed SNO with a matching `DEV_ENV_NAME`: let developers
   explicitly target one or more existing, potentially user-managed clusters.
   Add per-target capability checks and idempotent installation, and ensure
   teardown only removes workflow-owned resources—not borrowed clusters.

5. **Evaluate KubeVirt Redfish as a future BMC backend.** Pilot
   [`kubevirt/redfish-controller`](https://github.com/kubevirt/redfish-controller)
   alongside the current KubeVirtBMC integration. Validate Metal3/Ironic
   compatibility for virtual-media boot, power and boot controls, credentials,
   and complete provision/deprovision cleanup; assess its asynchronous task and
   conflict-retry behavior, and upstream maturity, release, and support status
   (see [VEP 0176](https://github.com/kubevirt/enhancements/issues/176)). Keep
   KubeVirtBMC as the current default until the pilot passes and the upstream
   release path is clear; this is not a chart-only swap.

## Installing prerequisites

`make osac-dev-setup` installs what the workflow needs instead of only naming it,
in both target modes and without prompting:

| Scope | Installed when missing | Notes |
|---|---|---|
| workstation (always on this machine, both targets) | Helm at the version pinned in `.github/helm-version`, in `~/.local/bin`, Skaffold, a `docker`→`podman` shim, the rootless `podman.socket` | never needs root; `OSAC_DEV_HELM_VERSION` overrides the Helm pin for a one-off run, `OSAC_DEV_SKAFFOLD_VERSION` pins Skaffold (default `latest`) |
| cluster host | `python3 git make curl tar dnsmasq nftables NetworkManager chrony libvirt-client podman`, then `cluster-tool` | over `dnf`, only when this script already has root there; libvirt, QEMU, podman, HAProxy, firewall and storage are left to cluster-tool's first `connect local` |

Every step is idempotent and only touches what is missing, so it is safe to run
before each workflow run. Helm is installed only when `helm version --short`
does not already report the pinned version; a stale version is replaced in
`~/.local/bin`, or reported as a manual step when it cannot be downloaded. The
pin and the reason for it are in [Helm version](#helm-version).

Every wrapper that runs Helm or Skaffold (`make osac-dev`, `-deploy`, `-dev`,
`-install-infra`, `-kubeconfig`, `-bmh` and `-e2e`) prepends `~/.local/bin` to
`PATH`, so the versions this target installed win over a system copy. A Helm in
`/usr/bin` or `/usr/local/bin` is left installed and untouched; it is simply no
longer the one the workflow resolves. Run `bash tools/osac-dev/osac-dev-help.sh`
for the current target order and environment variables.

```bash
make osac-dev-setup             # install what is missing
make osac-dev-setup DRY_RUN=1   # print the plan, change nothing
```

It never runs `sudo` and never stores credentials. When the cluster host needs
packages and the script does not have root there, it prints the exact command
instead of failing silently:

- localhost target, non-root caller:
  `sudo dnf install -y <missing>` — or re-run `make osac-dev-setup` as root;
- remote target: `dnf install -y <missing>` on `REMOTE_HOST` as root.

After the install steps it re-checks the commands the targets use (`oc`,
`kubectl`, `helm`, `go`, `uv`, Skaffold, the container CLI, plus `ssh`/`scp` for
a remote target) and lists everything it cannot install itself, then exits
non-zero while anything is still missing. Registry login stays manual:
`podman login quay.io` (or the host of `OSAC_DEV_REGISTRY`).

Run through `sudo` in localhost mode, it skips the workstation scope with a
message, because `$HOME` would otherwise be root's home and the build tooling
would land where the developer cannot use it. Run `make osac-dev-setup` without
`sudo` for those pieces and with `sudo` for the host packages.

## Full workflow

`make osac-dev` automatically runs preflight: it prompts for missing required
inputs and validates prerequisites, then runs
**cluster → grow-storage → install-infra → bmh → deploy → dns**, stopping on
failure. Both SNO disks are grown to at least **200 GiB** before infrastructure
installation. DNS is configured from the current clone's networks, not persisted
addresses from a previous boot.
There is no need to run `make osac-dev-check` first.
Neither command persists your answers; export inputs to reuse them.

```bash
export REMOTE_HOST=root@your-host.example
export PULL_SECRET_FILE=/absolute/path/to/pull-secret.json
export OSAC_DEV_REGISTRY=quay.io/your-user
export OSAC_DEV_LICENSE_REMOTE=/root/license.zip
# Alternatively export OSAC_DEV_LICENSE_FILE=/absolute/local/license.zip (0600).
# With the localhost target the default is /root/license.zip on this machine, so
# either variable works without a copy.
# Log in to the registry with the same container CLI Skaffold uses.
make osac-dev
```

For an **optional preflight-only check**, run `make osac-dev-check`. It validates
inputs and prerequisites (including read-only SSH checks for a remote target)
without deploying.
A later `make osac-dev` repeats preflight automatically; the check does not
cache results or skip validation on the deployment run.

The full workflow requires a valid pull secret even when reusing a cluster,
so a later rebuild cannot unexpectedly require one. Local tools and container
daemon availability, root access on the selected target, license
availability/permissions, and input formats are checked before mutation. Registry push authorization, remote
capacity, downloads, DNS and eventual cluster/operator readiness can still fail
at runtime. Existing confirmation prompts for remote preparation remain.
Individual targets do not prompt for the full workflow configuration.

No guest NIC name is required up front. After the cluster and CNV are ready,
the BMH stage inspects the SNO's links, IPv4 addresses and routes using
`oc debug`, before changing node networking or installing BMH resources. It
selects the sole connected, addressed secondary guest Ethernet NIC, excluding
the node's InternalIP interface, its preferred default route, equally preferred
routes, and ports of other bridges/bonds (including OVS). A higher-metric
secondary default route is allowed. An existing `br-bmh` port can be reused.
If there are no safe candidates or the choice is ambiguous, it stops with
interface diagnostics rather than guessing. `OSAC_DEV_BMH_NODE_NIC` can
select among multiple safe candidates and receives the same safety checks.
Discovery does not prove DHCP service for the future BMH VMs; that remains a
lab-network prerequisite.

BMH now initializes Ironic before OSAC installation; deploy preserves the bridge
addresses configured by BMH. This only reorders existing lab prerequisites: it
does not implement or alter the accepted Unified/BMaaS tenant networking APIs
(OSAC-1433/OSAC-1437).

## Cluster-only workflow

The `osac-dev-cluster` Make target prepares one remote `cluster-tool` host and boots or
reuses a single SNO cluster from
`quay.io/osac-project/cluster-flavors:sno-4-22`. It saves a local kubeconfig
for the selected cluster, but does not install OSAC services, infrastructure
charts, CNV, or other development workloads. Both SNO clone disks are grown to
at least 200 GiB automatically; workload installation is a separate step.

Before fetching kubeconfig or probing the API, access setup installs the current
host DNS helper and checks the selected clone's DNS/DHCP listeners. Missing
listeners are restored from the original libvirt configurations without touching
running listeners or restarting networks. This also runs for
`make osac-dev-kubeconfig` and standalone `make osac-dev-install-infra`; it does
not require Kubernetes, NTP discovery, a registry login or an AAP license.

```bash
REMOTE_HOST=root@your-host.example \
PULL_SECRET_FILE=/path/on/your/workstation/pull-secret.json \
make osac-dev-cluster
```

`REMOTE_HOST` must connect as root because `cluster-tool`'s local server setup
and cluster operations require root. `PULL_SECRET_FILE` is a path on the
workstation running `make`, not on the remote host. If the selected cluster is
missing, the workflow copies the secret via `scp` into a mode-restricted
temporary directory on the remote host, uses it to boot the cluster, and removes
the temporary copy. The pull-secret contents are not printed or committed. An
already-running cluster is reused without requiring or copying a pull secret.

## Cluster name

`DEV_ENV_NAME` is a 1–4 character lowercase alphanumeric slug (default: `osac`).
The cluster-tool ID is `<DEV_ENV_NAME>-dev`, which is `osac-dev` by default. For
example, `DEV_ENV_NAME=lab` uses `lab-dev`. Use a different slug for each
independent development cluster on the same host.

## Lifecycle

- `make osac-dev-cluster` prepares the remote host and boots a new SNO only if the
  selected cluster ID is missing. Any existing cluster with that ID is reused,
  regardless of its recorded flavor; the cluster's current flavor is reported.
- `make osac-dev-status` reports the selected cluster and its actual flavor.
- `make osac-dev-down` asks for local confirmation and destroys only the
  selected cluster. It leaves unrelated clusters and pulled flavor images alone.

On first setup, the workflow asks locally before configuring
dnsmasq/NetworkManager on the remote host, running `cluster-tool connect` (which
installs/configures the VM host packages and services), or pulling the SNO flavor
image. The dnsmasq setup restarts NetworkManager and may briefly interrupt SSH;
the workflow waits for the host to reconnect and resumes preparation when
possible.

The selected cluster ID is the reuse key. If it already exists with a different
flavor (for example, a CaaS cluster left by the former paired-cluster workflow),
`make osac-dev-cluster` does not provision another cluster or replace the existing one.
Use `make osac-dev-install-infra` to update the supported infrastructure
workloads on that cluster.

## Flavor and storage

`SNO_FLAVOR` defaults to `sno-4-22` and can be overridden. The image is pulled
from `quay.io/osac-project/cluster-flavors`. `CLUSTER_TOOL_DATA_PATH` defaults
to `/data/cluster-tool` on the remote host; use storage with enough free space
for the flavor image and cluster disk. Ensure the remote host has the CPU and
RAM required by the selected flavor.

## Infra-only snapshot factory

`make osac-dev-snapshot` creates a **new local cluster-tool flavor** containing
`osac-deps`, `osac-infra`, and CNV, but no OSAC platform release. It does not run
BMH setup, build branch images, install AAP workloads, or push the snapshot.
The selected builder can be an existing cluster-tool-managed SNO: no special
creation-time flag or snapshot-specific provisioning is required. It defaults
to `osac-dev` (`DEV_ENV_NAME=osac`). If missing, it is booted first.

```bash
REMOTE_HOST=localhost \
PULL_SECRET_FILE=/absolute/path/to/pull-secret.json \
make osac-dev-snapshot SNAPSHOT_NAME=osac-caas-infra-v1
```

Use `REMOTE_HOST=root@host` instead for a remote cluster-tool host. Prerequisites
are root access on the selected host, a working cluster-tool `local` server
registration there, `oc`, Helm, Make, Python 3, and a valid local pull-secret
file. Use `make osac-dev-setup` to install missing tools; if the host has not
been connected yet, run `cluster-tool connect local --host local
--data-path /data/cluster-tool` on it first. Existing bootstrap preparation
prompts still apply. No `OSAC_DEV_REGISTRY`, container build daemon, Skaffold,
or AAP license is required for this target.

The workflow is deliberately separate from `make osac-dev`:

1. Refuse existing validation clone and flavor names. An existing builder is
   allowed. A host/list failure is fatal, not interpreted as an empty host.
2. Reuse `<DEV_ENV_NAME>-dev` if present, regardless of its recorded flavor;
   otherwise boot it from `SNO_FLAVOR` (default `sno-4-22`). Fetch its kubeconfig
   and reject an installed OSAC platform Helm release before changing storage
   or infrastructure. Nothing is uninstalled to make the cluster infra-only.
3. Inspect **both disks**. If both are already at least **200 GiB** (or the
   configured target), skip the entire storage growth helper, including guest
   filesystem/LVMS operations. Otherwise use the existing grow-only host/guest
   helper. Then install/update the `caas-ci` deps/infra profile with
   `infra-cnv.yaml`, using the normal version/CNV-based skip checks.
4. Confirm both disk capacities through libvirt without resizing. Require
   the selected node and API to be ready, ClusterOperators available,
   not progressing and not degraded, workload rollouts complete in the profile's
   infrastructure namespaces, CNV and Kafka ready, and retained infrastructure
   hook Jobs complete. An OSAC platform Helm release is rejected. Verify the
   expected Helm versions and CNV state again without performing upgrades.
5. Run `cluster-tool snapshot --server local --source <builder>-dev
   --name <SNAPSHOT_NAME>` on the host. cluster-tool gracefully shuts down the
   builder, flattens all its disks, and restarts it. **Expect builder downtime.**
6. Boot a second clone from the new flavor, fetch its own kubeconfig, repeat
   the health checks, and verify Helm/CNV **without installing or upgrading
   anything**. No disk growth runs on this validation clone to conceal a bad
   capture. Only then print `Reusable snapshot verified`.

| Input | Default / behavior |
|---|---|
| `SNAPSHOT_NAME` | Required, new versioned flavor name; never overwrite |
| `DEV_ENV_NAME` | `osac`, builder slug (1–4 lowercase alphanumeric characters), producing cluster `osac-dev` |
| `OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME` | `svfy`, distinct fresh validation slug |
| `SNO_FLAVOR` | `sno-4-22`, clean base used only when the builder is missing |
| `OSAC_DEV_DISK_TARGET` | `200G`, minimum 200 GiB on each builder disk |
| `OSAC_DEV_SNAPSHOT_TIMEOUT` | `1800`, 1–7200 seconds per health wait |
| `OSAC_DEV_KUBECONFIG` | Builder kubeconfig; validation always uses `~/.kube/<validation>-dev.kubeconfig` |

Plan host capacity for **two SNO VMs at once**, plus the flattened flavor disks.
An inherited `OSAC_DEV_KUBECONFIG_ONLY` or `OSAC_DEV_INFRA_CHECK_ONLY` cannot
bypass the factory stages. The builder and validation clone remain on success
or failure (subject to cluster-tool's own failed-boot rollback). Nothing
existing is removed; a failed validation leaves the candidate flavor
**unvalidated**. For another run you can reuse the same builder, but choose a
new flavor name and a fresh validation name, or explicitly clean up the old
validation clone first.

Remove the disposable validation clone later with the same `REMOTE_HOST`:

```bash
make osac-dev-down DEV_ENV_NAME=svfy
```

The builder may have existed before the snapshot run. It is **not** automatically
owned or deleted by the factory. Only run `make osac-dev-down DEV_ENV_NAME=osac`
if you explicitly intend to destroy that builder and its workloads.

The flavor is retained separately. To boot another development environment on
that host from it, use `SNO_FLAVOR=osac-caas-infra-v1 DEV_ENV_NAME=dev1
make osac-dev-cluster`. No registry pull is needed while the flavor is local.

**Security and validation boundary:** a flavor contains disk-resident
credentials, CA signing keys, and SSH private material. These snapshots are
private development artifacts, not sanitized distributable images. Publishing
requires a separate explicit decision and an appropriately restricted registry.
The restore smoke check exercises real API/workload/Helm/CNV health when run on
a real host; it does not prove every Keycloak/OpenBao identity or endpoint was
rewritten, guest filesystem/LVMS sizes survived capture, guest network
connectivity, or CaaS provisioning. Those require live guest disk inspection,
application checks and the existing CaaS E2E journey before promoting a baseline for wider reuse. Record
the checkout revision and local changes with your chosen versioned flavor name;
chart versions alone do not detect unversioned chart-content changes.

## Infrastructure workloads

`make osac-dev-cluster` creates or reuses the cluster and then saves its local kubeconfig.
For an already-running cluster, `make osac-dev-kubeconfig` fetches or refreshes
the kubeconfig without changing workloads. `make osac-dev-install-infra` also
refreshes the kubeconfig before installing or updating infrastructure:

```bash
REMOTE_HOST=root@your-host.example make osac-dev-install-infra
```

The persistent kubeconfig defaults to
`~/.kube/<DEV_ENV_NAME>-dev.kubeconfig` (for example,
`~/.kube/osac-dev.kubeconfig`) and is mode 0600. Set `OSAC_DEV_KUBECONFIG` to
choose another absolute file path. Make cannot export `KUBECONFIG` into the
calling shell, so use the printed path with `export KUBECONFIG=...` or prefix an
`oc` command with `KUBECONFIG=...`.

With a **remote target**, the installer fetches
`/root/.kube/<cluster-id>.kubeconfig` over SSH (override the host path with
`OSAC_DEV_HOST_KUBECONFIG`), then uses the SSH-reachable host address for the API
endpoint while preserving the original API hostname for TLS/SNI. If direct API
access on port 6443 is unavailable, it opens a temporary SSH tunnel (local port
16443 by default). Set `OSAC_DEV_API_HOST` to override the host address for NAT
or multihomed hosts, or `OSAC_DEV_LOCAL_API_PORT` to choose a different tunnel
port. The temporary transfer file and tunnel are removed when the command exits;
the persistent kubeconfig remains available for later `oc` commands.

With the **localhost target**, the cluster-tool kubeconfig at
`/root/.kube/<cluster-id>.kubeconfig` (or `OSAC_DEV_HOST_KUBECONFIG`) is copied
unchanged: there is no API endpoint rewrite, no TLS SNI pin and no tunnel,
because this machine already reaches the API, the hosted-cluster routes and the
MetalLB VIPs directly. `OSAC_DEV_API_HOST` and `OSAC_DEV_LOCAL_API_PORT` are
ignored with an informational message. If the API is unreachable, the command
fails with the local remedies (`make osac-dev-dns`, `make osac-dev-kubeconfig`)
instead of falling back to a tunnel.

API readiness polling returns immediately on success and otherwise allows
`OSAC_DEV_API_RECOVERY_TIMEOUT` seconds (default **900**, valid range 1–3600).
It reports progress every 30 seconds. The same budget applies on reruns even
when DNS was already restored by a previous command: NetworkManager can back
off DHCP for five minutes, followed by control-plane recovery. A live recovery
took 441 seconds, exceeding the former 300-second budget. For a different bound,
export the timeout before invoking an access/provisioning target.

The machine running `make` must have `ssh` and `scp` for a remote target, or
neither for the localhost target, plus `oc`, Helm, Make, and Python 3. With the
localhost target, `cluster-tool`, libvirt and the host DNS helper run there too,
so the cluster-tool host prerequisites below apply to this machine.
The install phase uses the `caas-ci` infrastructure profile with the
`values/osac-dev/infra-cnv.yaml` overlay, which enables CNV on the `stable`
channel. It installs or updates only the `osac-deps` and `osac-infra` Helm
releases; it does not install the `osac` platform chart.

The operator subscriptions that `osac-deps` creates (LVMS, CNV, MCE, MetalLB)
install their CRDs asynchronously, so a chart that also declares one of them
meets an object Helm did not create. Helm refuses to adopt it
(`exists and cannot be imported into the current release ... missing key
"meta.helm.sh/release-name"`), which would otherwise wedge every rerun on that
cluster. With `OSAC_DEV_ADOPT_CRDS` set to **1** (the default), the tool labels
and annotates each such object for the named release — the same effect as
`helm --take-ownership` — and retries `install-infra`, up to three attempts.
This covers any kind Helm refuses to import, not only CRDs. Each adoption is
logged with the kind, name and release name. Set `OSAC_DEV_ADOPT_CRDS=0` to
surface the failure with the manual `oc label` / `oc annotate` remedy instead.

The full Helm output of a failed `install-infra` run is kept at
`${OSAC_DEV_INSTALL_LOG:-/tmp/osac-dev-install-infra.log}`, and the failure
message names its cause: an ownership conflict that was adopted, an adoption
that could not be applied, or an unrelated Helm failure (with the log's own
`Error:` lines repeated at the end). Set `OSAC_DEV_INSTALL_LOG` to keep it
somewhere else.

Before upgrading, the installer compares each deployed Helm chart version with
its local `Chart.yaml` version (currently `0.0.1` for both charts) and checks
that the CNV Subscription uses `stable`, its current CSV is `Succeeded`, and the
HyperConverged resource is Available. If versions or readiness differ, it runs
the OpenShift `install-infra` phase and verifies the result. This comparison
cannot detect chart-content changes without a chart version bump; handling that
drift is deferred to the later content-update process. CNV follows the `stable`
channel rather than a pinned operator CSV version.

For an upgrade-free verification, use
`OSAC_DEV_INFRA_CHECK_ONLY=1 make osac-dev-install-infra`. It still refreshes
access/DNS/kubeconfig, but a release or CNV mismatch fails rather than running
Helm upgrades. It is mutually exclusive with kubeconfig-only mode. The snapshot
factory uses this mode before capture and after restore.

The base `make osac-dev-cluster` workflow prepares and boots/reuses the cluster, then
saves its local kubeconfig. The infra target is deliberately separate so the
base SNO can be recycled independently of its configured workloads. The upstream
`cluster-tool` currently has no supported advertised-IP override; this workflow
does not patch it and does not change its host-side DNS configuration.

## OSAC platform deployment (branch code)

`make osac-dev-deploy` installs or updates the `osac` platform Helm chart on the
selected cluster with every OSAC-owned image built from the current checkout
— uncommitted changes included — pushed to the personal quay.io namespace, and
deployed digest-pinned. It produces the same release shape as
`make install-osac PLATFORM=openshift PROFILE=caas-ci NS=osac`, but with
branch-built images instead of published ones.

### Prerequisites

- `make osac-dev-cluster` (cluster plus local kubeconfig) and
  `make osac-dev-install-infra` (osac-deps, osac-infra, CNV).
- podman with the user socket: `systemctl --user start podman.socket`.
  A `docker` shim is also required in `~/.local/bin` (`exec podman "$@"`):
  skaffold.yaml sets `build.local.useDockerCLI: true`, so builds run through
  the docker CLI because rootless podman's Docker-compat API cannot build
  from tar contexts that record the host user's UID (`lchown ... invalid
  argument`); the podman CLI handles directory contexts natively. Pushes and
  image inspection still use the API via `DOCKER_HOST`. If socket builds ever
  fail with UID-mapping errors, run `podman system migrate` (note: it stops
  and re-maps running containers, including any kind cluster nodes).
- `podman login quay.io` as the `rh_ee_rpiccoli` account
  (default `OSAC_DEV_REGISTRY=quay.io/rh_ee_rpiccoli`).
- Skaffold v2.25+ in `~/.local/bin` (`make osac-dev-setup` installs it), or
  manually:

  ```bash
  curl -Lo /tmp/skaffold https://storage.googleapis.com/skaffold/releases/latest/skaffold-linux-amd64 && install -m 0755 /tmp/skaffold ~/.local/bin/skaffold
  ```

  The config uses `apiVersion: skaffold/v3`; the released binary does not
  accept the v4 headers shown on skaffold.dev.
- Helm, at the version pinned in `.github/helm-version`, which
  `make osac-dev-setup` installs (see
  [Helm version](#helm-version)). The shared installer selects the apply flags
  from `helm version --short`; Skaffold receives the same flags as a direct
  Helm installation.
- The AAP license at `/root/license.zip` on `REMOTE_HOST`. It is fetched once
  over SSH into the gitignored `osac-installer/values/osac-dev/license.zip`
  (mode 0600); afterwards `REMOTE_HOST` is no longer needed. With the localhost
  target the same path is read in place, and an unreadable file fails with a
  hint to place it manually or set `OSAC_DEV_LICENSE_REMOTE`; nothing is staged
  or removed.

### Usage

```bash
REMOTE_HOST=root@host make osac-dev-deploy   # one-shot build + push + helm upgrade --install osac
make osac-dev-dev                            # watch mode: skaffold dev rebuilds and redeploys on file changes
```

### What it deploys

The wrapper calls `make -C osac-installer install-osac PLATFORM=openshift
PROFILE=caas-ci NS=osac DEV_MODE=1`, adding the `osac-dev/aap-noop-dns.yaml`
overlay. The installer resolves the chart, namespace, ordered values files,
hostnames, deployment ID and Helm flags once. A private temporary Skaffold
configuration combines those settings with the branch-built images below;
one-shot and watch use the same configuration, with only the Skaffold command
(`run` or `dev`) differing. Normal installation keeps direct Helm and does not
require Skaffold or uv.

| Artifact | Build | Helm image key |
|---|---|---|
| fulfillment-service | Containerfile, context `.` | `service.images.service.{repository,tag}` |
| osac-operator | Containerfile, context `.` | `operator.image.{repository,tag}` |
| bare-metal-fulfillment-operator | Containerfile, context `.` | `bmf.image.{repository,tag}` |
| metering-service | Containerfile, context `.` | `metering.image.{repository,tag}` |
| metering echo adapter | `osac-metering/adapters/Containerfile.echo-adapter`, context `.` | `metering.echoAdapter.image.{repository,tag}` |
| osac-csi-driver | Containerfile, context `.` | `csiDriver.image.{repository,tag}` |
| osac-ui | Containerfile, context `osac-ui` | `ui.images.ui` |
| osac-aap EE | ansible-builder-generated context | `aap.bootstrap.image` and `aap.configAsCode.eeImage` |

The AAP EE image fills two Helm keys (`aap.bootstrap.image` and
`aap.configAsCode.eeImage`).

### Behavior details

- The wrapper (`tools/osac-dev/osac-dev-deploy.sh`) validates the kubeconfig
  and osac-deps/osac-infra releases, fetches a missing license, prepares the
  Metal3 Provisioning CR and local build inputs, then delegates to the installer.
  The installer owns namespace and `config-as-code-manifest-ig` Secret creation,
  PostgreSQL prerequisite checks, chart dependencies and cluster-domain discovery.
  The wrapper no longer carries a second copy of those installation commands.
- `skaffold.yaml` is a build/image-mapping template, not a standalone deployment
  configuration. The adapter uses mode-0600 temporary JSON and removes it on
  success or failure. On Ctrl-C or SIGTERM, it forwards the signal and waits
  for Skaffold's graceful shutdown before removing the file. License contents
  are not embedded in this configuration.
  Restart watch mode after changing installer arguments or the build template;
  the generated deployment settings are a snapshot of that invocation.
- The AAP EE custom builder (`tools/osac-dev/osac-dev-build-ee.sh`) runs
  `ansible-builder create` into a fresh temporary directory before each image
  build and removes it afterwards. Skaffold watches the original collections,
  vendor content, EE definition, compiled requirements and build helper, so
  edits trigger regeneration in watch mode as well as on repeat deployments.
  Generated context files are not watched or reused; deleted source files
  cannot linger in subsequent images. If `osac-aap/pyproject.toml` changed,
  recompile requirements first (`uv pip compile`, see
  `osac-aap/execution-environment/README.md`).
- The infra check is existence-only (`helm status`); a release in a
  non-deployed state is not detected — known limitation.

### quay housekeeping

Pushed images auto-create repositories in the personal quay namespace, which
default to **private**. The cluster has no pull credentials for them, so the
first deployment blocks in `ImagePullBackOff` until every repository
(`fulfillment-service`, `osac-operator`, `bare-metal-fulfillment-operator`,
`metering-service`, `metering-echo-adapter`, `osac-csi-driver`, `osac-ui`,
`osac-aap-ee`) is flipped to public in the quay web UI — OSAC is open source,
so public images are acceptable — or a pull robot/secret is wired in instead.
The quay docker-login token cannot change visibility through the API
(CSRF-protected), so this is a manual step.

### Registry transition

Set `OSAC_DEV_REGISTRY` (the wrapper passes it as Skaffold's
`--default-repo`) to move to another registry later; no other changes are
needed.

### Maintenance note

Skaffold upstream is in maintenance (repository archival announced for
2027-01; releases remain available). The pipeline is a thin declarative layer;
the wrapper and Make targets are tool-agnostic.

### Helm version

Helm has one pin for every surface that installs it: `.github/helm-version`.
CI jobs install it through `.github/actions/setup-helm`, `make osac-dev-setup`
installs or replaces it, and `fulfillment-service/scripts/setup-e2e-tools.sh`
installs the same version. Bumping the file moves all of them together;
nothing else carries a Helm version literal, and `OSAC_DEV_HELM_VERSION`
overrides the pin locally for a one-off run.

The pin was checked against this repository before it was adopted:
`helm template` renders the same objects, with identical content, for `osac`
(164 objects), `osac-deps` (32) and `osac-infra` (130) on `v3.16.3` and
`v4.3.1`; `helm lint` gives the same result per chart on both; `helm list
--output json` keeps the fields `release_state()` reads; and every subcommand
the tooling uses (`upgrade --install`, `status`, `list`, `uninstall`,
`dependency build`, `package`, `push`, `registry login`, `show chart`,
`get manifest`) still exists in the 4.x line. `--wait` alone still means the
full readiness wait, which is what the targets pass.

Release listing also differs between versions: Helm 3 requires `list --all`
to include every release state, while Helm 4 includes every state by default
and **rejects `--all`**. The snapshot and infrastructure wrappers share
`osac-dev-helm.sh`, which selects the correct form from `helm version --short`.
This keeps failed and pending releases visible instead of silently treating
them as absent. The shell test doubles validate the flags and Helm 3 status
filtering in both wrappers. Both listing forms were additionally checked with
the real `v3.16.3` and `v4.3.1` CLIs using `--help`; that verifies argument
acceptance without contacting Kubernetes, not deployed release discovery.

Helm 4 applies server-side by default and then refuses to change fields another
controller owns. The AAP operator owns `app.kubernetes.io/managed-by` on the
`osac-aap` CR, so `osac-installer/Makefile` adds `--force-conflicts` when
`HELM_MAJOR` is 4. The Skaffold adapter receives that same argument; there is
no separate Helm-version profile to maintain. Helm 3 never receives the flag.
`DEV_MODE=1` rejects unreadable or unsupported Helm majors before installation.

The pin is a default, not a restriction: `OSAC_DEV_HELM_VERSION=v4.4.0 make
osac-dev-setup` installs a different version, and the deploy wrapper adapts to
the supported major (3 or 4) that resolves on `PATH`. A stale Helm in `~/.local/bin` is
replaced by the install; when the download is impossible, setup lists it as a
remaining manual step and exits non-zero instead of silently leaving the old
version in place.

### Troubleshooting

- Platform-mismatch errors on deploy can require
  `--check-cluster-node-platforms=false`.
- The AAP bootstrap hook job can take several minutes; Helm `--wait` with
  `--timeout 40m` covers it. If the timeout fires while pods sit in
  `ImagePullBackOff` (for example, private quay repos before the housekeeping
  step above), fix the cause and simply rerun `make osac-dev-deploy`; the
  release upgrades in place and the images are already built and pushed.
- The Metal3 admission webhook rejects a bare `Provisioning` CR (Managed
  mode requires `provisioningIP` and a DHCP range); the wrapper applies the
  e2e-compatible spec (`provisioningNetwork: Disabled`, virtual media only,
  node InternalIP) automatically.
- Strict YAML consumers (skaffold's helm post-renderer) reject duplicate
  mapping keys that Helm itself tolerates; the bmf chart's duplicated
  `control-plane` label was removed for this reason.
- Watch-mode rebuild latency is higher for the six artifacts sharing the
  monorepo build context `.`; dependency resolution limits rebuilds to files
  actually COPYed into each image.
- `make osac-dev-setup` ends with `Helm <version> at <path> does not match the
  pinned <pin>`: the download failed (no network, or no `curl`/`tar`). Install
  `https://get.helm.sh/helm-${pin}-linux-amd64.tar.gz`, where `<pin>` is the
  content of `.github/helm-version`, into `~/.local/bin` by hand, or set
  `OSAC_DEV_HELM_VERSION` to the version you do have.
- Do not run `skaffold run` directly against the checked-in build template.
  Use `make osac-dev-deploy` or `make -C osac-installer install-osac DEV_MODE=1`
  with the required installer inputs so namespace, values and Helm flags stay
  aligned with normal installations.
- `osac-infra` failing with `CustomResourceDefinition ... exists and cannot be
  imported into the current release` (or any other kind) means an object
  arrived from an operator instead of from Helm. The default
  `OSAC_DEV_ADOPT_CRDS=1` adopts it and retries; see
  [Infrastructure workloads](#infrastructure-workloads) for the manual
  `oc label`/`oc annotate` remedy when adoption is disabled. Any other
  `install-infra` failure is reported as *not* an ownership conflict: read the
  `Error:` lines the wrapper repeats, or the full log it names.

## Virtual bare-metal hosts (CNV)

`make osac-dev-bmh` creates virtual bare-metal hosts on the selected cluster
for BMaaS (and CaaS-over-BMaaS) development. It is the CNV counterpart of
osac-test-infra's `setup-virtual-bmh.sh` (libvirt VMs + sushy-tools on the
cluster-tool host): each host is a KubeVirt `VirtualMachine` managed through
[KubeVirtBMC](https://kubevirtbmc.io/), which serves a per-VM Redfish BMC that
Ironic drives exactly like physical hardware — inspection and provisioning go
through Redfish virtual media, so no PXE/provisioning network is involved
(the shared Provisioning prerequisite initialized by BMH or deploy runs Ironic with
`provisioningNetwork: Disabled`).

### Prerequisites

- `make osac-dev-cluster` (cluster plus kubeconfig), `make osac-dev-install-infra`
  (CNV). BMH activates Ironic through the Provisioning CR and waits for
  its pods; the OSAC platform release is not required yet.
- Local `oc` and Helm; no remote-host access is needed.

The tool itself installs the KubeVirtBMC Helm release (pinned chart version,
namespace `kubevirtbmc-system`) if it is missing, enables CNV's
`declarativeHotplugVolumes` feature gate through the HyperConverged CR when
absent — a cluster-wide change to the (dev-preview) declarative volume-hotplug
API that KubeVirtBMC's Redfish virtual media requires — and bridges the VMs
onto the node's secondary lab NIC so Ironic can reach the agents (see
Limitations). Both the release and the gate stay installed after
`make osac-dev-bmh-clean`.

### Usage

```bash
make osac-dev-bmh         # create the hosts (default 2) and wait until available
make osac-dev-bmh-clean   # delete hosts, VMs, BMCs, disks, and secrets
```

Pass `OSAC_DEV_BMH_COUNT=<n>` for a different number of hosts (1–15; note the
SNO has ~30 Gi of unrequested memory, so at most three 8Gi hosts fit
comfortably). Other knobs: `OSAC_DEV_BMH_NAMESPACE` (default
`host-inventory`), `OSAC_DEV_BMH_PREFIX` (default `virtual-bmh`),
`OSAC_DEV_BMH_CPU` / `OSAC_DEV_BMH_MEMORY` / `OSAC_DEV_BMH_DISK` (defaults
`4` / `8Gi` / `150Gi`, matching the e2e virtual hosts — assisted installs
need at least 100 GB), `OSAC_DEV_BMH_STORAGE_CLASS` (default `lvms-vg1`,
also used for the virtual-media DataVolumes), `OSAC_DEV_BMH_NODE_NIC`
(optional override; the secondary lab NIC is discovered after boot),
`OSAC_DEV_BMH_KUBEVIRTBMC_VERSION` (default `0.8.0`),
`OSAC_DEV_BMH_TIMEOUT_MIN` (default `10`; minutes to wait per attempt for
the hosts to become available), and `OSAC_DEV_BMH_ATTEMPTS` (default `2`;
total create-and-wait attempts — hosts that are not available after the
timeout are deleted, reset, and re-created). For cleanup, pass the same
count/prefix/namespace used at creation.

### What it creates

Per host `virtual-bmh-N` in `host-inventory`: a 150Gi block-mode PVC root
disk named `virtual-bmh-N-root` (the `-root` suffix avoids colliding with
KubeVirtBMC's virtual-media DataVolume, which takes the VM's name), a Halted
UEFI VirtualMachine (virtio root disk at `/dev/vda`, a sata CD-ROM for
virtual media, one bridge-bound NIC on the `br-bmh-nad` attachment with a
pinned MAC `52:54:00:bb:cc:0N`), a
BMC credentials Secret, a `VirtualMachineBMC` (which runs the per-VM
`virtual-bmh-N-virtbmc` Redfish service; it carries the
`bmc.kubevirt.io/datavolume-size-margin: "30"` annotation because LVMS
scratch-space overhead exceeds CDI's 6% assumption and same-size ISOs would
otherwise fail to import), and a `BareMetalHost` wired as:

```yaml
bmc:
  address: redfish-virtualmedia+http://virtual-bmh-N-virtbmc.host-inventory.svc.cluster.local:80/redfish/v1/Systems/1
  credentialsName: virtual-bmh-N-bmc
```

The BMHs carry label `osac.openshift.io/host-type=default` (the e2e shared
type's host selector) and the `osac.openshift.io/interface-macs` annotation
mapping fabric port `data-0` to the pinned MAC, so BMaaS instances select and
attach to them the same way they do to the e2e CI virtual hosts
(see `tests/e2e/bmaas/README.md`). Expect each host to take a few minutes:
`registering → inspecting → preparing → available`, where the first
inspection imports the Ironic ramdisk ISO into a DataVolume before the VM
boots (about four minutes end to end for both hosts on osac-dev).

### Self-healing and re-runs

`make osac-dev-bmh` is idempotent and safe to re-run at any point; a re-run
re-ensures the whole chain and recovers the failure modes seen so far:

- The **node bridge** is verified before anything else and converged when
  broken — including the NetworkManager-reclaimed-NIC case above — both at
  startup and between host-creation attempts (a stuck inspection can be
  caused by a bridge that broke after the hosts were created).
- The **Provisioning CR** is re-advertised to the node bridge address
  (`provisioningIP`/`externalIPs` = the `br-bmh` IPv4). `make
  osac-dev-deploy` resets it to the node's primary IP, which would bake an
  unreachable Ironic API URL into every inspection ISO.
- The **Ironic API behind the CBO ironic-proxy** (`https://<bridge-ip>:6385`
  — the URL the inspection ISOs hand to the IPA agents) is probed and
  healed. The proxy fronts the API with TLS pinned to the
  `metal3-ironic-tls` secret, and when the CBO rotates that secret after a
  metal3 (re)start — e.g. after a Provisioning CR patch — metal3 serves a
  self-generated certificate the proxy does not trust, and every request
  through 6385 answers HTTP 500. The wrapper then restarts the ironic-proxy
  DaemonSet, and metal3 as well if the proxy restart alone does not help.
  Port 6388 keeps working throughout, which makes this failure easy to
  miss.
- A re-run **without** BareMetalHosts resets stale virtual media: the VM is
  halted (inspection boots reliably only from a halted VM — while it runs,
  KubeVirtBMC's one-shot boot override is consumed before the reboot lands),
  any leftover cdrom volume is stripped from the VM template, the
  DataVolume is deleted, and the BMC Secret is rotated to restart the
  virtbmc pod, whose in-memory Redfish `Inserted` state would otherwise
  make every Ironic eject fail with "No suitable virtual media device
  found".
- Hosts that do not reach `available` within `OSAC_DEV_BMH_TIMEOUT_MIN`
  minutes, or that enter the error state, are deleted, reset, and
  re-created up to `OSAC_DEV_BMH_ATTEMPTS` times; a stuck inspection never
  recovers on its own (Ironic retry backoff is long and the ramdisk simply
  cycles BMO's inspection timeout). Hosts already `available` or
  `provisioned` are left untouched, and a host held by a consumer
  (a provisioned BareMetalInstance) is never deleted.

### Limitations

- VMs bridge onto the node's discovered secondary lab NIC (optionally
  overridden with `OSAC_DEV_BMH_NODE_NIC`): the tool creates a Linux bridge (`br-bmh`) over
  it — preserving the NIC's IPv4 identity on the bridge — and attaches the
  VMs through a `cnv-bridge` NAD. Masquerade networking is not usable here:
  the Ironic agent inside a masquerade guest is unreachable from the
  hostNetwork metal3 pod, which starves BMI provisioning of deploy commands.
  The live secondary lab network's dnsmasq serves the VMs; its subnet can
  change when the clone is recreated. Metal3 reaches agents directly on that L2.
- When NetworkManager manages the bridged NIC (RHCOS and most RHEL-family
  hosts, remote or local), the bridge is created and owned by NetworkManager
  itself: an NM bridge profile (carrying the NIC's MAC and IPv4 settings) and
  a bridge-slave profile for the NIC, while the NIC's standalone profile is
  deactivated with `autoconnect=no`. A raw `ip link set master` enslavement
  would be reverted by the next NM DHCP renewal — observed live: the renewal
  re-asserted the standalone profile, pulled the NIC out of the bridge,
  duplicated the address on both interfaces, and left every subsequent
  inspection ramdisk without DHCP or Ironic reachability. With NM owning the
  bridge, renewals happen on the bridge and cannot steal the uplink, and the
  NM profiles persist across node reboots (VM pods restart and re-attach
  their taps on their own). Without NetworkManager the manual bridge is
  used; both paths run inside `oc debug node`, so they work identically for
  remote-host and local-host deployments. The bridge state is re-verified
  (and healed) both at startup and between host-creation attempts.
- A fresh NM bridge can report activation success before its port is forwarding
  or DHCP has finished. The readiness check allows up to 120 seconds for STP
  (normally about 30 seconds) and DHCP, returning immediately once the uplink is
  attached and the address has moved from the NIC onto the bridge. It leaves
  STP enabled. Setup failures print the captured node diagnostics instead of
  suggesting that a valid NIC name is wrong.
- Bridge only a **secondary** NIC: converging the bridge briefly deactivates
  the NIC's standalone connection, and the node's primary (API) network must
  not blip. The NIC's original NM profile is kept (with `autoconnect=no`) for
  a manual revert.
- KubeVirt's `rebootPolicy: Terminate` is unavailable — the HyperConverged
  operator on CNV 4.22 does not expose the `RebootPolicy` feature gate, and
  the VM field is rejected without it. In-guest reboots during live-ISO
  agent installs will therefore boot the virtual media again instead of the
  freshly installed disk. Ironic deploy flows (BMaaS RHCOS/DiskImage
  provisioning, whose final reboot is BMC-initiated with a persistent
  boot-from-disk order) are unaffected.
- KubeVirtBMC chart 0.8.0 (app v0.11.0) is built against kubevirt 1.9 APIs;
  the cluster runs CNV 4.22 (kubevirt 1.8.4). If the controller misbehaves,
  retry with `OSAC_DEV_BMH_KUBEVIRTBMC_VERSION=0.7.0`.

### Teardown and housekeeping

`make osac-dev-bmh-clean` deletes each host's BareMetalHost (waiting on the
metal3 finalizer — the slow step), VirtualMachineBMC, VirtualMachine, PVC,
and Secret. It leaves KubeVirtBMC and the feature gate installed; remove
them manually with `helm uninstall kubevirtbmc -n kubevirtbmc-system` and by
dropping the `declarativeHotplugVolumes` entry from the HyperConverged CR's
`spec.featureGates`.

### Troubleshooting

- A BMH stuck in `registering` usually means Ironic cannot reach the virtbmc
  service: check `oc get pods -n host-inventory -l kubevirt.io/virtualmachinebmc-name=virtual-bmh-N`
  and the service's endpoints.
- A BMH stuck in `inspecting`: check the virtual-media DataVolume
  (`oc get dv -n host-inventory`) — the ramdisk ISO import must reach
  `Succeeded` before the VM boots — and the metal3 logs in
  `openshift-machine-api`. A ramdisk that never boots is usually the
  hotplug race (the cdrom DataVolume attaches to the running VMI after the
  firmware's first boot attempt); the wrapper avoids it by halting the VM
  before (re-)creating the BMH, and a re-run of `make osac-dev-bmh` retries
  the host automatically after `OSAC_DEV_BMH_TIMEOUT_MIN` minutes.
- Every inspection attempt failing with "No suitable virtual media device
  found": stale in-memory Redfish state in the virtbmc pod after media was
  stripped behind KubeVirtBMC's back — healed by the wrapper's BMC Secret
  rotation (re-run `make osac-dev-bmh`), or manually by deleting the
  virtbmc pods (`oc delete pod -n host-inventory -l
  kubevirt.io/virtualmachinebmc-name`).
- The agent boots and DHCPs (check the lab dnsmasq leases) but never
  heartbeats: the Ironic API URL baked into the ISO (`IRONIC_BASE_URL`,
  `https://<provisioningIP>:6385`) is broken — probe it with `curl -sk
  https://<bridge-ip>:6385/` from the metal3 pod (expect 200; 500 means the
  ironic-proxy certificate race described above — the wrapper heals it).
  Confirm in the Ironic log that no requests arrive from the VM addresses
  (192.168.179.2xx on osac-dev).
- The wrapper fails fast if the kubevirt CR does not pick up the
  `DeclarativeHotplugVolumes` gate after the HyperConverged patch; check the
  HCO conditions (`oc get hyperconverged -n openshift-cnv`) — the CNV
  operator must reconcile the change.
- VMs failing to schedule point at node capacity (memory requests);
  `oc describe node` shows the pressure.

## Running e2e suites against osac-dev

`make osac-dev-e2e TESTS="..."` runs selected suites from `tests/e2e`
against the platform deployed by `make osac-dev-deploy`. The wrapper
(`tools/osac-dev/osac-dev-e2e.sh`) builds the `osac` CLI from the checkout, verifies
the cluster's route names resolve, exports the e2e environment
(`KUBECONFIG`, `OSAC_NAMESPACE=osac`, `OSAC_CLI_PATH`), and execs
`uv run pytest -n 0` from the repository root with the given test paths
(plus any extra pytest arguments such as `-k` filters — everything in
`TESTS` is passed through verbatim).

```bash
make osac-dev-e2e TESTS="tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py"
make osac-dev-e2e TESTS="tests/e2e/bmaas/sanity/ -k lifecycle"   # directory + pytest filter
```

### Prerequisites

- `make osac-dev-deploy` (the platform, AAP, Keycloak, Ironic) and, for the
  BMaaS suites, `make osac-dev-bmh` (virtual hosts in `host-inventory`).
- Local `oc`, `kubectl`, `helm`, `go`, `curl`, and `uv`. `grpcurl` is
  auto-installed on first use (pinned 1.9.1, checksum-verified, into
  `~/.local/bin`).
- **Route reachability:** the e2e clients reach the platform through the
  cluster's routes (`fulfillment-api-osac.<domain>`,
  `fulfillment-internal-api-osac.<domain>`, `keycloak-keycloak.<domain>`).
  When those names do not resolve on the workstation (the usual case
  outside the lab network), the wrapper runs pytest inside an unprivileged
  user+mount namespace (`unshare --user --map-root-user --mount`) with a
  merged `/etc/hosts` bind-mounted over the system one, mapping the route
  names onto the kubeconfig's API host — which forwards TCP 443 to the
  cluster router with SNI preserved. This covers every client including
  grpcurl (which ignores HTTP/SOCKS proxy variables); no root and no
  system-wide changes are involved. If unprivileged user namespaces are
  unavailable, the wrapper prints ready-to-paste `/etc/hosts` lines instead;
  if the router is not reachable at all, it fails fast with a network
  message.

### Environment

The suites' fixtures default correctly for osac-dev: `OSAC_NAMESPACE` is
set to `osac` by the wrapper (pass through your own value to override),
`OSAC_BMH_NAMESPACE` defaults to `host-inventory`, `OSAC_BMI_TEMPLATE` to
`bm-host-provisioning`, and the Keycloak/JWT credentials match the caas-ci
profile deployment (`admin`/`admin`, user password `foobar`). Private API
access uses `oc create token admin` through the exported `KUBECONFIG`.
Tenant provisioning (tenant1/tenant2, JWT users, organization memberships,
default subnets) happens automatically through the session-scoped autouse
fixtures. BMaaS suites run serially (`-n 0`); the conftest also forces this
for directory-level `tests/e2e/bmaas` invocations.

### Notes

- The BMI sanity lifecycle test provisions one of the virtual BMHs with the
  `fedora-cloud-bmi` DiskImage through AAP/Ironic, power-cycles it, and
  deprovisions it back to `available`; with two hosts the two sanity tests
  can also run one after the other (`-n 0` keeps them sequential).
- Metering-marked tests additionally require `METERING_ADAPTER_URL`; the
  runner defaults it to the deployed metering echo-adapter route
  (`https://osac-metering-echo-adapter-<namespace>.<domain>`, mapped like
  the other routes when names do not resolve locally), so the CaaS sanity
  lifecycle works out of the box. The BMaaS sanity tests do not use it.
- Test-scoped resources (catalog items, disk images, tenants, users) are
  created and cleaned up by the fixtures; the BMHs return to `available`.

### Hosted-cluster API access for CaaS suites

The CaaS suites connect to hosted API servers
(`api.<order>.hosted.<domain>:6443` — MetalLB VIPs on the primary lab network),
which a separate workstation cannot reach directly. With a **remote target** the
runner defaults `OSAC_DEV_E2E_SSH_HOST` to `REMOTE_HOST`, opens an SSH SOCKS
proxy and keeps the hub API and known routes direct through `NO_PROXY`. CaaS
suites fail early when neither SSH host is set, rather than silently skipping
hosted access:

```bash
REMOTE_HOST=root@your-host.example \
OSAC_PULL_SECRET_PATH=~/.osac-dev-pull-secret \
    make osac-dev-e2e TESTS="tests/e2e/caas/sanity"
```

`OSAC_DEV_E2E_SOCKS_PORT` overrides the proxy port (default 1080). The runner
checks and refreshes the persistent DNS service before starting tests. DNS is
not cleared when pytest exits.

With the **localhost target** the VIPs are reachable directly: no SOCKS proxy,
no `HTTPS_PROXY`/`NO_PROXY` injection and no `/etc/hosts` mount namespace.
`OSAC_DEV_E2E_SSH_HOST` is ignored with an informational message, and an
unresolved route fails with `The cluster routes do not resolve on the localhost
target` and a `make osac-dev-dns` hint. Set `OSAC_DEV_E2E_SSH_HOST=` (explicitly
empty) to disable the SOCKS hop on a remote target.

### Persistent lab DNS and NTP

The full workflow runs `make osac-dev-dns` after deployment. For an environment
created with individual targets, run it once on the cluster host
(`REMOTE_HOST=root@host`, or without the prefix with the localhost target).
The command installs `/usr/local/sbin/osac-dev-dns`, the refresh oneshot
`osac-dev-dns-<DEV_ENV_NAME>-dev.service` and its timer, plus two persistent
listener services on the cluster-tool host:

- `osac-dev-dns-<DEV_ENV_NAME>-dev-primary.service`
- `osac-dev-dns-<DEV_ENV_NAME>-dev-secondary.service`

Each listener uses `Type=exec`, dnsmasq `--keep-in-foreground`, normal control
group cleanup, and at most three automatic startup attempts per 60 seconds.
The units supply `VIR_BRIDGE_NAME` to dnsmasq and its lease helper. Startup checks
the selected libvirt network and bridge, configuration syntax, lease-helper
initialization, a DHCP socket owned by dnsmasq, and local DNS over UDP and TCP.
The listeners belong to their own service control groups: finishing, failing or
stopping the refresh oneshot, or disconnecting the installing SSH client, does
not stop them. An unchanged healthy listener keeps its PID.

Installation serializes with an already-running refresh using the clone lock.
It installs listener units before starting listeners, preserves healthy legacy
processes during API-independent recovery, and deliberately migrates one network
at a time during configuration. Supported legacy paths are libvirt's original
config, the clone's managed config, and the former `osac-dev` secondary config.
Preflight runs before stopping a legacy listener. No VM, bridge, libvirt network
or NetworkManager restart is part of this handoff.

Every refresh reads both live libvirt network definitions and their generated
configuration files as **read-only inputs**. It writes managed copies under
`/etc/osac-dev/<DEV_ENV_NAME>-dev/`, preserving DHCP reservations and libvirt's
lease helper. It validates both configurations before stopping either DNS
listener, targets only processes serving the selected clone, and restores the
previous configuration if activation fails. Every startup, including rollback,
passes `VIR_BRIDGE_NAME` to libvirt's lease script. The script's `init` action is
preflighted too: dnsmasq `--test` alone does not exercise it. Preflight errors
retain bounded stderr diagnostics; daemon startup errors are in the listener
journal. Resource JSON and lease stdout stay out of error logs. If both startup and rollback fail, both errors are reported.
The libvirt networks are never restarted. DHCP excludes the primary `.240-.250`
lab MetalLB range; the shared
`caas-address-pool` is set to that range on the actual primary subnet. Existing
VIPs outside that range cause a failure instead of silent reassignment.

The timer refreshes records ten seconds after each completed run:

- Hub apps resolve to the SNO address on the querying lab network.
- API and internal API records use actual kube-apiserver LoadBalancer status.
- Apps records use ClusterOrder worker UUIDs, namespaced BMI lookup and BMH
  IPv4 inventory. No BMI cluster-order label is required. The first known worker
  supplies the lab ingress address; arbitrary multi-worker router placement is
  not discovered by this helper.
- `rhel.pool.ntp.org` (including `2.rhel.pool.ntp.org`) resolves to the
  hypervisor's selected IPv4 chrony source. Set `OSAC_DEV_NTP_SERVER=<IPv4>` if
  another reachable source is needed or the host has no selected source.
- The hypervisor's NetworkManager DNS forwards the hosted domain to the lab
  resolver, replacing old static VIP overrides. Inter-bridge forwarding is
  re-ensured for this clone only.

API read failures retain existing DNS rather than clearing records. Successful
refreshes remove records for orders that no longer exist. These are development
baseline connectivity prerequisites, not OSAC tenant-network API operations;
the accepted OSAC-1433/1436/1437 attachment and fabric-manager contracts are
unchanged. The host needs Python 3, `oc`, `virsh`, dnsmasq, chrony, NetworkManager,
nftables and systemd (provided by the existing lab/cluster-tool prerequisites).

#### Recovery when the existing SNO API is unreachable

A failed listener replacement can leave the VM running but unable to renew its
primary DHCP lease. Once the lease expires, neither direct API access nor an
SSH tunnel to that IP can work. Recreating the SNO is not the first remedy.

Rerun normal provisioning, or repair baseline connectivity and refresh kubeconfig
without running the rest of the deployment:

```bash
REMOTE_HOST=root@your-host.example make osac-dev-kubeconfig
```

Access setup runs the helper's API-independent `recover` action **before** the
first API probe. It checks both selected networks and bridges are active, reuses
a validated
last-working managed configuration (falling back to the original configuration
if necessary), and preflights the lease helper. It restores absent or unhealthy
listeners through the persistent services with the correct bridge environment.
Healthy existing listeners, the VM and the libvirt networks remain running.
API readiness uses the configurable 900-second
budget described above, including reruns with no newly missing listener.
A node that has stopped retrying DHCP or has other faults can still require
further diagnosis; this is not an unconditional
API-readiness guarantee. Direct DNS configure and each refresh-timer run also
check missing listeners before API or NTP lookups. If initial setup failed
before installing the timer, a provisioning/access/recovery command must be
invoked to trigger repair.

For just the host-side baseline repair, without kubeconfig/API checks:

```bash
REMOTE_HOST=root@your-host.example tools/osac-dev/osac-dev-dns.sh --recover
```

Recovery does not recreate hosted records or install the refresh timer. After
baseline/API recovery, the normal final DNS stage reconciles the full desired
state; `make osac-dev-dns` is also available independently. Original libvirt
configurations remain unchanged throughout recovery.

For the default `DEV_ENV_NAME=osac`, inspect these units on the host:

```bash
systemctl status osac-dev-dns-osac-dev{,-primary,-secondary}.service
systemctl status osac-dev-dns-osac-dev.timer
journalctl -u osac-dev-dns-osac-dev.service -u osac-dev-dns-osac-dev-primary.service -u osac-dev-dns-osac-dev-secondary.service
systemctl show -p MainPID -p ControlGroup osac-dev-dns-osac-dev-primary.service
```

A start failure reports activation and rollback separately; inspect the listener
journal for dnsmasq's startup error. `--recover` explicitly resets the service's
start limit before retrying. To disable refreshes, remove hosted overrides and
restore validated original configurations through the persistent units, run on
the host:

```bash
/usr/local/sbin/osac-dev-dns remove osac-dev
```

This removes the refresh service/timer and clone-specific NetworkManager
forwarding. It retains the baseline listener units and managed copies while the
networks exist, preserving reservations and lease-helper state. Repeating it is
safe, including after partial installation. Run the same operation remotely:

```bash
REMOTE_HOST=root@host tools/osac-dev/osac-dev-dns.sh --remove
```

`make osac-dev-down` installs the current helper before teardown. Under the same
clone lock it quiesces refreshes, establishes baseline connectivity, destroys
only the selected clone, then removes listener units/configs after both selected
networks are gone (including inactive definitions). A failed destruction retains
baseline service ownership for surviving active networks. Repeated teardown of
an absent clone performs cleanup and refuses to discard units for networks that
still exist. To clean up after independently removing both networks, run
`/usr/local/sbin/osac-dev-dns cleanup <clone>-dev` on the host.

Do not invoke the former manually installed `osac-dev-guest-dns` helper: it may
contain addresses from a destroyed clone. The new provisioning migrates its
listener without reusing its stale configuration.

#### Validation boundaries

Run the offline suite once after a source change:

```bash
make osac-dev-test
```

That runs six Python suites (the installer's `test-skaffold-deploy.py`,
`test_osac_dev_ee.py`, `test_osac_dev_nic.py`, `test_osac_dev_bridge.py`,
`test_osac_dev_api_wait.py`, `test_osac_dev_dns.py`) and thirteen shell suites
(`test-osac-dev-target.sh`, `-setup`, `-dns`, `-workflow`, `-provisioning`,
`-bootstrap`, `-clusters`, `-install-infra`, `-snapshot`, `-deploy`, `-bmh`, `-e2e`,
`-grow-storage`). Everything is offline: `ssh`, `scp`, `oc`, `helm`, `skaffold`,
`dnf`, `systemctl`, `virsh` and `cluster-tool` are recording doubles, and every
suite that touches a target runs its cases in both target modes. The EE suite
also probes dependency hashing with the real Skaffold binary, when installed,
using `build --dry-run` without a daemon, registry or cluster. Signal tests use
a slow cooperative child to verify that the adapter waits for cleanup.

The root/systemd lifecycle suite is separate and explicitly opt-in. Use a
disposable Fedora/RHEL-style host with systemd, libvirt's nftables backend,
dnsmasq, the libvirt lease helper, NetworkManager, `ip`, `nft` and `dig`:

```bash
sudo env OSAC_DEV_DNS_SYSTEMD_TEST=1 python3 tools/osac-dev/tests/test_osac_dev_dns_systemd.py
```

It refuses name/subnet collisions, creates two isolated fixture networks and
DHCP client namespaces, and cleans only fixture-owned resources. It executes the
real helper from a real oneshot, checks listener PID/control-group stability and
DNS every second for 30 seconds after each of two unchanged refreshes, API
failure and refresh-service stop, then covers DHCP acquisition/renewal, record
replacement, rollback, legacy migration and baseline cleanup. It verifies the
generated units with `systemd-analyze verify`. Only Kubernetes/NTP discovery
inputs are simulated. The suite takes several minutes and is excluded from
`make osac-dev-test`.

After live installation, observe both bridge DNS addresses for at least 120
seconds across three refreshes; require stable listener PIDs and no query
failures. Stop/start the refresh service and timer independently, then restore
the timer. From an authorized guest shell check its DHCP lease, DNS server,
default gateway, route to Assisted, DNS over UDP/TCP and HTTPS using the actual
Assisted hostname and normal resolver. Confirm Agent registration against the
intended InfraEnv/order, then run:

```bash
REMOTE_HOST=root@host make osac-dev-e2e TESTS="tests/e2e/caas/sanity"
```

Host DNS and direct HTTP probes do not establish guest connectivity or CaaS
success. Guest acceptance remains unverified without guest access. Preserve the
current order and failed-job evidence; do not automatically reprovision it.

### Growing the VM disks

The published flavor starts with 100 GB disks, which the platform, AAP, CNV,
Kafka and a hosted control plane outgrow. Both `make osac-dev-cluster` and
`make osac-dev` automatically grow the root and LVMS disks to **200 GiB minimum**
after boot and kubeconfig retrieval, before workload installation. Larger disks
are never shrunk. The following target remains available for existing clusters:

```bash
REMOTE_HOST=root@host make osac-dev-grow-storage          # default 200G
REMOTE_HOST=root@host make osac-dev-grow-storage OSAC_DEV_DISK_TARGET=300G
```

The wrapper resizes qcow2 files live (`virsh blockresize` over SSH), then grows
the root partition/XFS filesystem and any existing LVMS PV/thin-pool through
`oc debug`. It handles repeated growth, a root source shown as an OSTree bind
mount, and RHCOS images without `growpart` (using util-linux instead). Overrides
below 200 GiB are rejected. Disk expansion cannot be reversed safely by shrinking;
restore a backup or recreate the selected clone if rollback is necessary.

The `osac-dev-infra-cnv` flavor already ships 200G disks (the images were
resized offline: `virt-resize` for the root disk, `pvresize` +
`lvextend` for the LVMS disk; the original 100G images are kept in
`osac-dev-infra-cnv-backup-100g` on the remote host), so boots from it do
not need this step — it remains the tool for growing other flavors or
source clusters.
