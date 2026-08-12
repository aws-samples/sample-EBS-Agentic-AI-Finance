-- =============================================================================
-- XX_POLICY_SETTINGS_26ai.sql — app-owned "policy of record" settings.
--
-- Holds the narrative policy-of-record values the app treats as "within policy"
-- (currently the AP price-variance tolerance). This value USED to be hardcoded in
-- XX_P2P_TOLERANCE_RECON_V; moving it into a small COLLECTIONS_AI-owned table lets the
-- Policy library "Sync from EBS" action update it to match what Payables actually
-- enforces, so a drifting document can be reconciled from the UI.
--
-- IMPORTANT (security): this table lives in the COLLECTIONS_AI application schema. The
-- sync action writes ONLY here — it never writes EBS financial config. EBS remains the
-- system of record for the enforced tolerance; this row is the app's copy of the
-- *documented* policy, kept honest against EBS by the reconciliation view.
--
-- Run as COLLECTIONS_AI@ERPUAT. Idempotent (creates only if missing; seeds only if empty).
-- =============================================================================
set define off
set echo off
serveroutput on

DECLARE
  v_cnt INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM user_tables WHERE table_name = 'XX_POLICY_SETTINGS';
  IF v_cnt = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE TABLE XX_POLICY_SETTINGS (
        setting_key    VARCHAR2(60)  PRIMARY KEY,
        setting_value  VARCHAR2(400) NOT NULL,
        source         VARCHAR2(30)  DEFAULT 'MANUAL' NOT NULL,  -- MANUAL | EBS_SYNC
        updated_by     VARCHAR2(120),
        updated_at     DATE          DEFAULT SYSDATE NOT NULL
      )]';
    DBMS_OUTPUT.PUT_LINE('Created XX_POLICY_SETTINGS');
  ELSE
    DBMS_OUTPUT.PUT_LINE('XX_POLICY_SETTINGS already exists');
  END IF;
END;
/

-- Seed the price-variance policy-of-record (10% = what Vision Operations enforces, so the
-- default state is IN_SYNC). Only inserts if the key is absent; never overwrites a synced value.
MERGE INTO XX_POLICY_SETTINGS t
USING (SELECT 'PRICE_TOL_PCT' AS setting_key, '10' AS setting_value FROM dual) s
ON (t.setting_key = s.setting_key)
WHEN NOT MATCHED THEN
  INSERT (setting_key, setting_value, source, updated_by, updated_at)
  VALUES (s.setting_key, s.setting_value, 'SEED', 'deploy', SYSDATE);

COMMIT;

prompt === XX_POLICY_SETTINGS contents ===
SELECT setting_key, setting_value, source,
       TO_CHAR(updated_at,'YYYY-MM-DD HH24:MI') AS updated_at
FROM   XX_POLICY_SETTINGS ORDER BY setting_key;
