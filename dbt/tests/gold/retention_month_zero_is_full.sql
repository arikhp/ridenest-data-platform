-- By definition every rider is active in the month of their first trip.
select * from {{ ref('mart_rider_retention_monthly') }}
where months_since_first_trip = 0 and retention_rate <> 1
