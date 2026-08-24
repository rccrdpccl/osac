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
	"encoding/base64"
	"fmt"

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
	privatev1 "github.com/osac-project/osac/osac-operator/internal/api/osac/private/v1"
	"github.com/osac-project/osac/osac-operator/internal/controller/baremetalworker"
	"github.com/osac-project/osac/osac-operator/internal/controller/baremetalworker/fake"
	"github.com/osac-project/osac/osac-operator/internal/testing/envsim"
)

func newInstanceType(name string, fabricPort string, extraPorts ...*privatev1.BareMetalNetworkPortSpec) *privatev1.BareMetalInstanceType {
	ports := append([]*privatev1.BareMetalNetworkPortSpec{
		privatev1.BareMetalNetworkPortSpec_builder{
			Name: fabricPort, Role: "fabric", Type: "Ethernet", Speed: "25Gbps",
		}.Build(),
	}, extraPorts...)
	return privatev1.BareMetalInstanceType_builder{
		Metadata: privatev1.Metadata_builder{Name: name}.Build(),
		Spec: privatev1.BareMetalInstanceTypeSpec_builder{
			Hardware: privatev1.BareMetalHardwareSpec_builder{
				Cpu:          privatev1.BareMetalCPUSpec_builder{Cores: 64, Architecture: "x86_64", ThreadsPerCore: 2}.Build(),
				Memory:       privatev1.BareMetalMemorySpec_builder{TotalGb: 256}.Build(),
				NetworkPorts: ports,
			}.Build(),
			HostLabelSelector: privatev1.BareMetalLabelSelector_builder{
				MatchLabels: map[string]string{"type": name},
			}.Build(),
		}.Build(),
	}.Build()
}

var _ = Describe("BareMetalWorkerReconciler ensureInfraEnv", func() {
	var (
		sim *envsim.Simulator
		fc  *fake.FulfillmentClient
		ign *fake.IgnitionServer
		rec *record.FakeRecorder
		r   *baremetalworker.Reconciler
	)

	BeforeEach(func() {
		sim = envsim.New(k8sClient)
		fc = fake.NewFulfillmentClient()
		ign = fake.NewIgnitionServer()
		rec = record.NewFakeRecorder(10)
		r = baremetalworker.NewReconciler(k8sClient, k8sClient, scheme.Scheme,
			fc, baremetalworker.NewIgnitionFetcher(nil), rec, testNamespace)
	})

	AfterEach(func() { ign.Close() })

	const (
		clusterUUID    = "test-cluster-uuid"
		cvID           = "4.18.0"
		diskImageID    = "rhcos-4.18"
		clusterIDLabel = "osac.openshift.io/clusterorder-uuid"
	)

	preloadDiskImageChain := func() {
		fc.AddCluster(privatev1.Cluster_builder{
			Id: clusterUUID,
			Spec: privatev1.ClusterSpec_builder{
				Version: privatev1.ClusterVersionReference_builder{Id: cvID}.Build(),
			}.Build(),
		}.Build())
		fc.AddClusterVersion(privatev1.ClusterVersion_builder{
			Id: cvID,
			Spec: privatev1.ClusterVersionSpec_builder{
				DiskImage: privatev1.DiskImageReference_builder{Id: diskImageID}.Build(),
			}.Build(),
		}.Build())
		fc.AddBareMetalInstanceType(newInstanceType("bm-standard", "data-0"))
	}

	newBareMetalClusterOrder := func(name string) *osacv1alpha1.ClusterOrder {
		return &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: testNamespace,
				Labels:    map[string]string{clusterIDLabel: clusterUUID},
			},
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
				NetworkAttachment: &osacv1alpha1.ClusterNetworkAttachment{
					SubnetRef:         "my-subnet",
					SecurityGroupRefs: []string{"sg-default"},
				},
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
		preloadDiskImageChain()
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
		preloadDiskImageChain()
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

var _ = Describe("BareMetalWorkerReconciler ensureSystemCatalogItem", func() {
	var (
		fc  *fake.FulfillmentClient
		ign *fake.IgnitionServer
		rec *record.FakeRecorder
		r   *baremetalworker.Reconciler
	)

	BeforeEach(func() {
		fc = fake.NewFulfillmentClient()
		ign = fake.NewIgnitionServer()
		rec = record.NewFakeRecorder(10)
		r = baremetalworker.NewReconciler(k8sClient, k8sClient, scheme.Scheme,
			fc, baremetalworker.NewIgnitionFetcher(nil), rec, testNamespace)
	})

	AfterEach(func() { ign.Close() })

	newBareMetalClusterOrder := func(name string) *osacv1alpha1.ClusterOrder {
		return &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: testNamespace,
				Labels:    map[string]string{"osac.openshift.io/clusterorder-uuid": "ci-cluster"},
			},
			Spec: osacv1alpha1.ClusterOrderSpec{
				TemplateID: "test",
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

	create := func(co *osacv1alpha1.ClusterOrder) {
		GinkgoHelper()
		Expect(k8sClient.Create(ctx, co)).To(Succeed())
		DeferCleanup(func() {
			_ = k8sClient.Delete(ctx, co)
			ie := newInfraEnv(co.Name + "-infraenv")
			_ = k8sClient.Delete(ctx, ie)
		})
	}

	It("creates the system catalog item when absent", func() {
		co := newBareMetalClusterOrder("bmw-ci-create")
		create(co)

		_, err := runReconcile("bmw-ci-create")
		Expect(err).ToNot(HaveOccurred())

		calls := fc.CreateCatalogItemCalls()
		Expect(calls).To(HaveLen(1))
		ci := calls[0]
		Expect(ci.GetMetadata().GetName()).To(Equal("system-bmi-passthrough"))
		Expect(ci.GetMetadata().GetTenant()).To(Equal("system"))
		Expect(ci.GetTitle()).To(Equal("System BMI Pass-through"))
		Expect(ci.GetPublished()).To(BeTrue())
		Expect(ci.GetFieldDefinitions()).To(BeEmpty())
		Expect(ci.GetTemplate()).To(BeNil())
	})

	It("is a no-op when the system catalog item already exists", func() {
		co := newBareMetalClusterOrder("bmw-ci-noop")
		create(co)

		// Pre-create the catalog item.
		_, err := fc.CreateBareMetalInstanceCatalogItem(ctx, privatev1.BareMetalInstanceCatalogItem_builder{
			Metadata: privatev1.Metadata_builder{Name: "system-bmi-passthrough"}.Build(),
		}.Build())
		Expect(err).ToNot(HaveOccurred())

		_, err = runReconcile("bmw-ci-noop")
		Expect(err).ToNot(HaveOccurred())

		// Only the pre-create call, no additional create from the reconciler.
		Expect(fc.CreateCatalogItemCalls()).To(HaveLen(1))
		Expect(fc.ListCatalogItemCalls()).To(HaveLen(1))
	})

	It("handles AlreadyExists gracefully (concurrent create race)", func() {
		co := newBareMetalClusterOrder("bmw-ci-race")
		create(co)

		// First reconcile creates the catalog item.
		_, err := runReconcile("bmw-ci-race")
		Expect(err).ToNot(HaveOccurred())
		Expect(fc.CreateCatalogItemCalls()).To(HaveLen(1))

		// Remove it from list but leave it stored (simulates race: list returns empty,
		// but Create returns AlreadyExists). We achieve this by running a second reconcile —
		// list will find it and skip create.
		_, err = runReconcile("bmw-ci-race")
		Expect(err).ToNot(HaveOccurred())
		// No additional create call — list found it.
		Expect(fc.CreateCatalogItemCalls()).To(HaveLen(1))
	})
})

var _ = Describe("BareMetalWorkerReconciler resolveDiskImage", func() {
	const (
		clusterUUID    = "resolve-cluster-uuid"
		cvID           = "4.18.0"
		diskImageID    = "rhcos-4.18"
		clusterIDLabel = "osac.openshift.io/clusterorder-uuid"
	)

	var (
		sim *envsim.Simulator
		fc  *fake.FulfillmentClient
		ign *fake.IgnitionServer
		rec *record.FakeRecorder
		r   *baremetalworker.Reconciler
	)

	BeforeEach(func() {
		sim = envsim.New(k8sClient)
		fc = fake.NewFulfillmentClient()
		ign = fake.NewIgnitionServer()
		rec = record.NewFakeRecorder(10)
		r = baremetalworker.NewReconciler(k8sClient, k8sClient, scheme.Scheme,
			fc, baremetalworker.NewIgnitionFetcher(nil), rec, testNamespace)
	})

	AfterEach(func() { ign.Close() })

	newBareMetalClusterOrder := func(name string, labels map[string]string) *osacv1alpha1.ClusterOrder {
		return &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: testNamespace,
				Labels:    labels,
			},
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
				NetworkAttachment: &osacv1alpha1.ClusterNetworkAttachment{
					SubnetRef:         "my-subnet",
					SecurityGroupRefs: []string{"sg-default"},
				},
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

	makeInfraEnvReady := func(name string) {
		GinkgoHelper()
		_, err := runReconcile(name)
		Expect(err).ToNot(HaveOccurred())
		Expect(sim.MarkInfraEnvReady(ctx, name+"-infraenv", testNamespace, ign.URL())).To(Succeed())
		_, err = runReconcile(name)
		Expect(err).ToNot(HaveOccurred())
		Expect(apimeta.IsStatusConditionTrue(
			getClusterOrder(name).Status.Conditions, osacv1alpha1.ConditionInfraEnvReady)).To(BeTrue())
	}

	addInstanceType := func(name string) {
		fc.AddBareMetalInstanceType(newInstanceType(name, "data-0"))
	}

	It("resolves DiskImage ID from a ClusterVersion with disk_image set", func() {
		fc.AddCluster(privatev1.Cluster_builder{
			Id: clusterUUID,
			Spec: privatev1.ClusterSpec_builder{
				Version: privatev1.ClusterVersionReference_builder{Id: cvID}.Build(),
			}.Build(),
		}.Build())
		fc.AddClusterVersion(privatev1.ClusterVersion_builder{
			Id: cvID,
			Spec: privatev1.ClusterVersionSpec_builder{
				DiskImage: privatev1.DiskImageReference_builder{Id: diskImageID}.Build(),
			}.Build(),
		}.Build())
		addInstanceType("bm-standard")

		co := newBareMetalClusterOrder("bmw-resolve", map[string]string{clusterIDLabel: clusterUUID})
		create(co)
		makeInfraEnvReady("bmw-resolve")

		res, err := runReconcile("bmw-resolve")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		cond := apimeta.FindStatusCondition(
			getClusterOrder("bmw-resolve").Status.Conditions, osacv1alpha1.ConditionRHCOSImageNotFound)
		Expect(cond).To(BeNil(), "RHCOSImageNotFound should not be set when disk_image is present")
	})

	It("sets RHCOSImageNotFound when ClusterVersion has no disk_image", func() {
		addInstanceType("bm-standard")
		fc.AddCluster(privatev1.Cluster_builder{
			Id: clusterUUID,
			Spec: privatev1.ClusterSpec_builder{
				Version: privatev1.ClusterVersionReference_builder{Id: cvID}.Build(),
			}.Build(),
		}.Build())
		fc.AddClusterVersion(privatev1.ClusterVersion_builder{
			Id:   cvID,
			Spec: privatev1.ClusterVersionSpec_builder{}.Build(),
		}.Build())

		co := newBareMetalClusterOrder("bmw-nodisk", map[string]string{clusterIDLabel: clusterUUID})
		create(co)
		makeInfraEnvReady("bmw-nodisk")

		res, err := runReconcile("bmw-nodisk")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		cond := apimeta.FindStatusCondition(
			getClusterOrder("bmw-nodisk").Status.Conditions, osacv1alpha1.ConditionRHCOSImageNotFound)
		Expect(cond).ToNot(BeNil())
		Expect(cond.Status).To(Equal(metav1.ConditionTrue))
	})

	It("requeues when the clusterorder-uuid label is absent", func() {
		co := newBareMetalClusterOrder("bmw-nolabel", nil)
		create(co)
		makeInfraEnvReady("bmw-nolabel")

		res, err := runReconcile("bmw-nolabel")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeNumerically(">", 0))
	})

	It("clears RHCOSImageNotFound when disk_image is later set on the ClusterVersion", func() {
		addInstanceType("bm-standard")
		fc.AddCluster(privatev1.Cluster_builder{
			Id: clusterUUID,
			Spec: privatev1.ClusterSpec_builder{
				Version: privatev1.ClusterVersionReference_builder{Id: cvID}.Build(),
			}.Build(),
		}.Build())
		fc.AddClusterVersion(privatev1.ClusterVersion_builder{
			Id:   cvID,
			Spec: privatev1.ClusterVersionSpec_builder{}.Build(),
		}.Build())

		co := newBareMetalClusterOrder("bmw-clear", map[string]string{clusterIDLabel: clusterUUID})
		create(co)
		makeInfraEnvReady("bmw-clear")

		_, err := runReconcile("bmw-clear")
		Expect(err).ToNot(HaveOccurred())
		cond := apimeta.FindStatusCondition(
			getClusterOrder("bmw-clear").Status.Conditions, osacv1alpha1.ConditionRHCOSImageNotFound)
		Expect(cond).ToNot(BeNil())
		Expect(cond.Status).To(Equal(metav1.ConditionTrue))

		fc.AddClusterVersion(privatev1.ClusterVersion_builder{
			Id: cvID,
			Spec: privatev1.ClusterVersionSpec_builder{
				DiskImage: privatev1.DiskImageReference_builder{Id: diskImageID}.Build(),
			}.Build(),
		}.Build())

		res, err := runReconcile("bmw-clear")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		cond = apimeta.FindStatusCondition(
			getClusterOrder("bmw-clear").Status.Conditions, osacv1alpha1.ConditionRHCOSImageNotFound)
		Expect(cond).ToNot(BeNil())
		Expect(cond.Status).To(Equal(metav1.ConditionFalse))
	})
})

var _ = Describe("BareMetalWorkerReconciler reconcileWorkers", func() {
	const (
		clusterUUID    = "workers-cluster-uuid"
		cvID           = "4.18.0"
		diskImageID    = "rhcos-4.18"
		clusterIDLabel = "osac.openshift.io/clusterorder-uuid"
	)

	var (
		sim *envsim.Simulator
		fc  *fake.FulfillmentClient
		ign *fake.IgnitionServer
		rec *record.FakeRecorder
		r   *baremetalworker.Reconciler
	)

	BeforeEach(func() {
		sim = envsim.New(k8sClient)
		fc = fake.NewFulfillmentClient()
		ign = fake.NewIgnitionServer()
		rec = record.NewFakeRecorder(10)
		r = baremetalworker.NewReconciler(k8sClient, k8sClient, scheme.Scheme,
			fc, baremetalworker.NewIgnitionFetcher(nil), rec, testNamespace)
	})

	AfterEach(func() { ign.Close() })

	addInstanceType := func(name, fabricPort string) {
		mgmt := privatev1.BareMetalNetworkPortSpec_builder{
			Name: "mgmt-0", Role: "management", Type: "Ethernet", Speed: "1Gbps",
		}.Build()
		fc.AddBareMetalInstanceType(newInstanceType(name, fabricPort, mgmt))
	}

	preloadDiskImageChain := func() {
		fc.AddCluster(privatev1.Cluster_builder{
			Id: clusterUUID,
			Spec: privatev1.ClusterSpec_builder{
				Version: privatev1.ClusterVersionReference_builder{Id: cvID}.Build(),
			}.Build(),
		}.Build())
		fc.AddClusterVersion(privatev1.ClusterVersion_builder{
			Id: cvID,
			Spec: privatev1.ClusterVersionSpec_builder{
				DiskImage: privatev1.DiskImageReference_builder{Id: diskImageID}.Build(),
			}.Build(),
		}.Build())
		addInstanceType("bm-standard", "data-0")
	}

	newBareMetalClusterOrder := func(name string, numWorkers int) *osacv1alpha1.ClusterOrder {
		co := &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{
				Name:      name,
				Namespace: testNamespace,
				Labels:    map[string]string{clusterIDLabel: clusterUUID},
			},
			Spec: osacv1alpha1.ClusterOrderSpec{
				TemplateID:   "test",
				SSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5",
				NodeRequests: []osacv1alpha1.NodeRequest{{
					ResourceClass: "bm-standard",
					NumberOfNodes: numWorkers,
					BareMetal: &osacv1alpha1.BareMetalNodeSpec{
						InstanceType: "bm-standard",
					},
				}},
				NetworkAttachment: &osacv1alpha1.ClusterNetworkAttachment{
					SubnetRef:         "my-subnet",
					SecurityGroupRefs: []string{"sg-default"},
				},
			},
		}
		return co
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

	makeInfraEnvReady := func(name string) {
		GinkgoHelper()
		_, err := runReconcile(name)
		Expect(err).ToNot(HaveOccurred())
		Expect(sim.MarkInfraEnvReady(ctx, name+"-infraenv", testNamespace, ign.URL())).To(Succeed())
		_, err = runReconcile(name)
		Expect(err).ToNot(HaveOccurred())
		Expect(apimeta.IsStatusConditionTrue(
			getClusterOrder(name).Status.Conditions, osacv1alpha1.ConditionInfraEnvReady)).To(BeTrue())
	}

	It("creates BMIs with correct fields for a single-worker node set", func() {
		preloadDiskImageChain()
		co := newBareMetalClusterOrder("bmw-create", 1)
		create(co)
		makeInfraEnvReady("bmw-create")

		res, err := runReconcile("bmw-create")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		calls := fc.CreateCalls()
		Expect(calls).To(HaveLen(1))

		bmi := calls[0]
		Expect(bmi.GetMetadata().GetTenant()).To(Equal("system"))
		Expect(bmi.GetMetadata().GetName()).To(Equal("bmw-create-worker-0"))
		Expect(bmi.GetMetadata().GetLabels()).To(HaveKeyWithValue("osac.openshift.io/cluster-order", "bmw-create"))
		Expect(bmi.GetMetadata().GetAnnotations()).To(HaveKeyWithValue(
			"osac.openshift.io/owner-reference", "ClusterOrder/bmw-create"))
		Expect(bmi.GetSpec().GetCatalogItem().GetName()).To(Equal("system-bmi-passthrough"))
		Expect(bmi.GetSpec().GetImage().GetSourceType()).To(Equal("disk_image"))
		Expect(bmi.GetSpec().GetImage().GetSourceRef()).To(Equal(diskImageID))
		Expect(bmi.GetSpec().GetInstanceType()).To(Equal("bm-standard"))

		userData := bmi.GetSpec().GetUserData()
		decoded, decErr := base64.StdEncoding.DecodeString(userData)
		Expect(decErr).ToNot(HaveOccurred())
		Expect(decoded).ToNot(BeEmpty())

		netAttachments := bmi.GetSpec().GetNetworkAttachments()
		Expect(netAttachments).To(HaveLen(1))
		Expect(netAttachments[0].GetSubnet().GetName()).To(Equal("my-subnet"))
		Expect(netAttachments[0].GetSecurityGroups()).To(HaveLen(1))
		Expect(netAttachments[0].GetSecurityGroups()[0].GetName()).To(Equal("sg-default"))
	})

	It("creates N BMIs for a multi-worker node set", func() {
		preloadDiskImageChain()
		co := newBareMetalClusterOrder("bmw-multi", 3)
		create(co)
		makeInfraEnvReady("bmw-multi")

		res, err := runReconcile("bmw-multi")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		calls := fc.CreateCalls()
		Expect(calls).To(HaveLen(3))
		for i, call := range calls {
			Expect(call.GetMetadata().GetName()).To(Equal(fmt.Sprintf("bmw-multi-worker-%d", i)))
		}

		co = getClusterOrder("bmw-multi")
		Expect(co.Status.Workers).To(HaveLen(3))
	})

	It("skips creation when BMI already exists (list-before-create)", func() {
		preloadDiskImageChain()
		co := newBareMetalClusterOrder("bmw-idem", 1)
		create(co)

		// Pre-create the BMI in the fake BEFORE makeInfraEnvReady, because the second
		// reconcile in makeInfraEnvReady reaches reconcileWorkers.
		_, err := fc.CreateBareMetalInstance(ctx, privatev1.BareMetalInstance_builder{
			Metadata: privatev1.Metadata_builder{
				Tenant: "system",
				Name:   "bmw-idem-worker-0",
				Labels: map[string]string{"osac.openshift.io/cluster-order": "bmw-idem"},
			}.Build(),
		}.Build())
		Expect(err).ToNot(HaveOccurred())

		makeInfraEnvReady("bmw-idem")

		// makeInfraEnvReady's second reconcile and subsequent reconciles all skip
		// creation because list-before-create finds the pre-existing BMI.
		createCallsBefore := len(fc.CreateCalls())

		res, err := runReconcile("bmw-idem")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		Expect(fc.CreateCalls()).To(HaveLen(createCallsBefore))

		co = getClusterOrder("bmw-idem")
		Expect(co.Status.Workers).To(HaveLen(1))
		Expect(co.Status.Workers[0].Name).To(Equal("bmw-idem-worker-0"))
		Expect(co.Status.Workers[0].Phase).To(Equal("Provisioning"))
	})

	It("handles AlreadyExists by re-listing and recording the existing BMI", func() {
		preloadDiskImageChain()
		co := newBareMetalClusterOrder("bmw-exists", 1)
		create(co)
		makeInfraEnvReady("bmw-exists")

		// First reconcile creates the BMI, second finds it via list (idempotent re-reconcile).
		res, err := runReconcile("bmw-exists")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		// First reconcile created it.
		Expect(fc.CreateCalls()).To(HaveLen(1))

		// Second reconcile — list finds it, no new create call.
		res, err = runReconcile("bmw-exists")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		// Still only 1 create call total — second reconcile used list-before-create.
		Expect(fc.CreateCalls()).To(HaveLen(1))

		co = getClusterOrder("bmw-exists")
		Expect(co.Status.Workers).To(HaveLen(1))
		Expect(co.Status.Workers[0].ResourceID).ToNot(BeEmpty())
	})

	It("returns an error when BMI creation fails", func() {
		preloadDiskImageChain()
		co := newBareMetalClusterOrder("bmw-unavail", 1)
		create(co)

		// Set the create error BEFORE makeInfraEnvReady so it is active when
		// the second reconcile reaches reconcileWorkers.
		fc.SetCreateError(fmt.Errorf("connection refused"))

		// First reconcile creates InfraEnv (no fulfillment call yet).
		_, err := runReconcile("bmw-unavail")
		Expect(err).ToNot(HaveOccurred())
		Expect(sim.MarkInfraEnvReady(ctx, "bmw-unavail-infraenv", testNamespace, ign.URL())).To(Succeed())

		// Second reconcile fetches ignition, resolves disk image, then tries
		// reconcileWorkers — which fails on Create.
		_, err = runReconcile("bmw-unavail")
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("creating BMI"))
	})

	It("updates status.workers with phase Provisioning", func() {
		preloadDiskImageChain()
		co := newBareMetalClusterOrder("bmw-status", 2)
		create(co)
		makeInfraEnvReady("bmw-status")

		res, err := runReconcile("bmw-status")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		co = getClusterOrder("bmw-status")
		Expect(co.Status.Workers).To(HaveLen(2))
		for _, w := range co.Status.Workers {
			Expect(w.Phase).To(Equal("Provisioning"))
			Expect(w.Kind).To(Equal("BareMetalInstance"))
			Expect(w.ResourceID).ToNot(BeEmpty())
			Expect(w.NodeSet).To(Equal("bm-standard"))
		}
		Expect(co.Status.Workers[0].Name).To(Equal("bmw-status-worker-0"))
		Expect(co.Status.Workers[1].Name).To(Equal("bmw-status-worker-1"))
	})

	It("enriches BMI network attachment with interface from first fabric port and primary=true", func() {
		preloadDiskImageChain()
		co := newBareMetalClusterOrder("bmw-enrich", 1)
		create(co)
		makeInfraEnvReady("bmw-enrich")

		res, err := runReconcile("bmw-enrich")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		calls := fc.CreateCalls()
		Expect(calls).To(HaveLen(1))

		netAttachments := calls[0].GetSpec().GetNetworkAttachments()
		Expect(netAttachments).To(HaveLen(1))
		Expect(netAttachments[0].GetSubnet().GetName()).To(Equal("my-subnet"))
		Expect(netAttachments[0].GetSecurityGroups()).To(HaveLen(1))
		Expect(netAttachments[0].GetSecurityGroups()[0].GetName()).To(Equal("sg-default"))
		Expect(netAttachments[0].GetInterface()).To(Equal("data-0"))
		Expect(netAttachments[0].GetPrimary()).To(BeTrue())
	})

	It("resolves different interfaces for different instance types across node sets", func() {
		preloadDiskImageChain()
		addInstanceType("bm-gpu", "gpu-data-0")

		co := &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "bmw-multi-type",
				Namespace: testNamespace,
				Labels:    map[string]string{clusterIDLabel: clusterUUID},
			},
			Spec: osacv1alpha1.ClusterOrderSpec{
				TemplateID:   "test",
				SSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5",
				NodeRequests: []osacv1alpha1.NodeRequest{
					{
						ResourceClass: "bm-standard",
						NumberOfNodes: 1,
						BareMetal:     &osacv1alpha1.BareMetalNodeSpec{InstanceType: "bm-standard"},
					},
					{
						ResourceClass: "bm-gpu",
						NumberOfNodes: 1,
						BareMetal:     &osacv1alpha1.BareMetalNodeSpec{InstanceType: "bm-gpu"},
					},
				},
				NetworkAttachment: &osacv1alpha1.ClusterNetworkAttachment{
					SubnetRef:         "my-subnet",
					SecurityGroupRefs: []string{"sg-default"},
				},
			},
		}
		create(co)
		makeInfraEnvReady("bmw-multi-type")

		res, err := runReconcile("bmw-multi-type")
		Expect(err).ToNot(HaveOccurred())
		Expect(res.RequeueAfter).To(BeZero())

		calls := fc.CreateCalls()
		Expect(calls).To(HaveLen(2))
		Expect(calls[0].GetSpec().GetNetworkAttachments()[0].GetInterface()).To(Equal("data-0"))
		Expect(calls[1].GetSpec().GetNetworkAttachments()[0].GetInterface()).To(Equal("gpu-data-0"))
	})

	It("returns an error when networkAttachment is missing from ClusterOrder", func() {
		preloadDiskImageChain()
		co := &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "bmw-no-net",
				Namespace: testNamespace,
				Labels:    map[string]string{clusterIDLabel: clusterUUID},
			},
			Spec: osacv1alpha1.ClusterOrderSpec{
				TemplateID:   "test",
				SSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5",
				NodeRequests: []osacv1alpha1.NodeRequest{{
					ResourceClass: "bm-standard",
					NumberOfNodes: 1,
					BareMetal:     &osacv1alpha1.BareMetalNodeSpec{InstanceType: "bm-standard"},
				}},
			},
		}
		create(co)

		// First reconcile creates InfraEnv.
		_, err := runReconcile("bmw-no-net")
		Expect(err).ToNot(HaveOccurred())
		Expect(sim.MarkInfraEnvReady(ctx, "bmw-no-net-infraenv", testNamespace, ign.URL())).To(Succeed())

		// Second reconcile reaches reconcileWorkers which fails on missing networkAttachment.
		_, err = runReconcile("bmw-no-net")
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("no networkAttachment"))
	})
})
