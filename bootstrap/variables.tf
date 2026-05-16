variable "location" {
  description = "Azure region for the state storage account"
  type        = string
  default     = "eastus"
}

variable "storage_account_name" {
  description = "Globally unique name for the Terraform state storage account (3-24 lowercase alphanumeric)"
  type        = string
}

variable "subscription_id" {
  description = "Azure subscription ID — used to scope role assignments and derive the Key Vault name"
  type        = string
}

variable "tags" {
  description = "Tags applied to all bootstrap resources"
  type        = map(string)
  default = {
    environment = "shared"
    owner       = "platform"
    cost-center = "platform"
  }
}
