"""Bronze: Auto Loader picks up new landing files (CDC + clickstream) into append-only Delta tables."""

import argparse

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

CDC_TABLES = [
    "customers", "addresses", "products", "skus", "warehouses",
    "inventory", "orders", "order_items", "payments", "returns",
]


def ingest(spark, source_path, target_table, checkpoint):
    try:
        run_stream(spark, source_path, target_table, checkpoint)
    except Exception as e:
        # a table with no changes yet has no files, so there is nothing to infer a schema from
        if "CF_EMPTY_DIR_FOR_SCHEMA_INFERENCE" not in str(e):
            raise
        print(f"no files yet in {source_path}, skipping")


def run_stream(spark, source_path, target_table, checkpoint):
    stream = (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", "json")
        .option("cloudFiles.inferColumnTypes", "true")
        .option("cloudFiles.schemaEvolutionMode", "addNewColumns")
        .option("cloudFiles.schemaLocation", f"{checkpoint}/schema")
        .load(source_path)
        .withColumn("_file_name", F.col("_metadata.file_path"))
        .withColumn("_ingested_at", F.current_timestamp())
    )
    (
        stream.writeStream.option("checkpointLocation", checkpoint)
        .option("mergeSchema", "true")
        .trigger(availableNow=True)
        .toTable(target_table)
        .awaitTermination()
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--landing", required=True, help="e.g. s3://bucket/landing")
    parser.add_argument("--checkpoints", required=True, help="e.g. /Volumes/<catalog>/bronze/checkpoints")
    args = parser.parse_args()

    spark = SparkSession.builder.getOrCreate()
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {args.catalog}.bronze")

    for table in CDC_TABLES:
        ingest(spark, f"{args.landing}/cdc/shop.public.{table}", f"{args.catalog}.bronze.cdc_{table}",
               f"{args.checkpoints}/cdc_{table}")
    ingest(spark, f"{args.landing}/clickstream", f"{args.catalog}.bronze.clickstream_events",
           f"{args.checkpoints}/clickstream_events")


if __name__ == "__main__":
    main()
