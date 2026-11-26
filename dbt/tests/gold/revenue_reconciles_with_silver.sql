-- GOLD must not gain or lose trips or money versus SILVER (catches join fan-out / dropped rows).
with silver as (
    select count(*) as trips, sum(t.fare_amount_eur) as fare_eur,
           sum(iff(p.payment_status = 'succeeded', p.amount_eur, 0)) as collected_eur
    from {{ ref('trips') }} t left join {{ ref('payments') }} p on p.trip_id = t.trip_id
    where t.is_valid
),
gold as (
    select sum(trips) as trips, sum(gross_fare_eur) as fare_eur, sum(collected_eur) as collected_eur
    from {{ ref('mart_revenue_daily') }}
)
select s.*, g.trips as gold_trips, g.fare_eur as gold_fare_eur, g.collected_eur as gold_collected_eur
from silver s cross join gold g
where s.trips <> g.trips or abs(s.fare_eur - g.fare_eur) > 1 or abs(s.collected_eur - g.collected_eur) > 1
