{#
  One row per rider, WITHOUT personal data (name/email/phone stay in SILVER, PII-tagged).
  Status is evaluated "as of" the last day with trips in the data, not today's date,
  so the mock history stays meaningful.
#}
with trips as (
    select rider_id, trip_date_local, fare_amount_eur from {{ ref('trips') }} where is_valid
),
paid as (
    select rider_id, sum(iff(is_successful, amount_eur, 0)) as lifetime_paid_eur from {{ ref('payments') }} group by 1
),
agg as (
    select rider_id, min(trip_date_local) as first_trip_date, max(trip_date_local) as last_trip_date, count(*) as lifetime_trips
    from trips group by 1
),
data_end as (
    select max(trip_date_local) as as_of_date from trips
)
select
    r.rider_id,
    r.home_city_code,
    r.plan,
    r.signup_date,
    date_trunc('month', r.signup_date)::date                 as signup_month,
    r.marketing_opt_in,
    a.first_trip_date,
    date_trunc('month', a.first_trip_date)::date             as first_trip_month,
    a.last_trip_date,
    coalesce(a.lifetime_trips, 0)                            as lifetime_trips,
    coalesce(p.lifetime_paid_eur, 0)                         as lifetime_paid_eur,
    datediff('day', a.last_trip_date, d.as_of_date)          as days_since_last_trip,
    case
        when a.last_trip_date is null              then 'never_rode'
        when days_since_last_trip <= 30            then 'active'
        when days_since_last_trip <= 90            then 'lapsed'
        else 'churned'
    end                                                      as rider_status,
    d.as_of_date                                             as status_as_of
from {{ ref('riders') }} r
left join agg a  using (rider_id)
left join paid p using (rider_id)
cross join data_end d
