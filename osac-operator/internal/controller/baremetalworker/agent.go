// Copyright (c) 2026 Red Hat Inc.
// SPDX-License-Identifier: Apache-2.0

package baremetalworker

import (
	"context"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

const (
	agentInstallAPIVersion = "v1beta1"

	agentBareMetalRoleLabel = "agentBareMetal"
	workerNameLabel         = "osac.openshift.io/worker-name"
	infraEnvAgentLabel      = "infraenvs.agent-install.openshift.io"
	agentInstanceTypeLabel  = "osac.openshift.io/instance_type"
	agentNodeSetLabel       = "osac.openshift.io/node-set"

	agentRegistrationTimeout = 30 * time.Minute
	agentRequeueInterval     = 30 * time.Second

	eventReasonAgentCorrelated          = "AgentCorrelated"
	eventReasonAgentRegistrationTimeout = "AgentRegistrationTimeout"
	eventReasonWorkerReady              = "WorkerReady"
)

var agentGVK = schema.GroupVersionKind{
	Group: "agent-install.openshift.io", Version: agentInstallAPIVersion, Kind: "Agent",
}

// reconcileObservedAgents performs Agent actions against the invocation snapshot:
// it matches and binds unbound Agents, then enforces the registration timeout.
// Phase projection already happened once in observeExistingWorkers; this stage
// never re-derives phases from the Agent list, and after a bind or delete it
// leaves further observation to the next explicit invocation. Status persistence
// remains in the caller.
func (r *Reconciler) reconcileObservedAgents(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus, o *workerObservation,
) ([]v1alpha1.WorkerStatus, ctrl.Result, error) {
	workers = append([]v1alpha1.WorkerStatus(nil), workers...)
	if o.agents != nil {
		if _, err := r.matchAndBindAgents(ctx, co, o.agents, workers, r.workerMACResolver(o)); err != nil {
			return nil, ctrl.Result{}, err
		}
	}
	workers = r.checkAgentRegistrationTimeout(ctx, co, workers)

	if countWorkersInPhase(workers, workerPhaseWaitingForAgent) > 0 {
		return workers, ctrl.Result{RequeueAfter: agentRequeueInterval}, nil
	}
	return workers, ctrl.Result{}, nil
}

// observeAgentReadiness reports an actual Binding -> Ready transition from the
// single projection pass. Workers are matched by name because the projection may
// have removed entries; a missing previous entry is not a transition.
func (r *Reconciler) observeAgentReadiness(
	ctx context.Context, co *v1alpha1.ClusterOrder, previous, observed []v1alpha1.WorkerStatus,
) {
	for i := range observed {
		if observed[i].Phase != workerPhaseReady {
			continue
		}
		before := workerByName(previous, observed[i].Name)
		if before == nil || before.Phase != workerPhaseBinding {
			continue
		}
		ctrllog.FromContext(ctx).Info("worker ready", "worker", observed[i].Name)
		observeProvisioningDuration(tenantOf(co), observed[i])
		r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonWorkerReady, "AdvanceWorker",
			"worker %s is ready", observed[i].Name)
	}
}

// matchAndBindAgents correlates unbound Agents to BMIs by MAC and performs late binding.
// Returns the number of newly bound workers.
func (r *Reconciler) matchAndBindAgents(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	agents *unstructured.UnstructuredList, workers []v1alpha1.WorkerStatus, macs MACResolver,
) (int, error) {
	bound := 0
	for idx := range agents.Items {
		agent := &agents.Items[idx]
		if agent.GetLabels()[workerNameLabel] != "" {
			continue
		}
		matched, err := r.matchAndBindAgent(ctx, co, agent, workers, macs)
		if err != nil {
			return bound, err
		}
		if matched {
			bound++
		}
	}
	return bound, nil
}

// matchAndBindAgent matches a single Agent to a BMI by MAC, then binds it.
// Returns true if a worker was successfully bound.
func (r *Reconciler) matchAndBindAgent(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	agent *unstructured.Unstructured, workers []v1alpha1.WorkerStatus, macs MACResolver,
) (bool, error) {
	log := ctrllog.FromContext(ctx)

	workerName, isAmbiguous := matchAgentToBMI(ctx, agent, workers, macs)
	if isAmbiguous {
		log.Error(nil, "multiple BMIs match agent MAC, skipping bind", "agent", agent.GetName())
		return false, nil
	}
	if workerName == "" {
		return false, nil
	}

	worker := workerByName(workers, workerName)
	if err := r.bindAgent(ctx, co, agent, worker); err != nil {
		return false, err
	}

	setWorkerPhase(workers, workerName, workerPhaseBinding)
	if worker != nil {
		observeCorrelationDuration(tenantOf(co), *worker)
	}
	log.Info("agent correlated", "agent", agent.GetName(), "worker", workerName)
	r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonAgentCorrelated, "CorrelateAgent",
		"agent %s correlated to worker %s", agent.GetName(), workerName)
	return true, nil
}

// bindAgent sets the Agent's clusterDeploymentName (late binding), marks it approved,
// and applies labels for NodePool selection and role identification.
func (r *Reconciler) bindAgent(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	agent *unstructured.Unstructured, worker *v1alpha1.WorkerStatus,
) error {
	reader := r.apiReader
	if reader == nil {
		reader = r.Client
	}
	latest := &unstructured.Unstructured{}
	latest.SetGroupVersionKind(agentGVK)
	if err := reader.Get(ctx, client.ObjectKeyFromObject(agent), latest); err != nil {
		return err
	}
	if latest.GetUID() != agent.GetUID() {
		return fmt.Errorf("agent %s identity changed before binding", agent.GetName())
	}
	if err := verifyAgentBinding(latest, co, worker); err != nil {
		return err
	}
	base := latest.DeepCopy()

	if err := unstructured.SetNestedMap(latest.Object, map[string]interface{}{
		"name":      co.Name,
		"namespace": co.Namespace,
	}, "spec", "clusterDeploymentName"); err != nil {
		return fmt.Errorf("setting agent clusterDeploymentName: %w", err)
	}

	if err := unstructured.SetNestedField(latest.Object, true, "spec", "approved"); err != nil {
		return fmt.Errorf("setting agent approved: %w", err)
	}

	labels := latest.GetLabels()
	if labels == nil {
		labels = make(map[string]string)
	}
	workerName := ""
	if worker != nil {
		workerName = worker.Name
		labels[agentNodeSetLabel] = worker.NodeSet
		if worker.InstanceType != "" {
			labels[agentInstanceTypeLabel] = worker.InstanceType
		}
	}
	labels[workerNameLabel] = workerName
	labels[agentBareMetalRoleLabel] = "true"
	labels[clusterOrderLabel] = co.Name
	labels["osac.openshift.io/clusterorder"] = co.Name
	latest.SetLabels(labels)

	return r.Patch(ctx, latest, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
}

// verifyAgentBinding prevents reassigning an Agent, including when its binding
// changed after the reconcile snapshot or during an optimistic-lock conflict.
func verifyAgentBinding(agent *unstructured.Unstructured, co *v1alpha1.ClusterOrder, worker *v1alpha1.WorkerStatus) error {
	if worker == nil || agent.GetNamespace() != co.Namespace {
		return fmt.Errorf("agent %s has no eligible worker in the cluster namespace", agent.GetName())
	}
	labels := agent.GetLabels()
	for _, key := range []string{clusterOrderLabel, "osac.openshift.io/clusterorder"} {
		if labels[key] != "" && labels[key] != co.Name {
			return fmt.Errorf("agent %s belongs to another cluster", agent.GetName())
		}
	}
	if labels[workerNameLabel] != "" && labels[workerNameLabel] != worker.Name {
		return fmt.Errorf("agent %s belongs to another worker", agent.GetName())
	}
	name, _, _ := unstructured.NestedString(agent.Object, "spec", "clusterDeploymentName", "name")
	namespace, _, _ := unstructured.NestedString(agent.Object, "spec", "clusterDeploymentName", "namespace")
	if (name != "" && name != co.Name) || (namespace != "" && namespace != co.Namespace) {
		return fmt.Errorf("agent %s is bound to another cluster deployment", agent.GetName())
	}
	return nil
}

// checkAgentRegistrationTimeout transitions workers stuck in WaitingForAgent past the timeout
// to Failed with reason AgentRegistrationTimeout.
func (r *Reconciler) checkAgentRegistrationTimeout(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) []v1alpha1.WorkerStatus {
	log := ctrllog.FromContext(ctx)
	now := time.Now()

	for i := range workers {
		w := &workers[i]
		if !eligibleForAgentObservation(*w) || w.Phase != workerPhaseWaitingForAgent {
			continue
		}
		phaseStart := r.workerPhaseStartTime(co, w.Name)
		if phaseStart.IsZero() {
			continue
		}
		if now.Sub(phaseStart) < agentRegistrationTimeout {
			continue
		}
		w.Phase = workerPhaseFailed
		w.LastFailureReason = eventReasonAgentRegistrationTimeout
		w.LastFailureMessage = fmt.Sprintf("no agent registered within %s", agentRegistrationTimeout)
		failTime := metav1.NewTime(now)
		w.LastFailureTime = &failTime
		observeProvisioningFailure(tenantOf(co), *w)
		log.Info("agent registration timeout", "worker", w.Name)
		r.recorder.Eventf(co, nil, corev1.EventTypeWarning, eventReasonAgentRegistrationTimeout, "CheckTimeout",
			"worker %s: no agent registered within %s", w.Name, agentRegistrationTimeout)
	}
	return workers
}

// workerPhaseStartTime returns when a worker entered its current phase by checking the
// ClusterOrder's existing status.workers. For WaitingForAgent workers that were just
// transitioned, uses the resource version change time approximation.
func (r *Reconciler) workerPhaseStartTime(co *v1alpha1.ClusterOrder, workerName string) time.Time {
	for _, w := range co.Status.Workers {
		if w.Name == workerName && w.Phase == workerPhaseWaitingForAgent {
			if w.LastFailureTime != nil {
				return w.LastFailureTime.Time
			}
			return co.CreationTimestamp.Time
		}
	}
	return time.Time{}
}
