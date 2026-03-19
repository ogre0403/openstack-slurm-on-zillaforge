.DEFAULT_GOAL := help

TF_IMAGE ?= Zillaforge/terraform
KA_VER_TAG ?= py311-ka2024.2

TERRAFORM ?= terraform
SLURM_DIR ?= infra_slurm
OPENSTACK_DIR ?= infra_openstack
KOLLA_DOCKERFILE ?= kolla-ansible/Dockerfile
KOLLA_COMPOSE_FILE ?= kolla-ansible/docker-compose.yaml

.PHONY: help terraform-container slurm-up-via-terraform slurm-destroy-via-terraform \
	openstack-up-via-terraform openstack-down-via-terraform kolla-image kolla-up \
	kolla-exec kolla-down kolla-push-local-registry

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-32s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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
	docker run -ti --rm -v $$(pwd):/workspace --workdir /workspace $(TF_IMAGE):$$selected_tag sh -c 'apk add make openssh rsync sshpass && bash'

slurm-up-via-terraform: ## Initialize, plan, and apply the Slurm stack
	$(TERRAFORM) -chdir=$(SLURM_DIR) init
	$(TERRAFORM) -chdir=$(SLURM_DIR) plan
	$(TERRAFORM) -chdir=$(SLURM_DIR) apply

slurm-destroy-via-terraform: ## Initialize and destroy the Slurm stack
	$(TERRAFORM) -chdir=$(SLURM_DIR) init
	$(TERRAFORM) -chdir=$(SLURM_DIR) destroy

openstack-up-via-terraform: ## Initialize, plan, and apply the OpenStack stack
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) init
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) plan
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) apply

openstack-down-via-terraform: ## Initialize and destroy the OpenStack stack
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) init
	$(TERRAFORM) -chdir=$(OPENSTACK_DIR) destroy

kolla-image: ## Build the Kolla-Ansible image
	docker build -t kolla-ansible:$(KA_VER_TAG) -f $(KOLLA_DOCKERFILE) .

kolla-up: ## Start the Kolla-Ansible containers
	docker compose -f $(KOLLA_COMPOSE_FILE) up -d

kolla-push-local-registry: ## Tag and push the Kolla-Ansible image to the local registry
	@set -e; \
	host_ip=$$(ip route get 1.1.1.1 | awk '/src/ {print $$7; exit}'); \
	if [ -z "$$host_ip" ]; then \
		echo "Unable to determine host IP from default route"; \
		exit 1; \
	fi; \
	docker tag kolla-ansible:$(KA_VER_TAG) $$host_ip:5000/kolla-ansible:$(KA_VER_TAG); \
	docker push $$host_ip:5000/kolla-ansible:$(KA_VER_TAG)

kolla-exec: ## Open a shell inside the Kolla-Ansible container
	docker exec -u kolla -w /home/kolla -e HOME=/home/kolla -it kolla_ansible bash

kolla-down: ## Stop the Kolla-Ansible containers
	docker compose -f $(KOLLA_COMPOSE_FILE) down
