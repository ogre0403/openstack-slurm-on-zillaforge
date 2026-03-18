# --------------------------------------------------------------------------
# Outputs
# --------------------------------------------------------------------------

output "bastion_floating_ip" {
  description = "Bastion 的 Floating IP"
  value       = zillaforge_floating_ip.bastion.ip_address
}

output "default_network_ips" {
  description = "所有節點 (含 bastion) 在 default network 上的 IP"
  value = merge(
    { (zillaforge_server.bastion.name) = zillaforge_server.bastion.network_attachment[0].ip_address },
    { for s in zillaforge_server.nodes : s.name => s.network_attachment[0].ip_address }
  )
}
