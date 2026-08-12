# Payment Reminder Template (HTML Email)

## Trigger Criteria
- Invoice due within 7 days (pre-due reminder) OR
- Invoice overdue 1-14 days (early reminder, before formal dunning)
- Used for gentle nudge before Level 1 dunning kicks in

## Tone
Informational, helpful. Not a dunning letter — just a courtesy reminder.

## Subject Line
Upcoming Payment Due — Invoice {INVOICE_NUMBER} — {DUE_DATE}

## Template (HTML)

```html
<!DOCTYPE html>
<html>
<head>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; color: #333; line-height: 1.6; }
    .container { max-width: 600px; margin: 0 auto; padding: 20px; }
    .header { background: #1a365d; color: white; padding: 20px; border-radius: 8px 8px 0 0; }
    .content { background: #f8f9fa; padding: 24px; border: 1px solid #e2e8f0; }
    .invoice-box { background: white; border: 1px solid #e2e8f0; border-radius: 6px; padding: 16px; margin: 16px 0; }
    .amount { font-size: 24px; font-weight: bold; color: #1a365d; }
    .due-date { color: #e53e3e; font-weight: 600; }
    .pay-button { display: inline-block; background: #2b6cb0; color: white; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-weight: 600; }
    .footer { padding: 16px; font-size: 12px; color: #718096; text-align: center; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h2 style="margin:0;">Payment Reminder</h2>
      <p style="margin:4px 0 0 0; opacity:0.8;">Account: {ACCOUNT_NUMBER}</p>
    </div>
    <div class="content">
      <p>Dear {CUSTOMER_NAME},</p>
      <p>This is a friendly reminder that the following payment is {DUE_STATUS}:</p>
      
      <div class="invoice-box">
        <table style="width:100%; border-collapse:collapse;">
          <tr><td><strong>Invoice:</strong></td><td>{INVOICE_NUMBER}</td></tr>
          <tr><td><strong>Date:</strong></td><td>{INVOICE_DATE}</td></tr>
          <tr><td><strong>Due Date:</strong></td><td class="due-date">{DUE_DATE}</td></tr>
          <tr><td><strong>Amount:</strong></td><td class="amount">{CURRENCY} {AMOUNT_DUE}</td></tr>
        </table>
      </div>

      <p>If you have already sent payment, thank you — please disregard this notice.</p>
      
      <p style="text-align:center; margin: 24px 0;">
        <a href="{PAYMENT_PORTAL_URL}" class="pay-button">Make Payment</a>
      </p>
      
      <p>Payment options:</p>
      <ul>
        <li>Online: <a href="{PAYMENT_PORTAL_URL}">{PAYMENT_PORTAL_URL}</a></li>
        <li>Bank Transfer: {BANK_DETAILS}</li>
        <li>Reference: Invoice {INVOICE_NUMBER}</li>
      </ul>
      
      <p>Questions? Reply to this email or call {CONTACT_PHONE}.</p>
    </div>
    <div class="footer">
      <p>{COMPANY_NAME} | {COMPANY_ADDRESS}</p>
      <p>This is an automated payment reminder. If you believe you received this in error, please contact us.</p>
    </div>
  </div>
</body>
</html>
```

## Usage Notes
- Send via Amazon SES
- Schedule: 5 days before due date (pre-due) or Day 3 overdue (post-due)
- This is NOT a dunning letter — it's a courtesy reminder
- Can be sent automatically without collections manager review
- Do NOT send if invoice is disputed
- Do NOT send if payment plan covers this invoice
- Log as EBS note: "Payment reminder sent via email"
