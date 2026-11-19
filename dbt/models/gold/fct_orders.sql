-- one row per order, with when it reached each status (from the CDC history)
with status_times as (
    select
        order_id,
        min(case when status = 'CONFIRMED' then _source_ts end) as confirmed_at,
        min(case when status = 'CANCELLED' then _source_ts end) as cancelled_at,
        min(case when status = 'SHIPPED' then _source_ts end) as shipped_at,
        min(case when status = 'DELIVERED' then _source_ts end) as delivered_at
    from {{ source('silver', 'orders_changes') }}
    group by order_id
),

items as (
    select
        order_id,
        count(*) as item_count,
        sum(line_amount) as order_amount,
        sum(discount * qty) as discount_amount,
        sum(refund_amount) as refund_amount
    from {{ ref('fct_order_items') }}
    group by order_id
)

select
    o.order_id,
    o.customer_id,
    o.placed_at,
    cast(o.placed_at as date) as order_date,
    o.status,
    o.channel,
    o.coupon_code,
    i.item_count,
    i.order_amount,
    i.discount_amount,
    i.refund_amount,
    p.method as payment_method,
    p.status as payment_status,
    st.confirmed_at,
    st.cancelled_at,
    st.shipped_at,
    st.delivered_at
from {{ ref('stg_orders') }} as o
left join items as i on o.order_id = i.order_id
left join {{ ref('stg_payments') }} as p on o.order_id = p.order_id
left join status_times as st on o.order_id = st.order_id
