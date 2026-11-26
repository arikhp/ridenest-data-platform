-- City x month x issue: maintenance volume, cost and speed, normalised by fleet size.
with tickets as (
    select t.*, v.city_code, date_trunc('month', t.opened_at)::date as month_start
    from {{ ref('maintenance_tickets') }} t
    join {{ ref('dim_vehicle') }} v using (vehicle_id)
),
fleet as (
    select date_trunc('month', snapshot_date)::date as month_start, city_code,
           avg(fleet_size) as avg_fleet_size
    from (select snapshot_date, city_code, count_if(status <> 'retired') as fleet_size
          from {{ ref('fct_vehicle_day') }} group by 1, 2)
    group by 1, 2
),
agg as (
    select month_start, city_code, issue,
           count(*) as tickets, count_if(is_open) as open_tickets,
           sum(cost_eur) as total_cost_eur, avg(repair_hours) as avg_repair_hours
    from tickets
    group by 1, 2, 3
)
select
    a.month_start::date                                          as month_start,
    a.city_code::varchar                                         as city_code,
    a.issue::varchar                                             as issue,
    a.tickets::number                                            as tickets,
    a.open_tickets::number                                       as open_tickets,
    a.total_cost_eur::number(18, 2)                              as total_cost_eur,
    a.avg_repair_hours::number(9, 1)                             as avg_repair_hours,
    f.avg_fleet_size::number(9, 1)                               as avg_fleet_size,
    div0(a.total_cost_eur, f.avg_fleet_size)::number(18, 2)      as cost_per_fleet_vehicle_eur
from agg a
left join fleet f on f.month_start = a.month_start and f.city_code = a.city_code
