---
# Kolla-Ansible globals.yml for 3-node deployment
# Generated for OpenStack 2024.2 (Dalmatian)
# Date: 2026-03-15

# Dummy variable to allow Ansible to accept this file.
workaround_ansible_issue_8743: yes

################
# Kolla options
################
kolla_base_distro: "rocky"
openstack_release: "2024.2"

# Container engine
kolla_container_engine: "docker"

%{ if enable_private_registry ~}
###################
# Private Docker Registry
###################
#docker_registry: "${bastion_ip}:5000"
#docker_namespace: "openstack.kolla"
#docker_registry_insecure: "yes"
%{ endif ~}

######################
# Networking options
######################
# API / management interface (dynamically discovered from default network)
network_interface: "${network_interface_name}"

# Tunnel interface for Geneve (dynamically discovered from optional network)
# Falls back to network_interface when no optional network is configured
tunnel_interface: "${tunnel_interface_name != "" ? tunnel_interface_name : network_interface_name}"

# No external/provider network needed for this test deployment
# neutron_external_interface: ""

###################
# VIP / HAProxy - DISABLED
# Anti-Spoofing on OpenStack VMs prevents keepalived VIP.
# Point VIP directly to the single controller IP.
###################
kolla_internal_vip_address: "${controller_ip}"
kolla_external_vip_address: "${enable_controller_fip ? controller_fip : controller_ip}"
enable_haproxy: "no"
enable_keepalived: "no"
enable_proxysql: "no"

###################
# Horizon default port
###################
horizon_port: 8080
horizon_tls_port: 8443

###################
# OpenStack services - minimal set
###################
enable_openstack_core: "yes"
# Core: keystone, glance, nova, neutron, horizon, heat
# We disable heat since it's not needed
enable_heat: "no"

# Cinder
enable_cinder: "yes"
enable_cinder_backup: "no"
enable_cinder_backend_nfs: "yes"
enable_cinder_backend_lvm: "no"

# Disable all non-required services
enable_aodh: "no"
enable_barbican: "no"
enable_blazar: "no"
enable_ceilometer: "no"
enable_cloudkitty: "no"
enable_collectd: "no"
enable_cyborg: "no"
enable_designate: "no"
enable_etcd: "no"
enable_gnocchi: "no"
enable_grafana: "no"
enable_influxdb: "no"
enable_ironic: "no"
enable_magnum: "no"
enable_manila: "no"
enable_masakari: "no"
enable_mistral: "no"
enable_octavia: "no"
enable_opensearch: "no"
enable_osprofiler: "no"
enable_prometheus: "no"
enable_redis: "no"
enable_skyline: "no"
enable_swift: "no"
enable_tacker: "no"
enable_telegraf: "no"
enable_trove: "no"
enable_venus: "no"
enable_watcher: "no"
enable_zun: "no"
enable_nova_novncproxy: "no"

###################
# Neutron - OVN
###################
neutron_plugin_agent: "ovn"
neutron_ovn_distributed_fip: "no"

###################
# Nova
###################
nova_compute_virt_type: "kvm"
nova_console: "novnc"

###################
# Glance
###################
glance_backend_file: "yes"

###################
# Logging - keep fluentd for container log collection
###################
enable_fluentd: "yes"
enable_central_logging: "no"
