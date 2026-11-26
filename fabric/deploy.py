"""Deploy the Fabric items in this folder to one RideNest workspace.

    python fabric/deploy.py <dev|preprod|prod>

Auth: Azure CLI login to the Fabric tenant (locally: AZURE_CONFIG_DIR=~/.azure-fabric az login;
in CI: the workflow's az login). Per-environment values come from parameter.yml.
"""
import os
import sys

from azure.identity import AzureCliCredential
from fabric_cicd import FabricWorkspace, publish_all_items

env = sys.argv[1] if len(sys.argv) > 1 else "dev"
assert env in ("dev", "preprod", "prod"), env

ws = FabricWorkspace(
    workspace_name=f"RideNest-{env}",
    environment=env,
    repository_directory=os.path.dirname(os.path.abspath(__file__)),
    item_type_in_scope=["SemanticModel"],
    token_credential=AzureCliCredential(),
)
publish_all_items(ws)
print(f"deployed to RideNest-{env}")
