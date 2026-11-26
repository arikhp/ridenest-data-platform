{#
  One row per trip: start + end event paired, duration, zones, fare.
  Bad trips are NOT dropped: `dq_issue` says what is wrong and `is_valid` is false, so GOLD can
  filter them while analysts can still inspect them (see the trips_rejected view).
#}
with events as (
    select * from {{ ref('trip_events') }}
),

started as (
    select trip_id, rider_id, vehicle_id, city_code,
           event_ts_utc as started_at_utc, event_ts_local as started_at_local,
           lat as start_lat, lon as start_lon, battery_pct as start_battery_pct
    from events where event_type = 'trip_started'
),

ended as (
    select trip_id, rider_id, vehicle_id, city_code,
           event_ts_utc as ended_at_utc, lat as end_lat, lon as end_lon, is_gps_missing as end_gps_missing,
           battery_pct as end_battery_pct, distance_m, fare_amount, currency, app_version
    from events where event_type = 'trip_ended'
),

paired as (
    select
        coalesce(s.trip_id, e.trip_id)          as trip_id,
        coalesce(s.rider_id, e.rider_id)        as rider_id,
        coalesce(s.vehicle_id, e.vehicle_id)    as vehicle_id,
        coalesce(s.city_code, e.city_code)      as city_code,
        s.started_at_utc,
        s.started_at_local,
        e.ended_at_utc,
        datediff('second', s.started_at_utc, e.ended_at_utc) / 60.0 as duration_min,
        s.start_lat, s.start_lon, e.end_lat, e.end_lon,
        s.start_battery_pct, e.end_battery_pct,
        e.distance_m, e.fare_amount, e.currency, e.app_version,
        coalesce(e.end_gps_missing, false)      as end_gps_missing,
        s.trip_id is not null                   as has_start,
        e.trip_id is not null                   as has_end
    from started s
    full outer join ended e on s.trip_id = e.trip_id
),

zones as (
    select * from {{ ref('zones') }}
),

start_zone as (
    select p.trip_id, z.zone_id
    from paired p join zones z on z.city_code = p.city_code
    where p.start_lat is not null
    qualify row_number() over (partition by p.trip_id order by haversine(p.start_lat, p.start_lon, z.centroid_lat, z.centroid_lon)) = 1
),

end_zone as (
    select p.trip_id, z.zone_id
    from paired p join zones z on z.city_code = p.city_code
    where p.end_lat is not null
    qualify row_number() over (partition by p.trip_id order by haversine(p.end_lat, p.end_lon, z.centroid_lat, z.centroid_lon)) = 1
),

final as (
    select
        p.trip_id,
        p.rider_id,
        p.vehicle_id,
        p.city_code,
        sz.zone_id                          as start_zone_id,
        ez.zone_id                          as end_zone_id,
        p.started_at_utc,
        p.started_at_local,
        to_date(p.started_at_local)         as trip_date_local,
        p.ended_at_utc,
        round(p.duration_min, 2)            as duration_min,
        p.distance_m,
        p.start_lat, p.start_lon, p.end_lat, p.end_lon,
        p.start_battery_pct, p.end_battery_pct,
        p.fare_amount,
        p.currency,
        round(p.fare_amount * fx.rate_to_eur, 2) as fare_amount_eur,
        p.app_version,
        case
            when not p.has_start          then 'missing_start'
            when not p.has_end            then 'missing_end'
            when p.duration_min <= 0      then 'non_positive_duration'
            when p.duration_min > 180     then 'implausible_duration'
            when p.end_gps_missing        then 'missing_end_gps'
        end                                 as dq_issue,
        dq_issue is null                    as is_valid
    from paired p
    left join start_zone sz on sz.trip_id = p.trip_id
    left join end_zone ez on ez.trip_id = p.trip_id
    left join {{ ref('fx_rates_to_eur') }} fx on fx.currency = p.currency
)

select * from final
