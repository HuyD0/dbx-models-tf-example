# Every rule here is ENFORCED: CI runs tflint with no minimum-failure-severity
# override, so notices (missing descriptions, naming) fail the build the same
# as errors. Run locally with:
#   tflint --init --config "$(pwd)/.tflint.hcl"
#   tflint --recursive --config "$(pwd)/.tflint.hcl"
# (--config must be an absolute path so recursive mode applies it everywhere.)
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
