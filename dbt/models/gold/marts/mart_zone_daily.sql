-- Start-zone x day: where demand comes from and what it earns.
with z as (
    select
        trip_date_local::date                    as date_day,
        start_zone_id                            as zone_id,
        city_code,
        count(*)                                 as trips,
        sum(collected_eur)                       as collected_eur,
        avg(duration_min)                        as avg_duration_min,
        count_if(start_zone_id = end_zone_id)    as same_zone_trips
    from {{ ref('fct_trips') }}
    group by 1, 2, 3
)
select
    z.date_day::date                                                                 as date_day,
    z.zone_id::varchar                                                               as zone_id,
    d.zone_name::varchar                                                             as zone_name,
    z.city_code::varchar                                                             as city_code,
    z.trips::number                                                                  as trips,
    div0(z.trips, sum(z.trips) over (partition by z.date_day, z.city_code))::number(9, 4) as share_of_city_trips,
    z.collected_eur::number(18, 2)                                                   as collected_eur,
    z.avg_duration_min::number(9, 1)                                                 as avg_duration_min,
    div0(z.same_zone_trips, z.trips)::number(9, 4)                                   as same_zone_trip_rate
from z
left join {{ ref('dim_zone') }} d on d.zone_id = z.zone_id
