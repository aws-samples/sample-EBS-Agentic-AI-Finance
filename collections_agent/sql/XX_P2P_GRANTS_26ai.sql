-- =============================================================================
-- XX_P2P_GRANTS_26ai.sql — SELECT grants so COLLECTIONS_AI can build the P2P views.
-- Run as SYS/SYSTEM. MUST run inside PDB ERPUAT (the AP/PO/RCV tables live there,
-- not in CDB$ROOT) — the deploy script connects to the PDB service for this reason.
-- Read-only grants; no write grants to AP base tables (all P2P writes go through the
-- audited APPS.XX_P2P_AP_PKG). Idempotent: re-running just re-grants.
-- =============================================================================
set echo off
set verify off
set pagesize 0
set serveroutput on
-- PDB name is passed as positional arg &1 (see deploy_p2p_layer.sh).
define v_pdb = &1
-- Switch to the PDB as a top-level statement (SYSDBA OS auth lands in CDB$ROOT; a
-- container switch is unreliable inside PL/SQL). Persists for the grants below.
ALTER SESSION SET CONTAINER=&v_pdb;
SELECT 'CONTAINER='||SYS_CONTEXT('USERENV','CON_NAME') FROM dual;
BEGIN
  FOR r IN (
    SELECT 'AP'  owner, 'AP_INVOICES_ALL'           tab FROM dual UNION ALL
    SELECT 'AP', 'AP_INVOICE_LINES_ALL'                 FROM dual UNION ALL
    SELECT 'AP', 'AP_HOLDS_ALL'                         FROM dual UNION ALL
    SELECT 'AP', 'AP_PAYMENT_SCHEDULES_ALL'             FROM dual UNION ALL
    SELECT 'AP', 'AP_SUPPLIERS'                         FROM dual UNION ALL
    SELECT 'PO', 'PO_HEADERS_ALL'                       FROM dual UNION ALL
    SELECT 'PO', 'PO_LINES_ALL'                         FROM dual UNION ALL
    SELECT 'PO', 'PO_LINE_LOCATIONS_ALL'                FROM dual UNION ALL
    SELECT 'PO', 'RCV_TRANSACTIONS'                     FROM dual UNION ALL
    SELECT 'PO', 'RCV_SHIPMENT_LINES'                   FROM dual UNION ALL
    -- Tolerance reconciliation (policy-of-record vs live Payables enforcement):
    SELECT 'AP',   'AP_TOLERANCE_TEMPLATES'             FROM dual UNION ALL
    SELECT 'AP',   'AP_SYSTEM_PARAMETERS_ALL'           FROM dual UNION ALL
    -- OU names: use the NON-editioned base table (APPS.HR_OPERATING_UNITS is edition-
    -- based → ORA-38818 when referenced from a non-editioned schema's view).
    SELECT 'HR',   'HR_ALL_ORGANIZATION_UNITS'          FROM dual
  ) LOOP
    BEGIN
      EXECUTE IMMEDIATE 'GRANT SELECT ON '||r.owner||'.'||r.tab||' TO COLLECTIONS_AI';
      DBMS_OUTPUT.PUT_LINE('GRANT OK   '||r.owner||'.'||r.tab);
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('GRANT SKIP '||r.owner||'.'||r.tab||' -> '||SQLERRM);
    END;
  END LOOP;
END;
/
