# SOP: Handling Disputed Invoices

## Applies To
Any invoice where the customer has raised a formal or informal dispute regarding accuracy, delivery, or terms.

## Rationale
Disputed invoices require a different handling path than standard overdue collections. Continuing dunning on disputed items damages customer relationships and may violate contractual obligations.

## Procedure

### Step 1: Log the Dispute
- Create EBS note on the customer account with:
  - Dispute reason code (from valid list below)
  - Invoice number(s) affected
  - Date customer raised dispute
  - Customer contact who raised it
  - Supporting documentation reference (if provided)

### Step 2: Freeze Dunning
- Exclude disputed invoice from aging calculations for dunning purposes
- Do NOT include in dunning letters or payment reminders
- Do NOT count toward credit hold thresholds
- The invoice remains "Open" in EBS but flagged as disputed

### Step 3: Route to Billing Team
- Create JTF task assigned to Billing Resolution team
- Priority: High
- Due date: Next business day
- Include: Invoice number, dispute reason, customer documentation
- SLA: Billing team must acknowledge within 24 hours

### Step 4: Resolution Timeline
- Target resolution: 10 business days from dispute logging
- Day 5: Check status with billing team (automated reminder task)
- Day 10: If unresolved, escalate to AR Manager
- Day 15: AR Manager escalates to Controller if still open

### Step 5: Resolution Actions
Based on investigation outcome:

**Dispute Valid (customer is correct):**
- Issue credit memo for full or partial amount
- Send confirmation to customer
- Update EBS note with resolution
- Resume normal collections on remaining balance (if any)
- Close dispute task

**Dispute Invalid (original invoice correct):**
- Send detailed explanation to customer with supporting documentation
- Reactivate invoice in aging calculations
- Resume dunning from current aging level (do not restart from Level 1)
- Update EBS note with determination
- Close dispute task

**Partial Resolution:**
- Issue credit memo for agreed portion
- Create new invoice for revised amount (if needed)
- Resume collections on undisputed balance
- Document agreement in EBS notes

### Step 6: Collections Resumption
- When resuming collections after dispute resolution:
  - Recalculate days overdue from dispute resolution date (NOT original due date)
  - Start dunning from Level 1 regardless of calendar days overdue
  - Allow 7-day grace period before first dunning after resolution

## Valid Dispute Reason Codes
| Code | Reason | Typical Resolution |
|---|---|---|
| PRICE | Incorrect pricing on invoice | Price correction, credit memo |
| GOODS_NR | Goods not received | Proof of delivery or credit |
| GOODS_DMG | Goods received damaged | RMA or credit |
| SVC_NP | Services not performed | Service verification or credit |
| DUPLICATE | Duplicate billing | Void duplicate invoice |
| TERMS | Contract terms disagreement | Contract review, adjustment |
| PO_MISMATCH | PO number incorrect or missing | Reissue with correct PO |
| QTY | Quantity discrepancy | Quantity verification, adjustment |

## Key Rules
- NEVER send dunning for a disputed invoice
- NEVER include disputed amounts in credit hold calculations
- ALWAYS route to billing within 24 hours
- Dispute freeze does NOT expire — only resolved or escalated
- Customer must provide some form of documentation within 30 days or dispute auto-closes
