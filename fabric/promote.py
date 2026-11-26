"""Promote the RideNest Fabric items one stage forward through the "RideNest" deployment pipeline.

    python fabric/promote.py preprod     # Development -> Test
    python fabric/promote.py prod        # Test -> Production

After the pipeline copies the items, the target's semantic model still carries the source stage's
Snowflake parameters (Fabric's API can't create deployment rules). So this script immediately:
  1. points the model's parameters at the target env (warehouse / role / database),
  2. re-binds it to the env's Snowflake connection and refreshes it (fabric/connect.py).
"""
import subprocess
import sys

from fabric_api import F, PBI, PBI_RES, call, item_id, workspace_id

TARGET = sys.argv[1] if len(sys.argv) > 1 else ""
ORDER = {"preprod": ("Development", "Test"), "prod": ("Test", "Production")}
if TARGET not in ORDER:
    raise SystemExit("usage: promote.py <preprod|prod>   (only one stage at a time)")
src_name, dst_name = ORDER[TARGET]
E = TARGET.upper()
MODEL = "RideNest Executive"
PARAMS = {"SnowflakeWarehouse": f"WH_{E}_BI", "SnowflakeRole": f"{E}_READER", "SnowflakeDatabase": f"RIDENEST_{E}"}

pid = next(p for p in call("GET", f"{F}/deploymentPipelines")["value"] if p["displayName"] == "RideNest")["id"]
stages = {s["displayName"]: s["id"] for s in call("GET", f"{F}/deploymentPipelines/{pid}/stages")["value"]}

note = f"promote.py {TARGET}" + (f" ({sys.argv[2]})" if len(sys.argv) > 2 else "")
call("POST", f"{F}/deploymentPipelines/{pid}/deploy", {
    "sourceStageId": stages[src_name], "targetStageId": stages[dst_name], "note": note[:1024],
    "options": {"allowCreateArtifact": True, "allowOverwriteArtifact": True},
})
print(f"pipeline: {src_name} -> {dst_name} deployed")

ws = workspace_id(f"RideNest-{TARGET}")
model = item_id(ws, MODEL)
call("POST", f"{PBI}/groups/{ws}/datasets/{model}/Default.UpdateParameters",
     {"updateDetails": [{"name": k, "newValue": v} for k, v in PARAMS.items()]}, resource=PBI_RES)
got = {p["name"]: p["currentValue"] for p in
       call("GET", f"{PBI}/groups/{ws}/datasets/{model}/parameters", resource=PBI_RES)["value"]}
wrong = {k: got.get(k) for k, v in PARAMS.items() if got.get(k) != v}
if wrong:
    raise SystemExit(f"parameters not applied: {wrong}")
print(f"parameters -> {', '.join(PARAMS.values())}")

sys.exit(subprocess.call([sys.executable, __file__.replace("promote.py", "connect.py"), TARGET]))
