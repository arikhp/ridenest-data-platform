# Usage:  source dbt/env.sh <dev|preprod|prod>
# Exports what profiles.yml needs. The dbt private key is read from the env's Key Vault into memory
# (needs `az login` + Key Vault Secrets User/Officer); nothing is written to disk.
_env="${1:-dev}"
_sub=$(az account show --query id -o tsv)
_sfx=$(printf "%s" "$_sub" | shasum | cut -c1-6)
export DBT_TARGET="$_env"
export SNOWFLAKE_ACCOUNT="QKVPWRB-GB28666"
export SNOWFLAKE_DBT_PRIVATE_KEY="$(az keyvault secret show --vault-name "kv-ridenest-${_env}-${_sfx:0:4}" -n snowflake-dbt-private-key --query value -o tsv)"
export DBT_PROFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
echo "dbt target=$DBT_TARGET account=$SNOWFLAKE_ACCOUNT key=$([ -n "$SNOWFLAKE_DBT_PRIVATE_KEY" ] && echo loaded || echo MISSING)"
unset _env _sub _sfx
