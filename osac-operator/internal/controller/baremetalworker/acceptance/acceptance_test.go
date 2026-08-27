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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"

	osacv1alpha1 "github.com/osac-project/osac/osac-operator/api/v1alpha1"
	privatev1 "github.com/osac-project/osac/osac-operator/internal/api/osac/private/v1"
	"github.com/osac-project/osac/osac-operator/internal/controller/baremetalworker"
	"github.com/osac-project/osac/osac-operator/internal/controller/baremetalworker/fake"
	"github.com/osac-project/osac/osac-operator/internal/testing/envsim"
)

const testNamespace = "default"

var (
	infraEnvGVK = schema.GroupVersionKind{Group: "agent-install.openshift.io", Version: "v1beta1", Kind: "InfraEnv"}
	agentGVK    = schema.GroupVersionKind{Group: "agent-install.openshift.io", Version: "v1beta1", Kind: "Agent"}
)

// bmiNamed builds a minimal BareMetalInstance the fake accepts (metadata.name required).
func bmiNamed(name string) *privatev1.BareMetalInstance {
	return privatev1.BareMetalInstance_builder{
		Metadata: privatev1.Metadata_builder{Name: name}.Build(),
	}.Build()
}

func newInfraEnv(name string) *unstructured.Unstructured {
	u := &unstructured.Unstructured{}
	u.SetGroupVersionKind(infraEnvGVK)
	u.SetName(name)
	u.SetNamespace(testNamespace)
	return u
}

// The bare-metal worker acceptance suite. It wires the fake private API + ignition endpoint
// (OSAC-4149) and the environment simulator (OSAC-4150) into an envtest harness. The controller
// behavior each scenario asserts is implemented by later slices; those scenarios are pending
// (PIt) and carry the slice reference that will make them active.
var _ = Describe("Bare-metal worker provisioning", func() {
	var (
		fc  *fake.FulfillmentClient
		sim *envsim.Simulator
		ign *fake.IgnitionServer
	)

	BeforeEach(func() {
		fc = fake.NewFulfillmentClient()
		sim = envsim.New(k8sClient)
		ign = fake.NewIgnitionServer()
	})

	AfterEach(func() {
		ign.Close()
	})

	// Active spec: proves the harness (envtest + fake + simulator + ignition endpoint) stands up
	// and the pieces interoperate. This is AC-1 ("wires the fake and simulator into the harness").
	It("wires the fake, simulator, and ignition endpoint into an envtest harness", func() {
		co := &osacv1alpha1.ClusterOrder{
			ObjectMeta: metav1.ObjectMeta{Name: "harness", Namespace: testNamespace},
			Spec:       osacv1alpha1.ClusterOrderSpec{TemplateID: "test"},
		}
		Expect(k8sClient.Create(ctx, co)).To(Succeed())
		DeferCleanup(func() { _ = k8sClient.Delete(ctx, co) })

		// Simulator: ClusterDeployment exists, then InfraEnv becomes ready with the fake ignition URL.
		Expect(sim.EnsureClusterDeployment(ctx, "harness-cd", testNamespace)).To(Succeed())
		ie := newInfraEnv("harness-infraenv")
		Expect(k8sClient.Create(ctx, ie)).To(Succeed())
		Expect(sim.MarkInfraEnvReady(ctx, "harness-infraenv", testNamespace, ign.URL())).To(Succeed())

		got := newInfraEnv("harness-infraenv")
		Expect(k8sClient.Get(ctx, types.NamespacedName{Name: "harness-infraenv", Namespace: testNamespace}, got)).To(Succeed())
		url, _, _ := unstructured.NestedString(got.Object, "status", "bootArtifacts", "discoveryIgnitionURL")
		Expect(url).To(Equal(ign.URL()))

		// Simulator: an Agent registers with a MAC.
		Expect(sim.RegisterAgent(ctx, envsim.AgentOptions{
			Name: "harness-agent", Namespace: testNamespace, MAC: "aa:bb:cc:dd:ee:ff",
		})).To(Succeed())

		// Fake private API: a BMI create is recorded, and the real IgnitionFetcher reads the endpoint.
		_, err := fc.CreateBareMetalInstance(ctx, bmiNamed("harness-worker-0"))
		Expect(err).ToNot(HaveOccurred())
		Expect(fc.CreateCalls()).To(HaveLen(1))

		body, err := baremetalworker.NewIgnitionFetcher(nil).FetchIgnition(ctx, ign.URL())
		Expect(err).ToNot(HaveOccurred())
		Expect(body).ToNot(BeEmpty())
	})

	// --- Pending feature scenarios (green-with-pending until their slice lands) ---
	// Each body sketches arrange/act/assert with existing harness helpers; the "act = reconcile"
	// step is a comment because the BareMetalWorkerReconciler is OSAC-4152.

	PIt("provisions a bare-metal cluster to Ready [OSAC-4152/OSAC-4159/OSAC-4160]", func() {
		// Given: a ClusterOrder with a bare-metal node set, ClusterDeployment present, DiskImage/
		//   ClusterVersion preloaded in the fake, InfraEnv marked ready with discovery ignition.
		// When:  the BareMetalWorkerReconciler reconciles (OSAC-4152); the simulator registers an
		//   Agent whose MAC matches the created BMI (OSAC-4160).
		// Then:  ClusterOrder.status.workers reach Ready and aggregate counts converge; NodePool
		//   replicas match.
	})

	PIt("creates BMIs with correct fields and keeps them tenant-invisible [OSAC-4159]", func() {
		// Given: a bare-metal node set + system-owned catalog item.
		// When:  the reconciler creates BMIs via the fake private API.
		// Then:  each recorded BMI carries instance_type, disk_image, user_data (ignition),
		//   network_attachments, and tenant="system"; they are invisible to tenant queries.
	})

	PIt("cleans up all BMIs on cluster delete [OSAC-4176]", func() {
		// Given: a Ready cluster with workers.
		// When:  the ClusterOrder is deleted and the finalizer runs.
		// Then:  every BMI in status.workers is deleted before the finalizer is removed.
	})

	PIt("rebuilds worker state after controller restart [OSAC-4167]", func() {
		// Given: a cluster mid-provisioning with persisted status.workers.
		// When:  a fresh reconciler starts and re-derives phases from live BMI/Agent state.
		// Then:  phases are rebuilt while attemptCount/failure history are preserved.
	})

	PIt("translates worker status to tenant-visible Cluster status [OSAC-4169]", func() {
		// Given: ClusterOrder worker conditions (WorkersFailed / InfraEnvReady / RHCOSImageNotFound).
		// When:  the feedback controller syncs to the public Cluster via Signal.
		// Then:  tenant-safe conditions (WORKER_PROVISIONING_FAILED/BLOCKED) appear without infra detail.
	})
})
