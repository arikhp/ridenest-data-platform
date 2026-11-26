{{
  config(
    materialized='incremental',
    unique_key='event_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}
{#
  One row per app event, deduplicated, typed, timestamps normalised to UTC.
  Incremental: only BRONZE rows loaded since the last run are processed. A re-loaded BRONZE day
  (daily partition replace / backfill) gets a newer _LOADED_AT and is simply merged again.
#}
with src as (
    select record as r, _source_file, _loaded_at
    from {{ source('bronze', 'raw_trip_events') }}
    {% if is_incremental() %}
    where _loaded_at > (select coalesce(max(bronze_loaded_at), '1900-01-01'::timestamp_ltz) from {{ this }})
    {% endif %}
),

typed as (
    select
        r:event_id::varchar                                   as event_id,
        r:event_type::varchar                                 as event_type,
        r:trip_id::varchar                                    as trip_id,
        r:rider_id::varchar                                   as rider_id,
        r:vehicle_id::varchar                                 as vehicle_id,
        r:city::varchar                                       as city_code,
        try_to_timestamp_tz(r:ts::varchar)                    as event_ts_local,
        convert_timezone('UTC', event_ts_local)::timestamp_ntz as event_ts_utc,
        -- the device reports (0,0) when it has no GPS fix
        (coalesce(r:lat::float, 0) = 0 and coalesce(r:lon::float, 0) = 0) as is_gps_missing,
        iff(is_gps_missing, null, r:lat::float)               as lat,
        iff(is_gps_missing, null, r:lon::float)               as lon,
        r:battery_pct::number(3, 0)                           as battery_pct,
        r:distance_m::number(10, 0)                           as distance_m,
        r:fare_amount::number(10, 2)                          as fare_amount,
        r:currency::varchar(3)                                as currency,
        r:app_version::varchar                                as app_version,
        _source_file                                          as bronze_source_file,
        _loaded_at                                            as bronze_loaded_at
    from src
)

select *
from typed
where event_id is not null
-- ~1% of events are delivered twice; keep the most recently loaded copy
qualify row_number() over (partition by event_id order by bronze_loaded_at desc, bronze_source_file desc) = 1
