"""Container HEALTHCHECK for the MCP server (CKV_DOCKER_2).

Exit 0 if the streamable-HTTP endpoint responds at all (an HTTP error such as
405/406 still proves the server process is up and listening); exit 1 only on a
connection-level failure.
"""
import sys
import urllib.error
import urllib.request

# Localhost container liveness probe: fixed loopback URL (no user input, no https on
# 127.0.0.1). Static URL, so no file:// / SSRF risk.
try:
    urllib.request.urlopen("http://127.0.0.1:8000/mcp", timeout=4)  # nosec B310  # nosemgrep: insecure-urlopen,dynamic-urllib-use-detected
except urllib.error.HTTPError:
    sys.exit(0)
except Exception:
    sys.exit(1)
sys.exit(0)
