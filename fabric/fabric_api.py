"""Tiny Fabric / Power BI REST helper shared by the fabric/ scripts.

Auth: Azure CLI login to the Fabric tenant. Locally that profile lives in ~/.azure-fabric (kept apart
from the RideNest Azure login); FABRIC_AZURE_CONFIG_DIR overrides it (e.g. in CI).
"""
import json
import os
import subprocess
import time
import urllib.error
import urllib.request

F = "https://api.fabric.microsoft.com/v1"
PBI = "https://api.powerbi.com/v1.0/myorg"
FABRIC_RES = "https://api.fabric.microsoft.com"
PBI_RES = "https://analysis.windows.net/powerbi/api"
FABRIC_CFG = os.environ.get("FABRIC_AZURE_CONFIG_DIR", os.path.expanduser("~/.azure-fabric"))
_tokens: dict[str, str] = {}


def az(args, fabric=False) -> str:
    env = dict(os.environ)
    if fabric:
        env["AZURE_CONFIG_DIR"] = FABRIC_CFG
    return subprocess.run(["az", *args], check=True, capture_output=True, text=True, env=env).stdout.strip()


def _token(resource):
    if resource not in _tokens:
        _tokens[resource] = az(["account", "get-access-token", "--resource", resource,
                                "--query", "accessToken", "-o", "tsv"], fabric=True)
    return _tokens[resource]


def call(method, url, body=None, resource=FABRIC_RES, raw=False):
    """JSON request. Long-running Fabric operations (202 + Location) are awaited."""
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {_token(resource)}",
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
            if r.status == 202 and r.headers.get("Location") and not raw:
                return wait_operation(r.headers["Location"], int(r.headers.get("Retry-After", "5")))
            return json.loads(data) if data else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {url.split('?')[0]} -> HTTP {e.code}: {e.read().decode()[:800]}")


def wait_operation(location, delay=5):
    for _ in range(180):
        time.sleep(max(delay, 3))
        op = call("GET", location, raw=True)
        status = op.get("status")
        if status in ("Succeeded", "Failed", "Cancelled"):
            if status != "Succeeded":
                raise SystemExit(f"operation {status}: {json.dumps(op.get('error') or op)[:800]}")
            return op
    raise SystemExit("operation timed out")


def workspace_id(name):
    return next(w for w in call("GET", f"{F}/workspaces")["value"] if w["displayName"] == name)["id"]


def item_id(ws, name, kind="semanticModels"):
    return next(i for i in call("GET", f"{F}/workspaces/{ws}/{kind}")["value"] if i["displayName"] == name)["id"]
