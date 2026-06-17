#!/usr/bin/env bash
#
# End-to-end latency probe: Postgres -> Estuary Flow -> Snowflake (transactions).
#
# Inserts COUNT tagged row(s) into ONE table (public.transactions) in a single
# transaction, then IMMEDIATELY and CONTINUOUSLY polls each downstream location
# and prints, the instant the row is observed there, how long it has been since
# the Postgres commit (t0):
#
#   collection  = row visible in the Estuary collection   (capture leg)
#   Snowflake   = row queryable in Snowflake               (full end-to-end)
#
# No drain/warm-up wait — polling starts the moment the row is committed.
#
# Usage:
#   ./scripts/latency.sh          # one row
#   ./scripts/latency.sh 5        # five rows committed together; per-row + summary
#
# Env overrides:
#   LATENCY_TIMEOUT=300   seconds to wait for all rows before giving up
#   LATENCY_POLL=1        seconds between poll cycles (snowsql adds its own time)
#
# Caveat: because we do NOT wait for the collection follower to drain its backlog
# first, the *collection* timing for the very first row can include the one-time
# journal-replay time (the follower streams the open fragment before reaching
# live data). The Snowflake timing is unaffected. Drain was removed on request.
#
# Requirements: terraform, psql, snowsql, python3, flowctl (ESTUARY_TOKEN auth).
# The pipeline must be running (./scripts/start.sh).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m    ✓ %s\033[0m\n' "$*" >&2; }
warn() { printf '\033[1;33m    WARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

COUNT="${1:-1}"
TIMEOUT_SECS="${LATENCY_TIMEOUT:-300}"
POLL_SECS="${LATENCY_POLL:-1}"
case "${COUNT}" in ''|*[!0-9]*) die "record count must be a positive integer (got '${COUNT}')";; esac
[ "${COUNT}" -ge 1 ] || die "record count must be >= 1"

# Single table under test.
TABLE="transactions"
ID_COL="transaction_id"
SF_TABLE="TRANSACTIONS"

# ---------------------------------------------------------------------------
# Config & prerequisites
# ---------------------------------------------------------------------------
for bin in terraform psql snowsql python3 flowctl; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is not installed or not on PATH."
done
[ -f "${ROOT_DIR}/.env" ] || die "Missing .env. Copy .env.example to .env and fill it in."
set -a
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"
set +a

: "${SNOWFLAKE_ACCOUNT:?Set SNOWFLAKE_ACCOUNT in .env}"
: "${SNOWFLAKE_USER:?Set SNOWFLAKE_USER in .env}"
: "${SNOWFLAKE_DATABASE:?Set SNOWFLAKE_DATABASE in .env}"
: "${SNOWFLAKE_WAREHOUSE:?Set SNOWFLAKE_WAREHOUSE in .env}"
: "${SNOWFLAKE_ROLE:?Set SNOWFLAKE_ROLE in .env}"
: "${SNOWFLAKE_PRIVATE_KEY_PATH:?Set SNOWFLAKE_PRIVATE_KEY_PATH in .env}"
: "${ESTUARY_PREFIX:?Set ESTUARY_PREFIX in .env}"
: "${ESTUARY_TOKEN:?Set ESTUARY_TOKEN in .env (Dashboard -> Admin -> CLI-API)}"

# Postgres endpoint from Terraform outputs (local state — no AWS call needed).
PGHOST="$(terraform -chdir=terraform output -raw address 2>/dev/null)" \
  || die "Couldn't read Terraform outputs. Is the demo deployed (./scripts/start.sh)?"
PGPORT="$(terraform -chdir=terraform output -raw port)"
PGDATABASE="$(terraform -chdir=terraform output -raw db_name)"
PGUSER="$(terraform -chdir=terraform output -raw username)"
PGPASSWORD="$(terraform -chdir=terraform output -raw password)"
export PGPASSWORD

# Effective (unique-per-tenant) Snowflake schema — same derivation as start/teardown.
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/schema.sh"
SF_SCHEMA="$(estuary_demo_schema "${SNOWFLAKE_SCHEMA}" "${ESTUARY_PREFIX}")"

# Normalize the Snowflake account id (accept a bare id or a full URL).
SF_ACCT="${SNOWFLAKE_ACCOUNT#https://}"; SF_ACCT="${SF_ACCT#http://}"
SF_ACCT="${SF_ACCT%%/*}"; SF_ACCT="${SF_ACCT%.snowflakecomputing.com}"

PG_DSN="host=${PGHOST} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER} sslmode=require"

# Estuary collection reads run as the .env token's identity (dedicated per-tenant
# profile, same as start.sh). `auth token` refuses an ambient FLOW_AUTH_TOKEN.
unset FLOW_AUTH_TOKEN
FLOWCTL_PROFILE="cdc-demo-$(printf '%s' "${ESTUARY_PREFIX%%/*}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//')"
flowctl --profile "${FLOWCTL_PROFILE}" auth token --token "${ESTUARY_TOKEN}" >/dev/null 2>&1 \
  || die "flowctl auth failed. Is ESTUARY_TOKEN current? (Dashboard -> Admin -> CLI-API -> Generate token)"
FC=(flowctl --profile "${FLOWCTL_PROFILE}")

now_ms()   { python3 -c 'import time; print(int(time.time()*1000))'; }
new_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
fmt()      { printf '%d.%03d s' $(( $1 / 1000 )) $(( $1 % 1000 )); }

# Run a single Snowflake query and print the raw result (clean TSV).
sf_query() {
  snowsql -a "${SF_ACCT}" -u "${SNOWFLAKE_USER}" \
    --private-key-path "${SNOWFLAKE_PRIVATE_KEY_PATH}" \
    -r "${SNOWFLAKE_ROLE}" -w "${SNOWFLAKE_WAREHOUSE}" -d "${SNOWFLAKE_DATABASE}" \
    -o output_format=tsv -o header=false -o friendly=false -o timing=false \
    -q "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Estuary collection follower (capture-leg timing)
# ---------------------------------------------------------------------------
# Tail the one collection in the background; the poll loop greps this file
# (cheap, local) to detect when the row reaches the collection. Started right
# before the insert — we do NOT wait for its backlog to drain (see caveat above).
COLL_FILE=""
COLL_PID=""
start_follower() {
  COLL_FILE="$(mktemp)"
  "${FC[@]}" collections read --collection "${ESTUARY_PREFIX}/${TABLE}" \
    --uncommitted --follow --since 0s -o json >"${COLL_FILE}" 2>/dev/null &
  COLL_PID=$!
  disown "${COLL_PID}" 2>/dev/null || true   # silence "Terminated" job-control noise on exit
}
stop_follower() {
  [ -n "${COLL_PID}" ] && kill "${COLL_PID}" 2>/dev/null || true
  [ -n "${COLL_FILE}" ] && rm -f "${COLL_FILE}" 2>/dev/null || true
}
coll_has() { grep -q "\"$1\"" "${COLL_FILE:-/dev/null}" 2>/dev/null; }

info "Postgres : ${PGHOST}:${PGPORT}/${PGDATABASE}"
info "Snowflake: ${SNOWFLAKE_DATABASE}.${SF_SCHEMA}.${SF_TABLE} (account ${SF_ACCT})"
info "Table    : public.${TABLE}"

trap stop_follower EXIT
start_follower

# ---------------------------------------------------------------------------
# Insert COUNT row(s) in one transaction, then poll continuously
# ---------------------------------------------------------------------------
# Per-row state (size COUNT). CAP/SF hold ms since t0, or -1 until observed.
IDS=(); CAP=(); SF=()
vals=""
for (( j=0; j<COUNT; j++ )); do
  id="$(new_uuid)"
  IDS[$j]="${id}"
  CAP[$j]=-1; SF[$j]=-1
  # customer_id is a logical (unenforced) FK here, so a fresh uuid is fine.
  vals="${vals}${vals:+,}('${id}', '${id}', 1.23, '__latency_probe__', now())"
done

psql "${PG_DSN}" -v ON_ERROR_STOP=1 -q -c "
  INSERT INTO public.${TABLE} (${ID_COL}, customer_id, amount, status, created_at)
  VALUES ${vals};" \
  || die "Probe insert into Postgres failed."
t0="$(now_ms)"

step "Inserted ${COUNT} row(s) into public.${TABLE} at t0 — polling each location continuously:"
[ "${COUNT}" -le 8 ] && for (( j=0; j<COUNT; j++ )); do info "#${j} ${ID_COL} = ${IDS[$j]}"; done

# Quoted IN-list of still-pending (not-yet-in-Snowflake) ids.
pending_inlist() {
  local j out=""
  for (( j=0; j<COUNT; j++ )); do
    [ "${SF[$j]}" -lt 0 ] && out="${out}${out:+,}'${IDS[$j]}'"
  done
  printf '%s' "${out}"
}

deadline=$(( t0 + TIMEOUT_SECS * 1000 ))
landed=0
while :; do
  # --- collection (capture leg): instant local greps ---
  for (( j=0; j<COUNT; j++ )); do
    if [ "${CAP[$j]}" -lt 0 ] && coll_has "${IDS[$j]}"; then
      CAP[$j]=$(( $(now_ms) - t0 ))
      ok "$(printf '#%-3d' "${j}") seen in collection after $(fmt "${CAP[$j]}")"
    fi
  done
  # --- Snowflake (end to end): one query for all pending ids ---
  inlist="$(pending_inlist)"
  if [ -n "${inlist}" ]; then
    found="$(sf_query "SELECT ${ID_COL} FROM ${SNOWFLAKE_DATABASE}.${SF_SCHEMA}.${SF_TABLE} WHERE ${ID_COL} IN (${inlist});")"
    if [ -n "${found}" ]; then
      nowm="$(now_ms)"
      while IFS= read -r fid; do
        [ -z "${fid}" ] && continue
        for (( j=0; j<COUNT; j++ )); do
          if [ "${SF[$j]}" -lt 0 ] && [ "${IDS[$j]}" = "${fid}" ]; then
            SF[$j]=$(( nowm - t0 )); landed=$(( landed + 1 ))
            ok "$(printf '#%-3d' "${j}") seen in Snowflake  after $(fmt "${SF[$j]}")"
            break
          fi
        done
      done <<< "${found}"
    fi
  fi

  [ "${landed}" -ge "${COUNT}" ] && break
  now="$(now_ms)"
  if [ "${now}" -gt "${deadline}" ]; then
    warn "Timed out after ${TIMEOUT_SECS}s — ${landed}/${COUNT} rows reached Snowflake."
    break
  fi
  sleep "${POLL_SECS}"
done

# ---------------------------------------------------------------------------
# Summary (multiple rows only)
# ---------------------------------------------------------------------------
if [ "${COUNT}" -gt 1 ]; then
  cap_list=""; sf_list=""
  for (( j=0; j<COUNT; j++ )); do
    [ "${CAP[$j]}" -ge 0 ] && cap_list="${cap_list} ${CAP[$j]}"
    [ "${SF[$j]}"  -ge 0 ] && sf_list="${sf_list} ${SF[$j]}"
  done
  step "Latency over ${COUNT} rows"
  summarize() { # label  ms...
    local label="$1"; shift
    [ "$#" -eq 0 ] && { info "$(printf '%-16s no deliveries' "${label}")"; return; }
    printf '%s\n' "$@" | python3 -c "
import sys
v=sorted(int(x) for x in sys.stdin.read().split()); n=len(v); f=lambda m:f'{m/1000:.3f}s'
print('    %-16s min %s  avg %s  max %s  (n=%d)' % ('${label}', f(v[0]), f(sum(v)/n), f(v[-1]), n))
" >&2
  }
  summarize "collection" ${cap_list}
  summarize "Snowflake"  ${sf_list}
fi
