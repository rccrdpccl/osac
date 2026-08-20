/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

package acceptance

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/record"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	osacv1alpha1 "github.com/osac-project/osac/osac-operator/api/v1alpha1"
	"github.com/osac-project/osac/osac-operator/internal/controller/baremetalworker"
	"github.com/osac-project/osac/osac-operator/internal/controller/baremetalworker/fake"
	"github.com/osac-project/osac/osac-operator/internal/testing/envsim"
)

var _ = Describe("BareMetalWorkerReconciler ensureInfraEnv", func() {
	var (
		sim *envsim.Simulator
		ign *fake.IgnitionServer
		rec *record.FakeRecorder
		r   *baremetalworker.Reconciler
	)

	BeforeEach(func() {
		sim = envsim.New(k8sClient)
		ign = fake.NewIgnitionServer()
		rec = record.NewFakeRecorder(10)
		r = baremetalworker.NewReconciler(k8sClient, k8sClient, scheme.Scheme,
			baremetalworker.NewIgnitionFetcher(nil), rec, testNamespace)
	})

	AfterEach(func() { ign.Close() })

	newBareMetalClusterOrder := func(name string) *osacv1alpha1.ClusterOrder {
		return &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: testNamespace},
			Spec: osacv1alpha1.ClusterOrderSpec{
				TemplateID:   "test",
				SSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5",
				NodeRequests: []osacv1alpha1.NodeRequest{{
					ResourceClass: "bm-standard",
					NumberOfNodes: 1,
					BareMetal: &osacv1alpha1.BareMetalNodeSpec{
						InstanceType: "bm-standard",
					},
				}},
			},
		}
	}

	runReconcile := func(name string) (reconcile.Result, error) {
		return r.Reconcile(ctx, reconcile.Request{
			NamespacedName: types.NamespacedName{Name: name, Namespace: testNamespace},
		})
	}

	getClusterOrder := func(name string) *osacv1alpha1.ClusterOrder {
		GinkgoHelper()
		co := &osacv1alpha1.ClusterOrder{}
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: name, Namespace: testNamespace}, co)).To(Succeed())
		return co
	}

	create := func(co *osacv1alpha1.ClusterOrder) {
		GinkgoHelper()
		Expect(k8sClient.Create(ctx, co)).To(Succeed())
		DeferCleanup(func() {
			_ = k8sClient.Delete(ctx, co)
			ie := newInfraEnv(co.Name + "-infraenv")
			_ = k8sClient.Delete(ctx, ie)
		})
	}

	It("creates an InfraEnv (late binding, owned by the ClusterOrder) and fetches its ignition [green]", func() {
		co := newBareMetalClusterOrder("bmw-green")
		create(co)

		// First reconcile: InfraEnv is created, ignition not ready yet -> requeue.
		res, err := runReconcile("bmw-green")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeNumerically(">", 0))

		ie := newInfraEnv("bmw-green-infraenv")
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(ie), ie)).To(Succeed())
		// Late binding: no clusterRef.
		_, hasClusterRef, _ := unstructured.NestedMap(ie.Object, "spec", "clusterRef")
		Expect(hasClusterRef).To(BeFalse())
		// Owned by the ClusterOrder.
		owners := ie.GetOwnerReferences()
		Expect(owners).To(HaveLen(1))
		Expect(owners[0].Kind).To(Equal("ClusterOrder"))
		Expect(owners[0].Name).To(Equal("bmw-green"))
		// pull secret referenced by convention.
		psName, _, _ := unstructured.NestedString(ie.Object, "spec", "pullSecretRef", "name")
		Expect(psName).To(Equal("bmw-green-pull-secret"))

		// InfraEnvReady is False while ignition is pending.
		cond := apimeta.FindStatusCondition(getClusterOrder("bmw-green").Status.Conditions, osacv1alpha1.ConditionInfraEnvReady)
		Expect(cond).ToNot(BeNil())
		Expect(cond.Status).To(Equal(metav1.ConditionFalse))

		// Simulator makes the discovery ignition available at the fake endpoint.
		Expect(sim.MarkInfraEnvReady(ctx, "bmw-green-infraenv", testNamespace, ign.URL())).To(Succeed())

		// Second reconcile: ignition fetched, InfraEnvReady=True, no requeue.
		res, err = runReconcile("bmw-green")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		Expect(apimeta.IsStatusConditionTrue(
			getClusterOrder("bmw-green").Status.Conditions, osacv1alpha1.ConditionInfraEnvReady)).To(BeTrue())
	})

	It("is idempotent: re-reconcile does not create a duplicate InfraEnv", func() {
		create(newBareMetalClusterOrder("bmw-idem"))

		_, err := runReconcile("bmw-idem")
		Expect(err).ToNot(HaveOccurred())
		_, err = runReconcile("bmw-idem")
		Expect(err).ToNot(HaveOccurred())

		list := &unstructured.UnstructuredList{}
		list.SetGroupVersionKind(infraEnvGVK)
		Expect(k8sClient.List(ctx, list, client.InNamespace(testNamespace))).To(Succeed())
		count := 0
		for i := range list.Items {
			if list.Items[i].GetName() == "bmw-idem-infraenv" {
				count++
			}
		}
		Expect(count).To(Equal(1))
	})

	It("emits DiscoveryIgnitionSizeWarning when ignition exceeds 48KB", func() {
		create(newBareMetalClusterOrder("bmw-big"))

		_, err := runReconcile("bmw-big")
		Expect(err).ToNot(HaveOccurred())

		ign.SetSize(50 * 1024) // above the 48KB warning threshold
		Expect(sim.MarkInfraEnvReady(ctx, "bmw-big-infraenv", testNamespace, ign.URL())).To(Succeed())

		_, err = runReconcile("bmw-big")
		Expect(err).ToNot(HaveOccurred())

		var events []string
		for done := false; !done; {
			select {
			case e := <-rec.Events:
				events = append(events, e)
			default:
				done = true
			}
		}
		Expect(events).To(ContainElement(ContainSubstring("DiscoveryIgnitionSizeWarning")))
	})

	It("ignores ClusterOrders without a bare-metal node set", func() {
		co := &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{Name: "bmw-none", Namespace: testNamespace},
			Spec: osacv1alpha1.ClusterOrderSpec{
				TemplateID: "test",
				NodeRequests: []osacv1alpha1.NodeRequest{{
					ResourceClass: "vm-standard",
					NumberOfNodes: 1,
				}},
			},
		}
		create(co)

		res, err := runReconcile("bmw-none")
		Expect(err).ToNot(HaveOccurred())
		Expect(res).To(Equal(reconcile.Result{}))

		ie := newInfraEnv("bmw-none-infraenv")
		err = k8sClient.Get(ctx, client.ObjectKeyFromObject(ie), ie)
		Expect(err).To(HaveOccurred(), "no InfraEnv should be created for a non-bare-metal ClusterOrder")
	})

	It("skips a ClusterOrder annotated management-state=unmanaged", func() {
		co := newBareMetalClusterOrder("bmw-unmanaged")
		co.Annotations = map[string]string{"osac.openshift.io/management-state": "unmanaged"}
		create(co)

		res, err := runReconcile("bmw-unmanaged")
		Expect(err).ToNot(HaveOccurred())
		Expect(res).To(Equal(reconcile.Result{}))

		ie := newInfraEnv("bmw-unmanaged-infraenv")
		err = k8sClient.Get(ctx, client.ObjectKeyFromObject(ie), ie)
		Expect(err).To(HaveOccurred(), "an unmanaged ClusterOrder must be skipped (no InfraEnv)")
	})

	It("returns an error when the discovery ignition fetch fails", func() {
		create(newBareMetalClusterOrder("bmw-fetcherr"))

		_, err := runReconcile("bmw-fetcherr")
		Expect(err).ToNot(HaveOccurred())

		// Point the InfraEnv at an unreachable ignition URL.
		Expect(sim.MarkInfraEnvReady(ctx, "bmw-fetcherr-infraenv", testNamespace,
			"http://127.0.0.1:0/discovery.ign")).To(Succeed())

		_, err = runReconcile("bmw-fetcherr")
		Expect(err).To(HaveOccurred())
	})
})
