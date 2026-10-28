#!/usr/bin/env bash
# Shared cluster prerequisite. Preserve addresses chosen by the BMH workflow.
set -euo pipefail
if oc get provisioning provisioning-configuration -n openshift-machine-api -o name >/dev/null 2>&1; then
    oc patch provisioning provisioning-configuration -n openshift-machine-api --type merge \
        -p '{"spec":{"watchAllNamespaces":true,"disableVirtualMediaTLS":true}}'
else
    node_ip=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    [[ -n "$node_ip" ]] || { printf 'ERROR: node InternalIP is empty\n' >&2; exit 1; }
    oc apply --server-side -f - <<PROVISIONING
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: "Disabled"
  watchAllNamespaces: true
  disableVirtualMediaTLS: true
  provisioningIP: "$node_ip"
  externalIPs:
    - $node_ip
PROVISIONING
fi
