"""Fake fashion store: writes orders, inventory, returns etc. into Postgres and emits clickstream events."""

import argparse
import gzip
import hashlib
import json
import math
import os
import random
import time
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import psycopg

CITIES = {
    "Bengaluru": "Karnataka", "Mumbai": "Maharashtra", "Pune": "Maharashtra", "Delhi": "Delhi",
    "Gurugram": "Haryana", "Kolkata": "West Bengal", "Chennai": "Tamil Nadu", "Hyderabad": "Telangana",
    "Jaipur": "Rajasthan", "Ahmedabad": "Gujarat",
}
WAREHOUSES = {1: "Bengaluru", 2: "Mumbai", 3: "Gurugram", 4: "Kolkata"}
BRANDS = [
    "Roadline", "Urbanloom", "Northpeak", "Kavya", "Stridex", "Bluefin", "Mira & Co", "Denimworks",
    "Aarohi", "Fleetfoot", "Coastline", "Indigo Thread", "Harbor", "Saanjh", "Metro Man", "Petalwise",
]
SMALL_FIT_BRANDS = {"Roadline", "Urbanloom"}  # sizes run small, so they get more size returns
CATEGORIES = {
    "Footwear": (["Sneakers", "Sandals", "Formal Shoes"], ["6", "7", "8", "9", "10", "11"]),
    "Topwear": (["T-Shirts", "Shirts", "Jackets"], ["XS", "S", "M", "L", "XL", "XXL"]),
    "Bottomwear": (["Jeans", "Trousers", "Shorts"], ["28", "30", "32", "34", "36"]),
    "Ethnic": (["Kurtas", "Sarees"], ["S", "M", "L", "XL"]),
}
COLOURS = ["Black", "White", "Navy", "Olive", "Maroon", "Beige", "Grey"]
RETURN_REASONS = ["SIZE_TOO_SMALL", "SIZE_TOO_LARGE", "NOT_AS_SHOWN", "DAMAGED", "CHANGED_MIND"]
FUNNEL = [
    "product_list_view", "product_view", "size_chart_open", "add_to_cart", "checkout_start",
    "address_selected", "delivery_date_shown", "payment_start", "order_placed",
]

# seconds an order waits in each status before moving on (compressed so a demo shows the full lifecycle)
CONFIRM_AFTER, SHIP_AFTER, DELIVER_AFTER, REFUND_AFTER = 5, 30, 60, 30


def now():
    return datetime.now(UTC)


def poisson(lam):
    if lam > 30:
        return max(0, round(random.gauss(lam, math.sqrt(lam))))
    limit, k, p = math.exp(-lam), 0, 1.0
    while p > limit:
        k += 1
        p *= random.random()
    return k - 1


def size_weights(sizes):
    # middle sizes sell more than the extremes
    mid = (len(sizes) - 1) / 2
    return [1 / (1 + abs(i - mid)) for i in range(len(sizes))]


def setup_schema(conn):
    conn.execute((Path(__file__).parent / "schema.sql").read_text())


def seed(conn, n_customers, n_products):
    if conn.execute("SELECT count(*) FROM customers").fetchone()[0] > 0:
        return
    print(f"seeding {n_customers} customers, {n_products} products")
    with conn.transaction(), conn.cursor() as cur:
        cur.executemany(
            "INSERT INTO warehouses VALUES (%s, %s) ON CONFLICT DO NOTHING", list(WAREHOUSES.items())
        )
        with cur.copy("COPY customers (email_hash, city, tier) FROM STDIN") as copy:
            for i in range(n_customers):
                email = hashlib.sha256(f"user{i}@example.com".encode()).hexdigest()
                copy.write_row((email, random.choice(list(CITIES)), "insider" if random.random() < 0.1 else "regular"))
        customers = conn.execute("SELECT customer_id, city FROM customers").fetchall()
        with cur.copy("COPY addresses (customer_id, pincode, city, state) FROM STDIN") as copy:
            for customer_id, city in customers:
                copy.write_row((customer_id, str(random.randint(110001, 799999)), city, CITIES[city]))

        with cur.copy("COPY products (brand, category, sub_category, gender, mrp) FROM STDIN") as copy:
            for _ in range(n_products):
                category = random.choice(list(CATEGORIES))
                gender = "Women" if category == "Ethnic" and random.random() < 0.8 else random.choice(["Men", "Women"])
                mrp = random.choice([499, 799, 999, 1299, 1499, 1999, 2499, 2999, 3999, 4999])
                copy.write_row((random.choice(BRANDS), category, random.choice(CATEGORIES[category][0]), gender, mrp))
        product_rows = conn.execute("SELECT product_id, category FROM products").fetchall()
        with cur.copy("COPY skus (product_id, size, colour) FROM STDIN") as copy:
            for product_id, category in product_rows:
                colour = random.choice(COLOURS)
                for size in CATEGORIES[category][1]:
                    copy.write_row((product_id, size, colour))
        sku_rows = conn.execute("SELECT sku_id FROM skus").fetchall()
        with cur.copy("COPY inventory (sku_id, warehouse_id, on_hand) FROM STDIN") as copy:
            for (sku_id,) in sku_rows:
                for warehouse_id in WAREHOUSES:
                    copy.write_row((sku_id, warehouse_id, random.randint(0, 40)))


def load_catalog(conn):
    products = {}
    for product_id, brand, category, mrp in conn.execute("SELECT product_id, brand, category, mrp FROM products"):
        products[product_id] = {"brand": brand, "category": category, "mrp": float(mrp), "skus": []}
    for sku_id, product_id, size in conn.execute("SELECT sku_id, product_id, size FROM skus ORDER BY sku_id"):
        products[product_id]["skus"].append((sku_id, size))
    ids = list(products)
    random.shuffle(ids)
    # Zipf-like popularity: a few products get most of the traffic
    weights = [1 / (rank + 1) for rank in range(len(ids))]
    return products, ids, weights


def pick_items(products, ids, weights, sale):
    items = []
    hot_product = ids[0]
    for _ in range(random.choices([1, 2, 3], [0.6, 0.3, 0.1])[0]):
        product_id = hot_product if sale and random.random() < 0.2 else random.choices(ids, weights)[0]
        product = products[product_id]
        sizes = [s for _, s in product["skus"]]
        sku_id, size = random.choices(product["skus"], size_weights(sizes))[0]
        items.append({"sku_id": sku_id, "product_id": product_id, "brand": product["brand"],
                      "size": size, "mrp": product["mrp"]})
    return items


def place_order(conn, customer_id, items, sale):
    """Reserve stock and create order + payment. Returns the items that made it into the order."""
    placed = []
    with conn.transaction():
        for item in items:
            row = conn.execute(
                """SELECT warehouse_id, on_hand - reserved FROM inventory WHERE sku_id = %s
                   ORDER BY on_hand - reserved DESC LIMIT 1 FOR UPDATE""",
                (item["sku_id"],),
            ).fetchone()
            warehouse_id, available = row
            # during the sale the app sometimes accepts orders it can't fill (race on the hot SKU) -> oversell
            if available < 1 and not (sale and random.random() < 0.3):
                continue
            conn.execute(
                "UPDATE inventory SET reserved = reserved + 1, updated_at = now() WHERE sku_id = %s AND warehouse_id = %s",
                (item["sku_id"], warehouse_id),
            )
            discount_pct = random.uniform(0.4, 0.7) if sale else random.uniform(0.1, 0.4)
            selling_price = round(item["mrp"] * (1 - discount_pct), 2)
            placed.append({**item, "warehouse_id": warehouse_id, "selling_price": selling_price})

        if not placed:
            return []
        coupon = random.choice(["EORS10", "EORS20", "FIRSTBUY"]) if sale and random.random() < 0.5 else None
        order_id = conn.execute(
            "INSERT INTO orders (customer_id, status, channel, coupon_code) VALUES (%s, 'PLACED', %s, %s) RETURNING order_id",
            (customer_id, random.choice(["android", "ios", "web"]), coupon),
        ).fetchone()[0]
        for item in placed:
            conn.execute(
                """INSERT INTO order_items (order_id, sku_id, warehouse_id, qty, mrp, selling_price, discount)
                   VALUES (%s, %s, %s, 1, %s, %s, %s)""",
                (order_id, item["sku_id"], item["warehouse_id"], item["mrp"], item["selling_price"],
                 round(item["mrp"] - item["selling_price"], 2)),
            )
        method = random.choices(["UPI", "CARD", "COD"], [0.55, 0.25, 0.2])[0]
        conn.execute(
            "INSERT INTO payments (order_id, method, status, amount) VALUES (%s, %s, %s, %s)",
            (order_id, method, "PENDING" if method == "COD" else "SUCCESS", sum(i["selling_price"] for i in placed)),
        )
    return placed


INVENTORY_FROM_ORDERS = """
    UPDATE inventory i SET {set_clause}, updated_at = now()
    FROM (SELECT sku_id, warehouse_id, sum(qty) AS qty FROM order_items WHERE order_id = ANY(%s) GROUP BY 1, 2) x
    WHERE i.sku_id = x.sku_id AND i.warehouse_id = x.warehouse_id
"""


def advance_orders(conn):
    with conn.transaction():
        rows = conn.execute(
            """UPDATE orders SET status = CASE WHEN random() < 0.03 THEN 'CANCELLED' ELSE 'CONFIRMED' END,
                      updated_at = now()
               WHERE status = 'PLACED' AND placed_at < now() - make_interval(secs => %s)
               RETURNING order_id, status""",
            (CONFIRM_AFTER,),
        ).fetchall()
        cancelled = [order_id for order_id, status in rows if status == "CANCELLED"]
        if cancelled:
            conn.execute(INVENTORY_FROM_ORDERS.format(set_clause="reserved = i.reserved - x.qty"), (cancelled,))
            conn.execute(
                """UPDATE payments SET status = CASE WHEN method = 'COD' THEN 'CANCELLED' ELSE 'REFUNDED' END,
                          updated_at = now() WHERE order_id = ANY(%s)""",
                (cancelled,),
            )

        shipped = [r[0] for r in conn.execute(
            """UPDATE orders SET status = 'SHIPPED', updated_at = now()
               WHERE status = 'CONFIRMED' AND updated_at < now() - make_interval(secs => %s) RETURNING order_id""",
            (SHIP_AFTER,),
        )]
        if shipped:
            conn.execute(
                INVENTORY_FROM_ORDERS.format(set_clause="on_hand = i.on_hand - x.qty, reserved = i.reserved - x.qty"),
                (shipped,),
            )

        delivered = [r[0] for r in conn.execute(
            """UPDATE orders SET status = 'DELIVERED', updated_at = now()
               WHERE status = 'SHIPPED' AND updated_at < now() - make_interval(secs => %s) RETURNING order_id""",
            (DELIVER_AFTER,),
        )]
        if delivered:
            conn.execute(
                "UPDATE payments SET status = 'SUCCESS', updated_at = now() WHERE order_id = ANY(%s) AND method = 'COD'",
                (delivered,),
            )
            create_returns(conn, delivered)

        refunded = [r[0] for r in conn.execute(
            """UPDATE returns SET status = 'REFUNDED'
               WHERE status = 'REQUESTED' AND requested_at < now() - make_interval(secs => %s) RETURNING order_item_id""",
            (REFUND_AFTER,),
        )]
        if refunded:
            # returned stock goes back on the shelf
            conn.execute(
                """UPDATE inventory i SET on_hand = i.on_hand + oi.qty, updated_at = now()
                   FROM order_items oi WHERE oi.order_item_id = ANY(%s)
                   AND i.sku_id = oi.sku_id AND i.warehouse_id = oi.warehouse_id""",
                (refunded,),
            )


def create_returns(conn, order_ids):
    items = conn.execute(
        """SELECT oi.order_item_id, oi.selling_price * oi.qty, p.brand, s.size
           FROM order_items oi JOIN skus s USING (sku_id) JOIN products p USING (product_id)
           WHERE oi.order_id = ANY(%s)""",
        (order_ids,),
    ).fetchall()
    returns = []
    for order_item_id, amount, brand, _ in items:
        if brand in SMALL_FIT_BRANDS and random.random() < 0.35:
            reason = random.choices(RETURN_REASONS, [0.7, 0.05, 0.1, 0.05, 0.1])[0]
        elif random.random() < 0.15:
            reason = random.choices(RETURN_REASONS, [0.2, 0.2, 0.25, 0.1, 0.25])[0]
        else:
            continue
        returns.append((order_item_id, reason, amount))
    if returns:
        with conn.cursor() as cur:
            cur.executemany(
                "INSERT INTO returns (order_item_id, reason, status, refund_amount) VALUES (%s, %s, 'REQUESTED', %s)",
                returns,
            )


def background_changes(conn, products, max_customer_id, sale_hot_sku_ids):
    """Restocks, price changes, customer updates, address deletes, signups. Returns new max customer id."""
    with conn.transaction():
        conn.execute(
            """UPDATE inventory SET on_hand = on_hand + 30, updated_at = now()
               WHERE on_hand - reserved < 3 AND random() < 0.3 AND NOT (sku_id = ANY(%s::bigint[]))""",
            (sale_hot_sku_ids,),
        )
        product_id = random.choice(list(products))
        factor = random.choice([0.9, 0.95, 1.05, 1.1])
        conn.execute(
            "UPDATE products SET mrp = round(mrp * %s::numeric, 2), updated_at = now() WHERE product_id = %s",
            (factor, product_id),
        )
        products[product_id]["mrp"] = round(products[product_id]["mrp"] * factor, 2)

        customer_id = random.randint(1, max_customer_id)
        if random.random() < 0.5:
            conn.execute(
                "UPDATE customers SET tier = 'insider', updated_at = now() WHERE customer_id = %s", (customer_id,)
            )
        else:
            city = random.choice(list(CITIES))
            conn.execute(
                "UPDATE customers SET city = %s, updated_at = now() WHERE customer_id = %s", (city, customer_id)
            )
            conn.execute("DELETE FROM addresses WHERE customer_id = %s", (customer_id,))
            conn.execute(
                "INSERT INTO addresses (customer_id, pincode, city, state) VALUES (%s, %s, %s, %s)",
                (customer_id, str(random.randint(110001, 799999)), city, CITIES[city]),
            )

        city = random.choice(list(CITIES))
        email = hashlib.sha256(uuid.uuid4().bytes).hexdigest()
        new_id = conn.execute(
            "INSERT INTO customers (email_hash, city) VALUES (%s, %s) RETURNING customer_id", (email, city)
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO addresses (customer_id, pincode, city, state) VALUES (%s, %s, %s, %s)",
            (new_id, str(random.randint(110001, 799999)), city, CITIES[city]),
        )
    return new_id


def session_events(customer_id, items, ordered):
    """Clickstream for one shopping session. Abandoned sessions stop at a random funnel step."""
    session_id, anonymous_id = str(uuid.uuid4()), str(uuid.uuid4())
    device, city = random.choice(["android", "ios", "web"]), random.choice(list(CITIES))
    if ordered:
        last_step = len(FUNNEL) - 1
    else:
        # most people drop early; small-fit brands lose more people at the size chart
        last_step = random.choices(range(len(FUNNEL) - 1), [30, 25, 10, 15, 8, 5, 4, 3])[0]
    steps = [s for s in FUNNEL[: last_step + 1] if s != "size_chart_open" or random.random() < 0.4]

    events, ts = [], now() - timedelta(seconds=20 * len(steps))
    for step_no, event_type in enumerate(steps):
        for item in items if event_type in ("product_view", "size_chart_open", "add_to_cart") else items[:1]:
            ts += timedelta(seconds=random.uniform(1, 20))
            events.append({
                "event_id": str(uuid.uuid4()),
                "event_type": event_type,
                "event_ts": ts.isoformat(),
                "session_id": session_id,
                "anonymous_id": anonymous_id,
                "customer_id": customer_id if ordered or random.random() < 0.5 else None,
                "device": device,
                "city": city,
                "sku_id": item["sku_id"],
                "product_id": item["product_id"],
                "brand": item["brand"],
                "size": item["size"],
                "price": item["mrp"],
                "step": FUNNEL.index(event_type),
                "schema_version": 1,
            })
    # a few duplicates, like a mobile SDK retrying
    events += [dict(e) for e in events if random.random() < 0.005]
    return events


def flush_events(events, args, clients):
    if not events:
        return
    ts = now()
    body = "".join(json.dumps(e) + "\n" for e in events)
    key = f"landing/clickstream/dt={ts:%Y-%m-%d}/hour={ts:%H}/{ts:%H%M%S}-{uuid.uuid4().hex[:8]}.json.gz"

    if args.clickstream == "local":
        path = Path(args.local_dir) / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(gzip.compress(body.encode()))
    elif args.clickstream == "s3":
        clients["s3"].put_object(Bucket=args.bucket, Key=key, Body=gzip.compress(body.encode()))
    else:
        # Firehose bills each record in 5 KB steps, so pack many events into ~4.5 KB records
        records, current = [], ""
        for line in body.splitlines(keepends=True):
            if current and len(current) + len(line) > 4500:
                records.append({"Data": current.encode()})
                current = ""
            current += line
        records.append({"Data": current.encode()})
        for i in range(0, len(records), 500):
            resp = clients["firehose"].put_record_batch(DeliveryStreamName=args.stream, Records=records[i:i + 500])
            if resp["FailedPutCount"]:
                print(f"firehose: {resp['FailedPutCount']} records failed")


def main():
    parser = argparse.ArgumentParser()
    env = os.environ.get
    parser.add_argument("--db", default=env("DATABASE_URL", "postgresql://shop:shop@localhost:5433/shop"))
    parser.add_argument("--rate", type=float, default=float(env("RATE", "2")), help="orders per second")
    parser.add_argument("--sale", action="store_true", default=env("SALE_MODE") == "true", help="10x traffic")
    parser.add_argument("--customers", type=int, default=int(env("SEED_CUSTOMERS", "5000")))
    parser.add_argument("--products", type=int, default=int(env("SEED_PRODUCTS", "1000")))
    parser.add_argument("--clickstream", choices=["local", "s3", "firehose"], default=env("CLICKSTREAM_SINK", "local"))
    parser.add_argument("--local-dir", default="data")
    parser.add_argument("--bucket", default=env("LAKE_BUCKET"))
    parser.add_argument("--stream", default=env("FIREHOSE_STREAM"))
    args = parser.parse_args()

    clients = {}
    if args.clickstream != "local":
        import boto3

        clients["s3"] = boto3.client("s3")
        clients["firehose"] = boto3.client("firehose")

    conn = psycopg.connect(args.db, autocommit=True)
    setup_schema(conn)
    seed(conn, args.customers, args.products)
    products, ids, weights = load_catalog(conn)
    max_customer_id = conn.execute("SELECT max(customer_id) FROM customers").fetchone()[0]
    hot_sku_ids = [sku_id for sku_id, _ in products[ids[0]]["skus"]] if args.sale else []

    rate = args.rate * (10 if args.sale else 1)
    print(f"running at ~{rate} orders/sec, sale={args.sale}, clickstream={args.clickstream}")
    events, last_flush, tick = [], time.time(), 0
    while True:
        started = time.time()
        for _ in range(poisson(rate)):
            customer_id = random.randint(1, max_customer_id)
            placed = place_order(conn, customer_id, pick_items(products, ids, weights, args.sale), args.sale)
            if placed:
                events += session_events(customer_id, placed, ordered=True)
            # roughly 2 abandoned sessions per order (60-70% cart abandonment)
            for _ in range(2):
                events += session_events(customer_id, pick_items(products, ids, weights, args.sale), ordered=False)

        advance_orders(conn)
        if tick % 10 == 0:
            max_customer_id = background_changes(conn, products, max_customer_id, hot_sku_ids)
        if time.time() - last_flush >= 10 or len(events) > 5000:
            flush_events(events, args, clients)
            events, last_flush = [], time.time()
        if tick % 60 == 0:
            orders, gmv = conn.execute(
                "SELECT count(DISTINCT order_id), coalesce(sum(selling_price * qty), 0) FROM order_items"
            ).fetchone()
            print(f"{now():%H:%M:%S} totals: orders={orders} booked_gmv={gmv}", flush=True)

        tick += 1
        time.sleep(max(0.0, 1 - (time.time() - started)))


if __name__ == "__main__":
    main()
