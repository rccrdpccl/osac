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
	"strings"
	"time"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

const (
	workerPhaseWaitingForAgent = "WaitingForAgent"
	workerPhaseBinding         = "Binding"
	workerPhaseReady           = "Ready"
	workerPhaseFailed          = "Failed"

	agentBareMetalRoleLabel = "agentBareMetal"
	workerNameLabel         = "osac.openshift.io/worker-name"

	agentRegistrationTimeout = 30 * time.Minute
	agentRequeueInterval     = 30 * time.Second

	eventReasonAgentCorrelated          = "AgentCorrelated"
	eventReasonAgentRegistrationTimeout = "AgentRegistrationTimeout"
	eventReasonWorkerReady              = "WorkerReady"
)

const agentInstallAPIVersion = "v1beta1"

var agentGVK = schema.GroupVersionKind{
	Group: "agent-install.openshift.io", Version: agentInstallAPIVersion, Kind: "Agent",
}

// MACResolver returns the allocated host MAC for a BMI by its resource ID. The production
// implementation will read it from the BMI status once the proto field lands (OSAC-2308/OSAC-3254);
// the fake provides it out-of-band via SetHostMAC.
type MACResolver func(bmiID string) string

// matchAgentToBMI performs the three-dimension match: the Agent must be in the correct namespace,
// carry the cluster-order label, and have an inventory MAC that uniquely matches one BMI's host
// MAC. Returns the matched worker name, or empty string with ambiguous=true if multiple match.
func matchAgentToBMI(
	agent *unstructured.Unstructured,
	workers []v1alpha1.WorkerStatus,
	hostMAC MACResolver,
) (workerName string, ambiguous bool) {
	agentMACs := extractAgentMACs(agent)
	if len(agentMACs) == 0 {
		return "", false
	}

	var matched string
	for i := range workers {
		w := &workers[i]
		if w.Phase != workerPhaseWaitingForAgent {
			continue
		}
		bmiMAC := hostMAC(w.ResourceID)
		if bmiMAC == "" {
			continue
		}
		for _, aMAC := range agentMACs {
			if strings.EqualFold(aMAC, bmiMAC) {
				if matched != "" {
					return "", true
				}
				matched = w.Name
				break
			}
		}
	}
	return matched, false
}

// extractAgentMACs reads all MAC addresses from the Agent's status.inventory.interfaces[].macAddress.
func extractAgentMACs(agent *unstructured.Unstructured) []string {
	interfaces, found, err := unstructured.NestedSlice(agent.Object, "status", "inventory", "interfaces")
	if err != nil || !found {
		return nil
	}
	macs := make([]string, 0, len(interfaces))
	for _, iface := range interfaces {
		m, ok := iface.(map[string]interface{})
		if !ok {
			continue
		}
		mac, ok := m["macAddress"].(string)
		if !ok || mac == "" {
			continue
		}
		macs = append(macs, mac)
	}
	return macs
}

// correlateAgents watches Agent CRs in the ClusterOrder's namespace, matches each to a BMI by
// MAC, and performs late binding (sets clusterDeploymentName + labels). Returns updated workers
// with phase transitions and a requeue result if any workers are still waiting for agents.
func (r *Reconciler) correlateAgents(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) ([]v1alpha1.WorkerStatus, ctrl.Result, error) {
	agents, err := r.listAgents(ctx, co)
	if err != nil {
		return workers, ctrl.Result{}, err
	}

	r.advanceBindingWorkers(ctx, co, agents, workers)

	waitingCount := countWorkersInPhase(workers, workerPhaseWaitingForAgent)
	if waitingCount == 0 {
		return workers, ctrl.Result{}, nil
	}

	waitingCount -= r.matchAndBindAgents(ctx, co, agents, workers)

	workers = r.checkAgentRegistrationTimeout(ctx, co, workers)

	if waitingCount > 0 {
		return workers, ctrl.Result{RequeueAfter: agentRequeueInterval}, nil
	}
	return workers, ctrl.Result{}, nil
}

func (r *Reconciler) listAgents(ctx context.Context, co *v1alpha1.ClusterOrder) (*unstructured.UnstructuredList, error) {
	agentList := &unstructured.UnstructuredList{}
	agentList.SetGroupVersionKind(schema.GroupVersionKind{
		Group: agentGVK.Group, Version: agentGVK.Version, Kind: agentGVK.Kind + "List",
	})
	if err := r.List(ctx, agentList,
		client.InNamespace(co.Namespace),
		client.MatchingLabels{clusterOrderLabel: co.Name},
	); err != nil {
		return nil, fmt.Errorf("listing agents for %s: %w", co.Name, err)
	}
	return agentList, nil
}

// advanceBindingWorkers transitions workers from Binding → Ready when the bound Agent reports
// installed state.
func (r *Reconciler) advanceBindingWorkers(
	ctx context.Context, co *v1alpha1.ClusterOrder, agents *unstructured.UnstructuredList, workers []v1alpha1.WorkerStatus,
) {
	log := ctrllog.FromContext(ctx)
	for i := range workers {
		if workers[i].Phase != workerPhaseBinding {
			continue
		}
		if r.isAgentInstalled(agents, workers[i].Name) {
			workers[i].Phase = workerPhaseReady
			if workers[i].ReadySince == nil {
				now := metav1.Now()
				workers[i].ReadySince = &now
			}
			log.Info("worker ready", "worker", workers[i].Name)
			observeProvisioningDuration(tenantOf(co), workers[i])
			r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonWorkerReady, "AdvanceWorker",
				"worker %s is ready", workers[i].Name)
		}
	}
}

// matchAndBindAgents correlates unbound Agents to BMIs by MAC and performs late binding.
// Returns the number of newly bound workers.
func (r *Reconciler) matchAndBindAgents(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	agents *unstructured.UnstructuredList, workers []v1alpha1.WorkerStatus,
) int {
	bound := 0
	for idx := range agents.Items {
		agent := &agents.Items[idx]
		if agent.GetLabels()[workerNameLabel] != "" {
			continue
		}
		if r.tryCorrelateAgent(ctx, co, agent, workers) {
			bound++
		}
	}
	return bound
}

// tryCorrelateAgent attempts to match a single Agent to a BMI by MAC and bind it.
// Returns true if a worker was successfully bound.
func (r *Reconciler) tryCorrelateAgent(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	agent *unstructured.Unstructured, workers []v1alpha1.WorkerStatus,
) bool {
	log := ctrllog.FromContext(ctx)

	workerName, isAmbiguous := matchAgentToBMI(agent, workers, r.macResolver)
	if isAmbiguous {
		log.Error(nil, "multiple BMIs match agent MAC, skipping bind", "agent", agent.GetName())
		return false
	}
	if workerName == "" {
		return false
	}

	if err := r.bindAgent(ctx, co, agent, workerName); err != nil {
		log.Error(err, "binding agent failed", "agent", agent.GetName(), "worker", workerName)
		return false
	}

	setWorkerPhase(workers, workerName, workerPhaseBinding)
	if w := workerByName(workers, workerName); w != nil {
		observeCorrelationDuration(tenantOf(co), *w)
	}
	log.Info("agent correlated", "agent", agent.GetName(), "worker", workerName)
	r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonAgentCorrelated, "CorrelateAgent",
		"agent %s correlated to worker %s", agent.GetName(), workerName)
	return true
}

// bindAgent sets the Agent's clusterDeploymentName (late binding) and applies labels for
// cached lookup and role identification.
func (r *Reconciler) bindAgent(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	agent *unstructured.Unstructured, workerName string,
) error {
	base := agent.DeepCopy()

	if err := unstructured.SetNestedMap(agent.Object, map[string]interface{}{
		"name":      co.Name,
		"namespace": co.Namespace,
	}, "spec", "clusterDeploymentName"); err != nil {
		return fmt.Errorf("setting agent clusterDeploymentName: %w", err)
	}

	labels := agent.GetLabels()
	if labels == nil {
		labels = make(map[string]string)
	}
	labels[workerNameLabel] = workerName
	labels[agentBareMetalRoleLabel] = "true"
	agent.SetLabels(labels)

	return r.Patch(ctx, agent, client.MergeFrom(base))
}

// isAgentInstalled checks whether an Agent bound to the given worker is installed by looking
// at its status.debugInfo.state field.
func (r *Reconciler) isAgentInstalled(agentList *unstructured.UnstructuredList, workerName string) bool {
	for idx := range agentList.Items {
		agent := &agentList.Items[idx]
		if agent.GetLabels()[workerNameLabel] != workerName {
			continue
		}
		state, _, _ := unstructured.NestedString(agent.Object, "status", "debugInfo", "state")
		return state == "installed"
	}
	return false
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
		if w.Phase != workerPhaseWaitingForAgent {
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

// reconcileNodePoolReplicas sets the NodePool's spec.replicas to the number of correlated
// (Binding or Ready phase) agents. NodePools are discovered by the same label selector the
// ClusterOrder controller uses.
func (r *Reconciler) reconcileNodePoolReplicas(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) (ctrl.Result, error) {
	clusterRef := co.Status.ClusterReference
	if clusterRef == nil || clusterRef.Namespace == "" {
		return ctrl.Result{}, nil
	}

	nodePools, err := r.listNodePools(ctx, clusterRef.Namespace, co.Name)
	if err != nil {
		return ctrl.Result{}, err
	}
	if len(nodePools.Items) == 0 {
		ctrllog.FromContext(ctx).Info("no NodePool found, requeuing")
		return ctrl.Result{RequeueAfter: agentRequeueInterval}, nil
	}

	replicas := countCorrelatedWorkers(workers)
	return ctrl.Result{}, r.patchNodePoolReplicas(ctx, nodePools, replicas)
}

func (r *Reconciler) listNodePools(ctx context.Context, namespace, clusterOrderName string) (*unstructured.UnstructuredList, error) {
	nodePoolList := &unstructured.UnstructuredList{}
	nodePoolList.SetGroupVersionKind(schema.GroupVersionKind{
		Group: "hypershift.openshift.io", Version: "v1beta1", Kind: "NodePoolList",
	})
	if err := r.List(ctx, nodePoolList,
		client.InNamespace(namespace),
		client.MatchingLabels{"osac.openshift.io/clusterorder": clusterOrderName},
	); err != nil {
		return nil, fmt.Errorf("listing nodepools for %s: %w", clusterOrderName, err)
	}
	return nodePoolList, nil
}

func (r *Reconciler) patchNodePoolReplicas(ctx context.Context, nodePools *unstructured.UnstructuredList, replicas int64) error {
	log := ctrllog.FromContext(ctx)
	for idx := range nodePools.Items {
		np := &nodePools.Items[idx]
		currentReplicas, _, _ := unstructured.NestedInt64(np.Object, "spec", "replicas")
		if currentReplicas == replicas {
			continue
		}
		patch := np.DeepCopy()
		if err := unstructured.SetNestedField(patch.Object, replicas, "spec", "replicas"); err != nil {
			return fmt.Errorf("setting nodepool replicas: %w", err)
		}
		if err := r.Patch(ctx, patch, client.MergeFrom(np)); err != nil {
			return fmt.Errorf("patching nodepool %s replicas: %w", np.GetName(), err)
		}
		log.Info("updated NodePool replicas", "nodepool", np.GetName(), "replicas", replicas)
	}
	return nil
}

func countCorrelatedWorkers(workers []v1alpha1.WorkerStatus) int64 {
	var n int64
	for _, w := range workers {
		if w.Phase == workerPhaseBinding || w.Phase == workerPhaseReady {
			n++
		}
	}
	return n
}

// updateWorkerStatusWithCorrelation patches status.workers, aggregate counts, and the
// WorkersFailed condition on the ClusterOrder, re-reading and retrying on conflict.
// It also resets attemptCount for workers that have been Ready for MinHealthyDuration.
func (r *Reconciler) updateWorkerStatusWithCorrelation(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) error {
	log := ctrllog.FromContext(ctx)
	resetHealthyWorkers(log, co, workers)
	return r.patchStatusWithRetry(ctx, co, func(latest *v1alpha1.ClusterOrder) {
		latest.Status.Workers = workers
		desired, current, ready := computeWorkerAggregates(workers)
		latest.Status.DesiredWorkers = &desired
		latest.Status.CurrentWorkers = &current
		latest.Status.ReadyWorkers = &ready

		failedMsg := FormatWorkersFailed(workers)
		switch {
		case failedMsg != "":
			latest.SetStatusCondition(v1alpha1.ConditionWorkersFailed,
				metav1.ConditionTrue, failedMsg, reasonWorkersFailed)
		case apimeta.IsStatusConditionTrue(latest.Status.Conditions, v1alpha1.ConditionWorkersFailed):
			latest.SetStatusCondition(v1alpha1.ConditionWorkersFailed,
				metav1.ConditionFalse, "all workers healthy", reasonWorkersFailedCleared)
		}
	})
}

// resetHealthyWorkers resets attemptCount for workers that have been Ready for at least
// MinHealthyDuration, clearing their failure history.
func resetHealthyWorkers(log logr.Logger, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus) {
	now := time.Now()
	for i := range workers {
		w := &workers[i]
		if w.Phase != workerPhaseReady || w.AttemptCount == 0 || w.ReadySince == nil {
			continue
		}
		if now.Sub(w.ReadySince.Time) < minHealthyDuration {
			continue
		}
		log.Info("worker healthy for MinHealthyDuration, resetting attemptCount",
			"worker", w.Name, "previousAttempts", w.AttemptCount)
		w.AttemptCount = 0
		w.LastFailureReason = ""
		w.LastFailureMessage = ""
		w.LastFailureTime = nil
		w.NextRetryTime = nil
	}
}

func computeWorkerAggregates(workers []v1alpha1.WorkerStatus) (desired, current, ready int32) {
	for _, w := range workers {
		desired++
		switch w.Phase {
		case workerPhaseProvisioning, workerPhaseWaitingForAgent, workerPhaseBinding, workerPhaseReady,
			workerPhaseUnbinding, workerPhaseDeleting:
			current++
		}
		if w.Phase == workerPhaseReady {
			ready++
		}
	}
	return
}

func countWorkersInPhase(workers []v1alpha1.WorkerStatus, phase string) int {
	n := 0
	for i := range workers {
		if workers[i].Phase == phase {
			n++
		}
	}
	return n
}

func setWorkerPhase(workers []v1alpha1.WorkerStatus, name, phase string) {
	for i := range workers {
		if workers[i].Name == name {
			workers[i].Phase = phase
			return
		}
	}
}

func workerByName(workers []v1alpha1.WorkerStatus, name string) *v1alpha1.WorkerStatus {
	for i := range workers {
		if workers[i].Name == name {
			return &workers[i]
		}
	}
	return nil
}
