# Customer Credit Risk Classification Policy

## 1. Risk Categories

### HIGH_RISK
Criteria (ANY of the following):
- Maximum days overdue > 90
- Total overdue amount > $100,000
- More than 5 overdue invoices simultaneously
- Bounced payments in last 90 days
- Credit hold placed in last 6 months
- Industry sector in economic downturn

Actions required:
- Weekly review by collections manager
- Credit hold recommendation if not already in place
- No new credit extensions without VP approval
- Dunning at Level 2 minimum
- Account manager notification within 24 hours of classification change

### MEDIUM_RISK
Criteria (ANY of the following):
- Maximum days overdue 61-90
- Total overdue amount $25,000 - $100,000
- 3-5 overdue invoices simultaneously
- Payment pattern deteriorating (DSO increasing >20% quarter over quarter)
- Recently downgraded from good standing

Actions required:
- Bi-weekly review by collections team
- Dunning Level 1 initiated
- Credit limit review scheduled
- Account manager informed
- Payment plan discussion initiated if >60 days

### HIGH_VALUE
Criteria:
- Annual revenue > $500,000
- Some overdue balance exists but within normal parameters
- Strong payment history overall
- Strategic relationship

Actions required:
- Gentle approach — relationship preservation priority
- Account manager leads communication
- Extended payment terms may be offered
- No credit hold without executive approval
- Quarterly relationship review

### NORMAL
Criteria:
- Does not meet any of the above criteria
- Standard payment terms
- Minor overdue amounts within tolerance

Actions required:
- Standard collections process
- Automated dunning at Level 1 after 30 days
- Escalation only if pattern develops

## 2. Classification Triggers
Risk classification is re-evaluated:
- When payment is received (may improve classification)
- When invoice becomes overdue (may worsen classification)
- Monthly batch review of all accounts
- Upon credit limit change request
- Upon customer complaint or dispute

## 3. Override Authority
- Collections Manager: Can override classification for 30 days with documentation
- Director: Can override for 90 days
- VP: Can permanently reclassify with annual review

## 4. Integration with EBS
- Risk category stored in HZ_CUSTOMER_PROFILES.CUSTOMER_CLASS_CODE
- Classification history tracked in customer notes
- Dashboard displays real-time risk distribution
- Agent uses classification to determine appropriate actions and tone
