# RideNest Mobility — data platform

Mock data platform for a fictional e-scooter rental company (Tel Aviv, Berlin, Lisbon).
Azure + Snowflake + Data Factory + dbt, provisioned with Terraform, delivered with GitHub Actions,
in three environments: **dev → preprod → prod**. Data is organised as **BRONZE / SILVER / GOLD**.

Architecture diagram: see [docs/architecture.md](docs/architecture.md).

## Layout
| Path | What |
|---|---|
| `infra/bootstrap` | One-time: resource group `rg-ridenest-ilc`, Terraform state storage, GitHub deploy identities (local state) |
| `infra/modules/azure_env` | Per-env Azure: ADLS Gen2 (`landing`, `bronze`), Data Factory, Key Vault, Azure SQL (billing), Log Analytics |
| `infra/modules/snowflake_env` | Per-env Snowflake: `RIDENEST_<ENV>` + layer schemas, warehouses, roles, service users, Azure storage integration, stage, tags, resource monitor |
| `infra/envs/<env>` | Azure root for that env (state key `<env>.tfstate`) |
| `infra/envs/<env>/snowflake` | Snowflake root for that env (state key `<env>-snowflake.tfstate`); also generates the loader/dbt key pairs into Key Vault |
| `infra/envs/<env>/pipelines` | Data Factory linked services, datasets, pipelines, trigger (state key `<env>-pipelines.tfstate`) |
| `infra/modules/adf_pipelines` | `PL_INGEST_DAILY` (one day) and `PL_BACKFILL` (all history in one run) |
| `infra/account/snowflake` | Account-level Snowflake: credit cap on the trial's `COMPUTE_WH` |
| `sql/00_snowflake_bootstrap.sql` | One-off: creates `TERRAFORM_SVC` (run with **Run All**) |
| `sql/bronze/` | BRONZE load SQL executed by ADF: daily partition replace, and full reload |
| `generator/` | Python mock-data generator (`dev` and `full` profiles) |
| `dbt/` | Filled in the next step |

## Conventions
- **All Azure resources live in one resource group, `rg-ridenest-ilc` (Israel Central).** Environments are
  separated by resource name (`adf-ridenest-dev-…`), the `env` tag, and separate Terraform state.
- Snowflake account `QKVPWRB-GB28666` runs on **AWS eu-central-2 (Zurich)** and reads the Azure lake cross-cloud through a storage integration.
- No secrets in the repo: Azure uses Entra ID / managed identities, Snowflake uses key-pair auth,
  generated secrets live in each env's Key Vault.

## Data flow
```
generator ─► Azure SQL billing.* ─┐
          └► ADLS landing/        ├─ ADF PL_INGEST_DAILY (runDate) ─► ADLS bronze/raw/<source>/yyyy/MM/dd/
                                  └─ ADF PL_BACKFILL (all dates)  ─► ADLS bronze/raw/<source>/…  (+ initial_load/)
                                                                          │ Script activity as <ENV>_LOADER
                                                                          ▼
                                             Snowflake RIDENEST_<ENV>.BRONZE.RAW_*  (RECORD VARIANT + file lineage)
```
- **Daily** replaces that day's partition (DELETE by `_SOURCE_FILE`, then `COPY … FORCE`), so re-runs never double-load.
- **Backfill** clears `raw/billing_payments/`, exports the whole payments table once, then TRUNCATE + COPY of every source.

| Env | Data | Volume |
|---|---|---|
| dev | `--profile dev`: 7 days | ~23k events, ~11.5k payments |
| preprod / prod | `--profile full`: 365 days to 2026-11-25 | ~4.3M events, ~2.1M payments, ~585k fleet snapshot rows |

```bash
cd generator && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python ridenest_gen.py --env prod --profile full --end 2026-11-25
az datafactory pipeline create-run -g rg-ridenest-ilc --factory-name adf-ridenest-prod-<suffix> -n PL_BACKFILL
```

## Cost guardrails
- Azure budget `budget-ridenest-monthly` ($25/month on `rg-ridenest-ilc`): emails the Owner role at 60% and 100% actual, and 100% forecast.
- Azure SQL serverless pauses after 15 idle minutes.
- Snowflake resource monitors: 5 / 5 / 10 credits per month (dev / preprod / prod) + 5 on `COMPUTE_WH`.
- The prod daily trigger stays **off** until the generator runs daily in CI (otherwise the 02:00 run finds no new files).

## Running Terraform locally
```bash
az login
# Azure
cd infra/envs/dev && terraform init -backend-config=../backend.hcl && terraform plan
# Snowflake (needs the env vars below)
export SNOWFLAKE_ORGANIZATION_NAME=... SNOWFLAKE_ACCOUNT_NAME=... SNOWFLAKE_USER=TERRAFORM_SVC \
       SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT SNOWFLAKE_PRIVATE_KEY="$(cat ~/.snowflake/keys/ridenest_terraform_rsa_key.p8)"
cd infra/envs/dev/snowflake && terraform init -backend-config=../../backend.hcl && terraform plan
```

## Status
- [x] Bootstrap (RG, state, deploy identities)
- [x] Azure dev / preprod / prod
- [x] Snowflake dev / preprod / prod, incl. cross-cloud read of the Azure bronze container (verified with LIST @ADLS_STAGE)
- [ ] GitHub repo + Actions (`infra.yml`)
- [x] Generator → ADF → BRONZE (dev: 7 days; preprod/prod: 1 year)
- [ ] dbt SILVER / GOLD
