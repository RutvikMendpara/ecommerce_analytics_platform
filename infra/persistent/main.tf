# Things with no hourly cost. Stays up between sessions.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # bucket passed at init: terraform init -backend-config="bucket=<your bucket>"
  backend "s3" {
    key          = "terraform/persistent.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { project = "ecommerce-analytics-platform" }
  }
}

variable "lake_bucket" {
  description = "Existing S3 bucket for landing data"
  type        = string
}

locals {
  name = "ecommerce-analytics"
}

data "aws_caller_identity" "current" {}

data "aws_s3_bucket" "lake" {
  bucket = var.lake_bucket
}
