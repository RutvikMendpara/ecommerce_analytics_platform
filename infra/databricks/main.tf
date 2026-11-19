# Databricks workspace objects: Unity Catalog access to the lake bucket, catalog/schemas, SQL warehouse, the pipeline job.
# Auth: export DATABRICKS_HOST and DATABRICKS_TOKEN before running terraform.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.80"
    }
  }
  backend "s3" {
    key          = "terraform/databricks.tfstate"
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

provider "databricks" {}

variable "lake_bucket" {
  type = string
}

variable "catalog" {
  type    = string
  default = "ecommerce"
}

variable "git_url" {
  type    = string
  default = "https://github.com/RutvikMendpara/ecommerce_analytics_platform"
}

variable "git_branch" {
  type    = string
  default = "main"
}

variable "alert_email" {
  type = string
}

data "aws_caller_identity" "current" {}

locals {
  uc_role_name = "ecommerce-analytics-unity-catalog"
}

variable "warehouse_name" {
  type    = string
  default = "Serverless Starter Warehouse"
}
