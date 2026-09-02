terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # S3-native locking (use_lockfile), GA since Terraform 1.11 -- no DynamoDB lock
  # table needed. The bucket itself was created by bootstrap/main.tf.
  backend "s3" {
    bucket       = "gha-demo-tfstate-123456789012"
    key          = "infra/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_caller_identity" "current" {}
