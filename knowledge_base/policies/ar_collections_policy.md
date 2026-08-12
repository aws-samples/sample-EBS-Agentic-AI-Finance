# AR Collections Policy v3.0

## 1. Purpose
This policy governs the management of overdue accounts receivable for Oracle E-Business Suite environments. It defines escalation procedures, authorization levels, and customer communication standards.

## 2. Scope
Applies to all customers with open AR balances managed through Oracle EBS R12.2. Covers credit holds, dunning communications, payment plans, and write-off procedures.

## 3. Aging Definitions
- **Current**: Not yet due
- **1-30 Days Overdue**: Early stage — monitoring only
- **31-60 Days Overdue**: Active collections — dunning Level 1
- **61-90 Days Overdue**: Escalated collections — dunning Level 2, credit review
- **>90 Days Overdue**: Critical — dunning Level 3, credit hold, potential legal

## 4. Credit Hold Policy

### 4.1 Automatic Credit Hold Triggers
Credit holds are automatically recommended when:
- Total overdue balance exceeds $10,000 AND account is >60 days overdue
- More than 3 invoices are simultaneously overdue regardless of amount
- Customer has bounced 2 or more payments in the last 6 months
- Account exceeds its approved credit limit by more than 20%

### 4.2 Credit Hold Placement Process
1. Verify no pending disputes exist for the overdue invoices
2. Check if customer is classified as "Strategic" (requires VP approval)
3. Notify the assigned Account Manager 24 hours before placement
4. Place hold via EBS (HZ_CUSTOMER_PROFILES.CREDIT_HOLD = 'Y')
5. Create EBS note documenting the reason and date
6. Send formal notification to customer within 24 hours

### 4.3 Credit Hold Impact
- Blocks new sales order entry
- Blocks shipment of existing orders
- Does NOT block cash receipt application
- Does NOT block credit memo creation

### 4.4 Credit Hold Release Criteria
Credit holds may be released when:
- Full payment received for all overdue amounts
- Payment plan agreed and first installment received
- Valid dispute documentation provided (hold transferred to dispute process)
- Management override with documented approval

## 5. Dunning Communications

### 5.1 Dunning Level 1 — Friendly Reminder (30 days overdue)
- Tone: Friendly, professional
- Channel: Email (primary), letter (if no email)
- Content: Invoice reminder, amount, due date, payment instructions
- No threat of action
- Sent automatically or by collections agent

### 5.2 Dunning Level 2 — Firm Request (60 days overdue)
- Tone: Firm but professional
- Channel: Email with read receipt
- Content: Past due notice, total amount, invoice list, request for immediate payment
- Mentions credit review as consequence
- Minimum 15 days after Level 1
- Requires collections manager review before sending

### 5.3 Dunning Level 3 — Final Notice (90 days overdue)
- Tone: Formal, consequential
- Channel: Email AND registered letter
- Content: Final notice, consequences (credit hold, order suspension, legal referral)
- 7-day deadline for response
- Minimum 15 days after Level 2
- Requires director approval for strategic accounts
- VP approval required if customer revenue >$1M annually

### 5.4 Dunning Restrictions
- Do NOT send dunning for disputed invoices
- Do NOT send Level 3 to strategic/enterprise accounts without VP approval
- Maximum one dunning per customer per 15-day period
- Holiday blackout: No dunning between Dec 20 - Jan 5

## 6. Payment Plans

### 6.1 Authorization Levels
| Plan Amount | Duration | Approver |
|---|---|---|
| Up to $50,000 | Up to 6 months | Collections Manager |
| $50,001 - $200,000 | Up to 12 months | Director |
| >$200,000 | >12 months | VP Finance |

### 6.2 Payment Plan Requirements
- Documented agreement signed by customer
- Late payment penalty: 1.5% monthly on overdue installments
- Automatic credit hold if 2 consecutive payments missed
- Security deposit may be required for amounts >$100,000

## 7. Dispute Management

### 7.1 Dispute Handling Process
1. Log dispute in EBS notes with reason code
2. Freeze dunning for disputed invoice
3. Route to billing team within 24 hours
4. Resolution target: 10 business days
5. If not resolved in 10 days, escalate to AR Manager
6. Customer documentation validates dispute → issue credit memo
7. Resume collections on undisputed balance only

### 7.2 Valid Dispute Reasons
- Incorrect pricing
- Goods not received / damaged
- Services not performed
- Duplicate billing
- Contract terms disagreement

## 8. Write-Off Policy
- Amounts under $500 overdue >180 days: Collections Manager can write off
- Amounts $500-$5,000 overdue >360 days: Director approval
- Amounts >$5,000: VP Finance approval + bad debt reserve review
- All write-offs must be documented with collection effort history

## 9. Strategic Account Handling
Accounts classified as "Strategic" (revenue >$500K annually):
- All escalation actions require one level higher approval
- Direct account manager involvement at every stage
- No automated dunning — all communications reviewed first
- Quarterly executive review of overdue balances
- Relationship preservation prioritized over immediate collection

## 10. Reporting
- Daily: Overdue balance summary by aging bucket
- Weekly: Top 20 risk customers, collections activity summary
- Monthly: Cash flow forecast, DSO trending, write-off analysis
- Quarterly: Policy compliance review, strategic account status
