select
    payment_id,
    order_id,
    method,
    status,
    cast(amount as decimal(10, 2)) as amount
from {{ source('silver', 'payments_current') }}
where not _is_deleted
