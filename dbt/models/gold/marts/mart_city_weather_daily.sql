-- City x local day: weather (Open-Meteo, from the 10-minute API pull) next to demand and revenue.
with weather as (
    select
        date_local,
        city_code,
        count(*)                                  as weather_hours,
        avg(avg_temperature_c)                    as avg_temperature_c,
        max(avg_temperature_c)                    as max_temperature_c,
        sum(precipitation_mm)                     as precipitation_mm,
        count_if(is_wet)                          as wet_hours,
        mode(weather_group)                       as weather_group
    from {{ ref('fct_city_weather_hourly') }}
    group by 1, 2
)

select
    w.date_local::date                                  as date_day,
    w.city_code::varchar                                as city_code,
    w.weather_hours::number                             as weather_hours,
    w.avg_temperature_c::number(5, 1)                   as avg_temperature_c,
    w.max_temperature_c::number(5, 1)                   as max_temperature_c,
    w.precipitation_mm::number(7, 2)                    as precipitation_mm,
    w.wet_hours::number                                 as wet_hours,
    (w.wet_hours >= 3)::boolean                         as is_rainy_day,
    w.weather_group::varchar                            as weather_group,
    coalesce(r.trips, 0)::number                        as trips,
    coalesce(r.collected_eur, 0)::number(18, 2)         as collected_eur,
    r.avg_duration_min::number(9, 1)                    as avg_duration_min
from weather w
left join {{ ref('mart_revenue_daily') }} r
    on r.date_day = w.date_local and r.city_code = w.city_code
