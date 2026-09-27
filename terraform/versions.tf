terraform {
  required_version = ">= 1.6.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = ">= 2.30.0, < 3.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0.0"
    }
  }
}

# Token comes from LINODE_TOKEN in the environment. Never put it in a tfvars file.
provider "linode" {}
