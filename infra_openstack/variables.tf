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

variable "keypair_name" {
  description = "Name of the SSH keypair to inject into the server"
  type        = string
  default     = ""
}

variable "sg_name" {
  description = "Name of the security group to attach to the server"
  type        = string
  default     = ""
}

variable "total" {
  description = "Number of VMs to create"
  type        = number
  default     = 1
}

variable "image_repository" {
  description = "Image repository to use for the server (e.g. ubuntu)"
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Image tag to use for the server (e.g. 2404)"
  type        = string
  default     = ""
}

variable "flavor_name" {
  description = "Flavor name to use for the server (e.g. Basic.small)"
  type        = string
  default     = ""
}

variable "network_name" {
  description = "Network name to attach the server to (e.g. default)"
  type        = string
  default     = ""
}