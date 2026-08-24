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
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	apimeta "k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/tools/record"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	controllerutil "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	mcmanager "sigs.k8s.io/multicluster-runtime/pkg/manager"

	"github.com/osac-project/osac/osac-operator/api/v1alpha1"
	privatev1 "github.com/osac-project/osac/osac-operator/internal/api/osac/private/v1"
)

const (
	infraEnvNameSuffix   = "-infraenv"
	pullSecretNameSuffix = "-pull-secret"

	// ignitionSizeWarningThreshold is 75% of the 64KB user_data limit; above it the controller
	// warns that discovery ignition is approaching the BMI user_data ceiling.
	ignitionSizeWarningThreshold = 48 * 1024
	infraEnvRequeueInterval      = 30 * time.Second

	// managementStateAnnotation / managementStateUnmanaged mirror the values the other osac
	// controllers honor (controller.ManagementStateUnmanaged = "unmanaged"; the annotation const
	// there is unexported). Kept in sync by the management-state skip test.
	managementStateAnnotation = "osac.openshift.io/management-state"
	managementStateUnmanaged  = "unmanaged"

	// clusterOrderIDLabel is the label set by the fulfillment-service provisioning flow, carrying
	// the fulfillment-service Cluster UUID. Same key as controller.osacClusterOrderIDLabel (unexported).
	clusterOrderIDLabel = "osac.openshift.io/clusterorder-uuid"

	eventReasonIgnitionSizeWarning = "DiscoveryIgnitionSizeWarning"
	reasonInfraEnvReady            = "InfraEnvReady"
	reasonIgnitionPending          = "IgnitionPending"
	reasonDiskImageNotFound        = "DiskImageNotFound"
	reasonDiskImageResolved        = "DiskImageResolved"

	systemTenant                 = "system"
	systemCatalogItemName        = "system-bmi-passthrough"
	clusterOrderLabel            = "osac.openshift.io/cluster-order"
	ownerReferenceAnnotation     = "osac.openshift.io/owner-reference"
	reasonFulfillmentUnavailable = "FulfillmentServiceUnavailable"
	reasonFulfillmentAvailable   = "FulfillmentServiceAvailable"
	unavailableBackoff           = 5 * time.Minute

	workerKindBMI           = "BareMetalInstance"
	workerPhaseProvisioning = "Provisioning"
)

var infraEnvGVK = schema.GroupVersionKind{Group: "agent-install.openshift.io", Version: "v1beta1", Kind: "InfraEnv"}

// Reconciler is the bare-metal worker reconciler (BareMetalWorkerReconciler). It watches
// ClusterOrder resources with bare-metal node sets and, for now, ensures a cluster-specific
// InfraEnv exists and its discovery ignition is fetched. Later slices add worker provisioning,
// agent correlation, and NodePool convergence.
type Reconciler struct {
	client.Client
	apiReader             client.Reader
	scheme                *runtime.Scheme
	fulfillment           FulfillmentClient
	ignition              IgnitionFetcher
	recorder              record.EventRecorder
	clusterOrderNamespace string
}

// NewReconciler builds the bare-metal worker reconciler.
func NewReconciler(
	c client.Client,
	apiReader client.Reader,
	scheme *runtime.Scheme,
	fulfillment FulfillmentClient,
	ignition IgnitionFetcher,
	recorder record.EventRecorder,
	clusterOrderNamespace string,
) *Reconciler {
	return &Reconciler{
		Client:                c,
		apiReader:             apiReader,
		scheme:                scheme,
		fulfillment:           fulfillment,
		ignition:              ignition,
		recorder:              recorder,
		clusterOrderNamespace: clusterOrderNamespace,
	}
}

// +kubebuilder:rbac:groups=osac.openshift.io,resources=clusterorders,verbs=get;list;watch
// +kubebuilder:rbac:groups=osac.openshift.io,resources=clusterorders/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=agent-install.openshift.io,resources=infraenvs,verbs=get;list;watch;create;update;patch;delete

// Reconcile ensures the InfraEnv for a bare-metal ClusterOrder exists and its discovery ignition
// is fetched. Worker provisioning, agent correlation, and NodePool convergence are later slices,
// so workers legitimately remain absent here.
func (r *Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	co := &v1alpha1.ClusterOrder{}
	if err := r.Get(ctx, req.NamespacedName, co); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}
	if !co.DeletionTimestamp.IsZero() {
		// Deletion / finalizer-driven BMI cleanup lands in OSAC-4176.
		return ctrl.Result{}, nil
	}
	if v, ok := co.Annotations[managementStateAnnotation]; ok && v == managementStateUnmanaged {
		return ctrl.Result{}, nil
	}
	if !co.HasBareMetalNodeSet() {
		return ctrl.Result{}, nil
	}

	if res, err := r.ensureSystemCatalogItem(ctx, co); err != nil || !res.IsZero() {
		return res, err
	}

	ignition, res, err := r.ensureInfraEnv(ctx, co)
	if err != nil || !res.IsZero() {
		return res, err
	}

	diskImageID, res, err := r.resolveDiskImage(ctx, co)
	if err != nil || !res.IsZero() {
		return res, err
	}

	return r.reconcileWorkers(ctx, co, diskImageID, ignition)
}

// ensureInfraEnv creates one InfraEnv per ClusterOrder (late binding, owned by the ClusterOrder),
// then polls for and fetches its discovery ignition, setting the InfraEnvReady condition.
// Returns the fetched ignition bytes once ready.
func (r *Reconciler) ensureInfraEnv(ctx context.Context, co *v1alpha1.ClusterOrder) ([]byte, ctrl.Result, error) {
	key := client.ObjectKey{Name: co.Name + infraEnvNameSuffix, Namespace: co.Namespace}
	existing := &unstructured.Unstructured{}
	existing.SetGroupVersionKind(infraEnvGVK)

	if apimeta.IsStatusConditionTrue(co.Status.Conditions, v1alpha1.ConditionInfraEnvReady) {
		if err := r.Get(ctx, key, existing); err != nil {
			return nil, ctrl.Result{}, fmt.Errorf("getting infraenv %s: %w", key, err)
		}
		return r.fetchDiscoveryIgnition(ctx, co, key, existing)
	}

	err := r.Get(ctx, key, existing)
	switch {
	case apierrors.IsNotFound(err):
		res, createErr := r.createInfraEnv(ctx, co, key)
		return nil, res, createErr
	case err != nil:
		return nil, ctrl.Result{}, fmt.Errorf("getting infraenv %s: %w", key, err)
	}
	return r.fetchDiscoveryIgnition(ctx, co, key, existing)
}

// createInfraEnv creates the InfraEnv and marks InfraEnvReady=False (ignition pending), requeuing.
func (r *Reconciler) createInfraEnv(ctx context.Context, co *v1alpha1.ClusterOrder, key client.ObjectKey) (ctrl.Result, error) {
	infraEnv, err := r.buildInfraEnv(co, key.Name)
	if err != nil {
		return ctrl.Result{}, err
	}
	if err := r.Create(ctx, infraEnv); err != nil && !apierrors.IsAlreadyExists(err) {
		return ctrl.Result{}, fmt.Errorf("creating infraenv %s: %w", key, err)
	}
	ctrllog.FromContext(ctx).Info("created InfraEnv", "infraenv", key.String())
	if err := r.setInfraEnvReady(ctx, co, metav1.ConditionFalse, reasonIgnitionPending,
		"InfraEnv created; waiting for discovery ignition"); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{RequeueAfter: infraEnvRequeueInterval}, nil
}

// fetchDiscoveryIgnition polls the InfraEnv's discovery ignition URL and, once available, fetches
// the ignition (warning if oversized) and marks InfraEnvReady=True. Returns the fetched bytes.
func (r *Reconciler) fetchDiscoveryIgnition(
	ctx context.Context, co *v1alpha1.ClusterOrder, key client.ObjectKey, infraEnv *unstructured.Unstructured,
) ([]byte, ctrl.Result, error) {
	ignitionURL, _, err := unstructured.NestedString(infraEnv.Object, "status", "bootArtifacts", "discoveryIgnitionURL")
	if err != nil {
		return nil, ctrl.Result{}, fmt.Errorf("reading infraenv %s ignition URL: %w", key, err)
	}
	if ignitionURL == "" {
		if condErr := r.setInfraEnvReady(ctx, co, metav1.ConditionFalse, reasonIgnitionPending,
			"waiting for discovery ignition URL"); condErr != nil {
			return nil, ctrl.Result{}, condErr
		}
		return nil, ctrl.Result{RequeueAfter: infraEnvRequeueInterval}, nil
	}

	ignition, err := r.ignition.FetchIgnition(ctx, ignitionURL)
	if err != nil {
		return nil, ctrl.Result{}, fmt.Errorf("fetching discovery ignition for %s: %w", key, err)
	}
	if len(ignition) > ignitionSizeWarningThreshold {
		r.recorder.Eventf(co, corev1.EventTypeWarning, eventReasonIgnitionSizeWarning,
			"discovery ignition is %d bytes, exceeding the %d byte warning threshold", len(ignition), ignitionSizeWarningThreshold)
	}
	if !apimeta.IsStatusConditionTrue(co.Status.Conditions, v1alpha1.ConditionInfraEnvReady) {
		if err := r.setInfraEnvReady(ctx, co, metav1.ConditionTrue, reasonInfraEnvReady,
			"discovery ignition fetched"); err != nil {
			return nil, ctrl.Result{}, err
		}
	}
	return ignition, ctrl.Result{}, nil
}

// buildInfraEnv constructs the (unstructured) InfraEnv object: late binding (no clusterRef),
// owned by the ClusterOrder, referencing the cluster pull secret and SSH key.
func (r *Reconciler) buildInfraEnv(co *v1alpha1.ClusterOrder, name string) (*unstructured.Unstructured, error) {
	infraEnv := &unstructured.Unstructured{}
	infraEnv.SetGroupVersionKind(infraEnvGVK)
	infraEnv.SetName(name)
	infraEnv.SetNamespace(co.Namespace)

	// The pull-secret Secret is provisioned by the cluster provisioning flow; the InfraEnv
	// references it by the conventional name. No clusterRef is set (late binding): agents
	// register unbound and are bound explicitly after MAC correlation (OSAC-4160).
	spec := map[string]interface{}{
		"pullSecretRef": map[string]interface{}{"name": co.Name + pullSecretNameSuffix},
	}
	if co.Spec.SSHPublicKey != "" {
		spec["sshAuthorizedKey"] = co.Spec.SSHPublicKey
	}
	if err := unstructured.SetNestedMap(infraEnv.Object, spec, "spec"); err != nil {
		return nil, fmt.Errorf("building infraenv spec: %w", err)
	}
	if err := controllerutil.SetControllerReference(co, infraEnv, r.scheme); err != nil {
		return nil, fmt.Errorf("setting infraenv owner reference: %w", err)
	}
	return infraEnv, nil
}

// setInfraEnvReady patches only the InfraEnvReady condition on the ClusterOrder, re-reading and
// retrying on conflict so it never clobbers status fields owned by the ClusterOrder controller.
func (r *Reconciler) setInfraEnvReady(
	ctx context.Context, co *v1alpha1.ClusterOrder, status metav1.ConditionStatus, reason, message string,
) error {
	key := client.ObjectKeyFromObject(co)
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &v1alpha1.ClusterOrder{}
		if err := r.apiReader.Get(ctx, key, latest); err != nil {
			return err
		}
		base := latest.DeepCopy()
		latest.SetStatusCondition(v1alpha1.ConditionInfraEnvReady, status, message, reason)
		// Optimistic lock so a concurrent ClusterOrder-controller status write yields a 409 that
		// RetryOnConflict re-reads and re-applies, instead of silently clobbering its conditions.
		return r.Status().Patch(ctx, latest, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
	})
}

// ensureSystemCatalogItem creates the system-owned BareMetalInstanceCatalogItem
// ("system-bmi-passthrough") if it doesn't already exist. Empty field_definitions means all
// fields are unlocked — hardware profile is determined by BareMetalInstanceType, not by this
// catalog item. AlreadyExists is handled gracefully for concurrent reconcile races.
func (r *Reconciler) ensureSystemCatalogItem(ctx context.Context, co *v1alpha1.ClusterOrder) (ctrl.Result, error) {
	log := ctrllog.FromContext(ctx)

	filter := fmt.Sprintf(`metadata.name == "%s"`, systemCatalogItemName)
	items, err := r.fulfillment.ListBareMetalInstanceCatalogItems(ctx, filter)
	if res, handled := r.handleUnavailable(ctx, co, err); handled {
		return res, nil
	}
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("listing catalog items: %w", err)
	}
	if len(items) > 0 {
		return ctrl.Result{}, nil
	}

	ci := privatev1.BareMetalInstanceCatalogItem_builder{
		Metadata: privatev1.Metadata_builder{
			Tenant: systemTenant,
			Name:   systemCatalogItemName,
		}.Build(),
	}.Build()
	ci.SetTitle("System BMI Pass-through")
	ci.SetPublished(true)

	_, err = r.fulfillment.CreateBareMetalInstanceCatalogItem(ctx, ci)
	if err != nil {
		if res, handled := r.handleUnavailable(ctx, co, err); handled {
			return res, nil
		}
		if st, ok := status.FromError(err); ok && st.Code() == codes.AlreadyExists {
			log.Info("system catalog item created concurrently, continuing")
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, fmt.Errorf("creating system catalog item: %w", err)
	}

	log.Info("created system catalog item", "name", systemCatalogItemName)
	return ctrl.Result{}, nil
}

// resolveDiskImage reads the Cluster's ClusterVersion reference via the fulfillment-service
// private API and extracts the DiskImage ID. It re-resolves on every reconcile so a
// ClusterVersion upgrade takes effect without controller restart.
func (r *Reconciler) resolveDiskImage(ctx context.Context, co *v1alpha1.ClusterOrder) (string, ctrl.Result, error) {
	log := ctrllog.FromContext(ctx)

	clusterID := co.Labels[clusterOrderIDLabel]
	if clusterID == "" {
		log.Info("ClusterOrder missing clusterorder-uuid label, requeuing")
		return "", ctrl.Result{RequeueAfter: infraEnvRequeueInterval}, nil
	}

	cluster, err := r.fulfillment.GetCluster(ctx, clusterID)
	if err != nil {
		return "", ctrl.Result{}, fmt.Errorf("getting cluster %s: %w", clusterID, err)
	}

	versionID := cluster.GetSpec().GetVersion().GetId()
	if versionID == "" {
		return "", ctrl.Result{}, fmt.Errorf("cluster %s has no version reference", clusterID)
	}

	cv, err := r.fulfillment.GetClusterVersion(ctx, versionID)
	if err != nil {
		return "", ctrl.Result{}, fmt.Errorf("getting cluster version %s: %w", versionID, err)
	}

	diskImage := cv.GetSpec().GetDiskImage()
	if diskImage == nil || diskImage.GetId() == "" {
		log.Info("ClusterVersion has no disk_image, setting RHCOSImageNotFound", "clusterVersion", versionID)
		if condErr := r.setRHCOSImageNotFound(ctx, co, metav1.ConditionTrue, reasonDiskImageNotFound,
			fmt.Sprintf("ClusterVersion %s has no disk_image reference", versionID)); condErr != nil {
			return "", ctrl.Result{}, condErr
		}
		return "", ctrl.Result{}, nil
	}

	if apimeta.IsStatusConditionTrue(co.Status.Conditions, v1alpha1.ConditionRHCOSImageNotFound) {
		if condErr := r.setRHCOSImageNotFound(ctx, co, metav1.ConditionFalse, reasonDiskImageResolved,
			"disk_image reference resolved"); condErr != nil {
			return "", ctrl.Result{}, condErr
		}
	}

	return diskImage.GetId(), ctrl.Result{}, nil
}

// setRHCOSImageNotFound patches only the RHCOSImageNotFound condition on the ClusterOrder,
// re-reading and retrying on conflict so it never clobbers status fields owned by other controllers.
func (r *Reconciler) setRHCOSImageNotFound(
	ctx context.Context, co *v1alpha1.ClusterOrder, status metav1.ConditionStatus, reason, message string,
) error {
	key := client.ObjectKeyFromObject(co)
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &v1alpha1.ClusterOrder{}
		if err := r.apiReader.Get(ctx, key, latest); err != nil {
			return err
		}
		base := latest.DeepCopy()
		latest.SetStatusCondition(v1alpha1.ConditionRHCOSImageNotFound, status, message, reason)
		return r.Status().Patch(ctx, latest, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
	})
}

// reconcileWorkers creates one BareMetalInstance per requested bare-metal worker, idempotently
// (list-before-create + AlreadyExists handling), and updates status.workers.
func (r *Reconciler) reconcileWorkers(
	ctx context.Context, co *v1alpha1.ClusterOrder, diskImageID string, ignition []byte,
) (ctrl.Result, error) {
	filter := fmt.Sprintf(`metadata.labels["%s"] == "%s"`, clusterOrderLabel, co.Name)
	existing, err := r.fulfillment.ListBareMetalInstances(ctx, filter)
	if res, handled := r.handleUnavailable(ctx, co, err); handled {
		return res, nil
	}
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("listing BMIs for %s: %w", co.Name, err)
	}

	existingByName := bmisByName(existing)
	ignitionB64 := base64.StdEncoding.EncodeToString(ignition)

	workers, res, err := r.reconcileNodeSets(ctx, co, existingByName, diskImageID, ignitionB64, filter)
	if err != nil || !res.IsZero() {
		return res, err
	}

	if apimeta.IsStatusConditionTrue(co.Status.Conditions, v1alpha1.ConditionFulfillmentServiceUnavailable) {
		if condErr := r.setFulfillmentServiceUnavailable(ctx, co, metav1.ConditionFalse,
			reasonFulfillmentAvailable, "fulfillment service recovered"); condErr != nil {
			return ctrl.Result{}, condErr
		}
	}

	if err := r.updateWorkerStatus(ctx, co, workers); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

// reconcileNodeSets iterates bare-metal node requests and ensures a BMI exists for each worker slot.
func (r *Reconciler) reconcileNodeSets(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	existingByName map[string]*privatev1.BareMetalInstance,
	diskImageID, ignitionB64, filter string,
) ([]v1alpha1.WorkerStatus, ctrl.Result, error) {
	log := ctrllog.FromContext(ctx)
	var workers []v1alpha1.WorkerStatus
	globalIndex := 0

	for i := range co.Spec.NodeRequests {
		nr := &co.Spec.NodeRequests[i]
		if !nr.IsBareMetal() {
			continue
		}
		for j := 0; j < nr.NumberOfNodes; j++ {
			workerName := fmt.Sprintf("%s-worker-%d", co.Name, globalIndex)
			globalIndex++

			if bmi, ok := existingByName[workerName]; ok {
				log.Info("worker BMI already exists, skipping create", "name", workerName)
				workers = append(workers, newWorkerStatus(nr.ResourceClass, workerName, bmi.GetId()))
				continue
			}

			bmi, res, err := r.ensureBMI(ctx, co, *nr, workerName, diskImageID, ignitionB64, filter)
			if err != nil {
				return nil, ctrl.Result{}, err
			}
			if !res.IsZero() {
				return nil, res, nil
			}
			log.Info("created BMI", "name", workerName, "id", bmi.GetId())
			workers = append(workers, newWorkerStatus(nr.ResourceClass, workerName, bmi.GetId()))
		}
	}

	return workers, ctrl.Result{}, nil
}

// ensureBMI creates a single BareMetalInstance, handling the AlreadyExists race by re-listing.
// Returns the BMI, a non-zero result on unavailability backoff, or an error.
func (r *Reconciler) ensureBMI(
	ctx context.Context, co *v1alpha1.ClusterOrder, nodeSet v1alpha1.NodeRequest,
	workerName, diskImageID, ignitionB64, filter string,
) (*privatev1.BareMetalInstance, ctrl.Result, error) {
	req := r.buildBMICreateRequest(co, nodeSet, workerName, diskImageID, ignitionB64)
	created, err := r.fulfillment.CreateBareMetalInstance(ctx, req)
	if err == nil {
		return created, ctrl.Result{}, nil
	}

	if res, handled := r.handleUnavailable(ctx, co, err); handled {
		return nil, res, nil
	}

	if st, ok := status.FromError(err); ok && st.Code() == codes.AlreadyExists {
		bmi, listErr := r.findBMIByName(ctx, filter, workerName)
		if listErr != nil {
			return nil, ctrl.Result{}, listErr
		}
		return bmi, ctrl.Result{}, nil
	}

	return nil, ctrl.Result{}, fmt.Errorf("creating BMI %s: %w", workerName, err)
}

// handleUnavailable checks whether err is ErrFulfillmentServiceUnavailable and, if so, sets the
// condition and returns a backoff result. Returns (result, true) when handled, (zero, false) otherwise.
func (r *Reconciler) handleUnavailable(ctx context.Context, co *v1alpha1.ClusterOrder, err error) (ctrl.Result, bool) {
	if !errors.Is(err, ErrFulfillmentServiceUnavailable) {
		return ctrl.Result{}, false
	}
	ctrllog.FromContext(ctx).Info("fulfillment service unavailable, backing off")
	if condErr := r.setFulfillmentServiceUnavailable(ctx, co, metav1.ConditionTrue,
		reasonFulfillmentUnavailable, err.Error()); condErr != nil {
		return ctrl.Result{}, false
	}
	return ctrl.Result{RequeueAfter: unavailableBackoff}, true
}

// findBMIByName re-lists BMIs and returns the one matching the given name.
func (r *Reconciler) findBMIByName(ctx context.Context, filter, name string) (*privatev1.BareMetalInstance, error) {
	ctrllog.FromContext(ctx).Info("BMI create returned AlreadyExists, re-listing", "name", name)
	refreshed, err := r.fulfillment.ListBareMetalInstances(ctx, filter)
	if err != nil {
		return nil, fmt.Errorf("re-listing BMIs after AlreadyExists: %w", err)
	}
	for _, bmi := range refreshed {
		if bmi.GetMetadata().GetName() == name {
			return bmi, nil
		}
	}
	return nil, fmt.Errorf("BMI %s returned AlreadyExists but not found in re-list", name)
}

func newWorkerStatus(nodeSet, name, resourceID string) v1alpha1.WorkerStatus {
	return v1alpha1.WorkerStatus{
		NodeSet:    nodeSet,
		Name:       name,
		Kind:       workerKindBMI,
		ResourceID: resourceID,
		Phase:      workerPhaseProvisioning,
	}
}

func bmisByName(bmis []*privatev1.BareMetalInstance) map[string]*privatev1.BareMetalInstance {
	m := make(map[string]*privatev1.BareMetalInstance, len(bmis))
	for _, bmi := range bmis {
		m[bmi.GetMetadata().GetName()] = bmi
	}
	return m
}

func (r *Reconciler) buildBMICreateRequest(
	co *v1alpha1.ClusterOrder, nodeSet v1alpha1.NodeRequest, workerName, diskImageID, ignitionB64 string,
) *privatev1.BareMetalInstance {
	labels := map[string]string{clusterOrderLabel: co.Name}
	annotations := map[string]string{ownerReferenceAnnotation: fmt.Sprintf("ClusterOrder/%s", co.Name)}

	var netAttachments []*privatev1.BareMetalNetworkAttachment
	if co.Spec.NetworkAttachment != nil {
		na := co.Spec.NetworkAttachment
		sgRefs := make([]*privatev1.SecurityGroupLocalReference, 0, len(na.SecurityGroupRefs))
		for _, sg := range na.SecurityGroupRefs {
			sgRefs = append(sgRefs, privatev1.SecurityGroupLocalReference_builder{Name: sg}.Build())
		}
		netAttachments = append(netAttachments, privatev1.BareMetalNetworkAttachment_builder{
			Subnet:         privatev1.SubnetLocalReference_builder{Name: na.SubnetRef}.Build(),
			SecurityGroups: sgRefs,
		}.Build())
	}

	return privatev1.BareMetalInstance_builder{
		Metadata: privatev1.Metadata_builder{
			Tenant:      systemTenant,
			Name:        workerName,
			Labels:      labels,
			Annotations: annotations,
		}.Build(),
		Spec: privatev1.BareMetalInstanceSpec_builder{
			CatalogItem: privatev1.BareMetalInstanceCatalogItemReference_builder{
				Name: systemCatalogItemName,
			}.Build(),
			Image: privatev1.BareMetalInstanceImage_builder{
				SourceType: "disk_image",
				SourceRef:  diskImageID,
			}.Build(),
			UserData:           &ignitionB64,
			InstanceType:       nodeSet.BareMetal.InstanceType,
			NetworkAttachments: netAttachments,
		}.Build(),
	}.Build()
}

// setFulfillmentServiceUnavailable patches the FulfillmentServiceUnavailable condition on the
// ClusterOrder, re-reading and retrying on conflict.
func (r *Reconciler) setFulfillmentServiceUnavailable(
	ctx context.Context, co *v1alpha1.ClusterOrder, condStatus metav1.ConditionStatus, reason, message string,
) error {
	key := client.ObjectKeyFromObject(co)
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &v1alpha1.ClusterOrder{}
		if err := r.apiReader.Get(ctx, key, latest); err != nil {
			return err
		}
		base := latest.DeepCopy()
		latest.SetStatusCondition(v1alpha1.ConditionFulfillmentServiceUnavailable, condStatus, message, reason)
		return r.Status().Patch(ctx, latest, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
	})
}

// updateWorkerStatus patches status.workers on the ClusterOrder, re-reading and retrying on conflict.
func (r *Reconciler) updateWorkerStatus(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) error {
	key := client.ObjectKeyFromObject(co)
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &v1alpha1.ClusterOrder{}
		if err := r.apiReader.Get(ctx, key, latest); err != nil {
			return err
		}
		base := latest.DeepCopy()
		latest.Status.Workers = workers
		return r.Status().Patch(ctx, latest, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
	})
}

func namespacePredicate(namespace string) predicate.Predicate {
	return predicate.NewPredicateFuncs(func(obj client.Object) bool {
		return obj.GetNamespace() == namespace
	})
}

// SetupWithManager registers the reconciler, watching ClusterOrder in the configured namespace.
//
// Agent watching (for MAC correlation) lands in OSAC-4160, where it can be gated on the
// assisted-service Agent CRD's presence: watching that CRD unconditionally here would make it a
// hard startup dependency for every osac-operator deployment (the manager fails to start if the
// CRD is absent).
func (r *Reconciler) SetupWithManager(mgr mcmanager.Manager) error {
	localMgr := mgr.GetLocalManager()
	if localMgr == nil {
		return fmt.Errorf("local manager is nil")
	}
	return ctrl.NewControllerManagedBy(localMgr).
		Named("baremetalworker").
		For(&v1alpha1.ClusterOrder{}, builder.WithPredicates(namespacePredicate(r.clusterOrderNamespace))).
		Complete(r)
}
