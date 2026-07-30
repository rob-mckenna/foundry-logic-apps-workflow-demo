"""Print agent versions and their OpenAPI tool server URLs."""

import os
from dotenv import load_dotenv
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential


def main() -> int:
    load_dotenv()
    client = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=DefaultAzureCredential(),
    )
    versions = list(client.agents.list_versions(agent_name=os.environ["AGENT_NAME"]))
    print(f"Total versions: {len(versions)}")
    for v in versions:
        created = getattr(v, "created_at", "?")
        print(f"\n=== Version {v.version} ===")
        print(f"  Created: {created}")
        tools = v.definition.tools if hasattr(v.definition, "tools") else []
        for t in tools:
            d = t.as_dict()
            if d.get("type") == "openapi":
                openapi = d.get("openapi", {})
                spec = openapi.get("spec", {})
                servers = spec.get("servers", [])
                print(f"  Tool name: {openapi.get('name')}")
                for s in servers:
                    print(f"  Server URL: {s.get('url')}")
    return 0


if __name__ == "__main__":
    main()
