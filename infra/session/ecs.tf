resource "aws_ecs_cluster" "main" {
  name = local.name
}

resource "aws_cloudwatch_log_group" "tasks" {
  for_each          = toset(["simulator", "connect"])
  name              = "/ecs/${local.name}/${each.key}"
  retention_in_days = 7
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secret" {
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_db_instance.postgres.master_user_secret[0].secret_arn
    }]
  })
}

resource "aws_iam_role" "simulator" {
  name               = "${local.name}-simulator"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "simulator" {
  role = aws_iam_role.simulator.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "firehose:PutRecordBatch"
      Resource = data.aws_kinesis_firehose_delivery_stream.clickstream.arn
    }]
  })
}

resource "aws_iam_role" "connect" {
  name               = "${local.name}-connect"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "connect" {
  role = aws_iam_role.connect.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = "${data.aws_s3_bucket.lake.arn}/landing/cdc/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
        Resource = data.aws_s3_bucket.lake.arn
      },
    ]
  })
}

locals {
  db_secret = "${aws_db_instance.postgres.master_user_secret[0].secret_arn}:password::"
  log_config = { for k, g in aws_cloudwatch_log_group.tasks : k => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = g.name
      awslogs-region        = "us-east-1"
      awslogs-stream-prefix = k
    }
  } }
}

resource "aws_ecs_task_definition" "simulator" {
  family                   = "${local.name}-simulator"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.simulator.arn
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name      = "simulator"
    image     = "${data.aws_ecr_repository.simulator.repository_url}:${var.image_tag}"
    essential = true
    environment = [
      { name = "DATABASE_URL", value = "postgresql://shop@${aws_db_instance.postgres.address}:5432/shop?sslmode=require" },
      { name = "RATE", value = tostring(var.orders_per_sec) },
      { name = "SALE_MODE", value = tostring(var.sale_mode) },
      { name = "CLICKSTREAM_SINK", value = "firehose" },
      { name = "FIREHOSE_STREAM", value = data.aws_kinesis_firehose_delivery_stream.clickstream.name },
      { name = "AWS_REGION", value = "us-east-1" },
    ]
    secrets          = [{ name = "PGPASSWORD", valueFrom = local.db_secret }]
    logConfiguration = local.log_config["simulator"]
  }])
}

resource "aws_ecs_task_definition" "connect" {
  family                   = "${local.name}-connect"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.connect.arn
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name      = "connect"
    image     = "${data.aws_ecr_repository.connect.repository_url}:${var.image_tag}"
    essential = true
    environment = [
      { name = "BOOTSTRAP_SERVERS", value = aws_msk_cluster.main.bootstrap_brokers },
      { name = "GROUP_ID", value = "shop-connect" },
      { name = "CONFIG_STORAGE_TOPIC", value = "connect_configs" },
      { name = "OFFSET_STORAGE_TOPIC", value = "connect_offsets" },
      { name = "STATUS_STORAGE_TOPIC", value = "connect_statuses" },
      { name = "CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR", value = "2" },
      { name = "CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR", value = "2" },
      { name = "CONNECT_STATUS_STORAGE_REPLICATION_FACTOR", value = "2" },
      { name = "KEY_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "VALUE_CONVERTER", value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE", value = "false" },
      { name = "CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE", value = "false" },
      { name = "CONNECT_CONFIG_PROVIDERS", value = "env" },
      { name = "CONNECT_CONFIG_PROVIDERS_ENV_CLASS", value = "org.apache.kafka.common.config.provider.EnvVarConfigProvider" },
      { name = "PGHOST", value = aws_db_instance.postgres.address },
      { name = "PGPORT", value = "5432" },
      { name = "PGUSER", value = "shop" },
      { name = "PGDATABASE", value = "shop" },
      { name = "REPLICATION_FACTOR", value = "2" },
      { name = "LAKE_BUCKET", value = var.lake_bucket },
      { name = "AWS_REGION", value = "us-east-1" },
    ]
    secrets          = [{ name = "PGPASSWORD", valueFrom = local.db_secret }]
    logConfiguration = local.log_config["connect"]
  }])
}

resource "aws_ecs_service" "simulator" {
  name            = "simulator"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.simulator.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }
}

resource "aws_ecs_service" "connect" {
  name            = "connect"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.connect.arn
  desired_count   = 1
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }
}
