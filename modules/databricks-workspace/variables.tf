variable "workspace_name" {
  description = "Name of the Azure Databricks workspace"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to deploy the workspace into"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "sku" {
  description = "Databricks workspace SKU: standard | premium | trial"
  type        = string
  default     = "premium"

  validation {
    condition     = contains(["standard", "premium", "trial"], var.sku)
    error_message = "SKU must be one of: standard, premium, trial."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "managed_resource_group_name" {
  description = "Name of the managed resource group created by Databricks. Leave null to auto-generate."
  type        = string
  default     = null
  nullable    = true
}

variable "no_public_ip" {
  description = "Enable Secure Cluster Connectivity (no public IP on clusters)"
  type        = bool
  default     = true
}

variable "public_network_access_enabled" {
  description = "Allow public network access to the workspace."
  type        = bool
  default     = true
}

variable "infrastructure_encryption_enabled" {
  description = "Enable secondary layer of encryption on DBFS root with platform-managed keys. Premium SKU only."
  type        = bool
  default     = true
}

variable "vnet_id" {
  description = "Resource ID of the VNet to inject into"
  type        = string
}

variable "public_subnet_name" {
  description = "Name of the public subnet"
  type        = string
}

variable "private_subnet_name" {
  description = "Name of the private subnet"
  type        = string
}

variable "public_nsg_association_id" {
  description = "Resource ID of the public subnet NSG association"
  type        = string
}

variable "private_nsg_association_id" {
  description = "Resource ID of the private subnet NSG association"
  type        = string
}
