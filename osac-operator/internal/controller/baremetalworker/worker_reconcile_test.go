// Copyright (c) 2026 Red Hat Inc.
// SPDX-License-Identifier: Apache-2.0

package baremetalworker

import (
	"context"
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
	privatev1 "github.com/osac-project/osac/proto/gen/osac/private/v1"
)

// These public reconciles deliberately stop at the pull-secret gate. Identity and
// Agent repair must already be durable, without allocation or provisioning.
type workerReadClient struct {
	*bmiObservationClient
	listed []*privatev1.BareMetalInstance
	lists  int
}

func (f *workerReadClient) ListBareMetalInstances(context.Context, string) ([]*privatev1.BareMetalInstance, error) {
	f.lists++
	return f.listed, f.listErr
}
func (f *workerReadClient) GetCluster(_ context.Context, id string) (*privatev1.Cluster, error) {
	return privatev1.Cluster_builder{Id: id, Metadata: privatev1.Metadata_builder{Tenant: "tenant"}.Build(), Spec: privatev1.ClusterSpec_builder{Version: privatev1.ClusterVersionReference_builder{Id: "cv"}.Build()}.Build()}.Build(), nil
}
func workerReadHarness(t *testing.T) (*Reconciler, *workerReadClient, *v1alpha1.ClusterOrder) {
	t.Helper()
	r, fc, co := bmiStageHarness(t, workerPhaseWaitingForAgent, "recorded-id")
	if err := corev1.AddToScheme(r.scheme); err != nil {
		t.Fatal(err)
	}
	co.Finalizers = []string{bmWorkerFinalizer}
	co.Labels = map[string]string{clusterOrderIDLabel: "cluster"}
	co.Annotations = map[string]string{"osac.openshift.io/tenant": "tenant"}
	if err := r.Update(context.Background(), co); err != nil {
		t.Fatal(err)
	}
	provider := &workerReadClient{bmiObservationClient: fc}
	r = NewReconciler(r.Client, r.apiReader, r.scheme, provider, nil, r.recorder, co.Namespace)
	return r, provider, co
}
func TestR01FinalizerReturnsBeforeObservation(t *testing.T) {
	r, fc, co := workerReadHarness(t)
	co.Finalizers = nil
	if err := r.Update(context.Background(), co); err != nil {
		t.Fatal(err)
	}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)})
	if err != nil || res.IsZero() {
		t.Fatalf("finalizer boundary: result=%+v err=%v", res, err)
	}
	if err := r.apiReader.Get(context.Background(), client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if len(co.Finalizers) != 1 || co.Finalizers[0] != bmWorkerFinalizer || fc.lists != 0 || len(fc.names) != 0 {
		t.Fatalf("continued past finalizer persistence: finalizers=%v lists=%d creates=%v", co.Finalizers, fc.lists, fc.names)
	}
}

func TestR01RepairReturnsBeforePrerequisites(t *testing.T) {
	r, fc, co := workerReadHarness(t)
	co.Status.Workers[0].BareMetalInstance.ID = ""
	co.Status.Workers[0].Phase = workerPhaseProvisioning
	if err := r.Status().Update(context.Background(), co); err != nil {
		t.Fatal(err)
	}
	fc.listed = []*privatev1.BareMetalInstance{ownedBMIFixture(co, "recorded-bmi", "created-id")}
	res, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)})
	if err != nil || res.IsZero() {
		t.Fatalf("repair entered missing pull-secret gate: result=%+v err=%v", res, err)
	}
	if err := r.apiReader.Get(context.Background(), client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if co.Status.Workers[0].BareMetalInstance.ID != "created-id" || len(fc.names) != 0 {
		t.Fatal("repair not persisted before returning")
	}
}

func TestWorkerObservationReadBudget(t *testing.T) {
	for _, omitted := range []bool{false, true} {
		t.Run(map[bool]string{false: "listed", true: "omitted"}[omitted], func(t *testing.T) {
			r, fc, co := workerReadHarness(t)
			bmi := ownedBMIFixture(co, "recorded-bmi", "recorded-id")
			bmi.SetStatus(privatev1.BareMetalInstanceStatus_builder{Hardware: privatev1.BareMetalHardware_builder{Nics: []*privatev1.BareMetalNICStatus{privatev1.BareMetalNICStatus_builder{Mac: "aa"}.Build()}}.Build()}.Build())
			fc.bmis = []*privatev1.BareMetalInstance{bmi}
			if !omitted {
				fc.listed = fc.bmis
			}
			a := agentPhaseFixture("", false)
			a.SetNamespace(co.Namespace)
			a.SetLabels(map[string]string{infraEnvAgentLabel: co.Name + infraEnvNameSuffix})
			_ = unstructured.SetNestedSlice(a.Object, []interface{}{map[string]interface{}{"macAddress": "aa"}}, "status", "inventory", "interfaces")
			if err := r.Create(context.Background(), a); err != nil {
				t.Fatal(err)
			}
			_, err := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)})
			if err == nil {
				t.Fatal("expected pull-secret gate for unchanged observation")
			}
			wantGets := 0
			if omitted {
				wantGets = 1
			}
			if fc.lists != 1 || fc.gets != wantGets {
				t.Fatalf("observation lists=%d gets=%d, want 1/%d", fc.lists, fc.gets, wantGets)
			}
			if len(fc.names) != 0 {
				t.Fatal("created before prerequisite gate")
			}
		})
	}
}
func TestWorkerObservationOutageBeforePrerequisites(t *testing.T) {
	for _, err := range []error{status.Error(codes.Internal, "list outage"), ErrFulfillmentServiceUnavailable} {
		t.Run(err.Error(), func(t *testing.T) {
			r, fc, co := workerReadHarness(t)
			fc.bmis = []*privatev1.BareMetalInstance{ownedBMIFixture(co, "recorded-bmi", "recorded-id")}
			fc.listErr = err
			before := co.DeepCopy()
			res, gotErr := r.Reconcile(context.Background(), ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)})
			if errors.Is(err, ErrFulfillmentServiceUnavailable) {
				if gotErr != nil || res.RequeueAfter != unavailableBackoff {
					t.Fatalf("result=%+v error=%v", res, gotErr)
				}
			} else if status.Code(gotErr) != codes.Internal {
				t.Fatalf("error=%v, want list outage", gotErr)
			}
			if err := r.Get(context.Background(), client.ObjectKeyFromObject(co), co); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(before.Status.Workers, co.Status.Workers) {
				t.Fatal("outage changed workers")
			}
			if fc.lists != 1 || fc.gets != 0 {
				t.Fatalf("outage lists=%d gets=%d", fc.lists, fc.gets)
			}
		})
	}
}
func TestBMIRecoveryRejectsAmbiguousNames(t *testing.T) {
	r, fc, co := bmiStageHarness(t, workerPhaseProvisioning, "")
	fc.bmis = []*privatev1.BareMetalInstance{ownedBMIFixture(co, "recorded-bmi", "first"), ownedBMIFixture(co, "recorded-bmi", "second")}
	if _, _, err := runBMIStage(context.Background(), r, co); err == nil {
		t.Fatal("adopted ambiguous name")
	}
	if err := r.Get(context.Background(), client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if co.Status.Workers[0].BareMetalInstance.ID != "" {
		t.Fatal("persisted ambiguous identity")
	}
}
func TestEarlyAgentObservationStopsOnConcurrentWorkerState(t *testing.T) {
	for _, mutation := range []string{"appended", "failed", "history"} {
		t.Run(mutation, func(t *testing.T) {
			r, _, co := bmiStageHarness(t, workerPhaseWaitingForAgent, "id")
			kube := r.Client
			var concurrent v1alpha1.WorkerStatus
			conflict := &bmiConflictClient{Client: kube, beforePatch: func() {
				latest := &v1alpha1.ClusterOrder{}
				if err := kube.Get(context.Background(), client.ObjectKeyFromObject(co), latest); err != nil {
					t.Fatal(err)
				}
				switch mutation {
				case "appended":
					latest.Status.Workers = append(latest.Status.Workers, newWorkerStatus("standard", "standard", "new-slot", "new-id", workerPhaseBinding))
				case "failed":
					latest.Status.Workers[0].Phase = workerPhaseFailed
				case "history":
					latest.Status.Workers[0].AttemptCount = 7
				}
				concurrent = latest.Status.Workers[len(latest.Status.Workers)-1]
				if err := kube.Status().Update(context.Background(), latest); err != nil {
					t.Fatal(err)
				}
				if err := kube.Get(context.Background(), client.ObjectKeyFromObject(co), latest); err != nil {
					t.Fatal(err)
				}
				concurrent = latest.Status.Workers[len(latest.Status.Workers)-1]
			}}
			r.Client = conflict
			agents := &unstructured.UnstructuredList{Items: []unstructured.Unstructured{*agentPhaseFixture("slot", true)}}
			observed := indexWorkerBMIs([]*privatev1.BareMetalInstance{ownedBMIFixture(co, "recorded-bmi", "id")})
			observed.agents = agents
			workers, err := r.observeExistingWorkers(context.Background(), co, "tenant", observed)
			if err != nil {
				t.Fatal(err)
			}
			err = r.updateWorkerStatus(context.Background(), co, workers)
			if !apierrors.IsConflict(err) {
				t.Fatalf("error=%v, want one-shot conflict", err)
			}
			if conflict.patches != 1 {
				t.Fatalf("status patches=%d, want 1", conflict.patches)
			}
			if err := kube.Get(context.Background(), client.ObjectKeyFromObject(co), co); err != nil {
				t.Fatal(err)
			}
			got := co.Status.Workers[len(co.Status.Workers)-1]
			if !reflect.DeepEqual(got, concurrent) {
				t.Fatalf("overwrote concurrent worker: got=%+v want=%+v", got, concurrent)
			}
		})
	}
}

func TestR02ConflictDoesNotRetry(t *testing.T) {
	ctx := context.Background()
	r, _, co := bmiStageHarness(t, workerPhaseBinding, "id")
	kube := r.Client
	conflict := &bmiConflictClient{Client: kube, beforePatch: func() {
		latest := &v1alpha1.ClusterOrder{}
		if err := kube.Get(ctx, client.ObjectKeyFromObject(co), latest); err != nil {
			t.Fatal(err)
		}
		latest.Status.Workers = append(latest.Status.Workers,
			newWorkerStatus("standard", "standard", "concurrent", "concurrent-id", workerPhaseReady))
		if err := kube.Status().Update(ctx, latest); err != nil {
			t.Fatal(err)
		}
	}}
	r.Client = conflict
	next := append([]v1alpha1.WorkerStatus(nil), co.Status.Workers...)
	next[0].Phase = workerPhaseReady

	err := r.updateWorkerStatus(ctx, co, next)
	if !apierrors.IsConflict(err) {
		t.Fatalf("error=%v, want one-shot conflict", err)
	}
	if conflict.patches != 1 {
		t.Fatalf("status patches=%d, want 1", conflict.patches)
	}
	latest := &v1alpha1.ClusterOrder{}
	if err := kube.Get(ctx, client.ObjectKeyFromObject(co), latest); err != nil {
		t.Fatal(err)
	}
	if len(latest.Status.Workers) != 2 || latest.Status.Workers[1].Name != "concurrent" {
		t.Fatalf("concurrent worker was not preserved: %+v", latest.Status.Workers)
	}
	if latest.Status.Workers[0].Phase != workerPhaseBinding {
		t.Fatalf("stale worker update was applied after conflict: %+v", latest.Status.Workers)
	}
}

func TestFinalWorkerStatusStopsOnConflict(t *testing.T) {
	ctx := context.Background()
	r, _, co := bmiStageHarness(t, workerPhaseBinding, "id")
	kube := r.Client
	conflict := &bmiConflictClient{Client: kube, beforePatch: func() {
		latest := &v1alpha1.ClusterOrder{}
		if err := kube.Get(ctx, client.ObjectKeyFromObject(co), latest); err != nil {
			t.Fatal(err)
		}
		latest.Status.Workers = append(latest.Status.Workers, newWorkerStatus("standard", "standard", "appended", "appended-id", workerPhaseReady))
		if err := kube.Status().Update(ctx, latest); err != nil {
			t.Fatal(err)
		}
	}}
	r.Client = conflict
	next := append([]v1alpha1.WorkerStatus(nil), co.Status.Workers...)
	next[0].Phase = workerPhaseReady
	if err := r.updateWorkerStatusWithAgent(ctx, co, next); !apierrors.IsConflict(err) {
		t.Fatalf("error=%v, want one-shot conflict", err)
	}
	if conflict.patches != 1 {
		t.Fatalf("status patches=%d, want 1", conflict.patches)
	}
	if err := kube.Get(ctx, client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if len(co.Status.Workers) != 2 || co.Status.Workers[1].Name != "appended" {
		t.Fatalf("lost appended worker: %+v", co.Status)
	}
	if co.Status.ReadyWorkers != nil {
		t.Fatalf("aggregates changed after conflict: %+v", co.Status)
	}
}

// R05-U1/U3: phase derivation happens exactly once, in the observation
// projection; the Agent action stage never re-derives phases from the snapshot.
func TestR05SingleProjectionStage(t *testing.T) {
	r, fc, co := workerReadHarness(t)
	fc.listed = []*privatev1.BareMetalInstance{ownedBMIFixture(co, "recorded-bmi", "recorded-id")}
	calls := 0
	r.SetMACResolver(func(context.Context, string) []string { calls++; return nil })
	observed, res, err := r.observeWorkerResources(context.Background(), co)
	if err != nil || !res.IsZero() {
		t.Fatalf("observation: %+v %v", res, err)
	}
	workers, err := r.observeExistingWorkers(context.Background(), co, "tenant", observed)
	if err != nil {
		t.Fatal(err)
	}
	if !workerSlicesEqual(co.Status.Workers, workers) {
		if err := r.updateWorkerStatus(context.Background(), co, workers); err != nil {
			t.Fatalf("status: %v", err)
		}
		if err := r.apiReader.Get(context.Background(), client.ObjectKeyFromObject(co), co); err != nil {
			t.Fatal(err)
		}
	}
	_, _, err = r.reconcileObservedAgents(context.Background(), co, co.Status.Workers, observed)
	if err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("phase MAC resolutions=%d, want exactly one projection", calls)
	}
}

func TestWorkerLocalMACResolverIsolationAndOverrides(t *testing.T) {
	ctx := context.Background()
	r := &Reconciler{}
	bmi := func(mac string) *privatev1.BareMetalInstance {
		return privatev1.BareMetalInstance_builder{Id: "same-id", Status: privatev1.BareMetalInstanceStatus_builder{Hardware: privatev1.BareMetalHardware_builder{Nics: []*privatev1.BareMetalNICStatus{privatev1.BareMetalNICStatus_builder{Mac: mac}.Build()}}.Build()}.Build()}.Build()
	}
	first := indexWorkerBMIs([]*privatev1.BareMetalInstance{bmi("first")})
	second := indexWorkerBMIs([]*privatev1.BareMetalInstance{bmi("second")})
	var wg sync.WaitGroup
	for _, tt := range []struct {
		o    *workerObservation
		want string
	}{{first, "first"}, {second, "second"}} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			resolve := r.workerMACResolver(tt.o)
			for range 100 {
				if got := resolve(ctx, "same-id"); !reflect.DeepEqual(got, []string{tt.want}) {
					t.Errorf("cross-invocation MACs=%v want=%s", got, tt.want)
				}
			}
		}()
	}
	wg.Wait()
	if r.macResolver != nil {
		t.Fatal("observation mutated shared resolver")
	}
	r.SetMACResolver(func(context.Context, string) []string { return []string{"override"} })
	if got := r.workerMACResolver(first)(ctx, "same-id"); !reflect.DeepEqual(got, []string{"override"}) {
		t.Fatalf("override ignored: %v", got)
	}
}
func TestWorkerFallbackGetMemoizesUnknownEvidence(t *testing.T) {
	r, fc, co := bmiStageHarness(t, workerPhaseWaitingForAgent, "missing")
	fc.getErr = status.Error(codes.Internal, "unknown ownership")
	o := indexWorkerBMIs(nil)
	o.agents = &unstructured.UnstructuredList{}
	if _, err := r.observeExistingWorkers(context.Background(), co, "tenant", o); err == nil {
		t.Fatal("unknown ownership permitted convergence")
	}
	r.macResolver = nil
	resolve := r.workerMACResolver(o)
	for range 3 {
		if got := resolve(context.Background(), "missing"); len(got) != 0 {
			t.Fatal("unknown evidence produced MACs")
		}
	}
	if fc.gets != 1 {
		t.Fatalf("fallback Gets=%d, want 1", fc.gets)
	}
}

func (f *workerReadClient) GetClusterVersion(context.Context, string) (*privatev1.ClusterVersion, error) {
	return privatev1.ClusterVersion_builder{Id: "cv"}.Build(), nil
}

func TestR04CleanupWithoutImageOrIgnition(t *testing.T) {
	ctx := context.Background()
	r, base, co := workerReadHarness(t)
	blocked := &r04PrereqClient{workerReadClient: base}
	r.fulfillment = blocked
	ignition := &countingIgnition{}
	r.ignition = ignition
	base.listed = []*privatev1.BareMetalInstance{
		ownedBMIFixture(co, "recorded-bmi", "recorded-id"),
		ownedBMIFixture(co, "excess", "excess-id"),
	}
	base.bmis = base.listed
	// One extra slot retires while every creation prerequisite is unavailable:
	// the pull secret is absent, the InfraEnv is gone and the image chain fails.
	co.Spec.NodeRequests[0].NumberOfNodes = 1
	if err := r.Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	co.Status.Workers = append(co.Status.Workers, newWorkerStatus("standard", "standard", "excess", "excess-id", workerPhaseWaitingForAgent))
	if err := r.Status().Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	res, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)})
	if err != nil || res.IsZero() {
		t.Fatalf("retirement boundary: result=%+v err=%v", res, err)
	}
	if err := r.Get(ctx, client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if got := workerByName(co.Status.Workers, "excess"); got == nil || got.Phase != workerPhaseUnbinding {
		t.Fatalf("retirement intent was not persisted without prerequisites: %+v", co.Status.Workers)
	}
	if len(blocked.names) != 0 || len(blocked.deletes) != 0 || ignition.calls != 0 {
		t.Fatalf("prerequisite-free retirement acted externally: creates=%v deletes=%v ignition=%d", blocked.names, blocked.deletes, ignition.calls)
	}

	// Cleanup proceeds on the next invocation even though the missing pull secret
	// is still reported, and it never fetches discovery ignition.
	if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)}); err == nil {
		t.Fatal("missing pull secret was not reported")
	}
	if len(blocked.deletes) != 1 || blocked.deletes[0] != "excess-id" {
		t.Fatalf("cleanup did not request BMI deletion: %v", blocked.deletes)
	}
	if ignition.calls != 0 || len(blocked.names) != 0 {
		t.Fatalf("cleanup fetched ignition or created a BMI: ignition=%d creates=%v", ignition.calls, blocked.names)
	}
}

func TestR04PendingRetryDoesNotBlockBinding(t *testing.T) {
	ctx := context.Background()
	r, base, co := workerReadHarness(t)
	fc := &r04PrereqClient{workerReadClient: base}
	r.fulfillment = fc
	future := metav1.NewTime(time.Now().Add(time.Hour))
	failed := newWorkerStatus("standard", "standard", "failed-bmi", "failed-id", workerPhaseFailed)
	failed.NextRetryTime = &future
	binding := newWorkerStatus("standard", "standard", "binding-bmi", "binding-id", workerPhaseBinding)
	co.Spec.NodeRequests[0].NumberOfNodes = 2
	co.Spec.PullSecret = `{"auths":{}}`
	if err := r.Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	co.Status.Workers = []v1alpha1.WorkerStatus{failed, binding}
	if err := r.Status().Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	fc.bmis = []*privatev1.BareMetalInstance{
		ownedBMIFixture(co, "failed-bmi", "failed-id"),
		ownedBMIFixture(co, "binding-bmi", "binding-id"),
	}
	fc.listed = fc.bmis
	agent := agentPhaseFixture("binding-bmi", true)
	agent.SetNamespace(co.Namespace)
	agent.SetLabels(map[string]string{workerNameLabel: "binding-bmi", clusterOrderLabel: co.Name})
	if err := unstructured.SetNestedSlice(agent.Object, []interface{}{map[string]interface{}{"macAddress": "aa:bb:cc:dd:ee:01"}}, "status", "inventory", "interfaces"); err != nil {
		t.Fatal(err)
	}
	if err := r.Create(ctx, agent); err != nil {
		t.Fatal(err)
	}
	// The first invocation projects the labeled Agent to Ready while the other
	// worker still waits for its retry; the second performs its pending cleanup.
	// A finite trace: binding converges on the first invocation, while the other
	// worker's cleanup proceeds on the next one that is not preempted by the
	// InfraEnv creation boundary.
	for i := 0; i < 4 && len(fc.deletes) == 0; i++ {
		if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)}); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.Get(ctx, client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if got := workerByName(co.Status.Workers, "binding-bmi"); got == nil || got.Phase != workerPhaseReady {
		t.Fatalf("binding did not converge past the pending retry: %+v", co.Status.Workers)
	}
	if got := workerByName(co.Status.Workers, "failed-bmi"); got == nil || got.Phase != workerPhaseFailed || got.BareMetalInstance.ID != "failed-id" {
		t.Fatalf("pending retry lost its recorded incarnation: %+v", co.Status.Workers)
	}
	if !reflect.DeepEqual(fc.deletes, []string{"failed-id"}) {
		t.Fatalf("pending cleanup deletes=%v, want the failed incarnation only", fc.deletes)
	}
	if deadline := r.workerRecheckDeadline(co.Status.Workers); deadline.RequeueAfter <= 0 {
		t.Fatalf("pending cleanup did not contribute a bounded recheck: %+v", deadline)
	}
}

func TestR04FairnessTraceAcrossWorkerStates(t *testing.T) {
	ctx := context.Background()
	r, base, co := workerReadHarness(t)
	fc := &r04PrereqClient{workerReadClient: base}
	r.fulfillment = fc
	// A ready worker with recent retry history must not be reset merely because
	// another worker is delayed.
	healthy := newWorkerStatus("standard", "standard", "healthy-bmi", "healthy-id", workerPhaseReady)
	healthy.AttemptCount = 2
	healthy.LastFailureReason = "previous"
	// metav1.Time persists at second precision, so compare at that precision.
	recent := metav1.NewTime(time.Now().Add(-time.Minute).Truncate(time.Second))
	healthy.ReadySince = &recent
	future := metav1.NewTime(time.Now().Add(time.Hour))
	pending := newWorkerStatus("standard", "standard", "pending-bmi", "pending-id", workerPhaseFailed)
	pending.NextRetryTime = &future
	waiting := newWorkerStatus("standard", "standard", "waiting-bmi", "waiting-id", workerPhaseWaitingForAgent)
	co.Spec.NodeRequests[0].NumberOfNodes = 3
	co.Spec.PullSecret = `{"auths":{}}`
	if err := r.Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	co.Status.Workers = []v1alpha1.WorkerStatus{healthy, pending, waiting}
	if err := r.Status().Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	fc.bmis = []*privatev1.BareMetalInstance{
		ownedBMIFixture(co, "healthy-bmi", "healthy-id"),
		ownedBMIFixture(co, "pending-bmi", "pending-id"),
		ownedBMIFixture(co, "waiting-bmi", "waiting-id"),
	}
	fc.listed = fc.bmis
	for i, name := range []string{"healthy-bmi", "waiting-bmi"} {
		agent := agentPhaseFixture(name, true)
		agent.SetName(name + "-agent")
		agent.SetNamespace(co.Namespace)
		agent.SetLabels(map[string]string{workerNameLabel: name, clusterOrderLabel: co.Name})
		mac := "aa:bb:cc:dd:ee:0" + string(rune('2'+i))
		if err := unstructured.SetNestedSlice(agent.Object, []interface{}{map[string]interface{}{"macAddress": mac}}, "status", "inventory", "interfaces"); err != nil {
			t.Fatal(err)
		}
		if err := r.Create(ctx, agent); err != nil {
			t.Fatal(err)
		}
	}
	for range 4 {
		if _, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)}); err != nil {
			t.Fatal(err)
		}
	}
	if err := r.Get(ctx, client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	bound := workerByName(co.Status.Workers, "waiting-bmi")
	if bound == nil || bound.Phase != workerPhaseReady {
		t.Fatalf("actionable worker did not converge: %+v", co.Status.Workers)
	}
	kept := workerByName(co.Status.Workers, "healthy-bmi")
	if kept == nil || kept.AttemptCount != 2 || kept.LastFailureReason != "previous" || kept.ReadySince == nil || !kept.ReadySince.Equal(&recent) {
		t.Fatalf("healthy worker history was reset by an unrelated delay: %+v", kept)
	}
	delayed := workerByName(co.Status.Workers, "pending-bmi")
	if delayed == nil || delayed.Phase != workerPhaseFailed || delayed.BareMetalInstance.ID != "pending-id" {
		t.Fatalf("delayed worker lost its recorded incarnation: %+v", delayed)
	}
	if len(fc.deletes) == 0 {
		t.Fatal("pending cleanup was starved by unrelated progress")
	}
	if deadline := r.workerRecheckDeadline(co.Status.Workers); deadline.RequeueAfter <= 0 {
		t.Fatalf("no bounded recheck for the delayed worker: %+v", deadline)
	}
}

func TestR04SummaryBeforeCreateGate(t *testing.T) {
	ctx := context.Background()
	r, base, co := workerReadHarness(t)
	imageErr := status.Error(codes.NotFound, "disk image unavailable")
	blocked := &r04PrereqClient{workerReadClient: base, imageErr: imageErr}
	r.fulfillment = blocked
	r.ignition = &countingIgnition{}
	blocked.listed = []*privatev1.BareMetalInstance{ownedBMIFixture(co, "recorded-bmi", "recorded-id")}
	blocked.bmis = blocked.listed
	// The worker was already demoted, but its aggregate summary is stale. A
	// scale-up makes the create gate due even though no slot needs a create yet.
	stale := int32(1)
	co.Spec.PullSecret = `{"auths":{}}`
	co.Spec.NodeRequests[0].NumberOfNodes = 2
	if err := r.Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	co.Status.ReadyWorkers = &stale
	if err := r.Status().Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	infra := &unstructured.Unstructured{Object: map[string]interface{}{}}
	infra.SetGroupVersionKind(infraEnvGVK)
	infra.SetName(co.Name + infraEnvNameSuffix)
	infra.SetNamespace(co.Namespace)
	infra.SetUID("infra-uid")
	if err := unstructured.SetNestedField(infra.Object, "http://ignition.test", "status", "bootArtifacts", "discoveryIgnitionURL"); err != nil {
		t.Fatal(err)
	}
	if err := r.Create(ctx, infra); err != nil {
		t.Fatal(err)
	}
	co.SetStatusCondition(v1alpha1.ConditionInfraEnvReady, metav1.ConditionTrue, "ready", reasonInfraEnvReady)
	if err := r.Status().Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	_, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)})
	if !errors.Is(err, imageErr) {
		t.Fatalf("error=%v, want the blocked image lookup", err)
	}
	if err := r.Get(ctx, client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if co.Status.ReadyWorkers == nil || *co.Status.ReadyWorkers != 0 {
		t.Fatalf("stale ready summary was not demoted before the create gate: %+v", co.Status)
	}
	if co.Status.DesiredWorkers == nil || *co.Status.DesiredWorkers != 1 || co.Status.CurrentWorkers == nil || *co.Status.CurrentWorkers != 1 {
		t.Fatalf("aggregate counts were not persisted: %+v", co.Status)
	}
	if len(blocked.names) != 0 {
		t.Fatalf("created a BMI under a blocked image lookup: %v", blocked.names)
	}
}

// r04PrereqClient records destructive actions and blocks the creation input
// chain, so prerequisite-free work can be asserted without resolving an image.
type r04PrereqClient struct {
	*workerReadClient
	deletes  []string
	imageErr error
}

func (f *r04PrereqClient) DeleteBareMetalInstance(_ context.Context, id string) error {
	f.deletes = append(f.deletes, id)
	return nil
}

// GetClusterVersion resolves a reference to an unusable disk image so image
// resolution fails after the tenant/version lookups succeed.
func (f *r04PrereqClient) GetClusterVersion(_ context.Context, id string) (*privatev1.ClusterVersion, error) {
	return privatev1.ClusterVersion_builder{
		Id:   id,
		Spec: privatev1.ClusterVersionSpec_builder{DiskImage: privatev1.DiskImageReference_builder{Id: "blocked"}.Build()}.Build(),
	}.Build(), nil
}

func (f *r04PrereqClient) GetDiskImage(context.Context, string) (*privatev1.DiskImage, error) {
	if f.imageErr != nil {
		return nil, f.imageErr
	}
	return nil, status.Error(codes.NotFound, "disk image unavailable")
}

type countingIgnition struct{ calls int }

func (c *countingIgnition) FetchIgnition(context.Context, string) ([]byte, error) {
	c.calls++
	return []byte(`{}`), nil
}

type workerIgnition struct{}

func (workerIgnition) FetchIgnition(context.Context, string) ([]byte, error) {
	return []byte(`{}`), nil
}

type staleFailureClient struct {
	client.Client
	err error
}

func (c *staleFailureClient) Status() client.SubResourceWriter {
	return &staleFailureWriter{SubResourceWriter: c.Client.Status(), err: c.err}
}

type staleFailureWriter struct {
	client.SubResourceWriter
	err error
}

func (w *staleFailureWriter) Patch(ctx context.Context, obj client.Object, p client.Patch, opts ...client.SubResourcePatchOption) error {
	co := obj.(*v1alpha1.ClusterOrder)
	if len(co.Status.Workers) > 0 && co.Status.Workers[0].Phase == workerPhaseFailed {
		return w.err
	}
	return w.SubResourceWriter.Patch(ctx, obj, p, opts...)
}
func TestStaleIgnitionPersistenceFailureDoesNotAdvanceUID(t *testing.T) {
	ctx := context.Background()
	r, fc, co := workerReadHarness(t)
	co.Spec.PullSecret = `{"auths":{}}`
	co.Annotations[infraEnvUIDAnnotation] = "old"
	if err := r.Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	co.SetStatusCondition(v1alpha1.ConditionInfraEnvReady, metav1.ConditionTrue, "ready", reasonInfraEnvReady)
	if err := r.Status().Update(ctx, co); err != nil {
		t.Fatal(err)
	}
	infra := &unstructured.Unstructured{}
	infra.SetGroupVersionKind(infraEnvGVK)
	infra.SetName(co.Name + infraEnvNameSuffix)
	infra.SetNamespace(co.Namespace)
	infra.SetUID("new")
	_ = unstructured.SetNestedField(infra.Object, "http://ignition.test", "status", "bootArtifacts", "discoveryIgnitionURL")
	if err := r.Create(ctx, infra); err != nil {
		t.Fatal(err)
	}
	fc.listed = []*privatev1.BareMetalInstance{ownedBMIFixture(co, "recorded-bmi", "recorded-id")}
	r.ignition = workerIgnition{}
	injected := errors.New("stale failure persistence interrupted")
	r.Client = &staleFailureClient{Client: r.Client, err: injected}
	_, err := r.Reconcile(ctx, ctrl.Request{NamespacedName: client.ObjectKeyFromObject(co)})
	if !errors.Is(err, injected) {
		t.Fatalf("error=%v, want persistence error", err)
	}
	if err := r.Get(ctx, client.ObjectKeyFromObject(co), co); err != nil {
		t.Fatal(err)
	}
	if co.Annotations[infraEnvUIDAnnotation] != "old" || co.Status.Workers[0].Phase != workerPhaseWaitingForAgent || len(fc.names) != 0 {
		t.Fatalf("advanced past failed stale-ignition persistence: %+v", co)
	}
}
