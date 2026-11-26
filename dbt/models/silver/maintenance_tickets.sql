-- Maintenance tickets, typed. A closed_at in the future means the ticket is still open (the export
-- carries the *planned* closing time), so it is treated as open until that time has passed.
select
    record:ticket_id::varchar                                  as ticket_id,
    record:vehicle_id::varchar                                 as vehicle_id,
    try_to_timestamp_ntz(record:opened_at::varchar)            as opened_at,
    try_to_timestamp_ntz(record:closed_at::varchar)            as planned_closed_at,
    iff(planned_closed_at <= current_timestamp()::timestamp_ntz, planned_closed_at, null) as closed_at,
    closed_at is null                                          as is_open,
    round(datediff('minute', opened_at, closed_at) / 60.0, 1)  as repair_hours,
    record:issue::varchar                                      as issue,
    try_to_number(record:cost_eur::varchar, 10, 2)             as cost_eur,
    _loaded_at                                                 as bronze_loaded_at
from {{ source('bronze', 'raw_fleet_maintenance') }}
qualify row_number() over (partition by ticket_id order by _loaded_at desc, _source_file desc) = 1
