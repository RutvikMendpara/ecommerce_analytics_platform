select warehouse_id, city
from {{ source('silver', 'warehouses_current') }}
where not _is_deleted
