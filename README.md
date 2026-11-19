# ecommerce_analytics_platform

Analytics for a (made up) fashion e-commerce store on its biggest sale day. Every insert, update and delete in the orders database is captured with CDC, so analytics never query production. The changes land in a Delta lakehouse on Databricks and dbt turns them into a star schema: one GMV number, stock-outs within minutes, funnel and returns by size.

```
Postgres --Debezium--> Kafka (MSK) --S3 sink--> S3 --Auto Loader--> bronze --MERGE--> silver --dbt--> gold / marts
simulator clickstream --Firehose--> S3 ------------------------------^
```

## What's where

| Folder | What |
|---|---|
| `simulator/` | Fake store. Places orders, ships, cancels, returns, restocks, changes prices. Sends clickstream. `--sale` = 10x traffic + a hot SKU that sells out |
| `connect/` | Kafka Connect image: Debezium Postgres source + S3 sink |
| `lakehouse/` | `bronze.py` (Auto Loader) and `silver.py` (CDC MERGE) |
| `dbt/` | staging → gold (SCD2 dims, facts) → marts (GMV, funnel, returns, stock-outs) |
| `infra/` | Terraform: `persistent` (VPC, Firehose, ECR), `session` (RDS, MSK, Fargate), `databricks` (Unity Catalog, job) |

## A few decisions

- **CDC from the WAL, not `updated_at` polling.** Catches deletes and every status change, no query load on the DB.
- **Databricks only reads S3.** It never connects to Kafka or Postgres, so no VPC peering or NAT. The raw change files in S3 are also the replay source for backfills.
- **Silver MERGE only applies newer LSNs.** Replaying the same files or getting batches out of order changes nothing. Deletes are soft (`_is_deleted`) so an old insert can't bring a row back.
- **SCD2 from the change history, not dbt snapshots.** Snapshots only see what's there at run time; the CDC history has every version.
- **GMV has three named versions** (`booked_gmv`, `gmv`, `net_gmv`) defined once in `mart_gmv_daily`. The dashboard uses `gmv`.
- **No NAT Gateway.** Fargate tasks sit in public subnets with no inbound rules; RDS and MSK are private.

## Run locally

```bash
docker compose up -d
uv run python simulator/simulator.py --rate 2        # add --sale for sale mode
```

Debezium starts streaming into local Kafka once the simulator has created the tables. To also write the CDC files to S3, put `LAKE_BUCKET=<bucket>` in `.env` and `docker compose up -d connect` again (uses your local AWS profile). Clickstream goes to `data/` by default, or `--clickstream s3 --bucket <bucket>`.

## AWS

Terraform state goes in your bucket under `terraform/`. Copy each `terraform.tfvars.example` to `terraform.tfvars` first.

One time (no hourly cost):

```bash
terraform -chdir=infra/persistent init -backend-config="bucket=<bucket>"
terraform -chdir=infra/persistent apply
```

Push the images:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY=$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $REGISTRY
docker build --platform linux/arm64 -f simulator/Dockerfile -t $REGISTRY/ecommerce-analytics/simulator:latest . && docker push $REGISTRY/ecommerce-analytics/simulator:latest
docker build --platform linux/arm64 -t $REGISTRY/ecommerce-analytics/connect:latest connect && docker push $REGISTRY/ecommerce-analytics/connect:latest
```

Each session (MSK takes ~20 min to come up):

```bash
terraform -chdir=infra/session init -backend-config="bucket=<bucket>"
terraform -chdir=infra/session apply
# ... run, record ...
terraform -chdir=infra/session destroy
```

Sale mode: `terraform -chdir=infra/session apply -var sale_mode=true`.

## Databricks

```bash
export DATABRICKS_HOST=https://<workspace>.cloud.databricks.com DATABRICKS_TOKEN=<pat>
terraform -chdir=infra/databricks init -backend-config="bucket=<bucket>"
terraform -chdir=infra/databricks apply
```

This creates the storage credential + external location on the bucket, the `ecommerce` catalog, a 2X-Small SQL warehouse and the `ecommerce-pipeline` job (bronze → silver → dbt build every 10 min). The job is paused by default; unpause it while a session is running.

## Load test

Run the session stack, then step `orders_per_sec` up (5, 10, 25, 50 …) with `terraform apply -var orders_per_sec=N`, ~10 min per step. Watch:

- Debezium lag: RDS `OldestReplicationSlotLag` in CloudWatch
- Freshness: `select max(placed_at) from ecommerce.gold.fct_orders` vs now
- Reconciliation: the simulator logs `orders=… booked_gmv=…` every minute; compare with `select count(*), sum(line_amount) from ecommerce.gold.fct_order_items`

Stop at the step where lag keeps growing.
