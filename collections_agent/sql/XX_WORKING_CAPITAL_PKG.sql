-- =============================================================================
-- XX_WORKING_CAPITAL_PKG — working-capital analytics for the AR+AP overview.
--
-- READ-ONLY analytics owned by COLLECTIONS_AI over the existing XX_COLL_*_V /
-- XX_P2P_*_V views (live EBS). NO DML on EBS — pure SELECT aggregation returned as
-- JSON. Powers three new demo features:
--   • simulate(...)         — working-capital "what-if" (collect top-N AR + release
--                             in-tolerance AP holds) → before/after cash + DSO/DPO.
--   • action_plan(...)      — ranked highest-value next moves (AR dunning + AP releases).
--   • predict_payment(...)  — per-customer expected days-late from paid history.
--
-- JSON is built by string concatenation (portable across DB JSON-function versions).
-- Idempotent (CREATE OR REPLACE).
-- =============================================================================
set define off
set echo off

CREATE OR REPLACE PACKAGE XX_WORKING_CAPITAL_PKG AS
  g_price_tol_pct CONSTANT NUMBER := 10;   -- AP price-variance tolerance (%) = "within policy"
                                           -- (matches the Vision Operations Payables tolerance template)

  PROCEDURE simulate(p_top_ar IN NUMBER DEFAULT 10, p_tol_pct IN NUMBER DEFAULT NULL,
                     p_result OUT CLOB);
  PROCEDURE action_plan(p_top IN NUMBER DEFAULT 8, p_result OUT CLOB);
  PROCEDURE predict_payment(p_top IN NUMBER DEFAULT 15, p_result OUT CLOB);
END XX_WORKING_CAPITAL_PKG;
/

CREATE OR REPLACE PACKAGE BODY XX_WORKING_CAPITAL_PKG AS

  -- Minimal JSON string helpers (avoid JSON_OBJECT/ARRAYAGG version quirks).
  FUNCTION jq(s IN VARCHAR2) RETURN VARCHAR2 IS  -- quote+escape a string
  BEGIN
    RETURN '"' || REPLACE(REPLACE(NVL(s,''), '\', '\\'), '"', '\"') || '"';
  END;
  FUNCTION jn(n IN NUMBER) RETURN VARCHAR2 IS   -- number or null (valid JSON, leading zero)
    s VARCHAR2(64);
  BEGIN
    IF n IS NULL THEN RETURN 'null'; END IF;
    s := TO_CHAR(n);
    IF s LIKE '.%'  THEN s := '0' || s; END IF;   -- .4  -> 0.4
    IF s LIKE '-.%' THEN s := '-0' || SUBSTR(s, 2); END IF;  -- -.4 -> -0.4
    RETURN s;
  END;

  FUNCTION ar_open RETURN NUMBER IS
    v NUMBER; BEGIN
    SELECT NVL(SUM(amount_due_remaining),0) INTO v FROM ar.ar_payment_schedules_all
     WHERE status='OP' AND amount_due_remaining>0; RETURN v; END;
  FUNCTION ar_overdue RETURN NUMBER IS
    v NUMBER; BEGIN
    SELECT NVL(SUM(amount_due_remaining),0) INTO v FROM ar.ar_payment_schedules_all
     WHERE status='OP' AND amount_due_remaining>0 AND due_date < TRUNC(SYSDATE); RETURN v; END;
  FUNCTION ap_blocked RETURN NUMBER IS
    v NUMBER; BEGIN SELECT NVL(SUM(invoice_amount),0) INTO v FROM XX_P2P_HOLDS_V; RETURN v; END;
  FUNCTION ap_open RETURN NUMBER IS
    v NUMBER; BEGIN
    SELECT NVL(SUM(amount_remaining),0) INTO v FROM ap.ap_payment_schedules_all
     WHERE payment_status_flag IN ('N','P') AND amount_remaining>0; RETURN v; END;
  FUNCTION ar_annual RETURN NUMBER IS
    v NUMBER; BEGIN
    SELECT NVL(SUM(amount_due_original),0) INTO v FROM ar.ar_payment_schedules_all
     WHERE trx_date >= ADD_MONTHS(TRUNC(SYSDATE),-12);
    IF NVL(v,0)=0 THEN
      -- Historical clone (no recent-dated rows): use total original AR as the annual proxy.
      SELECT NVL(SUM(amount_due_original),0) INTO v FROM ar.ar_payment_schedules_all;
    END IF; RETURN GREATEST(v,1); END;
  FUNCTION ap_annual RETURN NUMBER IS
    v NUMBER; BEGIN
    SELECT NVL(SUM(invoice_amount),0) INTO v FROM ap.ap_invoices_all
     WHERE invoice_date >= ADD_MONTHS(TRUNC(SYSDATE),-12);
    IF NVL(v,0)=0 THEN
      -- Historical clone: use total AP invoice value as the annual spend proxy.
      SELECT NVL(SUM(invoice_amount),0) INTO v FROM ap.ap_invoices_all;
    END IF; RETURN GREATEST(v,1); END;

  ----------------------------------------------------------------------------
  PROCEDURE simulate(p_top_ar IN NUMBER DEFAULT 10, p_tol_pct IN NUMBER DEFAULT NULL,
                     p_result OUT CLOB) IS
    l_tol NUMBER := NVL(p_tol_pct, g_price_tol_pct);
    l_ar_open NUMBER := ar_open(); l_ar_overdue NUMBER := ar_overdue();
    l_ap_blocked NUMBER := ap_blocked(); l_ap_open NUMBER := ap_open();
    l_ar_annual NUMBER := ar_annual(); l_ap_annual NUMBER := ap_annual();
    l_collect NUMBER := 0; l_release NUMBER := 0;
    l_dso_b NUMBER; l_dso_a NUMBER; l_dpo_b NUMBER; l_dpo_a NUMBER;
  BEGIN
    SELECT NVL(SUM(total_overdue),0) INTO l_collect FROM (
      SELECT total_overdue FROM XX_COLL_RISK_CUSTOMERS_V
      ORDER BY total_overdue DESC NULLS LAST FETCH FIRST p_top_ar ROWS ONLY);

    SELECT NVL(SUM(h.invoice_amount),0) INTO l_release
    FROM XX_P2P_HOLDS_V h
    WHERE NOT EXISTS (
      SELECT 1 FROM XX_P2P_MATCH_V m
       WHERE m.invoice_id = h.invoice_id
         AND m.match_status <> 'MATCHED'
         AND NVL(ABS(m.price_variance_pct),0) > l_tol);

    -- DSO on AR open vs annual sales proxy; DPO on AP open vs annual spend proxy.
    -- Releasing holds converts blocked AP to payable (does not change DPO base), so we
    -- report DPO on open payables and surface the blocked-value reduction separately.
    l_dso_b := ROUND(l_ar_open / l_ar_annual * 365, 1);
    l_dso_a := ROUND(GREATEST(l_ar_open - l_collect,0) / l_ar_annual * 365, 1);
    l_dpo_b := ROUND(l_ap_open / l_ap_annual * 365, 1);
    l_dpo_a := l_dpo_b;  -- releasing a hold doesn't extend/shorten DPO; base unchanged

    p_result := TO_CLOB('{')
      || '"status":"success"'
      || ',"top_ar_customers":' || jn(p_top_ar)
      || ',"price_tolerance_pct":' || jn(l_tol)
      || ',"before_ar_open":' || jn(ROUND(l_ar_open))
      || ',"before_ar_overdue":' || jn(ROUND(l_ar_overdue))
      || ',"before_ap_blocked":' || jn(ROUND(l_ap_blocked))
      || ',"before_dso_days":' || jn(l_dso_b)
      || ',"before_dpo_days":' || jn(l_dpo_b)
      || ',"cash_collected":' || jn(ROUND(l_collect))
      || ',"holds_released_value":' || jn(ROUND(l_release))
      || ',"after_ar_open":' || jn(ROUND(l_ar_open - l_collect))
      || ',"after_ar_overdue":' || jn(ROUND(GREATEST(l_ar_overdue - l_collect,0)))
      || ',"after_ap_blocked":' || jn(ROUND(GREATEST(l_ap_blocked - l_release,0)))
      || ',"after_dso_days":' || jn(l_dso_a)
      || ',"after_dpo_days":' || jn(l_dpo_a)
      || ',"cash_freed":' || jn(ROUND(l_collect + l_release))
      || ',"dso_improvement_days":' || jn(ROUND(l_dso_b - l_dso_a, 1))
      || ',"dpo_change_days":' || jn(ROUND(l_dpo_b - l_dpo_a, 1))
      || '}';
  EXCEPTION WHEN OTHERS THEN
    p_result := '{"status":"error","message":' || jq(SUBSTR(SQLERRM,1,400)) || '}';
  END simulate;

  ----------------------------------------------------------------------------
  PROCEDURE action_plan(p_top IN NUMBER DEFAULT 8, p_result OUT CLOB) IS
    l_tol NUMBER := g_price_tol_pct;
    l_json CLOB := TO_CLOB('['); l_first BOOLEAN := TRUE; l_rank NUMBER := 0;
  BEGIN
    FOR r IN (
      WITH ar_moves AS (
        SELECT 'AR' domain, 'collect' action_type, c.account_number ref_id, c.party_name nm,
               c.total_overdue val, c.max_days_overdue age_days,
               CASE WHEN c.max_days_overdue>60 THEN 'dunning_level_2'
                    WHEN c.max_days_overdue>30 THEN 'dunning_level_1'
                    ELSE 'payment_reminder' END rec, 'Y' pol, c.customer_id ent
        FROM XX_COLL_RISK_CUSTOMERS_V c),
      ap_moves AS (
        SELECT 'AP' domain, 'release_hold' action_type, e.invoice_num ref_id, e.vendor_name nm,
               e.invoice_amount val, e.hold_age_days age_days, 'release_ap_hold' rec,
               CASE WHEN NOT EXISTS (SELECT 1 FROM XX_P2P_MATCH_V m
                      WHERE m.invoice_id=e.invoice_id AND m.match_status<>'MATCHED'
                        AND NVL(ABS(m.price_variance_pct),0)>l_tol) THEN 'Y' ELSE 'N' END pol,
               e.invoice_id ent
        FROM XX_P2P_EXCEPTION_QUEUE_V e)
      SELECT * FROM (SELECT * FROM ar_moves UNION ALL SELECT * FROM ap_moves)
      ORDER BY val DESC NULLS LAST FETCH FIRST p_top ROWS ONLY)
    LOOP
      l_rank := l_rank + 1;
      IF NOT l_first THEN l_json := l_json || ','; END IF;
      l_first := FALSE;
      l_json := l_json || '{'
        || '"rank":' || jn(l_rank)
        || ',"domain":' || jq(r.domain)
        || ',"action_type":' || jq(r.action_type)
        || ',"ref_id":' || jq(r.ref_id)
        || ',"name":' || jq(r.nm)
        || ',"value":' || jn(ROUND(r.val))
        || ',"age_days":' || jn(r.age_days)
        || ',"recommended_action":' || jq(r.rec)
        || ',"within_policy":' || jq(r.pol)
        || ',"entity_id":' || jn(r.ent)
        || '}';
    END LOOP;
    p_result := l_json || ']';
  EXCEPTION WHEN OTHERS THEN
    p_result := '{"status":"error","message":' || jq(SUBSTR(SQLERRM,1,400)) || '}';
  END action_plan;

  ----------------------------------------------------------------------------
  PROCEDURE predict_payment(p_top IN NUMBER DEFAULT 15, p_result OUT CLOB) IS
    l_json CLOB := TO_CLOB('['); l_first BOOLEAN := TRUE;
  BEGIN
    FOR r IN (
      WITH hist AS (
        SELECT ps.customer_id,
               AVG(GREATEST(TRUNC(ps.gl_date)-TRUNC(ps.due_date),0)) avg_late, COUNT(*) cnt
        FROM ar.ar_payment_schedules_all ps
        WHERE ps.status='CL' AND ps.due_date IS NOT NULL AND ps.gl_date IS NOT NULL
        GROUP BY ps.customer_id HAVING COUNT(*) >= 2),
      openpos AS (
        SELECT ps.customer_id, SUM(ps.amount_due_remaining) open_amt, MIN(ps.due_date) next_due
        FROM ar.ar_payment_schedules_all ps
        WHERE ps.status='OP' AND ps.amount_due_remaining>0 GROUP BY ps.customer_id)
      SELECT h.customer_id, hp.party_name, hca.account_number, o.open_amt, h.avg_late, h.cnt,
             o.next_due,
             CASE WHEN h.avg_late>=30 THEN 'HIGH' WHEN h.avg_late>=10 THEN 'MEDIUM' ELSE 'LOW' END band
      FROM hist h JOIN openpos o ON o.customer_id=h.customer_id
      JOIN ar.hz_cust_accounts hca ON hca.cust_account_id=h.customer_id
      JOIN ar.hz_parties hp ON hp.party_id=hca.party_id
      ORDER BY h.avg_late DESC, o.open_amt DESC NULLS LAST FETCH FIRST p_top ROWS ONLY)
    LOOP
      IF NOT l_first THEN l_json := l_json || ','; END IF;
      l_first := FALSE;
      l_json := l_json || '{'
        || '"customer_id":' || jn(r.customer_id)
        || ',"party_name":' || jq(r.party_name)
        || ',"account_number":' || jq(r.account_number)
        || ',"open_amount":' || jn(ROUND(r.open_amt))
        || ',"avg_days_late":' || jn(ROUND(r.avg_late,1))
        || ',"paid_history":' || jn(r.cnt)
        || ',"risk_band":' || jq(r.band)
        || ',"predicted_pay_date":' || jq(TO_CHAR(r.next_due + ROUND(r.avg_late),'YYYY-MM-DD'))
        || '}';
    END LOOP;
    p_result := l_json || ']';
  EXCEPTION WHEN OTHERS THEN
    p_result := '{"status":"error","message":' || jq(SUBSTR(SQLERRM,1,400)) || '}';
  END predict_payment;

END XX_WORKING_CAPITAL_PKG;
/

prompt === XX_WORKING_CAPITAL_PKG status ===
SELECT object_name, object_type, status FROM user_objects
 WHERE object_name='XX_WORKING_CAPITAL_PKG' ORDER BY object_type;
SHOW ERRORS PACKAGE BODY XX_WORKING_CAPITAL_PKG
