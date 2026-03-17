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

######################
# Networking options
######################
# API / management interface (ens3 - 192.168.95.0/24)
network_interface: "ens3"

# Tunnel interface for Geneve (ens4 - 172.10.0.0/16)
tunnel_interface: "ens4"

# No external/provider network needed for this test deployment
# neutron_external_interface: ""

###################
# VIP / HAProxy - DISABLED
# Anti-Spoofing on OpenStack VMs prevents keepalived VIP.
# Point VIP directly to the single controller IP.
###################
kolla_internal_vip_address: "${controller_ip}"
enable_haproxy: "no"
enable_keepalived: "no"
enable_proxysql: "no"

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
