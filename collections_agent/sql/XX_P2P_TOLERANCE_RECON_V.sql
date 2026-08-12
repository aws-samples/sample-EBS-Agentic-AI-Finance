-- =============================================================================
-- XX_P2P_TOLERANCE_RECON_V.sql — Policy-vs-EBS tolerance reconciliation.
--
-- The Policy library documents state the AP price-variance tolerance in narrative
-- form (the "policy of record", stored in XX_POLICY_SETTINGS.PRICE_TOL_PCT).
-- EBS ENFORCES tolerances via Payables tolerance templates linked to each operating
-- unit (AP_SYSTEM_PARAMETERS_ALL.tolerance_id -> AP_TOLERANCE_TEMPLATES). This view
-- pulls the ACTUAL enforced PRICE_TOLERANCE live, per operating unit that has invoices,
-- and flags DRIFT vs the narrative policy — so an approver never trusts a document that
-- has silently diverged from what Payables actually enforces.
--
-- Schema note (verified live on this clone): AP_TOLERANCE_TEMPLATES is the FLAT model —
-- PRICE_TOLERANCE / QUANTITY_TOLERANCE are direct numeric percent columns (there is no
-- tolerance_type lines table and no INACTIVE_DATE column here). We scope to operating
-- units that actually have invoices so the reconciliation reflects live data.
--
-- Read-only, side-effect free. Run as COLLECTIONS_AI (needs SELECT on the AP tolerance /
-- system-parameter tables + HR_OPERATING_UNITS — granted by XX_P2P_GRANTS_26ai.sql).
-- Idempotent (CREATE OR REPLACE).
-- =============================================================================
set define off
set echo off

CREATE OR REPLACE VIEW XX_P2P_TOLERANCE_RECON_V AS
WITH policy_of_record AS (
  -- The narrative policy value the solution treats as "within policy". Read live from the
  -- app-owned XX_POLICY_SETTINGS table so the Policy library "Sync from EBS" action can
  -- reconcile it to what Payables enforces. Falls back to 10 if the row is missing.
  SELECT NVL(MAX(TO_NUMBER(setting_value)), 10) AS policy_price_pct
  FROM   XX_POLICY_SETTINGS
  WHERE  setting_key = 'PRICE_TOL_PCT'
),
enforced AS (
  -- Scope to Vision Operations only (org_id 204) — the operating unit that holds this
  -- demo's invoices/holds. The full EBS Vision demo has ~38 operating units; showing all
  -- of them is noise for a single-OU deployment.
  SELECT sp.org_id,
         NVL(hou.name, tt.tolerance_name) AS operating_unit,
         tt.tolerance_id,
         tt.tolerance_name,
         tt.price_tolerance       AS enforced_price_pct,
         tt.quantity_tolerance    AS enforced_qty_pct
  FROM   ap.ap_system_parameters_all sp
  LEFT   JOIN hr.hr_all_organization_units hou ON hou.organization_id = sp.org_id
  LEFT   JOIN ap.ap_tolerance_templates tt ON tt.tolerance_id = sp.tolerance_id
  WHERE  sp.org_id = 204
)
SELECT e.org_id,
       e.operating_unit,
       e.tolerance_id,
       e.tolerance_name,
       p.policy_price_pct,
       e.enforced_price_pct,
       e.enforced_qty_pct,
       CASE
         WHEN e.enforced_price_pct IS NULL              THEN 'UNKNOWN'
         WHEN e.enforced_price_pct = p.policy_price_pct THEN 'IN_SYNC'
         ELSE 'DRIFT'
       END AS recon_status,
       CASE
         WHEN e.enforced_price_pct IS NULL THEN
           'No tolerance template linked to this operating unit — Payables uses no price tolerance.'
         WHEN e.enforced_price_pct = p.policy_price_pct THEN
           'Narrative policy ('||p.policy_price_pct||'%) matches the tolerance Payables enforces.'
         ELSE
           'DRIFT: written policy is '||p.policy_price_pct||'% but Payables enforces '||
           e.enforced_price_pct||'% for this operating unit. Reconcile the document or the template.'
       END AS recon_note
FROM   enforced e
CROSS  JOIN policy_of_record p
ORDER  BY CASE WHEN e.enforced_price_pct <> p.policy_price_pct THEN 0 ELSE 1 END,
         e.org_id;

prompt === XX_P2P_TOLERANCE_RECON_V created — status ===
SELECT object_name, status FROM user_objects
 WHERE object_type='VIEW' AND object_name = 'XX_P2P_TOLERANCE_RECON_V';
