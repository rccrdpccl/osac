#!/usr/bin/env bash
# Read-only workflow cheat sheet.
set -euo pipefail
cat <<'HELP'
osac-dev — SNO development environment (remote host or localhost)

Target selection:
  REMOTE_HOST unset, empty, or "localhost" runs every stage on this machine
  (the localhost target). Any other value, e.g. root@host, drives that host
  over root SSH. Both targets require root. OSAC_DEV_TARGET is derived from
  REMOTE_HOST and cannot be set. The localhost target uses the cluster-tool
  kubeconfig as-is (no endpoint rewrite, SNI pin, tunnel or SOCKS proxy) and
  reaches hosted-cluster routes and MetalLB VIPs directly.

Full workflow:
  make osac-dev             Automatically run preflight, then these stages:
    1. osac-dev-cluster       Boot/reuse SNO and fetch kubeconfig.
    2. osac-dev-grow-storage  Ensure both disks are at least 200 GiB.
    3. osac-dev-install-infra Install osac-deps, osac-infra, CNV.
    4. osac-dev-bmh           Initialize Ironic and virtual BareMetalHosts.
    5. osac-dev-deploy        Build/push branch images and deploy OSAC.
    6. osac-dev-dns           Configure persistent lab DNS and NTP resolution.

Infra-only snapshot factory (separate from the full workflow):
  make osac-dev-snapshot SNAPSHOT_NAME=osac-caas-infra-v1
                           Boot/reuse SNO -> both disks >=200 GiB -> deps/infra/CNV
                           -> health gate -> capture -> restore smoke check.
                           Requires a prepared cluster-tool local server and
                           PULL_SECRET_FILE; no registry build login or license.
                           Defaults: builder osac-dev, disks 200G, validation
                           svfy-dev. Reuses the builder; skips storage growth
                           entirely when both disks already meet the target.
                           Refuses existing validation/flavor names and OSAC
                           platform releases. Retains both clusters, never
                           overwrites, deletes or pushes a flavor.
                           Snapshot disks/keys are sensitive private artifacts.

Optional check (not required before make osac-dev):
  make osac-dev-check       Preflight only, including read-only SSH checks;
                           no deployment. make osac-dev repeats preflight.

Installing prerequisites:
  make osac-dev-setup       Install what is missing instead of only naming it:
                           Skaffold, the docker->podman shim and the rootless
                           podman socket on this machine (always, for both
                           targets), plus the cluster-host packages and
                           cluster-tool when it already has root there.
                           DRY_RUN=1 prints the plan and changes nothing.
                           It never runs sudo: when root is unavailable it
                           prints the exact command. Registry login stays
                           manual.

Required full-workflow inputs (prompted if absent; export for reuse):
  REMOTE_HOST               Root SSH connection, e.g. root@host. Omit it to
                            run on this machine.
  PULL_SECRET_FILE          Absolute local OpenShift pull-secret JSON path.
  OSAC_DEV_REGISTRY         Writable registry namespace, e.g. quay.io/user.
  OSAC_DEV_LICENSE_REMOTE   Absolute host AAP license path, unless a local
                            OSAC_DEV_LICENSE_FILE exists (nonempty, 0600).

The BMH stage discovers the secondary guest NIC after boot. It stops with
interface diagnostics if selection is ambiguous or unsafe; no guessing.

Optional configuration:
  OSAC_DEV_BMH_NODE_NIC     Override discovery; primary/API NICs are rejected.
  DEV_ENV_NAME=osac         1-4 lowercase alphanumeric characters.
  OSAC_DEV_KUBECONFIG       Default ~/.kube/<DEV_ENV_NAME>-dev.kubeconfig.
  SNO_FLAVOR=sno-4-22       Cluster flavor.
  CLUSTER_TOOL_DATA_PATH   Default /data/cluster-tool.
  OSAC_DEV_API_HOST         Override API host address (remote target only).
  OSAC_DEV_LOCAL_API_PORT   Temporary API tunnel port, default 16443 (remote
                            target only).
  OSAC_DEV_HOST_KUBECONFIG  cluster-tool kubeconfig path on the host; default
                            /root/.kube/<DEV_ENV_NAME>-dev.kubeconfig.
  OSAC_DEV_DNS_HELPER       Host DNS helper; default /usr/local/sbin/osac-dev-dns.
  OSAC_DEV_API_RECOVERY_TIMEOUT
                           API readiness wait in seconds, default 900 (1-3600);
                           returns immediately when ready, including on reuse.
  OSAC_DEV_ADOPT_CRDS=1     Adopt cluster-scoped objects another controller
                           created (CRDs included) and retry install-infra;
                           0 disables.
  OSAC_DEV_INFRA_CHECK_ONLY=1
                           Verify releases/CNV without upgrades in standalone
                           install-infra; still refreshes access/kubeconfig.
  OSAC_DEV_SNAPSHOT_VERIFY_ENV_NAME=svfy
                           Fresh validation clone slug for the snapshot factory.
  OSAC_DEV_SNAPSHOT_TIMEOUT=1800
                           Seconds per factory health wait (1-7200).
  OSAC_DEV_INSTALL_LOG      Where a failed install-infra Helm log is kept,
                           default /tmp/osac-dev-install-infra.log.
  OSAC_DEV_HELM_VERSION     Override the Helm pin in .github/helm-version for a
                           one-off run; make osac-dev-deploy adapts to Helm 3
                           or 4.
  OSAC_DEV_BMH_COUNT=2      Number of virtual hosts (1-15).
  OSAC_DEV_DISK_TARGET=200G Both SNO disks; minimum 200 GiB, never shrink.
  OSAC_DEV_NTP_SERVER      IPv4 NTP override; defaults to host chrony source.
  DOCKER_HOST              Container daemon; defaults to user Podman socket.

Before running: install oc, Helm (the version pinned in .github/helm-version),
Make, Python 3, Skaffold, docker CLI (or Podman shim), uv, Go; ssh and scp are
needed only for a remote target. With the localhost target, cluster-tool,
libvirt and the host DNS helper must be present here. Start the container
daemon and log in to the registry with the build CLI.
make osac-dev-setup installs the missing pieces it can and prints the rest.
Preflight cannot guarantee registry push access, host capacity, DNS, download
availability or operator readiness.

Other targets:
  make osac-dev-status          Read cluster state.
  make osac-dev-kubeconfig      Repair missing DNS/DHCP and refresh kubeconfig
                               before API access; no workload deployment.
  make osac-dev-dev             Watch/rebuild/redeploy branch images.
  make osac-dev-bmh-clean       Remove virtual BMH stack.
  make osac-dev-grow-storage    Grow disks (OSAC_DEV_DISK_TARGET=200G).
  make osac-dev-dns             Install/refresh persistent lab DNS (root).
  make osac-dev-e2e TESTS=...   Run selected tests; a remote target adds the
                               CaaS SOCKS hop (OSAC_DEV_E2E_SSH_HOST overrides,
                               empty disables it).
  make osac-dev-test            Offline shell contract tests.
  make osac-dev-setup           Install missing prerequisites (see above).
  make osac-dev-down            Destroy selected cluster, with confirmation.

Full guide: tools/osac-dev/README.md (including all BMH overrides and e2e inputs).
HELP
