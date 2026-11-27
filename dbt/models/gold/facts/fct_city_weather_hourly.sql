{#
  Grain: one row per city per UTC hour with at least one weather observation (Open-Meteo).
  hour_local / date_local use the city's time zone, to line up with trip dates (fct_trips.trip_date_local).
#}
with obs as (
    select * from {{ ref('weather_observations') }}
)

select
    o.city_code,
    date_trunc('hour', o.observed_at_utc)                                          as hour_utc,
    convert_timezone('UTC', c.timezone, date_trunc('hour', o.observed_at_utc))     as hour_local,
    hour_local::date                                                               as date_local,
    count(*)                                                                       as observations,
    avg(o.temperature_c)::number(5, 1)                                             as avg_temperature_c,
    sum(o.precipitation_mm)::number(7, 2)                                          as precipitation_mm,
    max(o.wind_kmh)::number(5, 1)                                                  as max_wind_kmh,
    max(o.precipitation_mm) > 0 or count_if(o.weather_group in ('rain', 'snow', 'storm')) > 0 as is_wet,
    mode(o.weather_group)                                                          as weather_group
from obs o
join {{ ref('dim_city') }} c on c.city_code = o.city_code
group by o.city_code, date_trunc('hour', o.observed_at_utc), c.timezone
