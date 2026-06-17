#!/usr/bin/env bash
# Shared helper: derive the effective (unique-per-tenant) Snowflake schema name.
#
# Usage: estuary_demo_schema <base_schema> <estuary_prefix>
#   estuary_demo_schema "estuary_cdc_demo" "wassDemo/estuary-cdc-demo"
#     -> "estuary_cdc_demo_wassdemo"
#
# The result is <base>_<tenant>, where <tenant> is the first path segment of the
# Estuary prefix, lowercased, with every non-alphanumeric char collapsed to '_'
# and trailing underscores trimmed. Deterministic, so start.sh and teardown.sh
# always compute the same value from the same .env.
estuary_demo_schema() {
  local base="$1" prefix="$2" tenant token
  tenant="${prefix%%/*}"
  token="$(printf '%s' "${tenant}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' )"
  token="${token%%_}"        # trim one trailing underscore (from tr's newline)
  token="${token%_}"         # and any remaining trailing underscore
  printf '%s_%s' "${base}" "${token}"
}
