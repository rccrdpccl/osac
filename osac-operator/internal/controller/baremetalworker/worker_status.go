// Copyright (c) 2026 Red Hat Inc.
// SPDX-License-Identifier: Apache-2.0

package baremetalworker

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"time"

	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

const (
	workerKindBMI = "BareMetalInstance"

	workerPhaseProvisioning    = "Provisioning"
	workerPhaseWaitingForAgent = "WaitingForAgent"
	workerPhaseBinding         = "Binding"
	workerPhaseReady           = "Ready"
	workerPhaseFailed          = "Failed"
	workerPhaseUnbinding       = "Unbinding"
	workerPhaseDeleting        = "Deleting"

	reasonWorkersFailed        = "WorkersRetrying"
	reasonWorkersFailedCleared = "AllWorkersHealthy"

	reasonFulfillmentUnavailable = "FulfillmentServiceUnavailable"
	reasonFulfillmentAvailable   = "FulfillmentServiceAvailable"
	unavailableBackoff           = 5 * time.Minute
)

var errWorkerObservationChanged = errors.New("worker observation changed; reconcile again")

// patchStatusFromBase applies a single optimistic status patch. The caller must
// have obtained base from an authoritative read before making its observation or
// decision; a conflict deliberately aborts this invocation.
func (r *Reconciler) patchStatusFromBase(
	ctx context.Context, base, next *v1alpha1.ClusterOrder,
) error {
	if reflect.DeepEqual(base.Status, next.Status) {
		return nil
	}
	return r.Status().Patch(ctx, next, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
}

// patchStatus reads the authoritative order before applying a status-only
// mutation. It is used for condition writes that do not depend on an earlier
// external observation.
func (r *Reconciler) patchStatus(
	ctx context.Context, co *v1alpha1.ClusterOrder, mutate func(*v1alpha1.ClusterOrder),
) error {
	latest := co.DeepCopy()
	if err := r.readAuthoritativeOrder(ctx, latest); err != nil {
		return err
	}
	if !sameWorkerOrder(co, latest) {
		return errWorkerObservationChanged
	}
	base := latest.DeepCopy()
	mutate(latest)
	return r.patchStatusFromBase(ctx, base, latest)
}

func (r *Reconciler) readAuthoritativeOrder(ctx context.Context, co *v1alpha1.ClusterOrder) error {
	reader := r.apiReader
	if reader == nil {
		reader = r.Client
	}
	latest := &v1alpha1.ClusterOrder{}
	if err := reader.Get(ctx, client.ObjectKeyFromObject(co), latest); err != nil {
		return err
	}
	*co = *latest
	return nil
}

func (r *Reconciler) updateWorkerStatus(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) error {
	next := co.DeepCopy()
	next.Status.Workers = append([]v1alpha1.WorkerStatus(nil), workers...)
	return r.patchStatusFromBase(ctx, co, next)
}

// updateWorkerStatusWithAgent patches status.workers, aggregate counts, and the
// WorkersFailed condition on the ClusterOrder. It also resets attemptCount for
// workers that have been Ready for MinHealthyDuration.
func (r *Reconciler) updateWorkerStatusWithAgent(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) error {
	log := ctrllog.FromContext(ctx)
	workers = append([]v1alpha1.WorkerStatus(nil), workers...)
	resetHealthyWorkers(log, co, workers)
	next := co.DeepCopy()
	next.Status.Workers = workers
	desired, current, ready := computeWorkerAggregates(workers)
	next.Status.DesiredWorkers = &desired
	next.Status.CurrentWorkers = &current
	next.Status.ReadyWorkers = &ready

	failedMsg := FormatWorkersFailed(workers)
	switch {
	case failedMsg != "":
		next.SetStatusCondition(v1alpha1.ConditionWorkersFailed,
			metav1.ConditionTrue, failedMsg, reasonWorkersFailed)
	case apimeta.IsStatusConditionTrue(next.Status.Conditions, v1alpha1.ConditionWorkersFailed):
		next.SetStatusCondition(v1alpha1.ConditionWorkersFailed,
			metav1.ConditionFalse, "all workers healthy", reasonWorkersFailedCleared)
	}
	return r.patchStatusFromBase(ctx, co, next)
}

func sameWorkerOrder(observed, latest *v1alpha1.ClusterOrder) bool {
	return latest.UID == observed.UID && latest.Annotations["osac.openshift.io/tenant"] == observed.Annotations["osac.openshift.io/tenant"] &&
		latest.Labels[clusterOrderIDLabel] == observed.Labels[clusterOrderIDLabel] && latest.DeletionTimestamp.Equal(observed.DeletionTimestamp)
}

func sameCapacityPlan(expected, latest *v1alpha1.ClusterOrder) bool {
	return sameWorkerOrder(expected, latest) && expected.Generation == latest.Generation &&
		reflect.DeepEqual(expected.Spec, latest.Spec) && reflect.DeepEqual(expected.Status.Workers, latest.Status.Workers)
}

// checkCurrentCapacityPlan is an authoritative interruption boundary before an
// external action. Conditions may change, but spec, tenancy, deletion and all
// planned slots must still describe the plan. A stale plan returns before the
// action; a persistence conflict aborts the invocation rather than retrying
// inside it. The expectation never advances after an external action.
func (r *Reconciler) checkCurrentCapacityPlan(ctx context.Context, expected *v1alpha1.ClusterOrder) error {
	latest := &v1alpha1.ClusterOrder{}
	if err := r.apiReader.Get(ctx, client.ObjectKeyFromObject(expected), latest); err != nil {
		return err
	}
	if !sameCapacityPlan(expected, latest) {
		return errWorkerObservationChanged
	}
	return nil
}

// handleFulfillmentError is the single orchestration boundary for fulfillment
// availability evidence. Callers return the adapter's wrapped error unchanged;
// this boundary persists the order-scoped condition exactly once and applies the
// one bounded unavailable delay. A condition-write failure is surfaced instead
// of pretending the outage was recorded, and every non-availability error keeps
// its own caller policy (authoritative absence, ownership, retry, ...).
func (r *Reconciler) handleFulfillmentError(ctx context.Context, co *v1alpha1.ClusterOrder, err error) (ctrl.Result, error) {
	if !errors.Is(err, ErrFulfillmentServiceUnavailable) {
		return ctrl.Result{}, err
	}
	ctrllog.FromContext(ctx).Info("fulfillment service unavailable, backing off")
	if condErr := r.setFulfillmentServiceUnavailable(ctx, co, metav1.ConditionTrue,
		reasonFulfillmentUnavailable, err.Error()); condErr != nil {
		return ctrl.Result{}, fmt.Errorf("persisting fulfillment service unavailable condition: %w", condErr)
	}
	return ctrl.Result{RequeueAfter: unavailableBackoff}, nil
}

func (r *Reconciler) setFulfillmentServiceUnavailable(
	ctx context.Context, co *v1alpha1.ClusterOrder, condStatus metav1.ConditionStatus, reason, message string,
) error {
	return r.patchStatus(ctx, co, func(latest *v1alpha1.ClusterOrder) {
		latest.SetStatusCondition(v1alpha1.ConditionFulfillmentServiceUnavailable, condStatus, message, reason)
	})
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

// FormatWorkersFailed builds tenant-safe retry details from failed workers.
func FormatWorkersFailed(workers []v1alpha1.WorkerStatus) string {
	var parts []string
	for i := range workers {
		w := &workers[i]
		if w.Phase != workerPhaseFailed {
			continue
		}
		retry := "pending"
		if w.NextRetryTime != nil {
			retry = w.NextRetryTime.UTC().Format(time.RFC3339)
		}
		parts = append(parts, fmt.Sprintf("retry %d: attempt %d, next retry %s", len(parts)+1, w.AttemptCount, retry))
	}
	return strings.Join(parts, "; ")
}

func newWorkerStatus(nodeSet, instanceType, name, resourceID, phase string) v1alpha1.WorkerStatus {
	return v1alpha1.WorkerStatus{
		NodeSet:           nodeSet,
		InstanceType:      instanceType,
		Name:              name,
		Kind:              workerKindBMI,
		BareMetalInstance: v1alpha1.BareMetalInstanceReference{Name: name, ID: resourceID},
		Phase:             phase,
		CreationTimestamp: metav1.Now(),
	}
}

// workerCreated preserves the slot's history while recording the external identity.
func workerCreated(w *v1alpha1.WorkerStatus, name, id string) {
	w.BareMetalInstance = v1alpha1.BareMetalInstanceReference{Name: name, ID: id}
	w.Phase = workerPhaseWaitingForAgent
	w.NextRetryTime = nil
	if w.CreationTimestamp.IsZero() {
		w.CreationTimestamp = metav1.Now()
	}
}

func initializeReadySince(workers []v1alpha1.WorkerStatus) {
	now := metav1.Now()
	for i := range workers {
		if eligibleForAgentObservation(workers[i]) && workers[i].Phase == workerPhaseReady && workers[i].ReadySince == nil {
			workers[i].ReadySince = &now
		}
	}
}

func workerSlicesEqual(a, b []v1alpha1.WorkerStatus) bool {
	return reflect.DeepEqual(a, b)
}

func workerStatusesEqual(a, b []v1alpha1.WorkerStatus) bool {
	if len(a) != len(b) {
		return false
	}
	left := make(map[string]v1alpha1.WorkerStatus, len(a))
	for _, worker := range a {
		left[worker.Name] = worker
	}
	for _, worker := range b {
		other, ok := left[worker.Name]
		if !ok || !reflect.DeepEqual(other, worker) {
			return false
		}
	}
	return true
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

func workerByName(workers []v1alpha1.WorkerStatus, name string) *v1alpha1.WorkerStatus {
	for i := range workers {
		if workers[i].Name == name {
			return &workers[i]
		}
	}
	return nil
}
