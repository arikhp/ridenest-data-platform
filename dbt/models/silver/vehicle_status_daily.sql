-- One row per vehicle per day (end-of-day fleet snapshot), typed. The fleet export sends strings.
select
    record:vehicle_id::varchar                         as vehicle_id,
    record:snapshot_date::varchar::date                as snapshot_date,
    record:status::varchar                             as status,
    try_to_number(record:battery_pct::varchar)         as battery_pct,
    try_to_date(record:last_service_on::varchar)       as last_service_on,
    datediff('day', last_service_on, snapshot_date)    as days_since_service,
    record:city::varchar(3)                            as city_code,
    _loaded_at                                         as bronze_loaded_at
from {{ source('bronze', 'raw_fleet_vehicles') }}
qualify row_number() over (partition by vehicle_id, snapshot_date order by _loaded_at desc, _source_file desc) = 1
