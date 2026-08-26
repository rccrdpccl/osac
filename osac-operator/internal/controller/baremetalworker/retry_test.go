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
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
)

func TestClassifyFailure(t *testing.T) {
	tests := []struct {
		name   string
		reason string
		want   FailureCategory
	}{
		{name: "agent timeout", reason: "AgentRegistrationTimeout", want: FailureCategoryAgentTimeout},
		{name: "no host available", reason: "NoHostAvailable", want: FailureCategoryResource},
		{name: "resource exhausted", reason: "ResourceExhausted", want: FailureCategoryResource},
		{name: "transient infra error", reason: "InfrastructureError", want: FailureCategoryTransient},
		{name: "unknown reason", reason: "SomethingUnexpected", want: FailureCategoryTransient},
		{name: "empty reason", reason: "", want: FailureCategoryTransient},
		{name: "BMI creation failed", reason: "BMICreationFailed", want: FailureCategoryTransient},
		{name: "provisioning failed", reason: "ProvisioningFailed", want: FailureCategoryTransient},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ClassifyFailure(tt.reason)
			if got != tt.want {
				t.Errorf("ClassifyFailure(%q) = %d, want %d", tt.reason, got, tt.want)
			}
		})
	}
}

func TestComputeBackoff(t *testing.T) {
	tests := []struct {
		name     string
		category FailureCategory
		attempt  int32
		want     time.Duration
	}{
		// Transient: 30s, 60s, 120s, cap 5m
		{name: "transient attempt 1", category: FailureCategoryTransient, attempt: 1, want: 30 * time.Second},
		{name: "transient attempt 2", category: FailureCategoryTransient, attempt: 2, want: 60 * time.Second},
		{name: "transient attempt 3", category: FailureCategoryTransient, attempt: 3, want: 120 * time.Second},
		{name: "transient attempt 4 capped", category: FailureCategoryTransient, attempt: 4, want: 5 * time.Minute},
		{name: "transient attempt 10 capped", category: FailureCategoryTransient, attempt: 10, want: 5 * time.Minute},

		// Resource: 5m, 15m, 30m, cap 30m
		{name: "resource attempt 1", category: FailureCategoryResource, attempt: 1, want: 5 * time.Minute},
		{name: "resource attempt 2", category: FailureCategoryResource, attempt: 2, want: 15 * time.Minute},
		{name: "resource attempt 3", category: FailureCategoryResource, attempt: 3, want: 30 * time.Minute},
		{name: "resource attempt 4 capped", category: FailureCategoryResource, attempt: 4, want: 30 * time.Minute},

		// Agent timeout: same schedule as resource
		{name: "agent timeout attempt 1", category: FailureCategoryAgentTimeout, attempt: 1, want: 5 * time.Minute},
		{name: "agent timeout attempt 2", category: FailureCategoryAgentTimeout, attempt: 2, want: 15 * time.Minute},
		{name: "agent timeout attempt 3", category: FailureCategoryAgentTimeout, attempt: 3, want: 30 * time.Minute},
		{name: "agent timeout attempt 4 capped", category: FailureCategoryAgentTimeout, attempt: 4, want: 30 * time.Minute},

		// Edge: attempt 0 treated as attempt 1
		{name: "transient attempt 0", category: FailureCategoryTransient, attempt: 0, want: 30 * time.Second},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ComputeBackoff(tt.category, tt.attempt)
			if got != tt.want {
				t.Errorf("ComputeBackoff(%d, %d) = %v, want %v", tt.category, tt.attempt, got, tt.want)
			}
		})
	}
}

func TestFormatWorkersFailed(t *testing.T) {
	now := metav1.Now()
	retryTime := metav1.NewTime(now.Add(30 * time.Second))

	tests := []struct {
		name    string
		workers []v1alpha1.WorkerStatus
		want    string
	}{
		{
			name:    "no failed workers",
			workers: []v1alpha1.WorkerStatus{{Name: "w-0", Phase: workerPhaseReady}},
			want:    "",
		},
		{
			name: "one failed worker",
			workers: []v1alpha1.WorkerStatus{
				{Name: "w-0", Phase: workerPhaseFailed, AttemptCount: 2, NextRetryTime: &retryTime},
			},
			want: "w-0: attempt 2, next retry " + retryTime.UTC().Format(time.RFC3339),
		},
		{
			name: "multiple failed workers",
			workers: []v1alpha1.WorkerStatus{
				{Name: "w-0", Phase: workerPhaseReady},
				{Name: "w-1", Phase: workerPhaseFailed, AttemptCount: 1, NextRetryTime: &retryTime},
				{Name: "w-2", Phase: workerPhaseFailed, AttemptCount: 3, NextRetryTime: &retryTime},
			},
			want: "w-1: attempt 1, next retry " + retryTime.UTC().Format(time.RFC3339) +
				"; w-2: attempt 3, next retry " + retryTime.UTC().Format(time.RFC3339),
		},
		{
			name: "failed worker without next retry time",
			workers: []v1alpha1.WorkerStatus{
				{Name: "w-0", Phase: workerPhaseFailed, AttemptCount: 1},
			},
			want: "w-0: attempt 1, next retry pending",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FormatWorkersFailed(tt.workers)
			if got != tt.want {
				t.Errorf("FormatWorkersFailed() = %q, want %q", got, tt.want)
			}
		})
	}
}
