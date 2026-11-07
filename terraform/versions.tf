terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59, < 7.0"
    }
  }

  # Remote state - strongly recommended so state is not lost with the EC2 box.
  # 1. Create the bucket once:
  #      aws s3api create-bucket --bucket <name> --region eu-west-1 \
  #        --create-bucket-configuration LocationConstraint=eu-west-1
  #      aws s3api put-bucket-versioning --bucket <name> --versioning-configuration Status=Enabled
  # 2. Uncomment, set the bucket, then: terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket       = "CHANGE_ME-banking-tfstate"
  #   key          = "eks/banking/terraform.tfstate"
  #   region       = "eu-west-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "techbleat-global-bank"
      ManagedBy = "terraform"
    }
  }
}
