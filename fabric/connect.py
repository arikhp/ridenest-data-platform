"""Give the RideNest semantic model its Snowflake credentials, then refresh it.

    python fabric/connect.py <dev|preprod|prod> [--no-refresh]

1. Reads SVC_RIDENEST_<ENV>_BI's private key from the env's RideNest Key Vault (Azure tenant, default
   Azure CLI profile). It stays in memory: never printed, never written to disk.
2. Creates or updates the Fabric shareable cloud connection `ridenest-snowflake-<env>` (Snowflake, key-pair).
3. Binds the semantic model `RideNest Executive` in workspace RideNest-<env> to it and starts a refresh.

Fabric calls use the Fabric-tenant Azure CLI profile in ~/.azure-fabric (FABRIC_AZURE_CONFIG_DIR overrides).
"""
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ENV = sys.argv[1] if len(sys.argv) > 1 else "dev"
assert ENV in ("dev", "preprod", "prod"), ENV
E = ENV.upper()
SERVER = "qkvpwrb-gb28666.snowflakecomputing.com"
WAREHOUSE, USER = f"WH_{E}_BI", f"SVC_RIDENEST_{E}_BI"
MODEL, WORKSPACE, CONN = "RideNest Executive", f"RideNest-{ENV}", f"ridenest-snowflake-{ENV}"
FABRIC_CFG = os.environ.get("FABRIC_AZURE_CONFIG_DIR", os.path.expanduser("~/.azure-fabric"))


def az(args, fabric=False):
    env = dict(os.environ)
    if fabric:
        env["AZURE_CONFIG_DIR"] = FABRIC_CFG
    return subprocess.run(["az", *args], check=True, capture_output=True, text=True, env=env).stdout.strip()


def private_key() -> str:
    sub = az(["account", "show", "--query", "id", "-o", "tsv"])
    vault = f"kv-ridenest-{ENV}-{hashlib.sha1(sub.encode()).hexdigest()[:4]}"
    return az(["keyvault", "secret", "show", "--vault-name", vault, "-n", "snowflake-bi-private-key",
               "--query", "value", "-o", "tsv"])


TOKENS = {}


def call(method, url, body=None, resource="https://api.fabric.microsoft.com"):
    if resource not in TOKENS:
        TOKENS[resource] = az(["account", "get-access-token", "--resource", resource, "--query", "accessToken",
                               "-o", "tsv"], fabric=True)
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOKENS[resource]}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {url.split('?')[0]} -> HTTP {e.code}: {e.read().decode()[:600]}")


F = "https://api.fabric.microsoft.com/v1"
PBI = "https://api.powerbi.com/v1.0/myorg"

ws = next(w for w in call("GET", f"{F}/workspaces")[1]["value"] if w["displayName"] == WORKSPACE)["id"]
model = next(i for i in call("GET", f"{F}/workspaces/{ws}/semanticModels")[1]["value"] if i["displayName"] == MODEL)["id"]

credentials = {"credentialType": "KeyPair", "identifier": USER, "privateKey": private_key()}
existing = [c for c in call("GET", f"{F}/connections")[1]["value"] if c.get("displayName") == CONN]
cred_details = {"singleSignOnType": "None", "connectionEncryption": "NotEncrypted", "skipTestConnection": False,
                "credentials": credentials}
if existing:
    conn = existing[0]["id"]
    call("PATCH", f"{F}/connections/{conn}", {"connectivityType": "ShareableCloud", "credentialDetails": cred_details})
    print(f"updated connection {CONN}")
else:
    conn = call("POST", f"{F}/connections", {
        "connectivityType": "ShareableCloud",
        "displayName": CONN,
        "privacyLevel": "Organizational",
        "connectionDetails": {"type": "Snowflake", "creationMethod": "Snowflake.Databases",
                              "parameters": [{"dataType": "Text", "name": "server", "value": SERVER},
                                             {"dataType": "Text", "name": "warehouse", "value": WAREHOUSE}]},
        "credentialDetails": cred_details,
    })[1]["id"]
    print(f"created connection {CONN} (key-pair, test passed)")
del credentials

call("POST", f"{F}/workspaces/{ws}/semanticModels/{model}/bindConnection", {"connectionBinding": {
    "id": conn, "connectivityType": "ShareableCloud",
    "connectionDetails": {"type": "Snowflake", "path": f"{SERVER};{WAREHOUSE}"}}})
print(f"bound {MODEL} ({WORKSPACE}) -> {CONN}")

if "--no-refresh" in sys.argv:
    raise SystemExit(0)
PBI_RES = "https://analysis.windows.net/powerbi/api"
call("POST", f"{PBI}/groups/{ws}/datasets/{model}/refreshes", {"notifyOption": "NoNotification"}, PBI_RES)
for _ in range(60):
    time.sleep(10)
    last = call("GET", f"{PBI}/groups/{ws}/datasets/{model}/refreshes?$top=1", resource=PBI_RES)[1]["value"][0]
    if last["status"] != "Unknown":  # Unknown = still running
        break
print(f"refresh: {last['status']}" + (f" - {last.get('serviceExceptionJson', '')[:500]}" if last["status"] != "Completed" else ""))
sys.exit(0 if last["status"] == "Completed" else 1)
