select
    order_id,
    customer_id,
    status,
    channel,
    coupon_code,
    cast(placed_at as timestamp) as placed_at,
    cast(updated_at as timestamp) as updated_at
from {{ source('silver', 'orders_current') }}
where not _is_deleted
