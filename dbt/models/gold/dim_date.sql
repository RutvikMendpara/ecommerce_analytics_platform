select
    date_day,
    year(date_day) as year,
    month(date_day) as month,
    weekofyear(date_day) as week_of_year,
    dayofweek(date_day) in (1, 7) as is_weekend,
    date_day between date '{{ var("sale_start") }}' and date '{{ var("sale_end") }}' as is_sale_day
from (select explode(sequence(date '2025-01-01', date '2027-12-31', interval 1 day)) as date_day)
