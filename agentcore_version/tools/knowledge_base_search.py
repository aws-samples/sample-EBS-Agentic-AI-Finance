"""
search_knowledge_base — Semantic search over collections policies, SOPs, and templates.

RAG PATH (non-Autonomous 26ai): in-database ONNX embeddings (provider "database").
The knowledge base (COLLECTIONS_KNOWLEDGE_BASE) is embedded with Oracle's prebuilt
all_MiniLM_L12_v2 ONNX model (COLL_EMBED_MODEL, 384-dim). Query embedding + COSINE
ranking happen entirely in-database via xx_kb_search_pkg.search — zero network egress,
deterministic, same vector space for docs and queries. The package auto-falls back to
keyword search if the model/embeddings are absent, so it always returns results.

(Bedrock Titan embeddings are NOT used: DBMS_VECTOR has no AWS provider and
DBMS_CLOUD.SEND_REQUEST signs only OCI/Azure. In-DB ONNX is the design's primary path.)
"""

import os
import json
import logging
import oracledb
import boto3
from strands import tool

logger = logging.getLogger(__name__)

_pool = None


def _get_db_credentials() -> dict:
    secret_name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])


def _get_pool() -> "oracledb.ConnectionPool":
    global _pool
    if _pool is None:
        creds = _get_db_credentials()
        host = os.environ.get("ORACLE_HOST") or creds.get("host")
        port = int(os.environ.get("ORACLE_PORT") or creds.get("port") or 1521)
        service = os.environ.get("ORACLE_SERVICE") or creds.get("service_name")
        if not host or not service:
            raise RuntimeError(
                "Oracle connection not configured: set ORACLE_HOST/ORACLE_SERVICE (env) or "
                "host/service_name in the Secrets Manager secret — no demo default is assumed."
            )
        dsn = f"{host}:{port}/{service}"
        _pool = oracledb.create_pool(
            user=creds.get("username", "COLLECTIONS_AI"),
            password=creds["password"],
            dsn=dsn,
            min=1,
            max=5,
            increment=1,
        )
    return _pool


@tool
def search_knowledge_base(query: str, top_k: int = 5) -> str:
    """
    Search the collections knowledge base using in-database semantic vector search.

    Searches embedded collections policies, SOPs, and dunning templates in Oracle 26ai
    using the in-DB ONNX embedding model (AI Vector Search, COSINE). Returns the most
    relevant documents by meaning. Falls back to keyword search automatically.

    Use this before escalation actions (credit holds, dunning level 3) to ground the
    decision in policy, or to fetch the right dunning template / SOP.

    Args:
        query: Natural language description of what you're looking for. Examples:
               - "policy for credit holds on accounts overdue more than 60 days"
               - "level 2 dunning letter template firm but professional"
               - "SOP for handling disputed invoices"
        top_k: Number of results to return (default 5).

    Returns:
        JSON string with matched documents (doc_type, summary, content, similarity).
    """
    try:
        pool = _get_pool()
        with pool.acquire() as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT doc_type, summary, content, similarity
                    FROM TABLE(xx_kb_search_pkg.search(:q, :k))
                    """,
                    {"q": query, "k": top_k},
                )
                columns = [c[0].lower() for c in cursor.description]
                rows = []
                for r in cursor.fetchall():
                    d = {}
                    for k, v in zip(columns, r):
                        d[k] = v.read() if hasattr(v, "read") else v
                    rows.append(d)

                if rows:
                    return json.dumps({
                        "status": "success",
                        "query": query,
                        "results_count": len(rows),
                        "results": rows,
                    }, default=str)
                return json.dumps({
                    "status": "no_results",
                    "query": query,
                    "message": "No matching documents found in the knowledge base.",
                })

    except oracledb.Error as e:
        logger.error(f"Vector search error: {e}")
        return json.dumps({"status": "error", "query": query, "error": f"Database error: {str(e)}"})
    except Exception as e:
        logger.error(f"Knowledge base search error: {e}")
        return json.dumps({"status": "error", "query": query, "error": str(e)})
