\set ON_ERROR_STOP on

-- Run against a disposable PostgreSQL database as a role allowed to create schemas.
-- All objects and sample rows are rolled back at the end. No existing schema is dropped.
BEGIN;
CREATE SCHEMA partition_demo;
SET LOCAL search_path = partition_demo, pg_catalog;
SET LOCAL TIME ZONE 'UTC';

CREATE TABLE ai_call_record (
  id BIGINT GENERATED ALWAYS AS IDENTITY,
  call_id UUID NOT NULL,
  channel TEXT NOT NULL,
  status TEXT NOT NULL,
  started_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (id, started_at)
) PARTITION BY RANGE (started_at);

CREATE TABLE ai_call_record_20251113 PARTITION OF ai_call_record
  FOR VALUES FROM ('2025-11-13 00:00:00+00') TO ('2025-11-14 00:00:00+00');
CREATE TABLE ai_call_record_20251114 PARTITION OF ai_call_record
  FOR VALUES FROM ('2025-11-14 00:00:00+00') TO ('2025-11-15 00:00:00+00');
CREATE TABLE ai_call_record_20251115 PARTITION OF ai_call_record
  FOR VALUES FROM ('2025-11-15 00:00:00+00') TO ('2025-11-16 00:00:00+00');

-- Synthetic data: one row per minute for three UTC days, not a throughput benchmark.
INSERT INTO ai_call_record (call_id, channel, status, started_at)
SELECT ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
       'demo', CASE WHEN n % 10 = 0 THEN 'failed' ELSE 'ok' END,
       TIMESTAMPTZ '2025-11-13 00:00:00+00' + n * INTERVAL '1 minute'
FROM generate_series(0, 4319) AS series(n);
ANALYZE ai_call_record;

-- Expected: 1440 rows in each of the three partitions.
SELECT tableoid::regclass AS partition_name, count(*)
FROM ai_call_record GROUP BY tableoid ORDER BY partition_name;

-- A single UTC day's range should scan only the November 14 partition.
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM ai_call_record
WHERE started_at >= TIMESTAMPTZ '2025-11-14 00:00:00+00'
  AND started_at < TIMESTAMPTZ '2025-11-15 00:00:00+00';

-- Without a time predicate the lookup must consider all three partitions.
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM ai_call_record
WHERE call_id = '00000000-0000-0000-0000-000000001500';

DO $$
BEGIN
  IF (SELECT count(*) FROM ai_call_record) <> 4320 THEN
    RAISE EXCEPTION 'Unexpected total row count';
  END IF;
  IF (SELECT tableoid::regclass::text FROM ai_call_record
      WHERE started_at = TIMESTAMPTZ '2025-11-14 00:00:00+00')
      IS DISTINCT FROM 'ai_call_record_20251114' THEN
    RAISE EXCEPTION 'Midnight row routed to the wrong partition';
  END IF;

  BEGIN
    INSERT INTO ai_call_record (call_id, channel, status, started_at)
    VALUES ('00000000-0000-0000-0000-999999999999', 'demo', 'ok',
            TIMESTAMPTZ '2025-11-16 00:00:00+00');
    RAISE EXCEPTION 'Expected the missing partition to reject this insert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'Verified: a missing partition rejects the insert';
  END;
END;
$$;

ROLLBACK;
