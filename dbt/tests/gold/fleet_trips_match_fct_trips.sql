-- Trips counted per vehicle-day must add up to the trips fact (no vehicle/day lost in the fleet join).
select (select count(*) from {{ ref('fct_trips') }}) as fct_trips,
       (select sum(trips) from {{ ref('fct_vehicle_day') }}) as vehicle_day_trips
having fct_trips <> vehicle_day_trips
