select
    session_date,
    device,
    brand,
    size,
    count(*) as sessions,
    sum(cast(viewed_product as int)) as viewed_product,
    sum(cast(opened_size_chart as int)) as opened_size_chart,
    sum(cast(added_to_cart as int)) as added_to_cart,
    sum(cast(started_checkout as int)) as started_checkout,
    sum(cast(started_payment as int)) as started_payment,
    sum(cast(placed_order as int)) as placed_order,
    round(sum(cast(placed_order as int)) / count(*), 4) as conversion_rate,
    round(1 - sum(cast(placed_order as int)) / nullif(sum(cast(added_to_cart as int)), 0), 4) as cart_abandonment_rate
from {{ ref('fct_sessions') }}
group by session_date, device, brand, size
