{{ config(severity='warn') }}
-- Data-quality budget: warn when more than 2% of trips are rejected (normal is ~0.8%).
select count_if(not is_valid) / nullif(count(*), 0) as rejected_share
from {{ ref('trips') }}
having rejected_share > 0.02
