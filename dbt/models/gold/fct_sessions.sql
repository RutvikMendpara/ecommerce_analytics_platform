-- one row per clickstream session and how far down the funnel it got
select
    session_id,
    min(event_ts) as started_at,
    cast(min(event_ts) as date) as session_date,
    max(event_ts) as ended_at,
    max(customer_id) as customer_id,
    min_by(device, event_ts) as device,
    min_by(city, event_ts) as city,
    min_by(brand, event_ts) as brand,
    min_by(size, event_ts) as size,
    max(step) as furthest_step,
    max(event_type = 'product_view') as viewed_product,
    max(event_type = 'size_chart_open') as opened_size_chart,
    max(event_type = 'add_to_cart') as added_to_cart,
    max(event_type = 'checkout_start') as started_checkout,
    max(event_type = 'payment_start') as started_payment,
    max(event_type = 'order_placed') as placed_order
from {{ source('silver', 'clickstream_events') }}
group by session_id
