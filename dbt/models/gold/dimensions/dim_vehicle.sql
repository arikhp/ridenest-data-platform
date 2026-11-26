with data_end as (
    select max(snapshot_date) as as_of_date from {{ ref('vehicle_status_daily') }}
)
select
    v.vehicle_id,
    v.model,
    v.vehicle_type,
    v.city_code,
    v.home_zone_id,
    v.commissioned_on,
    datediff('day', v.commissioned_on, d.as_of_date)   as age_days,
    v.current_status,
    v.current_status = 'retired'                       as is_retired,
    v.last_seen_on
from {{ ref('vehicles') }} v
cross join data_end d
