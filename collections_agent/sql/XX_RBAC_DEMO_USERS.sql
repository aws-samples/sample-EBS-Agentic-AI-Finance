-- =============================================================================
-- create_demo_users.sql — provision demo FND_USERs + responsibilities for the
-- RBAC demo (Cognito group -> EBS responsibility mapping).
-- Run as APPS on PDB ERPUAT. Uses seeded fnd_user_pkg APIs (supported path).
-- Idempotent: skips create if the user already exists; addresp is safe to re-run.
-- =============================================================================
set echo off feed off serveroutput on size unlimited lines 200 pages 100
whenever sqlerror continue

DECLARE
  -- responsibility coordinates (from live discovery)
  -- Collections Agent : resp_id 22941, appl_id 695 (IEX)
  -- Receivables Manager: resp_id 20678, appl_id 222 (AR)
  -- Payables Manager  : resp_id 20639, appl_id 200 (SQLAP)
  -- Payables Inquiry   : resp_id 20640, appl_id 200 (SQLAP)
  TYPE t_resp IS RECORD (appl_id NUMBER, resp_id NUMBER, label VARCHAR2(60));
  TYPE t_resp_tab IS TABLE OF t_resp;

  PROCEDURE ensure_user(p_user IN VARCHAR2, p_email IN VARCHAR2, p_desc IN VARCHAR2) IS
    l_cnt NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_cnt FROM applsys.fnd_user WHERE user_name = UPPER(p_user);
    IF l_cnt = 0 THEN
      fnd_user_pkg.createuser(
        x_user_name                => UPPER(p_user),
        x_owner                    => NULL,
        x_unencrypted_password     => 'Welcome_26ai1',
        x_session_number           => 0,
        x_start_date               => SYSDATE - 1,
        x_end_date                 => NULL,
        x_last_logon_date          => NULL,
        x_description              => p_desc,
        x_password_date            => SYSDATE - 1,
        x_password_accesses_left   => NULL,
        x_password_lifespan_accesses => NULL,
        x_password_lifespan_days   => NULL,
        x_employee_id              => NULL,
        x_email_address            => p_email,
        x_fax                      => NULL,
        x_customer_id              => NULL,
        x_supplier_id              => NULL);
      DBMS_OUTPUT.PUT_LINE('CREATED user '||UPPER(p_user));
    ELSE
      -- keep email current
      UPDATE applsys.fnd_user SET email_address = p_email
       WHERE user_name = UPPER(p_user) AND NVL(email_address,'~') <> p_email;
      DBMS_OUTPUT.PUT_LINE('EXISTS  user '||UPPER(p_user)||' (email synced)');
    END IF;
  END ensure_user;

  PROCEDURE grant_resp(p_user IN VARCHAR2, p_appl_id IN NUMBER, p_resp_id IN NUMBER, p_label IN VARCHAR2) IS
    l_appl_short  VARCHAR2(50);
    l_resp_key    VARCHAR2(100);
  BEGIN
    SELECT application_short_name INTO l_appl_short FROM apps.fnd_application WHERE application_id = p_appl_id;
    SELECT responsibility_key INTO l_resp_key FROM apps.fnd_responsibility
     WHERE responsibility_id = p_resp_id AND application_id = p_appl_id;
    fnd_user_pkg.addresp(
      username        => UPPER(p_user),
      resp_app        => l_appl_short,
      resp_key        => l_resp_key,
      security_group  => 'STANDARD',
      description     => 'RBAC demo grant',
      start_date      => SYSDATE - 1,
      end_date        => NULL);
    DBMS_OUTPUT.PUT_LINE('  + '||UPPER(p_user)||' -> '||p_label);
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('  ! '||UPPER(p_user)||' -> '||p_label||' : '||SQLERRM);
  END grant_resp;

BEGIN
  -- The Cognito RBAC demo (setup_rbac.sh) uses two generic personas:
  --   demo-manager@example.com  -> custom:ebs_username=SYSADMIN, groups ar-managers+ap-managers
  --   demo-sales@example.com    -> read-only (ar-analysts); no EBS responsibility needed
  -- 'demo-manager' maps to the existing EBS SYSADMIN so agent writes always carry a valid FND_USER
  -- (even if this optional rbac-ebs stage isn't run). We therefore only ensure SYSADMIN carries the
  -- AR + AP responsibilities for the demo — no real-named users are created.
  ensure_user('DEMO_MANAGER', 'demo-manager@example.com', 'RBAC demo - full AR+AP manager (generic)');

  -- Responsibilities.
  -- SYSADMIN = full AR + AP (backs the demo-manager persona; already the EBS superuser).
  grant_resp('SYSADMIN', 695, 22941, 'Collections Agent (IEX)');
  grant_resp('SYSADMIN', 222, 20678, 'Receivables Manager (AR)');
  grant_resp('SYSADMIN', 200, 20639, 'Payables Manager (AP)');
  -- DEMO_MANAGER = full AR + AP too, if you prefer a dedicated (non-superuser) demo FND_USER.
  grant_resp('DEMO_MANAGER', 695, 22941, 'Collections Agent (IEX)');
  grant_resp('DEMO_MANAGER', 222, 20678, 'Receivables Manager (AR)');
  grant_resp('DEMO_MANAGER', 200, 20639, 'Payables Manager (AP)');

  COMMIT;
  DBMS_OUTPUT.PUT_LINE('COMMIT done.');
END;
/

prompt === VERIFY: users ===
col user_name format a12
col email_address format a28
select user_name, email_address, to_char(end_date,'YYYY-MM-DD') end_date
from   applsys.fnd_user
where  user_name in ('SYSADMIN','DEMO_MANAGER')
order  by user_name;

prompt === VERIFY: responsibilities granted ===
col responsibility_name format a40
select u.user_name, r.responsibility_name
from   apps.fnd_user_resp_groups_direct d
join   applsys.fnd_user u on u.user_id = d.user_id
join   apps.fnd_responsibility_vl r on r.responsibility_id = d.responsibility_id
where  u.user_name in ('SYSADMIN','DEMO_MANAGER')
and    r.responsibility_id in (22941, 20678, 20639, 20640)
and    nvl(d.end_date, sysdate+1) > sysdate
order  by u.user_name, r.responsibility_name;

exit
