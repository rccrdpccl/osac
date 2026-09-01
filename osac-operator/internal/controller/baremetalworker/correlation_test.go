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
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

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
