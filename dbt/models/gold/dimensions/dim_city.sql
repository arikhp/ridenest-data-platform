select
    c.city_code,
    c.city_name,
    case c.city_code when 'TLV' then 'Israel' when 'BER' then 'Germany' when 'LIS' then 'Portugal' end as country,
    case c.city_code when 'TLV' then 'Asia/Jerusalem' when 'BER' then 'Europe/Berlin' when 'LIS' then 'Europe/Lisbon' end as timezone,
    c.currency,
    c.unlock_fee,
    c.price_per_minute,
    round(c.unlock_fee * fx.rate_to_eur, 2)        as unlock_fee_eur,
    round(c.price_per_minute * fx.rate_to_eur, 4)  as price_per_minute_eur
from {{ ref('cities') }} c
left join {{ ref('fx_rates_to_eur') }} fx on fx.currency = c.currency
