# Bare-metal worker prebinding recovery

On terminal ClusterOrder deletion, the worker controller can clear an Agent
prebinding written by OSAC that CAP-Agent never claimed. Ordinary provisioning
and scale-down are unchanged. Recovery requires:

- An uncached deleting order with its worker finalizer, authoritative matching
  Cluster/BMI tenant ownership, and unambiguous live worker identity.
- All recorded provision jobs terminal and a recorded deprovision job with a
  known state and ID. Missing/unknown evidence retains the worker.
- Validated naming contracts: hosting namespace `<order-namespace>-<order-name>`
  and control-plane namespace `<hosting>-<order-name>`. Status references must
  agree; a live hosting namespace/HostedCluster must match the order label, and
  the HostedCluster must use the order's Agent namespace. Early provisioning
  with neither namespace nor HostedCluster is supported. A control-plane
  namespace without a validated hosting namespace fails closed.
- No NodePools in the dedicated hosting namespace and no MachineDeployments,
  MachineSets, Machines or AgentMachines in the dedicated control-plane
  namespace, including unlabelled or terminating descendants. API discovery
  selects a served version; unsupported APIs and read failures are not absence.
- A freshly read Agent with the same UID, matching OSAC order/worker/InfraEnv
  labels and a live order → InfraEnv → Agent owner-UID chain. Any conflicting
  tenant/order annotation, Machine reference marker, bootstrap field or cluster
  reference prevents recovery. Assisted Service need not copy tenant annotations
  onto Agent/InfraEnv: tenancy is anchored in the authoritative Cluster/BMI and
  live owner chain, with conflicting optional annotations rejected.

Only `spec.clusterDeploymentName` is removed, with a resourceVersion-locked
merge patch. Labels, annotations, approval, bootstrap configuration, hooks and
finalizers are retained. Conflicts are not blindly retried. The worker remains
`Unbinding`, and Agent/BMI deletion cannot occur in that reconcile. A later
observation of detached `known-unbound` resumes the existing deletion lifecycle;
BMI NotFound is still required before removing the worker finalizer. Neither
prebinding removal nor BMI absence proves hardware readiness. Terminal deletion
uses uncached Agent lists and state reads, rejects duplicate worker/Agent identity,
and guards subsequent Agent deletion with UID/resourceVersion preconditions so
a stale detached observation cannot bypass recovery. Read/patch/delete errors
are logged and the existing periodic teardown requeue retains the worker.

## Accepted residual producer risk

The recorded-job gate is not a durable external producer fence. A create job
launched in AAP before its ID is durably persisted can survive a crash/status-write
failure and escape this gate. The live job and empty-descendant checks do not
exclude such a producer recreating workers after the Agent patch. This limitation
was explicitly accepted for this fix; durable producer fencing/job discovery
remains follow-up work with no assigned ticket/owner. No absolute
producer-quiescence guarantee is claimed.

Source references:

- `pkg/provisioning/provision_lifecycle.go`: external launch precedes job-history
  persistence; the immediate status-flush failure is non-fatal.
- `pkg/provisioning/aap_provider.go`: deprovision readiness checks/cancels the
  latest recorded provision job; cancellation is asynchronous and polled.
- `internal/controller/clusterorder_controller.go`: the initial cached deletion
  timestamp chooses provisioning versus deletion; the live duplicate-job helper
  does not itself fence external launches against deletion.

The recovery predicate is deliberately stricter than provider launch readiness:
all recorded provision jobs must be terminal, not just the latest one, and missing
or unknown deprovision evidence cannot authorize Agent mutation. A timeout is
only a diagnostic warning and never opens the gate.

## Validation boundaries

- **Unit / DEV:** `orphan_binding_test.go` tests identity, recorded-job gates,
  API failures, stale observations, patch scope and conflicts with fake clients.
- **Envtest / DEV:** the acceptance suite uses production Agent correlation and
  public Reconcile against real API/etcd, testing progress, restart/duplicates,
  job gates, terminating descendants, tenant/reference rejection and an actual
  resourceVersion conflict from a claim inserted between GET and PATCH. AAP,
  Fulfillment, CAP-Agent and Assisted Service progress are simulated.
- **Contract / DEV:** `test/contract/manager_worker_teardown_rbac_test.go` checks
  generated and Helm permissions, including get/list-only CAPI/CAP-Agent access.
- **Component integration / DEV:**
  `test/integration/baremetalworker_teardown_test.go` issues real GET/LIST requests
  impersonating the ServiceAccount of the deployed manager pod. This proves API
  permissions, not a real CAP-Agent claim or hardware teardown.

Run from `osac-operator/`, after configuring envtest assets, plus the normal
component checks described in `AGENTS.md`:

```sh
make envtest
export KUBEBUILDER_ASSETS="$(bin/setup-envtest use 1.31.0 --bin-dir bin -p path)"
go test ./internal/controller/baremetalworker/... -count=1
go test -race ./internal/controller/baremetalworker/... -count=1
go test ./test/contract/... -count=1
```

For the deployed permission case, use a dedicated Kind cluster with the current
image/manifests and manager pod labels expected by the integration suite. The
runner must be allowed to impersonate the manager ServiceAccount and its groups.
If real CAPI/CAP-Agent APIs are absent, install the four explicit test-only CRDs
before running `make integration-tests`:

```sh
kubectl apply -f config/crd/fakes/cluster.x-k8s.io_machinedeployments.yaml \
  -f config/crd/fakes/cluster.x-k8s.io_machinesets.yaml \
  -f config/crd/fakes/cluster.x-k8s.io_machines.yaml \
  -f config/crd/fakes/capi-provider.agent-install.openshift.io_agentmachines.yaml
```

These fixtures serve CAPI v1beta1/v1beta2 and CAP-Agent v1beta1 but provide no
provider controller semantics; see `config/crd/fakes/README.md`. Do not install
them over real provider CRDs. Missing required APIs or permissions fail the case.
The permission case performs reads only and does not delete cluster resources.
An object-level GET NotFound is an authorized read; Forbidden is a failure.
Compilation of the case does not prove deployed RBAC.

## Real-provider handoff

The real interrupted-provisioning user journey is **not execution-ready**:
there is no test-owned per-order barrier controlling the correlated-but-unclaimed
Agent interval. The barrier, image/version prerequisites, polling/deadline bounds,
rollback, QE owner and specific child task are unresolved under
[OSAC-4843](https://redhat.atlassian.net/browse/OSAC-4843). Future assertions must
not use cleanup helpers that remove hooks/finalizers. BMH/ConsumerRef cleanup
must be observed separately from BMI deletion.
