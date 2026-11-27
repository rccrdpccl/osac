// Copyright (c) 2026 Red Hat Inc.
// SPDX-License-Identifier: Apache-2.0

package baremetalworker

import (
	"context"
	"fmt"

	"google.golang.org/grpc"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
	privatev1 "github.com/osac-project/osac/proto/gen/osac/private/v1"
)

const workerKindCompute = "ComputeInstance"

func isWorkerKind(kind string) bool { return kind == workerKindBMI || kind == workerKindCompute }

// The existing worker journal consumes a BMI-shaped observation. Only identity,
// metadata and deletion state are needed before Agent correlation is available.
// Both strategies use the same ownership checks, reservations and retry policy.
type instanceStrategy interface {
	create(context.Context, *v1alpha1.ClusterOrder, *privatev1.Cluster, v1alpha1.NodeRequest, string, *privatev1.DiskImageReference, string) (*privatev1.BareMetalInstance, error)
	GetBareMetalInstance(context.Context, string) (*privatev1.BareMetalInstance, error)
	ListBareMetalInstances(context.Context, string) ([]*privatev1.BareMetalInstance, error)
	DeleteBareMetalInstance(context.Context, string) error
}

type bmiStrategy struct {
	FulfillmentClient
	r *Reconciler
}

func (s bmiStrategy) create(ctx context.Context, co *v1alpha1.ClusterOrder, cluster *privatev1.Cluster, nr v1alpha1.NodeRequest, name string, image *privatev1.DiskImageReference, ignition string) (*privatev1.BareMetalInstance, error) {
	req, err := s.r.buildBMICreateRequest(co, cluster.GetMetadata().GetTenant(), cluster, nr, name, image, ignition)
	if err != nil {
		return nil, err
	}
	return s.CreateBareMetalInstance(ctx, req)
}

func (r *Reconciler) instances(co *v1alpha1.ClusterOrder) instanceStrategy {
	if co.UsesComputeWorkers() {
		return computeStrategy{r.compute}
	}
	return bmiStrategy{r.fulfillment, r}
}

type computeStrategy struct {
	client privatev1.ComputeInstancesClient
}

func computeObservation(vm *privatev1.ComputeInstance) *privatev1.BareMetalInstance {
	state := privatev1.BareMetalInstanceState_BARE_METAL_INSTANCE_STATE_UNSPECIFIED
	if vm.GetStatus().GetState() == privatev1.ComputeInstanceState_COMPUTE_INSTANCE_STATE_DELETING {
		state = privatev1.BareMetalInstanceState_BARE_METAL_INSTANCE_STATE_DELETING
	}
	return privatev1.BareMetalInstance_builder{
		Id: vm.GetId(), Metadata: vm.GetMetadata(),
		Status: privatev1.BareMetalInstanceStatus_builder{State: state, Cluster: vm.GetStatus().GetCluster()}.Build(),
	}.Build()
}

// Until ComputeInstance exposes MACs, do not guess an Agent from a name,
// registration order, or a shared InfraEnv.
func computeWorkerMACs(context.Context, string) []string { return nil }

func (s computeStrategy) create(ctx context.Context, co *v1alpha1.ClusterOrder, cluster *privatev1.Cluster, nr v1alpha1.NodeRequest, name string, image *privatev1.DiskImageReference, ignition string) (*privatev1.BareMetalInstance, error) {
	ref := cluster.GetSpec().GetNodeSets()[nr.NodeSet].GetComputeInstanceType()
	if ref.GetId() == "" || ref.GetName() != nr.WorkerInstanceType() {
		return nil, fmt.Errorf("node set %q does not match the cluster's compute instance type", nr.NodeSet)
	}
	spec := privatev1.ComputeInstanceSpec_builder{
		Template: privatev1.ComputeInstanceTemplateReference_builder{
			Id: "osac.templates.ocp_virt_vm", Tenant: sharedTenant, Shared: true,
		}.Build(),
		InstanceType:   ref,
		DiskImage:      image,
		SshKey:         cluster.GetSpec().GetSshKey(),
		UserDataSource: privatev1.UserDataSource_builder{Inline: &ignition}.Build(),
	}
	if na := cluster.GetSpec().GetNetworkAttachment(); na != nil {
		spec.NetworkAttachments = []*privatev1.ComputeNetworkAttachment{
			privatev1.ComputeNetworkAttachment_builder{Subnet: na.GetSubnet(), SecurityGroups: na.GetSecurityGroups()}.Build(),
		}
	}
	vm := privatev1.ComputeInstance_builder{
		Metadata: privatev1.Metadata_builder{
			Name: name, Tenant: cluster.GetMetadata().GetTenant(), Project: cluster.GetMetadata().GetProject(),
			Labels:      map[string]string{clusterOrderLabel: co.Name},
			Annotations: map[string]string{ownerReferenceAnnotation: "ClusterOrder/" + co.Name},
		}.Build(),
		Spec: spec.Build(),
		Status: privatev1.ComputeInstanceStatus_builder{
			Cluster: privatev1.ClusterLocalReference_builder{Id: cluster.GetId()}.Build(),
		}.Build(),
	}.Build()
	resp, err := computeCall(ctx, s.client.Create, privatev1.ComputeInstancesCreateRequest_builder{Object: vm}.Build())
	if err != nil {
		return nil, err
	}
	return computeObservation(resp.GetObject()), nil
}

func (s computeStrategy) GetBareMetalInstance(ctx context.Context, id string) (*privatev1.BareMetalInstance, error) {
	resp, err := computeCall(ctx, s.client.Get, privatev1.ComputeInstancesGetRequest_builder{Id: id}.Build())
	if err != nil {
		return nil, err
	}
	return computeObservation(resp.GetObject()), nil
}

func (s computeStrategy) ListBareMetalInstances(ctx context.Context, filter string) ([]*privatev1.BareMetalInstance, error) {
	resp, err := computeCall(ctx, s.client.List, privatev1.ComputeInstancesListRequest_builder{Filter: &filter}.Build())
	if err != nil {
		return nil, err
	}
	out := make([]*privatev1.BareMetalInstance, 0, len(resp.GetItems()))
	for _, vm := range resp.GetItems() {
		out = append(out, computeObservation(vm))
	}
	return out, nil
}

func (s computeStrategy) DeleteBareMetalInstance(ctx context.Context, id string) error {
	_, err := computeCall(ctx, s.client.Delete, privatev1.ComputeInstancesDeleteRequest_builder{Id: id}.Build())
	return err
}

func computeCall[Req, Resp any](ctx context.Context, call func(context.Context, Req, ...grpc.CallOption) (Resp, error), req Req) (Resp, error) {
	op, cancel := context.WithTimeout(ctx, callTimeout)
	defer cancel()
	resp, err := call(op, req)
	if err != nil {
		return resp, classifyCallError(ctx, err)
	}
	return resp, nil
}
