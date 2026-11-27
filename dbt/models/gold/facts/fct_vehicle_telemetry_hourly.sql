{{
  config(
    materialized='incremental',
    unique_key=['vehicle_id', 'hour_utc'],
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}
{#
  Grain: one row per vehicle per UTC hour with at least one telemetry reading.
  Incremental: hours that received new (or late) readings since the last run are recomputed in full.
#}
with readings as (
    select * from {{ ref('vehicle_telemetry') }}
),

{% if is_incremental() %}
touched as (
    select distinct vehicle_id, date_trunc('hour', reading_ts_utc) as hour_utc
    from readings
    where bronze_loaded_at > (select coalesce(max(last_loaded_at), '1900-01-01'::timestamp_ltz) from {{ this }})
),
{% endif %}

hourly as (
    select
        r.vehicle_id,
        date_trunc('hour', r.reading_ts_utc)                               as hour_utc,
        count(*)                                                           as readings,
        count_if(r.is_late)                                                as late_readings,
        avg(r.battery_pct)::number(5, 1)                                   as avg_battery_pct,
        min(r.battery_pct)                                                 as min_battery_pct,
        (count_if(r.status = 'in_ride') / count(*))::number(5, 4)          as in_ride_share,
        (count_if(r.status = 'available') / count(*))::number(5, 4)        as available_share,
        (count_if(r.status = 'low_battery') / count(*))::number(5, 4)      as low_battery_share,
        greatest(max(r.odometer_km) - min(r.odometer_km), 0)::number(9, 1) as km_driven,
        max_by(r.status, r.reading_ts_utc)                                 as last_status,
        max_by(r.firmware, r.reading_ts_utc)                               as firmware,
        max(r.bronze_loaded_at)                                            as last_loaded_at
    from readings r
    {% if is_incremental() %}
    join touched t on t.vehicle_id = r.vehicle_id and t.hour_utc = date_trunc('hour', r.reading_ts_utc)
    {% endif %}
    group by 1, 2
)

select
    h.vehicle_id,
    h.hour_utc,
    to_number(to_char(h.hour_utc, 'YYYYMMDD'))  as date_key_utc,
    v.city_code,
    v.vehicle_type,
    h.readings,
    h.late_readings,
    h.avg_battery_pct,
    h.min_battery_pct,
    h.in_ride_share,
    h.available_share,
    h.low_battery_share,
    h.km_driven,
    h.last_status,
    h.firmware,
    h.last_loaded_at
from hourly h
left join {{ ref('dim_vehicle') }} v on v.vehicle_id = h.vehicle_id
