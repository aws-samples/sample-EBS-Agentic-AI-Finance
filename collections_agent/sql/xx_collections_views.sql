-- =============================================================================
-- xx_collections_views.sql
-- Deterministic reporting views for the APEX dashboard (EBS Collections 26ai).
-- Run as COLLECTIONS_AI in the ERPUAT PDB.
--
-- WHY DETERMINISTIC SQL (not SELECT AI) FOR THE DASHBOARD:
--   Dashboard KPIs load on every page view. Hardcoded, reviewed SQL is fast,
--   repeatable and safe to demo to enterprise customers. SELECT AI (the headline
--   feature) is reserved for the interactive "Ask AI" page where natural-language
--   exploration is the point.
--
-- Source tables (live EBS 12.2 AR schema, verified):
--   AR.AR_PAYMENT_SCHEDULES_ALL  (open items, amount_due_remaining, due_date)
--   AR.HZ_CUST_ACCOUNTS          (account_number, cust_account_id -> party_id)
--   AR.HZ_PARTIES                (party_name)
--   AR.RA_CUSTOMER_TRX_ALL       (trx_number / invoice number)
--   AR.HZ_CUSTOMER_PROFILES      (credit_hold flag)
--
-- COLLECTIONS_AI must already have SELECT on the AR.* tables above (granted during
-- SELECT AI setup — see XX_SELECT_AI_SETUP_26ai.sql). These views run with the
-- COLLECTIONS_AI user's privileges.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- KPI cards: total open, total overdue, count of open invoices, customers overdue
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW xx_coll_kpi_v AS
WITH base AS (
  SELECT aps.amount_due_remaining amt,
         aps.due_date,
         aps.customer_id,
         CASE WHEN aps.due_date < TRUNC(SYSDATE) THEN 1 ELSE 0 END is_overdue
  FROM   ar.ar_payment_schedules_all aps
  WHERE  aps.status = 'OP'
  AND    aps.amount_due_remaining > 0
)
SELECT 1 display_order,
       'Total Outstanding' metric_label,
       TO_CHAR(SUM(amt),'FM$999,999,999,990') metric_value,
       COUNT(*)||' open invoices' metric_subtext,
       'fa-money' icon_class
FROM   base
UNION ALL
SELECT 2,
       'Total Overdue',
       TO_CHAR(SUM(CASE WHEN is_overdue=1 THEN amt ELSE 0 END),'FM$999,999,999,990'),
       SUM(is_overdue)||' overdue invoices',
       'fa-exclamation-triangle'
FROM   base
UNION ALL
SELECT 3,
       'Customers Overdue',
       TO_CHAR(COUNT(DISTINCT CASE WHEN is_overdue=1 THEN customer_id END)),
       'with at least one overdue item',
       'fa-users'
FROM   base
UNION ALL
SELECT 4,
       'Avg Days Overdue',
       TO_CHAR(ROUND(AVG(CASE WHEN is_overdue=1 THEN TRUNC(SYSDATE)-TRUNC(due_date) END))),
       'across overdue invoices',
       'fa-clock-o'
FROM   base;

-- -----------------------------------------------------------------------------
-- AR aging buckets
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW xx_coll_aging_v AS
SELECT bucket_order, aging_bucket, SUM(amount_due_remaining) total_amount
FROM (
  SELECT aps.amount_due_remaining,
         CASE
           WHEN aps.due_date >= TRUNC(SYSDATE)                       THEN 'Current'
           WHEN TRUNC(SYSDATE)-TRUNC(aps.due_date) BETWEEN 1 AND 30  THEN '1-30 days'
           WHEN TRUNC(SYSDATE)-TRUNC(aps.due_date) BETWEEN 31 AND 60 THEN '31-60 days'
           WHEN TRUNC(SYSDATE)-TRUNC(aps.due_date) BETWEEN 61 AND 90 THEN '61-90 days'
           ELSE '90+ days'
         END aging_bucket,
         CASE
           WHEN aps.due_date >= TRUNC(SYSDATE)                       THEN 1
           WHEN TRUNC(SYSDATE)-TRUNC(aps.due_date) BETWEEN 1 AND 30  THEN 2
           WHEN TRUNC(SYSDATE)-TRUNC(aps.due_date) BETWEEN 31 AND 60 THEN 3
           WHEN TRUNC(SYSDATE)-TRUNC(aps.due_date) BETWEEN 61 AND 90 THEN 4
           ELSE 5
         END bucket_order
  FROM   ar.ar_payment_schedules_all aps
  WHERE  aps.status = 'OP'
  AND    aps.amount_due_remaining > 0
)
GROUP BY bucket_order, aging_bucket;

-- -----------------------------------------------------------------------------
-- Top risk customers (overdue ranking)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW xx_coll_risk_customers_v AS
SELECT hca.cust_account_id           customer_id,
       hca.account_number,
       hp.party_name,
       SUM(aps.amount_due_remaining) total_overdue,
       MAX(TRUNC(SYSDATE)-TRUNC(aps.due_date)) max_days_overdue,
       COUNT(*)                      open_invoices
FROM   ar.ar_payment_schedules_all aps
JOIN   ar.hz_cust_accounts hca ON hca.cust_account_id = aps.customer_id
JOIN   ar.hz_parties       hp  ON hp.party_id        = hca.party_id
WHERE  aps.status = 'OP'
AND    aps.amount_due_remaining > 0
AND    aps.due_date < TRUNC(SYSDATE)
GROUP BY hca.cust_account_id, hca.account_number, hp.party_name;

-- -----------------------------------------------------------------------------
-- Collections trend (overdue amount by due-month, last 12 months)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW xx_coll_trend_v AS
SELECT TO_CHAR(TRUNC(aps.due_date,'MM'),'YYYY-MM')          period_label,
       TO_NUMBER(TO_CHAR(TRUNC(aps.due_date,'MM'),'YYYYMM')) period_order,
       SUM(aps.amount_due_remaining)                        overdue_amount
FROM   ar.ar_payment_schedules_all aps
WHERE  aps.status = 'OP'
AND    aps.amount_due_remaining > 0
AND    aps.due_date >= ADD_MONTHS(TRUNC(SYSDATE,'MM'), -11)
GROUP BY TRUNC(aps.due_date,'MM');

-- -----------------------------------------------------------------------------
-- Customer summary (drilldown header)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW xx_coll_customer_summary_v AS
SELECT hca.cust_account_id           customer_id,
       hp.party_name,
       hca.account_number,
       NVL(SUM(CASE WHEN aps.status='OP' THEN aps.amount_due_remaining END),0) total_overdue,
       -- Credit-hold flag read as a scalar subquery so it is independent of the
       -- invoice-aging fan-out in the LEFT JOIN below. Previously this was a
       -- MAX(hcp.credit_hold) over a join, which combined with the aging fan-out and the
       -- profile join could drop the hold and report 'N' for a customer who was on hold.
       --
       -- Scope MUST match the write path: XX_COLLECTIONS_REST_PKG.get_customer_profile
       -- (used by place/release_credit_hold) reads and updates the ACCOUNT-LEVEL profile
       -- row (site_use_id IS NULL) via HZ_CUSTOMER_PROFILE_V2PUB. The customer-level credit
       -- hold lives on that row, so the dashboard reads the same row — otherwise the summary
       -- and the release action can disagree ("on hold" here, "no_hold" on release).
       (SELECT NVL(MAX(hcp.credit_hold),'N')
          FROM ar.hz_customer_profiles hcp
         WHERE hcp.cust_account_id = hca.cust_account_id
           AND hcp.site_use_id IS NULL) credit_hold_flag,
       COUNT(CASE WHEN aps.status='OP' AND aps.amount_due_remaining>0 THEN 1 END) open_invoices
FROM   ar.hz_cust_accounts hca
JOIN   ar.hz_parties       hp  ON hp.party_id = hca.party_id
LEFT   JOIN ar.ar_payment_schedules_all aps ON aps.customer_id = hca.cust_account_id
GROUP BY hca.cust_account_id, hp.party_name, hca.account_number;

-- -----------------------------------------------------------------------------
-- Open invoices for a customer (drilldown grid)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW xx_coll_open_invoices_v AS
SELECT aps.customer_id,
       rct.trx_number                          invoice_number,
       aps.due_date,
       aps.amount_due_remaining,
       GREATEST(0, TRUNC(SYSDATE)-TRUNC(aps.due_date)) days_overdue
FROM   ar.ar_payment_schedules_all aps
JOIN   ar.ra_customer_trx_all rct ON rct.customer_trx_id = aps.customer_trx_id
WHERE  aps.status = 'OP'
AND    aps.amount_due_remaining > 0;
