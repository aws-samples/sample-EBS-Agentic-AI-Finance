-- =============================================================================
-- XX_P2P_VIEWS_26ai.sql — Purchase-to-Pay (P2P) deterministic reporting views.
--
-- Mirrors the AR XX_COLL_*_V pattern: fast, demo-safe SQL over LIVE EBS AP/PO/RCV
-- that feeds the "AP Control Tower" dashboard and grounds agent NL->SQL.
--
-- Run as COLLECTIONS_AI (needs SELECT on AP/PO/RCV — granted by XX_P2P_GRANTS_26ai.sql).
-- All views are read-only and side-effect free. Idempotent (CREATE OR REPLACE).
-- =============================================================================
set define off
set echo off

-- 1) KPI header strip: invoices in flight, $ on hold, validation/approval backlog.
CREATE OR REPLACE VIEW XX_P2P_KPI_V AS
WITH inv AS (
  SELECT i.invoice_id, i.invoice_num, i.invoice_amount, i.org_id,
         i.vendor_id, i.invoice_date, i.payment_status_flag, i.wfapproval_status,
         NVL((SELECT 'Y' FROM ap.ap_holds_all h
                WHERE h.invoice_id = i.invoice_id AND h.status_flag = 'S'
                  AND ROWNUM = 1), 'N') AS on_hold_flag
  FROM ap.ap_invoices_all i
)
SELECT 1 AS display_order, 'Invoices in flight' AS metric_label,
       COUNT(*) AS metric_value, 'open + unpaid' AS metric_subtext FROM inv
       WHERE payment_status_flag IN ('N','P')
UNION ALL
SELECT 2, 'Invoices on hold', COUNT(*), 'one or more active holds'
  FROM inv WHERE on_hold_flag = 'Y'
UNION ALL
SELECT 3, 'Amount on hold', ROUND(SUM(invoice_amount)),
       'blocked invoice value' FROM inv WHERE on_hold_flag = 'Y'
UNION ALL
SELECT 4, 'Awaiting approval', COUNT(*), 'wfapproval not approved'
  FROM inv WHERE NVL(wfapproval_status,'NOT REQUIRED') NOT IN ('APPROVED','NOT REQUIRED','ACCEPTED')
UNION ALL
SELECT 5, 'Unpaid invoice value', ROUND(SUM(invoice_amount)), 'open payables'
  FROM inv WHERE payment_status_flag IN ('N','P');

-- 2) Every invoice currently on hold + hold type + age + $ (the blockage detail).
--    ONE ROW PER INVOICE. AP_HOLDS_ALL holds one row per invoice LINE/reason, so a single
--    invoice can carry many active hold rows. Reporting at that raw grain fans out the
--    queue (the same invoice repeated N times) and double-counts blocked value. We collapse
--    to invoice grain here: hold_count = number of active holds, hold_type = the dominant
--    (most frequent) hold code, hold_age_days = age of the OLDEST active hold, and
--    invoice_amount appears exactly once so SUM() over this view is the true blocked value.
-- NOTE: keep this statement free of INLINE (mid-statement) "--" comments. SQL*Plus silently
-- swallows a CREATE VIEW that contains inline comments after code on CTE/column lines (the
-- statement neither runs nor errors), which previously left XX_P2P_HOLDS_V uncreated and
-- cascaded ORA-00942 into its dependents. Documentation lives in the block comment above.
-- active = unreleased holds only ('S'); per_type collapses duplicate line-level holds of the
-- same code; ranked picks the dominant hold type per invoice + total hold_count; oldest drives
-- age off the earliest active hold. Final SELECT is one row per invoice (the dominant hold type).
CREATE OR REPLACE VIEW XX_P2P_HOLDS_V AS
WITH active AS (
  SELECT h.invoice_id,
         h.hold_lookup_code AS hold_type,
         h.hold_reason,
         h.creation_date,
         h.held_by
  FROM   ap.ap_holds_all h
  WHERE  h.status_flag = 'S'
),
per_type AS (
  SELECT invoice_id, hold_type,
         COUNT(*)             AS type_cnt,
         MIN(creation_date)   AS first_date,
         MAX(hold_reason)     AS hold_reason,
         MAX(held_by)         AS held_by
  FROM   active
  GROUP  BY invoice_id, hold_type
),
ranked AS (
  SELECT p.*,
         SUM(type_cnt) OVER (PARTITION BY invoice_id)                              AS hold_count,
         ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY type_cnt DESC, hold_type) AS rn
  FROM   per_type p
),
oldest AS (
  SELECT invoice_id, MIN(creation_date) AS hold_since
  FROM   active GROUP BY invoice_id
)
SELECT r.invoice_id,
       i.invoice_num,
       i.org_id,
       i.vendor_id,
       pv.vendor_name,
       r.hold_type,
       r.hold_reason,
       r.hold_count,
       i.invoice_amount,
       i.invoice_currency_code    AS currency,
       o.hold_since,
       ROUND(TRUNC(SYSDATE) - TRUNC(o.hold_since)) AS hold_age_days,
       r.held_by,
       'S'                        AS status_flag
FROM   ranked r
JOIN   ap.ap_invoices_all i ON i.invoice_id = r.invoice_id
LEFT   JOIN ap.ap_suppliers pv ON pv.vendor_id = i.vendor_id
JOIN   oldest o ON o.invoice_id = r.invoice_id
WHERE  r.rn = 1;

-- 3) 2/3-way match status + variance reason per invoice line (matched to PO/receipt).
--    Classifies the common EBS hold drivers into a human-readable reason.
CREATE OR REPLACE VIEW XX_P2P_MATCH_V AS
SELECT il.invoice_id,
       i.invoice_num,
       il.line_number,
       i.vendor_id,
       pv.vendor_name,
       il.po_header_id,
       ph.segment1                AS po_number,
       il.po_line_id,
       il.quantity_invoiced,
       pl.quantity                AS po_quantity,
       il.unit_price              AS invoice_unit_price,
       pl.unit_price              AS po_unit_price,
       (SELECT NVL(SUM(rt.quantity),0) FROM po.rcv_transactions rt
          WHERE rt.po_line_id = il.po_line_id
            AND rt.transaction_type = 'RECEIVE')   AS qty_received,
       CASE
         WHEN il.po_line_id IS NULL THEN 'NO_PO_MATCH'
         WHEN il.unit_price > pl.unit_price THEN 'PRICE_VARIANCE'
         WHEN il.quantity_invoiced >
              (SELECT NVL(SUM(rt.quantity),0) FROM po.rcv_transactions rt
                 WHERE rt.po_line_id = il.po_line_id
                   AND rt.transaction_type = 'RECEIVE') THEN 'QTY_OVER_RECEIPT'
         WHEN il.quantity_invoiced > pl.quantity THEN 'QTY_OVER_ORDER'
         ELSE 'MATCHED'
       END                        AS match_status,
       (il.unit_price - pl.unit_price)                              AS unit_price_variance,
       ROUND((il.unit_price - NULLIF(pl.unit_price,0))
             / NULLIF(pl.unit_price,0) * 100, 2)                    AS price_variance_pct
FROM   ap.ap_invoice_lines_all il
JOIN   ap.ap_invoices_all i ON i.invoice_id = il.invoice_id
LEFT   JOIN ap.ap_suppliers pv ON pv.vendor_id = i.vendor_id
LEFT   JOIN po.po_lines_all pl ON pl.po_line_id = il.po_line_id
LEFT   JOIN po.po_headers_all ph ON ph.po_header_id = il.po_header_id;

-- 4) Exception queue: held / mismatched invoices ranked by $ x age (the worklist).
-- One row per invoice (inherits the invoice grain from XX_P2P_HOLDS_V). hold_count lets
-- the UI show e.g. "QTY ORD x27" instead of repeating the invoice 27 times.
CREATE OR REPLACE VIEW XX_P2P_EXCEPTION_QUEUE_V AS
SELECT h.invoice_id,
       h.invoice_num,
       h.org_id,
       h.vendor_name,
       h.invoice_amount,
       h.currency,
       h.hold_type,
       h.hold_reason,
       h.hold_count,
       ROUND(h.hold_age_days) AS hold_age_days,
       NVL((SELECT MIN(m.match_status) FROM XX_P2P_MATCH_V m
              WHERE m.invoice_id = h.invoice_id
                AND m.match_status <> 'MATCHED'), h.hold_type) AS exception_reason,
       ROUND(h.invoice_amount * (1 + h.hold_age_days/30), 0)   AS priority_score
FROM   XX_P2P_HOLDS_V h;

-- 5) Invoices awaiting approval + age.
CREATE OR REPLACE VIEW XX_P2P_APPROVAL_V AS
SELECT i.invoice_id,
       i.invoice_num,
       i.org_id,
       i.vendor_id,
       pv.vendor_name,
       i.invoice_amount,
       i.invoice_currency_code AS currency,
       i.wfapproval_status,
       i.invoice_date,
       ROUND(TRUNC(SYSDATE) - TRUNC(i.invoice_date)) AS age_days
FROM   ap.ap_invoices_all i
LEFT   JOIN ap.ap_suppliers pv ON pv.vendor_id = i.vendor_id
WHERE  NVL(i.wfapproval_status,'NOT REQUIRED')
         NOT IN ('APPROVED','NOT REQUIRED','ACCEPTED')
  AND  i.payment_status_flag IN ('N','P');

-- 6) AP aging buckets (payables due/overdue).
CREATE OR REPLACE VIEW XX_P2P_AGING_V AS
SELECT bucket_order, aging_bucket, COUNT(*) AS invoice_count,
       ROUND(SUM(amount_remaining)) AS total_amount
FROM (
  SELECT ps.invoice_id, ps.amount_remaining,
         CASE
           WHEN ps.due_date >= TRUNC(SYSDATE) THEN 1
           WHEN TRUNC(SYSDATE) - ps.due_date BETWEEN 1 AND 30 THEN 2
           WHEN TRUNC(SYSDATE) - ps.due_date BETWEEN 31 AND 60 THEN 3
           WHEN TRUNC(SYSDATE) - ps.due_date BETWEEN 61 AND 90 THEN 4
           ELSE 5
         END AS bucket_order,
         CASE
           WHEN ps.due_date >= TRUNC(SYSDATE) THEN 'Not yet due'
           WHEN TRUNC(SYSDATE) - ps.due_date BETWEEN 1 AND 30 THEN '1-30 days'
           WHEN TRUNC(SYSDATE) - ps.due_date BETWEEN 31 AND 60 THEN '31-60 days'
           WHEN TRUNC(SYSDATE) - ps.due_date BETWEEN 61 AND 90 THEN '61-90 days'
           ELSE '90+ days'
         END AS aging_bucket
  FROM ap.ap_payment_schedules_all ps
  WHERE ps.payment_status_flag IN ('N','P')
    AND ps.amount_remaining > 0
)
GROUP BY bucket_order, aging_bucket
ORDER BY bucket_order;

-- 7) Per-supplier in-flight / on-hold / exception summary.
CREATE OR REPLACE VIEW XX_P2P_VENDOR_SUMMARY_V AS
SELECT pv.vendor_id,
       pv.vendor_name,
       COUNT(i.invoice_id)                                   AS total_invoices,
       SUM(CASE WHEN i.payment_status_flag IN ('N','P') THEN 1 ELSE 0 END) AS open_invoices,
       ROUND(SUM(CASE WHEN i.payment_status_flag IN ('N','P')
                      THEN i.invoice_amount ELSE 0 END))      AS open_amount,
       (SELECT COUNT(*) FROM XX_P2P_HOLDS_V h WHERE h.vendor_id = pv.vendor_id) AS invoices_on_hold
FROM   ap.ap_suppliers pv
JOIN   ap.ap_invoices_all i ON i.vendor_id = pv.vendor_id
GROUP  BY pv.vendor_id, pv.vendor_name;

-- 8) Pipeline funnel counts (the dashboard centrepiece): one row, stage counts.
CREATE OR REPLACE VIEW XX_P2P_PIPELINE_V AS
SELECT
  (SELECT COUNT(*) FROM ap.ap_invoices_all)                                          AS received,
  (SELECT COUNT(*) FROM ap.ap_invoices_all WHERE invoice_amount IS NOT NULL)         AS extracted,
  (SELECT COUNT(*) FROM ap.ap_invoices_all i
     WHERE NOT EXISTS (SELECT 1 FROM ap.ap_holds_all h
                        WHERE h.invoice_id = i.invoice_id AND h.status_flag = 'S'))  AS matched,
  (SELECT COUNT(*) FROM ap.ap_invoices_all
     WHERE NVL(wfapproval_status,'NOT REQUIRED') IN ('APPROVED','NOT REQUIRED','ACCEPTED')) AS approved,
  (SELECT COUNT(*) FROM ap.ap_payment_schedules_all
     WHERE payment_status_flag IN ('N','P'))                                         AS scheduled,
  (SELECT COUNT(*) FROM ap.ap_invoices_all WHERE payment_status_flag = 'Y')          AS paid
FROM dual;

prompt === XX_P2P views created — status ===
SELECT object_name, status FROM user_objects
 WHERE object_type='VIEW' AND object_name LIKE 'XX_P2P%' ORDER BY object_name;
