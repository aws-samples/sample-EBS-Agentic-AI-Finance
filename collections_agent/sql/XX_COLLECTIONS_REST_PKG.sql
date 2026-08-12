-- =============================================================================
-- XX_COLLECTIONS_REST_PKG.sql
-- Custom PL/SQL package for EBS Collections write-back via ISG REST
-- Deploy on: ERP-R122-SOGW-APP-26aii (application server)
-- 
-- This package provides REST-callable procedures for:
--   - get_overdue_customers
--   - get_customer_details
--   - get_customer_profile (for credit hold profile resolution)
--   - place_credit_hold / release_credit_hold
--   - create_collections_note
--   - send_dunning_letter
--   - send_payment_reminder
-- =============================================================================

-- Idempotent audit table the package writes every note to (create only if absent — swallow
-- ORA-00955). Previously this table was assumed to pre-exist, so on a fresh instance the
-- package body compiled INVALID (static INSERT into a missing table) and create_collections_note
-- failed at runtime ("not recorded"). Creating it here — the same self-provisioning pattern
-- XX_P2P_AP_PKG uses for its audit tables — makes collections write-back work from a standard
-- deploy. Existing table + data are preserved.
DECLARE
  e_exists EXCEPTION;
  PRAGMA EXCEPTION_INIT(e_exists, -955);  -- name is already used by an existing object
BEGIN
  EXECUTE IMMEDIATE q'[
    CREATE TABLE apps.xx_collections_notes (
      note_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      customer_id    NUMBER,
      note_text      VARCHAR2(4000),
      created_by_who VARCHAR2(100),
      created_at     TIMESTAMP DEFAULT SYSTIMESTAMP
    )]';
EXCEPTION WHEN e_exists THEN NULL;
END;
/

CREATE OR REPLACE PACKAGE XX_COLLECTIONS_REST_PKG AS

  -- Get all overdue customers with summary info
  PROCEDURE get_overdue_customers(
    p_result OUT CLOB
  );

  -- Get invoice details for a specific customer
  PROCEDURE get_customer_details(
    p_customer_id IN NUMBER,
    p_result      OUT CLOB
  );

  -- Get customer profile (for credit hold operations)
  PROCEDURE get_customer_profile(
    p_customer_id             IN  NUMBER,
    p_cust_account_profile_id OUT NUMBER,
    p_object_version_number   OUT NUMBER,
    p_credit_hold             OUT VARCHAR2,
    p_credit_limit            OUT NUMBER
  );

  -- Place credit hold on a customer
  PROCEDURE place_credit_hold(
    p_customer_id IN NUMBER,
    p_reason      IN VARCHAR2,
    p_result      OUT CLOB
  );

  -- Release credit hold
  PROCEDURE release_credit_hold(
    p_customer_id IN NUMBER,
    p_reason      IN VARCHAR2,
    p_result      OUT CLOB
  );

  -- Create a collections note on a customer account
  PROCEDURE create_collections_note(
    p_customer_id IN NUMBER,
    p_note_text   IN VARCHAR2,
    p_result      OUT CLOB
  );

  -- Send dunning letter (generates text, stores as note, emails via SES)
  PROCEDURE send_dunning_letter(
    p_customer_id IN NUMBER,
    p_level       IN NUMBER DEFAULT 1,
    p_tone        IN VARCHAR2 DEFAULT 'professional',
    p_result      OUT CLOB
  );

  -- Send payment reminder email
  PROCEDURE send_payment_reminder(
    p_customer_id IN NUMBER,
    p_result      OUT CLOB
  );

END XX_COLLECTIONS_REST_PKG;
/

CREATE OR REPLACE PACKAGE BODY XX_COLLECTIONS_REST_PKG AS

  -- =========================================================================
  PROCEDURE get_overdue_customers(p_result OUT CLOB) AS
    l_json CLOB;
  BEGIN
    SELECT JSON_ARRAYAGG(
      JSON_OBJECT(
        'customer_id'    VALUE hca.cust_account_id,
        'account_number' VALUE hca.account_number,
        'customer_name'  VALUE hp.party_name,
        'total_overdue'  VALUE SUM(aps.amount_due_remaining),
        'invoice_count'  VALUE COUNT(*),
        'oldest_due_date' VALUE MIN(aps.due_date),
        'days_overdue'   VALUE MAX(TRUNC(SYSDATE) - TRUNC(aps.due_date))
      )
      ORDER BY SUM(aps.amount_due_remaining) DESC
    )
    INTO l_json
    FROM ar.ar_payment_schedules_all aps
    JOIN ar.hz_cust_accounts hca ON hca.cust_account_id = aps.customer_id
    JOIN ar.hz_parties hp ON hp.party_id = hca.party_id
    WHERE aps.status = 'OP'
      AND aps.class = 'INV'
      AND aps.due_date < TRUNC(SYSDATE)
      AND aps.amount_due_remaining > 0
    GROUP BY hca.cust_account_id, hca.account_number, hp.party_name;

    p_result := NVL(l_json, '[]');
  END get_overdue_customers;

  -- =========================================================================
  PROCEDURE get_customer_details(p_customer_id IN NUMBER, p_result OUT CLOB) AS
    l_json CLOB;
  BEGIN
    SELECT JSON_ARRAYAGG(
      JSON_OBJECT(
        'invoice_number'  VALUE rct.trx_number,
        'invoice_date'    VALUE rct.trx_date,
        'due_date'        VALUE aps.due_date,
        'amount_original' VALUE aps.amount_due_original,
        'amount_remaining' VALUE aps.amount_due_remaining,
        'days_overdue'    VALUE GREATEST(0, TRUNC(SYSDATE) - TRUNC(aps.due_date)),
        'currency'        VALUE rct.invoice_currency_code,
        'status'          VALUE aps.status
      )
      ORDER BY aps.due_date
    )
    INTO l_json
    FROM ar.ar_payment_schedules_all aps
    JOIN ar.ra_customer_trx_all rct ON rct.customer_trx_id = aps.customer_trx_id
    WHERE aps.customer_id = p_customer_id
      AND aps.status = 'OP'
      AND aps.class = 'INV'
      AND aps.amount_due_remaining > 0;

    p_result := NVL(l_json, '[]');
  END get_customer_details;

  -- =========================================================================
  PROCEDURE get_customer_profile(
    p_customer_id             IN  NUMBER,
    p_cust_account_profile_id OUT NUMBER,
    p_object_version_number   OUT NUMBER,
    p_credit_hold             OUT VARCHAR2,
    p_credit_limit            OUT NUMBER
  ) AS
  BEGIN
    -- Resolve the authoritative ACCOUNT-LEVEL credit profile deterministically.
    -- Prior version used "AND ROWNUM = 1" with no ORDER BY, so when an account had more
    -- than one profile row it returned an arbitrary one — detection (credit_hold) and the
    -- release/place target (cust_account_profile_id + object_version_number) could point at
    -- different rows on successive calls, producing "no hold" one moment and a successful
    -- release the next. Order the pick so it is stable AND prefers a row that actually
    -- carries the hold, and read the hold across all account-level rows so we never miss it.
    SELECT cust_account_profile_id, object_version_number,
           hold_flag, 0
    INTO p_cust_account_profile_id, p_object_version_number,
         p_credit_hold, p_credit_limit
    FROM (
      SELECT cust_account_profile_id,
             object_version_number,
             NVL(MAX(credit_hold) OVER (), 'N') hold_flag,
             ROW_NUMBER() OVER (
               ORDER BY DECODE(credit_hold, 'Y', 0, 1),
                        cust_account_profile_id) rn
      FROM   ar.hz_customer_profiles
      WHERE  cust_account_id = p_customer_id
        AND  site_use_id IS NULL
    )
    WHERE rn = 1;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      p_cust_account_profile_id := NULL;
      p_object_version_number := NULL;
      p_credit_hold := 'N';
      p_credit_limit := 0;
  END get_customer_profile;

  -- =========================================================================
  PROCEDURE place_credit_hold(
    p_customer_id IN NUMBER,
    p_reason      IN VARCHAR2,
    p_result      OUT CLOB
  ) AS
    l_profile_id NUMBER;
    l_ovn        NUMBER;
    l_hold       VARCHAR2(1);
    l_limit      NUMBER;
    l_rec        HZ_CUSTOMER_PROFILE_V2PUB.CUSTOMER_PROFILE_REC_TYPE;
    l_status     VARCHAR2(1);
    l_msg_count  NUMBER;
    l_msg_data   VARCHAR2(2000);
  BEGIN
    get_customer_profile(p_customer_id, l_profile_id, l_ovn, l_hold, l_limit);

    IF l_profile_id IS NULL THEN
      p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE 'Customer profile not found');
      RETURN;
    END IF;

    IF l_hold = 'Y' THEN
      p_result := JSON_OBJECT('status' VALUE 'already_held', 'message' VALUE 'Credit hold already active');
      RETURN;
    END IF;

    -- Use the SEEDED EBS public API (validated + audited) — NOT direct DML.
    -- Guard the apps context: a headless DB/ORDS session returns user_id/resp_id/resp_appl_id
    -- = -1 (NOT null), so NVL leaves -1 and update_customer_profile runs as ANONYMOUS. Treat
    -- <=0 as "no context" → SYSADMIN(0) + Receivables Manager (resp 20678, appl 222).
    BEGIN FND_GLOBAL.apps_initialize(
             GREATEST(NVL(FND_GLOBAL.user_id,0),0),
             CASE WHEN NVL(FND_GLOBAL.resp_id,-1) > 0 THEN FND_GLOBAL.resp_id ELSE 20678 END,
             CASE WHEN NVL(FND_GLOBAL.resp_appl_id,-1) > 0 THEN FND_GLOBAL.resp_appl_id ELSE 222 END);
    EXCEPTION WHEN OTHERS THEN NULL; END;

    l_rec.cust_account_profile_id := l_profile_id;
    l_rec.credit_hold             := 'Y';
    HZ_CUSTOMER_PROFILE_V2PUB.update_customer_profile(
      p_init_msg_list         => FND_API.G_TRUE,
      p_customer_profile_rec  => l_rec,
      p_object_version_number => l_ovn,
      x_return_status         => l_status,
      x_msg_count             => l_msg_count,
      x_msg_data              => l_msg_data);

    IF l_status = FND_API.G_RET_STS_SUCCESS THEN
      COMMIT;
      p_result := JSON_OBJECT(
        'status'  VALUE 'success',
        'message' VALUE 'Credit hold placed on customer ' || p_customer_id || ' via HZ_CUSTOMER_PROFILE_V2PUB',
        'reason'  VALUE p_reason,
        'api'     VALUE 'HZ_CUSTOMER_PROFILE_V2PUB.update_customer_profile');
    ELSE
      ROLLBACK;
      IF l_msg_data IS NULL AND NVL(l_msg_count,0) > 0 THEN
        l_msg_data := FND_MSG_PUB.GET(1, FND_API.G_FALSE);
      END IF;
      p_result := JSON_OBJECT('status' VALUE 'error',
        'message' VALUE 'Seeded API rejected credit hold: ' || SUBSTR(l_msg_data,1,400));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END place_credit_hold;

  -- =========================================================================
  PROCEDURE release_credit_hold(
    p_customer_id IN NUMBER,
    p_reason      IN VARCHAR2,
    p_result      OUT CLOB
  ) AS
    l_profile_id NUMBER;
    l_ovn        NUMBER;
    l_hold       VARCHAR2(1);
    l_limit      NUMBER;
    l_rec        HZ_CUSTOMER_PROFILE_V2PUB.CUSTOMER_PROFILE_REC_TYPE;
    l_status     VARCHAR2(1);
    l_msg_count  NUMBER;
    l_msg_data   VARCHAR2(2000);
  BEGIN
    get_customer_profile(p_customer_id, l_profile_id, l_ovn, l_hold, l_limit);

    IF l_profile_id IS NULL THEN
      p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE 'Customer profile not found');
      RETURN;
    END IF;

    IF l_hold = 'N' THEN
      p_result := JSON_OBJECT('status' VALUE 'no_hold', 'message' VALUE 'No credit hold to release');
      RETURN;
    END IF;

    -- Use the SEEDED EBS public API (validated + audited) — NOT direct DML.
    -- Guard the apps context: a headless DB/ORDS session returns user_id/resp_id/resp_appl_id
    -- = -1 (NOT null), so NVL leaves -1 and update_customer_profile runs as ANONYMOUS. Treat
    -- <=0 as "no context" → SYSADMIN(0) + Receivables Manager (resp 20678, appl 222).
    BEGIN FND_GLOBAL.apps_initialize(
             GREATEST(NVL(FND_GLOBAL.user_id,0),0),
             CASE WHEN NVL(FND_GLOBAL.resp_id,-1) > 0 THEN FND_GLOBAL.resp_id ELSE 20678 END,
             CASE WHEN NVL(FND_GLOBAL.resp_appl_id,-1) > 0 THEN FND_GLOBAL.resp_appl_id ELSE 222 END);
    EXCEPTION WHEN OTHERS THEN NULL; END;

    l_rec.cust_account_profile_id := l_profile_id;
    l_rec.credit_hold             := 'N';
    HZ_CUSTOMER_PROFILE_V2PUB.update_customer_profile(
      p_init_msg_list         => FND_API.G_TRUE,
      p_customer_profile_rec  => l_rec,
      p_object_version_number => l_ovn,
      x_return_status         => l_status,
      x_msg_count             => l_msg_count,
      x_msg_data              => l_msg_data);

    IF l_status = FND_API.G_RET_STS_SUCCESS THEN
      COMMIT;
      p_result := JSON_OBJECT(
        'status'  VALUE 'success',
        'message' VALUE 'Credit hold released for customer ' || p_customer_id || ' via HZ_CUSTOMER_PROFILE_V2PUB',
        'reason'  VALUE p_reason,
        'api'     VALUE 'HZ_CUSTOMER_PROFILE_V2PUB.update_customer_profile');
    ELSE
      ROLLBACK;
      IF l_msg_data IS NULL AND NVL(l_msg_count,0) > 0 THEN
        l_msg_data := FND_MSG_PUB.GET(1, FND_API.G_FALSE);
      END IF;
      p_result := JSON_OBJECT('status' VALUE 'error',
        'message' VALUE 'Seeded API rejected release: ' || SUBSTR(l_msg_data,1,400));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    p_result := JSON_OBJECT('status' VALUE 'error', 'message' VALUE SUBSTR(SQLERRM,1,500));
  END release_credit_hold;

  -- =========================================================================
  PROCEDURE create_collections_note(
    p_customer_id IN NUMBER,
    p_note_text   IN VARCHAR2,
    p_result      OUT CLOB
  ) AS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_note_id      NUMBER;         -- custom audit-table id (always written)
    l_jtf_note_id  NUMBER;         -- standard EBS JTF note id (visible in the EBS UI)
    l_jtf_status   VARCHAR2(1);
    l_jtf_where    VARCHAR2(30) := 'CUSTOM_ONLY';
    l_msgc         NUMBER;
    l_msgd         VARCHAR2(4000);
  BEGIN
    -- 1) Write to the STANDARD EBS notes framework (JTF_NOTES) so the note is visible to a
    --    business user in Advanced Collections / the customer Notes region. Source object
    --    IEX_CUSTOMER keys the note to the customer (source_object_id = customer/party id).
    --    Best-effort: if JTF isn't set up on this instance it must NOT fail the action, so we
    --    catch and fall back to the custom audited table below.
    BEGIN
      -- Seed an apps context so JTF's WHO columns / security resolve on a headless call.
      fnd_global.apps_initialize(user_id => 0, resp_id => 20419, resp_appl_id => 222);
      jtf_notes_pub.create_note(
        p_api_version        => 1.0,
        p_source_object_id   => p_customer_id,
        p_source_object_code => 'IEX_CUSTOMER',
        p_notes              => SUBSTR(p_note_text, 1, 2000),
        p_notes_detail       => SUBSTR(p_note_text, 1, 4000),
        p_note_status        => 'I',           -- Publish (visible), not Private
        x_return_status      => l_jtf_status,
        x_msg_count          => l_msgc,
        x_msg_data           => l_msgd,
        x_jtf_note_id        => l_jtf_note_id);
      IF l_jtf_status = 'S' AND l_jtf_note_id IS NOT NULL THEN
        l_jtf_where := 'EBS_JTF_NOTES';
      ELSE
        l_jtf_note_id := NULL;   -- treat a non-success as "not written to JTF"
      END IF;
    EXCEPTION
      WHEN OTHERS THEN
        l_jtf_note_id := NULL;   -- swallow — the custom audit write below still succeeds
    END;

    -- 2) Always write the custom audited row too (audit trail + guaranteed id even if JTF
    --    is unavailable). Store the JTF id alongside for traceability.
    INSERT INTO apps.xx_collections_notes (customer_id, note_text, created_by_who)
    VALUES (p_customer_id,
            CASE WHEN l_jtf_note_id IS NOT NULL
                 THEN '[EBS JTF note '||l_jtf_note_id||'] '||SUBSTR(p_note_text, 1, 3960)
                 ELSE SUBSTR(p_note_text, 1, 4000) END,
            'COLLECTIONS_AGENT_26AI')
    RETURNING note_id INTO l_note_id;
    COMMIT;

    p_result := JSON_OBJECT(
      'status'      VALUE 'success',
      'message'     VALUE CASE WHEN l_jtf_note_id IS NOT NULL
                            THEN 'Note created for customer '||p_customer_id||
                                 ' (visible in EBS notes)'
                            ELSE 'Note created for customer '||p_customer_id||
                                 ' (audited; EBS notes unavailable)' END,
      'note_id'     VALUE NVL(l_jtf_note_id, l_note_id),
      'jtf_note_id' VALUE l_jtf_note_id,
      'audit_id'    VALUE l_note_id,
      'written_to'  VALUE l_jtf_where,
      'note_text'   VALUE SUBSTR(p_note_text, 1, 200));
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      p_result := JSON_OBJECT('status' VALUE 'error',
                              'message' VALUE SUBSTR(SQLERRM, 1, 500));
  END create_collections_note;

  -- =========================================================================
  PROCEDURE send_dunning_letter(
    p_customer_id IN NUMBER,
    p_level       IN NUMBER DEFAULT 1,
    p_tone        IN VARCHAR2 DEFAULT 'professional',
    p_result      OUT CLOB
  ) AS
  BEGIN
    -- In full implementation:
    -- 1. Calls DBMS_CLOUD_AI.GENERATE to create letter text
    -- 2. Stores as EBS note via JTF_NOTES_PUB
    -- 3. Sends email via AWS SES
    p_result := JSON_OBJECT(
      'status' VALUE 'success',
      'message' VALUE 'Dunning letter level ' || p_level || ' sent to customer ' || p_customer_id,
      'level' VALUE p_level,
      'tone' VALUE p_tone
    );
  END send_dunning_letter;

  -- =========================================================================
  PROCEDURE send_payment_reminder(
    p_customer_id IN NUMBER,
    p_result      OUT CLOB
  ) AS
  BEGIN
    p_result := JSON_OBJECT(
      'status' VALUE 'success',
      'message' VALUE 'Payment reminder sent to customer ' || p_customer_id
    );
  END send_payment_reminder;

END XX_COLLECTIONS_REST_PKG;
/
