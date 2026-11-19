select
    sku_id,
    warehouse_id,
    cast(on_hand as int) as on_hand,
    cast(reserved as int) as reserved,
    cast(on_hand as int) - cast(reserved as int) as available,
    cast(updated_at as timestamp) as updated_at
from {{ source('silver', 'inventory_current') }}
where not _is_deleted
