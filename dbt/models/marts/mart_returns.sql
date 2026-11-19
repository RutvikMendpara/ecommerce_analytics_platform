-- return rate = returned units / delivered units, by brand and size
select
    date_trunc('week', f.order_date) as order_week,
    p.brand,
    s.size,
    sum(case when f.order_status = 'DELIVERED' then f.qty else 0 end) as delivered_units,
    sum(case when f.is_returned then f.qty else 0 end) as returned_units,
    round(
        sum(case when f.is_returned then f.qty else 0 end)
        / nullif(sum(case when f.order_status = 'DELIVERED' then f.qty else 0 end), 0),
        4
    ) as return_rate,
    sum(case when f.return_reason = 'SIZE_TOO_SMALL' then 1 else 0 end) as size_too_small,
    sum(case when f.return_reason = 'SIZE_TOO_LARGE' then 1 else 0 end) as size_too_large
from {{ ref('fct_order_items') }} as f
inner join {{ ref('dim_product') }} as p on f.product_sk = p.product_sk
inner join {{ ref('dim_sku') }} as s on f.sku_id = s.sku_id
group by date_trunc('week', f.order_date), p.brand, s.size
