variable "workspace_name" {
  description = "Name prefix for networking resources"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy networking into"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "vnet_cidr" {
  description = "Address space for the VNet used for VNet injection"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
