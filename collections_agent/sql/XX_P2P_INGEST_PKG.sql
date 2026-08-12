-- =============================================================================
-- XX_P2P_INGEST_PKG — Invoice ingest via the SEEDED Payables Open Interface.
--
-- P3 of the P2P accelerator. Extracted invoices (from the extraction Lambda:
-- SES/S3 -> Textract/Bedrock vision -> structured JSON) are staged here and pushed
-- into the SEEDED AP_INVOICES_INTERFACE / AP_INVOICE_LINES_INTERFACE, then imported
-- by the seeded concurrent program **APXIIMPT** (Payables Open Interface Import).
-- This is the supported, license-clean creation path (core Payables; no SOA Suite).
--
-- CONFIDENCE GATE (human-in-the-loop): extraction confidence < threshold is NOT
-- auto-staged to the interface — it lands in XX_P2P_STAGING with status NEEDS_REVIEW
-- for the UI review page. >= threshold is staged to the interface (status NEW) ready
-- for import.
--
-- Run as APPS in PDB ERPUAT. Definer rights; audited.
-- Refs: EBS ISG/Open Interface guides (user-provided): 122isgig.pdf,
--   Payables Open Interface Import (APXIIMPT) — Oracle Payables User/Impl guides.
-- =============================================================================
set echo off

-- Local staging table: holds every extracted invoice + its extraction confidence,
-- the source S3 object, and the lifecycle status. Low-confidence rows stay here for
-- human review; high-confidence rows are also pushed to the AP interface.
-- Idempotent: create the staging table if absent; if it already exists from an earlier
-- deploy, add the review_reason column when missing (so re-deploys are safe).
DECLARE
  e_exists   EXCEPTION; PRAGMA EXCEPTION_INIT(e_exists, -955);   -- name already used
  e_col_dup  EXCEPTION; PRAGMA EXCEPTION_INIT(e_col_dup, -1430); -- column already exists
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE apps.xx_p2p_staging (
      staging_id      NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      source_uri      VARCHAR2(400),          -- S3 object the invoice was extracted from
      vendor_name     VARCHAR2(240),
      vendor_id       NUMBER,
      invoice_num     VARCHAR2(50),
      invoice_date    DATE,
      invoice_amount  NUMBER,
      currency_code   VARCHAR2(15),
      org_id          NUMBER,
      po_number       VARCHAR2(50),
      line_json       CLOB,                    -- extracted line items (JSON array)
      confidence      NUMBER,                  -- 0..1 extraction confidence
      review_reason   VARCHAR2(400),           -- short human-readable why-review rationale
      status          VARCHAR2(20) DEFAULT 'EXTRACTED', -- EXTRACTED|NEEDS_REVIEW|STAGED|IMPORTED|REJECTED
      group_id        VARCHAR2(80),            -- import GROUP_ID (batch)
      created_at      TIMESTAMP DEFAULT SYSTIMESTAMP,
      reviewed_by     VARCHAR2(100),
      reviewed_at     TIMESTAMP
    )]';
EXCEPTION WHEN e_exists THEN
  -- Table already there — ensure the review_reason column exists (added post-v1).
  BEGIN
    EXECUTE IMMEDIATE 'ALTER TABLE apps.xx_p2p_staging ADD (review_reason VARCHAR2(400))';
  EXCEPTION WHEN e_col_dup THEN NULL; END;
END;
/

CREATE OR REPLACE PACKAGE apps.xx_p2p_ingest_pkg AS
  -- Default confidence threshold for straight-through staging (overridable per call).
  g_default_threshold CONSTANT NUMBER := 0.80;

  -- Stage one extracted invoice. Returns JSON {staging_id, status, message}.
  PROCEDURE stage_invoice(
    p_source_uri     IN VARCHAR2,
    p_vendor_name    IN VARCHAR2,
    p_invoice_num    IN VARCHAR2,
    p_invoice_date   IN VARCHAR2,        -- 'YYYY-MM-DD'
    p_invoice_amount IN NUMBER,
    p_currency       IN VARCHAR2,
    p_org_id         IN NUMBER,
    p_po_number      IN VARCHAR2,
    p_line_json      IN CLOB,
    p_confidence     IN NUMBER,
    p_threshold      IN NUMBER DEFAULT NULL,
    p_result         OUT CLOB,
    p_review_reason  IN VARCHAR2 DEFAULT NULL);

  -- Approve a NEEDS_REVIEW row after human correction -> push to the AP interface.
  -- Optional corrected fields (NULL = keep extracted value) let a reviewer fix the
  -- vendor/number/amount/date/currency/PO in the UI before it goes to Payables.
  PROCEDURE approve_staged(
    p_staging_id     IN NUMBER,
    p_reviewer       IN VARCHAR2,
    p_result         OUT CLOB,
    p_vendor_name    IN VARCHAR2 DEFAULT NULL,
    p_invoice_num    IN VARCHAR2 DEFAULT NULL,
    p_invoice_amount IN NUMBER   DEFAULT NULL,
    p_invoice_date   IN VARCHAR2 DEFAULT NULL,
    p_currency       IN VARCHAR2 DEFAULT NULL,
    p_po_number      IN VARCHAR2 DEFAULT NULL);

  -- Reject a NEEDS_REVIEW row (human decides it should not enter Payables).
  PROCEDURE reject_staged(p_staging_id IN NUMBER, p_reviewer IN VARCHAR2,
                          p_reason IN VARCHAR2, p_result OUT CLOB);

  -- List rows needing human review (low confidence) as JSON.
  PROCEDURE get_review_queue(p_result OUT CLOB);

  -- Submit the seeded Payables Open Interface Import (APXIIMPT) for a group.
  PROCEDURE submit_import(p_org_id IN NUMBER, p_group_id IN VARCHAR2, p_result OUT CLOB);

  -- Read-only view of the Payables Open Interface pipeline for the AI-ingested source:
  -- what is still PENDING in AP_INVOICES_INTERFACE, and what has been IMPORTED into
  -- AP_INVOICES_ALL. Lets the UI show "what's in the interface" and confirm an invoice
  -- actually landed in Payables after Run Import. Returns a JSON object.
  PROCEDURE get_interface_status(p_result OUT CLOB, p_top IN NUMBER DEFAULT 25);
END xx_p2p_ingest_pkg;
/

CREATE OR REPLACE PACKAGE BODY apps.xx_p2p_ingest_pkg AS

  -- Resolve a vendor_id from the extracted vendor name (best-effort exact/like match).
  FUNCTION resolve_vendor(p_name IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT vendor_id INTO l_id FROM (
      SELECT vendor_id FROM ap.ap_suppliers
       WHERE UPPER(vendor_name) = UPPER(p_name)
       ORDER BY vendor_id) WHERE ROWNUM = 1;
    RETURN l_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    BEGIN
      SELECT vendor_id INTO l_id FROM (
        SELECT vendor_id FROM ap.ap_suppliers
         WHERE UPPER(vendor_name) LIKE '%'||UPPER(p_name)||'%'
         ORDER BY vendor_id) WHERE ROWNUM = 1;
      RETURN l_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL; END;
  END resolve_vendor;

  -- Push a staged row into AP_INVOICES_INTERFACE + lines (seeded import path).
  PROCEDURE push_to_interface(p_staging_id IN NUMBER, p_group_id IN VARCHAR2) IS
    r            apps.xx_p2p_staging%ROWTYPE;
    l_iface_id   NUMBER;
    l_ln_no      NUMBER := 0;
  BEGIN
    SELECT * INTO r FROM apps.xx_p2p_staging WHERE staging_id = p_staging_id;
    l_iface_id := ap.ap_invoices_interface_s.NEXTVAL;

    INSERT INTO ap.ap_invoices_interface (
      invoice_id, invoice_num, invoice_amount, vendor_id, vendor_name,
      invoice_date, invoice_currency_code, org_id, source, group_id,
      po_number, description, status)
    VALUES (
      l_iface_id, r.invoice_num, r.invoice_amount, r.vendor_id, r.vendor_name,
      r.invoice_date, NVL(r.currency_code,'USD'), r.org_id, 'AI_AGENT_P2P', p_group_id,
      r.po_number, 'Ingested by P2P AI agent from '||r.source_uri, NULL);

    -- Lines from the extracted JSON array [{amount, quantity, unit_price, description, po_line_number}]
    FOR ln IN (
      SELECT * FROM JSON_TABLE(r.line_json, '$[*]' COLUMNS (
        amount         NUMBER        PATH '$.amount',
        quantity       NUMBER        PATH '$.quantity',
        unit_price     NUMBER        PATH '$.unit_price',
        description    VARCHAR2(240) PATH '$.description',
        po_line_number NUMBER        PATH '$.po_line_number'))
    ) LOOP
      l_ln_no := l_ln_no + 1;
      INSERT INTO ap.ap_invoice_lines_interface (
        invoice_id, invoice_line_id, line_number, line_type_lookup_code,
        amount, quantity_invoiced, unit_price, po_number, po_line_number, description)
      VALUES (
        l_iface_id, ap.ap_invoice_lines_interface_s.NEXTVAL, l_ln_no,
        CASE WHEN r.po_number IS NOT NULL THEN 'ITEM' ELSE 'ITEM' END,
        ln.amount, ln.quantity, ln.unit_price, r.po_number, ln.po_line_number,
        SUBSTR(ln.description,1,240));
    END LOOP;

    -- If no lines were provided, create a single ITEM line for the header amount.
    IF l_ln_no = 0 THEN
      INSERT INTO ap.ap_invoice_lines_interface (
        invoice_id, invoice_line_id, line_number, line_type_lookup_code, amount, description)
      VALUES (l_iface_id, ap.ap_invoice_lines_interface_s.NEXTVAL, 1, 'ITEM',
              r.invoice_amount, 'Auto line (no extracted lines)');
    END IF;

    UPDATE apps.xx_p2p_staging
       SET status='STAGED', group_id=p_group_id
     WHERE staging_id = p_staging_id;
  END push_to_interface;

  PROCEDURE stage_invoice(
    p_source_uri IN VARCHAR2, p_vendor_name IN VARCHAR2, p_invoice_num IN VARCHAR2,
    p_invoice_date IN VARCHAR2, p_invoice_amount IN NUMBER, p_currency IN VARCHAR2,
    p_org_id IN NUMBER, p_po_number IN VARCHAR2, p_line_json IN CLOB,
    p_confidence IN NUMBER, p_threshold IN NUMBER DEFAULT NULL, p_result OUT CLOB,
    p_review_reason IN VARCHAR2 DEFAULT NULL) IS
    l_thr    NUMBER := NVL(p_threshold, g_default_threshold);
    l_vid    NUMBER := resolve_vendor(p_vendor_name);
    l_sid    NUMBER;
    l_grp    VARCHAR2(80) := 'P2P_'||TO_CHAR(SYSDATE,'YYYYMMDD');
    l_status VARCHAR2(20);
    l_reason VARCHAR2(400) := p_review_reason;
  BEGIN
    -- Build a human-readable why-review rationale when the extractor didn't supply one.
    -- Only relevant when the row will need review (below threshold).
    IF p_confidence < l_thr AND l_reason IS NULL THEN
      l_reason :=
        CASE WHEN p_confidence < 0.40 THEN 'Very low OCR confidence - document likely blurred or illegible'
             WHEN p_confidence < 0.60 THEN 'Low OCR confidence - key fields hard to read'
             ELSE 'Below auto-post threshold - verify extracted values' END;
      IF l_vid IS NULL THEN
        l_reason := l_reason || '; vendor not matched to a supplier record';
      END IF;
      IF p_invoice_num IS NULL THEN l_reason := l_reason || '; invoice number missing'; END IF;
      IF NVL(p_invoice_amount,0) = 0 THEN l_reason := l_reason || '; amount missing/zero'; END IF;
    END IF;

    INSERT INTO apps.xx_p2p_staging (
      source_uri, vendor_name, vendor_id, invoice_num, invoice_date, invoice_amount,
      currency_code, org_id, po_number, line_json, confidence, review_reason, status, group_id)
    VALUES (
      p_source_uri, p_vendor_name, l_vid, p_invoice_num,
      TO_DATE(p_invoice_date,'YYYY-MM-DD'), p_invoice_amount, p_currency, p_org_id,
      p_po_number, p_line_json, p_confidence, SUBSTR(l_reason,1,400),
      CASE WHEN p_confidence >= l_thr THEN 'EXTRACTED' ELSE 'NEEDS_REVIEW' END, l_grp)
    RETURNING staging_id INTO l_sid;

    IF p_confidence >= l_thr THEN
      push_to_interface(l_sid, l_grp);   -- straight-through to the seeded interface
      l_status := 'STAGED';
    ELSE
      l_status := 'NEEDS_REVIEW';        -- human-in-the-loop
    END IF;
    COMMIT;

    p_result := JSON_OBJECT(
      'status' VALUE 'success', 'staging_id' VALUE l_sid, 'lifecycle' VALUE l_status,
      'vendor_id' VALUE l_vid, 'confidence' VALUE p_confidence, 'threshold' VALUE l_thr,
      'group_id' VALUE l_grp,
      'message' VALUE CASE WHEN p_confidence >= l_thr
                          THEN 'Staged to AP Open Interface (group '||l_grp||')'
                          ELSE 'Low confidence ('||p_confidence||' < '||l_thr||') -> NEEDS_REVIEW' END);
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END stage_invoice;

  PROCEDURE approve_staged(
    p_staging_id     IN NUMBER,
    p_reviewer       IN VARCHAR2,
    p_result         OUT CLOB,
    p_vendor_name    IN VARCHAR2 DEFAULT NULL,
    p_invoice_num    IN VARCHAR2 DEFAULT NULL,
    p_invoice_amount IN NUMBER   DEFAULT NULL,
    p_invoice_date   IN VARCHAR2 DEFAULT NULL,
    p_currency       IN VARCHAR2 DEFAULT NULL,
    p_po_number      IN VARCHAR2 DEFAULT NULL) IS
    l_grp VARCHAR2(80);
    l_cnt NUMBER;
    l_vid NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_cnt FROM apps.xx_p2p_staging
     WHERE staging_id=p_staging_id AND status='NEEDS_REVIEW';
    IF l_cnt = 0 THEN
      p_result := JSON_OBJECT('status' VALUE 'no_op', 'message' VALUE 'Not in NEEDS_REVIEW state');
      RETURN;
    END IF;

    -- Re-resolve vendor_id in PL/SQL (can't call resolve_vendor inside SQL) if the
    -- reviewer changed the vendor name.
    IF p_vendor_name IS NOT NULL THEN l_vid := resolve_vendor(p_vendor_name); END IF;

    -- Apply any human corrections (NULL = keep the extracted value).
    UPDATE apps.xx_p2p_staging
       SET vendor_name    = NVL(p_vendor_name, vendor_name),
           vendor_id      = CASE WHEN p_vendor_name IS NOT NULL THEN l_vid ELSE vendor_id END,
           invoice_num    = NVL(p_invoice_num, invoice_num),
           invoice_amount = NVL(p_invoice_amount, invoice_amount),
           invoice_date   = NVL(TO_DATE(p_invoice_date,'YYYY-MM-DD'), invoice_date),
           currency_code  = NVL(p_currency, currency_code),
           po_number      = NVL(p_po_number, po_number),
           reviewed_by    = p_reviewer,
           reviewed_at    = SYSTIMESTAMP
     WHERE staging_id=p_staging_id AND status='NEEDS_REVIEW'
     RETURNING group_id INTO l_grp;

    push_to_interface(p_staging_id, l_grp);
    COMMIT;
    p_result := JSON_OBJECT('status' VALUE 'success', 'staging_id' VALUE p_staging_id,
                            'lifecycle' VALUE 'STAGED',
                            'message' VALUE 'Approved + staged to AP interface (group '||l_grp||')');
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END approve_staged;

  PROCEDURE reject_staged(p_staging_id IN NUMBER, p_reviewer IN VARCHAR2,
                          p_reason IN VARCHAR2, p_result OUT CLOB) IS
  BEGIN
    UPDATE apps.xx_p2p_staging
       SET status='REJECTED', reviewed_by=p_reviewer, reviewed_at=SYSTIMESTAMP,
           review_reason = SUBSTR('REJECTED: '||NVL(p_reason,'no reason given')
                                  ||' (was: '||review_reason||')', 1, 400)
     WHERE staging_id=p_staging_id AND status='NEEDS_REVIEW';
    IF SQL%ROWCOUNT = 0 THEN
      p_result := JSON_OBJECT('status' VALUE 'no_op', 'message' VALUE 'Not in NEEDS_REVIEW state');
      RETURN;
    END IF;
    COMMIT;
    p_result := JSON_OBJECT('status' VALUE 'success', 'staging_id' VALUE p_staging_id,
                            'lifecycle' VALUE 'REJECTED',
                            'message' VALUE 'Invoice rejected; will not enter Payables');
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END reject_staged;

  PROCEDURE get_review_queue(p_result OUT CLOB) IS
    l_json CLOB;
  BEGIN
    SELECT JSON_ARRAYAGG(JSON_OBJECT(
             'staging_id' VALUE staging_id, 'vendor_name' VALUE vendor_name,
             'invoice_num' VALUE invoice_num, 'invoice_amount' VALUE invoice_amount,
             'currency' VALUE currency_code, 'confidence' VALUE confidence,
             'review_reason' VALUE review_reason,
             'source_uri' VALUE source_uri, 'po_number' VALUE po_number
             RETURNING CLOB) RETURNING CLOB)
      INTO l_json
      FROM (SELECT * FROM apps.xx_p2p_staging WHERE status='NEEDS_REVIEW'
             ORDER BY created_at DESC FETCH FIRST 100 ROWS ONLY);
    p_result := NVL(l_json, TO_CLOB('[]'));
  END get_review_queue;

  PROCEDURE submit_import(p_org_id IN NUMBER, p_group_id IN VARCHAR2, p_result OUT CLOB) IS
    l_req   NUMBER;
    -- FND_REQUEST needs a real apps context (FND user + responsibility) to resolve the
    -- Oracle account; a bare oracledb session has none, so initialize explicitly.
    -- SYSADMIN (user_id 0) + Payables Manager (resp 20639, appl 200) exist on this instance.
    -- headless DB/ORDS sessions return user_id = -1 (NOT null), so NVL leaves -1 and the
    -- request/audit shows ANONYMOUS. Treat <=0 as "no context" and fall back to SYSADMIN(0).
    l_user  NUMBER := GREATEST(NVL(FND_GLOBAL.user_id, 0), 0);
    l_resp  NUMBER := CASE WHEN NVL(FND_GLOBAL.resp_id, -1) > 0
                           THEN FND_GLOBAL.resp_id ELSE 20639 END;   -- Payables Manager
    l_appl  NUMBER := CASE WHEN NVL(FND_GLOBAL.resp_appl_id, -1) > 0
                           THEN FND_GLOBAL.resp_appl_id ELSE 200 END; -- SQLAP (Payables)
  BEGIN
    -- Initialize an apps context, then submit the SEEDED APXIIMPT program.
    FND_GLOBAL.apps_initialize(l_user, l_resp, l_appl);
    MO_GLOBAL.set_policy_context('S', p_org_id);  -- single-org context for the import

    l_req := FND_REQUEST.SUBMIT_REQUEST(
      application => 'SQLAP',
      program     => 'APXIIMPT',           -- Payables Open Interface Import
      description => 'P2P AI agent import',
      start_time  => SYSDATE,
      sub_request => FALSE,
      -- APXIIMPT parameter order VERIFIED on this instance via $SRS$.APXIIMPT:
      --   1=Operating Unit, 2=Source, 3=Group, 4=Batch Name, 5=Hold Name, 6=Hold Reason,
      --   7=GL Date, 8=Purge, 9=Trace, 10=Debug, 11=Summarize, 12=Commit Batch Size,
      --   13=User ID, 14=Login ID, 15=Skip Validation.
      -- (Operating Unit is FIRST — passing Source in slot 1 caused REP-0091 "Invalid P_ORG_ID".)
      argument1   => TO_CHAR(p_org_id),    -- Operating Unit (numeric org id, e.g. 204)
      argument2   => 'AI_AGENT_P2P',       -- Source
      argument3   => p_group_id);          -- Group
    COMMIT;

    IF l_req = 0 THEN
      p_result := JSON_OBJECT('status' VALUE 'error',
                              'message' VALUE 'FND_REQUEST.SUBMIT_REQUEST returned 0: '||
                                              SUBSTR(FND_MESSAGE.GET,1,300));
    ELSE
      p_result := JSON_OBJECT('status' VALUE 'success', 'request_id' VALUE l_req,
        'message' VALUE 'Submitted APXIIMPT (Payables Open Interface Import) request '||l_req,
        'source' VALUE 'AI_AGENT_P2P', 'group_id' VALUE p_group_id, 'org_id' VALUE p_org_id);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END submit_import;

  PROCEDURE get_interface_status(p_result OUT CLOB, p_top IN NUMBER DEFAULT 25) IS
    l_pending  CLOB;
    l_imported CLOB;
    l_np       NUMBER := 0;   -- rows still sitting in the interface
    l_ni       NUMBER := 0;   -- rows already imported into Payables
    l_rej      NUMBER := 0;   -- interface rows the import rejected
  BEGIN
    -- 1) PENDING / REJECTED in the Open Interface (our AI source only). A row is still
    --    "pending" until APXIIMPT consumes it; APXIIMPT sets STATUS='PROCESSED' on success
    --    or 'REJECTED' on validation failure (and writes reasons to AP_INTERFACE_REJECTIONS).
    SELECT COUNT(*),
           NVL(SUM(CASE WHEN UPPER(NVL(status,'PENDING'))='REJECTED' THEN 1 ELSE 0 END),0)
      INTO l_np, l_rej
      FROM ap.ap_invoices_interface
     WHERE source = 'AI_AGENT_P2P';

    SELECT JSON_ARRAYAGG(JSON_OBJECT(
             'invoice_num'    VALUE invoice_num,
             'vendor_name'    VALUE vendor_name,
             'invoice_amount' VALUE invoice_amount,
             'currency'       VALUE invoice_currency_code,
             'group_id'       VALUE group_id,
             'po_number'      VALUE po_number,
             'status'         VALUE NVL(status,'PENDING')
             RETURNING CLOB) RETURNING CLOB)
      INTO l_pending
      FROM (SELECT * FROM ap.ap_invoices_interface
             WHERE source = 'AI_AGENT_P2P'
             ORDER BY creation_date DESC NULLS LAST, invoice_id DESC
             FETCH FIRST p_top ROWS ONLY);

    -- 2) IMPORTED into Payables: the same AI source now present in AP_INVOICES_ALL.
    SELECT COUNT(*) INTO l_ni
      FROM ap.ap_invoices_all
     WHERE source = 'AI_AGENT_P2P';

    SELECT JSON_ARRAYAGG(JSON_OBJECT(
             'invoice_id'     VALUE invoice_id,
             'invoice_num'    VALUE invoice_num,
             'invoice_amount' VALUE invoice_amount,
             'currency'       VALUE invoice_currency_code,
             'invoice_date'   VALUE TO_CHAR(invoice_date,'YYYY-MM-DD'),
             'status'         VALUE 'IMPORTED'
             RETURNING CLOB) RETURNING CLOB)
      INTO l_imported
      FROM (SELECT * FROM ap.ap_invoices_all
             WHERE source = 'AI_AGENT_P2P'
             ORDER BY invoice_id DESC
             FETCH FIRST p_top ROWS ONLY);

    -- Assemble the wrapper by string concatenation. l_pending / l_imported are already
    -- valid JSON arrays; embedding them via JSON_OBJECT(... FORMAT JSON) / nested CLOBs
    -- triggers PLS-00684 on this DB version, so build the object directly (bulletproof).
    p_result := '{"status":"success"'
             || ',"pending_count":'  || l_np
             || ',"rejected_count":' || l_rej
             || ',"imported_count":' || l_ni
             || ',"pending":'  || NVL(l_pending,  TO_CLOB('[]'))
             || ',"imported":' || NVL(l_imported, TO_CLOB('[]'))
             || '}';
  EXCEPTION WHEN OTHERS THEN
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END get_interface_status;

END xx_p2p_ingest_pkg;
/

prompt === XX_P2P_INGEST_PKG status ===
SELECT object_name, object_type, status FROM all_objects
 WHERE owner='APPS' AND object_name='XX_P2P_INGEST_PKG' ORDER BY object_type;
SHOW ERRORS PACKAGE BODY apps.xx_p2p_ingest_pkg
