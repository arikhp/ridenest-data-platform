select
    record:code::varchar                 as promo_code,
    record:discount_pct::number(3, 0)    as discount_pct,
    record:valid_from::date              as valid_from,
    record:valid_to::date                as valid_to
from {{ source('bronze', 'raw_billing_promo_codes') }}
qualify row_number() over (partition by promo_code order by _loaded_at desc, _source_file desc) = 1
