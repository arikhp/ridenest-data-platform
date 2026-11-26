{#
  Post-hook: tag the built object with its medallion layer, and every column whose YAML has
  `config: {meta: {pii: low|high}}` with the PII tag. Tags live in <db>.GOVERNANCE (created by Terraform).
#}
{% macro apply_catalog_tags(layer) -%}
    {%- if execute and model.config.materialized != 'ephemeral' -%}
        {%- set kind = 'view' if model.config.materialized == 'view' else 'table' -%}
        {%- set gov = target.database ~ '.GOVERNANCE' -%}
        alter {{ kind }} {{ this }} set tag {{ gov }}.LAYER = '{{ layer }}';
        {%- for col_name, col in model.columns.items() -%}
            {#- dbt >= 1.10: column meta lives under config.meta (older projects: top-level meta) -#}
            {%- set pii = (col.get('config') or {}).get('meta', {}).get('pii') or (col.get('meta') or {}).get('pii') -%}
            {%- if pii %}
        alter {{ kind }} {{ this }} modify column {{ col_name }} set tag {{ gov }}.PII = '{{ pii }}';
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}
{%- endmacro %}
