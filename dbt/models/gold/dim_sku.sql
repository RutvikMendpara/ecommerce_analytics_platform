select sku_id, product_id, size, colour
from {{ source('silver', 'skus_current') }}
where not _is_deleted
