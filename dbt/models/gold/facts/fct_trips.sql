{#
  Grain: one row per VALID trip (SILVER quarantines the rest), with its payment outcome.
  Payments are 1:1 with trips (tested), so the join cannot fan out.
#}
select
    t.trip_id,
    to_number(to_char(t.trip_date_local, 'YYYYMMDD'))   as date_key,
    t.trip_date_local,
    t.city_code,
    t.start_zone_id,
    t.end_zone_id,
    t.rider_id,
    t.vehicle_id,
    t.started_at_utc,
    t.ended_at_utc,
    hour(t.started_at_local)                            as start_hour_local,
    t.duration_min,
    round(t.distance_m / 1000, 3)                       as distance_km,
    t.currency,
    t.fare_amount,
    t.fare_amount_eur,
    p.payment_id,
    coalesce(p.payment_status, 'missing')               as payment_status,
    p.payment_method,
    p.promo_code,
    iff(p.payment_status = 'succeeded', p.amount_eur, 0) as collected_eur,
    iff(p.payment_status = 'refunded',  p.amount_eur, 0) as refunded_eur,
    iff(p.payment_status = 'failed',    p.amount_eur, 0) as failed_eur,
    p.promo_code is not null                            as used_promo
from {{ ref('trips') }} t
left join {{ ref('payments') }} p on p.trip_id = t.trip_id
where t.is_valid
