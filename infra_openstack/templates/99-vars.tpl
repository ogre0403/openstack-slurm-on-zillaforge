# These initial groups are the only groups required to be modified. The
# additional groups are for more control of the environment.

# ---- Global variables ----
[baremetal:vars]
ansible_user=cloud-user
ansible_become=true
ansible_become_password=${server_password}
ansible_password=${server_password}
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
