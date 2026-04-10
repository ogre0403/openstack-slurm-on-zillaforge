# Run Kolla Ansible in Slurm Job


## Prepare Terraform Container Environment

```shell
git clone https://github.com/ogre0403/openstack-slurm-on-zillaforge.git
cd openstack-slurm-on-zillaforge

# create tfvars example files
cp infra_openstack/terraform.tfvars.example infra_openstack/terraform.tfvars
cp infra_slurm/terraform.tfvars.example infra_slurm/terraform.tfvars

# edit terraform variables depends on your environment
vim infra_openstack/terraform.tfvars
vim infra_slurm/terraform.tfvars

# launch terraform container
make terraform-container
```

## Setup OpenStack

```shell
## execute in terraform container
make openstack-up

...

Outputs:

bastion_floating_ip = "y.y.y.y"
default_network_ips = {
  "OPSK-00-bastion-tf" = "192.168.95.208"
  "OPSK-01-control-tf" = "192.168.95.71"
  "OPSK-02-compute-tf" = "192.168.95.61"
  "OPSK-03-compute-tf" = "192.168.95.174"
}

# ssh to openstack bastion
make DEST=openstack ssh-to

## execute in opnestack bastion
cd ~/resource_manage
# build and launch kolla-ansible via docker compose
make kolla-up

# access kolla-ansible container as kolla user
make kolla-shell

# generate password
kolla-genpwd

# kolla-ansible deploy step
kolla-ansible bootstrap-servers -i /etc/kolla/inventroy/
kolla-ansible prechecks         -i /etc/kolla/inventroy/
kolla-ansible pull              -i /etc/kolla/inventroy/
kolla-ansible deploy            -i /etc/kolla/inventroy/
kolla-ansible post-deploy       -i /etc/kolla/inventroy/
```


## Setup Slurm

```shell
make slurm-up
...

Outputs:

default_network_ips = {
  "SLURM-01-headnode-tf" = "192.168.95.55"
  "SLURM-02-worker-tf" = "192.168.95.214"
  "SLURM-03-worker-tf" = "192.168.95.180"
  "SLURM-04-worker-tf" = "192.168.95.35"
}
headnode_floating_ip = "x.x.x.x"

## ssh to slurm headnode
make DEST=slurm ssh-to

cd ~/resource_manage
sudo make singularity-image

```


## Add new OpenStack Compute

**NOTE:**

Whole `inventroy` information and `passwords.yml` MUST be shared.

```shell
# Copy passwords.yml & globals.yml from "EXISTING" OpenStack Cluster

export BASTION_IP=192.168.x.x
scp cloud-user@${BASTION_IP}:~/resource_manage/kolla-ansible/etc/kolla/passwords.yml    ~/resource_manage/kolla-ansible/etc/kolla/
scp cloud-user@${BASTION_IP}:~/resource_manage/kolla-ansible/etc/kolla/globals.yml      ~/resource_manage/kolla-ansible/etc/kolla/
```

### Inside a singularity shell run commands

```shell
# Start a shell for singularity SIF
make singularity-shell

# Execute commands in the singularity shell
kolla-ansible bootstrap-servers -i /etc/kolla/inventroy/    --limit <NODE_NAME>
kolla-ansible prechecks         -i /etc/kolla/inventroy/    --limit <NODE_NAME>
kolla-ansible pull              -i /etc/kolla/inventroy/    --limit <NODE_NAME>
kolla-ansible deploy            -i /etc/kolla/inventroy/    --limit <NODE_NAME>
```

### Submit a Batch Job for adding nodes

```shell
# Submit a slurm job, use singularity container to run Kolla-Ansible Commands
make PARTITION=<partition> OCCUPY_NUM=<num> singularity-sbatch-expand

```

## Remove Existing OpenStack Compute

**Note:** 

OpenStack credentials are **MUST** required. That is because some OpenStack administration operation will be executed when removing node. 


```shell
export BASTION_IP=192.168.x.x
scp cloud-user@${BASTION_IP}:~/resource_manage/kolla-ansible/etc/kolla/admin-openrc.sh  ~/resource_manage/kolla-ansible/etc/kolla/
scp cloud-user@${BASTION_IP}:~/resource_manage/kolla-ansible/etc/kolla/clouds.yaml      ~/resource_manage/kolla-ansible/etc/kolla/
```


### Submit a real time job for deleting nodes

```shell
make PARTITION=<PARTITION> JOB_ID=<JOB_ID> singularity-srun-shrink
```


### Submit a Batch Job for deleting nodes

```shell
make PARTITION=<PARTITION> JOB_ID=<JOB_ID> singularity-sbatch-shrink
```


## RoadMap

* [x] Setup infrastructure from Terraform
  * [x] OpenStack
  * [x] Slurm

* [x] Run Kolla-Ansible in Conatiner
  * [x] Docker Container
  * [x] Singularity Container

* [x] Run Kolla-Ansible in Slurm Job
  * [x] Add new node
  * [x] Delete existing node

* [x] FIX:
  * [x] Squeue cannot find allocated nodelist for completed add job
  * [x] Export Horizon public endpoint