#!/usr/bin/env bash
#
# Full teardown. Removes every cloud resource the demo created, in reverse
# order of creation, so nothing is left running (and billing).
#
#   1. docker compose down     -> stop ShadowTraffic
#   2. flowctl delete          -> remove Flow capture/collections/materialization
#   3. DROP SCHEMA ... CASCADE  -> remove Snowflake schema + tables
#   4. terraform destroy        -> tear down RDS Postgres
#
# Steps 1-3 are best-effort (they warn but do not abort) so a partial teardown
# can always proceed to destroy the expensive RDS instance.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    WARN: %s\033[0m\n' "$*" >&2; }

[ -f "${ROOT_DIR}/.env" ] || { echo "Missing .env"; exit 1; }
set -a
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"
set +a

# Derive the same unique-per-tenant Snowflake schema that start.sh created, so
# we drop the right one. (SNOWFLAKE_SCHEMA in .env is the base name.)
if [ -n "${SNOWFLAKE_SCHEMA:-}" ] && [ -n "${ESTUARY_PREFIX:-}" ]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/scripts/lib/schema.sh"
  SNOWFLAKE_SCHEMA="$(estuary_demo_schema "${SNOWFLAKE_SCHEMA}" "${ESTUARY_PREFIX}")"
fi

# ---------------------------------------------------------------------------
# 1. Stop ShadowTraffic
# ---------------------------------------------------------------------------
step "1/4 Stopping ShadowTraffic"
# `docker compose down` still interpolates the whole compose file, including the
# service's ${PG*:?} guards (which exist to stop a bad `up`). At teardown the
# PG* vars aren't set (they come from Terraform outputs during start, not .env),
# so provide throwaway values — `down` ignores them, it just needs them present.
export PGHOST="${PGHOST:-teardown}" \
       PGDATABASE="${PGDATABASE:-teardown}" \
       PGUSER="${PGUSER:-teardown}" \
       PGPASSWORD="${PGPASSWORD:-teardown}"
if docker compose -f "${ROOT_DIR}/shadowtraffic/docker-compose.yml" down --remove-orphans; then
  info "ShadowTraffic stopped."
else
  warn "docker compose down failed (already stopped?). Continuing."
fi

# ---------------------------------------------------------------------------
# 2. Delete the Estuary Flow catalog
# ---------------------------------------------------------------------------
step "2/4 Deleting Estuary Flow resources"
if [ -n "${ESTUARY_TOKEN:-}" ] && [ -n "${ESTUARY_PREFIX:-}" ] && command -v flowctl >/dev/null 2>&1; then
  # Pin to ESTUARY_TOKEN's identity, isolated from your default flowctl login:
  # authenticate a dedicated, per-tenant profile with the .env token and pass
  # --profile on every call. Use `auth token` (not the FLOW_AUTH_TOKEN env var,
  # which needs a base64 refresh token — the dashboard CLI token is a JWT).
  # `auth token` refuses to run with an ambient FLOW_AUTH_TOKEN, so clear it.
  unset FLOW_AUTH_TOKEN
  FLOWCTL_PROFILE="cdc-demo-$(printf '%s' "${ESTUARY_PREFIX%%/*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//')"
  flowctl --profile "${FLOWCTL_PROFILE}" auth token --token "${ESTUARY_TOKEN}" >/dev/null 2>&1 || warn "flowctl auth failed."

  # Scope strictly to the namespace named in .env. Trim any trailing slash, then
  # add exactly one: a delete of --prefix "wassDemo/estuary-cdc-demo/" removes
  # EVERYTHING under that namespace but cannot touch anything else under
  # wassDemo/ — the trailing slash is the boundary, so a sibling such as
  # wassDemo/estuary-cdc-demo-2/ or wassDemo/other/ is never matched.
  DELETE_PREFIX="${ESTUARY_PREFIX%/}/"

  # Hand the whole operation to `flowctl catalog delete` directly (no
  # --dangerous-auto-approve). flowctl resolves the live specs under the prefix
  # the same way the dashboard does (reliable — no client-side list parsing),
  # PRINTS the specs it found, then prompts you to type the word "delete" to
  # confirm. Run it attached to the terminal so you see the list and respond.
  info "Asking flowctl to delete everything under ${DELETE_PREFIX}."
  info "It will list the specs and require you to type 'delete' to confirm."
  echo
  if flowctl --profile "${FLOWCTL_PROFILE}" catalog delete --prefix "${DELETE_PREFIX}"; then
    info "Estuary deletion complete."
  else
    # flowctl prints the reason above: "no specs found matching given selector",
    # "delete operation cancelled", or an auth/prefix error.
    warn "Estuary deletion not completed (see flowctl output above). If specs"
    warn "still exist, confirm ESTUARY_PREFIX matches the tenant your token"
    warn "administers ('flowctl auth roles list') and re-run, or delete in the UI."
  fi
else
  warn "ESTUARY_TOKEN/ESTUARY_PREFIX/flowctl missing; skipping Flow cleanup."
fi

# ---------------------------------------------------------------------------
# 3. Drop the Snowflake schema (requires SnowSQL CLI)
# ---------------------------------------------------------------------------
step "3/4 Dropping Snowflake schema ${SNOWFLAKE_DATABASE:-}.${SNOWFLAKE_SCHEMA:-}"
# We use SnowSQL (https://docs.snowflake.com/en/user-guide/snowsql) with
# key-pair auth — the same key used by the materialization.
if command -v snowsql >/dev/null 2>&1; then
  if [ -n "${SNOWFLAKE_SCHEMA:-}" ] && [ -n "${SNOWFLAKE_DATABASE:-}" ]; then
    # snowsql -a wants the bare account id; accept a full URL too and strip it.
    _sf_acct="${SNOWFLAKE_ACCOUNT#https://}"
    _sf_acct="${_sf_acct#http://}"
    _sf_acct="${_sf_acct%%/*}"
    _sf_acct="${_sf_acct%.snowflakecomputing.com}"
    snowsql \
      -a "${_sf_acct}" \
      -u "${SNOWFLAKE_USER}" \
      --private-key-path "${SNOWFLAKE_PRIVATE_KEY_PATH}" \
      -r "${SNOWFLAKE_ROLE}" \
      -w "${SNOWFLAKE_WAREHOUSE}" \
      -d "${SNOWFLAKE_DATABASE}" \
      -q "DROP SCHEMA IF EXISTS ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA} CASCADE;" \
      && info "Snowflake schema dropped." \
      || warn "snowsql DROP SCHEMA failed. Run it manually in Snowsight (see README)."
  else
    warn "SNOWFLAKE_DATABASE/SCHEMA not set; skipping."
  fi
else
  warn "snowsql not installed. Drop the schema manually in Snowsight:"
  warn "  DROP SCHEMA IF EXISTS ${SNOWFLAKE_DATABASE:-<db>}.${SNOWFLAKE_SCHEMA:-<schema>} CASCADE;"
fi

# ---------------------------------------------------------------------------
# 4. Destroy RDS Postgres
# ---------------------------------------------------------------------------
step "4/4 Destroying RDS Postgres with Terraform"
terraform -chdir=terraform destroy -auto-approve -input=false

# Clean up the rendered (secret-bearing) catalog.
rm -f "${ROOT_DIR}/flowctl/flow.generated.yaml"

step "Teardown complete. No demo resources remain."
