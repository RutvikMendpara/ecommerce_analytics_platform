# Everything with an hourly cost (RDS, MSK, Fargate). Apply before a session, destroy after.
# Reads the persistent stack's resources by name/tag.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {
    key          = "terraform/session.tfstate"
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
  type = string
}

variable "orders_per_sec" {
  type    = number
  default = 2
}

variable "sale_mode" {
  type    = bool
  default = false
}

variable "image_tag" {
  type    = string
  default = "latest"
}

locals {
  name = "ecommerce-analytics"
}

data "aws_vpc" "main" {
  tags = { Name = local.name }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { tier = "public" }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  tags = { tier = "private" }
}

data "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

data "aws_ecr_repository" "simulator" {
  name = "${local.name}/simulator"
}

data "aws_ecr_repository" "connect" {
  name = "${local.name}/connect"
}

data "aws_kinesis_firehose_delivery_stream" "clickstream" {
  name = "${local.name}-clickstream"
}

data "aws_s3_bucket" "lake" {
  bucket = var.lake_bucket
}

resource "aws_security_group" "tasks" {
  name   = "${local.name}-tasks"
  vpc_id = data.aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name   = "${local.name}-rds"
  vpc_id = data.aws_vpc.main.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
}

resource "aws_security_group" "msk" {
  name   = "${local.name}-msk"
  vpc_id = data.aws_vpc.main.id
  ingress {
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }
}
