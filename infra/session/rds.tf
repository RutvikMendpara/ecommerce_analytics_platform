resource "aws_db_parameter_group" "postgres" {
  name   = "${local.name}-pg16"
  family = "postgres16"
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_subnet_group" "postgres" {
  name       = local.name
  subnet_ids = data.aws_subnets.private.ids
}

resource "aws_db_instance" "postgres" {
  identifier                  = local.name
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  db_name                     = "shop"
  username                    = "shop"
  manage_master_user_password = true
  parameter_group_name        = aws_db_parameter_group.postgres.name
  db_subnet_group_name        = aws_db_subnet_group.postgres.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  publicly_accessible         = false
  backup_retention_period     = 0
  skip_final_snapshot         = true
  deletion_protection         = false
  apply_immediately           = true
}

# if Debezium stops reading, the replication slot keeps WAL around until the disk fills up
resource "aws_cloudwatch_metric_alarm" "replication_slot_lag" {
  alarm_name          = "${local.name}-replication-slot-lag"
  alarm_description   = "Debezium is not consuming the replication slot (WAL is piling up)"
  namespace           = "AWS/RDS"
  metric_name         = "OldestReplicationSlotLag"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.postgres.identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1073741824 # 1 GB
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [data.aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "free_storage" {
  alarm_name          = "${local.name}-rds-free-storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.postgres.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5368709120 # 5 GB
  comparison_operator = "LessThanThreshold"
  alarm_actions       = [data.aws_sns_topic.alerts.arn]
}
