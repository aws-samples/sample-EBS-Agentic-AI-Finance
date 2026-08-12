-- =============================================================================
-- XX_KB_REFRESH_26ai.sql - idempotent refresh of KB document CONTENT + re-embed.
-- Run as COLLECTIONS_AI in PDB ERPUAT (after XX_KB_SEED_26ai.sql).
--
-- WHY THIS EXISTS
--   XX_KB_SEED_26ai.sql only INSERTs when the table is empty (its guard prevents
--   duplicates on re-deploy). That means editing a document's content there does NOT
--   reach an already-seeded database. This script is the reproducible content authority:
--   it UPDATEs each row's content in place (matched by summary) and re-embeds any row
--   whose text changed, so the live DB always matches the repo - on fresh AND existing DBs.
--
-- IDEMPOTENT & SAFE
--   * UPDATE ... WHERE summary = ... AND content != new  → only touches changed rows.
--   * Nulls the embedding on change, then regenerates it via in-DB ONNX (COLL_EMBED_MODEL)
--     so semantic search stays aligned with the display text (changed text must be
--     re-embedded or ranking goes stale).
--   * Re-runnable: a second run updates 0 rows and re-embeds 0 rows.
--   * Keep the content here identical to XX_KB_SEED_26ai.sql so fresh + existing match.
-- =============================================================================
SET SERVEROUTPUT ON
SET DEFINE OFF
WHENEVER SQLERROR CONTINUE

DECLARE
  -- Update content only when it actually differs (keeps the run a no-op when unchanged),
  -- and null the embedding so the re-embed pass below regenerates just the changed rows.
  PROCEDURE upd(p_summary VARCHAR2, p_content CLOB) IS
  BEGIN
    UPDATE collections_knowledge_base
       SET content = p_content, embedding = NULL, updated_at = SYSTIMESTAMP
     WHERE summary = p_summary
       AND DBMS_LOB.COMPARE(content, p_content) != 0;
    IF SQL%ROWCOUNT > 0 THEN
      DBMS_OUTPUT.PUT_LINE('refreshed: '||p_summary);
    END IF;
  END;
BEGIN
  upd('Credit hold policy for accounts overdue over 60 days',
    '## Credit Hold Escalation' || CHR(10) || CHR(10) ||
    'Accounts with invoices **overdue more than 60 days** must be reviewed for credit hold placement.' || CHR(10) || CHR(10) ||
    '**Criteria (either triggers review):**' || CHR(10) ||
    '* Total overdue amount exceeds **$10,000**, OR' || CHR(10) ||
    '* More than **3 invoices** overdue simultaneously' || CHR(10) || CHR(10) ||
    '**Before placing a hold:**' || CHR(10) ||
    '* Verify no pending disputes exist' || CHR(10) ||
    '* Notify the account manager **24 hours** before placement' || CHR(10) || CHR(10) ||
    '**Effect:** credit holds block new order entry and shipments.');

  upd('AP invoice match tolerance and hold release policy',
    '## AP Invoice Match Tolerance & Hold Release' || CHR(10) || CHR(10) ||
    'When a Payables invoice is matched to its purchase order and goods receipt, small ' ||
    'variances are allowed before the invoice is placed on hold. The following tolerances ' ||
    'apply to Vision Operations (org 204):' || CHR(10) || CHR(10) ||
    '**Tolerances (within policy — safe to release):**' || CHR(10) ||
    '* **Price variance:** invoice unit price up to **10%** over the PO unit price.' || CHR(10) ||
    '* **Quantity variance:** invoice quantity up to **5%** over the quantity ordered or received.' || CHR(10) || CHR(10) ||
    '**Release rules:**' || CHR(10) ||
    '* A hold whose variance is **within tolerance** may be released by an **AP Manager**, ' ||
    'with a documented reason; the release is audited.' || CHR(10) ||
    '* A variance **above tolerance** requires **manual approval from the AP Manager or ' ||
    'Procurement** before release, or a corrected invoice/PO.' || CHR(10) ||
    '* **No PO match** or a **quantity over-receipt** must be investigated with Receiving/' ||
    'Procurement before payment — do not release on tolerance alone.' || CHR(10) || CHR(10) ||
    '**Note:** these tolerances are the *policy of record*. EBS enforces them via the ' ||
    'operating unit''s Payables tolerance template; the Policy library drift check flags any ' ||
    'divergence between this document and what Payables actually enforces.');

  upd('Dunning letter escalation levels and timing',
    '## Dunning Letter Escalation Levels' || CHR(10) || CHR(10) ||
    '* **Level 1 - 30 days overdue:** friendly reminder, professional tone.' || CHR(10) ||
    '* **Level 2 - 60 days overdue:** firm request mentioning credit review.' || CHR(10) ||
    '* **Level 3 - 90 days overdue:** final notice mentioning credit hold and potential legal action.' || CHR(10) || CHR(10) ||
    '**Rules:**' || CHR(10) ||
    '* Minimum **15-day gap** between letters.' || CHR(10) ||
    '* Do **not** send Level 3 to strategic accounts without **VP approval**.');

  upd('Payment plan authorization limits and requirements',
    '## Payment Plan Authorization' || CHR(10) || CHR(10) ||
    '**Authorization limits:**' || CHR(10) ||
    '* Collections manager: up to **$50,000** over **6 months** - no approval needed.' || CHR(10) ||
    '* Over $50,000 or 6 months: **director approval**.' || CHR(10) ||
    '* Over $200,000 or 12 months: **VP Finance approval**.' || CHR(10) || CHR(10) ||
    '**Every payment plan must include:**' || CHR(10) ||
    '* An agreed installment schedule' || CHR(10) ||
    '* Late-payment penalty of **1.5% monthly**' || CHR(10) ||
    '* Automatic credit hold if **2 consecutive payments** are missed.');

  upd('Standard procedure for disputed invoices',
    '## SOP: Handling Disputed Invoices' || CHR(10) || CHR(10) ||
    '1. **Log** the dispute in EBS notes with a reason code.' || CHR(10) ||
    '2. **Freeze dunning** for the disputed invoice.' || CHR(10) ||
    '3. **Route** to the billing team within **24 hours**.' || CHR(10) ||
    '4. If not resolved within **10 business days**, escalate to the **AR manager**.' || CHR(10) ||
    '5. If the customer provides valid documentation, issue a **credit memo**.' || CHR(10) ||
    '6. Resume collections on the **undisputed balance only**.');

  upd('Procedure for new customer first late payment',
    '## SOP: New Customer First Late Payment' || CHR(10) || CHR(10) ||
    'For customers with **less than 6 months** history who miss their first payment:' || CHR(10) || CHR(10) ||
    '* Wait **7 days** before first contact.' || CHR(10) ||
    '* Make a **courtesy call** before sending written notice.' || CHR(10) ||
    '* Do **NOT** place a credit hold on first occurrence unless the amount exceeds **$25,000**.' || CHR(10) ||
    '* Document the interaction in EBS notes.' || CHR(10) ||
    '* Schedule a **follow-up task for 14 days**.');

  upd('Procedure for setting up a customer payment plan',
    '## SOP: Payment Plan Setup' || CHR(10) || CHR(10) ||
    '1. **Confirm** the total balance and the customer hardship reason.' || CHR(10) ||
    '2. **Propose** a schedule within authorization limits.' || CHR(10) ||
    '3. **Document** terms in an EBS note with penalties of **1.5% monthly**.' || CHR(10) ||
    '4. **Set** an automatic credit-hold trigger after **2 missed payments**.' || CHR(10) ||
    '5. **Confirm** the plan in writing.' || CHR(10) ||
    '6. **Create** follow-up tasks for each installment.');

  upd('Level 1 dunning letter template friendly reminder tone',
    '## Dunning Template - Level 1 (Friendly Reminder)' || CHR(10) || CHR(10) ||
    '**Subject:** Payment Reminder for Invoice NUMBER' || CHR(10) || CHR(10) ||
    'Dear CUSTOMER_NAME,' || CHR(10) || CHR(10) ||
    'We wanted to bring to your attention that invoice **NUMBER** for **AMOUNT** was due on **DUE_DATE** and remains outstanding. If payment has already been sent, please disregard this notice.' || CHR(10) || CHR(10) ||
    'Thank you for your continued partnership.');

  upd('Level 2 dunning letter template firm professional tone',
    '## Dunning Template - Level 2 (Firm Request)' || CHR(10) || CHR(10) ||
    '**Subject:** Past Due Notice - Immediate Attention Required' || CHR(10) || CHR(10) ||
    'Dear CUSTOMER_NAME,' || CHR(10) || CHR(10) ||
    'Your account has invoices totaling **TOTAL_AMOUNT** that are now **DAYS days past due**. We request immediate payment or contact within **5 business days**.' || CHR(10) || CHR(10) ||
    'Continued non-payment may result in a review of your credit terms.');

  upd('Level 3 dunning letter template final notice',
    '## Dunning Template - Level 3 (Final Notice)' || CHR(10) || CHR(10) ||
    '**Subject:** FINAL NOTICE - Account ACCOUNT_NUMBER Past Due' || CHR(10) || CHR(10) ||
    'Dear CUSTOMER_NAME,' || CHR(10) || CHR(10) ||
    'Your account remains significantly past due with **TOTAL_AMOUNT** outstanding for **DAYS days**. This is the **final notice** before credit hold, suspension of open orders, and referral to collections.' || CHR(10) || CHR(10) ||
    'Remit full payment within **7 calendar days**.');

  COMMIT;
END;
/

-- Re-embed only the rows the refresh just changed (embedding IS NULL). In-DB ONNX,
-- provider "database". Fail-open: if the model is absent, search falls back to keyword.
-- We check for the model FIRST so the common "not loaded yet" case prints a clean, expected
-- message instead of an alarming ORA-40284 stack (the model is loaded later by
-- collections_agent/scripts/load_onnx_model.sh).
DECLARE
  n NUMBER := 0;
  model_cnt NUMBER := 0;
BEGIN
  SELECT COUNT(*) INTO model_cnt FROM user_mining_models WHERE model_name = 'COLL_EMBED_MODEL';
  IF model_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('KB embeddings skipped: COLL_EMBED_MODEL not loaded yet — search uses '
      ||'keyword fallback. Run collections_agent/scripts/load_onnx_model.sh to enable semantic RAG.');
  ELSE
    FOR r IN (SELECT id, content FROM collections_knowledge_base WHERE embedding IS NULL) LOOP
      UPDATE collections_knowledge_base
         SET embedding = DBMS_VECTOR_CHAIN.UTL_TO_EMBEDDING(
               r.content, JSON('{"provider":"database","model":"COLL_EMBED_MODEL"}'))
       WHERE id = r.id;
      n := n + 1;
    END LOOP;
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('KB refresh: re-embedded '||n||' row(s)');
  END IF;
EXCEPTION WHEN OTHERS THEN
  DBMS_OUTPUT.PUT_LINE('KB refresh: re-embed skipped (keyword fallback): '||SQLERRM);
END;
/
