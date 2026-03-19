# Run Kolla-Ansible in Singularity Container


```shell
export APPTAINER_NOHTTPS=true
# or SINGULARITY_NOHTTPS, but APPTAINER_NOHTTPS is pefered
# export SINGULARITY_NOHTTPS=true

BASTION_IP=192.168.95.X
singularity pull kolla-ansible.sif docker://${BASTION_IP}:5000/kolla-ansible:py311-ka2024.2


export APPTAINERENV_ANSIBLE_REMOTE_TMP=/tmp/.ansible-${USER}/tmp
export APPTAINERENV_ANSIBLE_LOCAL_TMP=/tmp/.ansible-${USER}/tmp
# or SINGULARITYENV_XXX, but APPTAINERENV_XXX is prefered
# export SINGULARITYENV_ANSIBLE_REMOTE_TMP=/tmp/.ansible-${USER}/tmp
# export SINGULARITYENV_ANSIBLE_LOCAL_TMP=/tmp/.ansible-${USER}/tmp

singularity exec \
-B resource_manage/kolla-ansible/etc/kolla/:/etc/kolla \
-B resource_manage/kolla-ansible/etc/openstack/:/etc/openstack \
kolla-ansible.sif bash

```

