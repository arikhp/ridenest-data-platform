{#
  BRONZE API tables are created by Terraform (envs/<env>/snowflake). Until that has run in an environment (e.g. a
  PR's dbt CI before the infra change is applied), read from an empty relation with the same columns instead of
  failing, so the rest of the project keeps building.
#}
{% macro bronze_api_source(table_name) -%}
    {%- set src = source('bronze', table_name) -%}
    {%- set rel = adapter.get_relation(database=src.database, schema=src.schema, identifier=src.identifier) if execute else none -%}
    {%- if rel is not none or not execute -%}
        {{ src }}
    {%- else -%}
        {{ log("BRONZE." ~ table_name ~ " does not exist yet; building from an empty set", info=true) }}
        (select null::variant as record, null::varchar as _source_file, null::number as _file_row,
                null::timestamp_ntz as _file_last_modified, null::timestamp_ltz as _loaded_at
         limit 0)
    {%- endif -%}
{%- endmacro %}
