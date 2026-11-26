-- One row per payment (latest loaded version), typed, with the amount in EUR.
with latest as (
    select record as r, _loaded_at
    from {{ source('bronze', 'raw_billing_payments') }}
    qualify row_number() over (partition by record:payment_id::varchar order by _loaded_at desc, _source_file desc) = 1
)

select
    r:payment_id::varchar                    as payment_id,
    r:rider_id::varchar                      as rider_id,
    r:trip_id::varchar                       as trip_id,
    r:amount::number(10, 2)                  as amount,
    r:currency::varchar(3)                   as currency,
    round(amount * fx.rate_to_eur, 2)        as amount_eur,
    r:method::varchar                        as payment_method,
    r:status::varchar                        as payment_status,
    payment_status = 'succeeded'             as is_successful,
    nullif(r:promo_code::varchar, '')        as promo_code,
    r:paid_at::timestamp_ntz                 as paid_at_utc,
    _loaded_at                               as bronze_loaded_at
from latest
left join {{ ref('fx_rates_to_eur') }} fx on fx.currency = r:currency::varchar
