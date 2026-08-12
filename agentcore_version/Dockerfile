# =============================================================================
# AgentCore Runtime image — Strands collections/P2P agent + SQLcl 25.2+ MCP server.
#
# AgentCore Runtime is a CONTAINER host (no zip-size limit), VPC-capable, so this is
# the natural home for the agent AND the bundled SQLcl MCP server. The container runs
# an HTTP server (POST /invocations, GET /ping on :8080) via bedrock-agentcore's
# BedrockAgentCoreApp (agentcore_runtime.py).
#
# AgentCore Runtime requires linux/arm64. Build with: docker build --platform linux/arm64
# (deploy.sh `agentcore` stage / the agentcore CLI handle this, incl. CodeBuild so no
# local Docker daemon is required).
# =============================================================================
FROM public.ecr.aws/docker/library/python:3.12-slim

# Fail any stage of a piped RUN command (Semgrep set-pipefail).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- JRE for SQLcl (SQLcl 25.2 needs Java 17+) + tools ---
# python:3.12-slim is Debian; use default-jre-headless (resolves to a current OpenJDK ≥17
# on trixie, where the openjdk-17-jre-headless package name is not available).
RUN apt-get update \
 && apt-get install -y --no-install-recommends default-jre-headless curl unzip ca-certificates \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# --- SQLcl 25.2+ (the version line that ships the MCP server; 25.2.2+ has it) ---
ARG SQLCL_URL=https://download.oracle.com/otn_software/java/sqldeveloper/sqlcl-latest.zip
# pipefail is already set globally via the SHELL directive above; the trailing "|| true"
# is intentional so a missing `sql -V` banner never fails the build.
# nosemgrep: set-pipefail
RUN mkdir -p /opt && cd /opt \
 && curl -fsSL -o /tmp/sqlcl.zip "${SQLCL_URL}" \
 && unzip -q /tmp/sqlcl.zip -d /opt \
 && rm -f /tmp/sqlcl.zip \
 && /opt/sqlcl/bin/sql -V || true

ENV SQLCL_HOME=/opt/sqlcl
ENV SQLCL_USER_HOME=/tmp/sqlcl-cfg
# SQLcl saves connections under $HOME/.dbtools (JVM user.home). Pin HOME to a writable dir
# so the connection-setup process and the `sql -mcp` server share one connection store.
ENV HOME=/tmp/sqlcl-cfg
ENV USE_SQLCL_MCP=1
ENV JAVA_TOOL_OPTIONS=""

WORKDIR /app

# --- Python deps (agent + bedrock-agentcore runtime SDK) ---
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt \
 && pip install --no-cache-dir bedrock-agentcore

# --- Agent code ---
COPY agentcore_runtime.py agent_strands.py healthcheck.py /app/
COPY tools /app/tools

# Run as a non-root user (CKV_DOCKER_3). HOME/SQLcl config dirs are under /tmp (writable
# by any uid), and the app dir is read-only to the runtime, so no chown of /app is needed.
RUN useradd --create-home --uid 10001 appuser \
 && mkdir -p /tmp/sqlcl-cfg && chown -R appuser:appuser /tmp/sqlcl-cfg
USER appuser

EXPOSE 8080
# Liveness check hitting the AgentCore /ping contract (CKV_DOCKER_2).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "/app/healthcheck.py"]
# AgentCore Runtime contract: HTTP server on :8080 (POST /invocations, GET /ping)
CMD ["python", "-u", "agentcore_runtime.py"]
