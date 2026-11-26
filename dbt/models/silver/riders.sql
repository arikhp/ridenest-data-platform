-- Current state of every rider (latest billing snapshot). Contains PII (see column meta / PII tag).
select
    record:rider_id::varchar             as rider_id,
    record:full_name::varchar            as full_name,
    record:email::varchar                as email,
    record:phone::varchar                as phone,
    record:home_city::varchar(3)         as home_city_code,
    record:signup_at::timestamp_ntz      as signup_at_utc,
    to_date(signup_at_utc)               as signup_date,
    record:plan::varchar                 as plan,
    record:marketing_opt_in::boolean     as marketing_opt_in,
    _loaded_at                           as bronze_loaded_at
from {{ source('bronze', 'raw_billing_riders') }}
qualify row_number() over (partition by rider_id order by _loaded_at desc, _source_file desc) = 1
