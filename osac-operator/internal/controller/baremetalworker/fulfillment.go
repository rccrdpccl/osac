/*
Copyright (c) 2026 Red Hat Inc.

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the
License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an
"AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific
language governing permissions and limitations under the License.
*/

// Package baremetalworker holds the CaaS bare-metal worker provisioning controller and the
// narrow client seam it uses to talk to the fulfillment-service private API.
package baremetalworker

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"google.golang.org/grpc"

	privatev1 "github.com/osac-project/osac/osac-operator/internal/api/osac/private/v1"
)

// callTimeout bounds every fulfillment-service gRPC call. The controller-runtime requeue
// provides the retry loop; this deadline only prevents a hung call from blocking a worker.
const callTimeout = 30 * time.Second

// unavailableThreshold is the number of consecutive gRPC failures after which the client
// reports the service as unavailable.
const unavailableThreshold = 3

// maxIgnitionBytes bounds the discovery ignition response to guard operator memory against an
// unexpectedly large or hostile response. Discovery ignition is ~15KB in practice.
const maxIgnitionBytes = 1 << 20 // 1 MiB

// ErrFulfillmentServiceUnavailable is returned (wrapped, matchable with errors.Is) once the
// fulfillment-service gRPC calls have failed unavailableThreshold times in a row. The
// reconciler maps it to a FulfillmentServiceUnavailable condition.
var ErrFulfillmentServiceUnavailable = errors.New("fulfillment service unavailable")

// FulfillmentClient is the narrow seam the bare-metal worker reconciler uses to talk to the
// fulfillment-service private API and to fetch discovery ignition. It is intentionally small
// so it can be faked in tests without a running fulfillment-service.
type FulfillmentClient interface {
	// CreateBareMetalInstance creates a BareMetalInstance and returns the created object.
	CreateBareMetalInstance(ctx context.Context, obj *privatev1.BareMetalInstance) (*privatev1.BareMetalInstance, error)
	// DeleteBareMetalInstance deletes the BareMetalInstance with the given id.
	DeleteBareMetalInstance(ctx context.Context, id string) error
	// GetBareMetalInstance returns the BareMetalInstance with the given id.
	GetBareMetalInstance(ctx context.Context, id string) (*privatev1.BareMetalInstance, error)
	// ListBareMetalInstances returns the BareMetalInstances matching the given CEL filter
	// (empty filter returns all instances visible to the caller).
	ListBareMetalInstances(ctx context.Context, filter string) ([]*privatev1.BareMetalInstance, error)
	// GetClusterVersion returns the ClusterVersion with the given id.
	GetClusterVersion(ctx context.Context, id string) (*privatev1.ClusterVersion, error)
	// FetchIgnition GETs the discovery ignition content from the given URL.
	FetchIgnition(ctx context.Context, url string) ([]byte, error)
}

// client is the production FulfillmentClient. It wraps the generated gRPC clients, applies a
// per-call deadline, and tracks consecutive gRPC failures for the unavailable signal.
type client struct {
	bmis     privatev1.BareMetalInstancesClient
	versions privatev1.ClusterVersionsClient
	http     *http.Client

	mu                  sync.Mutex
	consecutiveFailures int
}

// NewClient builds a FulfillmentClient from already-constructed dependencies. A nil httpClient
// defaults to a zero-value http.Client (per-call deadlines come from the context).
func NewClient(
	bmis privatev1.BareMetalInstancesClient,
	versions privatev1.ClusterVersionsClient,
	httpClient *http.Client,
) FulfillmentClient {
	if httpClient == nil {
		httpClient = &http.Client{}
	}
	return &client{bmis: bmis, versions: versions, http: httpClient}
}

// NewClientFromConn wires the production FulfillmentClient from the shared gRPC connection
// dialed in main(). This is what the reconciler is constructed with.
func NewClientFromConn(conn *grpc.ClientConn, httpClient *http.Client) FulfillmentClient {
	return NewClient(
		privatev1.NewBareMetalInstancesClient(conn),
		privatev1.NewClusterVersionsClient(conn),
		httpClient,
	)
}

// call runs a fulfillment-service gRPC operation under the per-call deadline and updates the
// consecutive-failure counter. After unavailableThreshold consecutive failures it wraps the
// underlying error with ErrFulfillmentServiceUnavailable; a success resets the counter.
func (c *client) call(ctx context.Context, op func(ctx context.Context) error) error {
	opCtx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	err := op(opCtx)

	c.mu.Lock()
	defer c.mu.Unlock()
	if err != nil {
		c.consecutiveFailures++
		if c.consecutiveFailures >= unavailableThreshold {
			return fmt.Errorf("%w: %w", ErrFulfillmentServiceUnavailable, err)
		}
		return err
	}
	c.consecutiveFailures = 0
	return nil
}

func (c *client) CreateBareMetalInstance(
	ctx context.Context,
	obj *privatev1.BareMetalInstance,
) (*privatev1.BareMetalInstance, error) {
	var out *privatev1.BareMetalInstance
	err := c.call(ctx, func(ctx context.Context) error {
		resp, err := c.bmis.Create(ctx, privatev1.BareMetalInstancesCreateRequest_builder{Object: obj}.Build())
		if err != nil {
			return err
		}
		out = resp.GetObject()
		return nil
	})
	return out, err
}

func (c *client) DeleteBareMetalInstance(ctx context.Context, id string) error {
	return c.call(ctx, func(ctx context.Context) error {
		_, err := c.bmis.Delete(ctx, privatev1.BareMetalInstancesDeleteRequest_builder{Id: id}.Build())
		return err
	})
}

func (c *client) GetBareMetalInstance(ctx context.Context, id string) (*privatev1.BareMetalInstance, error) {
	var out *privatev1.BareMetalInstance
	err := c.call(ctx, func(ctx context.Context) error {
		resp, err := c.bmis.Get(ctx, privatev1.BareMetalInstancesGetRequest_builder{Id: id}.Build())
		if err != nil {
			return err
		}
		out = resp.GetObject()
		return nil
	})
	return out, err
}

func (c *client) ListBareMetalInstances(ctx context.Context, filter string) ([]*privatev1.BareMetalInstance, error) {
	var out []*privatev1.BareMetalInstance
	err := c.call(ctx, func(ctx context.Context) error {
		req := privatev1.BareMetalInstancesListRequest_builder{}
		if filter != "" {
			req.Filter = &filter
		}
		resp, err := c.bmis.List(ctx, req.Build())
		if err != nil {
			return err
		}
		out = resp.GetItems()
		return nil
	})
	return out, err
}

func (c *client) GetClusterVersion(ctx context.Context, id string) (*privatev1.ClusterVersion, error) {
	var out *privatev1.ClusterVersion
	err := c.call(ctx, func(ctx context.Context) error {
		resp, err := c.versions.Get(ctx, privatev1.ClusterVersionsGetRequest_builder{Id: id}.Build())
		if err != nil {
			return err
		}
		out = resp.GetObject()
		return nil
	})
	return out, err
}

// FetchIgnition GETs the discovery ignition from url under the per-call deadline. It targets
// the InfraEnv boot-artifacts endpoint (assisted-service), not the fulfillment-service, so it
// does not affect the gRPC consecutive-failure counter.
func (c *client) FetchIgnition(ctx context.Context, url string) ([]byte, error) {
	reqCtx, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("building ignition request: %w", err)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetching ignition: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxIgnitionBytes))
	if err != nil {
		return nil, fmt.Errorf("reading ignition body: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		snippet := body
		if len(snippet) > 256 {
			snippet = snippet[:256]
		}
		return nil, fmt.Errorf("fetching ignition: unexpected status %d: %s", resp.StatusCode, snippet)
	}
	return body, nil
}
