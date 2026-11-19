resource "databricks_sql_endpoint" "dbt" {
  name                      = "ecommerce-dbt"
  cluster_size              = "2X-Small"
  max_num_clusters          = 1
  auto_stop_mins            = 10
  enable_serverless_compute = true
  warehouse_type            = "PRO"
}

locals {
  checkpoints = "/Volumes/${var.catalog}/bronze/checkpoints"
}

# bronze -> silver -> dbt build, every 10 minutes. Paused by default so it doesn't burn credits
# while the AWS side is down; unpause it in the UI (or set pause_status) during a session.
resource "databricks_job" "pipeline" {
  name = "ecommerce-pipeline"

  git_source {
    url      = var.git_url
    provider = "gitHub"
    branch   = var.git_branch
  }

  schedule {
    quartz_cron_expression = "0 0/10 * * * ?"
    timezone_id            = "UTC"
    pause_status           = "PAUSED"
  }

  environment {
    environment_key = "default"
    spec {
      client       = "2"
      dependencies = ["dbt-databricks>=1.9,<2"]
    }
  }

  task {
    task_key        = "bronze"
    environment_key = "default"
    spark_python_task {
      python_file = "lakehouse/bronze.py"
      parameters  = ["--catalog", var.catalog, "--landing", "s3://${var.lake_bucket}/landing", "--checkpoints", "${local.checkpoints}/bronze"]
    }
  }

  task {
    task_key        = "silver"
    environment_key = "default"
    depends_on {
      task_key = "bronze"
    }
    spark_python_task {
      python_file = "lakehouse/silver.py"
      parameters  = ["--catalog", var.catalog, "--checkpoints", "${local.checkpoints}/silver"]
    }
  }

  task {
    task_key        = "dbt"
    environment_key = "default"
    depends_on {
      task_key = "silver"
    }
    dbt_task {
      project_directory = "dbt"
      commands          = ["dbt build"]
      warehouse_id      = databricks_sql_endpoint.dbt.id
      catalog           = var.catalog
      schema            = "gold"
    }
  }

  email_notifications {
    on_failure = [var.alert_email]
  }

  max_concurrent_runs = 1
}

output "job_id" {
  value = databricks_job.pipeline.id
}

output "warehouse_http_path" {
  value = databricks_sql_endpoint.dbt.odbc_params[0].path
}
