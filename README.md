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
| `dbt/` | dbt project: SILVER + GOLD models and tests |

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
- The ADF schedule trigger stays **off**: the nightly chain is orchestrated by GitHub Actions (`daily.yml`), see below.

## SILVER (dbt)
dbt-core 1.12 + dbt-snowflake, connecting as `SVC_RIDENEST_<ENV>_DBT` / role `<ENV>_TRANSFORMER` (key pair from Key Vault).

| Model | What it does |
|---|---|
| `trip_events` | Incremental (merge on `event_id`). Dedups ~1% duplicate deliveries, local time → UTC, (0,0) GPS → NULL |
| `trips` | Pairs start/end events; duration, nearest start/end zone, fare in EUR; flags bad trips (`dq_issue`, `is_valid`) instead of dropping them |
| `trips_rejected` | View of the quarantined trips and why |
| `payments` | Typed, latest version per payment, `amount_eur` |
| `riders`, `vehicles` | Current state from the latest snapshot; rider PII columns tagged `PII = high` |
| `vehicle_status_daily`, `maintenance_tickets` | Typed; tickets with a future close time count as open |
| `zones`, `cities`, `promo_codes`, seed `fx_rates_to_eur` | Reference data |

57 tests (keys, accepted values, relationships, consistency of valid trips, rejected-trip budget < 2%).
Every object gets `LAYER = silver`; columns with `config.meta.pii` get the `PII` tag (catalog).

```bash
cd dbt && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt && .venv/bin/dbt deps
source ./env.sh dev          # loads the dbt key from Key Vault into memory
.venv/bin/dbt build          # SILVER on dev; full year on preprod builds in ~35 s on an XS warehouse
```

## GOLD (dbt)
Star schema + business marts, read by BI through the `<ENV>_READER` role. No personal data in GOLD.

| Kind | Model | Grain |
|---|---|---|
| Dimensions | `dim_date`, `dim_city`, `dim_zone`, `dim_vehicle`, `dim_rider` (status active/lapsed/churned, lifetime stats) | one row per member |
| Facts | `fct_trips` (valid trips + payment outcome), `fct_vehicle_day` (status, trips, utilisation) | trip / vehicle-day |
| Marts *(contracts enforced)* | `mart_revenue_daily` (finance), `mart_zone_daily` (finance), `mart_fleet_utilization_daily` (fleet), `mart_rider_retention_monthly` (riders), `mart_maintenance_monthly` (fleet) | city-day / zone-day / cohort-month / city-month-issue |

Reconciliation tests guarantee GOLD = SILVER for trips, fare and collected revenue, and fleet trips = trip fact.
Preprod (1 year, 2.1M valid trips): full SILVER + GOLD build with 106 tests in ~40 s on an XS warehouse.

## CI/CD (GitHub Actions)
Repo: https://github.com/arikhp/ridenest-data-platform — `main` is protected (PR required; checks `fmt + validate` and `plan-dev / plan dev` must pass).

| Event | What runs |
|---|---|
| Pull request | `terraform fmt`/`validate` on every root, `plan` for dev (Azure, Snowflake, pipelines), plan summary commented on the PR |
| Merge to `main` (infra/sql changes) | apply **dev** → apply **preprod** → apply **prod** after manual approval (GitHub Environment `prod`) |
| Pull request (dbt workflow) | full `dbt build` (models + tests) in `PR_<n>_SILVER` / `PR_<n>_GOLD` on dev data; results commented on the PR |
| PR closed / merged | `PR_<n>_*` schemas dropped (guarded: only `PR_<number>` prefixes, only in dev) |
| Merge to `main` (dbt changes) | `dbt build` **dev** → **preprod** → **prod** after manual approval |

dbt jobs read the env's dbt key from **that env's** Key Vault via OIDC, so no Snowflake dbt key is stored in GitHub
and a dev run cannot read the prod key. Each run keeps `manifest.json` / `run_results.json` as artifacts (30 days).

- Azure login: GitHub OIDC → `id-ridenest-deploy-<env>` managed identity (federated subject
  `repo:arikhp@<owner_id>/ridenest-data-platform@<repo_id>:environment:<env>`). No Azure secret stored.
- Snowflake login: `TERRAFORM_SVC` key pair (`SNOWFLAKE_PRIVATE_KEY` secret).
- Subscription/tenant/object IDs are GitHub **secrets** (masked in public logs) and git-ignored
  `local.auto.tfvars` files locally; committed `terraform.tfvars` hold only non-identifying settings.

## Nightly run (`daily.yml`)
Every day at **02:30 UTC** GitHub Actions runs, for prod and for *yesterday*:

1. **Generator** — writes the day's trip events and fleet files to `landing/`, the day's payments (and new riders) to Azure SQL.
   The world is anchored to a fixed history window, so re-running a day reproduces it exactly; ~70 new riders sign up per day.
2. **Data Factory** `PL_INGEST_DAILY` (runDate = that day) — landing/SQL → `bronze/raw/…/yyyy/MM/dd` → Snowflake BRONZE; the job waits for it.
3. **dbt** — `source freshness` (warning if BRONZE is stale) and `dbt build` (SILVER + GOLD + 106 checks).

Any failure fails the workflow (GitHub emails the repo owner). Manual run: *Actions → daily → Run workflow*, choose env and date
(useful to catch up a missed day).

Prod nightly runs use the GitHub Environment **`prod-ops`**: no approval, `main` branch only, prod identity — a decision by the
project owner so the nightly job does not wait for a click. Code deployments to prod (`infra.yml`, `dbt.yml`) still need approval.

## Running Terraform locally
```bash
az login
# Azure
# each root needs a git-ignored local.auto.tfvars with subscription_id (+ admin_object_ids / snowflake_sp_object_id)
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
- [x] GitHub repo + Actions (`infra.yml`): PR plan, dev → preprod → prod (approval)
- [x] Generator → ADF → BRONZE (dev: 7 days; preprod/prod: 1 year)
- [x] dbt SILVER (dev + preprod built; prod via dbt CI/CD, next)
- [x] dbt GOLD (dev + preprod built)
- [x] dbt CI/CD (PR schemas, dev → preprod → prod)
- [x] Scheduled daily runs (generator → ADF → dbt), prod 02:30 UTC
