-- =============================================================================
-- XX_P2P_ANOMALY_PKG — duplicate-invoice + anomaly detection for AP ingest.
--
-- READ-ONLY guard used at ingest time (P2P feature #4). Given a candidate invoice
-- (vendor + number + amount + date), it flags:
--   • DUPLICATE  — same vendor + invoice_num already in AP (classic dup-payment risk),
--   • NEAR_DUP   — same vendor + amount within a few days (re-submitted / scanned twice),
--   • AMOUNT_OUTLIER — amount far outside this vendor's historical invoice range.
-- Returns JSON the agent/extract-Lambda uses to decide straight-through vs review/hold.
--
-- No DML. Owned by APPS so it can read AP + the staging table; callable by the agent.
-- Idempotent (CREATE OR REPLACE).
-- =============================================================================
set define off
set echo off

CREATE OR REPLACE PACKAGE apps.xx_p2p_anomaly_pkg AS
  -- Check a candidate invoice for duplicates / anomalies. Returns JSON:
  -- {status, verdict: CLEAR|REVIEW|BLOCK, flags:[...], detail:{...}}
  PROCEDURE check_invoice(
    p_vendor_name    IN VARCHAR2,
    p_invoice_num    IN VARCHAR2,
    p_invoice_amount IN NUMBER,
    p_invoice_date   IN VARCHAR2,       -- 'YYYY-MM-DD'
    p_result         OUT CLOB);
END xx_p2p_anomaly_pkg;
/

CREATE OR REPLACE PACKAGE BODY apps.xx_p2p_anomaly_pkg AS

  FUNCTION resolve_vendor(p_name IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT vendor_id INTO l_id FROM (
      SELECT vendor_id FROM ap.ap_suppliers
       WHERE UPPER(vendor_name)=UPPER(p_name) ORDER BY vendor_id) WHERE ROWNUM=1;
    RETURN l_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    BEGIN
      SELECT vendor_id INTO l_id FROM (
        SELECT vendor_id FROM ap.ap_suppliers
         WHERE UPPER(vendor_name) LIKE '%'||UPPER(p_name)||'%' ORDER BY vendor_id) WHERE ROWNUM=1;
      RETURN l_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL; END;
  END resolve_vendor;

  PROCEDURE check_invoice(
    p_vendor_name IN VARCHAR2, p_invoice_num IN VARCHAR2, p_invoice_amount IN NUMBER,
    p_invoice_date IN VARCHAR2, p_result OUT CLOB) IS
    l_vid        NUMBER := resolve_vendor(p_vendor_name);
    l_dt         DATE   := TO_DATE(p_invoice_date,'YYYY-MM-DD');
    l_exact      NUMBER := 0;   -- same vendor + same invoice_num already in AP
    l_neardup    NUMBER := 0;   -- same vendor + amount within +/-3 days
    l_stage_dup  NUMBER := 0;   -- already sitting in staging
    l_avg        NUMBER; l_max NUMBER; l_cnt NUMBER;
    l_flags      VARCHAR2(400) := '';
    l_verdict    VARCHAR2(10)  := 'CLEAR';
    l_outlier    VARCHAR2(1)   := 'N';
  BEGIN
    IF l_vid IS NOT NULL THEN
      -- exact duplicate: same supplier + invoice number
      SELECT COUNT(*) INTO l_exact FROM ap.ap_invoices_all
       WHERE vendor_id=l_vid AND UPPER(invoice_num)=UPPER(p_invoice_num);

      -- near-duplicate: same supplier + same amount within a 3-day window
      SELECT COUNT(*) INTO l_neardup FROM ap.ap_invoices_all
       WHERE vendor_id=l_vid
         AND invoice_amount=p_invoice_amount
         AND ABS(TRUNC(invoice_date) - TRUNC(l_dt)) <= 3;

      -- vendor historical amount profile (outlier check)
      SELECT AVG(invoice_amount), MAX(invoice_amount), COUNT(*)
        INTO l_avg, l_max, l_cnt
        FROM ap.ap_invoices_all
       WHERE vendor_id=l_vid
         AND invoice_date >= ADD_MONTHS(TRUNC(SYSDATE),-24);

      IF l_cnt >= 5 AND l_avg IS NOT NULL AND p_invoice_amount > GREATEST(l_max, l_avg*5) THEN
        l_outlier := 'Y';
      END IF;
    END IF;

    -- already staged (avoid re-ingesting the same scan)
    SELECT COUNT(*) INTO l_stage_dup FROM apps.xx_p2p_staging
     WHERE UPPER(NVL(invoice_num,'~'))=UPPER(NVL(p_invoice_num,'~'))
       AND NVL(invoice_amount,-1)=NVL(p_invoice_amount,-1);

    IF l_exact > 0 THEN l_flags := l_flags||'DUPLICATE,'; l_verdict := 'BLOCK'; END IF;
    IF l_neardup > 0 THEN l_flags := l_flags||'NEAR_DUP,';
       IF l_verdict <> 'BLOCK' THEN l_verdict := 'REVIEW'; END IF; END IF;
    IF l_stage_dup > 0 THEN l_flags := l_flags||'ALREADY_STAGED,';
       IF l_verdict <> 'BLOCK' THEN l_verdict := 'REVIEW'; END IF; END IF;
    IF l_outlier = 'Y' THEN l_flags := l_flags||'AMOUNT_OUTLIER,';
       IF l_verdict = 'CLEAR' THEN l_verdict := 'REVIEW'; END IF; END IF;

    p_result := '{'
      || '"status":"success"'
      || ',"verdict":"' || l_verdict || '"'
      || ',"flags":"' || RTRIM(l_flags, ',') || '"'
      || ',"vendor_id":' || CASE WHEN l_vid IS NULL THEN 'null' ELSE TO_CHAR(l_vid) END
      || ',"exact_duplicate_count":' || TO_CHAR(l_exact)
      || ',"near_duplicate_count":' || TO_CHAR(l_neardup)
      || ',"already_staged_count":' || TO_CHAR(l_stage_dup)
      || ',"vendor_avg_amount":' || CASE WHEN l_avg IS NULL THEN 'null' ELSE TO_CHAR(ROUND(l_avg)) END
      || ',"vendor_max_amount":' || CASE WHEN l_max IS NULL THEN 'null' ELSE TO_CHAR(ROUND(l_max)) END
      || ',"vendor_history_count":' || CASE WHEN l_cnt IS NULL THEN '0' ELSE TO_CHAR(l_cnt) END
      || ',"amount_outlier":"' || l_outlier || '"'
      || '}';
  EXCEPTION WHEN OTHERS THEN
    p_result := '{"status":"error","message":"' ||
                REPLACE(SUBSTR(SQLERRM,1,400),'"','''') || '"}';
  END check_invoice;

END xx_p2p_anomaly_pkg;
/

prompt === XX_P2P_ANOMALY_PKG status ===
SELECT object_name, object_type, status FROM all_objects
 WHERE owner='APPS' AND object_name='XX_P2P_ANOMALY_PKG' ORDER BY object_type;
SHOW ERRORS PACKAGE BODY apps.xx_p2p_anomaly_pkg
