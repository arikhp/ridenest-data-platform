-- Calendar dimension. Weekend follows the operating cities' busiest days (Fri-Sun) as well as Sat/Sun.
with spine as (
    {{ dbt_utils.date_spine(datepart="day", start_date="'2024-01-01'::date", end_date="'2028-01-01'::date") }}
)
select
    date_day::date                                   as date_day,
    to_number(to_char(date_day, 'YYYYMMDD'))         as date_key,
    year(date_day)                                   as year,
    quarter(date_day)                                as quarter,
    month(date_day)                                  as month,
    monthname(date_day)                              as month_name_short,
    date_trunc('month', date_day)::date              as month_start,
    weekiso(date_day)                                as iso_week,
    date_trunc('week', date_day)::date               as week_start,
    dayofweekiso(date_day)                           as iso_day_of_week,
    dayname(date_day)                                as day_name_short,
    dayofweekiso(date_day) in (6, 7)                 as is_weekend,
    dayofweekiso(date_day) in (5, 6, 7)              as is_peak_weekend,
    case when month(date_day) in (12, 1, 2) then 'winter'
         when month(date_day) in (3, 4, 5)  then 'spring'
         when month(date_day) in (6, 7, 8)  then 'summer'
         else 'autumn' end                           as season
from spine
