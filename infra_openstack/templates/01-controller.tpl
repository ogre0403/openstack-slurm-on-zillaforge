# These initial groups are the only groups required to be modified. The
# additional groups are for more control of the environment.

[control]
${controller_name} ansible_host=${controller_ip}

[network]
${controller_name} ansible_host=${controller_ip}


[storage]
${controller_name} ansible_host=${controller_ip}

[monitoring]
# Not deploying monitoring

[deployment]
localhost ansible_connection=local ansible_become=false
