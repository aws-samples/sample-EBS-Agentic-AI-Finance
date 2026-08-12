"""Container HEALTHCHECK for the AgentCore agent runtime (CKV_DOCKER_2).

Exit 0 when the AgentCore /ping contract returns HTTP 200, else exit 1.
"""
import sys
import urllib.request

# Localhost container liveness probe: the URL is a fixed loopback address (no user input,
# no https possible without a cert on 127.0.0.1). Static URL, so no file:// / SSRF risk.
try:
    resp = urllib.request.urlopen("http://127.0.0.1:8080/ping", timeout=4)  # nosec B310  # nosemgrep: insecure-urlopen,dynamic-urllib-use-detected
    sys.exit(0 if resp.status == 200 else 1)
except Exception:
    sys.exit(1)
