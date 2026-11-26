{#
  Grain: one row per vehicle per day (end-of-day fleet snapshot) with that day's riding.
  utilization_pct = share of the 24h the vehicle was on a trip.
#}
with rides as (
    select vehicle_id, trip_date_local as snapshot_date,
           count(*) as trips, sum(duration_min) as ride_minutes, sum(collected_eur) as collected_eur
    from {{ ref('fct_trips') }}
    group by 1, 2
)
select
    s.vehicle_id,
    s.snapshot_date,
    to_number(to_char(s.snapshot_date, 'YYYYMMDD'))  as date_key,
    s.city_code,
    s.status,
    s.status not in ('retired', 'maintenance')       as is_deployable,
    s.battery_pct,
    s.days_since_service,
    coalesce(r.trips, 0)                             as trips,
    coalesce(r.ride_minutes, 0)                      as ride_minutes,
    coalesce(r.collected_eur, 0)                     as collected_eur,
    round(coalesce(r.ride_minutes, 0) / 1440, 4)     as utilization_pct
from {{ ref('vehicle_status_daily') }} s
left join rides r using (vehicle_id, snapshot_date)
