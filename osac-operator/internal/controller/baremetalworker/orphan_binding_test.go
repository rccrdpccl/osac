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
	"encoding/json"
	"errors"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/tools/events"
	"sigs.k8s.io/controller-runtime/pkg/client"
	clientfake "sigs.k8s.io/controller-runtime/pkg/client/fake"

	v1alpha1 "github.com/osac-project/osac/osac-operator/api/v1alpha1"
	privatev1 "github.com/osac-project/osac/proto/gen/osac/private/v1"
)

var teardownTestKinds = []schema.GroupVersionKind{
	{Group: "hypershift.openshift.io", Version: "v1beta1", Kind: "HostedCluster"},
	{Group: "hypershift.openshift.io", Version: "v1beta1", Kind: "NodePool"},
	{Group: "cluster.x-k8s.io", Version: "v1beta2", Kind: "MachineDeployment"},
	{Group: "cluster.x-k8s.io", Version: "v1beta2", Kind: "MachineSet"},
	{Group: "cluster.x-k8s.io", Version: "v1beta2", Kind: "Machine"},
	{Group: "capi-provider.agent-install.openshift.io", Version: "v1beta1", Kind: "AgentMachine"},
}

type orphanFixture struct {
	r     *Reconciler
	co    *v1alpha1.ClusterOrder
	w     v1alpha1.WorkerStatus
	agent *unstructured.Unstructured
	c     client.Client
}

func newOrphanFixture(t *testing.T) *orphanFixture {
	t.Helper()
	s := runtime.NewScheme()
	if err := v1alpha1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	if err := corev1.AddToScheme(s); err != nil {
		t.Fatal(err)
	}
	mapper := apimeta.NewDefaultRESTMapper([]schema.GroupVersion{
		{Group: "hypershift.openshift.io", Version: "v1beta1"},
		{Group: "cluster.x-k8s.io", Version: "v1beta2"},
		{Group: "capi-provider.agent-install.openshift.io", Version: "v1beta1"},
	})
	for _, gvk := range append(append([]schema.GroupVersionKind{}, teardownTestKinds...), agentGVK, infraEnvGVK) {
		mapper.Add(gvk, apimeta.RESTScopeNamespace)
	}
	co := &v1alpha1.ClusterOrder{ObjectMeta: metav1.ObjectMeta{
		Name: "order", Namespace: "orders", UID: "order-uid",
		DeletionTimestamp: &metav1.Time{Time: time.Now()}, Finalizers: []string{bmWorkerFinalizer},
		Annotations: map[string]string{"osac.openshift.io/tenant": "tenant1", infraEnvUIDAnnotation: "infraenv-uid"},
		Labels:      map[string]string{clusterOrderIDLabel: "cluster-id"},
	}, Status: v1alpha1.ClusterOrderStatus{ProvisioningJobs: []v1alpha1.JobStatus{
		{JobID: "create", Type: v1alpha1.JobTypeProvision, State: v1alpha1.JobStateCanceled},
		{JobID: "delete", Type: v1alpha1.JobTypeDeprovision, State: v1alpha1.JobStateRunning},
	}}}
	w := v1alpha1.WorkerStatus{Name: "order-worker-0", Kind: workerKindBMI, ResourceID: "bmi-id", Phase: workerPhaseUnbinding}
	co.Status.Workers = []v1alpha1.WorkerStatus{w}
	fc := &foreignExcessClient{bmi: privatev1.BareMetalInstance_builder{Id: w.ResourceID, Metadata: privatev1.Metadata_builder{
		Name: w.Name, Tenant: "tenant1", Labels: map[string]string{clusterOrderLabel: co.Name},
		Annotations: map[string]string{ownerReferenceAnnotation: "ClusterOrder/" + co.Name},
	}.Build()}.Build()}
	r := &Reconciler{scheme: s, fulfillment: fc, recorder: events.NewFakeRecorder(100)}
	ie, err := r.buildInfraEnv(co, co.Name+infraEnvNameSuffix)
	if err != nil {
		t.Fatal(err)
	}
	ie.SetUID("infraenv-uid")
	agent := &unstructured.Unstructured{}
	agent.SetGroupVersionKind(agentGVK)
	agent.SetName("agent")
	agent.SetNamespace(co.Namespace)
	agent.SetUID("agent-uid")
	agent.SetOwnerReferences([]metav1.OwnerReference{{APIVersion: infraEnvGVK.GroupVersion().String(), Kind: "InfraEnv", Name: ie.GetName(), UID: ie.GetUID()}})
	agent.SetLabels(map[string]string{infraEnvAgentLabel: ie.GetName()})
	if err := unstructured.SetNestedField(agent.Object, "known", "status", "debugInfo", "state"); err != nil {
		t.Fatal(err)
	}
	c := clientfake.NewClientBuilder().WithScheme(s).WithRESTMapper(mapper).
		WithStatusSubresource(co).WithObjects(co, ie, agent).Build()
	r.Client, r.apiReader = c, c
	// Exercise the real production prebinding, not a test-manufactured cluster reference.
	if err := r.bindAgent(context.Background(), co, agent, &w); err != nil {
		t.Fatal(err)
	}
	if err := c.Get(context.Background(), client.ObjectKeyFromObject(agent), agent); err != nil {
		t.Fatal(err)
	}
	return &orphanFixture{r: r, co: co, w: w, agent: agent, c: c}
}

func (f *orphanFixture) drive() {
	f.r.processUnbindingWorker(context.Background(), f.co, &f.w,
		&unstructured.UnstructuredList{Items: []unstructured.Unstructured{*f.agent.DeepCopy()}}, time.Now())
}
func (f *orphanFixture) current(t *testing.T) *unstructured.Unstructured {
	t.Helper()
	a := &unstructured.Unstructured{}
	a.SetGroupVersionKind(agentGVK)
	if err := f.c.Get(context.Background(), client.ObjectKeyFromObject(f.agent), a); err != nil {
		t.Fatal(err)
	}
	return a
}
func assertPrebinding(t *testing.T, a *unstructured.Unstructured, present bool) {
	t.Helper()
	_, found, err := unstructured.NestedFieldNoCopy(a.Object, "spec", "clusterDeploymentName")
	if err != nil || found != present {
		t.Fatalf("cluster prebinding present=%v, want %v, error=%v", found, present, err)
	}
}

func TestOrphanBindingProgress(t *testing.T) {
	f := newOrphanFixture(t)
	f.drive()
	a := f.current(t)
	assertPrebinding(t, a, false)
	if f.w.Phase != workerPhaseUnbinding {
		t.Fatal("patch must not advance worker deletion")
	}
	if len(f.r.fulfillment.(*foreignExcessClient).deletes) != 0 {
		t.Fatal("patch must not delete BMI")
	}
	// Restart/duplicate reconcile before Assisted Service observes detachment must retain Agent.
	f.agent = a
	f.drive()
	f.current(t)
}

func TestOrphanBindingFailsClosed(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*orphanFixture)
	}{
		{"scale down", func(f *orphanFixture) { f.co.DeletionTimestamp = nil }},
		{"missing finalizer", func(f *orphanFixture) { f.co.Finalizers = nil }},
		{"stale UID", func(f *orphanFixture) { f.agent.SetUID("old-agent") }},
		{"missing UID", func(f *orphanFixture) { f.agent.SetUID("") }},
		{"foreign order tenant", func(f *orphanFixture) { f.co.Annotations["osac.openshift.io/tenant"] = "tenant2" }},
		{"missing reader", func(f *orphanFixture) { f.r.apiReader = nil }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newOrphanFixture(t)
			tc.mutate(f)
			f.drive()
			assertPrebinding(t, f.current(t), true)
		})
	}
	for _, tc := range []struct {
		name   string
		mutate func(*unstructured.Unstructured)
	}{
		{"foreign Agent tenant", func(a *unstructured.Unstructured) {
			a.SetAnnotations(map[string]string{"osac.openshift.io/tenant": "tenant2"})
		}},
		{"foreign order", func(a *unstructured.Unstructured) { l := a.GetLabels(); l[clusterOrderLabel] = "other"; a.SetLabels(l) }},
		{"foreign worker", func(a *unstructured.Unstructured) { l := a.GetLabels(); l[workerNameLabel] = "other"; a.SetLabels(l) }},
		{"missing order identity", func(a *unstructured.Unstructured) { l := a.GetLabels(); delete(l, clusterOrderLabel); a.SetLabels(l) }},
		{"foreign InfraEnv", func(a *unstructured.Unstructured) {
			l := a.GetLabels()
			l[infraEnvAgentLabel] = "other"
			a.SetLabels(l)
		}},
		{"missing InfraEnv owner", func(a *unstructured.Unstructured) { a.SetOwnerReferences(nil) }},
		{"foreign InfraEnv UID", func(a *unstructured.Unstructured) {
			o := a.GetOwnerReferences()
			o[0].UID = "foreign"
			a.SetOwnerReferences(o)
		}},
		{"other cluster namespace", func(a *unstructured.Unstructured) {
			_ = unstructured.SetNestedField(a.Object, "other", "spec", "clusterDeploymentName", "namespace")
		}},
		{"malformed cluster reference", func(a *unstructured.Unstructured) {
			_ = unstructured.SetNestedField(a.Object, "invalid", "spec", "clusterDeploymentName")
		}},
		{"machine label", func(a *unstructured.Unstructured) {
			l := a.GetLabels()
			l["agentMachineRef"] = "machine"
			a.SetLabels(l)
		}},
		{"empty machine label", func(a *unstructured.Unstructured) { l := a.GetLabels(); l["agentMachineRef"] = ""; a.SetLabels(l) }},
		{"machine annotation", func(a *unstructured.Unstructured) {
			a.SetAnnotations(map[string]string{"agentMachineRefNamespace": "control-plane"})
		}},
		{"machine config pool", func(a *unstructured.Unstructured) {
			_ = unstructured.SetNestedField(a.Object, "worker", "spec", "machineConfigPool")
		}},
		{"ignition token", func(a *unstructured.Unstructured) {
			_ = unstructured.SetNestedMap(a.Object, map[string]interface{}{"name": "token"}, "spec", "ignitionEndpointTokenReference")
		}},
		{"ignition headers", func(a *unstructured.Unstructured) {
			_ = unstructured.SetNestedSlice(a.Object, []interface{}{}, "spec", "ignitionEndpointHTTPHeaders")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newOrphanFixture(t)
			a := f.current(t)
			tc.mutate(a)
			if err := f.c.Update(context.Background(), a); err != nil {
				t.Fatal(err)
			}
			f.drive()
			assertPrebinding(t, f.current(t), true)
		})
	}
	for _, tc := range []struct {
		name   string
		mutate func(*v1alpha1.ClusterOrder)
	}{
		{"nonterminal provision", func(co *v1alpha1.ClusterOrder) { co.Status.ProvisioningJobs[0].State = v1alpha1.JobStateRunning }},
		{"unknown provision", func(co *v1alpha1.ClusterOrder) { co.Status.ProvisioningJobs[0].State = v1alpha1.JobStateUnknown }},
		{"no deprovision evidence", func(co *v1alpha1.ClusterOrder) { co.Status.ProvisioningJobs = co.Status.ProvisioningJobs[:1] }},
		{"missing deprovision ID", func(co *v1alpha1.ClusterOrder) { co.Status.ProvisioningJobs[1].JobID = "" }},
		{"ambiguous worker status", func(co *v1alpha1.ClusterOrder) {
			other := co.Status.Workers[0]
			other.ResourceID = "another-bmi"
			co.Status.Workers = append(co.Status.Workers, other)
		}},
		{"wrong status namespace", func(co *v1alpha1.ClusterOrder) {
			co.Status.ClusterReference = &v1alpha1.ClusterOrderClusterReferenceType{Namespace: "foreign"}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newOrphanFixture(t)
			live := f.co.DeepCopy()
			tc.mutate(live)
			if err := f.c.Status().Update(context.Background(), live); err != nil {
				t.Fatal(err)
			}
			f.drive()
			assertPrebinding(t, f.current(t), true)
		})
	}
}

func TestOrphanBindingStaleDetachedObservation(t *testing.T) {
	f := newOrphanFixture(t)
	// Cached detachment must not bypass the recovery guards or delete live binding.
	unstructured.RemoveNestedField(f.agent.Object, "spec", "clusterDeploymentName")
	_ = unstructured.SetNestedField(f.agent.Object, "known-unbound", "status", "debugInfo", "state")
	f.drive()
	assertPrebinding(t, f.current(t), false)
	if f.w.Phase != workerPhaseUnbinding {
		t.Fatal("must observe real detachment on a later reconcile")
	}
}

func TestOrphanBindingAmbiguousAgents(t *testing.T) {
	f := newOrphanFixture(t)
	other := f.agent.DeepCopy()
	other.SetName("second-agent")
	other.SetUID("second-uid")
	other.SetResourceVersion("")
	if err := f.c.Create(context.Background(), other); err != nil {
		t.Fatal(err)
	}
	f.drive()
	assertPrebinding(t, f.current(t), true)
}

func TestOrphanBindingNamespaces(t *testing.T) {
	for _, tc := range []struct {
		name           string
		hostingLabel   string
		controlPlane   bool
		hostedCluster  bool
		agentNamespace string
		recover        bool
	}{
		{"early provisioning", "", false, false, "", true},
		{"validated live cluster", "order", true, true, "orders", true},
		{"foreign hosting namespace", "foreign", false, false, "", false},
		{"control plane without hosting identity", "", true, false, "", false},
		{"foreign HostedCluster Agent namespace", "order", true, true, "foreign", false},
		{"missing HostedCluster Agent namespace", "order", true, true, "", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newOrphanFixture(t)
			if tc.hostingLabel != "" {
				if err := f.c.Create(context.Background(), &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "orders-order", Labels: map[string]string{"osac.openshift.io/clusterorder": tc.hostingLabel}}}); err != nil {
					t.Fatal(err)
				}
			}
			if tc.controlPlane {
				if err := f.c.Create(context.Background(), &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: "orders-order-order"}}); err != nil {
					t.Fatal(err)
				}
			}
			if tc.hostedCluster {
				hc := &unstructured.Unstructured{}
				hc.SetGroupVersionKind(teardownTestKinds[0])
				hc.SetName(f.co.Name)
				hc.SetNamespace("orders-order")
				hc.SetLabels(map[string]string{"osac.openshift.io/clusterorder": f.co.Name})
				if tc.agentNamespace != "" {
					_ = unstructured.SetNestedField(hc.Object, tc.agentNamespace, "spec", "platform", "agent", "agentNamespace")
				}
				if err := f.c.Create(context.Background(), hc); err != nil {
					t.Fatal(err)
				}
			}
			f.drive()
			assertPrebinding(t, f.current(t), !tc.recover)
		})
	}
}

func TestOrphanBindingWaitsForAllDescendants(t *testing.T) {
	for _, gvk := range teardownTestKinds[1:] {
		for _, terminating := range []bool{false, true} {
			t.Run(gvk.Kind+map[bool]string{false: " active", true: " terminating"}[terminating], func(t *testing.T) {
				f := newOrphanFixture(t)
				u := &unstructured.Unstructured{}
				u.SetGroupVersionKind(gvk)
				u.SetName("unlabelled-descendant")
				u.SetNamespace("orders-order-order")
				if gvk.Kind == "NodePool" {
					u.SetNamespace("orders-order")
				}
				if terminating {
					u.SetFinalizers([]string{"provider-finalizer"})
				}
				if err := f.c.Create(context.Background(), u); err != nil {
					t.Fatal(err)
				}
				if terminating {
					if err := f.c.Delete(context.Background(), u); err != nil {
						t.Fatal(err)
					}
				}
				f.drive()
				assertPrebinding(t, f.current(t), true)
			})
		}
	}
}

type recoveryFaultClient struct {
	client.Client
	getErr, listErr, patchErr error
	claimBeforePatch          bool
	patches                   [][]byte
}

func (c *recoveryFaultClient) Get(ctx context.Context, k client.ObjectKey, o client.Object, opts ...client.GetOption) error {
	if c.getErr != nil {
		return c.getErr
	}
	return c.Client.Get(ctx, k, o, opts...)
}
func (c *recoveryFaultClient) List(ctx context.Context, o client.ObjectList, opts ...client.ListOption) error {
	if c.listErr != nil {
		return c.listErr
	}
	return c.Client.List(ctx, o, opts...)
}
func (c *recoveryFaultClient) Patch(ctx context.Context, o client.Object, p client.Patch, opts ...client.PatchOption) error {
	data, err := p.Data(o)
	if err != nil {
		return err
	}
	c.patches = append(c.patches, data)
	if c.patchErr != nil {
		return c.patchErr
	}
	if c.claimBeforePatch {
		c.claimBeforePatch = false
		a := &unstructured.Unstructured{}
		a.SetGroupVersionKind(agentGVK)
		if err := c.Client.Get(ctx, client.ObjectKeyFromObject(o), a); err != nil {
			return err
		}
		l := a.GetLabels()
		l["agentMachineRef"] = "new-claim"
		a.SetLabels(l)
		if err := c.Client.Update(ctx, a); err != nil {
			return err
		}
	}
	return c.Client.Patch(ctx, o, p, opts...)
}

func TestOrphanBindingLiveReadsAndPatchRaces(t *testing.T) {
	for _, tc := range []struct {
		name      string
		configure func(*recoveryFaultClient)
	}{
		{"get failure", func(c *recoveryFaultClient) { c.getErr = errors.New("unavailable") }},
		{"list failure", func(c *recoveryFaultClient) {
			c.listErr = apierrors.NewForbidden(schema.GroupResource{Group: "cluster.x-k8s.io", Resource: "machines"}, "", errors.New("denied"))
		}},
		{"unserved API", func(c *recoveryFaultClient) {
			c.listErr = &apimeta.NoKindMatchError{GroupKind: schema.GroupKind{Group: "cluster.x-k8s.io", Kind: "Machine"}}
		}},
		{"patch conflict", func(c *recoveryFaultClient) {
			c.patchErr = apierrors.NewConflict(schema.GroupResource{Group: agentGVK.Group, Resource: "agents"}, "agent", errors.New("conflict"))
		}},
		{"claim between GET and PATCH", func(c *recoveryFaultClient) { c.claimBeforePatch = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newOrphanFixture(t)
			c := &recoveryFaultClient{Client: f.c}
			tc.configure(c)
			f.r.Client = c
			f.r.apiReader = c
			f.drive()
			assertPrebinding(t, f.current(t), true)
			if len(c.patches) > 1 {
				t.Fatal("must not blindly retry a conflict")
			}
		})
	}
	t.Run("patch scope and optimistic lock", func(t *testing.T) {
		f := newOrphanFixture(t)
		c := &recoveryFaultClient{Client: f.c}
		f.r.Client = c
		f.r.apiReader = c
		f.drive()
		assertPrebinding(t, f.current(t), false)
		if len(c.patches) != 1 {
			t.Fatalf("got %d patches", len(c.patches))
		}
		var patch map[string]interface{}
		if err := json.Unmarshal(c.patches[0], &patch); err != nil {
			t.Fatal(err)
		}
		if len(patch) != 2 {
			t.Fatalf("unexpected patch: %s", c.patches[0])
		}
		spec, ok := patch["spec"].(map[string]interface{})
		if !ok || len(spec) != 1 || spec["clusterDeploymentName"] != nil {
			t.Fatalf("unexpected spec patch: %s", c.patches[0])
		}
		metadata, ok := patch["metadata"].(map[string]interface{})
		if !ok || len(metadata) != 1 || metadata["resourceVersion"] == nil {
			t.Fatalf("missing optimistic lock: %s", c.patches[0])
		}
	})
}
