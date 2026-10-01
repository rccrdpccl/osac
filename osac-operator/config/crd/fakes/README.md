# External API test fixtures

These hand-maintained source CRDs provide only the API shape needed by tests.
They are not generated OSAC production CRDs and must not be deployed to replace
real provider CRDs. `make manifests` does not generate them.

Worker teardown fixtures serve:

- CAPI `MachineDeployment`, `MachineSet`, and `Machine`: `cluster.x-k8s.io/v1beta1`
  and `v1beta2`, with `v1beta2` as storage and no conversion. Unknown `spec` and
  `status` fields are preserved. This permits discovery-selected version reads
  and tests across both served versions; it does not validate upstream schemas.
- CAP-Agent `AgentMachine`: `capi-provider.agent-install.openshift.io/v1beta1`.

Envtest loads this directory. Dedicated Kind deployments can install these four
fixtures explicitly for the manager-ServiceAccount read-permission check when
real CAPI/CAP-Agent APIs are unavailable. There are no provider controllers or
claim/install semantics in these fixtures.
