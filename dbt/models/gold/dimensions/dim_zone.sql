select
    z.zone_id,
    z.zone_name,
    z.city_code,
    c.city_name,
    z.centroid_lat,
    z.centroid_lon
from {{ ref('zones') }} z
left join {{ ref('cities') }} c using (city_code)
