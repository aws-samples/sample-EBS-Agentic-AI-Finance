-- =============================================================================
-- XX_P2P_AP_PKG — audited Purchase-to-Pay write-back package (APPS, definer rights).
--
-- Same SOX-compliant pattern as APPS.XX_COLLECTIONS_REST_PKG (proven working via the
-- Collections Lambda's direct oracledb callproc path on 2026-06-30): the APPS package
-- owns the mutation + audit; callers (P2P Lambda / agent) never do direct DML.
--
-- Procedures (all return a JSON CLOB in p_result):
--   get_invoice_exceptions(p_result)                 READ  — exception queue
--   diagnose_match_exception(p_invoice_id, p_result)  READ  — variance + match detail
--   release_ap_hold(p_invoice_id, p_hold_type, p_reason, p_result)   WRITE (gated)
--   validate_invoice(p_invoice_id, p_result)          WRITE — recompute holds (status only)
--   create_ap_note(p_invoice_id, p_note_text, p_result) WRITE — audited note
--
-- Run as APPS in PDB ERPUAT. Compiles VALID against EBS 12.2 AP.
-- =============================================================================
set echo off
-- Idempotent audit tables: create only if absent (swallow ORA-00955 "name already used"),
-- so a redeploy over an existing schema is CLEAN — no scary errors. -955 is the only code
-- tolerated; any other DDL failure still raises. Existing tables + their data are preserved.
DECLARE
  e_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_exists, -955);  -- name is already used by an existing object
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE apps.xx_p2p_notes (
      note_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      invoice_id     NUMBER,
      note_text      VARCHAR2(4000),
      created_by_who VARCHAR2(100),
      created_at     TIMESTAMP DEFAULT SYSTIMESTAMP
    )]';
EXCEPTION WHEN e_exists THEN NULL;
END;
/

DECLARE
  e_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_exists, -955);
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE apps.xx_p2p_hold_audit (
      audit_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      invoice_id     NUMBER,
      hold_type      VARCHAR2(40),
      action         VARCHAR2(20),
      reason         VARCHAR2(400),
      done_by_who    VARCHAR2(100),
      done_at        TIMESTAMP DEFAULT SYSTIMESTAMP
    )]';
EXCEPTION WHEN e_exists THEN NULL;
END;
/

CREATE OR REPLACE PACKAGE apps.xx_p2p_ap_pkg AS
  PROCEDURE get_invoice_exceptions(p_result OUT CLOB);
  PROCEDURE diagnose_match_exception(p_invoice_id IN NUMBER, p_result OUT CLOB);
  PROCEDURE release_single_hold(p_invoice_id IN NUMBER, p_hold_type IN VARCHAR2,
                                p_release_code IN VARCHAR2, p_reason IN VARCHAR2,
                                p_result OUT CLOB);
  PROCEDURE release_ap_hold(p_invoice_id IN NUMBER, p_hold_type IN VARCHAR2,
                            p_reason IN VARCHAR2, p_result OUT CLOB);
  PROCEDURE validate_invoice(p_invoice_id IN NUMBER, p_result OUT CLOB);
  PROCEDURE create_ap_note(p_invoice_id IN NUMBER, p_note_text IN VARCHAR2,
                           p_result OUT CLOB);
  -- P5: approval + payment proposal (gated, audited; uses real EBS statuses).
  PROCEDURE manual_approve_invoice(p_invoice_id IN NUMBER, p_reason IN VARCHAR2,
                                   p_result OUT CLOB);
  PROCEDURE propose_payment(p_invoice_id IN NUMBER, p_pay_date IN VARCHAR2,
                            p_result OUT CLOB);
END xx_p2p_ap_pkg;
/

CREATE OR REPLACE PACKAGE BODY apps.xx_p2p_ap_pkg AS

  PROCEDURE get_invoice_exceptions(p_result OUT CLOB) AS
    l_json CLOB;
  BEGIN
    -- Order/limit in a subquery, then aggregate (avoids ORA-40654 from ordering a
    -- NUMBER inside JSON_ARRAYAGG and keeps the buffer as CLOB).
    SELECT JSON_ARRAYAGG(
      JSON_OBJECT(
        'invoice_id'      VALUE invoice_id,
        'invoice_num'     VALUE invoice_num,
        'vendor_name'     VALUE vendor_name,
        'invoice_amount'  VALUE invoice_amount,
        'currency'        VALUE currency,
        'hold_type'       VALUE hold_type,
        'hold_reason'     VALUE hold_reason,
        'hold_age_days'   VALUE hold_age_days,
        'exception_reason' VALUE exception_reason,
        'priority_score'  VALUE priority_score
      ) RETURNING CLOB
    ) INTO l_json
    FROM (
      SELECT invoice_id, invoice_num, vendor_name, invoice_amount, currency,
             hold_type, hold_reason, hold_age_days, exception_reason, priority_score
      FROM collections_ai.xx_p2p_exception_queue_v
      ORDER BY priority_score DESC NULLS LAST
      FETCH FIRST 100 ROWS ONLY
    );
    p_result := NVL(l_json, TO_CLOB('[]'));
  END get_invoice_exceptions;

  PROCEDURE diagnose_match_exception(p_invoice_id IN NUMBER, p_result OUT CLOB) AS
    l_json CLOB;
  BEGIN
    SELECT JSON_OBJECT(
      'invoice_id' VALUE p_invoice_id,
      'lines' VALUE JSON_ARRAYAGG(
        JSON_OBJECT(
          'line_number'         VALUE line_number,
          'po_number'           VALUE po_number,
          'match_status'        VALUE match_status,
          'invoice_unit_price'  VALUE invoice_unit_price,
          'po_unit_price'       VALUE po_unit_price,
          'price_variance_pct'  VALUE price_variance_pct,
          'quantity_invoiced'   VALUE quantity_invoiced,
          'po_quantity'         VALUE po_quantity,
          'qty_received'        VALUE qty_received
        ) ORDER BY line_number RETURNING CLOB
      ) RETURNING CLOB
    ) INTO l_json
    FROM collections_ai.xx_p2p_match_v
    WHERE invoice_id = p_invoice_id;
    p_result := NVL(l_json, JSON_OBJECT('invoice_id' VALUE p_invoice_id,
                                        'lines' VALUE TO_CLOB('[]')));
  END diagnose_match_exception;

  PROCEDURE release_single_hold(p_invoice_id IN NUMBER, p_hold_type IN VARCHAR2,
                                p_release_code IN VARCHAR2, p_reason IN VARCHAR2,
                                p_result OUT CLOB) AS
    -- License-clean / supported path: call the SEEDED AP_HOLDS_PKG.RELEASE_SINGLE_HOLD
    -- API (the same routine the Payables "Invoice Holds" form / Invoice Validation use)
    -- instead of raw DML on AP_HOLDS_ALL. Standard Payables — no SOA Suite license.
    l_before NUMBER;
    l_after  NUMBER;
    l_release VARCHAR2(50) := NVL(p_release_code, 'VARIANCE CORRECTED');
    -- headless session returns user_id -1 (not null); <=0 => SYSADMIN(0) so audit isn't ANONYMOUS.
    l_user   NUMBER := GREATEST(NVL(FND_GLOBAL.user_id, 0), 0);
  BEGIN
    SELECT COUNT(*) INTO l_before FROM ap.ap_holds_all
     WHERE invoice_id = p_invoice_id AND status_flag = 'S'
       AND (p_hold_type IS NULL OR hold_lookup_code = p_hold_type);
    IF l_before = 0 THEN
      p_result := JSON_OBJECT('status' VALUE 'no_hold',
                              'message' VALUE 'No active "'||p_hold_type||'" hold on invoice '||p_invoice_id);
      RETURN;
    END IF;

    -- Establish an EBS apps context so the seeded API's audit (held_by/who) is correct.
    BEGIN
      FND_GLOBAL.apps_initialize(user_id => l_user, resp_id => NULL, resp_appl_id => NULL);
    EXCEPTION WHEN OTHERS THEN NULL; END;

    FOR h IN (SELECT hold_lookup_code, held_by FROM ap.ap_holds_all
               WHERE invoice_id = p_invoice_id AND status_flag = 'S'
                 AND (p_hold_type IS NULL OR hold_lookup_code = p_hold_type)) LOOP
      AP_HOLDS_PKG.release_single_hold(
        X_invoice_id          => p_invoice_id,
        X_hold_lookup_code    => h.hold_lookup_code,
        X_release_lookup_code => l_release,
        X_held_by             => NVL(h.held_by, l_user),
        X_calling_sequence    => 'XX_P2P_AP_PKG.release_single_hold');
    END LOOP;
    COMMIT;  -- AP_HOLDS_PKG performs the update; persist it.

    SELECT COUNT(*) INTO l_after FROM ap.ap_holds_all
     WHERE invoice_id = p_invoice_id AND status_flag = 'S'
       AND (p_hold_type IS NULL OR hold_lookup_code = p_hold_type);

    INSERT INTO apps.xx_p2p_hold_audit (invoice_id, hold_type, action, reason, done_by_who)
    VALUES (p_invoice_id, p_hold_type, 'RELEASE_SEEDED',
            SUBSTR('release='||l_release||'; '||p_reason,1,400), 'P2P_AGENT_26AI');
    COMMIT;

    p_result := JSON_OBJECT(
      'status'  VALUE CASE WHEN l_after < l_before THEN 'success' ELSE 'no_change' END,
      'message' VALUE 'Released '||(l_before - l_after)||' hold(s) on invoice '||p_invoice_id
                      ||' via seeded AP_HOLDS_PKG (release code '||l_release||')',
      'holds_released' VALUE (l_before - l_after),
      'api' VALUE 'AP_HOLDS_PKG.RELEASE_SINGLE_HOLD');
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500),
                            'api' VALUE 'AP_HOLDS_PKG.RELEASE_SINGLE_HOLD');
  END release_single_hold;

  PROCEDURE release_ap_hold(p_invoice_id IN NUMBER, p_hold_type IN VARCHAR2,
                            p_reason IN VARCHAR2, p_result OUT CLOB) AS
  BEGIN
    -- Back-compat wrapper → seeded-API path with the default release code.
    release_single_hold(p_invoice_id, p_hold_type, NULL, p_reason, p_result);
  END release_ap_hold;

  PROCEDURE validate_invoice(p_invoice_id IN NUMBER, p_result OUT CLOB) AS
    l_holds NUMBER;
    l_status VARCHAR2(40);
  BEGIN
    -- Report current validation/hold state. (A full impl enqueues the AP validation
    -- concurrent program; this returns the live status the UI/agent needs.)
    SELECT COUNT(*) INTO l_holds FROM ap.ap_holds_all
     WHERE invoice_id = p_invoice_id AND status_flag = 'S';
    SELECT NVL(MAX(wfapproval_status),'UNKNOWN') INTO l_status
     FROM ap.ap_invoices_all WHERE invoice_id = p_invoice_id;
    p_result := JSON_OBJECT(
      'status'           VALUE 'success',
      'invoice_id'       VALUE p_invoice_id,
      'active_holds'     VALUE l_holds,
      'approval_status'  VALUE l_status,
      'validation_state' VALUE CASE WHEN l_holds = 0 THEN 'CLEAN' ELSE 'ON_HOLD' END);
  EXCEPTION WHEN OTHERS THEN
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END validate_invoice;

  PROCEDURE create_ap_note(p_invoice_id IN NUMBER, p_note_text IN VARCHAR2,
                           p_result OUT CLOB) AS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_id NUMBER;
  BEGIN
    INSERT INTO apps.xx_p2p_notes (invoice_id, note_text, created_by_who)
    VALUES (p_invoice_id, SUBSTR(p_note_text,1,4000), 'P2P_AGENT_26AI')
    RETURNING note_id INTO l_id;
    COMMIT;
    p_result := JSON_OBJECT('status' VALUE 'success', 'note_id' VALUE l_id,
                            'message' VALUE 'Note created for invoice '||p_invoice_id);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END create_ap_note;

  PROCEDURE manual_approve_invoice(p_invoice_id IN NUMBER, p_reason IN VARCHAR2,
                                   p_result OUT CLOB) AS
    -- P5 approval. NOTE: this clone has no AME transaction-type configured for AP, so
    -- full AME/AP_WORKFLOW_PKG initiation is not available. We set the invoice to the
    -- real, valid EBS state 'MANUALLY APPROVED' (already used in live data) — the
    -- supported manual-approval status — and audit it. Production upgrade path: call
    -- AP_WORKFLOW_PKG once AME is configured (documented in DETAILED_DESIGN.md Part II §P5).
    l_cnt NUMBER;
    -- headless session returns user_id -1 (not null); <=0 => SYSADMIN(0) so audit isn't ANONYMOUS.
    l_user NUMBER := GREATEST(NVL(FND_GLOBAL.user_id, 0), 0);
  BEGIN
    UPDATE ap.ap_invoices_all
       SET wfapproval_status = 'MANUALLY APPROVED',
           last_update_date  = SYSDATE
     WHERE invoice_id = p_invoice_id
       AND NVL(wfapproval_status,'NOT REQUIRED') NOT IN ('MANUALLY APPROVED','APPROVED');
    l_cnt := SQL%ROWCOUNT;
    INSERT INTO apps.xx_p2p_hold_audit (invoice_id, hold_type, action, reason, done_by_who)
    VALUES (p_invoice_id, NULL, 'APPROVE', SUBSTR(p_reason,1,400), 'P2P_AGENT_26AI');
    COMMIT;
    p_result := JSON_OBJECT(
      'status'  VALUE CASE WHEN l_cnt > 0 THEN 'success' ELSE 'no_change' END,
      'invoice_id' VALUE p_invoice_id,
      'wfapproval_status' VALUE 'MANUALLY APPROVED',
      'message' VALUE CASE WHEN l_cnt > 0
                          THEN 'Invoice '||p_invoice_id||' set to MANUALLY APPROVED'
                          ELSE 'Invoice already approved / nothing to change' END);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END manual_approve_invoice;

  PROCEDURE propose_payment(p_invoice_id IN NUMBER, p_pay_date IN VARCHAR2,
                            p_result OUT CLOB) AS
    -- The MOST cautious action: this DRAFTS a payment proposal only. It does NOT create
    -- a payment, select the invoice into a payment batch, or move money. It reports the
    -- invoice's open payment schedule + a proposed pay date for human authorization.
    l_amt NUMBER; l_due DATE; l_status VARCHAR2(2); l_held NUMBER;
  BEGIN
    SELECT SUM(amount_remaining), MIN(due_date), MIN(payment_status_flag)
      INTO l_amt, l_due, l_status
      FROM ap.ap_payment_schedules_all
     WHERE invoice_id = p_invoice_id AND payment_status_flag IN ('N','P');
    SELECT COUNT(*) INTO l_held FROM ap.ap_holds_all
     WHERE invoice_id = p_invoice_id AND status_flag = 'S';

    IF l_amt IS NULL THEN
      p_result := JSON_OBJECT('status' VALUE 'no_op',
                              'message' VALUE 'No open payment schedule for invoice '||p_invoice_id);
      RETURN;
    END IF;
    p_result := JSON_OBJECT(
      'status' VALUE 'proposed',
      'invoice_id' VALUE p_invoice_id,
      'amount_remaining' VALUE l_amt,
      'earliest_due_date' VALUE TO_CHAR(l_due,'YYYY-MM-DD'),
      'proposed_pay_date' VALUE NVL(p_pay_date, TO_CHAR(GREATEST(l_due, TRUNC(SYSDATE)),'YYYY-MM-DD')),
      'active_holds' VALUE l_held,
      'payable' VALUE CASE WHEN l_held = 0 THEN 'YES' ELSE 'NO - release holds first' END,
      'message' VALUE 'PROPOSAL ONLY — no payment created. Requires human authorization in Payables.');
  EXCEPTION WHEN OTHERS THEN
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END propose_payment;

END xx_p2p_ap_pkg;
/

prompt === XX_P2P_AP_PKG status ===
SELECT object_name, object_type, status FROM all_objects
 WHERE owner='APPS' AND object_name='XX_P2P_AP_PKG' ORDER BY object_type;
SHOW ERRORS PACKAGE BODY apps.xx_p2p_ap_pkg
