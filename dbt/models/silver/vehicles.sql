-- Current attributes of every vehicle (from its most recent daily snapshot).
select
    vehicle_id,
    record:model::varchar                              as model,
    record:vehicle_type::varchar                       as vehicle_type,
    record:city::varchar(3)                            as city_code,
    record:home_zone_id::varchar                       as home_zone_id,
    try_to_date(record:commissioned_on::varchar)       as commissioned_on,
    snapshot_date                                      as last_seen_on,
    status                                             as current_status
from (
    select record, record:vehicle_id::varchar as vehicle_id, record:snapshot_date::varchar::date as snapshot_date,
           record:status::varchar as status, _loaded_at, _source_file
    from {{ source('bronze', 'raw_fleet_vehicles') }}
)
qualify row_number() over (partition by vehicle_id order by snapshot_date desc, _loaded_at desc, _source_file desc) = 1
