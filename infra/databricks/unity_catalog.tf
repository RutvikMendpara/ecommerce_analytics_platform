# Databricks reads the landing files in S3 through a UC storage credential (an IAM role) and an external location.
# It never connects to Kafka or Postgres.

resource "databricks_storage_credential" "lake" {
  name = "lake-reader"
  aws_iam_role {
    role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.uc_role_name}"
  }
  skip_validation = true
}

data "databricks_aws_unity_catalog_assume_role_policy" "lake" {
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = local.uc_role_name
  external_id    = databricks_storage_credential.lake.aws_iam_role[0].external_id
}

data "databricks_aws_unity_catalog_policy" "lake" {
  aws_account_id = data.aws_caller_identity.current.account_id
  bucket_name    = var.lake_bucket
  role_name      = local.uc_role_name
}

resource "aws_iam_role" "unity_catalog" {
  name               = local.uc_role_name
  assume_role_policy = data.databricks_aws_unity_catalog_assume_role_policy.lake.json
}

resource "aws_iam_role_policy" "unity_catalog" {
  role   = aws_iam_role.unity_catalog.id
  policy = data.databricks_aws_unity_catalog_policy.lake.json
}

resource "databricks_external_location" "landing" {
  name            = "landing"
  url             = "s3://${var.lake_bucket}/landing"
  credential_name = databricks_storage_credential.lake.name
  read_only       = true
  depends_on      = [aws_iam_role_policy.unity_catalog]
}

# The catalog itself is created once in the UI: Free Edition only allows catalogs on Default Storage,
# which the API can't create.
resource "databricks_schema" "layers" {
  for_each     = toset(["bronze", "silver", "staging", "gold", "marts"])
  catalog_name = var.catalog
  name         = each.key
}

# Auto Loader schema + streaming checkpoints
resource "databricks_volume" "checkpoints" {
  name         = "checkpoints"
  catalog_name = var.catalog
  schema_name  = databricks_schema.layers["bronze"].name
  volume_type  = "MANAGED"
}
