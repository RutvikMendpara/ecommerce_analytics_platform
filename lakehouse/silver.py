"""Silver: apply CDC changes from bronze with Delta MERGE.

<table>_current  one row per primary key, latest state (deletes kept as _is_deleted = true)
<table>_changes  every change, for SCD2 and status history

Both MERGEs only act on newer LSNs / unseen (pk, lsn) pairs, so replaying old files changes nothing.
"""

import argparse

from delta.tables import DeltaTable
from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F

PRIMARY_KEYS = {
    "customers": ["customer_id"],
    "addresses": ["address_id"],
    "products": ["product_id"],
    "skus": ["sku_id"],
    "warehouses": ["warehouse_id"],
    "inventory": ["sku_id", "warehouse_id"],
    "orders": ["order_id"],
    "order_items": ["order_item_id"],
    "payments": ["payment_id"],
    "returns": ["return_id"],
}
# dt/hour come from the landing folder names (Auto Loader adds them as columns)
BRONZE_ONLY_COLUMNS = ["_file_name", "_ingested_at", "_rescued_data", "dt", "hour"]


def prepare_changes(df, pk):
    """Debezium fields -> silver metadata columns, one row per (pk, lsn)."""
    return (
        df.withColumn("_op", F.col("__op"))
        .withColumn("_lsn", F.col("__lsn").cast("long"))
        .withColumn("_source_ts", F.timestamp_millis(F.col("__source_ts_ms").cast("long")))
        .withColumn("_is_deleted", F.col("__op") == "d")
        .drop("__op", "__lsn", "__source_ts_ms", "__deleted", *BRONZE_ONLY_COLUMNS)
        .dropDuplicates(pk + ["_lsn"])
    )


def latest_per_key(changes, pk):
    w = Window.partitionBy(*pk).orderBy(F.col("_lsn").desc())
    return changes.withColumn("_rn", F.row_number().over(w)).filter("_rn = 1").drop("_rn")


def merge_into(spark, df, table, on):
    """Create the table on first run; return a DeltaTable merge builder otherwise."""
    if not spark.catalog.tableExists(table):
        df.limit(0).write.format("delta").saveAsTable(table)
    return DeltaTable.forName(spark, table).alias("t").merge(df.alias("s"), on).withSchemaEvolution()


def apply_cdc(spark, batch_df, table, pk, catalog):
    changes = prepare_changes(batch_df, pk)
    on = " AND ".join(f"t.{c} = s.{c}" for c in pk)

    (
        merge_into(spark, latest_per_key(changes, pk), f"{catalog}.silver.{table}_current", on)
        # a delete event only carries the key, so just flag the existing row
        .whenMatchedUpdate(
            condition="s._lsn > t._lsn AND s._is_deleted",
            set={c: f"s.{c}" for c in ["_op", "_lsn", "_source_ts", "_is_deleted"]},
        )
        .whenMatchedUpdateAll(condition="s._lsn > t._lsn")
        .whenNotMatchedInsertAll()
        .execute()
    )
    (
        merge_into(spark, changes, f"{catalog}.silver.{table}_changes", f"{on} AND t._lsn = s._lsn")
        .whenNotMatchedInsertAll()
        .execute()
    )


def apply_clickstream(spark, batch_df, catalog):
    valid = F.col("event_id").isNotNull() & F.col("_rescued_data").isNull() & F.col("event_type").isNotNull()
    rejected = batch_df.filter(~valid)
    if not rejected.isEmpty():
        rejected.withColumn("_rejected_at", F.current_timestamp()).write.mode("append").option(
            "mergeSchema", "true"
        ).saveAsTable(f"{catalog}.silver.clickstream_rejected")

    events = (
        batch_df.filter(valid)
        .select(
            "event_id", "event_type",
            F.to_timestamp("event_ts").alias("event_ts"),
            "session_id", "anonymous_id",
            F.col("customer_id").cast("long").alias("customer_id"),
            "device", "city",
            F.col("sku_id").cast("long").alias("sku_id"),
            F.col("product_id").cast("long").alias("product_id"),
            "brand", "size",
            F.col("price").cast("decimal(10,2)").alias("price"),
            F.col("step").cast("int").alias("step"),
            F.col("schema_version").cast("int").alias("schema_version"),
            "_ingested_at",
        )
        .dropDuplicates(["event_id"])
    )
    (
        merge_into(spark, events, f"{catalog}.silver.clickstream_events", "t.event_id = s.event_id")
        .whenNotMatchedInsertAll()
        .execute()
    )


def run_stream(spark, source, checkpoint, handler):
    (
        spark.readStream.table(source)
        .writeStream.foreachBatch(handler)
        .option("checkpointLocation", checkpoint)
        .trigger(availableNow=True)
        .start()
        .awaitTermination()
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--checkpoints", required=True, help="e.g. /Volumes/<catalog>/silver/checkpoints")
    args = parser.parse_args()

    spark = SparkSession.builder.getOrCreate()
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {args.catalog}.silver")
    catalog = args.catalog

    for table, pk in PRIMARY_KEYS.items():
        source = f"{catalog}.bronze.cdc_{table}"
        if not spark.catalog.tableExists(source):
            print(f"{source} does not exist yet, skipping")
            continue
        run_stream(spark, source, f"{args.checkpoints}/{table}",
                   lambda df, _, t=table, k=pk: apply_cdc(df.sparkSession, df, t, k, catalog))

    if spark.catalog.tableExists(f"{catalog}.bronze.clickstream_events"):
        run_stream(spark, f"{catalog}.bronze.clickstream_events", f"{args.checkpoints}/clickstream_events",
                   lambda df, _: apply_clickstream(df.sparkSession, df, catalog))


if __name__ == "__main__":
    main()
