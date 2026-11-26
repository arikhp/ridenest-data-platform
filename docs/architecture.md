# Architecture

Interactive diagram: https://claude.ai/artifact/4eP1hMMHHjbbMPDRJjoHFK

```
Python generator ─► Azure SQL (billing) ─┐
                └─► ADLS landing/  ──────┤
                                         ▼
                Data Factory ─copy─► ADLS bronze/raw/<source>/yyyy/mm/dd/
                     │                   │ COPY INTO via storage integration + external stage
                     │                   ▼
                     │      Snowflake (AWS Zurich) RIDENEST_<ENV>: BRONZE ─dbt─► SILVER ─dbt─► GOLD ─► Power BI
                     └─trigger─► Container Apps Job (dbt build --target <env>)
Key Vault: SQL creds + Snowflake private keys (read by ADF / job via managed identity)
```

| | dev | preprod | prod |
|---|---|---|---|
| Azure names | `*-ridenest-dev-*` | `*-ridenest-preprod-*` | `*-ridenest-prod-*` |
| Resource group | `rg-ridenest-ilc` | `rg-ridenest-ilc` | `rg-ridenest-ilc` |
| Snowflake DB | `RIDENEST_DEV` | `RIDENEST_PREPROD` | `RIDENEST_PROD` |
| Roles | `DEV_LOADER/TRANSFORMER/READER` | `PREPROD_…` | `PROD_…` |
| Credit cap / month | 5 | 5 | 10 |
| Deploys | merge to main | after dev passes | manual approval |
