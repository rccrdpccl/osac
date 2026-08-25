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
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

func TestMatchAgentToBMI(t *testing.T) {
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

	workers := []v1alpha1.WorkerStatus{
		{Name: "w-0", ResourceID: "bmi-0", Phase: workerPhaseWaitingForAgent},
		{Name: "w-1", ResourceID: "bmi-1", Phase: workerPhaseWaitingForAgent},
		{Name: "w-2", ResourceID: "bmi-2", Phase: workerPhaseBinding},
	}

	hostMACs := map[string]string{
		"bmi-0": "aa:bb:cc:dd:ee:00",
		"bmi-1": "aa:bb:cc:dd:ee:11",
		"bmi-2": "aa:bb:cc:dd:ee:22",
	}
	resolver := func(id string) string { return hostMACs[id] }

	tests := []struct {
		name       string
		agentMACs  []string
		wantWorker string
		wantAmbig  bool
	}{
		{
			name:       "unique match",
			agentMACs:  []string{"aa:bb:cc:dd:ee:00"},
			wantWorker: "w-0",
		},
		{
			name:       "case-insensitive match",
			agentMACs:  []string{"AA:BB:CC:DD:EE:11"},
			wantWorker: "w-1",
		},
		{
			name:       "no match",
			agentMACs:  []string{"ff:ff:ff:ff:ff:ff"},
			wantWorker: "",
		},
		{
			name:       "empty agent MACs",
			agentMACs:  nil,
			wantWorker: "",
		},
		{
			name:      "ambiguous — agent MAC matches two BMIs",
			agentMACs: []string{"aa:bb:cc:dd:ee:00", "aa:bb:cc:dd:ee:11"},
			wantAmbig: true,
		},
		{
			name:       "skips workers not in WaitingForAgent phase",
			agentMACs:  []string{"aa:bb:cc:dd:ee:22"},
			wantWorker: "",
		},
		{
			name:       "multiple interfaces, one matches",
			agentMACs:  []string{"ff:ff:ff:ff:ff:ff", "aa:bb:cc:dd:ee:00"},
			wantWorker: "w-0",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			agent := makeAgent(tt.agentMACs...)
			gotWorker, gotAmbig := matchAgentToBMI(agent, workers, resolver)
			if gotWorker != tt.wantWorker {
				t.Errorf("workerName = %q, want %q", gotWorker, tt.wantWorker)
			}
			if gotAmbig != tt.wantAmbig {
				t.Errorf("ambiguous = %v, want %v", gotAmbig, tt.wantAmbig)
			}
		})
	}
}

func TestExtractAgentMACs(t *testing.T) {
	tests := []struct {
		name string
		obj  map[string]interface{}
		want []string
	}{
		{
			name: "single interface",
			obj: map[string]interface{}{
				"status": map[string]interface{}{
					"inventory": map[string]interface{}{
						"interfaces": []interface{}{
							map[string]interface{}{"macAddress": "aa:bb:cc:dd:ee:ff"},
						},
					},
				},
			},
			want: []string{"aa:bb:cc:dd:ee:ff"},
		},
		{
			name: "multiple interfaces",
			obj: map[string]interface{}{
				"status": map[string]interface{}{
					"inventory": map[string]interface{}{
						"interfaces": []interface{}{
							map[string]interface{}{"macAddress": "11:22:33:44:55:66"},
							map[string]interface{}{"macAddress": "aa:bb:cc:dd:ee:ff"},
						},
					},
				},
			},
			want: []string{"11:22:33:44:55:66", "aa:bb:cc:dd:ee:ff"},
		},
		{
			name: "no inventory",
			obj:  map[string]interface{}{},
			want: nil,
		},
		{
			name: "empty interfaces",
			obj: map[string]interface{}{
				"status": map[string]interface{}{
					"inventory": map[string]interface{}{
						"interfaces": []interface{}{},
					},
				},
			},
			want: []string{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			agent := &unstructured.Unstructured{Object: tt.obj}
			got := extractAgentMACs(agent)
			if len(got) != len(tt.want) {
				t.Fatalf("len = %d, want %d", len(got), len(tt.want))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("mac[%d] = %q, want %q", i, got[i], tt.want[i])
				}
			}
		})
	}
}
