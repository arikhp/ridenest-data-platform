-- A trip marked valid must end after it starts, have both zones and a non-negative fare.
select trip_id, duration_min, start_zone_id, end_zone_id, fare_amount
from {{ ref('trips') }}
where is_valid
  and (duration_min <= 0 or start_zone_id is null or end_zone_id is null or fare_amount < 0)
