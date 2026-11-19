{# use the folder schema (staging/gold/marts) as is, instead of dbt's default "<target>_<schema>" #}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {{ custom_schema_name or target.schema }}
{%- endmacro %}
