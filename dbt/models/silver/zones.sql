-- Operating zones with their centroid (used to assign trips to zones).
select
    record:zone_id::varchar        as zone_id,
    record:city::varchar(3)        as city_code,
    record:name::varchar           as zone_name,
    record:lat::varchar::float     as centroid_lat,
    record:lon::varchar::float     as centroid_lon
from {{ source('bronze', 'raw_ref_zones') }}
qualify row_number() over (partition by zone_id order by _loaded_at desc, _source_file desc) = 1
