#!/usr/bin/env bash
# dms-inventory.sh: read-only AWS DMS workload inventory for Estuary sizing
#
# Inventories a DMS deployment and reports, per task, the schemas/tables
# replicated, full-load row counts, and CDC change volume (row counts from
# DMS table statistics; bytes/day estimated from CloudWatch bandwidth).
#
# Read-only. The script calls dms describe-*, cloudwatch list-metrics,
# cloudwatch get-metric-statistics, ce get-cost-and-usage (optional), and
# sts get-caller-identity, and nothing else. iam-policy.json in this
# repository is the matching least-privilege policy.
#
# Requirements: aws CLI v2, python3.
#
# Usage:
#   ./dms-inventory.sh
#
#   Optional flags:
#     --profile PROFILE   named AWS profile (default: the default credential chain)
#     --region REGION     inventory one region only. Default: scan every
#                         enabled region (ec2:DescribeRegions) and inventory
#                         each one that has DMS resources.
#     --days N            CloudWatch lookback for CDC averaging (default 14)
#
# Output: human-readable report on stdout, saved to
#   ./dms-inventory-report-<account>-<region>-<date>.txt
#
# Table sizes in bytes: DMS table statistics are row counts only. The report
# footer prints the read-only SQL to run on the source database to get bytes
# per table.

set -euo pipefail

DAYS=14
PROFILE=""
REGION_ARG=""
AWSARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2";    AWSARGS+=(--profile "$2"); shift 2;;
    --region)  REGION_ARG="$2"; AWSARGS+=(--region "$2");  shift 2;;
    --days)    DAYS="$2"; shift 2;;
    *) echo "unknown argument: $1" >&2; exit 1;;
  esac
done
[[ "$DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "--days must be a positive integer (got: $DAYS)" >&2; exit 1; }

AWS() { aws ${AWSARGS[@]+"${AWSARGS[@]}"} --output json "$@"; }

command -v aws >/dev/null     || { echo "aws CLI not found. Install from https://aws.amazon.com/cli/ or run this in AWS CloudShell." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found. Install Python 3 from https://www.python.org/downloads/ or run this in AWS CloudShell." >&2; exit 1; }

# AWS CLI v1 lacks the DMS Serverless commands; the report would silently omit
# serverless replications. Warn, don't block.
CLI_MAJOR="$(aws --version 2>&1 | sed -E 's|^aws-cli/([0-9]+).*|\1|')"
if [[ "$CLI_MAJOR" != "2" ]]; then
  echo "WARNING: AWS CLI v2 is required for DMS Serverless inventory (found: $(aws --version 2>&1))." >&2
  echo "         Serverless replications will be MISSING from this report. Install v2: https://aws.amazon.com/cli/" >&2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILLOG="$WORK/call-failures.txt"
: > "$FAILLOG"

# try <label> <fallback-json> <outfile> <command...>
# On failure, writes the fallback and records the label with the last stderr
# line, so the report can warn that resources may be missing.
try() {
  local label="$1" fallback="$2" out="$3"; shift 3
  if ! "$@" > "$out" 2>"$WORK/stderr.tmp"; then
    echo "$label: $(tail -n 1 "$WORK/stderr.tmp" | cut -c1-200)" >> "$FAILLOG"
    echo "$fallback" > "$out"
  fi
}

if ! ACCOUNT="$(AWS sts get-caller-identity --query Account --output text 2>"$WORK/sts-err")"; then
  echo "AWS credentials are not working for this profile:" >&2
  sed 's/^/  /' "$WORK/sts-err" >&2
  echo "Fix: 'aws configure' (access keys), 'aws sso login' (SSO), or pass --profile <name>." >&2
  exit 1
fi
REGION="$(aws ${AWSARGS[@]+"${AWSARGS[@]}"} configure get region 2>/dev/null || true)"
[[ -z "$REGION" ]] && REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-unknown}}"

# Default: find every enabled region with DMS resources, then run this script
# once per such region (one report file each), so one run covers the account.
# --region skips the scan and inventories that region only.
if [[ -z "$REGION_ARG" ]]; then
  REGIONS="$(AWS ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null | tr '\t' '\n' | sort)" || true
  if [[ -z "$REGIONS" ]]; then
    echo "WARNING: could not list regions (needs ec2:DescribeRegions); falling back to" >&2
    echo "the default region ($REGION). Use --region to inventory others." >&2
  fi
  if [[ -n "$REGIONS" ]]; then
  NREG="$(echo "$REGIONS" | wc -w | tr -d ' ')"
  echo "Scanning $NREG enabled regions for DMS resources (probes run in parallel) ..." >&2
  mkdir -p "$WORK/probe"
  for r in $REGIONS; do
    (
      p() { aws ${AWSARGS[@]+"${AWSARGS[@]}"} --region "$r" --output json dms "$@" 2>/dev/null; }
      t="$(p describe-replication-tasks --without-settings --query 'length(ReplicationTasks)')" || t=""
      i="$(p describe-replication-instances --query 'length(ReplicationInstances)')" || i=""
      # CLI v1 lacks this command; treat failure as zero (the v1 warning covers it)
      c="$(p describe-replication-configs --query 'length(ReplicationConfigs)')" || c=0
      if [[ -z "$t" || -z "$i" ]]; then
        echo "err" > "$WORK/probe/$r"
      else
        echo "$(( t + i + c ))" > "$WORK/probe/$r"
      fi
    ) &
  done
  wait
  FOUND=0
  SKIPPED=""
  for r in $REGIONS; do
    v="$(cat "$WORK/probe/$r" 2>/dev/null || echo err)"
    if [[ "$v" == "err" ]]; then
      SKIPPED="$SKIPPED $r"
    elif (( v > 0 )); then
      FOUND=1
      echo "  $r: DMS resources found, running inventory ..." >&2
      "$0" ${PROFILE:+--profile "$PROFILE"} --days "$DAYS" --region "$r"
    fi
  done
  if (( FOUND )); then
    echo "" >&2
    echo "Done. One report per region was written; send all of them back:" >&2
    ls -1 "dms-inventory-report-$ACCOUNT-"*"-$(date -u +%Y%m%d).txt" 2>/dev/null | sed 's/^/  /' >&2 || true
  else
    echo "No DMS resources found in any probed region of account $ACCOUNT." >&2
  fi
  [[ -n "$SKIPPED" ]] && echo "WARNING: could not probe (API errors):$SKIPPED" >&2
  exit 0
  fi
fi

echo "Scoping DMS in account $ACCOUNT ($REGION), CloudWatch lookback ${DAYS}d ..." >&2

# ---- inventory (all read-only) ----------------------------------------------
try "dms describe-endpoints"             '{"Endpoints":[]}'            "$WORK/endpoints.json"    AWS dms describe-endpoints
try "dms describe-replication-instances" '{"ReplicationInstances":[]}' "$WORK/instances.json"    AWS dms describe-replication-instances
try "dms describe-replication-tasks"     '{"ReplicationTasks":[]}'     "$WORK/tasks.json"        AWS dms describe-replication-tasks --without-settings
# Serverless (AWS CLI v1 lacks these commands; the v1 warning above covers it)
try "dms describe-replication-configs"   '{"ReplicationConfigs":[]}'   "$WORK/configs.json"      AWS dms describe-replication-configs
try "dms describe-replications"          '{"Replications":[]}'         "$WORK/replications.json" AWS dms describe-replications

# Per-task table statistics (provisioned)
mkdir -p "$WORK/tablestats" "$WORK/srvtablestats"
python3 -c "import json;print('\n'.join(t['ReplicationTaskArn'] for t in json.load(open('$WORK/tasks.json'))['ReplicationTasks']))" |
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  id="${arn##*:}"
  try "dms describe-table-statistics ($id)" '{"TableStatistics":[]}' "$WORK/tablestats/$id.json" \
    AWS dms describe-table-statistics --replication-task-arn "$arn"
done

# Per-config table statistics (serverless)
python3 -c "import json;print('\n'.join(c['ReplicationConfigArn'] for c in json.load(open('$WORK/configs.json'))['ReplicationConfigs']))" |
while IFS= read -r arn; do
  [[ -z "$arn" ]] && continue
  id="${arn##*:}"
  try "dms describe-replication-table-statistics ($id)" '{"ReplicationTableStatistics":[]}' "$WORK/srvtablestats/$id.json" \
    AWS dms describe-replication-table-statistics --replication-config-arn "$arn"
done

# CloudWatch metric inventory for AWS/DMS (dimension sets are discovered, not
# guessed; serverless dimensions differ from provisioned)
try "cloudwatch list-metrics" '{"Metrics":[]}' "$WORK/cw-metrics.json" AWS cloudwatch list-metrics --namespace AWS/DMS

# Actual DMS spend from Cost Explorer (ce:GetCostAndUsage; global endpoint).
# Last 3 full months + month-to-date, grouped by usage type. Tolerate failure
# (CE not enabled, or IAM denies billing reads).
CE_START="$(python3 -c "import datetime as d;t=d.date.today();m=t.month-3;y=t.year+(m-1)//12;print(d.date(y,(m-1)%12+1,1))")"
CE_END="$(python3 -c "import datetime as d;print(d.date.today())")"
AWS ce get-cost-and-usage \
    --time-period "Start=$CE_START,End=$CE_END" \
    --granularity MONTHLY \
    --metrics UnblendedCost UsageQuantity \
    --filter '{"And":[{"Dimensions":{"Key":"SERVICE","Values":["AWS Database Migration Service"]}},{"Dimensions":{"Key":"LINKED_ACCOUNT","Values":["'"$ACCOUNT"'"]}}]}' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    > "$WORK/spend.json" 2>/dev/null || echo '{"ResultsByTime":[]}' > "$WORK/spend.json"

# ---- merge + report ----------------------------------------------------------
export SCOPE_WORK="$WORK" SCOPE_DAYS="$DAYS" SCOPE_ACCOUNT="$ACCOUNT" SCOPE_REGION="$REGION"
export SCOPE_PROFILE="$PROFILE" SCOPE_REGION_ARG="$REGION_ARG"
python3 <<'PY'
import json, os, subprocess, sys, datetime

WORK    = os.environ["SCOPE_WORK"]
DAYS    = int(os.environ["SCOPE_DAYS"])
ACCOUNT = os.environ["SCOPE_ACCOUNT"]
REGION  = os.environ["SCOPE_REGION"]
AWSARGS = []
if os.environ.get("SCOPE_PROFILE"):
    AWSARGS += ["--profile", os.environ["SCOPE_PROFILE"]]
if os.environ.get("SCOPE_REGION_ARG"):
    AWSARGS += ["--region", os.environ["SCOPE_REGION_ARG"]]

def load(name, key):
    with open(os.path.join(WORK, name)) as f:
        return json.load(f).get(key, [])

endpoints    = load("endpoints.json", "Endpoints")
instances    = load("instances.json", "ReplicationInstances")
tasks        = load("tasks.json", "ReplicationTasks")
configs      = load("configs.json", "ReplicationConfigs")
replications = load("replications.json", "Replications")
cw_metrics   = load("cw-metrics.json", "Metrics")

ep_by_arn = {e["EndpointArn"]: e for e in endpoints}
repl_by_config = {r.get("ReplicationConfigArn"): r for r in replications}

# Region can be unresolved when credentials come from the environment; the
# endpoint ARNs carry it.
if REGION in ("", "unknown") and endpoints:
    REGION = endpoints[0].get("EndpointArn", "::::unknown").split(":")[3] or "unknown"

failures = []
try:
    with open(os.path.join(WORK, "call-failures.txt")) as f:
        failures = [l for l in f.read().splitlines() if l.strip()]
except FileNotFoundError:
    pass

def ep_desc(arn):
    e = ep_by_arn.get(arn, {})
    s = e.get("EngineName", "?")
    if e.get("ServerName"):   s += " " + e["ServerName"]
    if e.get("DatabaseName"): s += "/" + e["DatabaseName"]
    return s

now = datetime.datetime.now(datetime.timezone.utc)
start = (now - datetime.timedelta(days=DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
end   = now.strftime("%Y-%m-%dT%H:%M:%SZ")

def cw_avg(metric_name, resource_id):
    """Average of a CW metric over the lookback, using whatever dimension set
    CloudWatch actually publishes for this resource (matched by dimension
    value, so it works for provisioned and serverless alike)."""
    for m in cw_metrics:
        if m["MetricName"] != metric_name:
            continue
        if not any(d["Value"] == resource_id for d in m["Dimensions"]):
            continue
        dims = []
        for d in m["Dimensions"]:
            dims += ["Name=%s,Value=%s" % (d["Name"], d["Value"])]
        cmd = ["aws"] + AWSARGS + ["--output", "json",
               "cloudwatch", "get-metric-statistics",
               "--namespace", "AWS/DMS", "--metric-name", metric_name,
               "--start-time", start, "--end-time", end,
               "--period", "3600", "--statistics", "Average",
               "--dimensions"] + dims
        try:
            out = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True).stdout)
            pts = out.get("Datapoints", [])
            if pts:
                return sum(p["Average"] for p in pts) / len(pts)
        except Exception:
            pass
    return None

def n(x): return format(int(x), ",")

def table_rows(stats):
    out, totals = [], {"rows": 0, "chg": 0}
    for t in sorted(stats, key=lambda t: -(t.get("FullLoadRows") or 0)):
        ins, upd, dele = (t.get("Inserts") or 0), (t.get("Updates") or 0), (t.get("Deletes") or 0)
        chg = ins + upd + dele
        totals["rows"] += t.get("FullLoadRows") or 0
        totals["chg"]  += chg
        out.append((t.get("SchemaName", "?"), t.get("TableName", "?"),
                    t.get("FullLoadRows") or 0, ins, upd, dele, t.get("TableState", "")))
    return out, totals

def parse_dt(s):
    if not s: return None
    if isinstance(s, str):
        try: return datetime.datetime.fromisoformat(s)
        except ValueError: return None
    return None

report = []
P = report.append

def H(title):
    P("")
    P("=" * 78)
    P(title)
    P("=" * 78)

P("=" * 78)
P("DMS WORKLOAD INVENTORY: account %s, region %s, %s" % (ACCOUNT, REGION, now.strftime("%Y-%m-%d %H:%MZ")))
P("=" * 78)

if failures:
    P("")
    P("WARNING: %d AWS API call(s) failed, so the sections below may be missing" % len(failures))
    P("resources. Failed calls:")
    for line in failures:
        P("  " + line)

src_eps = sorted({t["SourceEndpointArn"] for t in tasks} | {c["SourceEndpointArn"] for c in configs})
tgt_eps = sorted({t["TargetEndpointArn"] for t in tasks} | {c["TargetEndpointArn"] for c in configs})
src_engines = sorted({ep_by_arn.get(a, {}).get("EngineName", "?") for a in src_eps})
tgt_engines = sorted({ep_by_arn.get(a, {}).get("EngineName", "?") for a in tgt_eps})
inst_classes = {}
for i in instances:
    inst_classes[i["ReplicationInstanceClass"]] = inst_classes.get(i["ReplicationInstanceClass"], 0) + 1

H("1. INVENTORY")
P("  Replication instances : %d  %s" % (len(instances),
    "(" + ", ".join("%dx %s" % (v, k) for k, v in sorted(inst_classes.items())) + ")" if instances else ""))
P("  Serverless configs    : %d  %s" % (len(configs),
    "(" + ", ".join("%s [%s-%s DCU]" % (c["ReplicationConfigIdentifier"],
        c.get("ComputeConfig", {}).get("MinCapacityUnits", "?"),
        c.get("ComputeConfig", {}).get("MaxCapacityUnits", "?")) for c in configs) + ")" if configs else ""))
by_type = {}
for t in tasks: by_type[t["MigrationType"]] = by_type.get(t["MigrationType"], 0) + 1
for c in configs: by_type[c.get("ReplicationType", "?")] = by_type.get(c.get("ReplicationType", "?"), 0) + 1
P("  Tasks / replications  : %d provisioned + %d serverless  (%s)" % (len(tasks), len(configs),
    ", ".join("%s: %d" % kv for kv in sorted(by_type.items()))))
P("  Distinct source endpoints : %d  (engines: %s)" % (len(src_eps), ", ".join(src_engines) or "-"))
P("  Distinct target endpoints : %d  (engines: %s)" % (len(tgt_eps), ", ".join(tgt_engines) or "-"))

def emit_workload(kind, name, status, mig_type, src_arn, tgt_arn, stats, start_dt, resource_id, mappings=None):
    sys.stderr.write("  %s %s: collecting CloudWatch metrics ...\n" % (kind.lower(), name))
    sys.stderr.flush()
    rows, totals = table_rows(stats)
    elapsed_days = None
    if start_dt:
        elapsed_days = max((now - start_dt).total_seconds() / 86400.0, 1e-9)
    P("")
    P("-" * 78)
    P("%s %s  [%s, %s]" % (kind, name, status, mig_type))
    P("  source: %s" % ep_desc(src_arn))
    P("  target: %s" % ep_desc(tgt_arn))
    rules = []
    if mappings:
        try:
            rules = json.loads(mappings).get("rules", [])
        except (ValueError, TypeError):
            rules = []
    sel = [r for r in rules if r.get("rule-type") == "selection"]
    tx  = [r for r in rules if r.get("rule-type") == "transformation"]
    if sel:
        P("  table selection rules (%s matches any):" % "%")
        for r in sel:
            loc = r.get("object-locator", {})
            nf = len(r.get("filters") or [])
            extra = "  (+%d column filter%s)" % (nf, "s" if nf != 1 else "") if nf else ""
            P("    %-8s %s.%s%s" % (r.get("rule-action", "include"),
                loc.get("schema-name", "?"), loc.get("table-name", "?"), extra))
    if tx:
        actions = {}
        for r in tx:
            actions[r.get("rule-action", "?")] = actions.get(r.get("rule-action", "?"), 0) + 1
        P("  transformation rules: %s" % ", ".join("%s x%d" % kv for kv in sorted(actions.items())))
    P("  tables: %d   full-load rows total: %s" % (len(rows), n(totals["rows"])))
    if elapsed_days is not None and totals["chg"]:
        P("  CDC changes since task (re)start %s (%.1f d): %s rows  (~%s rows/day)" % (
            start_dt.strftime("%Y-%m-%d %H:%MZ"), elapsed_days, n(totals["chg"]), n(totals["chg"] / elapsed_days)))
    # CloudWatch bandwidth -> bytes/day estimate
    cw = {}
    for metric in ("CDCThroughputBandwidthSource", "CDCThroughputBandwidthTarget", "CDCThroughputRowsSource"):
        v = cw_avg(metric, resource_id)
        if v is not None:
            cw[metric] = v
    bw = cw.get("CDCThroughputBandwidthSource", cw.get("CDCThroughputBandwidthTarget"))
    if bw is not None:
        side = "source" if "CDCThroughputBandwidthSource" in cw else "target"
        gb_day = bw * 86400 / 1e6
        P("  CDC bandwidth (CloudWatch %s-side, avg of last %dd): %.1f KB/s" % (side, DAYS, bw))
        P("    => incremental volume ~ %.2f GB/day ~ %.0f GB/month" % (gb_day, gb_day * 30))
    if "CDCThroughputRowsSource" in cw:
        P("  CDC row rate (CloudWatch source, avg): %.1f rows/s" % cw["CDCThroughputRowsSource"])
    if rows:
        P("")
        w_s = max([len(r[0]) for r in rows] + [6]); w_t = max([len(r[1]) for r in rows] + [5])
        P("  %-*s %-*s %15s %12s %12s %12s  %s" % (w_s, "SCHEMA", w_t, "TABLE",
            "FULL_LOAD_ROWS", "INSERTS", "UPDATES", "DELETES", "STATE"))
        for s, t, fl, i, u, d, st in rows:
            P("  %-*s %-*s %15s %12s %12s %12s  %s" % (w_s, s, w_t, t, n(fl), n(i), n(u), n(d), st))
    else:
        P("  (no table statistics; task has not run yet)")

H("2. WORKLOAD DETAIL (one block per task)")
if not tasks and not configs:
    P("  (no tasks or serverless replications found)")

for t in tasks:
    tid = t["ReplicationTaskArn"].split(":")[-1]
    try:
        with open(os.path.join(WORK, "tablestats", tid + ".json")) as f:
            stats = json.load(f).get("TableStatistics", [])
    except FileNotFoundError:
        stats = []
    start_dt = parse_dt(t.get("ReplicationTaskStats", {}).get("FreshStartDate")
                        or t.get("ReplicationTaskStats", {}).get("StartDate")
                        or t.get("ReplicationTaskStartDate"))
    emit_workload(
        "TASK", t["ReplicationTaskIdentifier"], t.get("Status", "?"), t.get("MigrationType", "?"),
        t["SourceEndpointArn"], t["TargetEndpointArn"], stats, start_dt, tid,
        t.get("TableMappings"))

for c in configs:
    cid = c["ReplicationConfigArn"].split(":")[-1]
    try:
        with open(os.path.join(WORK, "srvtablestats", cid + ".json")) as f:
            stats = json.load(f).get("ReplicationTableStatistics", [])
    except FileNotFoundError:
        stats = []
    repl = repl_by_config.get(c["ReplicationConfigArn"], {})
    start_dt = parse_dt(repl.get("ReplicationStats", {}).get("FreshStartDate")
                        or repl.get("ReplicationStats", {}).get("StartDate"))
    emit_workload(
        "SERVERLESS", c["ReplicationConfigIdentifier"],
        repl.get("Status", "not started"), c.get("ReplicationType", "?"),
        c["SourceEndpointArn"], c["TargetEndpointArn"], stats, start_dt, cid,
        c.get("TableMappings"))

spend = load("spend.json", "ResultsByTime")
H("3. DMS SPEND (Cost Explorer, unblended, by usage type)")
if spend:
    total_by_month = {}
    for period in spend:
        month = period["TimePeriod"]["Start"][:7]
        groups = period.get("Groups", [])
        if not groups and float(period.get("Total", {}).get("UnblendedCost", {}).get("Amount", 0) or 0) == 0:
            continue
        for g in sorted(groups, key=lambda g: -float(g["Metrics"]["UnblendedCost"]["Amount"])):
            cost = float(g["Metrics"]["UnblendedCost"]["Amount"])
            qty  = float(g["Metrics"]["UsageQuantity"]["Amount"])
            unit = g["Metrics"]["UsageQuantity"].get("Unit", "")
            if cost < 0.01 and qty < 1:   # free-tier / data-transfer noise rows
                continue
            total_by_month[month] = total_by_month.get(month, 0) + cost
            P("  %s  %-45s $%10.2f   %12.1f %s" % (month, g["Keys"][0], cost, qty, unit))
    if total_by_month:
        for month in sorted(total_by_month):
            P("  %s  %-45s $%10.2f" % (month, "TOTAL", total_by_month[month]))
    else:
        P("  (no DMS charges found in the lookback window; note that Cost Explorer")
        P("   data lags ~24h, so resources created today won't show yet)")
else:
    P("  Unavailable: Cost Explorer not enabled, or this profile lacks")
    P("  ce:GetCostAndUsage. Ask the account owner for the 'AWS Database")
    P("  Migration Service' line in Cost Explorer, grouped by usage type.")
SIZE_SQL = {
    "postgres": [
        "postgres, all tables:",
        "  SELECT schemaname, relname, n_live_tup AS row_count,",
        "         pg_table_size(relid) / NULLIF(n_live_tup, 0) AS avg_row_bytes",
        "  FROM pg_stat_user_tables ORDER BY pg_table_size(relid) DESC;",
        "postgres, average JSON bytes per row (run per table):",
        "  SELECT avg(octet_length(to_jsonb(t)::text))::int AS avg_json_bytes",
        "  FROM (SELECT * FROM <schema>.<table> LIMIT 1000) t;",
    ],
    "mysql": [
        "mysql, all tables (from engine statistics):",
        "  SELECT table_schema, table_name, table_rows AS row_count,",
        "         avg_row_length AS avg_row_bytes",
        "  FROM information_schema.tables WHERE table_type='BASE TABLE' ORDER BY data_length DESC;",
        "mysql, estimated JSON bytes per row (row bytes plus per-column name overhead):",
        "  SELECT c.table_schema, c.table_name,",
        "         t.avg_row_length + SUM(CHAR_LENGTH(c.column_name) + 6) AS est_json_bytes",
        "  FROM information_schema.columns c",
        "  JOIN information_schema.tables t",
        "    ON t.table_schema=c.table_schema AND t.table_name=c.table_name",
        "  WHERE t.table_type='BASE TABLE'",
        "  GROUP BY c.table_schema, c.table_name, t.avg_row_length;",
    ],
    "sqlserver": [
        "sqlserver, all tables:",
        "  SELECT s.name AS schema_name, t.name AS table_name,",
        "         SUM(p.row_count) AS row_count,",
        "         SUM(p.used_page_count) * 8192 / NULLIF(SUM(p.row_count), 0) AS avg_row_bytes",
        "  FROM sys.dm_db_partition_stats p",
        "  JOIN sys.tables t ON t.object_id = p.object_id",
        "  JOIN sys.schemas s ON s.schema_id = t.schema_id",
        "  WHERE p.index_id IN (0, 1)",
        "  GROUP BY s.name, t.name ORDER BY SUM(p.used_page_count) DESC;",
        "sqlserver, average JSON bytes per row (run per table):",
        "  SELECT AVG(DATALENGTH(j)) AS avg_json_bytes FROM (",
        "    SELECT TOP 1000 (SELECT t.* FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS j",
        "    FROM <schema>.<table> t) x;",
    ],
    "oracle": [
        "oracle, all tables (optimizer statistics; refresh with DBMS_STATS if stale;",
        "                    use all_tables if dba_tables is not accessible):",
        "  SELECT owner, table_name, num_rows AS row_count, avg_row_len AS avg_row_bytes",
        "  FROM dba_tables WHERE owner NOT IN ('SYS','SYSTEM')",
        "  ORDER BY num_rows * avg_row_len DESC;",
        "oracle, average JSON bytes per row (run per table; 19c+; 1% sample):",
        "  SELECT AVG(LENGTH(JSON_OBJECT(* RETURNING CLOB))) AS avg_json_bytes",
        "  FROM <schema>.<table> SAMPLE(1);",
    ],
}
ENGINE_FAMILY = {
    "postgres": "postgres", "aurora-postgresql": "postgres",
    "mysql": "mysql", "aurora": "mysql", "mariadb": "mysql",
    "sqlserver": "sqlserver", "azuredb": "sqlserver",
    "azure-sql-managed-instance": "sqlserver",
    "oracle": "oracle",
}
src_engine_names = {e.get("EngineName", "") for e in endpoints
                    if e.get("EndpointType") == "SOURCE"} | set(src_engines)
families = sorted({ENGINE_FAMILY[e] for e in src_engine_names if e in ENGINE_FAMILY})
no_template = sorted(e for e in src_engine_names
                     if e and e not in ("?", "s3") and e not in ENGINE_FAMILY)

H("4. SOURCE DATABASE SIZE QUERIES (run on the source database)")
P("DMS reports row counts only, so these read-only queries fill the gap: row")
P("counts, average row bytes, and average row size as a JSON document.")
P("Replace <schema>.<table> where present; samples read 1000 rows.")
if not families:
    P("(No relational source endpoints identified in this account/region.)")
for fam in families:
    P("")
    for line in SIZE_SQL[fam]:
        P(line)
if no_template:
    P("")
    P("No size-query template for source engine(s): %s" % ", ".join(no_template))
if families:
    P("")
    P("Note: the JSON figures measure each row serialized as a document, which is")
    P("how change events are sized. They exceed avg_row_bytes because column names")
    P("repeat in every row and numbers and dates serialize as text.")
    P("Total JSON GB ~= row_count x avg_json_bytes.")
stamp = "%s-%s-%s" % (ACCOUNT, REGION, now.strftime("%Y%m%d"))
out_txt = "dms-inventory-report-%s.txt" % stamp
H("5. WHAT TO SEND BACK (copy/paste these three items)")
P("  1. This report (the text above, also saved as ./%s)." % out_txt)
P("  2. The output of the section-4 size queries.")
P("  3. If section 3 printed 'Unavailable': the 'AWS Database Migration Service'")
P("     line from Cost Explorer, grouped by usage type, past 3 months.")
P("")
P("Caveats: CDC insert/update/delete counters reset when a task is restarted or")
P("a table is reloaded, so the rows/day rate covers only the period since the")
P("last restart.")
P("CloudWatch bandwidth is uncompressed wire throughput averaged over %dd," % DAYS)
P("including idle periods; treat GB/month as an estimate to verify in a trial.")

with open(out_txt, "w") as f:
    f.write("\n".join(report) + "\n")

print("\n".join(report))
PY
