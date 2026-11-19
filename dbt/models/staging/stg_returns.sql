select
    return_id,
    order_item_id,
    reason,
    status,
    cast(requested_at as timestamp) as requested_at,
    cast(refund_amount as decimal(10, 2)) as refund_amount
from {{ source('silver', 'returns_current') }}
where not _is_deleted
