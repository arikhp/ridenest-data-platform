{{
  config(
    materialized='incremental',
    unique_key=['city_code', 'observed_at_utc'],
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}
{#
  One row per city per observation time (Open-Meteo, UTC). The 10-minute pull sees each 15-minute model step
  once or twice and backfills add hourly rows: one row per (city, time) is kept, preferring `current` and the
  latest fetch.
#}
with src as (
    select record as r, _source_file, _loaded_at
    from {{ bronze_api_source('raw_api_weather') }}
    {% if is_incremental() %}
    where _loaded_at > (select coalesce(max(bronze_loaded_at), '1900-01-01'::timestamp_ltz) from {{ this }})
    {% endif %}
),

typed as (
    select
        r:city::varchar(3)                                     as city_code,
        try_to_timestamp_ntz(r:observed_at::varchar)           as observed_at_utc,
        r:mode::varchar                                        as source_mode,
        r:interval_s::number                                   as interval_s,
        r:temperature_2m::number(5, 1)                         as temperature_c,
        r:precipitation::number(6, 2)                          as precipitation_mm,
        r:wind_speed_10m::number(5, 1)                         as wind_kmh,
        r:weather_code::number                                 as weather_code,
        case
            when r:weather_code::number = 0                then 'clear'
            when r:weather_code::number between 1 and 3    then 'cloudy'
            when r:weather_code::number in (45, 48)        then 'fog'
            when r:weather_code::number between 51 and 67
              or r:weather_code::number between 80 and 82  then 'rain'
            when r:weather_code::number between 71 and 77
              or r:weather_code::number in (85, 86)        then 'snow'
            when r:weather_code::number >= 95              then 'storm'
            else 'other'
        end                                                    as weather_group,
        try_to_timestamp_ntz(r:fetched_at::varchar)            as fetched_at_utc,
        _source_file                                           as bronze_source_file,
        _loaded_at                                             as bronze_loaded_at
    from src
)

select *
from typed
where city_code is not null and observed_at_utc is not null
qualify row_number() over (
    partition by city_code, observed_at_utc
    order by iff(source_mode = 'current', 0, 1), fetched_at_utc desc, bronze_loaded_at desc
) = 1
