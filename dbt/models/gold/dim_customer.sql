-- SCD2 built from the CDC change history, so every tier/city change is a version
-- (a nightly snapshot would miss changes that happen between runs)
with versions as (
    select
        customer_id,
        city,
        tier,
        _lsn,
        _source_ts,
        row_number() over (partition by customer_id order by _lsn) as version,
        lead(_source_ts) over (partition by customer_id order by _lsn) as next_change_ts
    from {{ source('silver', 'customers_changes') }}
    where not _is_deleted
)

select
    md5(concat_ws('|', cast(customer_id as string), cast(_lsn as string))) as customer_sk,
    customer_id,
    city,
    tier,
    version,
    -- first version covers everything before CDC started
    case when version = 1 then timestamp '1900-01-01' else _source_ts end as valid_from,
    coalesce(next_change_ts, timestamp '9999-12-31') as valid_to,
    next_change_ts is null as is_current
from versions
