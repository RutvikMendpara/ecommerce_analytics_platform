import pytest
from delta import configure_spark_with_delta_pip
from pyspark.sql import SparkSession
from silver import apply_cdc

COLUMNS = ["order_id", "status", "__op", "__lsn", "__source_ts_ms", "__deleted"]


@pytest.fixture(scope="session")
def spark(tmp_path_factory):
    builder = (
        SparkSession.builder.master("local[1]")
        .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
        .config("spark.sql.catalog.spark_catalog", "org.apache.spark.sql.delta.catalog.DeltaCatalog")
        .config("spark.sql.warehouse.dir", str(tmp_path_factory.mktemp("warehouse")))
        .config("spark.sql.shuffle.partitions", "1")
        .config("spark.ui.enabled", "false")
    )
    spark = configure_spark_with_delta_pip(builder).getOrCreate()
    spark.sql("CREATE SCHEMA IF NOT EXISTS silver")
    yield spark
    spark.stop()


def changes(spark, rows):
    return spark.createDataFrame(rows, COLUMNS)


def current(spark, table):
    return sorted(
        (r.order_id, r.status, r._is_deleted)
        for r in spark.table(f"silver.{table}_current").collect()
    )


INSERT = (1, "PLACED", "c", 100, 1_000, "false")
UPDATE = (1, "SHIPPED", "u", 200, 2_000, "false")
DELETE = (1, "", "d", 300, 3_000, "true")


def test_replaying_the_same_changes_changes_nothing(spark):
    batch = changes(spark, [INSERT, UPDATE])
    apply_cdc(spark, batch, "replay", ["order_id"], "spark_catalog")
    apply_cdc(spark, batch, "replay", ["order_id"], "spark_catalog")

    assert current(spark, "replay") == [(1, "SHIPPED", False)]
    assert spark.table("silver.replay_changes").count() == 2


def test_older_change_arriving_late_is_ignored(spark):
    apply_cdc(spark, changes(spark, [UPDATE]), "late", ["order_id"], "spark_catalog")
    apply_cdc(spark, changes(spark, [INSERT]), "late", ["order_id"], "spark_catalog")

    assert current(spark, "late") == [(1, "SHIPPED", False)]
    assert spark.table("silver.late_changes").count() == 2


def test_delete_is_not_undone_by_an_old_insert(spark):
    for batch in ([INSERT], [DELETE], [INSERT]):
        apply_cdc(spark, changes(spark, batch), "deletes", ["order_id"], "spark_catalog")

    # soft delete keeps the last known values and flags the row
    assert current(spark, "deletes") == [(1, "PLACED", True)]
