# Development environment helpers.
#
# `make osac-dev` provisions a dev cluster with cluster-tool, makes this machine
# able to reach it by name, and installs the OSAC prerequisites on it. Each step
# is a standalone script, so any of them can be run on its own:
#
#   tools/dev-env/cluster.sh   cluster-tool server setup, flavor pull, boot
#   tools/dev-env/setup.sh     client setup (dnsmasq, NetworkManager)
#   tools/dev-env/dns.sh       hub zone DNS routing here and on REMOTE_HOST
#   tools/dev-env/resize.sh    grow the hub's root disk to DISK_SIZE
#                              (the flavors are post-install images, so a
#                              clone starts at the image's 93 GiB and kubelet
#                              evicts under disk pressure minutes later)
#   tools/dev-env/deps.sh      osac-deps + osac-infra via osac-installer,
#                              skipped when the releases already match the
#                              in-tree chart version
#   tools/dev-env/bmh.sh       virtual BareMetalHosts on REMOTE_HOST, running
#                              tools/shared/virtual-bmh.sh there over ssh
#   tools/dev-env/osac.sh      prepare and deploy OSAC itself (Helm release
#                              `osac`) through the repository-root skaffold.yaml
#
# Every step is idempotent and skipped when its desired state already exists.
# Re-run them anyway with FORCE=1, e.g.
#
#   make osac-dev FORCE=1              every step, forced
#   make osac-dev-setup FORCE=1        client setup + DNS, forced
#   make osac-dev-cluster FORCE=1      cluster-tool server setup, forced
#
# `make osac-dev` ends with a deployed, ready OSAC: after the cluster steps it
# prepares (osac-dev-prep) and deploys (osac-dev-deploy). Both halves are
# targets of their own, so an iterate loop is
#
#   make osac-dev-prep        build and push every image, upload the AAP
#                             license, rebuild the chart dependencies
#   make osac-dev-deploy      `skaffold deploy` with the tags prep recorded;
#                             no build, no push, then wait for the rollout
#   make osac-dev-aap-project serve this worktree as the AAP config-as-code
#                             project and print its URL (deploy does it too,
#                             and watch mode refreshes it on every rebuild)
#   make osac-dev-watch       `skaffold dev`: prep's initial build, then
#                             rebuild and redeploy on every source change
#   make osac-dev-e2e E2E_SUITE=vmaas/sanity
#                             run an E2E suite against the deployed hub
#   make osac-dev-delete      uninstall the release
#
# Teardown is a menu too, so a run that half finished can be dismantled one
# concern at a time (osac-dev-delete stays as the release-only shortcut):
#
#   make osac-dev-teardown-bmh      BMHs, Redfish emulator, VMs, VM network
#   make osac-dev-teardown-osac     the release and the AAP project server
#   make osac-dev-teardown-cluster  the cluster-tool clone and its kubeconfig
#   make osac-dev-teardown-dns      the hub zone routing here and on the host
#   make osac-dev-teardown-local    the image-tag cache this flow wrote
#   make osac-dev-teardown YES=1    all of the above, in that order
#
# The steps are destructive and ask before each one; YES=1 answers every prompt
# and DRY_RUN=1 only prints the commands. TEARDOWN_CLIENT=1 also reverts
# cluster-tool's client setup, TEARDOWN_FLAVOR=1 also deletes the flavor.
#
# `make osac-dev-e2e` runs the pytest suites in tests/e2e against whatever is
# deployed. The suite is required, because the prerequisites differ by orders of
# magnitude: tests/e2e/projects only needs the API, vmaas/sanity needs a VM
# template and storage, caas/sanity provisions a cluster on the virtual BMHs.
# Narrow a run with E2E_FILTER (pytest -k), E2E_MARKER (pytest -m, e.g.
# 'sanity and not requires_caas'), or E2E_ARGS for anything else. The target
# wires the dev hub's kubeconfig, NS, and an osac CLI built from this worktree;
# the tests derive the cluster domain and the route hostnames themselves.
#
# Images go to IMAGE_PREFIX (quay.io/rh_ee_rpiccoli by default) instead of an
# in-cluster registry, so `podman login quay.io` once. The deploy needs an AAP
# subscription manifest: AAP_LICENSE_FILE=/path/to/license.zip, else
# osac-installer/values/<PROFILE>/license.zip.
#
# Fast path: when OSAC_DEV_HUB_KUBECONFIG points at a valid kubeconfig whose API
# server is reachable, cluster.sh skips cluster-tool entirely and only the
# prerequisites are installed on the existing hub.
#
# Inputs, exported to the scripts (defaults live in tools/dev-env/common.sh):
#   REMOTE_HOST=root@host        SSH target for the cluster-tool server
#   PULL_SECRET_FILE=~/ps.json   local pull secret injected into the cluster
#   OSAC_DEV_HUB_KUBECONFIG=...  existing hub to reuse (fast path)
#   FLAVOR=sno-4-22              flavor to boot (pulled when missing)
#   PROFILE=full-ci NS=osac      osac-installer profile/namespace for deps
#
# Client-side prerequisites (dnsmasq plus NetworkManager dns=dnsmasq) are part
# of the flow: tools/dev-env/setup.sh runs `cluster-tool setup client` when it is
# missing, and tools/dev-env/dns.sh routes the hub zone on this machine and on
# REMOTE_HOST, doing nothing when the entries are already in place.

OSAC_DEV_ENV ?= tools/dev-env

CLUSTER_TOOL            ?= cluster-tool
SERVER_NAME             ?= osac-dev
REMOTE_HOST             ?=
PULL_SECRET_FILE        ?=
OSAC_DEV_HUB_KUBECONFIG ?=
# Must match CLUSTER_TOOL_DATA on REMOTE_HOST, otherwise cluster-tool would pull
# a second copy of the flavor.
CLUSTER_TOOL_DATA       ?= /data/cluster-tool
# The flavor name must equal the image tag: `pull` derives the name from it.
FLAVOR                  ?= sno-4-22
FLAVOR_IMAGE            ?= quay.io/rh-ee-ovishlit/cluster-flavors:$(FLAVOR)
CLUSTER_NAME            ?= osac-dev
# Root disk size the hub is grown to after boot. This is not cosmetic: the
# cluster-tool flavors are post-install images whose partition table is fixed at
# build time, cluster-tool clones without a size, and 15% of 93 GiB (kubelet's
# imagefs.available eviction threshold) is less than the OSAC images need. Raise
# it when a flavor ships bigger; the resize is skipped when the disk is bigger.
DISK_SIZE               ?= 150G
CLUSTER_TOOL_FORCE      ?=
# Derived from the hub kubeconfig when empty.
CLUSTER_DOMAIN          ?=
# Shortcut for re-running the setup steps: make osac-dev FORCE=1
FORCE                   ?=
# Teardown: YES=1 skips its confirmations, DRY_RUN=1 prints instead of running.
YES                     ?=
DRY_RUN                 ?=
# Teardown extras: also revert cluster-tool's client setup (CLIENT), also
# delete the snapshot flavor (TEARDOWN_FLAVOR; pulling it again takes 10-15m).
TEARDOWN_CLIENT         ?=
TEARDOWN_FLAVOR         ?=
OSAC_INSTALLER          ?= osac-installer
HELM                    ?= helm
# Virtual BMH emulation; tools/shared/virtual-bmh.sh holds the shared logic.
BMH_NAMESPACE           ?= host-inventory
BMH_COUNT               ?= 2
BMH_DISK_SIZE           ?= 150G
SUSHY_PORT              ?= 8000
BMC_USERNAME            ?= admin
BMC_PASSWORD            ?= password
BMH_LABELS              ?= osac.openshift.io/host-type=default
PLATFORM                ?= openshift
PROFILE                 ?= full-ci
NS                      ?= osac
# OSAC instance deployment (skaffold.yaml); images are pushed to IMAGE_PREFIX
# instead of an in-cluster registry.
SKAFFOLD                ?= skaffold
IMAGE_PREFIX            ?= quay.io/rh_ee_rpiccoli
AAP_LICENSE_FILE        ?=
# Image tags recorded by osac-dev-prep and replayed by osac-dev-deploy.
ARTIFACTS_FILE          ?= $(HOME)/.cache/osac-dev/builds.json
# E2E runner (tools/dev-env/e2e.sh): the suite is required, the selectors and
# the extra arguments are optional, and OSAC_CLI_PATH overrides the CLI that the
# runner builds from this worktree into the ARTIFACTS_FILE directory.
E2E_SUITE               ?=
E2E_FILTER              ?=
E2E_MARKER              ?=
E2E_ARGS                ?=
E2E_REPO                ?=
OSAC_CLI_PATH           ?=
SKAFFOLD_ARGS           ?=

export CLUSTER_TOOL SERVER_NAME REMOTE_HOST PULL_SECRET_FILE \
	OSAC_DEV_HUB_KUBECONFIG CLUSTER_TOOL_DATA FLAVOR FLAVOR_IMAGE CLUSTER_NAME \
	DISK_SIZE CLUSTER_TOOL_FORCE CLUSTER_DOMAIN OSAC_INSTALLER PLATFORM PROFILE \
	NS HELM BMH_NAMESPACE BMH_COUNT BMH_DISK_SIZE SUSHY_PORT BMC_USERNAME \
	BMC_PASSWORD BMH_LABELS SKAFFOLD IMAGE_PREFIX AAP_LICENSE_FILE ARTIFACTS_FILE
export OSAC_DEV_FORCE := $(FORCE)
export E2E_SUITE := $(E2E_SUITE)
export E2E_FILTER := $(E2E_FILTER)
export E2E_MARKER := $(E2E_MARKER)
export E2E_ARGS := $(E2E_ARGS)
export E2E_REPO := $(E2E_REPO)
export OSAC_CLI_PATH := $(OSAC_CLI_PATH)
# Teardown answers and extras; the scripts read the TEARDOWN_* names.
export TEARDOWN_YES := $(YES)
export TEARDOWN_DRY_RUN := $(DRY_RUN)
export TEARDOWN_CLIENT := $(TEARDOWN_CLIENT)
export TEARDOWN_FLAVOR := $(TEARDOWN_FLAVOR)

# Skaffold turns an environment variable it cannot find into the literal string
# `<no value>`, and skaffold.yaml feeds these two into the config-as-code project
# source. Exporting them, empty by default, keeps an unset value empty so the
# chart drops the key instead of handing AAP a bogus source. osac.sh repeats it
# so running that script directly behaves the same.
export OSAC_DEV_AAP_PROJECT_GIT_BRANCH := $(OSAC_DEV_AAP_PROJECT_GIT_BRANCH)
export OSAC_DEV_AAP_PROJECT_ARCHIVE_URI := $(OSAC_DEV_AAP_PROJECT_ARCHIVE_URI)

.PHONY: osac-dev osac-dev-cluster osac-dev-setup osac-dev-deps osac-dev-bmh \
	osac-dev-dns osac-dev-resize osac-dev-prep osac-dev-deploy \
	osac-dev-aap-project \
	osac-dev-watch osac-dev-delete osac-dev-e2e osac-dev-teardown \
	osac-dev-teardown-bmh \
	osac-dev-teardown-osac osac-dev-teardown-cluster osac-dev-teardown-dns \
	osac-dev-teardown-local help

help: ## Show available targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2}'

osac-dev: ## Boot the dev cluster (or reuse the hub), install prerequisites, add virtual BMHs, deploy OSAC
	@$(OSAC_DEV_ENV)/cluster.sh
	@$(OSAC_DEV_ENV)/setup.sh
	@$(OSAC_DEV_ENV)/dns.sh
	@$(OSAC_DEV_ENV)/resize.sh
	@$(OSAC_DEV_ENV)/deps.sh
	@$(OSAC_DEV_ENV)/bmh.sh
	@$(OSAC_DEV_ENV)/osac.sh prep $(SKAFFOLD_ARGS)
	@$(OSAC_DEV_ENV)/osac.sh deploy $(SKAFFOLD_ARGS)

osac-dev-cluster: ## cluster-tool server setup, flavor pull, and boot only
	@$(OSAC_DEV_ENV)/cluster.sh

osac-dev-setup: ## Client setup only (dnsmasq, NetworkManager)
	@$(OSAC_DEV_ENV)/setup.sh

osac-dev-deps: ## Install OSAC prerequisites (osac-deps + osac-infra) on the hub
	@$(OSAC_DEV_ENV)/deps.sh

osac-dev-bmh: ## Create virtual BareMetalHosts on REMOTE_HOST (needs REMOTE_HOST)
	@$(OSAC_DEV_ENV)/bmh.sh

osac-dev-dns: ## Route hub names to dnsmasq here and on REMOTE_HOST
	@$(OSAC_DEV_ENV)/dns.sh

osac-dev-resize: ## Grow the hub's root disk to DISK_SIZE (osac-dev does this after dns)
	@$(OSAC_DEV_ENV)/resize.sh --size $(DISK_SIZE) $(if $(DRY_RUN),--dry-run,)

osac-dev-prep: ## Build and push every image, upload the AAP license, rebuild chart dependencies
	@$(OSAC_DEV_ENV)/osac.sh prep $(SKAFFOLD_ARGS)

osac-dev-deploy: ## Deploy OSAC with the images prep recorded and wait for the rollout
	@$(OSAC_DEV_ENV)/osac.sh deploy $(SKAFFOLD_ARGS)

osac-dev-aap-project: ## Serve this worktree as the config-as-code project, print its URL
	@$(OSAC_DEV_ENV)/aap-project.sh

osac-dev-watch: ## Rebuild and redeploy OSAC on every change (skaffold dev)
	@$(OSAC_DEV_ENV)/osac.sh dev $(SKAFFOLD_ARGS)

osac-dev-e2e: ## Run an E2E suite against the hub (E2E_SUITE=, E2E_FILTER=, E2E_MARKER=)
	@$(OSAC_DEV_ENV)/e2e.sh $(if $(DRY_RUN),--dry-run,)

osac-dev-delete: ## Uninstall the osac Helm release (keeps osac-deps/osac-infra)
	@$(OSAC_DEV_ENV)/osac.sh delete $(SKAFFOLD_ARGS)

osac-dev-teardown: ## Destroy everything the dev flow created (YES=1, DRY_RUN=1)
	@$(OSAC_DEV_ENV)/teardown.sh all

osac-dev-teardown-bmh: ## Delete the virtual BMHs, emulator, VMs and VM network
	@$(OSAC_DEV_ENV)/teardown.sh bmh

osac-dev-teardown-osac: ## Uninstall the release and the AAP project archive server
	@$(OSAC_DEV_ENV)/teardown.sh osac

osac-dev-teardown-cluster: ## Destroy the cluster-tool clone and its kubeconfig
	@$(OSAC_DEV_ENV)/teardown.sh cluster

osac-dev-teardown-dns: ## Remove the hub zone routing here and on REMOTE_HOST
	@$(OSAC_DEV_ENV)/teardown.sh dns

osac-dev-teardown-local: ## Remove the local image-tag cache the prep step wrote
	@$(OSAC_DEV_ENV)/teardown.sh local
