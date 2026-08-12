# SOP: Payment Plan Setup and Monitoring

## Applies To
Customers requesting extended payment terms for overdue balances. Includes installment plans, deferred payments, and structured settlements.

## Authorization Matrix
| Total Plan Amount | Maximum Duration | Required Approver |
|---|---|---|
| Up to $50,000 | Up to 6 months | Collections Manager |
| $50,001 - $200,000 | Up to 12 months | AR Director |
| Over $200,000 | Over 12 months | VP Finance |

## Procedure

### Step 1: Assess Eligibility
Before proposing a payment plan, verify:
- Customer has communicated willingness to pay (documented in EBS notes)
- No active fraud flags on the account
- Customer has been an active account for >90 days
- Previous payment plans (if any) were completed successfully

### Step 2: Propose Terms
Standard payment plan structures:
- **3-month plan**: Equal monthly installments, no penalty discount
- **6-month plan**: Equal monthly installments, 1.5% monthly penalty on late installments
- **12-month plan**: Monthly installments, 1.5% penalty, first payment = 20% of total
- **Custom**: Requires one level higher approval than standard matrix

Include in proposal:
- Total amount covered by plan
- Number of installments and amounts
- Due dates for each installment
- Late payment penalty terms (1.5% monthly)
- Credit hold trigger (2 missed consecutive payments)
- Any security deposit requirements (amounts >$100,000)

### Step 3: Get Approval
- Prepare payment plan summary document
- Route for approval per authorization matrix
- Include: Customer history, reason for overdue, proposed terms, risk assessment
- SLA: Approval within 3 business days

### Step 4: Document Agreement
- Generate payment plan letter/agreement
- Customer must acknowledge (email confirmation minimum, signed agreement preferred for >$50K)
- Store agreement as EBS attachment or note
- Record in HZ_CUSTOMER_PROFILES notes

### Step 5: Configure in EBS
- Create JTF tasks for each installment due date
- Set reminder: 5 days before each installment
- Update customer notes with payment plan reference
- If credit hold is active: release upon first installment received
- Update customer classification to reflect plan status

### Step 6: Monitor Compliance
- Track each installment against due date
- On-time payment: Mark task complete, no action needed
- Late payment (1-5 days): Send friendly reminder, apply penalty
- Late payment (>5 days): Contact customer, final warning
- Missed payment: Flag for review

### Step 7: Handle Breach
If customer misses 2 consecutive payments:
- Automatic credit hold placement
- Notify account manager
- Contact customer within 24 hours
- Options:
  a) Restructure plan (requires approval one level higher)
  b) Demand full remaining balance
  c) Escalate to legal/external collections

### Step 8: Successful Completion
When plan fully paid:
- Close all related JTF tasks
- Update customer notes: "Payment plan completed successfully"
- Review and potentially improve credit classification
- Consider credit limit increase if appropriate
- Send thank-you communication to customer

## Key Rules
- NEVER allow payment plan to extend beyond 18 months total
- ALWAYS get documented customer acknowledgment before activating
- First installment must be received within 7 days of agreement
- Security deposit required for amounts >$100,000
- Plan does NOT stop interest/penalty accrual on overdue portions
- Customer on active plan is exempt from additional dunning for covered invoices
