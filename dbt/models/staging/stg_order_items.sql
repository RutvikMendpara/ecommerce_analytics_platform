select
    order_item_id,
    order_id,
    sku_id,
    warehouse_id,
    cast(qty as int) as qty,
    cast(mrp as decimal(10, 2)) as mrp,
    cast(selling_price as decimal(10, 2)) as selling_price,
    cast(discount as decimal(10, 2)) as discount
from {{ source('silver', 'order_items_current') }}
where not _is_deleted
