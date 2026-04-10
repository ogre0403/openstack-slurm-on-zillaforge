.DEFAULT_GOAL := help

TF_IMAGE ?= Zillaforge/terraform
KA_VER_TAG ?= py311-ka2024.2

TERRAFORM ?= terraform
SLURM_DIR ?= infra_slurm
OPENSTACK_DIR ?= infra_openstack
KOLLA_DOCKERFILE ?= kolla-ansible/Dockerfile
KOLLA_SINGULARITYFILE ?= kolla-ansible/Singularity.def
KOLLA_COMPOSE_FILE ?= kolla-ansible/docker-compose.yaml
SIF_FILE ?= kolla-ansible.sif

MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

PARTITION ?=
OCCUPY_NUM ?=

JOB_ID ?=

DEST ?=

.PHONY: help terraform-container ssh-to sync-to \
		slurm-up slurm-down \
		openstack-up openstack-down \
		kolla-image kolla-up kolla-shell kolla-down \
		singularity-image singularity-shell \
		singularity-srun-expand   singularity-srun-shrink \
		singularity-sbatch-expand singularity-sbatch-shrink

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-32s %s\n", $$1, $$2; if ($$1 == "sync-from" || $$1 == "kolla-shell" || $$1 == "help" || $$1 == "sync-to") printf "\n"}' $(MAKEFILE_LIST)

terraform-container: ## Open a container with Terraform dependencies
	@set -e; \
	selected_tag=$$(docker images $(TF_IMAGE) --format '{{.Tag}}' | head -n1); \
	if [ -z "$$selected_tag" ]; then \
		echo "No local $(TF_IMAGE) image found; cloning and building $(TF_IMAGE)"; \
		git clone https://github.com/Zillaforge/terraform-provider-zillaforge.git /tmp/terraform-provider-zillaforge; \
		make -C /tmp/terraform-provider-zillaforge image; \
		rm -rf /tmp/terraform-provider-zillaforge; \
		selected_tag=$$(docker images $(TF_IMAGE) --format '{{.Tag}}' | head -n1); \
	fi; \
	if [ -z "$$selected_tag" ]; then \
		echo "Unable to find a usable tag for $(TF_IMAGE)"; \
		exit 1; \
	fi; \
	echo "Using $(TF_IMAGE):$$selected_tag"; \
	docker run -ti --rm -v $$(pwd):/workspace -v $$HOME/.ssh/id_rsa:/root/.ssh/id_rsa:ro \
	-e TFENV_AUTO_INSTALL=false \
	--workdir /workspace $(TF_IMAGE):$$selected_tag sh -c 'apk add make openssh rsync sshpass && bash'

slurm-up: ## Initialize, plan, and apply the Slurm stack
	$(TERRAFORM) -chdir=$(SLURM_DIR) init
	$(TERRAFORM) -chdir=$(SLURM_DIR) plan
	$(TERRAFORM) -chdir=$(SLURM_DIR) apply

slurm-down: ## Initialize and destroy the Slurm stack
	$(TERRAFORM) -chdir=$(SLURM_DIR) init
	$(TERRAFORM) -chdir=$(SLURM_DIR) destroy

openstack-up: ## Initialize, plan, and apply the OpenStack stack
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) init
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) plan
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) apply

openstack-down: ## Initialize and destroy the OpenStack stack
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) init
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) destroy

ssh-to: ## SSH into slurm (headnode) or openstack (bastion) using Terraform floating IP (DEST=slurm|openstack)
	@if [ "$(DEST)" != "slurm" ] && [ "$(DEST)" != "openstack" ]; then \
		echo "ERROR: DEST must be 'slurm' or 'openstack' (e.g. make DEST=slurm ssh-to)"; \
		exit 1; \
	fi
	@if [ "$(DEST)" = "slurm" ]; then \
		ip=$$($(TERRAFORM) -chdir=$(SLURM_DIR) output -raw headnode_floating_ip); \
	else \
		ip=$$($(TERRAFORM) -chdir=$(OPENSTACK_DIR) output -raw bastion_floating_ip); \
	fi; \
	echo "Connecting to $$ip ..."; \
	ssh -o StrictHostKeyChecking=no cloud-user@$$ip

sync-to: ## Sync local project (excluding .git) to remote resource_manage/ (DEST=slurm|openstack)
	@if [ "$(DEST)" != "slurm" ] && [ "$(DEST)" != "openstack" ]; then \
		echo "ERROR: DEST must be 'slurm' or 'openstack' (e.g. make DEST=slurm sync-to)"; \
		exit 1; \
	fi
	@if [ "$(DEST)" = "slurm" ]; then \
		ip=$$($(TERRAFORM) -chdir=$(SLURM_DIR) output -raw headnode_floating_ip); \
	else \
		ip=$$($(TERRAFORM) -chdir=$(OPENSTACK_DIR) output -raw bastion_floating_ip); \
	fi; \
	echo "Syncing to cloud-user@$$ip:resource_manage/ ..."; \
	rsync -az --exclude '.git' -e "ssh -o StrictHostKeyChecking=no" $(MAKEFILE_DIR) cloud-user@$$ip:resource_manage/

kolla-image: ## Build the Kolla-Ansible image
	docker build -t kolla-ansible:$(KA_VER_TAG) -f $(KOLLA_DOCKERFILE) .

kolla-up: ## Start the Kolla-Ansible containers
	docker compose -f $(KOLLA_COMPOSE_FILE) up -d

kolla-down: ## Stop the Kolla-Ansible containers
	docker compose -f $(KOLLA_COMPOSE_FILE) down

kolla-shell: ## Open a shell inside the Kolla-Ansible container
	docker exec -u kolla -w /home/kolla -e HOME=/home/kolla -it kolla_ansible bash

singularity-image: ## Build the Singularity Kolla-Ansible image
	singularity build $(SIF_FILE) $(KOLLA_SINGULARITYFILE)

singularity-shell: ## Open Singularity Shell
	singularity shell \
	--env OS_CLOUD=kolla-admin-internal \
	--env OS_CLIENT_CONFIG_FILE=/etc/kolla/clouds.yaml \
	-B kolla-ansible/etc/kolla/:/etc/kolla \
	-B kolla-ansible/etc/openstack/:/etc/openstack \
	-B playbook:/playbook \
	$(SIF_FILE)

singularity-srun-expand: ## srun expand compute nodes
	@if [ -z "$(strip $(PARTITION))" ]; then \
		echo "ERROR: PARTITION must be set (for example: make PARTITION=<PARTITION_NAME> singularity-srun-expand)"; \
		exit 1; \
	fi
	@if [ -z "$(strip $(OCCUPY_NUM))" ]; then \
		echo "ERROR: OCCUPY_NUM must be set (for example: make OCCUPY_NUM=<NUM_NODES> singularity-srun-expand)"; \
		exit 1; \
	fi
	srun -J expand -p $(PARTITION) -N $(OCCUPY_NUM) bash $(MAKEFILE_DIR)job_scripts/submit.sh add

singularity-srun-shrink: ## srun shrink compute nodes
	@if [ -z "$(strip $(PARTITION))" ]; then \
		echo "ERROR: PARTITION must be set (for example: make PARTITION=<PARTITION_NAME> singularity-sbatch-shrink)"; \
		exit 1; \
	fi
	@if [ -z "$(strip $(JOB_ID))" ]; then \
		echo "ERROR: JOB_ID must be set (for example: make JOB_ID=<JOB_ID> singularity-sbatch-shrink)"; \
		exit 1; \
	fi	
	srun -J shrink -p $(PARTITION) -N 1 bash $(MAKEFILE_DIR)job_scripts/submit.sh del $(JOB_ID)

singularity-sbatch-expand: ## Run batch Job to expand compute nodes
	@if [ -z "$(strip $(PARTITION))" ]; then \
		echo "ERROR: PARTITION must be set (for example: make PARTITION=<PARTITION_NAME> singularity-sbatch)"; \
		exit 1; \
	fi
	@if [ -z "$(strip $(OCCUPY_NUM))" ]; then \
		echo "ERROR: OCCUPY_NUM must be set (for example: make OCCUPY_NUM=<NUM_NODES> singularity-sbatch)"; \
		exit 1; \
	fi
	sbatch -J expand -p $(PARTITION) -N $(OCCUPY_NUM) \
		--export=ALL,PROJECT_DIR=$(MAKEFILE_DIR),PAYLOAD_DIR=$(MAKEFILE_DIR)job_scripts \
		$(MAKEFILE_DIR)job_scripts/submit.sh add

singularity-sbatch-shrink: ## Run batch Job to shrink compute nodes from previous expand job
	@if [ -z "$(strip $(PARTITION))" ]; then \
		echo "ERROR: PARTITION must be set (for example: make PARTITION=<PARTITION_NAME> singularity-sbatch-shrink)"; \
		exit 1; \
	fi
	@if [ -z "$(strip $(JOB_ID))" ]; then \
		echo "ERROR: JOB_ID must be set (for example: make JOB_ID=<JOB_ID> singularity-sbatch-shrink)"; \
		exit 1; \
	fi	
	sbatch -J shrink -p $(PARTITION) -N 1 \
		--export=ALL,PROJECT_DIR=$(MAKEFILE_DIR),PAYLOAD_DIR=$(MAKEFILE_DIR)job_scripts \
		$(MAKEFILE_DIR)job_scripts/submit.sh del $(JOB_ID)
