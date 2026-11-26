-- One row per operating city with its tariff.
select
    record:city::varchar(3)                    as city_code,
    record:city_name::varchar                  as city_name,
    record:currency::varchar(3)                as currency,
    record:unlock_fee::varchar::number(10, 2)  as unlock_fee,
    record:per_minute::varchar::number(10, 2)  as price_per_minute
from {{ source('bronze', 'raw_ref_pricing') }}
qualify row_number() over (partition by city_code order by _loaded_at desc, _source_file desc) = 1
