select
    r.return_id,
    r.order_item_id,
    f.order_id,
    f.customer_sk,
    f.product_sk,
    f.sku_id,
    f.warehouse_id,
    f.order_date,
    r.reason,
    r.status,
    r.requested_at,
    r.refund_amount
from {{ ref('stg_returns') }} as r
inner join {{ ref('fct_order_items') }} as f on r.order_item_id = f.order_item_id
