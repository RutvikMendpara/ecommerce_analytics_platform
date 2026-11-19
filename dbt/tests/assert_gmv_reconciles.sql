-- mart totals match the fact table, and net_gmv <= gmv <= booked_gmv
with mart as (
    select sum(booked_gmv) as booked_gmv, sum(gmv) as gmv, sum(net_gmv) as net_gmv
    from {{ ref('mart_gmv_daily') }}
),

fct as (
    select sum(line_amount) as booked_gmv from {{ ref('fct_order_items') }}
)

select *
from mart cross join fct
where mart.booked_gmv <> fct.booked_gmv
   or mart.gmv > mart.booked_gmv
   or mart.net_gmv > mart.gmv
