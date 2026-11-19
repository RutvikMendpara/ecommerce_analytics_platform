CREATE TABLE IF NOT EXISTS customers (
    customer_id  BIGSERIAL PRIMARY KEY,
    email_hash   TEXT NOT NULL,
    city         TEXT NOT NULL,
    tier         TEXT NOT NULL DEFAULT 'regular',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS addresses (
    address_id   BIGSERIAL PRIMARY KEY,
    customer_id  BIGINT NOT NULL REFERENCES customers,
    pincode      TEXT NOT NULL,
    city         TEXT NOT NULL,
    state        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS products (
    product_id    BIGSERIAL PRIMARY KEY,
    brand         TEXT NOT NULL,
    category      TEXT NOT NULL,
    sub_category  TEXT NOT NULL,
    gender        TEXT NOT NULL,
    mrp           NUMERIC(10, 2) NOT NULL,
    is_active     BOOLEAN NOT NULL DEFAULT true,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS skus (
    sku_id      BIGSERIAL PRIMARY KEY,
    product_id  BIGINT NOT NULL REFERENCES products,
    size        TEXT NOT NULL,
    colour      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS warehouses (
    warehouse_id  INT PRIMARY KEY,
    city          TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS inventory (
    sku_id        BIGINT NOT NULL REFERENCES skus,
    warehouse_id  INT NOT NULL REFERENCES warehouses,
    on_hand       INT NOT NULL,
    reserved      INT NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (sku_id, warehouse_id)
);

CREATE TABLE IF NOT EXISTS orders (
    order_id     BIGSERIAL PRIMARY KEY,
    customer_id  BIGINT NOT NULL REFERENCES customers,
    status       TEXT NOT NULL,
    channel      TEXT NOT NULL,
    coupon_code  TEXT,
    placed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS order_items (
    order_item_id  BIGSERIAL PRIMARY KEY,
    order_id       BIGINT NOT NULL REFERENCES orders,
    sku_id         BIGINT NOT NULL REFERENCES skus,
    warehouse_id   INT NOT NULL REFERENCES warehouses,
    qty            INT NOT NULL,
    mrp            NUMERIC(10, 2) NOT NULL,
    selling_price  NUMERIC(10, 2) NOT NULL,
    discount       NUMERIC(10, 2) NOT NULL
);

CREATE TABLE IF NOT EXISTS payments (
    payment_id  BIGSERIAL PRIMARY KEY,
    order_id    BIGINT NOT NULL REFERENCES orders,
    method      TEXT NOT NULL,
    status      TEXT NOT NULL,
    amount      NUMERIC(10, 2) NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS returns (
    return_id      BIGSERIAL PRIMARY KEY,
    order_item_id  BIGINT NOT NULL REFERENCES order_items,
    reason         TEXT NOT NULL,
    status         TEXT NOT NULL,
    requested_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    refund_amount  NUMERIC(10, 2) NOT NULL
);

CREATE INDEX IF NOT EXISTS orders_status_idx ON orders (status, updated_at);

-- full before-image on delete/update for the high-churn tables
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE inventory REPLICA IDENTITY FULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'shop_pub') THEN
        CREATE PUBLICATION shop_pub FOR TABLE
            customers, addresses, products, skus, warehouses, inventory,
            orders, order_items, payments, returns;
    END IF;
END $$;
