#!/usr/bin/env bash
#
# Full startup orchestration for the Postgres -> Estuary Flow -> Snowflake
# CDC demo. Idempotent and safe to re-run.
#
#   1. terraform apply        -> provision RDS Postgres
#   2. read Terraform outputs  -> export PG* connection vars
#   3. psql setup.sql          -> tables, publication, replication slot
#   4. docker compose up       -> ShadowTraffic data generator
#   5. flowctl publish         -> capture, collections, materialization
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths & helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
step "Checking prerequisites and configuration"

for bin in terraform psql docker flowctl envsubst awk aws; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is not installed or not on PATH."
done
# docker compose v2 (plugin) is required.
docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) is required."

[ -f "${ROOT_DIR}/.env" ] || die "Missing .env. Copy .env.example to .env and fill it in."
# Load .env into the environment.
set -a
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"
set +a
# A blank AWS_PROFILE= from .env would make the AWS SDK look for a profile named
# "" — unset it so default-chain credentials work.
[ -z "${AWS_PROFILE:-}" ] && unset AWS_PROFILE || true

# This demo generates its source data with ShadowTraffic (https://shadowtraffic.io/),
# a load/data generator for streaming pipelines. Thanks to the ShadowTraffic team!
# Running it requires a license — grab a free trial at https://shadowtraffic.io/
# and drop the values into shadowtraffic/license.env.
if [ ! -f "${ROOT_DIR}/shadowtraffic/license.env" ]; then
  die "Missing shadowtraffic/license.env. This demo uses ShadowTraffic to generate data.
    Create a free trial license at https://shadowtraffic.io/, then copy
    shadowtraffic/license.env.example to shadowtraffic/license.env and fill it in."
fi

: "${AWS_REGION:?Set AWS_REGION in .env}"
# Operator IP allowlisting. If TF_VAR_allowed_cidr is unset/empty, auto-detect
# this machine's public IPv4 and allowlist it as /32 so RDS is reachable for
# psql/admin access. Set TF_VAR_allowed_cidr in .env to override (e.g. to add
# extra CIDRs or pin a static range). It's always additive to estuary_cidrs.
if [ -z "${TF_VAR_allowed_cidr:-}" ]; then
  info "TF_VAR_allowed_cidr not set; detecting this machine's public IP..."
  myip="$(curl -4 -fsS --max-time 10 ifconfig.me 2>/dev/null \
    || curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
    || true)"
  case "${myip}" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) die "Could not auto-detect a public IPv4. Set TF_VAR_allowed_cidr in .env (your IP in CIDR, e.g. 1.2.3.4/32)." ;;
  esac
  export TF_VAR_allowed_cidr="${myip}/32"
  info "Allowlisting ${TF_VAR_allowed_cidr} (override by setting TF_VAR_allowed_cidr in .env)."
fi
: "${ESTUARY_TOKEN:?Set ESTUARY_TOKEN in .env}"
: "${ESTUARY_PREFIX:?Set ESTUARY_PREFIX in .env (e.g. yourTenant/estuary-cdc-demo)}"
: "${SNOWFLAKE_ACCOUNT:?Set SNOWFLAKE_ACCOUNT in .env}"
: "${SNOWFLAKE_DATABASE:?Set SNOWFLAKE_DATABASE in .env}"
: "${SNOWFLAKE_SCHEMA:?Set SNOWFLAKE_SCHEMA in .env}"
: "${SNOWFLAKE_WAREHOUSE:?Set SNOWFLAKE_WAREHOUSE in .env}"
: "${SNOWFLAKE_ROLE:?Set SNOWFLAKE_ROLE in .env}"
: "${SNOWFLAKE_USER:?Set SNOWFLAKE_USER in .env}"
: "${SNOWFLAKE_PRIVATE_KEY_PATH:?Set SNOWFLAKE_PRIVATE_KEY_PATH in .env}"
[ -f "${SNOWFLAKE_PRIVATE_KEY_PATH}" ] || \
  die "Snowflake private key not found at SNOWFLAKE_PRIVATE_KEY_PATH=${SNOWFLAKE_PRIVATE_KEY_PATH}"

# Make the Snowflake schema unique per Estuary tenant. SNOWFLAKE_SCHEMA in .env
# is a BASE name; the effective schema appends a sanitized token derived from
# the tenant (first path segment of ESTUARY_PREFIX). This way, recycling to a
# fresh tenant lands in a fresh schema and never collides with leftover tables
# from a previous run. teardown.sh derives the identical name to drop it.
# (Defined in scripts/lib/schema.sh so both scripts stay in sync.)
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/schema.sh"
export SNOWFLAKE_SCHEMA="$(estuary_demo_schema "${SNOWFLAKE_SCHEMA}" "${ESTUARY_PREFIX}")"
info "Snowflake schema (unique per tenant): ${SNOWFLAKE_SCHEMA}"

# Fail fast on missing/expired AWS credentials — Terraform's error for this is
# cryptic ("ExpiredToken ... validating provider credentials").
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  die "AWS credentials missing or expired.$( [ -n "${AWS_PROFILE:-}" ] && echo " (AWS_PROFILE=${AWS_PROFILE})" ) For SSO run: aws sso login${AWS_PROFILE:+ --profile $AWS_PROFILE}. Set AWS_PROFILE in .env (or your shell), and make sure no stale AWS_ACCESS_KEY_ID/AWS_SESSION_TOKEN env vars are overriding it. Verify with: aws sts get-caller-identity"
fi
info "AWS identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"

# ---------------------------------------------------------------------------
# 1. Provision RDS Postgres
# ---------------------------------------------------------------------------
step "1/5 Provisioning RDS Postgres with Terraform"
terraform -chdir=terraform init -input=false
terraform -chdir=terraform apply -auto-approve -input=false

# ---------------------------------------------------------------------------
# 2. Export Postgres connection details from Terraform outputs
# ---------------------------------------------------------------------------
step "2/5 Reading Terraform outputs"
export PGHOST="$(terraform -chdir=terraform output -raw address)"
export PGPORT="$(terraform -chdir=terraform output -raw port)"
export PGDATABASE="$(terraform -chdir=terraform output -raw db_name)"
export PGUSER="$(terraform -chdir=terraform output -raw username)"
export PGPASSWORD="$(terraform -chdir=terraform output -raw password)"
# RDS forces TLS by default.
export PGSSLMODE="require"
info "Postgres endpoint: ${PGHOST}:${PGPORT} (db=${PGDATABASE}, user=${PGUSER})"
STORAGE_BUCKET="$(terraform -chdir=terraform output -raw storage_bucket_name 2>/dev/null || true)"
[ -n "${STORAGE_BUCKET}" ] && info "Estuary storage bucket: ${STORAGE_BUCKET}"

# Wait for the endpoint to accept connections (DNS + listener may lag apply).
step "Waiting for Postgres to accept connections"
for i in $(seq 1 30); do
  if pg_isready -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" >/dev/null 2>&1; then
    info "Postgres is ready."
    break
  fi
  [ "$i" -eq 30 ] && die "Postgres did not become reachable. Check TF_VAR_allowed_cidr matches your current IP."
  info "  ...not ready yet (attempt ${i}/30); retrying in 10s"
  sleep 10
done

# ---------------------------------------------------------------------------
# 3. Postgres CDC setup (tables, publication, replication slot)
# ---------------------------------------------------------------------------
step "3/5 Running Postgres CDC setup (tables, publication, slot)"
psql "host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} sslmode=require" \
  -v ON_ERROR_STOP=1 -f "${ROOT_DIR}/scripts/sql/setup.sql"

# ---------------------------------------------------------------------------
# 4. Start ShadowTraffic
# ---------------------------------------------------------------------------
step "4/5 Starting ShadowTraffic data generator"
# PG* are exported above; docker compose interpolates them into the service.
# --force-recreate so a re-run always picks up edits to shadowtraffic.json
# (a mounted-file change alone doesn't trigger a normal `up -d` recreate).
docker compose -f "${ROOT_DIR}/shadowtraffic/docker-compose.yml" up -d --force-recreate
info "ShadowTraffic running. Tail logs with:"
info "  docker compose -f shadowtraffic/docker-compose.yml logs -f"

# ---------------------------------------------------------------------------
# 5. Deploy the Estuary Flow catalog
# ---------------------------------------------------------------------------
step "5/5 Deploying Estuary Flow catalog"

# Pin flowctl to THIS token's identity for every command below.
#
# flowctl prefers the DEFAULT profile's saved session, so a prior `flowctl auth
# login` to another account silently runs these commands as the WRONG identity.
# We isolate by authenticating a DEDICATED, per-tenant profile with the .env
# token and passing --profile on every call. We authenticate via `auth token`
# (not the FLOW_AUTH_TOKEN env var, which requires a base64 refresh token — the
# dashboard CLI token is a JWT and is rejected as "not base64"). `auth token`
# refuses to run with an ambient FLOW_AUTH_TOKEN, so clear it first.
unset FLOW_AUTH_TOKEN
FLOWCTL_PROFILE="cdc-demo-$(printf '%s' "${ESTUARY_PREFIX%%/*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//')"
flowctl --profile "${FLOWCTL_PROFILE}" auth token --token "${ESTUARY_TOKEN}" >/dev/null

# Normalize the Snowflake host. SNOWFLAKE_ACCOUNT may be a bare account id
# (rinkxyn-sa68832) OR a full URL (https://rinkxyn-sa68832.snowflakecomputing.com/);
# strip scheme, any path, and an existing suffix, then append it exactly once.
_sf_host="${SNOWFLAKE_ACCOUNT#https://}"
_sf_host="${_sf_host#http://}"
_sf_host="${_sf_host%%/*}"                     # drop /path and trailing slash
_sf_host="${_sf_host%.snowflakecomputing.com}" # drop suffix if already present
export SNOWFLAKE_HOST="${_sf_host}.snowflakecomputing.com"
info "Snowflake host: ${SNOWFLAKE_HOST}"

# The Snowflake private key (PEM) must become a single YAML-safe value: collapse
# it to one line with literal \n separators so the double-quoted YAML string in
# flow.yaml round-trips back to a valid multi-line PEM.
export SNOWFLAKE_PRIVATE_KEY="$(awk 'BEGIN{ORS="\\n"} {sub(/\r$/,""); print}' "${SNOWFLAKE_PRIVATE_KEY_PATH}")"

# Render the template -> flow.generated.yaml (git-ignored), substituting only
# our known variables so nothing else in the file is touched.
envsubst '${ESTUARY_PREFIX} ${PGHOST} ${PGPORT} ${PGDATABASE} ${PGUSER} ${PGPASSWORD} ${SNOWFLAKE_HOST} ${SNOWFLAKE_DATABASE} ${SNOWFLAKE_SCHEMA} ${SNOWFLAKE_WAREHOUSE} ${SNOWFLAKE_ROLE} ${SNOWFLAKE_USER} ${SNOWFLAKE_PRIVATE_KEY}' \
  < "${ROOT_DIR}/flowctl/flow.yaml" \
  > "${ROOT_DIR}/flowctl/flow.generated.yaml"

# Existence-aware publish. `flowctl catalog publish` is idempotent (it updates
# specs in place and never renames them), but re-publishing a live capture can
# re-trigger validation/backfill. So if all five specs already exist under the
# prefix, skip the publish to avoid churning a running pipeline. Override with
# FORCE_PUBLISH=1 to always (re)publish.
EXPECTED_SPECS=(
  "${ESTUARY_PREFIX}/source-postgres"
  "${ESTUARY_PREFIX}/customers"
  "${ESTUARY_PREFIX}/transactions"
  "${ESTUARY_PREFIX}/shipments"
  "${ESTUARY_PREFIX}/materialize-snowflake"
)
existing_specs="$(flowctl --profile "${FLOWCTL_PROFILE}" catalog list --prefix "${ESTUARY_PREFIX}/" -o json 2>/dev/null || true)"
missing_specs=()
for _spec in "${EXPECTED_SPECS[@]}"; do
  printf '%s' "${existing_specs}" | grep -qF "\"${_spec}\"" || missing_specs+=("${_spec}")
done

if [ "${#missing_specs[@]}" -eq 0 ] && [ "${FORCE_PUBLISH:-0}" != "1" ]; then
  info "Flow catalog already deployed under ${ESTUARY_PREFIX}/ — all 5 specs present."
  info "Skipping publish so the running pipeline isn't disturbed (FORCE_PUBLISH=1 to republish)."
else
  if [ "${#missing_specs[@]}" -gt 0 ]; then
    info "Publishing catalog (missing: ${missing_specs[*]})."
  else
    info "FORCE_PUBLISH=1 set — republishing all specs."
  fi
  # publish creates the missing specs and updates any that exist; it never
  # recreates-from-scratch or renames specs you already own.
  flowctl --profile "${FLOWCTL_PROFILE}" catalog publish --source "${ROOT_DIR}/flowctl/flow.generated.yaml" --auto-approve
fi

# ---------------------------------------------------------------------------
# Collection-storage status (informational, NEVER fatal).
#
# The demo runs on Estuary's DEFAULT managed storage. Bringing your own S3
# bucket is an OPTIONAL later lab exercise: we provision the bucket regardless,
# and here just report whether Estuary is already pointed at it. Any failure to
# query (permissions, schema drift, offline) is ignored — defaults resolve
# themselves during Estuary instantiation, which is fine.
# ---------------------------------------------------------------------------
ESTUARY_TENANT="${ESTUARY_PREFIX%%/*}"
STORAGE_MSG="bucket not created (TF_VAR_create_storage_bucket=false)"
if [ -n "${STORAGE_BUCKET}" ]; then
  STORAGE_MSG="Estuary is on its DEFAULT managed storage; this bucket is provisioned but not yet used (optional later step)."
  sm_json="$(flowctl --profile "${FLOWCTL_PROFILE}" raw get --table storage_mappings \
      -q "select=catalog_prefix,spec" \
      -q "catalog_prefix=like.${ESTUARY_TENANT}*" 2>/dev/null || true)"
  if printf '%s' "${sm_json}" | grep -q "\"${STORAGE_BUCKET}\""; then
    STORAGE_MSG="Estuary already uses this bucket as its storage mapping — nothing to do. ✓"
  fi
fi

step "Done."
cat <<EOF

The pipeline is live:
  Postgres (RDS) --CDC--> Estuary Flow --delta-updates--> Snowflake

Collection storage  (OPTIONAL later lab exercise — the demo already works on
Estuary's default managed storage, so nothing here is required now):
  Status:                   ${STORAGE_MSG}
  S3 bucket ID:             ${STORAGE_BUCKET:-<not created>}
  Catalog prefix to cover:  ${ESTUARY_TENANT}/
  When you're ready to use your own bucket:
    Dashboard -> Admin -> Settings -> Cloud Storage -> Add Storage Mapping
    (prefix ${ESTUARY_TENANT}/, provider AWS, the bucket ID above; run the test).
  Estuary writes objects under a collection-data/ prefix automatically. The
  bucket policy is already applied by Terraform; after switching, backfill your
  captures since existing data isn't migrated.

Verify:
  - ShadowTraffic:  docker compose -f shadowtraffic/docker-compose.yml logs -f
  - Postgres rows:  psql "host=${PGHOST} dbname=${PGDATABASE} user=${PGUSER} sslmode=require" -c "select count(*) from transactions;"
  - Estuary:        flowctl --profile ${FLOWCTL_PROFILE} catalog status --name ${ESTUARY_PREFIX}/source-postgres
                    (the '${FLOWCTL_PROFILE}' profile keeps this pinned to your tenant, not your default flowctl login)
  - Snowflake:      SELECT COUNT(*) FROM ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.TRANSACTIONS;

Tear it all down with:  ./scripts/teardown.sh

Source data is generated by ShadowTraffic (https://shadowtraffic.io/) — thanks
to their team. Need a license? Grab a free trial at https://shadowtraffic.io/.
EOF
