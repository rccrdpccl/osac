/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package integration

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/rest"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

var _ = Describe("Bare-metal worker teardown API permissions", func() {
	It("allows actual GET/LIST requests as the deployed manager ServiceAccount", func() {
		ctx := context.Background()
		cfg, err := ctrl.GetConfig()
		Expect(err).NotTo(HaveOccurred())
		admin, err := client.New(cfg, client.Options{})
		Expect(err).NotTo(HaveOccurred())
		pods := &corev1.PodList{}
		Expect(admin.List(ctx, pods, client.InNamespace(operatorNamespace), client.MatchingLabels{
			"control-plane": "controller-manager", "app.kubernetes.io/name": "operator",
		})).To(Succeed())
		var serviceAccount string
		for _, pod := range pods.Items {
			if pod.DeletionTimestamp.IsZero() {
				Expect(serviceAccount).To(BeEmpty(), "require one live manager pod")
				serviceAccount = pod.Spec.ServiceAccountName
			}
		}
		Expect(serviceAccount).NotTo(BeEmpty())
		managerConfig := rest.CopyConfig(cfg)
		managerConfig.Impersonate = rest.ImpersonationConfig{
			UserName: "system:serviceaccount:" + operatorNamespace + ":" + serviceAccount,
			Groups:   []string{"system:serviceaccounts", "system:serviceaccounts:" + operatorNamespace, "system:authenticated"},
		}
		manager, err := client.New(managerConfig, client.Options{Mapper: admin.RESTMapper()})
		Expect(err).NotTo(HaveOccurred())
		for _, kind := range []schema.GroupKind{
			{Group: "cluster.x-k8s.io", Kind: "MachineDeployment"},
			{Group: "cluster.x-k8s.io", Kind: "MachineSet"},
			{Group: "cluster.x-k8s.io", Kind: "Machine"},
			{Group: "capi-provider.agent-install.openshift.io", Kind: "AgentMachine"},
			{Group: "agent-install.openshift.io", Kind: "InfraEnv"},
		} {
			By("reading " + kind.String() + " as " + managerConfig.Impersonate.UserName)
			mapping, err := admin.RESTMapper().RESTMapping(kind)
			Expect(err).NotTo(HaveOccurred(), "install required fixture APIs in the dedicated Kind cluster")
			list := &unstructured.UnstructuredList{}
			list.SetGroupVersionKind(mapping.GroupVersionKind.GroupVersion().WithKind(kind.Kind + "List"))
			Expect(manager.List(ctx, list, client.InNamespace(operatorNamespace))).To(Succeed())
			obj := &unstructured.Unstructured{}
			obj.SetGroupVersionKind(mapping.GroupVersionKind)
			// A real object-level NotFound proves the GET was authorized; Forbidden,
			// transport failures and unsupported APIs are failures, not absence.
			err = manager.Get(ctx, client.ObjectKey{Namespace: operatorNamespace, Name: "osac-teardown-rbac-check"}, obj)
			Expect(err == nil || apierrors.IsNotFound(err)).To(BeTrue(), "GET failed: %v", err)
		}
	})
})
