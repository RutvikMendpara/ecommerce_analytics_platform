-- SKUs that are out of stock right now in a warehouse, and how many units were oversold
with history as (
    select
        sku_id,
        warehouse_id,
        _source_ts,
        cast(on_hand as int) - cast(reserved as int) as available,
        lag(cast(on_hand as int) - cast(reserved as int)) over (
            partition by sku_id, warehouse_id order by _lsn
        ) as prev_available
    from {{ source('silver', 'inventory_changes') }}
    where not _is_deleted
),

out_since as (
    select
        sku_id,
        warehouse_id,
        coalesce(max(case when available <= 0 and prev_available > 0 then _source_ts end), min(_source_ts))
            as out_of_stock_since
    from history
    group by sku_id, warehouse_id
),

last_hour_sales as (
    select sku_id, warehouse_id, sum(qty) as units_last_hour
    from {{ ref('fct_order_items') }}
    where placed_at >= current_timestamp() - interval 1 hour
    group by sku_id, warehouse_id
)

select
    i.sku_id,
    i.warehouse_id,
    w.city as warehouse_city,
    p.brand,
    p.category,
    s.size,
    i.on_hand,
    i.reserved,
    i.available,
    greatest(-i.available, 0) as oversold_units,
    o.out_of_stock_since,
    coalesce(l.units_last_hour, 0) as units_last_hour
from {{ ref('stg_inventory') }} as i
inner join {{ ref('dim_sku') }} as s on i.sku_id = s.sku_id
inner join {{ ref('dim_product') }} as p on s.product_id = p.product_id and p.is_current
inner join {{ ref('dim_warehouse') }} as w on i.warehouse_id = w.warehouse_id
left join out_since as o on i.sku_id = o.sku_id and i.warehouse_id = o.warehouse_id
left join last_hour_sales as l on i.sku_id = l.sku_id and i.warehouse_id = l.warehouse_id
where i.available <= 0
