variable "api_endpoint" {
  description = "API endpoint to use with the provider"
  type        = string
  default     = "https://api.trusted-cloud.nchc.org.tw"
}

variable "api_key" {
  description = "API key for zillaforge provider"
  type        = string
  default     = ""
}

variable "project_sys_code" {
  description = "Project system code to use with the provider"
  type        = string
  default     = ""
}

variable "node_name_prefix" {
  description = "Prefix used for OpenStack node names"
  type        = string
  default     = "opsk"
}

variable "keypair_name" {
  description = "Name of the SSH keypair to inject into the server"
  type        = string
  default     = null
}

variable "securitygroup_name" {
  description = "Name of the security group to attach to the server"
  type        = string
  default     = null
}

variable "image_repository" {
  description = "Image repository to use for the server (e.g. ubuntu)"
  type        = string
  default     = null
}

variable "image_tag" {
  description = "Image tag to use for the server (e.g. 2404)"
  type        = string
  default     = null
}

variable "flavor_name" {
  description = "Flavor name to use for the server (e.g. Basic.small)"
  type        = string
  default     = null
}

variable "default_network_name" {
  description = "Network name to attach the server to (e.g. default)"
  type        = string
  default     = "default"
}

variable "optional_network_name" {
  description = "Optional network name to attach the server to. If omitted or not found, the servers will use only the default network."
  type        = string
  default     = null
}

variable "total" {
  description = "Number of VMs to create (minimum 2: at least one controller and one compute)"
  type        = number
  default     = 2

  validation {
    condition     = var.total >= 2
    error_message = "total must be at least 2 (one controller + one compute node)."
  }
}

variable "server_password" {
  description = "Password for the VMs (will be base64-encoded before passing to the API); must be supplied manually — no default."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition     = var.server_password != ""
    error_message = "server_password must not be empty — please supply a password."
  }
}

variable "enable_controller_fip" {
  description = "When true, allocate a Floating IP for the controller node and use it as kolla_external_vip_address. When false, kolla_external_vip_address falls back to the same value as kolla_internal_vip_address."
  type        = bool
  default     = false
}
