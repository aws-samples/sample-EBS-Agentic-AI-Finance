-- =============================================================================
-- xx_selectai_pkg.sql
-- SELECT AI interface for APEX pages (Oracle 26ai EBS Collections).
-- Run as COLLECTIONS_AI in the ERPUAT PDB.
--
-- Wraps DBMS_CLOUD_AI against the EBS_COLLECTIONS profile so APEX regions and
-- AJAX callbacks can call natural-language analytics directly (no agent needed).
-- =============================================================================

CREATE OR REPLACE PACKAGE xx_selectai_pkg AS
  c_profile CONSTANT VARCHAR2(50) := 'EBS_COLLECTIONS';

  -- Return generated SQL only (for "show me the SQL" / debugging)
  FUNCTION showsql(p_prompt IN VARCHAR2) RETURN CLOB;

  -- Run the generated SQL and return JSON rows (for reports/cards)
  FUNCTION runsql(p_prompt IN VARCHAR2) RETURN CLOB;

  -- Natural-language narration of results
  FUNCTION narrate(p_prompt IN VARCHAR2) RETURN CLOB;

  -- Free-form chat (no SQL)
  FUNCTION chat(p_prompt IN VARCHAR2) RETURN CLOB;

  -- Returns a runnable SELECT statement string for use as an APEX region source.
  -- Strips markdown fences if the model adds them.
  FUNCTION sql_for_region(p_prompt IN VARCHAR2) RETURN CLOB;
END xx_selectai_pkg;
/

CREATE OR REPLACE PACKAGE BODY xx_selectai_pkg AS

  FUNCTION g(p_prompt IN VARCHAR2, p_action IN VARCHAR2) RETURN CLOB AS
    l_out CLOB;
  BEGIN
    l_out := DBMS_CLOUD_AI.GENERATE(
               prompt       => p_prompt,
               profile_name => c_profile,
               action       => p_action);
    RETURN l_out;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN '{"error":"'||REPLACE(SQLERRM,'"','''')||'"}';
  END g;

  FUNCTION showsql(p_prompt IN VARCHAR2) RETURN CLOB AS
  BEGIN RETURN g(p_prompt, 'showsql'); END;

  FUNCTION runsql(p_prompt IN VARCHAR2) RETURN CLOB AS
  BEGIN RETURN g(p_prompt, 'runsql'); END;

  FUNCTION narrate(p_prompt IN VARCHAR2) RETURN CLOB AS
  BEGIN RETURN g(p_prompt, 'narrate'); END;

  FUNCTION chat(p_prompt IN VARCHAR2) RETURN CLOB AS
  BEGIN RETURN g(p_prompt, 'chat'); END;

  FUNCTION sql_for_region(p_prompt IN VARCHAR2) RETURN CLOB AS
    l_sql CLOB;
  BEGIN
    l_sql := DBMS_CLOUD_AI.GENERATE(
               prompt       => p_prompt,
               profile_name => c_profile,
               action       => 'showsql');
    -- strip ```sql ... ``` fences if present
    l_sql := REGEXP_REPLACE(l_sql, '```sql', '', 1, 0, 'i');
    l_sql := REPLACE(l_sql, '```', '');
    RETURN TRIM(l_sql);
  END sql_for_region;

END xx_selectai_pkg;
/
