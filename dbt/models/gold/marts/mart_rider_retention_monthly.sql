{#
  Monthly cohort retention: riders grouped by the month of their FIRST trip (and home city);
  retention_rate = share of the cohort that rode again N months later.
  The first month of history is left-censored (riders who started before the data window land
  in it), so it is flagged with is_left_censored_cohort and should be excluded from analysis.
#}
with activity as (
    select distinct rider_id, date_trunc('month', trip_date_local)::date as activity_month
    from {{ ref('fct_trips') }}
),
cohorts as (
    select rider_id, first_trip_month as cohort_month, home_city_code
    from {{ ref('dim_rider') }}
    where first_trip_month is not null
),
sizes as (
    select cohort_month, home_city_code, count(*) as cohort_size from cohorts group by 1, 2
),
retained as (
    select c.cohort_month, c.home_city_code,
           datediff('month', c.cohort_month, a.activity_month) as months_since_first_trip,
           count(distinct a.rider_id) as active_riders
    from cohorts c
    join activity a on a.rider_id = c.rider_id
    group by 1, 2, 3
)
select
    r.cohort_month::date                                           as cohort_month,
    r.home_city_code::varchar                                      as home_city_code,
    r.months_since_first_trip::number                              as months_since_first_trip,
    s.cohort_size::number                                          as cohort_size,
    r.active_riders::number                                        as active_riders,
    div0(r.active_riders, s.cohort_size)::number(9, 4)             as retention_rate,
    (r.cohort_month = min(r.cohort_month) over ())::boolean        as is_left_censored_cohort
from retained r
join sizes s on s.cohort_month = r.cohort_month and s.home_city_code = r.home_city_code
