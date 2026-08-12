-- =============================================================================
-- XX_KB_SEED_26ai.sql  - idempotent seed of 9 KB docs (run as COLLECTIONS_AI)
-- Inserts only if the table is empty. Embeddings populated separately (ONNX/Titan).
-- NOTE: because this is insert-only-when-empty, editing content here does NOT reach an
-- already-seeded DB. XX_KB_REFRESH_26ai.sql (run right after, by deploy_ai_layer.sh)
-- UPDATEs existing rows to this same content + re-embeds. Keep the two in sync.
-- =============================================================================
SET SERVEROUTPUT ON
-- KB doc text contains literal '&' (e.g. "Tolerance & Hold Release"); disable SQL*Plus
-- substitution so '&' is inserted literally instead of prompting (SP2-0546 over SSM).
SET DEFINE OFF
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM collections_knowledge_base;
  IF n > 0 THEN
    DBMS_OUTPUT.PUT_LINE('KB already has '||n||' rows, skipping seed');
    RETURN;
  END IF;

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## Credit Hold Escalation' || CHR(10) || CHR(10) ||
    'Accounts with invoices **overdue more than 60 days** must be reviewed for credit hold placement.' || CHR(10) || CHR(10) ||
    '**Criteria (either triggers review):**' || CHR(10) ||
    '* Total overdue amount exceeds **$10,000**, OR' || CHR(10) ||
    '* More than **3 invoices** overdue simultaneously' || CHR(10) || CHR(10) ||
    '**Before placing a hold:**' || CHR(10) ||
    '* Verify no pending disputes exist' || CHR(10) ||
    '* Notify the account manager **24 hours** before placement' || CHR(10) || CHR(10) ||
    '**Effect:** credit holds block new order entry and shipments.',
    'Credit hold policy for accounts overdue over 60 days', 'policy',
    JSON_OBJECT('source' VALUE 'AR_COLLECTIONS_POLICY_v3.pdf', 'section' VALUE '4.2'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
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
    'divergence between this document and what Payables actually enforces.',
    'AP invoice match tolerance and hold release policy', 'policy',
    JSON_OBJECT('source' VALUE 'AP_PAYABLES_POLICY_v2.pdf', 'section' VALUE '3.1'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## Dunning Letter Escalation Levels' || CHR(10) || CHR(10) ||
    '* **Level 1 - 30 days overdue:** friendly reminder, professional tone.' || CHR(10) ||
    '* **Level 2 - 60 days overdue:** firm request mentioning credit review.' || CHR(10) ||
    '* **Level 3 - 90 days overdue:** final notice mentioning credit hold and potential legal action.' || CHR(10) || CHR(10) ||
    '**Rules:**' || CHR(10) ||
    '* Minimum **15-day gap** between letters.' || CHR(10) ||
    '* Do **not** send Level 3 to strategic accounts without **VP approval**.',
    'Dunning letter escalation levels and timing', 'policy',
    JSON_OBJECT('source' VALUE 'AR_COLLECTIONS_POLICY_v3.pdf', 'section' VALUE '5.1'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## Payment Plan Authorization' || CHR(10) || CHR(10) ||
    '**Authorization limits:**' || CHR(10) ||
    '* Collections manager: up to **$50,000** over **6 months** - no approval needed.' || CHR(10) ||
    '* Over $50,000 or 6 months: **director approval**.' || CHR(10) ||
    '* Over $200,000 or 12 months: **VP Finance approval**.' || CHR(10) || CHR(10) ||
    '**Every payment plan must include:**' || CHR(10) ||
    '* An agreed installment schedule' || CHR(10) ||
    '* Late-payment penalty of **1.5% monthly**' || CHR(10) ||
    '* Automatic credit hold if **2 consecutive payments** are missed.',
    'Payment plan authorization limits and requirements', 'policy',
    JSON_OBJECT('source' VALUE 'AR_COLLECTIONS_POLICY_v3.pdf', 'section' VALUE '6.3'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## SOP: Handling Disputed Invoices' || CHR(10) || CHR(10) ||
    '1. **Log** the dispute in EBS notes with a reason code.' || CHR(10) ||
    '2. **Freeze dunning** for the disputed invoice.' || CHR(10) ||
    '3. **Route** to the billing team within **24 hours**.' || CHR(10) ||
    '4. If not resolved within **10 business days**, escalate to the **AR manager**.' || CHR(10) ||
    '5. If the customer provides valid documentation, issue a **credit memo**.' || CHR(10) ||
    '6. Resume collections on the **undisputed balance only**.',
    'Standard procedure for disputed invoices', 'sop',
    JSON_OBJECT('source' VALUE 'COLLECTIONS_SOP_v2.pdf', 'section' VALUE '3.4'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## SOP: New Customer First Late Payment' || CHR(10) || CHR(10) ||
    'For customers with **less than 6 months** history who miss their first payment:' || CHR(10) || CHR(10) ||
    '* Wait **7 days** before first contact.' || CHR(10) ||
    '* Make a **courtesy call** before sending written notice.' || CHR(10) ||
    '* Do **NOT** place a credit hold on first occurrence unless the amount exceeds **$25,000**.' || CHR(10) ||
    '* Document the interaction in EBS notes.' || CHR(10) ||
    '* Schedule a **follow-up task for 14 days**.',
    'Procedure for new customer first late payment', 'sop',
    JSON_OBJECT('source' VALUE 'COLLECTIONS_SOP_v2.pdf', 'section' VALUE '2.1'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## SOP: Payment Plan Setup' || CHR(10) || CHR(10) ||
    '1. **Confirm** the total balance and the customer hardship reason.' || CHR(10) ||
    '2. **Propose** a schedule within authorization limits.' || CHR(10) ||
    '3. **Document** terms in an EBS note with penalties of **1.5% monthly**.' || CHR(10) ||
    '4. **Set** an automatic credit-hold trigger after **2 missed payments**.' || CHR(10) ||
    '5. **Confirm** the plan in writing.' || CHR(10) ||
    '6. **Create** follow-up tasks for each installment.',
    'Procedure for setting up a customer payment plan', 'sop',
    JSON_OBJECT('source' VALUE 'COLLECTIONS_SOP_v2.pdf', 'section' VALUE '4.1'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## Dunning Template - Level 1 (Friendly Reminder)' || CHR(10) || CHR(10) ||
    '**Subject:** Payment Reminder for Invoice NUMBER' || CHR(10) || CHR(10) ||
    'Dear CUSTOMER_NAME,' || CHR(10) || CHR(10) ||
    'We wanted to bring to your attention that invoice **NUMBER** for **AMOUNT** was due on **DUE_DATE** and remains outstanding. If payment has already been sent, please disregard this notice.' || CHR(10) || CHR(10) ||
    'Thank you for your continued partnership.',
    'Level 1 dunning letter template friendly reminder tone', 'template',
    JSON_OBJECT('level' VALUE 1, 'tone' VALUE 'friendly', 'days_overdue' VALUE '30'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## Dunning Template - Level 2 (Firm Request)' || CHR(10) || CHR(10) ||
    '**Subject:** Past Due Notice - Immediate Attention Required' || CHR(10) || CHR(10) ||
    'Dear CUSTOMER_NAME,' || CHR(10) || CHR(10) ||
    'Your account has invoices totaling **TOTAL_AMOUNT** that are now **DAYS days past due**. We request immediate payment or contact within **5 business days**.' || CHR(10) || CHR(10) ||
    'Continued non-payment may result in a review of your credit terms.',
    'Level 2 dunning letter template firm professional tone', 'template',
    JSON_OBJECT('level' VALUE 2, 'tone' VALUE 'firm', 'days_overdue' VALUE '60'));

  INSERT INTO collections_knowledge_base (content, summary, doc_type, metadata) VALUES (
    '## Dunning Template - Level 3 (Final Notice)' || CHR(10) || CHR(10) ||
    '**Subject:** FINAL NOTICE - Account ACCOUNT_NUMBER Past Due' || CHR(10) || CHR(10) ||
    'Dear CUSTOMER_NAME,' || CHR(10) || CHR(10) ||
    'Your account remains significantly past due with **TOTAL_AMOUNT** outstanding for **DAYS days**. This is the **final notice** before credit hold, suspension of open orders, and referral to collections.' || CHR(10) || CHR(10) ||
    'Remit full payment within **7 calendar days**.',
    'Level 3 dunning letter template final notice', 'template',
    JSON_OBJECT('level' VALUE 3, 'tone' VALUE 'final_notice', 'days_overdue' VALUE '90'));

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('KB seeded with 9 docs');
END;
/
