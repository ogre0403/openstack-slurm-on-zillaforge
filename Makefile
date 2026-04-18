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
KOLLA_PULL_INVENTORY ?= kolla-ansible/etc/kolla/inventroy/pull-all
KOLLA_PUSH_SCRIPT ?= scripts/kolla-push.sh
LOCAL_IP ?= $(shell hostname -I | cut -d ' ' -f 1)
REGISTRY_ADDR ?= $(LOCAL_IP):5000
# Pass -it only when running interactively (i.e. stdout is a TTY)
DOCKER_TTY := $(shell [ -t 1 ] && echo "-it")

MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

PARTITION ?=
OCCUPY_NUM ?=

JOB_ID ?=

DEST ?=

.PHONY: help terraform-container ssh-to sync-to \
		slurm-up slurm-down \
		openstack-up openstack-down openstack-deploy \
		kolla-image kolla-up kolla-shell kolla-down \
		kolla-pull kolla-push \
		singularity-image singularity-shell \
		singularity-srun-expand   singularity-srun-shrink \
		singularity-sbatch-expand singularity-sbatch-shrink

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-32s %s\n", $$1, $$2; if ($$1 == "sync-from" || $$1 == "kolla-shell" || $$1 == "help" || $$1 == "sync-to" || $$1 == "openstack-deploy") printf "\n"}' $(MAKEFILE_LIST)

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


openstack-deploy: ## Run full kolla-ansible deployment in the background
	@ip=$$($(TERRAFORM) -chdir=$(OPENSTACK_DIR) output -raw bastion_floating_ip); \
	private_registry=$$($(TERRAFORM) -chdir=$(OPENSTACK_DIR) output -raw enable_private_registry 2>/dev/null || echo "false"); \
	if ssh -o StrictHostKeyChecking=no cloud-user@$$ip '[ -f ~/resource_manage/.kolla_deploy.done ]'; then \
		echo "OpenStack deployment already completed on $$ip (.kolla_deploy.done exists)."; \
		echo "If you need to re-run, remove the flag file on the bastion and run this target again."; \
		exit 0; \
	fi; \
	if ssh -o StrictHostKeyChecking=no cloud-user@$$ip '[ -f ~/resource_manage/.kolla_deploy.inprogress ]'; then \
		echo "Deployment is currently in progress on $$ip."; \
		echo "Monitor progress with:"; \
		echo "  ssh cloud-user@$$ip 'tail -f ~/resource_manage/kolla-deploy.log'"; \
		exit 0; \
	fi; \
	echo "Launching background kolla-ansible deployment on $$ip (enable_private_registry=$$private_registry) ..."; \
	ssh -o StrictHostKeyChecking=no cloud-user@$$ip \
		"ENABLE_PRIVATE_REGISTRY=$$private_registry nohup bash ~/resource_manage/scripts/kolla_deploy.sh > /dev/null 2>&1 &"; \
	echo ""; \
	echo "Deployment is running in the background on $$ip."; \
	echo "Monitor progress with:"; \
	echo "  ssh cloud-user@$$ip 'tail -f ~/resource_manage/kolla-deploy.log'"

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
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null cloud-user@$$ip

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
	rsync -avzu --exclude '.git' -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" $(MAKEFILE_DIR) cloud-user@$$ip:resource_manage/


kolla-up: ## Start the Kolla-Ansible containers
	docker compose -f $(KOLLA_COMPOSE_FILE) up -d

kolla-down: ## Stop the Kolla-Ansible containers
	docker compose -f $(KOLLA_COMPOSE_FILE) down

kolla-pull: ## Pull all kolla images to bastion via kolla-ansible pull
	docker exec -u kolla -w /home/kolla -e HOME=/home/kolla $(DOCKER_TTY) kolla_ansible \
		bash -c 'kolla-ansible pull -i /etc/kolla/all-in-one && bash /scripts/kolla-pull-additional.sh'

kolla-push: ## Re-tag and push all kolla images to the private registry
	docker exec -u kolla -w /home/kolla -e HOME=/home/kolla $(DOCKER_TTY) kolla_ansible \
		bash -c 'bash /scripts/kolla-push.sh $(REGISTRY_ADDR) && sed -i "/^#docker_/s/^#//" /etc/kolla/globals.yml'

kolla-image: ## Build the Kolla-Ansible image
	docker build -t kolla-ansible:$(KA_VER_TAG) -f $(KOLLA_DOCKERFILE) .

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
