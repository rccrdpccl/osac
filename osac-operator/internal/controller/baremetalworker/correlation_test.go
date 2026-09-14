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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/tools/events"
	clientfake "sigs.k8s.io/controller-runtime/pkg/client/fake"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

var _ = Describe("matchAgentToBMI", func() {
	makeAgent := func(macs ...string) *unstructured.Unstructured {
		interfaces := make([]interface{}, 0, len(macs))
		for _, mac := range macs {
			interfaces = append(interfaces, map[string]interface{}{"macAddress": mac})
		}
		agent := &unstructured.Unstructured{Object: map[string]interface{}{}}
		agent.SetGroupVersionKind(agentGVK)
		_ = unstructured.SetNestedSlice(agent.Object, interfaces, "status", "inventory", "interfaces")
		return agent
	}

	var (
		workers  []v1alpha1.WorkerStatus
		resolver MACResolver
	)

	BeforeEach(func() {
		workers = []v1alpha1.WorkerStatus{
			{Name: "w-0", ResourceID: "bmi-0", Phase: workerPhaseWaitingForAgent},
			{Name: "w-1", ResourceID: "bmi-1", Phase: workerPhaseWaitingForAgent},
			{Name: "w-2", ResourceID: "bmi-2", Phase: workerPhaseBinding},
		}
		// bmi-1 reports two NICs — correlation must match against any of them.
		hostMACs := map[string][]string{
			"bmi-0": {"aa:bb:cc:dd:ee:00"},
			"bmi-1": {"aa:bb:cc:dd:ee:11", "aa:bb:cc:dd:ee:1f"},
			"bmi-2": {"aa:bb:cc:dd:ee:22"},
		}
		resolver = func(_ context.Context, id string) []string { return hostMACs[id] }
	})

	DescribeTable("matches agents to workers by MAC",
		func(agentMACs []string, wantWorker string, wantAmbig bool) {
			agent := makeAgent(agentMACs...)
			gotWorker, gotAmbig := matchAgentToBMI(context.Background(), agent, workers, resolver)
			Expect(gotWorker).To(Equal(wantWorker))
			Expect(gotAmbig).To(Equal(wantAmbig))
		},
		Entry("unique match", []string{"aa:bb:cc:dd:ee:00"}, "w-0", false),
		Entry("case-insensitive match", []string{"AA:BB:CC:DD:EE:11"}, "w-1", false),
		Entry("no match", []string{"ff:ff:ff:ff:ff:ff"}, "", false),
		Entry("empty agent MACs", nil, "", false),
		Entry("ambiguous — agent MAC matches two BMIs", []string{"aa:bb:cc:dd:ee:00", "aa:bb:cc:dd:ee:11"}, "", true),
		Entry("skips workers not in WaitingForAgent phase", []string{"aa:bb:cc:dd:ee:22"}, "", false),
		Entry("multiple interfaces, one matches", []string{"ff:ff:ff:ff:ff:ff", "aa:bb:cc:dd:ee:00"}, "w-0", false),
		Entry("matches a BMI's secondary NIC", []string{"aa:bb:cc:dd:ee:1f"}, "w-1", false),
	)
})

var _ = Describe("extractAgentMACs", func() {
	DescribeTable("extracts MAC addresses from agent inventory",
		func(obj map[string]interface{}, want []string) {
			agent := &unstructured.Unstructured{Object: obj}
			got := extractAgentMACs(agent)
			if want == nil {
				Expect(got).To(BeNil())
			} else {
				Expect(got).To(Equal(want))
			}
		},
		Entry("single interface",
			map[string]interface{}{
				"status": map[string]interface{}{
					"inventory": map[string]interface{}{
						"interfaces": []interface{}{
							map[string]interface{}{"macAddress": "aa:bb:cc:dd:ee:ff"},
						},
					},
				},
			},
			[]string{"aa:bb:cc:dd:ee:ff"},
		),
		Entry("multiple interfaces",
			map[string]interface{}{
				"status": map[string]interface{}{
					"inventory": map[string]interface{}{
						"interfaces": []interface{}{
							map[string]interface{}{"macAddress": "11:22:33:44:55:66"},
							map[string]interface{}{"macAddress": "aa:bb:cc:dd:ee:ff"},
						},
					},
				},
			},
			[]string{"11:22:33:44:55:66", "aa:bb:cc:dd:ee:ff"},
		),
		Entry("no inventory",
			map[string]interface{}{},
			nil,
		),
		Entry("empty interfaces",
			map[string]interface{}{
				"status": map[string]interface{}{
					"inventory": map[string]interface{}{
						"interfaces": []interface{}{},
					},
				},
			},
			[]string{},
		),
	)
})

var _ = Describe("advanceBindingWorkers", func() {
	makeAgent := func(workerName, conditionStatus string, debugInstalled bool) unstructured.Unstructured {
		agent := unstructured.Unstructured{Object: map[string]interface{}{}}
		agent.SetGroupVersionKind(agentGVK)
		agent.SetLabels(map[string]string{workerNameLabel: workerName})
		if conditionStatus != "" {
			_ = unstructured.SetNestedSlice(agent.Object, []interface{}{
				map[string]interface{}{"type": "Installed", "status": conditionStatus},
			}, "status", "conditions")
		}
		if debugInstalled {
			_ = unstructured.SetNestedField(agent.Object, "installed", "status", "debugInfo", "state")
		}
		return agent
	}

	DescribeTable("advances only when the Agent is installed",
		func(conditionStatus string, debugInstalled bool, wantPhase string) {
			r := &Reconciler{recorder: events.NewFakeRecorder(1)}
			workers := []v1alpha1.WorkerStatus{{
				Name:              "w-0",
				Phase:             workerPhaseBinding,
				CreationTimestamp: metav1.Now(),
			}}
			agents := &unstructured.UnstructuredList{Items: []unstructured.Unstructured{
				makeAgent("w-0", conditionStatus, debugInstalled),
			}}

			r.advanceBindingWorkers(context.Background(), &v1alpha1.ClusterOrder{}, agents, workers)

			Expect(workers[0].Phase).To(Equal(wantPhase))
		},
		Entry("Installed=True without debug state", "True", false, workerPhaseReady),
		Entry("Installed=False overrides stale debug state", "False", true, workerPhaseBinding),
		Entry("Installed=Unknown overrides stale debug state", "Unknown", true, workerPhaseBinding),
		Entry("legacy debug state when condition is absent", "", true, workerPhaseReady),
	)
})

var _ = Describe("requestedBareMetalWorkersByResourceClass", func() {
	It("counts requested bare-metal workers before any Agent is correlated", func() {
		co := &v1alpha1.ClusterOrder{}
		co.Spec.NodeRequests = []v1alpha1.NodeRequest{
			{ResourceClass: "bm-worker", NumberOfNodes: 2,
				BareMetal: &v1alpha1.BareMetalNodeSpec{InstanceType: "bm-worker"}},
			{NumberOfNodes: 3},
		}

		Expect(requestedBareMetalWorkersByResourceClass(co)).To(Equal(map[string]int64{
			"bm-worker": 2,
		}))
	})
})

var _ = Describe("reconcileNodePoolReplicas", func() {
	It("keeps replica counts isolated by resource class", func() {
		nodePoolGVK := schema.GroupVersionKind{
			Group: "hypershift.openshift.io", Version: "v1beta1", Kind: "NodePool",
		}
		nodePoolListGVK := nodePoolGVK
		nodePoolListGVK.Kind = "NodePoolList"
		s := runtime.NewScheme()
		Expect(v1alpha1.AddToScheme(s)).To(Succeed())
		s.AddKnownTypeWithName(nodePoolGVK, &unstructured.Unstructured{})
		s.AddKnownTypeWithName(nodePoolListGVK, &unstructured.UnstructuredList{})

		co := &v1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{Name: "co-replicas", Namespace: "osac"},
			Spec: v1alpha1.ClusterOrderSpec{
				NodeRequests: []v1alpha1.NodeRequest{
					{ResourceClass: "bm-standard", NumberOfNodes: 2,
						BareMetal: &v1alpha1.BareMetalNodeSpec{InstanceType: "bm-standard"}},
					{ResourceClass: "bm-gpu", NumberOfNodes: 1,
						BareMetal: &v1alpha1.BareMetalNodeSpec{InstanceType: "bm-gpu"}},
				},
			},
			Status: v1alpha1.ClusterOrderStatus{
				ClusterReference: &v1alpha1.ClusterOrderClusterReferenceType{Namespace: "workload"},
			},
		}

		makeNodePool := func(name, resourceClass string) *unstructured.Unstructured {
			np := &unstructured.Unstructured{Object: map[string]interface{}{}}
			np.SetGroupVersionKind(nodePoolGVK)
			np.SetName(name)
			np.SetNamespace("workload")
			np.SetLabels(map[string]string{
				"osac.openshift.io/clusterorder": co.Name,
				nodePoolResourceClassLabel:       resourceClass,
			})
			Expect(unstructured.SetNestedField(np.Object, int64(0), "spec", "replicas")).To(Succeed())
			return np
		}

		k8sClient := clientfake.NewClientBuilder().
			WithScheme(s).
			WithObjects(co, makeNodePool("standard", "bm-standard"), makeNodePool("gpu", "bm-gpu")).
			Build()
		r := &Reconciler{Client: k8sClient}

		_, err := r.reconcileNodePoolReplicas(context.Background(), co)
		Expect(err).ToNot(HaveOccurred())

		for name, want := range map[string]int64{"standard": 2, "gpu": 1} {
			np := &unstructured.Unstructured{}
			np.SetGroupVersionKind(nodePoolGVK)
			Expect(k8sClient.Get(context.Background(), types.NamespacedName{
				Name: name, Namespace: "workload",
			}, np)).To(Succeed())
			replicas, found, err := unstructured.NestedInt64(np.Object, "spec", "replicas")
			Expect(err).ToNot(HaveOccurred())
			Expect(found).To(BeTrue())
			Expect(replicas).To(Equal(want), name)
		}
	})
})
