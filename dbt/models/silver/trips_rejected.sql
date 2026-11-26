{{ config(materialized='view') }}
-- Quarantine view: trips GOLD excludes, with the reason. Use it to monitor source data quality.
select trip_id, dq_issue, city_code, rider_id, vehicle_id, started_at_utc, ended_at_utc, duration_min, end_lat, end_lon
from {{ ref('trips') }}
where not is_valid
