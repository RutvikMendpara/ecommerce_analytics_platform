-- the one GMV definition everyone uses; variants are named, not argued about (see marts.yml)
select
    f.order_date,
    p.category,
    p.brand,
    c.city as customer_city,
    count(distinct f.order_id) as orders,
    sum(f.qty) as units,
    sum(f.line_amount) as booked_gmv,
    sum(case when not f.is_cancelled_before_ship then f.line_amount else 0 end) as gmv,
    sum(case when not f.is_cancelled_before_ship then f.line_amount else 0 end) - sum(f.refund_amount) as net_gmv
from {{ ref('fct_order_items') }} as f
inner join {{ ref('dim_product') }} as p on f.product_sk = p.product_sk
inner join {{ ref('dim_customer') }} as c on f.customer_sk = c.customer_sk
group by f.order_date, p.category, p.brand, c.city
