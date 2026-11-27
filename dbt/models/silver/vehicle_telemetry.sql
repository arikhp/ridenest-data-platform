{{
  config(
    materialized='incremental',
    unique_key='reading_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
  )
}}
{#
  One row per vehicle reading from the ScootTrack telemetry API, deduplicated and typed (UTC).
  Incremental on BRONZE _loaded_at; late readings simply arrive in a later file and merge in by reading_id.
#}
with src as (
    select record as r, _source_file, _loaded_at
    from {{ bronze_api_source('raw_api_vehicle_telemetry') }}
    {% if is_incremental() %}
    where _loaded_at > (select coalesce(max(bronze_loaded_at), '1900-01-01'::timestamp_ltz) from {{ this }})
    {% endif %}
),

typed as (
    select
        r:reading_id::varchar                                  as reading_id,
        r:vehicle_id::varchar                                  as vehicle_id,
        try_to_timestamp_ntz(r:ts::varchar)                    as reading_ts_utc,
        try_to_timestamp_ntz(r:received_at::varchar)           as received_at_utc,
        datediff('second', reading_ts_utc, received_at_utc)    as delivery_delay_s,
        delivery_delay_s > 600                                 as is_late,
        r:lat::float                                           as lat,
        r:lon::float                                           as lon,
        r:battery_pct::number(3, 0)                            as battery_pct,
        r:status::varchar                                      as status,
        r:speed_kmh::number(5, 1)                              as speed_kmh,
        r:odometer_km::number(10, 1)                           as odometer_km,
        r:firmware::varchar                                    as firmware,
        _source_file                                           as bronze_source_file,
        _loaded_at                                             as bronze_loaded_at
    from src
)

select *
from typed
where reading_id is not null and reading_ts_utc is not null
-- ~0.5% of readings are delivered twice; keep the most recently loaded copy
qualify row_number() over (partition by reading_id order by bronze_loaded_at desc, bronze_source_file desc) = 1
