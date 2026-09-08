# Run `make help` for the repository's user-facing commands.
.DEFAULT_GOAL := help

TERRAFORM ?= terraform
KUBECTL ?= kubectl
TERRAFORM_DIR ?= terraform
APPS_DIR ?= kubernetes/apps

# Canonical failure manifests for the existing labs.
# Override a path with: make lab03-trigger LAB03_MANIFEST=path/to/manifest.yaml
LAB02_MANIFEST ?= kubernetes/chaos/node-drain-failure.yaml
LAB03_MANIFEST ?= kubernetes/chaos/memory-leak.yaml
LAB04_MANIFEST ?= kubernetes/chaos/irsa-security-breach.yaml

.PHONY: help init up down deploy-apps lab01-trigger lab02-trigger lab03-trigger lab04-trigger

help:
	@printf '%s\n' \
	  'Usage: make <target>' \
	  '' \
	  '  init           Initialize Terraform providers and backend' \
	  '  up             Apply Terraform infrastructure (interactive approval)' \
	  '  down           Terraform destroy only; first follow docs/teardown.md' \
	  '  deploy-apps    Apply application manifests recursively from kubernetes/apps' \
	  '  lab01-trigger  Show the staged Lab 01 upgrade runbook' \
	  '  lab02-trigger  Apply the node drain failure manifest' \
	  '  lab03-trigger  Apply the memory leak manifest' \
	  '  lab04-trigger  Apply the IRSA security breach manifest' \
	  '' \
	  'Kubernetes commands use your current kubectl context.' \
	  'Review the matching runbook before deploying applications or lab manifests.' \
	  'Override paths with TERRAFORM_DIR, APPS_DIR, or LAB02_MANIFEST through LAB04_MANIFEST.'

init:
	$(TERRAFORM) -chdir="$(TERRAFORM_DIR)" init

up:
	$(TERRAFORM) -chdir="$(TERRAFORM_DIR)" apply

down:
	@printf '%s\n' 'Prerequisite: complete docs/teardown.md through Kubernetes/LB cleanup and Helm preparation; this target only destroys Terraform-managed resources.'
	TERRAFORM="$(TERRAFORM)" TERRAFORM_DIR="$(TERRAFORM_DIR)" bash scripts/check-load-balancer-cleanup.sh
	$(TERRAFORM) -chdir="$(TERRAFORM_DIR)" destroy

deploy-apps:
	@test -d "$(APPS_DIR)" || { printf 'Application directory not found: %s\n' "$(APPS_DIR)" >&2; exit 1; }
	@test -n "$$(find "$(APPS_DIR)" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print -quit)" || { printf 'No application manifests found in: %s\n' "$(APPS_DIR)" >&2; exit 1; }
	$(KUBECTL) apply -R -f "$(APPS_DIR)"

lab01-trigger:
	@printf '%s\n' 'Follow labs/01-cluster-upgrade.md: preflight, control plane, health gate, one node group at a time, final validation. No upgrade is executed by this target.'
lab02-trigger: LAB_MANIFEST = $(LAB02_MANIFEST)
lab03-trigger: LAB_MANIFEST = $(LAB03_MANIFEST)
lab04-trigger: LAB_MANIFEST = $(LAB04_MANIFEST)

lab02-trigger lab03-trigger lab04-trigger:
	@test -f "$(LAB_MANIFEST)" || { printf 'Failure manifest not found: %s. Add it or override this lab\047s LABxx_MANIFEST variable.\n' "$(LAB_MANIFEST)" >&2; exit 1; }
	$(KUBECTL) apply -f "$(LAB_MANIFEST)"
