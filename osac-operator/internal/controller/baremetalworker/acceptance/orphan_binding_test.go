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
	"context"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Inject the claim through the real envtest API after the recovery GET. The
// API server, not this double, rejects the stale resourceVersion on the patch.
type claimDuringRecoveryClient struct {
	client.Client
	patches int
}

func (c *claimDuringRecoveryClient) Patch(ctx context.Context, obj client.Object, patch client.Patch, opts ...client.PatchOption) error {
	if obj.GetObjectKind().GroupVersionKind() == agentGVK {
		c.patches++
		a := &unstructured.Unstructured{}
		a.SetGroupVersionKind(agentGVK)
		if err := c.Client.Get(ctx, client.ObjectKeyFromObject(obj), a); err != nil {
			return err
		}
		labels := a.GetLabels()
		labels["agentMachineRef"] = "racing-machine"
		a.SetLabels(labels)
		if err := c.Client.Update(ctx, a); err != nil {
			return err
		}
	}
	return c.Client.Patch(ctx, obj, patch, opts...)
}
