# Terraform's own minimum severity is `error`; bump to warning if you want noisier output.
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

config {
  call_module_type = "all"
  force            = false
}

rule "terraform_required_version" { enabled = true }
rule "terraform_required_providers" { enabled = true }
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_typed_variables" { enabled = true }
rule "terraform_documented_variables" { enabled = true }
rule "terraform_documented_outputs" { enabled = true }
rule "terraform_naming_convention" { enabled = true }
