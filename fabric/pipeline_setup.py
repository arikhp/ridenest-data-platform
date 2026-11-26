"""Create (idempotently) the Fabric deployment pipeline "RideNest" and assign the three workspaces.

    python fabric/pipeline_setup.py

Development -> RideNest-dev, Test -> RideNest-preprod, Production -> RideNest-prod.
Uses the Fabric-tenant Azure CLI profile (~/.azure-fabric).
"""
from fabric_api import F, call, workspace_id

PIPELINE = "RideNest"
STAGES = [("Development", "RideNest-dev"), ("Test", "RideNest-preprod"), ("Production", "RideNest-prod")]

pipes = [p for p in call("GET", f"{F}/deploymentPipelines")["value"] if p["displayName"] == PIPELINE]
if pipes:
    pid = pipes[0]["id"]
    print(f"pipeline {PIPELINE} exists")
else:
    pid = call("POST", f"{F}/deploymentPipelines", {
        "displayName": PIPELINE,
        "description": "RideNest executive dashboard: dev -> preprod -> prod. Source of truth: GitHub arikhp/ridenest-data-platform (fabric/).",
        "stages": [{"displayName": s, "description": f"Workspace {w}", "isPublic": False} for s, w in STAGES],
    })["id"]
    print(f"created pipeline {PIPELINE}")

stages = sorted(call("GET", f"{F}/deploymentPipelines/{pid}/stages")["value"], key=lambda s: s["order"])
for stage, (name, ws_name) in zip(stages, STAGES):
    ws = workspace_id(ws_name)
    if stage.get("workspaceId") == ws:
        print(f"  {name:<12} -> {ws_name} (already assigned)")
        continue
    call("POST", f"{F}/deploymentPipelines/{pid}/stages/{stage['id']}/assignWorkspace", {"workspaceId": ws})
    print(f"  {name:<12} -> {ws_name} (assigned)")
