# DMS Inventory

`dms-inventory.sh` is a read-only shell script that inventories the AWS DMS resources in one account
and region. It reports which tables are replicated, how many rows they hold,
and how much change volume flows per day. The output is used to size a
migration of DMS replication workloads.

## Output

The report has five sections:

1. INVENTORY: replication instances, serverless configurations, tasks, and
   source and target engines.
2. WORKLOAD DETAIL: table selection rules (including wildcard patterns),
   tables, full-load row counts, and CDC
   change rates from DMS table statistics and CloudWatch.
3. DMS SPEND: Last three months from Cost Explorer, grouped by usage
   type. If the caller lacks Cost Explorer access, this section reports itself
   unavailable and the rest of the report is unaffected.
4. SOURCE DATABASE SIZE QUERIES: Read-only SQL statements for the source engines found, returning row counts, average row bytes, and average row size serialized as JSON. DMS itself reports row counts only.
5. WHAT TO SEND BACK: Instuctions on what information to share.

[examples/sample-report.txt](examples/sample-report.txt) is output from a real
run, with identifiers anonymized.

## AWS API calls

The script is read-only. It makes the following calls and no others.

| Service | Calls |
|---|---|
| DMS | DescribeEndpoints, DescribeReplicationInstances, DescribeReplicationTasks, DescribeReplicationConfigs, DescribeReplications, DescribeTableStatistics, DescribeReplicationTableStatistics |
| CloudWatch | ListMetrics, GetMetricStatistics (namespace AWS/DMS) |
| EC2 | DescribeRegions (region discovery; without it the script falls back to the default region) |
| Cost Explorer | GetCostAndUsage (optional) |
| STS | GetCallerIdentity (requires no permission) |

Output goes to stdout and to two files in the local working directory. The
report contains schema and table names and row counts, not row data.

[iam-policy.json](iam-policy.json) covers the calls above and nothing else.
If you already run with the AWS managed ReadOnlyAccess policy or broader, you
do not need it; it documents the required scope. To run the script under a
dedicated identity instead, attach it:

```
aws iam put-role-policy --role-name <role> --policy-name dms-inventory-readonly --policy-document file://iam-policy.json
```

(`put-user-policy --user-name <user>` for an IAM user.) The Cost Explorer
statement can be removed; section 3 then reports itself unavailable.

## Requirements

- bash
- AWS CLI v2. The script runs under v1 but DMS Serverless replications are
  then missing from the report, and it prints a warning.
- Python 3, standard library only.

All three are preinstalled in AWS CloudShell and on Amazon Linux EC2
instances.

## Usage

Run it from any of:

- AWS CloudShell
- an EC2 instance with a read-only instance role
- a laptop with the AWS CLI configured

Get the script by cloning the repository:

```
git clone https://github.com/estuary/cdc-quickstart.git
cd cdc-quickstart/migration-tools/dms
```

or by downloading the one file:

```
curl -fsSLO https://raw.githubusercontent.com/estuary/cdc-quickstart/main/migration-tools/dms/dms-inventory.sh
chmod +x dms-inventory.sh
```

Then run the following once per AWS account. The script scans every enabled
region and inventories each one that has DMS resources, writing one report
per region. The credentials select the account.

```
./dms-inventory.sh

# optional flags:
#   --profile PROFILE   named AWS profile (default: the default credential chain)
#   --region REGION     inventory one region only (default: scan all enabled regions)
#   --days N            CloudWatch lookback for CDC averaging (default: 14;
#                       use 30 for an estimate based on a full month)
```

With no flags, the script uses the default AWS credentials and covers all
enabled regions.

## Output files
An inventory report will be generated for each account and region combination. You can either copy/paste the response from the script or share these files directly.

- `dms-inventory-report-<account>-<region>-<date>.txt`: the report, identical
  to stdout. This is the only file the script writes.
