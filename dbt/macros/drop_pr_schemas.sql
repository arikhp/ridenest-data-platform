{#
  CI cleanup: drop the schemas a pull request built (PR_<n>_SILVER, PR_<n>_GOLD) in DEV.
  Usage: dbt run-operation drop_pr_schemas --args '{prefix: PR_12}'
  Refuses anything that is not a PR_ prefix or not the dev target.
#}
{% macro drop_pr_schemas(prefix) %}
    {%- set prefix = prefix | string | upper -%}
    {%- if not modules.re.match('^PR_[0-9]+$', prefix) or target.name != 'dev' -%}
        {{ exceptions.raise_compiler_error("drop_pr_schemas only drops PR_<number>_* schemas in dev (got " ~ prefix ~ " on " ~ target.name ~ ")") }}
    {%- endif -%}
    {%- for layer in ['SILVER', 'GOLD'] -%}
        {%- set fqn = target.database ~ '.' ~ prefix ~ '_' ~ layer -%}
        {% do run_query('drop schema if exists ' ~ fqn ~ ' cascade') %}
        {% do log('dropped ' ~ fqn, info=True) %}
    {%- endfor -%}
{% endmacro %}
