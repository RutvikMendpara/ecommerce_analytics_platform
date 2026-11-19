-- one row per order line; customer and product versions are the ones valid when the order was placed
with shipped as (
    select order_id, min(_source_ts) as shipped_at
    from {{ source('silver', 'orders_changes') }}
    where status = 'SHIPPED'
    group by order_id
)

select
    i.order_item_id,
    i.order_id,
    o.customer_id,
    c.customer_sk,
    i.sku_id,
    s.product_id,
    p.product_sk,
    i.warehouse_id,
    o.placed_at,
    cast(o.placed_at as date) as order_date,
    o.status as order_status,
    o.channel,
    o.coupon_code,
    i.qty,
    i.mrp,
    i.selling_price,
    i.discount,
    i.selling_price * i.qty as line_amount,
    o.status = 'CANCELLED' as is_cancelled,
    o.status = 'CANCELLED' and sh.shipped_at is null as is_cancelled_before_ship,
    r.return_id is not null as is_returned,
    r.reason as return_reason,
    case when r.status = 'REFUNDED' then r.refund_amount else 0 end as refund_amount
from {{ ref('stg_order_items') }} as i
inner join {{ ref('stg_orders') }} as o on i.order_id = o.order_id
inner join {{ ref('dim_sku') }} as s on i.sku_id = s.sku_id
left join {{ ref('dim_customer') }} as c
    on o.customer_id = c.customer_id and o.placed_at >= c.valid_from and o.placed_at < c.valid_to
left join {{ ref('dim_product') }} as p
    on s.product_id = p.product_id and o.placed_at >= p.valid_from and o.placed_at < p.valid_to
left join {{ ref('stg_returns') }} as r on i.order_item_id = r.order_item_id
left join shipped as sh on i.order_id = sh.order_id
