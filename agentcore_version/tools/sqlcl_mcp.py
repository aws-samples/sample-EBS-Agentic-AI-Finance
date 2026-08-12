"""
sqlcl_mcp — SQLcl 25.2+ Model Context Protocol (MCP) server as an agent tool provider.

WHAT THIS IS
  The non-Autonomous 26ai DB has NO managed MCP endpoint (that is an ADB-only feature).
  Per the design (DETAILED_DESIGN.md Part I §5.3b/5.6, SOLUTION_OVERVIEW "MCP & AI capability strategy"),
  the customer-managed MCP path is Oracle SQLcl run as an MCP server (`sql -mcp`). SQLcl 25.2.2+
  exposes governed CONNECTIONS + SQL tools (connect, list-connections, run-sql, run-sqlcl)
  over MCP. This module lets the Strands agent CONSUME those tools as a runtime tool provider.

HOW IT IS WIRED (co-located stdio, not a network endpoint)
  SQLcl MCP speaks JSON-RPC over a child process's stdio. The agent runtime is VPC-attached and
  already reaches the DB on 1521, so we spawn `sql -mcp` AS A LOCAL SUBPROCESS inside the agent
  container and let Strands' MCPClient talk to it over stdio. No SSM tunnel, no open port, no
  separate host. SQLcl connects to the DB using a saved connection (SQLCL_CONN) created at
  container build/start from the same Secrets Manager creds the other tools use.

WHY GOVERNED / SOX-SAFE
  SQLcl MCP runs SQL under the COLLECTIONS_AI connection's own grants (read on the AR views +
  EBS AR tables). It does NOT bypass the audited ISG-REST write-back path — EBS mutations still
  go through execute_collections_action. SQLcl MCP also records its activity to a SQLCL_MCP log
  table, adding an audit trail for agent-issued SQL.

ENABLEMENT
  Off by default. Set USE_SQLCL_MCP=1 (and ship the container image that bundles SQLcl + a JRE)
  to have agent_strands attach these tools. When off, get_sqlcl_mcp_tools() returns [] and the
  agent keeps using execute_oracle_ai_query exactly as today — zero behaviour change.

PORTABILITY PAYOFF
  If the DB is later migrated to Autonomous, swap this stdio MCPClient for the managed per-DB MCP
  HTTPS endpoint (OAuth bearer); the agent's tool-consumption code barely changes.

Refs:
  SQLcl MCP server: https://docs.oracle.com/en/database/oracle/sql-developer-command-line/25.2/sqcug/starting-and-managing-sqlcl-mcp-server.html
  How it works:     https://docs.oracle.com/en/database/oracle/sql-developer-command-line/25.2/sqcug/how-sqlcl-mcp-server-works.html
"""

import os
import json
import shutil
import logging
import tempfile

import boto3

logger = logging.getLogger(__name__)

# Default SQLcl config/connection-store dir. Derived from the platform temp dir rather than a
# hardcoded "/tmp/..." literal (Bandit B108); overridable via SQLCL_USER_HOME. In the container
# the Dockerfile sets SQLCL_USER_HOME/HOME explicitly, so this default is only a fallback.
_DEFAULT_SQLCL_HOME = os.path.join(tempfile.gettempdir(), "sqlcl-cfg")

# Module-level handle so the spawned SQLcl MCP process + client persist for the
# life of the warm Lambda/container (one cold-start cost, reused across invokes).
_mcp_client = None


def _get_db_credentials() -> dict:
    secret_name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])


def _sqlcl_bin() -> str:
    """Locate the SQLcl launcher inside the image (SQLCL_HOME/bin/sql or on PATH)."""
    home = os.environ.get("SQLCL_HOME")
    if home:
        cand = os.path.join(home, "bin", "sql")
        if os.path.exists(cand):
            return cand
    found = shutil.which("sql")
    if found:
        return found
    raise FileNotFoundError(
        "SQLcl launcher not found. Set SQLCL_HOME or install SQLcl on PATH "
        "(the agent container image must bundle SQLcl 25.2+ and a JRE)."
    )


def _ensure_saved_connection() -> str:
    """
    Ensure an isolated SQLcl saved connection exists so `sql -mcp` can offer the DB
    by name (the MCP `connect` tool takes a saved-connection NAME, never raw creds).

    The connection is stored via the documented `conn -save … -savepwd` flow into an
    isolated, fresh SQLCL_USER_HOME. We disable the SQLcl secure-password prompt
    (`set secureconfig off` / SQLCL_HOME-independent) so `-savepwd` persists headlessly
    without asking for a master password — otherwise the saved password is dropped and
    the MCP `list-connections` tool sees nothing. Returns the connection name.

    Idempotent + safe on every cold start (SQLcl overwrites the stored entry).
    """
    import subprocess

    conn_name = os.environ.get("SQLCL_CONN", "EBS_COLLECTIONS")
    creds = _get_db_credentials()
    user = creds.get("username", "COLLECTIONS_AI")
    pwd = creds["password"]
    host = os.environ.get("ORACLE_HOST") or creds.get("host")
    port = int(os.environ.get("ORACLE_PORT") or creds.get("port") or 1521)
    service = os.environ.get("ORACLE_SERVICE") or creds.get("service_name")
    if not host or not service:
        raise RuntimeError(
            "Oracle connection not configured: set ORACLE_HOST/ORACLE_SERVICE (env) or "
            "host/service_name in the Secrets Manager secret — no demo default is assumed."
        )
    ez = f"{host}:{port}/{service}"

    user_home = os.environ.get("SQLCL_USER_HOME", _DEFAULT_SQLCL_HOME)
    os.makedirs(user_home, exist_ok=True)

    # SQLcl persists saved connections under $HOME/.dbtools (driven by the JVM user.home,
    # i.e. the HOME env var) — SQLCL_USER_HOME alone does NOT redirect the connection store.
    # In the container the process is root (HOME=/root); point HOME at our writable dir so
    # BOTH this setup process and the `sql -mcp` subprocess share the same store.
    # `set secureconfig off` stops SQLcl demanding an interactive master password for the
    # secure store, so `-savepwd` persists headlessly.
    script = (
        "set secureconfig off\n"
        f"connmgr delete -conn {conn_name}\n"
        f"conn -save {conn_name} -savepwd {user}/{pwd}@{ez}\n"
        "connmgr list\n"
        "exit\n"
    )
    env = {
        **os.environ,
        "HOME": user_home,
        "SQLCL_USER_HOME": user_home,
        "JAVA_TOOL_OPTIONS": "",
    }
    # Fixed binary path + static "/nolog" arg, no shell=True; the SQL runs via stdin (input=),
    # not the command line. No externally-controlled value reaches the argv, so there is no
    # command-injection surface.
    proc = subprocess.run(  # nosemgrep: dangerous-subprocess-use-audit
        [_sqlcl_bin(), "/nolog"],
        input=script, env=env, text=True, capture_output=True, timeout=120,
    )
    logger.info("SQLcl connmgr setup rc=%s user_home=%s", proc.returncode, user_home)
    # Log the connmgr list so we can confirm the saved connection is visible to SQLcl
    # (the same store the MCP server reads). Truncated to keep logs tidy.
    logger.info("SQLcl connmgr stdout: %s", (proc.stdout or "")[-800:])
    if proc.stderr:
        logger.info("SQLcl connmgr stderr: %s", proc.stderr[-400:])
    return conn_name


def get_sqlcl_mcp_tools() -> list:
    """
    Spawn `sql -mcp` as a local stdio subprocess and return its MCP tools as Strands tools.

    Returns an empty list (never raises) when USE_SQLCL_MCP != 1 or when the MCP client
    cannot be started, so the agent degrades gracefully to its built-in tools.
    """
    global _mcp_client
    if os.environ.get("USE_SQLCL_MCP", "0") != "1":
        return []

    try:
        # Imported lazily so the dependency is only needed when the feature is enabled.
        from mcp import StdioServerParameters, stdio_client
        from strands.tools.mcp import MCPClient

        conn_name = _ensure_saved_connection()
        user_home = os.environ.get("SQLCL_USER_HOME", _DEFAULT_SQLCL_HOME)

        # `sql -mcp` starts the MCP server; the LLM calls its connect tool with conn_name,
        # then run-sql. JAVA_TOOL_OPTIONS cleared so banners never corrupt the JSON-RPC stream.
        # HOME must match _ensure_saved_connection so the MCP server reads the SAME
        # $HOME/.dbtools connection store the saved connection was written to.
        params = StdioServerParameters(
            command=_sqlcl_bin(),
            args=["-mcp"],
            env={
                **os.environ,
                "HOME": user_home,
                "SQLCL_USER_HOME": user_home,
                "JAVA_TOOL_OPTIONS": "",
            },
        )

        _mcp_client = MCPClient(lambda: stdio_client(params))
        _mcp_client.start()
        tools = _mcp_client.list_tools_sync()
        logger.info("SQLcl MCP started; %d tools available (conn=%s)", len(tools), conn_name)
        return tools

    except Exception as e:
        logger.warning("SQLcl MCP unavailable, falling back to built-in tools: %s", e)
        _mcp_client = None
        return []
