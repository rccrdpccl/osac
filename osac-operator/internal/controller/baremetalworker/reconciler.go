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
	"k8s.io/client-go/tools/events"
	"k8s.io/client-go/util/retry"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	controllerutil "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
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

	eventReasonWorkerRetry     = "WorkerRetry"
	eventReasonWorkerFailed    = "WorkerFailed"
	reasonWorkersFailed        = "WorkersRetrying"
	reasonWorkersFailedCleared = "AllWorkersHealthy"

	infraEnvUIDAnnotation            = "osac.openshift.io/infraenv-uid"
	eventReasonStaleIgnition         = "StaleIgnition"
	reasonInfraEnvRecreated          = "InfraEnvRecreated"
	reasonStaleIgnitionWorkersMarked = "StaleIgnitionWorkersMarked"

	workerPhaseUnbinding = "Unbinding"
	workerPhaseDeleting  = "Deleting"

	agentUnbindingState              = "unbinding-pending-user-action"
	agentUnbindingTimeout            = 30 * time.Minute
	eventReasonWorkerDeleted         = "WorkerDeleted"
	eventReasonAgentUnbindingTimeout = "AgentUnbindingTimeout"
	teardownRequeueInterval          = 30 * time.Second
)

var infraEnvGVK = schema.GroupVersionKind{Group: "agent-install.openshift.io", Version: agentInstallAPIVersion, Kind: "InfraEnv"}

// Reconciler is the bare-metal worker reconciler (BareMetalWorkerReconciler). It watches
// ClusterOrder resources with bare-metal node sets, ensures a cluster-specific InfraEnv exists,
// creates BMIs, correlates registered Agents by MAC, and converges NodePool replicas.
type Reconciler struct {
	client.Client
	apiReader             client.Reader
	scheme                *runtime.Scheme
	fulfillment           FulfillmentClient
	ignition              IgnitionFetcher
	recorder              events.EventRecorder
	clusterOrderNamespace string
	macResolver           MACResolver
}

// NewReconciler builds the bare-metal worker reconciler.
func NewReconciler(
	c client.Client,
	apiReader client.Reader,
	scheme *runtime.Scheme,
	fulfillment FulfillmentClient,
	ignition IgnitionFetcher,
	recorder events.EventRecorder,
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
		macResolver:           func(string) string { return "" },
	}
}

// SetMACResolver sets the function used to resolve a BMI's host MAC address for agent
// correlation. In tests, this is wired to the fake's HostMAC; in production, it will read
// from the BMI status once the proto field lands (OSAC-2308/OSAC-3254).
func (r *Reconciler) SetMACResolver(resolver MACResolver) {
	r.macResolver = resolver
}

// +kubebuilder:rbac:groups=osac.openshift.io,resources=clusterorders,verbs=get;list;watch
// +kubebuilder:rbac:groups=osac.openshift.io,resources=clusterorders/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=agent-install.openshift.io,resources=infraenvs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=agent-install.openshift.io,resources=agents,verbs=get;list;watch;patch;delete
// +kubebuilder:rbac:groups=hypershift.openshift.io,resources=nodepools,verbs=get;list;watch;patch

// Reconcile ensures the InfraEnv for a bare-metal ClusterOrder exists, creates BMIs, correlates
// registered Agents by MAC, and converges NodePool replicas.
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

	ignition, infraEnvUID, res, err := r.ensureInfraEnv(ctx, co)
	if err != nil || !res.IsZero() {
		return res, err
	}

	if r.detectStaleIgnitionWorkers(ctx, co, infraEnvUID) {
		if err := r.apiReader.Get(ctx, req.NamespacedName, co); err != nil {
			return ctrl.Result{}, fmt.Errorf("re-reading ClusterOrder after stale detection: %w", err)
		}
	}
	r.trackInfraEnvUID(ctx, co, infraEnvUID)

	diskImageID, res, err := r.resolveDiskImage(ctx, co)
	if err != nil || !res.IsZero() {
		return res, err
	}

	res, err = r.reconcileWorkers(ctx, co, diskImageID, ignition)
	if err != nil || !res.IsZero() {
		return res, err
	}

	// Re-read the ClusterOrder to pick up the workers just written by reconcileWorkers.
	if err := r.apiReader.Get(ctx, req.NamespacedName, co); err != nil {
		return ctrl.Result{}, fmt.Errorf("re-reading ClusterOrder: %w", err)
	}

	teardownWorkers := co.Status.Workers
	teardownWorkers = r.handleUnbindingWorkers(ctx, co, teardownWorkers)
	teardownWorkers = r.handleDeletingWorkers(ctx, co, teardownWorkers)
	if !workerSlicesEqual(co.Status.Workers, teardownWorkers) {
		if err := r.updateWorkerStatus(ctx, co, teardownWorkers); err != nil {
			return ctrl.Result{}, fmt.Errorf("updating worker status after teardown: %w", err)
		}
		if err := r.apiReader.Get(ctx, req.NamespacedName, co); err != nil {
			return ctrl.Result{}, fmt.Errorf("re-reading ClusterOrder after teardown: %w", err)
		}
	}

	workers, res, err := r.correlateAgents(ctx, co, co.Status.Workers)
	if err != nil {
		return ctrl.Result{}, err
	}

	npRes, npErr := r.reconcileNodePoolReplicas(ctx, co, workers)
	if npErr != nil {
		return ctrl.Result{}, npErr
	}

	if err := r.updateWorkerStatusWithCorrelation(ctx, co, workers); err != nil {
		return ctrl.Result{}, err
	}

	if !res.IsZero() {
		return res, nil
	}
	if hasTeardownWorkers(workers) {
		return ctrl.Result{RequeueAfter: teardownRequeueInterval}, nil
	}
	return npRes, nil
}

// ensureInfraEnv creates one InfraEnv per ClusterOrder (late binding, owned by the ClusterOrder),
// then polls for and fetches its discovery ignition, setting the InfraEnvReady condition.
// Returns the fetched ignition bytes and the InfraEnv's UID once ready.
func (r *Reconciler) ensureInfraEnv(ctx context.Context, co *v1alpha1.ClusterOrder) ([]byte, string, ctrl.Result, error) {
	key := client.ObjectKey{Name: co.Name + infraEnvNameSuffix, Namespace: co.Namespace}
	existing := &unstructured.Unstructured{}
	existing.SetGroupVersionKind(infraEnvGVK)

	if apimeta.IsStatusConditionTrue(co.Status.Conditions, v1alpha1.ConditionInfraEnvReady) {
		if err := r.Get(ctx, key, existing); err != nil {
			if !apierrors.IsNotFound(err) {
				return nil, "", ctrl.Result{}, fmt.Errorf("getting infraenv %s: %w", key, err)
			}
			ctrllog.FromContext(ctx).Info("InfraEnv deleted while InfraEnvReady=True, resetting condition", "infraenv", key)
			if condErr := r.setInfraEnvReady(ctx, co, metav1.ConditionFalse, reasonInfraEnvRecreated,
				"InfraEnv was deleted; recreating"); condErr != nil {
				return nil, "", ctrl.Result{}, condErr
			}
			res, createErr := r.createInfraEnv(ctx, co, key)
			return nil, "", res, createErr
		}
		ign, res, err := r.fetchDiscoveryIgnition(ctx, co, key, existing)
		return ign, string(existing.GetUID()), res, err
	}

	err := r.Get(ctx, key, existing)
	switch {
	case apierrors.IsNotFound(err):
		res, createErr := r.createInfraEnv(ctx, co, key)
		return nil, "", res, createErr
	case err != nil:
		return nil, "", ctrl.Result{}, fmt.Errorf("getting infraenv %s: %w", key, err)
	}
	ign, res, fetchErr := r.fetchDiscoveryIgnition(ctx, co, key, existing)
	return ign, string(existing.GetUID()), res, fetchErr
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
		r.recorder.Eventf(co, nil, corev1.EventTypeWarning, eventReasonIgnitionSizeWarning, "FetchIgnition",
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

func (r *Reconciler) setInfraEnvReady(
	ctx context.Context, co *v1alpha1.ClusterOrder, status metav1.ConditionStatus, reason, message string,
) error {
	return r.patchStatusWithRetry(ctx, co, func(latest *v1alpha1.ClusterOrder) {
		latest.SetStatusCondition(v1alpha1.ConditionInfraEnvReady, status, message, reason)
	})
}

// trackInfraEnvUID stores the InfraEnv's UID as an annotation on the ClusterOrder so
// stale ignition can be detected after InfraEnv deletion+recreation.
func (r *Reconciler) trackInfraEnvUID(
	ctx context.Context, co *v1alpha1.ClusterOrder, uid string,
) {
	if uid == "" {
		return
	}
	if co.Annotations != nil && co.Annotations[infraEnvUIDAnnotation] == uid {
		return
	}
	base := co.DeepCopy()
	if co.Annotations == nil {
		co.Annotations = make(map[string]string)
	}
	co.Annotations[infraEnvUIDAnnotation] = uid
	if err := r.Patch(ctx, co, client.MergeFrom(base)); err != nil {
		ctrllog.FromContext(ctx).Error(err, "patching infraenv-uid annotation")
	}
}

// detectStaleIgnitionWorkers checks whether the InfraEnv was recreated since the last
// reconcile. If so, workers in WaitingForAgent phase have stale ignition and are marked
// Failed with AgentRegistrationTimeout so they enter the retry pipeline.
func (r *Reconciler) detectStaleIgnitionWorkers(
	ctx context.Context, co *v1alpha1.ClusterOrder, infraEnvUID string,
) bool {
	storedUID := ""
	if co.Annotations != nil {
		storedUID = co.Annotations[infraEnvUIDAnnotation]
	}
	if storedUID == "" || storedUID == infraEnvUID {
		return false
	}

	log := ctrllog.FromContext(ctx)
	marked := false
	now := metav1.Now()
	for i := range co.Status.Workers {
		w := &co.Status.Workers[i]
		if w.Phase != workerPhaseWaitingForAgent {
			continue
		}
		log.Info("marking worker as stale-ignition failure", "worker", w.Name)
		w.Phase = workerPhaseFailed
		w.LastFailureReason = eventReasonAgentRegistrationTimeout
		w.LastFailureMessage = "stale ignition: InfraEnv was recreated"
		w.LastFailureTime = &now
		marked = true
		r.recorder.Eventf(co, nil, corev1.EventTypeWarning, eventReasonStaleIgnition, "DetectStaleIgnition",
			"worker %s: marked failed due to stale ignition after InfraEnv recreation", w.Name)
	}

	if marked {
		if err := r.updateWorkerStatus(ctx, co, co.Status.Workers); err != nil {
			log.Error(err, "updating worker status after stale ignition detection")
		}
	}
	return marked
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

func (r *Reconciler) setRHCOSImageNotFound(
	ctx context.Context, co *v1alpha1.ClusterOrder, status metav1.ConditionStatus, reason, message string,
) error {
	return r.patchStatusWithRetry(ctx, co, func(latest *v1alpha1.ClusterOrder) {
		latest.SetStatusCondition(v1alpha1.ConditionRHCOSImageNotFound, status, message, reason)
	})
}

// reconcileWorkers creates one BareMetalInstance per requested bare-metal worker, idempotently
// (list-before-create + AlreadyExists handling), and updates status.workers. Preserves existing
// worker phases (Binding, Ready, etc.) for workers that have already been correlated.
// Failed workers are retried with escalating backoff: the failed BMI is deleted, and a
// replacement is created once NextRetryTime has passed.
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

	r.handleFailedWorkers(ctx, co, existingByName)

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

	retryResult := r.earliestRetryRequeue(workers)

	if err := r.updateWorkerStatus(ctx, co, workers); err != nil {
		return ctrl.Result{}, err
	}

	return retryResult, nil
}

// reconcileNodeSets iterates bare-metal node requests and ensures a BMI exists for each worker
// slot. Reuses existing WorkerStatus entries (preserving phase/failure fields) for workers that
// already exist; only creates new entries for genuinely new workers.
func (r *Reconciler) reconcileNodeSets(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	existingByName map[string]*privatev1.BareMetalInstance,
	diskImageID, ignitionB64, filter string,
) ([]v1alpha1.WorkerStatus, ctrl.Result, error) {
	existingWorkers := workersByName(co.Status.Workers)
	var workers []v1alpha1.WorkerStatus
	globalIndex := 0

	if co.Spec.NetworkAttachment == nil {
		return nil, ctrl.Result{}, fmt.Errorf("ClusterOrder %s has no networkAttachment", co.Name)
	}

	for i := range co.Spec.NodeRequests {
		nr := &co.Spec.NodeRequests[i]
		if !nr.IsBareMetal() {
			continue
		}

		fabricInterface, res, err := r.resolveFabricInterfaceForNodeSet(ctx, co, nr.BareMetal.InstanceType)
		if err != nil {
			return nil, ctrl.Result{}, err
		}
		if !res.IsZero() {
			return nil, res, nil
		}

		for j := 0; j < nr.NumberOfNodes; j++ {
			workerName := fmt.Sprintf("%s-worker-%d", co.Name, globalIndex)
			globalIndex++

			if prev, ok := existingWorkers[workerName]; ok {
				res, err := r.retryFailedWorker(ctx, co, nr, &prev, diskImageID, ignitionB64, filter, fabricInterface)
				if err != nil {
					return nil, ctrl.Result{}, err
				}
				if !res.IsZero() {
					return nil, res, nil
				}
				workers = append(workers, prev)
				continue
			}

			ws, res, err := r.ensureWorkerBMI(ctx, co, nr, workerName, existingByName, diskImageID, ignitionB64, filter, fabricInterface)
			if err != nil {
				return nil, ctrl.Result{}, err
			}
			if !res.IsZero() {
				return nil, res, nil
			}
			workers = append(workers, ws)
		}
	}

	excess := r.identifyExcessWorkers(co, workers)
	if len(excess) > 0 {
		workers = r.handleScaleDown(ctx, co, workers, excess)
	}

	return workers, ctrl.Result{}, nil
}

// retryFailedWorker creates a replacement BMI for a failed worker whose retry is due.
// Returns a non-zero result if the fulfillment service is unavailable. If the worker is not
// eligible for retry, this is a no-op.
func (r *Reconciler) retryFailedWorker(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	nr *v1alpha1.NodeRequest, prev *v1alpha1.WorkerStatus,
	diskImageID, ignitionB64, filter, fabricInterface string,
) (ctrl.Result, error) {
	if prev.Phase != workerPhaseFailed || prev.ResourceID != "" || !isRetryDue(*prev) {
		return ctrl.Result{}, nil
	}
	log := ctrllog.FromContext(ctx)
	bmi, res, err := r.ensureBMI(ctx, co, *nr, prev.Name, diskImageID, ignitionB64, filter, fabricInterface)
	if err != nil {
		return ctrl.Result{}, err
	}
	if !res.IsZero() {
		return res, nil
	}
	log.Info("created replacement BMI for failed worker", "name", prev.Name, "attempt", prev.AttemptCount, "id", bmi.GetId())
	prev.ResourceID = bmi.GetId()
	prev.Phase = workerPhaseWaitingForAgent
	prev.NextRetryTime = nil
	r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonWorkerRetry, "RetryWorker",
		"worker %s: retry attempt %d", prev.Name, prev.AttemptCount)
	return ctrl.Result{}, nil
}

// ensureWorkerBMI creates a BMI for a new worker slot, skipping creation if a BMI with the
// same name already exists (list-before-create idempotency after controller restart).
func (r *Reconciler) ensureWorkerBMI(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	nr *v1alpha1.NodeRequest, workerName string,
	existingByName map[string]*privatev1.BareMetalInstance,
	diskImageID, ignitionB64, filter, fabricInterface string,
) (v1alpha1.WorkerStatus, ctrl.Result, error) {
	log := ctrllog.FromContext(ctx)
	if bmi, ok := existingByName[workerName]; ok {
		log.Info("worker BMI already exists, skipping create", "name", workerName)
		return newWorkerStatus(nr.ResourceClass, workerName, bmi.GetId()), ctrl.Result{}, nil
	}

	bmi, res, err := r.ensureBMI(ctx, co, *nr, workerName, diskImageID, ignitionB64, filter, fabricInterface)
	if err != nil {
		return v1alpha1.WorkerStatus{}, ctrl.Result{}, err
	}
	if !res.IsZero() {
		return v1alpha1.WorkerStatus{}, res, nil
	}
	log.Info("created BMI", "name", workerName, "id", bmi.GetId())
	return newWorkerStatus(nr.ResourceClass, workerName, bmi.GetId()), ctrl.Result{}, nil
}

// desiredWorkerNames returns the set of worker names derived from the current NodeRequests.
func desiredWorkerNames(co *v1alpha1.ClusterOrder) map[string]bool {
	names := make(map[string]bool)
	globalIndex := 0
	for i := range co.Spec.NodeRequests {
		nr := &co.Spec.NodeRequests[i]
		if !nr.IsBareMetal() {
			continue
		}
		for j := 0; j < nr.NumberOfNodes; j++ {
			names[fmt.Sprintf("%s-worker-%d", co.Name, globalIndex)] = true
			globalIndex++
		}
	}
	return names
}

// identifyExcessWorkers returns workers in status that are not in the desired set and are not
// already in a teardown phase (Unbinding/Deleting).
func (r *Reconciler) identifyExcessWorkers(
	co *v1alpha1.ClusterOrder, currentWorkers []v1alpha1.WorkerStatus,
) []v1alpha1.WorkerStatus {
	desired := desiredWorkerNames(co)
	var excess []v1alpha1.WorkerStatus
	for _, w := range co.Status.Workers {
		if desired[w.Name] {
			continue
		}
		alreadyTracked := false
		for _, cw := range currentWorkers {
			if cw.Name == w.Name {
				alreadyTracked = true
				break
			}
		}
		if alreadyTracked {
			continue
		}
		excess = append(excess, w)
	}
	return excess
}

// handleScaleDown processes excess workers: removes Failed workers first (deleting their BMIs),
// then marks remaining excess as Unbinding. Failed-first ordering ensures dead workers are cleaned
// before healthy ones are touched.
func (r *Reconciler) handleScaleDown(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	workers []v1alpha1.WorkerStatus, excess []v1alpha1.WorkerStatus,
) []v1alpha1.WorkerStatus {
	log := ctrllog.FromContext(ctx)

	// Remove Failed excess first.
	var remaining []v1alpha1.WorkerStatus
	for _, w := range excess {
		if w.Phase == workerPhaseFailed {
			if w.ResourceID != "" {
				if err := r.fulfillment.DeleteBareMetalInstance(ctx, w.ResourceID); err != nil {
					log.Error(err, "deleting excess failed BMI", "worker", w.Name)
					workers = append(workers, w)
					continue
				}
				log.Info("deleted excess failed BMI", "worker", w.Name, "bmiID", w.ResourceID)
			}
			r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonWorkerDeleted, "ScaleDown",
				"removed failed worker %s during scale-down", w.Name)
			continue
		}
		remaining = append(remaining, w)
	}

	// Mark non-failed excess as Unbinding.
	now := metav1.Now()
	for i := range remaining {
		w := &remaining[i]
		if w.Phase == workerPhaseUnbinding || w.Phase == workerPhaseDeleting {
			workers = append(workers, *w)
			continue
		}
		log.Info("marking worker for scale-down", "worker", w.Name, "previousPhase", w.Phase)
		w.Phase = workerPhaseUnbinding
		w.LastFailureTime = &now
		r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonWorkerDeleted, "ScaleDown",
			"worker %s marked for unbinding during scale-down", w.Name)
		workers = append(workers, *w)
	}

	return workers
}

// handleUnbindingWorkers processes workers in Unbinding phase: finds matching Agents via the
// worker-name label, waits for the Agent to enter unbinding-pending-user-action, then deletes
// the Agent CR and calls BareMetalInstances.Delete. Transitions to Deleting after BMI delete
// is initiated. Checks for unbinding timeout (30 min).
func (r *Reconciler) handleUnbindingWorkers(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	workers []v1alpha1.WorkerStatus,
) []v1alpha1.WorkerStatus {
	log := ctrllog.FromContext(ctx)
	agents, err := r.listAgents(ctx, co)
	if err != nil {
		log.Error(err, "listing agents for unbinding check")
		return workers
	}

	now := time.Now()
	for i := range workers {
		w := &workers[i]
		if w.Phase != workerPhaseUnbinding {
			continue
		}

		agent := findAgentByWorkerName(agents, w.Name)
		if agent == nil {
			log.Info("no agent found for unbinding worker, transitioning to Deleting", "worker", w.Name)
			w.Phase = workerPhaseDeleting
			continue
		}

		state, _, _ := unstructured.NestedString(agent.Object, "status", "debugInfo", "state")
		if state != agentUnbindingState {
			if w.LastFailureTime != nil && now.Sub(w.LastFailureTime.Time) > agentUnbindingTimeout {
				log.Info("agent unbinding timeout", "worker", w.Name, "agent", agent.GetName())
				w.LastFailureReason = eventReasonAgentUnbindingTimeout
				w.LastFailureMessage = fmt.Sprintf("agent %s stuck unbinding for > %s", agent.GetName(), agentUnbindingTimeout)
				r.recorder.Eventf(co, nil, corev1.EventTypeWarning, eventReasonAgentUnbindingTimeout, "UnbindTimeout",
					"worker %s: agent %s stuck unbinding", w.Name, agent.GetName())
			}
			continue
		}

		if err := r.Delete(ctx, agent); err != nil {
			log.Error(err, "deleting agent CR", "agent", agent.GetName())
			continue
		}
		log.Info("deleted agent CR", "worker", w.Name, "agent", agent.GetName())
		w.Phase = workerPhaseDeleting
	}
	return workers
}

// handleDeletingWorkers processes workers in Deleting phase: checks if the BMI is confirmed
// deleted (GetBareMetalInstance returns NotFound), and removes the entry. Retries Delete if
// the BMI still exists.
func (r *Reconciler) handleDeletingWorkers(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	workers []v1alpha1.WorkerStatus,
) []v1alpha1.WorkerStatus {
	log := ctrllog.FromContext(ctx)
	var kept []v1alpha1.WorkerStatus
	for i := range workers {
		w := &workers[i]
		if w.Phase != workerPhaseDeleting {
			kept = append(kept, *w)
			continue
		}
		if w.ResourceID == "" {
			log.Info("worker deletion confirmed (no resource ID)", "worker", w.Name)
			r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonWorkerDeleted, "ConfirmDeletion",
				"worker %s removed after BMI deletion confirmed", w.Name)
			continue
		}
		_, err := r.fulfillment.GetBareMetalInstance(ctx, w.ResourceID)
		if err != nil {
			if status.Code(err) == codes.NotFound {
				log.Info("worker BMI deletion confirmed", "worker", w.Name, "bmiID", w.ResourceID)
				r.recorder.Eventf(co, nil, corev1.EventTypeNormal, eventReasonWorkerDeleted, "ConfirmDeletion",
					"worker %s removed after BMI %s deletion confirmed", w.Name, w.ResourceID)
				continue
			}
			log.Error(err, "checking BMI existence for deleting worker", "worker", w.Name)
		} else {
			if delErr := r.fulfillment.DeleteBareMetalInstance(ctx, w.ResourceID); delErr != nil {
				log.Error(delErr, "retrying BMI deletion", "worker", w.Name)
			}
		}
		kept = append(kept, *w)
	}
	return kept
}

// findAgentByWorkerName finds an Agent with the given worker-name label.
func findAgentByWorkerName(agents *unstructured.UnstructuredList, workerName string) *unstructured.Unstructured {
	for idx := range agents.Items {
		agent := &agents.Items[idx]
		if agent.GetLabels()[workerNameLabel] == workerName {
			return agent
		}
	}
	return nil
}

// workerSlicesEqual returns true if the two worker slices have the same length and
// each worker has the same Name and Phase. Used to detect whether teardown handlers
// changed anything.
func workerSlicesEqual(a, b []v1alpha1.WorkerStatus) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Name != b[i].Name || a[i].Phase != b[i].Phase {
			return false
		}
	}
	return true
}

// hasTeardownWorkers returns true if any workers are in Unbinding or Deleting phase.
func hasTeardownWorkers(workers []v1alpha1.WorkerStatus) bool {
	for _, w := range workers {
		if w.Phase == workerPhaseUnbinding || w.Phase == workerPhaseDeleting {
			return true
		}
	}
	return false
}

// handleFailedWorkers processes workers in Failed phase: deletes their BMIs via the
// fulfillment API, increments attemptCount, computes failure-appropriate backoff, and
// sets NextRetryTime. The failed BMI's ResourceID is cleared so reconcileNodeSets
// creates a replacement when the retry is due.
func (r *Reconciler) handleFailedWorkers(
	ctx context.Context, co *v1alpha1.ClusterOrder,
	existingByName map[string]*privatev1.BareMetalInstance,
) {
	log := ctrllog.FromContext(ctx)
	for i := range co.Status.Workers {
		w := &co.Status.Workers[i]
		if w.Phase != workerPhaseFailed || w.ResourceID == "" {
			continue
		}
		if err := r.fulfillment.DeleteBareMetalInstance(ctx, w.ResourceID); err != nil {
			log.Error(err, "deleting failed BMI", "worker", w.Name, "bmiID", w.ResourceID)
			continue
		}
		log.Info("deleted failed BMI", "worker", w.Name, "bmiID", w.ResourceID)
		delete(existingByName, w.Name)

		w.AttemptCount++
		category := ClassifyFailure(w.LastFailureReason)
		backoff := ComputeBackoff(category, w.AttemptCount)
		now := metav1.Now()
		retryTime := metav1.NewTime(now.Add(backoff))
		w.NextRetryTime = &retryTime
		w.ResourceID = ""
		w.ReadySince = nil
		r.recorder.Eventf(co, nil, corev1.EventTypeWarning, eventReasonWorkerFailed, "HandleFailedWorker",
			"worker %s: failed (attempt %d, reason %s), next retry in %s",
			w.Name, w.AttemptCount, w.LastFailureReason, backoff)
	}
}

// isRetryDue returns true if a Failed worker's NextRetryTime has passed (or is nil).
func isRetryDue(w v1alpha1.WorkerStatus) bool {
	if w.NextRetryTime == nil {
		return true
	}
	return !time.Now().Before(w.NextRetryTime.Time)
}

// earliestRetryRequeue returns a RequeueAfter result for the earliest pending retry
// among Failed workers, or a zero result if no retries are pending.
func (r *Reconciler) earliestRetryRequeue(workers []v1alpha1.WorkerStatus) ctrl.Result {
	var earliest time.Time
	for i := range workers {
		w := &workers[i]
		if w.Phase != workerPhaseFailed || w.NextRetryTime == nil {
			continue
		}
		if earliest.IsZero() || w.NextRetryTime.Time.Before(earliest) {
			earliest = w.NextRetryTime.Time
		}
	}
	if earliest.IsZero() {
		return ctrl.Result{}
	}
	delay := time.Until(earliest)
	if delay < time.Second {
		delay = time.Second
	}
	return ctrl.Result{RequeueAfter: delay}
}

func workersByName(workers []v1alpha1.WorkerStatus) map[string]v1alpha1.WorkerStatus {
	m := make(map[string]v1alpha1.WorkerStatus, len(workers))
	for _, w := range workers {
		m[w.Name] = w
	}
	return m
}

// resolveFabricInterfaceForNodeSet resolves the fabric interface name from the BareMetalInstanceType
// referenced by the node set.
func (r *Reconciler) resolveFabricInterfaceForNodeSet(
	ctx context.Context, co *v1alpha1.ClusterOrder, instanceTypeName string,
) (string, ctrl.Result, error) {
	it, err := r.fulfillment.GetBareMetalInstanceType(ctx, instanceTypeName)
	if res, handled := r.handleUnavailable(ctx, co, err); handled {
		return "", res, nil
	}
	if err != nil {
		return "", ctrl.Result{}, fmt.Errorf("getting BareMetalInstanceType %s: %w", instanceTypeName, err)
	}

	iface, err := resolveFabricInterface(it)
	if err != nil {
		return "", ctrl.Result{}, err
	}
	return iface, ctrl.Result{}, nil
}

// ensureBMI creates a single BareMetalInstance, handling the AlreadyExists race by re-listing.
// Returns the BMI, a non-zero result on unavailability backoff, or an error.
func (r *Reconciler) ensureBMI(
	ctx context.Context, co *v1alpha1.ClusterOrder, nodeSet v1alpha1.NodeRequest,
	workerName, diskImageID, ignitionB64, filter, fabricInterface string,
) (*privatev1.BareMetalInstance, ctrl.Result, error) {
	req := r.buildBMICreateRequest(co, nodeSet, workerName, diskImageID, ignitionB64, fabricInterface)
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
		Phase:      workerPhaseWaitingForAgent,
	}
}

// resolveFabricInterface returns the name of the first network port with role "fabric" from the
// BareMetalInstanceType. Returns an error if no fabric port is found.
func resolveFabricInterface(it *privatev1.BareMetalInstanceType) (string, error) {
	for _, port := range it.GetSpec().GetHardware().GetNetworkPorts() {
		if port.GetRole() == "fabric" {
			return port.GetName(), nil
		}
	}
	return "", fmt.Errorf("BareMetalInstanceType %s has no fabric-role network port", it.GetMetadata().GetName())
}

func bmisByName(bmis []*privatev1.BareMetalInstance) map[string]*privatev1.BareMetalInstance {
	m := make(map[string]*privatev1.BareMetalInstance, len(bmis))
	for _, bmi := range bmis {
		m[bmi.GetMetadata().GetName()] = bmi
	}
	return m
}

func (r *Reconciler) buildBMICreateRequest(
	co *v1alpha1.ClusterOrder, nodeSet v1alpha1.NodeRequest, workerName, diskImageID, ignitionB64, fabricInterface string,
) *privatev1.BareMetalInstance {
	labels := map[string]string{clusterOrderLabel: co.Name}
	annotations := map[string]string{ownerReferenceAnnotation: fmt.Sprintf("ClusterOrder/%s", co.Name)}

	na := co.Spec.NetworkAttachment
	sgRefs := make([]*privatev1.SecurityGroupLocalReference, 0, len(na.SecurityGroupRefs))
	for _, sg := range na.SecurityGroupRefs {
		sgRefs = append(sgRefs, privatev1.SecurityGroupLocalReference_builder{Name: sg}.Build())
	}
	primary := true
	netAttachments := []*privatev1.BareMetalNetworkAttachment{
		privatev1.BareMetalNetworkAttachment_builder{
			Subnet:         privatev1.SubnetLocalReference_builder{Name: na.SubnetRef}.Build(),
			SecurityGroups: sgRefs,
			Interface:      &fabricInterface,
			Primary:        &primary,
		}.Build(),
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

func (r *Reconciler) setFulfillmentServiceUnavailable(
	ctx context.Context, co *v1alpha1.ClusterOrder, condStatus metav1.ConditionStatus, reason, message string,
) error {
	return r.patchStatusWithRetry(ctx, co, func(latest *v1alpha1.ClusterOrder) {
		latest.SetStatusCondition(v1alpha1.ConditionFulfillmentServiceUnavailable, condStatus, message, reason)
	})
}

func (r *Reconciler) updateWorkerStatus(
	ctx context.Context, co *v1alpha1.ClusterOrder, workers []v1alpha1.WorkerStatus,
) error {
	return r.patchStatusWithRetry(ctx, co, func(latest *v1alpha1.ClusterOrder) {
		latest.Status.Workers = workers
	})
}

// patchStatusWithRetry re-reads the ClusterOrder and applies the mutate function to its status,
// retrying on conflict with optimistic locking.
func (r *Reconciler) patchStatusWithRetry(
	ctx context.Context, co *v1alpha1.ClusterOrder, mutate func(*v1alpha1.ClusterOrder),
) error {
	key := client.ObjectKeyFromObject(co)
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest := &v1alpha1.ClusterOrder{}
		if err := r.apiReader.Get(ctx, key, latest); err != nil {
			return err
		}
		base := latest.DeepCopy()
		mutate(latest)
		return r.Status().Patch(ctx, latest, client.MergeFromWithOptions(base, client.MergeFromWithOptimisticLock{}))
	})
}

func namespacePredicate(namespace string) predicate.Predicate {
	return predicate.NewPredicateFuncs(func(obj client.Object) bool {
		return obj.GetNamespace() == namespace
	})
}

// SetupWithManager registers the reconciler, watching ClusterOrder in the configured namespace.
// Agent and NodePool watches are gated on CRD presence to avoid hard startup dependencies.
func (r *Reconciler) SetupWithManager(mgr mcmanager.Manager) error {
	localMgr := mgr.GetLocalManager()
	if localMgr == nil {
		return fmt.Errorf("local manager is nil")
	}

	log := ctrl.Log.WithName("baremetalworker")
	bld := ctrl.NewControllerManagedBy(localMgr).
		Named("baremetalworker").
		For(&v1alpha1.ClusterOrder{}, builder.WithPredicates(namespacePredicate(r.clusterOrderNamespace)))

	if crdExists(mgr, agentGVK) {
		agentObj := &unstructured.Unstructured{}
		agentObj.SetGroupVersionKind(agentGVK)
		bld = bld.Watches(agentObj, handler.EnqueueRequestsFromMapFunc(r.labelToClusterOrderMapper(clusterOrderLabel)))
		log.Info("watching Agent CRs for MAC correlation")
	} else {
		log.Info("Agent CRD not found, skipping Agent watch")
	}

	npGVK := schema.GroupVersionKind{Group: "hypershift.openshift.io", Version: "v1beta1", Kind: "NodePool"}
	if crdExists(mgr, npGVK) {
		npObj := &unstructured.Unstructured{}
		npObj.SetGroupVersionKind(npGVK)
		bld = bld.Watches(npObj, handler.EnqueueRequestsFromMapFunc(r.labelToClusterOrderMapper("osac.openshift.io/clusterorder")))
		log.Info("watching NodePool CRs for replica convergence")
	} else {
		log.Info("NodePool CRD not found, skipping NodePool watch")
	}

	return bld.Complete(r)
}

// crdExists checks whether a CRD for the given GVK is registered in the API server.
func crdExists(mgr mcmanager.Manager, gvk schema.GroupVersionKind) bool {
	localMgr := mgr.GetLocalManager()
	if localMgr == nil {
		return false
	}
	mapper := localMgr.GetRESTMapper()
	_, err := mapper.RESTMapping(gvk.GroupKind(), gvk.Version)
	return err == nil
}

// labelToClusterOrderMapper returns a MapFunc that maps events to ClusterOrder reconcile
// requests by reading a label value as the ClusterOrder name.
func (r *Reconciler) labelToClusterOrderMapper(labelKey string) handler.MapFunc {
	return func(_ context.Context, obj client.Object) []ctrl.Request {
		coName := obj.GetLabels()[labelKey]
		if coName == "" {
			return nil
		}
		return []ctrl.Request{{
			NamespacedName: client.ObjectKey{Name: coName, Namespace: r.clusterOrderNamespace},
		}}
	}
}
