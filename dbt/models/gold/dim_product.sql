-- SCD2 on brand, category, mrp and is_active, from the CDC change history
with versions as (
    select
        product_id,
        brand,
        category,
        sub_category,
        gender,
        cast(mrp as decimal(10, 2)) as mrp,
        is_active,
        _lsn,
        _source_ts,
        row_number() over (partition by product_id order by _lsn) as version,
        lead(_source_ts) over (partition by product_id order by _lsn) as next_change_ts
    from {{ source('silver', 'products_changes') }}
    where not _is_deleted
)

select
    md5(concat_ws('|', cast(product_id as string), cast(_lsn as string))) as product_sk,
    product_id,
    brand,
    category,
    sub_category,
    gender,
    mrp,
    is_active,
    version,
    case when version = 1 then timestamp '1900-01-01' else _source_ts end as valid_from,
    coalesce(next_change_ts, timestamp '9999-12-31') as valid_to,
    next_change_ts is null as is_current
from versions
