/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

// Package fake provides in-memory test doubles for the bare-metal worker controller's external
// seams: a recording FulfillmentClient (OSAC-4146) that stands in for the fulfillment-service
// private API, and a configurable HTTP endpoint that stands in for an InfraEnv's discovery
// ignition URL. Together they let path-A tests exercise the full reconcile loop without a
// running fulfillment-service or assisted-service.
//
// Field-contract note: the fake performs only minimal validation (it requires metadata.name on
// create, as the real API does). The fulfillment-service contract tests (OSAC-4129 track) are
// the source of truth for the accepted-field contract, and the B-lite harness (OSAC-4153) is the
// anti-drift check that runs the controller against the real private API + Postgres.
package fake

import (
	"context"
	"sort"
	"sync"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	privatev1 "github.com/osac-project/osac/osac-operator/internal/api/osac/private/v1"
	"github.com/osac-project/osac/osac-operator/internal/controller/baremetalworker"
)

// FulfillmentClient is an in-memory, call-recording implementation of
// baremetalworker.FulfillmentClient for tests. All methods are safe for concurrent use.
type FulfillmentClient struct {
	mu              sync.Mutex
	bmis            map[string]*privatev1.BareMetalInstance
	hostMACs        map[string]string
	clusterVersions map[string]*privatev1.ClusterVersion
	createErr       error
	deleteErr       error

	createCalls []*privatev1.BareMetalInstance
	deleteCalls []string
	getCalls    []string
	listCalls   []string
	getCVCalls  []string
}

var _ baremetalworker.FulfillmentClient = (*FulfillmentClient)(nil)

// NewFulfillmentClient returns an empty fake FulfillmentClient.
func NewFulfillmentClient() *FulfillmentClient {
	return &FulfillmentClient{
		bmis:            map[string]*privatev1.BareMetalInstance{},
		hostMACs:        map[string]string{},
		clusterVersions: map[string]*privatev1.ClusterVersion{},
	}
}

func cloneBMI(b *privatev1.BareMetalInstance) *privatev1.BareMetalInstance {
	return proto.Clone(b).(*privatev1.BareMetalInstance)
}

func cloneCV(c *privatev1.ClusterVersion) *privatev1.ClusterVersion {
	return proto.Clone(c).(*privatev1.ClusterVersion)
}

// CreateBareMetalInstance records the call, assigns an id (defaulting to metadata.name) and stores
// the object. It returns the injected create error when one is set (still recording the call).
func (f *FulfillmentClient) CreateBareMetalInstance(
	_ context.Context, obj *privatev1.BareMetalInstance,
) (*privatev1.BareMetalInstance, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.createCalls = append(f.createCalls, cloneBMI(obj))
	if f.createErr != nil {
		return nil, f.createErr
	}
	name := obj.GetMetadata().GetName()
	if name == "" {
		return nil, status.Error(codes.InvalidArgument, "baremetalinstance metadata.name is required")
	}
	stored := cloneBMI(obj)
	id := stored.GetId()
	if id == "" {
		id = name
		stored.SetId(id)
	}
	// Mirror the real private API's uniqueness constraint (OSAC-3266: UNIQUE(tenant,project,name)),
	// so idempotency/list-before-create tests exercise the AlreadyExists path.
	if _, exists := f.bmis[id]; exists {
		return nil, status.Errorf(codes.AlreadyExists, "baremetalinstance %q already exists", id)
	}
	f.bmis[id] = stored
	return cloneBMI(stored), nil
}

// DeleteBareMetalInstance records the call and removes the object. It returns the injected delete
// error when one is set (still recording the call).
func (f *FulfillmentClient) DeleteBareMetalInstance(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.deleteCalls = append(f.deleteCalls, id)
	if f.deleteErr != nil {
		return f.deleteErr
	}
	delete(f.bmis, id)
	delete(f.hostMACs, id)
	return nil
}

// GetBareMetalInstance records the call and returns a copy of the stored object, or an error if
// no object with that id exists.
func (f *FulfillmentClient) GetBareMetalInstance(
	_ context.Context, id string,
) (*privatev1.BareMetalInstance, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.getCalls = append(f.getCalls, id)
	b, ok := f.bmis[id]
	if !ok {
		return nil, status.Errorf(codes.NotFound, "baremetalinstance %q not found", id)
	}
	return cloneBMI(b), nil
}

// ListBareMetalInstances records the filter and returns copies of all stored objects, ordered by
// id for deterministic tests.
func (f *FulfillmentClient) ListBareMetalInstances(
	_ context.Context, filter string,
) ([]*privatev1.BareMetalInstance, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.listCalls = append(f.listCalls, filter)
	ids := make([]string, 0, len(f.bmis))
	for id := range f.bmis {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	out := make([]*privatev1.BareMetalInstance, 0, len(ids))
	for _, id := range ids {
		out = append(out, cloneBMI(f.bmis[id]))
	}
	return out, nil
}

// GetClusterVersion records the call and returns a preloaded ClusterVersion (see
// AddClusterVersion), or an error if none is registered for that id.
func (f *FulfillmentClient) GetClusterVersion(
	_ context.Context, id string,
) (*privatev1.ClusterVersion, error) {
	f.mu.Lock()
	defer f.mu.Unlock()

	f.getCVCalls = append(f.getCVCalls, id)
	cv, ok := f.clusterVersions[id]
	if !ok {
		return nil, status.Errorf(codes.NotFound, "clusterversion %q not found", id)
	}
	return cloneCV(cv), nil
}

// --- Builder / control surface (test-only) ---

// AddClusterVersion preloads a ClusterVersion so GetClusterVersion can return it (keyed by id).
func (f *FulfillmentClient) AddClusterVersion(cv *privatev1.ClusterVersion) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.clusterVersions[cv.GetId()] = cloneCV(cv)
}

// SetHostMAC records the allocated host MAC for a BMI so correlation tests can drive Agent
// matching.
//
// The canonical BMI status MAC field does not exist in the proto yet (design §MAC Address
// Correlation; pending OSAC-2308/OSAC-3254), so the fake exposes it out of band via HostMAC.
// Once the proto gains the field, this should also populate it on the stored object's status.
func (f *FulfillmentClient) SetHostMAC(bmiID, mac string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hostMACs[bmiID] = mac
}

// HostMAC returns the MAC previously set for a BMI via SetHostMAC (empty if none).
func (f *FulfillmentClient) HostMAC(bmiID string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hostMACs[bmiID]
}

// SetCreateError makes subsequent CreateBareMetalInstance calls return err (nil clears it).
func (f *FulfillmentClient) SetCreateError(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.createErr = err
}

// SetDeleteError makes subsequent DeleteBareMetalInstance calls return err (nil clears it).
func (f *FulfillmentClient) SetDeleteError(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleteErr = err
}

// --- Recorded-call accessors (return copies under lock) ---

// CreateCalls returns copies of the BareMetalInstance objects passed to CreateBareMetalInstance.
func (f *FulfillmentClient) CreateCalls() []*privatev1.BareMetalInstance {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]*privatev1.BareMetalInstance, len(f.createCalls))
	for i, b := range f.createCalls {
		out[i] = cloneBMI(b)
	}
	return out
}

// DeleteCalls returns the ids passed to DeleteBareMetalInstance, in order.
func (f *FulfillmentClient) DeleteCalls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.deleteCalls...)
}

// GetCalls returns the ids passed to GetBareMetalInstance, in order.
func (f *FulfillmentClient) GetCalls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.getCalls...)
}

// ListCalls returns the filters passed to ListBareMetalInstances, in order.
func (f *FulfillmentClient) ListCalls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.listCalls...)
}

// GetClusterVersionCalls returns the ids passed to GetClusterVersion, in order.
func (f *FulfillmentClient) GetClusterVersionCalls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.getCVCalls...)
}
