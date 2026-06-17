-- Postgres CDC setup for the Estuary demo.
-- Idempotent: safe to run on every `start.sh` invocation.
-- Run as the RDS master user (see scripts/start.sh).

-- 1. Allow the (non-superuser) master user to drive logical replication.
--    On RDS this capability is granted via the rds_replication role rather
--    than the REPLICATION attribute. GRANT is a no-op if already a member.
DO $$
BEGIN
  EXECUTE 'GRANT rds_replication TO ' || quote_ident(current_user);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'Skipping rds_replication grant: %', SQLERRM;
END $$;

-- 2. Demo tables. ShadowTraffic runs with tablePolicy=manual, so these define
--    the canonical schema.
--
--    Key columns are `uuid` to match ShadowTraffic's `_gen: uuid` (which emits
--    a real uuid value). Using `text` breaks UPDATEs with
--    "operator does not exist: text = uuid".
--
--    The customer_id / transaction_id columns are LOGICAL foreign keys: the
--    generator fills them with real parent ids via lookups, but the constraint
--    is intentionally NOT enforced at the DB. ShadowTraffic writes each table in
--    its own batched transaction with no guarantee a parent commits before its
--    child, so an enforced FK would abort batches and stop all data flow. The
--    relationship is preserved in the data; it just isn't policed by Postgres.
--
--    Dropped and recreated on every run so the schema is always correct and
--    stale data is cleared. ShadowTraffic regenerates the data each start.
DROP TABLE IF EXISTS public.shipments, public.transactions, public.customers CASCADE;

CREATE TABLE public.customers (
  customer_id uuid PRIMARY KEY,
  name        text,
  email       text,
  created_at  timestamptz
);

CREATE TABLE public.transactions (
  transaction_id uuid PRIMARY KEY,
  customer_id    uuid,  -- logical FK -> customers.customer_id (not enforced)
  amount         numeric(12, 2),
  status         text,
  created_at     timestamptz
);

CREATE TABLE public.shipments (
  shipment_id    uuid PRIMARY KEY,
  transaction_id uuid,  -- logical FK -> transactions.transaction_id (not enforced)
  address        text,
  status         text,
  updated_at     timestamptz
);

-- 3. Watermarks table used by the Estuary source-postgres connector to
--    coordinate consistent backfills.
CREATE TABLE IF NOT EXISTS public.flow_watermarks (
  slot      text PRIMARY KEY,
  watermark text
);

-- 4. Publication covering the demo tables (+ watermarks). Recreated cleanly.
DROP PUBLICATION IF EXISTS flow_publication;
CREATE PUBLICATION flow_publication;
ALTER PUBLICATION flow_publication SET (publish_via_partition_root = true);
ALTER PUBLICATION flow_publication
  ADD TABLE public.customers,
            public.transactions,
            public.shipments,
            public.flow_watermarks;

-- 5. Logical replication slot (pgoutput plugin). Created only if absent so
--    re-running this script does not error.
SELECT pg_create_logical_replication_slot('flow_slot', 'pgoutput')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_replication_slots WHERE slot_name = 'flow_slot'
);
