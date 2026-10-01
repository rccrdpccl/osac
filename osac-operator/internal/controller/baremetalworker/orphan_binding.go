/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

package baremetalworker

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/validation"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"

	v1alpha1 "github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

const (
	capiAPIGroup         = "cluster.x-k8s.io"
	hypershiftAPIGroup   = "hypershift.openshift.io"
	hypershiftAPIVersion = "v1beta1"
	nodePoolKind         = "NodePool"
)

var workerProducerKinds = []schema.GroupKind{
	{Group: capiAPIGroup, Kind: "MachineDeployment"},
	{Group: capiAPIGroup, Kind: "MachineSet"},
	{Group: capiAPIGroup, Kind: "Machine"},
	{Group: "capi-provider.agent-install.openshift.io", Kind: "AgentMachine"},
}

// recoverOSACPrebinding only clears the exact prebinding written by bindAgent.
// It does not delete anything, acknowledge detachment, or alter CAP-Agent's
// hooks/bootstrap data. The caller retains Unbinding and periodically requeues.
func (r *Reconciler) recoverOSACPrebinding(
	ctx context.Context, co *v1alpha1.ClusterOrder, w *v1alpha1.WorkerStatus, observed *unstructured.Unstructured,
) error {
	if co.DeletionTimestamp.IsZero() || !controllerutil.ContainsFinalizer(co, bmWorkerFinalizer) {
		return nil // Ordinary scale-down is deliberately not recovered here.
	}
	if r.apiReader == nil {
		return fmt.Errorf("prebinding recovery requires an uncached API reader")
	}
	live := &v1alpha1.ClusterOrder{}
	if err := r.apiReader.Get(ctx, client.ObjectKeyFromObject(co), live); err != nil {
		return fmt.Errorf("reading deleting order: %w", err)
	}
	if live.UID == "" || live.UID != co.UID || live.DeletionTimestamp.IsZero() ||
		!controllerutil.ContainsFinalizer(live, bmWorkerFinalizer) ||
		live.Labels[clusterOrderIDLabel] != co.Labels[clusterOrderIDLabel] || tenantOf(live) != tenantOf(co) {
		return fmt.Errorf("deleting order identity changed")
	}
	tenant, err := r.verifyOrderWorkerOwnership(ctx, live)
	if err != nil {
		return err
	}
	if !recordedProducersStopped(live) {
		return nil
	}
	if !workerHasUniqueLiveIdentity(live, w) {
		return fmt.Errorf("worker identity is missing or ambiguous in live order")
	}
	hosting, controlPlane, err := r.deletionNamespaces(ctx, live)
	if err != nil {
		return err
	}
	absent, err := r.workerDescendantsAbsent(ctx, hosting, controlPlane)
	if err != nil || !absent {
		return err
	}

	agent := &unstructured.Unstructured{}
	agent.SetGroupVersionKind(agentGVK)
	if err := r.apiReader.Get(ctx, client.ObjectKeyFromObject(observed), agent); err != nil {
		return fmt.Errorf("reading recovery Agent: %w", err)
	}
	if observed.GetUID() == "" || agent.GetUID() != observed.GetUID() || !agent.GetDeletionTimestamp().IsZero() {
		return fmt.Errorf("agent identity changed or agent is deleting")
	}
	matchingAgents := &unstructured.UnstructuredList{}
	matchingAgents.SetGroupVersionKind(agentGVK.GroupVersion().WithKind("AgentList"))
	if err := r.apiReader.List(ctx, matchingAgents, client.InNamespace(live.Namespace),
		client.MatchingLabels{workerNameLabel: w.Name}); err != nil {
		return fmt.Errorf("checking unique worker Agent: %w", err)
	}
	if len(matchingAgents.Items) != 1 || matchingAgents.Items[0].GetUID() != agent.GetUID() {
		return fmt.Errorf("worker Agent identity is missing or ambiguous")
	}
	if err := r.checkPrebindingIdentity(ctx, live, w, agent, tenant); err != nil {
		return err
	}
	if !agentHasOnlyPrebinding(agent, live) {
		return nil // A remaining/ambiguous claim stays on CAP-Agent's lifecycle.
	}
	base := agent.DeepCopy()
	unstructured.RemoveNestedField(agent.Object, "spec", "clusterDeploymentName")
	// Do not retry here: any conflict requires re-evaluating every gate, not just
	// repeating the patch on a newer Agent. ResourceVersion fences concurrent claims.
	if err := r.Patch(ctx, agent, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{})); err != nil {
		return fmt.Errorf("clearing OSAC-only Agent prebinding: %w", err)
	}
	ctrllog.FromContext(ctx).Info("cleared OSAC-only Agent prebinding; awaiting detachment", "agent", agent.GetName(), "worker", w.Name)
	return nil
}

func workerHasUniqueLiveIdentity(co *v1alpha1.ClusterOrder, w *v1alpha1.WorkerStatus) bool {
	if w.Kind != workerKindBMI || w.ResourceID == "" {
		return false
	}
	matched := false
	for _, worker := range co.Status.Workers {
		if worker.Name != w.Name {
			continue
		}
		if matched || worker.Kind != w.Kind || worker.ResourceID != w.ResourceID {
			return false
		}
		matched = true
	}
	return matched
}

// recordedProducersStopped is intentionally a recorded-job gate, not a durable
// external producer fence. An AAP launch lost before status persistence can
// escape it; that residual risk is accepted and documented in the operator README.
func recordedProducersStopped(co *v1alpha1.ClusterOrder) bool {
	deprovisionStarted := false
	for _, job := range co.Status.ProvisioningJobs {
		switch job.Type {
		case v1alpha1.JobTypeProvision:
			if job.JobID == "" || !job.State.IsTerminal() {
				return false
			}
		case v1alpha1.JobTypeDeprovision:
			if job.Target == "" && job.JobID != "" &&
				(job.State == v1alpha1.JobStatePending || job.State == v1alpha1.JobStateWaiting ||
					job.State == v1alpha1.JobStateRunning || job.State.IsTerminal()) {
				deprovisionStarted = true
			}
		default:
			return false
		}
	}
	return deprovisionStarted
}

func (r *Reconciler) deletionNamespaces(ctx context.Context, co *v1alpha1.ClusterOrder) (string, string, error) {
	hosting := co.Namespace + "-" + co.Name // generateNamespaceName contract
	controlPlane := hosting + "-" + co.Name // AAP/HyperShift control-plane contract
	if len(validation.IsDNS1123Label(hosting)) != 0 || len(validation.IsDNS1123Label(controlPlane)) != 0 {
		return "", "", fmt.Errorf("invalid derived hosting/control-plane namespace")
	}
	if ref := co.Status.ClusterReference; ref != nil {
		if (ref.Namespace != "" && ref.Namespace != hosting) || (ref.HostedClusterName != "" && ref.HostedClusterName != co.Name) {
			return "", "", fmt.Errorf("cluster status reference disagrees with naming contract")
		}
	}
	ns := &corev1.Namespace{}
	hostingAbsent := false
	if err := r.apiReader.Get(ctx, client.ObjectKey{Name: hosting}, ns); err != nil {
		if !apierrors.IsNotFound(err) {
			return "", "", fmt.Errorf("reading hosting namespace: %w", err)
		}
		hostingAbsent = true
	} else if ns.Labels["osac.openshift.io/clusterorder"] != co.Name {
		return "", "", fmt.Errorf("hosting namespace is not owned by this order")
	}
	hc := &unstructured.Unstructured{}
	hc.SetGroupVersionKind(schema.GroupVersionKind{Group: hypershiftAPIGroup, Version: hypershiftAPIVersion, Kind: "HostedCluster"})
	if err := r.apiReader.Get(ctx, client.ObjectKey{Namespace: hosting, Name: co.Name}, hc); err != nil {
		if !apierrors.IsNotFound(err) {
			return "", "", fmt.Errorf("reading HostedCluster identity: %w", err)
		}
	} else {
		agentNamespace, found, readErr := unstructured.NestedString(hc.Object, "spec", "platform", "agent", "agentNamespace")
		if hc.GetLabels()["osac.openshift.io/clusterorder"] != co.Name || hostingAbsent ||
			readErr != nil || !found || agentNamespace != co.Namespace {
			return "", "", fmt.Errorf("HostedCluster identity does not match this order")
		}
	}
	if err := r.apiReader.Get(ctx, client.ObjectKey{Name: controlPlane}, ns); err != nil {
		if !apierrors.IsNotFound(err) {
			return "", "", fmt.Errorf("reading control-plane namespace: %w", err)
		}
	} else if hostingAbsent {
		return "", "", fmt.Errorf("control-plane namespace exists without validated hosting namespace")
	}
	return hosting, controlPlane, nil
}

func (r *Reconciler) workerDescendantsAbsent(ctx context.Context, hosting, controlPlane string) (bool, error) {
	kinds := append([]schema.GroupKind{{Group: hypershiftAPIGroup, Kind: nodePoolKind}}, workerProducerKinds...)
	for _, kind := range kinds {
		// Select a served version using discovery, rather than treating NoMatch on
		// a hard-coded beta version as absence (CAPI may serve v1beta1 or v1beta2).
		mapping, err := r.RESTMapper().RESTMapping(kind)
		if err != nil {
			return false, fmt.Errorf("discovering required %s API: %w", kind, err)
		}
		list := &unstructured.UnstructuredList{}
		list.SetGroupVersionKind(mapping.GroupVersionKind.GroupVersion().WithKind(kind.Kind + "List"))
		namespace := controlPlane
		if kind.Kind == nodePoolKind {
			namespace = hosting
		}
		// These namespaces are dedicated to this order. List every descendant,
		// including unlabelled/in-flight and terminating objects.
		if err := r.apiReader.List(ctx, list, client.InNamespace(namespace)); err != nil {
			return false, fmt.Errorf("listing %s in %s: %w", kind, namespace, err)
		}
		if len(list.Items) != 0 {
			return false, nil
		}
	}
	return true, nil
}

func (r *Reconciler) checkPrebindingIdentity(
	ctx context.Context, co *v1alpha1.ClusterOrder, w *v1alpha1.WorkerStatus, agent *unstructured.Unstructured, tenant string,
) error {
	labels := agent.GetLabels()
	if agent.GetNamespace() != co.Namespace || labels[clusterOrderLabel] != co.Name ||
		labels[workerNameLabel] != w.Name || labels[infraEnvAgentLabel] != co.Name+infraEnvNameSuffix {
		return fmt.Errorf("agent order/worker/InfraEnv identity mismatch")
	}
	if err := checkOptionalTenantIdentity(agent, co, tenant); err != nil {
		return err
	}
	ie := &unstructured.Unstructured{}
	ie.SetGroupVersionKind(infraEnvGVK)
	if err := r.apiReader.Get(ctx, client.ObjectKey{Namespace: co.Namespace, Name: co.Name + infraEnvNameSuffix}, ie); err != nil {
		return fmt.Errorf("reading Agent InfraEnv: %w", err)
	}
	if ie.GetUID() == "" || string(ie.GetUID()) != co.Annotations[infraEnvUIDAnnotation] || !ie.GetDeletionTimestamp().IsZero() {
		return fmt.Errorf("InfraEnv identity changed or InfraEnv is deleting")
	}
	if err := checkOptionalTenantIdentity(ie, co, tenant); err != nil {
		return err
	}
	if !hasExactOwner(ie, "osac.openshift.io", "ClusterOrder", co.Name, string(co.UID)) ||
		!hasExactOwner(agent, infraEnvGVK.Group, "InfraEnv", ie.GetName(), string(ie.GetUID())) {
		return fmt.Errorf("Agent/InfraEnv ownership is missing or ambiguous")
	}
	return nil
}

// Assisted Service does not necessarily copy tenant annotations onto Agent or
// InfraEnv. Tenant identity is anchored in the authoritative Cluster/BMI and the
// live order -> InfraEnv -> Agent UID chain. Reject conflicting annotations too.
func checkOptionalTenantIdentity(obj client.Object, co *v1alpha1.ClusterOrder, tenant string) error {
	if value, exists := obj.GetAnnotations()["osac.openshift.io/tenant"]; exists && value != tenant {
		return fmt.Errorf("%s has a foreign tenant annotation", obj.GetName())
	}
	if value, exists := obj.GetAnnotations()[ownerReferenceAnnotation]; exists && value != "ClusterOrder/"+co.Name {
		return fmt.Errorf("%s has a foreign order annotation", obj.GetName())
	}
	return nil
}

func hasExactOwner(obj client.Object, group, kind, name, uid string) bool {
	owners := obj.GetOwnerReferences()
	if len(owners) != 1 || uid == "" {
		return false
	}
	owner := owners[0]
	gv, err := schema.ParseGroupVersion(owner.APIVersion)
	return err == nil && gv.Group == group && owner.Kind == kind && owner.Name == name && string(owner.UID) == uid
}

func agentHasOnlyPrebinding(agent *unstructured.Unstructured, co *v1alpha1.ClusterOrder) bool {
	if _, exists := agent.GetLabels()["agentMachineRef"]; exists {
		return false
	}
	if _, exists := agent.GetAnnotations()["agentMachineRefNamespace"]; exists {
		return false
	}
	for _, field := range []string{"machineConfigPool", "ignitionEndpointTokenReference", "ignitionEndpointHTTPHeaders"} {
		if _, found, err := unstructured.NestedFieldNoCopy(agent.Object, "spec", field); err != nil || found {
			return false
		}
	}
	ref, found, err := unstructured.NestedMap(agent.Object, "spec", "clusterDeploymentName")
	return err == nil && found && len(ref) == 2 && ref["name"] == co.Name && ref["namespace"] == co.Namespace
}
