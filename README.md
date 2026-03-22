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

## Setup OpenStack

```shell
## execute in terraform container
make openstack-up-via-terraform

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
ssh cloud-user@y.y.y.y

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
make slurm-up-via-terraform
...

Outputs:

default_network_ips = {
  "SLURM-01-headnode-tf" = "192.168.95.55"
  "SLURM-02-compute-tf" = "192.168.95.214"
  "SLURM-03-compute-tf" = "192.168.95.180"
  "SLURM-04-compute-tf" = "192.168.95.35"
}
headnode_floating_ip = "x.x.x.x"

## ssh to slurm headnode
ssh cloud-user@x.x.x.x

cd ~/c
sudo make singilarity-image

make singilarity-shell
```


## Add OpenStack Compute

**NOTE:**

While `inventroy` information and `passwords.yml` MUST be shared.

```shell
# Remove unused inventory files
rm ~/resource_manage/kolla-ansible/etc/kolla/inventroy/01-controller
rm ~/resource_manage/kolla-ansible/etc/kolla/inventroy/05-compute

# Copy passwords.yml & globals.yml from "EXISTING" OpenStack Cluster

scp cloud-user@y.y.y.y:~/resource_manage/kolla-ansible/etc/kolla/passwords.yml ~/resource_manage/kolla-ansible/etc/kolla/
scp cloud-user@y.y.y.y:~/resource_manage/kolla-ansible/etc/kolla/globals.yml   ~/resource_manage/kolla-ansible/etc/kolla/
```

### Run in singilarity-shell 

```shell
kolla-ansible bootstrap-servers -i /etc/kolla/inventroy/    --limit <NODE_NAME>
kolla-ansible prechecks         -i /etc/kolla/inventroy/    --limit <NODE_NAME>
kolla-ansible pull              -i /etc/kolla/inventroy/    --limit <NODE_NAME>
kolla-ansible deploy            -i /etc/kolla/inventroy/    --limit <NODE_NAME>
```


在 controller 上，強制openstack 發現新節點，不然要等五分鐘
```shell
docker exec -t nova_api nova-manage cell_v2 discover_hosts --verbose
```

### Run Deployment as a SLURM Job

`KOLLA_CMD` 只接受以下值：`bootstrap-servers`、`prechecks`、`pull`、`deploy`。
`LIMIT` 必須明確提供，沒有預設值，避免誤放到整個 inventory。

```shell
make KOLLA_CMD=bootstrap-servers LIMIT=<NODE_NAME> singilarity-submit
make KOLLA_CMD=prechecks         LIMIT=<NODE_NAME> singilarity-submit
make KOLLA_CMD=pull              LIMIT=<NODE_NAME> singilarity-submit
make KOLLA_CMD=deploy            LIMIT=<NODE_NAME> singilarity-submit
```


## RoadMap

* [x] Setup infrastructure from Terraform
    * [x] OpenStack
    * [x] Slurm

* [x] Run Kolla-Ansible in Conatiner
    * [x] Docker Container
    * [x] Singularity Container