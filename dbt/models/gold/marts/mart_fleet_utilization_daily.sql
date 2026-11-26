-- City x day fleet KPIs. "Deployable" = not retired and not in maintenance.
-- trips_per_deployable_vehicle (TVD) is the core micromobility efficiency metric.
select
    snapshot_date::date                                                        as date_day,
    city_code::varchar                                                         as city_code,
    count_if(status <> 'retired')::number                                      as fleet_size,
    count_if(is_deployable)::number                                            as deployable_vehicles,
    count_if(status = 'maintenance')::number                                   as vehicles_in_maintenance,
    sum(trips)::number                                                         as trips,
    div0(sum(trips), count_if(is_deployable))::number(9, 2)                    as trips_per_deployable_vehicle,
    avg(iff(is_deployable, utilization_pct, null))::number(9, 4)               as avg_utilization_pct,
    div0(sum(collected_eur), count_if(is_deployable))::number(18, 2)           as collected_eur_per_deployable_vehicle,
    avg(iff(is_deployable, battery_pct, null))::number(9, 1)                   as avg_battery_pct
from {{ ref('fct_vehicle_day') }}
group by 1, 2
