# ecommerce_analytics_platform

A data pipeline for a made-up online fashion store. A small simulator places orders, ships them, handles returns and restocks inventory in Postgres. Every change in that database is picked up from the Postgres log, landed in S3, and turned into reporting tables in Databricks.

I built it to practice change data capture, Delta Lake merges and dimensional modeling with dbt.

![architecture](docs/architecture.png)

## How it works

1. **Simulator** (`simulator/`) writes orders, payments, returns and inventory updates into Postgres. It also sends clickstream events (product views, add to cart, checkout steps) to Firehose. `--sale` turns on 10x traffic and a product that sells out.
2. **Debezium** reads the Postgres write-ahead log and publishes every insert, update and delete to Kafka (MSK). The analytics side never runs queries against the app database.
3. **Kafka Connect S3 sink** writes those changes to S3 as JSON files, one folder per table, split by date and hour. Firehose does the same for clickstream.
4. **Bronze** (`lakehouse/bronze.py`): Auto Loader picks up new files into append-only Delta tables.
5. **Silver** (`lakehouse/silver.py`): a Delta MERGE applies the changes. Each table gets a `_current` version (latest row per key) and a `_changes` version (full history).
6. **Gold and marts** (`dbt/`): a star schema with customer and product dimensions that keep their history (SCD type 2), order/return/session facts, and four marts: daily GMV, funnel, returns by size, and stock-outs.
7. A Databricks job runs bronze, silver and `dbt build` every 10 minutes.

## Things worth pointing out

- **Applying changes safely.** Silver only applies a change if its log position (LSN) is newer than what's already there. Running the same files twice, or getting an older batch late, doesn't change the result. Deletes are kept as a flag, so a late insert can't bring a deleted row back. `tests/test_silver.py` checks all three cases.
- **History from the log, not snapshots.** The customer and product dimensions are built from every change Debezium captured. A nightly snapshot would miss a customer who changed city twice in a day.
- **One GMV number.** `mart_gmv_daily` has `booked_gmv` (everything ordered), `gmv` (minus orders cancelled before shipping) and `net_gmv` (minus refunds). Each is defined once, and a dbt test checks they add up.
- **Databricks only reads S3.** It never connects to Kafka or Postgres, so there's no network setup between the two, and the files in S3 can be replayed if something needs rebuilding.
- **Cheap to run.** No NAT gateway. The expensive parts (RDS, MSK, Fargate) live in their own Terraform stack that I create before a run and destroy after.

## Run it locally

Needs Docker and [uv](https://docs.astral.sh/uv/).

```bash
docker compose up -d
uv run python simulator/simulator.py --rate 2
```

This starts Postgres, Kafka and Kafka Connect with Debezium. Changes show up in Kafka topics `shop.public.<table>`. To also write them to S3, put `LAKE_BUCKET=<bucket>` in `.env` and restart the `connect` container.

Tests:

```bash
uv run pytest tests
```

## Deploy

All infrastructure is Terraform in `infra/`, with state stored in the S3 bucket.

| Stack | What's in it |
|---|---|
| `persistent` | VPC, Firehose, ECR repos, SNS alerts. No hourly cost. |
| `session` | RDS Postgres, MSK, Fargate services for the simulator and Kafka Connect. Destroy after use. |
| `databricks` | Unity Catalog access to the bucket, schemas, the pipeline job. |

```bash
terraform -chdir=infra/<stack> init -backend-config="bucket=<bucket>"
terraform -chdir=infra/<stack> apply
```

On Databricks Free Edition, create the `ecommerce` catalog in the UI first. Free Edition doesn't allow creating it through the API.

## Stack

Postgres, Debezium, Kafka (MSK), Kafka Connect, Kinesis Firehose, S3, Databricks (Auto Loader, Delta Lake, Unity Catalog, Workflows), dbt, Terraform, GitHub Actions.
