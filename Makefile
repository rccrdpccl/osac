IMAGE_NAME ?= osac-dev
DISTROBOX_NAME ?= osac
HOME_DIR ?= $(HOME)
CONTAINER_CMD ?= $(shell command -v podman 2>/dev/null || echo docker)
DISTROBOX_CONTEXT := tools/distrobox
ARGS ?=

.PHONY: image enter claude stop rm rebuild status help osac-dev osac-dev-down osac-dev-status osac-dev-kubeconfig osac-dev-install-infra osac-dev-deploy osac-dev-dev osac-dev-test osac-dev-bmh osac-dev-bmh-clean osac-dev-e2e osac-dev-grow-storage osac-dev-help osac-dev-setup

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

image: ## Build the distrobox image
	$(CONTAINER_CMD) build -t $(IMAGE_NAME) -f $(DISTROBOX_CONTEXT)/Containerfile $(DISTROBOX_CONTEXT)

enter: image ## Enter the distrobox (creates it on first run)
	@if ! distrobox list --no-color 2>/dev/null | awk -F'|' 'NR>1{gsub(/^ +| +$$/,"",$$2); print $$2}' | grep -Fxq "$(DISTROBOX_NAME)"; then \
		distrobox create --image $(IMAGE_NAME) --name $(DISTROBOX_NAME) --home "$(HOME_DIR)"; \
	fi
	distrobox enter $(DISTROBOX_NAME)

claude: image ## Run Claude Code inside distrobox (ARGS="--flag" to pass flags)
	@if ! distrobox list --no-color 2>/dev/null | awk -F'|' 'NR>1{gsub(/^ +| +$$/,"",$$2); print $$2}' | grep -Fxq "$(DISTROBOX_NAME)"; then \
		distrobox create --image $(IMAGE_NAME) --name $(DISTROBOX_NAME) --home "$(HOME_DIR)"; \
	fi
	distrobox enter $(DISTROBOX_NAME) -- claude $(ARGS)

stop: ## Stop the running distrobox container
	@distrobox stop -Y $(DISTROBOX_NAME) 2>/dev/null || true

rm: ## Remove the distrobox and its container
	@distrobox rm --force $(DISTROBOX_NAME) 2>/dev/null || true

rebuild: rm image enter ## Rebuild image from scratch and enter

status: ## Show distrobox and image status
	@echo "=== Images ==="
	@$(CONTAINER_CMD) images --filter reference=$(IMAGE_NAME) --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.Created}}"
	@echo ""
	@echo "=== Distrobox ==="
	@distrobox list --no-color 2>/dev/null | head -1; distrobox list --no-color 2>/dev/null | awk -F'|' 'NR>1{gsub(/^ +| +$$/,"",$$2); if($$2=="$(DISTROBOX_NAME)") { print; found=1 }} END { if (!found) print "  (not created)" }'

osac-dev: ## Preflight, then cluster -> 200GiB storage -> infra -> BMH -> deploy -> DNS (REMOTE_HOST unset/localhost = run here)
	@tools/osac-dev/osac-dev-workflow.sh

.PHONY: osac-dev-cluster osac-dev-check osac-dev-dns
osac-dev-check: ## Prompt/check full-workflow inputs without deploying (read-only host checks)
	@tools/osac-dev/osac-dev-workflow.sh --check

osac-dev-setup: ## Install missing prerequisites (Skaffold, docker shim, podman socket, host packages, cluster-tool); DRY_RUN=1 prints the plan
	@tools/osac-dev/osac-dev-setup.sh $(if $(filter 1 yes true,$(DRY_RUN)),--dry-run,)

osac-dev-cluster: ## Boot/reuse one SNO, save kubeconfig, ensure 200GiB disks (remote or localhost)
	@tools/osac-dev/osac-dev-bootstrap.sh up
	@OSAC_DEV_KUBECONFIG_ONLY=1 tools/osac-dev/osac-dev-install-infra.sh
	@tools/osac-dev/osac-dev-grow-storage.sh

osac-dev-grow-storage: ## Grow both SNO disks (default/minimum 200GiB; REMOTE_HOST selects host)
	@tools/osac-dev/osac-dev-grow-storage.sh

osac-dev-dns: ## Configure persistent lab DNS/NTP from the current topology (REMOTE_HOST selects host)
	@tools/osac-dev/osac-dev-dns.sh

osac-dev-help: ## Print the osac-dev workflow cheat sheet (targets, sequence, env vars)
	@tools/osac-dev/osac-dev-help.sh

osac-dev-down: ## Destroy only the selected SNO cluster (REMOTE_HOST selects host, DEV_ENV_NAME=osac)
	@tools/osac-dev/osac-dev-bootstrap.sh down

osac-dev-status: ## Show the selected SNO cluster (REMOTE_HOST selects host, DEV_ENV_NAME=osac)
	@tools/osac-dev/osac-dev-bootstrap.sh status

osac-dev-kubeconfig: ## Repair missing lab DNS/DHCP and refresh kubeconfig (no workload deploy)
	@OSAC_DEV_KUBECONFIG_ONLY=1 tools/osac-dev/osac-dev-install-infra.sh

osac-dev-install-infra: ## Install/update osac-deps, osac-infra, and CNV on the selected cluster
	@tools/osac-dev/osac-dev-install-infra.sh

.PHONY: osac-dev-snapshot
osac-dev-snapshot: ## Snapshot and restore-test a booted/reused infra-only SNO (SNAPSHOT_NAME= required; defaults osac-dev, 200GiB disks)
	@tools/osac-dev/osac-dev-snapshot.sh

osac-dev-deploy: ## Build branch images, push to quay, install/upgrade the osac release (REMOTE_HOST selects host)
	@tools/osac-dev/osac-dev-deploy.sh

osac-dev-dev: ## Watch mode: rebuild and redeploy branch images on file change
	@tools/osac-dev/osac-dev-deploy.sh --dev

osac-dev-bmh: ## Create virtual BareMetalHosts on the selected cluster via CNV VMs + KubeVirtBMC (initializes Ironic if needed)
	@tools/osac-dev/osac-dev-bmh.sh

osac-dev-bmh-clean: ## Remove the virtual BareMetalHosts, VMs, and BMC resources
	@tools/osac-dev/osac-dev-bmh.sh --clean

osac-dev-e2e: ## Run selected e2e suites; REMOTE_HOST adds a SOCKS hop for CaaS (TESTS="tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py")
	@test -n "$(TESTS)" || { echo "error: TESTS is required, e.g. make osac-dev-e2e TESTS=tests/e2e/bmaas/sanity/test_baremetal_instance_lifecycle.py" >&2; exit 1; }
	@tools/osac-dev/osac-dev-e2e.sh $(TESTS)

osac-dev-test: ## Run offline unit and shell contract tests for the osac-dev workflow (remote and localhost targets)
	@uv run --frozen --offline python osac-installer/scripts/test-skaffold-deploy.py
	@uv run --frozen --offline python tools/osac-dev/tests/test_osac_dev_ee.py
	@python3 tools/osac-dev/tests/test_osac_dev_nic.py
	@python3 tools/osac-dev/tests/test_osac_dev_bridge.py
	@python3 tools/osac-dev/tests/test_osac_dev_api_wait.py
	@python3 tools/osac-dev/tests/test_osac_dev_dns.py
	@bash tools/osac-dev/tests/test-osac-dev-target.sh
	@bash tools/osac-dev/tests/test-osac-dev-setup.sh
	@bash tools/osac-dev/tests/test-osac-dev-dns.sh
	@bash tools/osac-dev/tests/test-osac-dev-workflow.sh
	@bash tools/osac-dev/tests/test-osac-dev-provisioning.sh
	@bash tools/osac-dev/tests/test-osac-dev-bootstrap.sh
	@bash tools/osac-dev/tests/test-osac-dev-clusters.sh
	@bash tools/osac-dev/tests/test-osac-dev-install-infra.sh
	@bash tools/osac-dev/tests/test-osac-dev-snapshot.sh
	@bash tools/osac-dev/tests/test-osac-dev-deploy.sh
	@bash tools/osac-dev/tests/test-osac-dev-bmh.sh
	@bash tools/osac-dev/tests/test-osac-dev-e2e.sh
	@bash tools/osac-dev/tests/test-osac-dev-grow-storage.sh
