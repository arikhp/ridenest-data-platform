-- City x day revenue and demand KPIs (trip date in the city's local time).
select
    trip_date_local::date                                          as date_day,
    city_code::varchar                                             as city_code,
    count(*)::number                                               as trips,
    count(distinct rider_id)::number                               as active_riders,
    count(distinct vehicle_id)::number                             as vehicles_used,
    sum(fare_amount_eur)::number(18, 2)                            as gross_fare_eur,
    sum(collected_eur)::number(18, 2)                              as collected_eur,
    sum(refunded_eur)::number(18, 2)                               as refunded_eur,
    sum(failed_eur)::number(18, 2)                                 as failed_eur,
    div0(sum(collected_eur), sum(fare_amount_eur))::number(9, 4)   as collection_rate,
    avg(fare_amount_eur)::number(18, 2)                            as avg_fare_eur,
    avg(duration_min)::number(9, 1)                                as avg_duration_min,
    avg(distance_km)::number(9, 2)                                 as avg_distance_km,
    count_if(used_promo)::number                                   as promo_trips
from {{ ref('fct_trips') }}
group by 1, 2
