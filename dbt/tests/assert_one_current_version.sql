-- every customer and product has exactly one current SCD2 version
select 'customer' as dim, customer_id as id, count_if(is_current) as current_versions
from {{ ref('dim_customer') }}
group by customer_id
having count_if(is_current) <> 1

union all

select 'product', product_id, count_if(is_current)
from {{ ref('dim_product') }}
group by product_id
having count_if(is_current) <> 1
