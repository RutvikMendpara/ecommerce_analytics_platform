resource "aws_msk_configuration" "main" {
  name              = local.name
  kafka_versions    = ["3.8.x"]
  server_properties = <<-EOT
    auto.create.topics.enable=true
    default.replication.factor=2
    min.insync.replicas=1
    num.partitions=1
    log.retention.hours=24
  EOT
}

# Plaintext inside the VPC to keep it simple; only the ECS tasks' security group can reach it.
resource "aws_msk_cluster" "main" {
  cluster_name           = local.name
  kafka_version          = "3.8.x"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = data.aws_subnets.private.ids
    security_groups = [aws_security_group.msk.id]
    storage_info {
      ebs_storage_info {
        volume_size = 10
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.main.arn
    revision = aws_msk_configuration.main.latest_revision
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "PLAINTEXT"
    }
  }
}
