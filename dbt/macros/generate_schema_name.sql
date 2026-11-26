{#
  Schemas are the medallion layers, upper-case, without dbt's default "<target_schema>_" prefix:
    models/silver -> SILVER, models/gold -> GOLD
  CI builds a pull request in isolation by setting DBT_SCHEMA_PREFIX=PR_<n>  ->  PR_<n>_SILVER
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set layer = (custom_schema_name or target.schema) | trim | upper -%}
    {%- set prefix = env_var('DBT_SCHEMA_PREFIX', '') | trim | upper -%}
    {%- if prefix -%}{{ prefix }}_{{ layer }}{%- else -%}{{ layer }}{%- endif -%}
{%- endmacro %}
