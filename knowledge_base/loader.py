"""
Knowledge Base Loader — Generates embeddings and loads them into Oracle 26ai Vector Store.

This script:
1. Connects to the Oracle 26ai database
2. Reads documents from the knowledge_base/ subdirectories (or from DB rows without embeddings)
3. Generates embeddings using Amazon Titan Embed Text v2 via Bedrock
4. Updates the collections_knowledge_base table with embeddings

Usage:
    python loader.py                    # Generate embeddings for rows missing them
    python loader.py --load-files       # Load new documents from files + generate embeddings
"""

import os
import sys
import json
import time
import logging
import argparse
from pathlib import Path

import boto3
import oracledb

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# Rate limiting for Bedrock Titan embeddings
RATE_LIMIT_DELAY = 0.2  # seconds between calls
BATCH_SIZE = 10


def get_db_connection() -> oracledb.Connection:
    """Create Oracle DB connection using environment variables or Secrets Manager."""
    secret_name = os.environ.get("ORACLE_SECRET_NAME", "oracle-26ai-collections-cred")
    region = os.environ.get("AWS_REGION", "us-east-1")

    try:
        client = boto3.client("secretsmanager", region_name=region)
        response = client.get_secret_value(SecretId=secret_name)
        creds = json.loads(response["SecretString"])
    except Exception:
        # Fallback to environment variables for local dev
        creds = {
            "username": os.environ.get("ORACLE_USER", "COLLECTIONS_AI"),
            "password": os.environ.get("ORACLE_PASSWORD", ""),
            "host": os.environ.get("ORACLE_HOST", "localhost"),
            "port": os.environ.get("ORACLE_PORT", "1521"),
            "service_name": os.environ.get("ORACLE_SERVICE", ""),
        }

    dsn = f"{creds['host']}:{creds['port']}/{creds['service_name']}"
    conn = oracledb.connect(
        user=creds["username"],
        password=creds["password"],
        dsn=dsn,
    )
    logger.info(f"Connected to Oracle: {dsn}")
    return conn


def generate_embedding(text: str, bedrock_client) -> list:
    """Generate embedding using Amazon Titan Embed Text v2."""
    # Truncate to Titan's max input (8192 tokens ~= 25000 chars)
    truncated = text[:25000]

    response = bedrock_client.invoke_model(
        modelId="amazon.titan-embed-text-v2:0",
        contentType="application/json",
        accept="application/json",
        body=json.dumps({"inputText": truncated}),
    )
    result = json.loads(response["body"].read())
    return result["embedding"]


def update_missing_embeddings(conn: oracledb.Connection, bedrock_client):
    """Generate embeddings for all rows that have NULL embeddings."""
    with conn.cursor() as cursor:
        cursor.execute(
            "SELECT id, content FROM collections_knowledge_base WHERE embedding IS NULL"
        )
        rows = cursor.fetchall()

    if not rows:
        logger.info("All documents already have embeddings. Nothing to do.")
        return

    logger.info(f"Found {len(rows)} documents without embeddings. Generating...")

    for i, (doc_id, content) in enumerate(rows):
        if hasattr(content, "read"):
            content = content.read()

        try:
            embedding = generate_embedding(content, bedrock_client)
            vector_str = json.dumps(embedding)

            with conn.cursor() as cursor:
                cursor.execute(
                    """UPDATE collections_knowledge_base
                       SET embedding = :vec, updated_at = SYSTIMESTAMP
                       WHERE id = :id""",
                    {"vec": vector_str, "id": doc_id},
                )
            conn.commit()

            logger.info(f"  [{i+1}/{len(rows)}] Generated embedding for doc id={doc_id}")
            # Deliberate throttle between Bedrock embedding calls to stay under the API
            # rate limit during a one-off batch load (not stray debug code).
            time.sleep(RATE_LIMIT_DELAY)  # nosemgrep: arbitrary-sleep

        except Exception as e:
            logger.error(f"  Error generating embedding for doc id={doc_id}: {e}")
            continue

    logger.info("Done generating embeddings.")


def load_files_from_directory(conn: oracledb.Connection, bedrock_client):
    """Load text/markdown files from knowledge_base subdirectories."""
    base_dir = Path(__file__).parent
    subdirs = {"policies": "policy", "sops": "sop", "templates": "template"}

    for subdir_name, doc_type in subdirs.items():
        subdir = base_dir / subdir_name
        if not subdir.exists():
            logger.info(f"Skipping {subdir_name}/ (directory not found)")
            continue

        files = list(subdir.glob("*.txt")) + list(subdir.glob("*.md"))
        logger.info(f"Found {len(files)} files in {subdir_name}/")

        for filepath in files:
            content = filepath.read_text(encoding="utf-8")
            summary = content[:200].replace("\n", " ").strip()

            # Generate embedding
            try:
                embedding = generate_embedding(content, bedrock_client)
                vector_str = json.dumps(embedding)
            except Exception as e:
                logger.error(f"  Error generating embedding for {filepath.name}: {e}")
                vector_str = None

            # Insert into DB
            with conn.cursor() as cursor:
                cursor.execute(
                    """INSERT INTO collections_knowledge_base
                       (content, summary, doc_type, metadata, embedding)
                       VALUES (:content, :summary, :doc_type, :metadata, :embedding)""",
                    {
                        "content": content,
                        "summary": summary[:500],
                        "doc_type": doc_type,
                        "metadata": json.dumps({"source": filepath.name}),
                        "embedding": vector_str,
                    },
                )
            conn.commit()
            logger.info(f"  Loaded: {filepath.name} ({doc_type})")
            # Deliberate throttle between Bedrock embedding calls (batch-load rate limit).
            time.sleep(RATE_LIMIT_DELAY)  # nosemgrep: arbitrary-sleep


def main():
    parser = argparse.ArgumentParser(description="Load/update knowledge base embeddings")
    parser.add_argument("--load-files", action="store_true", help="Load new docs from files")
    args = parser.parse_args()

    region = os.environ.get("AWS_REGION", "us-east-1")
    bedrock_client = boto3.client("bedrock-runtime", region_name=region)
    conn = get_db_connection()

    try:
        if args.load_files:
            load_files_from_directory(conn, bedrock_client)

        # Always update missing embeddings
        update_missing_embeddings(conn, bedrock_client)

    finally:
        conn.close()
        logger.info("Connection closed.")


if __name__ == "__main__":
    main()
