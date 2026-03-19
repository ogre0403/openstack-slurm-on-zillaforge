# 資源動態調度


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

## Setup Slurm

```shell
make slurm-up-via-terraform

## ssh to slurm headnode
ssh cloud-user@x.x.x.x
```


## Setup OpenStack

```shell
## execute in terraform container
make openstack-up-via-terraform

# ssh to openstack bastion
ssh cloud-user@y.y.y.y

## execute in opnestack bastion
cd ~/resource_manage
# build and launch kolla-ansible via docker compose
make kolla-up

# access kolla-ansible container as kolla user
make kolla-exec

# generate password
kolla-genpwd

# kolla-ansible deploy step
kolla-ansible bootstrap-servers -i /etc/kolla/inventroy/
kolla-ansible prechecks         -i /etc/kolla/inventroy/
kolla-ansible pull              -i /etc/kolla/inventroy/
kolla-ansible deploy            -i /etc/kolla/inventroy/
kolla-ansible post-deploy       -i /etc/kolla/inventroy/
```


## Add OpenStack Compute

```shell
kolla-ansible bootstrap-servers -i /etc/kolla/inventroy/    --limit SLURM-03-compute-tf 
kolla-ansible prechecks         -i /etc/kolla/inventroy/    --limit SLURM-03-compute-tf 
kolla-ansible pull              -i /etc/kolla/inventroy/    --limit SLURM-03-compute-tf 
kolla-ansible deploy            -i /etc/kolla/inventroy/    --limit SLURM-03-compute-tf 
```

在 controller 上，強制openstack 發現新節點，不然要等五分鐘
```shell
docker exec -t nova_api nova-manage cell_v2 discover_hosts --verbose
```

## RoadMap

* [x] Setup infrastructure from Terraform
    * [x] OpenStack
    * [x] Slurm

* [x] Run Kolla-Ansible in Conatiner
    * [x] Docker Container
    * [x] Singularity Container