# Estuary CDC Demo — Postgres → Estuary Flow → Snowflake

A self-contained, one-command demo of real-time change data capture. Terraform
stands up an RDS Postgres instance, ShadowTraffic streams realistic inserts and
updates into it, Estuary Flow captures the changes via logical replication, and
a Snowflake materialization lands them in append-only tables.

Everything spins up with `./scripts/start.sh` and tears down cleanly with
`./scripts/teardown.sh` — no orphaned cloud resources.

## Architecture

```
            ./scripts/start.sh
      (provisions + runs the pipeline)
                     │
                     ▼
  ┌────────────────────────────────────┐
  │ ShadowTraffic  (Docker)            │
  │ synthetic data generator           │
  │ ~5-10 rows/s, insert-heavy         │
  └──────────────────┬─────────────────┘
                     │  INSERT / UPDATE
                     ▼
  ┌────────────────────────────────────┐
  │ AWS RDS Postgres  (Terraform)      │
  │ tables: customers,                 │
  │         transactions, shipments    │
  └──────────────────┬─────────────────┘
                     │  logical replication (pgoutput)
                     │  slot: flow_slot · pub: flow_publication
                     ▼
  ┌────────────────────────────────────┐
  │ Estuary Flow                       │
  │   source-postgres  (capture)       │
  │         │                          │
  │         ▼                          │
  │   3 collections                    │
  │         │                          │
  │         ▼                          │
  │   materialize-snowflake            │
  │   (delta-updates, append-only)     │
  └──────────────────┬─────────────────┘
                     ▼
  ┌────────────────────────────────────┐
  │ Snowflake                          │
  │ <DB>.<SCHEMA> · X-SMALL warehouse  │
  │ tables: CUSTOMERS, TRANSACTIONS,   │
  │         SHIPMENTS                  │
  └────────────────────────────────────┘
```

Data model (relationships are logical — the generator fills real parent ids via
lookups; DB-level FK constraints are intentionally not enforced, since
ShadowTraffic's batched async writes don't guarantee parent-before-child commit
ordering):

```
customers(customer_id PK, name, email, created_at)
   └──< transactions(transaction_id PK, customer_id FK, amount, status, created_at)
            └──< shipments(shipment_id PK, transaction_id FK, address, status, updated_at)
```

## Repository layout

```
terraform/        AWS RDS Postgres + S3 storage bucket (logical replication, local state)
shadowtraffic/    docker-compose + data generator config + license.env
flowctl/          flow.yaml — capture + 3 collections + Snowflake materialization (template)
scripts/
  start.sh        full startup orchestration
  teardown.sh     full teardown orchestration
  sql/setup.sql   tables, publication, replication slot
.env.example      every required variable, commented
```

## Prerequisites

Tools (CLIs on your PATH):

| Tool | Notes |
|------|-------|
| Terraform | ≥ 1.5 |
| AWS credentials | `aws configure`, SSO, or env vars; needs RDS, EC2/VPC, and S3 permissions (see setup step 2) |
| Docker + Compose v2 | `docker compose version` must work (no Desktop extensions used) |
| `psql` | PostgreSQL client (libpq) |
| `flowctl` | Estuary CLI — https://docs.estuary.dev/concepts/flowctl/ |
| `envsubst`, `awk` | usually preinstalled (gettext / coreutils) |
| `snowsql` | Snowflake CLI — only needed at teardown to drop the schema |

Accounts:

- **AWS** — any account; the instance is free-tier eligible (`db.t3.micro`, 20 GB).
- **ShadowTraffic** — free license from https://shadowtraffic.io/pricing.html
- **Estuary Flow** — https://dashboard.estuary.dev (note your tenant prefix).
- **Snowflake** — a trial account works; this demo uses an X-SMALL warehouse.

## First-time setup

### 1. Configure environment

```bash
cp .env.example .env
cp shadowtraffic/license.env.example shadowtraffic/license.env
```

Edit `.env` and fill in AWS, Estuary, and Snowflake values. Edit
`shadowtraffic/license.env` with your ShadowTraffic license variables.

`TF_VAR_allowed_cidr` controls which IP gets `psql`/admin access. **It's
optional** — leave it blank and `start.sh` auto-detects this machine's public
IPv4 and allowlists it as `/32`. Set it explicitly only to override (e.g. pin a
static range or allow several IPs):

```bash
echo "$(curl -4 -s ifconfig.me)/32"   # paste into TF_VAR_allowed_cidr
```

Port 5432 is opened to **your IP plus Estuary's data-plane egress IPs** — the
capture connects to Postgres from those, not from your machine. These IPs come
from the **Estuary data plane your tenant runs in, which is independent of
`AWS_REGION`** (your RDS region and the data-plane region are unrelated). The
default in `terraform/variables.tf` allowlists **all of Estuary's public data
planes** (AWS us-east-1, GCP us-central1, AWS us-west-2, AWS eu-west-1, AWS
ap-southeast-2), so whichever one your tenant uses is covered.

To tighten the allowlist to just your data plane, check **Admin → "Allowlist IP
addresses"** in the Estuary dashboard (or the
[allowlist reference](https://docs.estuary.dev/reference/allow-ip-addresses/))
and override:

```bash
export TF_VAR_estuary_cidrs='["35.226.75.135/32"]'
```

The `PG*` variables stay blank — `start.sh` fills them from Terraform outputs.

### 2. Authenticate to AWS

Terraform uses the standard AWS SDK credential chain — it does **not** read
keys from `.env`. If you see `Error: No valid credential sources found`, set up
credentials one of these ways, then verify.

**Option A — IAM access keys (`aws configure`):** simplest for a personal/demo
account.

```bash
aws configure
# AWS Access Key ID:      <from IAM > Security credentials > Access keys>
# AWS Secret Access Key:  <...>
# Default region name:    us-west-2          # match AWS_REGION in .env
# Default output format:  json
```

**Option B — AWS IAM Identity Center (SSO):** common at organizations.

```bash
aws configure sso       # one-time: set start URL, region, choose account/role
aws sso login           # refresh when the session expires
export AWS_PROFILE=<the-profile-name-you-just-created>
```

**Option C — environment variables:** e.g. temporary STS credentials.

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...        # only if using temporary credentials
```

Verify before running Terraform (this should print your account and identity):

```bash
aws sts get-caller-identity
```

> The identity you use needs permission to manage RDS, EC2/VPC (security groups,
> subnets), and DB parameter/subnet groups. `AWS_REGION` in `.env` sets the
> region Terraform deploys to; if you use a named profile, also export
> `AWS_PROFILE` so `start.sh` inherits it.

### 3. Create the Snowflake key pair (JWT auth)

The Snowflake connector uses key-pair auth (Snowflake is retiring single-factor
password sign-in). Generate an **unencrypted PKCS#8** key:

```bash
mkdir -p secrets
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out secrets/rsa_key.p8 -nocrypt
openssl rsa -in secrets/rsa_key.p8 -pubout -out secrets/rsa_key.pub
```

Assign the **public** key to your Snowflake user (run once in Snowsight, as a
role that can alter the user — paste the base64 body without the header/footer):

```sql
ALTER USER <SNOWFLAKE_USER> SET RSA_PUBLIC_KEY='MIIBIjANBgkq...';
```

Point `SNOWFLAKE_PRIVATE_KEY_PATH` in `.env` at `./secrets/rsa_key.p8`
(the default). `secrets/` is git-ignored.

### 4. Make sure the Snowflake warehouse exists and is cheap

`start.sh` does not create Snowflake objects (Estuary provisions the schema and
tables). It does expect the warehouse named in `SNOWFLAKE_WAREHOUSE` to exist.
Create an X-SMALL, auto-suspending warehouse once:

```sql
CREATE WAREHOUSE IF NOT EXISTS <SNOWFLAKE_WAREHOUSE>
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60          -- seconds
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
```

### 5. Start everything

```bash
./scripts/start.sh
```

This runs Terraform → reads outputs → sets up Postgres CDC → starts
ShadowTraffic → publishes the Flow catalog. Re-running it is safe (idempotent).

If the Flow capture, collections, and materialization already exist under your
prefix, `start.sh` detects them (via `flowctl catalog list`) and **skips the
publish** so a running pipeline isn't disturbed — `flowctl` would update them in
place anyway, never rename or recreate them. To force a republish (e.g. after
editing `flow.yaml`), run `FORCE_PUBLISH=1 ./scripts/start.sh`.

### 6. (Optional later lab exercise) Use your own S3 bucket for collection storage

**Not required to run the demo.** The pipeline works immediately on Estuary's
**default managed storage** (which expires data after 20 days on the Free plan).
Bringing your own bucket is meant as a follow-on exercise once the basic
pipeline is flowing.

To make that exercise turnkey, Terraform provisions the S3 bucket up front and
attaches the required bucket policy (granting Estuary's data-plane IAM users
`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`,
`s3:GetBucketPolicy`). On every run `start.sh` prints the **bucket ID**, the
**catalog prefix** to cover, and a **status line** reporting whether Estuary is
still on default storage or already pointed at this bucket (a best-effort,
non-fatal check via `flowctl raw get --table storage_mappings`).

**`start.sh` does not wire the bucket into Estuary.** Storage mappings are
created through the dashboard, not via flowctl or the published catalog, so when
you're ready this is a one-time manual step:

1. Dashboard → **Admin** → **Settings** tab → **Cloud Storage** → **Add Storage
   Mapping**.
2. Choose your catalog prefix, select your data plane(s), pick **AWS**, and
   enter the bucket name (the `storage_bucket_name` output).
3. Run the connection tests — they validate the policy Terraform already applied,
   so they should pass. If the dialog shows different data-plane principal ARNs
   than the defaults, set `TF_VAR_estuary_data_plane_principals` to those and
   `terraform apply` again, then re-test.
4. Save, then **backfill your captures** — existing data isn't migrated from the
   previous (managed) storage to the new bucket.

To skip creating the bucket entirely, set `TF_VAR_create_storage_bucket=false`.

## What to verify at each step

| Step | Check |
|------|-------|
| **Terraform** | `terraform -chdir=terraform output` shows `address`, `port`, `db_name`. |
| **Postgres setup** | `psql "host=$PGHOST dbname=$PGDATABASE user=$PGUSER sslmode=require" -c "\dt"` lists the three tables + `flow_watermarks`; `SELECT slot_name FROM pg_replication_slots;` shows `flow_slot`. |
| **ShadowTraffic** | `docker compose -f shadowtraffic/docker-compose.yml logs -f` shows rows being written; row counts climb: `SELECT count(*) FROM transactions;`. |
| **Estuary capture** | `flowctl catalog status --name $ESTUARY_PREFIX/source-postgres` is `Running`; the dashboard shows growing collection stats. |
| **Snowflake** | `SELECT COUNT(*) FROM <DB>.<SCHEMA>.TRANSACTIONS;` increases over time. The schema and tables were created by Estuary. |

Expected volume: roughly 5–10 rows/sec combined across the three tables (well
under 0.5 Mbps), insert-dominated with a slow trickle of status UPDATEs.

Latency: the Snowflake materialization is configured with `syncSchedule.syncFrequency: 0s`,
so it commits as fast as possible — rows should appear in Snowflake within seconds,
making the CDC latency easy to demo. The tradeoff is that the warehouse wakes
frequently (more credits); to batch for cost instead, raise `syncFrequency` (e.g.
`5m`/`30m`) in `flowctl/flow.yaml` and republish with `FORCE_PUBLISH=1 ./scripts/start.sh`.

## Teardown

```bash
./scripts/teardown.sh
```

In order: stop ShadowTraffic → delete the Flow capture/collections/materialization
→ `DROP SCHEMA IF EXISTS <DB>.<SCHEMA> CASCADE` in Snowflake (via `snowsql`) →
`terraform destroy -auto-approve`. Steps 1–3 are best-effort so teardown always
reaches the RDS destroy.

> **Estuary deletion is scoped and confirmed.** Teardown runs `flowctl catalog
> delete --prefix "<ESTUARY_PREFIX>/"`, which lists the specs in that namespace
> (e.g. everything under `wassDemo/estuary-cdc-demo/`, and nothing else under
> `wassDemo/`) and requires you to type the word `delete` to confirm. It does
> not use `--dangerous-auto-approve`.

> **Snowflake drop requires `snowsql`.** If it isn't installed, teardown prints
> the exact `DROP SCHEMA ... CASCADE` to run manually in Snowsight, then still
> destroys the rest.

> **Unique schema per tenant.** `SNOWFLAKE_SCHEMA` in `.env` is a *base* name;
> the scripts append a token derived from your Estuary tenant (e.g.
> `estuary_cdc_demo_wassdemo`). So recycling to a fresh tenant lands in a fresh
> schema and won't hit "table already exists" from leftover tables. `start.sh`
> and `teardown.sh` compute the same name (via `scripts/lib/schema.sh`), so
> teardown drops exactly what start created. If you change tenants without
> tearing down the old one first, the old tenant's schema is left behind — drop
> it manually.

## Troubleshooting

**`Error: No valid credential sources found` (Terraform / AWS provider).** Your
AWS credentials aren't set up. Terraform does not read keys from `.env` — see
setup step 2. Run `aws sts get-caller-identity` to confirm you're authenticated;
if you use a named profile, `export AWS_PROFILE=<name>` before `start.sh`. For
SSO, re-run `aws sso login` when the session expires.

**RDS not reachable / `psql` times out.** Almost always `TF_VAR_allowed_cidr`.
The security group allowlists your operator CIDR; if your IP changed, update
`.env` and re-run `start.sh` (Terraform updates the rule in place). Confirm the
instance is publicly accessible and `Available` in the RDS console.

**`psql` works but the Estuary capture can't connect (i/o timeout / connection
refused).** The capture connects from Estuary's data-plane IPs, not your
machine — so this is the `estuary_cidrs` allowlist, not `allowed_cidr`. Confirm
which data plane your tenant uses under **Admin** in the dashboard and set
`TF_VAR_estuary_cidrs` to its IPs (defaults cover the AWS us-west-2 c1 plane),
then re-run `start.sh`.

**`replication slot "flow_slot" already exists`.** Harmless — `setup.sql` only
creates the slot if absent, so re-runs skip it. To reset it manually:
`SELECT pg_drop_replication_slot('flow_slot');` then re-run `start.sh`. (A slot
that is never consumed will hold WAL — teardown drops the whole instance, so
this only matters during long-lived debugging.)

**Capture errors about `wal_level`.** Logical replication is enabled via the
`rds.logical_replication=1` parameter, applied at boot. If you imported a
pre-existing instance, it needs a reboot for the static parameter to take
effect: `SHOW wal_level;` must return `logical`.

**Snowflake warehouse suspended / first query slow.** The X-SMALL warehouse
auto-suspends after 60s and auto-resumes on demand, so the first
materialization write after idle may lag a few seconds. This is expected and
keeps credit usage minimal. If writes fail with "warehouse cannot be resumed,"
ensure `SNOWFLAKE_ROLE` can use it (`GRANT USAGE ON WAREHOUSE ... TO ROLE ...`).

**Snowflake auth fails (JWT).** Verify the **public** key is set on the user
(`DESC USER <user>;` → `RSA_PUBLIC_KEY_FP`) and that `SNOWFLAKE_PRIVATE_KEY_PATH`
points to the matching **unencrypted** PKCS#8 key. `SNOWFLAKE_ACCOUNT` must be
the account identifier only (e.g. `abcd-xy12345`), not the full URL.

**ShadowTraffic exits immediately.** Check `shadowtraffic/license.env` is filled
in and that `PGHOST`/`PGPASSWORD` reached the container:
`docker compose -f shadowtraffic/docker-compose.yml logs`. Run `start.sh` (not
`docker compose up` directly) so the Postgres env vars are exported first.

**`flowctl: command not found` / auth errors.** Install flowctl per the Estuary
docs and confirm `ESTUARY_TOKEN` is a current refresh token from
**Admin → CLI-API → Generate token**, generated while logged into the tenant
that owns your `ESTUARY_PREFIX`.

**`PermissionDenied` / publish or delete runs as the wrong account.** flowctl
prefers the saved session on its **default profile** (from a prior `flowctl auth
login`), so if you've logged into another account, commands silently act as that
identity. The scripts isolate from this by authenticating a dedicated per-tenant
profile with your `.env` token and passing `--profile cdc-demo-<tenant>` on every
call: `flowctl --profile cdc-demo-<tenant> auth token --token "$ESTUARY_TOKEN"`,
then `flowctl --profile cdc-demo-<tenant> catalog …`. If you run flowctl by hand
and see the wrong tenant, use that same `--profile`. Confirm what an identity can
reach with `flowctl auth roles list`.

**`FLOW_AUTH_TOKEN is not base64`.** That env var expects a base64 *refresh*
token, but the dashboard CLI-API token is a JWT (it contains `.`). The scripts
don't use `FLOW_AUTH_TOKEN` for this reason — they pass the token to
`flowctl auth token --token` instead, which accepts the JWT form. Put that same
dashboard token in `ESTUARY_TOKEN`; don't export `FLOW_AUTH_TOKEN` yourself (the
scripts `unset` it so it can't interfere).
