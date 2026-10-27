# OSAC development tool

Rewrite in progress under [OSAC-6535](https://issues.redhat.com/browse/OSAC-6535).
The launcher and Make wrapper support read-only target inspection (`plan` and
`doctor`, currently target/access scope only). Typed hub/BM-CNV references,
credential precedence, native/host adapters, fingerprints, and the generic
reconciliation core have offline tests. Operational application stages are
explicitly disabled until prerequisite/lab/deployment adapters are wired; native
creation exists only at the internal adapter boundary. No live acceptance is
claimed. The PoC is a reference, not a runtime dependency. Full documentation is
the final planned task. Run `tools/osac-dev/osac-dev plan --help` for current inputs.

## Native compatibility and gaps

[`dependencies.lock.json`](dependencies.lock.json) records the inspected
cluster-tool revision and executable hash, default `sno-4-22` flavor manifest
digest, and frozen PoC reference. These identify inspected artifacts, not proven
runtime compatibility.

- Native `servers` and `list --server ALIAS` expose human-readable tables, not
  JSON; clone listing does not establish live health.
- Native boot reads the pull-secret path on the invoking workstation and writes
  its kubeconfig there under `~/.kube/<name>.kubeconfig`.
- Native pull derives the installed flavor name from the image tag; a digest
  reference is not a drop-in replacement. The default flavor manifest was
  inspected by tag and verified by digest, but no disk layers were pulled or booted.

**Named clones initially work only from their creator workstation with existing
native access.** The pinned CLI has no public clone import, kubeconfig export,
or standalone access/DNS refresh operation. Boot rejects an existing name;
`connect` performs server setup rather than recovering clone access.

A future upstream import feature can be wrapped here. Missing access must be
diagnosed, never repaired by copying/rewriting kubeconfigs, opening custom hub
tunnels, or rebooting/replacing a clone. A supplied working kubeconfig remains
independent and must not require cluster-tool.

## Roadmap

1. CLI, explicit hub/BM-CNV targets, credential handling, platform gate, and wrappers.
2. Content-aware reconciliation and role-specific infrastructure prerequisites.
3. Lab DNS/DHCP/NTP, guest access, and separate BM-CNV hardware/hub BMH inventory.
4. Skaffold/E2E handoff and guarded migration.
5. Live acceptance on shared, split, mixed, local, and remote targets.
6. Documentation: supported usage, inputs, topology, migration, and diagnostics.

Run `make osac-dev-test` for Unit and Contract tests. They exercise selector and
input safety, recording native/SSH/API/Helm boundaries, Make argument forwarding,
content identity and reconciliation failures/no-op reruns. Installed Helm runs
only offline CLI/render checks; set `OSAC_DEV_TEST_HELM4` to a Helm 4 executable
to include that version. Release-state JSON fixtures are simulated, not live
Helm evidence. Real native/SSH/API/release integration and CaaS E2E acceptance
remain unrun under [OSAC-6535](https://issues.redhat.com/browse/OSAC-6535); no
separate gap tickets exist yet. These tests do not duplicate cluster-tool's
self-tests or snapshot upstream help output.

Named inspection requires an explicit existing `--hub-server`/`--bm-cnv-server`
alias. Missing connections require explicit native `connect`; client setup,
default-server changes and access repair are never automatic. Fingerprint inputs
must be public chart sources and non-secret values: runtime credentials are
separately reconciled, not hashed. Root chart README/license files and runtime
caches are excluded and must not be used as rendered inputs.
