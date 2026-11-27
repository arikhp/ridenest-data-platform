# Architecture

Interactive diagram: https://claude.ai/artifact/4eP1hMMHHjbbMPDRJjoHFK

```
Python generator ─► Azure SQL (billing) ─┐
                └─► ADLS landing/  ──────┤
                                         ▼
                Data Factory ─copy─► ADLS bronze/raw/<source>/yyyy/mm/dd/
                                         │ COPY INTO via storage integration + external stage (daily)
ScootTrack mock API ─┐                   │
Open-Meteo ──────────┴─► Function (10 min) ─► ADLS bronze/raw/api_<source>/yyyy/mm/dd/HH/
                                         │ Event Grid ─► queue ─► Snowpipe (auto-ingest, ~1 min)
                                         ▼
            Snowflake (AWS Zurich) RIDENEST_<ENV>: BRONZE ─dbt─► SILVER ─dbt─► GOLD ─► Fabric / Power BI
GitHub Actions: daily.yml (generator ─► ADF ─► dbt build), functions.yml, api-backfill.yml, streaming-health.yml
Key Vault: SQL creds, Snowflake private keys, mock API key (read via managed identities / OIDC)
```

| | dev | preprod | prod |
|---|---|---|---|
| Azure names | `*-ridenest-dev-*` | `*-ridenest-preprod-*` | `*-ridenest-prod-*` |
| Resource group | `rg-ridenest-ilc` | `rg-ridenest-ilc` | `rg-ridenest-ilc` |
| Snowflake DB | `RIDENEST_DEV` | `RIDENEST_PREPROD` | `RIDENEST_PROD` |
| Roles | `DEV_LOADER/TRANSFORMER/READER` | `PREPROD_…` | `PROD_…` |
| Credit cap / month | 5 | 5 | 10 |
| API pull every 10 min | off (backfill only) | on | on |
| Deploys | merge to main | after dev passes | manual approval |
